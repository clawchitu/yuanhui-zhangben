// 换商品图（S22d-server）：POST /v1/images/:product_id/select（选候选图）与 PUT /v1/images/:product_id（拍照上传）。
// 权限由 guard 按 permissions.json 判：家用、审核能；收银员、被踢设备拒。店 id 一律取自令牌。
// - 图片开关关着（或没配对象存储）：404。演示店：403（演示店公用，不放用户图，也不用第三方图）。
// - select：条码必须在本店挂在这个商品上、候选是 ready；把候选缩图原样复制成 images/<店>/<商品>/<ver>-<哈希>.jpg。
// - PUT：Content-Type image/jpeg 裸体，路由级上限 1 MB（超了 413）；只收 JPEG（按文件头认），过 makeThumbnail（按 EXIF 转正、去掉全部元数据）。
// - 写回都在 withStoreLock 里：image_ver+1、nextRev()、image_source 记 kuainiao / upload，返回 {image_ver}。
//   幂等：内容哈希和当前图相同就不升版本，直接回当前版本。商品不存在或已归档 404。
// - 和注销清除的协调照 image-fetch：上传前查 storeGone，锁内复查，店没了走 dropLateObject。
// - 换图后尽力删旧对象和本机缓存文件，删不掉记日志 image_discard_failed（活店换图删不掉的旧对象暂无清扫，§14 跨段待办）。
import { rm } from "node:fs/promises";
import type { FastifyBaseLogger, FastifyInstance } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { ImageRejected, makeThumbnail, sha256, sniffFormat } from "../lookup/images.ts";
import { CID_RE } from "../lookup/candidates.ts";
import { imageKey, isCandidateKey, isImageKey, safeJoin, type ObjectStore } from "../lookup/oss.ts";
import { dropLateObject, storeGone } from "../jobs/account-purge.ts";
import { StoreBusy, withStoreLock } from "../sync/lock.ts";
import { sendError } from "./errors.ts";

/** 拍照上传的请求体上限（手机端压到长边 ≤ 1024px、≤ 400 KB；服务器硬上限 1 MB） */
export const UPLOAD_LIMIT = 1024 * 1024;
/** 写回时商品的 image_ver 被别人改了（同时两路换图）：重来几次 */
const MAX_TRIES = 3;

const UUID = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
const PARAMS = { type: "object", required: ["product_id"], properties: { product_id: { type: "string", pattern: UUID } } } as const;

type Promoted = { kind: "ok"; imageVer: number } | { kind: "not_found" } | { kind: "busy" };

export async function productImageRoutes(app: FastifyInstance): Promise<void> {
  const { db, config } = app.deps;
  const kysely = db.kysely;
  const imagesOn = app.deps.imagesOn;

  // 只在这个插件里认图片裸体（不影响别的路由）。类型不是 JPEG 的也先收下来，按文件头判、回 400 invalid
  app.addContentTypeParser(/^image\/.*/, { parseAs: "buffer", bodyLimit: UPLOAD_LIMIT }, (_req, body, done) => done(null, body));
  app.addContentTypeParser("application/octet-stream", { parseAs: "buffer", bodyLimit: UPLOAD_LIMIT }, (_req, body, done) => done(null, body));

  /** 把一张已经是 200px JPEG 的缩图设成商品图 */
  async function promote(storeId: string, productId: string, thumb: Buffer, source: "kuainiao" | "upload", log: FastifyBaseLogger): Promise<Promoted> {
    const store = app.deps.objectStore as ObjectStore;
    const hash = sha256(thumb);
    for (let i = 0; i < MAX_TRIES; i++) {
      const cur = await kysely
        .selectFrom("products")
        .select(["image_ver", "image_key", "archived_at"])
        .where("store_id", "=", storeId)
        .where("id", "=", productId)
        .executeTakeFirst();
      if (!cur || cur.archived_at) return { kind: "not_found" };
      // 幂等：内容和当前图一样（重发、重复选同一张）就不升版本
      if (cur.image_ver > 0 && cur.image_key && isImageKey(cur.image_key) && cur.image_key.endsWith(`-${hash.slice(0, 16)}.jpg`)) return { kind: "ok", imageVer: cur.image_ver };
      if (await storeGone(kysely, storeId)) return { kind: "not_found" };
      const ver = cur.image_ver + 1;
      const key = imageKey(storeId, productId, ver, hash);
      try {
        await store.put(key, thumb, "image/jpeg");
      } catch (e) {
        // 上传报错时对象可能其实写进去了：店已被清除就顺手删（删不掉交给清除的复扫）
        if (await storeGone(kysely, storeId).catch(() => false)) await dropLateObject(kysely, storeId, () => store.delete(key), log);
        throw e;
      }
      let out: "gone" | { miss: "missing" | "changed"; current: string | null } | { old: string | null };
      try {
        out = await withStoreLock(kysely, storeId, async (tx) => {
          if (await storeGone(tx.trx, storeId)) return "gone" as const;
          const now = await tx.trx
            .selectFrom("products")
            .select(["image_ver", "image_key", "archived_at"])
            .where("store_id", "=", tx.storeId)
            .where("id", "=", productId)
            .executeTakeFirst();
          if (!now || now.archived_at) return { miss: "missing" as const, current: now?.image_key ?? null };
          if (now.image_ver !== cur.image_ver) return { miss: "changed" as const, current: now.image_key };
          await tx.trx
            .updateTable("products")
            .set({ image_key: key, image_source: source, image_ver: ver, rev: await tx.nextRev(), updated_at: app.deps.clock() })
            .where("store_id", "=", tx.storeId)
            .where("id", "=", productId)
            .execute();
          return { old: now.image_key };
        });
      } catch (e) {
        // 拿店铺锁时店已经没了（锁那边报店不存在）等：店被清除就删掉刚传的，按商品不存在回 404
        if (await storeGone(kysely, storeId).catch(() => false)) {
          await dropLateObject(kysely, storeId, () => store.delete(key), log);
          return { kind: "not_found" };
        }
        // 没写回（排队满了、库出错）：刚传的对象只在确认没被引用时删（PR #42 Fable 可选 4）
        await discardIfUnreferenced(store, key, storeId, productId, log);
        if (e instanceof StoreBusy) return { kind: "busy" };
        throw e;
      }
      if (out === "gone") {
        await dropLateObject(kysely, storeId, () => store.delete(key), log);
        return { kind: "not_found" };
      }
      if ("miss" in out) {
        // 没写回。同内容的另一路先提交了同一个键（PR #42 必须改 1）：这个键正被商品引用，绝不删，按成功处理（下一轮命中幂等）
        if (out.current !== key) await discardIfUnreferenced(store, key, storeId, productId, log);
        if (out.miss === "missing") return { kind: "not_found" };
        continue;
      }
      if (out.old && out.old !== key && isImageKey(out.old)) await discardIfUnreferenced(store, out.old, storeId, productId, log);
      log.info({ store_id: storeId, product_id: productId, image_ver: ver, source }, "商品图已更换");
      return { kind: "ok", imageVer: ver };
    }
    return { kind: "busy" };
  }

  /**
   * 尽力删一个商品图对象和它在本机缓存里的文件：只在提交之后、再查一次确认没有任何商品引用这个键时才删（PR #42 必须改 1）。
   * 键里带着 image_ver：版本一旦越过它，就再没有请求能把这个键写进商品（锁内要求读到的版本没变），所以「查过没引用」之后不会再被引用
   */
  async function discardIfUnreferenced(store: ObjectStore, key: string, storeId: string, productId: string, log: FastifyBaseLogger) {
    try {
      const ref = await kysely.selectFrom("products").select("id").where("image_key", "=", key).executeTakeFirst();
      if (ref) return;
      await store.delete(key);
      await rm(safeJoin(config.imageCacheDir, key), { force: true });
    } catch (e) {
      log.warn({ store_id: storeId, product_id: productId, code: (e as { code?: string })?.code ?? "error" }, "image_discard_failed");
    }
  }

  function reply(r: Promoted, rep: Parameters<typeof sendError>[0]) {
    if (r.kind === "ok") return { image_ver: r.imageVer };
    if (r.kind === "busy") return sendError(rep, 503, "unavailable", { retry_after_s: 1 });
    return sendError(rep, 404, "not_found");
  }

  app.post<{ Params: { product_id: string }; Body: { barcode: string; candidate_id: string } }>(
    "/v1/images/:product_id/select",
    {
      schema: {
        params: PARAMS,
        body: {
          type: "object",
          additionalProperties: false,
          required: ["barcode", "candidate_id"],
          properties: {
            barcode: { type: "string", minLength: 1, maxLength: 64, pattern: "^[0-9A-Za-z._-]+$" },
            candidate_id: { type: "string", pattern: CID_RE.source },
          },
        },
      },
    },
    async (req, rep) => {
      const auth = authOf(req);
      if (!imagesOn) return sendError(rep, 404, "not_found");
      if (auth.store.isDemo) return sendError(rep, 403, "forbidden");
      const productId = req.params.product_id.toLowerCase();
      const { barcode, candidate_id: cid } = req.body;
      const link = await kysely
        .selectFrom("product_barcodes")
        .select("product_id")
        .where("store_id", "=", auth.store.id)
        .where("barcode", "=", barcode)
        .where("deleted_at", "is", null)
        .executeTakeFirst();
      if (!link || link.product_id !== productId) return sendError(rep, 404, "not_found");
      const c = await kysely
        .selectFrom("catalog_image_candidates")
        .select("object_key")
        .where("barcode", "=", barcode)
        .where("cid", "=", cid)
        .where("state", "=", "ready")
        .executeTakeFirst();
      if (!c?.object_key || !isCandidateKey(c.object_key)) return sendError(rep, 404, "not_found");
      const bytes = await (app.deps.objectStore as ObjectStore).get(c.object_key);
      if (!bytes) return sendError(rep, 404, "not_found");
      return reply(await promote(auth.store.id, productId, bytes, "kuainiao", req.log), rep);
    },
  );

  app.put<{ Params: { product_id: string }; Body: unknown }>(
    "/v1/images/:product_id",
    { bodyLimit: UPLOAD_LIMIT, schema: { params: PARAMS } },
    async (req, rep) => {
      const auth = authOf(req);
      if (!imagesOn) return sendError(rep, 404, "not_found");
      if (auth.store.isDemo) return sendError(rep, 403, "forbidden");
      const body = req.body;
      if (!Buffer.isBuffer(body) || sniffFormat(body) !== "jpeg") return sendError(rep, 400, "invalid", { message: "只收 JPEG" });
      let thumb: Buffer;
      try {
        thumb = await makeThumbnail(body);
      } catch (e) {
        if (e instanceof ImageRejected) return sendError(rep, 400, "invalid", { message: "图片解不开或尺寸不对" });
        throw e;
      }
      return reply(await promote(auth.store.id, req.params.product_id.toLowerCase(), thumb, "upload", req.log), rep);
    },
  );
}
