// 读 contracts/permissions.json（§6.1 的机器可读版）。guard 和测试都只认这一份，服务器里不再抄一遍权限表。
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PERMISSIONS_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../../../contracts/permissions.json");

/** 四种身份：permissions.json 的四列 */
export type Identity = "family" | "cashier" | "review" | "revoked";
export const IDENTITIES: readonly Identity[] = ["family", "cashier", "review", "revoked"];

export type Decision = "public" | "allow" | "deny" | "held" | "not_applicable";

export type Condition =
  | "own_device_sale"
  | "sale_day_eq_server_receive_day"
  | "quick_only"
  | "occurred_at_lte_revoked_at"
  | "within_revoke_window"
  | "not_self"
  | "demo_login_enabled"
  | "recovery_mode_on";

export interface Cell {
  decision: Decision;
  conditions?: Condition[];
  scope?: string;
  note?: string;
}

interface RuleBase {
  id: string;
  source: string;
  note?: string;
  family: Cell;
  cashier: Cell;
  review: Cell;
  revoked: Cell;
}
export interface HttpRule extends RuleBase {
  kind: "http";
  method: string;
  path: string;
}
export interface OpRule extends RuleBase {
  kind: "op";
  /** 按 payload 字段选行（product_upsert 按 quick 分两行） */
  match?: Record<string, unknown>;
}
export interface PullRule extends RuleBase {
  kind: "sync_pull";
}
export type Rule = HttpRule | OpRule | PullRule;

export interface Permissions {
  version: number;
  conditions: Record<Condition, string>;
  rules: Rule[];
}

let cached: Permissions | undefined;
export function loadPermissions(path = PERMISSIONS_PATH): Permissions {
  if (path === PERMISSIONS_PATH && cached) return cached;
  const p = JSON.parse(readFileSync(path, "utf8")) as Permissions;
  if (p.version !== 1) throw new Error(`permissions.json 版本 ${p.version} 不认识`);
  if (path === PERMISSIONS_PATH) cached = p;
  return p;
}

/** op 行的类型名：`op:product_upsert[quick]` → `product_upsert` */
export function opTypeOf(rule: OpRule): string {
  return rule.id.replace(/^op:/, "").replace(/\[.*\]$/, "");
}
