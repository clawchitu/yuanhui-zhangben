// 进程入口：读配置 → 监听。Docker 镜像里 `node src/server.ts`。
// 迁移不在启动时自动跑：发布时 deploy.sh 先单独跑 `node scripts/migrate.ts`（§9.1），失败就不换镜像。
// 本机开发想省一步可以设 MIGRATE_ON_START=1。
import { buildApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { createDb, migrate } from "./db.ts";
import { defaultTasks, Scheduler } from "./jobs/scheduler.ts";
import { archiveStoreFromConfig } from "./lookup/oss.ts";

const config = loadConfig();
const db = createDb({ connectionString: config.databaseUrl });
const app = buildApp({ config, db });

if (process.env.MIGRATE_ON_START === "1") {
  const applied = await migrate(db.pool);
  app.log.info({ applied }, "迁移完成");
}

await app.listen({ host: config.host, port: config.port });

// 后台任务（jobs/scheduler.ts）：商品图（开关打开且配了对象存储才登记）、演示店每日重置、注销导出包、注销到期清除。
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
