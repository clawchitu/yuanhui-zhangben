// Kysely 的表类型，和 migrations/*.sql 一一对应（test/schema.test.ts 会核对列名）。
// bigint 列由 pg 以字符串读出（避免丢精度），写入时可传 number / bigint / string。
import type { ColumnType, Generated } from "kysely";

type Int8 = ColumnType<string, number | bigint | string, number | bigint | string>;
type Int8Default = ColumnType<string, number | bigint | string | undefined, number | bigint | string>;
type Ts = ColumnType<Date, Date | string, Date | string>;
type TsDefault = ColumnType<Date, Date | string | undefined, Date | string>;
type Json = ColumnType<unknown, string, string>;
type JsonDefault = ColumnType<unknown, string | undefined, string>;
type DateCol = ColumnType<string, string, string>;

export interface StoresTable {
  id: Generated<string>;
  name: string;
  is_demo: Generated<boolean>;
  low_stock_default: Generated<number>;
  rev: Int8Default;
  epoch: Generated<string>;
  created_at: TsDefault;
}

export interface AccountsTable {
  id: Generated<string>;
  store_id: string;
  username: string;
  password_hash: string;
  kind: "family" | "review";
  failed_logins: Generated<number>;
  locked_until: Ts | null;
  delete_requested_at: Ts | null;
  created_at: TsDefault;
}

/** demo_reset 就是同步响应里的 discard_outbox（§4.5） */
export type RevokeReason = "kicked" | "revoke_others" | "logout" | "account_delete" | "demo_reset";

export interface DevicesTable {
  id: string;
  account_id: string;
  store_id: string;
  role: "family" | "cashier";
  label: string;
  token_hash: string;
  app_build: number | null;
  created_at: TsDefault;
  last_seen_at: Ts | null;
  revoked_at: Ts | null;
  revoke_reason: RevokeReason | null;
}

export interface PairingTokensTable {
  id: Generated<string>;
  token_hash: string;
  account_id: string;
  store_id: string;
  role: "family" | "cashier";
  label: string | null;
  created_by_device: string;
  expires_at: Ts;
  used_at: Ts | null;
  used_by_device: string | null;
}

export interface ProductsTable {
  id: string;
  store_id: string;
  name: string;
  base_unit: Generated<string>;
  price_fen: Int8;
  stock_qty: Generated<number>;
  stock_value_fen: Int8Default;
  last_cost_fen: Int8 | null;
  cost_known: Generated<boolean>;
  stock_ver: Int8Default;
  last_count_at: Ts | null;
  low_at: number | null;
  stock_known: Generated<boolean>;
  track_expiry: Generated<boolean>;
  expiry_warn_days: Generated<number>;
  shelf_life_months: number | null;
  needs_review: Generated<boolean>;
  image_key: string | null;
  /** 0006：当前商品图内容的 sha256（选图 / 上传的幂等判断用）；旧行为空 */
  image_sha256: string | null;
  image_source: string | null;
  image_ver: Generated<number>;
  archived_at: Ts | null;
  created_by_device: string | null;
  rev: Int8;
  updated_at: TsDefault;
}

export interface ProductBarcodesTable {
  store_id: string;
  barcode: string;
  product_id: string;
  pack_qty: number;
  unit_name: string;
  pack_price_fen: Int8 | null;
  rev: Int8;
  deleted_at: Ts | null;
}

export interface ProductAliasesTable {
  store_id: string;
  alias_id: string;
  product_id: string;
}

export interface BarcodeCatalogTable {
  barcode: string;
  found: boolean;
  name: string | null;
  spec: string | null;
  brand: string | null;
  image_url: string | null;
  /** 0004：完整图片地址列表（第一张 = image_url）；旧行是空数组 */
  image_urls: ColumnType<string[], string[] | undefined, string[]>;
  source: string;
  raw: Json | null;
  fetched_at: TsDefault;
  /** 0007：上一次为了候选图重新问外部的时间（每个条码一天最多一次） */
  images_refreshed_at: ColumnType<Date | null, Date | string | null | undefined, Date | string | null>;
}

/** 0005（S22d）：商品图候选，全局、不分店 */
export interface CatalogImageCandidatesTable {
  barcode: string;
  idx: number;
  source_url: string;
  state: ColumnType<"pending" | "ready" | "failed", "pending" | "ready" | "failed" | undefined, "pending" | "ready" | "failed">;
  cid: string | null;
  object_key: string | null;
  attempts: Generated<number>;
  next_try_at: TsDefault;
  last_error: string | null;
  fetched_at: Ts | null;
}

export type OpType =
  | "sale_batch"
  | "void"
  | "product_upsert"
  | "product_edit"
  | "barcode_link"
  | "barcode_unlink"
  | "stock_in"
  | "opening"
  | "product_review_complete"
  | "count"
  | "expiry_dispose"
  | "lot_snooze";

export interface OpsTable {
  id: string;
  store_id: string;
  device_id: string;
  type: OpType;
  payload: Json;
  payload_hash: string;
  occurred_at: Ts;
  received_at: TsDefault;
  status: "applied" | "rejected" | "held";
  reject_code: string | null;
  result: Json;
  resolved_at: Ts | null;
  resolved_by_device: string | null;
  flags: JsonDefault;
}

export interface SaleBatchesTable {
  id: string;
  store_id: string;
  device_id: string;
  list_total_fen: Int8;
  paid_total_fen: Int8;
  occurred_at: Ts;
  received_at: TsDefault;
  rev: Int8;
}

export type EntryType =
  | "sale"
  | "stock_in"
  | "opening"
  | "count"
  | "cost_adjust"
  | "cost_fix"
  | "expire_loss"
  | "supplier_return";

export interface EntriesTable {
  id: string;
  store_id: string;
  seq: Int8;
  op_id: string;
  batch_id: string | null;
  type: EntryType;
  reverses_entry_id: string | null;
  product_id: string;
  barcode: string | null;
  name_snapshot: string;
  unit_name: string | null;
  pack_qty: number | null;
  pack_count: number | null;
  qty_delta: number;
  list_amount_fen: Int8;
  amount_fen: Int8;
  unit_cost_fen: Int8 | null;
  cogs_fen: Int8Default;
  value_delta_fen: Int8Default;
  cost_missing: Generated<boolean>;
  expiry_date: DateCol | null;
  device_id: string;
  occurred_at: Ts;
  received_at: TsDefault;
  voided_at: Ts | null;
  voided_by_device: string | null;
  cost_fix_entry_id: string | null;
  flags: JsonDefault;
  rev: Int8;
}

export interface StockLotsTable {
  id: string;
  store_id: string;
  product_id: string;
  source_entry_id: string;
  expiry_date: DateCol | null;
  qty_in: number;
  qty_left: number;
  snoozed_until: DateCol | null;
  closed_at: Ts | null;
  closed_reason: "disposed" | "voided" | null;
  handle_ver: Generated<number>;
  rev: Int8;
}

export interface LotMovesTable {
  store_id: string;
  entry_id: string;
  lot_id: string;
  qty: number;
}

export interface ImageJobsTable {
  product_id: string;
  store_id: string;
  source_url: string;
  attempts: Generated<number>;
  next_try_at: TsDefault;
  done_at: Ts | null;
  last_error: string | null;
}

export interface RemovedTable {
  store_id: string;
  rev: Int8;
  kind: "barcode" | "product_alias" | "entry" | "batch" | "lot";
  row_id: string;
}

export interface DemoStoresTable {
  store_id: string;
  review_password_hash: string;
  seeded_at: Ts;
  next_reset_at: Ts;
}

export interface ExportJobsTable {
  store_id: string;
  requested_at: Ts;
  object_key: string | null;
  done_at: Ts | null;
  attempts: Generated<number>;
  next_try_at: Ts;
  last_error: string | null;
  cancelled_at: Ts | null;
  stale_cleared_at: Ts | null;
}

export interface StorePurgesTable {
  store_id: string;
  purged_at: Ts;
  swept_at: Ts | null;
  objects_cleared_at: Ts | null;
  attempts: Generated<number>;
  last_error: string | null;
  /** 失败退避：这个时间之前不重试；空 = 随时可试（0003） */
  next_try_at: Ts | null;
}

export interface ObjectDiscardsTable {
  object_key: string;
  upload_id: Generated<string>;
  store_id: string;
  created_at: Ts;
  attempts: Generated<number>;
  next_try_at: Ts;
  last_error: string | null;
}

export interface SchemaMigrationsTable {
  name: string;
  checksum: string;
  applied_at: TsDefault;
}

export interface Database {
  stores: StoresTable;
  accounts: AccountsTable;
  devices: DevicesTable;
  pairing_tokens: PairingTokensTable;
  products: ProductsTable;
  product_barcodes: ProductBarcodesTable;
  product_aliases: ProductAliasesTable;
  barcode_catalog: BarcodeCatalogTable;
  catalog_image_candidates: CatalogImageCandidatesTable;
  ops: OpsTable;
  sale_batches: SaleBatchesTable;
  entries: EntriesTable;
  stock_lots: StockLotsTable;
  lot_moves: LotMovesTable;
  image_jobs: ImageJobsTable;
  removed: RemovedTable;
  demo_stores: DemoStoresTable;
  export_jobs: ExportJobsTable;
  store_purges: StorePurgesTable;
  object_discards: ObjectDiscardsTable;
  schema_migrations: SchemaMigrationsTable;
}
