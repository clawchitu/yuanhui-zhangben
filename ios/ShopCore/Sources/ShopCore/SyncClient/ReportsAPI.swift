import Foundation

// S24 看账的网络层（契约 openapi.yaml「查询」：`/v1/reports/today`、`/v1/reports/month`，口径 §5.3）。
// 金额一律整数分（`Fen`），日期保留服务器给的字符串（上海时区的 YYYY-MM-DD / YYYY-MM）。手机不重算任何一项，原样显示。

/// 一个商品和它的数（卖得最好：卖出个数和金额；快没货：现在的库存；快过期：要提醒的批次剩余数和最早到期日）
public struct ReportProductAmount: Decodable, Equatable, Sendable {
    public let productId: UUID
    public let name: String
    public let qty: Int64?
    public let amountFen: Fen?
    public let expiryDate: String?
    enum CodingKeys: String, CodingKey {
        case name, qty
        case productId = "product_id", amountFen = "amount_fen", expiryDate = "expiry_date"
    }
    public init(productId: UUID, name: String, qty: Int64? = nil, amountFen: Fen? = nil, expiryDate: String? = nil) {
        self.productId = productId; self.name = name; self.qty = qty; self.amountFen = amountFen; self.expiryDate = expiryDate
    }
}

/// `GET /v1/reports/today`（设计稿 09）
public struct ReportToday: Decodable, Equatable, Sendable {
    public let date: String
    public let soldFen: Fen
    public let profitFen: Fen
    public let discountFen: Fen
    /// 「记了 N 笔」：一次记账算一笔（§14 S07-1），与 07a 卡片数一致
    public let count: Int
    public let costMissingCount: Int
    public let lossCostMissingCount: Int
    public let topSellers: [ReportProductAmount]
    public let lowStock: [ReportProductAmount]
    public let expiring: [ReportProductAmount]
    enum CodingKeys: String, CodingKey {
        case date, count, expiring
        case soldFen = "sold_fen", profitFen = "profit_fen", discountFen = "discount_fen"
        case costMissingCount = "cost_missing_count", lossCostMissingCount = "loss_cost_missing_count"
        case topSellers = "top_sellers", lowStock = "low_stock"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        soldFen = try c.decode(Fen.self, forKey: .soldFen)
        profitFen = try c.decode(Fen.self, forKey: .profitFen)
        discountFen = try c.decode(Fen.self, forKey: .discountFen)
        count = try c.decode(Int.self, forKey: .count)
        costMissingCount = try c.decode(Int.self, forKey: .costMissingCount)
        // 契约里不是必填（老服务器没有），没有就当 0
        lossCostMissingCount = try c.decodeIfPresent(Int.self, forKey: .lossCostMissingCount) ?? 0
        topSellers = try c.decode([ReportProductAmount].self, forKey: .topSellers)
        lowStock = try c.decode([ReportProductAmount].self, forKey: .lowStock)
        expiring = try c.decode([ReportProductAmount].self, forKey: .expiring)
    }
}

/// 对账的一行：本月 `entries.value_delta_fen` 按类型分组求和（§5.3）
public struct ReportReconRow: Decodable, Equatable, Sendable {
    public enum Key: String, Decodable, Sendable {
        case stockIn = "stock_in", sale, count, expireLoss = "expire_loss", supplierReturn = "supplier_return"
        case openingAndAdjust = "opening_and_adjust"
    }
    public let key: Key
    public let amountFen: Fen
    public let costMissingCount: Int
    enum CodingKeys: String, CodingKey { case key, amountFen = "amount_fen", costMissingCount = "cost_missing_count" }
    public init(key: Key, amountFen: Fen, costMissingCount: Int = 0) {
        self.key = key; self.amountFen = amountFen; self.costMissingCount = costMissingCount
    }
}

/// `GET /v1/reports/month`（设计稿 10）
public struct ReportMonth: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable {
        public let date: String
        public let soldFen: Fen
        public let profitFen: Fen
        enum CodingKeys: String, CodingKey { case date, soldFen = "sold_fen", profitFen = "profit_fen" }
    }
    public struct Reconciliation: Decodable, Equatable, Sendable {
        public let stockValueStartFen: Fen
        public let rows: [ReportReconRow]
        public let stockValueEndFen: Fen
        enum CodingKeys: String, CodingKey {
            case rows, stockValueStartFen = "stock_value_start_fen", stockValueEndFen = "stock_value_end_fen"
        }
    }
    public let month: String
    public let soldFen: Fen
    public let profitFen: Fen
    /// 10 的「现在店里货值」取这个（§14 S07-4）
    public let stockValueEndFen: Fen
    public let discountFen: Fen
    public let expireLossFen: Fen
    public let costMissingCount: Int
    public let lossCostMissingCount: Int
    public let daily: [Day]
    public let reconciliation: Reconciliation
    enum CodingKeys: String, CodingKey {
        case month, daily, reconciliation
        case soldFen = "sold_fen", profitFen = "profit_fen", stockValueEndFen = "stock_value_end_fen"
        case discountFen = "discount_fen", expireLossFen = "expire_loss_fen"
        case costMissingCount = "cost_missing_count", lossCostMissingCount = "loss_cost_missing_count"
    }
}

extension APIClient {
    /// 今天的账；`date` 为 nil = 服务器的今天（上海）
    public func reportToday(date: String? = nil, token: String) async throws -> ReportToday {
        let q = date.map { "?date=\($0)" } ?? ""
        return try await send("GET", "/v1/reports/today\(q)", body: nil as [String: String]?, token: token)
    }

    /// 本月的账；`month` 为 nil = 服务器的本月（上海）
    public func reportMonth(month: String? = nil, token: String) async throws -> ReportMonth {
        let q = month.map { "?month=\($0)" } ?? ""
        return try await send("GET", "/v1/reports/month\(q)", body: nil as [String: String]?, token: token)
    }
}
