// guard：按 contracts/permissions.json 判定「这个身份能不能调这个接口 / 发这种 op」。
// 这里是纯函数，不查库、不依赖路由：调用方把判定需要的事实（facts）传进来，缺了的事实一律按「不满足」处理（宁拒勿放）。
// HTTP 接口由 auth/plugin.ts 在每个请求的 onRequest 里调 decideHttp；op 由同步（S04 起）逐个调 decideOp。
import {
  loadPermissions,
  opTypeOf,
  type Cell,
  type Condition,
  type Decision,
  type HttpRule,
  type Identity,
  type OpRule,
  type Permissions,
  type PullRule,
  type Rule,
} from "./permissions.ts";

/** 被踢设备补传窗口（§4.5）：被踢后 30 天 */
export const REVOKE_WINDOW_MS = 30 * 24 * 3600 * 1000;

/** 收银员 quick 登记只能带这些字段（§4.3） */
const QUICK_FIELDS = new Set(["product_id", "barcode", "name", "price_fen", "quick"]);

/**
 * 「注销期间禁止写账和开通设备」（permissions.json global 第 3 条）落到哪些规则上：
 * 所有 op、出开通码、确认暂存账、恢复导入。兑码（public）在路由里另查。
 */
/** 按「服务器收到的时间」判的条件：事后补传、事后确认时不复核（originalRoleAllows） */
const TIME_OF_RECEIPT_CONDITIONS = new Set<Condition>(["sale_day_eq_server_receive_day"]);

const WRITE_HTTP_RULES = new Set(["POST /v1/pairing-tokens", "POST /v1/held-ops/{id}/resolve", "POST /v1/recovery/import"]);

export interface Facts {
  /** 服务器收到请求的时间 */
  now: Date;
  config: { demoLoginEnabled: boolean; recoveryMode: boolean };
  callerDeviceId?: string;
  /** not_self：被操作的设备 */
  targetDeviceId?: string;
  /** 调用设备的 revoked_at */
  revokedAt?: Date | null;
  /** op 的 occurred_at */
  opOccurredAt?: Date;
  /** op 的 payload（quick_only） */
  payload?: Record<string, unknown>;
  /** 被撤销的卖出（own_device_sale、sale_day_eq_server_receive_day） */
  targetSale?: { deviceId: string; occurredAt: Date };
  /** 账号在注销期间（accounts.delete_requested_at 非空） */
  deletePending?: boolean;
}

export type ErrorCode =
  | "forbidden"
  | "revoked"
  | "demo_disabled"
  | "recovery_disabled"
  | "cannot_revoke_self"
  | "delete_pending";

export interface Verdict {
  ok: boolean;
  /** 表格里这一格的判定 */
  decision: Decision;
  /** ok=true 且 decision=held：不直接入账，记为 held */
  held: boolean;
  scope?: string;
  /** 没满足的条件 */
  failed: Condition[];
  /** ok=false 时：HTTP 状态和错误码（op 只用 code，一律 rejected） */
  status?: number;
  code?: ErrorCode;
}

const SHANGHAI_DAY = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" });
/** 上海时区的日历日 YYYY-MM-DD */
export function shanghaiDay(d: Date): string {
  return SHANGHAI_DAY.format(d);
}

export function evalCondition(c: Condition, f: Facts): boolean {
  switch (c) {
    case "own_device_sale":
      return !!f.targetSale && !!f.callerDeviceId && f.targetSale.deviceId === f.callerDeviceId;
    case "sale_day_eq_server_receive_day":
      return !!f.targetSale && shanghaiDay(f.targetSale.occurredAt) === shanghaiDay(f.now);
    case "quick_only":
      return !!f.payload && f.payload.quick === true && Object.keys(f.payload).every((k) => QUICK_FIELDS.has(k));
    case "occurred_at_lte_revoked_at":
      return !!f.revokedAt && !!f.opOccurredAt && f.opOccurredAt.getTime() <= f.revokedAt.getTime();
    case "within_revoke_window":
      return !!f.revokedAt && f.now.getTime() - f.revokedAt.getTime() <= REVOKE_WINDOW_MS;
    case "not_self":
      // UUID 不分大小写（Postgres 认为是同一台设备），规范化后再比
      return !!f.targetDeviceId && !!f.callerDeviceId && f.targetDeviceId.toLowerCase() !== f.callerDeviceId.toLowerCase();
    case "demo_login_enabled":
      return f.config.demoLoginEnabled;
    case "recovery_mode_on":
      return f.config.recoveryMode;
    default: {
      const never: never = c;
      throw new Error(`permissions.json 里有 guard 不认识的条件：${String(never)}`);
    }
  }
}

/** 条件没满足时的 HTTP 状态和错误码（契约里各接口写的） */
function conditionError(c: Condition): { status: number; code: ErrorCode } {
  switch (c) {
    case "demo_login_enabled":
      return { status: 404, code: "demo_disabled" };
    case "recovery_mode_on":
      return { status: 403, code: "recovery_disabled" };
    case "not_self":
      return { status: 400, code: "cannot_revoke_self" };
    default:
      return { status: 403, code: "forbidden" };
  }
}

function judge(cell: Cell, identity: Identity, f: Facts, isWrite: boolean): Verdict {
  const failed = (cell.conditions ?? []).filter((c) => !evalCondition(c, f));
  const base = { decision: cell.decision, scope: cell.scope, failed, held: false };
  const denied = (status: number, code: ErrorCode): Verdict => ({ ...base, ok: false, status, code });
  switch (cell.decision) {
    case "deny":
    case "not_applicable": // 计划里写「—」的格子：这个身份不该来调，来了就拒
      return identity === "revoked" ? denied(401, "revoked") : denied(403, "forbidden");
    case "public":
    case "allow":
    case "held": {
      if (failed.length > 0) {
        // held 的条件不满足 = 拒收（§4.5「occurred_at > revoked_at 的任何 op 拒收」）
        const e = cell.decision === "held" ? { status: 403, code: "forbidden" as const } : conditionError(failed[0]!);
        return denied(e.status, e.code);
      }
      if (isWrite && f.deletePending) return denied(403, "delete_pending");
      return { ...base, ok: true, held: cell.decision === "held" };
    }
    default: {
      const never: never = cell.decision;
      throw new Error(`permissions.json 里有 guard 不认识的判定：${String(never)}`);
    }
  }
}

/** Fastify 路由 `/v1/devices/:id/revoke` ↔ 权限表 `/v1/devices/{id}/revoke` */
export function routeToRulePath(url: string): string {
  return url.replace(/:([A-Za-z_][A-Za-z0-9_]*)/g, "{$1}");
}

export class Guard {
  readonly perms: Permissions;
  private http = new Map<string, HttpRule>();
  private ops = new Map<string, OpRule[]>();
  private pull: PullRule | undefined;

  constructor(perms: Permissions = loadPermissions()) {
    this.perms = perms;
    for (const r of perms.rules) {
      if (r.kind === "http") this.http.set(`${r.method} ${r.path}`, r);
      else if (r.kind === "op") {
        const t = opTypeOf(r);
        this.ops.set(t, [...(this.ops.get(t) ?? []), r]);
      } else this.pull = r;
    }
  }

  httpRule(method: string, path: string): HttpRule | undefined {
    return this.http.get(`${method === "HEAD" ? "GET" : method} ${path}`);
  }

  /** 按 payload 选 op 行；没有匹配的行（未知 op 类型、match 字段取值不在表里）返回 undefined */
  opRule(type: string, payload: Record<string, unknown> | undefined): OpRule | undefined {
    const rows = this.ops.get(type);
    if (!rows) return undefined;
    return rows.find((r) => !r.match || Object.entries(r.match).every(([k, v]) => payload?.[k] === v));
  }

  decide(rule: Rule, identity: Identity, f: Facts): Verdict {
    const isWrite = rule.kind === "op" || (rule.kind === "http" && WRITE_HTTP_RULES.has(rule.id));
    return judge(rule[identity], identity, f, isWrite);
  }

  /** 权限表里没有的接口一律拒（宁拒勿放） */
  decideHttp(method: string, path: string, identity: Identity, f: Facts): Verdict {
    const rule = this.httpRule(method, path);
    if (!rule) return { ok: false, decision: "deny", held: false, failed: [], status: 403, code: "forbidden" };
    return this.decide(rule, identity, f);
  }

  /**
   * 推上来的一个 op：ok=true 且 held=false → 应用；held=true → 记为 held；ok=false → rejected: code。
   * 被踢设备被拒的 op 也是 rejected: forbidden（不是 HTTP 401：sync 照常响应，§4.5）。
   */
  decideOp(type: string, payload: Record<string, unknown> | undefined, identity: Identity, f: Facts): Verdict {
    const rule = this.opRule(type, payload);
    if (!rule) return { ok: false, decision: "deny", held: false, failed: [], status: 403, code: "forbidden" };
    const v = this.decide(rule, identity, { ...f, payload });
    return v.ok || v.code === "delete_pending" ? v : { ...v, status: 403, code: "forbidden" };
  }

  /**
   * 被踢设备的 op 再按它被踢前的身份复核一次（T37，S23a）：被踢的收银员不能借「补传 → 家里人记上」做收银员本来做不了的事
   * （进货、盘点、改商品、带家用字段的 quick 登记、撤别人的卖出）。只看和时间无关的条件：`sale_day_eq_server_receive_day`
   * 按「服务器收到那天」判，补传和确认都在事后，这条不复核（被踢那台的撤销本来就是 held，由家里人逐笔看）。
   */
  originalRoleAllows(type: string, payload: Record<string, unknown> | undefined, original: Exclude<Identity, "revoked">, f: Facts): boolean {
    const rule = this.opRule(type, payload);
    if (!rule) return false;
    const v = this.decide(rule, original, { ...f, payload, deletePending: false });
    if (v.ok) return true;
    if (v.decision !== "allow" && v.decision !== "held") return false;
    return v.failed.length > 0 && v.failed.every((c) => TIME_OF_RECEIPT_CONDITIONS.has(c));
  }

  /** 拉取：允许时带 scope（full_store / cashier_projection），被踢设备 ok=false */
  decidePull(identity: Identity, f: Facts): Verdict {
    if (!this.pull) throw new Error("permissions.json 缺 sync:pull 行");
    return this.decide(this.pull, identity, f);
  }
}
