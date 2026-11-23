// 商品图候选（S22d-server ①③⑤⑥）：查码当下插候选、异步转存（真实 fetchImage + 本机假图床）、保序最多 6 张、内容去重；
// SSRF / 端口 / 跳转 / 超 5 MB / 非图片 / 解压炸弹各自 failed，不影响查码和商品保存；兜底任务复用候选不再下载；
// 重试 3 次后不再领取；每周清扫只删无行且超过 1 小时的对象；开关关着全部 404 / none、不下载。真实 Postgres。
import http from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { crc32 } from "node:zlib";
import sharp from "sharp";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp, type AppDeps } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import type { BarcodeSource } from "../src/lookup/kuainiao.ts";
import { DEFAULT_FETCH_POLICY, fetchImage, makeThumbnail, sha256, type FetchPolicy } from "../src/lookup/images.ts";
import { MemoryObjectStore, candidateKey } from "../src/lookup/oss.ts";
import { barcodeDir, claimCandidate, sweepCandidateObjects, ORPHAN_GRACE_MS } from "../src/lookup/candidates.ts";
import { enqueueImageJobs, runImageJobs } from "../src/jobs/image-fetch.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { TestClock, bearer, login, makeLoginShop, pair } from "./helpers/auth.ts";
import { expectContract, newBarcode, syncOk, upsertFull } from "./helpers/sync.ts";

let tdb: TestDb;
let cacheRoot: string;
let server: http.Server;
let port = 0;
const hits: string[] = [];
const routes: Record<string, (res: http.ServerResponse) => void> = {};
/** 每个条码快鸟给的图片地址 */
const urlsOf = new Map<string, string[]>();

const color = (c: string, w = 400, h = 300) => sharp({ create: { width: w, height: h, channels: 3, background: c } }).png().toBuffer();
const serve = (p: string, body: Buffer, type = "image/png") => {
  routes[p] = (res) => res.writeHead(200, { "content-type": type, "content-length": body.length }).end(body);
  return `http://img.test:${port}${p}`;
};

function pngHeaderOnly(w: number, h: number): Buffer {
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", Buffer.from([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])), chunk("IEND", Buffer.alloc(0))]);
}

beforeAll(async () => {
  tdb = await createTestDb();
  cacheRoot = await mkdtemp(path.join(tmpdir(), "yh-s22d-cand-"));
  server = http.createServer((req, res) => {
    hits.push(req.url!);
    const h = routes[req.url!];
    if (h) return h(res);
    res.writeHead(404).end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  port = (server.address() as AddressInfo).port;
});
afterAll(async () => {
  await new Promise<void>((r) => server.close(() => r()));
  await tdb.drop();
  await rm(cacheRoot, { recursive: true, force: true });
});

// 真实下载，只放行本机假图床：img.test → 127.0.0.1、端口放行假图床那一个（其余照真实规则：80/443 以外的端口拒、内网地址拒）
const policy: () => FetchPolicy = () => ({
  ...DEFAULT_FETCH_POLICY,
  allowAddress: (ip) => ip === "127.0.0.1",
  allowPorts: [port],
  resolve: async (h) => (h === "img.test" ? [{ address: "127.0.0.1", family: 4 }] : []),
  timeoutMs: 1500,
});

const source: BarcodeSource = {
  name: "kuainiao",
  async lookup(b) {
    const urls = urlsOf.get(b) ?? [];
    return { kind: "found", hit: { name: `商品${b}`, spec: "1个", ...(urls.length ? { imageUrl: urls[0], imageUrls: urls } : {}) }, raw: {} };
  },
};

function mk(o: { config?: Partial<Config>; clock?: TestClock; store?: MemoryObjectStore; rateLimits?: AppDeps["rateLimits"] } = {}) {
  return buildApp({
    config: testConfig({ productImagesEnabled: true, imageCacheDir: path.join(cacheRoot, randomUUID()), ...o.config }),
    db: tdb,
    logger: false,
    clock: o.clock?.now,
    barcodeSource: source,
    objectStore: o.store ?? new MemoryObjectStore(),
    fetchImage: (u) => fetchImage(u, policy()),
    rateLimits: o.rateLimits,
  });
}

async function shop(app: FastifyInstance) {
  const s = await makeLoginShop(tdb);
  const fam = await login(app, s.username);
  return { ...s, token: fam.token };
}
const lookup = (app: FastifyInstance, token: string, code: string) => app.inject({ method: "GET", url: `/v1/barcode-lookup/${code}`, headers: bearer(token) });
const poll = (app: FastifyInstance, token: string, code: string) => app.inject({ method: "GET", url: `/v1/barcode-lookup/${code}/images`, headers: bearer(token) });
const rows = (code: string) => tdb.kysely.selectFrom("catalog_image_candidates").selectAll().where("barcode", "=", code).orderBy("idx").execute();
const cidOf = async (img: Buffer) => sha256(await makeThumbnail(img)).slice(0, 16);

describe("转存", () => {
  it("多图：查码立即返回 pending、不等下载；转存后 ids 按快鸟顺序、最多 6 张；内容重复的记 failed duplicate；再查不重插；缩图强缓存", async () => {
    const app = mk();
    const a = await shop(app);
    const code = newBarcode();
    const imgs = await Promise.all(["#a00", "#0a0", "#00a", "#0a0", "#aa0", "#0aa", "#a0a", "#555"].map((c) => color(c)));
    urlsOf.set(code, imgs.map((b, i) => serve(`/${code}/${i}.png`, b)));
    const t0 = performance.now();
    const r1 = await lookup(app, a.token, code);
    expect(performance.now() - t0).toBeLessThan(1000);
    expect(r1.json()).toMatchObject({ found: true, has_image: true, image_candidates: { state: "pending", ids: [] } });
    await expectContract("BarcodeLookup", r1.json());
    await app.candidates.drain();
    const want = [await cidOf(imgs[0]!), await cidOf(imgs[1]!), await cidOf(imgs[2]!), await cidOf(imgs[4]!), await cidOf(imgs[5]!)];
    const p = await poll(app, a.token, code);
    expect(p.json()).toEqual({ state: "ready", ids: want });
    await expectContract("ImageCandidates", p.json());
    const rs = await rows(code);
    expect(rs.map((r) => [r.idx, r.state, r.last_error])).toEqual([
      [0, "ready", null],
      [1, "ready", null],
      [2, "ready", null],
      [3, "failed", "duplicate"],
      [4, "ready", null],
      [5, "ready", null],
    ]);
    expect(rs[0]!.object_key).toBe(candidateKey(barcodeDir(code), want[0]!));
    expect(hits.filter((h) => h.startsWith(`/${code}/6`) || h.startsWith(`/${code}/7`))).toEqual([]); // 第 7、8 张不下
    // 再查：不重插、不重下
    const before = hits.length;
    expect((await lookup(app, a.token, code)).json().image_candidates).toEqual({ state: "ready", ids: want });
    await app.candidates.drain();
    expect(hits.length).toBe(before);
    // 缩图
    const img = await app.inject({ method: "GET", url: `/v1/barcode-lookup/${code}/images/${want[1]}`, headers: bearer(a.token) });
    expect(img.statusCode).toBe(200);
    expect(img.headers).toMatchObject({ "content-type": "image/jpeg", "cache-control": "private, max-age=31536000, immutable", "x-content-type-options": "nosniff", "content-security-policy": "default-src 'none'" });
    expect((await sharp(img.rawPayload).metadata()).format).toBe("jpeg");
    expect((await app.inject({ method: "GET", url: `/v1/barcode-lookup/${code}/images/${"0".repeat(16)}`, headers: bearer(a.token) })).statusCode).toBe(404);
    // S08-1 回归：响应里搜不到第三方主机名
    for (const r of [r1, p]) expect(r.body).not.toContain("img.test");
    await app.close();
  });

  it("单图也有候选；兜底任务（image_ver=0 落第一张）直接复制它，不再下载", async () => {
    const store = new MemoryObjectStore();
    const app = mk({ store });
    const a = await shop(app);
    const code = newBarcode();
    const img = await color("#c33");
    urlsOf.set(code, [serve(`/${code}/only.png`, img)]);
    await lookup(app, a.token, code);
    await app.candidates.drain();
    const cid = await cidOf(img);
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "ready", ids: [cid] });
    const productId = randomUUID();
    await syncOk(app, a.token, { epoch: a.epoch, ops: [upsertFull({ productId, barcode: code })] });
    const downloads: string[] = [];
    const d = { db: tdb.kysely, store, enabled: true, clock: () => new Date(), fetchImage: async (u: string) => (downloads.push(u), Buffer.alloc(0)) };
    await enqueueImageJobs(d);
    await runImageJobs(d, 1000);
    expect(downloads.filter((u) => u.includes(code))).toEqual([]);
    expect(hits.filter((h) => h === `/${code}/only.png`)).toHaveLength(1);
    const p = await tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", a.storeId).where("id", "=", productId).executeTakeFirstOrThrow();
    expect([p.image_ver, p.image_source]).toEqual([1, "kuainiao"]);
    const got = await app.inject({ method: "GET", url: `/v1/images/${productId}?v=1`, headers: bearer(a.token) });
    expect(got.rawPayload.equals(store.objects.get((await rows(code))[0]!.object_key!)!.body)).toBe(true);
    await app.close();
  });

  it("内网地址、跳转到内网、非 80/443 端口、超 5 MB、不是图片、伪装成 PNG 的 SVG、解压炸弹：各自 failed（原因代码），查码照常返回、商品照常保存", async () => {
    const app = mk();
    const a = await shop(app);
    const code = newBarcode();
    routes[`/${code}/redir`] = (res) => res.writeHead(302, { location: `http://169.254.169.254:${port}/latest/meta-data` }).end();
    const big = Buffer.alloc(5 * 1024 * 1024 + 10, 1);
    urlsOf.set(code, [
      `http://10.1.2.3:${port}/a.jpg`,
      `http://img.test:${port}/${code}/redir`,
      `http://img.test:8443/${code}/x.jpg`,
      serve(`/${code}/big.png`, big),
      serve(`/${code}/page.html`, Buffer.from("<html></html>"), "text/html"),
      serve(`/${code}/svg.png`, Buffer.from("<svg xmlns='http://www.w3.org/2000/svg'/>")),
    ]);
    const r = await lookup(app, a.token, code);
    expect([r.statusCode, r.json().found]).toEqual([200, true]);
    await app.candidates.drain();
    expect((await rows(code)).map((x) => [x.state, x.last_error])).toEqual([
      ["failed", "private_address"],
      ["failed", "private_address"],
      ["failed", "bad_port"],
      ["failed", "too_large"],
      ["failed", "bad_type"],
      ["failed", "bad_format"],
    ]);
    // 解压炸弹单独一个码（每码最多 6 张）
    const bomb = newBarcode();
    urlsOf.set(bomb, [serve(`/${bomb}/bomb.png`, pngHeaderOnly(6000, 6000))]);
    await lookup(app, a.token, bomb);
    await app.candidates.drain();
    expect((await rows(bomb)).map((x) => [x.state, x.last_error])).toEqual([["failed", "too_big_dimensions"]]);
    // 全失败 = none；查码照常、has_image false；商品照常保存
    const again = await lookup(app, a.token, code);
    expect(again.json()).toMatchObject({ found: true, has_image: false, image_candidates: { state: "none", ids: [] } });
    for (const x of [r, again]) {
      expect(x.body).not.toContain("img.test");
      expect(x.body).not.toContain("10.1.2.3");
    }
    await syncOk(app, a.token, { epoch: a.epoch, ops: [upsertFull({ barcode: code })] });
    await app.close();
  });

  it("重试共 3 次（隔 30 秒、5 分钟），之后 failed、不再领取；last_error 只记原因代码", async () => {
    const clock = new TestClock(Date.parse("2001-01-01T00:00:00Z"));
    const app = mk({ clock });
    const a = await shop(app);
    const code = newBarcode();
    routes[`/${code}/500`] = (res) => res.writeHead(500).end();
    urlsOf.set(code, [`http://img.test:${port}/${code}/500`]);
    await lookup(app, a.token, code);
    const n = () => hits.filter((h) => h === `/${code}/500`).length;
    await app.candidates.drain();
    expect([n(), (await rows(code))[0]!.state, (await rows(code))[0]!.attempts]).toEqual([1, "pending", 1]);
    await app.candidates.drain(); // 没到点
    expect(n()).toBe(1);
    clock.advance(30_000);
    await app.candidates.drain();
    expect(n()).toBe(2);
    clock.advance(5 * 60_000);
    await app.candidates.drain();
    const row = (await rows(code))[0]!;
    expect([n(), row.state, row.attempts, row.last_error]).toEqual([3, "failed", 3, "bad_status"]);
    clock.advance(24 * 3600_000);
    await app.candidates.drain();
    expect(n()).toBe(3);
    expect(await claimCandidate({ db: tdb.kysely, store: new MemoryObjectStore(), enabled: true, clock: clock.now })).toBeNull();
    await app.close();
  });

  it("轮询接口每设备每分钟 60 次（这里调成 2 次），超了 429 rate_limited", async () => {
    const app = mk({ rateLimits: { barcodeImages: { limit: 2, windowMs: 60_000 } } });
    const a = await shop(app);
    const code = newBarcode();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    await poll(app, a.token, code);
    const r = await poll(app, a.token, code);
    expect([r.statusCode, r.json().code]).toEqual([429, "rate_limited"]);
    await app.close();
  });
});

describe("清扫与开关", () => {
  it("每周清扫：只删 images/_catalog/ 下没有对应行、落地超过 1 小时的对象", async () => {
    const store = new MemoryObjectStore();
    const now = new Date();
    const code = newBarcode();
    await tdb.kysely.insertInto("barcode_catalog").values({ barcode: code, found: true, name: "x", source: "kuainiao" }).execute();
    const live = candidateKey(barcodeDir(code), "1".repeat(16));
    await tdb.kysely.insertInto("catalog_image_candidates").values({ barcode: code, idx: 0, source_url: "https://x/y", state: "ready", cid: "1".repeat(16), object_key: live }).execute();
    const oldOrphan = candidateKey(barcodeDir(code), "2".repeat(16));
    const newOrphan = candidateKey(barcodeDir(code), "3".repeat(16));
    for (const k of [live, oldOrphan, newOrphan]) await store.put(k, Buffer.from("jpg"), "image/jpeg");
    store.objects.get(live)!.at = new Date(now.getTime() - 2 * ORPHAN_GRACE_MS);
    store.objects.get(oldOrphan)!.at = new Date(now.getTime() - ORPHAN_GRACE_MS - 1000);
    store.objects.get(newOrphan)!.at = new Date(now.getTime() - ORPHAN_GRACE_MS + 60_000);
    const removed = await sweepCandidateObjects({ db: tdb.kysely, store, enabled: true, clock: () => now });
    expect(removed).toEqual([oldOrphan]);
    expect([...store.objects.keys()].sort()).toEqual([live, newOrphan].sort());
  });

  it("清扫与转存竞态（PR #42 必须改 2）：列举之后、删除之前这个键刚被写成 ready → 不删，不留悬空 ready 行", async () => {
    const store = new MemoryObjectStore();
    const now = new Date();
    const code = newBarcode();
    await tdb.kysely.insertInto("barcode_catalog").values({ barcode: code, found: true, name: "x", source: "kuainiao" }).execute();
    const key = candidateKey(barcodeDir(code), "4".repeat(16));
    await store.put(key, Buffer.from("jpg"), "image/jpeg");
    store.objects.get(key)!.at = new Date(now.getTime() - 2 * ORPHAN_GRACE_MS);
    const list = store.listWithTimes.bind(store);
    store.listWithTimes = async (p) => {
      const r = await list(p);
      // 快照拿到之后，worker 重新转存了同一张并写成 ready
      await tdb.kysely.insertInto("catalog_image_candidates").values({ barcode: code, idx: 0, source_url: "https://x/y", state: "ready", cid: "4".repeat(16), object_key: key }).execute();
      return r;
    };
    expect(await sweepCandidateObjects({ db: tdb.kysely, store, enabled: true, clock: () => now })).toEqual([]);
    expect(store.objects.has(key)).toBe(true);
  });

  it("领满 3 次还停在 pending 的遗留行（第 3 次领取后进程退出）：不再算 pending，下一轮收成 failed", async () => {
    const app = mk();
    const a = await shop(app);
    const code = newBarcode();
    await tdb.kysely.insertInto("barcode_catalog").values({ barcode: code, found: true, name: "x", source: "kuainiao" }).execute();
    await tdb.kysely.insertInto("catalog_image_candidates").values({ barcode: code, idx: 0, source_url: "https://x/y", state: "pending", attempts: 3, next_try_at: new Date(Date.now() - 1000) }).execute();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    await app.candidates.drain();
    expect((await rows(code)).map((r) => [r.state, r.last_error])).toEqual([["failed", "abandoned"]]);
    await app.close();
  });

  it("开关关着时轮询一律 404，不进限速计数（PR #42 Codex 可选 1）", async () => {
    const app = mk({ config: { productImagesEnabled: false }, rateLimits: { barcodeImages: { limit: 2, windowMs: 60_000 } } });
    const a = await shop(app);
    for (let i = 0; i < 4; i++) expect((await poll(app, a.token, newBarcode())).statusCode).toBe(404);
    await app.close();
  });

  it("开关关着：不插候选、不下载；lookup state=none、has_image=false；候选、缩图、选图、上传、读图全部 404；/v1/config 为 false", async () => {
    const app = mk({ config: { productImagesEnabled: false } });
    const a = await shop(app);
    const code = newBarcode();
    urlsOf.set(code, [serve(`/${code}/off.png`, await color("#123"))]);
    const r = await lookup(app, a.token, code);
    expect(r.json()).toEqual({ found: true, name: `商品${code}`, spec: "1个", has_image: false, image_candidates: { state: "none", ids: [] } });
    await app.candidates.drain();
    expect(await rows(code)).toEqual([]);
    expect(hits.filter((h) => h.startsWith(`/${code}/`))).toEqual([]);
    const productId = randomUUID();
    await syncOk(app, a.token, { epoch: a.epoch, ops: [upsertFull({ productId, barcode: code })] });
    const jpeg = await sharp({ create: { width: 64, height: 64, channels: 3, background: "#456" } }).jpeg().toBuffer();
    for (const req of [
      { method: "GET" as const, url: `/v1/barcode-lookup/${code}/images` },
      { method: "GET" as const, url: `/v1/barcode-lookup/${code}/images/${"a".repeat(16)}` },
      { method: "POST" as const, url: `/v1/images/${productId}/select`, payload: { barcode: code, candidate_id: "a".repeat(16) } },
      { method: "PUT" as const, url: `/v1/images/${productId}`, payload: jpeg, headers: { "content-type": "image/jpeg" } },
      { method: "GET" as const, url: `/v1/images/${productId}` },
    ]) {
      const res = await app.inject({ ...req, headers: { ...bearer(a.token), ...(req.headers ?? {}) } });
      expect([res.statusCode, res.json().code], req.url).toEqual([404, "not_found"]);
    }
    expect((await app.inject({ method: "GET", url: "/v1/config" })).json().product_images_enabled).toBe(false);
    await app.close();
  });

  it("演示店：不插候选、state 恒为 none；收银员的查码响应没有 image_candidates", async () => {
    const app = mk();
    const demo = await makeLoginShop(tdb, { demo: true });
    const rv = await login(app, demo.username);
    const r = await lookup(app, rv.token, "2000000000015");
    expect(r.json()).toMatchObject({ has_image: false, image_candidates: { state: "none", ids: [] } });
    expect((await poll(app, rv.token, "2000000000015")).json()).toEqual({ state: "none", ids: [] });
    const a = await shop(app);
    const cashier = await pair(app, a.token, "cashier", "小李");
    const code = newBarcode();
    urlsOf.set(code, [serve(`/${code}/c.png`, await color("#321"))]);
    const c = await lookup(app, cashier.token, code);
    expect(c.json()).toEqual({ found: true, name: `商品${code}`, spec: "1个", has_image: true });
    await app.candidates.drain();
    await app.close();
  });
});
