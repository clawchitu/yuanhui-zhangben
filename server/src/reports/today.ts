// 今天的账（设计稿 09，§5.3）：卖了、赚了、优惠、笔数、卖得最好、快没货、快过期。
// 前四项只由所选那一天（上海时间）的流水求和；「快没货」「快过期」是店里现在的状态，与所选日期无关，按服务器的今天算。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { int } from "../sync/projection.ts";
import { shouldRemind } from "../ledger/lots.ts";
import { RECORD_COUNT_SQL, addDay, dayStart, readSnapshot, today, totals, type Bound, type Q } from "./common.ts";

/** 卖得最好：设计稿 09 列 3 个 */
export const TOP_SELLERS = 3;

export interface ProductAmount {
  product_id: string;
  name: string;
  qty?: number;
  amount_fen?: number;
  expiry_date?: string;
}

export interface ReportToday {
  date: string;
  sold_fen: number;
  profit_fen: number;
  discount_fen: number;
  count: number;
  cost_missing_count: number;
  loss_cost_missing_count: number;
  top_sellers: ProductAmount[];
  low_stock: ProductAmount[];
  expiring: ProductAmount[];
}

/** 卖得最好：按卖出个数（基本单位，Σ −qty_delta，含冲销行，所以当天撤掉的不算），并列时按金额、再按商品 id */
async function topSellers(db: Q, storeId: string, from: Bound, to: Bound): Promise<ProductAmount[]> {
  const r = await sql<{ product_id: string; name: string; qty: string; amount: string }>`
    SELECT e.product_id, p.name, (-SUM(e.qty_delta))::text AS qty, SUM(e.amount_fen)::text AS amount
    FROM entries e JOIN products p ON p.store_id = e.store_id AND p.id = e.product_id
    WHERE e.store_id = ${storeId} AND e.type = 'sale' AND e.occurred_at >= ${from} AND e.occurred_at < ${to}
    GROUP BY e.product_id, p.name
    HAVING -SUM(e.qty_delta) > 0
    ORDER BY -SUM(e.qty_delta) DESC, SUM(e.amount_fen) DESC, e.product_id
    LIMIT ${TOP_SELLERS}`.execute(db);
  return r.rows.map((x) => ({ product_id: x.product_id, name: x.name, qty: int(x.qty), amount_fen: int(x.amount) }));
}

/**
 * 快没货：没停用、库存动过（stock_ver > 0，从没进过货也没卖过的新登记商品不算）、库存 ≤ 提醒线
 * （商品自己的 low_at，没设就用店里的 low_stock_default）。按库存从少到多。
 */
async function lowStock(db: Q, storeId: string): Promise<ProductAmount[]> {
  const r = await sql<{ id: string; name: string; stock_qty: number }>`
    SELECT p.id, p.name, p.stock_qty FROM products p JOIN stores s ON s.id = p.store_id
    WHERE p.store_id = ${storeId} AND p.archived_at IS NULL AND p.stock_ver > 0
      AND p.stock_qty <= COALESCE(p.low_at, s.low_stock_default)
    ORDER BY p.stock_qty, p.name, p.id`.execute(db);
  return r.rows.map((x) => ({ product_id: x.id, name: x.name, qty: x.stock_qty }));
}

/** 快过期：§5.4 的提醒规则（shouldRemind），按商品合并：qty = 该商品要提醒的批次剩余数之和，expiry_date = 其中最早的到期日 */
async function expiring(db: Q, storeId: string, todayStr: string): Promise<ProductAmount[]> {
  const r = await sql<{ product_id: string; name: string; expiry_date: string; expiry_warn_days: number; qty_left: number; snoozed_until: string | null }>`
    SELECT l.product_id, p.name, to_char(l.expiry_date, 'YYYY-MM-DD') AS expiry_date, p.expiry_warn_days, l.qty_left,
           to_char(l.snoozed_until, 'YYYY-MM-DD') AS snoozed_until
    FROM stock_lots l JOIN products p ON p.store_id = l.store_id AND p.id = l.product_id
    WHERE l.store_id = ${storeId} AND l.closed_at IS NULL AND l.qty_left > 0 AND l.expiry_date IS NOT NULL AND p.archived_at IS NULL`.execute(db);
  const by = new Map<string, ProductAmount & { qty: number; expiry_date: string }>();
  for (const l of r.rows) {
    if (!shouldRemind(todayStr, { ...l, closed: false })) continue;
    const cur = by.get(l.product_id);
    if (!cur) by.set(l.product_id, { product_id: l.product_id, name: l.name, qty: l.qty_left, expiry_date: l.expiry_date });
    else {
      cur.qty += l.qty_left;
      if (l.expiry_date < cur.expiry_date) cur.expiry_date = l.expiry_date;
    }
  }
  return [...by.values()].sort((a, b) => (a.expiry_date < b.expiry_date ? -1 : a.expiry_date > b.expiry_date ? 1 : a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

export async function reportToday(db: Kysely<Database>, storeId: string, date: string, now: Date): Promise<ReportToday> {
  const from = dayStart(date);
  const to = dayStart(addDay(date, 1));
  return readSnapshot(db, async (trx) => {
    const t = await totals(trx, storeId, from, to);
    const c = await sql<{ n: number }>`SELECT ${RECORD_COUNT_SQL} AS n FROM entries
      WHERE store_id = ${storeId} AND occurred_at >= ${from} AND occurred_at < ${to}`.execute(trx);
    return {
      date,
      sold_fen: t.sold,
      profit_fen: t.profit,
      discount_fen: t.discount,
      count: Number(c.rows[0]!.n),
      cost_missing_count: t.costMissingProducts,
      loss_cost_missing_count: t.lossMissing.count + t.lossMissing.expire_loss + t.lossMissing.supplier_return,
      top_sellers: await topSellers(trx, storeId, from, to),
      low_stock: await lowStock(trx, storeId),
      expiring: await expiring(trx, storeId, today(now)),
    };
  });
}
