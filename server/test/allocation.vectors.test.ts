// S04（§14 S12-4）：服务器跑和手机同一份向量。roundDiv（§5.0）和优惠分摊（§5.1）逐组与 contracts/vectors 对照。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { roundDiv } from "../src/ledger/rounddiv.ts";
import { allocate, AllocationError } from "../src/ledger/allocation.ts";
import { CONTRACTS_DIR } from "./helpers/contract.ts";

const load = (name: string) => JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "vectors", name), "utf8"));

interface RdCase {
  id: string;
  numerator_factors: number[];
  b: number;
  expected: number;
}
interface AllocCase {
  id: string;
  lines: Array<{ unit_price_fen: number; pack_count: number; pack_qty?: number }>;
  paid_total_fen: number;
  expect: { list_fen: number[]; list_total_fen: number; amount_fen: number[] } | { error: "invalid" };
}

describe("rounddiv.json", () => {
  const { cases } = load("rounddiv.json") as { cases: RdCase[] };
  it("向量不少于 20 组", () => expect(cases.length).toBeGreaterThanOrEqual(20));
  for (const c of cases) {
    it(`${c.id}: roundDiv(${c.numerator_factors.join("×")}, ${c.b}) = ${c.expected}`, () => {
      const a = c.numerator_factors.reduce((x, y) => x * BigInt(y), 1n);
      expect(roundDiv(a, BigInt(c.b))).toBe(BigInt(c.expected));
    });
  }
  it("除数不是正数时抛错", () => {
    expect(() => roundDiv(1n, 0n)).toThrow();
    expect(() => roundDiv(1n, -2n)).toThrow();
  });
  it("性质：roundDiv(−a, b) = −roundDiv(a, b)，且 |a/b − roundDiv(a, b)| ≤ 1/2", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: -(2n ** 63n), max: 2n ** 63n }), fc.bigInt({ min: 1n, max: 2n ** 40n }), (a, b) => {
        const q = roundDiv(a, b);
        expect(roundDiv(-a, b)).toBe(-q);
        const diff2 = 2n * (a - q * b); // 2·(a − q·b)，与 b 比较
        expect(diff2 <= b && diff2 >= -b).toBe(true);
        // 恰好一半时远离零
        if (diff2 === b || diff2 === -b) expect(q === 0n ? false : (q > 0n) === (a > 0n)).toBe(true);
      }),
      { numRuns: 2000 },
    );
  });
});

describe("allocation.json", () => {
  const { cases } = load("allocation.json") as { cases: AllocCase[] };
  it("向量不少于 12 组，包含必过向量 53.50 → 53.00", () => {
    expect(cases.length).toBeGreaterThanOrEqual(12);
    expect(cases.find((c) => c.id === "alloc-01")!.expect).toMatchObject({ amount_fen: [2476, 2378, 446] });
  });
  for (const c of cases) {
    it(`${c.id}`, () => {
      const run = () =>
        allocate(
          c.lines.map((l) => ({ unitPriceFen: BigInt(l.unit_price_fen), packCount: BigInt(l.pack_count), packQty: BigInt(l.pack_qty ?? 1) })),
          BigInt(c.paid_total_fen),
        );
      if ("error" in c.expect) {
        expect(run).toThrow(AllocationError);
        return;
      }
      const r = run();
      expect(r.listFen.map(Number)).toEqual(c.expect.list_fen);
      expect(Number(r.listTotalFen)).toBe(c.expect.list_total_fen);
      expect(r.amountFen.map(Number)).toEqual(c.expect.amount_fen);
    });
  }
  it("性质：在上限内任意购物篮，Σa_i = P、各行非负", () => {
    fc.assert(
      fc.property(
        fc.array(fc.record({ p: fc.integer({ min: 0, max: 99_999 }), n: fc.integer({ min: 0, max: 999 }) }), { minLength: 1, maxLength: 200 }),
        fc.integer({ min: 0, max: 2_000_000_000 }),
        (lines, paid) => {
          const ls = lines.map((l) => ({ unitPriceFen: BigInt(l.p), packCount: BigInt(l.n), packQty: 1n }));
          const total = ls.reduce((s, l) => s + l.unitPriceFen * l.packCount, 0n);
          const P = total === 0n ? 0n : BigInt(paid);
          const r = allocate(ls, P);
          expect(r.amountFen.reduce((s, x) => s + x, 0n)).toBe(P);
          expect(r.amountFen.every((x) => x >= 0n)).toBe(true);
        },
      ),
      { numRuns: 500 },
    );
  });
});
