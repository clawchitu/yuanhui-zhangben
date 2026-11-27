// 从 `Authorization: Bearer <设备令牌>` 认出设备、账号、店和身份。店 id 只从令牌来，路由拿不到别的店（§3 通用约定）。
import type { Kysely } from "kysely";
import type { Database } from "../db.ts";
import type { Identity } from "./permissions.ts";
import { sha256Hex } from "./tokens.ts";

export interface AuthContext {
  identity: Identity;
  device: { id: string; role: "family" | "cashier"; label: string; revokedAt: Date | null; revokeReason: string | null };
  account: { id: string; kind: "family" | "review"; username: string; deleteRequestedAt: Date | null };
  store: { id: string; name: string; isDemo: boolean; epoch: string; lowStockDefault: number };
}

/** last_seen_at 最多每分钟写一次 */
const SEEN_THROTTLE_MS = 60_000;

export function bearerToken(header: string | undefined): string | undefined {
  if (!header) return undefined;
  const m = /^Bearer[ ]+([A-Za-z0-9_-]{16,128})$/.exec(header.trim());
  return m?.[1];
}

/**
 * 身份：设备已撤销 → revoked；收银员设备 → cashier（演示店里开通的收银员也是 cashier）；
 * 家用设备且账号是审核号 → review；否则 family。
 */
export function identityOf(d: { role: string; revoked_at: Date | null }, accountKind: string): Identity {
  if (d.revoked_at) return "revoked";
  if (d.role === "cashier") return "cashier";
  return accountKind === "review" ? "review" : "family";
}

export async function authenticate(db: Kysely<Database>, token: string, now: Date): Promise<AuthContext | undefined> {
  const row = await db
    .selectFrom("devices as d")
    .innerJoin("accounts as a", (j) => j.onRef("a.id", "=", "d.account_id").onRef("a.store_id", "=", "d.store_id"))
    .innerJoin("stores as s", "s.id", "d.store_id")
    .select([
      "d.id as device_id",
      "d.role",
      "d.label",
      "d.revoked_at",
      "d.revoke_reason",
      "d.last_seen_at",
      "a.id as account_id",
      "a.kind",
      "a.username",
      "a.delete_requested_at",
      "s.id as store_id",
      "s.name as store_name",
      "s.is_demo",
      "s.epoch",
      "s.low_stock_default",
    ])
    .where("d.token_hash", "=", sha256Hex(token))
    .executeTakeFirst();
  if (!row) return undefined;
  if (!row.revoked_at && (!row.last_seen_at || now.getTime() - row.last_seen_at.getTime() > SEEN_THROTTLE_MS)) {
    await db
      .updateTable("devices")
      .set({ last_seen_at: now })
      .where("store_id", "=", row.store_id)
      .where("id", "=", row.device_id)
      .execute();
  }
  return {
    identity: identityOf(row, row.kind),
    device: {
      id: row.device_id,
      role: row.role,
      label: row.label,
      revokedAt: row.revoked_at,
      revokeReason: row.revoke_reason,
    },
    account: { id: row.account_id, kind: row.kind, username: row.username, deleteRequestedAt: row.delete_requested_at },
    store: { id: row.store_id, name: row.store_name, isDemo: row.is_demo, epoch: row.epoch, lowStockDefault: row.low_stock_default },
  };
}
