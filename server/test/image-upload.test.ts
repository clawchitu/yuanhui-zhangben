// 选图与拍照上传（S22d-server ②④⑥）：POST /v1/images/:id/select、PUT /v1/images/:id。
// image_ver +1、rev 取号、sync 拉得到、GET /v1/images?v= 拿到新图、重复提交不升版本、旧对象和本机缓存被删；
// 权限矩阵（收银员、被踢、演示店、跨店、条码不属于该商品、已归档）；1 MB 上限 413、PNG / 伪装文件头 400、EXIF GPS 被去掉；
// 上传途中店被清除：对象被删，删不掉则 objects_cleared_at 被撤回。真实 Postgres。
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import type { BarcodeSource } from "../src/lookup/kuainiao.ts";
import { MemoryObjectStore, isImageKey } from "../src/lookup/oss.ts";
import { purgeStore } from "../src/jobs/account-purge.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeLoginShop, pair } from "./helpers/auth.ts";
import { expectContract, newBarcode, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";

let tdb: TestDb;
let cacheRoot: string;
const pictures = new Map<string, Buffer>();
beforeAll(async () => {
  tdb = await createTestDb();
  cacheRoot = await mkdtemp(path.join(tmpdir(), "yh-s22d-up-"));
});
afterAll(async () => {
  await tdb.drop();
  await rm(cacheRoot, { recursive: true, force: true });
});

const source: BarcodeSource = {
  name: "kuainiao",
  async lookup(b) {
    const urls = [`https://img.example-cdn.com/${b}/0.png`, `https://img.example-cdn.com/${b}/1.png`];
    return { kind: "found", hit: { name: `商品${b}`, imageUrl: urls[0], imageUrls: urls }, raw: {} };
  },
};

function mk(store = new MemoryObjectStore(), dir = path.join(cacheRoot, randomUUID())) {
  const app = buildApp({
    config: testConfig({ productImagesEnabled: true, imageCacheDir: dir }),
    db: tdb,
    logger: false,
    ...(process.env.DEBUG_LOG ? { logStream: { write: (l: string) => (l.includes('"level":50') ? process.stderr.write(l) : true) } } : {}),
    barcodeSource: source,
    objectStore: store,
    fetchImage: async (u) => {
      let b = pictures.get(u);
      if (!b) {
        b = await sharp({ create: { width: 300, height: 200, channels: 3, background: `#${randomUUID().slice(0, 6)}` } }).png().toBuffer();
        pictures.set(u, b);
      }
      return b;
    },
  });
  return { app, store, dir };
}

const jpeg = (c: string, w = 800, h = 600) => sharp({ create: { width: w, height: h, channels: 3, background: c } }).jpeg().toBuffer();

/** 一家店 + 一个商品（带条码）+ 条码的两张候选已转存好 */
async function setup(app: FastifyInstance) {
  const s = await makeLoginShop(tdb);
  const fam = await login(app, s.username);
  const barcode = newBarcode();
  const productId = randomUUID();
  await syncOk(app, fam.token, { epoch: s.epoch, ops: [upsertFull({ productId, barcode })] });
  await app.inject({ method: "GET", url: `/v1/barcode-lookup/${barcode}`, headers: bearer(fam.token) });
  await app.candidates.drain();
  const ids = (await app.inject({ method: "GET", url: `/v1/barcode-lookup/${barcode}/images`, headers: bearer(fam.token) })).json().ids as string[];
  expect(ids).toHaveLength(2);
  return { ...s, token: fam.token, barcode, productId, ids };
}

const product = (storeId: string, id: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const select = (app: FastifyInstance, token: string, productId: string, barcode: string, cid: string) =>
  app.inject({ method: "POST", url: `/v1/images/${productId}/select`, headers: bearer(token), payload: { barcode, candidate_id: cid } });
const put = (app: FastifyInstance, token: string, productId: string, body: Buffer, type = "image/jpeg") =>
  app.inject({ method: "PUT", url: `/v1/images/${productId}`, headers: { ...bearer(token), "content-type": type }, payload: body });

describe("选图与拍照", () => {
  it("select：image_ver +1、rev 取号、image_source=kuainiao、sync 拉得到；GET ?v= 拿到新图；重复提交不升版本；换一张后旧对象和本机缓存被删", async () => {
    const { app, store, dir } = mk();
    const s = await setup(app);
    const rev0 = (await product(s.storeId, s.productId)).rev;
    const r1 = await select(app, s.token, s.productId, s.barcode, s.ids[0]!);
    expect([r1.statusCode, r1.json()]).toEqual([200, { image_ver: 1 }]);
    await expectContract("ImageVer", r1.json());
    const p1 = await product(s.storeId, s.productId);
    expect([p1.image_ver, p1.image_source, Number(p1.rev) > Number(rev0)]).toEqual([1, "kuainiao", true]);
    const pulled = await pullAll(app, s.token, s.epoch);
    expect(pulled.products.get(s.productId)?.image_ver).toBe(1);
    const g1 = await app.inject({ method: "GET", url: `/v1/images/${s.productId}?v=1`, headers: bearer(s.token) });
    expect(g1.headers["cache-control"]).toBe("private, max-age=31536000, immutable");
    const cand0 = await tdb.kysely.selectFrom("catalog_image_candidates").select("object_key").where("barcode", "=", s.barcode).where("cid", "=", s.ids[0]!).executeTakeFirstOrThrow();
    expect(g1.rawPayload.equals(store.objects.get(cand0.object_key!)!.body)).toBe(true);
    // 重复提交：不升版本、rev 不变
    expect((await select(app, s.token, s.productId, s.barcode, s.ids[0]!)).json()).toEqual({ image_ver: 1 });
    expect((await product(s.storeId, s.productId)).rev).toBe(p1.rev);
    // 换第二张：旧对象、旧缓存文件都没了；候选本身还在
    const oldFile = path.join(dir, ...p1.image_key!.split("/"));
    await stat(oldFile);
    expect((await select(app, s.token, s.productId, s.barcode, s.ids[1]!)).json()).toEqual({ image_ver: 2 });
    expect(store.objects.has(p1.image_key!)).toBe(false);
    await expect(stat(oldFile)).rejects.toThrow(/ENOENT/);
    expect(store.objects.has(cand0.object_key!)).toBe(true);
    await app.close();
  });

  it("PUT：image_ver +1、image_source=upload、存 200px；同一张再传不升版本；GET ?v= 拿到新图、旧对象被删", async () => {
    const { app, store } = mk();
    const s = await setup(app);
    await select(app, s.token, s.productId, s.barcode, s.ids[0]!);
    const old = (await product(s.storeId, s.productId)).image_key!;
    const photo = await jpeg("#2a6");
    const r = await put(app, s.token, s.productId, photo);
    expect([r.statusCode, r.json()]).toEqual([200, { image_ver: 2 }]);
    const p = await product(s.storeId, s.productId);
    expect([p.image_ver, p.image_source, isImageKey(p.image_key!)]).toEqual([2, "upload", true]);
    expect(store.objects.has(old)).toBe(false);
    const m = await sharp(store.objects.get(p.image_key!)!.body).metadata();
    expect([m.format, m.width, m.height]).toEqual(["jpeg", 200, 150]);
    expect((await put(app, s.token, s.productId, photo)).json()).toEqual({ image_ver: 2 });
    const g = await app.inject({ method: "GET", url: `/v1/images/${s.productId}?v=2`, headers: bearer(s.token) });
    expect(g.rawPayload.equals(store.objects.get(p.image_key!)!.body)).toBe(true);
    await app.close();
  });

  it("同内容并发（PR #42 必须改 1）：两路同时 PUT 同一张、两路同时 select 同一张，都 200 同一个 image_ver，对象还在，GET 200", async () => {
    const { app, store } = mk();
    const s = await setup(app);
    const photo = await jpeg("#5a5");
    const [a, b] = await Promise.all([put(app, s.token, s.productId, photo), put(app, s.token, s.productId, photo)]);
    expect([a.statusCode, b.statusCode, a.json(), b.json()]).toEqual([200, 200, { image_ver: 1 }, { image_ver: 1 }]);
    const p1 = await product(s.storeId, s.productId);
    expect(store.objects.has(p1.image_key!)).toBe(true);
    expect((await app.inject({ method: "GET", url: `/v1/images/${s.productId}?v=1`, headers: bearer(s.token) })).statusCode).toBe(200);
    const [c, d] = await Promise.all([select(app, s.token, s.productId, s.barcode, s.ids[0]!), select(app, s.token, s.productId, s.barcode, s.ids[0]!)]);
    expect([c.statusCode, d.statusCode, c.json(), d.json()]).toEqual([200, 200, { image_ver: 2 }, { image_ver: 2 }]);
    const p2 = await product(s.storeId, s.productId);
    expect(store.objects.has(p2.image_key!)).toBe(true);
    expect(store.objects.has(p1.image_key!)).toBe(false); // 换图后旧的照删
    expect((await app.inject({ method: "GET", url: `/v1/images/${s.productId}?v=2`, headers: bearer(s.token) })).statusCode).toBe(200);
    await app.close();
  });

  it("超 1 MB 的 413 文案不说「拆批」（PR #42 Fable 可选 6）", async () => {
    const { app } = mk();
    const s = await setup(app);
    const r = await put(app, s.token, s.productId, Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(1024 * 1024)]));
    expect([r.statusCode, r.json().code]).toEqual([413, "invalid"]);
    expect(r.json().message).not.toContain("拆");
    await app.close();
  });

  it("PUT 超 1 MB → 413；PNG、伪装成 JPEG 文件头的垃圾 → 400 invalid；带 EXIF GPS 的照片输出不含任何元数据", async () => {
    const { app, store } = mk();
    const s = await setup(app);
    const huge = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(1024 * 1024)]);
    expect((await put(app, s.token, s.productId, huge)).statusCode).toBe(413);
    const png = await sharp({ create: { width: 64, height: 64, channels: 3, background: "#123" } }).png().toBuffer();
    for (const [body, type] of [
      [png, "image/jpeg"],
      [png, "image/png"],
      [Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from("not really a jpeg".repeat(20))]), "image/jpeg"],
    ] as const) {
      const r = await put(app, s.token, s.productId, body, type);
      expect([r.statusCode, r.json().code]).toEqual([400, "invalid"]);
    }
    expect((await product(s.storeId, s.productId)).image_ver).toBe(0);
    const gps = await sharp({ create: { width: 640, height: 480, channels: 3, background: "#888" } })
      .jpeg()
      .withExif({ IFD0: { Artist: "secret-owner" }, IFD3: { GPSLatitudeRef: "N", GPSLatitude: "31/1 54/1 0/1", GPSLongitudeRef: "E", GPSLongitude: "120/1 15/1 0/1" } })
      .toBuffer();
    expect((await sharp(gps).metadata()).exif).toBeTruthy();
    expect((await put(app, s.token, s.productId, gps)).json()).toEqual({ image_ver: 1 });
    const out = store.objects.get((await product(s.storeId, s.productId)).image_key!)!.body;
    const m = await sharp(out).metadata();
    expect([m.exif, m.xmp, m.icc, m.iptc]).toEqual([undefined, undefined, undefined, undefined]);
    expect(out.includes(Buffer.from("secret-owner"))).toBe(false);
    expect(out.includes(Buffer.from("GPS"))).toBe(false);
    await app.close();
  });

  it("权限：收银员四个接口 403；被踢 401 revoked；演示店选图、上传 403；跨店商品、条码不属于该商品、已归档、候选没了 404", async () => {
    const { app } = mk();
    const s = await setup(app);
    const photo = await jpeg("#a52");
    const cashier = await pair(app, s.token, "cashier", "小张");
    for (const r of [
      await app.inject({ method: "GET", url: `/v1/barcode-lookup/${s.barcode}/images`, headers: bearer(cashier.token) }),
      await app.inject({ method: "GET", url: `/v1/barcode-lookup/${s.barcode}/images/${s.ids[0]}`, headers: bearer(cashier.token) }),
      await select(app, cashier.token, s.productId, s.barcode, s.ids[0]!),
      await put(app, cashier.token, s.productId, photo),
    ])
      expect([r.statusCode, r.json().code]).toEqual([403, "forbidden"]);
    const victim = await login(app, s.username);
    await app.inject({ method: "POST", url: `/v1/devices/${victim.deviceId}/revoke`, headers: bearer(s.token) });
    for (const r of [await select(app, victim.token, s.productId, s.barcode, s.ids[0]!), await put(app, victim.token, s.productId, photo)])
      expect([r.statusCode, r.json().code]).toEqual([401, "revoked"]);
    // 演示店（审核号）：选图、上传 403；缩图 404
    const demo = await makeLoginShop(tdb, { demo: true });
    const rv = await login(app, demo.username);
    const dp = randomUUID();
    await syncOk(app, rv.token, { epoch: demo.epoch, ops: [upsertFull({ productId: dp, barcode: s.barcode })] });
    for (const r of [await select(app, rv.token, dp, s.barcode, s.ids[0]!), await put(app, rv.token, dp, photo)]) expect([r.statusCode, r.json().code]).toEqual([403, "forbidden"]);
    expect((await app.inject({ method: "GET", url: `/v1/barcode-lookup/${s.barcode}/images/${s.ids[0]}`, headers: bearer(rv.token) })).statusCode).toBe(404);
    // 跨店：别的店拿这个商品 id（自己店里没有）
    const other = await makeLoginShop(tdb);
    const ot = await login(app, other.username);
    for (const r of [await select(app, ot.token, s.productId, s.barcode, s.ids[0]!), await put(app, ot.token, s.productId, photo)]) expect([r.statusCode, r.json().code]).toEqual([404, "not_found"]);
    // 条码不属于这个商品
    const p2 = randomUUID();
    await syncOk(app, s.token, { epoch: s.epoch, ops: [upsertFull({ productId: p2 })] });
    expect((await select(app, s.token, p2, s.barcode, s.ids[0]!)).statusCode).toBe(404);
    // 候选不存在
    expect((await select(app, s.token, s.productId, s.barcode, "f".repeat(16))).statusCode).toBe(404);
    // 已归档
    await tdb.kysely.updateTable("products").set({ archived_at: new Date() }).where("store_id", "=", s.storeId).where("id", "=", s.productId).execute();
    for (const r of [await select(app, s.token, s.productId, s.barcode, s.ids[0]!), await put(app, s.token, s.productId, photo)]) expect([r.statusCode, r.json().code]).toEqual([404, "not_found"]);
    expect((await product(s.storeId, s.productId)).image_ver).toBe(0);
    await app.close();
  });

  it("上传途中店被清除：刚传的对象被删；删不掉时 store_purges.objects_cleared_at 被撤回、记原因", async () => {
    for (const failDelete of [false, true]) {
      const store = new MemoryObjectStore();
      const { app } = mk(store);
      const s = await setup(app);
      // 注销申请已过 7 天（直接改库，设备令牌照旧有效，模拟「验完令牌之后才清除」）
      await tdb.kysely.updateTable("accounts").set({ delete_requested_at: new Date(Date.now() - 8 * 86_400_000) }).where("store_id", "=", s.storeId).execute();
      const realPut = store.put.bind(store);
      let uploaded: string | null = null;
      store.put = async (k, b, t) => {
        await realPut(k, b, t);
        if (k.startsWith(`images/${s.storeId}/`)) {
          uploaded = k;
          expect(await purgeStore(tdb.kysely, s.storeId, new Date(), new MemoryObjectStore())).toBe("purged");
          await tdb.kysely.updateTable("store_purges").set({ swept_at: new Date(), objects_cleared_at: new Date() }).where("store_id", "=", s.storeId).execute();
          if (failDelete)
            store.delete = async () => {
              throw Object.assign(new Error("网络断了"), { code: "ECONNRESET" });
            };
        }
      };
      const r = await put(app, s.token, s.productId, await jpeg("#909"));
      expect(r.statusCode).toBe(404);
      expect(uploaded).not.toBeNull();
      const sp = await tdb.kysely.selectFrom("store_purges").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
      if (failDelete) {
        expect(store.objects.has(uploaded!)).toBe(true);
        expect([sp.objects_cleared_at, sp.last_error]).toEqual([null, "ECONNRESET"]);
      } else {
        expect(store.objects.has(uploaded!)).toBe(false);
        expect(sp.objects_cleared_at).not.toBeNull();
      }
      await app.close();
    }
  });
});


