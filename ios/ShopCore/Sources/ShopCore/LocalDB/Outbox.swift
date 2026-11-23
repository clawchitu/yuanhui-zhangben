import Foundation
import GRDB

/// outbox 里的一条 op（§3.4）。归属（店、设备、令牌引用）写入后不可改。
public struct OutboxItem: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable { case pending, applied, rejected, held }
    public let seq: Int64
    public let id: UUID
    public let storeId: UUID
    public let deviceId: UUID
    public let tokenRef: String
    public let type: OpType
    /// `Op.encoded()` 的字节，重发时原样发
    public let opJSON: Data
    public let occurredAt: String
    public let status: Status
    public let rejectCode: String?
    public let confirmedAt: String?
}

/// 恢复队列里一个旧会话的未确认 op（§4.5）：用它自己的旧令牌单独上传，只推不拉。
public struct RecoveryGroup: Hashable, Sendable {
    public let storeId: UUID
    public let deviceId: UUID
    public let tokenRef: String
    public let ops: [OutboxItem]
}

/// 一条 op 对本地库存的增减（基本单位）
public struct StockEffect: Hashable, Sendable {
    public let productId: UUID
    public let qtyDelta: Int64
    public init(productId: UUID, qtyDelta: Int64) { self.productId = productId; self.qtyDelta = qtyDelta }
}

/// 一条 op 的服务器结果（`results[]` 一项）
public struct OpResult: Hashable, Sendable {
    public let id: UUID
    public let status: OutboxItem.Status
    public let code: String?
    /// 服务器返回的结果原文，留档
    public let raw: Data?
    public init(id: UUID, status: OutboxItem.Status, code: String? = nil, raw: Data? = nil) throws {
        guard status != .pending else { throw invalid("结果不能是 pending") }
        self.id = id; self.status = status; self.code = code; self.raw = raw
    }
}

extension LocalDB {
    /// 确认后保留几天（§4.6）
    public static let confirmedRetentionDays = 14

    /// 写一条 op 进 outbox，绑定当前会话的店、设备和令牌。只在已有的写事务里调用。
    static func enqueue(_ db: Database, _ op: Op, session s: LocalSession, effects: [StockEffect]) throws {
        try db.execute(sql: """
            INSERT INTO outbox (id, store_id, device_id, token_ref, type, op_json, occurred_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [op.id.uuidString, s.storeId.uuidString, s.deviceId.uuidString, s.tokenRef, op.type.rawValue,
                             op.encoded(), Op.formatTimestamp(op.occurredAt)])
        for e in effects where e.qtyDelta != 0 {
            try db.execute(sql: "INSERT INTO outbox_effect (store_id, op_id, product_id, qty_delta) VALUES (?, ?, ?, ?)",
                           arguments: [s.storeId.uuidString, op.id.uuidString, e.productId.uuidString, e.qtyDelta])
        }
    }

    /// 只写 op、不写本地流水（例如登记商品、改商品、整件码）。有权限检查；只能联网提交的 op 不进队列（§5.6）。
    public func enqueue(_ op: Op, effects: [StockEffect] = []) throws {
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            try Self.enqueue(db, op, session: s, effects: effects)
        }
    }

    static func checkCanQueue(_ db: Database, _ op: Op, session s: LocalSession) throws {
        guard !op.type.onlineOnly else { throw invalid("\(op.type.rawValue) 只能联网提交，不进离线队列（§5.6）") }
        let quick = (op.payload as? ProductUpsertPayload)?.quick ?? false
        guard Capabilities(role: s.role).canSend(op.type, quick: quick) else {
            throw invalid("这台手机不能记 \(op.type.rawValue)")
        }
        if let o = op.payload as? OpeningPayload { try checkOfflineOpening(db, o, store: s.storeId) }
    }

    /// 期初只有「新商品登记第二步」能离线排队（§5.6 第 1、3 条）：不带 `base_ver`；本店 outbox 里有这个商品的
    /// 登记（`product_upsert`，没被拒）；本地基线没有过库存变动（`stock_ver` 为 0 或还没有基线）；本店 outbox 里
    /// 也没有别的、没被拒的**库存类 op**（期初、进货、卖货、盘点、补全、处理快过期）涉及这个商品。否则就是已有商品，
    /// 排空 outbox 后在线提交。
    ///
    /// 看的是 op 本身（类型 + 商品），不看 `outbox_effect`：调用方可以不传增减，数量为 0 的增减也不保存，
    /// 只看增减会让第二条无版本期初混进队列（Codex 第二轮 P2）。
    static func checkOfflineOpening(_ db: Database, _ o: OpeningPayload, store: UUID) throws {
        let online = invalid("已有商品的期初只能联网提交，不进离线队列（§5.6）")
        guard o.baseVer == nil else { throw online }
        let upserts = try Data.fetchAll(db, sql: """
            SELECT op_json FROM outbox WHERE store_id = ? AND type = 'product_upsert' AND status <> 'rejected'
            """, arguments: [store.uuidString])
        guard upserts.contains(where: { Self.payloadProductIds($0).contains(o.productId) }) else { throw online }
        let ver = try Int64.fetchOne(db, sql: "SELECT stock_ver FROM product_private WHERE product_id = ?",
                                     arguments: [o.productId.uuidString])
        guard (ver ?? 0) == 0 else { throw online }
        // 本地有这个商品的保质期批次 = 进过货或记过期初
        let hasLot = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM lot WHERE product_id = ?)",
                                       arguments: [o.productId.uuidString]) ?? false
        guard !hasLot else { throw online }
        let types = Self.stockOpTypes.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let history = try Data.fetchAll(db, sql: """
            SELECT op_json FROM outbox WHERE store_id = ? AND status <> 'rejected' AND type IN (\(types))
            """, arguments: [store.uuidString])
        guard !history.contains(where: { Self.payloadProductIds($0).contains(o.productId) }) else { throw online }
    }

    /// 带商品 id、会动这个商品库存的 op 类型（§4.3）。`void` 撤的那条流水本身已经算在里面；`expiry_dispose`
    /// 只带批次 id，批次的前提是进过货或记过期初，已由上面的批次检查和这里的 `stock_in` / `opening` 挡住
    static let stockOpTypes: [OpType] = [.opening, .stockIn, .saleBatch, .count, .productReviewComplete]

    /// op 字节里涉及的商品：`payload.product_id`，以及 `payload.lines[].product_id`（卖货）
    static func payloadProductIds(_ data: Data) -> Set<UUID> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return [] }
        var ids: [Any?] = [payload["product_id"]]
        for line in payload["lines"] as? [[String: Any]] ?? [] { ids.append(line["product_id"]) }
        return Set(ids.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) })
    }

    /// 当前会话待传的 op，按产生顺序（重启后顺序不变）
    public func pendingOps(limit: Int = 200) throws -> [OutboxItem] {
        try writer.read { db in
            guard let s = try Self.currentSession(db) else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ? ORDER BY seq LIMIT ?
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString, limit]).map(Self.outboxFrom)
        }
    }

    /// 全部 outbox（含已确认、含旧会话），按 seq
    public func allOutbox() throws -> [OutboxItem] {
        try writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY seq").map(Self.outboxFrom) }
    }

    /// 恢复队列：不属于当前会话的未确认 op，按旧会话分组，组内按 seq（§4.5）
    public func recoveryQueue() throws -> [RecoveryGroup] {
        try writer.read { db in
            let cur = try Self.currentSession(db)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM outbox WHERE status = 'pending' ORDER BY seq").map(Self.outboxFrom)
            var order: [UUID] = []
            var groups: [UUID: [OutboxItem]] = [:]
            for o in rows where !(o.deviceId == cur?.deviceId && o.storeId == cur?.storeId) {
                if groups[o.deviceId] == nil { order.append(o.deviceId) }
                groups[o.deviceId, default: []].append(o)
            }
            return order.map { d in
                let ops = groups[d]!
                return RecoveryGroup(storeId: ops[0].storeId, deviceId: d, tokenRef: ops[0].tokenRef, ops: ops)
            }
        }
    }

    /// 已退役、恢复队列已传完的旧会话的令牌引用：调用方删掉钥匙串里的旧令牌后调 `forgetSession`（§4.5）
    public func retiredSessionsWithoutPendingOps() throws -> [LocalSession] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM session s WHERE s.is_current = 0
                AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.device_id = s.device_id AND o.status = 'pending')
                """).map(Self.sessionFrom)
        }
    }

    public func forgetSession(deviceId: UUID) throws {
        try writer.write { db in
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE device_id = ? AND status = 'pending'",
                                           arguments: [deviceId.uuidString]) ?? 0
            guard pending == 0 else { throw invalid("这个会话还有 \(pending) 笔没传，不能删") }
            try db.execute(sql: "DELETE FROM session WHERE device_id = ? AND is_current = 0", arguments: [deviceId.uuidString])
        }
    }

    /// 记下服务器对每个 op 的结果（applied / rejected / held）。被拒的 op 对库存的临时增减自然消失。
    /// 只改结果列；归属列由触发器保护。op id 只在店内唯一，所以结果要带店（发这批 op 的会话的店）。
    ///
    /// 当前会话是收银员时，旧会话的 op 一拿到结果就删，不进 14 天保留，删完压缩（§14 S13-1）；
    /// 上次没压缩完的也在这里补做（被读事务挡住不抛错，标记保留到下次）。
    public func recordResults(_ results: [OpResult], storeId: UUID, at now: Date = Date()) throws {
        let ts = Op.formatTimestamp(now)
        try writer.write { db in
            for r in results {
                try db.execute(sql: """
                    UPDATE outbox SET status = ?, reject_code = ?, result_json = ?, confirmed_at = ?
                    WHERE store_id = ? AND id = ? AND status = 'pending'
                    """, arguments: [r.status.rawValue, r.code, r.raw, ts, storeId.uuidString, r.id.uuidString])
            }
            if let cur = try Self.currentSession(db) { try Self.deleteConfirmedForeignOps(db, current: cur) }
        }
        try faultHook?(.afterResultsBeforeCompact)
        try compactIfPossible()
    }

    /// 删掉确认超过 14 天的 op（§4.6）。未确认的永远不删。
    /// 还在分页对账的也不删，不按时间一刀切（PR #36 Codex 增量复审必须修）：
    /// - 还有 `effect_hold`：新库存基线还在商品流后页，删了会级联带走 hold，库存错回；商品流拉到底或新基线到了才放
    /// - 已确认的 void 还留着本机临时冲销行：流水还没拉到底，拉到底那一步按 outbox 里的 applied 认残留行，删了会多算一次冲销
    @discardableResult
    public func purgeConfirmed(now: Date = Date()) throws -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let cutoff = cal.date(byAdding: .day, value: -Self.confirmedRetentionDays, to: now) else { return 0 }
        return try writer.write { db in
            try db.execute(sql: """
                DELETE FROM outbox WHERE status <> 'pending' AND confirmed_at < ?
                  AND NOT EXISTS (SELECT 1 FROM effect_hold h WHERE h.store_id = outbox.store_id AND h.op_id = outbox.id)
                  AND NOT (status = 'applied' AND EXISTS (SELECT 1 FROM entry e
                           WHERE e.op_id = outbox.id AND e.seq IS NULL AND e.reverses_entry_id IS NOT NULL))
                """, arguments: [Op.formatTimestamp(cutoff)])
            return db.changesCount
        }
    }

    /// 演示小店重置（`discard_outbox = true`，§4.5）：丢弃这家店的 outbox 和恢复队列，不重放。
    public func discardOutbox(storeId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE store_id = ?", arguments: [storeId.uuidString])
            try db.execute(sql: "DELETE FROM session WHERE store_id = ? AND is_current = 0", arguments: [storeId.uuidString])
        }
    }

    static func outboxFrom(_ r: Row) throws -> OutboxItem {
        guard let type = OpType(rawValue: r["type"]), let status = OutboxItem.Status(rawValue: r["status"])
        else { throw invalid("outbox 里的类型或状态不认识") }
        return OutboxItem(seq: r["seq"], id: try parseUUID(r["id"]), storeId: try parseUUID(r["store_id"]),
                          deviceId: try parseUUID(r["device_id"]), tokenRef: r["token_ref"], type: type, opJSON: r["op_json"],
                          occurredAt: r["occurred_at"], status: status, rejectCode: r["reject_code"], confirmedAt: r["confirmed_at"])
    }
}
