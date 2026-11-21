// 账号（§7）：改密码、申请注销、撤回注销。
// 申请时为非演示店登记导出任务；导出包生成、7 天后真正删除在 jobs/account-purge.ts（S09）。
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { hashPassword, PASSWORD_MAX, PASSWORD_MIN } from "../auth/password.ts";
import { SlidingWindowLimiter } from "../auth/ratelimit.ts";
import { DELETE_GRACE_MS, deletePendingUntil } from "../auth/session.ts";
import { sendError } from "./errors.ts";

export async function accountRoutes(app: FastifyInstance): Promise<void> {
  const db = app.deps.db.kysely;

  // 令牌验过之后这家店到期清除了（jobs/account-purge.ts 删掉了账号）：和清除之后再来的请求一样按令牌不认识回 401，不是 500
  const gone = (reply: FastifyReply) => sendError(reply, 401, "unauthorized");
  const currentHash = async (accountId: string) =>
    (await db.selectFrom("accounts").select("password_hash").where("id", "=", accountId).executeTakeFirst())?.password_hash;

  // 原密码输错按账号限速（§14 S03-8）：改密码和申请注销共用一个计数，不计入登录锁定（否则一台家用手机能把登录锁死）。
  // 先占一格再验密码，验对了撤回：同时发来的一批请求也最多猜 5 次。
  const wrongPassword = new SlidingWindowLimiter(app.deps.rateLimits.accountPassword);
  const checkOldPassword = async (req: FastifyRequest, reply: FastifyReply, password: string): Promise<boolean> => {
    const a = authOf(req);
    const at = req.receivedAt.getTime();
    const wait = wrongPassword.hit(a.account.id, at);
    if (wait > 0) {
      reply.header("retry-after", String(wait));
      sendError(reply, 429, "rate_limited", { retry_after_s: wait, message: "密码错了太多次，请稍后再试" });
      return false;
    }
    const hash = await currentHash(a.account.id);
    if (hash === undefined) {
      wrongPassword.undo(a.account.id, at);
      gone(reply);
      return false;
    }
    if (await app.deps.verifyPassword(hash, password)) {
      wrongPassword.undo(a.account.id, at);
      return true;
    }
    sendError(reply, 401, "bad_credentials", { message: "密码不对" });
    return false;
  };

  // 不强制其他手机退出（§7）
  app.post<{ Body: { old: string; new: string } }>(
    "/v1/account/password",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["old", "new"],
          properties: {
            old: { type: "string", minLength: 1, maxLength: PASSWORD_MAX },
            new: { type: "string", minLength: PASSWORD_MIN, maxLength: PASSWORD_MAX },
          },
        },
      },
    },
    async (req, reply) => {
      const a = authOf(req);
      if (!(await checkOldPassword(req, reply, req.body.old))) return reply;
      const r = await db.updateTable("accounts").set({ password_hash: await hashPassword(req.body.new) }).where("id", "=", a.account.id).executeTakeFirst();
      if (Number(r.numUpdatedRows) !== 1) return gone(reply);
      return reply.code(204).send();
    },
  );

  // 记 delete_requested_at，全部设备退出（含本机），还没用的开通码作废
  app.post<{ Body: { password: string } }>(
    "/v1/account/delete-request",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["password"],
          properties: { password: { type: "string", minLength: 1, maxLength: PASSWORD_MAX } },
        },
      },
    },
    async (req, reply) => {
      const a = authOf(req);
      if (!(await checkOldPassword(req, reply, req.body.password))) return reply;
      const now = req.receivedAt;
      const requestedAt = await db.transaction().execute(async (trx) => {
        const acct = await trx
          .selectFrom("accounts")
          .select("delete_requested_at")
          .where("id", "=", a.account.id)
          // 和登录、兑码同一把账号锁（FOR NO KEY UPDATE，见 createDevice 的说明）
          .forNoKeyUpdate()
          .executeTakeFirst();
        if (!acct) return null;
        // 重复申请不重新起算 7 天
        const at = acct.delete_requested_at ?? now;
        if (!acct.delete_requested_at) {
          await trx.updateTable("accounts").set({ delete_requested_at: at }).where("id", "=", a.account.id).execute();
          // 非演示店：同一事务里登记导出任务（jobs/account-purge.ts 生成导出包、告警转交黄总，S09）。
          // 撤回后又申请是新的一次：同一行重置（旧包由新包生成成功后删掉，或由撤回清理删掉）
          if (!a.store.isDemo) {
            await trx
              .insertInto("export_jobs")
              .values({ store_id: a.store.id, requested_at: at, next_try_at: now })
              .onConflict((oc) =>
                oc.column("store_id").doUpdateSet({ requested_at: at, next_try_at: now, object_key: null, done_at: null, attempts: 0, last_error: null, cancelled_at: null, stale_cleared_at: null }),
              )
              .execute();
          }
        }
        await trx
          .updateTable("devices")
          .set({ revoked_at: now, revoke_reason: "account_delete" })
          .where("store_id", "=", a.store.id)
          .where("revoked_at", "is", null)
          .execute();
        await trx
          .updateTable("pairing_tokens")
          .set({ expires_at: now })
          .where("store_id", "=", a.store.id)
          .where("used_at", "is", null)
          .where("expires_at", ">", now)
          .execute();
        return at;
      });
      if (!requestedAt) return gone(reply);
      return { delete_pending_until: deletePendingUntil(requestedAt) };
    },
  );

  // 7 天内用账号密码登录后撤回（§7）。不在注销期间、或已过 7 天 → 409 not_delete_pending
  app.post("/v1/account/delete-cancel", async (req, reply) => {
    const a = authOf(req);
    const at = a.account.deleteRequestedAt;
    if (!at || req.receivedAt.getTime() - at.getTime() > DELETE_GRACE_MS) {
      return sendError(reply, 409, "not_delete_pending", { message: at ? "已经超过 7 天，不能撤回" : "账号不在注销中" });
    }
    // 条件更新：和到期清除（锁账号行后重查）不会两边都成立；同一事务里把导出任务标成撤回（定时任务删掉已生成的包）
    const ok = await db.transaction().execute(async (trx) => {
      const r = await trx
        .updateTable("accounts")
        .set({ delete_requested_at: null })
        .where("id", "=", a.account.id)
        .where("delete_requested_at", "=", at)
        .executeTakeFirst();
      if (Number(r.numUpdatedRows) !== 1) return false;
      await trx.updateTable("export_jobs").set({ cancelled_at: req.receivedAt }).where("store_id", "=", a.store.id).execute();
      return true;
    });
    if (!ok) return sendError(reply, 409, "not_delete_pending", { message: "账号不在注销中" });
    return reply.code(204).send();
  });
}
