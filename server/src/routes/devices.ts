// 开通码与设备管理（§7）：出码、轮询、已登录的手机、踢人、改手机名。
// 店 id 一律取自令牌（authOf），别的店的 id 查不到 → 404。
import type { FastifyInstance } from "fastify";
import { sql } from "kysely";
import { authOf } from "../auth/plugin.ts";
import { lockStoreLabels, uniqueLabel } from "../auth/session.ts";
import { newSecret, sha256Hex } from "../auth/tokens.ts";
import { sendError } from "./errors.ts";

/** 开通码 2 分钟过期（§3.1） */
export const PAIRING_TTL_MS = 2 * 60_000;

const idParam = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", format: "uuid" } },
} as const;
const label = { type: "string", minLength: 1, maxLength: 40 } as const;

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  const db = app.deps.db.kysely;

  // 只有家用（和演示店里的审核）设备能出码：guard 按 permissions.json 已经拦了收银员；注销期间 guard 拦 delete_pending
  app.post<{ Body: { role: "family" | "cashier"; label?: string } }>(
    "/v1/pairing-tokens",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["role"],
          properties: { role: { enum: ["family", "cashier"] }, label },
          // 收银员码必须带称呼（§7）
          if: { properties: { role: { const: "cashier" } } },
          then: { required: ["label"] },
        },
      },
    },
    async (req, reply) => {
      const a = authOf(req);
      const code = newSecret();
      const expires = new Date(req.receivedAt.getTime() + PAIRING_TTL_MS);
      const label = req.body.label?.trim() || null;
      if (req.body.role === "cashier" && !label) return sendError(reply, 400, "invalid", { message: "收银员码要写称呼" });
      const row = await db
        .insertInto("pairing_tokens")
        .values({
          token_hash: sha256Hex(code),
          account_id: a.account.id,
          store_id: a.store.id,
          role: req.body.role,
          label,
          created_by_device: a.device.id,
          expires_at: expires,
        })
        .returning(["id"])
        .executeTakeFirstOrThrow();
      return reply.code(201).send({ id: row.id, code, expires_at: expires.toISOString() });
    },
  );

  app.get<{ Params: { id: string } }>("/v1/pairing-tokens/:id", { schema: { params: idParam } }, async (req, reply) => {
    const a = authOf(req);
    const pt = await db
      .selectFrom("pairing_tokens as p")
      .leftJoin("devices as u", (j) => j.onRef("u.id", "=", "p.used_by_device").onRef("u.store_id", "=", "p.store_id"))
      .select(["p.expires_at", "p.used_at", "u.label as used_by_label"])
      .where("p.store_id", "=", a.store.id)
      .where("p.id", "=", req.params.id)
      .executeTakeFirst();
    if (!pt) return sendError(reply, 404, "not_found");
    if (pt.used_at) return { status: "used", ...(pt.used_by_label ? { used_by_label: pt.used_by_label } : {}) };
    return { status: pt.expires_at <= req.receivedAt ? "expired" : "waiting" };
  });

  // 未撤销的设备，以及有暂存账的已撤销设备（「『某手机』被退出前还有 N 笔别的账」）
  app.get("/v1/devices", async (req) => {
    const a = authOf(req);
    const rows = await db
      .selectFrom("devices as d")
      .select((eb) => [
        "d.id",
        "d.label",
        "d.role",
        "d.created_at",
        "d.last_seen_at",
        "d.revoked_at",
        eb
          .selectFrom("ops as o")
          .select(sql<string>`count(*)`.as("n"))
          .whereRef("o.store_id", "=", "d.store_id")
          .whereRef("o.device_id", "=", "d.id")
          .where("o.status", "=", "held")
          .as("held_count"),
      ])
      .where("d.store_id", "=", a.store.id)
      .orderBy("d.created_at")
      .orderBy("d.id")
      .execute();
    return {
      devices: rows
        .map((r) => ({ ...r, held: Number(r.held_count ?? 0) }))
        .filter((r) => r.revoked_at === null || r.held > 0)
        .map((r) => ({
          id: r.id,
          label: r.label,
          role: r.role,
          created_at: r.created_at.toISOString(),
          last_seen_at: r.last_seen_at ? r.last_seen_at.toISOString() : null,
          is_me: r.id === a.device.id,
          revoked: r.revoked_at !== null,
          held_count: r.held,
        })),
    };
  });

  // 不能踢自己：guard 的 not_self 条件已经回 400 cannot_revoke_self
  app.post<{ Params: { id: string } }>("/v1/devices/:id/revoke", { schema: { params: idParam } }, async (req, reply) => {
    const a = authOf(req);
    const d = await db
      .selectFrom("devices")
      .select(["id", "revoked_at"])
      .where("store_id", "=", a.store.id)
      .where("id", "=", req.params.id)
      .executeTakeFirst();
    if (!d) return sendError(reply, 404, "not_found");
    if (!d.revoked_at) {
      await db
        .updateTable("devices")
        .set({ revoked_at: req.receivedAt, revoke_reason: "kicked" })
        .where("store_id", "=", a.store.id)
        .where("id", "=", d.id)
        .where("revoked_at", "is", null)
        .execute();
    }
    return reply.code(204).send();
  });

  app.post("/v1/devices/revoke-others", async (req) => {
    const a = authOf(req);
    const r = await db
      .updateTable("devices")
      .set({ revoked_at: req.receivedAt, revoke_reason: "revoke_others" })
      .where("store_id", "=", a.store.id)
      .where("id", "<>", a.device.id)
      .where("revoked_at", "is", null)
      .executeTakeFirst();
    return { revoked: Number(r.numUpdatedRows) };
  });

  // 收银员不能改（称呼由家里人定）：guard 已拦
  app.patch<{ Body: { label: string } }>(
    "/v1/devices/me",
    {
      schema: {
        body: { type: "object", additionalProperties: false, required: ["label"], properties: { label } },
      },
    },
    async (req, reply) => {
      const a = authOf(req);
      if (!req.body.label.trim()) return sendError(reply, 400, "invalid", { message: "名字不能是空的" });
      const label = await db.transaction().execute(async (trx) => {
        await lockStoreLabels(trx, a.store.id);
        const l = await uniqueLabel(trx, a.store.id, req.body.label, a.device.id);
        await trx.updateTable("devices").set({ label: l }).where("store_id", "=", a.store.id).where("id", "=", a.device.id).execute();
        return l;
      });
      return { label };
    },
  );
}
