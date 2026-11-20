// 验收：迁移在空库上跑通且可重复执行；§3 全部表、列齐全，与契约一致。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { listMigrations, migrate } from "../src/db.ts";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { CONTRACTS_DIR, loadOpenApi } from "./helpers/contract.ts";

// §3.1–§3.3 每张表的字段（照抄计划）；products 另加契约要的 image_ver（见 PR 疑问）
const SPEC: Record<string, string[]> = {
  stores: ["id", "name", "is_demo", "low_stock_default", "rev", "epoch", "created_at"],
  accounts: ["id", "store_id", "username", "password_hash", "kind", "failed_logins", "locked_until", "delete_requested_at", "created_at"],
  devices: ["id", "account_id", "store_id", "role", "label", "token_hash", "app_build", "created_at", "last_seen_at", "revoked_at", "revoke_reason"],
  pairing_tokens: ["id", "token_hash", "account_id", "store_id", "role", "label", "created_by_device", "expires_at", "used_at", "used_by_device", "created_at"],
  products: [
    "id", "store_id", "name", "base_unit", "price_fen", "stock_qty", "stock_value_fen", "last_cost_fen", "cost_known", "stock_ver",
    "last_count_at", "low_at", "stock_known", "track_expiry", "expiry_warn_days", "shelf_life_months", "needs_review", "image_key",
    "image_source", "archived_at", "created_by_device", "rev", "updated_at", "image_ver",
  ],
  product_barcodes: ["store_id", "barcode", "product_id", "pack_qty", "unit_name", "pack_price_fen", "rev", "deleted_at"],
  product_aliases: ["store_id", "alias_id", "product_id"],
  barcode_catalog: ["barcode", "found", "name", "spec", "brand", "image_url", "source", "raw", "fetched_at"],
  ops: ["id", "store_id", "device_id", "type", "payload", "payload_hash", "occurred_at", "received_at", "status", "reject_code", "result", "flags"],
  sale_batches: ["id", "store_id", "device_id", "list_total_fen", "paid_total_fen", "occurred_at", "received_at", "rev"],
  entries: [
    "id", "store_id", "seq", "op_id", "batch_id", "type", "reverses_entry_id", "product_id", "barcode", "name_snapshot", "unit_name",
    "pack_qty", "pack_count", "qty_delta", "list_amount_fen", "amount_fen", "unit_cost_fen", "cogs_fen", "value_delta_fen",
    "cost_missing", "expiry_date", "device_id", "occurred_at", "received_at", "voided_at", "voided_by_device", "cost_fix_entry_id",
    "flags", "rev",
  ],
  stock_lots: ["id", "store_id", "product_id", "source_entry_id", "expiry_date", "qty_in", "qty_left", "snoozed_until", "closed_at", "closed_reason", "handle_ver", "rev"],
  lot_moves: ["entry_id", "lot_id", "qty"],
  image_jobs: ["product_id", "store_id", "source_url", "attempts", "next_try_at", "done_at", "last_error"],
  removed: ["store_id", "rev", "kind", "row_id"],
};

async function columns(t: TestDb): Promise<Record<string, Record<string, string>>> {
  const r = await t.pool.query<{ table_name: string; column_name: string; data_type: string }>(
    "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = $1",
    [t.schema],
  );
  const out: Record<string, Record<string, string>> = {};
  for (const row of r.rows) (out[row.table_name] ??= {})[row.column_name] = row.data_type;
  return out;
}

async function checkValues(t: TestDb, table: string, column: string): Promise<string[]> {
  const r = await t.pool.query<{ def: string }>(
    `SELECT pg_get_constraintdef(c.oid) AS def FROM pg_constraint c
       JOIN pg_class k ON k.oid = c.conrelid JOIN pg_namespace n ON n.oid = k.relnamespace
      WHERE n.nspname = $1 AND k.relname = $2 AND c.contype = 'c'`,
    [t.schema, table],
  );
  const def = r.rows.map((x) => x.def).find((d) => d.includes(`(${column} = ANY`) || d.includes(`((${column} = ANY`));
  if (!def) throw new Error(`${table}.${column} 没有枚举 CHECK`);
  return [...def.matchAll(/'([^']+)'::text/g)].map((m) => m[1]).sort();
}

describe("迁移", () => {
  let t: TestDb;
  beforeAll(async () => {
    t = await createTestDb({ migrate: false });
  });
  afterAll(() => t.drop());

  it("空库上跑通：执行全部迁移文件", async () => {
    const files = listMigrations().map((f) => f.name);
    expect(files[0]).toBe("0001_init.sql");
    expect(await migrate(t.pool)).toEqual(files);
  });

  it("可重复执行：第二、三次什么都不做，表结构不变", async () => {
    const before = await columns(t);
    expect(await migrate(t.pool)).toEqual([]);
    expect(await migrate(t.pool)).toEqual([]);
    expect(await columns(t)).toEqual(before);
    const r = await t.pool.query("SELECT count(*)::int AS n FROM schema_migrations");
    expect(r.rows[0].n).toBe(listMigrations().length);
  });

  it("两个进程同时迁移：咨询锁串行化，只执行一次", async () => {
    const t2 = await createTestDb({ migrate: false });
    try {
      const [a, b] = await Promise.all([migrate(t2.pool), migrate(t2.pool)]);
      expect([...a, ...b].sort()).toEqual(listMigrations().map((f) => f.name));
    } finally {
      await t2.drop();
    }
  });

  it("已执行的迁移文件被改过 → 拒绝执行", async () => {
    await t.pool.query("UPDATE schema_migrations SET checksum = 'tampered' WHERE name = '0001_init.sql'");
    await expect(migrate(t.pool)).rejects.toThrow(/内容被改了/);
    await t.pool.query("UPDATE schema_migrations SET checksum = $1 WHERE name = '0001_init.sql'", [listMigrations()[0].checksum]);
  });

  it("§3 的每张表、每个字段都在，没有多余的表", async () => {
    const cols = await columns(t);
    expect(Object.keys(cols).sort()).toEqual([...Object.keys(SPEC), "schema_migrations"].sort());
    for (const [table, fields] of Object.entries(SPEC)) {
      expect(Object.keys(cols[table]).sort(), table).toEqual([...fields].sort());
    }
  });

  it("金额列一律 bigint（整数分），数量列 integer，时间列 timestamptz", async () => {
    const cols = await columns(t);
    for (const [table, c] of Object.entries(cols)) {
      for (const [name, type] of Object.entries(c)) {
        if (name.endsWith("_fen")) expect(type, `${table}.${name}`).toBe("bigint");
        if (name === "rev" || name === "seq" || name === "stock_ver") expect(type, `${table}.${name}`).toBe("bigint");
        if (name.endsWith("_at") && name !== "low_at") expect(type, `${table}.${name}`).toBe("timestamp with time zone");
        if (["qty_delta", "stock_qty", "qty_in", "qty_left", "qty", "pack_qty", "pack_count"].includes(name))
          expect(type, `${table}.${name}`).toBe("integer");
      }
    }
  });

  it("每张业务表都有 store_id（barcode_catalog 全局缓存、lot_moves 挂在流水下除外）", async () => {
    const cols = await columns(t);
    for (const table of Object.keys(SPEC)) {
      if (["stores", "barcode_catalog", "lot_moves"].includes(table)) continue;
      expect(cols[table], table).toHaveProperty("store_id");
    }
  });

  it("枚举 CHECK 与契约一致", async () => {
    const api = await loadOpenApi();
    const s = api.components.schemas;
    const opsSchema = JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "ops.schema.json"), "utf8"));
    expect(await checkValues(t, "entries", "type")).toEqual([...s.EntryType.enum].sort());
    expect(await checkValues(t, "ops", "type")).toEqual([...opsSchema.$defs.op_type.enum].sort());
    expect(await checkValues(t, "removed", "kind")).toEqual([...s.Removed.properties.kind.enum].sort());
    expect(await checkValues(t, "devices", "role")).toEqual([...s.Role.enum].sort());
    expect(await checkValues(t, "pairing_tokens", "role")).toEqual([...s.Role.enum].sort());
    const reasons = s.StockLot.properties.closed_reason.oneOf.find((x: { enum?: string[] }) => x.enum).enum;
    expect(await checkValues(t, "stock_lots", "closed_reason")).toEqual([...reasons].sort());
    const statuses = api.components.schemas.OpResult.properties.status.enum;
    expect(await checkValues(t, "ops", "status")).toEqual([...statuses].sort());
    expect(await checkValues(t, "accounts", "kind")).toEqual(["family", "review"]);
  });

  it("契约里同步下发的字段都有对应的列（Product.private、ProductBarcode、Entry、SaleBatch、StockLot、Removed）", async () => {
    const cols = await columns(t);
    const s = (await loadOpenApi()).components.schemas;
    // 由列推导、不单独存的字段
    const derived: Record<string, string[]> = {
      Product: ["archived", "private"],
      Entry: ["device_label"],
    };
    const check = (schemaName: string, props: object, table: string) => {
      for (const k of Object.keys(props)) {
        if (derived[schemaName]?.includes(k)) continue;
        expect(cols[table], `${schemaName}.${k} → ${table}`).toHaveProperty(k);
      }
    };
    check("Product", s.Product.properties, "products");
    check("Product.private", s.Product.properties.private.properties, "products");
    check("ProductBarcode", s.ProductBarcode.properties, "product_barcodes");
    check("Entry", s.Entry.properties, "entries");
    check("SaleBatch", s.SaleBatch.properties, "sale_batches");
    check("StockLot", s.StockLot.properties, "stock_lots");
    check("Removed", s.Removed.properties, "removed");
  });
});
