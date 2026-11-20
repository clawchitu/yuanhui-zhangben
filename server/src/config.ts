// 服务器配置：全部从环境变量读，启动时校验一次。密钥（数据库口令等）只在环境变量里，不进仓库、不进日志。
// 示例见 server/.env.example。

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
  };
}
