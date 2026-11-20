// 测试夹具：直接往 ledger 流的表里写卖出、进货、批次（记账引擎在 S05/S06，这里只为测拉取和裁剪）。
// 写入走正式的店铺锁和取号函数，和以后的记账引擎一样。
import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { Kysely } from "kysely";
import type { Database } from "../../src/db.ts";
import { withStoreLock } from "../../src/sync/lock.ts";

type K = Kysely<Database>;

/** 建一台带已知令牌的设备（不走 argon2 登录，性质测试里要建很多店） */
export async function makeTokenDevice(db: K, storeId: string, accountId: string, role: "family" | "cashier" = "family") {
  const token = randomBytes(32).toString("base64url");
  const id = randomUUID();
  await db
    .insertInto("devices")
    .values({
      id,
      store_id: storeId,
      account_id: accountId,
      role,
      label: `${role}_${randomBytes(3).toString("hex")}`,
      token_hash: createHash("sha256").update(token).digest("hex"),
    })
    .execute();
  return { id, token };
}

/** 一个店 + 账号（不需要密码）+ 一台家用设备 */
export async function makeFastShop(db: K) {
  const store = await db.insertInto("stores").values({ name: "测试店" }).returningAll().executeTakeFirstOrThrow();
  const account = await db
    .insertInto("accounts")
    .values({ store_id: store.id, username: `u_${randomBytes(5).toString("hex")}`, password_hash: "x", kind: "family" })
    .returningAll()
    .executeTakeFirstOrThrow();
  const family = await makeTokenDevice(db, store.id, account.id, "family");
  return { storeId: store.id, epoch: store.epoch, accountId: account.id, family };
}

async function appliedOp(trx: K, storeId: string, deviceId: string, type: "sale_batch" | "stock_in", at: Date) {
  const id = randomUUID();
  await trx
    .insertInto("ops")
    .values({
      id,
      store_id: storeId,
      device_id: deviceId,
      type,
      payload: "{}",
      payload_hash: "fixture",
      occurred_at: at,
      status: "applied",
      result: JSON.stringify({ id, status: "applied" }),
    })
    .execute();
  return id;
}

async function nextSeq(trx: K, storeId: string): Promise<number> {
  const r = await trx
    .selectFrom("entries")
    .select((eb) => eb.fn.max("seq").as("m"))
    .where("store_id", "=", storeId)
    .executeTakeFirst();
  return Number(r?.m ?? 0) + 1;
}

/** 一笔卖出：一个批次头 + 每行一条 sale 流水（数字随便填，只测同步） */
export async function insertSale(
  db: K,
  s: { storeId: string; deviceId: string; productIds: string[]; at?: Date },
): Promise<{ batchId: string; entryIds: string[] }> {
  const at = s.at ?? new Date(Date.now() - 60_000);
  return withStoreLock(db, s.storeId, async (tx) => {
    const opId = await appliedOp(tx.trx, s.storeId, s.deviceId, "sale_batch", at);
    const batchId = randomUUID();
    await tx.trx
      .insertInto("sale_batches")
      .values({
        id: batchId,
        store_id: s.storeId,
        device_id: s.deviceId,
        list_total_fen: 300 * s.productIds.length,
        paid_total_fen: 300 * s.productIds.length,
        occurred_at: at,
        rev: await tx.nextRev(),
      })
      .execute();
    const entryIds: string[] = [];
    for (const pid of s.productIds) {
      const id = randomUUID();
      entryIds.push(id);
      await tx.trx
        .insertInto("entries")
        .values({
          id,
          store_id: s.storeId,
          seq: await nextSeq(tx.trx, s.storeId),
          op_id: opId,
          batch_id: batchId,
          type: "sale",
          product_id: pid,
          barcode: "6900000000000",
          name_snapshot: "可乐",
          unit_name: "罐",
          pack_qty: 1,
          pack_count: 1,
          qty_delta: -1,
          list_amount_fen: 300,
          amount_fen: 300,
          unit_cost_fen: 200,
          cogs_fen: 200,
          value_delta_fen: -200,
          device_id: s.deviceId,
          occurred_at: at,
          rev: await tx.nextRev(),
        })
        .execute();
    }
    return { batchId, entryIds };
  });
}

/** 一次进货：一条 stock_in 流水 + 一个保质期批次 */
export async function insertStockIn(db: K, s: { storeId: string; deviceId: string; productId: string; at?: Date }) {
  const at = s.at ?? new Date(Date.now() - 120_000);
  return withStoreLock(db, s.storeId, async (tx) => {
    const opId = await appliedOp(tx.trx, s.storeId, s.deviceId, "stock_in", at);
    const entryId = randomUUID();
    await tx.trx
      .insertInto("entries")
      .values({
        id: entryId,
        store_id: s.storeId,
        seq: await nextSeq(tx.trx, s.storeId),
        op_id: opId,
        type: "stock_in",
        product_id: s.productId,
        barcode: "6900000000000",
        name_snapshot: "可乐",
        unit_name: "箱",
        pack_qty: 24,
        pack_count: 1,
        qty_delta: 24,
        list_amount_fen: 4800,
        amount_fen: 4800,
        unit_cost_fen: 4800,
        value_delta_fen: 4800,
        expiry_date: "2027-03-01",
        device_id: s.deviceId,
        occurred_at: at,
        rev: await tx.nextRev(),
      })
      .execute();
    const lotId = randomUUID();
    await tx.trx
      .insertInto("stock_lots")
      .values({
        id: lotId,
        store_id: s.storeId,
        product_id: s.productId,
        source_entry_id: entryId,
        expiry_date: "2027-03-01",
        qty_in: 24,
        qty_left: 24,
        rev: await tx.nextRev(),
      })
      .execute();
    return { entryId, lotId };
  });
}
