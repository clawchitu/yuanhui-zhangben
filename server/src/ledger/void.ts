// 撤销（§3.3 撤销的记法、§4.4「撤销两次」、§5.2 撤销 / 成本补记，§14 S05-1、S05-6 ④⑤）：void op 写库。
// target 是整批（batch_id：批内每一行卖出）或单行（entry_id）。每撤一行：冲销行（类型相同、数量金额取反、
// unit_cost_fen 照抄、occurred_at = 撤销时间），被补记过的卖出再加 cost_fix 冲销行和 +数量 × b 的 cost_adjust（b 取原 cost_fix），
// 必要时 cost_adjust 归位；原行打 voided_at。算法全在 cost.ts 的 voidEntry，这里只读库、写库。
// 同一行产生的流水 seq 相邻递增（assertLedger 的 cost_fix 冲销断言依赖它）。已撤销的行跳过：撤销两次第二次无操作。
// 找不到 target、target 是冲销行或自动生成的行（cost_adjust、cost_fix）→ rejected invalid 并留档。
import type { Selectable } from "kysely";
import type { Database } from "../db.ts";
import type { StoreTx } from "../sync/lock.ts";
import { Remap } from "../sync/aliases.ts";
import type { Outcome } from "../sync/catalog.ts";
import { raw, VOIDABLE, type Draft, type EntryType } from "./cost.ts";
import { onVoid } from "./lots.ts";
import { bad, guarded, loadProduct, stateOf, writeStep, type LedgerContext } from "./apply.ts";

type EntryRow = Selectable<Database["entries"]>;

interface VoidPayload {
  target: { batch_id?: string; entry_id?: string };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 权限判定要的事实（§6 第③条，permissions.json op:void 的 own_device_sale、sale_day_eq_server_receive_day）：
 * 被撤销的卖出是哪台设备记的、什么时候记的。整批看批次头（批内每一行与批次头同设备、同时间）；
 * 单行只认原始的卖出行（冲销行、进货等返回 undefined → 收银员按「不满足」拒）。payload 还没过 schema，id 格式不对就当找不到。
 */
export async function voidTargetSale(tx: StoreTx, payload: unknown): Promise<{ deviceId: string; occurredAt: Date } | undefined> {
  const t = (payload as VoidPayload | undefined)?.target;
  if (!t || typeof t !== "object") return undefined;
  if (typeof t.batch_id === "string" && UUID.test(t.batch_id)) {
    const b = await tx.trx.selectFrom("sale_batches").select(["device_id", "occurred_at"]).where("store_id", "=", tx.storeId).where("id", "=", t.batch_id.toLowerCase()).executeTakeFirst();
    return b && { deviceId: b.device_id, occurredAt: b.occurred_at };
  }
  if (typeof t.entry_id === "string" && UUID.test(t.entry_id)) {
    const e = await tx.trx
      .selectFrom("entries")
      .select(["device_id", "occurred_at", "type", "reverses_entry_id"])
      .where("store_id", "=", tx.storeId)
      .where("id", "=", t.entry_id.toLowerCase())
      .executeTakeFirst();
    return e && e.type === "sale" && e.reverses_entry_id === null ? { deviceId: e.device_id, occurredAt: e.occurred_at } : undefined;
  }
  return undefined;
}

function draftOf(e: EntryRow): Draft & { ref: string } {
  return {
    ref: e.id,
    type: e.type as EntryType,
    qty_delta: BigInt(e.qty_delta),
    amount_fen: BigInt(e.amount_fen),
    list_amount_fen: BigInt(e.list_amount_fen),
    cogs_fen: BigInt(e.cogs_fen),
    value_delta_fen: BigInt(e.value_delta_fen),
    cost_missing: e.cost_missing,
    unit_cost_fen: e.unit_cost_fen === null ? null : BigInt(e.unit_cost_fen),
  };
}

async function voidOne(tx: StoreTx, ctx: LedgerContext, e: EntryRow) {
  if (e.voided_at !== null) return; // 撤销两次：第二次无操作
  const prod = (await loadProduct(tx, e.product_id))!;
  let fixedBy: { ref: string; b: bigint } | undefined;
  if (e.cost_fix_entry_id !== null) {
    const f = await tx.trx.selectFrom("entries").select(["id", "unit_cost_fen"]).where("store_id", "=", tx.storeId).where("id", "=", e.cost_fix_entry_id).executeTakeFirstOrThrow();
    fixedBy = { ref: f.id, b: BigInt(f.unit_cost_fen!) };
  }
  const step = raw.voidEntry(stateOf(prod), draftOf(e), fixedBy);
  // 冲销行照抄原行的展示字段；件数是数量，跟 qty_delta 一起取反（§3.3「所有数量和金额取反」）
  await writeStep(tx, ctx, prod, {
    batchId: e.batch_id ?? undefined,
    nameSnapshot: e.name_snapshot,
    barcode: e.barcode,
    unitName: e.unit_name,
    packQty: e.pack_qty,
    packCount: e.pack_count === null ? null : -e.pack_count,
    expiryDate: e.expiry_date,
  }, step);
  await tx.trx
    .updateTable("entries")
    .set({ voided_at: ctx.occurredAt, voided_by_device: ctx.deviceId, rev: await tx.nextRev() } as never)
    .where("store_id", "=", tx.storeId)
    .where("id", "=", e.id)
    .execute();
  await onVoid(tx, ctx, e);
}

export async function applyVoid(tx: StoreTx, ctx: LedgerContext, p: VoidPayload): Promise<Outcome> {
  return guarded(tx, new Remap(), async () => {
    const base = tx.trx.selectFrom("entries").selectAll().where("store_id", "=", tx.storeId);
    let rows: EntryRow[];
    if (p.target.batch_id !== undefined) {
      const id = p.target.batch_id.toLowerCase();
      const b = await tx.trx.selectFrom("sale_batches").select("id").where("store_id", "=", tx.storeId).where("id", "=", id).executeTakeFirst();
      if (!b) bad("要撤销的这笔卖出不存在");
      rows = await base.where("batch_id", "=", id).where("type", "=", "sale").where("reverses_entry_id", "is", null).orderBy("seq").execute();
    } else {
      const e = await base.where("id", "=", p.target.entry_id!.toLowerCase()).executeTakeFirst();
      if (!e) bad("要撤销的流水不存在");
      if (e.reverses_entry_id !== null || !VOIDABLE.has(e.type as EntryType)) bad(`${e.type} 冲销行 / 自动生成的流水不能撤销`);
      rows = [e];
    }
    for (const e of rows) await voidOne(tx, ctx, e);
  });
}
