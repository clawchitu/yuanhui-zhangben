// 本月的账（设计稿 10，§5.3）：三张卡、优惠和过期损耗、每日柱状图、对账各行。
// 对账：月初货值 + Σ rows = 月末货值，每一项都是本月 entries.value_delta_fen 按类型分组求和；
// 月初货值 = 本月第一刻之前全部流水的 value_delta 之和，所以跨月撤销（冲销行落在撤销那个月）不会改动上月的任何数字。
import type { Kysely } from "kysely";
import type { Database } from "../db.ts";
import { addDay, dayStart, nextMonth, readSnapshot, type Q, stockValueBefore, today, totals, totalsByDay } from "./common.ts";

export type ReconKey = "stock_in" | "sale" | "count" | "expire_loss" | "supplier_return" | "opening_and_adjust";

export interface ReportMonth {
  month: string;
  sold_fen: number;
  profit_fen: number;
  stock_value_end_fen: number;
  discount_fen: number;
  expire_loss_fen: number;
  cost_missing_count: number;
  loss_cost_missing_count: number;
  daily: Array<{ date: string; sold_fen: number; profit_fen: number }>;
  reconciliation: {
    stock_value_start_fen: number;
    rows: Array<{ key: ReconKey; amount_fen: number; cost_missing_count: number }>;
    stock_value_end_fen: number;
  };
}

/**
 * month：YYYY-MM（上海）。now：服务器时间，决定柱状图画到哪一天（本月画到今天，过去的月份画满，将来的月份为空）。
 * 月末货值一律 = 下月第一刻之前全部流水的 value_delta 之和（§14 S07-4），本月也一样，不说「本月 = 现在」：
 * 时钟超前 5 分钟以内又跨月的流水（§4.4）算在下个月，那几分钟里本月月末比商品投影少这一笔；本月月末 = 下月月初照样成立。
 */
export async function reportMonth(db: Kysely<Database>, storeId: string, month: string, now: Date): Promise<ReportMonth> {
  return readSnapshot(db, (trx) => reportMonthIn(trx, storeId, month, now));
}

/** 同上，在调用方给的事务（快照）里算。注销导出包在同一个快照里导流水和月报，两边的合计一定对得上（S09） */
export async function reportMonthIn(trx: Q, storeId: string, month: string, now: Date): Promise<ReportMonth> {
  const firstDay = `${month}-01`;
  const nextFirst = `${nextMonth(month)}-01`;
  const from = dayStart(firstDay);
  const to = dayStart(nextFirst);
  {
    const start = await stockValueBefore(trx, storeId, from);
    const t = await totals(trx, storeId, from, to);
    const byDay = await totalsByDay(trx, storeId, from, to);

    const v = t.value;
    const rows: ReportMonth["reconciliation"]["rows"] = [
      { key: "stock_in", amount_fen: v.stock_in, cost_missing_count: 0 },
      { key: "sale", amount_fen: v.sale, cost_missing_count: t.costMissingSales },
      { key: "count", amount_fen: v.count, cost_missing_count: t.lossMissing.count },
      { key: "expire_loss", amount_fen: v.expire_loss, cost_missing_count: t.lossMissing.expire_loss },
      { key: "supplier_return", amount_fen: v.supplier_return, cost_missing_count: t.lossMissing.supplier_return },
    ];
    // 期初登记和调整：非零才显示（§5.3）
    const openingAndAdjust = v.opening + v.cost_adjust;
    if (openingAndAdjust !== 0) rows.push({ key: "opening_and_adjust", amount_fen: openingAndAdjust, cost_missing_count: 0 });
    // cost_fix 行的 value_delta 恒为 0（§3.3），不单列；这里断言它，万一不是 0 就宁可报错也不出一张对不上的账
    if (v.cost_fix !== 0) throw new Error(`cost_fix 行的 value_delta 之和不是 0：${v.cost_fix}`);
    const end = start + rows.reduce((s, r) => s + r.amount_fen, 0);
    if (!Number.isSafeInteger(end)) throw new Error("月末货值超出安全整数范围");

    // 柱状图：本月 1 号到今天（过去的月份到月末），没有流水的日子补 0。
    // 与月合计用同一个归日口径（同一条 SQL、同一个时间段）：时钟超前 5 分钟以内又跨零点的流水落在「明天」，
    // 柱状图就画到那一天，每日之和恒等于月合计（Codex 第一轮 2，§14 S07-5）。
    const todayStr = today(now);
    const lastDay = addDay(nextFirst, -1);
    let until = todayStr < lastDay ? todayStr : lastDay;
    for (const d of byDay.keys()) if (d > until) until = d;
    const daily: ReportMonth["daily"] = [];
    for (let d = firstDay; d <= until; d = addDay(d, 1)) {
      const x = byDay.get(d);
      daily.push({ date: d, sold_fen: x?.sold ?? 0, profit_fen: x?.profit ?? 0 });
    }

    return {
      month,
      sold_fen: t.sold,
      profit_fen: t.profit,
      stock_value_end_fen: end,
      discount_fen: t.discount,
      expire_loss_fen: t.expireLoss,
      cost_missing_count: t.costMissingProducts,
      loss_cost_missing_count: t.lossMissing.count + t.lossMissing.expire_loss + t.lossMissing.supplier_return,
      daily,
      reconciliation: { stock_value_start_fen: start, rows, stock_value_end_fen: end },
    };
  }
}
