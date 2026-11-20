// 推送（§4.1、§4.2、§4.4、§4.5）：一个请求一个事务，在店铺锁内按到达顺序逐个处理 op。
//
// 注销期间（§14 S04-2）：整批一个都不应用、不留档、不给结果（results 为空），响应顶层带 delete_pending_until。
// 注销可以撤回，不是终局，不能用 rejected 表达（手机会当成「没记上」不再重发，撤回后丢账）。被踢设备同样处理。
//
// 每个 op 的处理顺序：
//  0. 存不进库、算不了哈希的 op（\u0000、不成对的代理项、解析不出时间的 occurred_at）→ rejected: invalid，不留档（§14 S04-13）。
//     兜底：每个 op 在自己的 savepoint 里处理，Postgres 报数据类错误（SQLSTATE 22xxx）时只回滚这个 op、拒 invalid、不留档。
//     任何 op 的内容都不许让整个请求 500、连累同批的其他 op。
//  1. 按 (store_id, id) 找留档：有 → 内容哈希相同就原样返回当初的结果（replayed: true），不同就 id_conflict（不留档、不应用）。
//  2. 本段还没实现的 op 类型（卖出、进货、盘点等，S05/S06）→ rejected: invalid，不留档，等实现后重发能正常处理。
//  3. 手机时钟超前 5 分钟以上 → occurred_at 改成服务器收到的时间，flags.clock_adjusted（§4.4）。
//  4. 按 permissions.json 判权限（guard.decideOp；被踢设备按 §4.5 的列）。
//  5. 按 ops.schema.json 校验 payload（§5.0 上限）→ 不过就 rejected: invalid。
//  6. 被踢设备的非 quick op → held（留档，等家用手机确认，S 后续段做确认接口）。
//  7. 应用（catalog.ts），记下结果。被拒的、暂存的都留档，重发返回同样的结果（I8）。
//
// 内容哈希 = sha256(规范化 JSON {type, occurred_at（换算成 UTC 毫秒的 ISO 写法）, payload（键排序）})。
// 不含设备：服务器恢复后重新开通的设备补交同一个 op，按原 id 幂等（§4.6）。
import { createHash } from "node:crypto";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import type { AuthContext } from "../auth/authenticate.ts";
import { identityOf } from "../auth/authenticate.ts";
import type { Guard } from "../auth/guard.ts";
import type { Identity } from "../auth/permissions.ts";
import { applyBarcodeLink, applyBarcodeUnlink, applyProductEdit, applyProductUpsert, type ApplyContext, type Outcome } from "./catalog.ts";
import { STORE_QUEUE_LIMIT, withStoreLock, type StoreTx } from "./lock.ts";
import { opSchemaValid, type OpType } from "./validate.ts";

/** 手机时钟超前多少算错（§4.4） */
export const CLOCK_SKEW_MS = 5 * 60_000;

export interface IncomingOp {
  id: string;
  type: OpType;
  occurred_at: string;
  payload: Record<string, unknown>;
}

export type OpResultCode = "forbidden" | "stale" | "id_conflict" | "invalid" | "discarded";

export interface OpResult {
  id: string;
  status: "applied" | "rejected" | "held";
  code?: OpResultCode;
  remap?: Record<string, string>;
  current?: Record<string, unknown>;
  replayed?: boolean;
}

/** 锁内重新读到的设备状态（请求进来以后可能刚被踢） */
export interface DeviceState {
  role: "family" | "cashier";
  label: string;
  identity: Identity;
  revokedAt: Date | null;
  revokeReason: string | null;
  deletePending: boolean;
  /** 账号的注销申请时间（deletePending 时非空） */
  deleteRequestedAt: Date | null;
}

export class EpochMismatch extends Error {
  readonly epoch: string;
  constructor(epoch: string) {
    super("epoch_mismatch");
    this.epoch = epoch;
  }
}

type Handler = (tx: StoreTx, ctx: ApplyContext, payload: never) => Promise<Outcome>;
/** S04 实现的 op 类型；其余在 S05/S06 加进来 */
const HANDLERS: Partial<Record<OpType, Handler>> = {
  product_upsert: applyProductUpsert as Handler,
  product_edit: applyProductEdit as Handler,
  barcode_link: applyBarcodeLink as Handler,
  barcode_unlink: applyBarcodeUnlink as Handler,
};

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v && typeof v === "object") {
    const keys = Object.keys(v as object).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical((v as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(v);
}

export function payloadHash(op: Pick<IncomingOp, "type" | "occurred_at" | "payload">): string {
  const at = new Date(op.occurred_at).toISOString();
  return createHash("sha256").update(canonical({ type: op.type, occurred_at: at, payload: op.payload })).digest("hex");
}

export interface PushInput {
  auth: AuthContext;
  ops: IncomingOp[];
  now: Date;
  /** 请求里的 epoch（锁内再和库里比一次） */
  epoch: string;
  config: { demoLoginEnabled: boolean; recoveryMode: boolean };
  /** 这家店在途写入的上限（§14 S04-8），超过抛 StoreBusy */
  queueLimit?: number;
}

/** 不成对的代理项（高位后面没跟低位、低位前面没有高位）和 \u0000：Postgres 的 text / jsonb 都存不了 */
const UNSTORABLE = /\u0000|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;
function storableJson(v: unknown): boolean {
  if (typeof v === "string") return !UNSTORABLE.test(v);
  if (Array.isArray(v)) return v.every(storableJson);
  if (v && typeof v === "object") return Object.entries(v).every(([k, x]) => !UNSTORABLE.test(k) && storableJson(x));
  return true;
}
/** op 过了外壳校验，但服务器算不了哈希或存不进库（§14 S04-13） */
export function storable(op: IncomingOp): boolean {
  // 闰秒写法 23:59:60 等：ajv 的 date-time 放行，但解析不出时间
  if (!Number.isFinite(Date.parse(op.occurred_at))) return false;
  return storableJson(op.payload);
}

export async function pushOps(db: Kysely<Database>, guard: Guard, input: PushInput): Promise<{ results: OpResult[]; device: DeviceState }> {
  const { auth, now } = input;
  const storeId = auth.store.id;
  return withStoreLock(db, storeId, async (tx) => {
    const store = await tx.trx.selectFrom("stores").select("epoch").where("id", "=", storeId).executeTakeFirstOrThrow();
    if (store.epoch.toLowerCase() !== input.epoch.toLowerCase()) throw new EpochMismatch(store.epoch);
    const device = await readDevice(tx, auth);
    // 注销期间（锁内重新读的状态）：一个都不应用、不留档、不给结果（§14 S04-2）
    if (device.deletePending) return { results: [], device };
    const results: OpResult[] = [];
    for (const op of input.ops) results.push(await processOpSafely(tx, guard, device, auth.device.id, op, now, input.config));
    return { results, device };
  }, { queueLimit: input.queueLimit ?? STORE_QUEUE_LIMIT });
}

/**
 * 一个 op 一个 savepoint：Postgres 报数据类错误（22xxx：存不了的字符、超出范围的值等）时只回滚这个 op，
 * rejected: invalid、不留档（存不进去），同批其余照常（§14 S04-13）。别的错误（连接断了、程序错）照常抛出。
 */
async function processOpSafely(...args: Parameters<typeof processOp>): Promise<OpResult> {
  const [tx, , , , op] = args;
  const invalid: OpResult = { id: op.id, status: "rejected", code: "invalid" };
  if (!storable(op)) return invalid;
  await sql`SAVEPOINT op`.execute(tx.trx);
  try {
    const r = await processOp(...args);
    await sql`RELEASE SAVEPOINT op`.execute(tx.trx);
    return r;
  } catch (e) {
    const code = (e as { code?: unknown }).code;
    if (typeof code === "string" && code.startsWith("22")) {
      await sql`ROLLBACK TO SAVEPOINT op`.execute(tx.trx);
      return invalid;
    }
    throw e;
  }
}

async function readDevice(tx: StoreTx, auth: AuthContext): Promise<DeviceState> {
  const d = await tx.trx
    .selectFrom("devices as d")
    .innerJoin("accounts as a", (j) => j.onRef("a.store_id", "=", "d.store_id").onRef("a.id", "=", "d.account_id"))
    .select(["d.role", "d.label", "d.revoked_at", "d.revoke_reason", "a.kind", "a.delete_requested_at"])
    .where("d.store_id", "=", tx.storeId)
    .where("d.id", "=", auth.device.id)
    .executeTakeFirstOrThrow();
  return {
    role: d.role,
    label: d.label,
    identity: identityOf(d, d.kind),
    revokedAt: d.revoked_at,
    revokeReason: d.revoke_reason,
    deletePending: d.delete_requested_at !== null,
    deleteRequestedAt: d.delete_requested_at,
  };
}

async function processOp(
  tx: StoreTx,
  guard: Guard,
  device: DeviceState,
  deviceId: string,
  op: IncomingOp,
  now: Date,
  config: PushInput["config"],
): Promise<OpResult> {
  const id = op.id.toLowerCase();
  const hash = payloadHash(op);

  // 1. 幂等
  const prev = await tx.trx
    .selectFrom("ops")
    .select(["payload_hash", "result"])
    .where("store_id", "=", tx.storeId)
    .where("id", "=", id)
    .executeTakeFirst();
  if (prev) {
    if (prev.payload_hash !== hash) return { id: op.id, status: "rejected", code: "id_conflict" };
    return { ...(prev.result as OpResult), id: op.id, replayed: true };
  }

  // 2. 本段还没实现的类型
  const handler = HANDLERS[op.type];
  if (!handler) return { id: op.id, status: "rejected", code: "invalid" };

  // 3. 手机时钟
  const flags: Record<string, unknown> = {};
  let occurredAt = new Date(op.occurred_at);
  if (occurredAt.getTime() > now.getTime() + CLOCK_SKEW_MS) {
    flags.clock_adjusted = true;
    flags.client_occurred_at = op.occurred_at;
    occurredAt = now;
  }

  const record = async (result: OpResult, rejectCode: OpResultCode | null = null) => {
    await tx.trx
      .insertInto("ops")
      .values({
        id,
        store_id: tx.storeId,
        device_id: deviceId,
        type: op.type,
        payload: JSON.stringify(op.payload),
        payload_hash: hash,
        occurred_at: occurredAt,
        received_at: now,
        status: result.status,
        reject_code: rejectCode,
        result: JSON.stringify(result),
        flags: JSON.stringify(flags),
      })
      .execute();
    return result;
  };
  const reject = (code: OpResultCode) => record({ id: op.id, status: "rejected", code }, code);

  // 4. 权限。payload 缺了选行用的字段（product_upsert 的 quick）就是格式不对
  if (!guard.opRule(op.type, op.payload)) return reject("invalid");
  const v = guard.decideOp(op.type, op.payload, device.identity, {
    now,
    config,
    callerDeviceId: deviceId,
    revokedAt: device.revokedAt,
    opOccurredAt: occurredAt,
    deletePending: device.deletePending,
  });
  // 注销期间在 pushOps 里整批跳过，到不了这里（§14 S04-2）
  if (!v.ok) return reject("forbidden");

  // 5. 格式与上限
  if (!opSchemaValid(op)) return reject("invalid");

  // 6. 被踢设备的暂存
  if (v.held) return record({ id: op.id, status: "held" });
  if (device.identity === "revoked") flags.late_from_revoked = true;

  // 7. 应用
  const out = await handler(tx, { deviceId, now, occurredAt }, op.payload as never);
  const result: OpResult = { id: op.id, ...out };
  return record(result, out.status === "rejected" ? out.code : null);
}
