// 登录相关（§7）：账号密码登录、扫码兑换开通码、演示登录、退出、查自己。
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { sql } from "kysely";
import { authOf } from "../auth/plugin.ts";
import { verifyPassword } from "../auth/password.ts";
import { SlidingWindowLimiter } from "../auth/ratelimit.ts";
import { createDevice, deletePendingUntil, DeviceIdTaken } from "../auth/session.ts";
import { sha256Hex } from "../auth/tokens.ts";
import { sendError } from "./errors.ts";

/** 连错 5 次锁 15 分钟（§7、25c） */
export const MAX_FAILED_LOGINS = 5;
export const LOCK_MS = 15 * 60_000;
/** 演示登录建的设备叫这个 */
const DEMO_LABEL = "演示手机";

const uuid = { type: "string", format: "uuid" } as const;
const label = { type: "string", minLength: 1, maxLength: 40 } as const;

interface SessionInfo {
  token: string;
  role: "family" | "cashier";
  store: { name: string; is_demo: boolean };
  label: string;
  epoch: string;
  deleteRequestedAt: Date | null;
}

function sessionBody(s: SessionInfo) {
  const until = deletePendingUntil(s.deleteRequestedAt);
  return {
    token: s.token,
    role: s.role,
    store: s.store,
    label: s.label,
    epoch: s.epoch,
    ...(until ? { delete_pending_until: until } : {}),
  };
}

export async function authRoutes(app: FastifyInstance): Promise<void> {
  const limits = app.deps.rateLimits;
  const loginLimiter = new SlidingWindowLimiter(limits.login);
  const redeemLimiter = new SlidingWindowLimiter(limits.redeem);
  const demoLimiter = new SlidingWindowLimiter(limits.demo);
  const db = app.deps.db.kysely;

  const limited = (l: SlidingWindowLimiter, req: FastifyRequest, reply: FastifyReply) => {
    const wait = l.hit(req.ip, req.receivedAt.getTime());
    if (wait > 0) {
      reply.header("retry-after", String(wait));
      sendError(reply, 429, "rate_limited", { retry_after_s: wait });
      return true;
    }
    return false;
  };

  app.post<{ Body: { username: string; password: string; device_id: string; label?: string } }>(
    "/v1/auth/login",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["username", "password", "device_id"],
          properties: {
            username: { type: "string", minLength: 1, maxLength: 64 },
            password: { type: "string", minLength: 1, maxLength: 256 },
            device_id: uuid,
            label,
          },
        },
      },
    },
    async (req, reply) => {
      if (limited(loginLimiter, req, reply)) return reply;
      const now = req.receivedAt;
      const { username, password, device_id } = req.body;
      const acct = await db
        .selectFrom("accounts as a")
        .innerJoin("stores as s", "s.id", "a.store_id")
        .select([
          "a.id",
          "a.store_id",
          "a.password_hash",
          "a.kind",
          "a.locked_until",
          "a.delete_requested_at",
          "s.name as store_name",
          "s.is_demo",
          "s.epoch",
        ])
        .where(sql<string>`lower(a.username)`, "=", username.trim().toLowerCase())
        .executeTakeFirst();

      // 错误信息不区分「账号不存在」和「密码错」（§7）
      if (!acct) {
        await verifyPassword(undefined, password);
        return sendError(reply, 401, "bad_credentials", { message: "用户名或密码不对" });
      }
      // 锁定期内正确密码也拒（S03 验收）
      if (acct.locked_until && acct.locked_until > now) {
        return sendError(reply, 423, "locked", { locked_until: acct.locked_until.toISOString(), message: "密码错了太多次，请稍后再试" });
      }
      if (!(await verifyPassword(acct.password_hash, password))) {
        // 原子地 +1；到 5 次就锁 15 分钟并把计数清零（解锁后重新数）
        const r = await db
          .updateTable("accounts")
          .set({ failed_logins: sql`failed_logins + 1` })
          .where("id", "=", acct.id)
          .where((eb) => eb.or([eb("locked_until", "is", null), eb("locked_until", "<=", now)]))
          .returning("failed_logins")
          .executeTakeFirst();
        if (!r || r.failed_logins >= MAX_FAILED_LOGINS) {
          const until = new Date(now.getTime() + LOCK_MS);
          if (r) await db.updateTable("accounts").set({ failed_logins: 0, locked_until: until }).where("id", "=", acct.id).execute();
          const lockedUntil = r ? until : ((await db.selectFrom("accounts").select("locked_until").where("id", "=", acct.id).executeTakeFirst())?.locked_until ?? until);
          return sendError(reply, 423, "locked", { locked_until: lockedUntil.toISOString(), message: "密码错了太多次，请稍后再试" });
        }
        return sendError(reply, 401, "bad_credentials", { message: "用户名或密码不对" });
      }

      try {
        const s = await db.transaction().execute(async (trx) => {
          await trx.updateTable("accounts").set({ failed_logins: 0, locked_until: null }).where("id", "=", acct.id).execute();
          return createDevice(trx, {
            storeId: acct.store_id,
            accountId: acct.id,
            deviceId: device_id,
            role: "family",
            label: req.body.label,
            now,
          });
        });
        return sessionBody({
          token: s.token,
          role: "family",
          store: { name: acct.store_name, is_demo: acct.is_demo },
          label: s.label,
          epoch: acct.epoch,
          deleteRequestedAt: acct.delete_requested_at,
        });
      } catch (e) {
        if (e instanceof DeviceIdTaken) return sendError(reply, 400, "invalid", { message: "device_id 已经用过，请重新生成" });
        throw e;
      }
    },
  );

  app.post<{ Body: { code: string; device_id: string } }>(
    "/v1/auth/pair/redeem",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["code", "device_id"],
          properties: { code: { type: "string", minLength: 1, maxLength: 128 }, device_id: uuid },
        },
      },
    },
    async (req, reply) => {
      if (limited(redeemLimiter, req, reply)) return reply;
      const now = req.receivedAt;
      type Out = { err: [number, string, string] } | { ok: SessionInfo };
      let out: Out;
      try {
        out = await db.transaction().execute(async (trx): Promise<Out> => {
          // 锁住这张码：两台手机同时扫同一张码，只有一台成功
          const pt = await trx
            .selectFrom("pairing_tokens as p")
            .innerJoin("accounts as a", (j) => j.onRef("a.id", "=", "p.account_id").onRef("a.store_id", "=", "p.store_id"))
            .innerJoin("stores as s", "s.id", "p.store_id")
            .innerJoin("devices as c", (j) => j.onRef("c.id", "=", "p.created_by_device").onRef("c.store_id", "=", "p.store_id"))
            .select([
              "p.id",
              "p.store_id",
              "p.account_id",
              "p.role",
              "p.label",
              "p.expires_at",
              "p.used_at",
              "a.delete_requested_at",
              "s.name as store_name",
              "s.is_demo",
              "s.epoch",
              "c.revoked_at as creator_revoked_at",
            ])
            .where("p.token_hash", "=", sha256Hex(req.body.code))
            .forUpdate("p")
            .executeTakeFirst();
          if (!pt) return { err: [404, "not_found", "这个码不认识"] };
          if (pt.used_at) return { err: [410, "pairing_used", "这个码已经用过了"] };
          // 出码的手机已被退出，它出的码也作废
          if (pt.expires_at <= now || pt.creator_revoked_at) return { err: [410, "pairing_expired", "这个码过期了"] };
          if (pt.delete_requested_at) return { err: [403, "delete_pending", "账号正在注销，不能开通新手机"] };
          const d = await createDevice(trx, {
            storeId: pt.store_id,
            accountId: pt.account_id,
            deviceId: req.body.device_id,
            role: pt.role,
            label: pt.label,
            now,
          });
          await trx
            .updateTable("pairing_tokens")
            .set({ used_at: now, used_by_device: req.body.device_id })
            .where("id", "=", pt.id)
            .execute();
          return {
            ok: {
              token: d.token,
              // 码里的角色决定设备角色（S03 验收）
              role: pt.role,
              store: { name: pt.store_name, is_demo: pt.is_demo },
              label: d.label,
              epoch: pt.epoch,
              deleteRequestedAt: null,
            },
          };
        });
      } catch (e) {
        if (e instanceof DeviceIdTaken) return sendError(reply, 400, "invalid", { message: "device_id 已经用过，请重新生成" });
        throw e;
      }
      if ("err" in out) return sendError(reply, out.err[0], out.err[1], { message: out.err[2] });
      return sessionBody(out.ok);
    },
  );

  // 开关关着时 guard 已经回了 404 demo_disabled（permissions.json 的 demo_login_enabled 条件）
  app.post<{ Body: { device_id: string } }>(
    "/v1/auth/demo",
    {
      schema: {
        body: { type: "object", additionalProperties: false, required: ["device_id"], properties: { device_id: uuid } },
      },
    },
    async (req, reply) => {
      if (limited(demoLimiter, req, reply)) return reply;
      const acct = await db
        .selectFrom("accounts as a")
        .innerJoin("stores as s", "s.id", "a.store_id")
        .select(["a.id", "a.store_id", "s.name as store_name", "s.epoch"])
        .where("a.kind", "=", "review")
        .where("s.is_demo", "=", true)
        .orderBy("a.created_at")
        .limit(1)
        .executeTakeFirst();
      if (!acct) return sendError(reply, 404, "demo_disabled", { message: "演示小店还没建" });
      try {
        // 发的是演示店的家用设备令牌（§7）；账号是审核号，所以身份是 review
        const d = await db.transaction().execute((trx) =>
          createDevice(trx, {
            storeId: acct.store_id,
            accountId: acct.id,
            deviceId: req.body.device_id,
            role: "family",
            label: DEMO_LABEL,
            now: req.receivedAt,
          }),
        );
        return sessionBody({
          token: d.token,
          role: "family",
          store: { name: acct.store_name, is_demo: true },
          label: d.label,
          epoch: acct.epoch,
          deleteRequestedAt: null,
        });
      } catch (e) {
        if (e instanceof DeviceIdTaken) return sendError(reply, 400, "invalid", { message: "device_id 已经用过，请重新生成" });
        throw e;
      }
    },
  );

  app.post("/v1/auth/logout", async (req, reply) => {
    const a = authOf(req);
    await db
      .updateTable("devices")
      .set({ revoked_at: req.receivedAt, revoke_reason: "logout" })
      .where("store_id", "=", a.store.id)
      .where("id", "=", a.device.id)
      .where("revoked_at", "is", null)
      .execute();
    return reply.code(204).send();
  });

  app.get("/v1/me", async (req) => {
    const a = authOf(req);
    const until = deletePendingUntil(a.account.deleteRequestedAt);
    return {
      role: a.device.role,
      store: { name: a.store.name, is_demo: a.store.isDemo },
      label: a.device.label,
      ...(until ? { delete_pending_until: until } : {}),
    };
  });
}
