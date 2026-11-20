import Foundation
import GRDB

/// 本地流水的一行（§3.4 `entry`，界面「记的账」读它）
public struct LocalEntry: Hashable, Sendable {
    public let id: UUID
    public let opId: UUID?
    public let batchId: UUID?
    public let type: EntryType
    public let productId: UUID
    public let barcode: String?
    public let name: String
    public let unitName: String?
    public let packQty: Int64?
    public let packCount: Int64?
    public let qtyDelta: Int64
    public let listAmountFen: Fen
    public let amountFen: Fen
    public let deviceId: UUID
    public let occurredAt: String
    public let voidedAt: String?
}

extension LocalDB {
    /// 流水在本地保留几天（§3.4）：家用 35 天全店，收银员只留本机 2 天的卖出
    public static let familyLedgerDays = 35
    public static let cashierLedgerDays = 2

    /// 「收好钱了，记账」：写批次头 + 各行流水（按 §5.1 分摊后的实收）+ `sale_batch` op + 库存增减，**同一个事务**。
    /// 任何一步失败（包括崩溃注入点）整笔回滚，流水和 outbox 要么都在要么都不在。
    @discardableResult
    public func recordSale(_ basket: Basket, batchId: UUID = UUID(), opId: UUID = UUID(), at now: Date = Date()) throws -> SaleBatchPayload {
        let payload = try basket.makeSaleBatch(batchId: batchId)
        let alloc = try basket.allocation()
        let op = Op(id: opId, occurredAt: now, payload: payload)
        let ts = Op.formatTimestamp(now)
        var effects: [StockEffect] = []
        for l in basket.lines { effects.append(StockEffect(productId: l.productId, qtyDelta: -(try l.baseQty()))) }
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            try db.execute(sql: """
                INSERT INTO sale_batch (id, device_id, list_total_fen, paid_total_fen, occurred_at, op_id) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [batchId.uuidString, s.deviceId.uuidString, alloc.listTotalFen, payload.paidTotalFen.raw, ts,
                                 opId.uuidString])
            for (i, l) in basket.lines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO entry (id, op_id, batch_id, type, product_id, barcode, name_snapshot, unit_name, pack_qty, pack_count,
                      qty_delta, list_amount_fen, amount_fen, device_id, occurred_at)
                    VALUES (?, ?, ?, 'sale', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [l.id.uuidString, opId.uuidString, batchId.uuidString, l.productId.uuidString, l.barcode, l.name,
                                     l.unitName, l.packQty, l.packCount, -(try l.baseQty()), alloc.listFen[i], alloc.amountFen[i],
                                     s.deviceId.uuidString, ts])
            }
            try faultHook?(.afterEntriesBeforeOutbox)
            try Self.enqueue(db, op, session: s, effects: effects)
        }
        return payload
    }

    /// 记进货：写一行 `stock_in` 流水 + `stock_in` op + 库存增减，同一个事务。只有家用 / 审核能记。
    public func recordStockIn(_ payload: StockInPayload, name: String, unitName: String, opId: UUID = UUID(), at now: Date = Date()) throws {
        let op = Op(id: opId, occurredAt: now, payload: payload)
        let ts = Op.formatTimestamp(now)
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            try db.execute(sql: """
                INSERT INTO entry (id, op_id, type, product_id, barcode, name_snapshot, unit_name, pack_qty, pack_count, qty_delta,
                  list_amount_fen, amount_fen, unit_cost_fen, expiry_date, device_id, occurred_at)
                VALUES (?, ?, 'stock_in', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [payload.entryId.uuidString, opId.uuidString, payload.productId.uuidString, payload.barcode, name,
                                 unitName, payload.packQty, payload.packCount, payload.baseQty, payload.totalFen.raw,
                                 payload.totalFen.raw, payload.unitCostFen.raw, payload.expiryDate?.description,
                                 s.deviceId.uuidString, ts])
            try faultHook?(.afterEntriesBeforeOutbox)
            try Self.enqueue(db, op, session: s, effects: [StockEffect(productId: payload.productId, qtyDelta: payload.baseQty)])
        }
    }

    /// 本地流水，新的在前
    public func entries(limit: Int = 500) throws -> [LocalEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM entry ORDER BY occurred_at DESC, rowid DESC LIMIT ?", arguments: [limit]).map { r in
                guard let type = EntryType(rawValue: r["type"]) else { throw invalid("流水类型不认识") }
                return LocalEntry(id: try parseUUID(r["id"]), opId: try (r["op_id"] as String?).map(parseUUID),
                                  batchId: try (r["batch_id"] as String?).map(parseUUID), type: type,
                                  productId: try parseUUID(r["product_id"]), barcode: r["barcode"], name: r["name_snapshot"],
                                  unitName: r["unit_name"], packQty: r["pack_qty"], packCount: r["pack_count"],
                                  qtyDelta: r["qty_delta"], listAmountFen: Fen(r["list_amount_fen"]), amountFen: Fen(r["amount_fen"]),
                                  deviceId: try parseUUID(r["device_id"]), occurredAt: r["occurred_at"], voidedAt: r["voided_at"])
            }
        }
    }

    /// 修剪本地流水：家用留 35 天，收银员留本机 2 天（按上海日历天）。还绑着未确认 op 的流水不删。
    @discardableResult
    public func trimLedger(now: Date = Date()) throws -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return try writer.write { db in
            guard let s = try Self.currentSession(db) else { return 0 }
            let days = s.holdsPrivateData ? Self.familyLedgerDays : Self.cashierLedgerDays
            guard let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now)) else { return 0 }
            let store = s.storeId.uuidString
            let keepPending = "AND (op_id IS NULL OR op_id NOT IN (SELECT id FROM outbox WHERE status = 'pending' AND store_id = ?))"
            try db.execute(sql: "DELETE FROM entry WHERE occurred_at < ? \(keepPending)", arguments: [Op.formatTimestamp(cutoff), store])
            var n = db.changesCount
            if !s.holdsPrivateData {
                try db.execute(sql: "DELETE FROM entry WHERE device_id <> ? \(keepPending)", arguments: [s.deviceId.uuidString, store])
                n += db.changesCount
            }
            try db.execute(sql: "DELETE FROM sale_batch WHERE id NOT IN (SELECT batch_id FROM entry WHERE batch_id IS NOT NULL)")
            return n
        }
    }
}
