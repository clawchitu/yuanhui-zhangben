// S03：登录、锁定、按 IP 限速、演示登录、退出、/v1/me。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";
import { bearer, login, makeApp, makeLoginShop, PASSWORD, TestClock } from "./helpers/auth.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const loginBody = (username: string, password: string) => ({ username, password, device_id: randomUUID() });

async function sessionValidator() {
  const api = await loadOpenApi();
  return validatorFor(api.components.responses.Session.content["application/json"].schema);
}
async function errorValidator() {
  const api = await loadOpenApi();
  return validatorFor(api.components.schemas.Error);
}

describe("POST /v1/auth/login", () => {
  it("正确密码 → 家用设备令牌，响应符合契约，带店的 epoch", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const res = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { ...loginBody(shop.username, PASSWORD), label: "老板的手机" } });
    await app.close();
    expect(res.statusCode).toBe(200);
    const body = res.json();
    const v = await sessionValidator();
    expect(v(body), JSON.stringify(v.errors)).toBe(true);
    expect(body).toMatchObject({ role: "family", label: "老板的手机", epoch: shop.epoch, store: { name: "元辉烟酒店", is_demo: false } });
    expect(body.delete_pending_until).toBeUndefined();
  });

  it("用户名不分大小写", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const res = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username.toUpperCase(), PASSWORD) });
    await app.close();
    expect(res.statusCode).toBe(200);
  });

  it("错误信息不区分「账号不存在」和「密码错」", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const a = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, "wrong-password") });
    const b = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody("nobody_here", "wrong-password") });
    await app.close();
    expect(a.statusCode).toBe(401);
    expect(b.statusCode).toBe(401);
    expect(a.json()).toEqual(b.json());
    expect(a.json().code).toBe("bad_credentials");
  });

  it("密码错 5 次锁 15 分钟，锁定期内正确密码也拒；15 分钟后正确密码能登录，计数清零", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const ev = await errorValidator();
    for (let i = 1; i <= 4; i++) {
      const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, `wrong-${i}`) });
      expect(r.statusCode, `第 ${i} 次`).toBe(401);
      clock.advance(1000);
    }
    const fifth = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, "wrong-5") });
    expect(fifth.statusCode).toBe(423);
    expect(fifth.json().code).toBe("locked");
    expect(ev(fifth.json()), JSON.stringify(ev.errors)).toBe(true);
    const until = Date.parse(fifth.json().locked_until);
    expect(until - clock.t).toBe(15 * 60_000);

    // 锁定期内：正确密码也拒
    clock.advance(14 * 60_000 + 59_000);
    const right = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, PASSWORD) });
    expect(right.statusCode).toBe(423);
    expect(Date.parse(right.json().locked_until)).toBe(until);
    // 锁定期内再错也不延长锁定
    const wrongAgain = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, "wrong-6") });
    expect(wrongAgain.statusCode).toBe(423);
    expect(Date.parse(wrongAgain.json().locked_until)).toBe(until);

    // 到点解锁
    clock.t = until;
    const ok = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, PASSWORD) });
    expect(ok.statusCode).toBe(200);
    const acct = await tdb.kysely.selectFrom("accounts").selectAll().where("id", "=", shop.accountId).executeTakeFirstOrThrow();
    expect(acct.failed_logins).toBe(0);
    expect(acct.locked_until).toBeNull();
    await app.close();
  });

  it("成功登录把之前的错误次数清零（不累积到下一次）", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    for (let i = 0; i < 4; i++) await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, "x-wrong") });
    expect((await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, PASSWORD) })).statusCode).toBe(200);
    const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, "x-wrong") });
    await app.close();
    expect(r.statusCode).toBe(401);
  });

  it("按 IP 限速：超过上限 429 rate_limited，带 retry_after_s；换个 IP 不受影响", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb, { rateLimits: { login: { limit: 3, windowMs: 60_000 } } });
    for (let i = 0; i < 3; i++) {
      const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody("nobody", "pw"), remoteAddress: "10.0.0.1" });
      expect(r.statusCode).toBe(401);
    }
    const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, PASSWORD), remoteAddress: "10.0.0.1" });
    expect(r.statusCode).toBe(429);
    expect(r.json().code).toBe("rate_limited");
    expect(r.json().retry_after_s).toBeGreaterThan(0);
    const other = await app.inject({ method: "POST", url: "/v1/auth/login", payload: loginBody(shop.username, PASSWORD), remoteAddress: "10.0.0.2" });
    await app.close();
    expect(other.statusCode).toBe(200);
  });

  it("同店里重复的 device_id → 400 invalid（每次登录必须新生成）", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const deviceId = randomUUID();
    await login(app, shop.username, { deviceId });
    const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: shop.username, password: PASSWORD, device_id: deviceId } });
    await app.close();
    expect(r.statusCode).toBe(400);
    expect(r.json().code).toBe("invalid");
  });

  it("同一 device_id 可以出现在另一家店（主键是 (store_id, id)）", async () => {
    const a = await makeLoginShop(tdb);
    const b = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const deviceId = randomUUID();
    await login(app, a.username, { deviceId });
    await login(app, b.username, { deviceId });
    await app.close();
  });

  it("称呼重名自动加序号", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const l1 = await login(app, shop.username, { label: "手机" });
    const l2 = await login(app, shop.username, { label: "手机" });
    const l3 = await login(app, shop.username);
    await app.close();
    expect([l1.label, l2.label, l3.label]).toEqual(["手机", "手机2", "手机3"]);
  });

  it("请求体格式不对 → 400 invalid", async () => {
    const app = makeApp(tdb);
    const r = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: "a", password: "b", device_id: "not-uuid" } });
    await app.close();
    expect(r.statusCode).toBe(400);
    expect(r.json().code).toBe("invalid");
  });
});

describe("POST /v1/auth/demo", () => {
  it("开关关着（默认）→ 404 demo_disabled", async () => {
    const app = makeApp(tdb);
    const r = await app.inject({ method: "POST", url: "/v1/auth/demo", payload: { device_id: randomUUID() } });
    await app.close();
    expect(r.statusCode).toBe(404);
    expect(r.json().code).toBe("demo_disabled");
  });

  it("开关打开 → 演示店的家用设备令牌，身份是审核（能出码，不能进元辉店）", async () => {
    const demo = await makeLoginShop(tdb, { demo: true });
    const app = makeApp(tdb, { config: { demoLoginEnabled: true } });
    const r = await app.inject({ method: "POST", url: "/v1/auth/demo", payload: { device_id: randomUUID() } });
    expect(r.statusCode).toBe(200);
    const v = await sessionValidator();
    expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
    expect(r.json()).toMatchObject({ role: "family", epoch: demo.epoch, store: { is_demo: true } });
    const me = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(r.json().token) });
    expect(me.json().store.is_demo).toBe(true);
    const devices = await tdb.kysely.selectFrom("devices").select("store_id").where("label", "like", "演示手机%").execute();
    expect(devices.map((d) => d.store_id)).toEqual([demo.storeId]);
    await app.close();
  });
});

describe("POST /v1/auth/logout 与 GET /v1/me", () => {
  it("/v1/me 返回角色、店名、设备名，符合契约", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username, { label: "柜台" });
    const r = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(s.token) });
    await app.close();
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ role: "family", store: { name: "元辉烟酒店", is_demo: false }, label: "柜台" });
    const api = await loadOpenApi();
    const v = validatorFor(api.components.schemas.Me);
    expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
  });

  it("没令牌、令牌不认识 → 401 unauthorized", async () => {
    const app = makeApp(tdb);
    const a = await app.inject({ method: "GET", url: "/v1/me" });
    const b = await app.inject({ method: "GET", url: "/v1/me", headers: bearer("A".repeat(43)) });
    const c = await app.inject({ method: "GET", url: "/v1/me", headers: { authorization: "Basic abc" } });
    await app.close();
    for (const r of [a, b, c]) {
      expect(r.statusCode).toBe(401);
      expect(r.json().code).toBe("unauthorized");
    }
  });

  it("退出登录后令牌作废：204，之后 401 revoked，设备行保留、原因 logout", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout", headers: bearer(s.token) })).statusCode).toBe(204);
    const r = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(s.token) });
    await app.close();
    expect(r.statusCode).toBe(401);
    expect(r.json().code).toBe("revoked");
    const d = await tdb.kysely.selectFrom("devices").selectAll().where("store_id", "=", shop.storeId).where("id", "=", s.deviceId).executeTakeFirstOrThrow();
    expect(d.revoke_reason).toBe("logout");
  });

  it("认证时更新 last_seen_at（每分钟最多一次）", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const s = await login(app, shop.username);
    clock.advance(5 * 60_000);
    await app.inject({ method: "GET", url: "/v1/me", headers: bearer(s.token) });
    const d = await tdb.kysely.selectFrom("devices").select("last_seen_at").where("store_id", "=", shop.storeId).where("id", "=", s.deviceId).executeTakeFirstOrThrow();
    await app.close();
    expect(d.last_seen_at?.getTime()).toBe(clock.t);
  });
});
