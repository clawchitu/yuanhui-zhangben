// 手动跑迁移：DATABASE_URL=... node scripts/migrate.ts（deploy.sh 发布时也用它）
import { createDb, migrate } from "../src/db.ts";

const url = process.env.DATABASE_URL;
if (!url) {
  console.error("缺少 DATABASE_URL");
  process.exit(2);
}
const db = createDb({ connectionString: url });
try {
  const applied = await migrate(db.pool);
  console.log(applied.length ? `执行了：${applied.join(", ")}` : "没有新的迁移");
} finally {
  await db.close();
}
