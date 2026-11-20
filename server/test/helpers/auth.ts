// 测试辅助：建能登录的店（真实 argon2 密码）、可拨的钟、登录 / 开通拿令牌。
import { randomBytes, randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { buildApp, type AppDeps } from "../../src/app.ts";
import { createAccount } from "../../scripts/create-account.ts";
import { createStore } from "../../scripts/create-store.ts";
import type { Config } from "../../src/config.ts";
import { testConfig, type TestDb } from "./db.ts";

export const PASSWORD = "correct-horse-1";

export class TestClock {
  t: number;
  constructor(start = Date.parse("2026-11-20T02:00:00Z")) {
    this.t = start;
  }
  now = () => new Date(this.t);
  advance(ms: number) {
    this.t += ms;
  }
}

export function makeApp(
  tdb: TestDb,
  o: { clock?: TestClock; config?: Partial<Config>; rateLimits?: AppDeps["rateLimits"] } = {},
): FastifyInstance {
  return buildApp({
    config: testConfig(o.config),
    db: tdb,
    logger: false,
    clock: o.clock?.now,
    rateLimits: o.rateLimits,
  });
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
