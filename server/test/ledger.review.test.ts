// S05b 返修（PR #13 的 Codex / Fable 审核）：每条都是先在旧代码上失败（或改坏实现后失败）的回归测试。
// - Codex P1：重放缓存结果按当前请求角色裁剪（收银员重发家用的 stale 期初拿不到 stock_qty），库里保留原结果
// - Codex P2：卖出行存手机传来的名称快照（离线旧名），撤销沿用原快照
// - Fable 1：记账 op 写到一半被拒时整笔回滚（guarded() 的 ROLLBACK TO SAVEPOINT ledger）
// - Fable 2：收银员撤本机名下的非原始卖出行（冲销行）得 forbidden（voidTargetSale 只认原始卖出行）
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { allKeys, op, syncOk, upsertFull } from "./helpers/sync.ts";

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
  const newProduct = async (name?: string) => {
    const u = upsertFull(name ? { name } : {});
    await send(u);
    return u.payload.product_id as string;
  };
  return { shop, clock, app, boss, send, sendAs, newProduct };
}
const opening = (pid: string, counted_qty: number, extra: Record<string, unknown> = {}) => op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty, ...extra }, { at: AT });

const COST_KEYS = ["stock_qty", "stock_ver", "stock_value_fen", "unit_cost_fen", "cogs_fen", "value_delta_fen", "qty_left", "handle_ver", "closed", "current"];

describe("Codex P1：重放结果按当前角色裁剪", () => {
  it("家用发过期期初 → 收银员同 id 同内容重发 → 结果不含 stock_qty / 成本键；家用重放仍带 current；库里原结果不变", async () => {
    const { shop, app, boss, send, sendAs, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 37, { unit_cost_fen: 100 }));
    const stale = opening(pid, 5, { base_ver: 0 });
    const first = await send(stale);
    expect(first).toEqual([{ id: stale.id, status: "rejected", code: "stale", current: { stock_qty: 37, stock_ver: 1 } }]);
    const cashier = await pair(app, boss.token, "cashier", "收银台");
    const res = await sendAs(cashier.token, stale);
    expect(res).toEqual([{ id: stale.id, status: "rejected", code: "stale", replayed: true }]);
    const keys = allKeys(res);
    for (const k of COST_KEYS) expect(keys.has(k)).toBe(false);
    expect(await send(stale)).toEqual([{ ...first[0], replayed: true }]);
    const row = await tdb.kysely.selectFrom("ops").select("result").where("store_id", "=", shop.storeId).where("id", "=", stale.id).executeTakeFirstOrThrow();
    expect((row.result as { current?: unknown }).current).toEqual({ stock_qty: 37, stock_ver: 1 });
    await app.close();
  });
});

const entriesOf = (storeId: string, pid: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).where("product_id", "=", pid).orderBy("seq").execute();
const saleLine = (pid: string, o: { name?: string; price?: number; count?: number } = {}) =>
  ({ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: o.name ?? "x", unit_name: "个", pack_qty: 1, pack_count: o.count ?? 1, unit_price_fen: o.price ?? 100 });
const saleOp = (lines: ReturnType<typeof saleLine>[], paid?: number, at = AT) =>
  op("sale_batch", { batch_id: randomUUID(), paid_total_fen: paid ?? lines.reduce((a, l) => a + l.unit_price_fen * l.pack_count * l.pack_qty, 0), lines }, { at });
const voidOp = (target: Record<string, string>, at = "2026-11-20T01:59:30Z") => op("void", { target }, { at });

describe("Codex P2：卖出名称快照", () => {
  it("离线旧名卖出、商品已改名后补传 → 流水存旧名；撤销的冲销行保留原快照", async () => {
    const { shop, app, send, newProduct } = await setup();
    const pid = await newProduct("旧名称");
    await send(opening(pid, 10, { unit_cost_fen: 100 }));
    await send(op("product_edit", { product_id: pid, name: "新名称" }));
    const line = saleLine(pid, { name: "旧名称" });
    const s = saleOp([line]);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    let es = await entriesOf(shop.storeId, pid);
    expect(es.find((e) => e.id === line.entry_id)!.name_snapshot).toBe("旧名称");
    const v = voidOp({ entry_id: line.entry_id });
    expect(await send(v)).toEqual([{ id: v.id, status: "applied" }]);
    es = await entriesOf(shop.storeId, pid);
    const rev = es.find((e) => e.reverses_entry_id === line.entry_id)!;
    expect(rev.name_snapshot).toBe("旧名称");
    await app.close();
  });
});

const snapshot = async (storeId: string) => ({
  products: await tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
  entries: await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).orderBy("seq").execute(),
  batches: await tdb.kysely.selectFrom("sale_batches").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
  lots: await tdb.kysely.selectFrom("stock_lots").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
});
const setStock = (storeId: string, pid: string, qty: number) =>
  tdb.kysely.updateTable("products").set({ stock_qty: qty } as never).where("store_id", "=", storeId).where("id", "=", pid).execute();

describe("Fable 1：记账 op 写到一半被拒 → 整笔回滚", () => {
  it("三行卖出：第一行正常、第二行自动建商品、第三行库存溢出 → invalid，批次头 / 流水 / 商品 / 投影都不变；重发同样结果", async () => {
    const { shop, app, send, newProduct } = await setup();
    const [a, c] = [await newProduct(), await newProduct()];
    await send(opening(a, 10, { unit_cost_fen: 100 }));
    await setStock(shop.storeId, c, -2147483647);
    const before = await snapshot(shop.storeId);
    const s = saleOp([saleLine(a), saleLine(randomUUID(), { name: "新商品" }), saleLine(c, { count: 10 })]);
    expect(await send(s)).toEqual([{ id: s.id, status: "rejected", code: "invalid" }]);
    expect(await snapshot(shop.storeId)).toEqual(before);
    expect(await send(s)).toEqual([{ id: s.id, status: "rejected", code: "invalid", replayed: true }]);
    expect(await snapshot(shop.storeId)).toEqual(before);
    await app.close();
  });

  it("整批撤销：第一行冲销已写、第二行冲销库存溢出 → invalid，原行 voided_at、cost_fix_entry_id、流水、商品都不变", async () => {
    const { shop, app, send, newProduct } = await setup();
    const [a, b] = [await newProduct(), await newProduct()];
    await send(opening(a, 10, { unit_cost_fen: 100 }), opening(b, 10, { unit_cost_fen: 100 }));
    const s = saleOp([saleLine(a), saleLine(b, { count: 2 })]);
    expect(await send(s)).toEqual([{ id: s.id, status: "applied" }]);
    await setStock(shop.storeId, b, 2147483647);
    const before = await snapshot(shop.storeId);
    const v = voidOp({ batch_id: s.payload.batch_id as string });
    expect(await send(v)).toEqual([{ id: v.id, status: "rejected", code: "invalid" }]);
    const after = await snapshot(shop.storeId);
    expect(after).toEqual(before);
    expect(after.entries.every((e) => e.voided_at === null && e.reverses_entry_id === null)).toBe(true);
    await app.close();
  });
});

describe("Fable 2：收银员只能撤本机当天的原始卖出行", () => {
  it("收银员撤自己的卖出成功，再撤自己名下那条冲销行 → forbidden（与不存在的 id 同码）", async () => {
    const { shop, app, boss, send, sendAs, newProduct } = await setup();
    const pid = await newProduct();
    await send(opening(pid, 10, { unit_cost_fen: 100 }));
    const cashier = await pair(app, boss.token, "cashier", "收银台");
    const line = saleLine(pid);
    const s = saleOp([line]);
    expect(await sendAs(cashier.token, s)).toEqual([{ id: s.id, status: "applied" }]);
    const v = voidOp({ entry_id: line.entry_id });
    expect(await sendAs(cashier.token, v)).toEqual([{ id: v.id, status: "applied" }]);
    const rev = (await entriesOf(shop.storeId, pid)).find((e) => e.reverses_entry_id === line.entry_id)!;
    expect(rev.device_id).toBe(cashier.deviceId);
    const before = await snapshot(shop.storeId);
    const v2 = voidOp({ entry_id: rev.id });
    const missing = voidOp({ entry_id: randomUUID() });
    expect(await sendAs(cashier.token, v2, missing)).toEqual([v2, missing].map((o) => ({ id: o.id, status: "rejected", code: "forbidden" })));
    expect(await snapshot(shop.storeId)).toEqual(before);
    await app.close();
  });
});
