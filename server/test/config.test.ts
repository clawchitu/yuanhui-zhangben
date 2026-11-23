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

  it("API_BASE（S21 服务器地址下发）：没配就是 undefined；两个白名单地址照原样采用", () => {
    expect(loadConfig({ DATABASE_URL: "x" }).apiBase).toBeUndefined();
    expect(loadConfig({ DATABASE_URL: "x", API_BASE: "" }).apiBase).toBeUndefined();
    for (const ok of ["https://47.117.184.253", "https://api.yuanhuishop.cn", "https://api.yuanhuishop.cn/", "https://api.yuanhuishop.cn:443"]) {
      expect(loadConfig({ DATABASE_URL: "x", API_BASE: ok }).apiBase, ok).toBe(ok);
    }
  });

  it("API_BASE 不在白名单（https、主机整串相等、无用户信息、端口空或 443、路径空或 /）就拒绝启动，报错只提 API_BASE、不带值", () => {
    const bad = [
      "https://evil.example",
      "https://api.yuanhuishop.cn.evil.example",
      "https://evil.api.yuanhuishop.cn",
      "https://api.yuanhuishop.cn@evil.example",
      "https://evil.example@api.yuanhuishop.cn",
      "https://user:pw@api.yuanhuishop.cn",
      "http://47.117.184.253",
      "http://api.yuanhuishop.cn",
      "https://api.yuanhuishop.cn:8443",
      "https://47.117.184.253:8443",
      "https://api.yuanhuishop.cn/x",
      "https://api.yuanhuishop.cn?x=1",
      "https://api.yuanhuishop.cn#x",
      "https://API.yuanhuishop.cn",
      "https://47.117.184.253.",
      "api.yuanhuishop.cn",
      "not a url",
    ];
    for (const b of bad) {
      let err: unknown;
      try {
        loadConfig({ DATABASE_URL: "postgres://u:secretpw@h/db", API_BASE: b });
      } catch (e) {
        err = e;
      }
      expect(err, b).toBeInstanceOf(ConfigError);
      expect((err as Error).message, b).toMatch(/API_BASE/);
      expect((err as Error).message, b).not.toContain("secretpw");
    }
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
      product_images_enabled: false,
    });
    const v = validatorFor((await loadOpenApi()).components.schemas.Config);
    expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
  });

  it("没配 API_BASE 就不返回 api_base 字段（S21）", async () => {
    const app = buildApp({ config: testConfig(), db: t, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/config" });
    await app.close();
    expect(res.statusCode).toBe(200);
    expect(Object.keys(res.json())).not.toContain("api_base");
  });

  it("配了 API_BASE 就原样返回 api_base（两个白名单地址），符合契约 Config", async () => {
    const v = validatorFor((await loadOpenApi()).components.schemas.Config);
    for (const apiBase of ["https://47.117.184.253", "https://api.yuanhuishop.cn"]) {
      const config = testConfig({ apiBase: loadConfig({ DATABASE_URL: "x", API_BASE: apiBase }).apiBase });
      const app = buildApp({ config, db: t, logger: false });
      const res = await app.inject({ method: "GET", url: "/v1/config" });
      await app.close();
      expect(res.json().api_base).toBe(apiBase);
      expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
    }
  });

  it("契约 Config.api_base 可选、只接受 https URI", async () => {
    const v = validatorFor((await loadOpenApi()).components.schemas.Config);
    const base = { min_build: 0, demo_login_enabled: false, privacy_url: "https://yuanhuishop.cn/privacy", support_url: "https://yuanhuishop.cn/support", product_images_enabled: false };
    expect(v(base)).toBe(true);
    expect(v({ ...base, api_base: "https://api.yuanhuishop.cn" })).toBe(true);
    expect(v({ ...base, api_base: "http://47.117.184.253" })).toBe(false);
    expect(v({ ...base, api_base: "" })).toBe(false);
  });

  it("product_images_enabled（T11、S22d）：总开关开且配了对象存储才是 true；关着、或开着但没配对象存储都是 false；契约里必填", async () => {
    const { MemoryObjectStore } = await import("../src/lookup/oss.ts");
    const v = validatorFor((await loadOpenApi()).components.schemas.Config);
    for (const [enabled, store, want] of [
      [true, new MemoryObjectStore(), true],
      [false, new MemoryObjectStore(), false],
      [true, null, false],
    ] as const) {
      const app = buildApp({ config: testConfig({ productImagesEnabled: enabled }), db: t, logger: false, objectStore: store });
      const res = await app.inject({ method: "GET", url: "/v1/config" });
      await app.close();
      expect(res.json().product_images_enabled, `${enabled} ${!!store}`).toBe(want);
      expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
    }
    const { product_images_enabled: _, ...without } = { min_build: 0, demo_login_enabled: false, privacy_url: "https://yuanhuishop.cn/privacy", support_url: "https://yuanhuishop.cn/support", product_images_enabled: true };
    expect(v(without)).toBe(false);
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
