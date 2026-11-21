// 建演示小店和审核号并种上数据（S09）。审核号的用户名、密码写进 App Store 的 Review Notes；每日重置把密码恢复成这里设的。
// 用法：DATABASE_URL=... node scripts/create-demo-store.ts --username <审核号>，密码从标准输入读一行（不进命令行历史）
// 输出一行 JSON：{"store_id": "...", "account_id": "..."}
import { parseArgs } from "node:util";
import { text } from "node:stream/consumers";
import { createDb } from "../src/db.ts";
import { PASSWORD_MAX, PASSWORD_MIN } from "../src/auth/password.ts";
import { setupDemoStore } from "../src/demo/reset.ts";

if (import.meta.main) {
  const { values } = parseArgs({ options: { username: { type: "string" } } });
  const url = process.env.DATABASE_URL;
  if (!url || !values.username) {
    console.error("用法：DATABASE_URL=... node scripts/create-demo-store.ts --username <审核号>（密码从标准输入读）");
    process.exit(2);
  }
  const password = (await text(process.stdin)).replace(/\r?\n$/, "");
  if (password.length < PASSWORD_MIN || password.length > PASSWORD_MAX) {
    console.error(`密码 ${PASSWORD_MIN}–${PASSWORD_MAX} 个字符`);
    process.exit(2);
  }
  const db = createDb({ connectionString: url, max: 2 });
  try {
    const r = await setupDemoStore(db.kysely, { username: values.username, password, now: new Date() });
    console.log(JSON.stringify({ store_id: r.storeId, account_id: r.accountId }));
  } catch (e) {
    console.error(`建演示店失败：${(e as Error).message}`);
    process.exitCode = 1;
  } finally {
    await db.close();
  }
}
