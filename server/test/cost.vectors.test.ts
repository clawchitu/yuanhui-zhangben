// S05a：§5.2 移动加权平均的纯算法。contracts/vectors/cost.json 逐组、逐步、逐分对照；fast-check 随机动作序列断言 I1–I3
// 和冲销 / 成本补记的结构性质（invariants.ts）。数据库里的应用、并发与重放在 S05b。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { CostError, INT32, INT64, unitCost, type CostState } from "../src/ledger/cost.ts";
import { roundDiv } from "../src/ledger/rounddiv.ts";
import { assertLedger, MemLedger, type Action, type Row } from "../src/ledger/invariants.ts";
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

// ── 列范围（§14 S05-4 第二层）：算出来存不进 integer / bigint 列的，整步拒 invalid，什么都不改 ──
/** 应用一个动作，期望被拒且账本原样不动 */
function expectRejected(l: MemLedger, a: Action) {
  const before = { state: l.state, rows: structuredClone(l.rows) };
  expect(() => l.apply(a)).toThrow(CostError);
  expect(l.state).toEqual(before.state);
  expect(l.rows).toEqual(before.rows);
}

describe("列范围（stock_qty、qty_delta 是 integer，金额是 bigint）", () => {
  it("Codex 复现：期初 9,999,998 个进价 0 → 期初 9,999,999 个进价 99,999,999 → 撤销第一次期初 → 卖 10,000 个：cogs 超出 Int64，拒绝", () => {
    const l = new MemLedger({ q: 0n, v: 0n, c: null, k: false });
    const [first] = l.apply({ type: "opening", counted_qty: 9_999_998n, unit_cost_fen: 0n });
    l.apply({ type: "opening", counted_qty: 9_999_999n, unit_cost_fen: 99_999_999n });
    l.apply({ type: "void", target: first! });
    expect(l.state).toEqual({ q: 1n, v: 999_999_890_000_001n, c: 99_999_999n, k: true });
    // 不加检查时这一步得到 cogs_fen = 9,999,998,900,000,010,000 > 2^63 − 1
    expectRejected(l, { type: "sale", pack_qty: 1n, pack_count: 10_000n, amount_fen: 100n, list_amount_fen: 100n });
    // 同样越界的扔掉、退货也拒；不越界的卖出照常
    expectRejected(l, { type: "expire_loss", qty: 10_000n });
    expectRejected(l, { type: "supplier_return", qty: 10_000n });
    l.apply({ type: "sale", pack_qty: 1n, pack_count: 9_000n, amount_fen: 100n, list_amount_fen: 100n });
    assertLedger(l.initial, l.state, l.rows);
  });

  it("货值恰好 2^63 − 1 收，再多 1 分拒", () => {
    const T = 99_999_999n;
    const ok = new MemLedger({ q: 1n, v: INT64.max - T, c: 1n, k: true });
    ok.apply({ type: "stock_in", pack_qty: 1n, pack_count: 1n, unit_cost_fen: T });
    expect(ok.state.v).toBe(INT64.max);
    assertLedger(ok.initial, ok.state, ok.rows);
    expectRejected(new MemLedger({ q: 1n, v: INT64.max - T + 1n, c: 1n, k: true }), { type: "stock_in", pack_qty: 1n, pack_count: 1n, unit_cost_fen: T });
  });

  it("库存数恰好 2^31 − 1 收，再多 1 个拒；负库存恰好 −2^31 收，再少 1 个拒", () => {
    const n = 9_999_999n;
    const up = (q: bigint) => new MemLedger({ q, v: 0n, c: 0n, k: true });
    const exact = up(INT32.max - 9_999_000n);
    exact.apply({ type: "stock_in", pack_qty: 9_999n, pack_count: 1_000n, unit_cost_fen: 0n });
    expect(exact.state.q).toBe(INT32.max);
    expectRejected(up(INT32.max - 9_999_000n + 1n), { type: "stock_in", pack_qty: 9_999n, pack_count: 1_000n, unit_cost_fen: 0n });
    const down = (q: bigint) => new MemLedger({ q, v: 0n, c: null, k: false });
    const low = down(INT32.min + n);
    low.apply({ type: "sale", pack_qty: 1n, pack_count: n, amount_fen: 0n, list_amount_fen: 0n });
    expect(low.state.q).toBe(INT32.min);
    expectRejected(down(INT32.min + n - 1n), { type: "sale", pack_qty: 1n, pack_count: n, amount_fen: 0n, list_amount_fen: 0n });
  });
});

describe("列范围的性质测试：贴着列上限的状态 + §5.0 上限内的动作", () => {
  const near = (lo: bigint, hi: bigint, span: bigint) =>
    fc.oneof(fc.bigInt({ min: lo, max: lo + span }), fc.bigInt({ min: hi - span, max: hi }), fc.bigInt({ min: lo, max: hi }));
  const initialNear: fc.Arbitrary<CostState> = fc.oneof(
    near(INT32.min, INT32.max, 30_000_000n).map((q) => ({ q, v: 0n, c: null, k: false })),
    fc
      .record({ q: fc.oneof(fc.bigInt({ min: 1n, max: 100n }), near(1n, INT32.max, 30_000_000n)), v: near(0n, INT64.max, 10n ** 16n), c: fc.bigInt({ min: 0n, max: 99_999_999n }) })
      .map(({ q, v, c }) => ({ q, v, c, k: true })),
    fc
      .record({ q: fc.oneof(fc.bigInt({ min: -100n, max: 0n }), near(INT32.min, 0n, 30_000_000n)), f: fc.bigInt({ min: 0n, max: 1_000_000n }) })
      .map(({ q, f }) => {
        const cmax = q === 0n ? 99_999_999n : INT64.max / -q; // 保证 c 和 q × c 都存得下
        const c = (cmax * f) / 1_000_000n;
        return { q, v: q * c, c, k: true };
      }),
  );
  const qtyArb = fc.record({ pack_qty: fc.bigInt({ min: 1n, max: 9_999n }), pack_count: fc.bigInt({ min: 1n, max: 1_000n }) }); // 件数 × 换算 ≤ 9,999,000
  const limitActionArb: fc.Arbitrary<Action> = fc.oneof(
    qtyArb.chain(({ pack_qty, pack_count }) =>
      fc.bigInt({ min: 0n, max: 99_999_999n / pack_count }).map((unit_cost_fen) => ({ type: "stock_in" as const, pack_qty, pack_count, unit_cost_fen })),
    ),
    fc
      .record({ q: qtyArb, amount_fen: fc.bigInt({ min: 0n, max: 19_999_999_800n }) })
      .map(({ q, amount_fen }) => ({ type: "sale" as const, ...q, amount_fen, list_amount_fen: amount_fen })),
    fc.record({ type: fc.constant("opening" as const), counted_qty: fc.bigInt({ min: 0n, max: 9_999_999n }), unit_cost_fen: fc.option(fc.bigInt({ min: 0n, max: 99_999_999n }), { nil: null }) }),
    fc.record({ type: fc.constant("count" as const), counted_qty: fc.bigInt({ min: 0n, max: 9_999_999n }) }),
    fc.record({ type: fc.constantFrom("expire_loss" as const, "supplier_return" as const), qty: fc.bigInt({ min: 0n, max: 9_999_999n }) }),
    fc.record({ type: fc.constant("void" as const), target: fc.nat(40) }),
  );

  it("（1,000 组）每一步要么成功且所有列都存得下，要么整步拒 invalid、什么都不改；两种结果都真的出现了", () => {
    let rejected = 0;
    let applied = 0;
    fc.assert(
      fc.property(initialNear, fc.array(limitActionArb, { minLength: 1, maxLength: 20 }), (init, actions) => {
        const l = new MemLedger(init);
        for (const a0 of actions) {
          const a = a0.type === "void" ? { ...a0, target: l.rows.length ? a0.target % l.rows.length : 0 } : a0;
          const before = { state: l.state, rows: structuredClone(l.rows) };
          try {
            l.apply(a);
            applied++;
          } catch (e) {
            if (!(e instanceof CostError)) throw e;
            if (e.message.includes("超出列范围")) rejected++;
            expect(l.state).toEqual(before.state);
            expect(l.rows).toEqual(before.rows);
          }
          assertLedger(l.initial, l.state, l.rows); // 含 assertStorable
        }
      }),
      { numRuns: 1_000 },
    );
    expect(rejected).toBeGreaterThan(50);
    expect(applied).toBeGreaterThan(1_000);
  });
});

// ── 成本补记之后撤销（§5.2）：补记 → 改变当前进价 → 撤销，同一条 cost_fix 被多次部分冲销 ──
const fixScenarioArb = fc.record({
  q0: big0(-20, 20),
  sales: fc.array(fc.record({ pack_qty: big0(1, 4), pack_count: big0(1, 5), amount_fen: big0(0, 5000) }), { minLength: 2, maxLength: 6 }),
  /** 补记之前就撤销的卖出（第 0 笔永远不撤，保证有东西可补记） */
  preVoid: fc.array(fc.boolean(), { minLength: 6, maxLength: 6 }),
  fix: fc.oneof(
    fc.record({ type: fc.constant("stock_in" as const), pack_qty: big0(1, 6), pack_count: big0(1, 10), unit_cost_fen: big0(0, 5000) }),
    fc.record({ type: fc.constant("opening" as const), counted_qty: big0(0, 60), unit_cost_fen: big0(0, 5000) }),
  ),
  /** 补记后、每次撤销前插一次进货改掉当前进价（偏移 1..3000 分，0 = 不插） */
  bumps: fc.array(fc.record({ off: big0(0, 3000), pack_qty: big0(1, 3), pack_count: big0(1, 5) }), { minLength: 7, maxLength: 7 }),
  order: fc.func(fc.integer()),
  voidTwice: fc.boolean(),
});

describe("补记 → 改变当前进价 → 撤销（定向生成器）", () => {
  it("（500 组）每次冲销 cost_fix 和返库的 cost_adjust 都用原补记的 b，不用撤销时的当前进价", () => {
    let cDiffers = 0;
    let multi = 0;
    fc.assert(
      fc.property(fixScenarioArb, (sc) => {
        const l = new MemLedger({ q: sc.q0, v: 0n, c: null, k: false });
        const step = (a: Action) => {
          const out = l.apply(a);
          assertLedger(l.initial, l.state, l.rows);
          return out;
        };
        const saleRows = sc.sales.map((x) => step({ type: "sale", ...x, list_amount_fen: x.amount_fen })[0]!);
        const pre = saleRows.filter((_, i) => i > 0 && sc.preVoid[i]);
        for (const r of pre) step({ type: "void", target: r });
        const fixOut = step(sc.fix);
        const b = sc.fix.type === "opening" ? sc.fix.unit_cost_fen : roundDiv(sc.fix.pack_count * sc.fix.unit_cost_fen, sc.fix.pack_qty * sc.fix.pack_count);
        const fixRow = fixOut.map((i) => l.rows[i]!).find((r) => r.type === "cost_fix")!;
        const covered = saleRows.filter((r) => !pre.includes(r));
        // 补记的正好是补记时仍有效的卖出（已撤销的不算），存 b
        expect(fixRow.covers).toEqual(covered);
        expect(fixRow.unit_cost_fen).toBe(b);
        // 把被补记的卖出按随机顺序逐笔撤销，每次之前先改当前进价
        const order = [...covered].sort((x, y) => sc.order(x) - sc.order(y) || x - y);
        order.forEach((target, i) => {
          const bump = sc.bumps[i]!;
          if (bump.off > 0n) step({ type: "stock_in", pack_qty: bump.pack_qty, pack_count: bump.pack_count, unit_cost_fen: (b + bump.off) * bump.pack_qty });
          if (l.state.c !== b) cDiffers++;
          const out = step({ type: "void", target }).map((x) => l.rows[x]!);
          const sold = l.rows[target]!;
          const n = -sold.qty_delta;
          // 逐分：卖出冲销 → cost_fix 冲销（−实收、−n × b）→ cost_adjust（+n × b，为 0 不记）→ 也许还有归位
          expect(out[0]).toMatchObject({ type: "sale", reverses: target });
          expect(out[1]).toMatchObject({ type: "cost_fix", reverses: fixRow.idx, amount_fen: -sold.amount_fen, cogs_fen: -(n * b), unit_cost_fen: b, qty_delta: 0n, value_delta_fen: 0n });
          if (n * b !== 0n) expect(out[2]).toMatchObject({ type: "cost_adjust", value_delta_fen: n * b });
          if (sc.voidTwice) expect(l.apply({ type: "void", target })).toEqual([]);
        });
        const revs = l.rows.filter((r: Row) => r.type === "cost_fix" && r.reverses === fixRow.idx);
        expect(revs.length).toBe(covered.length);
        if (revs.length >= 2) multi++;
        // 全部撤完，cost_fix 净额归零
        expect(fixRow.amount_fen + revs.reduce((x, r) => x + r.amount_fen, 0n)).toBe(0n);
        expect(fixRow.cogs_fen + revs.reduce((x, r) => x + r.cogs_fen, 0n)).toBe(0n);
      }),
      { numRuns: 500 },
    );
    // 生成器确实覆盖了「撤销时当前进价 ≠ b」和「同一条 cost_fix 冲两次以上」
    expect(cDiffers).toBeGreaterThan(300);
    expect(multi).toBeGreaterThan(200);
  });

  it("Codex 的例子：补记价 200 → 进货价 300 → 撤销卖出 2 个：冲销 −400、货值 2300（不是 −600、2500）", () => {
    const l = new MemLedger({ q: 0n, v: 0n, c: null, k: false });
    const [s] = l.apply({ type: "sale", pack_qty: 1n, pack_count: 2n, amount_fen: 700n, list_amount_fen: 700n });
    l.apply({ type: "stock_in", pack_qty: 1n, pack_count: 10n, unit_cost_fen: 200n }); // q 8、v 1600、补记 b = 200
    l.apply({ type: "stock_in", pack_qty: 1n, pack_count: 1n, unit_cost_fen: 300n }); // q 9、v 1900、c = 300
    const out = l.apply({ type: "void", target: s! }).map((i) => l.rows[i]!);
    expect(out.map((r) => [r.type, r.cogs_fen, r.value_delta_fen])).toEqual([
      ["sale", 0n, 0n],
      ["cost_fix", -400n, 0n],
      ["cost_adjust", 0n, 400n],
    ]);
    expect(l.state).toEqual({ q: 11n, v: 2300n, c: 300n, k: true });
    assertLedger(l.initial, l.state, l.rows);
  });
});

// ── 盘盈按当前单位成本 u（不是最近进价 c）。S05-8：cost.json 的 u ≠ c 盘盈向量由 S06 补，这里先用性质测试守住 ──
describe("盘盈 d × u", () => {
  it("Fable 的例子：库存 6、货值 24280、c = 4000，数到 8 → 盘盈 2 × 4047 = 8094", () => {
    const l = new MemLedger({ q: 6n, v: 24_280n, c: 4_000n, k: true });
    const [r] = l.apply({ type: "count", counted_qty: 8n });
    expect(l.rows[r!]).toMatchObject({ type: "count", qty_delta: 2n, value_delta_fen: 8_094n, cogs_fen: -8_094n, cost_missing: false });
    expect(l.state).toEqual({ q: 8n, v: 32_374n, c: 4_000n, k: true });
  });
  it("（500 组）进价已知、库存为正时盘盈：货值增加 = d × roundDiv(v, q)，c 不变；且 u ≠ c 的情形真的出现了", () => {
    let differs = 0;
    fc.assert(
      fc.property(big0(1, 300), big0(0, 5000), big0(0, 5000), big0(1, 300), (q, u0, c, d) => {
        const v = q * u0 + (q > 1n ? (u0 % q) : 0n); // 让 v 不总是 q 的整数倍
        const s: CostState = { q, v, c, k: true };
        const u = roundDiv(v, q);
        if (u !== c) differs++;
        const l = new MemLedger(s);
        const [r] = l.apply({ type: "count", counted_qty: q + d });
        expect(l.rows[r!]!.value_delta_fen).toBe(d * u);
        expect(l.rows[r!]!.cogs_fen).toBe(-(d * u));
        expect(l.state).toEqual({ q: q + d, v: v + d * u, c, k: true });
        assertLedger(l.initial, l.state, l.rows);
      }),
      { numRuns: 500 },
    );
    expect(differs).toBeGreaterThan(400);
  });
});
