// 报表测试辅助：经 /v1/sync 造账、调报表接口、按 §5.3 的定义从流水表独立重算（JS 逐行求和，不复用 src/reports 的 SQL）。
import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { expect } from "vitest";
import type { TestDb } from "./db.ts";
import { bearer } from "./auth.ts";
import { expectContract, op, syncOk, type Op } from "./sync.ts";

export const SH = (local: string) => `${local}+08:00`;

export function shopIO(app: FastifyInstance, token: string, epoch: string) {
  const send = async (...ops: Op[]) => {
    const r = (await syncOk(app, token, { epoch, ops, pull: false })).results as Array<{ id: string; status: string; code?: string }>;
    for (const x of r) expect(x.status, JSON.stringify(x)).toBe("applied");
    return r;
  };
  const get = async (url: string, schema?: string) => {
    const res = await app.inject({ method: "GET", url, headers: bearer(token) });
    expect(res.statusCode, res.body).toBe(200);
    const body = res.json();
    if (schema) await expectContract(schema, body);
    return body;
  };
  return { send, get };
}

export function saleOp(lines: Array<{ pid: string; n: number; price: number; barcode?: string }>, at: string, discount = 0) {
  const ls = lines.map((l) => ({
    entry_id: randomUUID(),
    product_id: l.pid,
    barcode: l.barcode ?? "6900000000001",
    name: "x",
    unit_name: "个",
    pack_qty: 1,
    pack_count: l.n,
    unit_price_fen: l.price,
  }));
  const list = ls.reduce((s, l) => s + l.unit_price_fen * l.pack_count, 0);
  const batch_id = randomUUID();
  return { batch_id, entryIds: ls.map((l) => l.entry_id), op: op("sale_batch", { batch_id, paid_total_fen: list - discount, lines: ls }, { at }) };
}
export const stockInOp = (pid: string, n: number, unit: number, at: string, expiry?: string) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit, ...(expiry ? { expiry_date: expiry } : {}) }, { at });
export const voidOp = (target: { entry_id: string } | { batch_id: string }, at: string) => op("void", { target }, { at });

type E = Awaited<ReturnType<typeof allEntries>>[number];
export const allEntries = (tdb: TestDb, storeId: string) =>
  tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).orderBy("seq").execute();

const shDay = (d: Date) => new Date(d.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
const N = (v: string | number) => Number(v);

/** §5.3 的定义，逐行在 JS 里重算一个时间段（按上海日期字符串前缀筛：'2026-11' 是一个月，'2026-11-05' 是一天） */
export function recompute(es: E[], prefix: string) {
  const inside = es.filter((e) => shDay(e.occurred_at).startsWith(prefix));
  const before = es.filter((e) => shDay(e.occurred_at).slice(0, prefix.length) < prefix);
  const sum = (rows: E[], f: (e: E) => number) => rows.reduce((s, e) => s + f(e), 0);
  const val = (t: string) => sum(inside.filter((e) => e.type === t), (e) => N(e.value_delta_fen));
  const pendingSale = inside.filter((e) => e.type === "sale" && e.cost_missing && e.reverses_entry_id === null && e.voided_at === null && e.cost_fix_entry_id === null);
  const lossMissing = (t: string) => inside.filter((e) => e.type === t && e.cost_missing && e.reverses_entry_id === null && e.voided_at === null).length;
  const start = sum(before, (e) => N(e.value_delta_fen));
  return {
    start,
    end: start + sum(inside, (e) => N(e.value_delta_fen)),
    sold: sum(inside.filter((e) => e.type === "sale"), (e) => N(e.amount_fen)),
    profit: sum(inside.filter((e) => (e.type === "sale" && !e.cost_missing) || e.type === "cost_fix"), (e) => N(e.amount_fen) - N(e.cogs_fen)),
    discount: sum(inside.filter((e) => e.type === "sale"), (e) => N(e.list_amount_fen) - N(e.amount_fen)),
    expireLoss: sum(inside.filter((e) => e.type === "expire_loss"), (e) => N(e.cogs_fen)),
    value: { stock_in: val("stock_in"), sale: val("sale"), count: val("count"), expire_loss: val("expire_loss"), supplier_return: val("supplier_return"), opening_and_adjust: val("opening") + val("cost_adjust") },
    costMissingProducts: new Set(pendingSale.map((e) => e.product_id)).size,
    costMissingSales: pendingSale.length,
    lossMissing: { count: lossMissing("count"), expire_loss: lossMissing("expire_loss"), supplier_return: lossMissing("supplier_return") },
    records: new Set(inside.filter((e) => e.reverses_entry_id === null && e.type !== "cost_adjust").map((e) => e.op_id)).size,
    days: [...new Set(inside.map((e) => shDay(e.occurred_at)))].sort(),
    dayOf: shDay,
  };
}

/** 报表 JSON 与重算结果逐项比对 */
export function expectMonthMatches(rep: any, r: ReturnType<typeof recompute>) {
  const rows: Record<string, { amount_fen: number; cost_missing_count: number }> = Object.fromEntries(rep.reconciliation.rows.map((x: any) => [x.key, x]));
  expect([rep.sold_fen, rep.profit_fen, rep.discount_fen, rep.expire_loss_fen, rep.cost_missing_count, rep.loss_cost_missing_count]).toEqual([
    r.sold, r.profit, r.discount, r.expireLoss, r.costMissingProducts, r.lossMissing.count + r.lossMissing.expire_loss + r.lossMissing.supplier_return,
  ]);
  expect([rep.reconciliation.stock_value_start_fen, rep.reconciliation.stock_value_end_fen, rep.stock_value_end_fen]).toEqual([r.start, r.end, r.end]);
  for (const k of ["stock_in", "sale", "count", "expire_loss", "supplier_return"] as const) expect(rows[k]!.amount_fen, k).toBe(r.value[k]);
  if (r.value.opening_and_adjust === 0) expect(rows.opening_and_adjust).toBeUndefined();
  else expect(rows.opening_and_adjust!.amount_fen).toBe(r.value.opening_and_adjust);
  expect([rows.sale!.cost_missing_count, rows.count!.cost_missing_count, rows.expire_loss!.cost_missing_count, rows.supplier_return!.cost_missing_count, rows.stock_in!.cost_missing_count]).toEqual([
    r.costMissingSales, r.lossMissing.count, r.lossMissing.expire_loss, r.lossMissing.supplier_return, 0,
  ]);
  // 对账等式逐分成立
  expect(rep.reconciliation.stock_value_start_fen + rep.reconciliation.rows.reduce((s: number, x: any) => s + x.amount_fen, 0)).toBe(rep.reconciliation.stock_value_end_fen);
}
