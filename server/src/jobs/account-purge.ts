// 账号注销的后台任务（S09，§8 S09、§9.4、§14 S03-4、T12）：
//
// 1. 导出包（runExportJobs）：申请注销时（routes/account.ts，同一事务）为非演示店插一行 export_jobs。这里一次领一个到期的任务
//    （FOR UPDATE SKIP LOCKED，attempts + 1、next_try_at 推后当租约），生成 CSV 压缩包（export/store-export.ts）写到临时文件，
//    从文件流式上传（putFile，不整包进内存）到存档桶的 exports/<店>/，再按「还是领到时那一次申请、没被撤回」条件写回；条件不成立（期间撤回或撤回后又申请）就删掉刚传的包。
//    写回成功先打一条告警日志（附包的位置），由 Chitu 转交黄总；再删 exports/<店>/ 下比这一版更早的旧包（clearStaleExports，
//    只删键里申请时间更早的、开始前在任务行锁里复查版本；失败只让 stale_cleared_at 留空、下一轮单独重试，不碰已完成的包）。
//    生成、上传、写回失败只记原因代码、按次数退避重试。作废的包、失败时已经写进去的包删不掉就记待删标记 object_discards，
//    每轮按退避重试直到删掉（retryObjectDiscards，PR #20 Codex 第二轮 2）。
//    撤回注销记 cancelled_at：这里锁住那一行、删掉 exports/<店>/ 下的包、再删行（锁住期间重新申请会等着，不会删到新包）。
// 2. 到期清除（runAccountPurges）：delete_requested_at 已过 7 天（恰好 7 天整仍可撤回，所以是严格大于）的非演示店。
//    每家店一个事务、拿店铺锁（withStoreLock）和账号行锁（FOR UPDATE，和登录、兑码、申请注销的 FOR NO KEY UPDATE 冲突）后锁内重查，
//    删光这家店的全部在线数据（业务表 → 设备 → 导出任务 → 账号 → 店），同一事务里记一行 store_purges。重复跑、并发跑都只删一次。
//    删在线数据之前（锁内、确认撤回不了之后）先往存档桶写删除记录 deletions/<店>.json（不在数据库里、不随备份回滚，
//    restore.sh 恢复后重放，S10b）；写不成（没配存档桶、写失败）就不删，告警、下一轮重来（PR #20 Codex 1）。
// 3. 对象清理（clearPurgedObjects）：对 store_purges 里还没清理完的店，再写一遍删除记录（幂等），删商品图桶的 images/<店>/、存档桶的 exports/<店>/、
//    本机图片缓存目录里这家店的子树（T12）。清除之后马上做第一遍；隔满 1 小时（RESCAN_DELAY_MS）再按前缀扫一遍，
//    这一遍成功了才记 objects_cleared_at（T17）。每一步都可重做，失败下一轮接着来。
// 在途的图片任务、GET /v1/images 的缓存回填可能在清理之后才把对象落地（PR #20 Codex 2）：清除删掉了这家店的 image_jobs，
// 在途的那个传完之后在店铺锁里复查店还在不在，不在就删掉刚传的（jobs/image-fetch.ts）；缓存回填写完文件后同样复查（cacheFillGuard）。
// 删不掉就撤回 objects_cleared_at，交给下一轮对象清理（dropLateObject）。
// 演示店不走这里：审核号的注销申请由每日重置撤回（demo/reset.ts）。
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import path from "node:path";
import { sql, type Kysely, type Transaction } from "kysely";
import type { Database } from "../db.ts";
import { DELETE_GRACE_MS } from "../auth/session.ts";
import { withStoreLock } from "../sync/lock.ts";
import { wipeStoreData } from "../demo/wipe.ts";
import { deletionKey, exportKey, pendingUploadOf, removeStoreDir, storePrefix, type ObjectStore } from "../lookup/oss.ts";
import { writeStoreExport } from "../export/store-export.ts";

export interface PurgeLog {
  info(obj: object, msg: string): void;
  warn(obj: object, msg: string): void;
  error(obj: object, msg: string): void;
}

export interface AccountJobDeps {
  db: Kysely<Database>;
  /** 商品图所在的桶（images/），没配是 null */
  images: ObjectStore | null;
  /** 存档桶（exports/、deletions/），没配是 null。§9.1 是另一个桶；生产不许和商品图共用（archiveStoreFromConfig，S09-11） */
  archive: ObjectStore | null;
  /** GET /v1/images 的本机磁盘缓存目录 */
  imageCacheDir: string;
  clock: () => Date;
  log?: PurgeLog;
  /** 只给测试用：生成导出包时的分页大小 */
  exportPageSize?: number;
  /** 只给测试用：导出包上传之后、写回之前调用（测「生成期间撤回」） */
  afterExportUpload?: () => Promise<void>;
}

/** 领导出任务的租约：生成 + 上传超过这么久没写回，别的进程可以重新领 */
export const EXPORT_LEASE_MS = 30 * 60_000;
/** 第 n 次失败后隔多久再试：5 分钟起翻倍，最多 6 小时 */
export function exportBackoffMs(attempts: number): number {
  return Math.min(5 * 60_000 * 2 ** Math.max(0, attempts - 1), 6 * 3_600_000);
}

/** 只记原因代码，不把错误信息（可能带路径、店名）写进库 */
function reason(e: unknown): string {
  const code = (e as { code?: unknown }).code;
  if (typeof code === "string" && /^[A-Za-z0-9_.-]{1,40}$/.test(code)) return code;
  return (e as Error)?.name === "Error" ? "error" : String((e as Error)?.name ?? "error").slice(0, 40);
}

// ── 1. 导出包 ──

export type ExportOutcome = { store_id: string; result: "done" | "superseded" | "failed"; object_key?: string };

/** 导出包键里的申请时间（毫秒）；不是导出包键返回 null */
export function exportKeyRequestedAt(key: string): number | null {
  const m = /^exports\/[0-9a-f-]{36}\/([0-9]{13})-[0-9a-f]{16}\.zip$/.exec(key);
  return m ? Number(m[1]) : null;
}

/** 处理一个到期的导出任务；没有就返回 null */
export async function runOneExportJob(d: AccountJobDeps): Promise<ExportOutcome | null> {
  if (!d.archive) return null;
  const archive = d.archive;
  const now = d.clock();
  const claimed = await sql<{ store_id: string; requested_at: Date; attempts: number }>`
    UPDATE export_jobs j SET attempts = j.attempts + 1, next_try_at = ${new Date(now.getTime() + EXPORT_LEASE_MS)}
    WHERE j.store_id = (
      SELECT store_id FROM export_jobs
      WHERE done_at IS NULL AND cancelled_at IS NULL AND next_try_at <= ${now}
      ORDER BY next_try_at, store_id
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    RETURNING j.store_id, j.requested_at, j.attempts`.execute(d.db);
  const job = claimed.rows[0];
  if (!job) return null;
  const storeId = job.store_id;
  const requestedAt = new Date(job.requested_at);
  let key: string | null = null;
  let superseded = false;
  const dir = await mkdtemp(path.join(tmpdir(), "yh-export-"));
  try {
    const file = path.join(dir, "export.zip");
    const out = createWriteStream(file, { mode: 0o600 });
    try {
      await writeStoreExport(d.db, storeId, out, now, { pageSize: d.exportPageSize });
    } finally {
      const closed = once(out, "close");
      out.end();
      await closed;
    }
    // 生成期间这家店被到期清除了（清除删掉了任务行）：不传。清除提交之后不再有新上传开始，迟到的只可能是已在途的（T17 复扫兜底）
    if (await storeGone(d.db, storeId)) return { store_id: storeId, result: "superseded" };
    key = exportKey(storeId, requestedAt, randomBytes(8).toString("hex"));
    // 边读文件边传，不把整包读进内存（PR #20 Codex 5）：生成那头分页、流式压缩，传这头也有界
    await archive.putFile(key, file, "application/zip");
    await d.afterExportUpload?.();
    const w = await d.db
      .updateTable("export_jobs")
      .set({ object_key: key, done_at: d.clock(), last_error: null, stale_cleared_at: null })
      .where("store_id", "=", storeId)
      .where("requested_at", "=", requestedAt)
      .where("cancelled_at", "is", null)
      .where("done_at", "is", null)
      .executeTakeFirst();
    superseded = Number(w.numUpdatedRows) !== 1;
  } catch (e) {
    // 只到「写回完成」为止的失败走这里：包还没算完成，删掉刚传的、按次数退避
    const code = reason(e);
    await d.db
      .updateTable("export_jobs")
      .set({ last_error: code, next_try_at: new Date(d.clock().getTime() + exportBackoffMs(job.attempts)) })
      .where("store_id", "=", storeId)
      .where("requested_at", "=", requestedAt)
      .where("done_at", "is", null)
      .execute();
    if (key) await discardExport(d, storeId, key, "failed");
    // 分片上传失败、中止也失败：记下 uploadId，之后重试中止（Codex 第二轮 3）
    const pu = pendingUploadOf(e);
    if (pu) await recordDiscard(d, storeId, pu.key, pu.uploadId, "upload_abort_failed", "failed");
    (job.attempts >= 3 ? d.log?.error : d.log?.warn)?.call(d.log, { alert: job.attempts >= 3 ? "account_delete_export_failed" : undefined, store_id: storeId, code, attempts: job.attempts }, "导出包生成失败");
    return { store_id: storeId, result: "failed" };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  if (superseded) {
    // 生成期间撤回了（或撤回后又申请、或到期清除了）：这个包不该留。撤回清理、对象清理可能在包落地之前就做完了，
    // 没有任务行再指向它，所以删不掉要记待删标记、定时重试（PR #20 Codex 第二轮 2）
    await discardExport(d, storeId, key, "superseded");
    return { store_id: storeId, result: "superseded" };
  }
  // 完成了就先通知（不等旧包清理）；旧包清理单独做、单独重试，失败不碰这个已完成的包（PR #20 Codex 4）
  d.log?.warn({ alert: "account_delete_export", store_id: storeId, object_key: key }, "账号注销申请：导出包已生成，请转交黄总");
  await clearStaleExports(d, storeId);
  return { store_id: storeId, result: "done", object_key: key };
}

/**
 * 删掉一个不该留的导出包（作废的、生成失败时已经写进去的）。删不掉就在 object_discards 记一条待删标记（重复记只推后重试时间），
 * 由 retryObjectDiscards 每轮按退避重试，直到删掉。记标记也失败（数据库断了）只能打 error 日志：这家店若被清除，T17 复扫兜底。
 */
export async function discardExport(d: AccountJobDeps, storeId: string, key: string, why: "superseded" | "failed"): Promise<void> {
  try {
    await d.archive!.delete(key);
  } catch (e) {
    await recordDiscard(d, storeId, key, "", reason(e), why);
  }
}

/** 记一条待删标记（uploadId 空串 = 删对象，非空 = 中止分片上传）；重复记只更新原因 */
async function recordDiscard(d: AccountJobDeps, storeId: string, key: string, uploadId: string, code: string, why: string): Promise<void> {
  try {
    const now = d.clock();
    await d.db
      .insertInto("object_discards")
      .values({ object_key: key, upload_id: uploadId, store_id: storeId, created_at: now, next_try_at: now, last_error: code })
      .onConflict((oc) => oc.columns(["object_key", "upload_id"]).doUpdateSet({ last_error: code }))
      .execute();
    d.log?.warn({ store_id: storeId, code, why, upload: uploadId !== "" }, "不该留的导出包 / 分片上传没删掉，已记待删标记，定时重试");
  } catch (e2) {
    d.log?.error({ alert: "export_discard_lost", store_id: storeId, code: reason(e2), why }, "不该留的导出包 / 分片上传没删掉，待删标记也没记上");
  }
}

/**
 * 待删标记重试（runExportJobs 每轮先做）：一行一个事务、FOR UPDATE SKIP LOCKED（多进程各删各的）。
 * 删之前确认没有已完成的导出任务指向这个键（生成失败分支的写回其实提交了的极端情况），指向着就只删标记不删包。
 * 删掉了删标记；失败 attempts + 1、按 exportBackoffMs 退避，次数多了打 error 告警。返回这轮删掉了几个。
 */
export async function retryObjectDiscards(d: AccountJobDeps, limit = 50): Promise<number> {
  if (!d.archive) return 0;
  const archive = d.archive;
  let n = 0;
  const since = d.clock();
  for (let i = 0; i < limit; i++) {
    const r = await d.db.transaction().execute(async (trx) => {
      // 这一轮失败的会被推到以后，不会再领到；只领这一轮开始时已到点的
      const row = await trx
        .selectFrom("object_discards")
        .selectAll()
        .where("next_try_at", "<=", since)
        .orderBy("next_try_at")
        .orderBy("object_key")
        .orderBy("upload_id")
        .limit(1)
        .forUpdate()
        .skipLocked()
        .executeTakeFirst();
      if (!row) return null;
      try {
        if (row.upload_id !== "") {
          await archive.abortUpload(row.object_key, row.upload_id);
        } else {
          const live = await trx.selectFrom("export_jobs").select("store_id").where("object_key", "=", row.object_key).where("done_at", "is not", null).executeTakeFirst();
          if (!live) await archive.delete(row.object_key);
        }
        await trx.deleteFrom("object_discards").where("object_key", "=", row.object_key).where("upload_id", "=", row.upload_id).execute();
        return true;
      } catch (e) {
        const attempts = row.attempts + 1;
        await trx
          .updateTable("object_discards")
          .set({ attempts, last_error: reason(e), next_try_at: new Date(d.clock().getTime() + exportBackoffMs(attempts)) })
          .where("object_key", "=", row.object_key)
          .where("upload_id", "=", row.upload_id)
          .execute();
        (attempts >= 3 ? d.log?.error : d.log?.warn)?.call(d.log, { alert: attempts >= 3 ? "object_discard_failed" : undefined, store_id: row.store_id, code: reason(e), attempts }, "待删对象重试失败");
        return false;
      }
    });
    if (r === null) break;
    if (r) n++;
  }
  return n;
}

/**
 * 已完成的导出任务：删掉 exports/<店>/ 里比这一版更早的包（撤回后又申请留下的），删完记 stale_cleared_at。
 * 只删键里申请时间早于这一版的（PR #20 Codex 3）：清理期间又撤回、重新申请、新包生成好了，新包的申请时间更晚，不会被删。
 * 开始前在任务行锁里复查版本：已经不是这一版（撤回了、又申请了）就不清，交给新的那一版。
 * 失败只记日志，stale_cleared_at 留空，下一轮 runExportJobs 接着来。storeId 不给就清所有待清的（最多 limit 家）。
 */
export async function clearStaleExports(d: AccountJobDeps, storeId?: string, limit = 20): Promise<string[]> {
  if (!d.archive) return [];
  const archive = d.archive;
  let q = d.db
    .selectFrom("export_jobs")
    .select(["store_id", "requested_at", "object_key"])
    .where("done_at", "is not", null)
    .where("stale_cleared_at", "is", null)
    .where("cancelled_at", "is", null);
  if (storeId) q = q.where("store_id", "=", storeId);
  const rows = await q.orderBy("store_id").limit(limit).execute();
  const out: string[] = [];
  for (const r of rows) {
    const version = new Date(r.requested_at);
    try {
      const still = await d.db.transaction().execute(async (trx) => {
        const cur = await trx
          .selectFrom("export_jobs")
          .select("store_id")
          .where("store_id", "=", r.store_id)
          .where("requested_at", "=", version)
          .where("done_at", "is not", null)
          .where("cancelled_at", "is", null)
          .forUpdate()
          .executeTakeFirst();
        return !!cur;
      });
      if (!still) continue;
      for (const k of await archive.list(storePrefix("exports", r.store_id))) {
        const at = exportKeyRequestedAt(k);
        if (at !== null && at < version.getTime() && k !== r.object_key) await archive.delete(k);
      }
      const w = await d.db
        .updateTable("export_jobs")
        .set({ stale_cleared_at: d.clock() })
        .where("store_id", "=", r.store_id)
        .where("requested_at", "=", version)
        .where("done_at", "is not", null)
        .executeTakeFirst();
      if (Number(w.numUpdatedRows) === 1) out.push(r.store_id);
    } catch (e) {
      d.log?.warn({ store_id: r.store_id, code: reason(e) }, "旧导出包清理失败，下一轮重试");
    }
  }
  return out;
}

/** 撤回了的导出任务：删掉 exports/<店>/ 下的包，再删这一行。锁住那一行做，期间重新申请的会等着 */
export async function clearCancelledExports(d: AccountJobDeps, limit = 20): Promise<number> {
  if (!d.archive) return 0;
  const archive = d.archive;
  let n = 0;
  for (let i = 0; i < limit; i++) {
    const done = await d.db.transaction().execute(async (trx) => {
      const row = await trx
        .selectFrom("export_jobs")
        .select("store_id")
        .where("cancelled_at", "is not", null)
        .orderBy("store_id")
        .limit(1)
        .forUpdate()
        .skipLocked()
        .executeTakeFirst();
      if (!row) return false;
      for (const k of await archive.list(storePrefix("exports", row.store_id))) await archive.delete(k);
      await trx.deleteFrom("export_jobs").where("store_id", "=", row.store_id).execute();
      return true;
    });
    if (!done) break;
    n++;
  }
  return n;
}

/** 一轮：先清撤回的，再把到期的导出任务一个一个做完（最多 limit 个） */
export async function runExportJobs(d: AccountJobDeps, limit = 10): Promise<ExportOutcome[]> {
  if (!d.archive) {
    // 没配存档桶：导出包生成不了，而到期清除不等导出包（S09-6）。有未完成的任务就每轮打 error 级告警，不能静默跳过（Fable 必须改 2）
    const r = await sql<{ n: string }>`SELECT count(*)::text AS n FROM export_jobs WHERE done_at IS NULL AND cancelled_at IS NULL`.execute(d.db);
    const pending = Number(r.rows[0]?.n ?? 0);
    if (pending > 0) d.log?.error({ alert: "export_no_archive", pending }, "有注销申请的导出包要生成，但没配存档桶");
    return [];
  }
  await retryObjectDiscards(d);
  await clearCancelledExports(d);
  // 上一轮没清完的旧包单独重试（不重新生成）
  await clearStaleExports(d);
  const out: ExportOutcome[] = [];
  for (let i = 0; i < limit; i++) {
    const r = await runOneExportJob(d);
    if (!r) break;
    out.push(r);
  }
  return out;
}

// ── 2. 到期清除 ──

export type PurgeOutcome = "purged" | "skipped";

/**
 * 清除一家店（锁内重查：不在注销中、没满 7 天、是演示店、已经删过 → skipped）。
 * 锁内确认已经撤回不了（满 7 天、撤回要改的账号行被这里锁着）之后，先把删除记录 deletions/<店>.json 写进存档桶，写成了才删在线数据
 * （PR #20 Codex 1）：否则提交之后、写删除记录之前进程退出或写失败，从备份恢复就会让这家店复活。写删除记录失败 → 抛错、整个事务回滚，下一轮重来。
 * 记录先写、事务后来回滚了也无妨：这家店已满 7 天、撤回不了，下一轮照样会删，重放记录删它是对的。
 */
export async function purgeStore(db: Kysely<Database>, storeId: string, now: Date, archive: ObjectStore): Promise<PurgeOutcome> {
  return withStoreLock(db, storeId, async (tx) => {
    const acct = await tx.trx
      .selectFrom("accounts as a")
      .innerJoin("stores as s", "s.id", "a.store_id")
      .select(["a.id", "a.delete_requested_at", "s.is_demo"])
      .where("a.store_id", "=", storeId)
      .forUpdate("a")
      .executeTakeFirst();
    if (!acct || acct.is_demo || !acct.delete_requested_at) return "skipped";
    if (now.getTime() - new Date(acct.delete_requested_at).getTime() <= DELETE_GRACE_MS) return "skipped";
    await archive.put(deletionKey(storeId), deletionRecord(storeId, now), "application/json");
    await wipeStoreData(tx);
    await tx.trx.deleteFrom("devices").where("store_id", "=", storeId).execute();
    await tx.trx.deleteFrom("export_jobs").where("store_id", "=", storeId).execute();
    await tx.trx.deleteFrom("demo_stores").where("store_id", "=", storeId).execute();
    await tx.trx.deleteFrom("accounts").where("store_id", "=", storeId).execute();
    await tx.trx.deleteFrom("stores").where("id", "=", storeId).execute();
    await tx.trx.insertInto("store_purges").values({ store_id: storeId, purged_at: now }).onConflict((oc) => oc.column("store_id").doNothing()).execute();
    return "purged";
  });
}

/** 一轮：找出到期的店逐个清除，再清理已清除店的对象。返回每家店的结果 */
export async function runAccountPurges(d: AccountJobDeps): Promise<{ purged: string[]; cleared: string[] }> {
  const now = d.clock();
  const due = await d.db
    .selectFrom("accounts as a")
    .innerJoin("stores as s", "s.id", "a.store_id")
    .select("a.store_id")
    .where("s.is_demo", "=", false)
    .where("a.delete_requested_at", "<", new Date(now.getTime() - DELETE_GRACE_MS))
    .orderBy("a.store_id")
    .execute();
  const purged: string[] = [];
  if (!d.archive) {
    // 删除记录写不了就不删在线数据（Codex 1）。到期了却删不了，每轮 error 级告警
    if (due.length) d.log?.error({ alert: "purge_no_archive", due: due.length }, "有注销到期的店，但没配存档桶，删除记录写不了，暂不清除");
  }
  for (const { store_id } of d.archive ? due : []) {
    try {
      if ((await purgeStore(d.db, store_id, now, d.archive!)) === "purged") {
        purged.push(store_id);
        d.log?.info({ store_id }, "注销到期：在线数据已清除");
      }
    } catch (e) {
      d.log?.error({ store_id, code: reason(e) }, "注销到期清除失败，下一轮重试");
    }
  }
  const cleared = await clearPurgedObjects(d);
  return { purged, cleared };
}

// ── 3. 对象清理 ──

/** 这家店已经被清除了（店那一行没了）。清除在店铺锁里删店，在店铺锁里查就不会和它交错 */
export async function storeGone(db: Kysely<Database> | Transaction<Database>, storeId: string): Promise<boolean> {
  return !(await db.selectFrom("stores").select("id").where("id", "=", storeId).executeTakeFirst());
}

/**
 * 店清除之后才落地的对象（在途的图片任务传上去的图、GET /v1/images 回填到本机缓存的图，PR #20 Codex 2）：马上删掉；
 * 删不掉就把 store_purges 重新标成「对象没清完」（objects_cleared_at 置空、记原因），下一轮 clearPurgedObjects 整个前缀再清一遍。
 * 不会提前永久标成清理完成：标记只在这里被撤回，清理那边每轮都按前缀重列。
 */
export async function dropLateObject(
  db: Kysely<Database>,
  storeId: string,
  drop: () => Promise<void>,
  log?: { warn(obj: object, msg: string): void; error?(obj: object, msg: string): void },
): Promise<void> {
  try {
    await drop();
  } catch (e) {
    await db.updateTable("store_purges").set({ objects_cleared_at: null, last_error: reason(e) }).where("store_id", "=", storeId).execute();
    (log?.error ?? log?.warn)?.call(log, { store_id: storeId, code: reason(e) }, "已清除店的迟到对象删除失败，交给下一轮对象清理");
  }
}

/** 给 ImageCache 用：回填到本机缓存之后复查店还在不在，不在就删掉刚写的文件（见 dropLateObject） */
export function cacheFillGuard(db: Kysely<Database>, log?: PurgeLog) {
  return async (storeId: string, file: string): Promise<void> => {
    if (await storeGone(db, storeId)) await dropLateObject(db, storeId, () => rm(file, { force: true }), log);
  };
}

/** 删除记录的内容：只有店 id 和时间，不含任何业务数据 */
export function deletionRecord(storeId: string, purgedAt: Date): Buffer {
  return Buffer.from(`${JSON.stringify({ store_id: storeId, purged_at: purgedAt.toISOString() })}\n`, "utf8");
}

/**
 * 清除之后隔多久做最后那一遍复扫（§14 T17，PR #20 Fable 第二轮裁定 ②）。清除提交之后不会再有新的上传开始
 * （图片任务传之前复查店还在、导出任务传之前复查店还在、清除删掉了两种任务），在途的上传都有时限（OSS 请求超时 10 秒）；
 * 隔够 1 小时再按前缀扫一遍，进程退出、上传报错（对象其实写进去了）、上传后拿锁或复查失败留下的对象都会被这一遍删掉。
 */
export const RESCAN_DELAY_MS = 60 * 60_000;

/**
 * 对象清理：对 store_purges 里还没清完的店，按前缀删商品图、导出包、未完成的分片上传和本机缓存。
 * 每一遍成功记 swept_at；清除后满 RESCAN_DELAY_MS 才开始的那一遍成功了才记 objects_cleared_at（返回值里只列这些店）。
 * 一行一个事务、FOR UPDATE SKIP LOCKED：多进程同时跑各清各的，一家店同一时刻只有一个在扫。每一步都可重做。
 */
export async function clearPurgedObjects(d: AccountJobDeps, limit = 20): Promise<string[]> {
  const cleared: string[] = [];
  if (!d.archive) {
    const n = await d.db.selectFrom("store_purges").select("store_id").where("objects_cleared_at", "is", null).limit(1).execute();
    if (n.length) d.log?.error({ alert: "purge_no_archive" }, "有已清除的店，但没配对象存储，删除记录写不了");
    return cleared;
  }
  const archive = d.archive;
  const images = d.images;
  const tried = new Set<string>();
  for (let i = 0; i < limit; i++) {
    const r = await d.db.transaction().execute(async (trx) => {
      // 这一遍开始的时间：离清除满 RESCAN_DELAY_MS 的这一遍才算复扫（T17）。第一遍做过、还没到复扫时间的先跳过，不白扫
      const now = d.clock();
      const rescanBefore = new Date(now.getTime() - RESCAN_DELAY_MS);
      let q = trx
        .selectFrom("store_purges")
        .select(["store_id", "purged_at"])
        .where("objects_cleared_at", "is", null)
        .where((eb) => eb.or([eb("swept_at", "is", null), eb("purged_at", "<=", rescanBefore)]));
      if (tried.size) q = q.where("store_id", "not in", [...tried]);
      const row = await q.orderBy("purged_at").orderBy("store_id").limit(1).forUpdate().skipLocked().executeTakeFirst();
      if (!row) return null;
      tried.add(row.store_id);
      const final = new Date(row.purged_at).getTime() <= rescanBefore.getTime();
      try {
        // 删除记录在清除时已写过；这里再写一遍（幂等），保证对象清理完时它一定在
        await archive.put(deletionKey(row.store_id), deletionRecord(row.store_id, new Date(row.purged_at)), "application/json");
        if (images) for (const k of await images.list(storePrefix("images", row.store_id))) await images.delete(k);
        for (const k of await archive.list(storePrefix("exports", row.store_id))) await archive.delete(k);
        // 未完成的分片上传（传到一半失败、中止也失败留下的残片，Codex 第二轮 3）：delete 删不掉，按前缀列出来逐个中止
        if (images) for (const u of await images.listUploads(storePrefix("images", row.store_id))) await images.abortUpload(u.key, u.uploadId);
        for (const u of await archive.listUploads(storePrefix("exports", row.store_id))) await archive.abortUpload(u.key, u.uploadId);
        await removeStoreDir(d.imageCacheDir, "images", row.store_id);
        await trx
          .updateTable("store_purges")
          .set({ swept_at: now, objects_cleared_at: final ? now : null, last_error: null })
          .where("store_id", "=", row.store_id)
          .execute();
        return { id: row.store_id, ok: final };
      } catch (e) {
        await trx
          .updateTable("store_purges")
          .set((eb) => ({ attempts: eb("attempts", "+", 1), last_error: reason(e) }))
          .where("store_id", "=", row.store_id)
          .execute();
        d.log?.error({ store_id: row.store_id, code: reason(e) }, "已清除店的对象清理失败，下一轮重试");
        return { id: row.store_id, ok: false };
      }
    });
    if (!r) break;
    if (r.ok) cleared.push(r.id);
  }
  return cleared;
}
