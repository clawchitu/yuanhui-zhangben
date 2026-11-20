// 账号（§7）：改密码、申请注销、撤回注销。
// 本段只做申请、撤回和「注销期间禁止写账与开通」（guard 的 delete_pending）；7 天后真正删除和导出在 S09。
import type { FastifyInstance } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { hashPassword, PASSWORD_MAX, PASSWORD_MIN, verifyPassword } from "../auth/password.ts";
import { DELETE_GRACE_MS, deletePendingUntil } from "../auth/session.ts";
import { sendError } from "./errors.ts";

export async function accountRoutes(app: FastifyInstance): Promise<void> {
  const db = app.deps.db.kysely;

  const currentHash = async (accountId: string) =>
    (await db.selectFrom("accounts").select("password_hash").where("id", "=", accountId).executeTakeFirstOrThrow()).password_hash;

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
      if (!(await verifyPassword(await currentHash(a.account.id), req.body.old))) {
        return sendError(reply, 401, "bad_credentials", { message: "原密码不对" });
      }
      await db.updateTable("accounts").set({ password_hash: await hashPassword(req.body.new) }).where("id", "=", a.account.id).execute();
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
      if (!(await verifyPassword(await currentHash(a.account.id), req.body.password))) {
        return sendError(reply, 401, "bad_credentials", { message: "密码不对" });
      }
      const now = req.receivedAt;
      const requestedAt = await db.transaction().execute(async (trx) => {
        const acct = await trx
          .selectFrom("accounts")
          .select("delete_requested_at")
          .where("id", "=", a.account.id)
          .forUpdate()
          .executeTakeFirstOrThrow();
        // 重复申请不重新起算 7 天
        const at = acct.delete_requested_at ?? now;
        if (!acct.delete_requested_at) {
          await trx.updateTable("accounts").set({ delete_requested_at: at }).where("id", "=", a.account.id).execute();
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
    await db.updateTable("accounts").set({ delete_requested_at: null }).where("id", "=", a.account.id).execute();
    return reply.code(204).send();
  });
}
