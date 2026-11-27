// 进程入口：读配置 → 监听。Docker 镜像里 `node src/server.ts`。
// 迁移不在启动时自动跑：发布时 deploy.sh 先单独跑 `node scripts/migrate.ts`（§9.1），失败就不换镜像。
// 本机开发想省一步可以设 MIGRATE_ON_START=1。
import { buildApp } from "./app.ts";
import { ConfigError, loadConfig, type Config } from "./config.ts";
import { createDb, migrate } from "./db.ts";
import { defaultTasks, Scheduler } from "./jobs/scheduler.ts";
import { archiveStoreFromConfig } from "./lookup/oss.ts";
import type { AlerterLog } from "./monitor/alerter.ts";
import { monitorFromConfig } from "./monitor/setup.ts";
import { ServerMonitor } from "./monitor/server-monitor.ts";

// 配置不对就拒绝启动：写一行 JSON 日志说清是哪一项，退出码 1。只写报错文字，不打印环境变量的值（S21 API_BASE 白名单等）
let config: Config;
try {
  config = loadConfig();
} catch (e) {
  if (!(e instanceof ConfigError)) throw e;
  process.stderr.write(JSON.stringify({ level: 60, time: Date.now(), msg: `配置错误，拒绝启动：${e.message}` }) + "\n");
  process.exit(1);
}
const db = createDb({ connectionString: config.databaseUrl });
const startedAt = new Date();
// 监控（S10c）：日志先交给 LogTap，Alerter 等 app 建好后拿 app.log 记自己的发送失败。
// Alerter 在 app 建好之前就构造（读 state.json；坏了要记一条警告），所以 app 建好之前先往 stderr 写一行 JSON，
// 建好之后换成 app.log（PR #25 返修：以前这里直接引用还没初始化的 app，状态文件一坏 api 就起不来）。
const earlyLog = (level: number) => (o: object, m: string) => process.stderr.write(JSON.stringify({ level, time: Date.now(), ...o, msg: m }) + "\n");
let monLogTarget: AlerterLog = { warn: earlyLog(40), error: earlyLog(50) };
const monLog: AlerterLog = { warn: (o, m) => monLogTarget.warn(o, m), error: (o, m) => monLogTarget.error(o, m) };
const mon = monitorFromConfig(config, () => new Date(), monLog);
const app = buildApp({ config, db, ...(mon ? { logTap: (l: string) => mon.tap.line(l) } : {}) });
monLogTarget = { warn: (o, m) => app.log.warn(o, m), error: (o, m) => app.log.error(o, m) };
if (!mon) app.log.warn("没配 MONITOR_DIR：不跑监控检查，告警只留在日志里（生产必须配，见 deploy/compose.yml）");

if (process.env.MIGRATE_ON_START === "1") {
  const applied = await migrate(db.pool);
  app.log.info({ applied }, "迁移完成");
}

await app.listen({ host: config.host, port: config.port });

// 后台任务（jobs/scheduler.ts）：商品图（开关打开且配了对象存储才登记）、演示店每日重置、注销导出包、注销到期清除、监控（S10c）。
// 存档桶（exports/、deletions/）：本机目录和商品图共用；阿里云是第二个桶 OSS_ARCHIVE_BUCKET（yuanhui-backup），不落到商品图桶（S09-11、T13）。
const clock = () => new Date();
const scheduler = new Scheduler({
  clock,
  log: app.log,
  tasks: defaultTasks({
    db: db.kysely,
    clock,
    productImagesEnabled: config.productImagesEnabled,
    images: app.deps.objectStore,
    archive: archiveStoreFromConfig(config, app.deps.objectStore),
    imageCacheDir: config.imageCacheDir,
    log: app.log,
    candidates: app.candidates,
    monitor: mon
      ? new ServerMonitor({
          db: db.kysely,
          alerter: mon.alerter,
          tap: mon.tap,
          syncSeen: app.syncSeen,
          quotaUsage: (now) => app.catalog.quota.usage(now),
          startedAt,
          backupDir: config.monitor.backupDir,
          diskPath: config.monitor.diskPath,
          noSyncStores: config.monitor.noSyncStores,
        })
      : null,
  }),
});
scheduler.start();

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.once(sig, async () => {
    app.log.info({ sig }, "收到退出信号");
    await scheduler.stop();
    await app.close();
    await db.close();
    process.exit(0);
  });
}
