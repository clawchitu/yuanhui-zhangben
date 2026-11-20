// S06：盘点（count）与待确认补全（product_review_complete）经 /v1/sync 写库（§5.2、§5.6 第 2 条，§14 S05-1、S05-9、R1）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop } from "./helpers/auth.ts";
import { op, syncOk, upsertFull } from "./helpers/sync.ts";

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
  return { shop, app, send, newProduct };
}
const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const stockIn = (pid: string, n: number, unit: number) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit });
const opening = (pid: string, counted_qty: number, extra: Record<string, unknown> = {}) => op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty, ...extra });
const count = (pid: string, counted_qty: number, base_ver: number, base_qty = 0) => op("count", { entry_id: randomUUID(), product_id: pid, counted_qty, base_qty, base_ver });
const review = (pid: string, counted_qty: number, unit_cost_fen: number, base_ver: number, extra: Record<string, unknown> = {}) =>
  op("product_review_complete", { entry_id: randomUUID(), product_id: pid, counted_qty, unit_cost_fen, base_ver, ...extra });
const sale = (pid: string, n: number, price = 300) =>
  op("sale_batch", {
    batch_id: randomUUID(),
    paid_total_fen: n * price,
    lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: n, unit_price_fen: price }],
  });
const ver = async (storeId: string, pid: string) => Number((await product(storeId, pid)).stock_ver);

describe("盘点 count", () => {
  it("账面 2 实数 1 → 盘亏 1 个，按平均进价（货值 250 / 2 → 125）；stock_ver + 1、写 last_count_at", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(stockIn(pid, 1, 100), stockIn(pid, 1, 150));
    const c = count(pid, 1, await ver(shop.storeId, pid), 2);
    expect(await send(c)).toEqual([{ id: c.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.stock_ver), p.last_count_at !== null]).toEqual([1, 125, 3, true]);
    const last = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([last.id, last.type, last.qty_delta, Number(last.cogs_fen), Number(last.value_delta_fen), last.cost_missing]).toEqual([c.payload.entry_id, "count", -1, 125, -125, false]);
    expect(await send(c)).toEqual([{ id: c.id, status: "applied", replayed: true }]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(1);
    await app.close();
  });

  it("并发盘点：A 看到 10（版本 n）→ B 卖 2 → A 交 10 被拒 stale 带回 8 → A 带新版本确认后库存 10、盘盈 2", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(stockIn(pid, 10, 100));
    const n = await ver(shop.storeId, pid);
    await send(sale(pid, 2));
    const a = count(pid, 10, n, 10);
    const r = await send(a);
    expect(r).toEqual([{ id: a.id, status: "rejected", code: "stale", current: { stock_qty: 8, stock_ver: n + 1 } }]);
    expect((await entriesOf(shop.storeId, pid)).filter((e) => e.type === "count")).toHaveLength(0);
    const a2 = count(pid, 10, n + 1, 8);
    expect(await send(a2)).toEqual([{ id: a2.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([10, 1000]);
    const last = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([last.type, last.qty_delta, Number(last.value_delta_fen), Number(last.cogs_fen)]).toEqual(["count", 2, 200, -200]);
    // 重放被拒的那条：仍是当初的 stale 结果（I8）
    expect((await send(a))[0]).toMatchObject({ status: "rejected", code: "stale", current: { stock_qty: 8 }, replayed: true });
    await app.close();
  });

  it("点「没错」（d = 0）也记一条全 0 的 count，不标 cost_missing（进价未知也一样）", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 3));
    await send(count(pid, 3, await ver(shop.storeId, pid), 3));
    const last = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([last.type, last.qty_delta, Number(last.value_delta_fen), last.cost_missing]).toEqual(["count", 0, 0, false]);
    expect(Number((await product(shop.storeId, pid)).stock_ver)).toBe(2);
    await app.close();
  });

  it("u ≠ c 的盘盈（S05-8）：库存 6、货值 24280、c = 4000，数到 8 → 盘盈 2 × 4047 = 8094", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 6, { unit_cost_fen: 4000 }));
    await send(stockIn(pid, 1, 280)); // 7 个、24280；c = 280
    await send(sale(pid, 1)); // cogs = roundDiv(24280, 7) = 3469 → 6 个、20811
    // 用 cost.json 的同一组：直接设出 q=6, v=24280, c=4000
    await tdb.kysely.updateTable("products").set({ stock_qty: 6, stock_value_fen: "24280", last_cost_fen: "4000" } as never).where("store_id", "=", shop.storeId).where("id", "=", pid).execute();
    await send(count(pid, 8, await ver(shop.storeId, pid), 6));
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen)]).toEqual([8, 24280 + 8094, 4000]);
    await app.close();
  });

  it("商品不存在 → rejected invalid 并留档", async () => {
    const { shop, app, send } = await setup();
    const c = count(randomUUID(), 1, 0);
    expect(await send(c)).toEqual([{ id: c.id, status: "rejected", code: "invalid" }]);
    const row = await tdb.kysely.selectFrom("ops").select("status").where("store_id", "=", shop.storeId).where("id", "=", c.id).executeTakeFirst();
    expect(row?.status).toBe("rejected");
    await app.close();
  });
});

describe("待确认补全 product_review_complete", () => {
  it("记 opening（不是 stock_in）、清 needs_review、一条 cost_fix，原卖出行 cogs_fen 不变", async () => {
    const { shop, app, send } = await setup();
    const pid = randomUUID();
    await send(sale(pid, 1, 250)); // 自动建待确认商品，cost_missing
    const before = (await entriesOf(shop.storeId, pid))[0]!;
    expect([before.type, Number(before.cogs_fen), before.cost_missing]).toEqual(["sale", 0, true]);
    expect((await product(shop.storeId, pid)).needs_review).toBe(true);
    const r = review(pid, 10, 200, await ver(shop.storeId, pid), { track_expiry: true });
    expect(await send(r)).toEqual([{ id: r.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.needs_review, p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known, p.track_expiry]).toEqual([false, 10, 2000, 200, true, true]);
    const es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => [e.type, e.qty_delta, Number(e.amount_fen), Number(e.cogs_fen), Number(e.value_delta_fen)])).toEqual([
      ["sale", -1, 250, 0, 0],
      ["opening", 11, 0, 0, 2000],
      ["cost_fix", 0, 250, 200, 0],
    ]);
    expect(es[1]!.id).toBe(r.payload.entry_id);
    expect(es[0]!.cost_fix_entry_id).toBe(es[2]!.id);
    expect(es.some((e) => e.type === "stock_in")).toBe(false);
    await app.close();
  });

  it("base_ver 过时 → stale 带回账面数，needs_review 不清", async () => {
    const { shop, app, send } = await setup();
    const pid = randomUUID();
    await send(sale(pid, 1));
    const r = review(pid, 5, 100, 0);
    expect(await send(r)).toEqual([{ id: r.id, status: "rejected", code: "stale", current: { stock_qty: -1, stock_ver: 1 } }]);
    expect((await product(shop.storeId, pid)).needs_review).toBe(true);
    await app.close();
  });

  it("S05-9：自动建的商品（卖价 0、没条码）走完 product_edit + barcode_link + product_review_complete", async () => {
    const { shop, app, send } = await setup();
    const pid = randomUUID();
    const s = op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: 4800,
      lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000099", name: "可乐整箱", unit_name: "箱", pack_qty: 24, pack_count: 1, unit_price_fen: 4800 }],
    });
    await send(s);
    expect(Number((await product(shop.storeId, pid)).price_fen)).toBe(0);
    const edit = op("product_edit", { product_id: pid, price_fen: 250 });
    const link = op("barcode_link", { barcode: "6900000000100", product_id: pid, pack_qty: 1, unit_name: "罐" });
    const r = review(pid, 48, 200, await ver(shop.storeId, pid));
    expect((await send(edit, link, r)).map((x: { status: string }) => x.status)).toEqual(["applied", "applied", "applied"]);
    const p = await product(shop.storeId, pid);
    expect([Number(p.price_fen), p.needs_review, p.stock_qty, Number(p.stock_value_fen)]).toEqual([250, false, 48, 9600]);
    const bc = await tdb.kysely.selectFrom("product_barcodes").select("product_id").where("store_id", "=", shop.storeId).where("barcode", "=", "6900000000100").executeTakeFirst();
    expect(bc?.product_id).toBe(pid);
    const fix = (await entriesOf(shop.storeId, pid)).find((e) => e.type === "cost_fix")!;
    expect([Number(fix.amount_fen), Number(fix.cogs_fen)]).toEqual([4800, 24 * 200]);
    await app.close();
  });
});
