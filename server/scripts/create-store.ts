// 建店。没有注册接口，店和账号只能由运维用脚本建（§3.1）。
// 用法：DATABASE_URL=... node scripts/create-store.ts --name 江阴市周庄元辉烟酒店 [--demo] [--low-stock-default 3]
// 输出一行 JSON：{"id": "...", "epoch": "..."}
import { parseArgs } from "node:util";
import type { Kysely } from "kysely";
import { createDb, type Database } from "../src/db.ts";

export interface CreateStoreInput {
  name: string;
  isDemo?: boolean;
  lowStockDefault?: number;
}

export async function createStore(db: Kysely<Database>, input: CreateStoreInput): Promise<{ id: string; epoch: string }> {
  const name = input.name.trim();
  if (name.length < 1 || name.length > 100) throw new Error("店名 1–100 个字");
  const low = input.lowStockDefault ?? 3;
  if (!Number.isSafeInteger(low) || low < 0) throw new Error("low-stock-default 必须是非负整数");
  return db
    .insertInto("stores")
    .values({ name, is_demo: input.isDemo ?? false, low_stock_default: low })
    .returning(["id", "epoch"])
    .executeTakeFirstOrThrow();
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      name: { type: "string" },
      demo: { type: "boolean", default: false },
      "low-stock-default": { type: "string" },
    },
  });
  const url = process.env.DATABASE_URL;
  if (!url || !values.name) {
    console.error("用法：DATABASE_URL=... node scripts/create-store.ts --name <店名> [--demo] [--low-stock-default 3]");
    process.exit(2);
  }
  const db = createDb({ connectionString: url, max: 1 });
  try {
    const low = values["low-stock-default"];
    const r = await createStore(db.kysely, {
      name: values.name,
      isDemo: values.demo,
      lowStockDefault: low === undefined ? undefined : Number(low),
    });
    console.log(JSON.stringify(r));
  } catch (e) {
    console.error(`建店失败：${(e as Error).message}`);
    process.exitCode = 1;
  } finally {
    await db.close();
  }
}
