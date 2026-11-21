// 按 IP 限速（§7 登录「另有按 IP 限速」）。单实例服务器，放内存里就够；重启清零可以接受。
// 账号级的「连错 5 次锁 15 分钟」在 routes/auth.ts，存在 accounts 表里，不靠这个。
// 改密码、申请注销的原密码输错按账号限速（accountPassword），也用这里的实现。

export interface RateLimitRule {
  limit: number;
  windowMs: number;
}

export class SlidingWindowLimiter {
  private hits = new Map<string, number[]>();
  private readonly rule: RateLimitRule;
  constructor(rule: RateLimitRule) {
    this.rule = rule;
  }

  /** 记一次；超限时返回还要等几秒，没超限返回 0 */
  hit(key: string, now: number): number {
    const from = now - this.rule.windowMs;
    const list = (this.hits.get(key) ?? []).filter((t) => t > from);
    if (list.length >= this.rule.limit) {
      this.hits.set(key, list);
      return Math.max(1, Math.ceil((list[0]! + this.rule.windowMs - now) / 1000));
    }
    list.push(now);
    this.hits.set(key, list);
    if (this.hits.size > 10_000) this.sweep(from);
    return 0;
  }

  /** 撤回一次 hit 记的那一下（按账号限速只数输错：先占位再验密码，验对了撤回，并发请求也不会多猜） */
  undo(key: string, at: number): void {
    const list = this.hits.get(key);
    if (!list) return;
    const i = list.lastIndexOf(at);
    if (i >= 0) list.splice(i, 1);
    if (list.length === 0) this.hits.delete(key);
  }

  private sweep(from: number) {
    for (const [k, v] of this.hits) if (v.every((t) => t <= from)) this.hits.delete(k);
  }
}

export interface RateLimits {
  /** POST /v1/auth/login */
  login: RateLimitRule;
  /** POST /v1/auth/pair/redeem */
  redeem: RateLimitRule;
  /** POST /v1/auth/demo */
  demo: RateLimitRule;
  /** 改密码、申请注销时原密码输错：按账号，两个接口共用一个计数，不计入登录锁定（§14 S03-8） */
  accountPassword: RateLimitRule;
  /** GET /v1/barcode-lookup：按设备，每分钟 20 次（§7） */
  barcodeLookup: RateLimitRule;
}

// 店里几台手机常常共用一个出口 IP（店里的 Wi-Fi），所以按 IP 的上限不能太紧；防撞库主要靠账号锁定。
export const DEFAULT_RATE_LIMITS: RateLimits = {
  login: { limit: 30, windowMs: 15 * 60_000 },
  redeem: { limit: 30, windowMs: 15 * 60_000 },
  demo: { limit: 30, windowMs: 15 * 60_000 },
  accountPassword: { limit: 5, windowMs: 15 * 60_000 },
  barcodeLookup: { limit: 20, windowMs: 60_000 },
};
