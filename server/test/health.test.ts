import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
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

  it("连接建立了但查询卡住（表被锁）：约 2 秒内 503，卡住的连接被销毁不回池，之后恢复 200、连接池能正常关闭", async () => {
    const db = createDb({ connectionString: tdb.url, max: 2 });
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
      expect(db.pool.totalCount).toBe(0); // 卡住的连接都销毁了
    } finally {
      await locker.query("ROLLBACK");
      locker.release();
    }
    expect((await app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(200);
    await app.close();
    await db.close(); // 不会因为残留的查询挂住
  }, 15_000);

  it("S00 的 /v1/health 已经去掉（Q13）", async () => {
    const app = buildApp({ config: testConfig(), db: tdb, logger: false });
    const res = await app.inject({ method: "GET", url: "/v1/health" });
    await app.close();
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ code: "not_found" });
  });
});
