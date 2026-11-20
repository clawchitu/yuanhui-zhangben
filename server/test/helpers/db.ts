// 测试辅助：每个测试文件一个独立 schema（迁移跑在里面），测试文件之间互不干扰、可以并行。
// 需要真实 Postgres：CI 用服务容器；本机设 DATABASE_URL（例如 Homebrew postgresql@16）。
import { randomBytes } from "node:crypto";
import pg from "pg";
import { sql, type Kysely } from "kysely";
import { createDb, migrate, quoteIdent, type Db, type Database } from "../../src/db.ts";
import { loadConfig, type Config } from "../../src/config.ts";

export function databaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("测试需要 DATABASE_URL（真实 Postgres 16），见 CLAUDE.md「服务器」");
  return url;
}

/** 给连接串加上 search_path，命令行脚本（create-store.ts 等）也能落到测试 schema 里 */
export function urlWithSearchPath(url: string, schema: string): string {
  const u = new URL(url);
  u.searchParams.set("options", `-c search_path=${quoteIdent(schema)}`);
  return u.toString();
}

export interface TestDb extends Db {
  schema: string;
  url: string;
  /** 删掉整个 schema 并关闭连接池 */
  drop(): Promise<void>;
}

/** 新建一个空 schema；migrateIt=true（默认）时跑完全部迁移 */
export async function createTestDb(opts: { migrate?: boolean } = {}): Promise<TestDb> {
  const url = databaseUrl();
  const schema = `t_${Date.now().toString(36)}_${randomBytes(4).toString("hex")}`;
  const admin = new pg.Client({ connectionString: url });
  await admin.connect();
  try {
    await admin.query(`CREATE SCHEMA ${quoteIdent(schema)}`);
  } finally {
    await admin.end();
  }
  const db = createDb({ connectionString: url, searchPath: schema, max: 4 });
  if (opts.migrate !== false) await migrate(db.pool);
  return {
    ...db,
    schema,
    url: urlWithSearchPath(url, schema),
    async drop() {
      await db.close();
      const c = new pg.Client({ connectionString: url });
      await c.connect();
      try {
        await c.query(`DROP SCHEMA ${quoteIdent(schema)} CASCADE`);
      } finally {
        await c.end();
      }
    },
  };
}

/** 在事务里跑 fn，结束后一律回滚（同一个测试文件里需要干净状态时用） */
export async function withRollback<T>(db: Kysely<Database>, fn: (trx: Kysely<Database>) => Promise<T>): Promise<T> {
  const ROLLBACK = Symbol("rollback");
  let out: T | undefined;
  try {
    await db.transaction().execute(async (trx) => {
      out = await fn(trx);
      throw ROLLBACK;
    });
  } catch (e) {
    if (e !== ROLLBACK) throw e;
  }
  return out as T;
}

export function testConfig(overrides: Partial<Config> = {}): Config {
  return { ...loadConfig({ DATABASE_URL: "postgres://unused" }), logLevel: "silent", ...overrides };
}

/** Postgres 报错码：23505 唯一、23514 CHECK、23503 外键、23502 非空 */
export async function expectPgError(p: Promise<unknown>, code: string, constraint?: string | RegExp): Promise<void> {
  let err: { code?: string; constraint?: string; message?: string } | undefined;
  try {
    await p;
  } catch (e) {
    err = e as typeof err;
  }
  if (!err) throw new Error(`应该失败（期望 ${code}${constraint ? ` / ${constraint}` : ""}），但成功了`);
  if (err.code !== code) throw new Error(`期望错误码 ${code}，实际 ${err.code}：${err.message}`);
  if (constraint !== undefined) {
    const ok = typeof constraint === "string" ? err.constraint === constraint : constraint.test(err.constraint ?? "");
    if (!ok) throw new Error(`期望违反约束 ${constraint}，实际 ${err.constraint}：${err.message}`);
  }
}

/** 测试用的取号：stores.rev + 1。正式的取号函数（店铺锁内）在 S04 */
export async function nextRev(db: Kysely<Database>, storeId: string): Promise<string> {
  const r = await db
    .updateTable("stores")
    .set({ rev: sql`rev + 1` })
    .where("id", "=", storeId)
    .returning("rev")
    .executeTakeFirstOrThrow();
  return r.rev;
}
