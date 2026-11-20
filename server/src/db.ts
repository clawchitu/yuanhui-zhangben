// 数据库：pg 连接池 + Kysely，以及按文件名顺序执行 migrations/*.sql 的迁移器。
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Kysely, PostgresDialect } from "kysely";
import pg from "pg";
import type { Database } from "./db-types.ts";

export type { Database } from "./db-types.ts";

export const MIGRATIONS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../migrations");

// 只给本连接池用的类型解析：date 列保持 'YYYY-MM-DD' 字符串（不转成本地时区的 Date）；
// int8 保持 pg 默认的字符串，金额不经过 JS number 丢精度。
const DATE_OID = 1082;
const types = {
  getTypeParser(oid: number, format?: "text" | "binary") {
    if (oid === DATE_OID) return (v: string) => v;
    return format === "binary" ? pg.types.getTypeParser(oid, "binary") : pg.types.getTypeParser(oid);
  },
};

export interface DbOptions {
  connectionString: string;
  /** 只用于测试：每个测试文件一个独立 schema */
  searchPath?: string;
  max?: number;
  connectionTimeoutMillis?: number;
}

export interface Db {
  pool: pg.Pool;
  kysely: Kysely<Database>;
  close(): Promise<void>;
}

export function createDb(opts: DbOptions): Db {
  const pool = new pg.Pool({
    connectionString: opts.connectionString,
    max: opts.max ?? 10,
    connectionTimeoutMillis: opts.connectionTimeoutMillis ?? 2000,
    idleTimeoutMillis: 30_000,
    options: opts.searchPath ? `-c search_path=${quoteIdent(opts.searchPath)}` : undefined,
    types,
  });
  // 空闲连接被数据库断开时不要让进程崩掉；下一次取连接会重连
  pool.on("error", () => {});
  const kysely = new Kysely<Database>({ dialect: new PostgresDialect({ pool }) });
  let closed = false;
  return {
    pool,
    kysely,
    async close() {
      if (closed) return;
      closed = true;
      // Kysely 的驱动是懒初始化的：没用 Kysely 查过就 destroy 不会关池，所以自己再关一次
      await kysely.destroy();
      if (!pool.ended) await pool.end();
    },
  };
}

export function quoteIdent(name: string): string {
  if (!/^[a-z_][a-z0-9_]*$/.test(name)) throw new Error(`不合法的标识符：${name}`);
  return `"${name}"`;
}

export interface MigrationFile {
  name: string;
  sql: string;
  checksum: string;
}

export function listMigrations(dir = MIGRATIONS_DIR): MigrationFile[] {
  return readdirSync(dir)
    .filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f))
    .sort()
    .map((name) => {
      const sql = readFileSync(join(dir, name), "utf8");
      return { name, sql, checksum: createHash("sha256").update(sql).digest("hex") };
    });
}

// 迁移锁的固定键（pg_advisory_lock），防止两个进程同时迁移
const MIGRATION_LOCK_KEY = 7_207_001;

/**
 * 按文件名顺序执行还没执行过的迁移，每个文件一个事务。可重复执行：已执行的跳过。
 * 已执行的文件内容被改过 → 报错（迁移只能追加新文件，不能改旧文件）。
 * 返回这次新执行的文件名。
 */
export async function migrate(pool: pg.Pool, dir = MIGRATIONS_DIR): Promise<string[]> {
  const files = listMigrations(dir);
  const client = await pool.connect();
  try {
    await client.query("SELECT pg_advisory_lock($1)", [MIGRATION_LOCK_KEY]);
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name       text PRIMARY KEY,
      checksum   text NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    const done = new Map<string, string>(
      (await client.query<{ name: string; checksum: string }>("SELECT name, checksum FROM schema_migrations")).rows.map(
        (r) => [r.name, r.checksum],
      ),
    );
    const applied: string[] = [];
    for (const f of files) {
      const prev = done.get(f.name);
      if (prev !== undefined) {
        if (prev !== f.checksum) throw new Error(`迁移 ${f.name} 已执行过但内容被改了；只能追加新的迁移文件`);
        continue;
      }
      await client.query("BEGIN");
      try {
        await client.query(f.sql);
        await client.query("INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)", [f.name, f.checksum]);
        await client.query("COMMIT");
      } catch (e) {
        await client.query("ROLLBACK");
        throw new Error(`迁移 ${f.name} 失败：${(e as Error).message}`, { cause: e });
      }
      applied.push(f.name);
    }
    return applied;
  } finally {
    await client.query("SELECT pg_advisory_unlock($1)", [MIGRATION_LOCK_KEY]).catch(() => {});
    client.release();
  }
}
