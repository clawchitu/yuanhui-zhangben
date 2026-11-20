import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import type pg from "pg";
import { createDb } from "../src/db.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { loadOpenApi, validatorFor } from "./helpers/contract.ts";

describe("GET /healthz", () => {
  let tdb: TestDb;
  beforeAll(async () => {
    tdb = await createTestDb();
  });
  afterAll(() => tdb.drop());

  it("数据库正常时 200 {ok:true}，且符合契约", async () => {
    const app = buildApp({ config: testConfig(), db: tdb, logger: false });
    const res = await app.inject({ method: "GET", url: "/healthz" });
    await app.close();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
    const api = await loadOpenApi();
    const v = validatorFor(api.paths["/healthz"].get.responses["200"].content["application/json"].schema);
    expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
  });

  it("数据库连不上时 503 {code:'unavailable'}（契约 Error）", async () => {
    // 端口 1 上没有 Postgres：连接被拒
    const bad = createDb({ connectionString: "postgres://nobody@127.0.0.1:1/none", connectionTimeoutMillis: 500 });
    const app = buildApp({ config: testConfig(), db: bad, logger: false });
    const res = await app.inject({ method: "GET", url: "/healthz" });
    await app.close();
    await bad.close();
    expect(res.statusCode).toBe(503);
    expect(res.json().code).toBe("unavailable");
    const api = await loadOpenApi();
    const v = validatorFor(api.components.schemas.Error);
    expect(v(res.json()), JSON.stringify(v.errors)).toBe(true);
  });

  it("运行中数据库断开（连接池关闭）后 503，而不是挂住或 500", async () => {
    const db = createDb({ connectionString: tdb.url, connectionTimeoutMillis: 500 });
    const app = buildApp({ config: testConfig(), db, logger: false });
    expect((await app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(200);
    // 关掉连接池：之后任何查询都会立即失败，模拟运行中数据库掉线
    await db.close();
    const res = await app.inject({ method: "GET", url: "/healthz" });
    await app.close();
    expect(res.statusCode).toBe(503);
  });

  it("数据库不响应时 2 秒左右返回 503（不无限等）", async () => {
    // 一个只接受 TCP、永远不回话的端口：连接超时
    const net = await import("node:net");
    const sockets: import("node:net").Socket[] = [];
    const server = net.createServer((s) => sockets.push(s));
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as import("node:net").AddressInfo).port;
    const db = createDb({ connectionString: `postgres://x@127.0.0.1:${port}/x`, connectionTimeoutMillis: 10_000 });
    const app = buildApp({ config: testConfig(), db, logger: false });
    const t0 = Date.now();
    const res = await app.inject({ method: "GET", url: "/healthz" });
    const ms = Date.now() - t0;
    await app.close();
    sockets.forEach((s) => s.destroy());
    server.close();
    await db.close().catch(() => {});
    expect(res.statusCode).toBe(503);
    expect(ms).toBeLessThan(3000);
  });

  // 机器忙的时候取连接本身就要几百毫秒：取连接超过 0.5 秒时，2 秒的总时限先于 1.5 秒的 statement_timeout 到，
  // 探活先回 503，那条卡住的连接要再过一会儿才被销毁。所以不能在拿到 503 的当下就数连接池，
  // 要等每次探活都把连接交回来（每次正好交回一次），再看是不是全部销毁、一条都没回池（Codex 第二轮首跑不稳的原因）。
  // 第二种情况用「取连接前先等 0.8 秒」把这个交错固定下来。
  for (const connectDelayMs of [0, 800]) {
    it(`连接建立了但查询卡住（表被锁，取连接延迟 ${connectDelayMs} 毫秒）：约 2 秒内 503，卡住的连接被销毁不回池，之后恢复 200、连接池能正常关闭`, async () => {
      const db = createDb({ connectionString: tdb.url, max: 2 });
      const connect = db.pool.connect.bind(db.pool) as () => Promise<pg.PoolClient>;
      (db.pool as { connect: () => Promise<pg.PoolClient> }).connect = async () => {
        if (connectDelayMs) await new Promise((r) => setTimeout(r, connectDelayMs));
        return connect();
      };
      const releases: unknown[] = [];
      let allReleased!: () => void;
      const released = new Promise<void>((r) => (allReleased = r));
      db.pool.on("release", (err) => {
        releases.push(err);
        if (releases.length === 3) allReleased();
      });
      const app = buildApp({ config: testConfig(), db, logger: false });
      const locker = await tdb.pool.connect();
      try {
        await locker.query("BEGIN");
        await locker.query("LOCK TABLE stores IN ACCESS EXCLUSIVE MODE");
        // 连续探 3 次，池子只有 2 条连接：如果卡住的连接不释放，第 3 次会一直取不到连接
        for (let i = 0; i < 3; i++) {
          const t0 = Date.now();
          const res = await app.inject({ method: "GET", url: "/healthz" });
          expect(res.statusCode).toBe(503);
          expect(Date.now() - t0).toBeLessThan(3000);
        }
        // 表还锁着：等 3 次探活都把连接交回来（查询超时后），每一条都是带错误交回的（销毁），一条都没回池
        await released;
        expect(releases).toHaveLength(3);
        expect(releases.every((e) => e)).toBe(true);
        expect(db.pool.totalCount).toBe(0);
        expect(db.pool.idleCount).toBe(0);
      } finally {
        await locker.query("ROLLBACK");
        locker.release();
      }
      expect((await app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(200);
      await app.close();
      await db.close(); // 不会因为残留的查询挂住
    }, 15_000);
  }

  it("S00 的 /v1/health 已经去掉（Q13）", async () => {
    const app = buildApp({ config: testConfig(), db: tdb, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/health" });
    await app.close();
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ code: "not_found" });
  });
});
