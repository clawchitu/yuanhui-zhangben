// 验收：迁移在空库上跑通且可重复执行；§3 全部表、列齐全，与契约一致。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { listMigrations, migrate } from "../src/db.ts";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { CONTRACTS_DIR, loadOpenApi } from "./helpers/contract.ts";

// §3.1–§3.3 每张表的字段：直接从 docs/plan-v2.md 的表格里解析（不手抄，计划改了测试跟着变）
const PLAN = readFileSync(resolve(CONTRACTS_DIR, "../docs/plan-v2.md"), "utf8");
function specFromPlan(): Record<string, string[]> {
  const sec = PLAN.slice(PLAN.indexOf("### 3.1"), PLAN.indexOf("### 3.4"));
  const out: Record<string, string[]> = {};
  for (const m of sec.matchAll(/^\| `([a-z_]+)` \| `([^`]+)` \|/gm)) {
    out[m[1]] = m[2].split(",").map((f) => f.trim().split(/\s+/)[0]);
  }
  return out;
}
const SPEC = specFromPlan();
// S09 的三张运维表（演示店重置状态、注销导出任务、清除进度）：不是业务数据、不同步给手机，§3 的表格里没有，
// 字段以 migrations/0002_demo_and_deletion.sql 为准，在这里手抄一份做结构回归保护（多了、少了都会红）
const S09_TABLES: Record<string, string[]> = {
  demo_stores: ["store_id", "review_password_hash", "seeded_at", "next_reset_at"],
  export_jobs: ["store_id", "requested_at", "object_key", "done_at", "attempts", "next_try_at", "last_error", "cancelled_at"],
  store_purges: ["store_id", "purged_at", "objects_cleared_at", "attempts", "last_error"],
};

// 索引：名字 → 定义里必须出现的片段（结构回归保护，Codex 审核意见）
const INDEXES: Record<string, string> = {
  accounts_pkey: "(id)",
  accounts_store_id_id_key: "(store_id, id)",
  accounts_username_lower_key: "UNIQUE INDEX accounts_username_lower_key ON accounts USING btree (lower(username))",
  accounts_store_key: "UNIQUE INDEX accounts_store_key ON accounts USING btree (store_id)",
  stores_pkey: "(id)",
  devices_pkey: "(store_id, id)",
  devices_token_hash_key: "(token_hash)",
  devices_active_label_key: "(store_id, label) WHERE (revoked_at IS NULL)",
  devices_account_idx: "(store_id, account_id)",
  pairing_tokens_pkey: "(id)",
  pairing_tokens_token_hash_key: "(token_hash)",
  pairing_tokens_store_idx: "(store_id, expires_at)",
  products_pkey: "(store_id, id)",
  products_store_rev_key: "UNIQUE INDEX products_store_rev_key ON products USING btree (store_id, rev)",
  products_store_name_idx: "(store_id, name)",
  products_needs_review_idx: "(store_id) WHERE needs_review",
  product_barcodes_pkey: "(store_id, barcode)",
  product_barcodes_store_rev_key: "UNIQUE INDEX product_barcodes_store_rev_key ON product_barcodes USING btree (store_id, rev)",
  product_barcodes_product_idx: "(store_id, product_id)",
  product_barcodes_prefix_idx: "(store_id, barcode text_pattern_ops) WHERE (deleted_at IS NULL)",
  product_aliases_pkey: "(store_id, alias_id)",
  barcode_catalog_pkey: "(barcode)",
  ops_pkey: "(store_id, id)",
  ops_device_idx: "(store_id, device_id, received_at)",
  ops_held_idx: "(store_id, device_id) WHERE (status = 'held'::text)",
  sale_batches_pkey: "(store_id, id)",
  sale_batches_store_rev_key: "UNIQUE INDEX sale_batches_store_rev_key ON sale_batches USING btree (store_id, rev)",
  sale_batches_occurred_idx: "(store_id, occurred_at)",
  entries_pkey: "(store_id, id)",
  entries_store_id_id_type_key: "UNIQUE INDEX entries_store_id_id_type_key ON entries USING btree (store_id, id, type)",
  entries_store_seq_key: "UNIQUE INDEX entries_store_seq_key ON entries USING btree (store_id, seq)",
  entries_store_rev_key: "UNIQUE INDEX entries_store_rev_key ON entries USING btree (store_id, rev)",
  entries_reverses_key: "UNIQUE INDEX entries_reverses_key ON entries USING btree (store_id, reverses_entry_id) WHERE ((reverses_entry_id IS NOT NULL) AND (type <> 'cost_fix'::text))",
  entries_occurred_idx: "(store_id, occurred_at)",
  entries_product_idx: "(store_id, product_id, seq)",
  entries_batch_idx: "(store_id, batch_id) WHERE (batch_id IS NOT NULL)",
  entries_op_idx: "(store_id, op_id)",
  entries_device_idx: "(store_id, device_id, occurred_at)",
  stock_lots_pkey: "(store_id, id)",
  stock_lots_store_rev_key: "UNIQUE INDEX stock_lots_store_rev_key ON stock_lots USING btree (store_id, rev)",
  stock_lots_open_idx: "(store_id, product_id, expiry_date",
  stock_lots_source_idx: "(store_id, source_entry_id)",
  lot_moves_pkey: "(store_id, entry_id, lot_id)",
  lot_moves_lot_idx: "(store_id, lot_id)",
  image_jobs_pkey: "(store_id, product_id)",
  demo_stores_pkey: "(store_id)",
  export_jobs_pkey: "(store_id)",
  store_purges_pkey: "(store_id)",
  image_jobs_pending_idx: "(next_try_at) WHERE (done_at IS NULL)",
  removed_pkey: "(store_id, rev)",
  removed_row_idx: "(store_id, kind, row_id)",
  schema_migrations_pkey: "(name)",
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

  it("§3 的每张表、每个字段都在（从计划解析），没有多余的表和列", async () => {
    expect(Object.keys(SPEC).length).toBe(15);
    expect(SPEC.lot_moves).toEqual(["store_id", "entry_id", "lot_id", "qty"]);
    expect(SPEC.ops).toContain("resolved_by_device");
    const cols = await columns(t);
    expect(Object.keys(cols).sort()).toEqual([...Object.keys(SPEC), ...Object.keys(S09_TABLES), "schema_migrations"].sort());
    for (const [table, fields] of Object.entries({ ...SPEC, ...S09_TABLES })) {
      expect(Object.keys(cols[table]).sort(), table).toEqual([...fields].sort());
    }
  });

  it("索引齐全，定义与预期一致（手机生成 id 的表主键是 (store_id, id)）", async () => {
    const r = await t.pool.query<{ indexname: string; indexdef: string }>(
      "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1",
      [t.schema],
    );
    const got = Object.fromEntries(r.rows.map((x) => [x.indexname, x.indexdef.replaceAll(`${t.schema}.`, "")]));
    expect(Object.keys(got).sort()).toEqual(Object.keys(INDEXES).sort());
    for (const [name, frag] of Object.entries(INDEXES)) expect(got[name], name).toContain(frag);
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

  it("每张业务表都有 store_id（stores 本身、barcode_catalog 全局缓存除外）", async () => {
    const cols = await columns(t);
    for (const table of Object.keys(SPEC)) {
      if (["stores", "barcode_catalog"].includes(table)) continue;
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
