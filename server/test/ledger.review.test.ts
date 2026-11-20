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
