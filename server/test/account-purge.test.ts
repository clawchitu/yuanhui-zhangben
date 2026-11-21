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
import { MemoryObjectStore, deletionKey, imageKey, storePrefix } from "../src/lookup/oss.ts";
import { clearPurgedObjects, runAccountPurges, runExportJobs, type AccountJobDeps } from "../src/jobs/account-purge.ts";
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

  it("分页导出（每页 1、2、3 行）与一次导完逐字节相同", async () => {
    const clock = new TestClock(T0);
    const s = await shopWithBooks(clock, "分页店");
    const full = await zipOf(s.storeId, clock.now());
    for (const n of [1, 2, 3]) expect((await zipOf(s.storeId, clock.now(), n)).equals(full), `pageSize ${n}`).toBe(true);
    await s.app.close();
  });

  it("大数据量：3000 条流水按 250 行一页导出，行数、序号、合计都对", async () => {
    const clock = new TestClock(T0);
    const shop = await makeLoginShop(tdb, { name: "大店" });
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    const pid = randomUUID();
    const code = newBarcode();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [upsertFull({ productId: pid, barcode: code, price: 100 }), op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 100000, unit_cost_fen: 50 }, { at: "2026-11-01T00:00:00Z" })] });
    for (let k = 0; k < 15; k++) {
      const ops = Array.from({ length: 200 }, (_, i) =>
        op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 100, lines: [{ entry_id: randomUUID(), product_id: pid, barcode: code, name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 100 }] }, {
          at: new Date(Date.parse("2026-11-05T00:00:00Z") + (k * 200 + i) * 60_000),
        }),
      );
      await syncOk(app, boss.token, { epoch: shop.epoch, ops });
    }
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
    const put = flaky.put.bind(flaky);
    flaky.put = async (k, b, c) => {
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
    expect(mine(await runAccountPurges({ ...d, log: sink.log }))).toEqual({ purged: [yh.storeId], cleared: [yh.storeId] });
    const after = await rowCounts(yh.storeId);
    expect(Object.values(after).every((n) => n === 0), JSON.stringify(after)).toBe(true);
    const rec = JSON.parse(d.archive.objects.get(deletionKey(yh.storeId))!.body.toString("utf8"));
    expect(rec).toEqual({ store_id: yh.storeId, purged_at: new Date(T0 + DELETE_GRACE_MS + 1).toISOString() });
    expect(await d.images.list(storePrefix("images", yh.storeId))).toEqual([]);
    expect(await d.archive.list(storePrefix("exports", yh.storeId))).toEqual([]);
    await expect(readdir(path.join(cacheRoot, "images", yh.storeId))).rejects.toThrow(/ENOENT/);
    const purge = await tdb.kysely.selectFrom("store_purges").selectAll().where("store_id", "=", yh.storeId).executeTakeFirstOrThrow();
    expect([purge.purged_at.getTime(), purge.objects_cleared_at?.getTime(), purge.last_error]).toEqual([T0 + DELETE_GRACE_MS + 1, T0 + DELETE_GRACE_MS + 1, null]);
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
    const syncs = Array.from({ length: 4 }, () =>
      s.app.inject({ method: "POST", url: "/v1/sync", headers: bearer(relog.token), payload: { epoch: s.epoch, cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1 } }),
    );
    const [r1, r2, r3, ...rs] = await Promise.all([runAccountPurges({ ...d, log: sink.log }), runAccountPurges({ ...d, log: sink.log }), runAccountPurges({ ...d, log: sink.log }), ...syncs]);
    expect([r1, r2, r3].flatMap((r) => r.purged).filter((x) => x === s.storeId)).toEqual([s.storeId]);
    expect(sink.lines.filter((l) => l.level === "error")).toEqual([]);
    for (const r of rs) expect([200, 401]).toContain(r.statusCode);
    expect(Object.values(await rowCounts(s.storeId)).every((n) => n === 0)).toBe(true);
    expect(d.archive.objects.has(deletionKey(s.storeId))).toBe(true);
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
    expect(await clearPurgedObjects(d)).toContain(s.storeId);
    expect(await d.images.list(storePrefix("images", s.storeId))).toEqual([]);
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
