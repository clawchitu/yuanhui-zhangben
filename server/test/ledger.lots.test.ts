// S06：保质期批次与处理快过期经 /v1/sync 写库（§5.4、§4.3 expiry_dispose / lot_snooze、§4.4 stale）。
// expiry.json 的 dispose / undo 两组在这里逐条跑；验收里批次的几条场景、四个处理动作各一条；收银员裁剪覆盖批次和新流水种类。
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { assertDbLedger } from "./helpers/ledger.ts";
import { CONTRACTS_DIR } from "./helpers/contract.ts";
import { allKeys, op, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";
import { shouldRemind } from "../src/ledger/lots.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
const V = JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "vectors", "expiry.json"), "utf8")) as Any;

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

/** 上海某天中午的 UTC 时间 */
const noon = (day: string) => `${day}T04:00:00.000Z`;
const AT = noon("2026-11-20");

/** today：服务器时间取上海这天下午（op 时间不晚于服务器，不触发时钟校正）；不给就用真实时间 */
async function setup(today?: string) {
  const shop = await makeLoginShop(tdb);
  const app = today ? makeApp(tdb, { clock: new TestClock(Date.parse(noon(today)) + 3600_000) }) : makeApp(tdb);
  const boss = await login(app, shop.username);
  const send = async (...ops: ReturnType<typeof op>[]) => (await syncOk(app, boss.token, { epoch: shop.epoch, ops, pull: false })).results;
  const newProduct = async (track = true) => {
    const u = upsertFull({ extra: { track_expiry: track, expiry_warn_days: 7 } });
    await send(u);
    return u.payload.product_id as string;
  };
  return { shop, app, boss, send, newProduct };
}
const S = (storeId: string) => ({
  product: (id: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow(),
  lots: (pid: string) =>
    tdb.kysely
      .selectFrom("stock_lots as l")
      .innerJoin("entries as e", (j) => j.onRef("e.store_id", "=", "l.store_id").onRef("e.id", "=", "l.source_entry_id"))
      .selectAll("l")
      .where("l.store_id", "=", storeId)
      .where("l.product_id", "=", pid)
      .orderBy("e.seq")
      .execute(),
  lot: (id: string) => tdb.kysely.selectFrom("stock_lots").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow(),
  moves: () => tdb.kysely.selectFrom("lot_moves").selectAll().where("store_id", "=", storeId).execute(),
  entry: (id: string) => tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow(),
  /** 赚了 = Σ 进价已知的卖出行 (amount − cogs) + Σ cost_fix (amount − cogs)（§5.3） */
  profit: async () => {
    const es = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).execute();
    return es.filter((e) => (e.type === "sale" && !e.cost_missing) || e.type === "cost_fix").reduce((x, e) => x + Number(e.amount_fen) - Number(e.cogs_fen), 0);
  },
});
const stockIn = (pid: string, n: number, unit: number, expiry_date?: string) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit, ...(expiry_date ? { expiry_date } : {}) }, { at: AT });
const sale = (pid: string, n: number, price = 300) =>
  op(
    "sale_batch",
    {
      batch_id: randomUUID(),
      paid_total_fen: n * price,
      lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: n, unit_price_fen: price }],
    },
    { at: AT },
  );
const lineOf = (s: ReturnType<typeof sale>) => (s.payload.lines as Any[])[0].entry_id as string;
const voidEntry = (entry_id: string) => op("void", { target: { entry_id } }, { at: AT });
const dispose = (lot_id: string, handle_ver: number, action: string, actual_qty: number, at = AT) =>
  op("expiry_dispose", { lot_id, handle_ver, actual_qty, action, entry_id: randomUUID() }, { at });
const snooze = (lot_id: string, handle_ver: number, actual_qty: number, days: number, at = AT) => op("lot_snooze", { lot_id, handle_ver, actual_qty, days }, { at });
const setHandle = (storeId: string, id: string, handle_ver: number) => tdb.kysely.updateTable("stock_lots").set({ handle_ver }).where("store_id", "=", storeId).where("id", "=", id).execute();

describe("批次的生成与扣减（§5.4）", () => {
  it("管保质期的商品每次进货 / 期初生成一个批次（没填到期日也生成）；不管保质期的不生成", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    const si = stockIn(pid, 5, 100, "2026-12-01");
    const si2 = stockIn(pid, 3, 100);
    await send(si, si2);
    const ls = await db.lots(pid);
    expect(ls.map((l) => [l.source_entry_id, l.expiry_date, l.qty_in, l.qty_left, l.closed_at, l.handle_ver])).toEqual([
      [si.payload.entry_id, "2026-12-01", 5, 5, null, 0],
      [si2.payload.entry_id, null, 3, 3, null, 0],
    ]);
    const other = await newProduct(false);
    await send(stockIn(other, 5, 100, "2026-12-01"), op("opening", { entry_id: randomUUID(), product_id: other, counted_qty: 9 }, { at: AT }));
    expect(await db.lots(other)).toEqual([]);
    const p2 = await newProduct();
    const o = op("opening", { entry_id: randomUUID(), product_id: p2, counted_qty: 4, unit_cost_fen: 100, expiry_date: "2027-01-01" }, { at: AT });
    await send(o);
    expect((await db.lots(p2)).map((l) => [l.source_entry_id, l.expiry_date, l.qty_in, l.qty_left])).toEqual([[o.payload.entry_id, "2027-01-01", 4, 4]]);
    await app.close();
  });

  it("卖出按到期日从早到晚扣（空日期最后），写 lot_moves；撤销后各批次数量与卖出前逐一相等", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 3, 100, "2026-12-01"), stockIn(pid, 5, 100), stockIn(pid, 2, 100, "2026-11-25"));
    const before = (await db.lots(pid)).map((l) => l.qty_left);
    const s = sale(pid, 6);
    await send(s);
    expect((await db.lots(pid)).map((l) => l.qty_left)).toEqual([0, 4, 0]);
    const ms = await db.moves();
    expect(ms.every((m) => m.entry_id === lineOf(s))).toBe(true);
    expect(ms.map((m) => m.qty).sort()).toEqual([1, 2, 3]);
    await send(voidEntry(lineOf(s)));
    expect((await db.lots(pid)).map((l) => l.qty_left)).toEqual(before);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("盘亏也按到期日扣批次；盘盈不动批次", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 3, 100, "2026-12-01"), stockIn(pid, 3, 100, "2026-11-25"));
    const v = Number((await db.product(pid)).stock_ver);
    const c = op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 2, base_qty: 6, base_ver: v }, { at: AT });
    await send(c);
    expect((await db.lots(pid)).map((l) => l.qty_left)).toEqual([2, 0]);
    expect((await db.moves()).map((m) => [m.entry_id, m.qty]).sort()).toEqual([[c.payload.entry_id, 1], [c.payload.entry_id, 3]].sort());
    const c2 = op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 9, base_qty: 2, base_ver: v + 1 }, { at: AT });
    await send(c2);
    expect((await db.lots(pid)).map((l) => l.qty_left)).toEqual([2, 0]);
    await send(voidEntry(c.payload.entry_id as string));
    expect((await db.lots(pid)).map((l) => l.qty_left)).toEqual([3, 3]);
    await app.close();
  });

  it("已有销售后撤销来源进货 → 批次关闭（voided）、lot_moves 保留、I1–I3 成立", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    const si = stockIn(pid, 5, 100, "2026-12-01");
    await send(si, sale(pid, 2));
    await send(voidEntry(si.payload.entry_id as string));
    const [l] = await db.lots(pid);
    expect([l!.closed_reason, l!.closed_at !== null, l!.qty_left]).toEqual(["voided", true, 3]);
    expect(await db.moves()).toHaveLength(1);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("扔掉 → 撤销来源进货 → 再撤销「扔掉」：库存加回，批次不重开、改记 voided（来源已撤销的批次不再提醒）", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    const si = stockIn(pid, 5, 100, "2026-12-01");
    await send(si);
    const [l0] = await db.lots(pid);
    const d = dispose(l0!.id, 0, "discard", 2);
    await send(d);
    await send(voidEntry(si.payload.entry_id as string));
    expect((await db.lot(l0!.id)).closed_reason).toBe("disposed"); // 已关闭的不改
    await send(voidEntry(d.payload.entry_id as string));
    const l = await db.lot(l0!.id);
    expect([l.closed_at !== null, l.closed_reason, l.qty_left, l.handle_ver]).toEqual([true, "voided", 5, 1]);
    expect((await db.product(pid)).stock_qty).toBe(0);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });
});

describe("处理快过期（expiry_dispose / lot_snooze）", () => {
  it("扔掉：减库存、减货值、记 expire_loss（按平均进价），不改变「赚了」；flags 存处理前 qty_left；handle_ver + 1", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 1, 100, "2026-11-25"), stockIn(pid, 2, 250, "2026-11-25"), sale(pid, 1));
    const profit = await db.profit();
    const p0 = await db.product(pid);
    const [l] = await db.lots(pid);
    const d = dispose(l!.id, 0, "discard", 1);
    expect(await send(d)).toEqual([{ id: d.id, status: "applied" }]);
    const e = await db.entry(d.payload.entry_id as string);
    // 卖了 1 后 q = 2、v = 600 − 200 = 400 → 扔 1 个，按平均 200
    expect([e.type, e.qty_delta, Number(e.cogs_fen), Number(e.value_delta_fen), Number(e.amount_fen), e.flags]).toEqual(["expire_loss", -1, 200, -200, 0, { lot_id: l!.id, qty_left_before: 0 }]);
    const p = await db.product(pid);
    expect([p.stock_qty, Number(p.stock_value_fen), Number(p.stock_ver)]).toEqual([p0.stock_qty - 1, Number(p0.stock_value_fen) - 200, Number(p0.stock_ver) + 1]);
    const lot = await db.lot(l!.id);
    expect([lot.closed_reason, lot.handle_ver]).toEqual(["disposed", 1]);
    expect(await db.profit()).toBe(profit);
    expect(await send(d)).toEqual([{ id: d.id, status: "applied", replayed: true }]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("退货：记 supplier_return，cogs 0（不计盈亏），货值按平均进价减", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 4, 150, "2026-11-25"));
    const [l] = await db.lots(pid);
    const d = dispose(l!.id, 0, "return", 3);
    await send(d);
    const e = await db.entry(d.payload.entry_id as string);
    expect([e.type, e.qty_delta, Number(e.cogs_fen), Number(e.value_delta_fen)]).toEqual(["supplier_return", -3, 0, -450]);
    const p = await db.product(pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([1, 150]);
    expect(await db.profit()).toBe(0);
    await app.close();
  });

  it("卖完了：关批次、不动库存、不记流水", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 4, 150, "2026-11-25"));
    const p0 = await db.product(pid);
    const [l] = await db.lots(pid);
    const d = dispose(l!.id, 0, "sold_out", 0);
    await send(d);
    const p = await db.product(pid);
    expect([p.stock_qty, p.stock_value_fen, p.stock_ver]).toEqual([p0.stock_qty, p0.stock_value_fen, p0.stock_ver]);
    const n = await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("id", "=", d.payload.entry_id as string).execute();
    expect(n).toEqual([]);
    expect((await db.lot(l!.id)).closed_reason).toBe("disposed");
    await app.close();
  });

  it("过几天再提醒：批次数量改成实际数、snoozed_until = 今天 + 天数，期内不提醒，到期后重新出现", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 5, 100, "2026-11-22"));
    const [l] = await db.lots(pid);
    const remind = async (today: string) => {
      const x = await db.lot(l!.id);
      return shouldRemind(today, { expiry_date: x.expiry_date as string | null, expiry_warn_days: 7, qty_left: x.qty_left, closed: x.closed_at !== null, snoozed_until: x.snoozed_until as string | null });
    };
    expect(await remind("2026-11-20")).toBe(true);
    const s = snooze(l!.id, 0, 4, 3);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    const x = await db.lot(l!.id);
    expect([x.qty_left, x.snoozed_until, x.handle_ver, x.closed_at]).toEqual([4, "2026-11-23", 1, null]);
    expect((await db.product(pid)).stock_qty).toBe(5);
    expect(await remind("2026-11-22")).toBe(false);
    expect(await remind("2026-11-23")).toBe(true);
    await app.close();
  });

  it("两台设备带同一个 handle_ver 各提交一次「扔掉 2 个」→ 只成功一次，另一次 stale 带回批次状态", async () => {
    const { shop, app, boss, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, 5, 100, "2026-11-25"));
    const [l] = await db.lots(pid);
    const other = await pair(app, boss.token, "family", "老板娘");
    const a = dispose(l!.id, 0, "discard", 2);
    const b = dispose(l!.id, 0, "discard", 2);
    expect(await send(a)).toEqual([{ id: a.id, status: "applied" }]);
    const rb = (await syncOk(app, other.token, { epoch: shop.epoch, ops: [b], pull: false })).results;
    expect(rb).toEqual([{ id: b.id, status: "rejected", code: "stale", current: { qty_left: 5, handle_ver: 1, closed: true } }]);
    expect((await db.product(pid)).stock_qty).toBe(3);
    // snooze 也校验 handle_ver
    const s = snooze(l!.id, 0, 1, 3);
    expect((await send(s))[0]).toMatchObject({ status: "rejected", code: "stale" });
    await app.close();
  });

  it("批次处理（关闭）后再撤销此前的卖出 → 批次不重开、不加回；撤销「扔掉」→ 批次重开且数量恢复为处理前", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    const s = sale(pid, 2);
    await send(stockIn(pid, 5, 100, "2026-11-25"), s);
    const [l] = await db.lots(pid);
    const d = dispose(l!.id, 0, "discard", 2);
    await send(d);
    await send(voidEntry(lineOf(s)));
    let x = await db.lot(l!.id);
    expect([x.closed_reason, x.qty_left]).toEqual(["disposed", 3]);
    await send(voidEntry(d.payload.entry_id as string));
    x = await db.lot(l!.id);
    expect([x.closed_at, x.closed_reason, x.qty_left, x.handle_ver]).toEqual([null, null, 3, 1]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("批次不存在 → rejected invalid 并留档；进价未知时扔掉金额 0、标 cost_missing", async () => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const ghost = dispose(randomUUID(), 0, "discard", 1);
    const ghost2 = snooze(randomUUID(), 0, 1, 3);
    expect(await send(ghost, ghost2)).toEqual([
      { id: ghost.id, status: "rejected", code: "invalid" },
      { id: ghost2.id, status: "rejected", code: "invalid" },
    ]);
    const logged = await tdb.kysely.selectFrom("ops").select("id").where("store_id", "=", shop.storeId).where("id", "in", [ghost.id, ghost2.id]).execute();
    expect(logged).toHaveLength(2);
    const pid = await newProduct();
    await send(op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 4 }, { at: AT }));
    const [l] = await db.lots(pid);
    const d = dispose(l!.id, 0, "discard", 1);
    await send(d);
    const e = await db.entry(d.payload.entry_id as string);
    expect([e.qty_delta, Number(e.cogs_fen), Number(e.value_delta_fen), e.cost_missing]).toEqual([-1, 0, 0, true]);
    await app.close();
  });
});

describe("expiry.json dispose / undo 经 /v1/sync", () => {
  it.each(V.dispose as Any[])("dispose $id：$note", async (c) => {
    const { shop, app, send, newProduct } = await setup(c.today);
    const db = S(shop.storeId);
    const pid = await newProduct();
    await send(stockIn(pid, c.lot.qty_left, 100, "2026-12-31"));
    const [l] = await db.lots(pid);
    await setHandle(shop.storeId, l!.id, c.lot.handle_ver);
    const o =
      c.op.action === "snooze"
        ? snooze(l!.id, c.op.handle_ver, c.op.actual_qty, c.op.days, noon(c.today))
        : dispose(l!.id, c.op.handle_ver, c.op.action, c.op.actual_qty, noon(c.today));
    expect(await send(o)).toEqual([{ id: o.id, status: "applied" }]);
    const x = await db.lot(l!.id);
    const got: Record<string, unknown> = { closed: x.closed_at !== null, handle_ver: x.handle_ver };
    if ("closed_reason" in c.expected.lot) got.closed_reason = x.closed_reason;
    if ("qty_left" in c.expected.lot) got.qty_left = x.qty_left;
    if ("snoozed_until" in c.expected.lot) got.snoozed_until = x.snoozed_until;
    expect(got).toEqual(c.expected.lot);
    const es = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).where("op_id", "=", o.id).execute();
    if (c.expected.entry === null) expect(es).toEqual([]);
    else {
      expect(es.map((e) => ({ type: e.type, qty_delta: e.qty_delta }))).toEqual([c.expected.entry]);
      expect((es[0]!.flags as Any).qty_left_before).toBe(c.expected.flags_qty_left_before);
    }
    await app.close();
  });

  it.each(V.undo as Any[])("undo $id：$note", async (c) => {
    const { shop, app, send, newProduct } = await setup();
    const db = S(shop.storeId);
    const pid = await newProduct();
    let lotId: string;
    if (c.event === "void_discard" || c.event === "void_return") {
      await send(stockIn(pid, c.lot_before.qty_left_before_dispose, 100, "2026-12-31"));
      lotId = (await db.lots(pid))[0]!.id;
      const d = dispose(lotId, 0, c.event === "void_discard" ? "discard" : "return", 2);
      await send(d);
      expect((await db.lot(lotId)).closed_reason).toBe(c.lot_before.closed_reason);
      await send(voidEntry(d.payload.entry_id as string));
    } else if (c.event === "void_sale") {
      const s = sale(pid, c.lot_move_qty);
      await send(stockIn(pid, c.lot_before.qty_left + c.lot_move_qty, 100, "2026-12-31"), s);
      lotId = (await db.lots(pid))[0]!.id;
      expect((await db.moves()).map((m) => m.qty)).toEqual([c.lot_move_qty]);
      if (c.lot_before.closed) await send(dispose(lotId, 0, "sold_out", 0));
      await send(voidEntry(lineOf(s)));
    } else {
      const si = stockIn(pid, c.lot_before.qty_left, 100, "2026-12-31");
      await send(si);
      lotId = (await db.lots(pid))[0]!.id;
      await send(voidEntry(si.payload.entry_id as string));
    }
    const x = await db.lot(lotId);
    const got: Record<string, unknown> = { closed: x.closed_at !== null, qty_left: x.qty_left };
    if ("closed_reason" in c.expected) got.closed_reason = x.closed_reason;
    expect(got).toEqual(c.expected);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });
});

describe("收银员（§4.2 按角色裁剪、§6）", () => {
  it("收银员发 expiry_dispose / lot_snooze 被拒 forbidden；拉取里没有批次、没有损耗 / 退货 / 盘点流水、没有批次相关的键；家用全有", async () => {
    // 冻结在 AT 那天：用真实时钟的话一过上海 11-22 零点，收银员 2 天的流水窗口（§4.2）就不含 AT 的卖出了
    const { shop, app, boss, send, newProduct } = await setup("2026-11-20");
    const db = S(shop.storeId);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const pid = await newProduct();
    await send(stockIn(pid, 6, 100, "2026-11-25"), stockIn(pid, 6, 100, "2026-11-28"));
    const [l1, l2] = await db.lots(pid);
    const cd = dispose(l1!.id, 0, "discard", 1);
    const cs = snooze(l1!.id, 0, 1, 3);
    const rc = (await syncOk(app, cas.token, { epoch: shop.epoch, ops: [cd, cs], pull: false })).results;
    expect(rc).toEqual([
      { id: cd.id, status: "rejected", code: "forbidden" },
      { id: cs.id, status: "rejected", code: "forbidden" },
    ]);
    // 收银员卖一笔（扣批次），家用扔掉 / 退货 / 盘点
    await syncOk(app, cas.token, { epoch: shop.epoch, ops: [sale(pid, 1)], pull: false });
    const v = Number((await db.product(pid)).stock_ver);
    await send(dispose(l1!.id, 0, "discard", 2), dispose(l2!.id, 0, "return", 1), op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 3, base_qty: 0, base_ver: v + 2 }, { at: AT }));
    const types = (await tdb.kysely.selectFrom("entries").select("type").where("store_id", "=", shop.storeId).execute()).map((e) => e.type);
    expect(new Set(types)).toEqual(new Set(["stock_in", "sale", "expire_loss", "supplier_return", "count"]));

    const body = await syncOk(app, cas.token, { epoch: shop.epoch });
    expect(body.has_more).toEqual({ catalog: false, ledger: false });
    const snap = (await pullAll(app, cas.token, shop.epoch)).snapshot();
    expect(snap.lots).toEqual([]);
    expect(snap.entries.map((e: Any) => e.type)).toEqual(["sale"]);
    const FORBIDDEN_KEY = /cost|value|stock|cogs|qty_left|qty_in|handle_ver|snooze|lot_id|expiry_date/i;
    expect([...allKeys(body)].filter((k) => FORBIDDEN_KEY.test(k))).toEqual([]);
    const fam = (await pullAll(app, boss.token, shop.epoch)).snapshot();
    expect(fam.lots).toHaveLength(2);
    expect(new Set(fam.entries.map((e: Any) => e.type))).toEqual(new Set(types));
    await app.close();
  });
});

describe("撤销加回批次的溢出预检查（PR #16 Codex 2，§14 S05-4）", () => {
  it("推迟提醒把批次数量改回、卖出、再逐笔撤销：加回后 qty_left 超出 integer 的那次撤销拒 invalid 并留档，整个 op 回滚，重发结果不变", { timeout: 180_000 }, async () => {
    const { shop, app, send, newProduct } = await setup();
    const s = S(shop.storeId);
    const pid = await newProduct();
    const BIG = 9_999_000;
    const bigSale = () =>
      op("sale_batch", {
        batch_id: randomUUID(),
        paid_total_fen: 0,
        lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "箱", pack_qty: 9_999, pack_count: 1_000, unit_price_fen: 0 }],
      }, { at: AT });
    await send(op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 9_999, pack_count: 1_000, unit_cost_fen: 0 }, { at: AT }));
    const [lot] = await s.lots(pid);
    // 每一轮：卖 9,999,000（扣批次到 0）→ 人数了说还有 9,999,999，过几天再提醒（批次数量改成实际数）
    const N = 214;
    const sales: string[] = [];
    const ops: ReturnType<typeof op>[] = [];
    for (let i = 0; i < N; i++) {
      const sl = bigSale();
      sales.push(lineOf(sl));
      ops.push(sl, snooze(lot!.id, i, 9_999_999, 1));
    }
    for (let i = 0; i < ops.length; i += 200) expect((await send(...ops.slice(i, i + 200))).every((r: Any) => r.status === "applied")).toBe(true);
    expect((await s.lot(lot!.id)).qty_left).toBe(9_999_999);
    // 前 213 笔撤销：每笔按 lot_moves 加回 9,999,000 → 9,999,999 + 213 × 9,999,000 = 2,139,786,999
    const voids = sales.map((e) => voidEntry(e));
    for (let i = 0; i < N - 1; i += 200) expect((await send(...voids.slice(i, Math.min(i + 200, N - 1)))).every((r: Any) => r.status === "applied")).toBe(true);
    expect((await s.lot(lot!.id)).qty_left).toBe(9_999_999 + (N - 1) * BIG);
    const before = await s.product(pid);
    // 第 214 笔：再加回 9,999,000 超出 integer 上界（商品库存本身仍合法）
    const last = voids[N - 1]!;
    expect(await send(last)).toEqual([{ id: last.id, status: "rejected", code: "invalid" }]);
    const after = await s.product(pid);
    expect([after.stock_qty, after.stock_value_fen, after.stock_ver]).toEqual([before.stock_qty, before.stock_value_fen, before.stock_ver]);
    expect((await s.entry(sales[N - 1]!)).voided_at).toBeNull();
    expect((await s.lot(lot!.id)).qty_left).toBe(9_999_999 + (N - 1) * BIG);
    const reversals = await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("reverses_entry_id", "=", sales[N - 1]!).execute();
    expect(reversals).toEqual([]);
    const archived = await tdb.kysely.selectFrom("ops").select(["status", "reject_code"]).where("store_id", "=", shop.storeId).where("id", "=", last.id).executeTakeFirstOrThrow();
    expect(archived).toEqual({ status: "rejected", reject_code: "invalid" });
    expect(await send(last)).toEqual([{ id: last.id, status: "rejected", code: "invalid", replayed: true }]);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });
});
