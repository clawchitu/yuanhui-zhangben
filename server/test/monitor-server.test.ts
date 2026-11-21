// S10c 服务器内的检查任务（连真实 Postgres）：日志里的告警（登录锁定、注销申请、T16）、5xx、快鸟单店 200 次、
// 营业时间无同步、被退出手机的暂存账、ops 表、磁盘、备份（心跳、失败、连续失败、跳过、生命周期、门禁跳过、恢复失败）。
import { mkdtempSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import { createDb } from "../src/db.ts";
import { Alerter } from "../src/monitor/alerter.ts";
import { LogTap } from "../src/monitor/logtap.ts";
import { ServerMonitor, SyncSeen, type ServerMonitorDeps } from "../src/monitor/server-monitor.ts";
import { defaultTasks } from "../src/jobs/scheduler.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeLoginShop, PASSWORD, TestClock } from "./helpers/auth.ts";
import { syncOk } from "./helpers/sync.ts";
import { FakeSink } from "./helpers/monitor.ts";

const H = 3600_000;
const sh = (iso: string) => Date.parse(`${iso}+08:00`);

describe("服务器监控", () => {
  let tdb: TestDb;
  beforeAll(async () => {
    tdb = await createTestDb();
  });
  afterAll(() => tdb.drop());

  function rig(o: Partial<ServerMonitorDeps> & { clock?: TestClock } = {}) {
    const clock = o.clock ?? new TestClock(sh("2026-11-20T10:00:00"));
    const sink = new FakeSink();
    const alerter = new Alerter({ sink, clock: clock.now });
    const tap = new LogTap(clock.now);
    const syncSeen = new SyncSeen();
    let usage: Array<{ storeId: string; used: number }> = [];
    const mon = new ServerMonitor({
      db: tdb.kysely,
      alerter,
      tap,
      syncSeen,
      quotaUsage: () => usage,
      startedAt: clock.now(),
      backupDir: "",
      diskPath: "",
      ...o,
    });
    return { clock, sink, alerter, tap, syncSeen, mon, setUsage: (u: typeof usage) => (usage = u), run: () => mon.run(clock.now()) };
  }

  it("登录锁定、注销申请经日志转成告警（只在刚锁上、新申请时各一条），内容不含口令和令牌", async () => {
    const shop = await makeLoginShop(tdb);
    const clock = new TestClock(sh("2026-11-20T10:00:00"));
    const r = rig({ clock });
    const app = buildApp({ config: testConfig(), db: tdb, clock: clock.now, logStream: { write: (l) => r.tap.line(l) } });
    for (let i = 0; i < 6; i++) {
      await app.inject({ method: "POST", url: "/v1/auth/login", payload: { username: shop.username, password: `wrong-${i}`, device_id: randomUUID() } });
    }
    clock.advance(16 * 60_000); // 锁 15 分钟
    const boss = await login(app, shop.username);
    for (let i = 0; i < 2; i++) await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } });
    await app.close();
    await r.run();
    const kinds = r.sink.kinds().filter((k) => !k.includes("no_sync") && !k.includes("ops_"));
    expect(kinds).toEqual([`event:login_locked:${shop.storeId}`, `event:account_delete_request:${shop.storeId}`]);
    const all = JSON.stringify(r.sink.sent);
    expect(all).not.toContain(PASSWORD);
    expect(all).not.toContain(boss.token);
    expect(r.sink.sent[1]!.details.reason).toContain("exports/");
  });

  it("5xx 一小时超过 20 次告警，窗口过去后恢复（从 Fastify 的 request completed 日志里数）", async () => {
    const clock = new TestClock(sh("2026-11-20T10:00:00"));
    const r = rig({ clock });
    const bad = createDb({ connectionString: "postgres://nobody@127.0.0.1:1/none", connectionTimeoutMillis: 300 });
    const app = buildApp({ config: testConfig(), db: bad, clock: clock.now, logStream: { write: (l) => r.tap.line(l) } });
    for (let i = 0; i < 20; i++) expect((await app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(503);
    // pino 的 time 是真实时钟：窗口按 r.clock 判断，把时钟对齐到现在
    clock.t = Date.now();
    await r.run();
    expect(r.alerter.firing("http_5xx_rate")).toBe(false);
    await app.inject({ method: "GET", url: "/healthz" });
    await r.run();
    expect(r.alerter.firing("http_5xx_rate")).toBe(true);
    clock.advance(H + 1000);
    await r.run();
    expect(r.sink.kinds().filter((k) => k.endsWith("http_5xx_rate"))).toEqual(["fire:http_5xx_rate", "resolved:http_5xx_rate"]);
    await app.close();
    await bad.close();
  });

  it("快鸟：单店当天到 200 次告警（S08-3 条件二），199 次不报；过零点清零后恢复；接的是 app.catalog.quota", async () => {
    const r = rig();
    r.setUsage([{ storeId: "s1", used: 199 }]);
    await r.run();
    expect(r.alerter.firing("kuainiao_store_daily:s1")).toBe(false);
    r.setUsage([{ storeId: "s1", used: 200 }, { storeId: "s2", used: 3 }]);
    await r.run();
    expect(r.alerter.firing("kuainiao_store_daily:s1")).toBe(true);
    r.setUsage([]);
    await r.run();
    expect(r.sink.kinds().filter((k) => k.includes("kuainiao"))).toEqual(["fire:kuainiao_store_daily:s1", "resolved:kuainiao_store_daily:s1"]);
    // 真实的 DailyQuota.usage：按上海日期分
    const app = buildApp({ config: testConfig({ barcodeDailyLimit: 300 }), db: tdb, logger: false });
    const now = new Date(sh("2026-11-20T23:59:00"));
    for (let i = 0; i < 3; i++) app.catalog.quota.take("s9", now);
    expect(app.catalog.quota.usage(now)).toEqual([{ storeId: "s9", used: 3 }]);
    expect(app.catalog.quota.usage(new Date(sh("2026-11-21T00:00:01")))).toEqual([]);
    await app.close();
  });

  it("快鸟网关报额度用完（quota 类）的日志带 alert=kuainiao_quota", async () => {
    const shop = await makeLoginShop(tdb);
    const r = rig();
    const { SourceError } = await import("../src/lookup/kuainiao.ts");
    const app = buildApp({
      config: testConfig({ barcodeDailyLimit: 300 }),
      db: tdb,
      logStream: { write: (l) => r.tap.line(l) },
      barcodeSource: { name: "kuainiao", lookup: async () => Promise.reject(new SourceError("http", "快鸟 HTTP 403（quota）")) },
    });
    const boss = await login(app, shop.username);
    await app.inject({ method: "GET", url: "/v1/barcode-lookup/6901234567892", headers: bearer(boss.token) });
    await app.close();
    expect(r.tap.drain().events.map((e) => e.key)).toContain("kuainiao_quota");
  });

  it("营业时间无同步：3 小时没有同步成功告警，同步一次（真实 /v1/sync）就恢复；演示店不报", async () => {
    const shop = await makeLoginShop(tdb, { name: "无同步测试店" });
    await makeLoginShop(tdb, { demo: true });
    const clock = new TestClock(sh("2026-11-20T08:00:00"));
    const r = rig({ clock });
    const app = buildApp({ config: testConfig(), db: tdb, logger: false, clock: clock.now });
    app.syncSeen.ok = (id, at) => r.syncSeen.ok(id, at); // 让 app 的同步记录进这个监控
    const boss = await login(app, shop.username);
    clock.advance(3 * H);
    await r.run();
    expect(r.alerter.firing(`no_sync:${shop.storeId}`)).toBe(false);
    clock.advance(60_000);
    await r.run();
    expect(r.alerter.firing(`no_sync:${shop.storeId}`)).toBe(true);
    const demoKeys = Object.keys(r.alerter.state.conditions).filter((k) => k.startsWith("no_sync:") && k !== `no_sync:${shop.storeId}`);
    await syncOk(app, boss.token, { epoch: shop.epoch });
    await r.run();
    expect(r.alerter.firing(`no_sync:${shop.storeId}`)).toBe(false);
    expect(r.sink.kinds()).toContain(`resolved:no_sync:${shop.storeId}`);
    // 别的测试建的店也可能在报，但演示店一定不在
    const demo = await tdb.kysely.selectFrom("stores").select("id").where("is_demo", "=", true).execute();
    for (const d of demo) expect(demoKeys).not.toContain(`no_sync:${d.id}`);
    await app.close();
  });

  it("营业时间无同步：21:00 打烊、次日 8:00–11:00 不算恢复，没真的同步过就一直在告警；同步一次才发「已恢复」（PR #25 Fable 建议 7）", async () => {
    const shop = await makeLoginShop(tdb, { name: "无同步打烊测试店" });
    const clock = new TestClock(sh("2026-11-20T08:00:00"));
    const r = rig({ clock });
    const app = buildApp({ config: testConfig(), db: tdb, logger: false, clock: clock.now });
    await login(app, shop.username); // 有在用的设备才在监控范围
    await app.close();
    const key = `no_sync:${shop.storeId}`;
    clock.advance(3 * H + 60_000);
    await r.run();
    expect(r.alerter.firing(key)).toBe(true);
    for (const t of ["2026-11-20T21:00:00", "2026-11-21T03:00:00", "2026-11-21T08:30:00", "2026-11-21T10:59:00"]) {
      clock.t = sh(t);
      await r.run();
      expect(r.alerter.firing(key), t).toBe(true);
    }
    expect(r.sink.kinds()).not.toContain(`resolved:${key}`);
    clock.t = sh("2026-11-21T11:00:01");
    await r.run();
    expect(r.sink.kinds().filter((k) => k.endsWith(key))).toEqual([`fire:${key}`, `repeat:${key}`]);
    r.syncSeen.ok(shop.storeId, clock.now());
    clock.advance(60_000);
    await r.run();
    expect(r.alerter.firing(key)).toBe(false);
    expect(r.sink.kinds()).toContain(`resolved:${key}`);
  });
  it("被退出手机暂存的账超过 24 小时没处理告警，处理后恢复", async () => {
    const shop = await makeLoginShop(tdb);
    const app = buildApp({ config: testConfig(), db: tdb, logger: false });
    const boss = await login(app, shop.username);
    await app.close();
    const r = rig();
    const now = r.clock.now();
    const id = randomUUID();
    await tdb.kysely
      .insertInto("ops")
      .values({ id, store_id: shop.storeId, device_id: boss.deviceId, type: "stock_in", payload: "{}", payload_hash: "h", occurred_at: new Date(now.getTime() - 26 * H), received_at: new Date(now.getTime() - 24 * H + 60_000), status: "held", result: '{"status":"held"}' })
      .execute();
    await r.run();
    expect(r.alerter.firing(`held_ops:${shop.storeId}`)).toBe(false);
    r.clock.advance(2 * 60_000);
    await r.run();
    expect(r.alerter.firing(`held_ops:${shop.storeId}`)).toBe(true);
    await tdb.kysely.updateTable("ops").set({ status: "rejected", reject_code: "discarded", resolved_at: now, resolved_by_device: boss.deviceId }).where("id", "=", id).execute();
    await r.run();
    expect(r.sink.kinds()).toContain(`resolved:held_ops:${shop.storeId}`);
  });

  it("ops 表体积和 24 小时增长、磁盘用量（T3）", async () => {
    let free = 50;
    const r = rig({ diskPath: "/data", statfs: async () => ({ blocks: 100, bfree: free, bavail: free }), limits: { opsTableBytes: 1, opsGrowthBytesPerDay: 1 } });
    await r.run();
    expect(r.alerter.firing("ops_table_size")).toBe(true);
    expect(r.alerter.firing("ops_table_growth")).toBe(false); // 还没有 24 小时前的样本
    expect(r.alerter.firing("disk_usage")).toBe(false);
    free = 19;
    r.clock.advance(24 * H);
    const shop = await makeLoginShop(tdb);
    const app = buildApp({ config: testConfig(), db: tdb, logger: false });
    const boss = await login(app, shop.username);
    await app.close();
    for (let i = 0; i < 50; i++)
      await tdb.kysely.insertInto("ops").values({ id: randomUUID(), store_id: shop.storeId, device_id: boss.deviceId, type: "stock_in", payload: JSON.stringify({ pad: "x".repeat(4000) + i }), payload_hash: "h", occurred_at: new Date(), status: "applied", result: "{}" }).execute();
    await r.run();
    expect(r.alerter.firing("ops_table_growth")).toBe(true);
    expect(r.alerter.firing("disk_usage")).toBe(true);
    expect(r.sink.sent.find((m) => m.key === "disk_usage")!.details.used_percent).toBe("81");
  });

  it("备份（T26）：心跳超时、失败、连续失败、生命周期没生效、被跳过、门禁跳过、恢复失败；恢复正常后发恢复", async () => {
    const dir = mkdtempSync(join(tmpdir(), "yh-bk-"));
    const clock = new TestClock(sh("2026-11-20T10:00:00"));
    const r = rig({ clock, backupDir: dir });
    const nowS = () => Math.floor(clock.t / 1000);
    // 一次备份都没有
    await r.run();
    expect(r.alerter.firing("backup_heartbeat_stale")).toBe(true);
    const metrics = (o: Record<string, number>) =>
      writeFileSync(join(dir, "metrics.prom"), "# 注释\n" + Object.entries(o).map(([k, v]) => `yuanhui_backup_${k} ${v}`).join("\n") + "\n");
    metrics({ last_success_timestamp_seconds: nowS() - 3 * 3600, last_ok: 0, consecutive_failures: 1, last_skip_timestamp_seconds: 0, lifecycle_stale: 0 });
    await r.run();
    expect(r.alerter.firing("backup_failed")).toBe(true);
    expect(r.alerter.firing("backup_consecutive_failures")).toBe(false);
    metrics({ last_success_timestamp_seconds: nowS() - 3 * 3600, last_ok: 0, consecutive_failures: 2, last_skip_timestamp_seconds: nowS() - 60, lifecycle_stale: 1 });
    writeFileSync(join(dir, "gate-skips.log"), "2026-11-20T02:00:00Z tag=abc1234 跳过备份门禁：没有任何成功的备份记录\n");
    writeFileSync(join(dir, "restore-events.log"), JSON.stringify({ at: "x", event: "restore_failed", alert: "restore_failed", stage: "pg_restore" }) + "\n");
    await r.run();
    await r.run(); // 同样的文件再看一遍：不重复
    const k = r.sink.kinds();
    for (const want of ["fire:backup_heartbeat_stale", "fire:backup_failed", "fire:backup_consecutive_failures", "fire:backup_lifecycle_stale", "event:backup_skipped", "event:backup_gate_skipped", "event:restore_failed"]) {
      expect(k.filter((x) => x === want), want).toHaveLength(1);
    }
    expect(r.sink.sent.find((m) => m.key === "restore_failed")!.details.stage).toBe("pg_restore");
    // 门禁又跳过一次：新行再发（静默期过后）
    clock.advance(31 * 60_000);
    appendFileSync(join(dir, "gate-skips.log"), "2026-11-20T03:00:00Z tag=def5678 跳过备份门禁：x\n");
    metrics({ last_success_timestamp_seconds: nowS(), last_ok: 1, consecutive_failures: 0, last_skip_timestamp_seconds: nowS() - 31 * 60 - 60, lifecycle_stale: 0 });
    await r.run();
    const k2 = r.sink.kinds();
    expect(k2.filter((x) => x === "event:backup_gate_skipped")).toHaveLength(2);
    expect(k2.filter((x) => x === "event:backup_skipped")).toHaveLength(1);
    for (const key of ["backup_heartbeat_stale", "backup_failed", "backup_consecutive_failures", "backup_lifecycle_stale"]) expect(k2).toContain(`resolved:${key}`);
  });

  it("一段检查出错不连累后面几段：出错段报 monitor_check_error，后面的备份检查照跑；好了发恢复（PR #25 Fable 建议 3）", async () => {
    let broken = true;
    const backupDir = mkdtempSync(join(tmpdir(), "yh-monbk-"));
    const r = rig({
      backupDir,
      quotaUsage: () => {
        if (broken) throw new Error("quota 坏了");
        return [];
      },
    });
    await expect(r.run()).rejects.toThrow("quota 坏了");
    expect(r.alerter.firing("monitor_check_error:quota")).toBe(true);
    expect(r.alerter.firing("monitor_check_error:db")).toBe(false);
    expect(r.alerter.firing("backup_heartbeat_stale")).toBe(true); // quota 后面的备份段照样跑了（目录里没有成功记录）
    broken = false;
    await r.run();
    expect(r.sink.kinds()).toContain("resolved:monitor_check_error:quota");
  });
  it("scheduler：配了监控才登记 monitor 任务，每分钟一次", () => {
    const base = { db: tdb.kysely, clock: () => new Date(), productImagesEnabled: false, images: null, archive: null, imageCacheDir: "/tmp" };
    expect(defaultTasks(base).map((t) => t.name)).not.toContain("monitor");
    const t = defaultTasks({ ...base, monitor: { run: async () => {} } }).find((x) => x.name === "monitor");
    expect(t?.everyMs).toBe(60_000);
  });

  it("logTap：生产路径（不给 logStream）每行日志照常写 stdout，同时交给监控", async () => {
    const lines: string[] = [];
    const app = buildApp({ config: testConfig({ logLevel: "info" }), db: tdb, logTap: (l) => lines.push(l) });
    await app.inject({ method: "GET", url: "/healthz" });
    await app.close();
    expect(lines.some((l) => JSON.parse(l).msg === "request completed")).toBe(true);
  });
});
