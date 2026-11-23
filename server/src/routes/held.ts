// 被退出的手机补传上来、等确认的账（§4.5、§7）：`GET /v1/held-ops`、`POST /v1/held-ops/:id/resolve`。只有家用（permissions.json）。
// 「记上」：店铺锁内按原设备、原 occurred_at 跑同一个处理函数（push.ts 的 HANDLERS），流水带 late_from_revoked；
// 依赖当时账面数的（盘点、期初、补全、处理快过期）版本已变 → 409 stale、不改，只能「不要」。
// 「不要」：status = rejected、reject_code = discarded。两种都写 resolved_at / resolved_by_device，之后那台手机重发拿到的就是新结果。
import type { FastifyInstance } from "fastify";
import type { Kysely } from "kysely";
import type { Database } from "../db.ts";
import { authOf } from "../auth/plugin.ts";
import { HANDLERS, type OpResult } from "../sync/push.ts";
import { withStoreLock } from "../sync/lock.ts";
import type { OpType } from "../sync/validate.ts";
import { sendError } from "./errors.ts";

const idParam = { type: "object", required: ["id"], properties: { id: { type: "string", format: "uuid" } } } as const;

/** 版本还对得上吗（不对只能丢弃）。没有版本字段的 op 总是可以记上 */
async function canAccept(tx: { trx: Kysely<Database>; storeId: string }, type: string, payload: Record<string, unknown>): Promise<boolean> {
  // 不带 base_ver 的期初（新商品第二步）隐含版本 0：商品库存动过就只能不要（PR #41 Codex 可选 2）
  const implicitZero = type === "opening" && payload.base_ver === undefined;
  if ((typeof payload.base_ver === "number" || implicitZero) && typeof payload.product_id === "string") {
    const p = await tx.trx.selectFrom("products").select("stock_ver").where("store_id", "=", tx.storeId)
      .where("id", "=", payload.product_id).executeTakeFirst();
    if (!p) return implicitZero;
    return Number(p.stock_ver) === (implicitZero ? 0 : payload.base_ver);
  }
  if ((type === "expiry_dispose" || type === "lot_snooze") && typeof payload.lot_id === "string") {
    const l = await tx.trx.selectFrom("stock_lots").select("handle_ver").where("store_id", "=", tx.storeId)
      .where("id", "=", payload.lot_id).executeTakeFirst();
    return !!l && Number(l.handle_ver) === payload.handle_ver;
  }
  return true;
}

class Stale extends Error {}

export async function heldRoutes(app: FastifyInstance): Promise<void> {
  const db = app.deps.db.kysely;

  app.get("/v1/held-ops", async (req) => {
    const a = authOf(req);
    const rows = await db
      .selectFrom("ops as o")
      .innerJoin("devices as d", (j) => j.onRef("d.store_id", "=", "o.store_id").onRef("d.id", "=", "o.device_id"))
      .select(["o.id", "o.device_id", "d.label", "o.type", "o.occurred_at", "o.payload"])
      .where("o.store_id", "=", a.store.id)
      .where("o.status", "=", "held")
      .orderBy("o.received_at")
      .orderBy("o.id")
      .execute();
    const held = [];
    for (const r of rows) {
      const payload = r.payload as Record<string, unknown>;
      held.push({
        id: r.id,
        device_id: r.device_id,
        device_label: r.label,
        type: r.type,
        occurred_at: r.occurred_at.toISOString(),
        payload,
        can_accept: await canAccept({ trx: db, storeId: a.store.id }, r.type, payload),
      });
    }
    return { held };
  });

  app.post<{ Params: { id: string }; Body: { action: "accept" | "discard" } }>(
    "/v1/held-ops/:id/resolve",
    {
      schema: {
        params: idParam,
        body: { type: "object", additionalProperties: false, required: ["action"], properties: { action: { enum: ["accept", "discard"] } } },
      },
    },
    async (req, reply) => {
      const a = authOf(req);
      const now = req.receivedAt;
      const id = req.params.id.toLowerCase();
      try {
        const result = await withStoreLock(db, a.store.id, async (tx): Promise<OpResult | null> => {
          const op = await tx.trx.selectFrom("ops").selectAll().where("store_id", "=", tx.storeId).where("id", "=", id)
            .where("status", "=", "held").forUpdate().executeTakeFirst();
          if (!op) return null;
          const payload = op.payload as Record<string, unknown>;
          let out: OpResult;
          if (req.body.action === "discard") {
            out = { id, status: "rejected", code: "discarded" };
          } else {
            if (!(await canAccept(tx, op.type, payload))) throw new Stale();
            const flags = { ...(op.flags as Record<string, unknown>), late_from_revoked: true };
            await tx.trx.updateTable("ops").set({ status: "applied", flags: JSON.stringify(flags), resolved_at: now, resolved_by_device: a.device.id })
              .where("store_id", "=", tx.storeId).where("id", "=", id).execute();
            const r = await HANDLERS[op.type as OpType](tx, { deviceId: op.device_id, now, occurredAt: op.occurred_at, opId: id, flags }, payload as never);
            if (r.status === "rejected" && r.code === "stale") throw new Stale();
            out = { id, ...r };
          }
          await tx.trx.updateTable("ops")
            .set({
              status: out.status === "held" ? "applied" : out.status,
              reject_code: out.status === "rejected" ? (out.code ?? null) : null,
              result: JSON.stringify(out),
              resolved_at: now,
              resolved_by_device: a.device.id,
            })
            .where("store_id", "=", tx.storeId).where("id", "=", id).execute();
          return out;
        });
        if (!result) return sendError(reply, 404, "not_found");
        return result;
      } catch (e) {
        if (e instanceof Stale) return sendError(reply, 409, "stale", { message: "账面已经变了，只能不要，重新盘一次" });
        throw e;
      }
    },
  );
}
