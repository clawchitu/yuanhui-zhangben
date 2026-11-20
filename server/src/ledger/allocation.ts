// 优惠分摊（§5.1，规则；服务器和手机各实现一遍，contracts/vectors/allocation.json 一致）。
// 和 ios/ShopCore 的 Allocation.allocate 逐步对应。§14 S12-4：S04 先让服务器跑同一份向量，卖出入账在 S05。
import { roundDiv } from "./rounddiv.ts";

/** §5.0 上限 */
export const LIMITS = {
  maxLines: 200,
  maxUnitPriceFen: 99_999_999n,
  maxLineAmountFen: 99_999_999n,
  maxPackCount: 99_999n,
  maxPackQty: 9_999n,
  maxBaseQty: 9_999_999n,
  maxPaidTotalFen: 19_999_999_800n,
} as const;

export class AllocationError extends Error {
  readonly code = "invalid";
}

export interface AllocationLine {
  /** 单价（整件码就是整件价） */
  unitPriceFen: bigint;
  /** 件数 */
  packCount: bigint;
  /** 换算（只用于基本单位数量上限），默认 1 */
  packQty?: bigint;
}

export interface Allocation {
  /** 各行原价 L_i = 单价 × 件数 */
  listFen: bigint[];
  /** L = Σ L_i */
  listTotalFen: bigint;
  /** 各行摊完的实收 a_i，Σ a_i = P */
  amountFen: bigint[];
}

function invalid(msg: string): never {
  throw new AllocationError(msg);
}

/** 各行原价与合计，同时做 §5.0 的逐行上限校验 */
export function listAmounts(lines: AllocationLine[]): { list: bigint[]; total: bigint } {
  if (lines.length === 0) invalid("购物篮是空的");
  if (lines.length > LIMITS.maxLines) invalid(`一笔卖出最多 ${LIMITS.maxLines} 行：${lines.length}`);
  const list: bigint[] = [];
  for (const l of lines) {
    const packQty = l.packQty ?? 1n;
    if (l.unitPriceFen < 0n || l.unitPriceFen > LIMITS.maxUnitPriceFen) invalid(`单价超出范围：${l.unitPriceFen}`);
    if (l.packCount < 0n || l.packCount > LIMITS.maxPackCount) invalid(`件数超出范围：${l.packCount}`);
    if (packQty < 1n || packQty > LIMITS.maxPackQty) invalid(`换算超出范围：${packQty}`);
    if (packQty * l.packCount > LIMITS.maxBaseQty) invalid(`基本单位数量超出上限：${packQty * l.packCount}`);
    const amount = l.unitPriceFen * l.packCount;
    if (amount > LIMITS.maxLineAmountFen) invalid(`单行金额超出上限：${amount}`);
    list.push(amount);
  }
  return { list, total: list.reduce((s, x) => s + x, 0n) };
}

/** 分摊。超限、实收为负或超上限、L = 0 而 P ≠ 0 时抛 AllocationError（op 结果 rejected: invalid）。 */
export function allocate(lines: AllocationLine[], paidTotalFen: bigint): Allocation {
  const { list, total } = listAmounts(lines);
  const p = paidTotalFen;
  if (p < 0n || p > LIMITS.maxPaidTotalFen) invalid(`实收超出范围：${p}`);

  // 第 0 步：全零购物篮，P 必须为 0，各行 0
  if (total === 0n) {
    if (p !== 0n) invalid("全是零价商品时实收只能是 0");
    return { listFen: list, listTotalFen: 0n, amountFen: list.map(() => 0n) };
  }

  // 第 1 步：a_i = roundDiv(L_i × P, L)
  const a = list.map((li) => roundDiv(li * p, total));

  // 按原价降序、并列取最前的行顺序
  const order = list.map((_, i) => i).sort((x, y) => (list[x]! !== list[y]! ? (list[x]! > list[y]! ? -1 : 1) : x - y));

  // 第 2 步：d = P − Σa_i 加到原价最大的一行
  const d = p - a.reduce((s, x) => s + x, 0n);
  const top = order[0]!;
  a[top] = a[top]! + d;

  // 第 3 步：该行因此小于 0 时设为 0，不足部分依次从下一大的行扣
  if (a[top]! < 0n) {
    let deficit = -a[top]!;
    a[top] = 0n;
    for (const i of order.slice(1)) {
      if (deficit === 0n) break;
      const take = a[i]! < deficit ? a[i]! : deficit;
      a[i] = a[i]! - take;
      deficit -= take;
    }
    // Σa_i = P ≥ 0，所以不足部分一定扣得完
    if (deficit !== 0n) invalid("分摊不足部分无法扣完");
  }
  return { listFen: list, listTotalFen: total, amountFen: a };
}
