-- 0001_init：§3 全部表、约束、索引（docs/plan-v2.md §3，契约 contracts/openapi.yaml）。
-- 金额一律整数分 bigint；数量整数基本单位；时间 timestamptz；业务日按 Asia/Shanghai（由应用计算，库里存 timestamptz）。
-- 不写 schema 名：迁移跑在连接的 search_path 上（测试里每个文件一个独立 schema）。
-- 跨表引用一律带 store_id 的复合外键，库层面就不可能把 A 店的行挂到 B 店的商品、设备上。
-- id 由手机生成的六张表（devices、products、ops、sale_batches、entries、stock_lots）主键是 (store_id, id)，
-- 不做全库唯一：一家店里出现的 id 不挡另一家店（§3 通用约定、§14 S02-8）。

-- ───────────────────────── 3.1 账号与设备 ─────────────────────────

CREATE TABLE stores (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  is_demo           boolean NOT NULL DEFAULT false,
  low_stock_default integer NOT NULL DEFAULT 3 CHECK (low_stock_default >= 0),
  -- 本店变更序号计数器：店铺锁内每改一行取一个新号（§4.2）
  rev               bigint NOT NULL DEFAULT 0 CHECK (rev >= 0),
  -- 从备份恢复后换新（§4.6）；演示店每日重置不换（§4.5）
  epoch             uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id            uuid NOT NULL REFERENCES stores (id),
  username            text NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
  password_hash       text NOT NULL,
  kind                text NOT NULL CHECK (kind IN ('family', 'review')),
  failed_logins       integer NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
  locked_until        timestamptz,
  delete_requested_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, id)
);
-- 用户名不分大小写唯一
CREATE UNIQUE INDEX accounts_username_lower_key ON accounts (lower(username));
-- 一个店一个账号
CREATE UNIQUE INDEX accounts_store_key ON accounts (store_id);

CREATE TABLE devices (
  -- 设备 id 由手机在每次登录或兑码时新生成，从不重复使用（§3.1）
  id            uuid NOT NULL,
  account_id    uuid NOT NULL,
  store_id      uuid NOT NULL,
  role          text NOT NULL CHECK (role IN ('family', 'cashier')),
  label         text NOT NULL CHECK (length(label) BETWEEN 1 AND 40),
  -- 256 位随机令牌的 sha256（十六进制 64 位），库里不存令牌原文
  token_hash    text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  app_build     integer CHECK (app_build >= 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz,
  -- 被踢后行保留，靠它认出被踢设备补传的流水（§4.5）
  revoked_at    timestamptz,
  -- demo_reset 就是同步响应里的 discard_outbox（§4.5）
  revoke_reason text CHECK (revoke_reason IN ('kicked', 'revoke_others', 'logout', 'account_delete', 'demo_reset')),
  PRIMARY KEY (store_id, id),
  UNIQUE (token_hash),
  FOREIGN KEY (store_id, account_id) REFERENCES accounts (store_id, id),
  CONSTRAINT devices_revoked_consistent CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL))
);
-- 同店未撤销设备的称呼不重名（重名时由应用自动加序号）
CREATE UNIQUE INDEX devices_active_label_key ON devices (store_id, label) WHERE revoked_at IS NULL;
CREATE INDEX devices_account_idx ON devices (store_id, account_id);

CREATE TABLE pairing_tokens (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash        text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  account_id        uuid NOT NULL,
  store_id          uuid NOT NULL,
  role              text NOT NULL CHECK (role IN ('family', 'cashier')),
  label             text CHECK (length(label) BETWEEN 1 AND 40),
  -- 只有 role='family' 的设备能创建（S03 的接口校验）
  created_by_device uuid NOT NULL,
  -- 2 分钟过期，一次性
  expires_at        timestamptz NOT NULL,
  used_at           timestamptz,
  used_by_device    uuid,
  UNIQUE (token_hash),
  FOREIGN KEY (store_id, account_id) REFERENCES accounts (store_id, id),
  FOREIGN KEY (store_id, created_by_device) REFERENCES devices (store_id, id),
  FOREIGN KEY (store_id, used_by_device) REFERENCES devices (store_id, id),
  -- 收银员码必须带称呼（§7）
  CHECK (role <> 'cashier' OR label IS NOT NULL),
  CHECK ((used_at IS NULL) = (used_by_device IS NULL))
);
CREATE INDEX pairing_tokens_store_idx ON pairing_tokens (store_id, expires_at);

-- ───────────────────────── 3.2 商品 ─────────────────────────

CREATE TABLE products (
  -- 商品 id 由手机生成
  id                uuid NOT NULL,
  store_id          uuid NOT NULL REFERENCES stores (id),
  name              text NOT NULL CHECK (length(name) >= 1),
  base_unit         text NOT NULL DEFAULT '个' CHECK (length(base_unit) >= 1),
  -- 单件卖价只存这一处（单件码不存价，§3.2）；上限 §5.0
  price_fen         bigint NOT NULL CHECK (price_fen BETWEEN 0 AND 99999999),
  stock_qty         integer NOT NULL DEFAULT 0,
  -- 货值可为负（负库存时 = stock_qty × last_cost_fen，§5.2 I3）
  stock_value_fen   bigint NOT NULL DEFAULT 0,
  last_cost_fen     bigint CHECK (last_cost_fen >= 0),
  -- 进价是否已知：区分「真的零成本」和「没填」（§5.2）
  cost_known        boolean NOT NULL DEFAULT false,
  -- 每次库存变动 +1（§5.6）
  stock_ver         bigint NOT NULL DEFAULT 0 CHECK (stock_ver >= 0),
  last_count_at     timestamptz,
  low_at            integer CHECK (low_at >= 0),
  stock_known       boolean NOT NULL DEFAULT false,
  track_expiry      boolean NOT NULL DEFAULT false,
  expiry_warn_days  integer NOT NULL DEFAULT 7 CHECK (expiry_warn_days >= 0),
  shelf_life_months integer CHECK (shelf_life_months >= 1),
  -- 收银员临时登记、等家用号补全
  needs_review      boolean NOT NULL DEFAULT false,
  image_key         text,
  image_source      text,
  -- image_key 每变一次 +1，0 = 没图（§3.2、§14 S02-1）
  image_ver         integer NOT NULL DEFAULT 0 CHECK (image_ver >= 0),
  archived_at       timestamptz,
  created_by_device uuid,
  rev               bigint NOT NULL CHECK (rev >= 1),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, id),
  FOREIGN KEY (store_id, created_by_device) REFERENCES devices (store_id, id),
  -- I3 里不依赖计算的部分由库兜底（§3.3）：进价未知时货值恒为 0；进价已知时一定有最近进价
  CONSTRAINT products_unknown_cost_zero_value CHECK (cost_known OR stock_value_fen = 0),
  CONSTRAINT products_known_cost_has_last CHECK (NOT cost_known OR last_cost_fen IS NOT NULL)
);
-- 同店 rev 不重复；也是 catalog 流 `rev > cursor` 分页的索引（§4.2）
CREATE UNIQUE INDEX products_store_rev_key ON products (store_id, rev);
CREATE INDEX products_store_name_idx ON products (store_id, name);
CREATE INDEX products_needs_review_idx ON products (store_id) WHERE needs_review;

CREATE TABLE product_barcodes (
  store_id       uuid NOT NULL,
  barcode        text NOT NULL CHECK (length(barcode) BETWEEN 1 AND 64),
  product_id     uuid NOT NULL,
  -- 1 = 单件码；>1 = 整件码（§5.0 上限 9,999）
  pack_qty       integer NOT NULL CHECK (pack_qty BETWEEN 1 AND 9999),
  unit_name      text NOT NULL CHECK (length(unit_name) >= 1),
  pack_price_fen bigint CHECK (pack_price_fen BETWEEN 0 AND 99999999),
  rev            bigint NOT NULL CHECK (rev >= 1),
  deleted_at     timestamptz,
  PRIMARY KEY (store_id, barcode),
  FOREIGN KEY (store_id, product_id) REFERENCES products (store_id, id),
  -- 单件码不存价，卖价一律读 products.price_fen（§3.2）
  CONSTRAINT product_barcodes_single_no_price CHECK (pack_qty > 1 OR pack_price_fen IS NULL)
);
CREATE UNIQUE INDEX product_barcodes_store_rev_key ON product_barcodes (store_id, rev);
CREATE INDEX product_barcodes_product_idx ON product_barcodes (store_id, product_id);
-- 手输条码前缀匹配（§5.5）：text_pattern_ops 让 LIKE 'xxx%' 走索引
CREATE INDEX product_barcodes_prefix_idx ON product_barcodes (store_id, barcode text_pattern_ops) WHERE deleted_at IS NULL;

CREATE TABLE product_aliases (
  store_id   uuid NOT NULL,
  -- 后到的商品 id（它本身没有在 products 里建行）
  alias_id   uuid NOT NULL,
  product_id uuid NOT NULL,
  PRIMARY KEY (store_id, alias_id),
  FOREIGN KEY (store_id, product_id) REFERENCES products (store_id, id),
  CHECK (alias_id <> product_id)
);

-- 全局缓存，不分店；查不到也缓存（found=false，7 天后可重查）
CREATE TABLE barcode_catalog (
  barcode    text PRIMARY KEY CHECK (length(barcode) BETWEEN 1 AND 64),
  found      boolean NOT NULL,
  name       text,
  spec       text,
  brand      text,
  image_url  text,
  source     text NOT NULL,
  raw        jsonb,
  fetched_at timestamptz NOT NULL DEFAULT now()
);

-- ───────────────────────── 3.3 流水 ─────────────────────────

CREATE TABLE ops (
  -- 手机生成；幂等键是 (store_id, id)
  id           uuid NOT NULL,
  store_id     uuid NOT NULL,
  device_id    uuid NOT NULL,
  type         text NOT NULL CHECK (type IN (
                 'sale_batch', 'void', 'product_upsert', 'product_edit', 'barcode_link', 'barcode_unlink',
                 'stock_in', 'opening', 'product_review_complete', 'count', 'expiry_dispose', 'lot_snooze')),
  payload      jsonb NOT NULL,
  payload_hash text NOT NULL,
  occurred_at  timestamptz NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),
  status       text NOT NULL CHECK (status IN ('applied', 'rejected', 'held')),
  reject_code  text,
  -- 当初返回给手机的结果（含 remap、拒绝原因），重发时原样返回（§4.2）
  result       jsonb NOT NULL,
  -- 暂存的 op 被家用手机处理（记上 → applied；不要 → rejected + discarded）的时间和设备（§3.3、§14 S02-3）
  resolved_at        timestamptz,
  resolved_by_device uuid,
  flags        jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (store_id, id),
  FOREIGN KEY (store_id, device_id) REFERENCES devices (store_id, id),
  FOREIGN KEY (store_id, resolved_by_device) REFERENCES devices (store_id, id),
  CONSTRAINT ops_rejected_has_code CHECK (status <> 'rejected' OR reject_code IS NOT NULL),
  CONSTRAINT ops_resolved_consistent CHECK ((resolved_at IS NULL) = (resolved_by_device IS NULL)),
  -- 处理过的就不再是暂存
  CONSTRAINT ops_resolved_not_held CHECK (resolved_at IS NULL OR status <> 'held')
);
CREATE INDEX ops_device_idx ON ops (store_id, device_id, received_at);
-- 「已登录的手机」里列出被踢设备暂存待确认的账（§4.5）
CREATE INDEX ops_held_idx ON ops (store_id, device_id) WHERE status = 'held';

CREATE TABLE sale_batches (
  id             uuid NOT NULL,
  store_id       uuid NOT NULL,
  device_id      uuid NOT NULL,
  list_total_fen bigint NOT NULL CHECK (list_total_fen >= 0),
  -- 撤销单行后不改，报表按行求和；上限 §5.0（Q1）
  paid_total_fen bigint NOT NULL CHECK (paid_total_fen BETWEEN 0 AND 19999999800),
  occurred_at    timestamptz NOT NULL,
  received_at    timestamptz NOT NULL DEFAULT now(),
  rev            bigint NOT NULL CHECK (rev >= 1),
  PRIMARY KEY (store_id, id),
  FOREIGN KEY (store_id, device_id) REFERENCES devices (store_id, id)
);
CREATE UNIQUE INDEX sale_batches_store_rev_key ON sale_batches (store_id, rev);
CREATE INDEX sale_batches_occurred_idx ON sale_batches (store_id, occurred_at);

CREATE TABLE entries (
  id                uuid NOT NULL,
  store_id          uuid NOT NULL,
  -- 本店内的应用顺序
  seq               bigint NOT NULL CHECK (seq >= 1),
  op_id             uuid NOT NULL,
  batch_id          uuid,
  type              text NOT NULL CHECK (type IN (
                      'sale', 'stock_in', 'opening', 'count', 'cost_adjust', 'cost_fix', 'expire_loss', 'supplier_return')),
  -- 冲销行指向原行（§3.3 撤销的记法）
  reverses_entry_id uuid,
  product_id        uuid NOT NULL,
  barcode           text,
  name_snapshot     text NOT NULL,
  unit_name         text,
  pack_qty          integer CHECK (pack_qty >= 1),
  pack_count        integer,
  qty_delta         integer NOT NULL,
  list_amount_fen   bigint NOT NULL,
  amount_fen        bigint NOT NULL,
  -- 单价不是金额：冲销行照抄原行、不取反（§3.3、R4），所以永远 >= 0
  unit_cost_fen     bigint CHECK (unit_cost_fen >= 0),
  cogs_fen          bigint NOT NULL DEFAULT 0,
  value_delta_fen   bigint NOT NULL DEFAULT 0,
  cost_missing      boolean NOT NULL DEFAULT false,
  expiry_date       date,
  device_id         uuid NOT NULL,
  occurred_at       timestamptz NOT NULL,
  received_at       timestamptz NOT NULL DEFAULT now(),
  voided_at         timestamptz,
  voided_by_device  uuid,
  cost_fix_entry_id uuid,
  flags             jsonb NOT NULL DEFAULT '{}'::jsonb,
  rev               bigint NOT NULL CHECK (rev >= 1),
  PRIMARY KEY (store_id, id),
  FOREIGN KEY (store_id, op_id) REFERENCES ops (store_id, id),
  FOREIGN KEY (store_id, batch_id) REFERENCES sale_batches (store_id, id),
  FOREIGN KEY (store_id, reverses_entry_id) REFERENCES entries (store_id, id),
  FOREIGN KEY (store_id, product_id) REFERENCES products (store_id, id),
  FOREIGN KEY (store_id, device_id) REFERENCES devices (store_id, id),
  FOREIGN KEY (store_id, voided_by_device) REFERENCES devices (store_id, id),
  FOREIGN KEY (store_id, cost_fix_entry_id) REFERENCES entries (store_id, id),
  CHECK (reverses_entry_id IS NULL OR reverses_entry_id <> id)
);
CREATE UNIQUE INDEX entries_store_seq_key ON entries (store_id, seq);
CREATE UNIQUE INDEX entries_store_rev_key ON entries (store_id, rev);
-- 除 cost_fix 外一行最多被冲销一次（撤销两次第二次无操作，§4.4）。
-- cost_fix 可以被多次部分冲销：它补记的每一笔卖出被撤销时各冲一条（§3.3、§14 S02-9、cost.json cost-19）
CREATE UNIQUE INDEX entries_reverses_key ON entries (store_id, reverses_entry_id)
  WHERE reverses_entry_id IS NOT NULL AND type <> 'cost_fix';
-- 报表按上海时区的日/月求和
CREATE INDEX entries_occurred_idx ON entries (store_id, occurred_at);
CREATE INDEX entries_product_idx ON entries (store_id, product_id, seq);
CREATE INDEX entries_batch_idx ON entries (store_id, batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX entries_op_idx ON entries (store_id, op_id);
-- 收银员只拉本机最近 2 天的卖出（§3.4）
CREATE INDEX entries_device_idx ON entries (store_id, device_id, occurred_at);

CREATE TABLE stock_lots (
  id              uuid NOT NULL,
  store_id        uuid NOT NULL,
  product_id      uuid NOT NULL,
  source_entry_id uuid NOT NULL,
  expiry_date     date,
  qty_in          integer NOT NULL CHECK (qty_in >= 0),
  qty_left        integer NOT NULL CHECK (qty_left >= 0),
  snoozed_until   date,
  closed_at       timestamptz,
  closed_reason   text CHECK (closed_reason IN ('disposed', 'voided')),
  -- 只在「处理」和「过几天再提醒」时 +1（§5.4）
  handle_ver      integer NOT NULL DEFAULT 0 CHECK (handle_ver >= 0),
  rev             bigint NOT NULL CHECK (rev >= 1),
  PRIMARY KEY (store_id, id),
  FOREIGN KEY (store_id, product_id) REFERENCES products (store_id, id),
  FOREIGN KEY (store_id, source_entry_id) REFERENCES entries (store_id, id),
  CONSTRAINT stock_lots_closed_consistent CHECK ((closed_at IS NULL) = (closed_reason IS NULL))
);
CREATE UNIQUE INDEX stock_lots_store_rev_key ON stock_lots (store_id, rev);
-- 扣批次顺序：到期日从早到晚（空日期最后），同日先建的先扣（§5.4、Q11）
CREATE INDEX stock_lots_open_idx ON stock_lots (store_id, product_id, expiry_date NULLS LAST) WHERE closed_at IS NULL;
CREATE INDEX stock_lots_source_idx ON stock_lots (store_id, source_entry_id);

-- 每笔卖出/损耗/盘点扣了哪个批次，撤销时原样加回
CREATE TABLE lot_moves (
  store_id uuid NOT NULL,
  entry_id uuid NOT NULL,
  lot_id   uuid NOT NULL,
  qty      integer NOT NULL CHECK (qty <> 0),
  PRIMARY KEY (store_id, entry_id, lot_id),
  FOREIGN KEY (store_id, entry_id) REFERENCES entries (store_id, id),
  FOREIGN KEY (store_id, lot_id) REFERENCES stock_lots (store_id, id)
);
CREATE INDEX lot_moves_lot_idx ON lot_moves (store_id, lot_id);

-- 图片下载队列，失败重试 3 次
CREATE TABLE image_jobs (
  product_id  uuid NOT NULL,
  store_id    uuid NOT NULL,
  source_url  text NOT NULL,
  attempts    integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 3),
  next_try_at timestamptz NOT NULL DEFAULT now(),
  done_at     timestamptz,
  last_error  text,
  PRIMARY KEY (store_id, product_id),
  FOREIGN KEY (store_id, product_id) REFERENCES products (store_id, id)
);
CREATE INDEX image_jobs_pending_idx ON image_jobs (next_try_at) WHERE done_at IS NULL;

-- 墓碑：被删的行（解除的整件码等），让手机同步删除；也占一个 rev
CREATE TABLE removed (
  store_id uuid NOT NULL REFERENCES stores (id),
  rev      bigint NOT NULL CHECK (rev >= 1),
  kind     text NOT NULL CHECK (kind IN ('barcode', 'product_alias', 'entry', 'batch', 'lot')),
  -- 条码墓碑是条码本身，其余是 uuid
  row_id   text NOT NULL,
  PRIMARY KEY (store_id, rev)
);
CREATE INDEX removed_row_idx ON removed (store_id, kind, row_id);
