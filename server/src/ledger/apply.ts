// 记账 op 写库（§5.1、§5.2、§5.6 第 2、3 条，§14 S05-1…S05-4）：sale_batch / stock_in / opening。
// 调用方（push.ts）已拿店铺锁、判过权限和 schema，并先写好 ops 这一行（entries.op_id 外键指向它）。
// 每个 op 在自己的 savepoint「ledger」里写：能在写库前判定的问题（0 件进货、乘积上限、列范围、年份 0000 的 expiry_date、
// entry_id / batch_id 已被占用）抛 LedgerInvalid / CostError / AllocationError → 回滚这个 op 写过的行，rejected invalid 并留档。
// 之后写库时再出 22xxx 不在这里接，由 push.ts 让整个请求 500（§14 S04-14）。
// 每改一行取一个新号；每次库存变动 stock_ver + 1；期初写 last_count_at。同一个 op 产生的流水 seq 连续递增（cost_fix 冲销相邻依赖它）。
import { randomUUID } from "node:crypto";
import { sql, type Selectable } from "kysely";
import type { Database } from "../db.ts";
import type { StoreTx } from "../sync/lock.ts";
import { Remap, resolveProductId } from "../sync/aliases.ts";
import { DEFAULT_BASE_UNIT, type ApplyContext, type Outcome } from "../sync/catalog.ts";
import { allocate, AllocationError, LIMITS } from "./allocation.ts";
import { CostError, opening, sale, stockIn, type CostState, type MissingSale, type Step } from "./cost.ts";

export interface LedgerContext extends ApplyContext {
  opId: string;
  /** op 的 flags（clock_adjusted、late_from_revoked…），照抄到流水上 */
  flags: Record<string, unknown>;
}

export class LedgerInvalid extends Error {}
export function bad(msg: string): never {
  throw new LedgerInvalid(msg);
}

type ProductRow = Selectable<Database["products"]>;

const withRemap = (remap: Remap) => {
  const m = remap.toJSON();
  return m ? { remap: m } : {};
};

/** 一个 op 一个内层 savepoint：可预检查的问题回滚这个 op 写过的行，返回 invalid（push.ts 留档） */
export async function guarded(tx: StoreTx, remap: Remap, fn: () => Promise<Outcome | void>): Promise<Outcome> {
  await sql`SAVEPOINT ledger`.execute(tx.trx);
  try {
    const out = await fn();
    await sql`RELEASE SAVEPOINT ledger`.execute(tx.trx);
    return out ?? { status: "applied", ...withRemap(remap) };
  } catch (e) {
    if (e instanceof LedgerInvalid || e instanceof CostError || e instanceof AllocationError) {
      await sql`ROLLBACK TO SAVEPOINT ledger`.execute(tx.trx);
      await sql`RELEASE SAVEPOINT ledger`.execute(tx.trx);
      return { status: "rejected", code: "invalid", ...withRemap(remap) };
    }
    throw e;
  }
}

export async function loadProduct(tx: StoreTx, id: string) {
  return tx.trx.selectFrom("products").selectAll().where("store_id", "=", tx.storeId).where("id", "=", id).executeTakeFirst();
}

export function stateOf(p: ProductRow): CostState {
  return { q: BigInt(p.stock_qty), v: BigInt(p.stock_value_fen), c: p.last_cost_fen === null ? null : BigInt(p.last_cost_fen), k: p.cost_known };
}

/** 等待成本补记的卖出行（§5.2）：cost_missing、未撤销、未补记、不是冲销行，按应用顺序 */
export async function missingSales(tx: StoreTx, pid: string): Promise<MissingSale<string>[]> {
  const rows = await tx.trx
    .selectFrom("entries")
    .select(["id", "qty_delta", "amount_fen"])
    .where("store_id", "=", tx.storeId)
    .where("product_id", "=", pid)
    .where("type", "=", "sale")
    .where("cost_missing", "=", true)
    .where("voided_at", "is", null)
    .where("cost_fix_entry_id", "is", null)
    .where("reverses_entry_id", "is", null)
    .orderBy("seq")
    .execute();
  return rows.map((r) => ({ ref: r.id, qty: -BigInt(r.qty_delta), amount_fen: BigInt(r.amount_fen) }));
}

async function entryFree(tx: StoreTx, id: string) {
  const e = await tx.trx.selectFrom("entries").select("id").where("store_id", "=", tx.storeId).where("id", "=", id.toLowerCase()).executeTakeFirst();
  if (e) bad(`entry_id ${id} 已被占用`);
}

/** 年份 0000：Postgres 的 date 存不下；op 本身存得下，按 payload 格式不对留档（§14 S05-4） */
function checkExpiry(d: string | undefined) {
  if (d !== undefined && d.startsWith("0000")) bad("expiry_date 年份 0000");
}

async function nextSeq(tx: StoreTx): Promise<bigint> {
  const r = await tx.trx.selectFrom("entries").select((eb) => eb.fn.max("seq").as("m")).where("store_id", "=", tx.storeId).executeTakeFirst();
  return BigInt((r?.m as string | number | null) ?? 0) + 1n;
}

export interface MainRow {
  /** 主流水的 id（op 里给的）；冲销时不给，取新 uuid */
  id?: string;
  /** 冲销行照抄原行的商品名快照；不给就用商品现在的名字 */
  nameSnapshot?: string;
  batchId?: string;
  barcode?: string | null;
  unitName?: string | null;
  packQty?: number | null;
  packCount?: number | null;
  expiryDate?: string | null;
}

/** 把 cost.ts 的一步写进 entries（第一条是主流水），再改商品投影 */
export async function writeStep(tx: StoreTx, ctx: LedgerContext, prod: ProductRow, main: MainRow, step: Step<string>, o: { counted?: boolean } = {}) {
  let seq = await nextSeq(tx);
  for (const [i, d] of step.entries.entries()) {
    const id = i === 0 && main.id !== undefined ? main.id.toLowerCase() : randomUUID();
    await tx.trx
      .insertInto("entries")
      .values({
        id,
        store_id: tx.storeId,
        seq: String(seq++),
        op_id: ctx.opId,
        batch_id: i === 0 ? (main.batchId ?? null) : null,
        type: d.type,
        reverses_entry_id: "reverses" in d ? (d.reverses as string) : null,
        product_id: prod.id,
        barcode: i === 0 ? (main.barcode ?? null) : null,
        name_snapshot: i === 0 ? (main.nameSnapshot ?? prod.name) : prod.name,
        unit_name: i === 0 ? (main.unitName ?? null) : null,
        pack_qty: i === 0 ? (main.packQty ?? null) : null,
        pack_count: i === 0 ? (main.packCount ?? null) : null,
        qty_delta: Number(d.qty_delta),
        list_amount_fen: String(d.list_amount_fen),
        amount_fen: String(d.amount_fen),
        unit_cost_fen: d.unit_cost_fen === null ? null : String(d.unit_cost_fen),
        cogs_fen: String(d.cogs_fen),
        value_delta_fen: String(d.value_delta_fen),
        cost_missing: d.cost_missing,
        expiry_date: i === 0 ? (main.expiryDate ?? null) : null,
        device_id: ctx.deviceId,
        occurred_at: ctx.occurredAt,
        received_at: ctx.now,
        flags: JSON.stringify(ctx.flags),
        rev: await tx.nextRev(),
      } as never)
      .execute();
    if ("covers" in d) {
      for (const c of d.covers as string[]) {
        await tx.trx
          .updateTable("entries")
          .set({ cost_fix_entry_id: id, rev: await tx.nextRev() } as never)
          .where("store_id", "=", tx.storeId)
          .where("id", "=", c)
          .execute();
      }
    }
  }
  const s = step.state;
  await tx.trx
    .updateTable("products")
    .set({
      stock_qty: Number(s.q),
      stock_value_fen: String(s.v),
      last_cost_fen: s.c === null ? null : String(s.c),
      cost_known: s.k,
      stock_ver: sql`stock_ver + 1`,
      ...(o.counted ? { last_count_at: ctx.occurredAt } : {}),
      rev: await tx.nextRev(),
      updated_at: ctx.now,
    } as never)
    .where("store_id", "=", tx.storeId)
    .where("id", "=", prod.id)
    .execute();
}

async function unitNameOf(tx: StoreTx, prod: ProductRow, barcode: string): Promise<string> {
  const b = await tx.trx
    .selectFrom("product_barcodes")
    .select("unit_name")
    .where("store_id", "=", tx.storeId)
    .where("barcode", "=", barcode)
    .where("product_id", "=", prod.id)
    .where("deleted_at", "is", null)
    .executeTakeFirst();
  return b?.unit_name ?? prod.base_unit;
}

interface StockInPayload {
  entry_id: string;
  product_id: string;
  barcode: string;
  pack_qty: number;
  pack_count: number;
  unit_cost_fen: number;
  expiry_date?: string;
}

/** 进货（§5.2）：0 件、乘积超上限、商品不存在 → invalid 留档；进价从没填变已知时当场成本补记（§14 S05-1） */
export async function applyStockIn(tx: StoreTx, ctx: LedgerContext, p: StockInPayload): Promise<Outcome> {
  const remap = new Remap();
  return guarded(tx, remap, async () => {
    checkExpiry(p.expiry_date);
    const packQty = BigInt(p.pack_qty);
    const packCount = BigInt(p.pack_count);
    const unit = BigInt(p.unit_cost_fen);
    if (packCount < 1n) bad("进货 0 件（§14 S05-3）");
    const n = packQty * packCount;
    const T = packCount * unit;
    if (n > LIMITS.maxBaseQty) bad("基本单位数量超上限");
    if (T > LIMITS.maxLineAmountFen) bad("进货总价超上限");
    const prod = (await loadProduct(tx, await resolveProductId(tx, p.product_id, remap))) ?? bad("商品不存在");
    await entryFree(tx, p.entry_id);
    const step = stockIn(stateOf(prod), n, T, unit, await missingSales(tx, prod.id));
    await writeStep(tx, ctx, prod, {
      id: p.entry_id,
      barcode: p.barcode,
      unitName: await unitNameOf(tx, prod, p.barcode),
      packQty: p.pack_qty,
      packCount: p.pack_count,
      expiryDate: p.expiry_date ?? null,
    }, step);
  });
}

interface OpeningPayload {
  entry_id: string;
  product_id: string;
  counted_qty: number;
  unit_cost_fen?: number;
  expiry_date?: string;
  base_ver?: number;
  base_qty?: number;
}

/**
 * 期初（§5.2、§5.6 第 2、3 条，§14 S05-2）：带 base_ver 的比对 stock_ver；不带的只在 stock_ver = 0 时接受，
 * 否则 rejected stale，current 带回最新账面数和版本。没填进价且进价已知时记 count（Q4）。
 */
export async function applyOpening(tx: StoreTx, ctx: LedgerContext, p: OpeningPayload): Promise<Outcome> {
  const remap = new Remap();
  return guarded(tx, remap, async () => {
    checkExpiry(p.expiry_date);
    const prod = (await loadProduct(tx, await resolveProductId(tx, p.product_id, remap))) ?? bad("商品不存在");
    const ver = BigInt(prod.stock_ver);
    if (p.base_ver !== undefined ? ver !== BigInt(p.base_ver) : ver !== 0n) {
      return { status: "rejected", code: "stale", current: { stock_qty: prod.stock_qty, stock_ver: Number(ver) }, ...withRemap(remap) };
    }
    await entryFree(tx, p.entry_id);
    const b = p.unit_cost_fen === undefined ? null : BigInt(p.unit_cost_fen);
    const step = opening(stateOf(prod), BigInt(p.counted_qty), b, await missingSales(tx, prod.id));
    await writeStep(tx, ctx, prod, { id: p.entry_id, unitName: prod.base_unit, expiryDate: p.expiry_date ?? null }, step, { counted: true });
  });
}

interface SaleLine {
  entry_id: string;
  product_id: string;
  barcode: string;
  name: string;
  unit_name: string;
  pack_qty: number;
  pack_count: number;
  unit_price_fen: number;
}
interface SaleBatchPayload {
  batch_id: string;
  paid_total_fen: number;
  lines: SaleLine[];
}

/**
 * 卖出（§5.1 分摊、§5.2）：库存变负也照收；引用不存在的商品按名称和卖价自动建 needs_review 商品，绝不丢账（§4.4）。
 * 自动建的商品：pack_qty = 1 时卖价取行单价，整件行取 0（单件价未知，等家用补全）；不挂条码（条码可能属于别的商品）。
 */
export async function applySaleBatch(tx: StoreTx, ctx: LedgerContext, p: SaleBatchPayload): Promise<Outcome> {
  const remap = new Remap();
  return guarded(tx, remap, async () => {
    const batchId = p.batch_id.toLowerCase();
    const dup = await tx.trx.selectFrom("sale_batches").select("id").where("store_id", "=", tx.storeId).where("id", "=", batchId).executeTakeFirst();
    if (dup) bad("batch_id 已被占用");
    const ids = new Set(p.lines.map((l) => l.entry_id.toLowerCase()));
    if (ids.size !== p.lines.length) bad("同一笔里 entry_id 重复");
    for (const id of ids) await entryFree(tx, id);
    const alloc = allocate(
      p.lines.map((l) => ({ unitPriceFen: BigInt(l.unit_price_fen), packCount: BigInt(l.pack_count), packQty: BigInt(l.pack_qty) })),
      BigInt(p.paid_total_fen),
    );
    await tx.trx
      .insertInto("sale_batches")
      .values({
        id: batchId,
        store_id: tx.storeId,
        device_id: ctx.deviceId,
        list_total_fen: String(alloc.listTotalFen),
        paid_total_fen: String(p.paid_total_fen),
        occurred_at: ctx.occurredAt,
        received_at: ctx.now,
        rev: await tx.nextRev(),
      } as never)
      .execute();
    for (const [i, l] of p.lines.entries()) {
      const pid = await resolveProductId(tx, l.product_id, remap);
      let prod = await loadProduct(tx, pid);
      if (!prod) {
        await tx.trx
          .insertInto("products")
          .values({
            id: pid,
            store_id: tx.storeId,
            name: l.name,
            base_unit: DEFAULT_BASE_UNIT,
            price_fen: l.pack_qty === 1 ? l.unit_price_fen : 0,
            needs_review: true,
            created_by_device: ctx.deviceId,
            rev: await tx.nextRev(),
            updated_at: ctx.now,
          } as never)
          .execute();
        prod = (await loadProduct(tx, pid))!;
      }
      const step = sale(stateOf(prod), BigInt(l.pack_qty) * BigInt(l.pack_count), alloc.amountFen[i]!, alloc.listFen[i]!);
      await writeStep(tx, ctx, prod, {
        id: l.entry_id,
        batchId,
        barcode: l.barcode,
        unitName: l.unit_name,
        packQty: l.pack_qty,
        packCount: l.pack_count,
      }, step);
    }
  });
}
