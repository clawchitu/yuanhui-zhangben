// GET /healthz：存活检查，查一次数据库。无鉴权，路径不带 /v1（§7、Q13）。
// 探活不能把连接池拖死（Codex 审核第 6 条）：
//   - 服务端：SET LOCAL statement_timeout，查询本身最多跑 HEALTH_STATEMENT_MS；
//   - 客户端：query_timeout 兜底（连接建立了但对方不回话），超时后把这条连接销毁而不是放回池里；
//   - 整体：HTTP 最多等 HEALTH_DEADLINE_MS 就回 503（取连接本身卡住时也一样）。
import type { FastifyInstance } from "fastify";
import type pg from "pg";

export const HEALTH_STATEMENT_MS = 1500;
export const HEALTH_DEADLINE_MS = 2000;
// 查一张真实的表：库在、迁移跑过、没有被长时间锁住，才算健康
const HEALTH_SQL = `SET LOCAL statement_timeout = ${HEALTH_STATEMENT_MS}; SELECT 1 FROM stores LIMIT 1`;

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get("/healthz", async (req, reply) => {
    try {
      await withTimeout(probe(app), HEALTH_DEADLINE_MS);
      return { ok: true };
    } catch (e) {
      req.log.warn({ err: (e as Error).message }, "healthz：数据库不可用");
      return reply.code(503).send({ code: "unavailable", message: "数据库不可用" });
    }
  });
}

async function probe(app: FastifyInstance): Promise<void> {
  const client = await app.deps.db.pool.connect();
  try {
    // query_timeout 是 pg 支持、但 @types/pg 没写进 QueryConfig 的选项
    const q: pg.QueryConfig & { query_timeout: number } = { text: HEALTH_SQL, query_timeout: HEALTH_DEADLINE_MS };
    await client.query(q);
  } catch (e) {
    client.release(true); // 销毁：这条连接的状态不可信，不放回池里
    throw e;
  }
  client.release();
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const t = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`超时 ${ms}ms`)), ms);
  });
  p.catch(() => {}); // 超时之后底层才失败的，不要变成未处理的 rejection
  return Promise.race([p, t]).finally(() => clearTimeout(timer));
}
