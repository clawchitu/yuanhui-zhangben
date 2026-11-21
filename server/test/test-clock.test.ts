// 测试基础设施：makeApp 默认用固定时钟（TEST_NOW = 上海 2026-11-20 10:00），测试不随真实日期推进而失败。
// 防回归：helpers/sync.ts 的 op() 默认把流水写在 2026-11-20；用真实时钟的话，家用 35 天拉取窗口（§3.4）约在 12-25 起就把它排除。
// 用 `TEST_SHIFT_NOW=2027-01-15T10:00:00+08:00 npm test` 可以把「现在」整体推到以后验证（test/setup/shift-now.ts）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, TEST_NOW } from "./helpers/auth.ts";
import { op, pullAll, syncOk, upsertFull } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

describe("测试默认固定时钟", () => {
  it("makeApp 不传 clock：服务器时钟固定在 TEST_NOW；传 \"real\" 才用真实时间", async () => {
    const fixed = makeApp(tdb);
    expect(fixed.deps.clock().getTime()).toBe(TEST_NOW);
    await fixed.close();
    const real = makeApp(tdb, { clock: "real" });
    expect(Math.abs(real.deps.clock().getTime() - Date.now())).toBeLessThan(5_000);
    await real.close();
  });

  it("op() 默认日期写的卖出，家用拉流水总能拉到（不随真实日期过期）", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const u = upsertFull({ price: 300 });
    const pid = u.payload.product_id as string;
    const s = op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: 300,
      lines: [{ entry_id: randomUUID(), product_id: pid, barcode: u.payload.barcode, name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 300 }],
    });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [u, s], pull: false });
    const snap = (await pullAll(app, boss.token, shop.epoch)).snapshot();
    expect(snap.entries.map((e: { type: string }) => e.type)).toEqual(["sale"]);
    await app.close();
  });
});
