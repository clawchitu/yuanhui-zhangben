// S09：账号注销 —— 申请时生成导出包（只导本店、收银员不可、演示店不导、合计与月报一致、分页导出与一次导完逐字节相同）、
// 撤回（含生成期间撤回）、满 7 天删除（事务、幂等、并发只删一次、恰好 7 天整不删）、deletions/ 删除记录、
// OSS 图片 / 导出包 / 本机图片缓存清理（§14 T12，用内存对象存储，不碰真实 OSS）、清理失败下一轮重试。全部连真实 Postgres。
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { sql } from "kysely";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, pair, PASSWORD, TestClock } from "./helpers/auth.ts";
import { newBarcode, op, syncOk, upsertFull } from "./helpers/sync.ts";
import { readZip } from "./helpers/zip.ts";
import { parseCsv } from "../src/export/csv.ts";
import { EXPORT_FILES, MONTH_HEADER, writeStoreExport } from "../src/export/store-export.ts";
import { reportMonth } from "../src/reports/month.ts";
import { AliOssObjectStore, LocalDirObjectStore, MemoryObjectStore, archiveStoreFromConfig, objectStoreFromConfig, deletionKey, imageKey, storePrefix } from "../src/lookup/oss.ts";
import { loadConfig, type Config } from "../src/config.ts";
import { clearPurgedObjects, purgeStore, runAccountPurges, runExportJobs, type AccountJobDeps } from "../src/jobs/account-purge.ts";
import { authenticate } from "../src/auth/authenticate.ts";
import { Guard } from "../src/auth/guard.ts";
import { pullChanges } from "../src/sync/pull.ts";
import { pushOps } from "../src/sync/push.ts";
import { StoreGone } from "../src/sync/lock.ts";
import { DELETE_GRACE_MS } from "../src/auth/session.ts";
import { STORE_DATA_TABLES } from "../src/demo/wipe.ts";
import { exportStoreToFile } from "../scripts/export-store.ts";

let tdb: TestDb;
let cacheRoot: string;
beforeAll(async () => {
  tdb = await createTestDb();
  cacheRoot = await mkdtemp(path.join(tmpdir(), "yh-purge-cache-"));
});
afterAll(async () => {
  await tdb.drop();
  await rm(cacheRoot, { recursive: true, force: true });
});

const T0 = Date.parse("2026-11-20T02:00:00Z"); // 北京 11-20 10:00

function logSink() {
  const lines: Array<{ level: string; obj: Record<string, unknown>; msg: string }> = [];
  const mk = (level: string) => (obj: object, msg: string) => void lines.push({ level, obj: obj as Record<string, unknown>, msg });
  return { lines, log: { info: mk("info"), warn: mk("warn"), error: mk("error") } };
}

function deps(clock: TestClock, o: Partial<AccountJobDeps> = {}): AccountJobDeps & { images: MemoryObjectStore; archive: MemoryObjectStore } {
  return { db: tdb.kysely, images: new MemoryObjectStore(), archive: new MemoryObjectStore(), imageCacheDir: cacheRoot, clock: clock.now, ...o } as never;
}

/** 一家有两个月账的店：10 月卖出（11 月撤销，跨月）、11 月进货和带抹零的卖出；一个名字带公式和逗号引号的商品 */
async function shopWithBooks(clock: TestClock, name: string) {
  const shop = await makeLoginShop(tdb, { name });
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const a = randomUUID();
  const b = randomUUID();
  const s1 = randomUUID();
  const ca = newBarcode();
  const cb = newBarcode();
  const ops = [
    upsertFull({ productId: a, barcode: ca, name: `${name}的可乐`, price: 300 }),
    upsertFull({ productId: b, barcode: cb, name: `=HYPERLINK("x"),${name}"坏"名`, price: 1250 }),
    op("opening", { entry_id: randomUUID(), product_id: a, counted_qty: 50, unit_cost_fen: 200 }, { at: "2026-10-01T02:00:00Z" }),
    op("opening", { entry_id: randomUUID(), product_id: b, counted_qty: 10, unit_cost_fen: 800 }, { at: "2026-10-01T02:00:00Z" }),
    op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 900, lines: [{ entry_id: s1, product_id: a, barcode: ca, name: "可乐", unit_name: "罐", pack_qty: 1, pack_count: 3, unit_price_fen: 300 }] }, { at: "2026-10-25T08:00:00Z" }),
    op("stock_in", { entry_id: randomUUID(), product_id: a, barcode: ca, pack_qty: 1, pack_count: 24, unit_cost_fen: 210 }, { at: "2026-11-02T02:00:00Z" }),
    op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: 1500,
      lines: [
        { entry_id: randomUUID(), product_id: a, barcode: ca, name: "可乐", unit_name: "罐", pack_qty: 1, pack_count: 1, unit_price_fen: 300 },
        { entry_id: randomUUID(), product_id: b, barcode: cb, name: "坏名", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 1250 },
      ],
    }, { at: "2026-11-10T08:00:00Z" }),
    op("void", { target: { entry_id: s1 } }, { at: "2026-11-11T08:00:00Z" }),
  ];
  const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops });
  expect(r.results.map((x: { status: string }) => x.status), JSON.stringify(r.results)).toEqual(ops.map(() => "applied"));
  return { ...shop, app, boss, productIds: [a, b] };
}

async function zipOf(storeId: string, now: Date, pageSize?: number) {
  const pt = new PassThrough();
  const chunks: Buffer[] = [];
  pt.on("data", (c: Buffer) => chunks.push(c));
  await writeStoreExport(tdb.kysely, storeId, pt, now, { pageSize });
  pt.end();
  return Buffer.concat(chunks);
}

const csv = (files: Map<string, Buffer>, name: string) => parseCsv(files.get(name)!.toString("utf8"));
const yuanToFen = (s: string) => {
  const m = /^(-?)(\d+)\.(\d{2})$/.exec(s);
  if (!m) throw new Error(`不是金额：${s}`);
  return (m[1] ? -1 : 1) * (Number(m[2]) * 100 + Number(m[3]));
};

async function rowCounts(storeId: string) {
  const out: Record<string, number> = {};
  for (const t of [...STORE_DATA_TABLES, "devices", "accounts", "export_jobs", "demo_stores"] as const) {
    out[t] = Number((await sql<{ n: string }>`SELECT count(*)::text AS n FROM ${sql.table(t)} WHERE store_id = ${storeId}`.execute(tdb.kysely)).rows[0]!.n);
  }
  out.stores = Number((await sql<{ n: string }>`SELECT count(*)::text AS n FROM stores WHERE id = ${storeId}`.execute(tdb.kysely)).rows[0]!.n);
  return out;
}

describe("导出包", () => {
  it("申请注销 → 同一事务里登记导出任务；任务生成 CSV 压缩包放 exports/<店>/、告警；只含本店；合计与月报一致", async () => {
    const clock = new TestClock(T0);
    const yh = await shopWithBooks(clock, "元辉");
    const other = await shopWithBooks(clock, "隔壁");
    const del = await yh.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(yh.boss.token), payload: { password: PASSWORD } });
    expect(del.statusCode, del.body).toBe(200);
    const job = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", yh.storeId).executeTakeFirstOrThrow();
    expect([job.requested_at.getTime(), job.done_at, job.object_key, job.cancelled_at]).toEqual([T0, null, null, null]);
    // 重复申请不重置任务
    await tdb.kysely.updateTable("export_jobs").set({ attempts: 1 }).where("store_id", "=", yh.storeId).execute();
    const again = await login(yh.app, yh.username);
    expect((await yh.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(again.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    expect((await tdb.kysely.selectFrom("export_jobs").select("attempts").where("store_id", "=", yh.storeId).executeTakeFirstOrThrow()).attempts).toBe(1);
    await tdb.kysely.updateTable("export_jobs").set({ attempts: 0 }).where("store_id", "=", yh.storeId).execute();

    const sink = logSink();
    const d = deps(clock, { log: sink.log, exportPageSize: 2 });
    const res = await runExportJobs(d);
    expect(res.map((x) => [x.store_id, x.result])).toEqual([[yh.storeId, "done"]]);
    const keys = await d.archive.list(storePrefix("exports", yh.storeId));
    expect(keys).toEqual([res[0]!.object_key]);
    expect(keys[0]).toMatch(new RegExp(`^exports/${yh.storeId}/${String(T0).padStart(13, "0")}-[0-9a-f]{16}\\.zip$`));
    expect(d.archive.objects.get(keys[0]!)!.contentType).toBe("application/zip");
    const done = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", yh.storeId).executeTakeFirstOrThrow();
    expect([done.object_key, done.done_at?.getTime(), done.last_error]).toEqual([keys[0], T0, null]);
    expect(sink.lines.find((l) => l.obj.alert === "account_delete_export")?.obj).toEqual({ alert: "account_delete_export", store_id: yh.storeId, object_key: keys[0] });
    // 做完了不再做
    expect(await runExportJobs(d)).toEqual([]);

    const files = readZip(d.archive.objects.get(keys[0]!)!.body);
    expect([...files.keys()]).toEqual([...EXPORT_FILES]);
    for (const [n, f] of files) if (n.endsWith(".csv")) expect(f.subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
    // 只含本店：隔壁的商品名、店 id、商品 id 都找不到
    const all = [...files.values()].map((b) => b.toString("utf8")).join("\n");
    expect(all).toContain("元辉的可乐");
    expect(all).not.toContain("隔壁");
    expect(all).not.toContain(other.storeId);
    for (const id of other.productIds) expect(all).not.toContain(id);

    // 纯数字条码写成 ="…"，Excel 打开显示原样文字、不变成科学计数法（PR #20 Fable 建议 2）
    const barcodes = csv(files, "条码.csv");
    expect(barcodes.slice(1).every((r) => /^="[0-9]+"$/.test(r[0]!)), JSON.stringify(barcodes)).toBe(true);
    expect(files.get("条码.csv")!.toString("utf8")).toMatch(/\r\n"=""69[0-9]{11}""",/);
    expect(files.get("说明.txt")!.toString("utf8")).toContain('="');
    const products = csv(files, "商品.csv");
    expect(products.length - 1).toBe(2);
    // 公式注入防护和转义：解析回来是 ' 开头的原名
    expect(products.map((r) => r[1])).toContain(`'=HYPERLINK("x"),元辉"坏"名`);
    const entries = csv(files, "流水.csv");
    const header = entries[0]!;
    const col = (n: string) => header.indexOf(n);
    const body = entries.slice(1);
    expect(body.length).toBe(Number((await sql<{ n: string }>`SELECT count(*)::text AS n FROM entries WHERE store_id = ${yh.storeId}`.execute(tdb.kysely)).rows[0]!.n));
    expect(body.map((r) => Number(r[col("序号")]))).toEqual(body.map((_, i) => i + 1));

    const months = csv(files, "月报.csv");
    expect(months[0]).toEqual(MONTH_HEADER);
    expect(months.slice(1).map((r) => r[0])).toEqual(["2026-10", "2026-11"]);
    for (const m of months.slice(1)) {
      const month = m[0]!;
      const rep = await reportMonth(tdb.kysely, yh.storeId, month, clock.now());
      const mcol = (n: string) => yuanToFen(m[MONTH_HEADER.indexOf(n)]!);
      // 月报.csv = App 里的月报
      expect([mcol("卖了(元)"), mcol("赚了(元)"), mcol("优惠(元)"), mcol("月初货值(元)"), mcol("月末货值(元)")]).toEqual([
        rep.sold_fen, rep.profit_fen, rep.discount_fen, rep.reconciliation.stock_value_start_fen, rep.stock_value_end_fen,
      ]);
      // 流水.csv 按月加起来 = 月报：卖了 = 当月卖出行实收之和（含冲销行），货值变化之和 = 月末 − 月初
      const inMonth = body.filter((r) => r[col("时间(北京)")]!.startsWith(month));
      const sold = inMonth.filter((r) => r[col("类型")] === "卖出").reduce((s, r) => s + yuanToFen(r[col("实收金额(元)")]!), 0);
      const dv = inMonth.reduce((s, r) => s + yuanToFen(r[col("货值变化(元)")]!), 0);
      expect(sold).toBe(rep.sold_fen);
      expect(dv).toBe(rep.stock_value_end_fen - rep.reconciliation.stock_value_start_fen);
    }
    // 十月卖了 9 元、十一月撤销冲掉 9 元、又卖了 15 元（抹零 0.5 元）
    expect(months.slice(1).map((r) => [r[1], r[3]])).toEqual([["9.00", "0.00"], ["6.00", "0.50"]]);
    await yh.app.close();
    await other.app.close();
  });

  it("流水时间按 Asia/Shanghai 历史时区写，和月报归月一致：1988 年夏令时的月末那一笔归九月（PR #20 Codex 7）", async () => {
    const clock = new TestClock(T0);
    const shop = await makeLoginShop(tdb, { name: "夏令时店" });
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const a = randomUUID();
    const ca = newBarcode();
    const sale = (at: string, n: number) =>
      op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 100 * n, lines: [{ entry_id: randomUUID(), product_id: a, barcode: ca, name: "可乐", unit_name: "罐", pack_qty: 1, pack_count: n, unit_price_fen: 100 }] }, { at });
    const ops = [
      upsertFull({ productId: a, barcode: ca, name: "夏令时可乐", price: 100 }),
      op("opening", { entry_id: randomUUID(), product_id: a, counted_qty: 50, unit_cost_fen: 50 }, { at: "1988-08-01T02:00:00Z" }),
      sale("1988-08-31T14:30:00Z", 1), // 北京（夏令时 +9）08-31 23:30
      sale("1988-08-31T15:30:00Z", 4), // 北京（夏令时 +9）09-01 00:30；固定 +8 会写成 08-31 23:30
    ];
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops });
    expect(r.results.map((x: { status: string }) => x.status), JSON.stringify(r.results)).toEqual(ops.map(() => "applied"));
    const now = new Date("1988-10-15T02:00:00Z");
    const files = readZip(await zipOf(shop.storeId, now));
    const entries = csv(files, "流水.csv");
    const col = (n: string) => entries[0]!.indexOf(n);
    const sales = entries.slice(1).filter((x) => x[col("类型")] === "卖出");
    expect(sales.map((x) => x[col("时间(北京)")])).toEqual(["1988-08-31 23:30:00", "1988-09-01 00:30:00"]);
    const months = csv(files, "月报.csv").slice(1);
    expect(months.map((m) => m[0])).toEqual(["1988-08", "1988-09", "1988-10"]);
    for (const m of months) {
      const rep = await reportMonth(tdb.kysely, shop.storeId, m[0]!, now);
      const sold = sales.filter((x) => x[col("时间(北京)")]!.startsWith(m[0]!)).reduce((s, x) => s + yuanToFen(x[col("实收金额(元)")]!), 0);
      expect([m[0], sold, yuanToFen(m[1]!)]).toEqual([m[0], rep.sold_fen, rep.sold_fen]);
    }
    expect(months.map((m) => m[1])).toEqual(["1.00", "4.00", "0.00"]);
    await app.close();
  });

  it("分页导出（每页 1、2、3 行）与一次导完逐字节相同", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "分页店");
    const full = await zipOf(s.storeId, clock.now());
    for (const n of [1, 2, 3]) expect((await zipOf(s.storeId, clock.now(), n)).equals(full), `pageSize ${n}`).toBe(true);
    await s.app.close();
  });

  // 机器忙时（和别的全套测试同时跑）会超过默认 30 秒，单独给 120 秒（PR #20 Fable 建议 1）；断言不变
  it("大数据量：3000 条流水按 250 行一页导出，行数、序号、合计都对", { timeout: 120_000 }, async () => {
    const clock = new TestClock(T0);
    const shop = await makeLoginShop(tdb, { name: "大店" });
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const pid = randomUUID();
    const code = newBarcode();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [upsertFull({ productId: pid, barcode: code, price: 100 }), op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 100000, unit_cost_fen: 50 }, { at: "2026-11-01T00:00:00Z" })] });
    // 每笔卖出 200 行（op 的上限），15 笔 = 3000 条流水；比 3000 个 op 快得多，跑全套时不会超时
    const ops = Array.from({ length: 15 }, (_, k) =>
      op("sale_batch", {
        batch_id: randomUUID(),
        paid_total_fen: 200 * 100,
        lines: Array.from({ length: 200 }, () => ({ entry_id: randomUUID(), product_id: pid, barcode: code, name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 100 })),
      }, { at: new Date(Date.parse("2026-11-05T00:00:00Z") + k * 3_600_000) }),
    );
    for (let k = 0; k < ops.length; k += 5) await syncOk(app, boss.token, { epoch: shop.epoch, ops: ops.slice(k, k + 5) });
    const files = readZip(await zipOf(shop.storeId, clock.now(), 250));
    const body = csv(files, "流水.csv").slice(1);
    expect(body.length).toBe(3001);
    expect(new Set(body.map((r) => r[1])).size).toBe(3001);
    const nov = csv(files, "月报.csv").find((r) => r[0] === "2026-11")!;
    expect(nov[1]).toBe("3000.00");
    await app.close();
  });

  it("收银员申请注销 → 403，不登记导出任务；演示店申请注销不登记导出任务", async () => {
    const clock = new TestClock(T0);
    const shop = await makeLoginShop(tdb, { name: "收银员店" });
    const app = makeApp(tdb, { clock, config: { demoLoginEnabled: true } });
    const boss = await login(app, shop.username);
    const cashier = await pair(app, boss.token, "cashier", "小王");
    const r = await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(cashier.token), payload: { password: PASSWORD } });
    expect(r.statusCode).toBe(403);
    expect(await tdb.kysely.selectFrom("export_jobs").select("store_id").where("store_id", "=", shop.storeId).execute()).toEqual([]);
    expect((await tdb.kysely.selectFrom("accounts").select("delete_requested_at").where("id", "=", shop.accountId).executeTakeFirstOrThrow()).delete_requested_at).toBeNull();

    const demo = await makeLoginShop(tdb, { demo: true });
    const rv = await login(app, demo.username);
    expect((await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(rv.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    expect(await tdb.kysely.selectFrom("export_jobs").select("store_id").where("store_id", "=", demo.storeId).execute()).toEqual([]);
    await app.close();
  });

  it("撤回注销：任务标为撤回，定时任务删掉已生成的包和这一行；撤回后再申请是新的一次，只留新包", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "撤回店");
    const d = deps(clock);
    const req = async () => {
      const t = await login(s.app, s.username);
      expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    };
    const cancel = async () => {
      const t = await login(s.app, s.username);
      return s.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(t.token) });
    };
    await req();
    const [first] = await runExportJobs(d);
    clock.advance(3600_000);
    expect((await cancel()).statusCode).toBe(204);
    expect((await tdb.kysely.selectFrom("export_jobs").select("cancelled_at").where("store_id", "=", s.storeId).executeTakeFirstOrThrow()).cancelled_at?.getTime()).toBe(clock.t);
    expect(await runExportJobs(d)).toEqual([]);
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([]);
    expect(await tdb.kysely.selectFrom("export_jobs").select("store_id").where("store_id", "=", s.storeId).execute()).toEqual([]);

    // 撤回 → 没清理就又申请：同一行重置，新包生成后旧包删掉
    clock.advance(3600_000);
    await req();
    const [second] = await runExportJobs(d);
    clock.advance(3600_000);
    expect((await cancel()).statusCode).toBe(204);
    clock.advance(3600_000);
    await req();
    const row = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([row.requested_at.getTime(), row.cancelled_at, row.done_at, row.object_key]).toEqual([clock.t, null, null, null]);
    const [third] = await runExportJobs(d);
    expect(third!.result).toBe("done");
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([third!.object_key]);
    expect(new Set([first!.object_key, second!.object_key, third!.object_key]).size).toBe(3);
    await s.app.close();
  });

  it("生成期间撤回：刚传上去的包删掉，任务不算完成；生成失败只记原因代码并退避", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "中途撤回店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const d = deps(clock, {
      afterExportUpload: async () => {
        const u = await login(s.app, s.username);
        expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(u.token) })).statusCode).toBe(204);
      },
    });
    expect((await runExportJobs(d)).map((x) => x.result)).toEqual(["superseded"]);
    // 撤回清理在下一轮
    expect(await runExportJobs(deps(clock, { archive: d.archive }))).toEqual([]);
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([]);

    // 上传失败：last_error 是原因代码，next_try_at 按次数退避，到点重试成功
    const u = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(u.token), payload: { password: PASSWORD } });
    const flaky = new MemoryObjectStore();
    let fail = true;
    const put = flaky.putFile.bind(flaky);
    flaky.putFile = async (k, b, c) => {
      if (fail) throw Object.assign(new Error(`上传到 ${k} 失败：店名元辉`), { code: "RequestTimeout" });
      return put(k, b, c);
    };
    const f = deps(clock, { archive: flaky });
    expect((await runExportJobs(f)).map((x) => x.result)).toEqual(["failed"]);
    const j = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([j.last_error, j.attempts, j.next_try_at.getTime() - clock.t, j.done_at]).toEqual(["RequestTimeout", 1, 5 * 60_000, null]);
    expect(await runExportJobs(f)).toEqual([]);
    fail = false;
    clock.advance(5 * 60_000);
    expect((await runExportJobs(f)).map((x) => x.result)).toEqual(["done"]);
    expect((await flaky.list(storePrefix("exports", s.storeId))).length).toBe(1);
    await s.app.close();
  });

  it("作废的导出包删不掉：记一条待删标记，之后每轮重试直到删掉；生成失败分支的删除失败同样记下（PR #20 Codex 第二轮 2）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "作废包店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const archive = new MemoryObjectStore();
    const del = archive.delete.bind(archive);
    let broken = false;
    archive.delete = async (k) => {
      if (broken) throw Object.assign(new Error("超时"), { code: "RequestTimeout" });
      return del(k);
    };
    const exportsOf = () => archive.list(storePrefix("exports", s.storeId));
    // 包传上去之后、写回之前：撤回，另一个进程的撤回清理在包落地之前列举过（看不到它）、删掉了任务行；随后存储出故障
    const d = deps(clock, {
      archive,
      afterExportUpload: async () => {
        const u = await login(s.app, s.username);
        expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(u.token) })).statusCode).toBe(204);
        await runExportJobs(deps(clock, { archive: new MemoryObjectStore() }));
        expect(await tdb.kysely.selectFrom("export_jobs").select("store_id").where("store_id", "=", s.storeId).execute()).toEqual([]);
        broken = true;
      },
    });
    const sink = logSink();
    expect((await runExportJobs({ ...d, log: sink.log })).map((x) => x.result)).toEqual(["superseded"]);
    expect((await exportsOf()).length).toBe(1);
    // 存储还坏着：重试也失败，标记留着
    clock.advance(60_000);
    await runExportJobs(deps(clock, { archive }));
    expect((await exportsOf()).length).toBe(1);
    // 存储恢复：到点重试删掉
    broken = false;
    clock.advance(6 * 3_600_000);
    await runExportJobs(deps(clock, { archive }));
    expect(await exportsOf()).toEqual([]);

    // 生成失败分支：包其实写进去了但上传报错，紧接着的删除也失败 → 同样记下、之后删掉
    const u = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(u.token), payload: { password: PASSWORD } });
    const putFile = archive.putFile.bind(archive);
    let lost = true;
    archive.putFile = async (k, f, c) => {
      await putFile(k, f, c);
      if (lost) {
        broken = true;
        throw Object.assign(new Error("响应丢了"), { code: "ResponseTimeoutError" });
      }
    };
    expect((await runExportJobs(deps(clock, { archive }))).map((x) => x.result)).toEqual(["failed"]);
    expect((await exportsOf()).length).toBe(1);
    broken = false;
    lost = false;
    clock.advance(6 * 3_600_000);
    const r = await runExportJobs(deps(clock, { archive }));
    // 重试那一版生成成功；失败那一版的包被删掉，只留新包
    expect(r.map((x) => x.result)).toEqual(["done"]);
    expect(await exportsOf()).toEqual([r[0]!.object_key]);
    await s.app.close();
  });

  it("导出包分片上传失败、中止也失败：记下 uploadId，之后定时重试把这次分片上传中止掉（PR #20 Codex 第二轮 3）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "残片店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const archive = new MemoryObjectStore();
    const realPutFile = archive.putFile.bind(archive);
    let fail = true;
    // 像阿里云那样：开了一个分片上传，传到一半失败，中止也失败 → 残片留着，错误里带 uploadId
    archive.putFile = async (k, f, c) => {
      if (!fail) return realPutFile(k, f, c);
      archive.uploads.set("up-1", k);
      throw Object.assign(new Error("第 2 片失败"), { code: "InternalError", pendingUpload: { key: k, uploadId: "up-1" } });
    };
    const realAbort = archive.abortUpload.bind(archive);
    let abortBroken = true;
    archive.abortUpload = async (k, id) => {
      if (abortBroken) throw Object.assign(new Error("中止失败"), { code: "RequestTimeout" });
      return realAbort(k, id);
    };
    expect((await runExportJobs(deps(clock, { archive }))).map((x) => x.result)).toEqual(["failed"]);
    expect([...archive.uploads.keys()]).toEqual(["up-1"]);
    abortBroken = false;
    fail = false;
    clock.advance(6 * 3_600_000);
    expect((await runExportJobs(deps(clock, { archive }))).map((x) => x.result)).toEqual(["done"]);
    expect([...archive.uploads.keys()]).toEqual([]);
    expect(await tdb.kysely.selectFrom("object_discards").select("object_key").where("store_id", "=", s.storeId).execute()).toEqual([]);
    await s.app.close();
  });

  it("没配存档桶：有未完成的导出任务就打 error 级告警（export_no_archive），不静默跳过（Fable 必须改 2）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "没桶店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const sink = logSink();
    expect(await runExportJobs(deps(clock, { archive: null, log: sink.log }))).toEqual([]);
    const alerts = sink.lines.filter((l) => l.obj.alert === "export_no_archive");
    expect(alerts.map((l) => l.level)).toEqual(["error"]);
    expect(Number(alerts[0]!.obj.pending)).toBeGreaterThanOrEqual(1);
    // 任务原样留着，配上桶之后照常生成
    const j = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([j.attempts, j.done_at]).toEqual([0, null]);
    const archive = new MemoryObjectStore();
    expect((await runExportJobs(deps(clock, { archive }))).find((x) => x.store_id === s.storeId)?.result).toBe("done");
    await s.app.close();
  });

  it("失败分支删包前复查：写回其实提交了、应答前连接断开 → 包不删，任务记完成（§14 T18）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "写回断线店");
    const t = await login(s.app, s.username);
    expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    const d = deps(clock, {
      afterExportWriteBack: async () => {
        throw Object.assign(new Error("Connection terminated unexpectedly"), { code: "ECONNRESET" });
      },
    });
    const out = await runExportJobs(d);
    const mine = out.find((x) => x.store_id === s.storeId)!;
    expect(mine.result).toBe("done");
    const j = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect(j.done_at).not.toBe(null);
    expect(j.object_key).toBe(mine.object_key);
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([j.object_key]);
    expect(j.stale_cleared_at).not.toBe(null);
    expect(await tdb.kysely.selectFrom("object_discards").select("object_key").where("store_id", "=", s.storeId).execute()).toEqual([]);
    expect(j.stale_cleared_at).not.toBe(null);
    await s.app.close();
  });

  it("存档桶按配置取：本机目录和商品图共用；阿里云用第二个桶，缺了或和商品图桶相同按没配处理，不落到商品图桶（S09-11、T13）", () => {
    const base = { databaseUrl: "postgres://x" } as never as Config;
    const local = new MemoryObjectStore();
    expect(archiveStoreFromConfig({ ...base, objectStore: { kind: "local", dir: "/tmp/x" } }, local)).toBe(local);
    expect(archiveStoreFromConfig({ ...base, objectStore: { kind: "none" } }, null)).toBe(null);
    expect(
      archiveStoreFromConfig({ ...base, objectStore: { kind: "aliyun", region: "r", bucket: "yuanhui-img", accessKeyId: "a", accessKeySecret: "b" } }, local),
    ).toBe(null);
    expect(
      archiveStoreFromConfig({ ...base, objectStore: { kind: "aliyun", region: "r", bucket: "yuanhui-img", archiveBucket: "yuanhui-img", accessKeyId: "a", accessKeySecret: "b" } }, local),
    ).toBe(null);
    const ali = { kind: "aliyun" as const, region: "r", bucket: "yuanhui-img", archiveBucket: "yuanhui-backup", accessKeyId: "a", accessKeySecret: "b" };
    const archive = archiveStoreFromConfig({ ...base, objectStore: ali }, objectStoreFromConfig({ ...base, objectStore: ali }));
    expect(archive).toBeInstanceOf(AliOssObjectStore);
    expect(archive).not.toBe(local);
    expect((archive as AliOssObjectStore).bucket).toBe("yuanhui-backup");
  });

  it("配置：OBJECT_STORE=aliyun 必须同时配存档桶，且不能和商品图桶同名（Fable 第二轮裁定 ①）", () => {
    const env = { DATABASE_URL: "x", OBJECT_STORE: "aliyun", OSS_REGION: "oss-cn-shanghai", OSS_BUCKET: "yuanhui-img", OSS_ACCESS_KEY_ID: "a", OSS_ACCESS_KEY_SECRET: "b" };
    expect(() => loadConfig(env)).toThrow(/OSS_ARCHIVE_BUCKET/);
    expect(() => loadConfig({ ...env, OSS_ARCHIVE_BUCKET: "yuanhui-img" })).toThrow(/同一个桶/);
    expect(loadConfig({ ...env, OSS_ARCHIVE_BUCKET: "yuanhui-backup" }).objectStore).toMatchObject({ bucket: "yuanhui-img", archiveBucket: "yuanhui-backup" });
  });

  it("旧任务清理旧包时又撤回、重新申请、新包已生成：旧任务只删它那一版之前的包，不删新包（PR #20 Codex 3）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "新旧包店");
    const req = async () => {
      const t = await login(s.app, s.username);
      expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    };
    const cancel = async () => {
      const t = await login(s.app, s.username);
      expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(t.token) })).statusCode).toBe(204);
    };
    await req();
    const archive = new MemoryObjectStore();
    const realList = archive.list.bind(archive);
    let newer: string | undefined;
    // 旧任务写完「完成」、进入旧包清理时：撤回 → 重新申请 → 新任务（另一个进程，直接用底层的列举）生成新包
    const oldView = Object.create(archive) as MemoryObjectStore;
    oldView.list = async (prefix) => {
      if (newer === undefined) {
        newer = "";
        clock.advance(60_000);
        await cancel();
        clock.advance(60_000);
        await req();
        const plain = Object.create(archive) as MemoryObjectStore;
        plain.list = realList;
        const [r] = await runExportJobs(deps(clock, { archive: plain }));
        expect(r?.result).toBe("done");
        newer = r!.object_key!;
      }
      return realList(prefix);
    };
    const [old] = await runExportJobs(deps(clock, { archive: oldView }));
    expect(old?.result).toBe("done");
    expect(newer).toMatch(/^exports\//);
    // 新包还在、库里指着它；旧包由新任务的清理删掉
    expect(await realList(storePrefix("exports", s.storeId))).toEqual([newer]);
    const j = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect(j.object_key).toBe(newer);
    await s.app.close();
  });

  it("清理旧包失败：已完成的新包留着、任务算完成、告警照发；旧包下一轮单独重试删掉（PR #20 Codex 4）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "清旧包失败店");
    const req = async () => {
      const t = await login(s.app, s.username);
      expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    };
    const archive = new MemoryObjectStore();
    await req();
    const [first] = await runExportJobs(deps(clock, { archive }));
    // 撤回后马上又申请（撤回清理还没轮到）：第一份包留在 exports/ 里
    clock.advance(60_000);
    const t = await login(s.app, s.username);
    expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(t.token) })).statusCode).toBe(204);
    clock.advance(60_000);
    await req();
    const realList = archive.list.bind(archive);
    let broken = true;
    archive.list = async (p) => {
      if (broken) throw Object.assign(new Error("列举超时"), { code: "RequestTimeout" });
      return realList(p);
    };
    const sink = logSink();
    const [second] = await runExportJobs(deps(clock, { archive, log: sink.log }));
    expect(second?.result).toBe("done");
    expect(sink.lines.find((l) => l.obj.alert === "account_delete_export")?.obj.object_key).toBe(second!.object_key);
    const j = await tdb.kysely.selectFrom("export_jobs").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([j.object_key, j.done_at?.getTime()]).toEqual([second!.object_key, clock.t]);
    expect(archive.objects.has(second!.object_key!)).toBe(true);
    expect(archive.objects.has(first!.object_key!)).toBe(true);
    // 下一轮：只重试清理（不重新生成），删掉旧包、留着新包
    broken = false;
    expect(await runExportJobs(deps(clock, { archive }))).toEqual([]);
    expect(await realList(storePrefix("exports", s.storeId))).toEqual([second!.object_key]);
    await s.app.close();
  });

  it("上传导出包走文件流（putFile），不把整个 ZIP 读进内存；本机目录的 putFile 边读边写、原子改名（PR #20 Codex 5）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "流式上传店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const archive = new MemoryObjectStore();
    const realPut = archive.put.bind(archive);
    archive.put = async (k, b, c) => {
      if (k.startsWith("exports/")) throw new Error("导出包不许整包放进内存上传");
      return realPut(k, b, c);
    };
    const r = (await runExportJobs(deps(clock, { archive }))).find((x) => x.store_id === s.storeId);
    expect(r?.result).toBe("done");
    expect([...readZip(archive.objects.get(r!.object_key!)!.body).keys()]).toEqual([...EXPORT_FILES]);

    const dir = await mkdtemp(path.join(tmpdir(), "yh-putfile-"));
    try {
      const src = path.join(dir, "src.zip");
      const big = Buffer.alloc(3 * 1024 * 1024 + 7, 0x5a);
      await writeFile(src, big);
      const local = new LocalDirObjectStore(path.join(dir, "oss"));
      const key = `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"0".repeat(16)}.zip`;
      await local.putFile(key, src, "application/zip");
      expect((await local.get(key))!.equals(big)).toBe(true);
      expect(await local.list(storePrefix("exports", s.storeId))).toEqual([key]);
      await expect(local.putFile("../x.zip", src, "application/zip")).rejects.toThrow(/对象键/);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
    await s.app.close();
  });

  it("两个进程同时跑导出任务：只生成一份", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "并发导出店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const archive = new MemoryObjectStore();
    const rs = await Promise.all([1, 2, 3].map(() => runExportJobs(deps(clock, { archive }))));
    expect(rs.flat().filter((x) => x.store_id === s.storeId).map((x) => x.result)).toEqual(["done"]);
    expect((await archive.list(storePrefix("exports", s.storeId))).length).toBe(1);
    await s.app.close();
  });

  it("scripts/export-store.ts：命令行导出到文件，格式同注销导出包；文件已存在不覆盖", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "脚本店");
    const dir = await mkdtemp(path.join(tmpdir(), "yh-export-cli-"));
    try {
      const file = path.join(dir, "out.zip");
      const r = await new Promise<{ code: number; stdout: string; stderr: string }>((res) =>
        execFile(process.execPath, [path.resolve(import.meta.dirname, "../scripts/export-store.ts"), "--store", s.storeId, "--out", file], { env: { PATH: process.env.PATH ?? "", DATABASE_URL: tdb.url } }, (err, stdout, stderr) =>
          res({ code: err ? ((err as { code?: number }).code ?? 1) : 0, stdout, stderr }),
        ),
      );
      expect(r.code, r.stderr).toBe(0);
      expect(JSON.parse(r.stdout)).toMatchObject({ out: file, products: 2, months: ["2026-10", "2026-11"] });
      expect([...readZip(await readFile(file)).keys()]).toEqual([...EXPORT_FILES]);
      await expect(exportStoreToFile(tdb.kysely, s.storeId, file)).rejects.toThrow(/EEXIST|exists/);
      await expect(exportStoreToFile(tdb.kysely, "../etc", path.join(dir, "x.zip"))).rejects.toThrow(/店 id/);
      await expect(exportStoreToFile(tdb.kysely, randomUUID(), path.join(dir, "y.zip"))).rejects.toThrow(/不存在/);
      expect(await readdir(dir)).toEqual(["out.zip"]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
    await s.app.close();
  });
});

describe("满 7 天删除", () => {
  /** 给一家店放 OSS 图片、导出包和本机图片缓存 */
  async function plantObjects(d: ReturnType<typeof deps>, storeId: string, productIds: string[]) {
    for (const p of productIds) {
      const k = imageKey(storeId, p, 1, "ab".repeat(32));
      await d.images.put(k, Buffer.from("jpg"), "image/jpeg");
      const f = path.join(cacheRoot, ...k.split("/"));
      await mkdir(path.dirname(f), { recursive: true });
      await writeFile(f, "jpg");
    }
  }

  it("恰好 7 天整不删、7 天内撤回则无事发生；过了 7 天：在线数据清空、删除记录、图片 / 导出包 / 本机缓存删掉，别的店不动", async () => {
    const clock = new TestClock(T0);
    const yh = await shopWithBooks(clock, "要删的店");
    const keep = await shopWithBooks(clock, "留着的店");
    const back = await shopWithBooks(clock, "撤回的店");
    const d = deps(clock);
    await plantObjects(d, yh.storeId, yh.productIds);
    await plantObjects(d, keep.storeId, keep.productIds);
    for (const s of [yh, back]) {
      const t = await login(s.app, s.username);
      expect((await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    }
    await runExportJobs(d);
    expect((await d.archive.list(storePrefix("exports", yh.storeId))).length).toBe(1);
    const keepBefore = await rowCounts(keep.storeId);
    const yhBefore = await rowCounts(yh.storeId);
    expect(yhBefore.entries).toBeGreaterThan(0);

    // 第 6 天撤回
    clock.advance(6 * 86_400_000);
    const bt = await login(back.app, back.username);
    expect((await back.app.inject({ method: "POST", url: "/v1/account/delete-cancel", headers: bearer(bt.token) })).statusCode).toBe(204);
    // 恰好 7 天整：仍可撤回，所以不删
    // 同一个 schema 里前面测试申请注销的店也会到期：结果只看本测试的三家
    const mine = (r: { purged: string[]; cleared: string[] }) => ({
      purged: r.purged.filter((x) => [yh.storeId, keep.storeId, back.storeId].includes(x)),
      cleared: r.cleared.filter((x) => [yh.storeId, keep.storeId, back.storeId].includes(x)),
    });
    clock.t = T0 + DELETE_GRACE_MS;
    expect(mine(await runAccountPurges(d))).toEqual({ purged: [], cleared: [] });
    expect(await rowCounts(yh.storeId)).toEqual(yhBefore);

    clock.advance(1);
    const sink = logSink();
    // 第一遍清掉对象，但要等隔满 1 小时的复扫做完才记清完（T17）
    expect(mine(await runAccountPurges({ ...d, log: sink.log }))).toEqual({ purged: [yh.storeId], cleared: [] });
    const after = await rowCounts(yh.storeId);
    expect(Object.values(after).every((n) => n === 0), JSON.stringify(after)).toBe(true);
    const rec = JSON.parse(d.archive.objects.get(deletionKey(yh.storeId))!.body.toString("utf8"));
    expect(rec).toEqual({ store_id: yh.storeId, purged_at: new Date(T0 + DELETE_GRACE_MS + 1).toISOString() });
    expect(await d.images.list(storePrefix("images", yh.storeId))).toEqual([]);
    expect(await d.archive.list(storePrefix("exports", yh.storeId))).toEqual([]);
    await expect(readdir(path.join(cacheRoot, "images", yh.storeId))).rejects.toThrow(/ENOENT/);
    clock.advance(60 * 60_000);
    expect(mine(await runAccountPurges(d))).toEqual({ purged: [], cleared: [yh.storeId] });
    const purge = await tdb.kysely.selectFrom("store_purges").selectAll().where("store_id", "=", yh.storeId).executeTakeFirstOrThrow();
    expect([purge.purged_at.getTime(), purge.objects_cleared_at?.getTime(), purge.last_error]).toEqual([T0 + DELETE_GRACE_MS + 1, T0 + DELETE_GRACE_MS + 1 + 60 * 60_000, null]);
    // 别的店：库里的行、OSS 图片、本机缓存都还在；撤回的店也在
    expect(await rowCounts(keep.storeId)).toEqual(keepBefore);
    expect((await d.images.list(storePrefix("images", keep.storeId))).length).toBe(2);
    expect((await readdir(path.join(cacheRoot, "images", keep.storeId))).length).toBe(2);
    expect((await rowCounts(back.storeId)).stores).toBe(1);
    // 旧令牌、原密码都不能用了
    expect((await yh.app.inject({ method: "GET", url: "/v1/me", headers: bearer(yh.boss.token) })).statusCode).toBe(401);
    expect((await yh.app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: yh.username, password: PASSWORD, device_id: randomUUID() } })).statusCode).toBe(401);
    // 再跑一次：幂等，什么都不做
    expect(mine(await runAccountPurges(d))).toEqual({ purged: [], cleared: [] });
    for (const s of [yh, keep, back]) await s.app.close();
  });

  it("并发：三轮同时跑只删一次、没有报错；删除和同一家店的同步请求同时到也没有 500", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "并发删除店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const relog = await login(s.app, s.username); // 注销期间还能登录（为了撤回）
    clock.advance(DELETE_GRACE_MS + 60_000);
    const d = deps(clock);
    const sink = logSink();
    const syncs = Array.from({ length: 6 }, (_, i) =>
      s.app.inject({
        method: "POST",
        url: "/v1/sync",
        headers: bearer(relog.token),
        payload: { epoch: s.epoch, cursors: { catalog: 0, ledger: 0 }, ops: i % 2 ? [op("product_edit", { product_id: s.productIds[0], price_fen: 1 })] : [], app_build: 1 },
      }),
    );
    const [r1, r2, r3, ...rs] = await Promise.all([runAccountPurges({ ...d, log: sink.log }), runAccountPurges({ ...d, log: sink.log }), runAccountPurges({ ...d, log: sink.log }), ...syncs]);
    expect([r1, r2, r3].flatMap((r) => r.purged).filter((x) => x === s.storeId)).toEqual([s.storeId]);
    expect(sink.lines.filter((l) => l.level === "error")).toEqual([]);
    for (const r of rs) expect([200, 401], r.body).toContain(r.statusCode);
    expect(Object.values(await rowCounts(s.storeId)).every((n) => n === 0)).toBe(true);
    expect(d.archive.objects.has(deletionKey(s.storeId))).toBe(true);
    await s.app.close();
  });

  it("令牌验过之后店被清除了：拉取、推送都按令牌不认识处理（StoreGone → 401），不是 500", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "验完就删店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    const relog = await login(s.app, s.username);
    const auth = (await authenticate(tdb.kysely, relog.token, clock.now()))!;
    clock.advance(DELETE_GRACE_MS + 1);
    expect(await purgeStore(tdb.kysely, s.storeId, clock.now(), new MemoryObjectStore())).toBe("purged");
    await expect(pullChanges(tdb.kysely, { storeId: s.storeId, deviceId: relog.deviceId, scope: "full_store", cursors: { catalog: 0, ledger: 0 }, pageSize: 10, now: clock.now() })).rejects.toThrow(StoreGone);
    await expect(
      pushOps(tdb.kysely, new Guard(), { auth, ops: [op("product_edit", { product_id: s.productIds[0], price_fen: 1 }) as never], now: clock.now(), epoch: s.epoch, config: { demoLoginEnabled: false, recoveryMode: false } }),
    ).rejects.toThrow(StoreGone);
    await s.app.close();
  });

  it("验密码期间到期清除了这家店：密码登录、改密码、申请注销都回 401，不是 500（Fable 必须改 3）", async () => {
    const real = (await import("../src/auth/password.ts")).verifyPassword;
    const cases = [
      { url: "/v1/auth/login", want: "bad_credentials" },
      { url: "/v1/account/password", want: "unauthorized" },
      { url: "/v1/account/delete-request", want: "unauthorized" },
    ] as const;
    for (const c of cases) {
      const clock = new TestClock(T0);
      const s = await shopWithBooks(clock, `验密码时被删店${c.url}`);
      const t = await login(s.app, s.username);
      await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
      const relog = await login(s.app, s.username); // 注销期间还能登录（为了撤回）
      clock.advance(DELETE_GRACE_MS + 1);
      let first = true;
      // 验密码（argon2，几十毫秒）的时候清除跑完了
      const app = makeApp(tdb, {
        clock,
        verifyPassword: async (hash, pw) => {
          const ok = await real(hash, pw);
          if (first) {
            first = false;
            expect(await purgeStore(tdb.kysely, s.storeId, clock.now(), new MemoryObjectStore())).toBe("purged");
          }
          return ok;
        },
      });
      const r =
        c.url === "/v1/auth/login"
          ? await app.inject({ method: "POST", url: c.url, payload: { username: s.username, password: PASSWORD, device_id: randomUUID() } })
          : await app.inject({ method: "POST", url: c.url, headers: bearer(relog.token), payload: c.url === "/v1/account/password" ? { old: PASSWORD, new: "another-pass-123" } : { password: PASSWORD } });
      expect([r.statusCode, r.body ? r.json().code : null], `${c.url} ${r.body}`).toEqual([401, c.want]);
      expect((await rowCounts(s.storeId)).accounts).toBe(0);
      await s.app.close();
      await app.close();
    }
  });

  it("删除记录先于在线数据删除写好：没配存档桶、写删除记录失败 → 在线数据不删、告警，下一轮写成了才删（PR #20 Codex 1）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "先写记录店");
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    const before = await rowCounts(s.storeId);

    // 没配存档桶：删除记录写不了 → 不删，error 级告警
    const sink = logSink();
    const r0 = await runAccountPurges(deps(clock, { archive: null, log: sink.log }));
    expect(r0.purged).not.toContain(s.storeId);
    expect(await rowCounts(s.storeId)).toEqual(before);
    expect(sink.lines.some((l) => l.level === "error" && l.obj.alert === "purge_no_archive")).toBe(true);
    expect(await tdb.kysely.selectFrom("store_purges").select("store_id").where("store_id", "=", s.storeId).execute()).toEqual([]);

    // 写删除记录失败：同样不删
    const d = deps(clock);
    const put = d.archive.put.bind(d.archive);
    let fail = true;
    d.archive.put = async (k, b, c) => {
      if (fail && k === deletionKey(s.storeId)) throw Object.assign(new Error("写不进去"), { code: "RequestTimeout" });
      return put(k, b, c);
    };
    const err = logSink();
    const r1 = await runAccountPurges({ ...d, log: err.log });
    expect(r1.purged).not.toContain(s.storeId);
    expect(await rowCounts(s.storeId)).toEqual(before);
    expect(d.archive.objects.has(deletionKey(s.storeId))).toBe(false);
    expect(err.lines.some((l) => l.level === "error" && l.obj.store_id === s.storeId && l.obj.code === "RequestTimeout")).toBe(true);

    // 写得进去了：先有删除记录，再删在线数据
    fail = false;
    const r2 = await runAccountPurges(d);
    expect(r2.purged).toContain(s.storeId);
    expect(JSON.parse(d.archive.objects.get(deletionKey(s.storeId))!.body.toString("utf8"))).toEqual({ store_id: s.storeId, purged_at: clock.now().toISOString() });
    expect(Object.values(await rowCounts(s.storeId)).every((n) => n === 0)).toBe(true);
    await s.app.close();
  });

  it("对象清理失败：在线数据照样删了，store_purges 记原因代码；删除记录已写；下一轮接着清完", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "清理失败店");
    const d = deps(clock);
    await plantObjects(d, s.storeId, s.productIds);
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    let broken = true;
    const del = d.images.delete.bind(d.images);
    d.images.delete = async (k) => {
      if (broken) throw Object.assign(new Error("网络断了"), { code: "ECONNRESET" });
      return del(k);
    };
    const r = await runAccountPurges(d);
    expect([r.purged.includes(s.storeId), r.cleared.includes(s.storeId)]).toEqual([true, false]);
    const p = await tdb.kysely.selectFrom("store_purges").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([p.objects_cleared_at, p.last_error, p.attempts]).toEqual([null, "ECONNRESET", 1]);
    expect(d.archive.objects.has(deletionKey(s.storeId))).toBe(true);
    expect((await rowCounts(s.storeId)).stores).toBe(0);
    broken = false;
    clock.advance(60 * 60_000);
    expect(await clearPurgedObjects(d)).toContain(s.storeId);
    expect(await d.images.list(storePrefix("images", s.storeId))).toEqual([]);
    await s.app.close();
  });

  it("清除之后才落地的图片、导出包（T17）：清除后马上做的对象清理不算清完；隔满 1 小时按前缀复扫一遍删掉才记 objects_cleared_at；复扫失败下一轮重试；两个进程同时复扫只记一次", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "迟到对象店");
    const d = deps(clock);
    await plantObjects(d, s.storeId, s.productIds);
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    const purgedAt = clock.t;
    const r0 = await runAccountPurges(d);
    // 第一遍照样删（已有的对象马上就没了），但还不算清完
    expect([r0.purged.includes(s.storeId), r0.cleared.includes(s.storeId)]).toEqual([true, false]);
    expect(await d.images.list(storePrefix("images", s.storeId))).toEqual([]);
    const cleared = async () => (await tdb.kysely.selectFrom("store_purges").select("objects_cleared_at").where("store_id", "=", s.storeId).executeTakeFirstOrThrow()).objects_cleared_at;
    expect(await cleared()).toBeNull();
    // 清除之后才落地：在途的图片上传（上传报错、拿锁失败都没删成）、迟到的导出包、本机缓存回填
    const lateImage = imageKey(s.storeId, s.productIds[0]!, 1, "cd".repeat(32));
    const lateExport = `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"e".repeat(16)}.zip`;
    const plantLate = async () => {
      await d.images.put(lateImage, Buffer.from("jpg"), "image/jpeg");
      await d.archive.put(lateExport, Buffer.from("zip"), "application/zip");
      const f = path.join(cacheRoot, ...lateImage.split("/"));
      await mkdir(path.dirname(f), { recursive: true });
      await writeFile(f, "jpg");
    };
    await plantLate();
    // 不到 1 小时：不复扫、不记完成
    clock.t = purgedAt + 59 * 60_000;
    expect((await runAccountPurges(d)).cleared).not.toContain(s.storeId);
    expect(await cleared()).toBeNull();
    // 满 1 小时，复扫失败：不记完成，下一轮重试
    clock.t = purgedAt + 60 * 60_000;
    let broken = true;
    const del = d.archive.delete.bind(d.archive);
    d.archive.delete = async (k) => {
      if (broken) throw Object.assign(new Error("网络断了"), { code: "ECONNRESET" });
      return del(k);
    };
    expect((await runAccountPurges(d)).cleared).not.toContain(s.storeId);
    expect(await cleared()).toBeNull();
    broken = false;
    // 两个进程同时复扫：都不报错，只有一个记完成
    const both = await Promise.all([clearPurgedObjects(d), clearPurgedObjects(d)]);
    expect(both.flat().filter((x) => x === s.storeId)).toEqual([s.storeId]);
    expect((await cleared())?.getTime()).toBe(purgedAt + 60 * 60_000);
    expect(await d.images.list(storePrefix("images", s.storeId))).toEqual([]);
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([]);
    await expect(readdir(path.join(cacheRoot, "images", s.storeId))).rejects.toThrow(/ENOENT/);
    expect(d.archive.objects.has(deletionKey(s.storeId))).toBe(true);
    // 记完成之后再跑：幂等，什么都不做
    expect((await runAccountPurges(d)).cleared).not.toContain(s.storeId);
    await s.app.close();
  });

  it("清除本身拖过 1 小时（前面的店耗时、等锁）：满 1 小时从这家店实际清除完成时起算，清完马上跑的对象清理不算清完（PR #20 Codex 第三轮 1）", async () => {
    const clock = new TestClock(T0);
    const a = await shopWithBooks(clock, "慢清除店甲");
    const b = await shopWithBooks(clock, "慢清除店乙");
    const d = deps(clock);
    for (const s of [a, b]) {
      const t = await login(s.app, s.username);
      await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    }
    clock.advance(DELETE_GRACE_MS + 1);
    const roundStart = clock.t;
    // 这一轮里先清的那家店（写删除记录、删在线数据）用掉 61 分钟，后一家店才开始清
    const put = d.archive.put.bind(d.archive);
    let slowed = false;
    d.archive.put = async (k, body, type) => {
      if (!slowed && (k === deletionKey(a.storeId) || k === deletionKey(b.storeId))) {
        slowed = true;
        clock.advance(61 * 60_000);
      }
      return put(k, body, type);
    };
    const r0 = await runAccountPurges(d);
    expect([a, b].map((s) => r0.purged.includes(s.storeId))).toEqual([true, true]);
    // 清完马上做的那一遍：两家都不能记清完
    expect([a, b].map((s) => r0.cleared.includes(s.storeId))).toEqual([false, false]);
    const rows = await tdb.kysely.selectFrom("store_purges").select(["store_id", "purged_at", "objects_cleared_at"]).where("store_id", "in", [a.storeId, b.storeId]).execute();
    for (const row of rows) {
      expect(row.objects_cleared_at).toBeNull();
      expect(row.purged_at.getTime()).toBeGreaterThanOrEqual(roundStart + 61 * 60_000);
    }
    // 清除之后才落地的包：要等复扫删掉
    const late = `exports/${b.storeId}/${String(T0).padStart(13, "0")}-${"f".repeat(16)}.zip`;
    await d.archive.put(late, Buffer.from("zip"), "application/zip");
    clock.advance(59 * 60_000);
    expect((await clearPurgedObjects(d)).filter((x) => x === a.storeId || x === b.storeId)).toEqual([]);
    expect(d.archive.objects.has(late)).toBe(true);
    clock.advance(60_000);
    expect((await clearPurgedObjects(d)).filter((x) => x === a.storeId || x === b.storeId).sort()).toEqual([a.storeId, b.storeId].sort());
    expect(d.archive.objects.has(late)).toBe(false);
    for (const s of [a, b]) await s.app.close();
  });

  it("复扫同时中止这家店前缀下未完成的分片上传（images/、exports/），别的店的不动（PR #20 Codex 第二轮 3、T17）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "残片清除店");
    const other = randomUUID();
    const d = deps(clock);
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    expect((await runAccountPurges(d)).purged).toContain(s.storeId);
    d.images.uploads.set("img-1", imageKey(s.storeId, s.productIds[0]!, 1, "ab".repeat(32)));
    d.archive.uploads.set("exp-1", `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"a".repeat(16)}.zip`);
    d.archive.uploads.set("exp-other", `exports/${other}/${String(T0).padStart(13, "0")}-${"b".repeat(16)}.zip`);
    // 中止失败：不记清完，下一轮重试
    const realAbort = d.archive.abortUpload.bind(d.archive);
    let broken = true;
    d.archive.abortUpload = async (k, id) => {
      if (broken) throw Object.assign(new Error("中止失败"), { code: "RequestTimeout" });
      return realAbort(k, id);
    };
    clock.advance(60 * 60_000);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    broken = false;
    expect(await clearPurgedObjects(d)).toContain(s.storeId);
    expect([...d.images.uploads.keys()]).toEqual([]);
    expect([...d.archive.uploads.keys()]).toEqual(["exp-other"]);
    await s.app.close();
  });

  it("复扫时分片上传恰好完成（列举对象和列举分片上传之间落地）：不会两边都漏掉还记清完（PR #20 Codex 第三轮 2）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "恰好传完店");
    const d = deps(clock);
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    expect((await runAccountPurges(d)).purged).toContain(s.storeId);
    // 一个在途的导出包分片上传，和一个在途的商品图分片上传
    const exp = `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"c".repeat(16)}.zip`;
    const img = imageKey(s.storeId, s.productIds[0]!, 1, "ef".repeat(32));
    d.archive.uploads.set("exp-late", exp);
    d.images.uploads.set("img-late", img);
    // 复扫列举分片上传的那一刻，两个上传都恰好完成：分片记录没了，对象落地
    for (const [store, id, key] of [[d.archive, "exp-late", exp], [d.images, "img-late", img]] as const) {
      const listUploads = store.listUploads.bind(store);
      let done = false;
      store.listUploads = async (prefix) => {
        if (!done && key.startsWith(prefix)) {
          done = true;
          store.uploads.delete(id);
          await store.put(key, Buffer.from("x"), "application/octet-stream");
        }
        return listUploads(prefix);
      };
    }
    clock.advance(60 * 60_000);
    const cleared = await clearPurgedObjects(d);
    // 记了清完，就不能留着刚落地的对象；留着就不能记清完
    if (cleared.includes(s.storeId)) {
      expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([]);
      expect(await d.images.list(storePrefix("images", s.storeId))).toEqual([]);
    }
    expect(cleared).toContain(s.storeId);
    expect([...d.archive.uploads.keys(), ...d.images.uploads.keys()]).toEqual([]);
    await s.app.close();
  });

  it("复扫时对象一直冒出来（来回 3 次还不干净）：这一遍不记清完、记原因，下一轮重来（PR #20 Codex 第三轮 2）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "一直冒对象店");
    const d = deps(clock);
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    expect((await runAccountPurges(d)).purged).toContain(s.storeId);
    const listUploads = d.archive.listUploads.bind(d.archive);
    let n = 0;
    let noisy = true;
    d.archive.listUploads = async (prefix) => {
      if (noisy && prefix === storePrefix("exports", s.storeId)) d.archive.uploads.set(`u-${n++}`, `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"d".repeat(16)}.zip`);
      return listUploads(prefix);
    };
    clock.advance(60 * 60_000);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    const p = await tdb.kysely.selectFrom("store_purges").select(["objects_cleared_at", "last_error"]).where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    expect([p.objects_cleared_at, p.last_error]).toEqual([null, "sweep_not_quiet"]);
    expect(n).toBe(3);
    noisy = false;
    expect(await clearPurgedObjects(d)).toContain(s.storeId);
    await s.app.close();
  });

  it("商品图桶不存在（NoSuchBucket）：不挡这家店 exports/ 和本机缓存的删除；照样不记清完（不跳过）；连续失败第 3 次起打 alert=purge_objects_failed 并退避，不每轮重试；清完后次数清零（PR #27 Fable S10r-7、S10r-11）", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "没有图片桶店");
    const sink = logSink();
    const d = { ...deps(clock), log: sink.log };
    await plantObjects(d, s.storeId, s.productIds);
    const exp = `exports/${s.storeId}/${String(T0).padStart(13, "0")}-${"9".repeat(16)}.zip`;
    await d.archive.put(exp, Buffer.from("zip"), "application/zip");
    const noBucket = async (): Promise<never> => {
      throw Object.assign(new Error("The specified bucket does not exist."), { code: "NoSuchBucket" });
    };
    d.images.list = noBucket;
    d.images.listUploads = noBucket;
    const t = await login(s.app, s.username);
    await s.app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(t.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 1);
    const row = async () => tdb.kysely.selectFrom("store_purges").selectAll().where("store_id", "=", s.storeId).executeTakeFirstOrThrow();
    const alerts = () => sink.lines.filter((l) => l.obj.alert === "purge_objects_failed");
    // 第 1 次（清除时）：导出包、本机缓存照样删掉；不记清完
    expect((await runAccountPurges(d)).purged).toContain(s.storeId);
    expect(await d.archive.list(storePrefix("exports", s.storeId))).toEqual([]);
    await expect(readdir(path.join(cacheRoot, "images", s.storeId))).rejects.toThrow(/ENOENT/);
    expect([(await row()).objects_cleared_at, (await row()).last_error, (await row()).attempts]).toEqual([null, "NoSuchBucket", 1]);
    expect(alerts()).toEqual([]);
    // 第 2、3 次（满 1 小时后的每一轮）：第 3 次打告警
    clock.advance(60 * 60_000);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    expect(alerts()).toEqual([]);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    expect((await row()).attempts).toBe(3);
    expect(alerts().map((l) => [l.level, l.obj.store_id, l.obj.code, l.obj.attempts])).toEqual([["error", s.storeId, "NoSuchBucket", 3]]);
    // 退避：马上再跑不重试（次数不涨、不再告警）；过了退避时间才重试
    const next = (await row()).next_try_at!;
    const firstGap = next.getTime() - clock.t;
    expect(firstGap).toBeGreaterThan(0);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    expect((await row()).attempts).toBe(3);
    clock.t = next.getTime();
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    expect((await row()).attempts).toBe(4);
    expect((await row()).next_try_at!.getTime() - clock.t).toBeGreaterThan(firstGap); // 退避一次比一次长
    expect(alerts()).toHaveLength(2);
    // 桶建好以后：下一次到点的重试清完，退避清掉
    const fresh = new MemoryObjectStore();
    clock.t = (await row()).next_try_at!.getTime();
    expect(await clearPurgedObjects({ ...d, images: fresh })).toContain(s.storeId);
    const done = await row();
    expect([done.objects_cleared_at?.getTime(), done.last_error, done.next_try_at, done.attempts]).toEqual([clock.t, null, null, 0]);
    // 成功后次数清零（PR #27 Fable 第二轮建议 2）：之后迟到对象撤回 objects_cleared_at、再失败一次，算第 1 次，不告警、不退避
    await tdb.kysely.updateTable("store_purges").set({ objects_cleared_at: null }).where("store_id", "=", s.storeId).execute();
    clock.advance(60_000);
    expect(await clearPurgedObjects(d)).not.toContain(s.storeId);
    expect([(await row()).attempts, (await row()).next_try_at]).toEqual([1, null]);
    expect(alerts()).toHaveLength(2);
    await s.app.close();
  });

  it("演示店的审核号申请注销满 7 天也不删（每日重置会撤回）", async () => {
    const clock = new TestClock(T0);
    const demo = await makeLoginShop(tdb, { demo: true });
    const app = makeApp(tdb, { clock });
    const rv = await login(app, demo.username);
    await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(rv.token), payload: { password: PASSWORD } });
    clock.advance(DELETE_GRACE_MS + 86_400_000);
    const r = await runAccountPurges(deps(clock));
    expect(r.purged).not.toContain(demo.storeId);
    expect((await rowCounts(demo.storeId)).stores).toBe(1);
    await app.close();
  });
});
