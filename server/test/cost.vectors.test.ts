// S05a：§5.2 移动加权平均的纯算法。contracts/vectors/cost.json 逐组、逐步、逐分对照；fast-check 随机动作序列断言 I1–I3
// 和冲销 / 成本补记的结构性质（invariants.ts）。数据库里的应用、并发与重放在 S05b。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { CostError, unitCost, type CostState } from "../src/ledger/cost.ts";
import { assertLedger, MemLedger, type Action } from "../src/ledger/invariants.ts";
import { CONTRACTS_DIR } from "./helpers/contract.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
const { cases } = JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "vectors", "cost.json"), "utf8")) as { cases: Any[] };

const big = (x: number | null) => (x === null ? null : BigInt(x));
const toState = (s: Any): CostState => ({ q: BigInt(s.q), v: BigInt(s.v), c: big(s.c), k: s.k });

function toAction(a: Any, stepRows: number[][]): Action {
  switch (a.type) {
    case "stock_in":
      return { type: "stock_in", pack_qty: BigInt(a.pack_qty), pack_count: BigInt(a.pack_count), unit_cost_fen: BigInt(a.unit_cost_fen) };
    case "sale":
      return { type: "sale", pack_qty: BigInt(a.pack_qty), pack_count: BigInt(a.pack_count), amount_fen: BigInt(a.amount_fen), list_amount_fen: BigInt(a.list_amount_fen) };
    case "opening":
      return { type: "opening", counted_qty: BigInt(a.counted_qty), unit_cost_fen: big(a.unit_cost_fen) };
    case "count":
      return { type: "count", counted_qty: BigInt(a.counted_qty) };
    case "expire_loss":
    case "supplier_return":
      return { type: a.type, qty: BigInt(a.qty) };
    case "void":
      return { type: "void", target: stepRows[a.target_step]![0]! };
    default:
      throw new Error(`cost.json 里有不认识的动作 ${a.type}`);
  }
}

describe("cost.json", () => {
  it("24 组，必过向量 8 组都在", () => {
    expect(cases.length).toBe(24);
    expect(cases.filter((c) => c.must_pass).map((c) => c.id)).toEqual(["cost-01", "cost-02", "cost-03", "cost-04", "cost-05", "cost-06", "cost-19", "cost-21"]);
  });
  for (const c of cases) {
    it(`${c.id}${c.must_pass ? "（必过）" : ""}：${c.title}`, () => {
      const l = new MemLedger(toState(c.initial));
      const stepRows: number[][] = [];
      c.steps.forEach((s: Any, i: number) => {
        const rows = l.apply(toAction(s.action, stepRows));
        stepRows.push(rows);
        const want = s.expect.entries as Any[];
        const got = rows.map((r) => l.rows[r]!);
        expect(got.map((r) => r.type), `${c.id} 第 ${i} 步的流水类型`).toEqual(want.map((w) => w.type));
        want.forEach((w, j) => {
          const g = got[j]!;
          const at = `${c.id} 第 ${i} 步第 ${j} 条（${w.type}）`;
          for (const k of ["qty_delta", "amount_fen", "list_amount_fen", "cogs_fen", "value_delta_fen"] as const) expect(Number(g[k]), `${at} ${k}`).toBe(w[k]);
          expect(g.cost_missing, `${at} cost_missing`).toBe(w.cost_missing);
          if ("unit_cost_fen" in w) expect(big(w.unit_cost_fen === undefined ? null : w.unit_cost_fen), `${at} unit_cost_fen`).toBe(g.unit_cost_fen);
          if ("reverses_step" in w) {
            const target = stepRows[w.reverses_step]!.find((x) => l.rows[x]!.type === w.type);
            expect(g.reverses, `${at} reverses`).toBe(target);
          } else expect(g.reverses, `${at} 不是冲销行`).toBeNull();
          if ("covers_steps" in w) {
            const covered = (w.covers_steps as number[]).map((st) => stepRows[st]!.find((x) => l.rows[x]!.type === "sale"));
            expect(g.covers, `${at} covers`).toEqual(covered);
            for (const x of covered) {
              // 原行写上 cost_fix_entry_id，本身的 cogs / value_delta 不改
              expect(l.rows[x!]!.costFixBy).toBe(g.idx);
            }
          }
        });
        const st = s.expect.state;
        expect({ q: Number(l.state.q), v: Number(l.state.v), c: l.state.c === null ? null : Number(l.state.c), k: l.state.k }, `${c.id} 第 ${i} 步之后的状态`).toEqual({
          q: st.q,
          v: st.v,
          c: st.c,
          k: st.k,
        });
        const u = unitCost(l.state);
        expect(u === null ? null : Number(u), `${c.id} 第 ${i} 步之后的 u`).toBe(st.u);
        assertLedger(l.initial, l.state, l.rows);
      });
    });
  }
});

describe("§5.2 单条规则", () => {
  const unknown: CostState = { q: 0n, v: 0n, c: null, k: false };
  it("正库存但进价没填时卖出 → cost_missing、cogs 0（不进「赚了」）", () => {
    const l = new MemLedger({ q: 10n, v: 0n, c: null, k: false });
    const [r] = l.apply({ type: "sale", pack_qty: 1n, pack_count: 1n, amount_fen: 300n, list_amount_fen: 300n });
    expect(l.rows[r!]).toMatchObject({ cost_missing: true, cogs_fen: 0n, value_delta_fen: 0n });
  });
  it("明确零成本的商品卖出不标 cost_missing", () => {
    const l = new MemLedger(unknown);
    l.apply({ type: "opening", counted_qty: 5n, unit_cost_fen: 0n });
    const [r] = l.apply({ type: "sale", pack_qty: 1n, pack_count: 1n, amount_fen: 100n, list_amount_fen: 100n });
    expect(l.rows[r!]).toMatchObject({ cost_missing: false, cogs_fen: 0n });
  });
  it("进货 0 个被拒（不能算单位成本），状态不变", () => {
    const l = new MemLedger(unknown);
    expect(() => l.apply({ type: "stock_in", pack_qty: 1n, pack_count: 0n, unit_cost_fen: 100n })).toThrow(CostError);
    expect(l.rows).toEqual([]);
    expect(l.state).toEqual(unknown);
  });
  it("撤销两次：第二次无操作；冲销行、cost_adjust、cost_fix 不能直接撤销", () => {
    const l = new MemLedger(unknown);
    const [s] = l.apply({ type: "stock_in", pack_qty: 1n, pack_count: 10n, unit_cost_fen: 100n });
    const rev = l.apply({ type: "void", target: s! });
    expect(l.apply({ type: "void", target: s! })).toEqual([]);
    expect(() => l.apply({ type: "void", target: rev[0]! })).toThrow(CostError);
    const l2 = new MemLedger({ q: -1n, v: -30n, c: 30n, k: true });
    const [, adj] = l2.apply({ type: "stock_in", pack_qty: 3n, pack_count: 1n, unit_cost_fen: 100n });
    expect(l2.rows[adj!]!.type).toBe("cost_adjust");
    expect(() => l2.apply({ type: "void", target: adj! })).toThrow(CostError);
  });
});

// ── 性质测试 ──
const big0 = (min: number, max: number) => fc.integer({ min, max }).map(BigInt);
const initialArb: fc.Arbitrary<CostState> = fc.oneof(
  fc.record({ q: big0(-50, 50), v: fc.constant(0n), c: fc.constant(null), k: fc.constant(false) }),
  fc
    .record({ q: big0(-50, 50), c: big0(0, 5000), v0: big0(0, 300_000) })
    .map(({ q, c, v0 }) => ({ q, c, v: q > 0n ? v0 : q * c, k: true })),
);
const actionArb: fc.Arbitrary<Action> = fc.oneof(
  { weight: 3, arbitrary: fc.record({ type: fc.constant("stock_in" as const), pack_qty: big0(1, 24), pack_count: big0(0, 20), unit_cost_fen: big0(0, 50_000) }) },
  {
    weight: 4,
    arbitrary: fc.record({ type: fc.constant("sale" as const), pack_qty: big0(1, 24), pack_count: big0(0, 20), amount_fen: big0(0, 100_000), list_amount_fen: big0(0, 100_000) }),
  },
  { weight: 2, arbitrary: fc.record({ type: fc.constant("opening" as const), counted_qty: big0(0, 300), unit_cost_fen: fc.option(big0(0, 5000), { nil: null }) }) },
  { weight: 1, arbitrary: fc.record({ type: fc.constant("count" as const), counted_qty: big0(0, 300) }) },
  { weight: 1, arbitrary: fc.record({ type: fc.constantFrom("expire_loss" as const, "supplier_return" as const), qty: big0(0, 60) }) },
  { weight: 3, arbitrary: fc.record({ type: fc.constant("void" as const), target: fc.nat(80) }) },
);

/** 随机序列：撤销的目标在已有的行里取模；CostError（进货 0 个、撤销自动行）要求什么都不改 */
function run(initial: CostState, actions: Action[]) {
  const l = new MemLedger(initial);
  let wasKnown = initial.k;
  for (const a0 of actions) {
    const a = a0.type === "void" ? { ...a0, target: l.rows.length ? a0.target % l.rows.length : 0 } : a0;
    const before = { state: l.state, n: l.rows.length };
    try {
      l.apply(a);
    } catch (e) {
      if (!(e instanceof CostError)) throw e;
      expect(l.state).toEqual(before.state);
      expect(l.rows.length).toBe(before.n);
    }
    assertLedger(l.initial, l.state, l.rows);
    // k 只增不减
    if (wasKnown) expect(l.state.k).toBe(true);
    wasKnown = l.state.k;
  }
  return l;
}

describe("性质测试（fast-check）", () => {
  it("随机动作序列（500 组）：每一步之后 I1、I2、I3 和冲销 / 补记的结构性质都成立，k 只增不减", () => {
    fc.assert(
      fc.property(initialArb, fc.array(actionArb, { minLength: 1, maxLength: 60 }), (init, actions) => {
        run(init, actions);
      }),
      { numRuns: 500 },
    );
  });
  it("确定性：同一序列重放得到逐分相同的流水和状态（纯算法层面的 I5）", () => {
    fc.assert(
      fc.property(initialArb, fc.array(actionArb, { minLength: 1, maxLength: 40 }), (init, actions) => {
        const a = run(init, actions);
        const b = run(init, actions);
        expect(b.rows).toEqual(a.rows);
        expect(b.state).toEqual(a.state);
      }),
      { numRuns: 500 },
    );
  });
  it("撤销一笔卖出再原样重卖：库存数量回到撤销前；进价已知且库存为正时货值也回到撤销前", () => {
    fc.assert(
      fc.property(initialArb, fc.array(actionArb, { maxLength: 30 }), big0(0, 20), (init, actions, n) => {
        const l = run(init, actions);
        const s0 = l.state;
        const [r] = l.apply({ type: "sale", pack_qty: 1n, pack_count: n, amount_fen: 100n, list_amount_fen: 100n });
        l.apply({ type: "void", target: r! });
        assertLedger(l.initial, l.state, l.rows);
        expect(l.state.q).toBe(s0.q);
        if (s0.k && s0.q - n > 0n) expect(l.state.v).toBe(s0.v);
      }),
      { numRuns: 500 },
    );
  });
});
