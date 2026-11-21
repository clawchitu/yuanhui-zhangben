// 服务器配置：全部从环境变量读，启动时校验一次。密钥（数据库口令等）只在环境变量里，不进仓库、不进日志。
// 示例见 server/.env.example。
import { parseProxyList } from "./auth/proxy.ts";

export interface Config {
  databaseUrl: string;
  host: string;
  port: number;
  logLevel: string;
  /** GET /v1/config：低于它的 App 显示「请更新」 */
  minBuild: number;
  /** GET /v1/config：「看看演示」开关，默认关（§7） */
  demoLoginEnabled: boolean;
  privacyUrl: string;
  supportUrl: string;
  /** 恢复模式：平时关闭，打开后才接受 POST /v1/recovery/import（§4.6） */
  recoveryMode: boolean;
  /** 前面有 Caddy 反代时为真：只信一跳，取 X-Forwarded-For 最右边一项（Caddy 填的对端地址）作客户端 IP（§7 按 IP 限速，§14 S03-6） */
  trustProxy: boolean;
  /** TRUST_PROXY 打开时必填：Caddy 的地址（IP 或 CIDR，逗号分隔）。只有 TCP 对端在这里面时才看 X-Forwarded-For，而且只取最右一项 */
  trustedProxies: string[];
  /** 每家店在本进程里在途（排队 + 正在处理）的同步写入上限，超过直接 503（§14 S04-8，默认 32） */
  storeQueueLimit: number;
  /** 商品图总开关（S08、§12 Q2）。默认关：关着时不抓图、GET /v1/images 一律 404、条码查询 has_image=false，手机全部显示首字 */
  productImagesEnabled: boolean;
  /** 快鸟条码接口（阿里云云市场 cmapi00067757）。AppCode 只从环境变量来；空 = 不调外部，查不到就是「没查到」 */
  kuainiao: { appCode: string; endpoint: string };
  /** 调快鸟的超时（§7：2 秒） */
  barcodeLookupTimeoutMs: number;
  /** 每店每天调快鸟的上限（§7：300） */
  barcodeDailyLimit: number;
  /** 对象存储。kind=none：不存图（图片任务不跑）；local：本机目录（开发用）；aliyun：阿里云 OSS（S10a 接） */
  objectStore:
    | { kind: "none" }
    | { kind: "local"; dir: string }
    | {
        kind: "aliyun";
        region: string;
        /** 商品图桶（yuanhui-img），只放 images/ */
        bucket: string;
        /** 存档桶（yuanhui-backup），放 exports/、deletions/ 和备份；必须和商品图桶不同（§14 S09-11、T13）。loadConfig 要求必填 */
        archiveBucket?: string;
        accessKeyId: string;
        accessKeySecret: string;
        endpoint?: string;
      };
  /** GET /v1/images 的本机磁盘缓存目录，缺了回源对象存储 */
  imageCacheDir: string;
}

type Env = Record<string, string | undefined>;

export class ConfigError extends Error {}

function int(env: Env, key: string, def: number, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  const raw = env[key];
  if (raw === undefined || raw === "") return def;
  if (!/^\d+$/.test(raw)) throw new ConfigError(`${key} 必须是非负整数`);
  const n = Number(raw);
  if (n < min || n > max) throw new ConfigError(`${key} 超出范围 ${min}–${max}`);
  return n;
}

function bool(env: Env, key: string, def: boolean): boolean {
  const raw = env[key];
  if (raw === undefined || raw === "") return def;
  if (raw === "1" || raw === "true") return true;
  if (raw === "0" || raw === "false") return false;
  throw new ConfigError(`${key} 只能是 1/0/true/false`);
}

function url(env: Env, key: string, def: string): string {
  const raw = env[key] || def;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new ConfigError(`${key} 不是合法 URL`);
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") throw new ConfigError(`${key} 只能是 http/https`);
  return raw;
}

export function loadConfig(env: Env = process.env): Config {
  const databaseUrl = env.DATABASE_URL;
  if (!databaseUrl) throw new ConfigError("缺少 DATABASE_URL");
  return {
    databaseUrl,
    host: env.HOST || "0.0.0.0",
    port: int(env, "PORT", 3000, 1, 65535),
    logLevel: env.LOG_LEVEL || "info",
    minBuild: int(env, "MIN_BUILD", 0),
    demoLoginEnabled: bool(env, "DEMO_LOGIN_ENABLED", false),
    privacyUrl: url(env, "PRIVACY_URL", "https://yuanhuishop.cn/privacy"),
    supportUrl: url(env, "SUPPORT_URL", "https://yuanhuishop.cn/support"),
    recoveryMode: bool(env, "RECOVERY_MODE", false),
    ...trustProxy(env),
    storeQueueLimit: int(env, "STORE_QUEUE_LIMIT", 32, 1, 10_000),
    productImagesEnabled: bool(env, "PRODUCT_IMAGES_ENABLED", false),
    kuainiao: {
      appCode: env.KUAINIAO_APPCODE ?? "",
      endpoint: url(env, "KUAINIAO_ENDPOINT", "https://icode.market.alicloudapi.com/getBarcode"),
    },
    barcodeLookupTimeoutMs: int(env, "BARCODE_LOOKUP_TIMEOUT_MS", 2000, 100, 10_000),
    barcodeDailyLimit: int(env, "BARCODE_DAILY_LIMIT", 300, 0, 100_000),
    objectStore: objectStore(env),
    imageCacheDir: env.IMAGE_CACHE_DIR || "/var/cache/yuanhui/images",
  };
}

function trustProxy(env: Env): Pick<Config, "trustProxy" | "trustedProxies"> {
  const on = bool(env, "TRUST_PROXY", false);
  if (!on) return { trustProxy: false, trustedProxies: [] };
  let list: string[];
  try {
    list = parseProxyList(env.TRUSTED_PROXY ?? "");
  } catch (e) {
    throw new ConfigError(`TRUSTED_PROXY ${(e as Error).message}`);
  }
  // 只开 TRUST_PROXY 不写 Caddy 地址等于信任所有对端，伪造的头就能换限速额度（S03-6），启动时拒绝
  if (!list.length) throw new ConfigError("TRUST_PROXY=1 需要 TRUSTED_PROXY（Caddy 的地址，如 172.30.0.2）");
  return { trustProxy: true, trustedProxies: list };
}

function objectStore(env: Env): Config["objectStore"] {
  const kind = env.OBJECT_STORE || "none";
  if (kind === "none") return { kind };
  if (kind === "local") {
    if (!env.OBJECT_STORE_DIR) throw new ConfigError("OBJECT_STORE=local 需要 OBJECT_STORE_DIR");
    return { kind, dir: env.OBJECT_STORE_DIR };
  }
  if (kind === "aliyun") {
    // 配了商品图桶就必须同时配好存档桶，而且不许是同一个（PR #20 Fable 第二轮裁定 ①、§14 S09-11、T13）
    const need = ["OSS_REGION", "OSS_BUCKET", "OSS_ARCHIVE_BUCKET", "OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET"] as const;
    for (const k of need) if (!env[k]) throw new ConfigError(`OBJECT_STORE=aliyun 需要 ${k}`);
    if (env.OSS_ARCHIVE_BUCKET === env.OSS_BUCKET) throw new ConfigError("OSS_ARCHIVE_BUCKET 不能和 OSS_BUCKET 是同一个桶（S09-11）");
    return {
      kind,
      region: env.OSS_REGION!,
      bucket: env.OSS_BUCKET!,
      archiveBucket: env.OSS_ARCHIVE_BUCKET!,
      accessKeyId: env.OSS_ACCESS_KEY_ID!,
      accessKeySecret: env.OSS_ACCESS_KEY_SECRET!,
      ...(env.OSS_ENDPOINT ? { endpoint: url(env, "OSS_ENDPOINT", "") } : {}),
    };
  }
  throw new ConfigError("OBJECT_STORE 只能是 none / local / aliyun");
}
