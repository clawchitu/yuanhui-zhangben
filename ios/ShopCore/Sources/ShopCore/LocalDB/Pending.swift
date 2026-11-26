import Foundation
import GRDB

/// 「待传」面板的一行（只读展示）：本机还没得到服务器结果的一笔。不带任何内部 id 给界面显示。
public struct PendingEntry: Hashable, Sendable, Identifiable {
    /// 列表的稳定标识（outbox 的 seq），只给 SwiftUI 用，不显示
    public let id: Int64
    public let occurredAt: Date
    public let type: OpType
    /// 涉及的商品名（卖出可能多样，按行顺序）；撤销等不带商品的为空
    public let names: [String]
    /// 数量：卖出 = 一共几件；进货 = 几件（箱 / 条 / 瓶）；期初 = 几个基本单位；整件码 = 一件几个
    public let quantity: Int64?
    public let unitName: String?
    /// 金额（分）：卖出 = 实收；进货 = 进货总价；登记商品 / 改价 = 卖价
    public let amountFen: Int64?
    /// 改商品只改了卖价（显示成「改价」）
    public let priceOnlyEdit: Bool

    public init(id: Int64, occurredAt: Date, type: OpType, names: [String], quantity: Int64?, unitName: String?,
                amountFen: Int64?, priceOnlyEdit: Bool) {
        self.id = id
        self.occurredAt = occurredAt
        self.type = type
        self.names = names
        self.quantity = quantity
        self.unitName = unitName
        self.amountFen = amountFen
        self.priceOnlyEdit = priceOnlyEdit
    }

    /// 类型的人话
    public var kindText: String {
        switch type {
        case .saleBatch: "卖出"
        case .void: "撤销"
        case .productUpsert: "登记商品"
        case .productEdit: priceOnlyEdit ? "改价" : "改商品"
        case .barcodeLink: "挂整件码"
        case .barcodeUnlink: "取消整件码"
        case .stockIn: "进货"
        case .opening: "填库存"
        case .productReviewComplete: "补全商品"
        case .count: "盘点"
        case .expiryDispose: "处理快过期"
        case .lotSnooze: "快过期晚点提醒"
        }
    }

    /// 时间：今天「19:32」，昨天「昨天 19:32」，更早「11月23日 19:32」（上海时间）
    public func timeText(now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: occurredAt)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: occurredAt), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return hm
        case 1: return "昨天 \(hm)"
        default: return "\(c.month ?? 0)月\(c.day ?? 0)日 \(hm)"
        }
    }

    /// 商品那一栏：一样写名称，多样写「第一样 等 N 样」
    public var namesText: String? {
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) 等 \(names.count) 样" : first
    }
}

/// 「待传」的统一口径（全 App 只有「待传」和「没记上」两个词）：
/// - 待传 = 本机还没得到服务器结果（outbox 里 `pending`）的笔数，当前会话 + 恢复队列（以前登录时没传完的）；
/// - 没记上 = 服务器明确拒收（`rejected`），不计入待传；
/// - 进货待确认（`held`）已经有服务器结果，不算待传。
public struct PendingOverview: Hashable, Sendable {
    /// 当前会话的待传，按时间倒序，最多 `limit` 条
    public let entries: [PendingEntry]
    /// 当前会话一共几笔待传
    public let currentCount: Int
    /// 恢复队列（以前登录时）还有几笔在补传；只给笔数，不给内容（收银员会话不能看旧会话的账，§4.5 / §14 S13-1）
    public let recoveryCount: Int
    /// 今天当前会话被服务器拒收（没记上）的笔数：记的账里有红字卡片
    public let rejectedToday: Int
    /// 待传里超过一天的（含恢复队列）
    public let overdueCount: Int

    /// 待传总数（顶栏、面板、首页 24 小时条用同一个数）
    public var total: Int { currentCount + recoveryCount }
    /// 列表外还有几笔（「还有 N 笔」）
    public var moreCount: Int { max(0, currentCount - entries.count) }
}

extension LocalDB {
    /// 面板最多列几笔
    public static let pendingListLimit = 20

    /// 待传总数和其中超过一天的（只读计数，顶栏 / 首页用）。口径见 `PendingOverview`
    public func pendingTally(now: Date = Date()) throws -> (total: Int, overdue: Int) {
        try writer.read { try Self.pendingTally($0, now: now) }
    }

    static func pendingTally(_ db: Database, now: Date) throws -> (total: Int, overdue: Int) {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE status = 'pending'") ?? 0
        let overdue = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE status = 'pending' AND occurred_at < ?",
                                       arguments: [dayAgo(now)]) ?? 0
        return (total, overdue)
    }

    /// 「待传」面板的数据（只读；调用方放后台线程）
    public func pendingOverview(limit: Int = LocalDB.pendingListLimit, now: Date = Date()) throws -> PendingOverview {
        try writer.read { db in
            let (all, overdue) = try Self.pendingTally(db, now: now)
            guard let s = try Self.currentSession(db) else {
                return PendingOverview(entries: [], currentCount: 0, recoveryCount: all, rejectedToday: 0, overdueCount: overdue)
            }
            let mine = [s.deviceId.uuidString, s.storeId.uuidString]
            let current = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ?
                """, arguments: StatementArguments(mine)) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT seq, type, op_json, occurred_at FROM outbox WHERE status = 'pending' AND device_id = ? AND store_id = ?
                ORDER BY occurred_at DESC, seq DESC LIMIT ?
                """, arguments: [s.deviceId.uuidString, s.storeId.uuidString, limit])
            let entries = try rows.compactMap { try Self.pendingEntry(db, $0) }
            let today = Self.shanghaiDay(now)
            let rejected = try String.fetchAll(db, sql: """
                SELECT occurred_at FROM outbox WHERE status = 'rejected' AND device_id = ? AND store_id = ?
                """, arguments: StatementArguments(mine))
                .filter { Self.parseTimestamp($0).map(Self.shanghaiDay) == today }.count
            return PendingOverview(entries: entries, currentCount: current, recoveryCount: all - current,
                                   rejectedToday: rejected, overdueCount: overdue)
        }
    }

    static func dayAgo(_ now: Date) -> String {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now).map(Op.formatTimestamp) ?? ""
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// op 字节里面板要用的几个字段（各类型的 payload 合在一起，没有的为 nil）
    private struct PanelOp: Decodable {
        struct Line: Decodable { let name: String?; let pack_count: Int64? }
        struct Payload: Decodable {
            let product_id: String?
            let barcode: String?
            let name: String?
            let lines: [Line]?
            let paid_total_fen: Int64?
            let pack_count: Int64?
            let pack_qty: Int64?
            let unit_cost_fen: Int64?
            let price_fen: Int64?
            let counted_qty: Int64?
        }
        let payload: Payload
    }

    /// productEdit 改了哪些字段（判断「改价」：只带 product_id 和 price_fen）
    private struct PayloadKeys: Decodable {
        struct AnyKey: CodingKey {
            var stringValue: String; var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        struct Keys: Decodable {
            let names: Set<String>
            init(from decoder: Decoder) throws {
                names = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
            }
        }
        let payload: Keys
    }

    /// op 字节 → 面板一行。商品名优先用 op 里带的，没有再查本机商品表
    static func pendingEntry(_ db: Database, _ r: Row) throws -> PendingEntry? {
        guard let type = OpType(rawValue: r["type"]), let at = parseTimestamp(r["occurred_at"]) else { return nil }
        return try describe(db, seq: r["seq"], type: type, data: r["op_json"], at: at)
    }

    /// op 字节（`{"payload": …}`）→ 面板一行。S23a 待确认的账也走这里
    static func describe(_ db: Database, seq: Int64, type: OpType, data: Data, at: Date) throws -> PendingEntry? {
        // 读不懂内容也不丢这一行（否则列表少一行、「还有 N 笔」又算上它，数对不上）：只写时间和类型
        guard let p = (try? JSONDecoder().decode(PanelOp.self, from: data))?.payload else {
            return PendingEntry(id: seq, occurredAt: at, type: type, names: [], quantity: nil, unitName: nil,
                                amountFen: nil, priceOnlyEdit: false)
        }
        func productName(_ id: String?) throws -> String? {
            guard let id = id.flatMap(UUID.init(uuidString:)) else { return nil }  // 本机表里是大写 uuidString
            return try String.fetchOne(db, sql: "SELECT name FROM product WHERE id = ?", arguments: [id.uuidString])
        }
        func baseUnit(_ id: String?) throws -> String? {
            guard let id = id.flatMap(UUID.init(uuidString:)) else { return nil }  // 本机表里是大写 uuidString
            return try String.fetchOne(db, sql: "SELECT base_unit FROM product WHERE id = ?", arguments: [id.uuidString])
        }
        var names: [String] = [], qty: Int64?, unit: String?, amount: Int64?, priceOnly = false
        switch type {
        case .saleBatch:
            let lines = p.lines ?? []
            names = lines.compactMap(\.name)
            qty = lines.reduce(0) { $0 + ($1.pack_count ?? 0) }
            unit = "件"
            amount = p.paid_total_fen
        case .stockIn:
            names = try productName(p.product_id).map { [$0] } ?? []
            qty = p.pack_count
            if let code = p.barcode {
                unit = try String.fetchOne(db, sql: "SELECT unit_name FROM barcode WHERE barcode = ?", arguments: [code])
            }
            if unit == nil { unit = try baseUnit(p.product_id) }
            if let c = p.unit_cost_fen, let n = p.pack_count { amount = c.multipliedReportingOverflow(by: n).overflow ? nil : c * n }
        case .productUpsert:
            names = p.name.map { [$0] } ?? []
            amount = p.price_fen
        case .productEdit:
            names = try (p.name ?? productName(p.product_id)).map { [$0] } ?? []
            amount = p.price_fen
            let keys = (try? JSONDecoder().decode(PayloadKeys.self, from: data))?.payload.names ?? []
            priceOnly = amount != nil && keys.subtracting(["product_id", "price_fen"]).isEmpty
        case .barcodeLink:
            names = try productName(p.product_id).map { [$0] } ?? []
            qty = p.pack_qty
            unit = try baseUnit(p.product_id)
        case .opening, .count, .productReviewComplete:
            names = try productName(p.product_id).map { [$0] } ?? []
            qty = p.counted_qty
            unit = try baseUnit(p.product_id)
        case .barcodeUnlink:
            names = try productName(p.product_id).map { [$0] } ?? []
        case .void, .expiryDispose, .lotSnooze:
            break
        }
        return PendingEntry(id: seq, occurredAt: at, type: type, names: names, quantity: qty, unitName: unit,
                            amountFen: amount, priceOnlyEdit: priceOnly)
    }
}
