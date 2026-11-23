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
      // T11 / S22d：false 时手机不显示也不请求商品图、清本地图片缓存，选图和拍照入口不出现（总开关开且对象存储配了才是 true）
      product_images_enabled: app.deps.imagesOn,
      // S21：只在配了 API_BASE 时返回（loadConfig 已按白名单校验过）
      ...(c.apiBase ? { api_base: c.apiBase } : {}),
    };
  });
}
