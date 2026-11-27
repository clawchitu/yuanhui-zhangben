import Foundation
import GRDB

// S26 盘点（§5.2 盘点、§5.6、设计稿 12a / 12b）的本地部分。
//
// - 盘点**只能联网**（§5.6 第 1 条）：不进 outbox，先把本机的账传完、拉到底（`SyncEngine.drainForOnline`），
//   再拿本机基线（= 服务器现在的账面数和版本）单独交 `count`（`SyncEngine.submitOnline`）。
// - 人是对着页面上那一版账面数数的：排空后版本变了（别的手机又卖了 / 进了），不交，先问「账上现在是 N 个，你数的还对吗」；
//   交上去被拒 `stale` 也一样。人确认过的那一版才带上去（`countOp` 的 `expectedVer`）。
// - 差额、金额、批次全由服务器算（`server/src/ledger/count.ts`、§14 T6），手机只发「数到几个 + 数的时候账上是几个、哪个版本」。
// - 进度「已数 N 种 / 还有 M 种」按本月（上海）已有盘点流水的商品数算：家用号本地有最近 35 天的全店流水，够一个月。

/// 12a 上的一个商品 / 12b 上的一行
public struct CountItem: Hashable, Sendable, Identifiable {
    public let product: Product
    /// 账上还有（服务器基线，排空后就是服务器现在的）
    public let stockQty: Int64
    /// 账面版本（交盘点时带上去比对）
    public let stockVer: Int64
    public var id: UUID { product.id }
    public var unit: String { product.baseUnit }

    public init(product: Product, stockQty: Int64, stockVer: Int64) {
        self.product = product; self.stockQty = stockQty; self.stockVer = stockVer
    }
}

/// 12a 顶上的进度、12b 的清单
public struct CountProgress: Hashable, Sendable {
    /// 本月已经数过的商品种数（有盘点流水的，含数了「没错」的）
    public let counted: Int
    /// 还没数的（在卖的、不是待确认的商品里本月没有盘点流水的），12b 按名称排
    public let uncounted: [CountItem]
    public var remaining: Int { uncounted.count }
    public init(counted: Int, uncounted: [CountItem]) { self.counted = counted; self.uncounted = uncounted }
}

/// 盘点的规则（纯函数）
public enum CountRule {
    /// 盘点数最多几位（基本单位数量 ≤ 9,999,999，§5.0）
    public static let maxDigits = 7

    /// 自家数字键盘按一个键：只收 0–9（没有小数点），去掉前导 0，最多 7 位
    public static func append(_ text: String, digit: Character) -> String {
        guard digit.isASCII, digit.isNumber else { return text }
        if text == "0" { return String(digit) }
        guard text.count < maxDigits else { return text }
        return text + String(digit)
    }

    /// 退格
    public static func backspace(_ text: String) -> String { String(text.dropLast()) }

    /// 框里的字 → 数到几个；空着为 nil
    public static func counted(_ text: String) -> Int64? {
        guard !text.isEmpty, text.count <= maxDigits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }

    /// 12a 黄条：比账上少 / 多几个；一样时 nil
    public static func hint(counted: Int64, book: Int64, unit: String) -> String? {
        if counted < book { return "比账上少 \(book - counted) \(unit)，存好后按实际算" }
        if counted > book { return "比账上多 \(counted - book) \(unit)，存好后按实际算" }
        return nil
    }

    /// 「账上现在是 N 个，你数的还对吗」（别的手机这期间记了账，§5.6 第 2 条）
    public static func staleQuestion(stockQty: Int64, unit: String) -> String { "账上现在是 \(stockQty) \(unit)，你数的还对吗" }

    /// 「没错」能不能点：账上是负数时数不出这个数，要填实际数
    public static func canConfirmBook(_ book: Int64) -> Bool { book >= 0 }

    /// 本月（上海）的起止（含两头），按 `occurred_at` 的统一格式（固定 +08:00、毫秒）字符串比较
    public static func monthBounds(_ day: CalendarDate) -> (String, String) {
        let ym = String(format: "%04d-%02d", day.year, day.month)
        return ("\(ym)-01T00:00:00.000+08:00", "\(ym)-31T23:59:59.999+08:00")
    }
}

/// 排空之后、交之前的判断（`LocalDB.countOp`）
public enum CountPrepared: Sendable {
    /// 版本还是人看到的那一版：交这个 op
    case submit(Op)
    /// 版本变了：先问人「账上现在是 N 个，你数的还对吗」，确认后带这一版再交
    case stale(stockQty: Int64, stockVer: Int64)
    /// 商品不在本机了（被合并 / 删了）
    case gone
}

extension LocalDB {
    /// 12a 扫到一个码：码 → 商品和账面数。没登记过返回 nil。整箱码也认成这个商品（盘点按基本单位数）
    public func countItem(barcode: String) throws -> CountItem? {
        guard let conv = try lookup(barcode: barcode) else { return nil }
        return try countItem(conv.product.id)
    }

    /// 12a / 12b「去数」：一个商品的账面数（收银员手机没有账面数，返回 nil）
    public func countItem(_ productId: UUID) throws -> CountItem? {
        try writer.read { db in
            let id = try Self.canonicalProductId(db, productId)
            guard let r = try Row.fetchOne(db, sql: """
                SELECT p.*, pp.stock_qty AS cq, pp.stock_ver AS cv FROM product p JOIN product_private pp ON pp.product_id = p.id
                WHERE p.id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return CountItem(product: try Self.productFrom(r), stockQty: r["cq"], stockVer: r["cv"])
        }
    }

    /// 本机临时 id 换成服务器的（`product_remap`）；没换过原样返回
    static func canonicalProductId(_ db: Database, _ id: UUID) throws -> UUID {
        guard let s = try currentSession(db) else { return id }
        let to = try String.fetchOne(db, sql: "SELECT new_id FROM product_remap WHERE store_id = ? AND old_id = ?",
                                     arguments: [s.storeId.uuidString, id.uuidString])
        return try to.map(parseUUID) ?? id
    }

    /// 进度和 12b 的清单。`today` 是上海的今天（算本月）；`alsoCounted` 是这次刚交成功、拉取还没带回流水的商品。
    /// 已数 = 本月有盘点流水的商品（原行，不算迟到补偿行、冲销行和被撤销的，§5.6 第 4 条的补偿不是人数的）；
    /// 没数 = 在卖的、不是待确认的商品里本月没数过的（待确认的走 22b 补全，停用的不用数）
    public func countProgress(today: CalendarDate, alsoCounted: Set<UUID> = []) throws -> CountProgress {
        let (from, to) = CountRule.monthBounds(today)
        return try writer.read { db in
            guard let s = try Self.currentSession(db), s.holdsPrivateData else { return CountProgress(counted: 0, uncounted: []) }
            var counted = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT product_id FROM entry
                WHERE type = 'count' AND reverses_entry_id IS NULL AND voided_at IS NULL
                  AND (flags IS NULL OR COALESCE(json_extract(flags, '$.late_before_count'), 0) = 0)
                  AND occurred_at BETWEEN ? AND ?
                """, arguments: [from, to]).compactMap { try? parseUUID($0) })
            for id in alsoCounted { counted.insert(try Self.canonicalProductId(db, id)) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.*, pp.stock_qty AS cq, pp.stock_ver AS cv FROM product p JOIN product_private pp ON pp.product_id = p.id
                """)
            var done = 0
            var left: [CountItem] = []
            for r in rows {
                let p = try Self.productFrom(r)
                if counted.contains(p.id) { done += 1; continue }
                guard !p.archived, !p.needsReview else { continue }
                left.append(CountItem(product: p, stockQty: r["cq"], stockVer: r["cv"]))
            }
            left.sort { ($0.product.name, $0.id.uuidString) < ($1.product.name, $1.id.uuidString) }
            return CountProgress(counted: done, uncounted: left)
        }
    }

    /// 排空之后调：读本机基线（= 服务器现在的），版本还是 `expectedVer`（人数货时看到的、或 stale 后人确认过的那一版）
    /// 就做出 `count` op；变了返回 `.stale` 让人重新确认，不交。每次新 op、新 entry id（被拒的 op 重交只会拿回同一个结果）
    public func countOp(productId: UUID, counted: Int64, expectedVer: Int64, at now: Date = Date()) throws -> CountPrepared {
        guard let item = try countItem(productId) else { return .gone }
        guard item.stockVer == expectedVer else { return .stale(stockQty: item.stockQty, stockVer: item.stockVer) }
        return .submit(Op(occurredAt: now, payload: try CountPayload(entryId: UUID(), productId: item.id, countedQty: counted,
                                                                     baseQty: item.stockQty, baseVer: item.stockVer)))
    }
}
