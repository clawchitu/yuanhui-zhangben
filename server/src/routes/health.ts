// GET /healthz：存活检查，查一次数据库。无鉴权，路径不带 /v1（§7、Q13）。
import type { FastifyInstance } from "fastify";

const DB_CHECK_TIMEOUT_MS = 2000;

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get("/healthz", async (req, reply) => {
    try {
      await withTimeout(app.deps.db.pool.query("SELECT 1"), DB_CHECK_TIMEOUT_MS);
      return { ok: true };
    } catch (e) {
      req.log.warn({ err: (e as Error).message }, "healthz：数据库不可用");
      return reply.code(503).send({ code: "unavailable", message: "数据库不可用" });
    }
  });
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const t = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`超时 ${ms}ms`)), ms);
  });
  return Promise.race([p, t]).finally(() => clearTimeout(timer));
}
