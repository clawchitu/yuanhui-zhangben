// S09：演示小店 —— 种子内容、每日重置（与种子逐表一致、有人在用就顺延、跨过重置的手机丢弃 outbox、恢复审核号）、
// 重置与同步并发、演示登录在注销申请中的响应、createDevice 没拿账号锁就失败（§14 T1）。全部连真实 Postgres，时钟可拨。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { sql } from "kysely";
import { createTestDb, databaseUrl, type TestDb } from "./helpers/db.ts";
import { createDb } from "../src/db.ts";
import { bearer, makeApp, PASSWORD, TestClock } from "./helpers/auth.ts";
import { expectContract, op, pullAll, sync, syncOk } from "./helpers/sync.ts";
import { nextResetAfter, resetDemoStore, runDemoResets, setupDemoStore } from "../src/demo/reset.ts";
import { COLA_CASE_BARCODE, SEED_PRODUCTS, seedId } from "../src/demo/seed.ts";
import { DEMO_CATALOG } from "../src/lookup/catalog.ts";
import { AccountLockMissing, createDevice, lockAccount } from "../src/auth/session.ts";
import { createStore } from "../scripts/create-store.ts";
import { createAccount } from "../scripts/create-account.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

// 北京时间 2026-11-20 10:00
const T0 = Date.parse("2026-11-20T02:00:00Z");
const DEMO_CONFIG = { demoLoginEnabled: true };
let seq = 0;

// runDemoResets 扫的是整个库里到点的演示店：同一个 schema 里别的测试建的演示店也会出现在结果里，只看本测试这家
async function newDemo(clock: TestClock) {
  seq += 1;
  const username = `review_${seq}_${randomUUID().slice(0, 6)}`;
  const { storeId, accountId } = await setupDemoStore(tdb.kysely, { username, password: PASSWORD, now: clock.now() });
  // 演示登录进「最早建的演示店」：同一个 schema 里每个测试各建一家，把这家的审核号排到最前
  await tdb.kysely.updateTable("accounts").set({ created_at: new Date(Date.UTC(2000, 0, 1) - seq * 86_400_000) }).where("id", "=", accountId).execute();
  const epoch = (await tdb.kysely.selectFrom("stores").select("epoch").where("id", "=", storeId).executeTakeFirstOrThrow()).epoch;
  return { storeId, accountId, username, epoch };
}

/** 这家店每张表的全部行（去掉 rev：变更序号只增不减，重置后接着往上取号），按主键排好。设备单独看 */
const TABLES = ["stores", "accounts", "products", "product_barcodes", "product_aliases", "ops", "sale_batches", "entries", "stock_lots", "lot_moves", "image_jobs", "removed", "pairing_tokens", "demo_stores"];
async function snapshot(storeId: string) {
  const out: Record<string, string[]> = {};
  for (const t of TABLES) {
    const col = t === "stores" ? "id" : "store_id";
    const rows = (await sql<{ j: Record<string, unknown> }>`SELECT to_jsonb(x) - 'rev' AS j FROM ${sql.table(t)} x WHERE ${sql.ref(col)} = ${storeId}`.execute(tdb.kysely)).rows;
    out[t] = rows.map((r) => JSON.stringify(r.j)).sort();
  }
  // accounts 里的密码哈希：同一个原始哈希
  return out;
}

async function demoLogin(app: ReturnType<typeof makeApp>) {
  const deviceId = randomUUID();
  const r = await app.inject({ method: "POST", url: "/v1/auth/demo", payload: { device_id: deviceId } });
  expect(r.statusCode, r.body).toBe(200);
  return { ...(r.json() as { token: string; epoch: string; delete_pending_until?: string }), deviceId, body: r.json() };
}

describe("种子数据", () => {
  it("约 30 个商品、没有烟酒、没有第三方图、不含 S08-10 的 6 个演示条码；7 天流水含抹零、撤销、进货；两个批次；待确认；整箱码", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const db = tdb.kysely;
    const products = await db.selectFrom("products").selectAll().where("store_id", "=", d.storeId).execute();
    expect(products.length).toBe(SEED_PRODUCTS.length + 1);
    expect(products.length).toBeGreaterThanOrEqual(28);
    for (const p of products) {
      expect(p.name).not.toMatch(/烟|酒|啤|白酒|红酒|香烟/);
      expect([p.image_ver, p.image_key]).toEqual([0, null]);
    }
    const store = await db.selectFrom("stores").selectAll().where("id", "=", d.storeId).executeTakeFirstOrThrow();
    expect([store.name, store.is_demo]).toEqual(["演示小店", true]);

    const barcodes = await db.selectFrom("product_barcodes").selectAll().where("store_id", "=", d.storeId).execute();
    for (const code of Object.keys(DEMO_CATALOG)) expect(barcodes.map((b) => b.barcode)).not.toContain(code);
    const caseCode = barcodes.find((b) => b.barcode === COLA_CASE_BARCODE)!;
    expect([caseCode.pack_qty, caseCode.unit_name]).toEqual([24, "箱"]);
    expect(products.find((p) => p.id === caseCode.product_id)?.name).toMatch(/可乐/);

    const entries = await db.selectFrom("entries").selectAll().where("store_id", "=", d.storeId).execute();
    for (const e of entries) {
      expect(e.occurred_at.getTime()).toBeLessThanOrEqual(T0);
      expect(e.occurred_at.getTime()).toBeGreaterThan(T0 - 8 * 86_400_000);
    }
    expect(entries.some((e) => e.type === "stock_in")).toBe(true);
    expect(entries.some((e) => e.reverses_entry_id !== null && e.type === "sale")).toBe(true);
    const batches = await db.selectFrom("sale_batches").selectAll().where("store_id", "=", d.storeId).execute();
    expect(batches.some((b) => Number(b.paid_total_fen) < Number(b.list_total_fen))).toBe(true);
    // 每天都有卖出（最近 7 天，含今天）
    const days = new Set(entries.filter((e) => e.type === "sale").map((e) => new Date(e.occurred_at.getTime() + 8 * 3600e3).toISOString().slice(0, 10)));
    expect(days.size).toBe(7);

    const lots = await db.selectFrom("stock_lots").selectAll().where("store_id", "=", d.storeId).where("expiry_date", "is not", null).execute();
    expect(lots.map((l) => l.expiry_date).sort()).toEqual(["2026-11-18", "2026-11-23"]);
    expect(products.filter((p) => p.needs_review).length).toBe(1);
    // 全部 op 都是 applied，记在已撤销的种子设备名下
    const ops = await db.selectFrom("ops").select(["status", "device_id"]).where("store_id", "=", d.storeId).execute();
    expect(new Set(ops.map((o) => o.status))).toEqual(new Set(["applied"]));
    expect(new Set(ops.map((o) => o.device_id))).toEqual(new Set([seedId(d.storeId, "device:seed")]));
  });

  it("北京时间 16:00：nextResetAfter 取下一个 16:00（不含当下）", () => {
    expect(nextResetAfter(new Date("2026-11-20T07:59:59Z")).toISOString()).toBe("2026-11-20T08:00:00.000Z");
    expect(nextResetAfter(new Date("2026-11-20T08:00:00Z")).toISOString()).toBe("2026-11-21T08:00:00.000Z");
    expect(nextResetAfter(new Date("2026-11-20T17:00:00Z")).toISOString()).toBe("2026-11-21T08:00:00.000Z");
  });
});

describe("每日重置", () => {
  it("重置后与种子逐表一致；所有设备标为已撤销 demo_reset；审核号密码、注销申请、登录锁都恢复", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const seed = await snapshot(d.storeId);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    // 弄乱：演示登录记一笔账、改密码、申请注销
    const p = await demoLogin(app);
    const pid = seedId(d.storeId, "product:water");
    await syncOk(app, p.token, { epoch: d.epoch, ops: [op("product_edit", { product_id: pid, price_fen: 999 }, { at: clock.now() })] });
    const pw = await app.inject({ method: "POST", url: "/v1/account/password", headers: bearer(p.token), payload: { old: PASSWORD, new: "changed-pass-9" } });
    expect(pw.statusCode).toBe(204);
    const p2 = await demoLogin(app);
    expect((await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(p2.token), payload: { password: "changed-pass-9" } })).statusCode).toBe(200);
    expect(await snapshot(d.storeId)).not.toEqual(seed);

    expect(await resetDemoStore(tdb.kysely, d.storeId, clock.now(), { force: true })).toBe("reset");
    expect(await snapshot(d.storeId)).toEqual(seed);
    const devs = await tdb.kysely.selectFrom("devices").select(["id", "revoke_reason"]).where("store_id", "=", d.storeId).execute();
    expect(devs.filter((x) => x.id !== seedId(d.storeId, "device:seed")).map((x) => x.revoke_reason).sort()).toEqual(["demo_reset", "demo_reset"]);
    // 用原密码能登录，不在注销中
    const li = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: d.username, password: PASSWORD, device_id: randomUUID() } });
    expect(li.statusCode, li.body).toBe(200);
    expect(li.json().delete_pending_until).toBeUndefined();
    expect(li.json().epoch).toBe(d.epoch); // 不换 epoch
    expect((await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: d.username, password: "changed-pass-9", device_id: randomUUID() } })).statusCode).toBe(401);
    await app.close();
  });

  it("有人在用（60 分钟内有请求）就顺延 1 小时，数据不动；之后没人用了才重置；没到点不重置", async () => {
    const clock = new TestClock(Date.parse("2026-11-20T07:00:00Z")); // 北京 15:00
    const d = await newDemo(clock);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    const p = await demoLogin(app);
    await syncOk(app, p.token, { epoch: d.epoch, ops: [op("product_edit", { product_id: seedId(d.storeId, "product:water"), price_fen: 777 }, { at: clock.now() })] });
    const dirty = await snapshot(d.storeId);

    clock.advance(30 * 60_000); // 15:30，没到点
    expect((await runDemoResets(tdb.kysely, clock.now()))[d.storeId]).toBeUndefined();
    clock.advance(30 * 60_000); // 16:00，30 分钟前还有人用
    await app.inject({ method: "GET", url: "/v1/me", headers: bearer(p.token) });
    clock.advance(60_000);
    expect((await runDemoResets(tdb.kysely, clock.now()))[d.storeId]).toBe("deferred");
    expect(await snapshot(d.storeId)).toEqual({ ...dirty, demo_stores: (await snapshot(d.storeId)).demo_stores });
    const next = (await tdb.kysely.selectFrom("demo_stores").select("next_reset_at").where("store_id", "=", d.storeId).executeTakeFirstOrThrow()).next_reset_at;
    expect(next.getTime()).toBe(clock.t + 60 * 60_000);
    // 顺延期间不再尝试
    clock.advance(30 * 60_000);
    expect((await runDemoResets(tdb.kysely, clock.now()))[d.storeId]).toBeUndefined();
    // 17:01：最后一次请求是 16:00，已经超过 60 分钟
    clock.advance(30 * 60_000);
    expect((await runDemoResets(tdb.kysely, clock.now()))[d.storeId]).toBe("reset");
    const price = await tdb.kysely.selectFrom("products").select("price_fen").where("store_id", "=", d.storeId).where("id", "=", seedId(d.storeId, "product:water")).executeTakeFirstOrThrow();
    expect(price.price_fen).toBe("200");
    const ds = await tdb.kysely.selectFrom("demo_stores").selectAll().where("store_id", "=", d.storeId).executeTakeFirstOrThrow();
    expect(ds.next_reset_at.toISOString()).toBe("2026-11-21T08:00:00.000Z");
    await app.close();
  });

  it("两个进程（两个连接池）同时跑每日重置：同一个周期只重置一次，另一个锁内重查到已处理就跳过（PR #20 Codex 6）", async () => {
    const clock = new TestClock(Date.parse("2026-11-20T07:00:00Z")); // 北京 15:00
    const d = await newDemo(clock);
    clock.advance(61 * 60_000); // 16:01，到点、没人在用
    const pools = [createDb({ connectionString: databaseUrl(), searchPath: tdb.schema, max: 2 }), createDb({ connectionString: databaseUrl(), searchPath: tdb.schema, max: 2 })];
    try {
      for (let round = 0; round < 3; round++) {
        const rs = await Promise.all(pools.map((p) => runDemoResets(p.kysely, clock.now())));
        const mine = rs.map((r) => r[d.storeId]).filter((x) => x !== undefined).sort();
        expect(mine, `第 ${round + 1} 轮`).toEqual(["reset", "skipped"]);
        const ds = await tdb.kysely.selectFrom("demo_stores").selectAll().where("store_id", "=", d.storeId).executeTakeFirstOrThrow();
        expect(ds.seeded_at.getTime()).toBe(clock.t);
        clock.advance(86_400_000);
      }
    } finally {
      for (const p of pools) await p.close();
    }
  });

  it("一台在重置前登录、带着未传 op 的手机跨过重置：得到 revoked + discard_outbox，旧 op 没进库；重新登录看到干净的种子数据", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    const phone = await demoLogin(app);
    // 手机离线记了一笔卖出（重置前发生）、一笔改价，还没传
    const pid = seedId(d.storeId, "product:cola");
    const pending = [
      op("sale_batch", {
        batch_id: randomUUID(),
        paid_total_fen: 300,
        lines: [{ entry_id: randomUUID(), product_id: pid, name: "可口可乐 330ml", unit_name: "罐", pack_qty: 1, pack_count: 1, unit_price_fen: 300 }],
      }, { at: clock.now() }),
      op("product_upsert", { product_id: randomUUID(), barcode: "2100000099990", name: "离线登记", price_fen: 100, quick: true }, { at: clock.now() }),
      op("product_edit", { product_id: pid, price_fen: 1 }, { at: clock.now() }),
    ];
    clock.advance(2 * 3600_000);
    await resetDemoStore(tdb.kysely, d.storeId, clock.now());
    const seed = await snapshot(d.storeId);

    const r = await syncOk(app, phone.token, { epoch: d.epoch, ops: pending });
    expect(r.device).toMatchObject({ revoked: true, discard_outbox: true });
    expect(r.results).toEqual([]);
    expect(r.changes.products).toEqual([]);
    await expectContract("SyncResponse", r);
    const got = await tdb.kysely.selectFrom("ops").select("id").where("store_id", "=", d.storeId).where("id", "in", pending.map((o) => o.id)).execute();
    expect(got).toEqual([]);
    expect(await snapshot(d.storeId)).toEqual(seed);

    const again = await demoLogin(app);
    const replica = await pullAll(app, again.token, again.epoch);
    expect(replica.products.size).toBe(SEED_PRODUCTS.length + 1);
    expect([...replica.products.values()].find((p: { id: string }) => p.id === pid)?.price_fen).toBe(300);
    await app.close();
  });

  it("重置和同步请求同时到：没有 500，结束后店里仍是干净的种子（重置前的写入被清掉，重置后的被整批丢弃）", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    const phones = await Promise.all(Array.from({ length: 6 }, () => demoLogin(app)));
    clock.advance(2 * 3600_000);
    const pid = seedId(d.storeId, "product:water");
    const syncs = phones.map((p, i) =>
      sync(app, p.token, { epoch: d.epoch, ops: [op("product_edit", { product_id: pid, price_fen: 1000 + i }, { at: clock.now() })] }),
    );
    const [outcome, ...rs] = await Promise.all([resetDemoStore(tdb.kysely, d.storeId, clock.now(), { force: true }), ...syncs]);
    expect(outcome).toBe("reset");
    for (const x of rs) expect(x.status, JSON.stringify(x.body)).toBe(200);
    const price = await tdb.kysely.selectFrom("products").select("price_fen").where("store_id", "=", d.storeId).where("id", "=", pid).executeTakeFirstOrThrow();
    expect(price.price_fen).toBe("200");
    // 每个手机这次或下次同步都拿到 discard_outbox
    for (const p of phones) expect((await syncOk(app, p.token, { epoch: d.epoch })).device.discard_outbox).toBe(true);
    const ops = await tdb.kysely.selectFrom("ops").select("device_id").where("store_id", "=", d.storeId).execute();
    expect(new Set(ops.map((o) => o.device_id))).toEqual(new Set([seedId(d.storeId, "device:seed")]));
    await app.close();
  });

  it("重置清理旧设备：本次撤销的留着（还要收 discard_outbox），7 天前撤销的删掉", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    const old = await demoLogin(app);
    clock.advance(2 * 3600_000);
    await resetDemoStore(tdb.kysely, d.storeId, clock.now());
    const recent = await demoLogin(app);
    clock.advance(8 * 86_400_000);
    await resetDemoStore(tdb.kysely, d.storeId, clock.now());
    const ids = (await tdb.kysely.selectFrom("devices").select("id").where("store_id", "=", d.storeId).execute()).map((x) => x.id);
    expect(ids).not.toContain(old.deviceId);
    expect(ids).toContain(recent.deviceId);
    expect((await syncOk(app, recent.token, { epoch: d.epoch })).device.discard_outbox).toBe(true);
    await app.close();
  });

  it("重置拒绝碰非演示店", async () => {
    const s = await createStore(tdb.kysely, { name: "元辉" });
    await createAccount(tdb.kysely, { storeId: s.id, username: `boss_${randomUUID().slice(0, 6)}`, password: PASSWORD });
    await expect(resetDemoStore(tdb.kysely, s.id, new Date(T0), { force: true })).rejects.toThrow(/不是演示店/);
  });
});

describe("演示登录与注销申请（§14 S03-9 的裁定）", () => {
  it("审核号在注销申请中：演示登录照样发令牌，响应带 delete_pending_until；同步整批不应用；重置后撤回", async () => {
    const clock = new TestClock(T0);
    const d = await newDemo(clock);
    const app = makeApp(tdb, { clock, config: DEMO_CONFIG });
    const p = await demoLogin(app);
    const del = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(p.token), payload: { password: PASSWORD } });
    expect(del.statusCode).toBe(200);
    const q = await demoLogin(app);
    expect(q.delete_pending_until).toBe(del.json().delete_pending_until);
    const r = await syncOk(app, q.token, { epoch: d.epoch, ops: [op("product_edit", { product_id: seedId(d.storeId, "product:water"), price_fen: 5 }, { at: clock.now() })] });
    expect([r.results, r.delete_pending_until]).toEqual([[], del.json().delete_pending_until]);
    clock.advance(2 * 3600_000);
    await resetDemoStore(tdb.kysely, d.storeId, clock.now());
    expect((await demoLogin(app)).delete_pending_until).toBeUndefined();
    await app.close();
  });
});

describe("createDevice 加固（§14 T1）", () => {
  it("没拿账号锁、拿的是别的事务的锁、锁的是别的账号：一律抛 AccountLockMissing，不建设备", async () => {
    const s = await createStore(tdb.kysely, { name: "T1 店" });
    const a = await createAccount(tdb.kysely, { storeId: s.id, username: `t1_${randomUUID().slice(0, 6)}`, password: PASSWORD });
    const s2 = await createStore(tdb.kysely, { name: "T1 别的店" });
    const a2 = await createAccount(tdb.kysely, { storeId: s2.id, username: `t1b_${randomUUID().slice(0, 6)}`, password: PASSWORD });
    const base = { storeId: s.id, accountId: a.id, role: "family" as const, now: new Date(T0) };
    await expect(tdb.kysely.transaction().execute((trx) => createDevice(trx, { ...base, accountLock: undefined, deviceId: randomUUID() }))).rejects.toThrow(AccountLockMissing);
    const foreign = await tdb.kysely.transaction().execute((trx) => lockAccount(trx, a.id));
    await expect(tdb.kysely.transaction().execute((trx) => createDevice(trx, { ...base, accountLock: foreign, deviceId: randomUUID() }))).rejects.toThrow(AccountLockMissing);
    await expect(
      tdb.kysely.transaction().execute(async (trx) => createDevice(trx, { ...base, accountLock: await lockAccount(trx, a2.id), deviceId: randomUUID() })),
    ).rejects.toThrow(AccountLockMissing);
    // 伪造的凭据（长得一样的对象）也不行
    const fake = { accountId: a.id, kind: "family", failedLogins: 0, lockedUntil: null, deleteRequestedAt: null } as const;
    await expect(tdb.kysely.transaction().execute((trx) => createDevice(trx, { ...base, accountLock: fake, deviceId: randomUUID() }))).rejects.toThrow(AccountLockMissing);
    expect(await tdb.kysely.selectFrom("devices").select("id").where("store_id", "=", s.id).execute()).toEqual([]);
    // 正确用法能建
    const ok = await tdb.kysely.transaction().execute(async (trx) => createDevice(trx, { ...base, accountLock: await lockAccount(trx, a.id), deviceId: randomUUID() }));
    expect(ok.label).toBe("手机");
  });
});
