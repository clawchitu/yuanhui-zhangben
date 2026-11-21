// S04 返修（PR #10 的 Codex / Fable 审核）：每条都是先在旧代码上失败的回归测试。
// - S04-2：注销期间整批不应用、results 为空、响应带 delete_pending_until
// - S04-8：按店排队上限，超过 503 unavailable
// - S04-10：product_upsert 的商品 id 已存在时不挂码（堵收银员绕过 barcode_link 权限）
// - S04-13：存不进库 / 算不了哈希的 op 单个 rejected invalid、不留档，绝不 500（第二轮：嵌套极深 / 节点过多的 payload；savepoint 兜底注入故障）
// - 请求体上限 1 MiB：最大的合法 op 放得下，超过 413 invalid
// - S04-5 补充：barcode_link 挂单件码时单位名一律写商品的基本单位
import { randomUUID } from "node:crypto";
import { sql } from "kysely";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { expectContract, newBarcode, op, sync, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";
import { BODY_LIMIT, buildApp } from "../src/app.ts";
import { opSchemaValid } from "../src/sync/validate.ts";
import { storable, type IncomingOp } from "../src/sync/push.ts";
import { storeLockKey } from "../src/sync/lock.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const storeRev = async (id: string) =>
  (await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", id).executeTakeFirstOrThrow()).rev;
const opsOf = (storeId: string) => tdb.kysely.selectFrom("ops").selectAll().where("store_id", "=", storeId).orderBy("id").execute();
const barcodesOf = (storeId: string) =>
  tdb.kysely.selectFrom("product_barcodes").selectAll().where("store_id", "=", storeId).orderBy("barcode").execute();
const productsOf = (storeId: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).orderBy("id").execute();

async function setup() {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb);
  const boss = await login(app, shop.username);
  return { shop, app, boss };
}

describe("S04-2 注销期间", () => {
  it("推 3 个 op：一个都不应用、不留档，results 为空，带 delete_pending_until，同一请求的拉取照常；撤回后原样重发全部 applied、不带 replayed", async () => {
    const { shop, app, boss } = await setup();
    const first = upsertFull({ name: "注销前登记的" });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [first] });
    const requestedAt = new Date("2026-11-20T01:00:00Z");
    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: requestedAt }).where("id", "=", shop.accountId).execute();
    const revBefore = await storeRev(shop.storeId);
    const opsBefore = await opsOf(shop.storeId);

    const ops = [upsertFull(), upsertFull(), op("product_edit", { product_id: first.payload.product_id, name: "改名" })];
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops });
    expect(r.results).toEqual([]);
    expect(r.delete_pending_until).toBe(new Date(requestedAt.getTime() + 7 * 24 * 3600 * 1000).toISOString());
    expect(r.changes.products.map((p: { id: string }) => p.id)).toEqual([first.payload.product_id]);
    expect(await storeRev(shop.storeId)).toBe(revBefore);
    expect(await opsOf(shop.storeId)).toEqual(opsBefore);

    // 不推 op 的请求也带
    const idle = await syncOk(app, boss.token, { epoch: shop.epoch });
    expect(idle.delete_pending_until).toBe(r.delete_pending_until);

    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: null }).where("id", "=", shop.accountId).execute();
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch, ops });
    await app.close();
    expect(r2.results).toEqual(ops.map((o) => ({ id: o.id, status: "applied" })));
    expect(r2).not.toHaveProperty("delete_pending_until");
  });

  it("被踢设备在注销期间补传的 op 同样处理：results 为空、不留档", async () => {
    const { shop, app, boss } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    await tdb.kysely.updateTable("devices").set({ revoked_at: new Date(), revoke_reason: "kicked" }).where("store_id", "=", shop.storeId).where("id", "=", cas.deviceId).execute();
    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: new Date() }).where("id", "=", shop.accountId).execute();
    const o = upsertQuick({ extra: {} });
    o.occurred_at = new Date(Date.now() - 60_000).toISOString();
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r.results).toEqual([]);
    expect(r.delete_pending_until).toEqual(expect.any(String));
    expect(await opsOf(shop.storeId)).toEqual([]);
  });

  it("请求进来以后、拿到店铺锁之前申请了注销：按锁内读到的状态，整批不应用", async () => {
    const { shop, app, boss } = await setup();
    const c = await tdb.pool.connect();
    await c.query("BEGIN");
    await c.query("SELECT pg_advisory_xact_lock($1)", [storeLockKey(shop.storeId)]);
    const o = upsertFull();
    const pending = sync(app, boss.token, { epoch: shop.epoch, ops: [o] });
    await new Promise((r) => setTimeout(r, 200));
    await c.query("UPDATE accounts SET delete_requested_at = now() WHERE id = $1", [shop.accountId]);
    await c.query("COMMIT");
    c.release();
    const r = await pending;
    await app.close();
    expect(r.status).toBe(200);
    expect(r.body.results).toEqual([]);
    expect(r.body.delete_pending_until).toEqual(expect.any(String));
    expect(await opsOf(shop.storeId)).toEqual([]);
  });
});

describe("S04-8 按店排队上限", () => {
  it("一家店在途请求超过上限：多出来的立刻 503 unavailable 带 retry_after_s；别的店照常；被 503 的原样重发能入账、再发是重放", async () => {
    const shopA = await makeLoginShop(tdb);
    const shopB = await makeLoginShop(tdb);
    const app = makeApp(tdb, { config: { storeQueueLimit: 2 } });
    const a = await login(app, shopA.username);
    const b = await login(app, shopB.username);
    // 另一个连接拿着 A 店的店铺锁，A 店的请求全部堵住
    const c = await tdb.pool.connect();
    await c.query("BEGIN");
    await c.query("SELECT pg_advisory_xact_lock($1)", [storeLockKey(shopA.storeId)]);
    const batches = Array.from({ length: 6 }, () => [upsertFull()]);
    const pending = batches.map((ops) => sync(app, a.token, { epoch: shopA.epoch, ops }));
    await new Promise((r) => setTimeout(r, 300));
    // 别的店不受影响
    const other = await syncOk(app, b.token, { epoch: shopB.epoch, ops: [upsertFull()] });
    expect(other.results[0].status).toBe("applied");
    await c.query("COMMIT");
    c.release();
    const rs = await Promise.all(pending);
    const ok = rs.filter((r) => r.status === 200);
    const busy = rs.filter((r) => r.status === 503);
    expect(ok).toHaveLength(2);
    expect(busy).toHaveLength(4);
    for (const r of busy) {
      expect(r.body.code).toBe("unavailable");
      expect(r.body.retry_after_s).toBeGreaterThan(0);
    }
    // 503 的请求一个 op 都没留档
    expect(await opsOf(shopA.storeId)).toHaveLength(2);
    const busyBatches = batches.filter((_, i) => rs[i]!.status === 503);
    for (const ops of busyBatches) {
      const r1 = await syncOk(app, a.token, { epoch: shopA.epoch, ops });
      expect(r1.results).toEqual([{ id: ops[0]!.id, status: "applied" }]);
      const r2 = await syncOk(app, a.token, { epoch: shopA.epoch, ops });
      expect(r2.results).toEqual([{ id: ops[0]!.id, status: "applied", replayed: true }]);
    }
    await app.close();
    expect(await opsOf(shopA.storeId)).toHaveLength(6);
  });

  it("默认上限 32，配置项 STORE_QUEUE_LIMIT 可改，必须是正整数", async () => {
    const { loadConfig, ConfigError } = await import("../src/config.ts");
    expect(loadConfig({ DATABASE_URL: "postgres://x" }).storeQueueLimit).toBe(32);
    expect(loadConfig({ DATABASE_URL: "postgres://x", STORE_QUEUE_LIMIT: "5" }).storeQueueLimit).toBe(5);
    expect(() => loadConfig({ DATABASE_URL: "postgres://x", STORE_QUEUE_LIMIT: "0" })).toThrow(ConfigError);
  });
});

describe("S04-10 product_upsert 的商品 id 已存在", () => {
  it("收银员 quick 登记引用已有商品 + 空闲条码（真实请求）：rejected invalid 并留档，条码没挂上，商品不变；barcode_link 同样 forbidden", async () => {
    const { shop, app, boss } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    const p = upsertFull();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p] });
    const before = { products: await productsOf(shop.storeId), barcodes: await barcodesOf(shop.storeId), rev: await storeRev(shop.storeId) };
    const free = newBarcode();
    const link = op("barcode_link", { barcode: free, product_id: p.payload.product_id, pack_qty: 1, unit_name: "罐" });
    const sneak = upsertQuick({ productId: p.payload.product_id as string, barcode: free });
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [link, sneak] });
    expect(r.results).toEqual([
      { id: link.id, status: "rejected", code: "forbidden" },
      { id: sneak.id, status: "rejected", code: "invalid" },
    ]);
    expect(await productsOf(shop.storeId)).toEqual(before.products);
    expect(await barcodesOf(shop.storeId)).toEqual(before.barcodes);
    expect(await storeRev(shop.storeId)).toBe(before.rev);
    const row = (await opsOf(shop.storeId)).find((o) => o.id === sneak.id);
    expect(row).toMatchObject({ status: "rejected", reject_code: "invalid" });
    // 重发得到同样的结果
    const again = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [sneak] });
    await app.close();
    expect(again.results).toEqual([{ id: sneak.id, status: "rejected", code: "invalid", replayed: true }]);
  });

  it("被踢设备走同一条路也挂不上", async () => {
    const { shop, app, boss } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    const p = upsertFull();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p] });
    const sneak = upsertQuick({ productId: p.payload.product_id as string });
    sneak.occurred_at = new Date(Date.now() - 120_000).toISOString();
    await tdb.kysely.updateTable("devices").set({ revoked_at: new Date(), revoke_reason: "kicked" }).where("store_id", "=", shop.storeId).where("id", "=", cas.deviceId).execute();
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [sneak] });
    await app.close();
    expect(r.results).toEqual([{ id: sneak.id, status: "rejected", code: "invalid" }]);
    expect((await barcodesOf(shop.storeId)).map((b) => b.barcode)).toEqual([p.payload.barcode]);
  });

  it("家用完整登记也一样：条码空闲 / 解除过 / 挂在别的商品上 → invalid、不带 remap、什么都不改；条码就挂在这个商品上 → applied 无操作", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull();
    const q = upsertFull();
    const unlinkedCode = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [
        p,
        q,
        op("barcode_link", { barcode: unlinkedCode, product_id: p.payload.product_id, pack_qty: 6, unit_name: "排" }),
        op("barcode_unlink", { barcode: unlinkedCode, product_id: p.payload.product_id }),
      ],
    });
    const before = { products: await productsOf(shop.storeId), barcodes: await barcodesOf(shop.storeId), rev: await storeRev(shop.storeId) };
    const pid = p.payload.product_id as string;
    const free = upsertFull({ productId: pid });
    const unlinked = upsertFull({ productId: pid, barcode: unlinkedCode });
    const others = upsertFull({ productId: pid, barcode: q.payload.barcode as string });
    const same = upsertFull({ productId: pid, barcode: p.payload.barcode as string, name: "别的名字", price: 999 });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [free, unlinked, others, same] });
    await app.close();
    expect(r.results).toEqual([
      { id: free.id, status: "rejected", code: "invalid" },
      { id: unlinked.id, status: "rejected", code: "invalid" },
      { id: others.id, status: "rejected", code: "invalid" },
      { id: same.id, status: "applied" },
    ]);
    expect(await productsOf(shop.storeId)).toEqual(before.products);
    expect(await barcodesOf(shop.storeId)).toEqual(before.barcodes);
    expect(await storeRev(shop.storeId)).toBe(before.rev);
  });
});

describe("S04-13 存不进库、算不了哈希的 op", () => {
  const cases: [string, (good: ReturnType<typeof upsertFull>) => ReturnType<typeof upsertFull>][] = [
    ["名称里有 \\u0000", () => upsertFull({ name: "可乐\u0000" })],
    ["条码里有 \\u0000", () => upsertFull({ barcode: "690\u0000123" })],
    ["payload 的键里有 \\u0000", () => upsertFull({ extra: { "x\u0000": 1 } })],
    ["名称里有不成对的代理项", () => upsertFull({ name: "a\ud800b" })],
    ["名称里有落单的低代理项", () => upsertFull({ name: "a\udc00" })],
    ["occurred_at 是闰秒写法", () => ({ ...upsertFull(), occurred_at: "2026-06-30T23:59:60Z" })],
    ["没实现的类型带 \\u0000", () => op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 1, lines: [], note: "\u0000" }) as ReturnType<typeof upsertFull>],
  ];
  for (const [name, make] of cases) {
    it(`${name}：这个 op rejected invalid、不留档，同批正常的 op applied；重发结果相同`, async () => {
      const { shop, app, boss } = await setup();
      const good = upsertFull();
      const bad = make(good);
      const tail = upsertFull();
      const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [good, bad, tail] });
      expect(r.results).toEqual([
        { id: good.id, status: "applied" },
        { id: bad.id, status: "rejected", code: "invalid" },
        { id: tail.id, status: "applied" },
      ]);
      expect((await opsOf(shop.storeId)).map((o) => o.id).sort()).toEqual([good.id, tail.id].sort());
      const again = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [bad] });
      await app.close();
      expect(again.results).toEqual([{ id: bad.id, status: "rejected", code: "invalid" }]);
    });
  }

  // 嵌套极深的 payload：请求本身很小（5000 层约 10 KB），但递归处理会栈溢出。
  // 手机 SDK 序列化不出这种东西，所以请求体按字符串拼，走真实的 HTTP 解析。
  const nest = (depth: number, open: string, close: string, leaf = "0") => open.repeat(depth) + leaf + close.repeat(depth);
  const deepCases: [string, string][] = [
    ["多余字段里 5000 层嵌套数组", nest(5000, "[", "]")],
    ["多余字段里 5000 层嵌套对象", nest(5000, '{"a":', "}")],
    ["多余字段里 50 万层嵌套数组（约 1 MB，请求体上限以内）", nest(500_000, "[", "]")],
    ["多余字段里 17 层嵌套（payload 本身算 1 层，超过上限 16 层）", nest(16, "[", "]")],
    ["多余字段里 2 万个元素的数组（超过节点数上限）", `[${Array(20_000).fill("0").join(",")}]`],
  ];
  async function pushRaw(app: ReturnType<typeof makeApp>, token: string, epoch: string, opsJson: string[]) {
    const res = await app.inject({
      method: "POST",
      url: "/v1/sync",
      headers: { ...bearer(token), "content-type": "application/json" },
      payload: `{"epoch":"${epoch}","cursors":{"catalog":0,"ledger":0},"app_build":1,"pull":false,"ops":[${opsJson.join(",")}]}`,
    });
    return { status: res.statusCode, body: res.json() };
  }
  const withExtra = (o: ReturnType<typeof upsertFull>, raw: string) => JSON.stringify(o).replace(/}}$/, `,"extra":${raw}}}`);
  for (const [name, raw] of deepCases) {
    it(`${name}：这个 op rejected invalid、不留档，前后正常的 op applied；重发结果相同`, async () => {
      const { shop, app, boss } = await setup();
      const good = upsertFull();
      const bad = upsertFull();
      const tail = upsertFull();
      const r = await pushRaw(app, boss.token, shop.epoch, [JSON.stringify(good), withExtra(bad, raw), JSON.stringify(tail)]);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.results).toEqual([
        { id: good.id, status: "applied" },
        { id: bad.id, status: "rejected", code: "invalid" },
        { id: tail.id, status: "applied" },
      ]);
      expect((await opsOf(shop.storeId)).map((o) => o.id).sort()).toEqual([good.id, tail.id].sort());
      expect((await productsOf(shop.storeId)).map((p) => p.id).sort()).toEqual([good.payload.product_id, tail.payload.product_id].sort());
      const again = await pushRaw(app, boss.token, shop.epoch, [withExtra(bad, raw)]);
      await app.close();
      expect(again.status).toBe(200);
      expect(again.body.results).toEqual([{ id: bad.id, status: "rejected", code: "invalid" }]);
    });
  }

  it("嵌套正好在上限（payload 共 16 层）：照常算哈希、按 schema 拒 invalid 并留档，重发 replayed", async () => {
    const { shop, app, boss } = await setup();
    const bad = upsertFull();
    const raw = nest(15, "[", "]");
    const r = await pushRaw(app, boss.token, shop.epoch, [withExtra(bad, raw)]);
    expect(r.body.results).toEqual([{ id: bad.id, status: "rejected", code: "invalid" }]);
    expect((await opsOf(shop.storeId)).map((o) => o.id)).toEqual([bad.id]);
    const again = await pushRaw(app, boss.token, shop.epoch, [withExtra(bad, raw)]);
    await app.close();
    expect(again.body.results).toEqual([{ id: bad.id, status: "rejected", code: "invalid", replayed: true }]);
  });

  it("成对的代理项（emoji）是合法的，照常入账", async () => {
    const { shop, app, boss } = await setup();
    const o = upsertFull({ name: "可乐🥤" });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r.results).toEqual([{ id: o.id, status: "applied" }]);
    expect((await productsOf(shop.storeId))[0]!.name).toBe("可乐🥤");
  });
});

describe("S04-5 补充：barcode_link 挂单件码", () => {
  it("单位名一律写商品的基本单位，不看 payload 的 unit_name（不拒）；整件码照 payload", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ baseUnit: "罐" });
    const single = newBarcode();
    const pack = newBarcode();
    const r = await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [
        p,
        op("barcode_link", { barcode: single, product_id: p.payload.product_id, pack_qty: 1, unit_name: "瓶" }),
        op("barcode_link", { barcode: pack, product_id: p.payload.product_id, pack_qty: 24, unit_name: "箱" }),
        // 已挂着的单件码改单位名也一样
        op("barcode_link", { barcode: p.payload.barcode, product_id: p.payload.product_id, pack_qty: 1, unit_name: "听" }),
      ],
    });
    await app.close();
    expect(r.results.map((x: { status: string }) => x.status)).toEqual(["applied", "applied", "applied", "applied"]);
    const bs = new Map((await barcodesOf(shop.storeId)).map((b) => [b.barcode, b.unit_name]));
    expect(bs.get(single)).toBe("罐");
    expect(bs.get(p.payload.barcode as string)).toBe("罐");
    expect(bs.get(pack)).toBe("箱");
  });
});

// savepoint 兜底（§14 S04-13）：正常输入走不到（预检查已经拦住），所以在数据库里装一个触发器注入故障——
// 挂某个条码时按指定的 SQLSTATE 报错。product_upsert 先插商品（取一个号）、再插条码（再取一个号）时出错，
// 所以出错前这个 op 已经真的取过号、改过行。走真实请求，不改服务器代码。
describe("S04-13 savepoint 兜底（注入故障）", () => {
  beforeAll(async () => {
    await sql`CREATE TABLE fault_barcodes (barcode text PRIMARY KEY, sqlstate text NOT NULL)`.execute(tdb.kysely);
    await sql.raw(`
      CREATE FUNCTION inject_fault() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE s text;
      BEGIN
        SELECT sqlstate INTO s FROM fault_barcodes WHERE barcode = NEW.barcode;
        IF s IS NOT NULL THEN RAISE EXCEPTION '注入的故障 %', s USING ERRCODE = s; END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER inject_fault BEFORE INSERT OR UPDATE ON product_barcodes FOR EACH ROW EXECUTE FUNCTION inject_fault();
    `).execute(tdb.kysely);
  });

  const faulty = async (sqlstate: string) => {
    const barcode = newBarcode();
    await tdb.kysely.insertInto("fault_barcodes" as never).values({ barcode, sqlstate } as never).execute();
    return upsertFull({ barcode });
  };
  /** 本店所有带 rev 的行的号，排好序 */
  const revsOf = async (storeId: string) => {
    const all: number[] = [];
    for (const t of ["products", "product_barcodes", "removed"] as const) {
      const rows = await tdb.kysely.selectFrom(t).select("rev").where("store_id", "=", storeId).execute();
      all.push(...rows.map((r) => Number(r.rev)));
    }
    return all.sort((a, b) => a - b);
  };
  async function setupLogged() {
    const shop = await makeLoginShop(tdb);
    const lines: Array<Record<string, unknown>> = [];
    const app = buildApp({ config: testConfig(), db: tdb, clock: new TestClock().now, logStream: { write: (l) => void lines.push(JSON.parse(l)) } });
    const boss = await login(app, shop.username);
    return { shop, app, boss, lines };
  }

  it("22012：只有这个 op rejected invalid、不留档，它取的号和改的行一起回滚，同批其余照常；一批两次也一样；记 error 日志", async () => {
    const { shop, app, boss, lines } = await setupLogged();
    const a = upsertFull();
    const bad1 = await faulty("22012");
    const b = upsertFull();
    const bad2 = await faulty("22003");
    const c = upsertFull();
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [a, bad1, b, bad2, c], pull: false });
    expect(r.results).toEqual([
      { id: a.id, status: "applied" },
      { id: bad1.id, status: "rejected", code: "invalid" },
      { id: b.id, status: "applied" },
      { id: bad2.id, status: "rejected", code: "invalid" },
      { id: c.id, status: "applied" },
    ]);
    expect((await opsOf(shop.storeId)).map((o) => o.id).sort()).toEqual([a.id, b.id, c.id].sort());
    expect((await productsOf(shop.storeId)).map((p) => p.id).sort()).toEqual(
      [a, b, c].map((o) => o.payload.product_id as string).sort(),
    );
    // 号从 1 连续、没有空洞：坏 op 取过的号随 savepoint 回滚了
    const revs = await revsOf(shop.storeId);
    expect(revs).toEqual(Array.from({ length: revs.length }, (_, i) => i + 1));
    expect(await storeRev(shop.storeId)).toBe(String(revs.length));

    const logged = lines.filter((l) => l.msg === "sync：op 触发数据类错误，已单个拒收（savepoint 兜底）");
    expect(logged).toHaveLength(2);
    expect(logged.map((l) => [l.level, l.op_id, l.op_type, l.sqlstate])).toEqual([
      [50, bad1.id, "product_upsert", "22012"],
      [50, bad2.id, "product_upsert", "22003"],
    ]);
    // 日志里不带令牌
    expect(JSON.stringify(lines)).not.toContain(boss.token);

    // 重发：同样单个拒收、不留档（存不进去，每次都重新处理）
    const again = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [bad1], pull: false });
    await app.close();
    expect(again.results).toEqual([{ id: bad1.id, status: "rejected", code: "invalid" }]);
    expect(await opsOf(shop.storeId)).toHaveLength(3);
  });

  for (const sqlstate of ["23505", "40001", "XX000"]) {
    it(`不是数据类错误（${sqlstate}）：不吞掉，整个请求 500、整批回滚`, async () => {
      const { shop, app, boss, lines } = await setupLogged();
      await syncOk(app, boss.token, { epoch: shop.epoch, ops: [upsertFull()], pull: false });
      const revBefore = await storeRev(shop.storeId);
      const opsBefore = await opsOf(shop.storeId);
      const r = await sync(app, boss.token, { epoch: shop.epoch, ops: [upsertFull(), await faulty(sqlstate), upsertFull()], pull: false });
      await app.close();
      expect(r.status).toBe(500);
      expect(r.body).toEqual({ code: "unavailable" });
      expect(await storeRev(shop.storeId)).toBe(revBefore);
      expect(await opsOf(shop.storeId)).toEqual(opsBefore);
      expect(lines.some((l) => String(l.msg).includes("savepoint 兜底"))).toBe(false);
    });
  }
});

describe("请求体上限（§4.2，1 MiB）", () => {
  /** 非 ASCII 全转义成 \uXXXX：最坏的 JSON 写法（emoji 一个字 12 字节） */
  const asciiJson = (v: unknown) => JSON.stringify(v).replace(/[\u0080-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
  const emoji = (n: number) => "🥤".repeat(n);
  /** 最大的合法 op：200 行的卖出，每个字符串写满上限、全是 emoji */
  const biggestOp = () =>
    op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: 19_999_999_800,
      lines: Array.from({ length: 200 }, () => ({
        entry_id: randomUUID(),
        product_id: randomUUID(),
        barcode: emoji(64),
        name: emoji(200),
        unit_name: emoji(20),
        pack_qty: 9999,
        pack_count: 99999,
        unit_price_fen: 99_999_999,
      })),
    });

  it("最大的合法 op 用最坏的 JSON 写法也放得进一个请求：200，不是 413", async () => {
    const { shop, app, boss } = await setup();
    const big = biggestOp();
    expect(opSchemaValid(big)).toBe(true);
    // 最大的合法 op 不会被嵌套层数 / 节点数上限误伤（S04-13）
    expect(storable(big as IncomingOp)).toBe(true);
    const body = `{"epoch":"${shop.epoch}","cursors":{"catalog":0,"ledger":0},"app_build":1,"pull":false,"ops":[${asciiJson(big)}]}`;
    expect(Buffer.byteLength(body)).toBeGreaterThan(BODY_LIMIT / 2);
    expect(Buffer.byteLength(body)).toBeLessThan(BODY_LIMIT);
    const res = await app.inject({ method: "POST", url: "/v1/sync", headers: { ...bearer(boss.token), "content-type": "application/json" }, payload: body });
    await app.close();
    expect(res.statusCode).toBe(200);
    // 9999 × 99999 超出基本单位数量上限，应用时拒 invalid（留档）；这里只证明它能送达服务器
    expect(res.json().results).toEqual([{ id: big.id, status: "rejected", code: "invalid" }]);
  });

  it("超过 1 MiB：413 invalid（契约 Error），一个 op 都不处理", async () => {
    const { shop, app, boss } = await setup();
    const ops = [upsertFull(), biggestOp(), biggestOp()];
    const body = `{"epoch":"${shop.epoch}","cursors":{"catalog":0,"ledger":0},"app_build":1,"pull":false,"ops":[${ops.map(asciiJson).join(",")}]}`;
    expect(Buffer.byteLength(body)).toBeGreaterThan(BODY_LIMIT);
    const res = await app.inject({ method: "POST", url: "/v1/sync", headers: { ...bearer(boss.token), "content-type": "application/json" }, payload: body });
    await app.close();
    expect(res.statusCode).toBe(413);
    expect(res.json()).toMatchObject({ code: "invalid" });
    await expectContract("Error", res.json());
    expect(await opsOf(shop.storeId)).toEqual([]);
    expect(await storeRev(shop.storeId)).toBe("0");
  });
});
