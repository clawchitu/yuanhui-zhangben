// 条码查询（§7 GET /v1/barcode-lookup/:barcode，§3.2 barcode_catalog）。
//
// 顺序：演示店 → 内置假数据（不碰缓存、不调外部、不占额度）；
//       否则先查 barcode_catalog（全局缓存，不分店）：查到的永久有效，查不到的 7 天内有效；
//       缓存没有 → 同一条码正在外部查询就跟着等那一次（进程内去重，不再占额度）；
//       → 占本店今天的额度（每店每天 1000 次，超了 429 lookup_quota_exceeded）→ 调外部，2 秒超时。
// 外部超时、出错、响应认不出（含 HTTP 200 里的业务错误）一律当「没查到」返回，不写缓存（下次还能再查）；接口最慢 = 超时 + 一点余量（验收：2 秒超时时 2.5 秒内返回）。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { SourceError, type BarcodeSource, type CatalogHit } from "./kuainiao.ts";

/** 查不到的结果缓存多久（§3.2：7 天后可重查） */
export const NOT_FOUND_TTL_MS = 7 * 24 * 3600_000;
/** 外部超时之后再等多久就不等了（防止某个实现不理 AbortSignal） */
const HARD_STOP_GRACE_MS = 150;

export type LookupOrigin = "demo" | "cache" | "external" | "unavailable";
export interface LookupResult {
  found: boolean;
  hit?: CatalogHit;
  origin: LookupOrigin;
}

/** 本店今天调外部的次数到上限了 */
export class LookupQuotaExceeded extends Error {
  readonly retryAfterS: number;
  constructor(retryAfterS: number) {
    super("本店今天的条码查询额度用完了");
    this.retryAfterS = retryAfterS;
  }
}

/**
 * 演示店的内置假数据（§6.1：演示店不调付费接口）。只有饮料、零食、日用品，没有烟酒（S09 演示数据同一口径），也没有图。
 * 条码用 2 开头的店内码段（GS1 留给店内自编，不会和真实商品撞）。
 */
export const DEMO_CATALOG: Readonly<Record<string, CatalogHit>> = {
  "2000000000015": { name: "演示可乐", spec: "330ml", brand: "演示" },
  "2000000000022": { name: "演示矿泉水", spec: "550ml", brand: "演示" },
  "2000000000039": { name: "演示薯片", spec: "75g", brand: "演示" },
  "2000000000046": { name: "演示饼干", spec: "100g", brand: "演示" },
  "2000000000053": { name: "演示纸巾", spec: "10包", brand: "演示" },
  "2000000000060": { name: "演示牙膏", spec: "120g", brand: "演示" },
};

/** 上海时区的日期和到下一个零点还有几秒（上海没有夏令时，固定 +8） */
export function shanghaiDay(now: Date): { day: string; secondsToMidnight: number } {
  const ms = now.getTime() + 8 * 3600_000;
  const day = new Date(ms).toISOString().slice(0, 10);
  const next = Math.floor(ms / 86_400_000 + 1) * 86_400_000;
  return { day, secondsToMidnight: Math.max(1, Math.ceil((next - ms) / 1000)) };
}

/**
 * 每店每天的额度。单实例服务器，放内存里（与按 IP 限速同一做法，见 auth/ratelimit.ts）：重启后当天的计数清零，
 * 每重启一次可能多用一份当天额度（上界 = 当天重启次数 × 上限）。能重启服务的只有我们自己，持令牌的设备触发不了。
 * 按 §14 S08-3 的裁定放内存，带两个条件：T9 接 AppCode 前确认快鸟是预付次数包、用完即停（不是的话先挪进数据库，
 * 按「店 + 上海日期」原子计数）；S10c 的「快鸟余量」告警接 app.catalog.quota。以后改成多实例时必须挪进数据库。
 * 只数「真的调了外部」的次数：缓存命中、跟着别人等的、演示店都不算。
 */
export class DailyQuota {
  private counts = new Map<string, number>();
  private readonly limit: number;
  constructor(limit: number) {
    this.limit = limit;
  }
  /** 占一次；超了抛 LookupQuotaExceeded，不占 */
  take(storeId: string, now: Date): void {
    const { day, secondsToMidnight } = shanghaiDay(now);
    const k = `${storeId}|${day}`;
    const n = this.counts.get(k) ?? 0;
    if (n >= this.limit) throw new LookupQuotaExceeded(secondsToMidnight);
    this.counts.set(k, n + 1);
    if (this.counts.size > 1000) for (const key of this.counts.keys()) if (!key.endsWith(`|${day}`)) this.counts.delete(key);
  }
  /** 今天各店用了几次（S10c 的「快鸟余量」告警看它，§14 S08-3 条件二） */
  usage(now: Date): Array<{ storeId: string; used: number }> {
    const suffix = `|${shanghaiDay(now).day}`;
    const out: Array<{ storeId: string; used: number }> = [];
    for (const [k, n] of this.counts) if (k.endsWith(suffix)) out.push({ storeId: k.slice(0, -suffix.length), used: n });
    return out;
  }
  used(storeId: string, now: Date): number {
    return this.counts.get(`${storeId}|${shanghaiDay(now).day}`) ?? 0;
  }
}

export interface LookupLog {
  warn(obj: object, msg: string): void;
}

export interface CatalogServiceDeps {
  db: Kysely<Database>;
  /** 外部条码库；null = 没配 AppCode，缓存没有就「没查到」 */
  source: BarcodeSource | null;
  timeoutMs: number;
  dailyLimit: number;
  clock: () => Date;
}

type Outcome = { kind: "found"; hit: CatalogHit } | { kind: "not_found" } | { kind: "unavailable" };

export class CatalogService {
  readonly quota: DailyQuota;
  private readonly inflight = new Map<string, Promise<Outcome>>();
  private readonly d: CatalogServiceDeps;
  constructor(d: CatalogServiceDeps) {
    this.d = d;
    this.quota = new DailyQuota(d.dailyLimit);
  }

  async lookup(store: { id: string; isDemo: boolean }, barcode: string, log: LookupLog): Promise<LookupResult> {
    if (store.isDemo) {
      const hit = DEMO_CATALOG[barcode];
      return hit ? { found: true, hit, origin: "demo" } : { found: false, origin: "demo" };
    }
    const now = this.d.clock();
    const cached = await readCache(this.d.db, barcode, now);
    if (cached) return { ...cached, origin: "cache" };
    if (!this.d.source) return { found: false, origin: "unavailable" };

    let p = this.inflight.get(barcode);
    if (!p) {
      this.quota.take(store.id, now); // 超了直接抛，不建查询
      p = this.fetchAndStore(this.d.source, barcode, log).finally(() => this.inflight.delete(barcode));
      this.inflight.set(barcode, p);
    }
    const out = await p;
    if (out.kind === "found") return { found: true, hit: out.hit, origin: "external" };
    return { found: false, origin: out.kind === "not_found" ? "external" : "unavailable" };
  }

  private async fetchAndStore(source: BarcodeSource, barcode: string, log: LookupLog): Promise<Outcome> {
    const ac = new AbortController();
    let timer: NodeJS.Timeout | undefined;
    const hardStop = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        ac.abort();
        // 实现理 signal 的话这里之前已经抛了 timeout；不理的话再给一点余量就放弃
        setTimeout(() => reject(new SourceError("timeout", "外部条码库超时")), HARD_STOP_GRACE_MS).unref();
      }, this.d.timeoutMs);
      timer.unref();
    });
    try {
      const r = await Promise.race([source.lookup(barcode, ac.signal), hardStop]);
      const fetchedAt = this.d.clock();
      try {
        await writeCache(this.d.db, barcode, source.name, r.kind === "found" ? r.hit : null, r.raw, fetchedAt);
      } catch (e) {
        // 缓存写不进去不影响这次的结果
        log.warn({ barcode, err: (e as Error).message }, "条码缓存写入失败");
      }
      return r.kind === "found" ? { kind: "found", hit: r.hit } : { kind: "not_found" };
    } catch (e) {
      const kind = e instanceof SourceError ? e.kind : "unknown";
      // 只记条码、失败类型和固定文字的错误信息（状态码 + 固定分类）；不记网关报错头、响应体（SourceError.raw 不记）。
      // 不是 SourceError 的异常一律记成 unexpected，不记它的 message（来源不明，可能带凭据）
      const err = e instanceof SourceError ? e.message : "unexpected";
      // 网关报额度用完 / 限流（gatewayErrorClass 分出来的 quota）：转成告警（S10c，§9.5「快鸟额度」）
      const alert = kind === "http" && err.includes("（quota）") ? { alert: "kuainiao_quota" } : {};
      log.warn({ barcode, source: source.name, kind, err, ...alert }, "外部条码库查询失败，按没查到返回");
      return { kind: "unavailable" };
    } finally {
      clearTimeout(timer);
    }
  }
}

async function readCache(db: Kysely<Database>, barcode: string, now: Date): Promise<{ found: boolean; hit?: CatalogHit } | null> {
  const row = await db.selectFrom("barcode_catalog").selectAll().where("barcode", "=", barcode).executeTakeFirst();
  if (!row) return null;
  if (row.found && row.name) return { found: true, hit: hitOf(row) };
  if (now.getTime() - new Date(row.fetched_at).getTime() < NOT_FOUND_TTL_MS) return { found: false };
  return null; // 查不到的过了 7 天：重查
}

function hitOf(row: { name: string | null; spec: string | null; brand: string | null; image_url: string | null; image_urls: string[] | null }): CatalogHit {
  // 0004 之前写的行 image_urls 是空数组：退回 image_url 一张
  const urls = row.image_urls?.length ? row.image_urls : row.image_url ? [row.image_url] : [];
  const first = row.image_url ?? urls[0];
  return {
    name: row.name!,
    ...(row.spec ? { spec: row.spec } : {}),
    ...(row.brand ? { brand: row.brand } : {}),
    ...(first ? { imageUrl: first, imageUrls: urls } : {}),
  };
}

/** 写进缓存的图片列表：第一张必须是 imageUrl（图片任务只下 image_url）；S22d 候选按这个顺序取前 6 张 */
export function urlsOf(hit: CatalogHit | null): string[] {
  if (!hit?.imageUrl) return [];
  const rest = (hit.imageUrls ?? []).filter((u) => u !== hit.imageUrl);
  return [hit.imageUrl, ...rest];
}

/** 写缓存。已经是「查到」的行不会被「没查到」覆盖（两个进程前后脚查时） */
export async function writeCache(
  db: Kysely<Database>,
  barcode: string,
  source: string,
  hit: CatalogHit | null,
  raw: unknown,
  fetchedAt: Date,
): Promise<void> {
  const values = {
    barcode,
    found: hit !== null,
    name: hit?.name ?? null,
    spec: hit?.spec ?? null,
    brand: hit?.brand ?? null,
    image_url: hit?.imageUrl ?? null,
    image_urls: urlsOf(hit),
    source,
    raw: raw === undefined ? null : JSON.stringify(raw),
    fetched_at: fetchedAt,
  };
  await db
    .insertInto("barcode_catalog")
    .values(values as never)
    .onConflict((oc) =>
      oc
        .column("barcode")
        .doUpdateSet({
          found: sql`excluded.found`,
          name: sql`excluded.name`,
          spec: sql`excluded.spec`,
          brand: sql`excluded.brand`,
          image_url: sql`excluded.image_url`,
          image_urls: sql`excluded.image_urls`,
          source: sql`excluded.source`,
          raw: sql`excluded.raw`,
          fetched_at: sql`excluded.fetched_at`,
        })
        .where(sql<boolean>`NOT barcode_catalog.found OR excluded.found`),
    )
    .execute();
}
