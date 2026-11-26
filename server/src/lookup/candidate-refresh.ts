// 候选图刷新（真机 11/26 修复 2）。
//
// 问题：候选只在 GET /v1/barcode-lookup/:barcode 第一次登记，用的是 barcode_catalog 里存的快鸟图片地址；
// api-yun 的图片链接约 2 小时就过期。所以 S22d 之前查过的老条码在「换商品图」里一张候选都没有（没有行，或者拿过期地址登记后全失败），
// #52 之前因为 bad_type 失败的候选也一直是 failed。
//
// 做法：手机问候选（GET .../images）时，如果这个条码一张能用的都没有（没有行 / 全部 failed / 卡死的 pending 已收不回来），
// 而条码库里的地址已经过期（取到超过 URL_TTL_MS），就重新问一次快鸟，刷新 barcode_catalog，把非 ready 的候选行清掉、按新地址重新登记，
// 唤醒 worker 转存，返回 pending，手机接着轮询。
//
// 计费保护（快鸟按次计费）：
// - 每个条码一天最多刷新一次：barcode_catalog.images_refreshed_at（0007），用一条带条件的 UPDATE 原子地占位，并发的轮询只有一个能占到；
//   不管快鸟这次是查到、没查到还是没问到，占了就算一次。
// - 照样占本店当天的查码额度（每店每天 1000 次），超了就不刷新，返回 none。
// - 条码库里明确「没查到」的、没有条码库行的、演示店、开关关着、没配快鸟：都不刷新。
// - 取到不到 2 小时的地址不刷新（链接还有效，失败就是真失败）。
// 查码接口（GET /v1/barcode-lookup/:barcode）命中旧缓存时也不再拿过期地址去登记：能刷新就回 pending 让手机来轮询，由这里刷新。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { LookupQuotaExceeded, urlsOf, type CatalogService, type LookupLog } from "./catalog.ts";
import { candidateView, ensureCandidates, type CandidateDeps, type CandidateView } from "./candidates.ts";

/** api-yun 图片链接的有效期（实测约 2 小时）：条码库里的地址取到超过这么久就当过期 */
export const URL_TTL_MS = 2 * 3600_000;
/** 同一条码两次刷新至少隔多久 */
export const REFRESH_INTERVAL_MS = 24 * 3600_000;

const NONE: CandidateView = { state: "none", ids: [] };

/** 现在能不能为这个条码刷新（只读，不占位）：条码库有「查到」的行、地址已过期、今天还没刷新过 */
export async function refreshAllowed(db: Kysely<Database>, barcode: string, now: Date): Promise<boolean> {
  const row = await db
    .selectFrom("barcode_catalog")
    .select(["found", "fetched_at", "images_refreshed_at"])
    .where("barcode", "=", barcode)
    .executeTakeFirst();
  if (!row?.found) return false;
  const t = now.getTime();
  if (t - new Date(row.fetched_at).getTime() < URL_TTL_MS) return false;
  return !row.images_refreshed_at || t - new Date(row.images_refreshed_at).getTime() >= REFRESH_INTERVAL_MS;
}

/** 条码库这一行的地址是不是已经过期（取到超过 URL_TTL_MS） */
export async function urlsStale(db: Kysely<Database>, barcode: string, now: Date): Promise<boolean> {
  const row = await db.selectFrom("barcode_catalog").select("fetched_at").where("barcode", "=", barcode).executeTakeFirst();
  return !!row && now.getTime() - new Date(row.fetched_at).getTime() >= URL_TTL_MS;
}

/** 原子地占今天的刷新名额：条件和 refreshAllowed 一样，占到返回 true */
async function claimRefresh(db: Kysely<Database>, barcode: string, now: Date): Promise<boolean> {
  const ttl = new Date(now.getTime() - URL_TTL_MS);
  const gap = new Date(now.getTime() - REFRESH_INTERVAL_MS);
  const r = await sql`
    UPDATE barcode_catalog SET images_refreshed_at = ${now}::timestamptz
    WHERE barcode = ${barcode} AND found AND fetched_at <= ${ttl}::timestamptz
      AND (images_refreshed_at IS NULL OR images_refreshed_at <= ${gap}::timestamptz)`.execute(db);
  return Number(r.numAffectedRows ?? 0) === 1;
}

export interface RefreshDeps {
  cand: CandidateDeps;
  catalog: CatalogService;
  wake: () => void;
}

/**
 * GET .../images 用：先看现状；一张能用的都没有、又允许刷新时重新问快鸟、重新登记，返回刷新后的现状。
 * 刷新出错（额度用完、数据库错）只记日志，返回刷新前的现状
 */
export async function candidatesWithRefresh(
  d: RefreshDeps,
  store: { id: string; isDemo: boolean },
  barcode: string,
  log: LookupLog,
): Promise<CandidateView> {
  const view = await candidateView(d.cand, barcode);
  if (view.state !== "none" || store.isDemo || !d.cand.enabled || !d.cand.store) return view;
  const now = d.cand.clock();
  if (!(await claimRefresh(d.cand.db, barcode, now))) return view;
  let r;
  try {
    r = await d.catalog.refresh(store, barcode, log);
  } catch (e) {
    if (e instanceof LookupQuotaExceeded) {
      log.warn({ barcode }, "本店今天的查码额度用完，候选图不刷新");
      return view;
    }
    throw e;
  }
  if (!r.found || !r.hit) return NONE;
  const urls = urlsOf(r.hit);
  if (urls.length === 0) return NONE;
  // 非 ready 的行（failed、收不回来的 pending）清掉，按新地址重登记。view 是 none，说明没有 ready、也没有在下载的
  const inserted = await d.cand.db.transaction().execute(async (trx) => {
    await trx.deleteFrom("catalog_image_candidates").where("barcode", "=", barcode).where("state", "<>", "ready").execute();
    return ensureCandidates({ ...d.cand, db: trx }, barcode, urls);
  });
  if (inserted > 0) d.wake();
  return candidateView(d.cand, barcode);
}

/**
 * 查码接口用（命中缓存时，所有身份）：决定这次登不登记、回什么现状。
 * - 缓存里的地址已过期、条码还一行候选都没有：不拿过期地址去登记（下下来全失败）；
 * - 一张能用的都没有、而今天还能刷新：回 pending（ids 空），手机接着轮询 GET .../images，由那里刷新（收银员拿不到这个键）。
 * 其余照旧：登记（已有行时是空操作）、回 candidateView
 */
export async function lookupCandidates(d: CandidateDeps, barcode: string, urls: readonly string[]): Promise<{ view: CandidateView; inserted: number }> {
  const now = d.clock();
  let inserted = 0;
  const stale = await urlsStale(d.db, barcode, now);
  const hasRows = !!(await d.db.selectFrom("catalog_image_candidates").select("idx").where("barcode", "=", barcode).executeTakeFirst());
  if (!stale || hasRows) inserted = await ensureCandidates(d, barcode, urls);
  const view = await candidateView(d, barcode);
  if (view.state === "none" && stale && d.enabled && d.store && (await refreshAllowed(d.db, barcode, now))) {
    return { view: { state: "pending", ids: [] }, inserted };
  }
  return { view, inserted };
}
