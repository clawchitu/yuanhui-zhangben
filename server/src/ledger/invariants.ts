// 不变式（§3.3 I1–I3 以及 §5.2 成本补记的几条推论），对一个商品的流水序列断言。
// MemLedger 是 cost.ts 的内存参考实现：把一个商品的流水按顺序记在数组里，撤销、补记都按 §3.3 / §5.2 的记法。
// cost.json 向量和 fast-check 性质测试都跑它；S05b 的数据库实现用同一套检查函数对库里的流水断言。
import { CostError, count, FEN, INT32, opening, removeStock, sale, stockIn, voidEntry, type CostState, type Draft, type MissingSale, type Step } from "./cost.ts";

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

/** 对一个商品的全部流水断言 I1、I2、I3、列范围，和冲销 / 补记（含 cost_fix 冲销逐分）的性质 */
export function assertLedger(initial: CostState, state: CostState, rows: Row[]) {
  const sum = (f: (r: Row) => bigint) => rows.reduce((x, r) => x + f(r), 0n);
  check(initial.q + sum((r) => r.qty_delta) === state.q, `I1：Σ qty_delta 与库存 ${state.q} 不等`);
  check(initial.v + sum((r) => r.value_delta_fen) === state.v, `I2：Σ value_delta 与货值 ${state.v} 不等`);
  assertI3(state);
  assertStorable(state, rows);
  const reversedBy = new Map<number, number>();
  for (const r of rows) {
    if (r.reverses === null) continue;
    const t = rows[r.reverses]!;
    check(t.type === r.type, `冲销行 ${r.idx} 的类型 ${r.type} 与原行 ${t.type} 不同`);
    check(r.unit_cost_fen === t.unit_cost_fen, `冲销行 ${r.idx} 的 unit_cost_fen 没有照抄原行`);
    if (r.type === "cost_fix") continue; // cost_fix 可以被多次部分冲销，金额在下面按被撤销的卖出逐行断言
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
  // 每条 cost_fix 的数量合计 × b = cogs，实收合计 = amount；补记的只能是当时仍有效、等待补记的卖出行
  for (const r of rows) {
    if (r.type !== "cost_fix" || r.covers === null) continue;
    const cov = r.covers.map((i) => rows[i]!);
    check(cov.length > 0, `cost_fix ${r.idx} 没有补记任何行`);
    check(cov.every((x) => x.costFixBy === r.idx), `cost_fix ${r.idx} 的补记行没有指回它`);
    for (const x of cov) {
      check(x.type === "sale" && x.cost_missing && x.reverses === null && x.idx < r.idx, `cost_fix ${r.idx} 补记了不该补记的第 ${x.idx} 行`);
      // 补记时已经撤销的行不参加（撤销它的冲销行必须在 cost_fix 之后）
      const rev = rows.find((y) => y.reverses === x.idx && y.type === "sale");
      check(rev === undefined || rev.idx > r.idx, `cost_fix ${r.idx} 补记了此前已撤销的第 ${x.idx} 行`);
    }
    check(r.amount_fen === cov.reduce((x, c) => x + c.amount_fen, 0n), `cost_fix ${r.idx} 的实收合计不对`);
    check(r.cogs_fen === cov.reduce((x, c) => x - c.qty_delta, 0n) * r.unit_cost_fen!, `cost_fix ${r.idx} 的进价合计不对`);
  }
  assertCostFixReversals(rows);
  // 金额为 0 的 cost_adjust 不记（§5.2 通则）
  check(rows.every((r) => r.type !== "cost_adjust" || r.value_delta_fen !== 0n), "出现了金额为 0 的 cost_adjust");
}

/**
 * cost_fix 冲销行逐分断言（§5.2「补记后撤销」，§14 S05-6 ⑥）。撤销一笔被补记过的卖出，同一次撤销产生的流水相邻：
 *   卖出的冲销行 → cost_fix 冲销行（实收 = −那笔卖出的实收，进价 = −数量 × b，其余为 0）→ cost_adjust（+数量 × b，b = 0 时没有）
 * b 是原 cost_fix 存的 unit_cost_fen（补记那一刻的进价），不是撤销时的当前进价。
 * 每条 cost_fix 冲销行对应恰好一笔被它补记、且已撤销的卖出；每笔这样的卖出也恰好对应一条。
 * 净额：原 cost_fix 加上它的全部冲销 = 仍有效的被补记卖出的合计。
 */
function assertCostFixReversals(rows: Row[]) {
  const seen = new Set<number>();
  for (const r of rows) {
    if (r.type !== "cost_fix" || r.reverses === null) continue;
    const f = rows[r.reverses]!;
    check(f.covers !== null, `cost_fix 冲销行 ${r.idx} 指向的第 ${f.idx} 行不是原 cost_fix`);
    const prev = rows[r.idx - 1];
    check(prev !== undefined && prev.type === "sale" && prev.reverses !== null, `cost_fix 冲销行 ${r.idx} 前面不是卖出的冲销行`);
    const sold = rows[prev!.reverses!]!;
    check(sold.costFixBy === f.idx && sold.voided, `cost_fix 冲销行 ${r.idx} 冲的卖出第 ${sold.idx} 行不是被第 ${f.idx} 行补记、已撤销的`);
    check(!seen.has(sold.idx), `被补记的卖出第 ${sold.idx} 行冲了两次 cost_fix`);
    seen.add(sold.idx);
    const b = f.unit_cost_fen!;
    const n = -sold.qty_delta;
    check(r.amount_fen === -sold.amount_fen, `cost_fix 冲销行 ${r.idx} 的实收 ${r.amount_fen} 不是 −${sold.amount_fen}`);
    check(r.cogs_fen === -(n * b), `cost_fix 冲销行 ${r.idx} 的进价 ${r.cogs_fen} 不是 −${n} × ${b}（原补记的 b）`);
    check(r.qty_delta === 0n && r.list_amount_fen === 0n && r.value_delta_fen === 0n && !r.cost_missing, `cost_fix 冲销行 ${r.idx} 的其余字段不是 0`);
    if (n * b !== 0n) {
      const adj = rows[r.idx + 1];
      check(adj !== undefined && adj.type === "cost_adjust" && adj.value_delta_fen === n * b, `cost_fix 冲销行 ${r.idx} 后面没有 +${n} × ${b} 的 cost_adjust`);
    }
  }
  for (const r of rows) {
    if (r.type === "sale" && r.costFixBy !== null && r.voided) check(seen.has(r.idx), `被补记的卖出第 ${r.idx} 行撤销了但没有冲 cost_fix`);
  }
  for (const f of rows) {
    if (f.type !== "cost_fix" || f.covers === null) continue;
    const all = rows.filter((r) => r.idx === f.idx || (r.type === "cost_fix" && r.reverses === f.idx));
    const live = f.covers.map((i) => rows[i]!).filter((x) => !x.voided);
    const sum = (xs: Row[], k: (r: Row) => bigint) => xs.reduce((x, r) => x + k(r), 0n);
    check(sum(all, (r) => r.amount_fen) === sum(live, (x) => x.amount_fen), `cost_fix ${f.idx} 含冲销的实收净额不等于仍有效的被补记卖出合计`);
    check(sum(all, (r) => r.cogs_fen) === sum(live, (x) => -x.qty_delta) * f.unit_cost_fen!, `cost_fix ${f.idx} 含冲销的进价净额不等于仍有效的被补记卖出合计`);
  }
}

/** 状态和每条流水都存得进库（stock_qty、qty_delta 是 integer，其余金额是 bigint，且都在契约安全整数范围内） */
export function assertStorable(state: CostState, rows: Row[]) {
  const ok = (x: bigint, r: { min: bigint; max: bigint }) => x >= r.min && x <= r.max;
  check(ok(state.q, INT32) && ok(state.v, FEN) && (state.c === null || ok(state.c, FEN)), `状态超出列范围：q=${state.q} v=${state.v} c=${state.c}`);
  for (const r of rows) {
    check(ok(r.qty_delta, INT32), `第 ${r.idx} 行 qty_delta 超出 integer`);
    for (const k of ["amount_fen", "list_amount_fen", "cogs_fen", "value_delta_fen"] as const) check(ok(r[k], FEN), `第 ${r.idx} 行 ${k} = ${r[k]} 超出 FEN（bigint ∩ 安全整数）`);
    check(r.unit_cost_fen === null || ok(r.unit_cost_fen, FEN), `第 ${r.idx} 行 unit_cost_fen 超出 FEN（bigint ∩ 安全整数）`);
  }
}
