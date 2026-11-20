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
            try db.execute(sql: "INSERT INTO outbox_effect (op_id, product_id, qty_delta) VALUES (?, ?, ?)",
                           arguments: [op.id.uuidString, e.productId.uuidString, e.qtyDelta])
        }
    }

    /// 只写 op、不写本地流水（例如登记商品、改商品、整件码）。有权限检查；只能联网提交的 op 不进队列（§5.6）。
    public func enqueue(_ op: Op, effects: [StockEffect] = []) throws {
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(op, session: s)
            try Self.enqueue(db, op, session: s, effects: effects)
        }
    }

    static func checkCanQueue(_ op: Op, session s: LocalSession) throws {
        guard !op.type.onlineOnly else { throw invalid("\(op.type.rawValue) 只能联网提交，不进离线队列（§5.6）") }
        let quick = (op.payload as? ProductUpsertPayload)?.quick ?? false
        guard Capabilities(role: s.role).canSend(op.type, quick: quick) else {
            throw invalid("这台手机不能记 \(op.type.rawValue)")
        }
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
    /// 只改结果列；归属列由触发器保护。
    public func recordResults(_ results: [OpResult], at now: Date = Date()) throws {
        let ts = Op.formatTimestamp(now)
        try writer.write { db in
            for r in results {
                try db.execute(sql: """
                    UPDATE outbox SET status = ?, reject_code = ?, result_json = ?, confirmed_at = ?
                    WHERE id = ? AND status = 'pending'
                    """, arguments: [r.status.rawValue, r.code, r.raw, ts, r.id.uuidString])
            }
        }
    }

    /// 删掉确认超过 14 天的 op（§4.6）。未确认的永远不删。
    @discardableResult
    public func purgeConfirmed(now: Date = Date()) throws -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let cutoff = cal.date(byAdding: .day, value: -Self.confirmedRetentionDays, to: now) else { return 0 }
        return try writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE status <> 'pending' AND confirmed_at < ?",
                           arguments: [Op.formatTimestamp(cutoff)])
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
