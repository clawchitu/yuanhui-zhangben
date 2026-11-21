// 演示小店（S09，§8 S09、§4.5、§14 S03-9）：建店种数据、每日重置。
//
// 重置时间：每天北京时间 16:00（美国西岸半夜）。演示店最近 60 分钟有请求（未撤销设备的 last_seen_at / 新登录）就顺延 1 小时再试。
// 重置在一个事务里、拿着店铺锁做（withStoreLock，和 /v1/sync 的写入同一把锁）：
//   锁审核号账号行（和登录、演示登录同一把，§14 T1）→ 锁内重查有没有人在用 → 清空业务数据 → 全部设备标为已撤销
//   （revoke_reason = demo_reset，同步响应带 discard_outbox，§4.5）→ 删掉 7 天前就撤销了的旧设备（演示登录每次建一行，不越积越多）→
//   恢复审核号密码、撤回注销申请、清登录锁 → 重新种子数据。不换 epoch。
// 重置途中进来的同步请求在店铺锁上等着；轮到它时锁内重读设备，已是 demo_reset → 整批不应用（push.ts），回 revoked + discard_outbox。
// 读（拉取、报表）用快照，看到的要么是重置前、要么是重置后，没有半截。
import type { Kysely } from "kysely";
import type { Database } from "../db.ts";
import { lockAccount } from "../auth/session.ts";
import { hashPassword } from "../auth/password.ts";
import { StoreBusy, withStoreLock } from "../sync/lock.ts";
import { applySeed, DEMO_STORE_NAME, seedId } from "./seed.ts";
import { wipeStoreData } from "./wipe.ts";

/** 每天北京时间几点重置 */
export const DEMO_RESET_HOUR = 16;
/** 最近多久有请求算「有人在用」 */
export const DEMO_ACTIVE_WINDOW_MS = 60 * 60_000;
/** 有人在用时顺延多久 */
export const DEMO_DEFER_MS = 60 * 60_000;
/**
 * 已撤销的演示设备留多久。刚在这次重置里撤销的要留着：那台手机下次同步才拿得到 revoked + discard_outbox；
 * 删掉了它只会拿到 401，不知道该丢弃 outbox。留 7 天，离线一周以内的手机都能正常收到；更早的删掉，设备行不越积越多。
 */
export const DEMO_DEVICE_RETENTION_MS = 7 * 86_400_000;
const LOW_STOCK_DEFAULT = 3;

/** now 之后（不含）的下一个北京时间 16:00 */
export function nextResetAfter(now: Date): Date {
  const sh = now.getTime() + 8 * 3_600_000;
  const dayStart = Math.floor(sh / 86_400_000) * 86_400_000;
  let t = dayStart + DEMO_RESET_HOUR * 3_600_000;
  if (t <= sh) t += 86_400_000;
  return new Date(t - 8 * 3_600_000);
}

export interface SetupDemoInput {
  username: string;
  password: string;
  now: Date;
}

/** 建演示店、审核号，并种上数据（scripts/create-demo-store.ts 用）。返回店 id */
export async function setupDemoStore(db: Kysely<Database>, input: SetupDemoInput): Promise<{ storeId: string; accountId: string }> {
  const username = input.username.trim();
  if (!username || /\s/.test(username) || username.length > 64) throw new Error("用户名 1–64 个字符、不能有空格");
  const hash = await hashPassword(input.password);
  const { storeId, accountId } = await db.transaction().execute(async (trx) => {
    const s = await trx.insertInto("stores").values({ name: DEMO_STORE_NAME, is_demo: true, low_stock_default: LOW_STOCK_DEFAULT }).returning("id").executeTakeFirstOrThrow();
    const a = await trx.insertInto("accounts").values({ store_id: s.id, username, password_hash: hash, kind: "review" }).returning("id").executeTakeFirstOrThrow();
    await trx
      .insertInto("demo_stores")
      .values({ store_id: s.id, review_password_hash: hash, seeded_at: input.now, next_reset_at: nextResetAfter(input.now) })
      .execute();
    return { storeId: s.id, accountId: a.id };
  });
  await resetDemoStore(db, storeId, input.now, { force: true });
  return { storeId, accountId };
}

export type ResetOutcome = "reset" | "deferred" | "skipped";

/**
 * 重置一家演示店。force=false 时先看有没有人在用（锁内判断），有就把 next_reset_at 顺延 1 小时、返回 deferred。
 * onlyIfDue（定时任务用）：锁内重查 next_reset_at，还没到（别的进程刚重置或顺延过这个周期）→ skipped，什么都不动。
 * 到期检查在锁外做过一次，但两个进程可能都看到「到点」，只有锁内这次重查算数（PR #20 Codex 6）。
 * 店不是演示店（demo_stores 里没有）直接抛错：这个函数绝不碰真实店。
 */
export async function resetDemoStore(db: Kysely<Database>, storeId: string, now: Date, o: { force?: boolean; onlyIfDue?: boolean } = {}): Promise<ResetOutcome> {
  return withStoreLock(db, storeId, async (tx) => {
    const demo = await tx.trx
      .selectFrom("demo_stores as d")
      .innerJoin("stores as s", "s.id", "d.store_id")
      .innerJoin("accounts as a", "a.store_id", "d.store_id")
      .select(["d.review_password_hash", "d.next_reset_at", "s.is_demo", "a.id as account_id", "a.kind"])
      .where("d.store_id", "=", storeId)
      .forUpdate("d")
      .executeTakeFirst();
    if (!demo || !demo.is_demo || demo.kind !== "review") throw new Error(`店 ${storeId} 不是演示店，拒绝重置`);
    // demo_stores 行已 FOR UPDATE 锁住（外面还有店铺锁）：并发的另一个进程在这里等，轮到它时读到的是已推后的 next_reset_at
    if (o.onlyIfDue && new Date(demo.next_reset_at).getTime() > now.getTime()) return "skipped";
    // 和登录、演示登录同一把账号锁：已经建好的设备这里看得见（算作有人在用、或者被这次重置撤销），还没建的等重置完再建
    const lock = await lockAccount(tx.trx, demo.account_id);
    if (!lock) throw new Error("审核号不见了");

    if (!o.force) {
      const since = new Date(now.getTime() - DEMO_ACTIVE_WINDOW_MS);
      const active = await tx.trx
        .selectFrom("devices")
        .select("id")
        .where("store_id", "=", storeId)
        .where("revoked_at", "is", null)
        .where((eb) => eb.or([eb("last_seen_at", ">", since), eb("created_at", ">", since)]))
        .limit(1)
        .executeTakeFirst();
      if (active) {
        await tx.trx.updateTable("demo_stores").set({ next_reset_at: new Date(now.getTime() + DEMO_DEFER_MS) }).where("store_id", "=", storeId).execute();
        return "deferred";
      }
    }

    await wipeStoreData(tx);
    // 全部设备（含重置前已因申请注销、被踢、退出而撤销的）都改成 demo_reset：它们的 outbox 同样属于重置前那份数据，
    // 留着别的撤销原因，被踢设备补传的规则会把旧 op 记进刚种好的数据里。已撤销的保留原撤销时间（7 天清理按它算）
    await tx.trx
      .updateTable("devices")
      .set((eb) => ({ revoked_at: eb.fn.coalesce("revoked_at", eb.val(now)), revoke_reason: "demo_reset" }))
      .where("store_id", "=", storeId)
      .execute();
    await tx.trx
      .deleteFrom("devices")
      .where("store_id", "=", storeId)
      .where((eb) => eb.or([eb("revoked_at", "<", new Date(now.getTime() - DEMO_DEVICE_RETENTION_MS)), eb("id", "=", seedId(storeId, "device:seed"))]))
      .execute();
    await tx.trx
      .updateTable("accounts")
      .set({ password_hash: demo.review_password_hash, delete_requested_at: null, failed_logins: 0, locked_until: null })
      .where("id", "=", demo.account_id)
      .execute();
    await tx.trx.updateTable("stores").set({ name: DEMO_STORE_NAME, low_stock_default: LOW_STOCK_DEFAULT }).where("id", "=", storeId).execute();
    await applySeed(tx, demo.account_id, now);
    await tx.trx.updateTable("demo_stores").set({ seeded_at: now, next_reset_at: nextResetAfter(now) }).where("store_id", "=", storeId).execute();
    return "reset";
  });
}

/** 定时任务：把到点的演示店逐个重置（或顺延）。锁内重查到别的进程已处理了这个周期 → skipped。店铺排队满了就留到下一轮 */
export async function runDemoResets(db: Kysely<Database>, now: Date): Promise<Record<string, ResetOutcome | "busy">> {
  const due = await db.selectFrom("demo_stores").select("store_id").where("next_reset_at", "<=", now).execute();
  const out: Record<string, ResetOutcome | "busy"> = {};
  for (const d of due) {
    try {
      out[d.store_id] = await resetDemoStore(db, d.store_id, now, { onlyIfDue: true });
    } catch (e) {
      if (e instanceof StoreBusy) out[d.store_id] = "busy";
      else throw e;
    }
  }
  return out;
}
