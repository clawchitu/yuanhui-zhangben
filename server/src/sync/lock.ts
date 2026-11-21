// 店铺锁与统一的取号函数（§4.1 第 4 条、§4.2「变更序号」）。
//
// 规则：所有会改到同步数据（products、product_barcodes、removed、entries、sale_batches、stock_lots）的写入，
// 都必须在 withStoreLock 里做，每改一行调一次 takeRev 拿一个新号写到这一行的 rev。
// - 锁是事务级的 pg_advisory_xact_lock：提交（行已经对别人可见）之后才放锁，所以同一店的号按提交顺序递增，
//   拉取时 `rev > cursor` 不会漏掉「号小但提交晚」的行。
// - takeRev 自己检查当前事务拿着这家店的锁，没拿锁就报错（不靠调用方自觉）。
// - 号和数据在同一个事务里：回滚时 stores.rev 一起回滚，不留空洞。
import { createHash } from "node:crypto";
import { sql, type Kysely, type Transaction } from "kysely";
import type { Database } from "../db.ts";

/** 店铺锁的键：店 id 的 sha256 前 8 字节（有符号 bigint）。不同店撞键只会多等一下，不影响正确性。 */
export function storeLockKey(storeId: string): string {
  return createHash("sha256").update(`store:${storeId.toLowerCase()}`).digest().readBigInt64BE(0).toString();
}

/** pg_locks 里一个 bigint 键拆成 classid（高 32 位）和 objid（低 32 位），objsubid = 1 */
function lockParts(key: string): { classid: string; objid: string } {
  const u = BigInt.asUintN(64, BigInt(key));
  return { classid: (u >> 32n).toString(), objid: (u & 0xffffffffn).toString() };
}

export interface StoreTx {
  readonly trx: Transaction<Database>;
  readonly storeId: string;
  /** 取一个新号（本店 stores.rev + 1） */
  nextRev(): Promise<number>;
}

/**
 * 在一个事务里拿店铺锁再执行 fn。fn 抛错则整个事务回滚（含取过的号）。
 * 同一店的写入在这里串行；不同店互不阻塞。不要在 fn 里再对同一家店调 withStoreLock（会自己等自己）。
 */
export async function withStoreLock<T>(
  db: Kysely<Database>,
  storeId: string,
  fn: (tx: StoreTx) => Promise<T>,
  opts: { queueLimit?: number } = {},
): Promise<T> {
  return queued(db, storeId.toLowerCase(), opts.queueLimit ?? STORE_QUEUE_LIMIT, () =>
    db.transaction().execute(async (trx) => {
      await sql`SELECT pg_advisory_xact_lock(${storeLockKey(storeId)}::bigint)`.execute(trx);
      return fn({ trx, storeId, nextRev: () => takeRev(trx, storeId) });
    }),
  );
}

/**
 * 令牌验过之后、轮到这个请求之前，这家店被注销到期清除了（jobs/account-purge.ts 删掉了店、账号、设备）。
 * 路由按「令牌不认识」回 401 unauthorized，和清除之后再来的请求一样，不是 500。
 */
export class StoreGone extends Error {
  constructor(storeId: string) {
    super(`店 ${storeId} 已被清除`);
  }
}

/** 每家店在本进程里在途的写入上限（默认值；服务器用配置 STORE_QUEUE_LIMIT，§14 S04-8） */
export const STORE_QUEUE_LIMIT = 32;
/** 一家店在途的写入超过上限：不进队列、不取连接，调用方返回 503 unavailable */
export class StoreBusy extends Error {
  /** 建议手机多少秒后重试 */
  readonly retryAfterS = 2;
  constructor(storeId: string) {
    super(`店 ${storeId} 在途的写入超过上限`);
  }
}

/**
 * 进程内按店排队：同一店的写入先在进程里排好队，轮到了才去连接池取连接、再拿数据库里的店铺锁。
 * 否则一家店同时来很多请求时，每个请求都占着一条连接干等锁，连接池被这一家店占满，别的店也取不到连接。
 * 正确性只靠数据库里的店铺锁（多进程、多个连接池也成立）；这里只是不让等锁的请求占连接。队列按连接池分开。
 * 队列有上限（§14 S04-8）：一家店在途（排队 + 正在处理）已经有 limit 个时，新来的直接抛 StoreBusy，
 * 不进队列、不取连接——否则堆积的请求一直占内存，手机那头早已超时重发，越堆越多。
 */
interface Lane {
  tail: Promise<unknown>;
  inFlight: number;
}
const lanes = new WeakMap<object, Map<string, Lane>>();
function queued<T>(db: object, key: string, limit: number, run: () => Promise<T>): Promise<T> {
  let byKey = lanes.get(db);
  if (!byKey) lanes.set(db, (byKey = new Map()));
  const m = byKey;
  let lane = m.get(key);
  if (!lane) m.set(key, (lane = { tail: Promise.resolve(), inFlight: 0 }));
  const l = lane;
  if (l.inFlight >= limit) return Promise.reject(new StoreBusy(key));
  l.inFlight += 1;
  const next = l.tail.then(run, run);
  l.tail = next.then(
    () => done(),
    () => done(),
  );
  function done() {
    l.inFlight -= 1;
    // 没有在途的了就清掉，Map 不会越积越多
    if (l.inFlight === 0 && m.get(key) === l) m.delete(key);
  }
  return next;
}

/**
 * 统一的取号函数：stores.rev + 1 并返回新值。只能在拿着这家店店铺锁的事务里调用（同一条 SQL 里查 pg_locks），
 * 否则抛错、什么都不改。以后的记账引擎、图片任务、定时任务写同步数据时都用它。
 */
export async function takeRev(trx: Kysely<Database>, storeId: string): Promise<number> {
  const { classid, objid } = lockParts(storeLockKey(storeId));
  const r = await sql<{ rev: string }>`
    UPDATE stores SET rev = rev + 1
    WHERE id = ${storeId}
      AND EXISTS (
        SELECT 1 FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
          AND classid = ${classid}::oid AND objid = ${objid}::oid AND objsubid = 1
      )
    RETURNING rev`.execute(trx);
  const row = r.rows[0];
  if (!row) throw new Error(`取号必须在店铺锁内（withStoreLock），店 ${storeId} 没有拿锁或不存在`);
  const n = Number(row.rev);
  if (!Number.isSafeInteger(n)) throw new Error(`店 ${storeId} 的 rev 超出安全整数范围`);
  return n;
}
