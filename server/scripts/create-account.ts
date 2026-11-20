// 给一个店建账号（一个店一个账号，§3.1）。没有注册接口，账号只能用这个脚本建。
// 用法：DATABASE_URL=... node scripts/create-account.ts --store <店id> --username <用户名> [--kind family|review]
// 密码不走命令行参数（会留在 shell 历史和进程列表里）：从标准输入读第一行，或者读环境变量 ACCOUNT_PASSWORD。
//   例：read -s P && printf '%s\n' "$P" | DATABASE_URL=... node scripts/create-account.ts --store ... --username ...
// 审核号（review）只能建在演示店，家用号（family）只能建在非演示店。
import { parseArgs } from "node:util";
import type { Kysely } from "kysely";
import { createDb, type Database } from "../src/db.ts";
import { hashPassword, PASSWORD_MAX, PASSWORD_MIN } from "../src/auth/password.ts";

export { hashPassword, PASSWORD_MAX, PASSWORD_MIN };

export interface CreateAccountInput {
  storeId: string;
  username: string;
  password: string;
  kind?: "family" | "review";
}

export async function createAccount(db: Kysely<Database>, input: CreateAccountInput): Promise<{ id: string }> {
  const username = input.username.trim();
  if (username.length < 1 || username.length > 64) throw new Error("用户名 1–64 个字符");
  if (/\s/.test(username)) throw new Error("用户名不能有空格");
  const kind = input.kind ?? "family";
  if (kind !== "family" && kind !== "review") throw new Error("kind 只能是 family 或 review");
  if (input.password.length < PASSWORD_MIN || input.password.length > PASSWORD_MAX) {
    throw new Error(`密码长度 ${PASSWORD_MIN}–${PASSWORD_MAX}`);
  }
  const store = await db.selectFrom("stores").select(["id", "is_demo"]).where("id", "=", input.storeId).executeTakeFirst();
  if (!store) throw new Error("店不存在");
  if (kind === "review" && !store.is_demo) throw new Error("审核号只能建在演示店");
  if (kind === "family" && store.is_demo) throw new Error("演示店只能建审核号");
  const password_hash = await hashPassword(input.password);
  return db
    .insertInto("accounts")
    .values({ store_id: store.id, username, password_hash, kind })
    .returning(["id"])
    .executeTakeFirstOrThrow();
}

async function readPassword(): Promise<string> {
  if (process.env.ACCOUNT_PASSWORD) return process.env.ACCOUNT_PASSWORD;
  if (process.stdin.isTTY) throw new Error("请从标准输入传入密码（不回显），或设置 ACCOUNT_PASSWORD");
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  return data.split(/\r?\n/)[0] ?? "";
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      store: { type: "string" },
      username: { type: "string" },
      kind: { type: "string", default: "family" },
    },
  });
  const url = process.env.DATABASE_URL;
  if (!url || !values.store || !values.username) {
    console.error("用法：DATABASE_URL=... node scripts/create-account.ts --store <店id> --username <用户名> [--kind family|review]，密码从标准输入读");
    process.exit(2);
  }
  const db = createDb({ connectionString: url, max: 1 });
  try {
    const password = await readPassword();
    const r = await createAccount(db.kysely, {
      storeId: values.store,
      username: values.username,
      password,
      kind: values.kind as "family" | "review",
    });
    console.log(JSON.stringify(r));
  } catch (e) {
    const msg = (e as { code?: string }).code === "23505" ? "用户名已被占用，或这个店已经有账号" : (e as Error).message;
    console.error(`建账号失败：${msg}`);
    process.exitCode = 1;
  } finally {
    await db.close();
  }
}
