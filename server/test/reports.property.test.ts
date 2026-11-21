// S07 性质测试：随机账本 → 报表 = 从流水按 §5.3 的定义独立重算（JS 逐行求和），对账等式恒成立。
// 随机生成进货（带 / 不带到期日）、期初（填 / 不填进价）、卖出（多行、优惠）、撤销（单行 / 整批，可能跨天跨月）、盘点、
// 待确认补全（补记成本）、扔掉 / 退货，occurred_at 随机落在 10 月 25 日到 11 月 20 日之间、按随机顺序到达（盘点之后才到的更早流水走迟到补偿）。
// 每组结束后比对：两个月的月报、每个有流水的日子和几个空日子的日报、07c 逐页拼起来 = 重算的日子列表；本月月末货值 = 全部商品投影货值之和（I2）。
// 组数：REPORT_PROP_RUNS（默认 300）。
import { randomUUID } from "node:crypto";
import fc from "fast-check";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { TestClock, login, makeApp, makeLoginShop } from "./helpers/auth.ts";
import { op, syncOk, upsertFull, type Op } from "./helpers/sync.ts";
import { allEntries, expectMonthMatches, recompute, shopIO } from "./helpers/reports.ts";

const RUNS = Number(process.env.REPORT_PROP_RUNS ?? 300);
/** 覆盖统计：证明随机账本真的走到了各种口径（不是一直空账） */
const seen: Record<string, number> = {};
const mark = (k: string, n = 1) => { seen[k] = (seen[k] ?? 0) + n; };
const NOW = Date.parse("2026-11-20T11:48:00Z");
const T0 = Date.parse("2026-10-25T00:00:00+08:00");
const SPAN = NOW - T0;

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

type Gen =
  | { k: "stock_in"; p: number; n: number; unit: number; expiry: boolean; t: number }
  | { k: "opening"; p: number; n: number; cost: number | null; t: number }
  | { k: "sale"; lines: Array<{ p: number; n: number; price: number }>; discount: number; t: number }
  | { k: "void"; target: number; whole: boolean; t: number }
  | { k: "count"; p: number; delta: number; t: number }
  | { k: "review"; p: number; n: number; cost: number; t: number }
  | { k: "dispose"; p: number; actual: number; action: "discard" | "return"; t: number };

const P = 3;
const tArb = fc.double({ min: 0, max: 1, noNaN: true }).map((x) => Math.floor(T0 + x * SPAN));
const genArb: fc.Arbitrary<Gen> = fc.oneof(
  { weight: 3, arbitrary: fc.record({ k: fc.constant("stock_in" as const), p: fc.nat(P - 1), n: fc.integer({ min: 1, max: 30 }), unit: fc.integer({ min: 0, max: 500 }), expiry: fc.boolean(), t: tArb }) },
  { weight: 1, arbitrary: fc.record({ k: fc.constant("opening" as const), p: fc.nat(P - 1), n: fc.integer({ min: 0, max: 30 }), cost: fc.option(fc.integer({ min: 0, max: 400 }), { nil: null }), t: tArb }) },
  {
    weight: 5,
    arbitrary: fc.record({
      k: fc.constant("sale" as const),
      lines: fc.array(fc.record({ p: fc.nat(P - 1), n: fc.integer({ min: 0, max: 6 }), price: fc.integer({ min: 0, max: 900 }) }), { minLength: 1, maxLength: 3 }),
      discount: fc.integer({ min: 0, max: 80 }),
      t: tArb,
    }),
  },
  { weight: 2, arbitrary: fc.record({ k: fc.constant("void" as const), target: fc.nat(), whole: fc.boolean(), t: tArb }) },
  { weight: 1, arbitrary: fc.record({ k: fc.constant("count" as const), p: fc.nat(P - 1), delta: fc.integer({ min: -5, max: 5 }), t: tArb }) },
  { weight: 1, arbitrary: fc.record({ k: fc.constant("review" as const), p: fc.nat(P - 1), n: fc.integer({ min: 0, max: 20 }), cost: fc.integer({ min: 0, max: 400 }), t: tArb }) },
  { weight: 1, arbitrary: fc.record({ k: fc.constant("dispose" as const), p: fc.nat(P - 1), actual: fc.integer({ min: 0, max: 5 }), action: fc.constantFrom("discard" as const, "return" as const), t: tArb }) },
);
const scenarioArb = fc.record({ gens: fc.array(genArb, { minLength: 4, maxLength: 22 }), order: fc.array(fc.nat(), { minLength: 22, maxLength: 22 }) });

type Scenario = { gens: Gen[]; order: number[] };
async function run(s: Scenario) {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb, { clock: new TestClock(NOW) });
  try {
    const boss = await login(app, shop.username);
    const { get } = shopIO(app, boss.token, shop.epoch);
    const send = (o: Op) => syncOk(app, boss.token, { epoch: shop.epoch, ops: [o], pull: false });
    const pids: string[] = [];
    for (let i = 0; i < P; i++) {
      const u = upsertFull({ price: 300, name: `商品${i}`, extra: i === 0 ? { track_expiry: true } : {} });
      await send(u);
      pids.push(u.payload.product_id as string);
    }
    const prod = (i: number) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", shop.storeId).where("id", "=", pids[i]!).executeTakeFirstOrThrow();
    // 到达顺序：按随机键稳定排序（时间上更早的可能更晚到）
    const idx = s.gens.map((_, i) => i).sort((a, b) => (s.order[a]! % 7) - (s.order[b]! % 7) || a - b);
    const sales: Array<{ batch: string; entries: string[] }> = [];
    for (const i of idx) {
      const g = s.gens[i]!;
      const at = new Date(g.t);
      let o: Op | undefined;
      switch (g.k) {
        case "stock_in":
          o = op("stock_in", { entry_id: randomUUID(), product_id: pids[g.p], barcode: "6900000000001", pack_qty: 1, pack_count: g.n, unit_cost_fen: g.unit, ...(g.expiry ? { expiry_date: "2026-11-15" } : {}) }, { at });
          break;
        case "opening":
          o = op("opening", { entry_id: randomUUID(), product_id: pids[g.p], counted_qty: g.n, ...(g.cost === null ? {} : { unit_cost_fen: g.cost }), base_ver: Number((await prod(g.p)).stock_ver) }, { at });
          break;
        case "sale": {
          const lines = g.lines.map((l) => ({ entry_id: randomUUID(), product_id: pids[l.p], barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: l.n, unit_price_fen: l.price }));
          const list = lines.reduce((x, l) => x + l.pack_count * l.unit_price_fen, 0);
          const batch = randomUUID();
          sales.push({ batch, entries: lines.map((l) => l.entry_id) });
          o = op("sale_batch", { batch_id: batch, paid_total_fen: Math.max(0, list - g.discount), lines }, { at });
          break;
        }
        case "void": {
          if (sales.length === 0) break;
          const sl = sales[g.target % sales.length]!;
          o = op("void", { target: g.whole ? { batch_id: sl.batch } : { entry_id: sl.entries[g.target % sl.entries.length]! } }, { at });
          break;
        }
        case "count": {
          const p = await prod(g.p);
          o = op("count", { entry_id: randomUUID(), product_id: pids[g.p], counted_qty: Math.max(0, p.stock_qty + g.delta), base_qty: p.stock_qty, base_ver: Number(p.stock_ver) }, { at });
          break;
        }
        case "review":
          o = op("product_review_complete", { entry_id: randomUUID(), product_id: pids[g.p], counted_qty: g.n, unit_cost_fen: g.cost, base_ver: Number((await prod(g.p)).stock_ver) }, { at });
          break;
        case "dispose": {
          const lot = await tdb.kysely.selectFrom("stock_lots").selectAll().where("store_id", "=", shop.storeId).where("product_id", "=", pids[g.p]!).where("closed_at", "is", null).orderBy("rev").executeTakeFirst();
          if (!lot) break;
          o = op("expiry_dispose", { lot_id: lot.id, handle_ver: lot.handle_ver, actual_qty: g.actual, action: g.action, entry_id: randomUUID() }, { at });
          break;
        }
      }
      if (o) await send(o); // 被拒（stale、invalid）的也没关系：报表只看入了账的流水
    }

    const es = await allEntries(tdb, shop.storeId);
    mark("entries", es.length);
    for (const e of es) {
      mark(`type:${e.type}`);
      if (e.reverses_entry_id !== null) mark("reversal");
      if (e.cost_missing) mark("cost_missing");
      if ((e.flags as Record<string, unknown> | null)?.late_before_count) mark("late_comp");
      if (e.reverses_entry_id !== null) {
        const orig = es.find((x) => x.id === e.reverses_entry_id)!;
        if (orig.occurred_at.getTime() < Date.parse("2026-11-01T00:00:00+08:00") && e.occurred_at.getTime() >= Date.parse("2026-11-01T00:00:00+08:00")) mark("cross_month_void");
      }
    }
    for (const month of ["2026-10", "2026-11"]) {
      const m = await get(`/v1/reports/month?month=${month}`, "ReportMonth");
      const r = recompute(es, month);
      expectMonthMatches(m, r);
      // 每日柱状图之和 = 月合计
      expect(m.daily.reduce((x: number, d: any) => x + d.sold_fen, 0)).toBe(m.sold_fen);
      expect(m.daily.reduce((x: number, d: any) => x + d.profit_fen, 0)).toBe(m.profit_fen);
    }
    const oct = await get("/v1/reports/month?month=2026-10");
    const nov = await get("/v1/reports/month?month=2026-11");
    expect(nov.reconciliation.stock_value_start_fen).toBe(oct.stock_value_end_fen);
    const projected = (await tdb.kysely.selectFrom("products").select("stock_value_fen").where("store_id", "=", shop.storeId).execute()).reduce((x, p) => x + Number(p.stock_value_fen), 0);
    expect(nov.stock_value_end_fen).toBe(projected);

    const r0 = recompute(es, "2026");
    for (const day of [...r0.days, "2026-10-24", "2026-11-21"]) {
      const t = await get(`/v1/reports/today?date=${day}`, "ReportToday");
      const r = recompute(es, day);
      expect([t.sold_fen, t.profit_fen, t.discount_fen, t.count, t.cost_missing_count, t.loss_cost_missing_count], day).toEqual([
        r.sold, r.profit, r.discount, r.records, r.costMissingProducts, r.lossMissing.count + r.lossMissing.expire_loss + r.lossMissing.supplier_return,
      ]);
    }
    // 07c 逐页（每页 2 天）拼起来 = 重算的日子列表（从近到远）
    const got: any[] = [];
    let before = "2026-11-22";
    for (;;) {
      const page = (await get(`/v1/entries/days?before=${before}&limit=2`)).days;
      got.push(...page);
      if (page.length < 2) break;
      before = page[page.length - 1].date;
    }
    expect(got).toEqual([...r0.days].reverse().map((d) => {
      const r = recompute(es, d);
      return { date: d, count: r.records, amount_fen: r.sold };
    }));
  } finally {
    await app.close();
  }
}

describe("报表性质测试（§5.3）", () => {
  it(`随机账本 ${RUNS} 组：月报、日报、07c 都等于从流水按定义重算，对账等式恒成立`, async () => {
    await fc.assert(fc.asyncProperty(scenarioArb, run), { numRuns: RUNS });
    console.log("覆盖统计", JSON.stringify(seen));
    if (RUNS >= 100) {
      for (const k of ["type:sale", "type:stock_in", "type:opening", "type:count", "type:cost_fix", "type:cost_adjust", "type:expire_loss", "type:supplier_return", "reversal", "cost_missing", "late_comp", "cross_month_void"]) {
        expect(seen[k] ?? 0, k).toBeGreaterThan(0);
      }
    }
  }, 600_000);
});
