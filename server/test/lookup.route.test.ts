// GET /v1/barcode-lookup/:barcode（§7、§6.1、S08）：缓存、7 天重查、2 秒超时 2.5 秒内返回、失败不缓存、并发去重、
// 每店每天额度、每设备每分钟限速、收银员裁剪、演示店不调外部、图片开关、AppCode 不进日志。真实 Postgres、真实 HTTP 请求。
import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp, type AppDeps } from "../src/app.ts";
import { KuainiaoClient, type BarcodeSource, type SourceResult } from "../src/lookup/kuainiao.ts";
import { NOT_FOUND_TTL_MS } from "../src/lookup/catalog.ts";
import type { Config } from "../src/config.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { TestClock, bearer, login, makeLoginShop, pair } from "./helpers/auth.ts";
import { expectContract, newBarcode } from "./helpers/sync.ts";

class FakeSource implements BarcodeSource {
  readonly name = "kuainiao";
  calls: string[] = [];
  behave: (barcode: string, signal: AbortSignal) => Promise<SourceResult> = async (b) => ({
    kind: "found",
    hit: { name: `商品${b}`, spec: "500ml", brand: "某牌", imageUrl: `https://img.example-cdn.com/${b}.jpg` },
    raw: { b },
  });
  async lookup(barcode: string, signal: AbortSignal) {
    this.calls.push(barcode);
    return this.behave(barcode, signal);
  }
}

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

function mk(o: { source?: BarcodeSource | null; config?: Partial<Config>; clock?: TestClock; rateLimits?: AppDeps["rateLimits"]; logStream?: AppDeps["logStream"] } = {}) {
  return buildApp({
    config: testConfig(o.config),
    db: tdb,
    logger: false,
    logStream: o.logStream,
    clock: o.clock?.now,
    barcodeSource: o.source === undefined ? new FakeSource() : o.source,
    objectStore: null,
    rateLimits: o.rateLimits,
  });
}

async function shop(app: FastifyInstance, o: { demo?: boolean } = {}) {
  const s = await makeLoginShop(tdb, o);
  const fam = await login(app, s.username);
  return { ...s, token: fam.token, deviceId: fam.deviceId };
}

const get = (app: FastifyInstance, token: string, code: string) =>
  app.inject({ method: "GET", url: `/v1/barcode-lookup/${encodeURIComponent(code)}`, headers: bearer(token) });

describe("缓存", () => {
  it("查到的写进 barcode_catalog，第二次（别的店也一样）不再调外部", async () => {
    const src = new FakeSource();
    const app = mk({ source: src });
    const a = await shop(app);
    const b = await shop(app);
    const code = newBarcode();
    const r1 = await get(app, a.token, code);
    expect(r1.statusCode).toBe(200);
    expect(r1.json()).toEqual({ found: true, name: `商品${code}`, spec: "500ml", has_image: false, brand: "某牌" });
    await expectContract("BarcodeLookup", r1.json());
    const row = await tdb.kysely.selectFrom("barcode_catalog").selectAll().where("barcode", "=", code).executeTakeFirstOrThrow();
    expect(row).toMatchObject({ found: true, name: `商品${code}`, image_url: `https://img.example-cdn.com/${code}.jpg`, source: "kuainiao" });
    const r2 = await get(app, a.token, code);
    const r3 = await get(app, b.token, code);
    expect(r2.json()).toEqual(r1.json());
    expect(r3.json()).toEqual(r1.json());
    expect(src.calls).toEqual([code]);
    expect(app.catalog.quota.used(a.storeId, new Date())).toBe(1);
    expect(app.catalog.quota.used(b.storeId, new Date())).toBe(0); // 缓存命中不占额度
    await app.close();
  });

  it("查不到也缓存：7 天内不再调外部，过了 7 天重查", async () => {
    const clock = new TestClock();
    const src = new FakeSource();
    src.behave = async () => ({ kind: "not_found", raw: { code: "1" } });
    const app = mk({ source: src, clock });
    const a = await shop(app);
    const code = newBarcode();
    expect((await get(app, a.token, code)).json()).toEqual({ found: false });
    clock.advance(NOT_FOUND_TTL_MS - 60_000);
    expect((await get(app, a.token, code)).json()).toEqual({ found: false });
    expect(src.calls).toHaveLength(1);
    clock.advance(120_000);
    src.behave = async (b) => ({ kind: "found", hit: { name: `后来有了${b}` }, raw: {} });
    expect((await get(app, a.token, code)).json()).toEqual({ found: true, name: `后来有了${code}`, has_image: false });
    expect(src.calls).toHaveLength(2);
    // 查到之后永久有效
    clock.advance(365 * 86_400_000);
    expect((await get(app, a.token, code)).json().found).toBe(true);
    expect(src.calls).toHaveLength(2);
    await app.close();
  });

  it("「查到」的缓存不会被后到的「没查到」覆盖", async () => {
    const { writeCache } = await import("../src/lookup/catalog.ts");
    const code = newBarcode();
    await writeCache(tdb.kysely, code, "kuainiao", { name: "有" }, {}, new Date());
    await writeCache(tdb.kysely, code, "kuainiao", null, {}, new Date());
    const row = await tdb.kysely.selectFrom("barcode_catalog").selectAll().where("barcode", "=", code).executeTakeFirstOrThrow();
    expect([row.found, row.name]).toEqual([true, "有"]);
  });
});

describe("超时与失败降级", () => {
  it("外部 2 秒不回（也不理中止信号）：接口 2.5 秒内返回「没查到」，不写缓存，下次还会再查", async () => {
    const src = new FakeSource();
    src.behave = () => new Promise(() => {}); // 永远不回
    const app = mk({ source: src, config: { barcodeLookupTimeoutMs: 2000 } });
    const a = await shop(app);
    const code = newBarcode();
    const t0 = performance.now();
    const r = await get(app, a.token, code);
    const ms = performance.now() - t0;
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ found: false });
    expect(ms).toBeGreaterThanOrEqual(1990);
    expect(ms).toBeLessThan(2500);
    expect(await tdb.kysely.selectFrom("barcode_catalog").select("barcode").where("barcode", "=", code).executeTakeFirst()).toBeUndefined();
    src.behave = async (b) => ({ kind: "found", hit: { name: b }, raw: {} });
    expect((await get(app, a.token, code)).json().found).toBe(true);
    expect(src.calls).toHaveLength(2);
    await app.close();
  }, 10_000);

  it("理中止信号的实现：到 2 秒就中止", async () => {
    const src = new FakeSource();
    let aborted = false;
    src.behave = (_b, signal) =>
      new Promise((_, rej) =>
        signal.addEventListener("abort", () => {
          aborted = true;
          rej(new Error("aborted"));
        }),
      );
    const app = mk({ source: src, config: { barcodeLookupTimeoutMs: 2000 } });
    const a = await shop(app);
    const t0 = performance.now();
    expect((await get(app, a.token, newBarcode())).json()).toEqual({ found: false });
    expect(performance.now() - t0).toBeLessThan(2500);
    expect(aborted).toBe(true);
    await app.close();
  }, 10_000);

  it("外部出错（网关 5xx、格式不对）→ 没查到，不缓存", async () => {
    const src = new FakeSource();
    src.behave = async () => {
      throw new Error("boom");
    };
    const app = mk({ source: src });
    const a = await shop(app);
    const code = newBarcode();
    expect((await get(app, a.token, code)).json()).toEqual({ found: false });
    expect((await get(app, a.token, code)).json()).toEqual({ found: false });
    expect(src.calls).toHaveLength(2);
    await app.close();
  });

  it("没配 AppCode：不调外部，返回没查到（缓存里有的照样返回）", async () => {
    const app = mk({ source: null });
    const a = await shop(app);
    expect((await get(app, a.token, newBarcode())).json()).toEqual({ found: false });
    await app.close();
  });

  it("AppCode 不进日志：真实客户端遇到网关 403 时，全部日志行里都没有 AppCode", async () => {
    const APPCODE = `appcode-${randomUUID()}`;
    const lines: string[] = [];
    const f = (async () =>
      new Response(`denied for ${APPCODE}`, { status: 403, headers: { "X-Ca-Error-Message": "Quota Exhausted" } })) as typeof fetch;
    const app = mk({
      source: new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/getBarcode", fetch: f }),
      logStream: { write: (l) => void lines.push(l) },
    });
    const a = await shop(app);
    expect((await get(app, a.token, newBarcode())).json()).toEqual({ found: false });
    await app.close();
    expect(lines.some((l) => l.includes("外部条码库查询失败"))).toBe(true);
    expect(lines.join("\n")).not.toContain(APPCODE);
  });
});

describe("AppCode 不进日志、业务错误不进缓存（PR #19 审核）", () => {
  it("网关错误头回显 AppCode（Invalid AppCode `<码>`）：全部日志行里都找不到 AppCode", async () => {
    const APPCODE = `appcode-${randomUUID()}`;
    const lines: string[] = [];
    const f = (async () => new Response("x", { status: 403, headers: { "X-Ca-Error-Message": `Invalid AppCode \`${APPCODE}\`` } })) as typeof fetch;
    const app = mk({
      source: new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/getBarcode", fetch: f }),
      logStream: { write: (l) => void lines.push(l) },
    });
    const a = await shop(app);
    expect((await get(app, a.token, newBarcode())).json()).toEqual({ found: false });
    await app.close();
    const failed = lines.filter((l) => l.includes("外部条码库查询失败"));
    expect(failed).toHaveLength(1);
    expect(failed[0]).toContain("403");
    expect(lines.join("\n")).not.toContain(APPCODE);
  });

  it("真实客户端 + 合法成功形态：当商品写缓存，第二次不再调外部", async () => {
    let calls = 0;
    const f = (async () => {
      calls++;
      return Response.json({ code: "0", msg: "查询成功", data: { goodsName: "白名单矿泉水", spec: "550ml", trademark: "示例牌" } });
    }) as typeof fetch;
    const app = mk({ source: new KuainiaoClient({ appCode: "x", endpoint: "https://h.example/getBarcode", fetch: f }) });
    const a = await shop(app);
    const code = newBarcode();
    expect((await get(app, a.token, code)).json()).toMatchObject({ found: true, name: "白名单矿泉水", spec: "550ml" });
    expect((await get(app, a.token, code)).json()).toMatchObject({ found: true, name: "白名单矿泉水" });
    expect(calls).toBe(1);
    expect(await tdb.kysely.selectFrom("barcode_catalog").selectAll().where("barcode", "=", code).executeTakeFirst()).toMatchObject({ found: true });
    await app.close();
  });

  it("HTTP 200 里的业务错误（{code:\"500\"}、{code:403,name:\"QuotaExhausted\"}）：返回没查到，不写缓存，下次还调外部", async () => {
    for (const body of [
      { code: "500", msg: "系统繁忙" },
      { code: 403, name: "QuotaExhausted" },
      { code: "1", msg: "未查询到该条码信息", data: null },
      // 嵌套业务错误（PR #19 第二轮审核）与未知形态
      { code: 0, data: { success: false, name: "QuotaExhausted" } },
      { code: 0, data: { status: 500, goodsName: "系统繁忙" } },
      { code: 0, data: { errCode: 403, goodsName: "x" } },
      { code: 200, name: "QuotaExhausted" },
      { code: 0, data: { code: "500", name: "系统繁忙" } },
      { code: 0, data: { goodsName: "x" }, extra: 1 },
    ]) {
      let calls = 0;
      const f = (async () => {
        calls++;
        return Response.json(body);
      }) as typeof fetch;
      const app = mk({ source: new KuainiaoClient({ appCode: "x", endpoint: "https://h.example/getBarcode", fetch: f }) });
      const a = await shop(app);
      const code = newBarcode();
      expect((await get(app, a.token, code)).json()).toEqual({ found: false });
      expect((await get(app, a.token, code)).json()).toEqual({ found: false });
      expect(calls).toBe(2);
      expect(await tdb.kysely.selectFrom("barcode_catalog").selectAll().where("barcode", "=", code).executeTakeFirst()).toBeUndefined();
      await app.close();
    }
  });
});

describe("并发去重", () => {
  it("同一条码 8 个请求同时到（不同设备、不同店）：只调外部一次，只占一次额度，结果一致", async () => {
    const src = new FakeSource();
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    src.behave = async (b) => {
      await gate;
      return { kind: "found", hit: { name: `同时${b}` }, raw: {} };
    };
    const app = mk({ source: src });
    const a = await shop(app);
    const b = await shop(app);
    const tokens = [a.token, b.token];
    for (let i = 0; i < 6; i++) tokens.push((await login(app, i % 2 ? a.username : b.username)).token);
    const code = newBarcode();
    const ps = tokens.map((t) => get(app, t, code));
    await new Promise((r) => setTimeout(r, 100));
    release();
    const rs = await Promise.all(ps);
    expect(rs.map((r) => r.statusCode)).toEqual(Array(8).fill(200));
    expect(new Set(rs.map((r) => r.body)).size).toBe(1);
    expect(src.calls).toEqual([code]);
    const used = app.catalog.quota.used(a.storeId, new Date()) + app.catalog.quota.used(b.storeId, new Date());
    expect(used).toBe(1);
    await app.close();
  });
});

describe("额度与限速", () => {
  it("每店每天调外部的次数到上限 → 429 lookup_quota_exceeded（带到上海零点的秒数）；缓存照常；别的店不受影响；第二天恢复", async () => {
    const clock = new TestClock(Date.parse("2026-11-20T15:00:00Z")); // 上海 23:00
    const src = new FakeSource();
    const app = mk({ source: src, clock, config: { barcodeDailyLimit: 3 } });
    const a = await shop(app);
    const b = await shop(app);
    const codes = [newBarcode(), newBarcode(), newBarcode(), newBarcode()];
    for (const c of codes.slice(0, 3)) expect((await get(app, a.token, c)).statusCode).toBe(200);
    const over = await get(app, a.token, codes[3]!);
    expect(over.statusCode).toBe(429);
    expect(over.json()).toEqual({ code: "lookup_quota_exceeded", retry_after_s: 3600 });
    await expectContract("Error", over.json());
    expect(src.calls).toHaveLength(3); // 超了不调外部
    expect((await get(app, a.token, codes[0]!)).json().found).toBe(true); // 缓存命中不受限
    expect((await get(app, b.token, codes[3]!)).statusCode).toBe(200); // 别的店照常
    clock.advance(3600_000); // 上海第二天 00:00
    expect((await get(app, a.token, newBarcode())).statusCode).toBe(200);
    await app.close();
  });

  it("默认上限是每店每天 1000 次", async () => {
    const src = new FakeSource();
    src.behave = async () => ({ kind: "not_found", raw: {} });
    const app = mk({ source: src, rateLimits: { barcodeLookup: { limit: 2000, windowMs: 60_000 } } });
    const a = await shop(app);
    for (let i = 0; i < 1000; i++) expect((await get(app, a.token, newBarcode())).statusCode).toBe(200);
    expect((await get(app, a.token, newBarcode())).json().code).toBe("lookup_quota_exceeded");
    expect(src.calls).toHaveLength(1000);
    await app.close();
  }, 30_000);

  it("每设备每分钟 20 次（含缓存命中）→ 429 rate_limited；别的设备不受影响；过一分钟恢复", async () => {
    const clock = new TestClock();
    const src = new FakeSource();
    const app = mk({ source: src, clock });
    const a = await shop(app);
    const other = await login(app, a.username);
    const code = newBarcode();
    for (let i = 0; i < 20; i++) expect((await get(app, a.token, code)).statusCode).toBe(200);
    const r = await get(app, a.token, code);
    expect(r.statusCode).toBe(429);
    expect(r.json().code).toBe("rate_limited");
    expect(r.json().retry_after_s).toBeGreaterThan(0);
    expect((await get(app, other.token, code)).statusCode).toBe(200);
    clock.advance(60_001);
    expect((await get(app, a.token, code)).statusCode).toBe(200);
    await app.close();
  });

  it("不合法的条码（超长、带斜杠、空格、中文）→ 400，不调外部", async () => {
    const src = new FakeSource();
    const app = mk({ source: src });
    const a = await shop(app);
    for (const c of ["1".repeat(65), "..%2F..%2Fetc", "12 34", "条码", "a/b"]) {
      const r = await app.inject({ method: "GET", url: `/v1/barcode-lookup/${c.includes("%") ? c : encodeURIComponent(c)}`, headers: bearer(a.token) });
      expect([400, 404], c).toContain(r.statusCode);
    }
    expect(src.calls).toEqual([]);
    await app.close();
  });
});

describe("权限与裁剪", () => {
  it("收银员只拿到 found、name、spec、has_image；家用另有 brand；谁都拿不到第三方图片地址", async () => {
    const app = mk({ config: { productImagesEnabled: true } });
    const a = await shop(app);
    const cashier = await pair(app, a.token, "cashier", "小王");
    const code = newBarcode();
    const c = await get(app, cashier.token, code);
    expect(c.statusCode).toBe(200);
    expect(c.json()).toEqual({ found: true, name: `商品${code}`, spec: "500ml", has_image: true });
    const f = await get(app, a.token, code);
    expect(f.json()).toEqual({ found: true, name: `商品${code}`, spec: "500ml", has_image: true, brand: "某牌" });
    for (const r of [c, f]) {
      await expectContract("BarcodeLookup", r.json());
      expect(r.body).not.toContain("img.example-cdn.com");
    }
    await app.close();
  });

  it("图片开关关着（默认）：has_image 一律 false", async () => {
    const app = mk();
    const a = await shop(app);
    expect((await get(app, a.token, newBarcode())).json().has_image).toBe(false);
    await app.close();
  });

  it("没令牌 401 unauthorized；被踢设备 401 revoked，不调外部", async () => {
    const src = new FakeSource();
    const app = mk({ source: src });
    const a = await shop(app);
    const victim = await login(app, a.username);
    const rv = await app.inject({ method: "POST", url: `/v1/devices/${victim.deviceId}/revoke`, headers: bearer(a.token) });
    expect(rv.statusCode).toBeLessThan(300);
    expect((await app.inject({ method: "GET", url: "/v1/barcode-lookup/123" })).json()).toEqual({ code: "unauthorized" });
    const r = await get(app, victim.token, "123");
    expect([r.statusCode, r.json().code]).toEqual([401, "revoked"]);
    expect(src.calls).toEqual([]);
    await app.close();
  });

  it("演示店（审核号）：返回内置假数据，不调外部、不读写缓存、不占额度；没有图", async () => {
    const src = new FakeSource();
    const app = mk({ source: src, config: { productImagesEnabled: true } });
    const d = await shop(app, { demo: true });
    const r = await get(app, d.token, "2000000000015");
    expect(r.json()).toEqual({ found: true, name: "演示可乐", spec: "330ml", has_image: false, brand: "演示" });
    // 真实缓存里有的条码，演示店也不返回
    const code = newBarcode();
    const fam = await shop(app);
    expect((await get(app, fam.token, code)).json().found).toBe(true);
    expect((await get(app, d.token, code)).json()).toEqual({ found: false });
    expect(src.calls).toEqual([code]); // 只有元辉店那一次
    expect(app.catalog.quota.used(d.storeId, new Date())).toBe(0);
    // 演示店里开通的收银员同样
    const cashier = await pair(app, d.token, "cashier", "演示收银");
    expect((await get(app, cashier.token, "2000000000022")).json()).toEqual({ found: true, name: "演示矿泉水", spec: "550ml", has_image: false });
    expect(src.calls).toHaveLength(1);
    await app.close();
  });
});
