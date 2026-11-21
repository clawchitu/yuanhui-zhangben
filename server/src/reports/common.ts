// 报表公共部分（§5.3）：上海时区的日 / 月界线、按时间段对流水求和的那一条 SQL。
// 所有数字都只由 entries 求和得出（不读商品投影），因此「报表 = 从流水按定义重算」是逐分成立的。
import { sql, type Kysely, type RawBuilder, type Transaction } from "kysely";
import type { Database } from "../db.ts";
import { shanghaiDay } from "../auth/guard.ts";
import { int } from "../sync/projection.ts";

export type Q = Kysely<Database> | Transaction<Database>;

export const DAY_MS = 86_400_000;

/**
 * 合法的日历日 YYYY-MM-DD（2026-02-30 这种不合法）。年份 0001–9999：入账只按「存不存得下」判，
 * 1970 年、公元 1 年的流水都照收（§14 S05-4），查询要覆盖全部能入账的日子（§14 S07-8，Codex 第一轮 1）。
 */
export function isValidDay(s: string): boolean {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/.exec(s);
  if (!m || m[1] === "0000") return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export function isValidMonth(s: string): boolean {
  return /^[0-9]{4}-(0[1-9]|1[0-2])$/.test(s) && isValidDay(`${s}-01`);
}

/**
 * 上海时间某一天 00:00 的时刻，由 Postgres 按 Asia/Shanghai 换算（SQL 片段，直接放进 WHERE）。
 * 与归日用的 `occurred_at AT TIME ZONE 'Asia/Shanghai'` 是同一份时区数据，所以「列表里的日期」和「按日期查」恒一致：
 * 1986–1991 年上海有夏令时、1901 年以前是地方平时，固定 +08:00 在那些年份会和归日对不上。
 * day 可以是 10000-01-01（9999-12-31 的下一天），Postgres 收得下。
 */
export function dayStart(day: string): RawBuilder<Date> {
  return sql<Date>`((${day}::date)::timestamp AT TIME ZONE 'Asia/Shanghai')`;
}
export type Bound = RawBuilder<Date>;

/** 归日：流水的 occurred_at 在上海是哪一天（与 dayStart 同一口径） */
export const DAY_OF_SQL = sql`to_char((occurred_at AT TIME ZONE 'Asia/Shanghai')::date, 'YYYY-MM-DD')`;

/** day + n 天（日历日）；年份补足 4 位，9999-12-31 的下一天写成 10000-01-01 */
export function addDay(day: string, n: number): string {
  const d = new Date(Date.parse(`${day}T00:00:00Z`) + n * DAY_MS);
  return `${String(d.getUTCFullYear()).padStart(4, "0")}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

export function nextMonth(month: string): string {
  const [y, m] = month.split("-").map(Number) as [number, number];
  return m === 12 ? `${String(y + 1).padStart(4, "0")}-01` : `${month.slice(0, 4)}-${String(m + 1).padStart(2, "0")}`;
}

export const today = shanghaiDay;
export const monthOf = (d: Date) => shanghaiDay(d).slice(0, 7);

/** 一个时间段 [from, to) 内的流水合计（§5.3 的全部口径） */
export interface Totals {
  /** 卖了 = Σ 卖出行 amount_fen（含冲销行；cost_fix 不算） */
  sold: number;
  /** 赚了 = Σ 进价已知卖出行 (amount − cogs) + Σ cost_fix 行 (amount − cogs) */
  profit: number;
  /** 优惠 = Σ 卖出行 (list_amount − amount)；只算卖出行，cost_fix 的 list_amount 是 0，算进去会变成负优惠 */
  discount: number;
  /** 过期损耗 = Σ expire_loss 行 cogs_fen */
  expireLoss: number;
  /** 各类型 value_delta_fen 之和 */
  value: Record<"sale" | "stock_in" | "opening" | "count" | "cost_adjust" | "cost_fix" | "expire_loss" | "supplier_return", number>;
  /** 尚未补记的 cost_missing 卖出（未撤销的原行、cost_fix_entry_id 为空）：涉及的商品种数 / 笔数 */
  costMissingProducts: number;
  costMissingSales: number;
  /** 标了 cost_missing 的损耗行（未撤销的原行）笔数，按类型 */
  lossMissing: Record<"count" | "expire_loss" | "supplier_return", number>;
}

const TOTALS_SELECT = sql`
  COALESCE(SUM(amount_fen) FILTER (WHERE type = 'sale'), 0)::text AS sold,
  COALESCE(SUM(amount_fen - cogs_fen) FILTER (WHERE (type = 'sale' AND NOT cost_missing) OR type = 'cost_fix'), 0)::text AS profit,
  COALESCE(SUM(list_amount_fen - amount_fen) FILTER (WHERE type = 'sale'), 0)::text AS discount,
  COALESCE(SUM(cogs_fen) FILTER (WHERE type = 'expire_loss'), 0)::text AS expire_loss,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'sale'), 0)::text AS v_sale,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'stock_in'), 0)::text AS v_stock_in,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'opening'), 0)::text AS v_opening,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'count'), 0)::text AS v_count,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'cost_adjust'), 0)::text AS v_cost_adjust,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'cost_fix'), 0)::text AS v_cost_fix,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'expire_loss'), 0)::text AS v_expire_loss,
  COALESCE(SUM(value_delta_fen) FILTER (WHERE type = 'supplier_return'), 0)::text AS v_supplier_return,
  COUNT(DISTINCT product_id) FILTER (WHERE type = 'sale' AND cost_missing AND reverses_entry_id IS NULL AND voided_at IS NULL AND cost_fix_entry_id IS NULL)::int AS cm_products,
  COUNT(*) FILTER (WHERE type = 'sale' AND cost_missing AND reverses_entry_id IS NULL AND voided_at IS NULL AND cost_fix_entry_id IS NULL)::int AS cm_sales,
  COUNT(*) FILTER (WHERE type = 'count' AND cost_missing AND reverses_entry_id IS NULL AND voided_at IS NULL)::int AS lm_count,
  COUNT(*) FILTER (WHERE type = 'expire_loss' AND cost_missing AND reverses_entry_id IS NULL AND voided_at IS NULL)::int AS lm_expire_loss,
  COUNT(*) FILTER (WHERE type = 'supplier_return' AND cost_missing AND reverses_entry_id IS NULL AND voided_at IS NULL)::int AS lm_supplier_return`;

type TotalsRow = Record<string, string | number>;

function toTotals(r: TotalsRow): Totals {
  const n = (k: string) => int(r[k] as string);
  return {
    sold: n("sold"),
    profit: n("profit"),
    discount: n("discount"),
    expireLoss: n("expire_loss"),
    value: {
      sale: n("v_sale"),
      stock_in: n("v_stock_in"),
      opening: n("v_opening"),
      count: n("v_count"),
      cost_adjust: n("v_cost_adjust"),
      cost_fix: n("v_cost_fix"),
      expire_loss: n("v_expire_loss"),
      supplier_return: n("v_supplier_return"),
    },
    costMissingProducts: Number(r.cm_products),
    costMissingSales: Number(r.cm_sales),
    lossMissing: { count: Number(r.lm_count), expire_loss: Number(r.lm_expire_loss), supplier_return: Number(r.lm_supplier_return) },
  };
}

export async function totals(db: Q, storeId: string, from: Bound, to: Bound): Promise<Totals> {
  const r = await sql<TotalsRow>`SELECT ${TOTALS_SELECT} FROM entries
    WHERE store_id = ${storeId} AND occurred_at >= ${from} AND occurred_at < ${to}`.execute(db);
  return toTotals(r.rows[0]!);
}

/** 按上海日期分组的合计（只返回有流水的日子） */
export async function totalsByDay(db: Q, storeId: string, from: Bound, to: Bound): Promise<Map<string, Totals>> {
  const r = await sql<TotalsRow & { day: string }>`SELECT ${DAY_OF_SQL} AS day, ${TOTALS_SELECT}
    FROM entries WHERE store_id = ${storeId} AND occurred_at >= ${from} AND occurred_at < ${to}
    GROUP BY 1`.execute(db);
  return new Map(r.rows.map((row) => [row.day, toTotals(row)]));
}

/** 某一时刻之前（不含）全部流水的 value_delta 之和 = 那一刻的店里货值（I2 对全部商品求和） */
export async function stockValueBefore(db: Q, storeId: string, t: Bound): Promise<number> {
  const r = await sql<{ v: string }>`SELECT COALESCE(SUM(value_delta_fen), 0)::text AS v FROM entries
    WHERE store_id = ${storeId} AND occurred_at < ${t}`.execute(db);
  return int(r.rows[0]!.v);
}

/**
 * 「笔数」：一次记账操作算一笔 = 这段时间里原行（非冲销行）的不同 op 个数，不算系统生成的 cost_adjust。
 * 一笔卖出（一个 sale_batch）算一笔；撤销本身只产生冲销行和 cost_adjust，不算一笔；补全产生的 opening + cost_fix 同属一个 op，算一笔。
 */
export const RECORD_COUNT_SQL = sql`COUNT(DISTINCT op_id) FILTER (WHERE reverses_entry_id IS NULL AND type <> 'cost_adjust')::int`;

/** 报表的读一律在一个可重复读的只读事务里：月初货值、各行、月末货值看到同一份快照，等式不会被并发写入打破 */
export function readSnapshot<T>(db: Kysely<Database>, fn: (trx: Transaction<Database>) => Promise<T>): Promise<T> {
  return db.transaction().setIsolationLevel("repeatable read").setAccessMode("read only").execute(fn);
}
