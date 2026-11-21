// S06：迟到流水补偿（§5.6 第 4 条）。影响库存的 op 入账时 occurred_at 早于商品的 last_count_at：
// 流水照记（收入、成本照记），另追加一条 count 补偿行（flags.late_before_count）抵消它对数量和货值的影响，库存保持盘点数。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
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
  // 冻结服务器时钟（TestClock 默认 2026-11-20T02:00Z）：流水时间写死在 11-20，用真实时钟的话一过上海 11-22 零点，
  // 收银员拉取的 2 天窗口（§4.2）就把这些卖出排除在外，测试随日期失效
  const app = makeApp(tdb, { clock: new TestClock() });
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

  it("被补偿的迟到卖出不扣批次、不写 lot_moves：批次 10 → 盘亏 8 → 迟到卖 2 后仍是 8（PR #16 Fable 2，裁定 S06-10）", async () => {
    const { shop, app, send } = await setup();
    const u = upsertFull({ price: 300, extra: { track_expiry: true, expiry_warn_days: 7 } });
    await send(u);
    const pid = u.payload.product_id as string;
    await send(op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 10, unit_cost_fen: 100, expiry_date: "2026-12-01" }, { at: T_LATE }));
    await send(count(pid, 8, await ver(shop.storeId, pid)));
    const lots = () => tdb.kysely.selectFrom("stock_lots").selectAll().where("store_id", "=", shop.storeId).where("product_id", "=", pid).execute();
    expect((await lots()).map((l) => l.qty_left)).toEqual([8]);
    const s = sale(pid, 2, T_LATE);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(8);
    expect((await lots()).map((l) => [l.qty_left, l.handle_ver])).toEqual([[8, 0]]);
    const saleId = ((s.payload.lines as Array<{ entry_id: string }>)[0]!).entry_id;
    const moves = await tdb.kysely.selectFrom("lot_moves").selectAll().where("store_id", "=", shop.storeId).where("entry_id", "=", saleId).execute();
    expect(moves).toEqual([]);
    // 盘点之后的卖出照常扣批次
    await send(sale(pid, 1, T_AFTER));
    expect((await lots()).map((l) => l.qty_left)).toEqual([7]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
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

  it("迟到的进货让进价从没填变已知、库存为正：补偿后货值归位到 q × c，之后卖出按进价记成本（PR #16 Fable 1，裁定 S06-8）", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    // 没填进价的期初 5 个（01:30）→ 迟到的进货 5 × 100（01:00）
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 5 }, { at: T_COUNT }));
    await send(stockIn(pid, 5, 100, T_LATE));
    let p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known]).toEqual([5, 500, 100, true]);
    const es = await entriesOf(shop.storeId, pid);
    const tail = es.slice(es.findIndex((e) => e.type === "stock_in"));
    // 进货 +5 / +500 → 进价补上时的 cost_adjust（10 × 100 − 500 = +500）→ 补偿 −5 / −1000 → 归位 +500（标 late）
    expect(tail.map((e) => [e.type, e.qty_delta, Number(e.value_delta_fen), late(e)])).toEqual([
      ["stock_in", 5, 500, false],
      ["cost_adjust", 0, 500, false],
      ["count", -5, -1000, true],
      ["cost_adjust", 0, 500, true],
    ]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    // 之后卖 2 个：cogs = 200，不标 cost_missing
    await send(sale(pid, 2, T_AFTER));
    const sl = (await entriesOf(shop.storeId, pid)).at(-1)!;
    expect([sl.type, Number(sl.cogs_fen), sl.cost_missing]).toEqual(["sale", 200, false]);
    p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([3, 300]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  for (const kind of ["count", "opening"] as const) {
    it(`last_count_at 只往后走：01:30 盘点之后，版本对、occurred_at 更早（01:00）的${kind === "count" ? "盘点" : "期初"}入账不把它拉回去；之后 01:15 的卖出仍被补偿（PR #16 Fable 3，S06-11）`, async () => {
      const { shop, app, send, newProduct } = await setup();
      const pid = await newProduct();
      await send(stockIn(pid, 10, 100, "2026-11-20T00:30:00Z"));
      await send(count(pid, 10, await ver(shop.storeId, pid)));
      const at = new Date(T_COUNT).toISOString();
      expect((await product(shop.storeId, pid)).last_count_at?.toISOString()).toBe(at);
      const v = await ver(shop.storeId, pid);
      const early =
        kind === "count"
          ? count(pid, 9, v, T_LATE)
          : op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 9, unit_cost_fen: 100, base_ver: v }, { at: T_LATE });
      expect(await send(early)).toEqual([{ id: early.id, status: "applied" }]);
      expect((await product(shop.storeId, pid)).last_count_at?.toISOString()).toBe(at);
      await send(sale(pid, 1, "2026-11-20T01:15:00Z"));
      const comp = (await entriesOf(shop.storeId, pid)).at(-1)!;
      expect([comp.type, late(comp)]).toEqual(["count", true]);
      expect((await product(shop.storeId, pid)).stock_qty).toBe(9);
      await assertDbLedger(tdb.kysely, shop.storeId, pid);
      await app.close();
    });
  }

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

/** 把 total 个基本单位拆成合法的行（每行 pack_qty ≤ 9999、pack_count ≤ 99999、乘积 ≤ 9,999,999） */
function split(total: number): Array<{ pack_qty: number; pack_count: number }> {
  const out: Array<{ pack_qty: number; pack_count: number }> = [];
  let left = total;
  while (left >= 9_999_000) {
    out.push({ pack_qty: 9_999, pack_count: 1_000 });
    left -= 9_999_000;
  }
  if (left >= 9_999) out.push({ pack_qty: 9_999, pack_count: Math.floor(left / 9_999) });
  left %= 9_999;
  if (left > 0) out.push({ pack_qty: 1, pack_count: left });
  return out;
}
const INT32_MIN = -2147483648;
const INT32_MAX = 2147483647;

describe("迟到补偿在范围检查之前组合（PR #16 Codex 1，§14 S05-4）", () => {
  it("库存已是 INT32 下界：迟到卖出 1 个照收（补偿后库存不变）；盘点之后的同样一笔仍拒 invalid", { timeout: 120_000 }, async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 0 }, { at: T_COUNT }));
    const lines = split(-INT32_MIN).map((l) => ({ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", ...l, unit_price_fen: 0 }));
    for (let i = 0; i < lines.length; i += 200) {
      const r = await send(op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 0, lines: lines.slice(i, i + 200) }, { at: T_AFTER }));
      expect(r[0]!.status).toBe("applied");
    }
    expect([(await product(shop.storeId, pid)).stock_qty, Number((await product(shop.storeId, pid)).stock_value_fen)]).toEqual([INT32_MIN, 0]);
    const s = sale(pid, 1, T_LATE);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), p.cost_known]).toEqual([INT32_MIN, 0, false]);
    const es = await entriesOf(shop.storeId, pid);
    expect(es.slice(-2).map((e) => [e.type, e.qty_delta, Number(e.amount_fen), late(e)])).toEqual([["sale", -1, 300, false], ["count", 1, 0, true]]);
    // 不迟到的同样一笔：最终库存越界，仍按 §14 S05-4 拒 invalid
    const s2 = sale(pid, 1, T_AFTER);
    expect(await send(s2)).toEqual([{ id: s2.id, status: "rejected", code: "invalid" }]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(INT32_MIN);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("库存已是 INT32 上界：迟到进货 1 个照收（补偿后库存不变，进价更新为这次的）；盘点之后的同样一笔仍拒 invalid", { timeout: 120_000 }, async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 0, unit_cost_fen: 0 }, { at: T_COUNT }));
    const ins = split(INT32_MAX).map((l) => op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", ...l, unit_cost_fen: 0 }, { at: T_AFTER }));
    for (let i = 0; i < ins.length; i += 200) {
      const r = await send(...ins.slice(i, i + 200));
      expect(r.every((x: { status: string }) => x.status === "applied")).toBe(true);
    }
    expect((await product(shop.storeId, pid)).stock_qty).toBe(INT32_MAX);
    const lateIn = stockIn(pid, 1, 5, T_LATE);
    expect(await send(lateIn)).toEqual([{ id: lateIn.id, status: "applied" }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known]).toEqual([INT32_MAX, 0, 5, true]);
    const s2 = stockIn(pid, 1, 5, T_AFTER);
    expect(await send(s2)).toEqual([{ id: s2.id, status: "rejected", code: "invalid" }]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });
});
