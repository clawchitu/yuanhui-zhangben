// S04：/v1/sync 的协议层：epoch 握手、最低版本、请求格式、被踢设备（§4.5）、注销期间、手机时钟超前、只推不拉。
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";
import { expectContract, op, sync, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";
import { HANDLERS } from "../src/sync/push.ts";
import { OP_TYPES, OPS_SCHEMA_PATH, type OpType } from "../src/sync/validate.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const storeRev = async (id: string) =>
  (await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", id).executeTakeFirstOrThrow()).rev;
const opsOf = (storeId: string) => tdb.kysely.selectFrom("ops").selectAll().where("store_id", "=", storeId).execute();

describe("epoch 握手", () => {
  it("epoch 不一致：409 epoch_mismatch + 新 epoch，一个 op 都不应用（含本来能应用的、重放的）", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    expect(boss.epoch).toBe(shop.epoch);
    const applied = upsertFull();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [applied] });
    const revBefore = await storeRev(shop.storeId);
    const opsBefore = await opsOf(shop.storeId);

    const fresh = [upsertFull(), upsertFull(), op("product_edit", { product_id: applied.payload.product_id, name: "改" })];
    const r = await sync(app, boss.token, { epoch: randomUUID(), ops: [applied, ...fresh] });
    await app.close();
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ code: "epoch_mismatch", epoch: shop.epoch });
    expect(await storeRev(shop.storeId)).toBe(revBefore);
    expect(await opsOf(shop.storeId)).toEqual(opsBefore);
  });

  it("epoch 必填、不能为空；大小写不同的同一个 epoch 照常通过", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    for (const payload of [
      { cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1 },
      { epoch: null, cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1 },
      { epoch: "", cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1 },
    ]) {
      const r = await app.inject({ method: "POST", url: "/v1/sync", headers: bearer(boss.token), payload });
      expect([r.statusCode, r.json().code]).toEqual([400, "invalid"]);
    }
    const ok = await sync(app, boss.token, { epoch: shop.epoch.toUpperCase() });
    await app.close();
    expect(ok.status).toBe(200);
  });
});

describe("请求格式", () => {
  it("缺游标、游标为负、超过 200 个 op、app_build 缺失：400 invalid", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const base = { epoch: shop.epoch, cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1 };
    const bad = [
      { ...base, cursors: undefined },
      { ...base, cursors: { catalog: -1, ledger: 0 } },
      { ...base, cursors: { catalog: 0 } },
      { ...base, ops: Array.from({ length: 201 }, () => upsertFull()) },
      { ...base, app_build: undefined },
      { ...base, extra: 1 },
    ];
    for (const payload of bad) {
      const r = await app.inject({ method: "POST", url: "/v1/sync", headers: bearer(boss.token), payload });
      expect([r.statusCode, r.json().code], JSON.stringify(payload).slice(0, 80)).toEqual([400, "invalid"]);
    }
    // 正好 200 个可以
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: Array.from({ length: 200 }, () => upsertFull()), pull: false });
    await app.close();
    expect(r.results).toHaveLength(200);
  });

  it("没令牌 401 unauthorized", async () => {
    const app = makeApp(tdb);
    const r = await app.inject({ method: "POST", url: "/v1/sync", payload: {} });
    await app.close();
    expect([r.statusCode, r.json().code]).toEqual([401, "unauthorized"]);
  });

  it("app_build 低于 min_build：426 build_too_old，不应用", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { config: { minBuild: 10 } });
    const boss = await login(app, shop.username);
    const r = await sync(app, boss.token, { epoch: shop.epoch, ops: [upsertFull()], app_build: 9 });
    const ok = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [], app_build: 10 });
    await app.close();
    expect([r.status, r.body.code]).toEqual([426, "build_too_old"]);
    expect(await opsOf(shop.storeId)).toEqual([]);
    expect(ok.min_build).toBe(10);
  });
});

describe("响应外壳", () => {
  it("带 server_time、epoch、min_build、device、store；pull=false 时 changes 为空、游标原样返回", async () => {
    const clock = new TestClock();
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username, { label: "老板的手机" });
    const o = upsertFull();
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o], pull: false, cursors: { catalog: 0, ledger: 0 } });
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch });
    await app.close();
    expect(r).toMatchObject({
      server_time: clock.now().toISOString(),
      epoch: shop.epoch,
      min_build: 0,
      device: { role: "family", label: "老板的手机", revoked: false },
      store: { name: "元辉烟酒店" },
      changes: { products: [], barcodes: [], removed: [], entries: [], batches: [], lots: [] },
      cursors: { catalog: 0, ledger: 0 },
      has_more: { catalog: false, ledger: false },
    });
    expect(r.device).not.toHaveProperty("discard_outbox");
    expect(r2.changes.products).toHaveLength(1);
    expect(r2.cursors.catalog).toBe(2);
  });
});

describe("store.low_stock_default（S25：手机 11「快没货」与 09 同一条件，§14 S07-6）", () => {
  it("家用的响应带店里的默认提醒线（改了就跟着变），收银员的响应里没有这个键；都符合契约", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const r1 = await syncOk(app, boss.token, { epoch: shop.epoch });
    await tdb.kysely.updateTable("stores").set({ low_stock_default: 7 }).where("id", "=", shop.storeId).execute();
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch });
    const rc = await syncOk(app, cas.token, { epoch: shop.epoch });
    await app.close();
    expect(r1.store).toEqual({ name: "元辉烟酒店", low_stock_default: 3 });
    expect(r2.store).toEqual({ name: "元辉烟酒店", low_stock_default: 7 });
    expect(rc.store).toEqual({ name: "元辉烟酒店" });
    for (const r of [r1, r2, rc]) await expectContract("SyncResponse", r);
  });
});

describe("手机时钟超前", () => {
  it("occurred_at 比服务器时间晚 5 分钟以上：改成服务器收到的时间，flags.clock_adjusted；5 分钟以内不改", async () => {
    const clock = new TestClock();
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const ahead = upsertFull();
    ahead.occurred_at = new Date(clock.t + 86_400_000).toISOString();
    const slight = upsertFull();
    slight.occurred_at = new Date(clock.t + 5 * 60_000).toISOString();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [ahead, slight] });
    // 重放仍是同一个 op（哈希按手机发来的原值算）
    const again = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [ahead] });
    await app.close();
    expect(again.results[0]).toMatchObject({ status: "applied", replayed: true });
    const rows = Object.fromEntries((await opsOf(shop.storeId)).map((o) => [o.id, o]));
    expect(rows[ahead.id]).toMatchObject({ occurred_at: clock.now(), flags: { clock_adjusted: true } });
    expect(rows[slight.id]).toMatchObject({ occurred_at: new Date(slight.occurred_at), flags: {} });
  });
});

describe("被踢设备（§4.5）", () => {
  async function kicked() {
    const clock = new TestClock();
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const fam2 = await pair(app, boss.token, "family", "儿子");
    // 两台都有点东西可拉
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [upsertFull()] });
    const revokedAt = clock.now();
    for (const d of [cas, fam2]) {
      const k = await app.inject({ method: "POST", url: `/v1/devices/${d.deviceId}/revoke`, headers: bearer(boss.token) });
      expect(k.statusCode).toBe(204);
    }
    clock.advance(3600_000);
    return { clock, shop, app, boss, cas, fam2, revokedAt };
  }

  it("响应 device.revoked=true，不返回任何数据（changes 为空、total_products=0、游标原样）", async () => {
    const { shop, app, cas, fam2 } = await kicked();
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, cursors: { catalog: 0, ledger: 0 } });
    expect(r.device).toEqual({ role: "cashier", label: "小王", revoked: true });
    expect(r.changes).toEqual({ products: [], barcodes: [], removed: [], entries: [], batches: [], lots: [] });
    // 被踢的家用设备也不发店里的快没货提醒线（S25）
    const rf = await syncOk(app, fam2.token, { epoch: shop.epoch, cursors: { catalog: 0, ledger: 0 } });
    await app.close();
    expect(rf.store).toEqual({ name: "元辉烟酒店" });
    expect(r.total_products).toBe(0);
    expect(r.cursors).toEqual({ catalog: 0, ledger: 0 });
    expect(r.has_more).toEqual({ catalog: false, ledger: false });
  });

  it("被踢前的 quick 登记直接入账并打 late_from_revoked；被踢前的其他商品 op 记 held；被踢后的、超过 30 天的拒收", async () => {
    const { clock, shop, app, cas, fam2, revokedAt } = await kicked();
    const before = new Date(revokedAt.getTime() - 60_000);
    const after = new Date(revokedAt.getTime() + 60_000);
    const quickBefore = upsertQuick({ name: "被踢前登记" });
    quickBefore.occurred_at = before.toISOString();
    const quickAfter = upsertQuick({ name: "被踢后登记" });
    quickAfter.occurred_at = after.toISOString();
    const r1 = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [quickBefore, quickAfter] });

    const pid = (await tdb.kysely.selectFrom("products").select("id").where("store_id", "=", shop.storeId).executeTakeFirstOrThrow()).id;
    const fullBefore = op("product_upsert", { ...upsertFull().payload }, { at: before });
    const editBefore = op("product_edit", { product_id: pid, name: "儿子改的" }, { at: before });
    const linkBefore = op("barcode_link", { barcode: "6909999999999", product_id: pid, pack_qty: 6, unit_name: "提" }, { at: before });
    const editAfter = op("product_edit", { product_id: pid, name: "被踢后改的" }, { at: after });
    const r2 = await syncOk(app, fam2.token, { epoch: shop.epoch, ops: [fullBefore, editBefore, linkBefore, editAfter] });
    // 重放暂存的结果
    const r3 = await syncOk(app, fam2.token, { epoch: shop.epoch, ops: [editBefore] });

    // 30 天以后：被踢前的 quick 登记也拒收
    clock.advance(31 * 86_400_000);
    const late = upsertQuick({ name: "太晚了" });
    late.occurred_at = before.toISOString();
    const r4 = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [late] });
    await app.close();

    expect(r1.results).toEqual([
      { id: quickBefore.id, status: "applied" },
      { id: quickAfter.id, status: "rejected", code: "forbidden" },
    ]);
    expect(r2.results).toEqual([
      { id: fullBefore.id, status: "held" },
      { id: editBefore.id, status: "held" },
      { id: linkBefore.id, status: "held" },
      { id: editAfter.id, status: "rejected", code: "forbidden" },
    ]);
    expect(r3.results).toEqual([{ id: editBefore.id, status: "held", replayed: true }]);
    expect(r4.results).toEqual([{ id: late.id, status: "rejected", code: "forbidden" }]);

    const rows = Object.fromEntries((await opsOf(shop.storeId)).map((o) => [o.id, o]));
    expect(rows[quickBefore.id]).toMatchObject({ status: "applied", flags: { late_from_revoked: true } });
    for (const o of [fullBefore, editBefore, linkBefore]) expect(rows[o.id]).toMatchObject({ status: "held", reject_code: null });
    const names = (await tdb.kysely.selectFrom("products").select("name").where("store_id", "=", shop.storeId).execute()).map((p) => p.name);
    // 暂存的没有动商品
    expect(names.sort()).toEqual(["可口可乐 330ml", "被踢前登记"].sort());
    const n = await tdb.kysely.selectFrom("product_barcodes").select("barcode").where("store_id", "=", shop.storeId).where("barcode", "=", "6909999999999").execute();
    expect(n).toEqual([]);
    // /v1/devices 里能看到儿子的手机有 3 笔暂存
    const app2 = makeApp(tdb, { clock });
    const boss2 = await login(app2, shop.username);
    const devs = await app2.inject({ method: "GET", url: "/v1/devices", headers: bearer(boss2.token) });
    await app2.close();
    expect(devs.json().devices.find((d: { id: string }) => d.id === fam2.deviceId)).toMatchObject({ revoked: true, held_count: 3 });
  });

  it("演示店重置撤销的设备：device.discard_outbox=true", async () => {
    const { shop, app, cas } = await kicked();
    await tdb.kysely.updateTable("devices").set({ revoke_reason: "demo_reset" }).where("store_id", "=", shop.storeId).where("id", "=", cas.deviceId).execute();
    const r = await syncOk(app, cas.token, { epoch: shop.epoch });
    await app.close();
    expect(r.device).toEqual({ role: "cashier", label: "小王", revoked: true, discard_outbox: true });
  });

  it("请求进来以后、拿到店铺锁之前被踢：按锁内重新读到的设备状态处理", async () => {
    const clock = new TestClock();
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    // 在另一个连接里拿着店铺锁，期间把收银员踢掉，再放锁
    const { storeLockKey } = await import("../src/sync/lock.ts");
    const c = await tdb.pool.connect();
    await c.query("BEGIN");
    await c.query("SELECT pg_advisory_xact_lock($1)", [storeLockKey(shop.storeId)]);
    const o = upsertQuick();
    o.occurred_at = new Date(clock.t + 1000).toISOString();
    const pending = sync(app, cas.token, { epoch: shop.epoch, ops: [o] });
    await new Promise((r) => setTimeout(r, 200));
    await c.query("UPDATE devices SET revoked_at = $1, revoke_reason = 'kicked' WHERE store_id = $2 AND id = $3", [clock.now(), shop.storeId, cas.deviceId]);
    await c.query("COMMIT");
    c.release();
    const r = await pending;
    await app.close();
    expect(r.status).toBe(200);
    // op 的时间晚于被踢时间 → 拒收；响应按被踢处理
    expect(r.body.results).toEqual([{ id: o.id, status: "rejected", code: "forbidden" }]);
    expect(r.body.device.revoked).toBe(true);
  });
});

describe("注销期间", () => {
  it("注销申请期间推 op：整批不应用、不留档、results 为空，带 delete_pending_until（S04-2，详见 sync.review.test.ts）", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: new Date() }).where("id", "=", shop.accountId).execute();
    const o = upsertFull();
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    expect(r.results).toEqual([]);
    expect(r.delete_pending_until).toEqual(expect.any(String));
    expect(await opsOf(shop.storeId)).toEqual([]);
    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: null }).where("id", "=", shop.accountId).execute();
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r2.results).toEqual([{ id: o.id, status: "applied" }]);
  });
});

describe("全部 op 类型都已接入（§14 S04-1、S05-6 ⑩）", () => {
  it("S05b 的四种记账 op 正常入账并留档；S06 的 count / product_review_complete（版本过时 → stale）、expiry_dispose / lot_snooze（批次不存在 → invalid）都正常处理并留档", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const u = upsertFull();
    const pid = u.payload.product_id as string;
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [u], pull: false });
    const eid = randomUUID();
    const ledger = [
      op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 5 }),
      op("stock_in", { entry_id: eid, product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 2, unit_cost_fen: 100 }),
      op("sale_batch", {
        batch_id: randomUUID(),
        paid_total_fen: 300,
        lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 300 }],
      }),
      op("void", { target: { entry_id: eid } }),
    ];
    // 都按 ops.schema.json 写成格式正确的 payload，排除「格式不对才拒」
    const lot = randomUUID();
    const stale = [
      op("count", { entry_id: randomUUID(), product_id: pid, counted_qty: 1, base_qty: 0, base_ver: 0 }),
      op("product_review_complete", { entry_id: randomUUID(), product_id: pid, unit_cost_fen: 100, counted_qty: 1, base_ver: 0 }),
    ];
    const lots = [
      op("expiry_dispose", { lot_id: lot, handle_ver: 0, actual_qty: 1, action: "discard", entry_id: randomUUID() }),
      op("lot_snooze", { lot_id: lot, handle_ver: 0, actual_qty: 1, days: 3 }),
    ];
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [...ledger, ...stale, ...lots], pull: false });
    await app.close();
    expect(r.results).toEqual([
      ...ledger.map((o) => ({ id: o.id, status: "applied" })),
      ...stale.map((o) => ({ id: o.id, status: "rejected", code: "stale", current: expect.objectContaining({ stock_qty: expect.any(Number), stock_ver: expect.any(Number) }) })),
      ...lots.map((o) => ({ id: o.id, status: "rejected", code: "invalid" })),
    ]);
    const logged = new Set((await opsOf(shop.storeId)).map((o) => o.id));
    for (const o of [...ledger, ...stale, ...lots]) expect(logged.has(o.id)).toBe(true);
    const types = await tdb.kysely.selectFrom("entries").select("type").where("store_id", "=", shop.storeId).execute();
    expect(new Set(types.map((t) => t.type))).toEqual(new Set(["opening", "stock_in", "sale", "cost_adjust"]));
  });
});

describe("ops.schema.json 里每个 type 都有处理函数（§14 S04-1）", () => {
  it("契约的 type 集合 = OP_TYPES = HANDLERS 的键，每个都是函数（HANDLERS 的类型是完整的 Record，少一个就编译不过）", () => {
    const schema = JSON.parse(readFileSync(OPS_SCHEMA_PATH, "utf8")) as { oneOf: Array<{ properties: { type: { const: string } } }> };
    const contractTypes = schema.oneOf.map((b) => b.properties.type.const).sort();
    expect([...OP_TYPES].sort()).toEqual(contractTypes);
    expect(Object.keys(HANDLERS).sort()).toEqual(contractTypes);
    for (const t of contractTypes) expect(typeof HANDLERS[t as OpType]).toBe("function");
  });
});
