// 服务器内的检查任务（S10c，§9.5）。scheduler 每分钟跑一次 run()：
//   日志转来的事件（T16、登录锁定、注销申请、快鸟额度报错）、5xx 一小时窗口、快鸟单店当天 200 次（S08-3 条件二）、
//   元辉店营业时间无同步、被退出手机的暂存账超过 24 小时、ops 表体积和增长、磁盘用量（T3）、
//   备份：心跳、失败、连续失败、被跳过（锁）、生命周期没生效、gate-skips.log 新行、restore-events.log 里的 restore_failed（T26）。
// 不在这里的：服务存活和 IP 证书（本机探测 scripts/probe.ts，api 挂了这里也挂了）；CPU、内存、磁盘 80%（阿里云云监控，runbook）。
import { statfs } from "node:fs/promises";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import type { Alerter } from "./alerter.ts";
import type { LogTap } from "./logtap.ts";
import { heartbeatVerdict, noSyncVerdict, parseMetrics, readNewLines, THRESHOLDS } from "./checks.ts";

/** 每家店最近一次同步成功（sync 路由回 200 时记；内存里，重启后从启动时刻重新算 3 小时） */
export class SyncSeen {
  private readonly m = new Map<string, Date>();
  ok(storeId: string, at: Date): void {
    this.m.set(storeId, at);
  }
  get(storeId: string): Date | undefined {
    return this.m.get(storeId);
  }
}

export interface ServerMonitorDeps {
  db: Kysely<Database>;
  alerter: Alerter;
  tap: LogTap;
  syncSeen: SyncSeen;
  /** 快鸟当天各店用量（CatalogService.quota.usage） */
  quotaUsage: (now: Date) => Array<{ storeId: string; used: number }>;
  /** 进程启动时刻：没同步记录的店从这里起算 */
  startedAt: Date;
  /** ECS 上的 /opt/yuanhui/backup（只读挂进来）；空 = 不查备份 */
  backupDir: string;
  /** 看用量的磁盘（挂在 /data 上的目录）；空 = 不查 */
  diskPath: string;
  statfs?: (path: string) => Promise<{ blocks: number; bfree: number; bavail: number }>;
}

type Cursors = { gateSkips?: number; restoreEvents?: number; lastSkip?: number; opsSamples?: Array<[number, number]> };

export class ServerMonitor {
  private readonly d: ServerMonitorDeps;
  constructor(d: ServerMonitorDeps) {
    this.d = d;
  }

  private get cur(): Cursors {
    const s = this.d.alerter.state.cursors as { server?: Cursors };
    return (s.server ??= {});
  }

  async run(now: Date): Promise<void> {
    const a = this.d.alerter;
    await a.flush();
    try {
      await this.logEvents(now);
      await this.quota(now);
      await this.dbChecks(now);
      await this.disk();
      if (this.d.backupDir) await this.backup(now);
    } finally {
      a.prune();
      a.save();
    }
  }

  private async logEvents(now: Date): Promise<void> {
    const { events, dropped } = this.d.tap.drain();
    for (const e of events) await this.d.alerter.event(e);
    if (dropped) await this.d.alerter.event({ key: "log_alerts_dropped", title: "一分钟内日志告警太多，有一部分没转", severity: "warning", details: { count: dropped } });
    const n = this.d.tap.errorsLastHour(now);
    await this.d.alerter.condition(n > THRESHOLDS.errorsPerHour, {
      key: "http_5xx_rate",
      title: "接口 5xx 一小时超过 20 次",
      severity: "critical",
      details: { count: n, threshold: THRESHOLDS.errorsPerHour },
    });
  }

  private async quota(now: Date): Promise<void> {
    const usage = this.d.quotaUsage(now);
    const seen = new Set<string>();
    for (const u of usage) {
      const key = `kuainiao_store_daily:${u.storeId}`;
      seen.add(key);
      await this.d.alerter.condition(u.used >= THRESHOLDS.kuainiaoStoreDaily, {
        key,
        title: "单店当天调快鸟已到 200 次（每店每天上限 300）",
        severity: "warning",
        details: { store_id: u.storeId, used: u.used, threshold: THRESHOLDS.kuainiaoStoreDaily },
      });
    }
    // 过了零点计数清零：昨天在告警的店这里看不到了，发恢复
    for (const k of Object.keys(this.d.alerter.state.conditions)) {
      if (k.startsWith("kuainiao_store_daily:") && !seen.has(k)) await this.d.alerter.condition(false, { key: k, title: "", severity: "warning", details: { reason: "新的一天，计数清零" } });
    }
  }

  private async dbChecks(now: Date): Promise<void> {
    const db = this.d.db;
    // 营业时间没有同步：非演示、不在注销中、至少有一台没退出的设备的店
    const stores = await db
      .selectFrom("stores as s")
      .innerJoin("accounts as a", "a.store_id", "s.id")
      .select("s.id")
      .where("s.is_demo", "=", false)
      .where("a.delete_requested_at", "is", null)
      .where((eb) => eb.exists(eb.selectFrom("devices as d").select("d.id").whereRef("d.store_id", "=", "s.id").where("d.revoked_at", "is", null)))
      .execute();
    const live = new Set<string>();
    for (const s of stores) {
      const key = `no_sync:${s.id}`;
      live.add(key);
      const last = this.d.syncSeen.get(s.id) ?? this.d.startedAt;
      const v = noSyncVerdict(last > this.d.startedAt ? last : this.d.startedAt, now);
      await this.d.alerter.condition(v.active, { key, title: "营业时间内超过 3 小时没有任何设备同步成功（店里断网或 App 出问题）", severity: "warning", details: { store_id: s.id, ...v.details } });
    }
    for (const k of Object.keys(this.d.alerter.state.conditions)) {
      if (k.startsWith("no_sync:") && !live.has(k)) await this.d.alerter.condition(false, { key: k, title: "", severity: "warning", details: { reason: "店已不在监控范围（注销中或没有在用的设备）" } });
    }

    // 被退出的手机暂存待确认的账超过 24 小时
    const held = await db
      .selectFrom("ops")
      .select(["store_id", (eb) => eb.fn.countAll<string>().as("n")])
      .where("status", "=", "held")
      .where("received_at", "<", new Date(now.getTime() - THRESHOLDS.heldMs))
      .groupBy("store_id")
      .execute();
    const heldKeys = new Set<string>();
    for (const h of held) {
      heldKeys.add(`held_ops:${h.store_id}`);
      await this.d.alerter.condition(true, {
        key: `held_ops:${h.store_id}`,
        title: "被退出的手机有待确认的账，超过 24 小时没人处理",
        severity: "warning",
        details: { store_id: h.store_id, count: Number(h.n) },
      });
    }
    for (const k of Object.keys(this.d.alerter.state.conditions)) {
      if (k.startsWith("held_ops:") && !heldKeys.has(k)) await this.d.alerter.condition(false, { key: k, title: "", severity: "warning" });
    }

    // ops 表体积和 24 小时增长（T3）
    const r = await sql<{ bytes: string }>`SELECT pg_total_relation_size('ops')::text AS bytes`.execute(db);
    const bytes = Number(r.rows[0]?.bytes ?? 0);
    const samples = (this.cur.opsSamples ??= []);
    samples.push([now.getTime(), bytes]);
    while (samples.length > 1 && samples[0]![0] < now.getTime() - 25 * 3600_000) samples.shift();
    if (samples.length > 200) samples.splice(0, samples.length - 200);
    const dayAgo = samples.find(([t]) => t <= now.getTime() - 24 * 3600_000 + 60_000) ?? (samples[0]![0] <= now.getTime() - 23 * 3600_000 ? samples[0] : undefined);
    await this.d.alerter.condition(bytes > THRESHOLDS.opsTableBytes, {
      key: "ops_table_size",
      title: "ops 表体积超过 512 MB（§14 T3，出现异常增长再提裁定）",
      severity: "warning",
      details: { bytes, threshold: THRESHOLDS.opsTableBytes },
    });
    const growth = dayAgo ? bytes - dayAgo[1] : 0;
    await this.d.alerter.condition(growth > THRESHOLDS.opsGrowthBytesPerDay, {
      key: "ops_table_growth",
      title: "ops 表 24 小时内增长超过 64 MB（§14 T3）",
      severity: "warning",
      details: { bytes, growth_bytes: growth, threshold: THRESHOLDS.opsGrowthBytesPerDay },
    });
  }

  private async disk(): Promise<void> {
    if (!this.d.diskPath) return;
    let pct: number;
    try {
      const s = await (this.d.statfs ?? ((p: string) => statfs(p)))(this.d.diskPath);
      const used = s.blocks - s.bfree;
      pct = used + s.bavail > 0 ? Math.round((used / (used + s.bavail)) * 100) : 0;
    } catch {
      return;
    }
    await this.d.alerter.condition(pct > THRESHOLDS.diskUsedPercent, {
      key: "disk_usage",
      title: "数据盘用量超过 80%",
      severity: "critical",
      details: { path: this.d.diskPath, used_percent: pct, threshold: THRESHOLDS.diskUsedPercent },
    });
  }

  private async backup(now: Date): Promise<void> {
    const a = this.d.alerter;
    const dir = this.d.backupDir;
    let m: Record<string, number> = {};
    try {
      m = parseMetrics(readFileSync(join(dir, "metrics.prom"), "utf8"));
    } catch {
      // 还没有 metrics.prom：一次备份都没跑过，心跳那条会报
    }
    const last = m.yuanhui_backup_last_success_timestamp_seconds || null;
    const hb = heartbeatVerdict(last, now);
    await a.condition(hb.active, { key: "backup_heartbeat_stale", title: "备份心跳超时（营业时间 2 小时、其余 6 小时没有成功备份）", severity: "critical", details: hb.details });

    const failing = m.yuanhui_backup_last_ok === 0;
    const fails = m.yuanhui_backup_consecutive_failures ?? 0;
    await a.condition(failing, { key: "backup_failed", title: "最近一次备份失败", severity: "warning", details: { consecutive_failures: fails } });
    await a.condition(fails >= THRESHOLDS.backupConsecutiveFailures, {
      key: "backup_consecutive_failures",
      title: "备份连续失败 2 次以上",
      severity: "critical",
      details: { consecutive_failures: fails, threshold: THRESHOLDS.backupConsecutiveFailures },
    });
    await a.condition(m.yuanhui_backup_lifecycle_stale === 1, {
      key: "backup_lifecycle_stale",
      title: "最旧的备份超过 36 天：OSS 生命周期规则没生效，「35 天内彻底清除」不成立",
      severity: "critical",
    });

    // 被跳过（上一次还在跑 / 锁）：last_skip 比上次看到的新就发一次
    const skip = m.yuanhui_backup_last_skip_timestamp_seconds ?? 0;
    const seenSkip = this.cur.lastSkip;
    if (skip > 0 && skip !== seenSkip && (seenSkip !== undefined || now.getTime() - skip * 1000 < 2 * 3600_000)) {
      await a.event({ key: "backup_skipped", title: "备份被跳过：上一次还在跑（锁）", severity: "warning", details: { since: new Date(skip * 1000).toISOString() } });
    }
    this.cur.lastSkip = skip;

    // gate-skips.log：发布时跳过了迁移前备份门禁
    const g = readNewLines(join(dir, "gate-skips.log"), this.cur.gateSkips ?? 0);
    if (g.lines.length) {
      await a.event({ key: "backup_gate_skipped", title: "有人发布时跳过了迁移前备份门禁（--skip-backup-gate）", severity: "warning", details: { count: g.lines.length, line: g.lines.at(-1) } });
    }
    this.cur.gateSkips = g.offset;

    // restore-events.log：restore.sh 在 ECS 上（RESTORE_COMPOSE_DIR）跑失败时写的
    const r = readNewLines(join(dir, "restore-events.log"), this.cur.restoreEvents ?? 0);
    for (const l of r.lines) {
      let o: Record<string, unknown> = {};
      try {
        o = JSON.parse(l) as Record<string, unknown>;
      } catch {
        continue;
      }
      if (o.event === "restore_failed") await a.event({ key: "restore_failed", title: "恢复失败（restore.sh）", severity: "critical", details: o });
    }
    this.cur.restoreEvents = r.offset;
  }
}
