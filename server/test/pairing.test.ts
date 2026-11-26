// S03：开通码（17a / 17b、14、25d）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";
import { bearer, login, makeApp, makeLoginShop, pair, TestClock } from "./helpers/auth.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

async function createCode(app: ReturnType<typeof makeApp>, token: string, body: object) {
  return app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(token), payload: body });
}
const redeem = (app: ReturnType<typeof makeApp>, code: string, deviceId = randomUUID()) =>
  app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code, device_id: deviceId } });

describe("开通码", () => {
  it("出码响应符合契约，2 分钟后过期；码原文不进库", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const s = await login(app, shop.username);
    const c = await createCode(app, s.token, { role: "family" });
    expect(c.statusCode).toBe(201);
    const api = await loadOpenApi();
    const v = validatorFor(api.paths["/v1/pairing-tokens"].post.responses["201"].content["application/json"].schema);
    expect(v(c.json()), JSON.stringify(v.errors)).toBe(true);
    expect(Date.parse(c.json().expires_at) - clock.t).toBe(120_000);
    const row = await tdb.kysely.selectFrom("pairing_tokens").selectAll().where("id", "=", c.json().id).executeTakeFirstOrThrow();
    expect(JSON.stringify(row)).not.toContain(c.json().code);
    await app.close();
  });

  it("码里的角色决定设备角色：家人码 → family，收银员码 → cashier 且称呼由出码方定", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const fam = await pair(app, s.token, "family");
    const cas = await pair(app, s.token, "cashier", "小王");
    expect(fam.role).toBe("family");
    expect(cas).toMatchObject({ role: "cashier", label: "小王" });
    const me = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(cas.token) });
    expect(me.json()).toMatchObject({ role: "cashier", label: "小王" });
    // S23b：账号名只给家用设备，收银员的兑码响应和 /v1/me 都不带
    expect(cas.username).toBeUndefined();
    expect(me.json().username).toBeUndefined();
    expect(fam.username).toBe(shop.username);
    const famMe = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(fam.token) });
    expect(famMe.json().username).toBe(shop.username);
    const rows = await tdb.kysely.selectFrom("devices").select(["id", "role"]).where("store_id", "=", shop.storeId).execute();
    expect(rows.find((r) => r.id === cas.deviceId)?.role).toBe("cashier");
    expect(rows.find((r) => r.id === fam.deviceId)?.role).toBe("family");
    await app.close();
  });

  it("兑码响应符合契约，带店的 epoch", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const c = await createCode(app, s.token, { role: "cashier", label: "收银台" });
    const r = await redeem(app, c.json().code);
    await app.close();
    expect(r.statusCode).toBe(200);
    const api = await loadOpenApi();
    const v = validatorFor(api.components.responses.Session.content["application/json"].schema);
    expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
    expect(r.json().epoch).toBe(shop.epoch);
  });

  it("第二次使用失败：410 pairing_used", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const c = await createCode(app, s.token, { role: "family" });
    expect((await redeem(app, c.json().code)).statusCode).toBe(200);
    const again = await redeem(app, c.json().code);
    await app.close();
    expect(again.statusCode).toBe(410);
    expect(again.json().code).toBe("pairing_used");
  });

  it("两台手机同时扫同一张码：只有一台成功", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const c = await createCode(app, s.token, { role: "family" });
    const rs = await Promise.all([1, 2, 3, 4].map(() => redeem(app, c.json().code)));
    await app.close();
    expect(rs.map((r) => r.statusCode).sort()).toEqual([200, 410, 410, 410]);
  });

  it("2 分钟后失效：1:59 能用，2:00 起 410 pairing_expired", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const s = await login(app, shop.username);
    const a = await createCode(app, s.token, { role: "family" });
    const b = await createCode(app, s.token, { role: "family" });
    clock.advance(119_000);
    expect((await redeem(app, a.json().code)).statusCode).toBe(200);
    clock.advance(1_000);
    const late = await redeem(app, b.json().code);
    await app.close();
    expect(late.statusCode).toBe(410);
    expect(late.json().code).toBe("pairing_expired");
  });

  it("不认识的码 → 404 not_found", async () => {
    const app = makeApp(tdb);
    const r = await redeem(app, "no-such-code");
    await app.close();
    expect(r.statusCode).toBe(404);
  });

  it("出码的手机被退出后，它出的码作废", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const other = await login(app, shop.username);
    const c = await createCode(app, s.token, { role: "family" });
    await app.inject({ method: "POST", url: `/v1/devices/${s.deviceId}/revoke`, headers: bearer(other.token) });
    const r = await redeem(app, c.json().code);
    await app.close();
    expect(r.json().code).toBe("pairing_expired");
  });

  it("收银员码必须带称呼 → 不带 400", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const s = await login(app, shop.username);
    const r = await createCode(app, s.token, { role: "cashier" });
    const blank = await createCode(app, s.token, { role: "cashier", label: "  " });
    await app.close();
    expect(r.statusCode).toBe(400);
    expect(blank.statusCode).toBe(400);
  });

  it("轮询：waiting → used（带对方称呼）；过期的 → expired；响应符合契约", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock();
    const app = makeApp(tdb, { clock });
    const s = await login(app, shop.username);
    const api = await loadOpenApi();
    const v = validatorFor(api.paths["/v1/pairing-tokens/{id}"].get.responses["200"].content["application/json"].schema);
    const poll = async (id: string) => {
      const r = await app.inject({ method: "GET", url: `/v1/pairing-tokens/${id}`, headers: bearer(s.token) });
      expect(v(r.json()), JSON.stringify(v.errors)).toBe(true);
      return r.json();
    };
    const c = await createCode(app, s.token, { role: "cashier", label: "小李" });
    expect(await poll(c.json().id)).toEqual({ status: "waiting" });
    await redeem(app, c.json().code);
    expect(await poll(c.json().id)).toEqual({ status: "used", used_by_label: "小李" });
    const d = await createCode(app, s.token, { role: "family" });
    clock.advance(121_000);
    expect(await poll(d.json().id)).toEqual({ status: "expired" });
    await app.close();
  });

  it("演示店里审核身份也能开通演示用的收银员", async () => {
    const demo = await makeLoginShop(tdb, { demo: true });
    const app = makeApp(tdb);
    const s = await login(app, demo.username);
    const cas = await pair(app, s.token, "cashier", "演示收银员");
    await app.close();
    expect(cas.role).toBe("cashier");
  });
});
