// 建设备、发令牌（登录、兑码、演示登录共用）和设备称呼去重。
import { sql, type Kysely, type Transaction } from "kysely";
import type { Database } from "../db.ts";
import { newSecret, sha256Hex } from "./tokens.ts";

type Trx = Transaction<Database> | Kysely<Database>;

export const LABEL_MAX = 40;
export const DEFAULT_LABEL = "手机";
/** 注销申请后 7 天删除（§7） */
export const DELETE_GRACE_MS = 7 * 24 * 3600 * 1000;

/** 同一店里改设备称呼、建设备时串行（只用于称呼去重，和 S04 的店铺记账锁不是同一把） */
export async function lockStoreLabels(trx: Trx, storeId: string): Promise<void> {
  await sql`SELECT pg_advisory_xact_lock(hashtext('device_labels'), hashtext(${storeId}))`.execute(trx);
}

/**
 * 同店未撤销设备的称呼不重名，重名时自动加序号（§3.1）：「手机」→「手机2」→「手机3」…
 * 调用方必须已经在事务里拿了 lockStoreLabels。excludeDeviceId：改名时不和自己比。
 */
export async function uniqueLabel(trx: Trx, storeId: string, wanted: string, excludeDeviceId?: string): Promise<string> {
  const base = [...(wanted.trim() || DEFAULT_LABEL)].slice(0, LABEL_MAX).join("");
  let q = trx.selectFrom("devices").select("label").where("store_id", "=", storeId).where("revoked_at", "is", null);
  if (excludeDeviceId) q = q.where("id", "<>", excludeDeviceId);
  const taken = new Set((await q.execute()).map((r) => r.label));
  if (!taken.has(base)) return base;
  for (let n = 2; ; n++) {
    const suffix = String(n);
    const label = [...base].slice(0, LABEL_MAX - suffix.length).join("") + suffix;
    if (!taken.has(label)) return label;
  }
}

export class DeviceIdTaken extends Error {}

/**
 * 「已经在这个事务里锁住了这个账号行」的凭据（§14 T1）。只有 lockAccount 能造出来（构造函数不导出，登记在模块内的 WeakSet 里），
 * createDevice 进门先核对：凭据是真的、属于同一个事务、锁的就是要建设备的账号。没拿锁就调 createDevice 会直接抛错，
 * 不再只靠注释约束「账号 → 开通码 → 设备称呼」的加锁顺序。
 */
export interface AccountLock {
  readonly accountId: string;
  readonly kind: "family" | "review";
  readonly failedLogins: number;
  readonly lockedUntil: Date | null;
  readonly deleteRequestedAt: Date | null;
}
const issuedLocks = new WeakMap<AccountLock, Transaction<Database>>();

export class AccountLockMissing extends Error {}

/**
 * 锁住账号行（FOR NO KEY UPDATE，见 createDevice 的说明）并返回锁内读到的状态。
 * 建设备的路径（密码登录、兑码、演示登录）都必须先调它，再拿开通码、设备称呼的锁。账号不存在返回 undefined。
 */
export async function lockAccount(trx: Transaction<Database>, accountId: string): Promise<AccountLock | undefined> {
  const row = await trx
    .selectFrom("accounts")
    .select(["id", "kind", "failed_logins", "locked_until", "delete_requested_at"])
    .where("id", "=", accountId)
    .forNoKeyUpdate()
    .executeTakeFirst();
  if (!row) return undefined;
  const lock: AccountLock = Object.freeze({
    accountId: row.id,
    kind: row.kind,
    failedLogins: row.failed_logins,
    lockedUntil: row.locked_until,
    deleteRequestedAt: row.delete_requested_at,
  });
  issuedLocks.set(lock, trx);
  return lock;
}

function assertAccountLocked(trx: Transaction<Database>, lock: AccountLock | undefined, accountId: string): void {
  if (!lock || issuedLocks.get(lock) !== trx) throw new AccountLockMissing("createDevice 之前必须在同一个事务里 lockAccount");
  if (lock.accountId !== accountId) throw new AccountLockMissing("lockAccount 锁的不是要建设备的账号");
}

export interface NewDevice {
  /** lockAccount 在同一事务里给的凭据（§14 T1） */
  accountLock: AccountLock | undefined;
  storeId: string;
  accountId: string;
  deviceId: string;
  role: "family" | "cashier";
  label?: string | null;
  now: Date;
  /** 测试钩子（AppDeps.afterDeviceLabelLock），生产是空函数 */
  afterLabelLock?: () => Promise<void>;
}

/**
 * 建一台设备，返回令牌原文（只在这一次响应里出现）。必须在事务里调用。
 * 调用方必须先用 lockAccount 锁住账号行（进门核对凭据，没锁就抛 AccountLockMissing），再调这里拿称呼锁：密码登录、兑码、演示登录统一
 * 「账号 → 开通码 → 设备称呼锁」，否则一边拿着称呼锁、一边拿着账号锁会互等死锁（§14 S03-3）。
 * 用 FOR NO KEY UPDATE 而不是 FOR UPDATE：彼此照样互斥，但不挡插设备时外键检查要的 KEY SHARE；
 * accounts 的键列从来不改，用不着 FOR UPDATE。
 */
export async function createDevice(trx: Transaction<Database>, d: NewDevice): Promise<{ token: string; label: string }> {
  assertAccountLocked(trx, d.accountLock, d.accountId);
  await lockStoreLabels(trx, d.storeId);
  await d.afterLabelLock?.();
  // 设备 id 由手机每次登录或兑码新生成，从不重复使用（§3.1）；同店里撞了就是手机的 bug，明确报错
  const exists = await trx
    .selectFrom("devices")
    .select("id")
    .where("store_id", "=", d.storeId)
    .where("id", "=", d.deviceId)
    .executeTakeFirst();
  if (exists) throw new DeviceIdTaken();
  const label = await uniqueLabel(trx, d.storeId, d.label ?? DEFAULT_LABEL);
  const token = newSecret();
  await trx
    .insertInto("devices")
    .values({
      id: d.deviceId,
      store_id: d.storeId,
      account_id: d.accountId,
      role: d.role,
      label,
      token_hash: sha256Hex(token),
      created_at: d.now,
      last_seen_at: d.now,
    })
    .execute();
  return { token, label };
}

export function deletePendingUntil(deleteRequestedAt: Date | null): string | undefined {
  return deleteRequestedAt ? new Date(deleteRequestedAt.getTime() + DELETE_GRACE_MS).toISOString() : undefined;
}
