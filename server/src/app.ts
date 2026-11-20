// Fastify 应用。只组装路由和公共错误格式，不在这里连数据库（由调用方传入，测试里每个文件一个独立 schema）。
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.ts";
import type { Db } from "./db.ts";
import { healthRoutes } from "./routes/health.ts";
import { configRoutes } from "./routes/config.ts";
import { authRoutes } from "./routes/auth.ts";
import { deviceRoutes } from "./routes/devices.ts";
import { accountRoutes } from "./routes/account.ts";
import { syncRoutes } from "./routes/sync.ts";
import { DEFAULT_PAGE_SIZE } from "./sync/pull.ts";
import { Guard } from "./auth/guard.ts";
import { installGuard } from "./auth/plugin.ts";
import { DEFAULT_RATE_LIMITS, type RateLimits } from "./auth/ratelimit.ts";
import { verifyPassword } from "./auth/password.ts";

/**
 * 请求体上限 1 MiB（§4.2）。最大的合法 op（200 行的卖出、每个字符串都写满、非 ASCII 全转义成 \uXXXX）约 0.75 MiB，
 * 单独一个总能发出去；手机按字节拆批（≤200 个 op 且 ≤ 1 MiB）。超过返回 413 invalid，一个 op 都不处理。
 */
export const BODY_LIMIT = 1024 * 1024;

export interface AppDeps {
  config: Config;
  db: Db;
  /** 测试里传 false 关日志 */
  logger?: boolean;
  /** 只给测试用：日志写到这里（逐行 JSON），用来断言某条路径记了日志。传了就忽略 logger: false */
  logStream?: { write(line: string): void };
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
  /** 同步每条流每页多少行（§4.2 默认 500；测试里调小测分页） */
  syncPageSize?: number;
}

export interface ResolvedDeps extends AppDeps {
  clock: () => Date;
  rateLimits: RateLimits;
  verifyPassword: typeof verifyPassword;
  afterDeviceLabelLock: () => Promise<void>;
  syncPageSize: number;
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
    syncPageSize: input.syncPageSize ?? DEFAULT_PAGE_SIZE,
  };
  if (!Number.isInteger(deps.syncPageSize) || deps.syncPageSize < 1) throw new Error("syncPageSize 必须是正整数");
  const app = Fastify({
    // 前面有 Caddy 反代时打开，按 X-Forwarded-For 取客户端 IP（按 IP 限速要用）
    trustProxy: deps.config.trustProxy,
    logger:
      deps.logger === false && !deps.logStream
        ? false
        : {
            level: deps.logStream ? "info" : deps.config.logLevel,
            ...(deps.logStream ? { stream: deps.logStream } : {}),
            // 令牌、口令、开通码不进日志
            redact: {
              paths: ["req.headers.authorization", "req.headers.cookie", "body.password", "body.code", "body.token"],
              remove: true,
            },
          },
    bodyLimit: BODY_LIMIT,
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
    if (status === 413) {
      reply.code(413).send({ code: "invalid", message: `请求体超过 ${BODY_LIMIT} 字节，拆成几批再发` });
      return;
    }
    reply.code(status).send(status === 400 ? { code: "invalid" } : status === 404 ? { code: "not_found" } : { code: "unavailable" });
  });

  // guard 必须在注册路由之前装上：onRoute 要检查每个路由都在 permissions.json 里
  installGuard(app, new Guard());
  app.register(healthRoutes);
  app.register(configRoutes);
  app.register(authRoutes);
  app.register(deviceRoutes);
  app.register(accountRoutes);
  app.register(syncRoutes);
  return app;
}
