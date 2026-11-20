// 把 guard 挂到 Fastify 上：
// - onRoute：每注册一个路由，都必须在 permissions.json 里有对应的行，否则启动就失败（新接口忘了写权限 = 起不来）。
// - onRequest：在解析 body 之前判权限。public 的只查条件（演示开关）；其余先认令牌，再按身份查表。
//   没令牌 / 令牌不认识 → 401 unauthorized；被踢设备 → 401 revoked；身份无权 → 403 forbidden；
//   注销期间写账、开通 → 403 delete_pending。
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { authenticate, bearerToken, type AuthContext } from "./authenticate.ts";
import { Guard, routeToRulePath, type Facts } from "./guard.ts";

declare module "fastify" {
  interface FastifyRequest {
    /** 需要登录的接口里一定有；public 接口里是 undefined */
    auth?: AuthContext;
    /** 服务器收到请求的时间（测试里可以拨钟） */
    receivedAt: Date;
  }
}

export function installGuard(app: FastifyInstance, guard: Guard): void {
  app.decorateRequest("auth", undefined);
  app.decorateRequest("receivedAt", undefined as unknown as Date);

  app.addHook("onRoute", (route) => {
    const methods = Array.isArray(route.method) ? route.method : [route.method];
    for (const m of methods) {
      if (m === "HEAD" || m === "OPTIONS") continue;
      if (!guard.httpRule(m, routeToRulePath(route.url))) {
        throw new Error(`路由 ${m} ${route.url} 不在 contracts/permissions.json 里；先在权限表里加一行`);
      }
    }
  });

  app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
    req.receivedAt = app.deps.clock();
    const url = req.routeOptions.url;
    if (!url) return; // 没匹配到路由：交给 404
    const rule = guard.httpRule(req.method, routeToRulePath(url));
    if (!rule) return deny(reply, 403, "forbidden");
    const facts: Facts = {
      now: req.receivedAt,
      config: { demoLoginEnabled: app.deps.config.demoLoginEnabled, recoveryMode: app.deps.config.recoveryMode },
    };
    if (rule.family.decision === "public") {
      // 公开接口三种身份的格子一样，只看条件
      const v = guard.decide(rule, "family", facts);
      if (!v.ok) return deny(reply, v.status!, v.code!);
      return;
    }
    const token = bearerToken(req.headers.authorization);
    const auth = token ? await authenticate(app.deps.db.kysely, token, req.receivedAt) : undefined;
    if (!auth) return deny(reply, 401, "unauthorized");
    req.auth = auth;
    const params = (req.params ?? {}) as Record<string, string | undefined>;
    const v = guard.decide(rule, auth.identity, {
      ...facts,
      callerDeviceId: auth.device.id,
      targetDeviceId: params.id,
      revokedAt: auth.device.revokedAt,
      deletePending: auth.account.deleteRequestedAt !== null,
    });
    if (!v.ok) return deny(reply, v.status!, v.code!);
  });
}

function deny(reply: FastifyReply, status: number, code: string) {
  return reply.code(status).send({ code });
}

/** 路由里取登录信息（guard 已经保证有） */
export function authOf(req: FastifyRequest): AuthContext {
  if (!req.auth) throw new Error("这个接口没有经过登录校验");
  return req.auth;
}
