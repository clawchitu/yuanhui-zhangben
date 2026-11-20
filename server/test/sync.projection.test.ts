// S04：按角色裁剪（§4.2、§3.4、§6）。收银员的响应里被裁的键不出现（不是置空）；收银员只能 quick 登记。
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { insertSale, insertStockIn } from "./helpers/ledger.ts";
import { allKeys, newBarcode, op, pullAll, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

/** 收银员响应里不许出现的键（§3.4 product_private、§4.2） */
const FORBIDDEN_KEY = /cost|value|stock|low_at|private|cogs|expiry_warn|shelf_life|last_count|qty_left|qty_in|handle_ver|snooze|lot_id/i;
/** 服务器时间：上海 2026-11-20 10:00 */
const NOW = Date.parse("2026-11-20T02:00:00Z");

async function richShop() {
  const clock = new TestClock(NOW);
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const cas = await pair(app, boss.token, "cashier", "小王");
  const p = upsertFull({ name: "可乐", price: 300, extra: { low_at: 5, track_expiry: true, expiry_warn_days: 14, shelf_life_months: 12 } });
  const pid = p.payload.product_id as string;
  await syncOk(app, boss.token, {
    epoch: shop.epoch,
    ops: [p, op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 24, unit_name: "箱", pack_price_fen: 6500 })],
  });
  // 模拟已经进过货：库存、货值、进价都有值（S05 才有记账引擎，这里直接写投影）
  await tdb.kysely
    .updateTable("products")
    .set({ stock_qty: 22, stock_value_fen: "4400", cost_known: true, last_cost_fen: "200", stock_ver: "3", last_count_at: new Date(NOW - 86_400_000) })
    .where("store_id", "=", shop.storeId)
    .execute();
  await insertStockIn(tdb.kysely, { storeId: shop.storeId, deviceId: boss.deviceId, productId: pid, at: new Date(NOW - 3600_000) });
  const at = (iso: string) => new Date(iso);
  const sales = {
    // 收银员本机：今天、昨天（上海）、前天（上海 11-18 23:00）
    casToday: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: cas.deviceId, productIds: [pid], at: at("2026-11-20T01:00:00Z") }),
    casYesterday: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: cas.deviceId, productIds: [pid], at: at("2026-11-18T16:00:00Z") }),
    casOld: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: cas.deviceId, productIds: [pid], at: at("2026-11-18T15:00:00Z") }),
    // 别的手机：今天
    bossToday: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: boss.deviceId, productIds: [pid, pid], at: at("2026-11-20T01:30:00Z") }),
    // 家用手机本地只留 35 天（§3.4）：30 天前的下发，40 天前的不下发
    boss30: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: boss.deviceId, productIds: [pid], at: new Date(NOW - 30 * 86_400_000) }),
    boss40: await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: boss.deviceId, productIds: [pid], at: new Date(NOW - 40 * 86_400_000) }),
  };
  return { clock, shop, app, boss, cas, pid, sales };
}

describe("收银员的拉取响应", () => {
  it("递归遍历整个响应：没有任何成本 / 货值 / 库存 / low_at / 批次相关的键；没有 lots、进货流水、别的手机的流水", async () => {
    const { shop, app, boss, cas, pid, sales } = await richShop();
    const bodies: unknown[] = [];
    const phone = await pullAll(app, cas.token, shop.epoch);
    // 再用页大小 1 拉一遍，把每一页都收集起来检查
    const small = makeApp(tdb, { clock: new TestClock(NOW), syncPageSize: 1 });
    let cursors = { catalog: 0, ledger: 0 };
    for (;;) {
      const b = await syncOk(small, cas.token, { epoch: shop.epoch, cursors });
      bodies.push(b);
      cursors = b.cursors;
      if (!b.has_more.catalog && !b.has_more.ledger) break;
    }
    await small.close();
    const family = await pullAll(app, boss.token, shop.epoch);
    await app.close();

    const keys = new Set<string>();
    for (const b of bodies) allKeys(b, keys);
    const bad = [...keys].filter((k) => FORBIDDEN_KEY.test(k));
    expect(bad).toEqual([]);
    expect(bodies.length).toBeGreaterThanOrEqual(4);

    const snap = phone.snapshot();
    expect(snap.lots).toEqual([]);
    expect(Object.keys(snap.products[0]).sort()).toEqual(["archived", "base_unit", "id", "image_ver", "name", "needs_review", "price_fen", "rev", "track_expiry"]);
    expect(snap.products[0]).toMatchObject({ id: pid, price_fen: 300, track_expiry: true });
    // 只有本机最近 2 天（上海时区的今天和昨天）的卖出
    expect(snap.entries.map((e: { id: string }) => e.id).sort()).toEqual([...sales.casToday.entryIds, ...sales.casYesterday.entryIds].sort());
    expect(snap.entries.every((e: { type: string; device_id: string }) => e.type === "sale" && e.device_id === cas.deviceId)).toBe(true);
    expect(snap.batches.map((b: { id: string }) => b.id).sort()).toEqual([sales.casToday.batchId, sales.casYesterday.batchId].sort());
    // 整件码的价是卖价，收银员要用，照发
    expect(snap.barcodes.find((b: { pack_qty: number }) => b.pack_qty === 24)).toMatchObject({ pack_price_fen: 6500 });

    // 对照：家用拿得到这些字段
    const fp = family.products.get(pid);
    expect(fp.private).toEqual({
      stock_qty: 22,
      stock_value_fen: 4400,
      last_cost_fen: 200,
      cost_known: true,
      stock_ver: 3,
      low_at: 5,
      expiry_warn_days: 14,
      shelf_life_months: 12,
      last_count_at: new Date(NOW - 86_400_000).toISOString(),
    });
    expect(family.snapshot().lots).toHaveLength(1);
    const fe = family.snapshot().entries;
    expect(fe.find((e: { type: string }) => e.type === "stock_in")).toMatchObject({ unit_cost_fen: 4800, value_delta_fen: 4800, cogs_fen: 0, cost_missing: false });
    // 家用：全店 35 天内
    const ids = new Set(fe.map((e: { id: string }) => e.id));
    for (const s of [sales.casToday, sales.casYesterday, sales.casOld, sales.bossToday, sales.boss30]) for (const id of s.entryIds) expect(ids.has(id)).toBe(true);
    for (const id of sales.boss40.entryIds) expect(ids.has(id)).toBe(false);
    expect(family.batches.has(sales.boss40.batchId)).toBe(false);
    expect(fe.find((e: { device_id: string }) => e.device_id === cas.deviceId)).toMatchObject({ device_label: "小王" });
  });

  it("收银员的流水被家用手机撤销后（打 voided_at、rev 变大），收银员下次拉取能收到", async () => {
    const { shop, app, cas, sales } = await richShop();
    const phone = await pullAll(app, cas.token, shop.epoch);
    const eid = sales.casToday.entryIds[0]!;
    expect(phone.entries.get(eid).voided_at).toBeNull();
    const { withStoreLock } = await import("../src/sync/lock.ts");
    await withStoreLock(tdb.kysely, shop.storeId, async (tx) => {
      await tx.trx
        .updateTable("entries")
        .set({ voided_at: new Date(NOW), rev: String(await tx.nextRev()) })
        .where("store_id", "=", shop.storeId)
        .where("id", "=", eid)
        .execute();
    });
    await pullAll(app, cas.token, shop.epoch, phone);
    await app.close();
    expect(phone.entries.get(eid).voided_at).toBe(new Date(NOW).toISOString());
  });
});

describe("收银员的墓碑按角色过滤（§14 S04 待办、S05-5）", () => {
  it("收银员只收条码 / 别名墓碑和本机卖出流水、批次头的墓碑；不收 lot、别机的、进货的、找不到原行的；家用全收", async () => {
    const { shop, app, boss, cas, pid, sales } = await richShop();
    const si = await insertStockIn(tdb.kysely, { storeId: shop.storeId, deviceId: boss.deviceId, productId: pid, at: new Date(NOW - 1800_000) });
    const { randomUUID } = await import("node:crypto");
    const { withStoreLock } = await import("../src/sync/lock.ts");
    const tomb = {
      barcode: ["barcode", "6900000000999"],
      alias: ["product_alias", randomUUID()],
      ownEntry: ["entry", sales.casToday.entryIds[0]!],
      ownOldEntry: ["entry", sales.casOld.entryIds[0]!],
      ownBatch: ["batch", sales.casToday.batchId],
      otherEntry: ["entry", sales.bossToday.entryIds[0]!],
      otherBatch: ["batch", sales.bossToday.batchId],
      stockInEntry: ["entry", si.entryId],
      lot: ["lot", si.lotId],
      goneEntry: ["entry", randomUUID()],
      goneBatch: ["batch", randomUUID()],
    } as const;
    await withStoreLock(tdb.kysely, shop.storeId, async (tx) => {
      for (const [kind, row_id] of Object.values(tomb))
        await tx.trx.insertInto("removed").values({ store_id: shop.storeId, kind, row_id, rev: String(await tx.nextRev()) }).execute();
    });
    const got = async (token: string) => {
      const out: string[] = [];
      let cursors = { catalog: 0, ledger: 0 };
      for (;;) {
        const b = await syncOk(app, token, { epoch: shop.epoch, cursors });
        for (const r of b.changes.removed as Array<{ kind: string; row_id: string }>) out.push(`${r.kind}:${r.row_id}`);
        cursors = b.cursors;
        if (!b.has_more.catalog && !b.has_more.ledger) return out.sort();
      }
    };
    const key = (t: readonly [string, string]) => `${t[0]}:${t[1]}`;
    expect(await got(cas.token)).toEqual([tomb.barcode, tomb.alias, tomb.ownEntry, tomb.ownOldEntry, tomb.ownBatch].map(key).sort());
    expect(await got(boss.token)).toEqual(Object.values(tomb).map(key).sort());
    await app.close();
  });
});

describe("收银员推 op", () => {
  it("带进价或任何家用字段的登记被拒 forbidden；只有名称和卖价的 quick 登记成功且 needs_review=true", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const bad = [
      upsertQuick({ extra: { unit_cost_fen: 200 } }),
      upsertQuick({ extra: { base_unit: "瓶" } }),
      upsertQuick({ extra: { low_at: 3 } }),
      upsertQuick({ extra: { track_expiry: true } }),
      upsertFull(),
      upsertFull({ extra: { unit_cost_fen: 200 } }),
    ];
    const good = upsertQuick({ name: "瓜子", price: 800 });
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [...bad, good] });
    await app.close();
    expect(r.results.slice(0, bad.length)).toEqual(bad.map((o) => ({ id: o.id, status: "rejected", code: "forbidden" })));
    expect(r.results[bad.length]).toEqual({ id: good.id, status: "applied" });
    const ps = await tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", shop.storeId).execute();
    expect(ps.map((p) => [p.name, p.needs_review])).toEqual([["瓜子", true]]);
    // 新登记的商品在同一个响应里就拉回来了
    expect(r.changes.products.map((p: { id: string; needs_review: boolean }) => [p.id, p.needs_review])).toEqual([[good.payload.product_id, true]]);
  });

  it("收银员发 product_edit / barcode_link / barcode_unlink（真实请求）：forbidden，什么都不改", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const p = upsertFull({ name: "原名", price: 300 });
    const pid = p.payload.product_id as string;
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p] });
    const before = await tdb.kysely.selectFrom("product_barcodes").selectAll().where("store_id", "=", shop.storeId).execute();
    const ops = [
      op("product_edit", { product_id: pid, price_fen: 1 }),
      op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 24, unit_name: "箱" }),
      op("barcode_unlink", { barcode: p.payload.barcode, product_id: pid }),
    ];
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops });
    await app.close();
    expect(r.results).toEqual(ops.map((o) => ({ id: o.id, status: "rejected", code: "forbidden" })));
    expect((await tdb.kysely.selectFrom("products").select("price_fen").where("store_id", "=", shop.storeId).executeTakeFirstOrThrow()).price_fen).toBe("300");
    expect(await tdb.kysely.selectFrom("product_barcodes").selectAll().where("store_id", "=", shop.storeId).execute()).toEqual(before);
  });

  it("演示店的审核号：完整登记、改商品都能做，拉取是全店（带 private）", async () => {
    const shop = await makeLoginShop(tdb, { demo: true });
    const app = makeApp(tdb);
    const rev = await login(app, shop.username);
    const p = upsertFull({ extra: { low_at: 4 } });
    const r = await syncOk(app, rev.token, {
      epoch: shop.epoch,
      ops: [p, op("product_edit", { product_id: p.payload.product_id, price_fen: 999 })],
    });
    await app.close();
    expect(r.results.map((x: { status: string }) => x.status)).toEqual(["applied", "applied"]);
    expect(r.changes.products[0]).toMatchObject({ price_fen: 999, private: { low_at: 4 } });
  });
});
