// 条码查询（§7 GET /v1/barcode-lookup/:barcode，§3.2 barcode_catalog）。
//
// 顺序：演示店 → 内置假数据（不碰缓存、不调外部、不占额度）；
//       否则先查 barcode_catalog（全局缓存，不分店）：查到的永久有效，查不到的 7 天内有效；
//       缓存没有 → 同一条码正在外部查询就跟着等那一次（进程内去重，不再占额度）；
//       → 占本店今天的额度（每店每天 300 次，超了 429 lookup_quota_exceeded）→ 调外部，2 秒超时。
// 外部超时、出错一律当「没查到」返回，不写缓存（下次还能再查）；接口最慢 = 超时 + 一点余量（验收：2 秒超时时 2.5 秒内返回）。
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
 * 最多多花一份当天额度。只数「真的调了外部」的次数：缓存命中、跟着别人等的、演示店都不算。
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
      // 只记条码和失败类型；错误信息里没有 AppCode（KuainiaoClient 保证），也不记响应体
      log.warn({ barcode, source: source.name, kind, err: e instanceof SourceError ? e.message : "unexpected" }, "外部条码库查询失败，按没查到返回");
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

function hitOf(row: { name: string | null; spec: string | null; brand: string | null; image_url: string | null }): CatalogHit {
  return {
    name: row.name!,
    ...(row.spec ? { spec: row.spec } : {}),
    ...(row.brand ? { brand: row.brand } : {}),
    ...(row.image_url ? { imageUrl: row.image_url } : {}),
  };
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
          source: sql`excluded.source`,
          raw: sql`excluded.raw`,
          fetched_at: sql`excluded.fetched_at`,
        })
        .where(sql<boolean>`NOT barcode_catalog.found OR excluded.found`),
    )
    .execute();
}
