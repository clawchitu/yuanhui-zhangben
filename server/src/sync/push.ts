// 推送（§4.1、§4.2、§4.4、§4.5）：一个请求一个事务，在店铺锁内按到达顺序逐个处理 op。
//
// 注销期间（§14 S04-2）：整批一个都不应用、不留档、不给结果（results 为空），响应顶层带 delete_pending_until。
// 注销可以撤回，不是终局，不能用 rejected 表达（手机会当成「没记上」不再重发，撤回后丢账）。被踢设备同样处理。
//
// 每个 op 的处理顺序：
//  0. 存不进库、算不了哈希的 op（\u0000、不成对的代理项、解析不出时间或年份 0000 的 occurred_at、payload 嵌套超过 16 层或节点超过 1 万个）
//     → rejected: invalid，不留档（§14 S04-13）。这一步是迭代的，之后的递归处理栈深度有界。
//     兜底（§14 S04-14、S05-4 第三层）：每个 op 在自己的 savepoint 里处理。Postgres 报数据类错误（SQLSTATE 22xxx）时，
//     商品类 op 只回滚这个 op、单个拒 invalid、不留档，不连累同批的其他 op；记账类 op（LEDGER_OPS）预检查之后仍报 22xxx
//     说明预检查有漏洞，直接抛出、整个请求 500、同批回滚，不留半截账。两种都按 error 级别记日志（要人看）。
//  1. 按 (store_id, id) 找留档：有 → 内容哈希相同就原样返回当初的结果（replayed: true），不同就 id_conflict（不留档、不应用）。
//  2. 手机时钟超前 5 分钟以上 → occurred_at 改成服务器收到的时间，flags.clock_adjusted（§4.4）。
//  3. 按 permissions.json 判权限（guard.decideOp；被踢设备按 §4.5 的列）。
//  4. 按 ops.schema.json 校验 payload（§5.0 上限）→ 不过就 rejected: invalid。
//  5. 被踢设备的非 quick op → held（留档，等家用手机确认，S 后续段做确认接口）。
//  6. 应用（HANDLERS：catalog.ts、ledger/*），记下结果。被拒的、暂存的都留档，重发返回同样的结果（I8）。
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
import { applyOpening, applySaleBatch, applyStockIn } from "../ledger/apply.ts";
import { applyVoid, voidTargetSale } from "../ledger/void.ts";
import { applyCount } from "../ledger/count.ts";
import { applyReviewComplete } from "../ledger/costfix.ts";
import { applyExpiryDispose, applyLotSnooze } from "../ledger/lots.ts";
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

type Handler = (tx: StoreTx, ctx: ApplyContext & { opId: string; flags: Record<string, unknown> }, payload: never) => Promise<Outcome>;
/** 每个 op 类型的处理函数。完整的 Record：ops.schema.json 加了类型而这里没接，编译不过（§14 S04-1；过渡分支已在 S06 删掉） */
export const HANDLERS: Record<OpType, Handler> = {
  product_upsert: applyProductUpsert as Handler,
  product_edit: applyProductEdit as Handler,
  barcode_link: applyBarcodeLink as Handler,
  barcode_unlink: applyBarcodeUnlink as Handler,
  sale_batch: applySaleBatch as Handler,
  stock_in: applyStockIn as Handler,
  opening: applyOpening as Handler,
  void: applyVoid as Handler,
  count: applyCount as Handler,
  product_review_complete: applyReviewComplete as Handler,
  expiry_dispose: applyExpiryDispose as Handler,
  lot_snooze: applyLotSnooze as Handler,
};

/** 记账类 op：预检查之后写库再出 22xxx 只能是服务器自己错了，整个请求 500，不单个拒收（§14 S04-14、S05-4 第三层） */
export const LEDGER_OPS: ReadonlySet<OpType> = new Set<OpType>(["sale_batch", "void", "stock_in", "opening", "product_review_complete", "count", "expiry_dispose", "lot_snooze"]);

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
  /** savepoint 兜底触发时记 error 日志（路由传 req.log） */
  log?: OpLogger;
}

export interface OpLogger {
  error(obj: Record<string, unknown>, msg: string): void;
}

/** 不成对的代理项（高位后面没跟低位、低位前面没有高位）和 \u0000：Postgres 的 text / jsonb 都存不了 */
const UNSTORABLE = /\u0000|[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

/**
 * payload 的嵌套层数上限（payload 对象本身算第 1 层）。合法的 op 最深 3 层（payload → lines → 行），16 层留足余量。
 * 层数有上限，后面所有递归处理（canonical 算哈希、JSON.stringify、ajv、Postgres 解析 jsonb）的栈深度才有界。
 */
export const MAX_PAYLOAD_DEPTH = 16;
/** payload 的节点数上限（对象、数组、标量各算一个）。合法的 op 最多约 2000 个（一笔卖出 200 行 × 每行 9 个）。 */
export const MAX_PAYLOAD_NODES = 10_000;

/**
 * 不递归地检查 payload：层数、节点数在上限内，键和字符串值都存得进库。
 * 必须是迭代的：请求体 1 MiB 以内就能拼出几十万层嵌套，递归检查本身会栈溢出（Codex 第二轮 P2）。
 */
function storablePayload(payload: unknown): boolean {
  const stack: Array<[unknown, number]> = [[payload, 1]];
  // 入栈时计数：超过上限立即停，栈本身也不会超过上限
  let nodes = 1;
  const push = (x: unknown, depth: number) => {
    if (++nodes > MAX_PAYLOAD_NODES) return false;
    stack.push([x, depth]);
    return true;
  };
  while (stack.length > 0) {
    const [v, depth] = stack.pop()!;
    if (typeof v === "string") {
      if (UNSTORABLE.test(v)) return false;
    } else if (v !== null && typeof v === "object") {
      if (depth > MAX_PAYLOAD_DEPTH) return false;
      if (Array.isArray(v)) {
        for (const x of v) if (!push(x, depth + 1)) return false;
      } else {
        for (const [k, x] of Object.entries(v)) {
          if (UNSTORABLE.test(k) || !push(x, depth + 1)) return false;
        }
      }
    }
  }
  return true;
}

/**
 * op 过了外壳校验，但服务器算不了哈希或存不进库（§14 S04-13）：rejected invalid、不留档。
 * 包括 payload 嵌套过深 / 节点过多（超过 MAX_PAYLOAD_DEPTH / MAX_PAYLOAD_NODES）。
 */
export function storable(op: IncomingOp): boolean {
  // 闰秒写法 23:59:60 等：ajv 的 date-time 放行，但解析不出时间
  const t = Date.parse(op.occurred_at);
  if (!Number.isFinite(t)) return false;
  // 年份 0000（含带时区偏移、换算成 UTC 落到公元前的）：不是公历年份，ops.occurred_at 存不下（§14 S05-4 第一层），所有 op 类型都判
  if (op.occurred_at.startsWith("0000") || new Date(t).getUTCFullYear() < 1) return false;
  return storablePayload(op.payload);
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
    for (const op of input.ops) results.push(await processOpSafely(input.log, tx, guard, device, auth.device.id, op, now, input.config));
    return { results, device };
  }, { queueLimit: input.queueLimit ?? STORE_QUEUE_LIMIT });
}

/**
 * 一个 op 一个 savepoint：Postgres 报数据类错误（22xxx：存不了的字符、超出范围的值等）时只回滚这个 op，
 * rejected: invalid、不留档（存不进去），同批其余照常（§14 S04-13）。别的错误（连接断了、程序错）照常抛出。
 */
async function processOpSafely(log: OpLogger | undefined, ...args: Parameters<typeof processOp>): Promise<OpResult> {
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
    if (typeof code === "string" && code.startsWith("22") && LEDGER_OPS.has(op.type)) {
      // 记账类：不回滚成单个拒收（那等于告诉手机「没记上」、不再重发，丢账）。整个请求 500，手机按 id 幂等重发（§14 S04-14）
      log?.error({ op_id: op.id, op_type: op.type, sqlstate: code, err: (e as Error).message }, "sync：记账 op 预检查后写库仍报数据类错误，整个请求失败");
      throw e;
    }
    if (typeof code === "string" && code.startsWith("22")) {
      await sql`ROLLBACK TO SAVEPOINT op`.execute(tx.trx);
      // 预检查本该拦住：走到这里说明有一类输入没想到，或者服务器自己算错了，要人看
      log?.error({ op_id: op.id, op_type: op.type, sqlstate: code, err: (e as Error).message }, "sync：op 触发数据类错误，已单个拒收（savepoint 兜底）");
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

  // 2. 手机时钟
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

  // 3. 权限。payload 缺了选行用的字段（product_upsert 的 quick）就是格式不对
  if (!guard.opRule(op.type, op.payload)) return reject("invalid");
  const v = guard.decideOp(op.type, op.payload, device.identity, {
    now,
    config,
    callerDeviceId: deviceId,
    revokedAt: device.revokedAt,
    opOccurredAt: occurredAt,
    deletePending: device.deletePending,
    // 收银员撤销：只认本机、服务器收到那天（上海）的卖出，不信 op 的 occurred_at（§6 第③条）
    ...(op.type === "void" ? { targetSale: await voidTargetSale(tx, op.payload) } : {}),
  });
  // 注销期间在 pushOps 里整批跳过，到不了这里（§14 S04-2）
  if (!v.ok) return reject("forbidden");

  // 4. 格式与上限
  if (!opSchemaValid(op)) return reject("invalid");

  // 5. 被踢设备的暂存
  if (v.held) return record({ id: op.id, status: "held" });
  if (device.identity === "revoked") flags.late_from_revoked = true;

  // 6. 应用。先写 ops 这一行（entries.op_id 的外键指向它），应用完再写上结果
  await record({ id: op.id, status: "applied" });
  const out = await HANDLERS[op.type](tx, { deviceId, now, occurredAt, opId: id, flags }, op.payload as never);
  const result: OpResult = { id: op.id, ...out };
  await tx.trx
    .updateTable("ops")
    .set({ status: result.status, reject_code: out.status === "rejected" ? out.code : null, result: JSON.stringify(result) })
    .where("store_id", "=", tx.storeId)
    .where("id", "=", id)
    .execute();
  return result;
}
