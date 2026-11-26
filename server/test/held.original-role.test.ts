// T37（S23a）：被踢设备的 op 还要按它被踢前的身份复核。被踢的收银员不能借「补传 → 家里人记上」做收银员本来做不了的事：
// 推送时直接 rejected: forbidden（不进 held）；S23a 之前已经暂存的这类 op 在 held-ops 里 can_accept = false，记上返回 403、不改。
// 被踢的收银员本来能做的（卖出、只带名称和卖价的 quick 登记、撤自己的卖出）照旧；被踢的家用手机不受影响。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { expectContract, op, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const T_BEFORE = "2026-11-20T01:00:00Z"; // 被踢之前（服务器时钟 02:00）

async function setup() {
  const shop = await makeLoginShop(tdb);
  const clock = new TestClock();
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const phone = await pair(app, boss.token, "family");
  const cashier = await pair(app, boss.token, "cashier", "小王");
  const send = async (token: string, ...ops: ReturnType<typeof op>[]) => (await syncOk(app, token, { epoch: shop.epoch, ops, pull: false })).results;
  const u = upsertFull({ price: 300 });
  await send(boss.token, u);
  const pid = u.payload.product_id as string;
  const kick = async (id: string) => {
    const r = await app.inject({ method: "POST", url: `/v1/devices/${id}/revoke`, headers: bearer(boss.token) });
    expect(r.statusCode).toBe(204);
  };
  const held = async () => (await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held as {
    id: string; device_role: string; can_accept: boolean;
  }[];
  const resolve = (id: string, action: "accept" | "discard") =>
    app.inject({ method: "POST", url: `/v1/held-ops/${id}/resolve`, headers: bearer(boss.token), payload: { action } });
  return { shop, app, clock, boss, phone, cashier, send, pid, kick, held, resolve };
}
const stockIn = (pid: string, n: number) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: 100 }, { at: T_BEFORE });
const sale = (pid: string, n: number) => {
  const entry = randomUUID();
  const batch = randomUUID();
  return {
    entry,
    batch,
    op: op("sale_batch", {
      batch_id: batch,
      paid_total_fen: n * 300,
      lines: [{ entry_id: entry, product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: n, unit_price_fen: 300 }],
    }, { at: T_BEFORE }),
  };
};

describe("被踢设备按原角色复核（T37）", () => {
  it("被踢的收银员补传进货、盘点、改商品、完整登记、期初：rejected forbidden，不进 held、不入账", async () => {
    const { shop, cashier, send, pid, kick, held } = await setup();
    await kick(cashier.deviceId);
    const ops = [
      stockIn(pid, 5),
      op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 99, base_qty: 0, base_ver: 0 }, { at: T_BEFORE }),
      op("product_edit", { product_id: pid, price_fen: 1 }, { at: T_BEFORE }),
      upsertFull({ price: 1 }),
      op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 3, unit_cost_fen: 100 }, { at: T_BEFORE }),
    ];
    ops[3]!.occurred_at = T_BEFORE;
    const res = await send(cashier.token, ...ops);
    expect(res.map((r: { status: string; code?: string }) => [r.status, r.code])).toEqual(ops.map(() => ["rejected", "forbidden"]));
    expect(await held()).toEqual([]);
    const p = await tdb.kysely.selectFrom("products").select(["stock_qty", "price_fen"]).where("store_id", "=", shop.storeId).where("id", "=", pid).executeTakeFirstOrThrow();
    expect([p.stock_qty, Number(p.price_fen)]).toEqual([0, 300]);
  });

  it("被踢的收银员：卖出照记（补传标记），只带名称和卖价的 quick 登记照收，带了家用字段的 quick 登记拒收", async () => {
    const { shop, cashier, send, pid, kick } = await setup();
    await kick(cashier.deviceId);
    const s = sale(pid, 2);
    const q = upsertQuick();
    q.occurred_at = T_BEFORE;
    const bad = upsertQuick({ extra: { track_expiry: true } });
    bad.occurred_at = T_BEFORE;
    const res = await send(cashier.token, s.op, q, bad);
    expect(res.map((r: { status: string; code?: string }) => [r.status, r.code ?? null])).toEqual([["applied", null], ["applied", null], ["rejected", "forbidden"]]);
    const e = await tdb.kysely.selectFrom("entries").select("flags").where("store_id", "=", shop.storeId).where("id", "=", s.entry).executeTakeFirstOrThrow();
    expect((e.flags as Record<string, unknown>).late_from_revoked).toBe(true);
  });

  it("被踢的收银员撤自己的卖出 → held 可以记上；撤别人的卖出 → 拒收", async () => {
    const { boss, cashier, send, pid, kick, held, resolve } = await setup();
    const own = sale(pid, 1);
    const other = sale(pid, 1);
    await send(cashier.token, own.op);
    await send(boss.token, other.op);
    await kick(cashier.deviceId);
    const vOwn = op("void", { target: { entry_id: own.entry } }, { at: T_BEFORE });
    const vOther = op("void", { target: { entry_id: other.entry } }, { at: T_BEFORE });
    const res = await send(cashier.token, vOwn, vOther);
    expect(res.map((r: { status: string; code?: string }) => [r.status, r.code ?? null])).toEqual([["held", null], ["rejected", "forbidden"]]);
    const list = await held();
    expect(list.map((h) => [h.id, h.device_role, h.can_accept])).toEqual([[vOwn.id, "cashier", true]]);
    expect((await resolve(vOwn.id, "accept")).json().status).toBe("applied");
  });

  it("收银员当天撤了自己的卖出、过了上海零点被踢后才补传：「收到那天」这条不复核，照样 held、可以记上", async () => {
    const { clock, cashier, send, pid, kick, held, resolve } = await setup();
    const own = sale(pid, 1);
    await send(cashier.token, own.op);
    const v = op("void", { target: { entry_id: own.entry } }, { at: "2026-11-20T01:30:00Z" });
    clock.advance(24 * 3600_000); // 服务器到了第二天（上海）
    await kick(cashier.deviceId);
    expect((await send(cashier.token, v))[0]).toMatchObject({ status: "held" });
    expect((await held()).map((h) => [h.id, h.can_accept])).toEqual([[v.id, true]]);
    expect((await resolve(v.id, "accept")).json().status).toBe("applied");
  });

  it("被踢的收银员按 batch_id 撤别人的整批卖出 → 拒收；旧服务器留下的这种 held 行 can_accept = false、记上 403", async () => {
    const { shop, boss, cashier, send, pid, kick, held, resolve } = await setup();
    const other = sale(pid, 1);
    await send(boss.token, other.op);
    await kick(cashier.deviceId);
    const v = op("void", { target: { batch_id: other.batch } }, { at: T_BEFORE });
    expect((await send(cashier.token, v))[0]).toMatchObject({ status: "rejected", code: "forbidden" });
    const legacy = op("void", { target: { entry_id: other.entry } }, { at: T_BEFORE });
    await tdb.kysely.insertInto("ops").values({
      id: legacy.id, store_id: shop.storeId, device_id: cashier.deviceId, type: "void", payload: JSON.stringify(legacy.payload),
      payload_hash: "legacy", occurred_at: new Date(T_BEFORE), received_at: new Date(T_BEFORE), status: "held",
      reject_code: null, result: JSON.stringify({ id: legacy.id, status: "held" }), flags: JSON.stringify({}),
    }).execute();
    expect((await held()).map((h) => [h.id, h.can_accept])).toEqual([[legacy.id, false]]);
    expect((await resolve(legacy.id, "accept")).statusCode).toBe(403);
  });

  it("审核号（演示店）被踢的手机：进货照旧 held、可以记上", async () => {
    const shop = await makeLoginShop(tdb, { demo: true });
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const other = await login(app, shop.username);
    const send = async (token: string, ...ops: ReturnType<typeof op>[]) => (await syncOk(app, token, { epoch: shop.epoch, ops, pull: false })).results;
    const u = upsertFull({ price: 300 });
    await send(boss.token, u);
    await app.inject({ method: "POST", url: `/v1/devices/${other.deviceId}/revoke`, headers: bearer(boss.token) });
    const s = stockIn(u.payload.product_id as string, 2);
    expect((await send(other.token, s))[0]!.status).toBe("held");
    const list = (await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held;
    expect(list.map((h: { device_role: string; can_accept: boolean }) => [h.device_role, h.can_accept])).toEqual([["family", true]]);
  });

  it("S23a 之前已经暂存的被踢收银员进货：列表 can_accept = false、device_role = cashier；记上 403 不改，不要照常", async () => {
    const { shop, app, boss, cashier, pid, kick, held, resolve } = await setup();
    await kick(cashier.deviceId);
    // 模拟旧服务器留下的 held 行（那时只看 revoked 列）
    const s = stockIn(pid, 7);
    await tdb.kysely.insertInto("ops").values({
      id: s.id, store_id: shop.storeId, device_id: cashier.deviceId, type: "stock_in", payload: JSON.stringify(s.payload),
      payload_hash: "legacy", occurred_at: new Date(T_BEFORE), received_at: new Date(T_BEFORE), status: "held",
      reject_code: null, result: JSON.stringify({ id: s.id, status: "held" }), flags: JSON.stringify({}),
    }).execute();
    const list = (await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held;
    await expectContract("HeldOp", list[0]);
    expect((await held()).map((h) => [h.id, h.device_role, h.can_accept])).toEqual([[s.id, "cashier", false]]);
    const r = await resolve(s.id, "accept");
    expect([r.statusCode, r.json().code]).toEqual([403, "forbidden"]);
    const row = await tdb.kysely.selectFrom("ops").select(["status", "resolved_at"]).where("store_id", "=", shop.storeId).where("id", "=", s.id).executeTakeFirstOrThrow();
    expect([row.status, row.resolved_at]).toEqual(["held", null]);
    const entries = await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("op_id", "=", s.id).execute();
    expect(entries).toEqual([]);
    expect((await resolve(s.id, "discard")).json()).toEqual({ id: s.id, status: "rejected", code: "discarded" });
  });

  it("被踢的家用手机：进货照旧 held、device_role = family、可以记上", async () => {
    const { phone, send, pid, kick, held, resolve } = await setup();
    await kick(phone.deviceId);
    const s = stockIn(pid, 2);
    expect((await send(phone.token, s))[0]!.status).toBe("held");
    expect((await held()).map((h) => [h.device_role, h.can_accept])).toEqual([["family", true]]);
    expect((await resolve(s.id, "accept")).json().status).toBe("applied");
  });
});
