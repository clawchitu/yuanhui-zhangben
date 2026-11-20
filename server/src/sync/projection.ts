// 按角色裁剪（§4.2「在 sync/projection.ts 一处实现」、§3.4、§6 第②条）。
// 一律用白名单挑键：收银员的响应里被裁的键根本不出现（不是置空）。行的形状对应契约 openapi.yaml 的
// Product / ProductBarcode / Removed / Entry / SaleBatch / StockLot。
//
// 收银员（scope = cashier_projection）拿不到：product_private 的任何字段（库存、货值、进价、low_at、保质期设置、盘点时间），
// 任何进货 / 盘点 / 损耗流水（只有卖出），别的手机的流水，保质期批次，cogs_fen / value_delta_fen / unit_cost_fen / cost_missing。
import type { Selectable } from "kysely";
import type { Database } from "../db.ts";

export type Scope = "full_store" | "cashier_projection";
export const SCOPES: readonly Scope[] = ["full_store", "cashier_projection"];

/** 手机本地保留多少天的流水（§3.4）：家用 35 天全店；收银员 2 天、只有本机的卖出。按上海时区的日历日算，含今天。 */
export const LEDGER_DAYS: Record<Scope, number> = { full_store: 35, cashier_projection: 2 };

type Row<T extends keyof Database> = Selectable<Database[T]>;

/** int8 列（pg 返回字符串）→ JSON 数字；超出安全整数范围就报错，绝不悄悄丢精度 */
export function int(v: string | number | bigint): number {
  const n = Number(v);
  if (!Number.isSafeInteger(n)) throw new Error(`整数超出 JSON 安全范围：${String(v)}`);
  return n;
}
const intOrNull = (v: string | number | null) => (v === null ? null : int(v));
const iso = (d: Date) => d.toISOString();
const isoOrNull = (d: Date | null) => (d === null ? null : d.toISOString());

export function productOut(p: Row<"products">, scope: Scope) {
  const pub = {
    id: p.id,
    name: p.name,
    base_unit: p.base_unit,
    price_fen: int(p.price_fen),
    needs_review: p.needs_review,
    track_expiry: p.track_expiry,
    image_ver: p.image_ver,
    archived: p.archived_at !== null,
    rev: int(p.rev),
  };
  if (scope === "cashier_projection") return pub;
  return {
    ...pub,
    private: {
      stock_qty: p.stock_qty,
      stock_value_fen: int(p.stock_value_fen),
      last_cost_fen: intOrNull(p.last_cost_fen),
      cost_known: p.cost_known,
      stock_ver: int(p.stock_ver),
      low_at: p.low_at,
      expiry_warn_days: p.expiry_warn_days,
      shelf_life_months: p.shelf_life_months,
      last_count_at: isoOrNull(p.last_count_at),
    },
  };
}

/** 单件码没有 pack_price_fen 这个键；整件码没带价时也没有（整件价 = 单件卖价 × 换算） */
export function barcodeOut(b: Row<"product_barcodes">) {
  return {
    barcode: b.barcode,
    product_id: b.product_id,
    pack_qty: b.pack_qty,
    unit_name: b.unit_name,
    ...(b.pack_price_fen !== null && b.pack_qty > 1 ? { pack_price_fen: int(b.pack_price_fen) } : {}),
    rev: int(b.rev),
  };
}

export function removedOut(r: Row<"removed">) {
  return { kind: r.kind, row_id: r.row_id, rev: int(r.rev) };
}

export function entryOut(e: Row<"entries"> & { device_label: string | null }, scope: Scope) {
  const common = {
    id: e.id,
    seq: int(e.seq),
    op_id: e.op_id,
    batch_id: e.batch_id,
    type: e.type,
    reverses_entry_id: e.reverses_entry_id,
    product_id: e.product_id,
    barcode: e.barcode,
    name_snapshot: e.name_snapshot,
    unit_name: e.unit_name,
    pack_qty: e.pack_qty,
    pack_count: e.pack_count,
    qty_delta: e.qty_delta,
    list_amount_fen: int(e.list_amount_fen),
    amount_fen: int(e.amount_fen),
    device_id: e.device_id,
    ...(e.device_label !== null ? { device_label: e.device_label } : {}),
    occurred_at: iso(e.occurred_at),
    received_at: iso(e.received_at),
    voided_at: isoOrNull(e.voided_at),
    rev: int(e.rev),
  };
  if (scope === "cashier_projection") {
    // flags 里只留和卖出本身有关的标记（qty_left_before 等批次信息不给）
    const f = (e.flags ?? {}) as Record<string, unknown>;
    const flags = Object.fromEntries(
      (["clock_adjusted", "late_from_revoked", "recovered"] as const).filter((k) => f[k] !== undefined).map((k) => [k, f[k]]),
    );
    return { ...common, flags };
  }
  return {
    ...common,
    unit_cost_fen: intOrNull(e.unit_cost_fen),
    cogs_fen: int(e.cogs_fen),
    value_delta_fen: int(e.value_delta_fen),
    cost_missing: e.cost_missing,
    expiry_date: e.expiry_date,
    cost_fix_entry_id: e.cost_fix_entry_id,
    flags: e.flags ?? {},
  };
}

export function batchOut(b: Row<"sale_batches">) {
  return {
    id: b.id,
    device_id: b.device_id,
    list_total_fen: int(b.list_total_fen),
    paid_total_fen: int(b.paid_total_fen),
    occurred_at: iso(b.occurred_at),
    received_at: iso(b.received_at),
    rev: int(b.rev),
  };
}

/** 只发给家用 / 审核（收银员根本不查这张表） */
export function lotOut(l: Row<"stock_lots">) {
  return {
    id: l.id,
    product_id: l.product_id,
    source_entry_id: l.source_entry_id,
    expiry_date: l.expiry_date,
    qty_in: l.qty_in,
    qty_left: l.qty_left,
    snoozed_until: l.snoozed_until,
    closed_at: isoOrNull(l.closed_at),
    closed_reason: l.closed_reason,
    handle_ver: l.handle_ver,
    rev: int(l.rev),
  };
}
