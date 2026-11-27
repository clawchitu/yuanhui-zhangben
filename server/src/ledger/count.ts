// 盘点（§5.2 盘点、§5.6 第 1、2 条）：count op 写库。只比对 base_ver（base_qty 只留档）；版本不一致 → rejected stale，
// current 带回最新账面数和版本。d = 0 也记一条全 0 的 count，写 last_count_at。算法全在 cost.ts 的 count，这里只读库、写库。
import { Remap } from "../sync/aliases.ts";
import { resolveProductId } from "../sync/aliases.ts";
import type { StoreTx } from "../sync/lock.ts";
import type { Outcome } from "../sync/catalog.ts";
import { count } from "./cost.ts";
import { addToEarliestLot, deductLots } from "./lots.ts";
import { bad, entryFree, guarded, loadProduct, staleOf, stateOf, writeStep, type LedgerContext } from "./apply.ts";

interface CountPayload {
  entry_id: string;
  product_id: string;
  counted_qty: number;
  base_qty: number;
  base_ver: number;
}

export async function applyCount(tx: StoreTx, ctx: LedgerContext, p: CountPayload): Promise<Outcome> {
  const remap = new Remap();
  return guarded(tx, remap, async () => {
    const prod = (await loadProduct(tx, await resolveProductId(tx, p.product_id, remap))) ?? bad("商品不存在");
    if (BigInt(prod.stock_ver) !== BigInt(p.base_ver)) return staleOf(prod, remap);
    await entryFree(tx, p.entry_id);
    const step = count<string>(stateOf(prod), BigInt(p.counted_qty));
    await writeStep(tx, ctx, prod, { id: p.entry_id, unitName: prod.base_unit }, step, { counted: true });
    // 盘亏按到期日扣批次（§5.4）；盘盈加到到期日最早的未关闭批次（§14 T6）
    const d = Number(step.entries[0]!.qty_delta);
    if (d < 0) await deductLots(tx, prod.id, p.entry_id, -d);
    else await addToEarliestLot(tx, prod.id, p.entry_id, d);
  });
}
