// S03：改密码、申请注销、撤回注销，以及「注销期间禁止写账与开通」。真正删除和导出在 S09。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";
import { Guard } from "../src/auth/guard.ts";
import { bearer, login, makeApp, makeLoginShop, pair, PASSWORD, TestClock } from "./helpers/auth.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

describe("改密码", () => {
  it("原密码对 → 204，新密码能登录、旧密码不能；其他手机不被踢", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const a = await login(app, shop.username);
    const b = await login(app, shop.username);
    const r = await app.inject({ method: "POST", url: "/v1/account/password", headers: bearer(a.token), payload: { old: PASSWORD, new: "new-password-9" } });
    expect(r.statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(b.token) })).statusCode).toBe(200);
    await expect(login(app, shop.username)).rejects.toThrow(/401/);
    await login(app, shop.username, { password: "new-password-9" });
    await app.close();
  });

  it("原密码错 → 401 bad_credentials；新密码短于 8 位 → 400", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const a = await login(app, shop.username);
    const wrong = await app.inject({ method: "POST", url: "/v1/account/password", headers: bearer(a.token), payload: { old: "nope-nope", new: "new-password-9" } });
    const short = await app.inject({ method: "POST", url: "/v1/account/password", headers: bearer(a.token), payload: { old: PASSWORD, new: "1234567" } });
    await app.close();
    expect([wrong.statusCode, wrong.json().code]).toEqual([401, "bad_credentials"]);
    expect(short.statusCode).toBe(400);
  });
});

describe("注销", () => {
  it("申请注销：要密码；记 delete_requested_at，全部设备（含本机）退出，未用的开通码作废", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const code = (await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "family" } })).json().code;

    const bad = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: "wrong-pass" } });
    expect(bad.statusCode).toBe(401);

    const r = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } });
    expect(r.statusCode).toBe(200);
    const api = await loadOpenApi();
    const v = validatorFor(api.paths["/v1/account/delete-request"].post.responses["200"].content["application/json"].schema);
    expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
    expect(Date.parse(r.json().delete_pending_until) - clock.t).toBe(7 * 24 * 3600e3);

    for (const t of [boss.token, cas.token]) {
      expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(t) })).json().code).toBe("revoked");
    }
    const reasons = await tdb.kysely.selectFrom("devices").select("revoke_reason").where("store_id", "=", shop.storeId).execute();
    expect(new Set(reasons.map((x) => x.revoke_reason))).toEqual(new Set(["account_delete"]));
    // 申请前出的码也不能用了
    const red = await app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code, device_id: randomUUID() } });
    expect(red.statusCode).toBe(410);
    await app.close();
  });

  it("注销申请中：能登录（响应带 delete_pending_until），但开通设备被拒 403 delete_pending；撤回后恢复", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const req = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } });
    const until = req.json().delete_pending_until;
    clock.advance(3600e3);

    const again = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: shop.username, password: PASSWORD, device_id: randomUUID() } });
    expect(again.statusCode).toBe(200);
    expect(again.json().delete_pending_until).toBe(until);
    const tok = again.json().token;
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(tok) })).json().delete_pending_until).toBe(until);

    // 开通设备被拒（家人码、收银员码都一样）
    for (const payload of [{ role: "family" }, { role: "cashier", label: "小王" }]) {
      const p = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(tok), payload });
      expect([p.statusCode, p.json().code]).toEqual([403, "delete_pending"]);
    }
    // 重复申请不重新起算
    const dup = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(tok), payload: { password: PASSWORD } });
    expect(dup.json().delete_pending_until).toBe(until);

    const relog = await login(app, shop.username);
    const cancel = await app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(relog.token) });
    expect(cancel.statusCode).toBe(204);
    const p = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(relog.token), payload: { role: "family" } });
    expect(p.statusCode).toBe(201);
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(relog.token) })).json().delete_pending_until).toBeUndefined();
    await app.close();
  });

  it("注销申请中，有人拿着之前漏网的码来兑 → 403 delete_pending", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const code = (await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "family" } })).json().code;
    // 直接改库模拟：账号进入注销，但码还没被作废
    await tdb.kysely.updateTable("accounts").set({ delete_requested_at: new Date() }).where("id", "=", shop.accountId).execute();
    const r = await app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code, device_id: randomUUID() } });
    await app.close();
    expect([r.statusCode, r.json().code]).toEqual([403, "delete_pending"]);
  });

  it("注销期间写账被拒：guard 对每一种 op 都判 delete_pending（sync 接口在 S04 接上）", () => {
    const g = new Guard();
    const f = { now: new Date(), config: { demoLoginEnabled: false, recoveryMode: false }, deletePending: true };
    for (const t of ["sale_batch", "void", "stock_in", "product_edit", "count"]) {
      expect(g.decideOp(t, {}, "family", f).code, t).toBe("delete_pending");
    }
  });

  it("不在注销中撤回 → 409 not_delete_pending；超过 7 天 → 409", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const r = await app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(boss.token) });
    expect([r.statusCode, r.json().code]).toEqual([409, "not_delete_pending"]);
    await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } });
    clock.advance(7 * 24 * 3600e3 + 1000);
    const relog = await login(app, shop.username);
    const late = await app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(relog.token) });
    await app.close();
    expect(late.statusCode).toBe(409);
  });
});
