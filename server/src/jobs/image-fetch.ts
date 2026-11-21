// 商品图任务（S08）：给新登记、还没有图、条码在缓存里有图片地址的商品抓图。
//
// 流程：enqueue 把候选商品放进 image_jobs（一个商品一行，主键去重）→ runImageJobs 一次一个、原子地领任务（attempts+1 并把 next_try_at
// 推到以后，FOR UPDATE SKIP LOCKED：两个进程 / 两轮同时跑也不会领到同一个）→ 安全下载 → 缩图 → 写对象存储 →
// 在 withStoreLock 里确认商品还没图、取一个新号，写回 image_key / image_ver（+1）/ rev。
// 图片任务和商品保存是两件事：商品早已在同步时保存，这里失败只记 last_error，商品照常可用（显示首字）。
// 总开关 product_images_enabled 关着时什么都不做；演示店不抓第三方图。
// 和注销清除（jobs/account-purge.ts）的协调（PR #20 Codex 2）：清除删掉这家店的 image_jobs；在途的那个上传前复查店还在，
// 传完在店铺锁里再查，店没了就删掉刚传的图，删不掉把 store_purges 重新标成没清完（dropLateObject）。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { withStoreLock } from "../sync/lock.ts";
import { imageKey, type ObjectStore } from "../lookup/oss.ts";
import { dropLateObject, storeGone } from "./account-purge.ts";
import { ImageRejected, fetchImage as defaultFetch, makeThumbnail, sha256 } from "../lookup/images.ts";

export const MAX_ATTEMPTS = 3;
/** 第 1、2 次失败后隔多久再试 */
export const RETRY_DELAYS_MS = [5 * 60_000, 60 * 60_000];
/** 这些原因重试也没用，直接放弃 */
const PERMANENT = new Set(["bad_url", "bad_scheme", "bad_port", "private_address", "too_large", "bad_format", "too_small", "too_big_dimensions", "empty", "bad_type"]);

export interface ImageJobDeps {
  db: Kysely<Database>;
  store: ObjectStore | null;
  enabled: boolean;
  clock: () => Date;
  /** 下载（测试里换成带放行策略的版本） */
  fetchImage?: (url: string) => Promise<Buffer>;
  log?: { warn(obj: object, msg: string): void; info(obj: object, msg: string): void };
}

/** 把候选商品放进队列，返回新放进去几个 */
export async function enqueueImageJobs(d: ImageJobDeps, limit = 200): Promise<number> {
  if (!d.enabled || !d.store) return 0;
  const r = await sql`
    INSERT INTO image_jobs (store_id, product_id, source_url, next_try_at)
    SELECT store_id, product_id, image_url, ${d.clock()} FROM (
      SELECT DISTINCT ON (p.store_id, p.id) p.store_id, p.id AS product_id, c.image_url
      FROM products p
      JOIN stores s ON s.id = p.store_id AND NOT s.is_demo
      JOIN product_barcodes b ON b.store_id = p.store_id AND b.product_id = p.id AND b.deleted_at IS NULL
      JOIN barcode_catalog c ON c.barcode = b.barcode AND c.found AND c.image_url IS NOT NULL
      WHERE p.image_ver = 0 AND p.archived_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM image_jobs j WHERE j.store_id = p.store_id AND j.product_id = p.id)
      ORDER BY p.store_id, p.id, b.pack_qty, b.barcode
      LIMIT ${limit}
    ) x
    ON CONFLICT (store_id, product_id) DO NOTHING`.execute(d.db);
  return Number(r.numAffectedRows ?? 0);
}

interface Claimed {
  store_id: string;
  product_id: string;
  source_url: string;
  attempts: number;
}

/** 原子地领到期的任务：领到的 attempts 已 +1，next_try_at 已推后（进程崩了也会在推后的时间重新可领） */
export async function claimDue(d: ImageJobDeps, limit: number): Promise<Claimed[]> {
  const now = d.clock();
  const r = await sql<Claimed>`
    UPDATE image_jobs j SET
      attempts = j.attempts + 1,
      next_try_at = ${now}::timestamptz + make_interval(secs => (CASE WHEN j.attempts = 0 THEN ${RETRY_DELAYS_MS[0]! / 1000}::int ELSE ${RETRY_DELAYS_MS[1]! / 1000}::int END))
    FROM (
      SELECT store_id, product_id FROM image_jobs
      WHERE done_at IS NULL AND attempts < ${MAX_ATTEMPTS} AND next_try_at <= ${now}
      ORDER BY next_try_at
      LIMIT ${limit}
      FOR UPDATE SKIP LOCKED
    ) due
    WHERE j.store_id = due.store_id AND j.product_id = due.product_id
    RETURNING j.store_id, j.product_id, j.source_url, j.attempts`.execute(d.db);
  return r.rows;
}

export interface RunResult {
  done: number;
  failed: number;
  skipped: number;
}

/**
 * 跑一轮：一次领一个、做完再领下一个，最多做 limit 个。
 * 不一次领一批：领到时租约（next_try_at 推后 5 分钟）就开始算，一批 20 张串行做、单张最慢 18 秒（下载 8 + 上传 10）
 * 就会做到租约过期，发布时新旧进程重叠会把排着的任务再领一遍（PR #19 审核）。一次一个，租约只需盖住单张。
 */
export async function runImageJobs(d: ImageJobDeps, limit = 20): Promise<RunResult> {
  const out: RunResult = { done: 0, failed: 0, skipped: 0 };
  if (!d.enabled || !d.store) return out;
  for (let i = 0; i < limit; i++) {
    const [job] = await claimDue(d, 1);
    if (!job) break;
    const r = await processJob(d, d.store, job);
    out[r] += 1;
  }
  return out;
}

async function processJob(d: ImageJobDeps, store: ObjectStore, job: Claimed): Promise<keyof RunResult> {
  const before = await d.db
    .selectFrom("products")
    .select(["image_ver", "archived_at"])
    .where("store_id", "=", job.store_id)
    .where("id", "=", job.product_id)
    .executeTakeFirst();
  if (!before || before.image_ver !== 0 || before.archived_at) {
    await finish(d, job, null);
    return "skipped";
  }
  // 上传开始之后出错（上传报错时对象可能其实写进去了、上传后拿锁或复查失败）：店已被清除就顺手删掉这个键；
  // 这一步本身失败也不要紧，清除之后隔满 1 小时的复扫会按前缀删掉它（T17，PR #20 Codex 2 第二轮）
  let uploading: string | null = null;
  try {
    const raw = await (d.fetchImage ?? defaultFetch)(job.source_url);
    const thumb = await makeThumbnail(raw);
    const ver = before.image_ver + 1;
    const key = imageKey(job.store_id, job.product_id, ver, sha256(thumb));
    // 下载期间店可能被注销清除了（PR #20 Codex 2）：传之前先复查，省一次上传
    if (await storeGone(d.db, job.store_id)) {
      await finish(d, job, null);
      return "skipped";
    }
    // 上传在锁外做（不拿着店铺锁等网络）；写回时在锁里再确认一次商品还没图、店还在
    uploading = key;
    await store.put(key, thumb, "image/jpeg");
    const wrote = await withStoreLock(d.db, job.store_id, async (tx) => {
      // 清除在店铺锁里删店：这里看到店没了，清除已提交，它的对象清理可能已经做完 → 刚传的图得自己删（删不掉交给下一轮清理）
      if (await storeGone(tx.trx, job.store_id)) return "gone" as const;
      const cur = await tx.trx
        .selectFrom("products")
        .select(["image_ver", "archived_at"])
        .where("store_id", "=", tx.storeId)
        .where("id", "=", job.product_id)
        .executeTakeFirst();
      if (!cur || cur.image_ver !== before.image_ver || cur.archived_at) return false;
      await tx.trx
        .updateTable("products")
        .set({ image_key: key, image_source: "kuainiao", image_ver: ver, rev: await tx.nextRev(), updated_at: d.clock() })
        .where("store_id", "=", tx.storeId)
        .where("id", "=", job.product_id)
        .execute();
      return true;
    });
    if (wrote === "gone") {
      await dropLateObject(d.db, job.store_id, () => store.delete(key), d.log);
      return "skipped";
    }
    await finish(d, job, null);
    d.log?.info({ store_id: job.store_id, product_id: job.product_id, wrote }, "商品图已写回");
    return wrote ? "done" : "skipped";
  } catch (e) {
    const reason = e instanceof ImageRejected ? e.reason : "error";
    const permanent = PERMANENT.has(reason);
    const key = uploading;
    if (key) {
      try {
        if (await storeGone(d.db, job.store_id)) await dropLateObject(d.db, job.store_id, () => store.delete(key), d.log);
      } catch {
        // 复查都做不了（数据库断了）：交给复扫
      }
    }
    // last_error 只记原因代码，不记地址和响应内容
    await d.db
      .updateTable("image_jobs")
      .set({ last_error: reason, ...(permanent ? { attempts: MAX_ATTEMPTS } : {}) })
      .where("store_id", "=", job.store_id)
      .where("product_id", "=", job.product_id)
      .execute();
    d.log?.warn({ store_id: job.store_id, product_id: job.product_id, reason, attempt: job.attempts, permanent }, "商品图抓取失败");
    return "failed";
  }
}

async function finish(d: ImageJobDeps, job: Claimed, err: string | null) {
  await d.db
    .updateTable("image_jobs")
    .set({ done_at: d.clock(), last_error: err })
    .where("store_id", "=", job.store_id)
    .where("product_id", "=", job.product_id)
    .execute();
}
