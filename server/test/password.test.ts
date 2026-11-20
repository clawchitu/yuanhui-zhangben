// argon2 不能占满 libuv 线程池（§14 T2）：否则 pg 新建连接时的 SCRAM 认证（WebCrypto PBKDF2，同一个线程池）
// 排在一长串 argon2 后面，超过 connectionTimeoutMillis，登录回 500。
import { webcrypto } from "node:crypto";
import { describe, expect, it } from "vitest";
import { ARGON2_CONCURRENCY, hashPassword, THREADPOOL_SIZE, verifyPassword } from "../src/auth/password.ts";

/** 和 pg 的 SCRAM-SHA-256 客户端同一种调用（pg/lib/crypto/utils.js deriveKey），4096 次是 Postgres 默认 */
async function scramLikeDerive(): Promise<void> {
  const key = await webcrypto.subtle.importKey("raw", new TextEncoder().encode("pw"), "PBKDF2", false, ["deriveBits"]);
  await webcrypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16), iterations: 4096 }, key, 256);
}

describe("argon2 和线程池（§14 T2）", () => {
  it("至少留一条线程给别的任务（线程池多于 1 条时）", () => {
    if (THREADPOOL_SIZE > 1) expect(ARGON2_CONCURRENCY).toBeLessThan(THREADPOOL_SIZE);
    expect(ARGON2_CONCURRENCY).toBeGreaterThanOrEqual(1);
  });

  it("一大批验密码同时在算时，SCRAM 那种 PBKDF2 不用排在整批后面", async () => {
    // 自己读线程池大小（不用 password.ts 的导出），这条在没有限流的旧代码上也能跑、并且失败
    const threads = Number.parseInt(process.env.UV_THREADPOOL_SIZE ?? "", 10) || 4;
    if (threads < 2) return; // 只有 1 条线程时没法留
    const hash = await hashPassword("correct-horse-1");
    const n = threads * 8;
    let done = 0;
    const all = Array.from({ length: n }, (_, i) => verifyPassword(hash, `wrong-${i}`).then(() => (done += 1)));
    // 等这批都交给 argon2（旧代码里这时 n 个任务已经全在线程池队列里）
    await new Promise((r) => setTimeout(r, 0));
    await scramLikeDerive();
    const doneWhenDerived = done;
    await Promise.all(all);
    // 旧代码：PBKDF2 排在 n 个 argon2 后面，轮到它时至少 n - 线程数 个已经算完
    expect(doneWhenDerived, `PBKDF2 算完时 ${n} 个 argon2 已经完成了 ${doneWhenDerived} 个`).toBeLessThan(n / 2);
  });
});
