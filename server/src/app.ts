import Fastify, { type FastifyInstance } from "fastify";

export function buildApp(): FastifyInstance {
  const app = Fastify({ logger: false });
  app.get("/v1/health", async () => ({ ok: true }));
  return app;
}
// S00 示例 PR：只改 server/
