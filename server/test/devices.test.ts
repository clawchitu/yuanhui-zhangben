// S03：已登录的手机、踢人、让其他手机退出、改手机名。
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";
import { makeOp } from "./helpers/fixtures.ts";
import { bearer, login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

describe("设备管理", () => {
  it("踢掉的设备下一次请求得到 revoked（401），行保留、原因 kicked", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(cas.token) })).statusCode).toBe(200);
    const k = await app.inject({ method: "POST", url: `/v1/devices/${cas.deviceId}/revoke`, headers: bearer(boss.token) });
    expect(k.statusCode).toBe(204);
    for (const [method, url] of [
      ["GET", "/v1/me"],
      ["GET", "/v1/devices"],
      ["POST", "/v1/pairing-tokens"],
    ] as const) {
      const r = await app.inject({ method, url, headers: bearer(cas.token), ...(method === "POST" ? { payload: { role: "family" } } : {}) });
      expect([r.statusCode, r.json().code], `${method} ${url}`).toEqual([401, "revoked"]);
    }
    const row = await tdb.kysely.selectFrom("devices").selectAll().where("store_id", "=", shop.storeId).where("id", "=", cas.deviceId).executeTakeFirstOrThrow();
    expect(row.revoke_reason).toBe("kicked");
    expect(row.revoked_at).not.toBeNull();
    // 再踢一次：幂等，不改原因
    expect((await app.inject({ method: "POST", url: `/v1/devices/${cas.deviceId}/revoke`, headers: bearer(boss.token) })).statusCode).toBe(204);
    await app.close();
  });

  it("不能踢自己：400 cannot_revoke_self", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const r = await app.inject({ method: "POST", url: `/v1/devices/${boss.deviceId}/revoke`, headers: bearer(boss.token) });
    await app.close();
    expect(r.statusCode).toBe(400);
    expect(r.json().code).toBe("cannot_revoke_self");
  });

  it("让其他手机全部退出：只留自己，返回退出的台数", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const a = await pair(app, boss.token, "family");
    const b = await pair(app, boss.token, "cashier", "小王");
    const r = await app.inject({ method: "POST", url: "/v1/devices/revoke-others", headers: bearer(boss.token) });
    expect(r.json()).toEqual({ revoked: 2 });
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(boss.token) })).statusCode).toBe(200);
    for (const t of [a.token, b.token]) expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(t) })).json().code).toBe("revoked");
    const reasons = await tdb.kysely.selectFrom("devices").select("revoke_reason").where("store_id", "=", shop.storeId).where("revoked_at", "is not", null).execute();
    expect(reasons.map((x) => x.revoke_reason)).toEqual(["revoke_others", "revoke_others"]);
    await app.close();
  });

  it("已登录的手机：未撤销的 + 有暂存账的已撤销设备；is_me、held_count；符合契约", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username, { label: "老板" });
    const kickedWithHeld = await pair(app, boss.token, "family");
    const kickedEmpty = await pair(app, boss.token, "cashier", "小王");
    const cas = await pair(app, boss.token, "cashier", "小李");
    // 被踢设备补传上来的两笔暂存账
    for (let i = 0; i < 2; i++) {
      const op = await makeOp(tdb.kysely, shop.storeId, kickedWithHeld.deviceId);
      await tdb.kysely.updateTable("ops").set({ status: "held", result: '{"status":"held"}' }).where("store_id", "=", shop.storeId).where("id", "=", op.id).execute();
    }
    for (const d of [kickedWithHeld, kickedEmpty]) {
      await app.inject({ method: "POST", url: `/v1/devices/${d.deviceId}/revoke`, headers: bearer(boss.token) });
    }
    const r = await app.inject({ method: "GET", url: "/v1/devices", headers: bearer(boss.token) });
    expect(r.statusCode).toBe(200);
    const api = await loadOpenApi();
    const v = validatorFor(api.paths["/v1/devices"].get.responses["200"].content["application/json"].schema);
    expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
    const byId = new Map(r.json().devices.map((d: { id: string }) => [d.id, d]));
    expect(byId.size).toBe(3);
    expect(byId.get(boss.deviceId)).toMatchObject({ label: "老板", is_me: true, revoked: false, held_count: 0, role: "family" });
    expect(byId.get(cas.deviceId)).toMatchObject({ is_me: false, revoked: false, role: "cashier" });
    expect(byId.get(kickedWithHeld.deviceId)).toMatchObject({ revoked: true, held_count: 2 });
    expect(byId.has(kickedEmpty.deviceId)).toBe(false);
    await app.close();
  });

  it("改手机名：重名自动加序号，被撤销设备的旧名可以再用", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const a = await login(app, shop.username, { label: "柜台" });
    const b = await login(app, shop.username, { label: "里屋" });
    const r = await app.inject({ method: "PATCH", url: "/v1/devices/me", headers: bearer(b.token), payload: { label: "柜台" } });
    expect(r.json()).toEqual({ label: "柜台2" });
    // 改成自己现在的名字不加序号
    const same = await app.inject({ method: "PATCH", url: "/v1/devices/me", headers: bearer(a.token), payload: { label: "柜台" } });
    expect(same.json()).toEqual({ label: "柜台" });
    await app.inject({ method: "POST", url: "/v1/auth/logout", headers: bearer(a.token) });
    const again = await app.inject({ method: "PATCH", url: "/v1/devices/me", headers: bearer(b.token), payload: { label: "柜台" } });
    expect(again.json()).toEqual({ label: "柜台" });
    await app.close();
  });
});
