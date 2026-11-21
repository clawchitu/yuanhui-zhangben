// S06 验收「两组逐分用例」（§5.2 成本补记、§5.3 对账与报表口径、§3.3 撤销算在撤销那天），全部经 /v1/sync 写库：
//  ① 先卖出 → 撤销 → 补进价：已撤销的卖出不参与补记。
//  ② 先卖出 → 补进价 → 跨月撤销：撤销月出现冲销的 cost_fix 和 cost_adjust，上月数字不变，对账等式两个月都成立。
// 月的界线按 occurred_at 的上海时间（§5.3）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop } from "./helpers/auth.ts";
import { op, syncOk, upsertFull } from "./helpers/sync.ts";
import { assertDbLedger } from "./helpers/ledger.ts";

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
  const u = upsertFull({ price: 300 });
  await send(u);
  return { shop, app, send, pid: u.payload.product_id as string };
}
const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const ver = async (storeId: string, pid: string) => Number((await product(storeId, pid)).stock_ver);
const sale = (pid: string, n: number, at: string, price = 300) => {
  const entry_id = randomUUID();
  return {
    entry_id,
    op: op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: n * price,
      lines: [{ entry_id, product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: n, unit_price_fen: price }],
    }, { at }),
  };
};
const voidEntry = (entry_id: string, at: string) => op("void", { target: { entry_id } }, { at });

const OCT = ["2026-10-01T00:00:00+08:00", "2026-11-01T00:00:00+08:00"] as const;
const NOV = ["2026-11-01T00:00:00+08:00", "2026-12-01T00:00:00+08:00"] as const;

/** 一个月的报表数字（§5.3）：各类型 value_delta 求和、卖了、赚了、月初 / 月末货值（全由流水求和，不读商品投影） */
async function month(storeId: string, pid: string, [from, to]: readonly [string, string]) {
  const es = await entriesOf(storeId, pid);
  const t0 = Date.parse(from);
  const t1 = Date.parse(to);
  const before = es.filter((e) => e.occurred_at.getTime() < t0);
  const inside = es.filter((e) => e.occurred_at.getTime() >= t0 && e.occurred_at.getTime() < t1);
  const sum = (rows: typeof es, f: (e: (typeof es)[number]) => number) => rows.reduce((x, e) => x + f(e), 0);
  const byType: Record<string, number> = {};
  for (const e of inside) byType[e.type] = (byType[e.type] ?? 0) + Number(e.value_delta_fen);
  const start = sum(before, (e) => Number(e.value_delta_fen));
  return {
    start,
    byType,
    end: start + sum(inside, (e) => Number(e.value_delta_fen)),
    // 卖了 = Σ 卖出行实收（含冲销行；cost_fix 不算）
    sold: sum(inside.filter((e) => e.type === "sale"), (e) => Number(e.amount_fen)),
    // 赚了 = Σ 进价已知的卖出行 (实收 − 进价) + Σ cost_fix (实收 − 进价)
    profit: sum(inside.filter((e) => (e.type === "sale" && !e.cost_missing) || e.type === "cost_fix"), (e) => Number(e.amount_fen) - Number(e.cogs_fen)),
    rows: inside.map((e) => [e.type, e.qty_delta, Number(e.amount_fen), Number(e.cogs_fen), Number(e.value_delta_fen), e.reverses_entry_id !== null]),
  };
}

describe("两组逐分用例（§5.2 成本补记 × §5.3 报表）", () => {
  it("① 先卖出 → 撤销 → 补进价：期初 10 没填，卖 1、卖 2，撤销卖 2，补全进价 2.00 数到 9 → cost_fix 只补卖 1 的那笔（300 / 200）", async () => {
    const { shop, app, send, pid } = await setup();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 10 }, { at: "2026-10-10T09:00:00+08:00" }));
    const s1 = sale(pid, 1, "2026-10-15T10:00:00+08:00");
    const s2 = sale(pid, 2, "2026-10-16T10:00:00+08:00");
    await send(s1.op, s2.op);
    await send(voidEntry(s2.entry_id, "2026-10-17T10:00:00+08:00"));
    const rc = op("product_review_complete", { entry_id: randomUUID(), product_id: pid, counted_qty: 9, unit_cost_fen: 200, base_ver: await ver(shop.storeId, pid) }, { at: "2026-10-20T10:00:00+08:00" });
    expect(await send(rc)).toEqual([{ id: rc.id, status: "applied" }]);

    const es = await entriesOf(shop.storeId, pid);
    const fix = es.find((e) => e.type === "cost_fix")!;
    expect([Number(fix.amount_fen), Number(fix.cogs_fen), Number(fix.unit_cost_fen), fix.qty_delta, Number(fix.value_delta_fen)]).toEqual([300, 200, 200, 0, 0]);
    expect(es.filter((e) => e.cost_fix_entry_id === fix.id).map((e) => e.id)).toEqual([s1.entry_id]);
    const sold2 = es.find((e) => e.id === s2.entry_id)!;
    expect([sold2.cost_fix_entry_id, sold2.voided_at !== null, Number(sold2.cogs_fen)]).toEqual([null, true, 0]);
    expect(es.filter((e) => e.type === "cost_fix")).toHaveLength(1);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen), p.cost_known, p.needs_review]).toEqual([9, 1800, 200, true, false]);

    const oct = await month(shop.storeId, pid, OCT);
    expect(oct.rows).toEqual([
      ["opening", 10, 0, 0, 0, false],
      ["sale", -1, 300, 0, 0, false],
      ["sale", -2, 600, 0, 0, false],
      ["sale", 2, -600, 0, 0, true],
      ["opening", 0, 0, 0, 1800, false],
      ["cost_fix", 0, 300, 200, 0, false],
    ]);
    // 卖了 300（卖 2 当月撤销抵消），赚了 = 补记的 300 − 200 = 100；对账 0 + 1800 = 1800 = 商品货值
    expect([oct.start, oct.end, oct.sold, oct.profit, oct.byType]).toEqual([0, 1800, 300, 100, { opening: 1800, sale: 0, cost_fix: 0 }]);
    expect(oct.end).toBe(Number(p.stock_value_fen));
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("② 先卖出 → 补进价 → 跨月撤销：10 月卖 1、卖 2、补进价 2.00（货值 1400），11 月撤销卖 2 → 11 月冲 cost_fix −600 / −400、cost_adjust +400，10 月数字不变，两个月对账都成立", async () => {
    const { shop, app, send, pid } = await setup();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 10 }, { at: "2026-10-10T09:00:00+08:00" }));
    const s1 = sale(pid, 1, "2026-10-15T10:00:00+08:00");
    const s2 = sale(pid, 2, "2026-10-16T10:00:00+08:00");
    await send(s1.op, s2.op);
    // 补进价：对已有商品的期初，带 base_ver（§5.6 第 2 条），数到 7、进价 200
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 7, unit_cost_fen: 200, base_ver: await ver(shop.storeId, pid) }, { at: "2026-10-31T23:59:00+08:00" }));

    const octBefore = await month(shop.storeId, pid, OCT);
    expect(octBefore.rows).toEqual([
      ["opening", 10, 0, 0, 0, false],
      ["sale", -1, 300, 0, 0, false],
      ["sale", -2, 600, 0, 0, false],
      ["opening", 0, 0, 0, 1400, false],
      ["cost_fix", 0, 900, 600, 0, false],
    ]);
    expect([octBefore.start, octBefore.end, octBefore.sold, octBefore.profit]).toEqual([0, 1400, 900, 300]);
    expect(Number((await product(shop.storeId, pid)).stock_value_fen)).toBe(octBefore.end);

    // 跨月撤销卖 2 的那笔（11 月 1 日 00:00 上海时间，恰好是 11 月的第一刻）
    const v = voidEntry(s2.entry_id, "2026-11-01T00:00:00+08:00");
    expect(await send(v)).toEqual([{ id: v.id, status: "applied" }]);

    const oct = await month(shop.storeId, pid, OCT);
    expect(oct).toEqual(octBefore); // 上月数字一分不变
    const nov = await month(shop.storeId, pid, NOV);
    expect(nov.rows).toEqual([
      ["sale", 2, -600, 0, 0, true],
      ["cost_fix", 0, -600, -400, 0, true],
      ["cost_adjust", 0, 0, 0, 400, false],
    ]);
    // 11 月：卖了 −600，赚了 = 冲销 cost_fix 的 −600 − (−400) = −200（卖出冲销行是 cost_missing，不进「赚了」）
    expect([nov.start, nov.end, nov.sold, nov.profit, nov.byType]).toEqual([1400, 1800, -600, -200, { sale: 0, cost_fix: 0, cost_adjust: 400 }]);
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.last_cost_fen)]).toEqual([9, 1800, 200]);
    expect(nov.end).toBe(Number(p.stock_value_fen));
    // 两个月合起来：赚的只剩卖 1 那笔的 300 − 200
    expect(oct.profit + nov.profit).toBe(100);
    // 原卖出行的 cogs_fen 不改；冲销行 occurred_at 是撤销时间
    const es = await entriesOf(shop.storeId, pid);
    expect(Number(es.find((e) => e.id === s2.entry_id)!.cogs_fen)).toBe(0);
    expect(es.filter((e) => e.op_id === v.id).every((e) => e.occurred_at.toISOString() === "2026-10-31T16:00:00.000Z")).toBe(true);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });
});
