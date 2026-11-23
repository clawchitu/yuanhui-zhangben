// 商品图候选（S22d-server）：查码查到、有图片地址时，把快鸟给的前 6 张异步转存成 200px 缩图，给手机选。
//
// - 异步：查码接口有 2.5 秒预算，单图下载最长 8 秒，所以查码只插行、立刻唤醒进程内 worker（并发 1），不等下载。
// - 表 catalog_image_candidates（0005）：全局、不分店，与 barcode_catalog 一致；ready 的不按时间过期（§14 S22d-1）。
// - 重试共 3 次，间隔 30 秒、5 分钟（链接会过期，之后直接放弃）；永久性失败原因沿用 image-fetch 的 PERMANENT。
//   领取原子（attempts+1、next_try_at 推后，FOR UPDATE SKIP LOCKED），进程内 worker 与调度器 images 任务同时跑也不会领到同一行。
// - 下载与校验全部复用 lookup/images.ts（fetchImage 管 SSRF / 端口 / 跳转 / 5 MB / 8 秒，makeThumbnail 管格式 / 像素 / 元数据）。
// - 对象键 images/_catalog/<sha256(条码)前 32 位>/<cid>.jpg，cid = 缩图 sha256 前 16 位；同条码内容重复的记 failed duplicate。
// - last_error 只记原因代码；source_url 不进日志、不下发。
// - 每周一次清扫 images/_catalog/：删掉没有对应行、落地超过 1 小时的对象。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { candidateKey, CANDIDATES_PREFIX, type ObjectStore } from "./oss.ts";
import { ImageRejected, fetchImage as defaultFetch, makeThumbnail, sha256 } from "./images.ts";
import { PERMANENT } from "../jobs/image-fetch.ts";

export const MAX_CANDIDATES = 6;
export const CANDIDATE_MAX_ATTEMPTS = 3;
/** 第 1、2 次失败后隔多久再试 */
export const CANDIDATE_RETRY_DELAYS_MS = [30_000, 5 * 60_000];
/** 孤儿对象落地多久之后才删（盖住「对象已上传、行还没写成 ready」的空档） */
export const ORPHAN_GRACE_MS = 60 * 60_000;
export const CID_RE = /^[0-9a-f]{16}$/;

export type CandidateState = "none" | "pending" | "ready";
export interface CandidateView {
  state: CandidateState;
  ids: string[];
}

export interface CandidateLog {
  warn(obj: object, msg: string): void;
  info?(obj: object, msg: string): void;
}

export interface CandidateDeps {
  db: Kysely<Database>;
  store: ObjectStore | null;
  /** 图片总开关（且对象存储配了）；关着什么都不做 */
  enabled: boolean;
  clock: () => Date;
  fetchImage?: (url: string) => Promise<Buffer>;
  log?: CandidateLog;
}

/** 条码在对象键里的那一段（不把条码原文放进键） */
export const barcodeDir = (barcode: string) => sha256(Buffer.from(barcode, "utf8")).slice(0, 32);

/**
 * 条码还没有候选行时插前 6 张（旧缓存行第一次被查到时同样补插一次）。已有行（哪怕全是 failed）就不再插，防止反复下载。
 * 返回新插了几行
 */
export async function ensureCandidates(d: CandidateDeps, barcode: string, urls: readonly string[]): Promise<number> {
  if (!d.enabled || !d.store) return 0;
  const list = [...new Set(urls.filter((u) => typeof u === "string" && u.length > 0))].slice(0, MAX_CANDIDATES);
  if (list.length === 0) return 0;
  const now = d.clock();
  const r = await sql`
    INSERT INTO catalog_image_candidates (barcode, idx, source_url, next_try_at)
    SELECT ${barcode}, u.ord - 1, u.url, ${now}::timestamptz
    FROM unnest(${list}::text[]) WITH ORDINALITY AS u(url, ord)
    WHERE NOT EXISTS (SELECT 1 FROM catalog_image_candidates c WHERE c.barcode = ${barcode})
    ON CONFLICT (barcode, idx) DO NOTHING`.execute(d.db);
  return Number(r.numAffectedRows ?? 0);
}

/**
 * 这个条码的候选现状：还有能重试的 pending → pending（ids 是已经好了的）；否则有 ready → ready；否则 none。
 * ids 按 idx 保序，最多 6 个。开关关着一律 none
 */
export async function candidateView(d: Pick<CandidateDeps, "db" | "enabled" | "store">, barcode: string): Promise<CandidateView> {
  if (!d.enabled || !d.store) return { state: "none", ids: [] };
  const rows = await d.db
    .selectFrom("catalog_image_candidates")
    .select(["idx", "state", "cid", "attempts"])
    .where("barcode", "=", barcode)
    .orderBy("idx")
    .execute();
  const ids = rows.filter((r) => r.state === "ready" && r.cid).map((r) => r.cid!);
  // 领满 3 次还停在 pending 的（第 3 次领取后进程退出，PR #42 可选）不算 pending，免得手机空等；runCandidateJobs 会把它收成 failed
  if (rows.some((r) => r.state === "pending" && r.attempts < CANDIDATE_MAX_ATTEMPTS)) return { state: "pending", ids };
  return ids.length ? { state: "ready", ids } : { state: "none", ids: [] };
}

interface Claimed {
  barcode: string;
  idx: number;
  source_url: string;
  attempts: number;
}

/** 原子地领一行到期的：attempts+1，next_try_at 推到下次重试的时间（进程崩了到点也能重新领） */
export async function claimCandidate(d: CandidateDeps): Promise<Claimed | null> {
  const now = d.clock();
  const r = await sql<Claimed>`
    UPDATE catalog_image_candidates c SET
      attempts = c.attempts + 1,
      next_try_at = ${now}::timestamptz + make_interval(secs => (CASE WHEN c.attempts = 0 THEN ${CANDIDATE_RETRY_DELAYS_MS[0]! / 1000}::int ELSE ${CANDIDATE_RETRY_DELAYS_MS[1]! / 1000}::int END))
    FROM (
      SELECT barcode, idx FROM catalog_image_candidates
      WHERE state = 'pending' AND attempts < ${CANDIDATE_MAX_ATTEMPTS} AND next_try_at <= ${now}
      ORDER BY next_try_at, barcode, idx
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    ) due
    WHERE c.barcode = due.barcode AND c.idx = due.idx
    RETURNING c.barcode, c.idx, c.source_url, c.attempts`.execute(d.db);
  return r.rows[0] ?? null;
}

export type CandidateOutcome = "ready" | "duplicate" | "failed" | "retry";

async function processCandidate(d: CandidateDeps, store: ObjectStore, c: Claimed): Promise<CandidateOutcome> {
  try {
    const raw = await (d.fetchImage ?? ((u: string) => defaultFetch(u)))(c.source_url);
    const thumb = await makeThumbnail(raw);
    const cid = sha256(thumb).slice(0, 16);
    const dup = await d.db
      .selectFrom("catalog_image_candidates")
      .select("idx")
      .where("barcode", "=", c.barcode)
      .where("state", "=", "ready")
      .where("cid", "=", cid)
      .executeTakeFirst();
    if (dup) {
      await markFailed(d, c, "duplicate");
      return "duplicate";
    }
    const key = candidateKey(barcodeDir(c.barcode), cid);
    try {
      // 上传和写成 ready 在同一个按键的咨询锁里做（PR #42 必须改 2）：清扫删对象前拿同一把锁、再查一次有没有行，
      // 两边按键串行，不会出现「刚写成 ready、对象被清扫删掉」的悬空行
      const n = await d.db.transaction().execute(async (trx) => {
        await lockKey(trx, key);
        await store.put(key, thumb, "image/jpeg");
        const u = await trx
          .updateTable("catalog_image_candidates")
          .set({ state: "ready", cid, object_key: key, last_error: null, fetched_at: d.clock() })
          .where("barcode", "=", c.barcode)
          .where("idx", "=", c.idx)
          .where("state", "=", "pending")
          .executeTakeFirst();
        return Number(u.numUpdatedRows);
      });
      if (n === 0) return "failed"; // 行被清掉了（T12 手册）：对象交给每周清扫
    } catch (e) {
      // 同条码另一行同时转存了同样的内容（唯一索引）：这一行记重复；对象是同一个键，归那一行
      if ((e as { code?: string }).code === "23505") {
        await markFailed(d, c, "duplicate");
        return "duplicate";
      }
      throw e;
    }
    return "ready";
  } catch (e) {
    const reason = e instanceof ImageRejected ? e.reason : "error";
    const permanent = PERMANENT.has(reason);
    const last = c.attempts >= CANDIDATE_MAX_ATTEMPTS;
    if (permanent || last) await markFailed(d, c, reason);
    else
      await d.db
        .updateTable("catalog_image_candidates")
        .set({ last_error: reason })
        .where("barcode", "=", c.barcode)
        .where("idx", "=", c.idx)
        .execute();
    // 只记条码、序号、原因代码；不记图片地址
    d.log?.warn({ barcode: c.barcode, idx: c.idx, reason, attempt: c.attempts, permanent }, "商品图候选转存失败");
    return permanent || last ? "failed" : "retry";
  }
}

async function markFailed(d: CandidateDeps, c: Claimed, reason: string) {
  await d.db
    .updateTable("catalog_image_candidates")
    .set({ state: "failed", last_error: reason, attempts: CANDIDATE_MAX_ATTEMPTS })
    .where("barcode", "=", c.barcode)
    .where("idx", "=", c.idx)
    .where("state", "=", "pending")
    .execute();
}

/** 一个对象键的咨询锁（事务级）：候选转存写对象 + 写行、清扫查行 + 删对象，都在它里面 */
async function lockKey(trx: Kysely<Database>, key: string) {
  await sql`SELECT pg_advisory_xact_lock(hashtextextended(${`candidate:${key}`}, 0))`.execute(trx);
}

/** 第 3 次领取后进程退出、没来得及记结果的行：领取次数用完了，收成 failed（PR #42 可选） */
async function abandonExhausted(d: CandidateDeps): Promise<void> {
  await d.db
    .updateTable("catalog_image_candidates")
    .set({ state: "failed", last_error: sql`coalesce(last_error, 'abandoned')` })
    .where("state", "=", "pending")
    .where("attempts", ">=", CANDIDATE_MAX_ATTEMPTS)
    .where("next_try_at", "<=", d.clock())
    .execute();
}

/** 跑一轮：一次领一行，做完再领，最多 limit 行；stop() 返回 true 时做完手上这一行就停 */
export async function runCandidateJobs(d: CandidateDeps, limit = 30, stop: () => boolean = () => false): Promise<Record<CandidateOutcome, number>> {
  const out: Record<CandidateOutcome, number> = { ready: 0, duplicate: 0, failed: 0, retry: 0 };
  if (!d.enabled || !d.store) return out;
  await abandonExhausted(d);
  for (let i = 0; i < limit && !stop(); i++) {
    const c = await claimCandidate(d);
    if (!c) break;
    out[await processCandidate(d, d.store, c)] += 1;
  }
  return out;
}

/**
 * 进程内 worker（并发 1）：查码插了行就 wake()，调度器 images 任务也走同一个实例的 drain()，同一进程里不会两路同时下载缩图。
 */
export class CandidateWorker {
  private readonly d: CandidateDeps;
  private running: Promise<void> | null = null;
  private again = false;
  private stopped = false;
  constructor(d: CandidateDeps) {
    this.d = d;
  }
  get deps(): CandidateDeps {
    return this.d;
  }
  /** 等正在跑的这一轮跑完（关服务时用，不再开新的一轮） */
  async idle(): Promise<void> {
    // 关服务：不再开新的一轮，在跑的这一轮做完手上那一行就停（PR #42 Fable 可选 2）
    this.stopped = true;
    this.again = false;
    if (this.running) await this.running;
  }
  /** 唤醒：正在跑就让它跑完这轮再跑一轮；出错只记日志 */
  wake(): void {
    void this.drain();
  }
  /** 跑到没有到期的为止（正在跑就等它，并在它之后再补一轮） */
  drain(): Promise<void> {
    if (!this.d.enabled || !this.d.store || this.stopped) return Promise.resolve();
    if (this.running) {
      this.again = true;
      return this.running;
    }
    const p = (async () => {
      do {
        this.again = false;
        try {
          await runCandidateJobs(this.d, 30, () => this.stopped);
        } catch (e) {
          this.d.log?.warn({ code: (e as { code?: string })?.code ?? "error" }, "商品图候选任务出错，下次再试");
        }
      } while (this.again);
    })().finally(() => {
      this.running = null;
    });
    this.running = p;
    return p;
  }
}

/** 每周清扫：images/_catalog/ 下没有对应行、落地超过 1 小时的对象删掉。返回删了哪些 */
export async function sweepCandidateObjects(d: CandidateDeps): Promise<string[]> {
  const store = d.store;
  if (!store?.listWithTimes) return [];
  const listed = await store.listWithTimes(CANDIDATES_PREFIX);
  if (listed.length === 0) return [];
  const rows = await d.db.selectFrom("catalog_image_candidates").select("object_key").where("object_key", "is not", null).execute();
  const live = new Set(rows.map((r) => r.object_key!));
  const cutoff = d.clock().getTime() - ORPHAN_GRACE_MS;
  const removed: string[] = [];
  for (const o of listed) {
    // 快照只用来挑候选；真正删之前逐个在按键的咨询锁里再查一次有没有行（PR #42 必须改 2）。
    // 转存在同一把锁里先写对象再写 ready：锁里查不到行，说明转存要么还没开始（之后会重新上传），要么写行失败（本就是孤儿）
    if (live.has(o.key) || o.modifiedAt.getTime() > cutoff) continue;
    try {
      const deleted = await d.db.transaction().execute(async (trx) => {
        await lockKey(trx, o.key);
        const ref = await trx.selectFrom("catalog_image_candidates").select("idx").where("object_key", "=", o.key).executeTakeFirst();
        if (ref) return false;
        await store.delete(o.key);
        return true;
      });
      if (deleted) removed.push(o.key);
    } catch (e) {
      d.log?.warn({ code: (e as { code?: string })?.code ?? "error" }, "商品图候选孤儿对象删除失败，下周再删");
    }
  }
  return removed;
}
