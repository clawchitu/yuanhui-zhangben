// Fastify 应用。只组装路由和公共错误格式，不在这里连数据库（由调用方传入，测试里每个文件一个独立 schema）。
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.ts";
import type { Db } from "./db.ts";
import { healthRoutes } from "./routes/health.ts";
import { configRoutes } from "./routes/config.ts";
import { authRoutes } from "./routes/auth.ts";
import { deviceRoutes } from "./routes/devices.ts";
import { accountRoutes } from "./routes/account.ts";
import { Guard } from "./auth/guard.ts";
import { installGuard } from "./auth/plugin.ts";
import { DEFAULT_RATE_LIMITS, type RateLimits } from "./auth/ratelimit.ts";
import { verifyPassword } from "./auth/password.ts";

export interface AppDeps {
  config: Config;
  db: Db;
  /** 测试里传 false 关日志 */
  logger?: boolean;
  /** 服务器时钟（测试里拨钟测锁定、开通码过期） */
  clock?: () => Date;
  /** 按 IP 限速（测试里调小） */
  rateLimits?: Partial<RateLimits>;
  /** 验密码（测试里包一层，控制并发请求的交错顺序；照样调真实的 argon2id） */
  verifyPassword?: typeof verifyPassword;
  /**
   * 只给测试用：建设备拿到称呼锁之后、插入设备之前调用，用来在真实 Postgres 上做受控交错。
   * 生产不传，默认无操作；只能在 buildApp 时由代码传入，没有任何请求能触发或改它。
   */
  afterDeviceLabelLock?: () => Promise<void>;
}

export interface ResolvedDeps extends AppDeps {
  clock: () => Date;
  rateLimits: RateLimits;
  verifyPassword: typeof verifyPassword;
  afterDeviceLabelLock: () => Promise<void>;
}

declare module "fastify" {
  interface FastifyInstance {
    deps: ResolvedDeps;
  }
}

export function buildApp(input: AppDeps): FastifyInstance {
  const deps: ResolvedDeps = {
    ...input,
    clock: input.clock ?? (() => new Date()),
    rateLimits: { ...DEFAULT_RATE_LIMITS, ...input.rateLimits },
    verifyPassword: input.verifyPassword ?? verifyPassword,
    afterDeviceLabelLock: input.afterDeviceLabelLock ?? (async () => {}),
  };
  const app = Fastify({
    // 前面有 Caddy 反代时打开，按 X-Forwarded-For 取客户端 IP（按 IP 限速要用）
    trustProxy: deps.config.trustProxy,
    logger:
      deps.logger === false
        ? false
        : {
            level: deps.config.logLevel,
            // 令牌、口令、开通码不进日志
            redact: {
              paths: ["req.headers.authorization", "req.headers.cookie", "body.password", "body.code", "body.token"],
              remove: true,
            },
          },
    bodyLimit: 1024 * 1024,
  });
  app.decorate("deps", deps);

  // 统一错误格式：契约 components/schemas/Error，{ code, message? }
  app.setNotFoundHandler((_req, reply) => {
    reply.code(404).send({ code: "not_found" });
  });
  app.setErrorHandler((err: { validation?: unknown; statusCode?: number; message: string }, req, reply) => {
    if (err.validation) {
      reply.code(400).send({ code: "invalid", message: err.message });
      return;
    }
    const status = err.statusCode && err.statusCode >= 400 && err.statusCode < 500 ? err.statusCode : 500;
    if (status >= 500) req.log.error({ err }, "未处理的错误");
    reply.code(status).send(status === 400 ? { code: "invalid" } : status === 404 ? { code: "not_found" } : { code: "unavailable" });
  });

  // guard 必须在注册路由之前装上：onRoute 要检查每个路由都在 permissions.json 里
  installGuard(app, new Guard());
  app.register(healthRoutes);
  app.register(configRoutes);
  app.register(authRoutes);
  app.register(deviceRoutes);
  app.register(accountRoutes);
  return app;
}
