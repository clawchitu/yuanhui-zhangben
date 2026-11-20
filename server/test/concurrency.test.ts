// S03 的并发回归（真实 Postgres）：并发登录不能绕过或清掉锁定；兑码和申请注销同时进行不死锁、不漏撤销。
import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, PASSWORD } from "./helpers/auth.ts";
import { verifyPassword } from "../src/auth/password.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const loginReq = (username: string, password: string, deviceId = randomUUID()) => ({
  method: "POST" as const,
  url: "/v1/auth/login",
  payload: { username, password, device_id: deviceId },
});

const accountRow = (id: string) =>
  tdb.kysely.selectFrom("accounts").select(["failed_logins", "locked_until"]).where("id", "=", id).executeTakeFirstOrThrow();

function gate() {
  let open!: () => void;
  const p = new Promise<void>((r) => (open = r));
  return { p, open };
}

/** 本测试 schema 里正在等锁的连接数 */
async function lockWaiters(): Promise<number> {
  const r = await tdb.pool.query(
    `select count(distinct a.pid)::int as n
       from pg_stat_activity a
      where a.wait_event_type = 'Lock'
        and exists (select 1 from pg_locks l
                      join pg_class c on c.oid = l.relation
                      join pg_namespace ns on ns.oid = c.relnamespace
                     where l.pid = a.pid and ns.nspname = $1)`,
    [tdb.schema],
  );
  return r.rows[0].n as number;
}

async function waitFor(cond: () => Promise<boolean>, what: string) {
  const until = Date.now() + 15_000;
  while (!(await cond())) {
    if (Date.now() > until) throw new Error(`等不到：${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe("并发登录（§14 S03-3）", () => {
  it("受控交错：正确密码验完之前账号被锁 → 423，不清锁、不建设备", async () => {
    const shop = await makeLoginShop(tdb);
    const g = gate();
    let started!: () => void;
    const verifying = new Promise<void>((r) => (started = r));
    const app = makeApp(tdb);
    // 真实的 argon2id 验完之后，让正确密码的请求停在发令牌之前
    app.deps.verifyPassword = async (hash, password) => {
      const ok = await verifyPassword(hash, password);
      if (password === PASSWORD) {
        started();
        await g.p;
      }
      return ok;
    };
    const deviceId = randomUUID();
    const right = app.inject(loginReq(shop.username, PASSWORD, deviceId));
    await verifying;
    const wrong = [];
    for (let i = 1; i <= 5; i++) wrong.push((await app.inject(loginReq(shop.username, `wrong-${i}`))).statusCode);
    expect(wrong).toEqual([401, 401, 401, 401, 423]);
    const lockedUntil = (await accountRow(shop.accountId)).locked_until;
    expect(lockedUntil).not.toBeNull();

    g.open();
    const r = await right;
    await app.close();
    expect([r.statusCode, r.json().code]).toEqual([423, "locked"]);
    expect(Date.parse(r.json().locked_until)).toBe(lockedUntil!.getTime());
    expect(await accountRow(shop.accountId)).toEqual({ failed_logins: 0, locked_until: lockedUntil });
    const dev = await tdb.kysely.selectFrom("devices").select("id").where("id", "=", deviceId).executeTakeFirst();
    expect(dev).toBeUndefined();
  });

  it("20 个错密码 + 1 个对密码同时发：结束后账号是锁定的；对的那个只有赶在锁生效前才拿到令牌", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const rightId = randomUUID();
    const reqs = [
      ...Array.from({ length: 20 }, (_, i) => loginReq(shop.username, `wrong-${i}`)),
      loginReq(shop.username, PASSWORD, rightId),
    ];
    const rs = await Promise.all(reqs.map((q) => app.inject(q)));
    await app.close();
    const wrong = rs.slice(0, 20).map((r) => r.statusCode);
    const right = rs[20]!;
    expect(wrong.every((c) => c === 401 || c === 423), wrong.join(",")).toBe(true);
    const acct = await accountRow(shop.accountId);
    // 锁一定在，没被正确密码清掉
    expect(acct.locked_until).not.toBeNull();
    expect(acct.locked_until!.getTime()).toBeGreaterThan(Date.now());
    expect(acct.failed_logins).toBe(0);
    const dev = await tdb.kysely.selectFrom("devices").select("created_at").where("id", "=", rightId).executeTakeFirst();
    if (right.statusCode === 200) {
      // 拿到令牌的话，计数在它那一刻清零，之后至少又错了 5 次才锁上：401 最多 4 + 4 个
      expect(dev).toBeDefined();
      expect(wrong.filter((c) => c === 401).length).toBeLessThanOrEqual(8);
    } else {
      expect([right.statusCode, right.json().code]).toEqual([423, "locked"]);
      expect(dev).toBeUndefined();
      expect(wrong.filter((c) => c === 401)).toHaveLength(4);
    }
  });
});

describe("兑码和申请注销同时进行（加锁顺序：账号 → 开通码）", () => {
  it("受控交错：不死锁、不报 500；注销结束后店里没有还有效的设备", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const c = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "family" } });
    expect(c.statusCode).toBe(201);
    const { id: pairingId, code } = c.json() as { id: string; code: string };

    // 另一个连接先占住这张码的行锁，让兑码和注销都卡在它后面，再一起放开
    const holder = new pg.Client({ connectionString: tdb.url });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("SELECT 1 FROM pairing_tokens WHERE id = $1 FOR UPDATE", [pairingId]);

      const newDevice = randomUUID();
      const redeem = app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code, device_id: newDevice } });
      await waitFor(async () => (await lockWaiters()) >= 1, "兑码在等锁");
      const del = app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } });
      await waitFor(async () => (await lockWaiters()) >= 2, "注销也在等锁");
      await holder.query("COMMIT");

      const [r, d] = await Promise.all([redeem, del]);
      expect(d.statusCode, d.body).toBe(200);
      // 兑码要么抢在注销前（200，随后被注销踢掉），要么在注销之后（码已作废 410 / 注销中 403）
      expect([200, 403, 410], r.body).toContain(r.statusCode);
      const live = await tdb.kysely
        .selectFrom("devices")
        .select("id")
        .where("store_id", "=", shop.storeId)
        .where("revoked_at", "is", null)
        .execute();
      expect(live).toEqual([]);
      if (r.statusCode === 200) {
        const me = await app.inject({ method: "GET", url: "/v1/me", headers: bearer(r.json().token) });
        expect([me.statusCode, me.json().code]).toEqual([401, "revoked"]);
      }
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
      await holder.end();
      await app.close();
    }
  });

  it("不加控制同时发 10 轮：没有 500", async () => {
    for (let round = 0; round < 10; round++) {
      const shop = await makeLoginShop(tdb);
      const app = makeApp(tdb);
      const boss = await login(app, shop.username);
      const c = await app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: bearer(boss.token), payload: { role: "cashier", label: "小王" } });
      const [r, d] = await Promise.all([
        app.inject({ method: "POST", url: "/v1/auth/pair/redeem", payload: { code: c.json().code, device_id: randomUUID() } }),
        app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } }),
      ]);
      await app.close();
      expect(d.statusCode, d.body).toBe(200);
      expect([200, 403, 410], r.body).toContain(r.statusCode);
      const live = await tdb.kysely.selectFrom("devices").select("id").where("store_id", "=", shop.storeId).where("revoked_at", "is", null).execute();
      expect(live).toEqual([]);
    }
  });
});
