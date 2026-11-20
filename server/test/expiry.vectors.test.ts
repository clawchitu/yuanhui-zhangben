// S06：保质期批次的纯算法（§5.4）。contracts/vectors/expiry.json 的 add_months / remind / deduct / handle_ver 在这里逐条对照；
// dispose / undo 两组要经 /v1/sync 写库，在 ledger.lots.test.ts 里逐条跑。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { addMonths, checkHandle, planDeduct, shouldRemind } from "../src/ledger/lots.ts";
import { CONTRACTS_DIR } from "./helpers/contract.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
const V = JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "vectors", "expiry.json"), "utf8")) as Any;

describe("expiry.json", () => {
  it.each(V.add_months as Any[])("add_months $id：$start + $months 个月 = $expected", (c) => {
    expect(addMonths(c.start, c.months)).toBe(c.expected);
  });

  it.each(V.remind as Any[])("remind $id：$note", (c) => {
    expect(
      shouldRemind(c.today, {
        expiry_date: c.lot.expiry_date,
        expiry_warn_days: c.lot.expiry_warn_days,
        qty_left: c.lot.qty_left,
        closed: c.lot.closed,
        snoozed_until: c.lot.snoozed_until,
      }),
    ).toBe(c.expected);
  });

  it.each(V.deduct as Any[])("deduct $id：$note", (c) => {
    const lots = (c.lots as Any[]).map((l) => ({ id: l.lot_id, expiry_date: l.expiry_date, qty_left: l.qty_left, closed: l.closed, seq: BigInt(l.seq) }));
    const r = planDeduct(lots, c.qty);
    expect({ moves: r.moves.map((m) => ({ lot_id: m.id, qty: m.qty })), unassigned: r.unassigned }).toEqual(c.expected);
  });

  it.each(V.handle_ver as Any[])("handle_ver $id：$note", (c) => {
    const r = checkHandle({ handle_ver: c.lot.handle_ver, closed: c.lot.closed }, c.op_handle_ver);
    expect(r).toEqual(c.expected.result === "ok" ? { result: "ok", new_handle_ver: c.expected.new_handle_ver } : { result: "stale" });
  });

  it("dispose、undo 两组也都有（在 ledger.lots.test.ts 经同步接口跑）", () => {
    expect(V.dispose.length).toBe(5);
    expect(V.undo.length).toBe(5);
  });
});
