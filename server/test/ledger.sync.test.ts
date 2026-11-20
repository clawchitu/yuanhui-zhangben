// S05b 第 (1) 步：sale_batch / stock_in / opening 经 /v1/sync 写库（§5.1、§5.2、§5.6，§14 S05-1…S05-4）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop } from "./helpers/auth.ts";
import { expectContract, op, syncOk, upsertFull } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

async function setup() {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb);
  const boss = await login(app, shop.username);
  const send = async (...ops: ReturnType<typeof op>[]) => (await syncOk(app, boss.token, { epoch: shop.epoch, ops, pull: false })).results;
  const newProduct = async (price = 300) => {
    const u = upsertFull({ price });
    await send(u);
    return u.payload.product_id as string;
  };
  return { shop, app, boss, send, newProduct };
}
const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const opRow = (storeId: string, id: string) => tdb.kysely.selectFrom("ops").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirst();
const stockIn = (pid: string, pack_qty: number, pack_count: number, unit_cost_fen: number, extra: Record<string, unknown> = {}) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty, pack_count, unit_cost_fen, ...extra });
const opening = (pid: string, counted_qty: number, extra: Record<string, unknown> = {}) => op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty, ...extra });
const saleOf = (paid: number, lines: Array<{ pid: string; price: number; count?: number; packQty?: number }>) =>
  op("sale_batch", {
    batch_id: randomUUID(),
    paid_total_fen: paid,
    lines: lines.map((l) => ({ entry_id: randomUUID(), product_id: l.pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: l.packQty ?? 1, pack_count: l.count ?? 1, unit_price_fen: l.price })),
  });

describe("进货写库", () => {
  it("可乐 5 箱 × ¥48（1 箱 = 24 罐）：入账 120 罐、货值 24000、每罐 200；stock_ver + 1；重放 replayed、库里不变", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    const si = stockIn(pid, 24, 5, 4800, { expiry_date: "2027-03-01" });
    expect(await send(si)).toEqual([{ id: si.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known, Number(p.stock_ver)]).toEqual([120, 24000, 200, true, 1]);
    const es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => [e.type, e.qty_delta, Number(e.amount_fen), Number(e.unit_cost_fen), Number(e.value_delta_fen), e.expiry_date])).toEqual([["stock_in", 120, 24000, 4800, 24000, "2027-03-01"]]);
    expect(await send(si)).toEqual([{ id: si.id, status: "applied", replayed: true }]);
    expect((await entriesOf(shop.storeId, pid)).length).toBe(1);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(120);
    await app.close();
  });

  it("进货 0 件（S05-3）、年份 0000 的 expiry_date（S05-4）：rejected invalid 并留档，什么都不记", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    const zero = stockIn(pid, 1, 0, 100);
    const y0 = stockIn(pid, 1, 1, 100, { expiry_date: "0000-01-01" });
    const over = stockIn(pid, 1, 2, 50_000_000);
    expect(await send(zero, y0, over)).toEqual([zero, y0, over].map((o) => ({ id: o.id, status: "rejected", code: "invalid" })));
    for (const o of [zero, y0, over]) expect(await opRow(shop.storeId, o.id)).toMatchObject({ status: "rejected", reject_code: "invalid" });
    expect(await entriesOf(shop.storeId, pid)).toEqual([]);
    expect(Number((await product(shop.storeId, pid)).stock_ver)).toBe(0);
    await app.close();
  });

  it("stock_qty 溢出 integer（S05-4 第二层）：拒 invalid 并留档，不产生 500", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await tdb.kysely.updateTable("products").set({ stock_qty: 2 ** 31 - 100, stock_value_fen: "0", cost_known: true, last_cost_fen: "0" }).where("id", "=", pid).execute();
    const o = stockIn(pid, 1, 1000, 0);
    expect(await send(o)).toEqual([{ id: o.id, status: "rejected", code: "invalid" }]);
    expect(await opRow(shop.storeId, o.id)).toMatchObject({ status: "rejected" });
    await app.close();
  });
});

describe("卖出写库", () => {
  it("抹零 53.50 收 53.00 → 各行 24.76 / 23.78 / 4.46，批次 paid 5300、list 5350（I4）；L = 0 而 P ≠ 0 被拒", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pids = [await newProduct(2500), await newProduct(2400), await newProduct(450)];
    const s = saleOf(5300, [{ pid: pids[0]!, price: 2500 }, { pid: pids[1]!, price: 2400 }, { pid: pids[2]!, price: 450 }]);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    const amounts = [];
    for (const pid of pids) amounts.push(...(await entriesOf(shop.storeId, pid)).map((e) => Number(e.amount_fen)));
    expect(amounts).toEqual([2476, 2378, 446]);
    const b = await tdb.kysely.selectFrom("sale_batches").selectAll().where("store_id", "=", shop.storeId).where("id", "=", (s.payload as { batch_id: string }).batch_id).executeTakeFirstOrThrow();
    expect([Number(b.paid_total_fen), Number(b.list_total_fen)]).toEqual([5300, 5350]);
    const zeroBasket = saleOf(100, [{ pid: pids[0]!, price: 0 }]);
    expect(await send(zeroBasket)).toEqual([{ id: zeroBasket.id, status: "rejected", code: "invalid" }]);
    await app.close();
  });

  it("进价未知的正库存卖出 → cost_missing、cogs 0；进货让进价变已知 → 当场一条 cost_fix，原行写 cost_fix_entry_id（S05-1）", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 10));
    const s = saleOf(300, [{ pid, price: 300 }]);
    await send(s);
    let es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => [e.type, e.cost_missing, Number(e.cogs_fen)])).toEqual([["opening", false, 0], ["sale", true, 0]]);
    await send(stockIn(pid, 1, 1, 200));
    es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => e.type)).toEqual(["opening", "sale", "stock_in", "cost_adjust", "cost_fix"]);
    const fix = es[4]!;
    expect([Number(fix.amount_fen), Number(fix.cogs_fen), Number(fix.unit_cost_fen)]).toEqual([300, 200, 200]);
    expect(es[1]!.cost_fix_entry_id).toBe(fix.id);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([10, 2000]);
    await app.close();
  });

  it("明确零成本：期初进价 0 后卖出不标 cost_missing；未知商品的卖出自动建待确认商品，不丢账；库存可以变负", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 1, { unit_cost_fen: 0 }));
    await send(saleOf(600, [{ pid, price: 300, count: 2 }]));
    const es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => [e.type, e.cost_missing, Number(e.unit_cost_fen ?? -1)])).toEqual([["opening", false, 0], ["sale", false, -1]]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(-1);
    const ghost = randomUUID();
    const s = saleOf(300, [{ pid: ghost, price: 300 }]);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    expect(await product(shop.storeId, ghost)).toMatchObject({ needs_review: true, stock_qty: -1, price_fen: "300" });
    await app.close();
  });
});

describe("期初的版本校验（S05-2）", () => {
  it("不带 base_ver 只在 stock_ver = 0 时接受，否则 stale 带回账面数；带对的 base_ver 成功并写 last_count_at", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 5, { unit_cost_fen: 100 }));
    const again = opening(pid, 7);
    expect(await send(again)).toEqual([{ id: again.id, status: "rejected", code: "stale", current: { stock_qty: 5, stock_ver: 1 } }]);
    const wrong = opening(pid, 7, { base_ver: 0 });
    expect((await send(wrong))[0]).toMatchObject({ status: "rejected", code: "stale" });
    const ok = opening(pid, 7, { base_ver: 1, unit_cost_fen: 100 });
    expect(await send(ok)).toEqual([{ id: ok.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_ver), p.last_count_at !== null]).toEqual([7, 2, true]);
    await app.close();
  });

  it("账上库存为负时期初被拒：stale 的 current.stock_qty 是负数，响应符合 openapi（Qty 允许负数）", async () => {
    const { shop, app, boss, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(saleOf(900, [{ pid, price: 300, count: 3 }]));
    expect((await product(shop.storeId, pid)).stock_qty).toBe(-3);
    const o = opening(pid, 4);
    const body = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o], pull: false });
    await app.close();
    expect(body.results).toEqual([{ id: o.id, status: "rejected", code: "stale", current: { stock_qty: -3, stock_ver: 1 } }]);
    await expectContract("SyncResponse", body);
    await expectContract("OpResult", body.results[0]);
  });
});
