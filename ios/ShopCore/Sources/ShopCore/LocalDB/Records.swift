import Foundation
import GRDB

// S20 记的账与撤销（07a / 07b / 07c / 08）。
//
// 撤销的记法照 §3.3（规则）：原流水打 `voided_at`、**不删**；另追加一行冲销流水（类型相同、`reverses_entry_id` 指向原行、
// 数量和金额取反、`unit_cost_fen` 照抄、`pack_qty` 照抄、`pack_count` 取反、`occurred_at` = 撤销时间），
// 同一个事务里写一条 `void` op 进 outbox，它对临时库存的增减 = −原行的 `qty_delta`。
//
// 手机写的冲销行只是**本机的临时样子**（`seq` 为空、`op_id` = 这次撤销的 op）：服务器在应用 `void` 时自己派生冲销行
// 和跟着来的 `cost_fix` 冲销、`cost_adjust`（§14 S09-2，手机不许推算服务器的 id），S22a 拉到服务器那几行后用它们替换
// 本机这几行（按 `op_id` 删 `seq` 为空的行）。成本、货值只在服务器算（§1）；冲销行的 `cogs_fen`、`value_delta_fen`
// 只在原行本来就有（从服务器拉下来的）时取反，本机记的卖出原行这两列为空，冲销行也为空。

/// 撤哪些：整笔卖出，或一行（§4.3 `void.target`）
public typealias VoidTarget = VoidPayload.Target

/// 撤销的结果。`alreadyVoided`：要撤的都撤过了，第二次什么也不做（§4.4「撤销两次」），不写 op。
public enum VoidOutcome: Hashable, Sendable {
    case voided(opId: UUID, lines: Int)
    case alreadyVoided
}

/// 一行流水的数量和金额（冲销规则的输入输出；与 `cost.json` 向量的 `entries[]` 同字段）
public struct EntryAmounts: Hashable, Sendable {
    public var type: EntryType
    public var qtyDelta: Int64
    public var amountFen: Int64
    public var listAmountFen: Int64
    public var cogsFen: Int64?
    public var valueDeltaFen: Int64?
    public var costMissing: Bool
    public var unitCostFen: Int64?
    public var packQty: Int64?
    public var packCount: Int64?

    public init(type: EntryType, qtyDelta: Int64, amountFen: Int64, listAmountFen: Int64, cogsFen: Int64? = nil,
                valueDeltaFen: Int64? = nil, costMissing: Bool = false, unitCostFen: Int64? = nil, packQty: Int64? = nil,
                packCount: Int64? = nil) {
        self.type = type; self.qtyDelta = qtyDelta; self.amountFen = amountFen; self.listAmountFen = listAmountFen
        self.cogsFen = cogsFen; self.valueDeltaFen = valueDeltaFen; self.costMissing = costMissing
        self.unitCostFen = unitCostFen; self.packQty = packQty; self.packCount = packCount
    }

    /// 能直接撤的类型（与服务器 `ledger/cost.ts` 的 `VOIDABLE` 一致）。`cost_adjust`、`cost_fix` 是自动生成的，不能撤
    public static let voidable: Set<EntryType> = [.sale, .stockIn, .opening, .count, .expireLoss, .supplierReturn]

    /// 冲销行（§3.3 撤销的记法）：数量、金额取反；单价、换算照抄；件数随数量取反。溢出拒 invalid。
    public func reversal() throws -> EntryAmounts {
        guard Self.voidable.contains(type) else { throw invalid("\(type.rawValue) 是自动生成的流水，不能撤销") }
        func neg(_ v: Int64) throws -> Int64 {
            let (r, o) = Int64(0).subtractingReportingOverflow(v)
            guard !o else { throw invalid("金额或数量超出范围") }
            return r
        }
        return EntryAmounts(type: type, qtyDelta: try neg(qtyDelta), amountFen: try neg(amountFen),
                            listAmountFen: try neg(listAmountFen), cogsFen: try cogsFen.map(neg),
                            valueDeltaFen: try valueDeltaFen.map(neg), costMissing: costMissing, unitCostFen: unitCostFen,
                            packQty: packQty, packCount: try packCount.map(neg))
    }
}

/// 07a / 07b 卡片里的一行
public struct RecordLine: Hashable, Sendable, Identifiable {
    public let id: UUID            // 原流水 id（「只撤这样」撤的就是它）
    public let productId: UUID
    public let name: String
    public let unitName: String?
    public let packQty: Int64?
    public let packCount: Int64?
    public let qtyDelta: Int64
    public let listAmountFen: Int64
    /// 摊后实收（08「退 ¥24.76」）
    public let amountFen: Int64
    public let valueDeltaFen: Int64?
    public let voided: Bool

    /// 「×4」或「5 箱」
    public var quantityText: String {
        let n = packCount ?? abs(qtyDelta)
        if let q = packQty, q > 1, let u = unitName { return "\(n) \(u)" }
        return "×\(n)"
    }
}

/// 07a / 07b 的一张卡 = 一次记账（一个 op，§14 S07-1）
public struct RecordCard: Hashable, Sendable, Identifiable {
    public let id: String          // op id（没有就用第一行的流水 id）
    public let opId: UUID?
    public let type: EntryType
    public let occurredAt: String
    public let deviceId: UUID
    /// 手机名（不是人名，S20 验收）
    public let deviceLabel: String
    public let batchId: UUID?
    public let listTotalFen: Int64?
    public let paidTotalFen: Int64?
    public let lines: [RecordLine]

    public var day: String { String(occurredAt.prefix(10)) }
    /// 「19:32」
    public var time: String { String(occurredAt.dropFirst(11).prefix(5)) }
    public var allVoided: Bool { lines.allSatisfy(\.voided) }
    public var openLines: [RecordLine] { lines.filter { !$0.voided } }

    /// 卡片上的大数：卖出 = 实收；进货 = 总价；过期扔掉 / 退货 = 按进价算的货值（有才显示）；盘点、期初不显示
    public var amountFen: Int64? {
        switch type {
        case .sale: return paidTotalFen ?? lines.reduce(0) { $0 + $1.amountFen }
        case .stockIn: return lines.reduce(0) { $0 + $1.amountFen }
        case .expireLoss, .supplierReturn:
            let v = lines.compactMap(\.valueDeltaFen)
            return v.count == lines.count ? -v.reduce(0, +) : nil
        default: return nil
        }
    }

    /// 抹了多少（正数 = 少收，负数 = 多收）；没改价为 0
    public var discountFen: Int64 {
        guard let l = listTotalFen, let p = paidTotalFen else { return 0 }
        return l - p
    }

    public var kindText: String {
        switch type {
        case .sale: "卖出"
        case .stockIn: "进货"
        case .opening: "期初"
        case .count: "盘点"
        case .expireLoss: "过期扔掉"
        case .supplierReturn: "退给供货商"
        case .costAdjust: "调整"
        case .costFix: "补记进价"
        }
    }
}

/// 07c 的一行：某一天记了几笔、卖了多少（实收，含当天的撤销）
public struct LedgerDay: Hashable, Sendable, Identifiable {
    public let day: CalendarDate
    public let count: Int
    public let saleFen: Int64
    public var id: String { day.description }
}

/// 从服务器拉下来的一行流水（S22a 的拉取接这个；夹具也用它装「别的手机记的」「已同步的」账）
public struct PulledEntry: Hashable, Sendable {
    public var id: UUID
    public var seq: Int64
    public var opId: UUID
    public var batchId: UUID?
    public var reversesEntryId: UUID?
    public var productId: UUID
    public var name: String
    public var unitName: String?
    public var amounts: EntryAmounts
    public var deviceId: UUID
    public var occurredAt: Date
    public var voidedAt: Date?
    /// `flags` 原文（JSON），例如 `{"late_before_count":true}`
    public var flags: String?

    public init(id: UUID = UUID(), seq: Int64, opId: UUID, batchId: UUID? = nil, reversesEntryId: UUID? = nil, productId: UUID,
                name: String, unitName: String? = nil, amounts: EntryAmounts, deviceId: UUID, occurredAt: Date,
                voidedAt: Date? = nil, flags: String? = nil) {
        self.id = id; self.seq = seq; self.opId = opId; self.batchId = batchId; self.reversesEntryId = reversesEntryId
        self.productId = productId; self.name = name; self.unitName = unitName; self.amounts = amounts
        self.deviceId = deviceId; self.occurredAt = occurredAt; self.voidedAt = voidedAt; self.flags = flags
    }
}

public struct PulledBatch: Hashable, Sendable {
    public var id: UUID
    public var deviceId: UUID
    public var listTotalFen: Int64
    public var paidTotalFen: Int64
    public var occurredAt: Date
    public init(id: UUID, deviceId: UUID, listTotalFen: Int64, paidTotalFen: Int64, occurredAt: Date) {
        self.id = id; self.deviceId = deviceId; self.listTotalFen = listTotalFen; self.paidTotalFen = paidTotalFen
        self.occurredAt = occurredAt
    }
}

extension LocalDB {
    /// 上海日历日
    public static func shanghaiDay(_ d: Date) -> CalendarDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        // 日期分量一定合法
        return try! CalendarDate(year: c.year!, month: c.month!, day: c.day!)
    }

    static func dayBounds(_ day: CalendarDate) -> (String, String) {
        ("\(day.description)T00:00:00.000+08:00", "\(day.description)T23:59:59.999+08:00")
    }

    /// 别的手机的名字（S22a 由拉取的设备列表填；夹具直接填）。名字只用手机名，不用人名
    public func setDeviceLabels(_ labels: [UUID: String]) throws {
        try writer.write { db in
            for (id, label) in labels {
                try db.execute(sql: "INSERT INTO device_label (device_id, label) VALUES (?, ?) ON CONFLICT(device_id) DO UPDATE SET label = excluded.label",
                               arguments: [id.uuidString, label])
            }
        }
    }

    /// 写入拉下来的流水和批次头（同 id 覆盖）
    public func applyPulledLedger(batches: [PulledBatch], entries: [PulledEntry]) throws {
        try writer.write { db in
            for b in batches {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO sale_batch (id, device_id, list_total_fen, paid_total_fen, occurred_at) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [b.id.uuidString, b.deviceId.uuidString, b.listTotalFen, b.paidTotalFen,
                                     Op.formatTimestamp(b.occurredAt)])
            }
            for e in entries {
                let a = e.amounts
                try db.execute(sql: """
                    INSERT OR REPLACE INTO entry (id, seq, op_id, batch_id, type, reverses_entry_id, product_id, name_snapshot, unit_name,
                      pack_qty, pack_count, qty_delta, list_amount_fen, amount_fen, unit_cost_fen, cogs_fen, value_delta_fen,
                      cost_missing, device_id, occurred_at, voided_at, flags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id.uuidString, e.seq, e.opId.uuidString, e.batchId?.uuidString, a.type.rawValue,
                                     e.reversesEntryId?.uuidString, e.productId.uuidString, e.name, e.unitName, a.packQty,
                                     a.packCount, a.qtyDelta, a.listAmountFen, a.amountFen, a.unitCostFen, a.cogsFen,
                                     a.valueDeltaFen, a.costMissing, e.deviceId.uuidString, Op.formatTimestamp(e.occurredAt),
                                     e.voidedAt.map(Op.formatTimestamp), e.flags])
            }
        }
    }

    /// 卡片的取数条件：原行（非冲销），不是自动生成的 `cost_fix` / `cost_adjust`，不是迟到补偿行；
    /// 收银员只看本机的卖出（§3.4、§6.2 07b）
    static func cardFilter(_ s: LocalSession) -> (String, [DatabaseValueConvertible]) {
        var sql = """
            reverses_entry_id IS NULL AND type NOT IN ('cost_fix', 'cost_adjust')
            AND (flags IS NULL OR COALESCE(json_extract(flags, '$.late_before_count'), 0) = 0)
            """
        var args: [DatabaseValueConvertible] = []
        if !s.holdsPrivateData {
            sql += " AND type = 'sale' AND device_id = ?"
            args.append(s.deviceId.uuidString)
        }
        return (sql, args)
    }

    /// 某一天（上海）的卡片，新的在前
    public func recordCards(on day: CalendarDate) throws -> [RecordCard] {
        let (from, to) = Self.dayBounds(day)
        return try writer.read { db in
            guard let s = try Self.currentSession(db) else { return [] }
            let (f, a) = Self.cardFilter(s)
            return try Self.cards(db, s, where: "\(f) AND occurred_at BETWEEN ? AND ?", args: a + [from, to])
        }
    }

    /// 首页「刚记的」：最近一张还没全撤的卡（本地有的范围内）
    public func lastRecord() throws -> RecordCard? {
        try writer.read { db in
            guard let s = try Self.currentSession(db) else { return nil }
            let (f, a) = Self.cardFilter(s)
            return try Self.cards(db, s, where: "\(f) AND voided_at IS NULL", args: a, limitRows: 200).first
        }
    }

    static func cards(_ db: Database, _ s: LocalSession, where cond: String, args: [DatabaseValueConvertible],
                      limitRows: Int = 5000) throws -> [RecordCard] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, b.list_total_fen AS b_list, b.paid_total_fen AS b_paid, d.label AS d_label
            FROM (SELECT *, rowid AS rid FROM entry WHERE \(cond) ORDER BY occurred_at DESC, rowid DESC LIMIT ?) e
            LEFT JOIN sale_batch b ON b.id = e.batch_id LEFT JOIN device_label d ON d.device_id = e.device_id
            ORDER BY e.occurred_at DESC, e.rid DESC
            """, arguments: StatementArguments(args + [limitRows]))
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for r in rows {
            let key: String = r["op_id"] ?? r["id"]
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return try order.map { key in
            let rs = groups[key]!.sorted { ($0["rid"] as Int64) < ($1["rid"] as Int64) }
            let first = rs[0]
            guard let type = EntryType(rawValue: first["type"]) else { throw invalid("流水类型不认识") }
            let device = try parseUUID(first["device_id"])
            let label: String = device == s.deviceId ? s.deviceLabel : (first["d_label"] ?? "别的手机")
            let lines = try rs.map { r in
                RecordLine(id: try parseUUID(r["id"]), productId: try parseUUID(r["product_id"]), name: r["name_snapshot"],
                           unitName: r["unit_name"], packQty: r["pack_qty"], packCount: r["pack_count"], qtyDelta: r["qty_delta"],
                           listAmountFen: r["list_amount_fen"], amountFen: r["amount_fen"], valueDeltaFen: r["value_delta_fen"],
                           voided: (r["voided_at"] as String?) != nil)
            }
            return RecordCard(id: key, opId: try (first["op_id"] as String?).map(parseUUID), type: type,
                              occurredAt: first["occurred_at"], deviceId: device, deviceLabel: label,
                              batchId: try (first["batch_id"] as String?).map(parseUUID), listTotalFen: first["b_list"],
                              paidTotalFen: first["b_paid"], lines: lines)
        }
    }

    /// 07c「更早」：前天往前、本地有的天（家用本地 35 天，§3.4），每天一行，只列笔数 > 0 或金额非零的日子（§14 S07-7）。
    /// 笔数 = 当天原行的不同 op 个数（§14 S07-1）；金额 = 当天卖出的实收合计（含当天的冲销行，撤销算在撤销那天）。
    public func ledgerDays(now: Date = Date()) throws -> [LedgerDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = cal.startOfDay(for: now)
        guard let oldest = cal.date(byAdding: .day, value: -(Self.familyLedgerDays - 1), to: today),
              let beforeYesterday = cal.date(byAdding: .day, value: -2, to: today) else { return [] }
        let from = Self.dayBounds(Self.shanghaiDay(oldest)).0
        let to = Self.dayBounds(Self.shanghaiDay(beforeYesterday)).1
        return try writer.read { db in
            guard let s = try Self.currentSession(db), s.holdsPrivateData else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT substr(occurred_at, 1, 10) AS d,
                  COUNT(DISTINCT CASE WHEN reverses_entry_id IS NULL AND type <> 'cost_adjust' THEN COALESCE(op_id, id) END) AS n,
                  COALESCE(SUM(CASE WHEN type = 'sale' THEN amount_fen ELSE 0 END), 0) AS fen
                FROM entry WHERE occurred_at BETWEEN ? AND ?
                GROUP BY d ORDER BY d DESC
                """, arguments: [from, to])
            return try rows.compactMap { r in
                let n: Int = r["n"], fen: Int64 = r["fen"]
                guard n > 0 || fen != 0 else { return nil }
                return LedgerDay(day: try CalendarDate(r["d"] as String), count: n, saleFen: fen)
            }
        }
    }

    /// 这张卡能不能撤：家用 / 审核 = 有没撤完的行；收银员另要本机记的、今天（上海）的卖出（§6 第③条，最终以服务器收到那天为准）
    public func canVoid(_ card: RecordCard, now: Date = Date()) throws -> Bool {
        guard let s = try currentSession(), Capabilities(role: s.role).canSend(.void),
              !card.openLines.isEmpty, EntryAmounts.voidable.contains(card.type) else { return false }
        if s.holdsPrivateData { return true }
        return card.type == .sale && card.deviceId == s.deviceId && card.day == Self.shanghaiDay(now).description
    }

    /// 撤销（08「整笔都撤销」/「只撤这样」）：原行打 `voided_at`，追加冲销行，写 `void` op 和库存增减，同一个事务。
    @discardableResult
    public func void(_ target: VoidTarget, opId: UUID = UUID(), at now: Date = Date()) throws -> VoidOutcome {
        let op = Op(id: opId, occurredAt: now, payload: VoidPayload(target: target))
        let ts = Op.formatTimestamp(now)
        let today = Self.shanghaiDay(now).description
        return try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            var rows: [Row]
            switch target {
            case .batch(let id):
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sale_batch WHERE id = ?)", arguments: [id.uuidString]) == true
                else { throw invalid("要撤销的这笔卖出不在本机") }
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM entry WHERE batch_id = ? AND type = 'sale' AND reverses_entry_id IS NULL ORDER BY rowid
                    """, arguments: [id.uuidString])
            case .entry(let id):
                guard let r = try Row.fetchOne(db, sql: "SELECT * FROM entry WHERE id = ?", arguments: [id.uuidString])
                else { throw invalid("要撤销的流水不在本机") }
                guard (r["reverses_entry_id"] as String?) == nil, let t = EntryType(rawValue: r["type"]),
                      EntryAmounts.voidable.contains(t)
                else { throw invalid("冲销行和自动生成的流水不能撤销") }
                rows = [r]
            }
            if !s.holdsPrivateData {
                // 收银员：只能本机的、今天的卖出（服务器按收到那天再判一次）
                for r in rows {
                    guard (r["type"] as String) == "sale", (r["device_id"] as String) == s.deviceId.uuidString,
                          (r["occurred_at"] as String).hasPrefix(today)
                    else { throw invalid("只能撤这台手机今天记的卖出，昨天的找家里人") }
                }
            }
            rows = rows.filter { ($0["voided_at"] as String?) == nil }
            guard !rows.isEmpty else { return .alreadyVoided }
            var effects: [StockEffect] = []
            for r in rows {
                guard let t = EntryType(rawValue: r["type"]) else { throw invalid("流水类型不认识") }
                let orig = EntryAmounts(type: t, qtyDelta: r["qty_delta"], amountFen: r["amount_fen"],
                                        listAmountFen: r["list_amount_fen"], cogsFen: r["cogs_fen"],
                                        valueDeltaFen: r["value_delta_fen"], costMissing: r["cost_missing"],
                                        unitCostFen: r["unit_cost_fen"], packQty: r["pack_qty"], packCount: r["pack_count"])
                let rev = try orig.reversal()
                let origId: String = r["id"]
                try db.execute(sql: """
                    INSERT INTO entry (id, op_id, batch_id, type, reverses_entry_id, product_id, barcode, name_snapshot, unit_name,
                      pack_qty, pack_count, qty_delta, list_amount_fen, amount_fen, unit_cost_fen, cogs_fen, value_delta_fen,
                      cost_missing, expiry_date, device_id, occurred_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, opId.uuidString, r["batch_id"] as String?, t.rawValue, origId,
                                     r["product_id"] as String, r["barcode"] as String?, r["name_snapshot"] as String,
                                     r["unit_name"] as String?, rev.packQty, rev.packCount, rev.qtyDelta, rev.listAmountFen,
                                     rev.amountFen, rev.unitCostFen, rev.cogsFen, rev.valueDeltaFen, rev.costMissing,
                                     r["expiry_date"] as String?, s.deviceId.uuidString, ts])
                try db.execute(sql: "UPDATE entry SET voided_at = ?, voided_by_device = ? WHERE id = ?",
                               arguments: [ts, s.deviceId.uuidString, origId])
                effects.append(StockEffect(productId: try parseUUID(r["product_id"]), qtyDelta: rev.qtyDelta))
            }
            try faultHook?(.afterEntriesBeforeOutbox)
            try Self.enqueue(db, op, session: s, effects: effects)
            return .voided(opId: opId, lines: rows.count)
        }
    }
}
