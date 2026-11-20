// 移动加权平均与成本（§5.2，规则，不许改口径）。纯函数，不查库：输入商品的四个量 (q, v, c, k) 和一个动作，
// 输出新的四个量和要写的流水草稿（按产生顺序）。S05b 的 apply.ts / void.ts 在店铺锁内读出商品、调这里、把草稿写进 entries。
// 向量：contracts/vectors/cost.json（每一组逐步、逐分对照）。全部整数分 BigInt，除法一律 roundDiv（§5.0）。
//
// 本文件也给 cost.json 里 S06 的动作（盘点、过期扔掉、退货）实现了纯算法，因为向量是同一份；op 处理函数在 S06。
import { roundDiv } from "./rounddiv.ts";

export type EntryType = "sale" | "stock_in" | "opening" | "count" | "cost_adjust" | "cost_fix" | "expire_loss" | "supplier_return";

/** 一个商品的成本状态（§5.2）：q = stock_qty，v = stock_value_fen，c = last_cost_fen，k = cost_known */
export interface CostState {
  q: bigint;
  v: bigint;
  c: bigint | null;
  k: boolean;
}

/** 流水草稿：数量和金额字段同 entries 表（§3.3） */
export interface Draft {
  type: EntryType;
  qty_delta: bigint;
  amount_fen: bigint;
  list_amount_fen: bigint;
  cogs_fen: bigint;
  value_delta_fen: bigint;
  cost_missing: boolean;
  /** stock_in：每件单价；cost_fix：补记用的单位成本 b；opening 填了进价时存 b；冲销行照抄原行、不取反 */
  unit_cost_fen: bigint | null;
}

/** 冲销草稿：指向被冲的那一行（调用方的引用，库里是 entry id） */
export interface ReversalDraft<R> extends Draft {
  reverses: R;
}

/** cost_fix 草稿：补记了哪些卖出行（这些行要写 cost_fix_entry_id，本身的 cogs / value_delta 不改） */
export interface CostFixDraft<R> extends Draft {
  type: "cost_fix";
  covers: R[];
}

/** 等待成本补记的卖出行：cost_missing、未撤销、未补记过、不是冲销行 */
export interface MissingSale<R> {
  ref: R;
  /** 卖出的基本单位数（正数，= −qty_delta） */
  qty: bigint;
  amount_fen: bigint;
}

export class CostError extends Error {
  readonly code = "invalid";
}

/**
 * 落库、下发的取值范围。数量（products.stock_qty、entries.qty_delta）是 integer；
 * 金额、货值、成本（stock_value_fen、last_cost_fen、amount_fen、list_amount_fen、cogs_fen、value_delta_fen、unit_cost_fen）
 * 既要存得进 bigint 列（0001_init.sql，±2^63），又要能经契约下发（openapi.yaml 的 SignedFen / Fen：JSON 安全整数 ±(2^53−1)），取两者更严，即 FEN。
 * 数量的 INT32 本身比安全整数严，不用再合并。
 * BigInt 只保证中间计算精确，结果还得落得进这些范围（§14 S05-4 第二层：超界拒 invalid 并留档，在写库之前判）。
 */
export const INT32 = { min: -(2n ** 31n), max: 2n ** 31n - 1n } as const;
export const INT64 = { min: -(2n ** 63n), max: 2n ** 63n - 1n } as const;
/** 契约 SignedFen：JSON 安全整数 ±9007199254740991 */
export const SAFE = { min: -(2n ** 53n - 1n), max: 2n ** 53n - 1n } as const;
const stricter = (a: { min: bigint; max: bigint }, b: { min: bigint; max: bigint }) => ({ min: a.min > b.min ? a.min : b.min, max: a.max < b.max ? a.max : b.max }) as const;
/** 金额类列的有效范围 = INT64 ∩ SAFE */
export const FEN = stricter(INT64, SAFE);

function inRange(x: bigint, r: { min: bigint; max: bigint }, what: string) {
  if (x < r.min || x > r.max) throw new CostError(`${what} = ${x} 超出列范围（bigint / integer 与契约 SignedFen 取更严）[${r.min}, ${r.max}]`);
}

/** 返回前统一检查新状态和每条流水草稿都存得进库；越界整步拒绝（纯函数，抛出时调用方什么都没改） */
function storable<S extends Step<unknown>>(step: S): S {
  const { state: s, entries } = step;
  inRange(s.q, INT32, "stock_qty");
  inRange(s.v, FEN, "stock_value_fen");
  if (s.c !== null) inRange(s.c, FEN, "last_cost_fen");
  for (const e of entries) {
    inRange(e.qty_delta, INT32, `${e.type}.qty_delta`);
    for (const k of ["amount_fen", "list_amount_fen", "cogs_fen", "value_delta_fen"] as const) inRange(e[k], FEN, `${e.type}.${k}`);
    if (e.unit_cost_fen !== null) inRange(e.unit_cost_fen, FEN, `${e.type}.unit_cost_fen`);
  }
  return step;
}

export interface Step<R> {
  state: CostState;
  entries: Array<Draft | ReversalDraft<R> | CostFixDraft<R>>;
}

const zero = (type: EntryType): Draft => ({
  type,
  qty_delta: 0n,
  amount_fen: 0n,
  list_amount_fen: 0n,
  cogs_fen: 0n,
  value_delta_fen: 0n,
  cost_missing: false,
  unit_cost_fen: null,
});

/** 当前单位成本 u：k 真且 q > 0 时 roundDiv(v, q)，否则 c */
export function unitCost(s: CostState): bigint | null {
  return s.k && s.q > 0n ? roundDiv(s.v, s.q) : s.c;
}

function known(s: CostState): bigint {
  if (s.c === null) throw new Error("cost_known 为真时 last_cost_fen 不能为空");
  return s.c;
}

/** 调整：金额为 0 的不记（§5.2 通则，§14 Q2） */
function adjust(entries: Draft[], s: CostState, target: bigint): CostState {
  const d = target - s.v;
  if (d !== 0n) entries.push({ ...zero("cost_adjust"), value_delta_fen: d });
  return { ...s, v: target };
}

/** 成本补记（§5.2）：没有可补记的行不记 */
function costFix<R>(missing: MissingSale<R>[], b: bigint): CostFixDraft<R>[] {
  if (missing.length === 0) return [];
  const amount = missing.reduce((x, m) => x + m.amount_fen, 0n);
  const qty = missing.reduce((x, m) => x + m.qty, 0n);
  return [{ ...zero("cost_fix"), type: "cost_fix", amount_fen: amount, cogs_fen: qty * b, unit_cost_fen: b, covers: missing.map((m) => m.ref) }];
}

/**
 * 按卖出的取法算 n 个的成本（卖出、过期扔掉、退货共用，§5.2）。只在 k 为真时调用。
 * q > 0：take = min(n, q)；cogs = (take = q ? v : roundDiv(v × take, q)) + (n − take) × u；n ≥ q 时 c = u。
 * q ≤ 0：cogs = n × c。
 */
function takeCost(s: CostState, n: bigint): { cogs: bigint; c: bigint } {
  const c = known(s);
  if (s.q > 0n) {
    const u = roundDiv(s.v, s.q);
    const take = n < s.q ? n : s.q;
    const cogs = (take === s.q ? s.v : roundDiv(s.v * take, s.q)) + (n - take) * u;
    return { cogs, c: n >= s.q ? u : c };
  }
  return { cogs: n * c, c };
}

function nonNegative(x: bigint, what: string) {
  if (x < 0n) throw new CostError(`${what}不能为负：${x}`);
}

/** 进货 n 个基本单位、总价 T（unitCostFen = 录入的每件单价，只存档） */
function stockInRaw<R>(s: CostState, n: bigint, T: bigint, unitCostFen: bigint, missing: MissingSale<R>[]): Step<R> {
  if (n <= 0n) throw new CostError(`进货数量必须为正：${n}`);
  nonNegative(T, "进货总价");
  const b = roundDiv(T, n);
  const line: Draft = { ...zero("stock_in"), qty_delta: n, amount_fen: T, list_amount_fen: T, value_delta_fen: T, unit_cost_fen: unitCostFen };
  if (s.k && s.q > 0n) return { state: { q: s.q + n, v: s.v + T, c: b, k: true }, entries: [line] };
  const entries: Array<Draft | CostFixDraft<R>> = [line];
  const q = s.q + n;
  const target = q > 0n ? roundDiv(T * q, n) : q * b;
  const after = adjust(entries, { ...s, q, v: s.v + T }, target);
  if (!s.k) entries.push(...costFix(missing, b));
  return { state: { ...after, c: b, k: true }, entries };
}

/** 卖出 n 个基本单位，实收 amount（已分摊）、原价 list */
function saleRaw<R>(s: CostState, n: bigint, amount: bigint, list: bigint): Step<R> {
  nonNegative(n, "卖出数量");
  const line: Draft = { ...zero("sale"), qty_delta: -n, amount_fen: amount, list_amount_fen: list };
  if (!s.k) return { state: { ...s, q: s.q - n }, entries: [{ ...line, cost_missing: true }] };
  const { cogs, c } = takeCost(s, n);
  return { state: { q: s.q - n, v: s.v - cogs, c, k: true }, entries: [{ ...line, cogs_fen: cogs, value_delta_fen: -cogs }] };
}

/** 盘点数到 N（§5.2；版本校验在 §5.6，不在这里）。d = 0 也记一条全 0 的 count */
function countRaw<R>(s: CostState, N: bigint): Step<R> {
  nonNegative(N, "盘点数");
  const d = N - s.q;
  if (d === 0n) return { state: s, entries: [zero("count")] };
  let vd = 0n;
  if (s.k && s.q > 0n) vd = d < 0n ? -(N === 0n ? s.v : roundDiv(s.v * -d, s.q)) : d * roundDiv(s.v, s.q);
  else if (s.k) vd = N * known(s) - s.v;
  const e: Draft = { ...zero("count"), qty_delta: d, cogs_fen: -vd, value_delta_fen: vd, cost_missing: !s.k };
  return { state: { ...s, q: N, v: s.v + vd }, entries: [e] };
}

/**
 * 期初 / 待确认补全，数到 N，进价 b（null = 没填）。按期初记，不算进货（§5.2）：
 * - 填了（含 0）：k = 真、c = b、v = N × b、q = N；k 原来为假时成本补记。
 * - 没填且 k 为真：就是一次盘点，流水记 count。
 * - 没填且 k 为假：只把数量设为 N。
 */
function openingRaw<R>(s: CostState, N: bigint, b: bigint | null, missing: MissingSale<R>[]): Step<R> {
  nonNegative(N, "期初数");
  if (b === null) {
    if (s.k) return countRaw(s, N);
    return { state: { ...s, q: N }, entries: [{ ...zero("opening"), qty_delta: N - s.q }] };
  }
  nonNegative(b, "期初进价");
  const v = N * b;
  const entries: Array<Draft | CostFixDraft<R>> = [{ ...zero("opening"), qty_delta: N - s.q, value_delta_fen: v - s.v, unit_cost_fen: b }];
  if (!s.k) entries.push(...costFix(missing, b));
  return { state: { q: N, v, c: b, k: true }, entries };
}

/** 过期扔掉 / 退给供货商 n 个：成本取法与卖出相同；扔掉记损耗，退货不计盈亏；k 为假时金额 0、标 cost_missing */
function removeStockRaw<R>(s: CostState, n: bigint, kind: "expire_loss" | "supplier_return"): Step<R> {
  nonNegative(n, "数量");
  const line: Draft = { ...zero(kind), qty_delta: -n };
  if (!s.k) return { state: { ...s, q: s.q - n }, entries: [{ ...line, cost_missing: true }] };
  const { cogs, c } = takeCost(s, n);
  return {
    state: { q: s.q - n, v: s.v - cogs, c, k: true },
    entries: [{ ...line, cogs_fen: kind === "expire_loss" ? cogs : 0n, value_delta_fen: -cogs }],
  };
}

/** 能被 void op 撤销的流水类型（cost_adjust、cost_fix 是自动生成的，跟着主流水走） */
export const VOIDABLE: ReadonlySet<EntryType> = new Set(["sale", "stock_in", "opening", "count", "expire_loss", "supplier_return"]);

/**
 * 撤销一行流水（§3.3 撤销的记法、§5.2 撤销 / 成本补记）：
 * 1. 冲销行：类型相同，数量和金额全部取反，unit_cost_fen、cost_missing 照抄。
 * 2. 被补记过的卖出（fixedBy 非空）：再冲一条 cost_fix（−实收、−数量 × b，b 取自那条 cost_fix 的 unit_cost_fen）
 *    和一条 cost_adjust（+数量 × b），让回到货架的货按补记的进价计入货值。
 * 3. k 只增不减：c、k 不回退，已经记的 cost_fix 不冲。
 * 4. 归位：k 为真，且（q ≤ 0 而 v ≠ q × c，或 q > 0 而 v < 0）时，一条 cost_adjust 归位到 v = q × c。
 */
function voidEntryRaw<R>(s: CostState, target: Draft & { ref: R }, fixedBy?: { ref: R; b: bigint }): Step<R> {
  if (!VOIDABLE.has(target.type)) throw new CostError(`${target.type} 流水不能直接撤销`);
  const rev: ReversalDraft<R> = {
    type: target.type,
    qty_delta: -target.qty_delta,
    amount_fen: -target.amount_fen,
    list_amount_fen: -target.list_amount_fen,
    cogs_fen: -target.cogs_fen,
    value_delta_fen: -target.value_delta_fen,
    cost_missing: target.cost_missing,
    unit_cost_fen: target.unit_cost_fen,
    reverses: target.ref,
  };
  const entries: Array<Draft | ReversalDraft<R>> = [rev];
  let st: CostState = { ...s, q: s.q + rev.qty_delta, v: s.v + rev.value_delta_fen };
  if (fixedBy) {
    if (target.type !== "sale") throw new Error("只有卖出行会被成本补记");
    const n = -target.qty_delta;
    entries.push({ ...zero("cost_fix"), amount_fen: -target.amount_fen, cogs_fen: -(n * fixedBy.b), unit_cost_fen: fixedBy.b, reverses: fixedBy.ref });
    st = adjust(entries, st, st.v + n * fixedBy.b);
  }
  if (st.k) {
    const c = known(st);
    if ((st.q <= 0n && st.v !== st.q * c) || (st.q > 0n && st.v < 0n)) st = adjust(entries, st, st.q * c);
  }
  return { state: st, entries };
}

// 对外的入口：每一步都过 storable（§14 S05-4）
export const stockIn = <R>(...a: Parameters<typeof stockInRaw<R>>): Step<R> => storable(stockInRaw<R>(...a));
export const sale = <R>(...a: Parameters<typeof saleRaw<R>>): Step<R> => storable(saleRaw<R>(...a));
export const count = <R>(...a: Parameters<typeof countRaw<R>>): Step<R> => storable(countRaw<R>(...a));
export const opening = <R>(...a: Parameters<typeof openingRaw<R>>): Step<R> => storable(openingRaw<R>(...a));
export const removeStock = <R>(...a: Parameters<typeof removeStockRaw<R>>): Step<R> => storable(removeStockRaw<R>(...a));
export const voidEntry = <R>(...a: Parameters<typeof voidEntryRaw<R>>): Step<R> => storable(voidEntryRaw<R>(...a));
