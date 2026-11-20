// S05b 第 (2) 步：void 经 /v1/sync 写库（§3.3、§4.4、§5.2、§6，§14 S05-6 ④⑤⑥⑧）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { allKeys, op, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";
import { assertDbLedger as assertDbLedgerIn } from "./helpers/ledger.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const AT = "2026-11-20T01:59:00Z";
async function setup() {
  const shop = await makeLoginShop(tdb);
  const clock = new TestClock();
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const sendAs = async (token: string, ...ops: ReturnType<typeof op>[]) => (await syncOk(app, token, { epoch: shop.epoch, ops, pull: false })).results;
  const send = (...ops: ReturnType<typeof op>[]) => sendAs(boss.token, ...ops);
  const newProduct = async () => {
    const u = upsertFull();
    await send(u);
    return u.payload.product_id as string;
  };
  return { shop, clock, app, boss, send, sendAs, newProduct };
}
const product = (storeId: string, id: string) =>
  tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", id).executeTakeFirstOrThrow();
const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const opening = (pid: string, counted_qty: number, extra: Record<string, unknown> = {}) => op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty, ...extra }, { at: AT });
const stockIn = (pid: string, n: number, unit: number) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit }, { at: AT });
const saleOf = (paid: number, lines: Array<{ pid: string; price: number; count?: number }>, at = AT) =>
  op("sale_batch", {
    batch_id: randomUUID(),
    paid_total_fen: paid,
    lines: lines.map((l) => ({ entry_id: randomUUID(), product_id: l.pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: l.count ?? 1, unit_price_fen: l.price })),
  }, { at });
const lineIds = (s: ReturnType<typeof saleOf>) => (s.payload.lines as Array<{ entry_id: string }>).map((l) => l.entry_id);
const batchId = (s: ReturnType<typeof saleOf>) => s.payload.batch_id as string;
const voidOp = (target: Record<string, string>, at = "2026-11-20T01:59:30Z") => op("void", { target }, { at });

const assertDbLedger = (storeId: string, pid: string) => assertDbLedgerIn(tdb.kysely, storeId, pid);

describe("撤销写库（④）", () => {
  it("整批：每行冲销、occurred_at 是撤销时间、原行 voided_at、paid_total_fen 不改；撤销两次第二次无操作；重放返回第一次结果", async () => {
    const { shop, app, send, newProduct } = await setup();
    const [a, b] = [await newProduct(), await newProduct()];
    await send(opening(a, 10, { unit_cost_fen: 100 }), opening(b, 10, { unit_cost_fen: 50 }));
    const s = saleOf(500, [{ pid: a, price: 300 }, { pid: b, price: 250, count: 2 }]);
    await send(s);
    const v = voidOp({ batch_id: batchId(s) });
    expect(await send(v)).toEqual([{ id: v.id, status: "applied" }]);
    for (const [pid, q, val] of [[a, 10, 1000], [b, 10, 500]] as const) {
      const { es, p } = await assertDbLedger(shop.storeId, pid);
      expect([p.stock_qty, Number(p.stock_value_fen), Number(p.stock_ver)]).toEqual([q, val, 3]);
      const rev = es.find((e) => e.reverses_entry_id !== null)!;
      expect(rev.occurred_at.toISOString()).toBe("2026-11-20T01:59:30.000Z");
      expect(rev.batch_id).toBe(batchId(s));
      expect(es.find((e) => e.id === rev.reverses_entry_id)!.voided_at!.toISOString()).toBe("2026-11-20T01:59:30.000Z");
    }
    const batch = await tdb.kysely.selectFrom("sale_batches").selectAll().where("store_id", "=", shop.storeId).where("id", "=", batchId(s)).executeTakeFirstOrThrow();
    expect(Number(batch.paid_total_fen)).toBe(500);
    const again = voidOp({ batch_id: batchId(s) });
    const single = voidOp({ entry_id: lineIds(s)[0]! });
    expect(await send(again, single)).toEqual([{ id: again.id, status: "applied" }, { id: single.id, status: "applied" }]);
    expect(await send(v)).toEqual([{ id: v.id, status: "applied", replayed: true }]);
    expect((await entriesOf(shop.storeId, a)).length).toBe(3);
    await app.close();
  });

  it("单行：只撤那一行，同批另一行不动；I4：未撤销 + 已撤销各行实收 = paid_total_fen", async () => {
    const { shop, app, send, newProduct } = await setup();
    const [a, b] = [await newProduct(), await newProduct()];
    await send(opening(a, 5, { unit_cost_fen: 100 }), opening(b, 5, { unit_cost_fen: 100 }));
    const s = saleOf(5300, [{ pid: a, price: 2500 }, { pid: b, price: 2850 }]);
    await send(s);
    const v = voidOp({ entry_id: lineIds(s)[1]! });
    expect(await send(v)).toEqual([{ id: v.id, status: "applied" }]);
    expect((await product(shop.storeId, a)).stock_qty).toBe(4);
    expect((await product(shop.storeId, b)).stock_qty).toBe(5);
    const lines = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).where("batch_id", "=", batchId(s)).where("reverses_entry_id", "is", null).execute();
    expect(lines.reduce((x, e) => x + Number(e.amount_fen), 0)).toBe(5300);
    expect(lines.map((e) => e.voided_at !== null).sort()).toEqual([false, true]);
    await assertDbLedger(shop.storeId, a);
    await assertDbLedger(shop.storeId, b);
    await app.close();
  });

  it("撤销进货、期初；找不到的 target、冲销行、cost_adjust 行 → invalid 并留档", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    const si1 = stockIn(pid, 10, 100);
    const si2 = stockIn(pid, 10, 10);
    await send(si1, si2, saleOf(500, [{ pid, price: 100, count: 5 }]));
    // 撤销归位向量：q = 5，v = −175，c = 10 → 归位到 50，cost_adjust +225
    await send(voidOp({ entry_id: si1.payload.entry_id as string }));
    const { es, p } = await assertDbLedger(shop.storeId, pid);
    expect([p.stock_qty, Number(p.stock_value_fen)]).toEqual([5, 50]);
    expect(es.slice(-2).map((e) => [e.type, Number(e.value_delta_fen)])).toEqual([["stock_in", -1000], ["cost_adjust", 225]]);
    const bad = [voidOp({ entry_id: randomUUID() }), voidOp({ batch_id: randomUUID() }), voidOp({ entry_id: es.at(-2)!.id }), voidOp({ entry_id: es.at(-1)!.id })];
    expect(await send(...bad)).toEqual(bad.map((o) => ({ id: o.id, status: "rejected", code: "invalid" })));
    const logged = await tdb.kysely.selectFrom("ops").select("status").where("store_id", "=", shop.storeId).where("id", "in", bad.map((o) => o.id)).execute();
    expect(logged.length).toBe(4);
    await assertDbLedger(shop.storeId, pid);
    await app.close();
  });
});

describe("补记写库（⑤）", () => {
  it("补记后撤销三条流水；同一条 cost_fix 被冲两次，用原补记的 b（进价之后改了也一样）；净额 = 仍有效的被补记卖出", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 10));
    const s1 = saleOf(300, [{ pid, price: 300 }]);
    const s2 = saleOf(600, [{ pid, price: 300, count: 2 }]);
    const s3 = saleOf(900, [{ pid, price: 300, count: 3 }]);
    await send(s1, s2, s3, stockIn(pid, 1, 200));
    let es = await entriesOf(shop.storeId, pid);
    const fix = es.find((e) => e.type === "cost_fix")!;
    expect(es.filter((e) => e.type === "sale").every((e) => e.cost_fix_entry_id === fix.id)).toBe(true);
    // 改变当前进价，再撤两笔
    await send(stockIn(pid, 10, 999));
    await send(voidOp({ batch_id: batchId(s2) }));
    await send(voidOp({ entry_id: lineIds(s3)[0]! }));
    ({ es } = await assertDbLedger(shop.storeId, pid));
    const tail = es.slice(-6).map((e) => [e.type, e.reverses_entry_id === null ? null : e.reverses_entry_id === fix.id ? "fix" : "sale", Number(e.amount_fen), Number(e.cogs_fen), Number(e.value_delta_fen)]);
    expect(tail).toEqual([
      ["sale", "sale", -600, 0, 0],
      ["cost_fix", "fix", -600, -400, 0],
      ["cost_adjust", null, 0, 0, 400],
      ["sale", "sale", -900, 0, 0],
      ["cost_fix", "fix", -900, -600, 0],
      ["cost_adjust", null, 0, 0, 600],
    ]);
    await app.close();
  });
});

describe("收银员撤销与被踢设备（§6、⑧）", () => {
  it("收银员：当天撤本机的成功；别机的、进货、昨天的（含伪造 occurred_at）被拒 forbidden", async () => {
    const { shop, clock, app, boss, send, sendAs, newProduct } = await setup();
    const cashier = await pair(app, boss.token, "cashier", "收银台");
    const pid = await newProduct();
    await send(opening(pid, 10, { unit_cost_fen: 100 }));
    const mine = saleOf(300, [{ pid, price: 300 }]);
    const mine2 = saleOf(300, [{ pid, price: 300 }]);
    const theirs = saleOf(300, [{ pid, price: 300 }]);
    const si = stockIn(pid, 1, 100);
    await sendAs(cashier.token, mine, mine2);
    await send(theirs, si);
    const ok = voidOp({ entry_id: lineIds(mine)[0]! });
    const other = voidOp({ batch_id: batchId(theirs) });
    const stock = voidOp({ entry_id: si.payload.entry_id as string });
    expect(await sendAs(cashier.token, ok, other, stock)).toEqual([
      { id: ok.id, status: "applied" },
      { id: other.id, status: "rejected", code: "forbidden" },
      { id: stock.id, status: "rejected", code: "forbidden" },
    ]);
    clock.advance(24 * 3600e3);
    const late = voidOp({ batch_id: batchId(mine2) }, "2026-11-20T02:00:00Z");
    const forged = voidOp({ entry_id: lineIds(mine2)[0]! }, "2026-11-20T01:59:59Z");
    expect(await sendAs(cashier.token, late, forged)).toEqual([late, forged].map((o) => ({ id: o.id, status: "rejected", code: "forbidden" })));
    await assertDbLedger(shop.storeId, pid);
    await app.close();
  });

  it("被踢设备：卖出直接入账带 late_from_revoked；进货 / 期初 / 撤销进 held，什么都不记", async () => {
    const { shop, app, boss, send, sendAs, newProduct } = await setup();
    const other = await pair(app, boss.token, "family", "旧手机");
    const pid = await newProduct();
    await send(opening(pid, 10, { unit_cost_fen: 100 }));
    const before = saleOf(300, [{ pid, price: 300 }]);
    await send(before);
    const r = await app.inject({ method: "POST", url: `/v1/devices/${other.deviceId}/revoke`, headers: bearer(boss.token) });
    expect(r.statusCode).toBe(204);
    const s = saleOf(300, [{ pid, price: 300 }]);
    const held = [stockIn(pid, 1, 100), opening(pid, 3, { base_ver: 2 }), voidOp({ batch_id: batchId(before) })];
    const res = await sendAs(other.token, s, ...held);
    expect(res).toEqual([{ id: s.id, status: "applied" }, ...held.map((o) => ({ id: o.id, status: "held" }))]);
    const es = await entriesOf(shop.storeId, pid);
    expect(es.map((e) => [e.type, (e.flags as Record<string, unknown>).late_from_revoked ?? false, e.voided_at])).toEqual([
      ["opening", false, null],
      ["sale", false, null],
      ["sale", true, null],
    ]);
    await assertDbLedger(shop.storeId, pid);
    await app.close();
  });
});

describe("收银员拉到真实流水（⑨）", () => {
  /** 与 sync.projection.test.ts 同一份：收银员响应里不许出现的键（§3.4、§4.2） */
  const FORBIDDEN_KEY = /cost|value|stock|low_at|private|cogs|expiry_warn|shelf_life|last_count|qty_left|qty_in|handle_ver|snooze|lot_id/i;

  it("经 /v1/sync 写出期初、进货、补记、撤销后：收银员响应逐页递归没有成本键，只收到本机的卖出（含本机撤销的冲销行）", async () => {
    const { shop, clock, app, boss, send, sendAs, newProduct } = await setup();
    const cashier = await pair(app, boss.token, "cashier", "收银台");
    const pid = await newProduct();
    await send(opening(pid, 10));
    const s1 = saleOf(300, [{ pid, price: 300 }]);
    const s2 = saleOf(600, [{ pid, price: 300, count: 2 }]);
    await sendAs(cashier.token, s1, s2);
    await send(stockIn(pid, 1, 200)); // 进价变已知 → cost_fix 补记收银员的两笔卖出
    const v1 = voidOp({ entry_id: lineIds(s1)[0]! });
    const v2 = voidOp({ batch_id: batchId(s2) });
    expect(await sendAs(cashier.token, v1)).toEqual([{ id: v1.id, status: "applied" }]);
    expect(await send(v2)).toEqual([{ id: v2.id, status: "applied" }]);
    const { es } = await assertDbLedger(shop.storeId, pid);
    // 前提：库里确实有这几种行，且有的是收银员这台设备写的
    expect(new Set(es.map((e) => e.type))).toEqual(new Set(["opening", "stock_in", "sale", "cost_fix", "cost_adjust"]));
    expect(es.some((e) => e.device_id === cashier.deviceId && e.type !== "sale")).toBe(true);

    // 页大小 1，逐页收集收银员的整个响应
    const small = makeApp(tdb, { clock: new TestClock(clock.now().getTime()), syncPageSize: 1 });
    const bodies: unknown[] = [];
    const seen: Array<{ id: string; type: string; device_id: string }> = [];
    let cursors = { catalog: 0, ledger: 0 };
    for (;;) {
      const b = await syncOk(small, cashier.token, { epoch: shop.epoch, cursors });
      bodies.push(b);
      seen.push(...(b.changes.entries as typeof seen));
      cursors = b.cursors;
      if (!b.has_more.catalog && !b.has_more.ledger) break;
    }
    await small.close();
    const keys = new Set<string>();
    for (const b of bodies) allKeys(b, keys);
    expect([...keys].filter((k) => FORBIDDEN_KEY.test(k))).toEqual([]);

    const mineSale = es.filter((e) => e.type === "sale" && e.device_id === cashier.deviceId).map((e) => e.id).sort();
    expect(mineSale.length).toBe(3); // s1、s2 各一行，加收银员撤 s1 的冲销行；家用撤 s2 的冲销行不是本机的
    expect(seen.map((e) => e.id).sort()).toEqual(mineSale);
    expect(seen.every((e) => e.type === "sale" && e.device_id === cashier.deviceId)).toBe(true);
    for (const t of ["stock_in", "opening", "cost_adjust", "cost_fix"]) expect(seen.some((e) => e.type === t)).toBe(false);

    // 对照：家用拿得到全部这些行和成本键
    const family = await pullAll(app, boss.token, shop.epoch);
    await app.close();
    expect(new Set(family.snapshot().entries.map((e: { type: string }) => e.type))).toEqual(new Set(["opening", "stock_in", "sale", "cost_fix", "cost_adjust"]));
  });
});
