// 商品类 op 的应用（§4.3、§4.4）：product_upsert / product_edit / barcode_link / barcode_unlink。
// 调用方（push.ts）已经拿着店铺锁、判过权限、按 ops.schema.json 校验过 payload。每改一行取一个新号。
//
// 单件卖价只有一处：products.price_fen。单件码（pack_qty=1）不存价；整件码可以带自己的价，不带时整件价 = 单件卖价 × 换算（§3.2、§14 S02-5）。
import { addAlias, Remap, resolveProductId } from "./aliases.ts";
import type { StoreTx } from "./lock.ts";

export interface ApplyContext {
  deviceId: string;
  /** 服务器收到的时间 */
  now: Date;
  /** op 的 occurred_at（手机时钟超前时已校正） */
  occurredAt: Date;
}

export type Outcome =
  | { status: "applied"; remap?: Record<string, string> }
  | { status: "rejected"; code: "invalid"; remap?: Record<string, string> };

const applied = (remap: Remap): Outcome => ({ status: "applied", ...withRemap(remap) });
const invalid = (remap: Remap): Outcome => ({ status: "rejected", code: "invalid", ...withRemap(remap) });
function withRemap(remap: Remap) {
  const m = remap.toJSON();
  return m ? { remap: m } : {};
}

interface UpsertPayload {
  product_id: string;
  barcode: string;
  name: string;
  price_fen: number;
  quick: boolean;
  base_unit?: string;
  track_expiry?: boolean;
  expiry_warn_days?: number;
  shelf_life_months?: number | null;
  low_at?: number | null;
}

interface EditPayload {
  product_id: string;
  name?: string;
  price_fen?: number;
  base_unit?: string;
  low_at?: number | null;
  track_expiry?: boolean;
  expiry_warn_days?: number;
  shelf_life_months?: number | null;
  archived?: boolean;
}

interface LinkPayload {
  barcode: string;
  product_id: string;
  pack_qty: number;
  unit_name: string;
  pack_price_fen?: number;
}

interface UnlinkPayload {
  barcode: string;
  product_id: string;
}

/** quick 登记不带基本单位，服务器默认「个」（§4.3、§14 Q3） */
export const DEFAULT_BASE_UNIT = "个";

async function productExists(tx: StoreTx, id: string) {
  return tx.trx
    .selectFrom("products")
    .select(["id", "base_unit", "archived_at"])
    .where("store_id", "=", tx.storeId)
    .where("id", "=", id)
    .executeTakeFirst();
}

/** 当前挂着的条码（解除过的不算） */
async function liveBarcode(tx: StoreTx, barcode: string) {
  return tx.trx
    .selectFrom("product_barcodes")
    .selectAll()
    .where("store_id", "=", tx.storeId)
    .where("barcode", "=", barcode)
    .where("deleted_at", "is", null)
    .executeTakeFirst();
}

/** 挂上条码：没有这一行就插入；解除过的、或者同一商品改换算和价，就整行改写。取一个新号。 */
async function writeBarcode(
  tx: StoreTx,
  b: { barcode: string; productId: string; packQty: number; unitName: string; packPriceFen: number | null },
) {
  const rev = await tx.nextRev();
  const values = {
    product_id: b.productId,
    pack_qty: b.packQty,
    unit_name: b.unitName,
    // 单件码不存价（库里的 CHECK 也兜底）
    pack_price_fen: b.packQty === 1 ? null : b.packPriceFen,
    rev,
    deleted_at: null,
  };
  await tx.trx
    .insertInto("product_barcodes")
    .values({ store_id: tx.storeId, barcode: b.barcode, ...values })
    .onConflict((oc) => oc.columns(["store_id", "barcode"]).doUpdateSet(values))
    .execute();
}

/**
 * product_upsert：
 * - 商品 id 已经是别名 → 什么都不改，返回 remap（重复登记）。
 * - 商品 id 已存在 → 不改商品的任何字段（改名称、卖价走 product_edit）；条码空闲就给它挂上一个单件码。
 * - 条码已经挂在别的商品上（不论单件码还是整件码、不论角色）→ 不改赢家任何字段，记别名，返回 remap（§4.4）。
 * - 否则建商品 + 一个单件码。quick 的基本单位默认「个」、needs_review=true（§4.3）。
 */
export async function applyProductUpsert(tx: StoreTx, ctx: ApplyContext, p: UpsertPayload): Promise<Outcome> {
  const remap = new Remap();
  const pid = await resolveProductId(tx, p.product_id, remap);
  if (remap.toJSON()) return applied(remap);

  const existing = await productExists(tx, pid);
  const taken = await liveBarcode(tx, p.barcode);
  if (existing) {
    if (!taken) await writeBarcode(tx, { barcode: p.barcode, productId: pid, packQty: 1, unitName: existing.base_unit, packPriceFen: null });
    return applied(remap);
  }
  if (taken) {
    await addAlias(tx, pid, taken.product_id);
    remap.add(p.product_id, taken.product_id);
    return applied(remap);
  }

  const baseUnit = p.quick ? DEFAULT_BASE_UNIT : (p.base_unit ?? DEFAULT_BASE_UNIT);
  await tx.trx
    .insertInto("products")
    .values({
      id: pid,
      store_id: tx.storeId,
      name: p.name,
      base_unit: baseUnit,
      price_fen: p.price_fen,
      track_expiry: p.track_expiry ?? false,
      expiry_warn_days: p.expiry_warn_days ?? 7,
      shelf_life_months: p.shelf_life_months ?? null,
      low_at: p.low_at ?? null,
      needs_review: p.quick,
      created_by_device: ctx.deviceId,
      rev: await tx.nextRev(),
      updated_at: ctx.now,
    })
    .execute();
  await writeBarcode(tx, { barcode: p.barcode, productId: pid, packQty: 1, unitName: baseUnit, packPriceFen: null });
  return applied(remap);
}

/**
 * product_edit：只改带了的字段，逐字段后写者赢（按到达服务器、应用的先后）。
 * 改基本单位时，这个商品当前挂着的单件码的单位名跟着改（各取一个新号）；整件码不动。
 * 商品不存在（或是别的店的）→ rejected: invalid。
 */
export async function applyProductEdit(tx: StoreTx, ctx: ApplyContext, p: EditPayload): Promise<Outcome> {
  const remap = new Remap();
  const pid = await resolveProductId(tx, p.product_id, remap);
  const existing = await productExists(tx, pid);
  if (!existing) return invalid(remap);

  const set: Record<string, unknown> = {};
  for (const k of ["name", "price_fen", "base_unit", "low_at", "track_expiry", "expiry_warn_days", "shelf_life_months"] as const) {
    if (p[k] !== undefined) set[k] = p[k];
  }
  if (p.archived !== undefined) set.archived_at = p.archived ? (existing.archived_at ?? ctx.occurredAt) : null;
  await tx.trx
    .updateTable("products")
    .set({ ...set, rev: await tx.nextRev(), updated_at: ctx.now })
    .where("store_id", "=", tx.storeId)
    .where("id", "=", pid)
    .execute();

  if (p.base_unit !== undefined) {
    const singles = await tx.trx
      .selectFrom("product_barcodes")
      .select("barcode")
      .where("store_id", "=", tx.storeId)
      .where("product_id", "=", pid)
      .where("pack_qty", "=", 1)
      .where("deleted_at", "is", null)
      .orderBy("barcode")
      .execute();
    for (const s of singles) {
      await tx.trx
        .updateTable("product_barcodes")
        .set({ unit_name: p.base_unit, rev: await tx.nextRev() })
        .where("store_id", "=", tx.storeId)
        .where("barcode", "=", s.barcode)
        .execute();
    }
  }
  return applied(remap);
}

/**
 * barcode_link：给商品挂单件码或整件码。
 * - 条码空闲（没有或解除过）→ 挂上；
 * - 已挂在同一商品上 → 改换算、单位名和整件价；
 * - 已挂在别的商品上 → rejected: invalid（不偷偷把条码挪走，要先解除）。
 * 商品不存在 → rejected: invalid。
 */
export async function applyBarcodeLink(tx: StoreTx, _ctx: ApplyContext, p: LinkPayload): Promise<Outcome> {
  const remap = new Remap();
  const pid = await resolveProductId(tx, p.product_id, remap);
  if (!(await productExists(tx, pid))) return invalid(remap);
  const taken = await liveBarcode(tx, p.barcode);
  if (taken && taken.product_id !== pid) return invalid(remap);
  await writeBarcode(tx, { barcode: p.barcode, productId: pid, packQty: p.pack_qty, unitName: p.unit_name, packPriceFen: p.pack_price_fen ?? null });
  return applied(remap);
}

/**
 * barcode_unlink：解除条码。打 deleted_at，写一条墓碑（kind=barcode，row_id=条码，取一个新号），让别的手机删掉。
 * 条码没挂着（没有或已经解除）→ 无操作（解除两次第二次无操作）；挂在别的商品上 → rejected: invalid。
 */
export async function applyBarcodeUnlink(tx: StoreTx, ctx: ApplyContext, p: UnlinkPayload): Promise<Outcome> {
  const remap = new Remap();
  const pid = await resolveProductId(tx, p.product_id, remap);
  const taken = await liveBarcode(tx, p.barcode);
  if (!taken) return applied(remap);
  if (taken.product_id !== pid) return invalid(remap);
  await tx.trx
    .updateTable("product_barcodes")
    .set({ deleted_at: ctx.now })
    .where("store_id", "=", tx.storeId)
    .where("barcode", "=", p.barcode)
    .execute();
  await tx.trx
    .insertInto("removed")
    .values({ store_id: tx.storeId, rev: await tx.nextRev(), kind: "barcode", row_id: p.barcode })
    .execute();
  return applied(remap);
}
