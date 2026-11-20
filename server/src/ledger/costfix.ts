// 待确认补全（§4.3 product_review_complete、§5.2 期初 / 待确认补全、§5.6 第 2 条，§14 S05-1、S05-9、R1）：
// 记一条 opening（不是 stock_in），进价必填（可为 0），清 needs_review；进价从没填变已知时的成本补记
// 走 cost.ts 的 opening（和 S05b 的期初同一套），不另写补记逻辑。原卖出行的 cogs_fen 不改。
// 只比对 base_ver（必带）。卖价、条码不在这里代填，由手机另发 product_edit、barcode_link（S05-9）。
import { Remap, resolveProductId } from "../sync/aliases.ts";
import type { StoreTx } from "../sync/lock.ts";
import type { Outcome } from "../sync/catalog.ts";
import { opening } from "./cost.ts";
import { bad, entryFree, guarded, loadProduct, missingSales, staleOf, stateOf, writeStep, type LedgerContext } from "./apply.ts";

interface ReviewCompletePayload {
  entry_id: string;
  product_id: string;
  unit_cost_fen: number;
  counted_qty: number;
  base_ver: number;
  base_qty?: number;
  track_expiry?: boolean;
  expiry_warn_days?: number;
  shelf_life_months?: number;
}

export async function applyReviewComplete(tx: StoreTx, ctx: LedgerContext, p: ReviewCompletePayload): Promise<Outcome> {
  const remap = new Remap();
  return guarded(tx, remap, async () => {
    const prod = (await loadProduct(tx, await resolveProductId(tx, p.product_id, remap))) ?? bad("商品不存在");
    if (BigInt(prod.stock_ver) !== BigInt(p.base_ver)) return staleOf(prod, remap);
    await entryFree(tx, p.entry_id);
    const step = opening(stateOf(prod), BigInt(p.counted_qty), BigInt(p.unit_cost_fen), await missingSales(tx, prod.id));
    await writeStep(tx, ctx, prod, { id: p.entry_id, unitName: prod.base_unit }, step, { counted: true });
    const settings: Record<string, unknown> = {};
    for (const k of ["track_expiry", "expiry_warn_days", "shelf_life_months"] as const) if (p[k] !== undefined) settings[k] = p[k];
    await tx.trx
      .updateTable("products")
      .set({ ...settings, needs_review: false, rev: await tx.nextRev(), updated_at: ctx.now } as never)
      .where("store_id", "=", tx.storeId)
      .where("id", "=", prod.id)
      .execute();
  });
}
