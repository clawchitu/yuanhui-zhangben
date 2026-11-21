// 备份清单（§9.4）：和 pg_dump 同一个快照里算（pg_export_snapshot + pg_dump --snapshot），恢复后逐项比对。
// 内容：每张表的行数；每个店的流水条数、value_delta_fen 合计、cogs_fen 合计、每个商品库存与货值的校验和、
// 每条流水的数量 / 金额 / 成本的校验和、本月和上月的月报全部数字。金额合计用字符串（bigint 不丢精度）。
// 清单也加密上传（含每家店的金额，算业务数据）。
import { sql, type Transaction } from "kysely";
import type { Database } from "../db.ts";
import { reportMonthIn, type ReportMonth } from "../reports/month.ts";
import { monthOf } from "../reports/common.ts";

export interface StoreManifest {
  entries: number;
  value_delta_fen: string;
  cogs_fen: string;
  products: number;
  /** md5(按商品 id 排序的 id:库存:货值:最近进价) */
  products_checksum: string;
  /** md5(按流水 id 排序的 id:类型:数量:实收:成本:货值变化:单位成本:rev) */
  entries_checksum: string;
  months: Record<string, ReportMonth>;
}

export interface Manifest {
  format: 1;
  /** 快照时刻（服务器钟）；恢复后比对月报时用同一个 now */
  taken_at: string;
  migrations: string[];
  tables: Record<string, number>;
  stores: Record<string, StoreManifest>;
  /** 上传时填：明文 dump 的 sha256 和字节数 */
  dump?: { sha256: string; bytes: number };
}

function prevMonth(m: string): string {
  const [y, mo] = m.split("-").map(Number) as [number, number];
  return mo === 1 ? `${y - 1}-12` : `${y}-${String(mo - 1).padStart(2, "0")}`;
}

/** 在调用方的快照事务里算清单（当前 search_path 下的表） */
export async function computeManifest(trx: Transaction<Database>, now: Date): Promise<Manifest> {
  const tablesRes = await sql<{ t: string }>`
    SELECT table_name AS t FROM information_schema.tables
    WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' ORDER BY table_name`.execute(trx);
  const tables: Record<string, number> = {};
  for (const { t } of tablesRes.rows) {
    if (!/^[a-z_][a-z0-9_]*$/.test(t)) throw new Error(`表名不对：${t}`);
    const r = await sql<{ n: string }>`SELECT count(*)::text AS n FROM ${sql.table(t)}`.execute(trx);
    tables[t] = Number(r.rows[0]!.n);
  }
  const migrations = tables.schema_migrations !== undefined
    ? (await sql<{ name: string }>`SELECT name FROM schema_migrations ORDER BY name`.execute(trx)).rows.map((r) => r.name)
    : [];
  const stores: Record<string, StoreManifest> = {};
  const ids = await trx.selectFrom("stores").select("id").orderBy("id").execute();
  const months = [monthOf(now), prevMonth(monthOf(now))];
  for (const { id } of ids) {
    const e = await sql<{ n: number; v: string; c: string; ck: string }>`
      SELECT count(*)::int AS n, coalesce(sum(value_delta_fen), 0)::text AS v, coalesce(sum(cogs_fen), 0)::text AS c,
             md5(coalesce(string_agg(concat_ws(':', id, type, qty_delta, amount_fen, cogs_fen, value_delta_fen,
               coalesce(unit_cost_fen::text, '-'), rev), ',' ORDER BY id), '')) AS ck
      FROM entries WHERE store_id = ${id}`.execute(trx);
    const p = await sql<{ n: number; ck: string }>`
      SELECT count(*)::int AS n,
             md5(coalesce(string_agg(concat_ws(':', id, stock_qty, stock_value_fen, coalesce(last_cost_fen::text, '-')), ',' ORDER BY id), '')) AS ck
      FROM products WHERE store_id = ${id}`.execute(trx);
    const m: Record<string, ReportMonth> = {};
    for (const mo of months) m[mo] = await reportMonthIn(trx, id, mo, now);
    const er = e.rows[0]!;
    stores[id] = {
      entries: er.n,
      value_delta_fen: er.v,
      cogs_fen: er.c,
      products: p.rows[0]!.n,
      products_checksum: p.rows[0]!.ck,
      entries_checksum: er.ck,
      months: m,
    };
  }
  return { format: 1, taken_at: now.toISOString(), migrations, tables, stores };
}

/** 逐项比对，返回差异（空 = 一致）。excludeStores：已重放删除的店，只核对它们确实不在了 */
export function diffManifests(expected: Manifest, actual: Manifest, o: { excludeStores?: Iterable<string>; skipTables?: boolean } = {}): string[] {
  const out: string[] = [];
  const ex = new Set([...(o.excludeStores ?? [])].map((s) => s.toLowerCase()));
  if (JSON.stringify(expected.migrations) !== JSON.stringify(actual.migrations)) out.push(`迁移不一致：${expected.migrations.join(",")} ≠ ${actual.migrations.join(",")}`);
  if (!o.skipTables) {
    for (const t of new Set([...Object.keys(expected.tables), ...Object.keys(actual.tables)])) {
      if (expected.tables[t] !== actual.tables[t]) out.push(`表 ${t} 行数：备份 ${expected.tables[t] ?? "无"}，恢复后 ${actual.tables[t] ?? "无"}`);
    }
  }
  for (const s of ex) if (actual.stores[s]) out.push(`店 ${s} 有删除记录，恢复后仍在`);
  for (const [s, want] of Object.entries(expected.stores)) {
    if (ex.has(s)) continue;
    const got = actual.stores[s];
    if (!got) {
      out.push(`店 ${s} 恢复后不见了`);
      continue;
    }
    for (const k of ["entries", "value_delta_fen", "cogs_fen", "products", "products_checksum", "entries_checksum"] as const) {
      if (want[k] !== got[k]) out.push(`店 ${s} ${k}：备份 ${want[k]}，恢复后 ${got[k]}`);
    }
    for (const [mo, rep] of Object.entries(want.months)) {
      if (JSON.stringify(rep) !== JSON.stringify(got.months[mo])) out.push(`店 ${s} ${mo} 月报不一致`);
    }
  }
  for (const s of Object.keys(actual.stores)) if (!expected.stores[s] && !ex.has(s)) out.push(`店 ${s} 备份里没有，恢复后多出来了`);
  return out;
}
