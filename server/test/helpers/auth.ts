// 测试辅助：建能登录的店（真实 argon2 密码）、可拨的钟、登录 / 开通拿令牌。
import { randomBytes, randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { buildApp, type AppDeps } from "../../src/app.ts";
import { createAccount } from "../../scripts/create-account.ts";
import { createStore } from "../../scripts/create-store.ts";
import type { Config } from "../../src/config.ts";
import { testConfig, type TestDb } from "./db.ts";

export const PASSWORD = "correct-horse-1";

/** 测试默认的「现在」：上海 2026-11-20 10:00（UTC 02:00），和 helpers/sync.ts 等处写死的流水时间配套 */
export const TEST_NOW = Date.parse("2026-11-20T02:00:00Z");

export class TestClock {
  t: number;
  constructor(start = TEST_NOW) {
    this.t = start;
  }
  now = () => new Date(this.t);
  advance(ms: number) {
    this.t += ms;
  }
}

export function makeApp(
  tdb: TestDb,
  o: {
    /**
     * 服务器时钟。默认新建一个固定在 TEST_NOW 的 TestClock，测试不随真实日期推进而失败（拉流水的保留窗口等）。
     * 确实要真实时钟的用例显式传 "real"。
     */
    clock?: TestClock | "real";
    config?: Partial<Config>;
    rateLimits?: AppDeps["rateLimits"];
    syncPageSize?: number;
    /** 换一个连接池（默认用 tdb 自己的） */
    db?: AppDeps["db"];
    /** 收服务端日志（见 errorLog） */
    logStream?: AppDeps["logStream"];
    /** 换掉验密码（测「验密码期间账号被清除」） */
    verifyPassword?: AppDeps["verifyPassword"];
  } = {},
): FastifyInstance {
  return buildApp({
    config: testConfig(o.config),
    db: o.db ?? tdb,
    logger: false,
    logStream: o.logStream,
    clock: o.clock === "real" ? undefined : (o.clock ?? new TestClock()).now,
    rateLimits: o.rateLimits,
    syncPageSize: o.syncPageSize,
    verifyPassword: o.verifyPassword,
  });
}

/** 收服务端 error 级日志：出 500 时把错误栈带进断言信息，CI 上也能看到根因 */
export function errorLog() {
  const lines: string[] = [];
  return {
    stream: { write: (l: string) => void (JSON.parse(l).level >= 50 && lines.push(l)) },
    lines,
    toString: () => (lines.length ? `\n服务端错误：\n${lines.slice(0, 3).join("\n")}` : ""),
  };
}

/** 建一个店和账号，返回用户名 */
export async function makeLoginShop(tdb: TestDb, o: { demo?: boolean; name?: string } = {}) {
  const store = await createStore(tdb.kysely, { name: o.name ?? (o.demo ? "演示小店" : "元辉烟酒店"), isDemo: o.demo });
  const username = `${o.demo ? "review" : "boss"}_${randomBytes(4).toString("hex")}`;
  const account = await createAccount(tdb.kysely, {
    storeId: store.id,
    username,
    password: PASSWORD,
    kind: o.demo ? "review" : "family",
  });
  return { storeId: store.id, epoch: store.epoch, accountId: account.id, username };
}

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

export async function login(app: FastifyInstance, username: string, o: { label?: string; deviceId?: string; password?: string } = {}) {
  const deviceId = o.deviceId ?? randomUUID();
  const res = await app.inject({
    method: "POST",
    url: "/v1/auth/login",
    payload: { username, password: o.password ?? PASSWORD, device_id: deviceId, ...(o.label ? { label: o.label } : {}) },
  });
  if (res.statusCode !== 200) throw new Error(`登录失败 ${res.statusCode} ${res.body}`);
  return { ...(res.json() as { token: string; role: string; label: string; epoch: string }), deviceId };
}

/** 用 token 的家用设备出码并让新手机兑换 */
export async function pair(app: FastifyInstance, token: string, role: "family" | "cashier", label?: string) {
  const c = await app.inject({
    method: "POST",
    url: "/v1/pairing-tokens",
    headers: bearer(token),
    payload: { role, ...(label ? { label } : {}) },
  });
  if (c.statusCode !== 201) throw new Error(`出码失败 ${c.statusCode} ${c.body}`);
  const deviceId = randomUUID();
  const r = await app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code: c.json().code, device_id: deviceId } });
  if (r.statusCode !== 200) throw new Error(`兑码失败 ${r.statusCode} ${r.body}`);
  return { ...(r.json() as { token: string; role: string; label: string }), deviceId, pairingId: c.json().id as string };
}
