// S04 返修（PR #10 的 Codex / Fable 审核）：每条都是先在旧代码上失败的回归测试。
// - S04-2：注销期间整批不应用、results 为空、响应带 delete_pending_until
// - S04-8：按店排队上限，超过 503 unavailable
// - S04-10：product_upsert 的商品 id 已存在时不挂码（堵收银员绕过 barcode_link 权限）
// - S04-13：存不进库 / 算不了哈希的 op 单个 rejected invalid、不留档，绝不 500
// - S04-5 补充：barcode_link 挂单件码时单位名一律写商品的基本单位
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { newBarcode, op, sync, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";
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
