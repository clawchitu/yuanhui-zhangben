// 测试夹具：最小化地建店、账号、设备、商品、条码、op、流水。
import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { Kysely } from "kysely";
import type { Database } from "../../src/db.ts";
import { nextRev } from "./db.ts";

type K = Kysely<Database>;

export async function makeStore(db: K, o: { name?: string; isDemo?: boolean } = {}) {
  return db
    .insertInto("stores")
    .values({ name: o.name ?? "测试店", is_demo: o.isDemo ?? false })
    .returningAll()
    .executeTakeFirstOrThrow();
}

export async function makeAccount(db: K, storeId: string, o: { username?: string; kind?: "family" | "review" } = {}) {
  return db
    .insertInto("accounts")
    .values({
      store_id: storeId,
      username: o.username ?? `u_${randomBytes(4).toString("hex")}`,
      password_hash: "x",
      kind: o.kind ?? "family",
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}

export const tokenHash = () => createHash("sha256").update(randomBytes(32)).digest("hex");

export async function makeDevice(
  db: K,
  storeId: string,
  accountId: string,
  o: { role?: "family" | "cashier"; label?: string; revoked?: boolean } = {},
) {
  return db
    .insertInto("devices")
    .values({
      id: randomUUID(),
      store_id: storeId,
      account_id: accountId,
      role: o.role ?? "family",
      label: o.label ?? `手机_${randomBytes(3).toString("hex")}`,
      token_hash: tokenHash(),
      revoked_at: o.revoked ? new Date() : null,
      revoke_reason: o.revoked ? "kicked" : null,
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}

/** 一个店 + 账号 + 家用设备 */
export async function makeShop(db: K, o: { username?: string } = {}) {
  const store = await makeStore(db);
  const account = await makeAccount(db, store.id, { username: o.username });
  const device = await makeDevice(db, store.id, account.id);
  return { store, account, device };
}

export async function makeProduct(db: K, storeId: string, o: { rev?: string | number; price?: number } = {}) {
  return db
    .insertInto("products")
    .values({
      id: randomUUID(),
      store_id: storeId,
      name: "可乐",
      price_fen: o.price ?? 300,
      rev: o.rev ?? (await nextRev(db, storeId)),
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}

export async function makeBarcode(
  db: K,
  storeId: string,
  productId: string,
  o: { barcode?: string; packQty?: number; packPrice?: number | null; rev?: string | number } = {},
) {
  return db
    .insertInto("product_barcodes")
    .values({
      store_id: storeId,
      barcode: o.barcode ?? `69${Math.floor(Math.random() * 1e11)}`,
      product_id: productId,
      pack_qty: o.packQty ?? 1,
      unit_name: (o.packQty ?? 1) > 1 ? "箱" : "罐",
      pack_price_fen: o.packPrice ?? null,
      rev: o.rev ?? (await nextRev(db, storeId)),
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}

export async function makeOp(db: K, storeId: string, deviceId: string, o: { type?: "sale_batch" | "stock_in" } = {}) {
  return db
    .insertInto("ops")
    .values({
      id: randomUUID(),
      store_id: storeId,
      device_id: deviceId,
      type: o.type ?? "stock_in",
      payload: "{}",
      payload_hash: "h",
      occurred_at: new Date(),
      status: "applied",
      result: '{"status":"applied"}',
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}

export async function makeEntry(
  db: K,
  s: { storeId: string; deviceId: string; productId: string; opId: string },
  o: { seq?: number; rev?: string | number; type?: Database["entries"]["type"]; reverses?: string } = {},
) {
  return db
    .insertInto("entries")
    .values({
      id: randomUUID(),
      store_id: s.storeId,
      seq: o.seq ?? Number(await nextRev(db, s.storeId)),
      op_id: s.opId,
      type: o.type ?? "stock_in",
      reverses_entry_id: o.reverses ?? null,
      product_id: s.productId,
      name_snapshot: "可乐",
      qty_delta: 1,
      list_amount_fen: 200,
      amount_fen: 200,
      unit_cost_fen: 200,
      value_delta_fen: 200,
      device_id: s.deviceId,
      occurred_at: new Date(),
      rev: o.rev ?? (await nextRev(db, s.storeId)),
    })
    .returningAll()
    .executeTakeFirstOrThrow();
}
