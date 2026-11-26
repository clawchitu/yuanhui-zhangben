// 候选图刷新（真机 11/26 修复 2）：老条码（S22d 之前查过，条码库里的图片地址已过期、没有候选行）、#52 之前 bad_type 全失败的条码，
// 换商品图时 GET .../images 重新问一次快鸟、刷新条码库、重登记候选，转存后 ready。
// 计费保护：每条码每天最多一次（并发轮询也只问一次；快鸟没问到也算一次）、占本店当天额度、地址没过期 / 明确没查到 / 演示店不刷新。
// 真实路径：真实 Postgres、真实 fetchImage + 本机假图床、真实 worker；快鸟用假的 BarcodeSource（记调用次数）。
import http from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import sharp from "sharp";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import type { Config } from "../src/config.ts";
import type { BarcodeSource, CatalogHit } from "../src/lookup/kuainiao.ts";
import { DEFAULT_FETCH_POLICY, fetchImage, makeThumbnail, sha256, type FetchPolicy } from "../src/lookup/images.ts";
import { MemoryObjectStore } from "../src/lookup/oss.ts";
import { REFRESH_INTERVAL_MS, URL_TTL_MS } from "../src/lookup/candidate-refresh.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { TestClock, bearer, login, makeLoginShop, pair } from "./helpers/auth.ts";
import { expectContract, newBarcode } from "./helpers/sync.ts";

let tdb: TestDb;
let cacheRoot: string;
let server: http.Server;
let port = 0;
const routes: Record<string, (res: http.ServerResponse) => void> = {};

const color = (c: string) => sharp({ create: { width: 400, height: 300, channels: 3, background: c } }).png().toBuffer();
const serve = (p: string, body: Buffer) => {
  routes[p] = (res) => res.writeHead(200, { "content-type": "image/png", "content-length": body.length }).end(body);
  return `http://img.test:${port}${p}`;
};
/** 已过期的地址：图床上已经没有了（api-yun 过期后不再给图） */
const expired = (code: string, i: number) => `http://img.test:${port}/${code}/expired-${i}.png`;
const cidOf = async (img: Buffer) => sha256(await makeThumbnail(img)).slice(0, 16);

beforeAll(async () => {
  tdb = await createTestDb();
  cacheRoot = await mkdtemp(path.join(tmpdir(), "yh-refresh-"));
  server = http.createServer((req, res) => {
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

const policy: () => FetchPolicy = () => ({
  ...DEFAULT_FETCH_POLICY,
  allowAddress: (ip) => ip === "127.0.0.1",
  allowPorts: [port],
  resolve: async (h) => (h === "img.test" ? [{ address: "127.0.0.1", family: 4 }] : []),
  timeoutMs: 1500,
});

/** 假快鸟：每个条码现在给什么（found 带新地址 / not_found / unavailable），记每次调用 */
type Answer = { kind: "found"; hit: CatalogHit } | { kind: "not_found" } | { kind: "unavailable" } | { kind: "slow"; hit: CatalogHit };
const answers = new Map<string, Answer>();
let calls: string[] = [];
const source: BarcodeSource = {
  name: "kuainiao",
  async lookup(b) {
    calls.push(b);
    const a = answers.get(b) ?? { kind: "not_found" };
    if (a.kind === "unavailable") throw Object.assign(new Error("timeout"), { kind: "timeout" });
    if (a.kind === "slow") {
      await new Promise((r) => setTimeout(r, 200));
      return { kind: "found", hit: a.hit, raw: {} };
    }
    return a.kind === "found" ? { kind: "found", hit: a.hit, raw: {} } : { kind: "not_found", raw: {} };
  },
};

function mk(clock: TestClock, config: Partial<Config> = {}) {
  return buildApp({
    config: testConfig({ productImagesEnabled: true, imageCacheDir: path.join(cacheRoot, randomUUID()), ...config }),
    db: tdb,
    logger: false,
    clock: clock.now,
    barcodeSource: source,
    objectStore: new MemoryObjectStore(),
    fetchImage: (u) => fetchImage(u, policy()),
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
const catalogRow = (code: string) => tdb.kysely.selectFrom("barcode_catalog").selectAll().where("barcode", "=", code).executeTakeFirstOrThrow();

/** 老条码：条码库里是 fetchedAt 那时取到的（现在已过期的）地址 */
async function oldCatalog(code: string, fetchedAt: Date, urls: string[], found = true) {
  await tdb.kysely
    .insertInto("barcode_catalog")
    .values({ barcode: code, found, name: found ? `商品${code}` : null, spec: null, brand: null, image_url: urls[0] ?? null, image_urls: urls, source: "kuainiao", raw: null, fetched_at: fetchedAt } as never)
    .execute();
}

/** 新地址：图床上真有的图 */
async function freshImages(code: string, colors: string[]) {
  const imgs = await Promise.all(colors.map(color));
  const urls = imgs.map((b, i) => serve(`/${code}/fresh-${i}.png`, b));
  answers.set(code, { kind: "found", hit: { name: `商品${code}`, imageUrl: urls[0], imageUrls: urls } });
  return Promise.all(imgs.map(cidOf));
}

beforeEach(() => {
  calls = [];
});

describe("老条码：没有候选行、条码库地址已过期", () => {
  it("查码不拿过期地址登记、回 pending；轮询时重新问一次快鸟、刷新条码库、登记新地址，转存后 ready（6921168509256 那种）", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 24 * 3600_000), [expired(code, 0), expired(code, 1)]);
    const want = await freshImages(code, ["#a11", "#1a1", "#11a"]);

    // 手机登记 / 换图：先查码（命中旧缓存，不调快鸟）
    const r = await lookup(app, a.token, code);
    expect(r.json()).toMatchObject({ found: true, image_candidates: { state: "pending", ids: [] } });
    await expectContract("BarcodeLookup", r.json());
    expect(calls).toEqual([]);
    expect(await rows(code)).toEqual([]); // 过期地址没登记

    // 轮询：刷新
    const p1 = await poll(app, a.token, code);
    expect(p1.json().state).toBe("ready"); // 刷新这次请求里就等到了第一张
    await expectContract("ImageCandidates", p1.json());
    expect(calls).toEqual([code]);
    const cat = await catalogRow(code);
    expect(cat.image_urls).toEqual((answers.get(code) as { hit: CatalogHit }).hit.imageUrls);
    expect(new Date(cat.fetched_at).getTime()).toBe(clock.t);
    expect(new Date(cat.images_refreshed_at!).getTime()).toBe(clock.t);
    await app.candidates.drain();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "ready", ids: want });
    expect(calls).toEqual([code]); // 之后的轮询不再问快鸟
    await app.close();
  });

  it("换商品图（现有包只问一次、不轮询）：这一次请求里就带回转存好的候选", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    const want = await freshImages(code, ["#b22"]);
    const t0 = performance.now();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "ready", ids: want });
    expect(performance.now() - t0).toBeLessThan(4500);
    expect(calls).toEqual([code]);
    await app.close();
  });

  it("并发轮询只问一次快鸟", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    await freshImages(code, ["#c33"]);
    const hit = (answers.get(code) as { hit: CatalogHit }).hit;
    answers.set(code, { kind: "slow", hit });
    const rs = await Promise.all([1, 2, 3, 4, 5].map(() => poll(app, a.token, code)));
    expect(rs.every((r) => r.statusCode === 200)).toBe(true);
    expect(calls).toEqual([code]);
    await app.candidates.drain();
    expect((await poll(app, a.token, code)).json().state).toBe("ready");
    await app.close();
  });
});

describe("全部 failed（#52 之前 bad_type、过期链接）", () => {
  it("按新地址重置候选行，转存后 ready；6901285993015 那种只有 1 张的也一样", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 5 * 3600_000), [expired(code, 0), expired(code, 1)]);
    await tdb.kysely
      .insertInto("catalog_image_candidates")
      .values([
        { barcode: code, idx: 0, source_url: expired(code, 0), state: "failed", attempts: 3, last_error: "bad_type" },
        { barcode: code, idx: 1, source_url: expired(code, 1), state: "failed", attempts: 3, last_error: "http" },
      ] as never)
      .execute();
    const want = await freshImages(code, ["#d44"]);
    // 查码：已有行、全失败 → 回 pending 让手机轮询（不在查码里调快鸟）
    expect((await lookup(app, a.token, code)).json().image_candidates).toEqual({ state: "pending", ids: [] });
    expect(calls).toEqual([]);
    expect((await poll(app, a.token, code)).json().state).toBe("ready");
    expect(calls).toEqual([code]);
    await app.candidates.drain();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "ready", ids: want });
    expect((await rows(code)).map((r) => [r.idx, r.state])).toEqual([[0, "ready"]]); // 旧的两行 failed 清掉了
    await app.close();
  });
});

describe("计费保护", () => {
  it("同一条码一天最多刷新一次：刷新后又全失败，24 小时内不再问；过了 24 小时再刷新一次", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    // 快鸟这次给的地址也下不下来
    answers.set(code, { kind: "found", hit: { name: `商品${code}`, imageUrl: expired(code, 9), imageUrls: [expired(code, 9)] } });
    await poll(app, a.token, code);
    // 图床 404 不是永久错误：要重试 3 次（30 秒、5 分钟）才收成 failed
    for (const step of [0, 31_000, 5 * 60_000 + 1000]) {
      clock.advance(step);
      await app.candidates.drain();
    }
    expect((await rows(code)).map((r) => r.state)).toEqual(["failed"]);
    expect(calls).toEqual([code]);
    // 地址又过期了（3 小时后），但还在 24 小时内：不问
    clock.advance(3 * 3600_000);
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    expect((await lookup(app, a.token, code)).json().image_candidates).toEqual({ state: "none", ids: [] });
    expect(calls).toEqual([code]);
    // 过了 24 小时：再刷新一次
    clock.advance(REFRESH_INTERVAL_MS);
    const want = await freshImages(code, ["#e55"]);
    expect((await poll(app, a.token, code)).json().state).toBe("ready");
    expect(calls).toEqual([code, code]);
    await app.candidates.drain();
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "ready", ids: want });
    await app.close();
  });

  it("快鸟没问到（超时）也算用掉今天这一次：之后的轮询不再问", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    answers.set(code, { kind: "unavailable" });
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    for (let i = 0; i < 5; i++) expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    expect(calls).toEqual([code]);
    await app.close();
  });

  it("占本店当天额度：额度用完不刷新", async () => {
    const clock = new TestClock();
    const app = mk(clock, { barcodeDailyLimit: 1 });
    const a = await shop(app);
    // 先用掉今天唯一的一次：查一个新码
    const other = newBarcode();
    answers.set(other, { kind: "not_found" });
    expect((await lookup(app, a.token, other)).json()).toEqual({ found: false });
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    await freshImages(code, ["#f66"]);
    expect((await poll(app, a.token, code)).json()).toEqual({ state: "none", ids: [] });
    expect(calls).toEqual([other]);
    // 额度用完没占今天的名额：过了上海零点（不到 24 小时）额度恢复，就能刷新
    clock.advance(24 * 3600_000 - 60_000); // TEST_NOW 当天内任一时刻起，拨近 24 小时必过一次上海零点
    expect((await poll(app, a.token, code)).json().state).not.toBe("none");
    expect(calls).toEqual([other, code]);
    await app.close();
  });

  it("地址没过期（取到不到 2 小时）、明确没查到、没有条码库行、演示店：都不刷新", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    // 2 小时内取到的：失败就是真失败
    const fresh = newBarcode();
    await oldCatalog(fresh, new Date(clock.t - URL_TTL_MS + 60_000), [expired(fresh, 0)]);
    await tdb.kysely.insertInto("catalog_image_candidates").values({ barcode: fresh, idx: 0, source_url: expired(fresh, 0), state: "failed", attempts: 3, last_error: "bad_type" } as never).execute();
    await freshImages(fresh, ["#123"]);
    expect((await poll(app, a.token, fresh)).json()).toEqual({ state: "none", ids: [] });
    expect((await lookup(app, a.token, fresh)).json().image_candidates).toEqual({ state: "none", ids: [] });
    // 明确没查到
    const nf = newBarcode();
    await oldCatalog(nf, new Date(clock.t - 3 * 24 * 3600_000), [], false);
    await freshImages(nf, ["#234"]);
    expect((await poll(app, a.token, nf)).json()).toEqual({ state: "none", ids: [] });
    // 没有条码库行（从没查过）
    const never = newBarcode();
    await freshImages(never, ["#345"]);
    expect((await poll(app, a.token, never)).json()).toEqual({ state: "none", ids: [] });
    expect(calls).toEqual([]);
    // 演示店
    const d = await makeLoginShop(tdb, { demo: true });
    const demo = await login(app, d.username);
    const old = newBarcode();
    await oldCatalog(old, new Date(clock.t - 3 * 3600_000), [expired(old, 0)]);
    await freshImages(old, ["#456"]);
    expect((await poll(app, demo.token, old)).json()).toEqual({ state: "none", ids: [] });
    expect(calls).toEqual([]);
    await app.close();
  });

  it("收银员问不了候选（guard 拒），查码也不回 image_candidates、不触发刷新", async () => {
    const clock = new TestClock();
    const app = mk(clock);
    const a = await shop(app);
    const cashier = await pair(app, a.token, "cashier", "收银员甲");
    const code = newBarcode();
    await oldCatalog(code, new Date(clock.t - 3 * 3600_000), [expired(code, 0)]);
    await freshImages(code, ["#567"]);
    expect((await poll(app, cashier.token, code)).statusCode).toBe(403);
    const r = (await lookup(app, cashier.token, code)).json();
    expect(r.image_candidates).toBeUndefined();
    expect(calls).toEqual([]);
    expect(await rows(code)).toEqual([]); // 收银员查码也不拿过期地址登记
    await app.close();
  });
});
