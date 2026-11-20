import { afterAll, describe, expect, it } from "vitest";
import pg from "pg";
import { buildApp } from "../src/app.js";

describe("S00 占位", () => {
  const app = buildApp();
  afterAll(() => app.close());

  it("GET /v1/health 返回 ok", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
  });

  // CI 里设置 DATABASE_URL 和 REQUIRE_DB=1，必须连得上 Postgres 服务容器；
  // 本机没设 DATABASE_URL 时跳过。
  const dbUrl = process.env.DATABASE_URL;
  it.skipIf(!dbUrl && process.env.REQUIRE_DB !== "1")("能连上 Postgres", async () => {
    expect(dbUrl, "REQUIRE_DB=1 但没有 DATABASE_URL").toBeTruthy();
    const client = new pg.Client({ connectionString: dbUrl });
    await client.connect();
    try {
      const r = await client.query("select 1 as one, current_setting('server_version_num')::int as v");
      expect(r.rows[0].one).toBe(1);
      expect(r.rows[0].v).toBeGreaterThanOrEqual(160000);
    } finally {
      await client.end();
    }
  });
});
