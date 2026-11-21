// 商品图任务与 GET /v1/images/:product_id（S08）：下载 → 长边 200px JPEG → 写对象存储 → 在店铺锁里取号写回 image_key / image_ver；
// 失败不影响商品、按次数重试、坏图直接放弃；两轮同时跑不重复抓；开关关着什么都不做、接口一律 404；演示店不抓；
// 读图走磁盘缓存、缺了回源；防路径穿越；跨店拿不到；收银员能看。真实 Postgres。
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import { writeCache } from "../src/lookup/catalog.ts";
import { ImageRejected } from "../src/lookup/images.ts";
import { MemoryObjectStore, type ObjectStore } from "../src/lookup/oss.ts";
import { claimDue, enqueueImageJobs, runImageJobs, type ImageJobDeps } from "../src/jobs/image-fetch.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { TestClock, bearer, login, makeLoginShop, pair } from "./helpers/auth.ts";
import { newBarcode, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
let cacheRoot: string;
let picture: Buffer;
beforeAll(async () => {
  tdb = await createTestDb();
  cacheRoot = await mkdtemp(path.join(tmpdir(), "yh-s08-cache-"));
  picture = await sharp({ create: { width: 800, height: 600, channels: 3, background: "#c33" } }).png().toBuffer();
});
afterAll(async () => {
  await tdb.drop();
  await rm(cacheRoot, { recursive: true, force: true });
});

function mkApp(o: { config?: Partial<Config>; store?: ObjectStore | null; clock?: TestClock } = {}) {
  return buildApp({
    config: testConfig({ productImagesEnabled: true, imageCacheDir: path.join(cacheRoot, randomUUID()), ...o.config }),
    db: tdb,
    logger: false,
    clock: o.clock?.now,
    barcodeSource: null,
    objectStore: o.store === undefined ? new MemoryObjectStore() : o.store,
  });
}

/** 一家店 + 一个带条码的商品，条码缓存里有图片地址 */
async function productWithImage(app: FastifyInstance, o: { demo?: boolean; imageUrl?: string | null } = {}) {
  const s = await makeLoginShop(tdb, { demo: o.demo });
  const fam = await login(app, s.username);
  const barcode = newBarcode();
  const productId = randomUUID();
  await syncOk(app, fam.token, { epoch: s.epoch, ops: [upsertFull({ productId, barcode })] });
  if (o.imageUrl !== null) await writeCache(tdb.kysely, barcode, "kuainiao", { name: "x", imageUrl: o.imageUrl ?? `https://img.example-cdn.com/${barcode}.jpg` }, {}, new Date());
  return { ...s, token: fam.token, productId, barcode };
}

const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const job = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("image_jobs").selectAll().where("store_id", "=", storeId).where("product_id", "=", id).executeTakeFirst();

function deps(o: Partial<ImageJobDeps> & { store: ObjectStore | null }): ImageJobDeps & { fetched: string[] } {
  const fetched: string[] = [];
  return {
    db: tdb.kysely,
    enabled: true,
    clock: () => new Date(),
    fetchImage: async (u) => {
      fetched.push(u);
      return picture;
    },
    ...o,
    fetched,
  };
}

/** 只处理这家店的任务：别的测试留下的任务不干扰断言 */
async function runFor(d: ImageJobDeps) {
  await enqueueImageJobs(d);
  return runImageJobs(d, 1000);
}

describe("图片任务", () => {
  it("下载 → 长边 200px JPEG → 写对象存储 → 店铺锁内取号写回 image_key、image_ver+1、rev；同步拉到 image_ver=1", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    const store = new MemoryObjectStore();
    const d = deps({ store });
    const before = await product(p.storeId, p.productId);
    expect(before.image_ver).toBe(0);
    await runFor(d);
    expect(d.fetched).toContain(`https://img.example-cdn.com/${p.barcode}.jpg`);
    const after = await product(p.storeId, p.productId);
    expect(after.image_ver).toBe(1);
    expect(after.image_source).toBe("kuainiao");
    expect(after.image_key).toMatch(new RegExp(`^images/${p.storeId}/${p.productId}/1-[0-9a-f]{16}\\.jpg$`));
    expect(Number(after.rev)).toBeGreaterThan(Number(before.rev));
    const st = await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", p.storeId).executeTakeFirstOrThrow();
    expect(Number(st.rev)).toBe(Number(after.rev)); // 用的是统一取号函数，号就是店的最新号
    const obj = store.objects.get(after.image_key!)!;
    expect(obj.contentType).toBe("image/jpeg");
    const m = await sharp(obj.body).metadata();
    expect([m.format, m.width, m.height]).toEqual(["jpeg", 200, 150]);
    expect((await job(p.storeId, p.productId))?.done_at).toBeTruthy();
    // 手机从 before.rev 往后拉，能拿到 image_ver=1
    const pulled = await syncOk(app, p.token, { epoch: p.epoch, cursors: { catalog: Number(before.rev), ledger: 0 } });
    const got = pulled.changes.products.find((x: { id: string }) => x.id === p.productId);
    expect(got.image_ver).toBe(1);
    // 已经有图的不再进队列、不再抓
    const again = deps({ store });
    await runFor(again);
    expect(again.fetched).not.toContain(`https://img.example-cdn.com/${p.barcode}.jpg`);
    await app.close();
  });

  it("下载失败不影响商品：商品照常在、image_ver 仍是 0；隔一段时间重试，满 3 次不再试", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    let now = Date.now();
    let tries = 0;
    const d = deps({
      store: new MemoryObjectStore(),
      clock: () => new Date(now),
      fetchImage: async (u) => {
        if (u.includes(p.barcode)) tries++;
        throw new ImageRejected("timeout", "下载超时");
      },
    });
    await runFor(d);
    expect(tries).toBe(1);
    let j = await job(p.storeId, p.productId);
    expect([j?.attempts, j?.last_error, j?.done_at]).toEqual([1, "timeout", null]);
    const prod = await product(p.storeId, p.productId);
    expect([prod.name, prod.image_ver, prod.image_key]).toEqual(["可口可乐 330ml", 0, null]);
    await runFor(d); // 还没到重试时间
    expect(tries).toBe(1);
    now += 5 * 60_000 + 1000;
    await runFor(d);
    now += 60 * 60_000 + 1000;
    await runFor(d);
    expect(tries).toBe(3);
    now += 24 * 3600_000;
    await runFor(d);
    expect(tries).toBe(3);
    j = await job(p.storeId, p.productId);
    expect(j?.attempts).toBe(3);
    // 后续同步、记账照常
    await syncOk(app, p.token, { epoch: p.epoch, ops: [upsertQuick({ name: "后面登记的" })] });
    await app.close();
  });

  it("坏图（内网地址、太大、格式不对）不重试，直接放弃；last_error 只记原因代码", async () => {
    const app = mkApp();
    for (const why of ["private_address", "too_large", "bad_format"]) {
      const p = await productWithImage(app);
      const d = deps({
        store: new MemoryObjectStore(),
        fetchImage: async (u) => {
          if (u.includes(p.barcode)) throw new ImageRejected(why, `不行 ${u}`);
          return picture;
        },
      });
      await runFor(d);
      const j = await job(p.storeId, p.productId);
      expect([j?.attempts, j?.last_error]).toEqual([3, why]);
      expect((await product(p.storeId, p.productId)).image_ver).toBe(0);
    }
    // 下载回来的不是图：缩图那一步拒
    const p = await productWithImage(app);
    await runFor(deps({ store: new MemoryObjectStore(), fetchImage: async () => Buffer.from("<svg xmlns='http://www.w3.org/2000/svg'/>") }));
    expect((await job(p.storeId, p.productId))?.last_error).toBe("bad_format");
    await app.close();
  });

  it("写对象存储失败：商品不变，按临时失败重试", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    const broken: ObjectStore = {
      put: async () => {
        throw new Error("oss down");
      },
      get: async () => null,
    };
    await runFor(deps({ store: broken }));
    const j = await job(p.storeId, p.productId);
    expect([j?.attempts, j?.last_error, j?.done_at]).toEqual([1, "error", null]);
    expect((await product(p.storeId, p.productId)).image_ver).toBe(0);
    await app.close();
  });

  it("并发去重：两轮同时跑、同一批任务只领一次，只抓一次，image_ver 只 +1", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    const store = new MemoryObjectStore();
    let n = 0;
    const slow = async (u: string) => {
      if (u.includes(p.barcode)) n++;
      await new Promise((r) => setTimeout(r, 50));
      return picture;
    };
    const d1 = deps({ store, fetchImage: slow });
    const d2 = deps({ store, fetchImage: slow });
    await Promise.all([enqueueImageJobs(d1), enqueueImageJobs(d2)]);
    const rows = await tdb.kysely.selectFrom("image_jobs").select("product_id").where("store_id", "=", p.storeId).execute();
    expect(rows).toHaveLength(1);
    await Promise.all([runImageJobs(d1, 1000), runImageJobs(d2, 1000), runImageJobs(d1, 1000)]);
    expect(n).toBe(1);
    expect((await product(p.storeId, p.productId)).image_ver).toBe(1);
    await app.close();
  });

  it("一次领一个（可控时钟，每张 18 秒）：做到第 306 秒时，另一个进程领不到这个进程手里的任务（PR #19 审核）", async () => {
    const app = mkApp();
    const ps = [];
    for (let i = 0; i < 20; i++) ps.push(await productWithImage(app));
    const byUrl = new Map<string, string>(ps.map((x) => [`https://img.example-cdn.com/${x.barcode}.jpg`, x.productId]));
    // 时钟放在很早以前：别的测试留下的任务都还没到期，只有这 20 个能领
    const clock = new TestClock(Date.parse("2001-01-01T00:00:00Z"));
    const t0 = clock.t;
    const mine = new Set<string>(ps.map((x) => x.productId));
    const processedByA: string[] = [];
    let claimedByB: string[] | null = null;
    const store = new MemoryObjectStore();
    const b = deps({ store, clock: clock.now });
    const a = deps({
      store,
      clock: clock.now,
      fetchImage: async (u) => {
        processedByA.push(byUrl.get(u)!);
        clock.advance(18_000); // 下载 8 秒 + 上传 10 秒
        if (claimedByB === null && clock.t - t0 >= 306_000) {
          claimedByB = (await claimDue(b, 1000)).map((x) => x.product_id).filter((id) => mine.has(id));
        }
        return picture;
      },
    });
    expect(await enqueueImageJobs(a, 1000)).toBeGreaterThanOrEqual(20);
    await runImageJobs(a, 20);
    expect(claimedByB).not.toBeNull();
    // B 领到的只能是 A 还没领的；A 手里的（正在做的、排着的）一个都不能被 B 领走
    expect(claimedByB!.filter((id) => processedByA.includes(id))).toEqual([]);
    expect(new Set([...processedByA, ...claimedByB!])).toEqual(mine);
    await app.close();
  });

  it("领任务是原子的：同时领，任务不会被两边都领到", async () => {
    const app = mkApp();
    const ps = [];
    for (let i = 0; i < 6; i++) ps.push(await productWithImage(app));
    const d = deps({ store: new MemoryObjectStore() });
    await enqueueImageJobs(d, 1000);
    const [a, b, c] = await Promise.all([claimDue(d, 1000), claimDue(d, 1000), claimDue(d, 1000)]);
    const mine = new Set<string>(ps.map((x) => x.productId));
    const got = [...a, ...b, ...c].filter((x) => mine.has(x.product_id)).map((x) => x.product_id);
    expect(got.sort()).toEqual([...mine].sort());
    await app.close();
  });

  it("抓图期间商品已经有了图（别处写了 image_ver）→ 不覆盖", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    const d = deps({
      store: new MemoryObjectStore(),
      fetchImage: async () => {
        await tdb.kysely.updateTable("products").set({ image_ver: 5, image_key: null }).where("store_id", "=", p.storeId).where("id", "=", p.productId).execute();
        return picture;
      },
    });
    await runFor(d);
    expect((await product(p.storeId, p.productId)).image_ver).toBe(5);
    await app.close();
  });

  it("开关关着 / 没配对象存储：不进队列、不抓；演示店的商品不抓第三方图；条码缓存没有图的不进队列", async () => {
    const app = mkApp();
    const p = await productWithImage(app);
    const off = deps({ store: new MemoryObjectStore(), enabled: false });
    expect(await enqueueImageJobs(off)).toBe(0);
    expect((await runImageJobs(off)).done).toBe(0);
    expect(await enqueueImageJobs(deps({ store: null }))).toBe(0);
    expect(await job(p.storeId, p.productId)).toBeUndefined();

    const demo = await productWithImage(app, { demo: true });
    const noImg = await productWithImage(app, { imageUrl: null });
    await runFor(deps({ store: new MemoryObjectStore() }));
    expect(await job(demo.storeId, demo.productId)).toBeUndefined();
    expect((await product(demo.storeId, demo.productId)).image_ver).toBe(0);
    expect(await job(noImg.storeId, noImg.productId)).toBeUndefined();
    await app.close();
  });
});

describe("GET /v1/images/:product_id", () => {
  async function withImage() {
    const store = new MemoryObjectStore();
    const app = mkApp({ store });
    const p = await productWithImage(app);
    await runFor(deps({ store }));
    const prod = await product(p.storeId, p.productId);
    return { app, store, p, prod };
  }

  it("带对的 v 强缓存；不带或不对的不缓存；收银员也能看；内容是 JPEG", async () => {
    const { app, p } = await withImage();
    const r = await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(p.token) });
    expect(r.statusCode).toBe(200);
    expect(r.headers["content-type"]).toBe("image/jpeg");
    expect(r.headers["cache-control"]).toBe("private, max-age=31536000, immutable");
    expect(r.headers["x-content-type-options"]).toBe("nosniff");
    expect((await sharp(r.rawPayload).metadata()).format).toBe("jpeg");
    const r0 = await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=0`, headers: bearer(p.token) });
    expect(r0.headers["cache-control"]).toBe("private, no-cache");
    const cashier = await pair(app, p.token, "cashier", "收银");
    const rc = await app.inject({ method: "GET", url: `/v1/images/${p.productId}`, headers: bearer(cashier.token) });
    expect(rc.statusCode).toBe(200);
    await app.close();
  });

  it("读过一次落到本机磁盘：对象存储里没了也照样出图", async () => {
    const { app, store, p } = await withImage();
    expect((await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(p.token) })).statusCode).toBe(200);
    store.objects.clear();
    expect((await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(p.token) })).statusCode).toBe(200);
    await app.close();
  });

  it("开关关掉：有图的商品也一律 404（手机显示首字）", async () => {
    const { app, store, p } = await withImage();
    await app.close();
    const off = mkApp({ store, config: { productImagesEnabled: false } });
    const r = await off.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(p.token) });
    expect([r.statusCode, r.json()]).toEqual([404, { code: "not_found" }]);
    await off.close();
  });

  it("没图、别的店的商品、不存在的商品 → 404；id 不是 uuid → 400；没令牌 401；被踢 401 revoked", async () => {
    const { app, p } = await withImage();
    const other = await productWithImage(app, { imageUrl: null });
    expect((await app.inject({ method: "GET", url: `/v1/images/${other.productId}`, headers: bearer(other.token) })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(other.token) })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/v1/images/${randomUUID()}`, headers: bearer(p.token) })).statusCode).toBe(404);
    for (const bad of ["..%2F..%2Fetc%2Fpasswd", "not-a-uuid", `${p.productId}%00`])
      expect((await app.inject({ method: "GET", url: `/v1/images/${bad}`, headers: bearer(p.token) })).statusCode, bad).toBe(400);
    // 「..」在路由之前就被规范化掉了，匹配不到这个接口
    expect((await app.inject({ method: "GET", url: "/v1/images/%2e%2e", headers: bearer(p.token) })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/v1/images/${p.productId}` })).statusCode).toBe(401);
    const victim = await login(app, p.username);
    await app.inject({ method: "POST", url: `/v1/devices/${victim.deviceId}/revoke`, headers: bearer(p.token) });
    const rv = await app.inject({ method: "GET", url: `/v1/images/${p.productId}`, headers: bearer(victim.token) });
    expect([rv.statusCode, rv.json().code]).toEqual([401, "revoked"]);
    await app.close();
  });

  it("库里的 image_key 被改成穿越路径：不拿去拼路径，404", async () => {
    const { app, p } = await withImage();
    await tdb.kysely.updateTable("products").set({ image_key: "../../../../etc/passwd" }).where("store_id", "=", p.storeId).where("id", "=", p.productId).execute();
    const r = await app.inject({ method: "GET", url: `/v1/images/${p.productId}?v=1`, headers: bearer(p.token) });
    expect(r.statusCode).toBe(404);
    await app.close();
  });
});
