// 账号注销的后台任务（S09，§8 S09、§9.4、§14 S03-4、T12）：
//
// 1. 导出包（runExportJobs）：申请注销时（routes/account.ts，同一事务）为非演示店插一行 export_jobs。这里一次领一个到期的任务
//    （FOR UPDATE SKIP LOCKED，attempts + 1、next_try_at 推后当租约），生成 CSV 压缩包（export/store-export.ts）写到临时文件，
//    上传到存档桶的 exports/<店>/，再按「还是领到时那一次申请、没被撤回」条件写回；条件不成立（期间撤回或撤回后又申请）就删掉刚传的包。
//    成功后删掉 exports/<店>/ 下别的旧包，并打一条告警日志（附包的位置），由 Chitu 转交黄总。失败只记原因代码、按次数退避重试。
//    撤回注销记 cancelled_at：这里锁住那一行、删掉 exports/<店>/ 下的包、再删行（锁住期间重新申请会等着，不会删到新包）。
// 2. 到期清除（runAccountPurges）：delete_requested_at 已过 7 天（恰好 7 天整仍可撤回，所以是严格大于）的非演示店。
//    每家店一个事务、拿店铺锁（withStoreLock）和账号行锁（FOR UPDATE，和登录、兑码、申请注销的 FOR NO KEY UPDATE 冲突）后锁内重查，
//    删光这家店的全部在线数据（业务表 → 设备 → 导出任务 → 账号 → 店），同一事务里记一行 store_purges。重复跑、并发跑都只删一次。
// 3. 对象清理（clearPurgedObjects）：对 store_purges 里还没清理完的店，先往存档桶写删除记录 deletions/<店>.json
//    （不在数据库里、不随备份回滚，restore.sh 恢复后重放，S10b），再删商品图桶的 images/<店>/、存档桶的 exports/<店>/、
//    本机图片缓存目录里这家店的子树（T12），都成功了才记 objects_cleared_at。每一步都可重做，失败下一轮接着来。
// 演示店不走这里：审核号的注销申请由每日重置撤回（demo/reset.ts）。
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import path from "node:path";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { DELETE_GRACE_MS } from "../auth/session.ts";
import { withStoreLock } from "../sync/lock.ts";
import { wipeStoreData } from "../demo/wipe.ts";
import { deletionKey, exportKey, removeStoreDir, storePrefix, type ObjectStore } from "../lookup/oss.ts";
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
  /** 存档桶（exports/、deletions/），没配是 null。§9.1 是另一个桶；S10a 配好之前和商品图用同一个 */
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

/** 处理一个到期的导出任务；没有就返回 null */
export async function runOneExportJob(d: AccountJobDeps): Promise<ExportOutcome | null> {
  if (!d.archive) return null;
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
    key = exportKey(storeId, requestedAt, randomBytes(8).toString("hex"));
    await d.archive.put(key, await readFile(file), "application/zip");
    await d.afterExportUpload?.();
    const w = await d.db
      .updateTable("export_jobs")
      .set({ object_key: key, done_at: d.clock(), last_error: null })
      .where("store_id", "=", storeId)
      .where("requested_at", "=", requestedAt)
      .where("cancelled_at", "is", null)
      .where("done_at", "is", null)
      .executeTakeFirst();
    if (Number(w.numUpdatedRows) !== 1) {
      // 生成期间撤回了（或撤回后又申请，那是新的一次，会重新生成）：这个包不该留
      await d.archive.delete(key);
      return { store_id: storeId, result: "superseded" };
    }
    // 同一家店以前的包（撤回后又申请留下的）删掉，只留这一份
    for (const k of await d.archive.list(storePrefix("exports", storeId))) if (k !== key) await d.archive.delete(k);
    d.log?.warn({ alert: "account_delete_export", store_id: storeId, object_key: key }, "账号注销申请：导出包已生成，请转交黄总");
    return { store_id: storeId, result: "done", object_key: key };
  } catch (e) {
    const code = reason(e);
    await d.db
      .updateTable("export_jobs")
      .set({ last_error: code, next_try_at: new Date(d.clock().getTime() + exportBackoffMs(job.attempts)) })
      .where("store_id", "=", storeId)
      .where("requested_at", "=", requestedAt)
      .where("done_at", "is", null)
      .execute();
    if (key) await d.archive.delete(key).catch(() => {});
    (job.attempts >= 3 ? d.log?.error : d.log?.warn)?.call(d.log, { alert: job.attempts >= 3 ? "account_delete_export_failed" : undefined, store_id: storeId, code, attempts: job.attempts }, "导出包生成失败");
    return { store_id: storeId, result: "failed" };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
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
  await clearCancelledExports(d);
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

/** 清除一家店（锁内重查：不在注销中、没满 7 天、是演示店、已经删过 → skipped） */
export async function purgeStore(db: Kysely<Database>, storeId: string, now: Date): Promise<PurgeOutcome> {
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
  for (const { store_id } of due) {
    try {
      if ((await purgeStore(d.db, store_id, now)) === "purged") {
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

/** 删除记录的内容：只有店 id 和时间，不含任何业务数据 */
export function deletionRecord(storeId: string, purgedAt: Date): Buffer {
  return Buffer.from(`${JSON.stringify({ store_id: storeId, purged_at: purgedAt.toISOString() })}\n`, "utf8");
}

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
      let q = trx.selectFrom("store_purges").select(["store_id", "purged_at"]).where("objects_cleared_at", "is", null);
      if (tried.size) q = q.where("store_id", "not in", [...tried]);
      const row = await q.orderBy("purged_at").orderBy("store_id").limit(1).forUpdate().skipLocked().executeTakeFirst();
      if (!row) return null;
      tried.add(row.store_id);
      try {
        // 删除记录最先写：之后哪一步失败、甚至这台机器从备份恢复，都还能按它把这家店再删一遍
        await archive.put(deletionKey(row.store_id), deletionRecord(row.store_id, new Date(row.purged_at)), "application/json");
        if (images) for (const k of await images.list(storePrefix("images", row.store_id))) await images.delete(k);
        for (const k of await archive.list(storePrefix("exports", row.store_id))) await archive.delete(k);
        await removeStoreDir(d.imageCacheDir, "images", row.store_id);
        await trx.updateTable("store_purges").set({ objects_cleared_at: d.clock(), last_error: null }).where("store_id", "=", row.store_id).execute();
        return { id: row.store_id, ok: true };
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
