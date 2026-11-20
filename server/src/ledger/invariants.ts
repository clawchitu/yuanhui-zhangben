// 不变式（§3.3 I1–I3 以及 §5.2 成本补记的几条推论），对一个商品的流水序列断言。
// MemLedger 是 cost.ts 的内存参考实现：把一个商品的流水按顺序记在数组里，撤销、补记都按 §3.3 / §5.2 的记法。
// cost.json 向量和 fast-check 性质测试都跑它；S05b 的数据库实现用同一套检查函数对库里的流水断言。
import { CostError, count, opening, removeStock, sale, stockIn, voidEntry, type CostState, type Draft, type MissingSale, type Step } from "./cost.ts";

export interface Row extends Draft {
  idx: number;
  reverses: number | null;
  covers: number[] | null;
  voided: boolean;
  costFixBy: number | null;
}

export type Action =
  | { type: "stock_in"; pack_qty: bigint; pack_count: bigint; unit_cost_fen: bigint }
  | { type: "sale"; pack_qty: bigint; pack_count: bigint; amount_fen: bigint; list_amount_fen: bigint }
  | { type: "opening"; counted_qty: bigint; unit_cost_fen: bigint | null }
  | { type: "count"; counted_qty: bigint }
  | { type: "expire_loss" | "supplier_return"; qty: bigint }
  | { type: "void"; target: number };

export class MemLedger {
  readonly initial: CostState;
  state: CostState;
  rows: Row[] = [];

  constructor(initial: CostState) {
    assertI3(initial);
    this.initial = { ...initial };
    this.state = { ...initial };
  }

  /** 等待补记的卖出行：cost_missing、未撤销、未补记、不是冲销行 */
  missing(): MissingSale<number>[] {
    return this.rows
      .filter((r) => r.type === "sale" && r.cost_missing && !r.voided && r.costFixBy === null && r.reverses === null)
      .map((r) => ({ ref: r.idx, qty: -r.qty_delta, amount_fen: r.amount_fen }));
  }

  /** 应用一个动作，返回新产生的行号（第一个是主流水）。抛 CostError 时什么都不改 */
  apply(a: Action): number[] {
    const s = this.state;
    let step: Step<number>;
    switch (a.type) {
      case "stock_in":
        step = stockIn(s, a.pack_qty * a.pack_count, a.pack_count * a.unit_cost_fen, a.unit_cost_fen, this.missing());
        break;
      case "sale":
        step = sale(s, a.pack_qty * a.pack_count, a.amount_fen, a.list_amount_fen);
        break;
      case "opening":
        step = opening(s, a.counted_qty, a.unit_cost_fen, this.missing());
        break;
      case "count":
        step = count(s, a.counted_qty);
        break;
      case "expire_loss":
      case "supplier_return":
        step = removeStock(s, a.qty, a.type);
        break;
      case "void": {
        const t = this.rows[a.target];
        if (!t || t.reverses !== null) throw new CostError(`没有可撤销的第 ${a.target} 行`);
        if (t.voided) return []; // 撤销两次：第二次无操作（§4.4）
        const fix = t.costFixBy === null ? undefined : { ref: t.costFixBy, b: this.rows[t.costFixBy]!.unit_cost_fen! };
        step = voidEntry(s, { ...t, ref: t.idx }, fix);
        t.voided = true;
        break;
      }
    }
    const out: number[] = [];
    for (const e of step.entries) {
      const idx = this.rows.length;
      const row: Row = {
        ...e,
        idx,
        reverses: "reverses" in e ? (e.reverses as number) : null,
        covers: "covers" in e ? (e.covers as number[]) : null,
        voided: false,
        costFixBy: null,
      };
      for (const c of row.covers ?? []) this.rows[c]!.costFixBy = idx;
      this.rows.push(row);
      out.push(idx);
    }
    this.state = step.state;
    return out;
  }
}

export class InvariantViolation extends Error {}
function check(ok: boolean, msg: string) {
  if (!ok) throw new InvariantViolation(msg);
}

/** I3：k 假时 v = 0；k 真时 q > 0 则 v ≥ 0，q ≤ 0 则 v = q × c */
export function assertI3(s: CostState) {
  if (!s.k) return check(s.v === 0n, `I3：进价未知但货值 ${s.v} ≠ 0`);
  check(s.c !== null && s.c >= 0n, `I3：进价已知但 last_cost_fen = ${s.c}`);
  if (s.q > 0n) check(s.v >= 0n, `I3：库存 ${s.q} > 0 但货值 ${s.v} < 0`);
  else check(s.v === s.q * s.c!, `I3：库存 ${s.q} ≤ 0 但货值 ${s.v} ≠ ${s.q} × ${s.c}`);
}

/** 对一个商品的全部流水断言 I1、I2、I3 和冲销 / 补记的结构性质 */
export function assertLedger(initial: CostState, state: CostState, rows: Row[]) {
  const sum = (f: (r: Row) => bigint) => rows.reduce((x, r) => x + f(r), 0n);
  check(initial.q + sum((r) => r.qty_delta) === state.q, `I1：Σ qty_delta 与库存 ${state.q} 不等`);
  check(initial.v + sum((r) => r.value_delta_fen) === state.v, `I2：Σ value_delta 与货值 ${state.v} 不等`);
  assertI3(state);
  const reversedBy = new Map<number, number>();
  for (const r of rows) {
    if (r.reverses === null) continue;
    const t = rows[r.reverses]!;
    check(t.type === r.type, `冲销行 ${r.idx} 的类型 ${r.type} 与原行 ${t.type} 不同`);
    check(r.unit_cost_fen === t.unit_cost_fen, `冲销行 ${r.idx} 的 unit_cost_fen 没有照抄原行`);
    if (r.type === "cost_fix") continue; // cost_fix 可以被多次部分冲销
    check(!reversedBy.has(t.idx), `第 ${t.idx} 行被冲销了两次`);
    reversedBy.set(t.idx, r.idx);
    check(t.voided, `第 ${t.idx} 行被冲销但没有标撤销`);
    for (const k of ["qty_delta", "amount_fen", "list_amount_fen", "cogs_fen", "value_delta_fen"] as const) {
      check(r[k] === -t[k], `冲销行 ${r.idx} 的 ${k} 不是原行取反`);
    }
  }
  for (const r of rows) if (r.voided) check(reversedBy.has(r.idx), `第 ${r.idx} 行标了撤销但没有冲销行`);
  // k 为真时不再有等待补记的卖出行（补记在 k 变真的那一刻做完，之后的卖出都有成本）
  if (state.k) {
    const pending = rows.filter((r) => r.type === "sale" && r.cost_missing && !r.voided && r.costFixBy === null && r.reverses === null);
    check(pending.length === 0, `进价已知但还有 ${pending.length} 行卖出没补记`);
  }
  // 每条 cost_fix 的数量合计 × b = cogs，实收合计 = amount
  for (const r of rows) {
    if (r.type !== "cost_fix" || r.covers === null) continue;
    const cov = r.covers.map((i) => rows[i]!);
    check(cov.every((x) => x.costFixBy === r.idx), `cost_fix ${r.idx} 的补记行没有指回它`);
    check(r.amount_fen === cov.reduce((x, c) => x + c.amount_fen, 0n), `cost_fix ${r.idx} 的实收合计不对`);
    check(r.cogs_fen === cov.reduce((x, c) => x - c.qty_delta, 0n) * r.unit_cost_fen!, `cost_fix ${r.idx} 的进价合计不对`);
  }
  // 金额为 0 的 cost_adjust 不记（§5.2 通则）
  check(rows.every((r) => r.type !== "cost_adjust" || r.value_delta_fen !== 0n), "出现了金额为 0 的 cost_adjust");
}
