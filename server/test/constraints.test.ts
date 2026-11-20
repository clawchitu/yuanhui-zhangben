// 验收：约束测试。每条断言具体的 Postgres 错误码和违反的约束名，不只是「报错了」。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, expectPgError, nextRev, withRollback, type TestDb } from "./helpers/db.ts";
import {
  makeAccount, makeBarcode, makeDevice, makeEntry, makeOp, makeProduct, makeShop, makeStore, tokenHash,
} from "./helpers/fixtures.ts";

const UNIQUE = "23505";
const CHECK = "23514";
const FK = "23503";

let t: TestDb;
beforeAll(async () => {
  t = await createTestDb();
});
afterAll(() => t.drop());

describe("验收：S02 约束", () => {
  it("重复 (store_id, barcode) 失败；同一条码在别的店可以", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    await makeBarcode(t.kysely, a.store.id, p.id, { barcode: "6901234567890" });
    const p2 = await makeProduct(t.kysely, a.store.id);
    await expectPgError(makeBarcode(t.kysely, a.store.id, p2.id, { barcode: "6901234567890" }), UNIQUE, "product_barcodes_pkey");
    const b = await makeShop(t.kysely);
    const pb = await makeProduct(t.kysely, b.store.id);
    await expect(makeBarcode(t.kysely, b.store.id, pb.id, { barcode: "6901234567890" })).resolves.toBeTruthy();
  });

  it("pack_qty=0 失败（负数、超过 9,999 也失败）", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { packQty: 0 }), CHECK, "product_barcodes_pack_qty_check");
    await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { packQty: -1 }), CHECK, "product_barcodes_pack_qty_check");
    await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { packQty: 10000 }), CHECK, "product_barcodes_pack_qty_check");
    await expect(makeBarcode(t.kysely, a.store.id, p.id, { packQty: 9999, packPrice: 100 })).resolves.toBeTruthy();
  });

  it("单件码（pack_qty=1）带 pack_price_fen 失败；不带价可以；整件码带价可以", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { packQty: 1, packPrice: 300 }), CHECK, "product_barcodes_single_no_price");
    // 价为 0 也不行：单件码根本不许有价
    await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { packQty: 1, packPrice: 0 }), CHECK, "product_barcodes_single_no_price");
    const single = await makeBarcode(t.kysely, a.store.id, p.id, { packQty: 1 });
    expect(single.pack_price_fen).toBeNull();
    const pack = await makeBarcode(t.kysely, a.store.id, p.id, { packQty: 24, packPrice: 6000 });
    expect(pack.pack_price_fen).toBe("6000");
    // 已有的单件码事后补价同样被拒
    await expectPgError(
      t.kysely
        .updateTable("product_barcodes")
        .set({ pack_price_fen: 300 })
        .where("store_id", "=", a.store.id)
        .where("barcode", "=", single.barcode)
        .execute(),
      CHECK,
      "product_barcodes_single_no_price",
    );
  });

  it("重复用户名（大小写不同）失败，跨店也不行", async () => {
    const s1 = await makeStore(t.kysely);
    const s2 = await makeStore(t.kysely);
    await makeAccount(t.kysely, s1.id, { username: "YuanHui" });
    await expectPgError(makeAccount(t.kysely, s2.id, { username: "yuanhui" }), UNIQUE, "accounts_username_lower_key");
    await expectPgError(makeAccount(t.kysely, s2.id, { username: "YUANHUI" }), UNIQUE, "accounts_username_lower_key");
    await expect(makeAccount(t.kysely, s2.id, { username: "yuanhui2" })).resolves.toBeTruthy();
  });

  it("一个店只有一个账号", async () => {
    const s = await makeStore(t.kysely);
    await makeAccount(t.kysely, s.id);
    await expectPgError(makeAccount(t.kysely, s.id), UNIQUE, "accounts_store_key");
  });

  describe("同店重复 rev 失败（每张带 rev 的表），别的店同一个 rev 可以", () => {
    it("products（插入和更新都拦）", async () => {
      const a = await makeShop(t.kysely);
      const b = await makeShop(t.kysely);
      await makeProduct(t.kysely, a.store.id, { rev: 5 });
      await expectPgError(makeProduct(t.kysely, a.store.id, { rev: 5 }), UNIQUE, "products_store_rev_key");
      await expect(makeProduct(t.kysely, b.store.id, { rev: 5 })).resolves.toBeTruthy();
      const p = await makeProduct(t.kysely, a.store.id, { rev: 6 });
      await expectPgError(
        t.kysely.updateTable("products").set({ rev: 5 }).where("id", "=", p.id).execute(),
        UNIQUE,
        "products_store_rev_key",
      );
    });

    it("product_barcodes", async () => {
      const a = await makeShop(t.kysely);
      const p = await makeProduct(t.kysely, a.store.id);
      await makeBarcode(t.kysely, a.store.id, p.id, { rev: 100 });
      await expectPgError(makeBarcode(t.kysely, a.store.id, p.id, { rev: 100 }), UNIQUE, "product_barcodes_store_rev_key");
    });

    it("entries（seq 也不许重复）", async () => {
      const a = await makeShop(t.kysely);
      const p = await makeProduct(t.kysely, a.store.id);
      const op = await makeOp(t.kysely, a.store.id, a.device.id);
      const s = { storeId: a.store.id, deviceId: a.device.id, productId: p.id, opId: op.id };
      await makeEntry(t.kysely, s, { seq: 1, rev: 200 });
      await expectPgError(makeEntry(t.kysely, s, { seq: 2, rev: 200 }), UNIQUE, "entries_store_rev_key");
      await expectPgError(makeEntry(t.kysely, s, { seq: 1, rev: 201 }), UNIQUE, "entries_store_seq_key");
    });

    it("sale_batches、stock_lots、removed", async () => {
      const a = await makeShop(t.kysely);
      const batch = (rev: number) =>
        t.kysely
          .insertInto("sale_batches")
          .values({ id: randomUUID(), store_id: a.store.id, device_id: a.device.id, list_total_fen: 0, paid_total_fen: 0, occurred_at: new Date(), rev })
          .execute();
      await batch(300);
      await expectPgError(batch(300), UNIQUE, "sale_batches_store_rev_key");

      const p = await makeProduct(t.kysely, a.store.id);
      const op = await makeOp(t.kysely, a.store.id, a.device.id);
      const e = await makeEntry(t.kysely, { storeId: a.store.id, deviceId: a.device.id, productId: p.id, opId: op.id });
      const lot = (rev: number) =>
        t.kysely
          .insertInto("stock_lots")
          .values({ id: randomUUID(), store_id: a.store.id, product_id: p.id, source_entry_id: e.id, qty_in: 1, qty_left: 1, rev })
          .execute();
      await lot(400);
      await expectPgError(lot(400), UNIQUE, "stock_lots_store_rev_key");

      const tomb = (rev: number) =>
        t.kysely.insertInto("removed").values({ store_id: a.store.id, rev, kind: "barcode", row_id: "690" }).execute();
      await tomb(500);
      await expectPgError(tomb(500), UNIQUE, "removed_pkey");
    });
  });
});

describe("其他约束", () => {
  it("令牌哈希唯一，且只能是 sha256 十六进制（不能存令牌原文）", async () => {
    const a = await makeShop(t.kysely);
    const dev = (hash: string, label: string) =>
      t.kysely
        .insertInto("devices")
        .values({ id: randomUUID(), store_id: a.store.id, account_id: a.account.id, role: "family", label, token_hash: hash })
        .execute();
    const h = tokenHash();
    await dev(h, "甲");
    await expectPgError(dev(h, "乙"), UNIQUE, "devices_token_hash_key");
    await expectPgError(dev("plain-token", "丙"), CHECK, "devices_token_hash_check");
  });

  it("同店未撤销设备称呼不重名；被撤销的不算；别的店可以同名", async () => {
    const a = await makeShop(t.kysely);
    await makeDevice(t.kysely, a.store.id, a.account.id, { label: "收银台", role: "cashier" });
    await expectPgError(makeDevice(t.kysely, a.store.id, a.account.id, { label: "收银台" }), UNIQUE, "devices_active_label_key");
    const a2 = await makeShop(t.kysely);
    await makeDevice(t.kysely, a2.store.id, a2.account.id, { label: "老手机", revoked: true });
    await expect(makeDevice(t.kysely, a2.store.id, a2.account.id, { label: "老手机" })).resolves.toBeTruthy();
    await expect(makeDevice(t.kysely, a2.store.id, a2.account.id, { label: "收银台" })).resolves.toBeTruthy();
  });

  it("设备角色只能 family / cashier；账号类型只能 family / review", async () => {
    const a = await makeShop(t.kysely);
    await expectPgError(
      t.kysely
        .insertInto("devices")
        .values({ id: randomUUID(), store_id: a.store.id, account_id: a.account.id, role: "review" as "family", label: "x", token_hash: tokenHash() })
        .execute(),
      CHECK,
      "devices_role_check",
    );
    const s = await makeStore(t.kysely);
    await expectPgError(makeAccount(t.kysely, s.id, { kind: "admin" as "family" }), CHECK, "accounts_kind_check");
  });

  it("店铺隔离：B 店的条码、流水、设备、op 不能挂到 A 店的商品 / 账号 / 设备上（复合外键）", async () => {
    const a = await makeShop(t.kysely);
    const b = await makeShop(t.kysely);
    const pa = await makeProduct(t.kysely, a.store.id);
    await expectPgError(makeBarcode(t.kysely, b.store.id, pa.id), FK, "product_barcodes_store_id_product_id_fkey");
    await expectPgError(makeDevice(t.kysely, b.store.id, a.account.id), FK, "devices_store_id_account_id_fkey");
    const opB = await makeOp(t.kysely, b.store.id, b.device.id);
    await expectPgError(
      makeEntry(t.kysely, { storeId: b.store.id, deviceId: b.device.id, productId: pa.id, opId: opB.id }),
      FK,
      "entries_store_id_product_id_fkey",
    );
    await expectPgError(makeOp(t.kysely, b.store.id, a.device.id), FK, "ops_store_id_device_id_fkey");
  });

  it("单件卖价 price_fen 在 0–99,999,999 分", async () => {
    const a = await makeShop(t.kysely);
    await expectPgError(makeProduct(t.kysely, a.store.id, { price: -1 }), CHECK, "products_price_fen_check");
    await expectPgError(makeProduct(t.kysely, a.store.id, { price: 100_000_000 }), CHECK, "products_price_fen_check");
    await expect(makeProduct(t.kysely, a.store.id, { price: 0 })).resolves.toBeTruthy();
    await expect(makeProduct(t.kysely, a.store.id, { price: 99_999_999 })).resolves.toBeTruthy();
  });

  it("金额列存得下 2^63−1 分，读出是字符串、不丢精度", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    const big = "9223372036854775807";
    const r = await t.kysely
      .updateTable("products")
      .set({ stock_value_fen: big })
      .where("id", "=", p.id)
      .returning("stock_value_fen")
      .executeTakeFirstOrThrow();
    expect(r.stock_value_fen).toBe(big);
  });

  it("实收上限 19,999,999,800 分（Q1），不为负", async () => {
    const a = await makeShop(t.kysely);
    const batch = async (paid: number) =>
      t.kysely
        .insertInto("sale_batches")
        .values({
          id: randomUUID(), store_id: a.store.id, device_id: a.device.id, list_total_fen: 0, paid_total_fen: paid,
          occurred_at: new Date(), rev: await nextRev(t.kysely, a.store.id),
        })
        .execute();
    await expect(batch(19_999_999_800)).resolves.toBeTruthy();
    await expectPgError(batch(19_999_999_801), CHECK, "sale_batches_paid_total_fen_check");
    await expectPgError(batch(-1), CHECK, "sale_batches_paid_total_fen_check");
  });

  it("流水类型、op 类型、op 状态只能取契约里的值；被拒的 op 必须带原因", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    const op = await makeOp(t.kysely, a.store.id, a.device.id);
    await expectPgError(
      makeEntry(t.kysely, { storeId: a.store.id, deviceId: a.device.id, productId: p.id, opId: op.id }, { type: "refund" as "sale" }),
      CHECK,
      "entries_type_check",
    );
    const insertOp = (o: { type?: string; status?: string; reject_code?: string | null }) =>
      t.kysely
        .insertInto("ops")
        .values({
          id: randomUUID(), store_id: a.store.id, device_id: a.device.id, type: (o.type ?? "void") as "void",
          payload: "{}", payload_hash: "h", occurred_at: new Date(), status: (o.status ?? "applied") as "applied",
          reject_code: o.reject_code ?? null, result: "{}",
        })
        .execute();
    await expectPgError(insertOp({ type: "refund" }), CHECK, "ops_type_check");
    await expectPgError(insertOp({ status: "pending" }), CHECK, "ops_status_check");
    await expectPgError(insertOp({ status: "rejected" }), CHECK, "ops_check");
    await expect(insertOp({ status: "rejected", reject_code: "forbidden" })).resolves.toBeTruthy();
    await expect(insertOp({ status: "held" })).resolves.toBeTruthy();
  });

  it("op id 全局唯一（幂等键）", async () => {
    const a = await makeShop(t.kysely);
    const op = await makeOp(t.kysely, a.store.id, a.device.id);
    await expectPgError(
      t.kysely
        .insertInto("ops")
        .values({
          id: op.id, store_id: a.store.id, device_id: a.device.id, type: "void", payload: "{}", payload_hash: "h2",
          occurred_at: new Date(), status: "applied", result: "{}",
        })
        .execute(),
      UNIQUE,
      "ops_pkey",
    );
  });

  it("一行流水最多被冲销一次", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    const op = await makeOp(t.kysely, a.store.id, a.device.id);
    const s = { storeId: a.store.id, deviceId: a.device.id, productId: p.id, opId: op.id };
    const orig = await makeEntry(t.kysely, s);
    await makeEntry(t.kysely, s, { reverses: orig.id });
    await expectPgError(makeEntry(t.kysely, s, { reverses: orig.id }), UNIQUE, "entries_reverses_key");
  });

  it("批次：closed_at 与 closed_reason 同有同无；closed_reason 只能 disposed / voided；qty_left 不为负", async () => {
    const a = await makeShop(t.kysely);
    const p = await makeProduct(t.kysely, a.store.id);
    const op = await makeOp(t.kysely, a.store.id, a.device.id);
    const e = await makeEntry(t.kysely, { storeId: a.store.id, deviceId: a.device.id, productId: p.id, opId: op.id });
    const lot = async (o: { closed_at?: Date | null; closed_reason?: string | null; qty_left?: number }) =>
      t.kysely
        .insertInto("stock_lots")
        .values({
          id: randomUUID(), store_id: a.store.id, product_id: p.id, source_entry_id: e.id, qty_in: 1,
          qty_left: o.qty_left ?? 1, closed_at: o.closed_at ?? null,
          closed_reason: (o.closed_reason ?? null) as "disposed" | null, rev: await nextRev(t.kysely, a.store.id),
        })
        .execute();
    await expectPgError(lot({ closed_at: new Date() }), CHECK, "stock_lots_check");
    await expectPgError(lot({ closed_reason: "disposed" }), CHECK, "stock_lots_check");
    await expectPgError(lot({ closed_at: new Date(), closed_reason: "sold" }), CHECK, "stock_lots_closed_reason_check");
    await expectPgError(lot({ qty_left: -1 }), CHECK, "stock_lots_qty_left_check");
    await expect(lot({ closed_at: new Date(), closed_reason: "voided" })).resolves.toBeTruthy();
  });

  it("开通码：收银员码必须带称呼；令牌哈希唯一；只能挂本店设备", async () => {
    const a = await makeShop(t.kysely);
    const b = await makeShop(t.kysely);
    const pt = (o: { role?: "family" | "cashier"; label?: string | null; hash?: string; by?: string }) =>
      t.kysely
        .insertInto("pairing_tokens")
        .values({
          token_hash: o.hash ?? tokenHash(), account_id: a.account.id, store_id: a.store.id, role: o.role ?? "family",
          label: o.label ?? null, created_by_device: o.by ?? a.device.id, expires_at: new Date(Date.now() + 120_000),
        })
        .execute();
    await expectPgError(pt({ role: "cashier" }), CHECK);
    await expect(pt({ role: "cashier", label: "小王" })).resolves.toBeTruthy();
    const h = tokenHash();
    await pt({ hash: h });
    await expectPgError(pt({ hash: h }), UNIQUE, "pairing_tokens_token_hash_key");
    await expectPgError(pt({ by: b.device.id }), FK, "pairing_tokens_store_id_created_by_device_fkey");
  });

  it("测试辅助 withRollback：事务里写的数据之后看不到", async () => {
    const id = await withRollback(t.kysely, async (trx) => (await makeStore(trx, { name: "回滚店" })).id);
    const r = await t.kysely.selectFrom("stores").select("id").where("id", "=", id).execute();
    expect(r).toEqual([]);
  });
});
