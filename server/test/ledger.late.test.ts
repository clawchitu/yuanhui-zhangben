// S06：迟到流水补偿（§5.6 第 4 条）。影响库存的 op 入账时 occurred_at 早于商品的 last_count_at：
// 流水照记（收入、成本照记），另追加一条 count 补偿行（flags.late_before_count）抵消它对数量和货值的影响，库存保持盘点数。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { op, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";
import { assertDbLedger } from "./helpers/ledger.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

// 服务器时钟 02:00；盘点 01:30，迟到的流水 01:00，盘点之后的 01:45
const T_LATE = "2026-11-20T01:00:00Z";
const T_COUNT = "2026-11-20T01:30:00Z";
const T_AFTER = "2026-11-20T01:45:00Z";

async function setup() {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb);
  const boss = await login(app, shop.username);
  const send = async (...ops: ReturnType<typeof op>[]) => (await syncOk(app, boss.token, { epoch: shop.epoch, ops, pull: false })).results;
  const newProduct = async () => {
    const u = upsertFull({ price: 300 });
    await send(u);
    return u.payload.product_id as string;
  };
  return { shop, app, boss, send, newProduct };
}
const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const ver = async (storeId: string, pid: string) => Number((await product(storeId, pid)).stock_ver);
const stockIn = (pid: string, n: number, unit: number, at = T_AFTER) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit }, { at });
const count = (pid: string, counted_qty: number, base_ver: number, at = T_COUNT) =>
  op("count", { entry_id: randomUUID(), product_id: pid, counted_qty, base_qty: 0, base_ver }, { at });
const sale = (pid: string, n: number, at: string, price = 300) =>
  op("sale_batch", {
    batch_id: randomUUID(),
    paid_total_fen: n * price,
    lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: n, unit_price_fen: price }],
  }, { at });
const late = (e: { flags: unknown }) => (e.flags as Record<string, unknown>).late_before_count === true;
const row = (e: { type: string; qty_delta: number; value_delta_fen: string; cogs_fen: string; cost_missing: boolean }) =>
  [e.type, e.qty_delta, Number(e.value_delta_fen), Number(e.cogs_fen), e.cost_missing];

describe("迟到流水补偿（§5.6 第 4 条）", () => {
  it("B 盘点前离线卖了 2 个、盘点（数到 8）后才传上来 → 卖出照记，补偿 count +2，库存仍是 8，盘亏净减 2 个", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(stockIn(pid, 10, 100, T_LATE));
    await send(count(pid, 8, await ver(shop.storeId, pid)));
    let p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([8, 800]);
    const s = sale(pid, 2, T_LATE);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known]).toEqual([8, 800, 100, true]);
    const es = await entriesOf(shop.storeId, pid);
    const [sl, comp] = es.slice(-2);
    // 卖出照记：实收 600、进价 2 × 100
    expect([sl!.type, sl!.qty_delta, Number(sl!.amount_fen), Number(sl!.cogs_fen), late(sl!)]).toEqual(["sale", -2, 600, 200, false]);
    // 补偿：count 行抵消卖出对数量、货值的影响（盘盈记法 cogs = −value_delta），和卖出同一个 op、seq 相邻
    expect(row(comp!)).toEqual(["count", 2, 200, -200, false]);
    expect([late(comp!), comp!.op_id, Number(comp!.seq), comp!.occurred_at.toISOString()]).toEqual([true, sl!.op_id, Number(sl!.seq) + 1, new Date(T_LATE).toISOString()]);
    // 盘点少了的：原来 −2 个 / −200，补偿后净 0（被这笔卖出解释）
    const counts = es.filter((e) => e.type === "count");
    expect([counts.reduce((x, e) => x + e.qty_delta, 0), counts.reduce((x, e) => x + Number(e.value_delta_fen), 0)]).toEqual([0, 0]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    // 重放：结果相同、不再补偿（I5、I8）
    expect(await send(s)).toEqual([{ id: s.id, status: "applied", replayed: true }]);
    expect(await entriesOf(shop.storeId, pid)).toHaveLength(es.length);
    await app.close();
  });

  it("盘点之后发生的（occurred_at 不早于 last_count_at）不补偿；同一时刻也不补偿", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(stockIn(pid, 10, 100, T_LATE));
    await send(count(pid, 10, await ver(shop.storeId, pid)));
    await send(sale(pid, 1, T_AFTER), sale(pid, 1, T_COUNT));
    const es = await entriesOf(shop.storeId, pid);
    expect(es.filter(late)).toEqual([]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(8);
    await app.close();
  });

  it("迟到的进货让进价从没填变已知、库存为负：补偿后按 v = q × c 归位（I3），补偿行和归位行都标 late_before_count", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    // 期初 0 个没填进价（01:30），之后卖 2 个 → q = −2、k 假
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 0 }, { at: T_COUNT }));
    await send(sale(pid, 2, T_AFTER));
    // 盘点前进的 5 个 × 100 迟到：进货照记（目标货值 300 的 cost_adjust、成本补记），再整体抵消，q 回到 −2，归位到 −2 × 100
    await send(stockIn(pid, 5, 100, T_LATE));
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known]).toEqual([-2, -200, 100, true]);
    const es = await entriesOf(shop.storeId, pid);
    const tail = es.slice(es.findIndex((e) => e.type === "stock_in"));
    expect(tail.map((e) => [e.type, late(e)])).toEqual([
      ["stock_in", false],
      ["cost_adjust", false],
      ["cost_fix", false],
      ["count", true],
      ["cost_adjust", true],
    ]);
    expect(row(tail[3]!)).toEqual(["count", -5, -300, 300, false]);
    expect(Number(tail[4]!.value_delta_fen)).toBe(-200);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("进价没填时补偿行只改数量、金额 0、标 cost_missing（同数量有变化的盘点）", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 5 }, { at: T_COUNT }));
    await send(sale(pid, 1, T_LATE));
    const comp = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([...row(comp), late(comp)]).toEqual(["count", 1, 0, 0, true, true]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(5);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("盘点前做的撤销迟到：冲销照记，补偿行抵消加回的数量和货值", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(stockIn(pid, 10, 100, T_LATE));
    const s = sale(pid, 2, T_LATE);
    await send(s);
    await send(count(pid, 8, await ver(shop.storeId, pid)));
    await send(op("void", { target: { batch_id: s.payload.batch_id } }, { at: "2026-11-20T01:10:00Z" }));
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([8, 800]);
    const comp = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([...row(comp), late(comp)]).toEqual(["count", -2, -200, 200, false, true]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("收银员的迟到卖出：补偿 count 行挂在收银员名下，收银员撤它被拒 forbidden；收银员拉不到它，家用能拉到", async () => {
    const { shop, app, boss, send, newProduct } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    const pid = await newProduct();
    await send(stockIn(pid, 10, 100, T_LATE));
    await send(count(pid, 8, await ver(shop.storeId, pid)));
    await syncOk(app, cas.token, { epoch: shop.epoch, ops: [sale(pid, 2, T_LATE)], pull: false });
    const comp = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([comp.type, late(comp), comp.device_id]).toEqual(["count", true, cas.deviceId]);
    const v = op("void", { target: { entry_id: comp.id } }, { at: T_AFTER });
    expect((await syncOk(app, cas.token, { epoch: shop.epoch, ops: [v], pull: false })).results).toEqual([{ id: v.id, status: "rejected", code: "forbidden" }]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(8);
    const cashierSnap = (await pullAll(app, cas.token, shop.epoch)).snapshot();
    expect(cashierSnap.entries.map((e: { type: string }) => e.type)).toEqual(["sale"]);
    const famSnap = (await pullAll(app, boss.token, shop.epoch)).snapshot();
    expect(famSnap.entries.some((e: { id: string }) => e.id === comp.id)).toBe(true);
    await app.close();
  });
});
