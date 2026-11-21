// 清空一家店的业务数据（演示店每日重置、注销到期清除共用）。只按 store_id 删，一条 SQL 只碰这一家店。
// 顺序照外键：批次移动 → 批次 → 流水（自引用的冲销行在同一条 DELETE 里一起删，外键在语句结束时才检查）→ 卖出单 →
// 图片任务（先于商品，§14 T12）→ 别名、条码 → 商品 → 墓碑 → 留档 → 开通码。设备、账号、店由调用方处理。
// 必须在 withStoreLock 里调（同一店的同步写入都在等这把锁，删到一半的状态没人看得见）。
import type { StoreTx } from "../sync/lock.ts";

export const STORE_DATA_TABLES = [
  "lot_moves",
  "stock_lots",
  "entries",
  "sale_batches",
  "image_jobs",
  "product_aliases",
  "product_barcodes",
  "products",
  "removed",
  "ops",
  "pairing_tokens",
] as const;

export async function wipeStoreData(tx: StoreTx): Promise<void> {
  for (const t of STORE_DATA_TABLES) await tx.trx.deleteFrom(t).where("store_id", "=", tx.storeId).execute();
}
