import Foundation

/// 上海时区的日历日 `YYYY-MM-DD`（§3、ops.schema.json 的 `date`）。只存年月日整数。
public struct CalendarDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...CalendarDate.daysIn(year: year, month: month)).contains(day)
        else { throw invalid("日期不合法：\(year)-\(month)-\(day)") }
        self.year = year; self.month = month; self.day = day
    }

    public init(_ s: String) throws {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { throw invalid("日期格式要是 YYYY-MM-DD：\(s)") }
        try self.init(year: y, month: m, day: d)
    }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func < (l: CalendarDate, r: CalendarDate) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    public var description: String {
        func pad(_ v: Int, _ w: Int) -> String { String(repeating: "0", count: max(0, w - String(v).count)) + String(v) }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    public init(from decoder: Decoder) throws { try self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

/// 流水类型（§3.3）
public enum EntryType: String, Codable, Sendable, CaseIterable {
    case sale, stockIn = "stock_in", opening, count
    case costAdjust = "cost_adjust", costFix = "cost_fix"
    case expireLoss = "expire_loss", supplierReturn = "supplier_return"
}

/// 商品的公开部分（§3.4 本地表 `product`，收银员也有）。
public struct Product: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var baseUnit: String
    public var priceFen: Fen
    public var needsReview: Bool
    public var trackExpiry: Bool
    public var imageVer: Int
    public var archived: Bool

    public init(id: UUID, name: String, baseUnit: String = "个", priceFen: Fen,
                needsReview: Bool = false, trackExpiry: Bool = false, imageVer: Int = 0, archived: Bool = false) throws {
        try Limits.checkText(name, max: Limits.maxNameLength, "名称")
        try Limits.checkText(baseUnit, max: Limits.maxUnitLength, "基本单位")
        try Limits.checkFen(priceFen.raw, "卖价")
        self.id = id; self.name = name; self.baseUnit = baseUnit; self.priceFen = priceFen
        self.needsReview = needsReview; self.trackExpiry = trackExpiry; self.imageVer = imageVer; self.archived = archived
    }
}

/// 商品的私有部分（§3.4 本地表 `product_private`）。**收银员手机上永远没有这些数据**（§4.2），
/// 所以单独成一个类型，不挂在 `Product` 上。
public struct ProductPrivate: Hashable, Sendable, Codable {
    public let productId: UUID
    /// 库存数（基本单位，可以为负）
    public var stockQty: Int64
    /// 货值（分）。`costKnown` 为假时恒为 0（I3）
    public var stockValueFen: Fen
    public var lastCostFen: Fen?
    /// 进价是否已知。区分「真的零成本」和「没填」，只看它（§5.2）
    public var costKnown: Bool
    public var stockVer: Int64
    public var lowAt: Int64?
    public var expiryWarnDays: Int64
    public var shelfLifeMonths: Int64?

    public init(productId: UUID, stockQty: Int64 = 0, stockValueFen: Fen = .zero, lastCostFen: Fen? = nil,
                costKnown: Bool = false, stockVer: Int64 = 0, lowAt: Int64? = nil,
                expiryWarnDays: Int64 = 7, shelfLifeMonths: Int64? = nil) {
        self.productId = productId; self.stockQty = stockQty; self.stockValueFen = stockValueFen
        self.lastCostFen = lastCostFen; self.costKnown = costKnown; self.stockVer = stockVer
        self.lowAt = lowAt; self.expiryWarnDays = expiryWarnDays; self.shelfLifeMonths = shelfLifeMonths
    }

    /// 当前单位成本 `u`（§5.2，仅供显示）：`k` 真且 `q > 0` 时 `roundDiv(v, q)`，否则 `c`。
    public func unitCost() throws -> Fen? {
        if costKnown, stockQty > 0 { return Fen(try roundDiv(stockValueFen.raw, stockQty)) }
        return lastCostFen
    }
}

/// 条码 → 商品（§3.2 `product_barcodes`）。单件码 `packQty = 1` 且不带整件价；整件码可以带自己的价。
public struct BarcodeRecord: Hashable, Sendable, Codable {
    public let barcode: String
    public let productId: UUID
    public let packQty: Int64
    public let unitName: String
    public let packPriceFen: Fen?

    public init(barcode: String, productId: UUID, packQty: Int64 = 1, unitName: String, packPriceFen: Fen? = nil) throws {
        try Limits.checkText(barcode, max: Limits.maxBarcodeLength, "条码")
        try Limits.checkText(unitName, max: Limits.maxUnitLength, "单位名")
        try Limits.checkPackQty(packQty)
        if packQty == 1, packPriceFen != nil {
            throw invalid("单件码不带整件价，卖价读商品的卖价（§3.2）")
        }
        if let p = packPriceFen { try Limits.checkFen(p.raw, "整件价") }
        self.barcode = barcode; self.productId = productId; self.packQty = packQty
        self.unitName = unitName; self.packPriceFen = packPriceFen
    }

    public var isPack: Bool { packQty > 1 }
}
