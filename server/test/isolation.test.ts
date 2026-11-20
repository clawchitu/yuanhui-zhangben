// S03：跨店隔离 —— A 店令牌访问 B 店任何资源 404；令牌、开通码在库里只有哈希。
import { createHash } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { sql } from "kysely";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";

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
