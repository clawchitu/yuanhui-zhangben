// S03：跨店隔离 —— A 店令牌访问 B 店任何资源 404；令牌、开通码在库里只有哈希。
import { createHash } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { sql } from "kysely";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { randomUUID } from "node:crypto";
import { bearer, login, makeApp, makeLoginShop, pair, PASSWORD, TestClock } from "./helpers/auth.ts";
import { allKeys, newBarcode, op, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";
import { setupDemoStore } from "../src/demo/reset.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

describe("跨店隔离", () => {
  it("A 店令牌：B 店的设备 id、开通码 id 一律 404，B 店的东西没被动；列表里只有 A 店", async () => {
    const A = await makeLoginShop(tdb, { name: "A 店" });
    const B = await makeLoginShop(tdb, { name: "B 店" });
    const app = makeApp(tdb);
    const a = await login(app, A.username);
    const b = await login(app, B.username);
    const bCashier = await pair(app, b.token, "cashier", "B 的收银员");
    const bCode = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(b.token), payload: { role: "family" } });

    for (const [method, url] of [
      ["POST", `/v1/devices/${b.deviceId}/revoke`],
      ["POST", `/v1/devices/${bCashier.deviceId}/revoke`],
      ["GET", `/v1/pairing-tokens/${bCode.json().id}`],
      ["GET", `/v1/pairing-tokens/${bCashier.pairingId}`],
    ] as const) {
      const r = await app.inject({ method, url, headers: bearer(a.token) });
      expect([r.statusCode, r.json().code], `${method} ${url}`).toEqual([404, "not_found"]);
    }
    // B 店的设备都还在用
    for (const t of [b.token, bCashier.token]) expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(t) })).statusCode).toBe(200);

    const list = await app.inject({ method: "GET", url: "/v1/devices", headers: bearer(a.token) });
    expect(list.json().devices.map((d: { id: string }) => d.id)).toEqual([a.deviceId]);
    // revoke-others 只动自己的店
    expect((await app.inject({ method: "POST", url: "/v1/devices/revoke-others", headers: bearer(a.token) })).json()).toEqual({ revoked: 0 });
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(a.token) })).json().store.name).toBe("A 店");
    await app.close();
  });

  it("B 店的码可以被兑换成 B 店的设备，与谁兑无关；A 店的设备 id 在 B 店可以重用", async () => {
    const A = await makeLoginShop(tdb, { name: "A 店" });
    const B = await makeLoginShop(tdb, { name: "B 店" });
    const app = makeApp(tdb);
    const a = await login(app, A.username);
    await login(app, B.username, { deviceId: a.deviceId });
    const devs = await tdb.kysely.selectFrom("devices").select("store_id").where("id", "=", a.deviceId).execute();
    expect(new Set(devs.map((d) => d.store_id))).toEqual(new Set([A.storeId, B.storeId]));
    await app.close();
  });
});

describe("令牌在库里只有哈希", () => {
  it("登录、兑码、出码之后：整个 schema 里找不到令牌和码的原文，token_hash = sha256(令牌)", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const pending = (await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "family" } })).json().code;
    await app.close();

    const secrets = [boss.token, cas.token, pending];
    const tables = (
      await sql<{ table_name: string }>`SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema()`.execute(tdb.kysely)
    ).rows.map((r) => r.table_name);
    expect(tables).toContain("devices");
    for (const t of tables) {
      const rows = (await sql<{ j: string }>`SELECT row_to_json(x)::text AS j FROM ${sql.table(t)} x`.execute(tdb.kysely)).rows;
      for (const r of rows) for (const s of secrets) expect(r.j.includes(s), `${t} 里出现了原文`).toBe(false);
    }
    const sha = (s: string) => createHash("sha256").update(s).digest("hex");
    const d = await tdb.kysely.selectFrom("devices").select(["id", "token_hash"]).where("store_id", "=", shop.storeId).execute();
    expect(d.find((x) => x.id === boss.deviceId)?.token_hash).toBe(sha(boss.token));
    expect(d.find((x) => x.id === cas.deviceId)?.token_hash).toBe(sha(cas.token));
    const pt = await tdb.kysely.selectFrom("pairing_tokens").select("token_hash").where("token_hash", "=", sha(pending)).executeTakeFirst();
    expect(pt).toBeDefined();
  });

  it("令牌是 256 位随机数（base64url 43 个字符），每次都不同", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const t1 = await login(app, shop.username);
    const t2 = await login(app, shop.username);
    await app.close();
    expect(t1.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(t1.token, "base64url").length).toBe(32);
    expect(t1.token).not.toBe(t2.token);
  });
});

describe("审核号令牌遍历元辉店的每一种 id（S09、§6.1）", () => {
  it("商品、条码、流水、卖出单、批次、设备、开通码、报表：全部 404 / 拒绝，元辉店一行都没变；审核号拉到、查到的只有演示店", async () => {
    const clock = new TestClock(Date.parse("2026-11-20T02:00:00Z"));
    const app = makeApp(tdb, { clock, config: { demoLoginEnabled: true } });
    // 元辉店：两个商品（一个管保质期）、进货生成批次、一笔卖出、一个收银员、一个没用的开通码
    const yh = await makeLoginShop(tdb, { name: "元辉" });
    const boss = await login(app, yh.username);
    const cashier = await pair(app, boss.token, "cashier", "元辉收银员");
    const code = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "family" } });
    const pa = randomUUID();
    const pb = randomUUID();
    const ca = newBarcode();
    const cb = newBarcode();
    const stockIn = randomUUID();
    const saleEntry = randomUUID();
    const batch = randomUUID();
    const yhOps = [
      upsertFull({ productId: pa, barcode: ca, name: "元辉专卖的中华", price: 4500 }),
      upsertFull({ productId: pb, barcode: cb, name: "元辉的牛奶", price: 350, extra: { track_expiry: true } }),
      op("stock_in", { entry_id: stockIn, product_id: pb, barcode: cb, pack_qty: 1, pack_count: 12, unit_cost_fen: 250, expiry_date: "2026-12-01" }),
      op("sale_batch", { batch_id: batch, paid_total_fen: 4500, lines: [{ entry_id: saleEntry, product_id: pa, barcode: ca, name: "中华", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 4500 }] }),
    ];
    expect((await syncOk(app, boss.token, { epoch: yh.epoch, ops: yhOps })).results.map((r: { status: string }) => r.status)).toEqual(["applied", "applied", "applied", "applied"]);
    const lot = await tdb.kysely.selectFrom("stock_lots").select(["id", "handle_ver"]).where("store_id", "=", yh.storeId).executeTakeFirstOrThrow();
    const yhIds = [yh.storeId, yh.accountId, pa, pb, stockIn, saleEntry, batch, lot.id, boss.deviceId, cashier.deviceId, code.json().id, cashier.pairingId, ca, cb];

    const snap = async () => {
      const out: Record<string, unknown> = {};
      for (const t of ["stores", "accounts", "devices", "pairing_tokens", "products", "product_barcodes", "ops", "sale_batches", "entries", "stock_lots", "lot_moves", "removed"] as const) {
        const col = t === "stores" ? "id" : "store_id";
        out[t] = (await sql`SELECT to_jsonb(x) AS j FROM ${sql.table(t)} x WHERE ${sql.ref(col)} = ${yh.storeId} ORDER BY 1`.execute(tdb.kysely)).rows;
      }
      return out;
    };
    const before = await snap();

    // 审核号：演示登录进演示小店
    const demo = await setupDemoStore(tdb.kysely, { username: `review_${randomUUID().slice(0, 6)}`, password: PASSWORD, now: clock.now() });
    const r = await app.inject({ method: "POST", url: "/v1/auth/demo", payload: { device_id: randomUUID() } });
    expect(r.statusCode, r.body).toBe(200);
    const rv = r.json() as { token: string; epoch: string };
    const demoEpoch = (await tdb.kysely.selectFrom("stores").select("epoch").where("id", "=", demo.storeId).executeTakeFirstOrThrow()).epoch;
    expect(rv.epoch).toBe(demoEpoch);

    // HTTP：按 id 的接口一律 404
    for (const [method, url] of [
      ["POST", `/v1/devices/${boss.deviceId}/revoke`],
      ["POST", `/v1/devices/${cashier.deviceId}/revoke`],
      ["GET", `/v1/pairing-tokens/${code.json().id}`],
      ["GET", `/v1/pairing-tokens/${cashier.pairingId}`],
      ["GET", `/v1/images/${pa}?v=1`],
      ["GET", `/v1/images/${pb}?v=1`],
    ] as const) {
      const x = await app.inject({ method, url, headers: bearer(rv.token) });
      expect(x.statusCode, `${method} ${url}`).toBe(404);
    }
    // 按日期 / 月份的报表、流水列表、设备列表、me：只有演示店的东西
    const seen: string[] = [];
    for (const url of ["/v1/reports/today?date=2026-11-20", "/v1/reports/month?month=2026-11", "/v1/entries?date=2026-11-20", "/v1/entries/days?before=2026-11-21", "/v1/devices", "/v1/me"]) {
      const x = await app.inject({ method: "GET", url, headers: bearer(rv.token) });
      expect(x.statusCode, `${url} ${x.body}`).toBe(200);
      seen.push(x.body);
    }
    const { reportMonth } = await import("../src/reports/month.ts");
    expect(JSON.parse(seen[1]!)).toEqual(await reportMonth(tdb.kysely, demo.storeId, "2026-11", clock.now()));

    // 同步：每一种引用元辉店 id 的 op 都不应用
    const attack = [
      op("product_edit", { product_id: pa, price_fen: 1 }),
      op("product_edit", { product_id: pb, archived: true }),
      op("barcode_link", { barcode: newBarcode(), product_id: pa, pack_qty: 10, unit_name: "条" }),
      op("barcode_unlink", { barcode: ca, product_id: pa }),
      op("stock_in", { entry_id: randomUUID(), product_id: pa, barcode: ca, pack_qty: 1, pack_count: 5, unit_cost_fen: 100 }),
      op("opening", { entry_id: randomUUID(), product_id: pa, counted_qty: 0 }),
      op("count", { entry_id: randomUUID(), product_id: pa, counted_qty: 0, base_qty: 0, base_ver: 0 }),
      op("product_review_complete", { entry_id: randomUUID(), product_id: pa, unit_cost_fen: 1, counted_qty: 1, base_ver: 0 }),
      op("void", { target: { entry_id: saleEntry } }),
      op("void", { target: { entry_id: stockIn } }),
      op("void", { target: { batch_id: batch } }),
      op("expiry_dispose", { lot_id: lot.id, handle_ver: lot.handle_ver, actual_qty: 12, action: "expire_loss", entry_id: randomUUID() }),
      op("lot_snooze", { lot_id: lot.id, handle_ver: lot.handle_ver, actual_qty: 12, days: 3 }),
      op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 4500, lines: [{ entry_id: randomUUID(), product_id: pa, barcode: ca, name: "中华", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 4500 }] }),
      // 用元辉店已有的 entry / batch / op id 当自己的新 id：演示店里是新行（主键带店 id），元辉店那边不受影响
      op("stock_in", { entry_id: stockIn, product_id: pa, barcode: ca, pack_qty: 1, pack_count: 1, unit_cost_fen: 1 }, { id: yhOps[2]!.id }),
    ];
    const res = await syncOk(app, rv.token, { epoch: rv.epoch, ops: attack });
    // 按设计会 applied 的三条，都只落在演示店自己里：解绑一个本店没有的码是无操作（幂等）；
    // 卖出引用本店没有的商品按名称和卖价在本店自动建待确认商品（§4.4 绝不丢账）；最后一条是本店的新行
    const st = res.results.map((x: { status: string; code?: string }) => x.status);
    const byDesign = new Set([3, attack.length - 2, attack.length - 1]);
    expect(st.map((x: string, i: number) => (byDesign.has(i) ? "by-design" : x)), JSON.stringify(res.results)).toEqual(st.map((_: string, i: number) => (byDesign.has(i) ? "by-design" : "rejected")));
    expect(await snap()).toEqual(before);
    // 自动建的那个商品在演示店里，名字来自 op 里的「中华」，不是元辉店的「元辉专卖的中华」；价格、库存是演示店自己的
    const auto = await tdb.kysely.selectFrom("products").select(["name", "needs_review", "stock_qty"]).where("store_id", "=", demo.storeId).where("id", "=", pa).executeTakeFirstOrThrow();
    expect(auto).toEqual({ name: "中华", needs_review: true, stock_qty: 0 }); // 卖出 −1，最后那条本店进货 +1

    // 审核号拉到的、查到的东西里没有元辉店的任何 id 和名字
    const replica = await pullAll(app, rv.token, rv.epoch);
    const dump = JSON.stringify(replica.snapshot()) + seen.join("\n") + JSON.stringify(res);
    // pa、ca：上面那笔卖出在演示店里自建的商品和码（演示店自己的行）；stockIn 和 yhOps[2].id：演示店自己用同样的 id 记的进货
    for (const id of yhIds.filter((x) => ![stockIn, yhOps[2]!.id, pa, ca].includes(x))) expect(dump, id).not.toContain(id);
    expect(dump).not.toContain("元辉");
    expect(allKeys(replica.snapshot()).size).toBeGreaterThan(0);
    await app.close();
  });
});
