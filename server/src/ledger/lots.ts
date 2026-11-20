// 保质期批次（§5.4，只管提醒，不参与成本）。上半部分是纯算法（contracts/vectors/expiry.json），
// 下半部分是写库：进货 / 期初建批次，卖出 / 盘亏按到期日扣批次写 lot_moves，撤销时按 §5.4 生命周期表处理，
// 以及 expiry_dispose / lot_snooze 两种 op。调用方都已在店铺锁内（StoreTx）。
// 每改一行批次取一个新号（rev）。handle_ver 只在「处理」和「过几天再提醒」时 +1，普通卖出扣批次不改它。
import { randomUUID } from "node:crypto";
import type { Selectable } from "kysely";
import type { Database } from "../db.ts";
import type { StoreTx } from "../sync/lock.ts";
import { shanghaiDay } from "../auth/guard.ts";
import { Remap } from "../sync/aliases.ts";
import type { Outcome } from "../sync/catalog.ts";
import { removeStock } from "./cost.ts";
import { bad, entryFree, guarded, loadProduct, stateOf, writeStep, type LedgerContext } from "./apply.ts";

// ── 纯算法 ──

const DAY_MS = 86_400_000;
const pad = (n: number, w = 2) => String(n).padStart(w, "0");
const parseDay = (d: string) => {
  const [y, m, dd] = d.split("-").map(Number) as [number, number, number];
  return { y, m, d: dd };
};
const fmt = (y: number, m: number, d: number) => `${pad(y, 4)}-${pad(m)}-${pad(d)}`;

/** 日期加整月，按日历月，月末对齐（1/31 + 1 个月 = 2/28 或 2/29） */
export function addMonths(day: string, months: number): string {
  const { y, m, d } = parseDay(day);
  const idx = y * 12 + (m - 1) + months;
  const ny = Math.floor(idx / 12);
  const nm = (idx % 12) + 1;
  const last = new Date(Date.UTC(ny, nm, 0)).getUTCDate();
  return fmt(ny, nm, Math.min(d, last));
}

/** 日期加天数（可为负） */
export function addDays(day: string, days: number): string {
  const { y, m, d } = parseDay(day);
  const t = new Date(Date.UTC(y, m - 1, d) + days * DAY_MS);
  return fmt(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}

export interface RemindLot {
  expiry_date: string | null;
  expiry_warn_days: number;
  qty_left: number;
  closed: boolean;
  snoozed_until: string | null;
}

/** 提醒（§5.4）：今天 >= 到期日 − 提前天数，未关闭、qty_left > 0、不在「过几天再提醒」期内（今天 < snoozed_until 才算在期内） */
export function shouldRemind(today: string, l: RemindLot): boolean {
  if (l.expiry_date === null || l.closed || l.qty_left <= 0) return false;
  if (l.snoozed_until !== null && today < l.snoozed_until) return false;
  return today >= addDays(l.expiry_date, -l.expiry_warn_days);
}

export interface DeductLot<I> {
  id: I;
  expiry_date: string | null;
  qty_left: number;
  closed: boolean;
  /** 来源流水的 seq：到期日相同时先扣先建的 */
  seq: bigint;
}

/** 扣批次（§5.4）：到期日从早到晚（空日期最后），同日按来源 seq；已关闭、qty_left = 0 的跳过；扣不完的不归任何批次 */
export function planDeduct<I>(lots: DeductLot<I>[], qty: number): { moves: Array<{ id: I; qty: number }>; unassigned: number } {
  const order = lots
    .filter((l) => !l.closed && l.qty_left > 0)
    .sort((a, b) => {
      if (a.expiry_date !== b.expiry_date) {
        if (a.expiry_date === null) return 1;
        if (b.expiry_date === null) return -1;
        return a.expiry_date < b.expiry_date ? -1 : 1;
      }
      return a.seq < b.seq ? -1 : a.seq > b.seq ? 1 : 0;
    });
  const moves: Array<{ id: I; qty: number }> = [];
  let left = qty;
  for (const l of order) {
    if (left <= 0) break;
    const take = Math.min(left, l.qty_left);
    moves.push({ id: l.id, qty: take });
    left -= take;
  }
  return { moves, unassigned: Math.max(left, 0) };
}

/** 防两台手机各处理一次（§5.4）：批次已关闭或版本不一致 → stale；否则接受，handle_ver + 1 */
export function checkHandle(lot: { handle_ver: number; closed: boolean }, opVer: number): { result: "ok"; new_handle_ver: number } | { result: "stale" } {
  if (lot.closed || lot.handle_ver !== opVer) return { result: "stale" };
  return { result: "ok", new_handle_ver: lot.handle_ver + 1 };
}

// ── 写库 ──

type LotRow = Selectable<Database["stock_lots"]>;
type EntryRow = Selectable<Database["entries"]>;
type ProductRow = Selectable<Database["products"]>;

const lotsOf = (tx: StoreTx) => tx.trx.selectFrom("stock_lots").where("store_id", "=", tx.storeId);

/** 管保质期的商品，每次进货 / 期初生成一个批次（没填到期日也生成，expiry_date = null，不提醒） */
export async function createLot(tx: StoreTx, prod: ProductRow, sourceEntryId: string, qty: number, expiryDate: string | null) {
  if (!prod.track_expiry) return;
  await tx.trx
    .insertInto("stock_lots")
    .values({
      id: randomUUID(),
      store_id: tx.storeId,
      product_id: prod.id,
      source_entry_id: sourceEntryId.toLowerCase(),
      expiry_date: expiryDate,
      qty_in: qty,
      qty_left: qty,
      rev: await tx.nextRev(),
    } as never)
    .execute();
}

/** 卖出、盘亏按到期日扣批次，写 lot_moves（不改 handle_ver） */
export async function deductLots(tx: StoreTx, productId: string, entryId: string, qty: number) {
  if (qty <= 0) return;
  const open = await tx.trx
    .selectFrom("stock_lots as l")
    .innerJoin("entries as e", (j) => j.onRef("e.store_id", "=", "l.store_id").onRef("e.id", "=", "l.source_entry_id"))
    .select(["l.id", "l.expiry_date", "l.qty_left", "e.seq"])
    .where("l.store_id", "=", tx.storeId)
    .where("l.product_id", "=", productId)
    .where("l.closed_at", "is", null)
    .where("l.qty_left", ">", 0)
    .execute();
  const plan = planDeduct(
    open.map((l) => ({ id: l.id, expiry_date: l.expiry_date as string | null, qty_left: l.qty_left, closed: false, seq: BigInt(l.seq) })),
    qty,
  );
  for (const m of plan.moves) {
    await tx.trx.insertInto("lot_moves").values({ store_id: tx.storeId, entry_id: entryId.toLowerCase(), lot_id: m.id, qty: m.qty }).execute();
    await tx.trx
      .updateTable("stock_lots")
      .set((eb) => ({ qty_left: eb("qty_left", "-", m.qty) }))
      .set({ rev: await tx.nextRev() } as never)
      .where("store_id", "=", tx.storeId)
      .where("id", "=", m.id)
      .execute();
  }
}

/**
 * 撤销一行流水时的批次动作（§5.4 生命周期表）：
 * - 卖出 / 盘亏：按 lot_moves 原样加回；对应批次已关闭的这部分不加回、也不重开。
 * - 来源进货 / 期初（不论流水类型，按 source_entry_id 找）：这次生成的批次关闭，closed_reason = voided；已扣过的 lot_moves 保留不动。
 * - 扔掉 / 退货：批次重新打开，qty_left 恢复为处理前的值（存在流水 flags 里）。
 */
export async function onVoid(tx: StoreTx, ctx: LedgerContext, e: EntryRow) {
  if (e.type === "sale" || e.type === "count") {
    const moves = await tx.trx.selectFrom("lot_moves").select(["lot_id", "qty"]).where("store_id", "=", tx.storeId).where("entry_id", "=", e.id).execute();
    for (const m of moves) {
      const lot = await lotsOf(tx).select("closed_at").where("id", "=", m.lot_id).executeTakeFirstOrThrow();
      if (lot.closed_at !== null) continue;
      await tx.trx
        .updateTable("stock_lots")
        .set((eb) => ({ qty_left: eb("qty_left", "+", m.qty) }))
        .set({ rev: await tx.nextRev() } as never)
        .where("store_id", "=", tx.storeId)
        .where("id", "=", m.lot_id)
        .execute();
    }
  }
  {
    // 来源流水（进货、期初；没填进价的期初可能记成 count）生成的批次
    const src = await lotsOf(tx).select("id").where("source_entry_id", "=", e.id).where("closed_at", "is", null).execute();
    for (const l of src) {
      await tx.trx
        .updateTable("stock_lots")
        .set({ closed_at: ctx.occurredAt, closed_reason: "voided", rev: await tx.nextRev() } as never)
        .where("store_id", "=", tx.storeId)
        .where("id", "=", l.id)
        .execute();
    }
  }
  if (e.type === "expire_loss" || e.type === "supplier_return") {
    const f = (e.flags ?? {}) as { lot_id?: string; qty_left_before?: number };
    if (typeof f.lot_id === "string" && typeof f.qty_left_before === "number") {
      await tx.trx
        .updateTable("stock_lots")
        .set({ closed_at: null, closed_reason: null, qty_left: f.qty_left_before, rev: await tx.nextRev() } as never)
        .where("store_id", "=", tx.storeId)
        .where("id", "=", f.lot_id)
        .execute();
    }
  }
}

/** 批次已关闭或版本不一致（§5.4、§4.4）：rejected stale，current 带回批次状态 */
function lotStale(l: LotRow): Outcome {
  return { status: "rejected", code: "stale", current: { qty_left: l.qty_left, handle_ver: l.handle_ver, closed: l.closed_at !== null } };
}

async function loadLot(tx: StoreTx, id: string) {
  return lotsOf(tx).selectAll().where("id", "=", id.toLowerCase()).executeTakeFirst();
}

interface DisposePayload {
  lot_id: string;
  handle_ver: number;
  actual_qty: number;
  action: "sold_out" | "discard" | "return";
  entry_id: string;
}

/**
 * 处理快过期（§5.4、20 / 20b）：一律以人数的为准。卖完了 → 关批次、不动库存；扔掉 → expire_loss；退货 → supplier_return；
 * 数量 = actual_qty，成本取法与卖出相同（cost.ts 的 removeStock，按平均进价）。三种都关闭批次（closed_reason = disposed），
 * handle_ver + 1，处理前的 qty_left 和 lot_id 记在流水的 flags 里（撤销时重开用）。批次找不到 → invalid。
 */
export async function applyExpiryDispose(tx: StoreTx, ctx: LedgerContext, p: DisposePayload): Promise<Outcome> {
  return guarded(tx, new Remap(), async () => {
    const lot = (await loadLot(tx, p.lot_id)) ?? bad("批次不存在");
    if (checkHandle({ handle_ver: lot.handle_ver, closed: lot.closed_at !== null }, p.handle_ver).result === "stale") return lotStale(lot);
    if (p.action !== "sold_out") {
      await entryFree(tx, p.entry_id);
      const prod = (await loadProduct(tx, lot.product_id))!;
      const step = removeStock<string>(stateOf(prod), BigInt(p.actual_qty), p.action === "discard" ? "expire_loss" : "supplier_return");
      const flags = { ...ctx.flags, lot_id: lot.id, qty_left_before: lot.qty_left };
      await writeStep(tx, { ...ctx, flags }, prod, { id: p.entry_id, unitName: prod.base_unit, expiryDate: lot.expiry_date as string | null }, step);
    }
    await tx.trx
      .updateTable("stock_lots")
      .set({ closed_at: ctx.occurredAt, closed_reason: "disposed", handle_ver: lot.handle_ver + 1, rev: await tx.nextRev() } as never)
      .where("store_id", "=", tx.storeId)
      .where("id", "=", lot.id)
      .execute();
  });
}

interface SnoozePayload {
  lot_id: string;
  handle_ver: number;
  actual_qty: number;
  days: number;
}

/** 还在卖、过几天再提醒（§5.4）：批次数量改成实际数，snoozed_until = 今天（op 时间的上海日期）+ 天数，handle_ver + 1；不动库存 */
export async function applyLotSnooze(tx: StoreTx, ctx: LedgerContext, p: SnoozePayload): Promise<Outcome> {
  return guarded(tx, new Remap(), async () => {
    const lot = (await loadLot(tx, p.lot_id)) ?? bad("批次不存在");
    if (checkHandle({ handle_ver: lot.handle_ver, closed: lot.closed_at !== null }, p.handle_ver).result === "stale") return lotStale(lot);
    await tx.trx
      .updateTable("stock_lots")
      .set({
        qty_left: p.actual_qty,
        snoozed_until: addDays(shanghaiDay(ctx.occurredAt), p.days),
        handle_ver: lot.handle_ver + 1,
        rev: await tx.nextRev(),
      } as never)
      .where("store_id", "=", tx.storeId)
      .where("id", "=", lot.id)
      .execute();
  });
}
