// S07 报表与查询接口（§5.3、§7、设计稿 09 / 10 / 07a / 07c）。全部经 /v1/sync 写库，再调真实 HTTP 接口，响应按 openapi 校验。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { TestClock, bearer, login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { op, upsertFull } from "./helpers/sync.ts";
import { SH, allEntries, expectMonthMatches, recompute, saleOp, shopIO, stockInOp, voidOp } from "./helpers/reports.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

/** 设计稿 10 的时刻：2026-11-20 19:48（上海） */
const NOW = Date.parse("2026-11-20T11:48:00Z");

async function setup(now = NOW) {
  const shop = await makeLoginShop(tdb);
  const clock = new TestClock(now);
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const io = shopIO(app, boss.token, shop.epoch);
  const product = async (o: { price: number; name: string; extra?: Record<string, unknown> }) => {
    const u = upsertFull({ price: o.price, name: o.name, extra: o.extra });
    await io.send(u);
    return u.payload.product_id as string;
  };
  return { shop, clock, app, boss, ...io, product };
}
const prod = (storeId: string, id: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const lotOf = (storeId: string, pid: string, expiry: string) =>
  tdb.kysely.selectFrom("stock_lots").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).where("expiry_date", "=", expiry).executeTakeFirstOrThrow();
const storeValue = async (storeId: string) =>
  (await tdb.kysely.selectFrom("products").select("stock_value_fen").where("store_id", "=", storeId).execute()).reduce((s, p) => s + Number(p.stock_value_fen), 0);

/**
 * 设计稿 10 的夹具（单位：分）。
 * 10 月：中华 进 4100 @500、卖 100 @650；农夫山泉（管保质期）进 5675 @100（批次 A，11-05 到期）；红牛 期初 2 个没填进价（货值 0）。
 *   → 11 月初货值 = 2,050,000 − 50,000 + 567,500 = 2,567,500（¥25,675）。
 * 11 月：进货 中华 2000 @500、农夫 58（批次 B，11-12 到期）+ 160（批次 C，11-18）+ 5702（批次 D）@100 = 1,592,000（¥15,920）；
 *   1–20 日每天两笔卖出（中华 140 @600 + 农夫 125 @150 优惠 2 元 / 最后一天 8 元；农夫 74 @200，最后一天 133 和 73），
 *   卖出合计 中华 2800、农夫 3987 → 进价 1,400,000 + 398,700 = 1,798,700（¥17,987），实收 2,347,400（¥23,474），优惠 4,600；
 *   11-05 多卖中华 10 个、11-06 撤销（跨天、同月）；11-10 卖农夫 5 个当场撤销；
 *   11-13 扔掉批次 B 58 个（¥58）；11-18 批次 C 退供货商 160 个（¥160）；11-19 晚盘点农夫少 128 个（¥128）。
 *   → 现在货值 = 中华 3200 × 500 + 农夫 7262 × 100 = 2,326,200（¥23,262）。
 */
async function design10() {
  const s = await setup();
  const zh = await s.product({ price: 600, name: "中华（硬）" });
  const nf = await s.product({ price: 150, name: "农夫山泉 550ml", extra: { track_expiry: true } });
  const rb = await s.product({ price: 600, name: "红牛 250ml" });
  await s.send(stockInOp(zh, 4100, 500, SH("2026-10-05T10:00:00")), stockInOp(nf, 5675, 100, SH("2026-10-05T10:05:00"), "2026-11-05"));
  await s.send(op("opening", { entry_id: randomUUID(), product_id: rb, counted_qty: 2 }, { at: SH("2026-10-06T10:00:00") }));
  await s.send(saleOp([{ pid: zh, n: 100, price: 650 }], SH("2026-10-20T15:00:00")).op);
  await s.send(
    stockInOp(zh, 2000, 500, SH("2026-11-01T09:00:00")),
    stockInOp(nf, 58, 100, SH("2026-11-01T09:05:00"), "2026-11-12"),
    stockInOp(nf, 160, 100, SH("2026-11-01T09:10:00"), "2026-11-18"),
    stockInOp(nf, 5702, 100, SH("2026-11-01T09:15:00"), "2027-06-30"),
  );
  const batches: Array<{ day: string; b1: ReturnType<typeof saleOp>; b2: ReturnType<typeof saleOp> }> = [];
  let extra!: ReturnType<typeof saleOp>;
  for (let d = 1; d <= 20; d++) {
    const day = `2026-11-${String(d).padStart(2, "0")}`;
    const last = d === 20;
    const b1 = saleOp([{ pid: zh, n: 140, price: 600 }, { pid: nf, n: last ? 133 : 125, price: 150 }], SH(`${day}T12:00:00`), last ? 800 : 200);
    const b2 = saleOp([{ pid: nf, n: last ? 73 : 74, price: 200 }], SH(`${day}T12:30:00`));
    await s.send(b1.op, b2.op);
    batches.push({ day, b1, b2 });
    if (d === 5) {
      extra = saleOp([{ pid: zh, n: 10, price: 600 }], SH("2026-11-05T15:00:00"));
      await s.send(extra.op);
    }
    if (d === 6) await s.send(voidOp({ entry_id: extra.entryIds[0]! }, SH("2026-11-06T09:00:00")));
    if (d === 10) {
      const x = saleOp([{ pid: nf, n: 5, price: 150 }], SH("2026-11-10T15:00:00"));
      await s.send(x.op, voidOp({ batch_id: x.batch_id }, SH("2026-11-10T15:05:00")));
    }
    if (d === 13) {
      const B = await lotOf(s.shop.storeId, nf, "2026-11-12");
      await s.send(op("expiry_dispose", { lot_id: B.id, handle_ver: B.handle_ver, actual_qty: 58, action: "discard", entry_id: randomUUID() }, { at: SH("2026-11-13T10:00:00") }));
    }
    if (d === 18) {
      const C = await lotOf(s.shop.storeId, nf, "2026-11-18");
      await s.send(op("expiry_dispose", { lot_id: C.id, handle_ver: C.handle_ver, actual_qty: 160, action: "return", entry_id: randomUUID() }, { at: SH("2026-11-18T10:00:00") }));
    }
    if (d === 19) {
      const p = await prod(s.shop.storeId, nf);
      await s.send(op("count", { entry_id: randomUUID(), product_id: nf, counted_qty: p.stock_qty - 128, base_qty: p.stock_qty, base_ver: Number(p.stock_ver) }, { at: SH("2026-11-19T20:00:00") }));
    }
  }
  return { ...s, zh, nf, rb, batches, extra };
}

describe("设计稿 10 的夹具", () => {
  it("本月的账逐分复现：卖了 23,474、赚了 5,487、月初 + 进货 41,595、卖掉的进价 17,987、盘点少 128、过期 58、退货 160、现在货值 23,262", async () => {
    const f = await design10();
    const m = await f.get("/v1/reports/month?month=2026-11", "ReportMonth");
    expect(m).toMatchObject({ month: "2026-11", sold_fen: 2_347_400, profit_fen: 548_700, discount_fen: 4_600, expire_loss_fen: 5_800, stock_value_end_fen: 2_326_200, cost_missing_count: 0, loss_cost_missing_count: 0 });
    expect(m.reconciliation).toEqual({
      stock_value_start_fen: 2_567_500,
      rows: [
        { key: "stock_in", amount_fen: 1_592_000, cost_missing_count: 0 },
        { key: "sale", amount_fen: -1_798_700, cost_missing_count: 0 },
        { key: "count", amount_fen: -12_800, cost_missing_count: 0 },
        { key: "expire_loss", amount_fen: -5_800, cost_missing_count: 0 },
        { key: "supplier_return", amount_fen: -16_000, cost_missing_count: 0 },
      ],
      stock_value_end_fen: 2_326_200,
    });
    // 设计稿上的写法：月初 + 本月进货 = 41,595；减四行 = 23,262；进货花了 15,920
    const r = m.reconciliation;
    expect(r.stock_value_start_fen + r.rows[0].amount_fen).toBe(4_159_500);
    expect(4_159_500 - 1_798_700 - 12_800 - 5_800 - 16_000).toBe(2_326_200);
    // 现在货值 = 全部商品投影的货值之和（I2），赚了 = 卖了 − 卖掉的进价
    expect(await storeValue(f.shop.storeId)).toBe(2_326_200);
    expect(m.sold_fen + r.rows[1].amount_fen).toBe(m.profit_fen);
    // 每日柱状图：1–20 日，5 日多卖 6,000、6 日撤销 −6,000、10 日当场撤销相抵
    expect(m.daily).toHaveLength(20);
    const daily = Object.fromEntries(m.daily.map((d: any) => [d.date, d.sold_fen]));
    expect([daily["2026-11-01"], daily["2026-11-05"], daily["2026-11-06"], daily["2026-11-10"], daily["2026-11-20"]]).toEqual([117_350, 123_350, 111_350, 117_350, 117_750]);
    expect(m.daily.reduce((s: number, d: any) => s + d.sold_fen, 0)).toBe(m.sold_fen);
    expect(m.daily.reduce((s: number, d: any) => s + d.profit_fen, 0)).toBe(m.profit_fen);
    // 与独立重算一致
    expectMonthMatches(m, recompute(await allEntries(tdb, f.shop.storeId), "2026-11"));

    // 10 月：月初 0，进货 2,617,500，卖出 −50,000，期初（红牛没填进价）为 0 不显示
    const oct = await f.get("/v1/reports/month?month=2026-10", "ReportMonth");
    expect([oct.sold_fen, oct.profit_fen, oct.reconciliation.stock_value_start_fen, oct.stock_value_end_fen, oct.reconciliation.rows.length, oct.daily.length]).toEqual([65_000, 15_000, 0, 2_567_500, 5, 31]);
    // 没带参数 = 本月
    expect(await f.get("/v1/reports/month")).toEqual(m);
    await f.app.close();
  });

  it("今天的账（09）：卖了、赚了、优惠、笔数、卖得最好、快没货、快过期", async () => {
    const f = await design10();
    const t = await f.get("/v1/reports/today", "ReportToday");
    // 20 日：实收 117,750；进价 中华 140×500 + 农夫 206×100 = 90,600 → 赚了 27,150；优惠 800；两笔
    expect(t).toMatchObject({ date: "2026-11-20", sold_fen: 117_750, profit_fen: 27_150, discount_fen: 800, count: 2, cost_missing_count: 0, loss_cost_missing_count: 0 });
    const es20 = (await allEntries(tdb, f.shop.storeId)).filter((e) => e.type === "sale" && e.occurred_at.toISOString().startsWith("2026-11-20"));
    const amt = (pid: string) => es20.filter((e) => e.product_id === pid).reduce((x, e) => x + Number(e.amount_fen), 0);
    expect(t.top_sellers).toEqual([
      { product_id: f.nf, name: "农夫山泉 550ml", qty: 206, amount_fen: amt(f.nf) },
      { product_id: f.zh, name: "中华（硬）", qty: 140, amount_fen: amt(f.zh) },
    ]);
    expect(t.top_sellers[0].amount_fen + t.top_sellers[1].amount_fen).toBe(117_750);
    // 快没货：红牛 2 个 ≤ 店里默认提醒线 3
    expect(t.low_stock).toEqual([{ product_id: f.rb, name: "红牛 250ml", qty: 2 }]);
    // 快过期：批次 A（11-05 到期）还剩 5675 − 3987 − 128（盘亏按到期日扣）= 1560；B、C 已处理关闭，D 2027 年到期
    expect(t.expiring).toEqual([{ product_id: f.nf, name: "农夫山泉 550ml", qty: 1560, expiry_date: "2026-11-05" }]);
    // 与重算一致（日）
    const r = recompute(await allEntries(tdb, f.shop.storeId), "2026-11-20");
    expect([t.sold_fen, t.profit_fen, t.discount_fen, t.count]).toEqual([r.sold, r.profit, r.discount, r.records]);
    // 5 日：三笔（两笔日常 + 多卖的那笔，后来被撤销也算一笔）；6 日撤销本身不算一笔，那天卖了少 6,000
    const d5 = await f.get("/v1/reports/today?date=2026-11-05", "ReportToday");
    const d6 = await f.get("/v1/reports/today?date=2026-11-06", "ReportToday");
    expect([d5.count, d5.sold_fen, d6.count, d6.sold_fen]).toEqual([3, 123_350, 2, 111_350]);
    // 10 日当场撤销的那笔：算一笔，卖了不变，卖得最好不含它
    const d10 = await f.get("/v1/reports/today?date=2026-11-10");
    expect([d10.count, d10.sold_fen, d10.top_sellers.find((x: any) => x.product_id === f.nf).qty]).toEqual([3, 117_350, 199]);
    await f.app.close();
  });

  it("记的账（07a / 07c）：不含冲销行，原行带 voided_at；按天列表与翻页", async () => {
    const f = await design10();
    const d5 = await f.get("/v1/entries?date=2026-11-05");
    expect(d5.entries.every((e: any) => e.reverses_entry_id === null)).toBe(true);
    expect(d5.entries).toHaveLength(4);
    expect(d5.batches).toHaveLength(3);
    const ex = d5.entries.find((e: any) => e.id === f.extra.entryIds[0]);
    expect(ex.voided_at).toBe("2026-11-06T01:00:00.000Z");
    expect(ex.device_label).toBeDefined();
    // 6 日的冲销行不出现在任何一天的列表里
    const d6 = await f.get("/v1/entries?date=2026-11-06");
    expect(d6.entries.map((e: any) => e.reverses_entry_id)).toEqual([null, null, null]);
    for (const e of [...d5.entries, ...d6.entries]) await (await import("./helpers/sync.ts")).expectContract("Entry", e);

    const days = await f.get("/v1/entries/days?before=2026-11-07&limit=3");
    expect(days.days).toEqual([
      { date: "2026-11-06", count: 2, amount_fen: 111_350 },
      { date: "2026-11-05", count: 3, amount_fen: 123_350 },
      { date: "2026-11-04", count: 2, amount_fen: 117_350 },
    ]);
    // 默认 before = 今天（不含）、limit = 7
    const def = await f.get("/v1/entries/days");
    expect(def.days.map((d: any) => d.date)).toEqual(["2026-11-19", "2026-11-18", "2026-11-17", "2026-11-16", "2026-11-15", "2026-11-14", "2026-11-13"]);
    // 19 日：两笔卖出 + 盘点；18 日：两笔 + 退货；13 日：两笔 + 扔掉
    expect([def.days[0].count, def.days[1].count, def.days[6].count]).toEqual([3, 3, 3]);
    // 翻页：逐页（每页 1–7 天）拼起来 = 一次拉 31 天，不重不漏
    for (const size of [1, 2, 5, 7]) {
      const got: any[] = [];
      let before = "2026-11-21";
      for (;;) {
        const page = (await f.get(`/v1/entries/days?before=${before}&limit=${size}`)).days;
        got.push(...page);
        if (page.length < size) break;
        before = page[page.length - 1].date;
      }
      const all = (await f.get("/v1/entries/days?before=2026-11-21&limit=31")).days;
      expect(got).toEqual(all);
      expect(all).toHaveLength(23); // 11 月 1–20 日 + 10 月 5、6、20 日
    }
    await f.app.close();
  });
});

describe("口径的逐分用例", () => {
  it("按批汇总（S05-12）：撤一行、整批撤、补记后撤销 → 每批原行之和 = paid_total_fen，冲销行落在撤销那天", async () => {
    const s = await setup();
    const a = await s.product({ price: 300, name: "a" });
    const b = await s.product({ price: 500, name: "b" });
    const c = await s.product({ price: 200, name: "c" });
    await s.send(stockInOp(a, 50, 100, SH("2026-11-01T08:00:00")), stockInOp(b, 50, 200, SH("2026-11-01T08:00:00")));
    await s.send(op("opening", { entry_id: randomUUID(), product_id: c, counted_qty: 10 }, { at: SH("2026-11-01T08:00:00") }));
    const one = saleOp([{ pid: a, n: 2, price: 300 }, { pid: b, n: 1, price: 500 }], SH("2026-11-02T10:00:00"), 50); // 撤一行
    const all = saleOp([{ pid: a, n: 1, price: 300 }, { pid: b, n: 2, price: 500 }], SH("2026-11-02T11:00:00"), 30); // 整批撤
    const fixed = saleOp([{ pid: c, n: 3, price: 200 }, { pid: a, n: 1, price: 300 }], SH("2026-11-02T12:00:00")); // 补记后撤销
    await s.send(one.op, all.op, fixed.op);
    const p = await prod(s.shop.storeId, c);
    await s.send(op("opening", { entry_id: randomUUID(), product_id: c, counted_qty: 7, unit_cost_fen: 120, base_ver: Number(p.stock_ver) }, { at: SH("2026-11-02T20:00:00") }));
    await s.send(
      voidOp({ entry_id: one.entryIds[1]! }, SH("2026-11-03T09:00:00")),
      voidOp({ batch_id: all.batch_id }, SH("2026-11-03T09:10:00")),
      voidOp({ entry_id: fixed.entryIds[0]! }, SH("2026-11-04T09:00:00")),
    );
    const d2 = await s.get("/v1/entries?date=2026-11-02");
    for (const sb of d2.batches) {
      const sum = d2.entries.filter((e: any) => e.batch_id === sb.id).reduce((x: number, e: any) => x + e.amount_fen, 0);
      expect(sum, sb.id).toBe(sb.paid_total_fen);
    }
    expect(d2.batches.map((x: any) => x.paid_total_fen)).toEqual([1050, 1270, 900]);
    // 数据库里冲销行带原 batch_id；不加 reverses_entry_id IS NULL 会把它们算进批里
    const es = await allEntries(tdb, s.shop.storeId);
    expect(es.filter((e) => e.batch_id === all.batch_id && e.reverses_entry_id !== null)).toHaveLength(2);
    // 冲销行落在撤销那天：2 日卖了 3220（全部原行），3 日 −（b 那行 + 整批），4 日 −600（c 那行）及冲销 cost_fix
    const day = async (d: string) => s.get(`/v1/reports/today?date=${d}`, "ReportToday");
    const [d2r, d3r, d4r] = [await day("2026-11-02"), await day("2026-11-03"), await day("2026-11-04")];
    const lineAmt = (id: string) => Number(es.find((e) => e.id === id)!.amount_fen);
    expect(d2r.sold_fen).toBe(1050 + 1270 + 900);
    expect(d3r.sold_fen).toBe(-lineAmt(one.entryIds[1]!) - 1270);
    expect(d4r.sold_fen).toBe(-600);
    // c 的卖出补记前是 cost_missing：2 日的「赚了」不含它；补记的 cost_fix（2 日 20:00）进 2 日的「赚了」；4 日撤销时冲销 cost_fix
    const fix = es.find((e) => e.type === "cost_fix" && e.reverses_entry_id === null)!;
    expect([Number(fix.amount_fen), Number(fix.cogs_fen)]).toEqual([600, 360]);
    expect(d4r.profit_fen).toBe(-(600 - 360));
    for (const d of ["2026-11-02", "2026-11-03", "2026-11-04"]) {
      const r = recompute(es, d);
      const t = await day(d);
      expect([t.sold_fen, t.profit_fen, t.discount_fen, t.count], d).toEqual([r.sold, r.profit, r.discount, r.records]);
    }
    const m = await s.get("/v1/reports/month?month=2026-11", "ReportMonth");
    expectMonthMatches(m, recompute(es, "2026-11"));
    expect(m.stock_value_end_fen).toBe(await storeValue(s.shop.storeId));
    await s.app.close();
  });

  it("跨月撤销不改变上月：10 月卖、11 月撤 → 10 月报表一分不变，11 月月初 = 10 月月末，冲销算在 11 月", async () => {
    const s = await setup();
    const a = await s.product({ price: 300, name: "a" });
    await s.send(stockInOp(a, 20, 100, SH("2026-10-01T08:00:00")), stockInOp(a, 10, 130, SH("2026-10-02T08:00:00")));
    const sale = saleOp([{ pid: a, n: 4, price: 300 }], SH("2026-10-31T23:59:59.999"));
    await s.send(sale.op);
    const octBefore = await s.get("/v1/reports/month?month=2026-10");
    await s.send(voidOp({ batch_id: sale.batch_id }, SH("2026-11-01T00:00:00")));
    const oct = await s.get("/v1/reports/month?month=2026-10");
    const nov = await s.get("/v1/reports/month?month=2026-11");
    expect(oct).toEqual(octBefore);
    expect(oct.sold_fen).toBe(1200);
    // 平均进价 (2000 + 1300) / 30 = 110 → 卖 4 个进价 440
    expect([oct.profit_fen, oct.reconciliation.stock_value_end_fen]).toEqual([1200 - 440, 3300 - 440]);
    expect(nov.reconciliation.stock_value_start_fen).toBe(oct.reconciliation.stock_value_end_fen);
    expect([nov.sold_fen, nov.profit_fen, nov.stock_value_end_fen]).toEqual([-1200, -760, 3300]);
    expect(nov.reconciliation.rows.find((r: any) => r.key === "sale").amount_fen).toBe(440);
    // 日界线：10-31 23:59:59.999 算 10-31，11-01 00:00:00 算 11-01
    expect((await s.get("/v1/reports/today?date=2026-10-31")).sold_fen).toBe(1200);
    expect((await s.get("/v1/reports/today?date=2026-11-01")).sold_fen).toBe(-1200);
    expect((await s.get("/v1/entries/days?before=2026-11-02&limit=2")).days).toEqual([
      { date: "2026-11-01", count: 0, amount_fen: -1200 },
      { date: "2026-10-31", count: 1, amount_fen: 1200 },
    ]);
    await s.app.close();
  });

  it("cost_missing：没补记的卖出不进「赚了」并计数（种数 / 笔数）；补记的 cost_fix 进「赚了」不进「卖了」；进价未知的损耗另计笔数", async () => {
    const s = await setup();
    const a = await s.product({ price: 300, name: "a" });
    const b = await s.product({ price: 300, name: "b", extra: { track_expiry: true } });
    const k = await s.product({ price: 300, name: "k" });
    await s.send(stockInOp(k, 10, 100, SH("2026-11-01T08:00:00")));
    await s.send(op("opening", { entry_id: randomUUID(), product_id: a, counted_qty: 10 }, { at: SH("2026-11-01T08:00:00") }));
    await s.send(op("opening", { entry_id: randomUUID(), product_id: b, counted_qty: 10, expiry_date: "2026-11-03" }, { at: SH("2026-11-01T08:00:00") }));
    await s.send(
      saleOp([{ pid: a, n: 1, price: 300 }], SH("2026-11-02T10:00:00")).op,
      saleOp([{ pid: a, n: 2, price: 300 }, { pid: k, n: 1, price: 300 }], SH("2026-11-02T11:00:00")).op,
      saleOp([{ pid: b, n: 1, price: 300 }], SH("2026-11-02T12:00:00")).op,
    );
    const lot = await lotOf(s.shop.storeId, b, "2026-11-03");
    await s.send(op("expiry_dispose", { lot_id: lot.id, handle_ver: lot.handle_ver, actual_qty: 2, action: "discard", entry_id: randomUUID() }, { at: SH("2026-11-04T10:00:00") }));
    const pb = await prod(s.shop.storeId, b);
    await s.send(op("count", { entry_id: randomUUID(), product_id: b, counted_qty: pb.stock_qty - 1, base_qty: pb.stock_qty, base_ver: Number(pb.stock_ver) }, { at: SH("2026-11-04T11:00:00") }));

    let m = await s.get("/v1/reports/month?month=2026-11", "ReportMonth");
    // 卖了含全部 5 个 1500；赚了只有 k 的 300 − 100
    expect([m.sold_fen, m.profit_fen, m.cost_missing_count, m.loss_cost_missing_count]).toEqual([1500, 200, 2, 2]);
    const rows = (x: any) => Object.fromEntries(x.reconciliation.rows.map((r: any) => [r.key, r.cost_missing_count]));
    expect(rows(m)).toEqual({ stock_in: 0, sale: 3, count: 1, expire_loss: 1, supplier_return: 0 });
    let t = await s.get("/v1/reports/today?date=2026-11-02", "ReportToday");
    expect([t.sold_fen, t.profit_fen, t.cost_missing_count]).toEqual([1500, 200, 2]);
    expectMonthMatches(m, recompute(await allEntries(tdb, s.shop.storeId), "2026-11"));

    // 补全 a：进价 150，数到 7 → cost_fix 3 个 × 150（实收 900、进价 450），记在补全那天（11-05）
    const pa = await prod(s.shop.storeId, a);
    await s.send(op("product_review_complete", { entry_id: randomUUID(), product_id: a, counted_qty: 7, unit_cost_fen: 150, base_ver: Number(pa.stock_ver) }, { at: SH("2026-11-05T10:00:00") }));
    m = await s.get("/v1/reports/month?month=2026-11", "ReportMonth");
    expect([m.sold_fen, m.profit_fen, m.cost_missing_count]).toEqual([1500, 200 + 450, 1]);
    expect(rows(m).sale).toBe(1);
    t = await s.get("/v1/reports/today?date=2026-11-05", "ReportToday");
    expect([t.sold_fen, t.profit_fen, t.count]).toEqual([0, 450, 1]);
    t = await s.get("/v1/reports/today?date=2026-11-02");
    expect([t.sold_fen, t.profit_fen, t.cost_missing_count]).toEqual([1500, 200, 1]);
    expectMonthMatches(m, recompute(await allEntries(tdb, s.shop.storeId), "2026-11"));
    await s.app.close();
  });

  it("迟到补偿行（§5.6 第 4 条）：迟到的卖出照记收入和成本，补偿的 count 行和它同一天、同一笔；对账照样成立", async () => {
    const s = await setup();
    const a = await s.product({ price: 300, name: "a" });
    await s.send(stockInOp(a, 10, 100, SH("2026-11-01T08:00:00")));
    const p = await prod(s.shop.storeId, a);
    await s.send(op("count", { entry_id: randomUUID(), product_id: a, counted_qty: 8, base_qty: 10, base_ver: Number(p.stock_ver) }, { at: SH("2026-11-03T20:00:00") }));
    await s.send(saleOp([{ pid: a, n: 2, price: 300 }], SH("2026-11-03T10:00:00")).op); // 盘点前卖的，盘点后才传上来
    const t = await s.get("/v1/reports/today?date=2026-11-03", "ReportToday");
    expect([t.sold_fen, t.profit_fen, t.count]).toEqual([600, 400, 2]);
    const m = await s.get("/v1/reports/month?month=2026-11", "ReportMonth");
    const rows = Object.fromEntries(m.reconciliation.rows.map((r: any) => [r.key, r.amount_fen]));
    // 盘亏 2 个（−200），迟到卖出 −200，补偿 count +200 → 盘点行净 0；库存 8 货值 800
    expect([rows.sale, rows.count, m.stock_value_end_fen]).toEqual([-200, 0, 800]);
    expect(m.stock_value_end_fen).toBe(await storeValue(s.shop.storeId));
    expectMonthMatches(m, recompute(await allEntries(tdb, s.shop.storeId), "2026-11"));
    await s.app.close();
  });
});

describe("权限与参数", () => {
  const URLS = ["/v1/reports/today", "/v1/reports/month", "/v1/entries?date=2026-11-20", "/v1/entries/days"];
  it("收银员全部 403（响应只有错误码）、被踢 401 revoked、没令牌 401（真实请求）", async () => {
    const s = await setup();
    const cas = await pair(s.app, s.boss.token, "cashier", "小王");
    for (const url of URLS) {
      const res = await s.app.inject({ method: "GET", url, headers: bearer(cas.token) });
      expect([res.statusCode, res.json()], url).toEqual([403, { code: "forbidden" }]);
      const anon = await s.app.inject({ method: "GET", url });
      expect([anon.statusCode, anon.json().code], url).toEqual([401, "unauthorized"]);
    }
    const kicked = await pair(s.app, s.boss.token, "family", "旧手机");
    expect((await s.app.inject({ method: "POST", url: `/v1/devices/${kicked.deviceId}/revoke`, headers: bearer(s.boss.token) })).statusCode).toBe(204);
    for (const url of URLS) {
      const res = await s.app.inject({ method: "GET", url, headers: bearer(kicked.token) });
      expect([res.statusCode, res.json().code], url).toEqual([401, "revoked"]);
    }
    await s.app.close();
  });

  it("别的店的流水看不到；参数不合法 400；时间范围边界", async () => {
    const s = await setup();
    const other = await setup();
    const a = await other.product({ price: 300, name: "a" });
    await other.send(stockInOp(a, 5, 100, SH("2026-11-20T08:00:00")), saleOp([{ pid: a, n: 1, price: 300 }], SH("2026-11-20T09:00:00")).op);
    const t = await s.get("/v1/reports/today", "ReportToday");
    expect([t.sold_fen, t.count, t.top_sellers, t.low_stock, t.expiring]).toEqual([0, 0, [], [], []]);
    expect((await s.get("/v1/entries?date=2026-11-20")).entries).toEqual([]);
    expect((await s.get("/v1/entries/days")).days).toEqual([]);
    const m = await s.get("/v1/reports/month", "ReportMonth");
    expect([m.reconciliation.stock_value_start_fen, m.stock_value_end_fen, m.daily.length]).toEqual([0, 0, 20]);
    // 将来的月份：柱状图为空；过去的闰年 2 月：29 天
    expect((await s.get("/v1/reports/month?month=2026-12")).daily).toEqual([]);
    expect((await s.get("/v1/reports/month?month=2024-02")).daily).toHaveLength(29);
    for (const url of ["/v1/reports/today?date=2026-02-30", "/v1/reports/today?date=2026-11-5", "/v1/reports/month?month=2026-13", "/v1/reports/month?month=1999-12",
      "/v1/entries", "/v1/entries?date=x", "/v1/entries/days?limit=0", "/v1/entries/days?limit=32", "/v1/entries/days?before=2026-11-31"]) {
      const res = await s.app.inject({ method: "GET", url, headers: bearer(s.boss.token) });
      expect([res.statusCode, res.json().code], url).toEqual([400, "invalid"]);
    }
    // 上海日界线：今天 00:00:00 算今天，前一刻算昨天
    await s.send(stockInOp((await s.product({ price: 100, name: "z" })), 5, 10, SH("2026-11-19T00:00:00")));
    const z = (await tdb.kysely.selectFrom("products").select("id").where("store_id", "=", s.shop.storeId).executeTakeFirstOrThrow()).id;
    await s.send(saleOp([{ pid: z, n: 1, price: 100 }], SH("2026-11-19T23:59:59.999")).op, saleOp([{ pid: z, n: 2, price: 100 }], SH("2026-11-20T00:00:00")).op);
    expect([(await s.get("/v1/reports/today?date=2026-11-19")).sold_fen, (await s.get("/v1/reports/today")).sold_fen]).toEqual([100, 200]);
    expect((await s.get("/v1/entries?date=2026-11-19")).entries.map((e: any) => e.type)).toEqual(["stock_in", "sale"]);
    await s.app.close();
    await other.app.close();
  });
});

describe("性能", () => {
  it("一个月 1 万条流水时月报 < 300 ms", async () => {
    const s = await setup();
    const ps: string[] = [];
    for (let i = 0; i < 10; i++) ps.push(await s.product({ price: 300, name: `p${i}` }));
    await s.send(...ps.map((p) => stockInOp(p, 99_999, 100, SH("2026-10-31T08:00:00"))));
    // 50 批 × 200 行 = 10,000 条卖出流水，散在 11 月 1–20 日
    for (let b = 0; b < 50; b++) {
      const day = String((b % 20) + 1).padStart(2, "0");
      const lines = Array.from({ length: 200 }, (_, i) => ({ pid: ps[i % 10]!, n: 1, price: 300 }));
      await s.send(saleOp(lines, SH(`2026-11-${day}T${String(8 + (b % 12)).padStart(2, "0")}:00:00`), 10).op);
    }
    const n = await tdb.kysely.selectFrom("entries").select((eb) => eb.fn.countAll<string>().as("n")).where("store_id", "=", s.shop.storeId).executeTakeFirstOrThrow();
    expect(Number(n.n)).toBe(10_010);
    await s.get("/v1/reports/month?month=2026-11"); // 预热
    const times: number[] = [];
    for (let i = 0; i < 5; i++) {
      const t0 = performance.now();
      const m = await s.get("/v1/reports/month?month=2026-11");
      times.push(performance.now() - t0);
      expect(m.sold_fen).toBe(10_000 * 300 - 50 * 10);
    }
    times.sort((x, y) => x - y);
    console.log(`月报耗时（ms）：${times.map((x) => x.toFixed(1)).join(", ")}`);
    expect(times[2]!).toBeLessThan(300);
  }, 120_000);
});
