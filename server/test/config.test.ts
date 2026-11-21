// config.ts 与 GET /v1/config
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import { ConfigError, loadConfig } from "../src/config.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";

describe("loadConfig", () => {
  it("默认值：演示登录默认关、恢复模式默认关、min_build 0", () => {
    const c = loadConfig({ DATABASE_URL: "postgres://x" });
    expect(c).toMatchObject({ demoLoginEnabled: false, recoveryMode: false, minBuild: 0, port: 3000 });
  });

  it("缺 DATABASE_URL、非法数字、非法开关、非 http(s) 链接都在启动时报错", () => {
    expect(() => loadConfig({})).toThrow(ConfigError);
    expect(() => loadConfig({ DATABASE_URL: "x", MIN_BUILD: "-1" })).toThrow(ConfigError);
    expect(() => loadConfig({ DATABASE_URL: "x", PORT: "70000" })).toThrow(ConfigError);
    expect(() => loadConfig({ DATABASE_URL: "x", DEMO_LOGIN_ENABLED: "yes" })).toThrow(ConfigError);
    expect(() => loadConfig({ DATABASE_URL: "x", PRIVACY_URL: "javascript:alert(1)" })).toThrow(ConfigError);
  });

  it("TRUST_PROXY：默认关；打开必须同时给 Caddy 地址（IP / CIDR），格式不对启动时报错（S03-6）", () => {
    expect(loadConfig({ DATABASE_URL: "x" })).toMatchObject({ trustProxy: false, trustedProxies: [] });
    expect(() => loadConfig({ DATABASE_URL: "x", TRUST_PROXY: "1" })).toThrow(/TRUSTED_PROXY/);
    expect(() => loadConfig({ DATABASE_URL: "x", TRUST_PROXY: "1", TRUSTED_PROXY: "caddy" })).toThrow(ConfigError);
    expect(() => loadConfig({ DATABASE_URL: "x", TRUST_PROXY: "1", TRUSTED_PROXY: "10.0.0.0/33" })).toThrow(ConfigError);
    // 前缀长度 0 等于信所有对端（PR #22 Fable，§14 S03-6 补）
    for (const all of ["0.0.0.0/0", "::/0", "172.30.0.2, 0.0.0.0/0", "10.0.0.0/00"]) {
      expect(() => loadConfig({ DATABASE_URL: "x", TRUST_PROXY: "1", TRUSTED_PROXY: all })).toThrow(/前缀长度/);
    }
    expect(loadConfig({ DATABASE_URL: "x", TRUST_PROXY: "1", TRUSTED_PROXY: "172.30.0.2, 172.30.0.0/29" })).toMatchObject({
      trustProxy: true,
      trustedProxies: ["172.30.0.2", "172.30.0.0/29"],
    });
  });

  it("环境变量覆盖", () => {
    const c = loadConfig({ DATABASE_URL: "x", MIN_BUILD: "42", DEMO_LOGIN_ENABLED: "1", RECOVERY_MODE: "true" });
    expect(c).toMatchObject({ minBuild: 42, demoLoginEnabled: true, recoveryMode: true });
  });
});

describe("GET /v1/config", () => {
  let t: TestDb;
  beforeAll(async () => {
    t = await createTestDb();
  });
  afterAll(() => t.drop());

  it("无鉴权，返回 min_build / demo_login_enabled / privacy_url / support_url，符合契约 Config", async () => {
    const app = buildApp({ config: testConfig({ minBuild: 7, demoLoginEnabled: true }), db: t, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/config" });
    await app.close();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      min_build: 7,
      demo_login_enabled: true,
      privacy_url: "https://yuanhuishop.cn/privacy",
      support_url: "https://yuanhuishop.cn/support",
    });
    const v = validatorFor((await loadOpenApi()).components.schemas.Config);
    expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
  });

  it("默认 demo_login_enabled=false", async () => {
    const app = buildApp({ config: testConfig(), db: t, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/config" });
    await app.close();
    expect(res.json().demo_login_enabled).toBe(false);
  });

  it("未知路径 404，错误体符合契约 Error", async () => {
    const app = buildApp({ config: testConfig(), db: t, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/nope" });
    await app.close();
    expect(res.statusCode).toBe(404);
    const v = validatorFor((await loadOpenApi()).components.schemas.Error);
    expect(v(res.json())).toBe(true);
  });
});
