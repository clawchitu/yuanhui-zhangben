// S22b：被退出的手机补传上来、等确认的账（§4.5、§7 held-ops）。家用列出、逐笔「记上 / 不要」；收银员不能看、不能处理；
// 记上后才入账（流水带 late_from_revoked）；版本已变的盘点只能不要；被踢的手机重发拿到的是处理后的结果。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { expectContract, op, syncOk, upsertFull } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const T_BEFORE = "2026-11-20T01:00:00Z"; // 被踢之前（服务器时钟 02:00）

async function setup() {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb, { clock: new TestClock() });
  const boss = await login(app, shop.username);
  const phone = await pair(app, boss.token, "family");
  const cashier = await pair(app, boss.token, "cashier", "小王");
  const send = async (token: string, ...ops: ReturnType<typeof op>[]) => (await syncOk(app, token, { epoch: shop.epoch, ops, pull: false })).results;
  const u = upsertFull({ price: 300 });
  await send(boss.token, u);
  const pid = u.payload.product_id as string;
  const kick = async () => {
    const r = await app.inject({ method: "POST", url: `/v1/devices/${phone.deviceId}/revoke`, headers: bearer(boss.token) });
    expect(r.statusCode).toBe(204);
  };
  return { shop, app, boss, phone, cashier, send, pid, kick };
}
const stockIn = (pid: string, n: number) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: 100 }, { at: T_BEFORE });

describe("held-ops（§4.5）", () => {
  it("被踢手机补传的进货是 held，不入账；家用列出后「记上」才入账，被踢手机重发拿到 applied", async () => {
    const { shop, app, boss, phone, send, pid, kick } = await setup();
    await kick();
    const s = stockIn(pid, 5);
    expect(await send(phone.token, s)).toEqual([{ id: s.id, status: "held" }]);
    const entries = () => tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).where("op_id", "=", s.id).execute();
    expect(await entries()).toHaveLength(0);

    const list = await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) });
    expect(list.statusCode).toBe(200);
    await expectContract("HeldOp", list.json().held[0]);
    expect(list.json().held.map((h: { id: string; can_accept: boolean; device_id: string }) => [h.id, h.can_accept, h.device_id]))
      .toEqual([[s.id, true, phone.deviceId]]);

    const r = await app.inject({ method: "POST", url: `/v1/held-ops/${s.id}/resolve`, headers: bearer(boss.token), payload: { action: "accept" } });
    expect(r.statusCode).toBe(200);
    expect(r.json().status).toBe("applied");
    const es = await entries();
    expect(es.map((e) => [e.type, e.qty_delta, e.device_id, (e.flags as Record<string, unknown>).late_from_revoked])).toEqual([["stock_in", 5, phone.deviceId, true]]);
    const p = await tdb.kysely.selectFrom("products").select("stock_qty").where("store_id", "=", shop.storeId).where("id", "=", pid).executeTakeFirstOrThrow();
    expect(p.stock_qty).toBe(5);
    // 处理过了：列表空、再处理 404、被踢手机重发拿到新结果
    expect((await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held).toEqual([]);
    expect((await app.inject({ method: "POST", url: `/v1/held-ops/${s.id}/resolve`, headers: bearer(boss.token), payload: { action: "accept" } })).statusCode).toBe(404);
    const again = await send(phone.token, s);
    expect(again[0]).toMatchObject({ id: s.id, status: "applied", replayed: true });
  });

  it("「不要」：rejected / discarded，不入账", async () => {
    const { app, boss, phone, send, pid, kick, shop } = await setup();
    await kick();
    const s = stockIn(pid, 3);
    await send(phone.token, s);
    const r = await app.inject({ method: "POST", url: `/v1/held-ops/${s.id}/resolve`, headers: bearer(boss.token), payload: { action: "discard" } });
    expect(r.json()).toEqual({ id: s.id, status: "rejected", code: "discarded" });
    const o = await tdb.kysely.selectFrom("ops").selectAll().where("store_id", "=", shop.storeId).where("id", "=", s.id).executeTakeFirstOrThrow();
    expect([o.status, o.reject_code, o.resolved_by_device !== null]).toEqual(["rejected", "discarded", true]);
    expect((await send(phone.token, s))[0]).toMatchObject({ status: "rejected", code: "discarded", replayed: true });
  });

  it("版本已变的盘点：can_accept = false，记上返回 409 stale、不改；只能不要", async () => {
    const { app, boss, phone, send, pid, kick, shop } = await setup();
    const verOf = async () => Number((await tdb.kysely.selectFrom("products").select("stock_ver").where("store_id", "=", shop.storeId).where("id", "=", pid).executeTakeFirstOrThrow()).stock_ver);
    const c = op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 4, base_qty: 0, base_ver: await verOf() }, { at: T_BEFORE });
    await kick();
    expect((await send(phone.token, c))[0]!.status).toBe("held");
    await send(boss.token, stockIn(pid, 2)); // 账面变了
    const list = (await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held;
    expect(list[0].can_accept).toBe(false);
    const r = await app.inject({ method: "POST", url: `/v1/held-ops/${c.id}/resolve`, headers: bearer(boss.token), payload: { action: "accept" } });
    expect([r.statusCode, r.json().code]).toEqual([409, "stale"]);
    const o = await tdb.kysely.selectFrom("ops").select(["status", "resolved_at"]).where("store_id", "=", shop.storeId).where("id", "=", c.id).executeTakeFirstOrThrow();
    expect([o.status, o.resolved_at]).toEqual(["held", null]);
  });

  it("收银员不能看、不能处理", async () => {
    const { app, cashier, phone, send, pid, kick } = await setup();
    await kick();
    const s = stockIn(pid, 1);
    await send(phone.token, s);
    expect((await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(cashier.token) })).statusCode).toBe(403);
    expect((await app.inject({ method: "POST", url: `/v1/held-ops/${s.id}/resolve`, headers: bearer(cashier.token), payload: { action: "accept" } })).statusCode).toBe(403);
  });

  it("不带 base_ver 的期初隐含版本 0：库存动过后 can_accept = false，记上 409", async () => {
    const { app, boss, phone, send, pid, kick } = await setup();
    const o = op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 3, unit_cost_fen: 100 }, { at: T_BEFORE });
    await kick();
    expect((await send(phone.token, o))[0]!.status).toBe("held");
    await send(boss.token, stockIn(pid, 1));
    const list = (await app.inject({ method: "GET", url: "/v1/held-ops", headers: bearer(boss.token) })).json().held;
    expect(list.find((h: { id: string }) => h.id === o.id).can_accept).toBe(false);
    const r = await app.inject({ method: "POST", url: `/v1/held-ops/${o.id}/resolve`, headers: bearer(boss.token), payload: { action: "accept" } });
    expect(r.statusCode).toBe(409);
  });
});
