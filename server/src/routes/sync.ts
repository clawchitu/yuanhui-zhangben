// POST /v1/sync（§4.2）：推 op + 拉变更。平时唯一的写账入口。
// 顺序：最低版本 → epoch 握手 → 推（店铺锁内一个事务；注销期间整批跳过）→ 拉（只读快照）。
import type { FastifyInstance } from "fastify";
import { authOf } from "../auth/plugin.ts";
import { Guard } from "../auth/guard.ts";
import { emptyChanges, pullChanges, type Cursors } from "../sync/pull.ts";
import { StoreBusy } from "../sync/lock.ts";
import { deletePendingUntil } from "../auth/session.ts";
import { EpochMismatch, pushOps, type DeviceState, type IncomingOp, type OpResult } from "../sync/push.ts";
import { SCOPES, type Scope } from "../sync/projection.ts";
import { strictValidatorCompiler, syncBodySchema } from "../sync/validate.ts";
import { identityOf } from "../auth/authenticate.ts";
import { sendError } from "./errors.ts";

interface SyncBody {
  epoch: string;
  cursors: Cursors;
  ops: IncomingOp[];
  app_build: number;
  pull?: boolean;
}

export async function syncRoutes(app: FastifyInstance): Promise<void> {
  const guard = new Guard();
  const db = app.deps.db.kysely;

  app.post<{ Body: SyncBody }>(
    "/v1/sync",
    { schema: { body: syncBodySchema }, validatorCompiler: strictValidatorCompiler },
    async (req, reply) => {
      const a = authOf(req);
      const body = req.body;
      const { config } = app.deps;
      const now = req.receivedAt;

      if (body.app_build < config.minBuild) return sendError(reply, 426, "build_too_old", { message: "请更新 App" });
      if (body.epoch.toLowerCase() !== a.store.epoch.toLowerCase()) {
        return reply.code(409).send({ code: "epoch_mismatch", epoch: a.store.epoch });
      }

      let results: OpResult[] = [];
      let device: DeviceState = {
        role: a.device.role,
        label: a.device.label,
        identity: identityOf({ role: a.device.role, revoked_at: a.device.revokedAt }, a.account.kind),
        revokedAt: a.device.revokedAt,
        revokeReason: a.device.revokeReason,
        deletePending: a.account.deleteRequestedAt !== null,
        deleteRequestedAt: a.account.deleteRequestedAt,
      };
      if (body.ops.length > 0) {
        try {
          ({ results, device } = await pushOps(db, guard, {
            auth: a,
            ops: body.ops,
            now,
            epoch: body.epoch,
            config: { demoLoginEnabled: config.demoLoginEnabled, recoveryMode: config.recoveryMode },
            queueLimit: config.storeQueueLimit,
            log: req.log,
          }));
        } catch (e) {
          if (e instanceof EpochMismatch) return reply.code(409).send({ code: "epoch_mismatch", epoch: e.epoch });
          // 这家店在途的写入超过上限（§14 S04-8）：不进队列、不取连接，手机原样重发（按 id 幂等）
          if (e instanceof StoreBusy) return sendError(reply, 503, "unavailable", { retry_after_s: e.retryAfterS });
          throw e;
        }
      }

      // 拉取：被踢设备不返回任何数据；pull=false（恢复队列只推不拉）也不拉
      const pull = guard.decidePull(device.identity, { now, config: { demoLoginEnabled: config.demoLoginEnabled, recoveryMode: config.recoveryMode } });
      let out = { changes: emptyChanges(), cursors: body.cursors, has_more: { catalog: false, ledger: false }, total_products: 0 };
      if (pull.ok && body.pull !== false) {
        const scope = pull.scope as Scope;
        if (!SCOPES.includes(scope)) throw new Error(`permissions.json 的 sync:pull 有不认识的 scope：${String(pull.scope)}`);
        out = await pullChanges(db, {
          storeId: a.store.id,
          deviceId: a.device.id,
          scope,
          cursors: body.cursors,
          pageSize: app.deps.syncPageSize,
          now,
        });
      }

      // 注销期间（§14 S04-2）：results 为空，带 delete_pending_until，手机把 op 留在 outbox、停止推送
      const until = device.deletePending ? deletePendingUntil(device.deleteRequestedAt) : undefined;
      return {
        results,
        ...(until ? { delete_pending_until: until } : {}),
        ...out,
        server_time: now.toISOString(),
        epoch: a.store.epoch,
        min_build: config.minBuild,
        device: {
          role: device.role,
          label: device.label,
          revoked: device.revokedAt !== null,
          ...(device.revokeReason === "demo_reset" ? { discard_outbox: true } : {}),
        },
        store: { name: a.store.name },
      };
    },
  );
}
