// 密码：argon2id。账号只能用 scripts/create-account.ts 建（§3.1），改密码走 POST /v1/account/password。
import argon2 from "argon2";

/** 密码最短 8 位（§14 S02-6）；最长和契约 password maxLength 一致 */
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 256;

/**
 * 同时在算的 argon2 个数上限（§14 T2）。argon2 跑在 libuv 线程池（默认 4 条，UV_THREADPOOL_SIZE）里，
 * 和 pg 新建连接时的 SCRAM 认证（WebCrypto PBKDF2）、dns.lookup、fs 共用同一个池、先来先算。
 * 一批登录同时到，argon2 把线程全占住、后面还排着一长串时，新连接的 SCRAM 那一步排在整串 argon2 后面，
 * 超过 connectionTimeoutMillis 就报「Connection terminated due to connection timeout」→ 500。
 * 所以 argon2 最多占 线程数 - 1 条，总留一条给别的线程池任务；多出来的在进程里排队（不占连接、不占线程）。
 * 线程池只有 1 条时没法留，只能 1 个 1 个算。
 */
export const THREADPOOL_SIZE = Math.max(1, Number.parseInt(process.env.UV_THREADPOOL_SIZE ?? "", 10) || 4);
export const ARGON2_CONCURRENCY = Math.max(1, THREADPOOL_SIZE - 1);

let running = 0;
const waiting: Array<() => void> = [];

async function limited<T>(fn: () => Promise<T>): Promise<T> {
  if (running >= ARGON2_CONCURRENCY) await new Promise<void>((r) => waiting.push(r));
  else running += 1;
  try {
    return await fn();
  } finally {
    // 名额直接交给下一个排队的（running 不变），没人排队才归还
    const next = waiting.shift();
    if (next) next();
    else running -= 1;
  }
}

export async function hashPassword(password: string): Promise<string> {
  return limited(() => argon2.hash(password, { type: argon2.argon2id }));
}

// 账号不存在时也算一次 argon2，响应时间不泄露「有没有这个账号」
let dummy: Promise<string> | undefined;

export async function verifyPassword(hash: string | undefined, password: string): Promise<boolean> {
  if (hash === undefined) {
    dummy ??= hashPassword("not-a-real-password");
    const h = await dummy;
    await limited(() => argon2.verify(h, password)).catch(() => false);
    return false;
  }
  try {
    return await limited(() => argon2.verify(hash, password));
  } catch {
    return false; // 库里的哈希格式坏了：按密码错处理
  }
}
