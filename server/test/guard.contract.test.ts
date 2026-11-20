// guard 的契约级测试（S03 验收）：对 permissions.json 里的每一格（身份 × 接口 / op 类型 / 拉取）断言判定结果。
// 只调 guard 的纯函数，不依赖业务路由是否已经实现。
// 每一格：条件全满足时的结果，以及每个条件单独不满足时的结果；写账类的格子再测注销期间。
import { describe, expect, it } from "vitest";
import { Guard, REVOKE_WINDOW_MS, type Facts, type Verdict } from "../src/auth/guard.ts";
import { IDENTITIES, loadPermissions, opTypeOf, type Cell, type Condition, type Identity, type Rule } from "../src/auth/permissions.ts";

const perms = loadPermissions();
const guard = new Guard(perms);

const NOW = new Date("2026-11-20T04:00:00Z"); // 上海 12:00
const ME = "00000000-0000-4000-8000-000000000001";
const OTHER = "00000000-0000-4000-8000-000000000002";
const REVOKED_AT = new Date(NOW.getTime() - 24 * 3600e3);

const quickPayload = { product_id: ME, barcode: "6901", name: "可乐", price_fen: 300, quick: true };
const fullPayload = { ...quickPayload, quick: false, base_unit: "瓶", low_at: 3 };

/** 所有条件都满足的事实 */
function okFacts(): Facts {
  return {
    now: NOW,
    config: { demoLoginEnabled: true, recoveryMode: true },
    callerDeviceId: ME,
    targetDeviceId: OTHER,
    revokedAt: REVOKED_AT,
    opOccurredAt: new Date(REVOKED_AT.getTime() - 60_000),
    targetSale: { deviceId: ME, occurredAt: new Date(NOW.getTime() - 3600e3) },
    deletePending: false,
  };
}

/** 只让一个条件不满足 */
const breakers: Record<Condition, (f: Facts) => Facts> = {
  own_device_sale: (f) => ({ ...f, targetSale: { ...f.targetSale!, deviceId: OTHER } }),
  // 上海时间前一天 23:00
  sale_day_eq_server_receive_day: (f) => ({ ...f, targetSale: { ...f.targetSale!, occurredAt: new Date("2026-11-19T15:00:00Z") } }),
  quick_only: (f) => f, // 由 payload 决定，见 payloadFor
  occurred_at_lte_revoked_at: (f) => ({ ...f, opOccurredAt: new Date(REVOKED_AT.getTime() + 1) }),
  within_revoke_window: (f) => ({ ...f, now: new Date(REVOKED_AT.getTime() + REVOKE_WINDOW_MS + 1) }),
  not_self: (f) => ({ ...f, targetDeviceId: ME }),
  demo_login_enabled: (f) => ({ ...f, config: { ...f.config, demoLoginEnabled: false } }),
  recovery_mode_on: (f) => ({ ...f, config: { ...f.config, recoveryMode: false } }),
};

function payloadFor(rule: Rule): Record<string, unknown> {
  if (rule.kind !== "op") return {};
  if (opTypeOf(rule) === "product_upsert") return rule.match?.quick === true ? quickPayload : fullPayload;
  return { entry_id: ME };
}

function run(rule: Rule, identity: Identity, f: Facts): Verdict {
  if (rule.kind === "http") return guard.decideHttp(rule.method, rule.path, identity, f);
  if (rule.kind === "op") return guard.decideOp(opTypeOf(rule), payloadFor(rule), identity, f);
  return guard.decidePull(identity, f);
}

/** 写账、开通类（permissions.json global「注销期间禁止写账和开通设备」） */
const WRITES = new Set(["POST /v1/pairing-tokens", "POST /v1/held-ops/{id}/resolve", "POST /v1/recovery/import"]);
const isWrite = (r: Rule) => r.kind === "op" || WRITES.has(r.id);

/** 拒绝时期望的错误：被踢设备的 HTTP 拒绝是 401 revoked；op 一律 forbidden */
function expectDenied(v: Verdict, rule: Rule, identity: Identity) {
  expect(v.ok).toBe(false);
  if (rule.kind === "op") expect(v.code).toBe("forbidden");
  else if (identity === "revoked") expect([v.status, v.code]).toEqual([401, "revoked"]);
  else expect([v.status, v.code]).toEqual([403, "forbidden"]);
}

const CONDITION_ERRORS: Partial<Record<Condition, [number, string]>> = {
  demo_login_enabled: [404, "demo_disabled"],
  recovery_mode_on: [403, "recovery_disabled"],
  not_self: [400, "cannot_revoke_self"],
};

describe("guard × permissions.json 每一格", () => {
  for (const rule of perms.rules) {
    for (const identity of IDENTITIES) {
      const cell: Cell = rule[identity];
      it(`${rule.id} × ${identity} = ${cell.decision}${cell.conditions ? ` [${cell.conditions.join(", ")}]` : ""}`, () => {
        const v = run(rule, identity, okFacts());
        expect(v.decision).toBe(cell.decision);
        expect(v.scope).toBe(cell.scope);

        if (cell.decision === "deny" || cell.decision === "not_applicable") {
          expectDenied(v, rule, identity);
          return;
        }
        // public / allow / held：条件全满足时放行
        expect(v.ok, JSON.stringify(v)).toBe(true);
        expect(v.held).toBe(cell.decision === "held");

        // 每个条件单独不满足 → 拒
        for (const c of cell.conditions ?? []) {
          const bad =
            c === "quick_only"
              ? guard.decideOp(opTypeOf(rule as never), { ...quickPayload, base_unit: "瓶" }, identity, okFacts())
              : run(rule, identity, breakers[c](okFacts()));
          expect(bad.ok, `条件 ${c} 不满足应拒`).toBe(false);
          expect(bad.failed).toContain(c);
          if (rule.kind === "op" || cell.decision === "held") expect(bad.code).toBe("forbidden");
          else expect([bad.status, bad.code]).toEqual(CONDITION_ERRORS[c] ?? [403, "forbidden"]);
        }

        // 注销期间：写账、开通类拒 delete_pending，其余不受影响
        const pending = run(rule, identity, { ...okFacts(), deletePending: true });
        if (isWrite(rule)) {
          expect(pending.ok).toBe(false);
          expect(pending.code).toBe("delete_pending");
        } else {
          expect(pending.ok).toBe(true);
        }
      });
    }
  }
});

// 和 §6.1 的表逐格对一遍（防止 permissions.json 被改得和计划不一致而 guard 测试照样全绿）。
// P=不需登录 A=能 D=拒 H=暂存 -=不适用；顺序：家用、收银员、审核、被踢。
const PLAN_6_1: Record<string, string> = {
  "GET /healthz": "PPP-",
  "GET /v1/config": "PPP-",
  "POST /v1/auth/login": "PPP-",
  "POST /v1/auth/pair/redeem": "PPP-",
  "POST /v1/auth/demo": "PPP-",
  "POST /v1/auth/logout": "AAA-",
  "GET /v1/me": "AAAD",
  "POST /v1/sync": "AAAA",
  "sync:pull": "AAAD",
  "GET /v1/barcode-lookup/{barcode}": "AAAD",
  "GET /v1/images/{product_id}": "AAAD",
  "GET /v1/reports/today": "ADAD",
  "GET /v1/reports/month": "ADAD",
  "GET /v1/entries": "ADAD",
  "GET /v1/entries/days": "ADAD",
  "POST /v1/pairing-tokens": "ADAD",
  "GET /v1/pairing-tokens/{id}": "ADAD",
  "GET /v1/devices": "ADAD",
  "POST /v1/devices/{id}/revoke": "ADAD",
  "POST /v1/devices/revoke-others": "ADAD",
  "PATCH /v1/devices/me": "ADAD",
  "GET /v1/held-ops": "ADAD",
  "POST /v1/held-ops/{id}/resolve": "ADAD",
  "POST /v1/recovery/import": "AADD",
  "POST /v1/account/password": "ADAD",
  "POST /v1/account/delete-request": "ADAD",
  "POST /v1/account/delete-cancel": "ADAD",
  "op:sale_batch": "AAAA",
  "op:void": "AAAH",
  "op:product_upsert[quick]": "AAAA",
  "op:product_upsert[full]": "ADAH",
  "op:product_edit": "ADAH",
  "op:barcode_link": "ADAH",
  "op:barcode_unlink": "ADAH",
  "op:stock_in": "ADAH",
  "op:opening": "ADAH",
  "op:product_review_complete": "ADAH",
  "op:count": "ADAH",
  "op:expiry_dispose": "ADAH",
  "op:lot_snooze": "ADAH",
};
const LETTER = { public: "P", allow: "A", deny: "D", held: "H", not_applicable: "-" } as const;

describe("permissions.json 与 §6.1 一致", () => {
  it("行一一对应，每格判定相同", () => {
    expect(perms.rules.map((r) => r.id).sort()).toEqual(Object.keys(PLAN_6_1).sort());
    for (const r of perms.rules) {
      expect(IDENTITIES.map((i) => LETTER[r[i].decision]).join(""), r.id).toBe(PLAN_6_1[r.id]);
    }
  });

  it("收银员撤销：只能本机、且卖出日期 = 服务器收到那天；被踢设备的 op 都要求被踢前、30 天内", () => {
    const voidRule = perms.rules.find((r) => r.id === "op:void")!;
    expect(voidRule.cashier.conditions).toEqual(["own_device_sale", "sale_day_eq_server_receive_day"]);
    for (const r of perms.rules.filter((r) => r.kind === "op")) {
      expect(r.revoked.conditions, r.id).toEqual(["occurred_at_lte_revoked_at", "within_revoke_window"]);
    }
  });
});

describe("guard 的边界", () => {
  it("权限表里没有的接口、op 类型一律拒", () => {
    expect(guard.decideHttp("GET", "/v1/secret", "family", okFacts())).toMatchObject({ ok: false, status: 403 });
    expect(guard.decideOp("drop_table", {}, "family", okFacts())).toMatchObject({ ok: false, code: "forbidden" });
  });

  it("product_upsert 不带 quick（选不到行）→ 拒", () => {
    const { quick: _q, ...noQuick } = quickPayload;
    expect(guard.decideOp("product_upsert", noQuick, "family", okFacts()).ok).toBe(false);
  });

  it("缺了判定需要的事实 → 按不满足处理（宁拒勿放）", () => {
    const f = { ...okFacts(), targetSale: undefined };
    expect(guard.decideOp("void", { target: {} }, "cashier", f)).toMatchObject({ ok: false, code: "forbidden" });
    const g = { ...okFacts(), revokedAt: null };
    expect(guard.decideOp("sale_batch", {}, "revoked", g)).toMatchObject({ ok: false, code: "forbidden" });
  });

  it("收银员撤销本机当天的卖出（上海时区）：0 点前后", () => {
    // 服务器收到时是上海 11-20 00:30；卖出在上海 11-19 23:50 → 不是同一天
    const now = new Date("2026-11-19T16:30:00Z");
    const f = { ...okFacts(), now, targetSale: { deviceId: ME, occurredAt: new Date("2026-11-19T15:50:00Z") } };
    expect(guard.decideOp("void", {}, "cashier", f).ok).toBe(false);
    const g = { ...f, targetSale: { deviceId: ME, occurredAt: new Date("2026-11-19T16:10:00Z") } };
    expect(guard.decideOp("void", {}, "cashier", g).ok).toBe(true);
  });

  it("被踢设备：被踢前的卖出直接收、被踢前的进货暂存、被踢后的一律拒", () => {
    expect(guard.decideOp("sale_batch", {}, "revoked", okFacts())).toMatchObject({ ok: true, held: false });
    expect(guard.decideOp("stock_in", {}, "revoked", okFacts())).toMatchObject({ ok: true, held: true });
    const late = breakers.occurred_at_lte_revoked_at(okFacts());
    expect(guard.decideOp("sale_batch", {}, "revoked", late).ok).toBe(false);
    expect(guard.decideOp("stock_in", {}, "revoked", late).ok).toBe(false);
  });
});
