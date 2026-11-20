// S03：本段已实现的接口各有一条真实请求的越权测试（收银员 403、被踢设备 401 revoked、没登录 401）。
// 后面每一段新增接口时，各自在自己的测试里补上真实请求的越权测试。
import { randomUUID } from "node:crypto";
import Fastify from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { Guard } from "../src/auth/guard.ts";
import { installGuard } from "../src/auth/plugin.ts";
import { loadPermissions } from "../src/auth/permissions.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

type Req = { method: "GET" | "POST" | "PATCH"; url: (ctx: { other: string; pairing: string }) => string; payload?: object; id: string };
// 本段实现的、收银员被拒的接口（permissions.json 里收银员列为「拒」的全部 S03 接口）
const CASHIER_DENIED: Req[] = [
  { id: "POST /v1/pairing-tokens", method: "POST", url: () => "/v1/pairing-tokens", payload: { role: "family" } },
  { id: "GET /v1/pairing-tokens/{id}", method: "GET", url: (c) => `/v1/pairing-tokens/${c.pairing}` },
  { id: "GET /v1/devices", method: "GET", url: () => "/v1/devices" },
  { id: "POST /v1/devices/{id}/revoke", method: "POST", url: (c) => `/v1/devices/${c.other}/revoke` },
  { id: "POST /v1/devices/revoke-others", method: "POST", url: () => "/v1/devices/revoke-others" },
  { id: "PATCH /v1/devices/me", method: "PATCH", url: () => "/v1/devices/me", payload: { label: "我自己起的名" } },
  { id: "POST /v1/account/password", method: "POST", url: () => "/v1/account/password", payload: { old: "x", new: "yyyyyyyy" } },
  { id: "POST /v1/account/delete-request", method: "POST", url: () => "/v1/account/delete-request", payload: { password: "x" } },
  { id: "POST /v1/account/delete-cancel", method: "POST", url: () => "/v1/account/delete-cancel" },
];
const AUTHED: Req[] = [
  ...CASHIER_DENIED,
  { id: "GET /v1/me", method: "GET", url: () => "/v1/me" },
  { id: "POST /v1/auth/logout", method: "POST", url: () => "/v1/auth/logout" },
];

describe("真实请求的越权", () => {
  it("和 permissions.json 对得上：列表里的收银员格子都是「拒」，S03 的其余接口收银员能用", () => {
    const perms = loadPermissions();
    for (const r of CASHIER_DENIED) expect(perms.rules.find((x) => x.id === r.id)?.cashier.decision, r.id).toBe("deny");
    for (const id of ["GET /v1/me", "POST /v1/auth/logout"]) expect(perms.rules.find((x) => x.id === id)?.cashier.decision).toBe("allow");
  });

  it("收银员调家用接口 → 403 forbidden，且没有副作用", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const ctx = { other: boss.deviceId, pairing: cas.pairingId };
    for (const r of CASHIER_DENIED) {
      const res = await app.inject({ method: r.method, url: r.url(ctx), headers: bearer(cas.token), ...(r.payload ? { payload: r.payload } : {}) });
      expect([res.statusCode, res.json().code], r.id).toEqual([403, "forbidden"]);
    }
    // 老板没被踢、店没进注销、收银员名字没变、没多出开通码
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(boss.token) })).json().delete_pending_until).toBeUndefined();
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(cas.token) })).json().label).toBe("小王");
    const codes = await tdb.kysely.selectFrom("pairing_tokens").select("id").where("store_id", "=", shop.storeId).execute();
    expect(codes).toHaveLength(1);
    await app.close();
  });

  it("收银员能看自己（/v1/me）、能退出登录", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(cas.token) })).statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout", headers: bearer(cas.token) })).statusCode).toBe(204);
    await app.close();
  });

  it("被踢设备调本段任何需登录的接口 → 401 revoked；没令牌 → 401 unauthorized", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const kicked = await login(app, shop.username);
    await app.inject({ method: "POST", url: `/v1/devices/${kicked.deviceId}/revoke`, headers: bearer(boss.token) });
    const ctx = { other: boss.deviceId, pairing: randomUUID() };
    for (const r of AUTHED) {
      const res = await app.inject({ method: r.method, url: r.url(ctx), headers: bearer(kicked.token), ...(r.payload ? { payload: r.payload } : {}) });
      expect([res.statusCode, res.json().code], r.id).toEqual([401, "revoked"]);
      const anon = await app.inject({ method: r.method, url: r.url(ctx), ...(r.payload ? { payload: r.payload } : {}) });
      expect([anon.statusCode, anon.json().code], `${r.id} 无令牌`).toEqual([401, "unauthorized"]);
    }
    expect((await app.inject({ method: "GET", url: "/v1/me", headers: bearer(boss.token) })).statusCode).toBe(200);
    await app.close();
  });

  it("权限先于请求体校验：收银员发格式错的请求也是 403，不是 400", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const r = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(cas.token), payload: { role: "boss" } });
    await app.close();
    expect(r.statusCode).toBe(403);
  });
});

describe("每个路由都必须在权限表里", () => {
  it("注册一个 permissions.json 里没有的路由 → 启动失败", async () => {
    const app = Fastify();
    app.decorate("deps", { clock: () => new Date() } as never);
    installGuard(app, new Guard());
    expect(() => app.get("/v1/not-in-permissions", async () => ({}))).toThrow(/不在 contracts\/permissions.json 里/);
    await app.close();
  });

  it("实际的 app 能启动（所有已注册路由都在表里）", async () => {
    const app = makeApp(tdb);
    await app.ready();
    await app.close();
  });
});
