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
      // S21：只在配了 API_BASE 时返回（loadConfig 已按白名单校验过）
      ...(c.apiBase ? { api_base: c.apiBase } : {}),
    };
  });
}
