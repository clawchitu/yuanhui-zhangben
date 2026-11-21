// 进程入口：读配置 → 监听。Docker 镜像里 `node src/server.ts`。
// 迁移不在启动时自动跑：发布时 deploy.sh 先单独跑 `node scripts/migrate.ts`（§9.1），失败就不换镜像。
// 本机开发想省一步可以设 MIGRATE_ON_START=1。
import { buildApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { createDb, migrate } from "./db.ts";
import { startImageFetchLoop } from "./jobs/image-fetch.ts";

const config = loadConfig();
const db = createDb({ connectionString: config.databaseUrl });
const app = buildApp({ config, db });

if (process.env.MIGRATE_ON_START === "1") {
  const applied = await migrate(db.pool);
  app.log.info({ applied }, "迁移完成");
}

await app.listen({ host: config.host, port: config.port });

// 商品图任务：开关打开且配了对象存储才跑（S08；S09 的 jobs/scheduler.ts 落地后挪过去）
const stopImages =
  config.productImagesEnabled && app.deps.objectStore
    ? startImageFetchLoop({ db: db.kysely, store: app.deps.objectStore, enabled: true, clock: () => new Date(), log: app.log })
    : () => {};

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.once(sig, async () => {
    app.log.info({ sig }, "收到退出信号");
    stopImages();
    await app.close();
    await db.close();
    process.exit(0);
  });
}
