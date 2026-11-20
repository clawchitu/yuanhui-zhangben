// 商品别名（§3.2 product_aliases、§4.4「同一条码已经登记过」、§4.2 remap）。
// 两台手机离线时各自登记了同一个条码：先到的赢，后到的商品 id 记成别名（它本身不在 products 里建行），
// 之后任何 op 引用到别名都改写到赢家，并在这个 op 的结果里带 remap {别名: 赢家}。
import type { StoreTx } from "./lock.ts";

/** 一个 op 的 remap 收集器：同一个 op 里可能引用好几个别名（S05 的 sale_batch 每行一个） */
export class Remap {
  private pairs = new Map<string, string>();
  add(alias: string, winner: string) {
    this.pairs.set(alias, winner);
  }
  /** 没有别名时返回 undefined（结果里不出现 remap 键） */
  toJSON(): Record<string, string> | undefined {
    return this.pairs.size ? Object.fromEntries(this.pairs) : undefined;
  }
}

/** 商品 id 若是别名，返回赢家 id 并记进 remap；否则原样返回（不检查商品是否存在） */
export async function resolveProductId(tx: StoreTx, productId: string, remap: Remap): Promise<string> {
  const id = productId.toLowerCase();
  const a = await tx.trx
    .selectFrom("product_aliases")
    .select("product_id")
    .where("store_id", "=", tx.storeId)
    .where("alias_id", "=", id)
    .executeTakeFirst();
  if (!a) return id;
  // remap 的键用手机发来的原样，手机按它改写本地引用
  remap.add(productId, a.product_id);
  return a.product_id;
}

/** 把 aliasId 记成 winnerId 的别名（已经记过就不动） */
export async function addAlias(tx: StoreTx, aliasId: string, winnerId: string): Promise<void> {
  await tx.trx
    .insertInto("product_aliases")
    .values({ store_id: tx.storeId, alias_id: aliasId.toLowerCase(), product_id: winnerId })
    .onConflict((oc) => oc.columns(["store_id", "alias_id"]).doNothing())
    .execute();
}
