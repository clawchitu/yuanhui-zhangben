// 记的账（设计稿 07a、07c）：某一天的流水；更早的日子每天一行。
// 列表不含冲销行（§3.3：冲销行只用于报表求和），原行带 voided_at；「撤销算在哪天」只用 voided_at = 冲销行 occurred_at 这一个口径（§14 S05-13）。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { batchOut, entryOut, int } from "../sync/projection.ts";
import { RECORD_COUNT_SQL, addDay, dayStart, readSnapshot } from "./common.ts";

export async function entriesOfDay(db: Kysely<Database>, storeId: string, date: string) {
  const from = dayStart(date);
  const to = dayStart(addDay(date, 1));
  return readSnapshot(db, async (trx) => {
    const rows = await trx
      .selectFrom("entries as e")
      .leftJoin("devices as d", (j) => j.onRef("d.store_id", "=", "e.store_id").onRef("d.id", "=", "e.device_id"))
      .selectAll("e")
      .select("d.label as device_label")
      .where("e.store_id", "=", storeId)
      .where("e.reverses_entry_id", "is", null)
      .where("e.occurred_at", ">=", from)
      .where("e.occurred_at", "<", to)
      .orderBy("e.occurred_at")
      .orderBy("e.seq")
      .execute();
    const batches = await trx
      .selectFrom("sale_batches")
      .selectAll()
      .where("store_id", "=", storeId)
      .where("occurred_at", ">=", from)
      .where("occurred_at", "<", to)
      .orderBy("occurred_at")
      .orderBy("id")
      .execute();
    return { date, entries: rows.map((e) => entryOut(e, "full_store")), batches: batches.map(batchOut) };
  });
}

/**
 * 07c：before（不含）之前有流水的日子，从近到远，最多 limit 天。
 * count = 笔数（RECORD_COUNT_SQL），amount_fen = 那天的「卖了」（卖出行含冲销行的 amount 之和，与日报 sold_fen 同一口径）。
 * 只有冲销行的日子（比如那天只撤销了前一天的卖出）也列出，count 为 0、amount 为负，免得那天的钱在列表里消失。
 * 翻页：下一页的 before = 本页最后一天。
 */
export async function entryDays(db: Kysely<Database>, storeId: string, before: string, limit: number) {
  const to = dayStart(before);
  const r = await sql<{ day: string; n: number; amount: string }>`
    SELECT to_char((occurred_at AT TIME ZONE 'Asia/Shanghai')::date, 'YYYY-MM-DD') AS day,
           ${RECORD_COUNT_SQL} AS n,
           COALESCE(SUM(amount_fen) FILTER (WHERE type = 'sale'), 0)::text AS amount
    FROM entries WHERE store_id = ${storeId} AND occurred_at < ${to}
    GROUP BY 1 ORDER BY 1 DESC LIMIT ${limit}`.execute(db);
  return { days: r.rows.map((x) => ({ date: x.day, count: Number(x.n), amount_fen: int(x.amount) })) };
}
