import GRDB

/// 手机本地库的表结构与迁移（§3.4）。金额一律整数分（INTEGER），时间存 `Op.formatTimestamp` 的
/// RFC 3339 文本（固定 +08:00、毫秒，等宽，按字符串比较就是按时间比较）。
///
/// 分两类：
/// - **投影**：`product product_private barcode sale_batch entry lot` 和 `meta` 里的游标、epoch。
///   退出、被踢、换角色、换账号时整体清空（§3.4、§4.5）。
/// - **outbox**：待传和已确认（保留 14 天）的 op。每条绑定产生它时的店、设备、令牌引用，**不可改绑**
///   （触发器拦截）；旧会话留下的未确认 op 就是恢复队列。换身份时不清。
enum LocalSchema {
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // 会话：当前一条（is_current = 1），以前的留着直到它的恢复队列传完、钥匙串里的旧令牌删掉。
            // 设备 id 每次登录 / 兑码新生成、从不重复（§3.1），所以用它当会话主键。
            try db.execute(sql: """
                CREATE TABLE session (
                  device_id    TEXT PRIMARY KEY,
                  store_id     TEXT NOT NULL,
                  role         TEXT NOT NULL CHECK (role IN ('family','cashier','review')),
                  token_ref    TEXT NOT NULL,          -- 钥匙串条目的名字，令牌本身不进库
                  store_name   TEXT NOT NULL,
                  device_label TEXT NOT NULL,
                  is_current   INTEGER NOT NULL DEFAULT 0 CHECK (is_current IN (0,1)),
                  created_at   TEXT NOT NULL,
                  retired_at   TEXT
                );
                CREATE UNIQUE INDEX session_one_current ON session(is_current) WHERE is_current = 1;

                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

                CREATE TABLE product (
                  id           TEXT PRIMARY KEY,
                  name         TEXT NOT NULL,
                  base_unit    TEXT NOT NULL,
                  price_fen    INTEGER NOT NULL CHECK (price_fen >= 0),
                  needs_review INTEGER NOT NULL DEFAULT 0,
                  track_expiry INTEGER NOT NULL DEFAULT 0,
                  image_ver    INTEGER NOT NULL DEFAULT 0,
                  archived     INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX product_name ON product(name);

                -- 收银员手机上永远是空的（触发器拦截写入，服务器也不下发）
                CREATE TABLE product_private (
                  product_id        TEXT PRIMARY KEY REFERENCES product(id) ON DELETE CASCADE,
                  stock_qty         INTEGER NOT NULL,     -- 服务器基线，只由拉取更新
                  stock_value_fen   INTEGER NOT NULL,
                  last_cost_fen     INTEGER,
                  cost_known        INTEGER NOT NULL,
                  stock_ver         INTEGER NOT NULL,
                  low_at            INTEGER,
                  expiry_warn_days  INTEGER NOT NULL,
                  shelf_life_months INTEGER
                );

                CREATE TABLE barcode (
                  barcode        TEXT PRIMARY KEY,
                  product_id     TEXT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
                  pack_qty       INTEGER NOT NULL CHECK (pack_qty >= 1),
                  unit_name      TEXT NOT NULL,
                  pack_price_fen INTEGER,
                  CHECK (pack_qty > 1 OR pack_price_fen IS NULL)   -- 单件码不带价
                );
                CREATE INDEX barcode_product ON barcode(product_id);

                CREATE TABLE sale_batch (
                  id             TEXT PRIMARY KEY,
                  device_id      TEXT NOT NULL,
                  list_total_fen INTEGER NOT NULL,
                  paid_total_fen INTEGER NOT NULL,
                  occurred_at    TEXT NOT NULL,
                  op_id          TEXT                    -- 本机记的才有；拉取来的为空
                );

                CREATE TABLE entry (
                  id                TEXT PRIMARY KEY,
                  seq               INTEGER,             -- 服务器的应用顺序；本机未确认的为空
                  op_id             TEXT,
                  batch_id          TEXT REFERENCES sale_batch(id) ON DELETE CASCADE,
                  type              TEXT NOT NULL,
                  reverses_entry_id TEXT,
                  product_id        TEXT NOT NULL,
                  barcode           TEXT,
                  name_snapshot     TEXT NOT NULL,
                  unit_name         TEXT,
                  pack_qty          INTEGER,
                  pack_count        INTEGER,
                  qty_delta         INTEGER NOT NULL,
                  list_amount_fen   INTEGER NOT NULL,
                  amount_fen        INTEGER NOT NULL,
                  unit_cost_fen     INTEGER,             -- 以下三列收银员手机上恒为空
                  cogs_fen          INTEGER,
                  value_delta_fen   INTEGER,
                  cost_missing      INTEGER NOT NULL DEFAULT 0,
                  expiry_date       TEXT,
                  device_id         TEXT NOT NULL,
                  occurred_at       TEXT NOT NULL,
                  voided_at         TEXT,
                  voided_by_device  TEXT
                );
                CREATE INDEX entry_occurred ON entry(occurred_at);
                CREATE INDEX entry_batch ON entry(batch_id);

                -- 仅家用号：未关闭的保质期批次
                CREATE TABLE lot (
                  id            TEXT PRIMARY KEY,
                  product_id    TEXT NOT NULL,
                  expiry_date   TEXT,
                  qty_in        INTEGER NOT NULL,
                  qty_left      INTEGER NOT NULL,
                  snoozed_until TEXT,
                  handle_ver    INTEGER NOT NULL
                );

                CREATE TABLE outbox (
                  seq          INTEGER PRIMARY KEY AUTOINCREMENT,   -- 上传顺序，重启后不变
                  id           TEXT NOT NULL,                      -- op id：店内唯一（§14 S02-8），见下面的 UNIQUE
                  store_id     TEXT NOT NULL,
                  device_id    TEXT NOT NULL,
                  token_ref    TEXT NOT NULL,
                  type         TEXT NOT NULL,
                  op_json      BLOB NOT NULL,                       -- Op.encoded()，重发字节不变
                  occurred_at  TEXT NOT NULL,
                  status       TEXT NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending','applied','rejected','held')),
                  reject_code  TEXT,
                  result_json  BLOB,
                  confirmed_at TEXT,
                  CHECK ((status = 'pending') = (confirmed_at IS NULL)),
                  UNIQUE (store_id, id)
                );
                CREATE INDEX outbox_device_status ON outbox(device_id, status);

                -- 每条 op 对本地库存的增减（基本单位）。显示库存 = 基线 + 本机未确认 op 的这些增减。
                CREATE TABLE outbox_effect (
                  store_id   TEXT NOT NULL,
                  op_id      TEXT NOT NULL,
                  product_id TEXT NOT NULL,
                  qty_delta  INTEGER NOT NULL,
                  FOREIGN KEY (store_id, op_id) REFERENCES outbox(store_id, id) ON DELETE CASCADE
                );
                CREATE INDEX outbox_effect_op ON outbox_effect(store_id, op_id);
                CREATE INDEX outbox_effect_product ON outbox_effect(product_id);

                -- 归属不可变：op 的身份和内容一经写入不许改，只有结果可以写。
                CREATE TRIGGER outbox_binding_immutable
                BEFORE UPDATE OF seq, id, store_id, device_id, token_ref, type, op_json, occurred_at ON outbox
                BEGIN SELECT RAISE(ABORT, 'outbox binding is immutable'); END;
                CREATE TRIGGER outbox_effect_immutable BEFORE UPDATE ON outbox_effect
                BEGIN SELECT RAISE(ABORT, 'outbox effect is immutable'); END;
                """)

            // 收银员形态下进价、库存、批次一概写不进来（§3.4、§6 原则 ②）。仓库层已经挡了，这是第二道。
            let cashier = "(SELECT role FROM session WHERE is_current = 1) = 'cashier'"
            for (table, op) in [("product_private", "INSERT"), ("product_private", "UPDATE"), ("lot", "INSERT"), ("lot", "UPDATE")] {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_\(op.lowercased())_not_cashier BEFORE \(op) ON \(table)
                    WHEN \(cashier) BEGIN SELECT RAISE(ABORT, 'cashier device has no private data'); END;
                    """)
            }
            for op in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER entry_\(op.lowercased())_not_cashier BEFORE \(op) ON entry
                    WHEN \(cashier) AND (NEW.type <> 'sale' OR NEW.unit_cost_fen IS NOT NULL
                                         OR NEW.cogs_fen IS NOT NULL OR NEW.value_delta_fen IS NOT NULL)
                    BEGIN SELECT RAISE(ABORT, 'cashier device has no private data'); END;
                    """)
            }
        }
        // S20：流水的 flags（迟到补偿行 `late_before_count` 不单独成卡，§14 S07-1）；别的手机的名字（07a 卡片上显示手机名）
        m.registerMigration("v2-records") { db in
            try db.execute(sql: """
                ALTER TABLE entry ADD COLUMN flags TEXT;
                CREATE INDEX entry_reverses ON entry(reverses_entry_id);
                CREATE INDEX entry_op ON entry(op_id);
                CREATE TABLE device_label (device_id TEXT PRIMARY KEY, label TEXT NOT NULL);
                """)
        }
        // S22a：本机记下的商品别名（§4.2 remap）。outbox 和 outbox_effect 的内容不可改（op 原样重发，服务器按别名认），
        // 待传 op 的增减仍挂在旧商品 id 上；显示库存时把旧 id 的增减并到赢家上，否则 remap 到确认之间赢家少算这几笔。
        m.registerMigration("v3-sync") { db in
            try db.execute(sql: """
                CREATE TABLE product_remap (
                  store_id TEXT NOT NULL,
                  old_id   TEXT NOT NULL,
                  new_id   TEXT NOT NULL,
                  PRIMARY KEY (store_id, old_id)
                );
                CREATE INDEX product_remap_new ON product_remap(store_id, new_id);
                """)
        }
        // PR #36 评审必须修 1：商品流按 rev 分页，条码可能先于它的商品到达。商品还没到的条码先放这里（不带外键），
        // 商品到了再挂进 `barcode`；`catalogDone` 之前不让卖，这些条码也扫不到。
        m.registerMigration("v4-sync-pending-barcode") { db in
            try db.execute(sql: """
                CREATE TABLE barcode_pending (
                  barcode        TEXT PRIMARY KEY,
                  product_id     TEXT NOT NULL,
                  pack_qty       INTEGER NOT NULL CHECK (pack_qty >= 1),
                  unit_name      TEXT NOT NULL,
                  pack_price_fen INTEGER
                );
                CREATE INDEX barcode_pending_product ON barcode_pending(product_id);
                """)
            // PR #36 评审必须修 2：op 已确认、但它动过的商品的新库存基线还在商品流后页时，这几笔增减继续算进显示库存，
            // 直到该商品的新基线拉下来（或商品流拉到底）才放掉，否则库存先对后错回（10 卖 1 → 9 → 又变回 10）
            try db.execute(sql: """
                CREATE TABLE effect_hold (
                  store_id   TEXT NOT NULL,
                  op_id      TEXT NOT NULL,
                  product_id TEXT NOT NULL,
                  PRIMARY KEY (store_id, op_id, product_id),
                  FOREIGN KEY (store_id, op_id) REFERENCES outbox(store_id, id) ON DELETE CASCADE
                );
                """)
        }
        // S22b：恢复队列用旧令牌上传要带旧会话自己的 epoch（换会话时 `server_epoch` 跟投影一起清掉）；
        // 主动退出登录时 outbox 没传完，`logout` 推迟到恢复队列传完再调（§4.5）；服务器已确认这个会话被踢（不用再调 logout）
        m.registerMigration("v5-identity") { db in
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN epoch TEXT;
                ALTER TABLE session ADD COLUMN logout_pending INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE session ADD COLUMN revoked INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE session ADD COLUMN logged_out INTEGER NOT NULL DEFAULT 0;
                """)
        }
        return m
    }

    /// 投影表（清空顺序照外键）
    static let projectionTables = ["device_label", "entry", "sale_batch", "lot", "barcode_pending", "barcode", "product_private", "product"]
    /// meta 里属于投影的键
    static let projectionMetaKeys = [MetaKey.catalogCursor, .ledgerCursor, .serverEpoch, .lastSyncAt, .catalogDone, .serverTimeAtSync,
                                     .deletePendingUntil]
}

/// `meta` 表的键（§3.4：游标、server_epoch；角色、店名、设备名在 `session` 表里）
public enum MetaKey: String, Sendable {
    case catalogCursor = "cursor.catalog"
    case ledgerCursor = "cursor.ledger"
    case serverEpoch = "server_epoch"
    /// 清投影 / 删旧进货 op 之后还没压缩完（§14 S13-1）。不属于投影，换身份时不清
    case compactPending = "compact.pending"
    /// S22a：上次同步成功（拿到响应并提交）的时间
    case lastSyncAt = "sync.last_at"
    /// S22a：上次同步响应里的 `server_time`。和 `lastSyncAt`（本机时钟）一比就是手机时钟偏了多少（T5）
    case serverTimeAtSync = "sync.server_time"
    /// S22a：首次同步的商品流已经拉到底（之后就能进首页开卖）
    case catalogDone = "sync.catalog_done"
    /// S22a：账号注销期间（§14 S04-2），值是服务器给的 `delete_pending_until`
    case deletePendingUntil = "sync.delete_pending_until"
    /// S22b：为什么没有当前会话（被踢 `kicked_family` / `kicked_cashier`，演示店重置 `demo_reset`）。启动时据此进 25b / 25f；
    /// 开新会话时清掉。不属于投影
    case signedOutReason = "identity.signed_out"
    /// S22b：恢复队列被服务器拒收、还没让人看过的笔数（收银员会话下旧会话的 op 拿到结果就删，读不回 outbox，
    /// 只能按当次响应记数，§8 S22b）。首页「N 笔没记上」点「知道了」清零。不属于投影
    case recoveryRejectedUnseen = "recovery.rejected_unseen"
    /// S22b：被拒 op 看到哪儿了（`confirmed_at`，首页「知道了」时记下）。不属于投影：换 epoch 后已点过「知道了」的不再冒出来
    case rejectedSeenAt = "sync.rejected_seen_at"
}
