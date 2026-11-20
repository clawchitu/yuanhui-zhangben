// GET /v1/config：客户端配置，无鉴权（§7；契约 components/schemas/Config）。
import type { FastifyInstance } from "fastify";

export async function configRoutes(app: FastifyInstance): Promise<void> {
  app.get("/v1/config", async () => {
    const c = app.deps.config;
    return {
      min_build: c.minBuild,
      demo_login_enabled: c.demoLoginEnabled,
      privacy_url: c.privacyUrl,
      support_url: c.supportUrl,
    };
  });
}
