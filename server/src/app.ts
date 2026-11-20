// Fastify 应用。只组装路由和公共错误格式，不在这里连数据库（由调用方传入，测试里每个文件一个独立 schema）。
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.ts";
import type { Db } from "./db.ts";
import { healthRoutes } from "./routes/health.ts";
import { configRoutes } from "./routes/config.ts";

export interface AppDeps {
  config: Config;
  db: Db;
  /** 测试里传 false 关日志 */
  logger?: boolean;
}

declare module "fastify" {
  interface FastifyInstance {
    deps: AppDeps;
  }
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
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

  app.register(healthRoutes);
  app.register(configRoutes);
  return app;
}
