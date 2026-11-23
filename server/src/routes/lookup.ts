// GET /v1/barcode-lookup/:barcode 与 GET /v1/images/:product_id（§7、§6.1）。
// 权限由 guard 按 permissions.json 判（被踢 401）；店 id 一律取自令牌。
// - 条码查询：每设备每分钟 20 次（超了 429 rate_limited），每店每天调外部 1000 次（超了 429 lookup_quota_exceeded）。
//   收银员只拿到 found、name、spec、has_image（§6.1）；家用 / 审核另有 brand。
//   第三方图片地址不下发给任何人（App 只从自家服务器取图，§0），所以 image_url 不出现。
//   没查到分两种：明确没查到 {found:false}；外部这次没问到 {found:false, retry_later:true}（手机不记，下次再查）。
//   S22d：查到且图片开着、不是演示店时，把条码库的前 6 张图片地址插成候选、唤醒 worker 异步转存（不等下载）。
//   家用 / 审核另有 image_candidates {state: none|pending|ready, ids}；收银员没有这个键（scope 不变）。
//   has_image = image_candidates.state != none（演示店、开关关着永远 false）。
// - 候选（S22d）：GET .../images 只读库、不调快鸟，供轮询（每设备每分钟 60 次）；GET .../images/:cid 出缩图，强缓存一年。
//   开关关着都 404；演示店候选恒为 none、读图 404。收银员由 guard 拒。
// - 商品图：总开关关着一律 404（手机显示首字）；带的 v 等于当前 image_ver 时强缓存一年，否则不缓存。
import type { FastifyInstance } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { SlidingWindowLimiter } from "../auth/ratelimit.ts";
import { LookupQuotaExceeded, urlsOf } from "../lookup/catalog.ts";
import { candidateView, CID_RE, ensureCandidates, type CandidateView } from "../lookup/candidates.ts";
import { ImageCache } from "../lookup/images.ts";
import { cacheFillGuard } from "../jobs/account-purge.ts";
import { isCandidateKey, isImageKey } from "../lookup/oss.ts";
import { sendError } from "./errors.ts";

const NONE: CandidateView = { state: "none", ids: [] };
const BARCODE_PARAM = { type: "string", minLength: 1, maxLength: 64, pattern: "^[0-9A-Za-z._-]+$" } as const;

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export async function lookupRoutes(app: FastifyInstance): Promise<void> {
  const { db, config } = app.deps;
  const catalog = app.catalog;
  const perDevice = new SlidingWindowLimiter(app.deps.rateLimits.barcodeLookup);
  const pollPerDevice = new SlidingWindowLimiter(app.deps.rateLimits.barcodeImages);
  const imagesOn = app.deps.imagesOn;
  const cand = app.candidates.deps;
  // 候选缩图不属于任何店：另一个缓存实例，不做按店的回填复查
  const candidateImages = new ImageCache(config.imageCacheDir, app.deps.objectStore);
  // 回填后复查店还在不在（注销清除之后不在本机缓存里留图，PR #20 Codex 2）
  const images = new ImageCache(config.imageCacheDir, app.deps.objectStore, cacheFillGuard(app.deps.db.kysely, app.log));

  app.get<{ Params: { barcode: string } }>(
    "/v1/barcode-lookup/:barcode",
    {
      schema: {
        params: {
          type: "object",
          required: ["barcode"],
          // 契约 Barcode 是 1–64 个字符；条码只会是可见 ASCII，别的直接 400，不进缓存、不发给外部
          properties: { barcode: BARCODE_PARAM },
        },
      },
    },
    async (req, reply) => {
      const auth = authOf(req);
      const wait = perDevice.hit(auth.device.id, req.receivedAt.getTime());
      if (wait > 0) return sendError(reply, 429, "rate_limited", { retry_after_s: wait });
      let r;
      try {
        r = await catalog.lookup({ id: auth.store.id, isDemo: auth.store.isDemo }, req.params.barcode, req.log);
      } catch (e) {
        if (e instanceof LookupQuotaExceeded) return sendError(reply, 429, "lookup_quota_exceeded", { retry_after_s: e.retryAfterS });
        throw e;
      }
      // 外部没问到（超时、出错、没配 AppCode）：告诉手机别记住，下次扫再查（PR #39 Fable 可选 1）
      if (!r.found || !r.hit) return r.origin === "unavailable" ? { found: false, retry_later: true } : { found: false };
      let view = NONE;
      if (imagesOn && !auth.store.isDemo) {
        // 候选出错不影响查码结果（S22d ⑥-2）
        try {
          if ((await ensureCandidates(cand, req.params.barcode, urlsOf(r.hit))) > 0) app.candidates.wake();
          view = await candidateView(cand, req.params.barcode);
        } catch (e) {
          req.log.warn({ barcode: req.params.barcode, code: (e as { code?: string })?.code ?? "error" }, "商品图候选登记失败");
        }
      }
      const body: Record<string, unknown> = { found: true, name: r.hit.name };
      if (r.hit.spec) body.spec = r.hit.spec;
      body.has_image = view.state !== "none";
      if (auth.identity !== "cashier") {
        if (r.hit.brand) body.brand = r.hit.brand;
        body.image_candidates = view;
      }
      return body;
    },
  );

  app.get<{ Params: { barcode: string } }>(
    "/v1/barcode-lookup/:barcode/images",
    { schema: { params: { type: "object", required: ["barcode"], properties: { barcode: BARCODE_PARAM } } } },
    async (req, reply) => {
      const auth = authOf(req);
      // 开关关着一律 404，不进限速计数（PR #42 Codex 可选 1）
      if (!imagesOn) return sendError(reply, 404, "not_found");
      const wait = pollPerDevice.hit(auth.device.id, req.receivedAt.getTime());
      if (wait > 0) return sendError(reply, 429, "rate_limited", { retry_after_s: wait });
      if (auth.store.isDemo) return NONE;
      return candidateView(cand, req.params.barcode);
    },
  );

  app.get<{ Params: { barcode: string; cid: string } }>(
    "/v1/barcode-lookup/:barcode/images/:cid",
    {
      schema: {
        params: { type: "object", required: ["barcode", "cid"], properties: { barcode: BARCODE_PARAM, cid: { type: "string", pattern: CID_RE.source } } },
      },
    },
    async (req, reply) => {
      const auth = authOf(req);
      if (!imagesOn || auth.store.isDemo) return sendError(reply, 404, "not_found");
      const row = await db.kysely
        .selectFrom("catalog_image_candidates")
        .select("object_key")
        .where("barcode", "=", req.params.barcode)
        .where("cid", "=", req.params.cid)
        .where("state", "=", "ready")
        .executeTakeFirst();
      if (!row?.object_key || !isCandidateKey(row.object_key)) return sendError(reply, 404, "not_found");
      const body = await candidateImages.get(row.object_key);
      if (!body) return sendError(reply, 404, "not_found");
      reply
        .header("content-type", "image/jpeg")
        .header("x-content-type-options", "nosniff")
        .header("content-security-policy", "default-src 'none'")
        .header("cache-control", "private, max-age=31536000, immutable");
      return reply.send(body);
    },
  );

  app.get<{ Params: { product_id: string }; Querystring: { v?: number } }>(
    "/v1/images/:product_id",
    {
      schema: {
        params: { type: "object", required: ["product_id"], properties: { product_id: { type: "string", pattern: UUID_RE.source } } },
        querystring: { type: "object", additionalProperties: false, properties: { v: { type: "integer", minimum: 0, maximum: 2147483647 } } },
      },
    },
    async (req, reply) => {
      const auth = authOf(req);
      if (!imagesOn) return sendError(reply, 404, "not_found");
      const p = await db.kysely
        .selectFrom("products")
        .select(["image_key", "image_ver"])
        .where("store_id", "=", auth.store.id)
        .where("id", "=", req.params.product_id.toLowerCase())
        .executeTakeFirst();
      // 键是服务器自己写的；格式不对（被改过的库）也不拿去拼路径
      if (!p || p.image_ver === 0 || !p.image_key || !isImageKey(p.image_key)) return sendError(reply, 404, "not_found");
      const body = await images.get(p.image_key);
      if (!body) return sendError(reply, 404, "not_found");
      const exact = req.query.v === p.image_ver;
      reply
        .header("content-type", "image/jpeg")
        .header("x-content-type-options", "nosniff")
        .header("content-security-policy", "default-src 'none'")
        .header("etag", `"${p.image_ver}"`)
        .header("cache-control", exact ? "private, max-age=31536000, immutable" : "private, no-cache");
      return reply.send(body);
    },
  );
}
