import Foundation
import GRDB

// S22a 同步引擎一：正常同步、首次同步、本地原子提交（§4.1 第 6 条、§4.2）。
//
// - 推：outbox 里当前会话的 pending op 按 seq 取，≤200 个且按 `op_json` 字节累加不超过 `maxBatchBytes`（§14 S04-13），
//   单个 op 总放得下；字节原样拼进请求体，重发字节不变。
// - 拉：catalog、ledger 两条流各自分页（`has_more` 为真就继续）。首次同步 catalog 拉到底就记 `catalogDone`，
//   界面据此进首页开卖，ledger 在后台继续。
// - 原子提交：一次响应 = 记每个 op 的结果 + 改写 remap + 写变更 + 推进游标 + epoch，**同一个事务**；
//   压缩在提交之后做（PR #9 Fable 约束）。本类型的方法都是同步阻塞的，调用方不许在主线程调。

/// 服务器的同步响应（`SyncResponse`，只解码手机要用的字段）
public struct SyncResponse: Decodable, Sendable {
    public struct Result: Decodable, Sendable {
        public let id: UUID
        public let status: String
        public let code: String?
        public let remap: [String: String]?
        public let replayed: Bool?
    }
    public struct Private: Decodable, Sendable {
        public let stockQty: Int64
        public let stockValueFen: Int64
        public let lastCostFen: Int64?
        public let costKnown: Bool
        public let stockVer: Int64
        public let lowAt: Int64?
        public let expiryWarnDays: Int64
        public let shelfLifeMonths: Int64?
    }
    public struct Product: Decodable, Sendable {
        public let id: UUID
        public let name: String
        public let baseUnit: String
        public let priceFen: Int64
        public let needsReview: Bool
        public let trackExpiry: Bool
        public let imageVer: Int64
        public let archived: Bool
        public let `private`: Private?
    }
    public struct Barcode: Decodable, Sendable {
        public let barcode: String
        public let productId: UUID
        public let packQty: Int64
        public let unitName: String
        public let packPriceFen: Int64?
    }
    public struct Removed: Decodable, Sendable {
        public let kind: String
        public let rowId: String
    }
    public struct Flags: Decodable, Sendable {
        public let lateBeforeCount: Bool?
        public let lateFromRevoked: Bool?
        public let clockAdjusted: Bool?
        public let recovered: Bool?
    }
    public struct Entry: Decodable, Sendable {
        public let id: UUID
        public let seq: Int64
        public let opId: UUID?
        public let batchId: UUID?
        public let type: String
        public let reversesEntryId: UUID?
        public let productId: UUID
        public let barcode: String?
        public let nameSnapshot: String
        public let unitName: String?
        public let packQty: Int64?
        public let packCount: Int64?
        public let qtyDelta: Int64
        public let listAmountFen: Int64
        public let amountFen: Int64
        public let unitCostFen: Int64?
        public let cogsFen: Int64?
        public let valueDeltaFen: Int64?
        public let costMissing: Bool?
        public let expiryDate: String?
        public let deviceId: UUID
        public let deviceLabel: String?
        public let occurredAt: String
        public let voidedAt: String?
        public let flags: Flags?
    }
    public struct Batch: Decodable, Sendable {
        public let id: UUID
        public let deviceId: UUID
        public let listTotalFen: Int64
        public let paidTotalFen: Int64
        public let occurredAt: String
    }
    public struct Lot: Decodable, Sendable {
        public let id: UUID
        public let productId: UUID
        public let expiryDate: String?
        public let qtyIn: Int64
        public let qtyLeft: Int64
        public let snoozedUntil: String?
        public let closedAt: String?
        public let handleVer: Int64
    }
    public struct Changes: Decodable, Sendable {
        public let products: [Product]
        public let barcodes: [Barcode]
        public let removed: [Removed]
        public let entries: [Entry]
        public let batches: [Batch]
        public let lots: [Lot]
    }
    public struct Cursors: Codable, Sendable, Equatable {
        public var catalog: Int64
        public var ledger: Int64
        public init(catalog: Int64, ledger: Int64) { self.catalog = catalog; self.ledger = ledger }
    }
    public struct HasMore: Decodable, Sendable { public let catalog: Bool; public let ledger: Bool }
    public struct Device: Decodable, Sendable {
        public let role: String
        public let label: String
        public let revoked: Bool
        public let discardOutbox: Bool?
    }

    public let results: [Result]
    public let deletePendingUntil: String?
    public let changes: Changes
    public let cursors: Cursors
    public let hasMore: HasMore
    public let totalProducts: Int64
    public let serverTime: String
    public let epoch: UUID
    public let device: Device

    public static func decode(_ data: Data) throws -> SyncResponse {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SyncResponse.self, from: data)
    }
}

/// 一次要推上去的 op（outbox 原样字节）
public struct PushBatch: Sendable {
    public let storeId: UUID
    public let items: [OutboxItem]
    public var ids: [UUID] { items.map(\.id) }
}

/// 同步状态指示（首页右上角、设置页、25a 提醒条）
public struct SyncStatus: Equatable, Sendable {
    public let pendingCount: Int
    /// 当前会话最早一条待传 op 的 `occurred_at`
    public let oldestPendingAt: Date?
    public let lastSyncAt: Date?
    public let catalogDone: Bool
    public let deletePendingUntil: String?

    /// 「超过一天没传」（§4.2：outbox 里有超过 24 小时的 → 首页提醒条 25a）
    public func overdue(now: Date) -> Bool {
        guard let o = oldestPendingAt else { return false }
        // 用日历加一天比较（ShopCore 不出现浮点，NoFloatTests）
        guard let limit = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: o) else { return false }
        return now > limit
    }
}

public enum SyncError: Error, Equatable, Sendable {
    /// 409 `epoch_mismatch`：S22b 处理（握手、重建投影、重传）
    case epochMismatch(UUID)
    /// 设备已被踢：S22b 处理（25b / 25f）
    case revoked(discardOutbox: Bool)
}

/// 首次同步进度（「194 / 312 样」）
public struct SyncProgress: Equatable, Sendable {
    public let products: Int
    public let totalProducts: Int
    public let catalogDone: Bool
}

extension LocalDB {
    /// 请求体上限 1 MiB；留 64 KiB 给外壳
    public static let maxBatchBytes = 1_048_576 - 65_536
    public static let maxBatchOps = 200

    /// 取下一批要推的 op：当前会话、pending、按 seq；≤200 个，字节累加到快 1 MiB 就截断，第一条总放得下（§14 S04-13）
    public func nextPushBatch(maxOps: Int = LocalDB.maxBatchOps, maxBytes: Int = LocalDB.maxBatchBytes) throws -> PushBatch? {
        try writer.read { db in
            guard let s = try Self.currentSession(db) else { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ? ORDER BY seq LIMIT ?
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString, maxOps]).map(Self.outboxFrom)
            var out: [OutboxItem] = []
            var bytes = 0
            for o in rows {
                if !out.isEmpty && bytes + o.opJSON.count + 1 > maxBytes { break }
                bytes += o.opJSON.count + 1
                out.append(o)
            }
            return out.isEmpty ? nil : PushBatch(storeId: s.storeId, items: out)
        }
    }

    /// 请求体：外壳 + outbox 里的原样字节（重发字节不变）
    public func syncRequestBody(_ batch: PushBatch?, appBuild: Int, pull: Bool = true) throws -> Data {
        let (cur, epoch) = try writer.read { db -> (SyncResponse.Cursors, String?) in
            let c = Int64(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [MetaKey.catalogCursor.rawValue]) ?? "0") ?? 0
            let l = Int64(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [MetaKey.ledgerCursor.rawValue]) ?? "0") ?? 0
            let e = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [MetaKey.serverEpoch.rawValue])
            return (SyncResponse.Cursors(catalog: c, ledger: l), e)
        }
        guard let epoch, UUID(uuidString: epoch) != nil else { throw invalid("还没有 epoch（登录响应里带）") }
        var body = Data("{\"epoch\":\"\(epoch)\",\"cursors\":{\"catalog\":\(cur.catalog),\"ledger\":\(cur.ledger)},\"app_build\":\(appBuild),\"pull\":\(pull),\"ops\":[".utf8)
        for (i, o) in (batch?.items ?? []).enumerated() {
            if i > 0 { body.append(0x2C) }
            body.append(o.opJSON)
        }
        body.append(contentsOf: Array("]}".utf8))
        return body
    }

    /// 把服务器时间换成本地统一格式（固定 +08:00、毫秒，按字符串比较就是按时间比较）
    static func normalizeTimestamp(_ s: String) throws -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Op.formatTimestamp(d) }
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { throw invalid("服务器时间格式不认识：\(s)") }
        return Op.formatTimestamp(d)
    }

    /// 处理一次同步响应（§4.1 第 6 条）：记结果 + 改写 remap + 写变更 + 推进游标 + epoch + 上次同步时间，**一个事务**。
    /// `sent` 是这次请求推上去的那批（结果带发送那批 op 的会话的店，op id 只在店内唯一）。压缩在提交之后。
    public func applySyncResponse(_ r: SyncResponse, sent: PushBatch?, at now: Date = Date()) throws {
        let ts = Op.formatTimestamp(now)
        try writer.write { db in
            let s = try Self.requireSession(db)
            let store = sent?.storeId ?? s.storeId
            // 1. 结果。注销期间 results 为空，op 原样留着（§14 S04-2）
            let enc = JSONEncoder()
            for res in r.results {
                guard let st = OutboxItem.Status(rawValue: res.status), st != .pending else { continue }
                let raw = try? enc.encode(["status": res.status, "code": res.code ?? ""])
                try db.execute(sql: """
                    UPDATE outbox SET status = ?, reject_code = ?, result_json = ?, confirmed_at = ?
                    WHERE store_id = ? AND id = ? AND status = 'pending'
                    """, arguments: [st.rawValue, res.code, raw, ts, store.uuidString, res.id.uuidString])
            }
            // 2. remap：投影里对旧商品 id 的引用改成赢家；outbox 的字节和增减不可改（服务器按 product_aliases 认旧 id），
            //    本机记进 product_remap，显示库存时把旧 id 上的待传增减并到赢家
            for res in r.results {
                for (o, n) in res.remap ?? [:] {
                    guard let ou = UUID(uuidString: o), let nu = UUID(uuidString: n) else { continue }
                    let old = ou.uuidString, new = nu.uuidString
                    // 记下别名（连锁的旧别名一并指到新赢家），待传 op 的增减按它并到赢家（product_remap）
                    try db.execute(sql: "UPDATE product_remap SET new_id = ? WHERE store_id = ? AND new_id = ?",
                                   arguments: [new, store.uuidString, old])
                    try db.execute(sql: """
                        INSERT INTO product_remap (store_id, old_id, new_id) VALUES (?, ?, ?)
                        ON CONFLICT(store_id, old_id) DO UPDATE SET new_id = excluded.new_id
                        """, arguments: [store.uuidString, old, new])
                    // 赢家可能还没拉到本机（本响应的 changes 在后面才写，或商品流还没拉到它）：先把旧商品行改名成赢家，
                    // 再改各处引用；外键检查推迟到提交时（否则改条码时赢家行还不存在就违反外键）
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    let winner = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM product WHERE id = ?)", arguments: [new]) ?? false
                    if !winner {
                        try db.execute(sql: "UPDATE OR IGNORE product SET id = ? WHERE id = ?", arguments: [new, old])
                        if s.holdsPrivateData {
                            try db.execute(sql: "UPDATE OR IGNORE product_private SET product_id = ? WHERE product_id = ?", arguments: [new, old])
                        }
                    }
                    try db.execute(sql: "UPDATE OR REPLACE barcode SET product_id = ? WHERE product_id = ?", arguments: [new, old])
                    try db.execute(sql: "UPDATE entry SET product_id = ? WHERE product_id = ?", arguments: [new, old])
                    if s.holdsPrivateData {
                        try db.execute(sql: "UPDATE lot SET product_id = ? WHERE product_id = ?", arguments: [new, old])
                    }
                    try db.execute(sql: "DELETE FROM product WHERE id = ?", arguments: [old])
                }
            }
            // 3. 变更
            try Self.applyChanges(db, r.changes, session: s)
            try faultHook?(.midSyncCommit)
            // 4. 游标、epoch、状态
            func put(_ k: MetaKey, _ v: String?) throws {
                if let v {
                    try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                   arguments: [k.rawValue, v])
                } else {
                    try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [k.rawValue])
                }
            }
            try put(.catalogCursor, String(r.cursors.catalog))
            try put(.ledgerCursor, String(r.cursors.ledger))
            try put(.serverEpoch, r.epoch.uuidString)
            try put(.lastSyncAt, ts)
            try put(.deletePendingUntil, r.deletePendingUntil)
            if !r.hasMore.catalog { try put(.catalogDone, "1") }
            try Self.deleteConfirmedForeignOps(db, current: s)
        }
        try faultHook?(.afterResultsBeforeCompact)
        try compactIfPossible()
    }

    static func applyChanges(_ db: Database, _ c: SyncResponse.Changes, session s: LocalSession) throws {
        for p in c.products {
            try db.execute(sql: """
                INSERT INTO product (id, name, base_unit, price_fen, needs_review, track_expiry, image_ver, archived)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, base_unit = excluded.base_unit, price_fen = excluded.price_fen,
                  needs_review = excluded.needs_review, track_expiry = excluded.track_expiry, image_ver = excluded.image_ver,
                  archived = excluded.archived
                """, arguments: [p.id.uuidString, p.name, p.baseUnit, p.priceFen, p.needsReview, p.trackExpiry, p.imageVer, p.archived])
            if let v = p.private, s.holdsPrivateData {
                try db.execute(sql: """
                    INSERT INTO product_private (product_id, stock_qty, stock_value_fen, last_cost_fen, cost_known, stock_ver,
                      low_at, expiry_warn_days, shelf_life_months) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(product_id) DO UPDATE SET stock_qty = excluded.stock_qty, stock_value_fen = excluded.stock_value_fen,
                      last_cost_fen = excluded.last_cost_fen, cost_known = excluded.cost_known, stock_ver = excluded.stock_ver,
                      low_at = excluded.low_at, expiry_warn_days = excluded.expiry_warn_days, shelf_life_months = excluded.shelf_life_months
                    """, arguments: [p.id.uuidString, v.stockQty, v.stockValueFen, v.lastCostFen, v.costKnown, v.stockVer,
                                     v.lowAt, v.expiryWarnDays, v.shelfLifeMonths])
            }
        }
        for b in c.barcodes {
            try db.execute(sql: """
                INSERT INTO barcode (barcode, product_id, pack_qty, unit_name, pack_price_fen) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(barcode) DO UPDATE SET product_id = excluded.product_id, pack_qty = excluded.pack_qty,
                  unit_name = excluded.unit_name, pack_price_fen = excluded.pack_price_fen
                """, arguments: [b.barcode, b.productId.uuidString, b.packQty, b.unitName, b.packQty > 1 ? b.packPriceFen : nil])
        }
        for x in c.removed {
            switch x.kind {
            case "barcode": try db.execute(sql: "DELETE FROM barcode WHERE barcode = ?", arguments: [x.rowId])
            case "product_alias": try db.execute(sql: "DELETE FROM product WHERE id = ?", arguments: [x.rowId.uppercased()])
            case "entry": try db.execute(sql: "DELETE FROM entry WHERE id = ?", arguments: [x.rowId.uppercased()])
            case "batch": try db.execute(sql: "DELETE FROM sale_batch WHERE id = ?", arguments: [x.rowId.uppercased()])
            case "lot": try db.execute(sql: "DELETE FROM lot WHERE id = ?", arguments: [x.rowId.uppercased()])
            default: continue
            }
        }
        // 批次头先于流水：冲突更新，不级联删已有明细；本机记的保留 op_id
        for b in c.batches {
            try db.execute(sql: """
                INSERT INTO sale_batch (id, device_id, list_total_fen, paid_total_fen, occurred_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, list_total_fen = excluded.list_total_fen,
                  paid_total_fen = excluded.paid_total_fen, occurred_at = excluded.occurred_at
                """, arguments: [b.id.uuidString, b.deviceId.uuidString, b.listTotalFen, b.paidTotalFen,
                                 try normalizeTimestamp(b.occurredAt)])
        }
        // 本机的临时冲销行（seq 为空）按 op_id 换成服务器的行（PR #34 已知偏差 1、§14 S09-2）
        let ops = Set(c.entries.compactMap(\.opId))
        for op in ops {
            try db.execute(sql: "DELETE FROM entry WHERE op_id = ? AND seq IS NULL AND reverses_entry_id IS NOT NULL",
                           arguments: [op.uuidString])
        }
        var labels: [UUID: String] = [:]
        for e in c.entries {
            if !s.holdsPrivateData && e.type != "sale" { continue }
            // 撤销指向的原行、或批次头不在本地（拉取窗口外，§14 S04-6）：不报错，批次挂空
            var batch = e.batchId?.uuidString
            if let b = batch, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sale_batch WHERE id = ?)", arguments: [b]) != true {
                batch = nil
            }
            var flags: String? = nil
            if e.flags?.lateBeforeCount == true { flags = #"{"late_before_count":true}"# }
            else if e.flags?.lateFromRevoked == true { flags = #"{"late_from_revoked":true}"# }
            let priv = s.holdsPrivateData
            try db.execute(sql: """
                INSERT INTO entry (id, seq, op_id, batch_id, type, reverses_entry_id, product_id, barcode, name_snapshot, unit_name,
                  pack_qty, pack_count, qty_delta, list_amount_fen, amount_fen, unit_cost_fen, cogs_fen, value_delta_fen,
                  cost_missing, expiry_date, device_id, occurred_at, voided_at, flags)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET seq = excluded.seq, op_id = excluded.op_id, batch_id = excluded.batch_id,
                  type = excluded.type, reverses_entry_id = excluded.reverses_entry_id, product_id = excluded.product_id,
                  barcode = excluded.barcode, name_snapshot = excluded.name_snapshot, unit_name = excluded.unit_name,
                  pack_qty = excluded.pack_qty, pack_count = excluded.pack_count, qty_delta = excluded.qty_delta,
                  list_amount_fen = excluded.list_amount_fen, amount_fen = excluded.amount_fen,
                  unit_cost_fen = excluded.unit_cost_fen, cogs_fen = excluded.cogs_fen, value_delta_fen = excluded.value_delta_fen,
                  cost_missing = excluded.cost_missing, expiry_date = excluded.expiry_date, device_id = excluded.device_id,
                  occurred_at = excluded.occurred_at, voided_at = excluded.voided_at, flags = excluded.flags
                """, arguments: [e.id.uuidString, e.seq, e.opId?.uuidString, batch, e.type, e.reversesEntryId?.uuidString,
                                 e.productId.uuidString, e.barcode, e.nameSnapshot, e.unitName, e.packQty, e.packCount,
                                 e.qtyDelta, e.listAmountFen, e.amountFen, priv ? e.unitCostFen : nil, priv ? e.cogsFen : nil,
                                 priv ? e.valueDeltaFen : nil, priv ? (e.costMissing ?? false) : false, e.expiryDate,
                                 e.deviceId.uuidString, try normalizeTimestamp(e.occurredAt),
                                 try e.voidedAt.map(normalizeTimestamp), flags])
            if let l = e.deviceLabel, e.deviceId != s.deviceId { labels[e.deviceId] = l }
        }
        for (id, label) in labels {
            try db.execute(sql: "INSERT INTO device_label (device_id, label) VALUES (?, ?) ON CONFLICT(device_id) DO UPDATE SET label = excluded.label",
                           arguments: [id.uuidString, label])
        }
        if s.holdsPrivateData {
            for l in c.lots {
                if l.closedAt != nil {
                    try db.execute(sql: "DELETE FROM lot WHERE id = ?", arguments: [l.id.uuidString]); continue
                }
                try db.execute(sql: """
                    INSERT INTO lot (id, product_id, expiry_date, qty_in, qty_left, snoozed_until, handle_ver) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET product_id = excluded.product_id, expiry_date = excluded.expiry_date,
                      qty_in = excluded.qty_in, qty_left = excluded.qty_left, snoozed_until = excluded.snoozed_until,
                      handle_ver = excluded.handle_ver
                    """, arguments: [l.id.uuidString, l.productId.uuidString, l.expiryDate, l.qtyIn, l.qtyLeft, l.snoozedUntil, l.handleVer])
            }
        }
    }

    /// 同步状态：待传笔数、最早一条待传的时间、上次同步时间（首页 / 设置 / 25a 的数来自这里，§14 S15-1）
    public func syncStatus() throws -> SyncStatus {
        try writer.read { db in
            let s = try Self.currentSession(db)
            let n = try s.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ?",
                                                 arguments: [$0.deviceId.uuidString, $0.storeId.uuidString]) ?? 0 } ?? 0
            let oldest = try s.flatMap { try String.fetchOne(db, sql: "SELECT MIN(occurred_at) FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ?",
                                                             arguments: [$0.deviceId.uuidString, $0.storeId.uuidString]) }
            func m(_ k: MetaKey) throws -> String? { try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [k.rawValue]) }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return SyncStatus(pendingCount: n, oldestPendingAt: oldest.flatMap(iso.date(from:)),
                              lastSyncAt: try m(.lastSyncAt).flatMap(iso.date(from:)), catalogDone: try m(.catalogDone) != nil,
                              deletePendingUntil: try m(.deletePendingUntil))
        }
    }
}

/// 同步引擎：推 outbox、拉两条流、每个响应一个事务提交。传输由调用方注入（App 里是 `APIClient`，测试里是假服务器）。
/// 全部方法同步阻塞，调用方在后台线程 / 后台任务里调（`beginSession` / `recordResults` / 压缩不许在主线程）。
public final class SyncEngine: Sendable {
    /// 发一次 `/v1/sync`：请求体 → (HTTP 状态, 响应体)
    public typealias Transport = @Sendable (Data) throws -> (Int, Data)
    public let db: LocalDB
    let transport: Transport
    let appBuild: Int

    public init(db: LocalDB, appBuild: Int, transport: @escaping Transport) {
        self.db = db; self.appBuild = appBuild; self.transport = transport
    }

    /// 同步一轮：先把 outbox 推完（注销期间不推），再把两条流拉到底。每页一个事务。
    /// `progress` 每页回调一次；`catalogDone` 为真时界面就能进首页开卖，ledger 继续。最多 `maxRounds` 次请求。
    @discardableResult
    public func sync(maxRounds: Int = 200, progress: (@Sendable (SyncProgress) -> Void)? = nil) throws -> SyncStatus {
        var products = 0
        for _ in 0..<maxRounds {
            let status = try db.syncStatus()
            let batch = status.deletePendingUntil == nil ? try db.nextPushBatch() : nil
            let body = try db.syncRequestBody(batch, appBuild: appBuild)
            let (code, data) = try transport(body)
            if code == 409, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = (obj["epoch"] as? String).flatMap(UUID.init(uuidString:)) {
                throw SyncError.epochMismatch(e)
            }
            guard code == 200 else { throw invalid("同步失败：HTTP \(code)") }
            let r = try SyncResponse.decode(data)
            if r.device.revoked { throw SyncError.revoked(discardOutbox: r.device.discardOutbox ?? false) }
            try db.applySyncResponse(r, sent: r.deletePendingUntil == nil ? batch : nil)
            products += r.changes.products.count
            progress?(SyncProgress(products: products, totalProducts: Int(r.totalProducts), catalogDone: !r.hasMore.catalog))
            let next = r.deletePendingUntil == nil ? try db.nextPushBatch() : nil; let morePush = next != nil
            if !r.hasMore.catalog && !r.hasMore.ledger && !morePush { return try db.syncStatus() }
        }
        return try db.syncStatus()
    }
}
