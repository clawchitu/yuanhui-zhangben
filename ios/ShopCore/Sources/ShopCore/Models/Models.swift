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
/// 字段全部只读：要改就走 `with(...)`，它重新跑一遍校验构造器；解码也走同一个构造器。
public struct Product: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let baseUnit: String
    public let priceFen: Fen
    public let needsReview: Bool
    public let trackExpiry: Bool
    public let imageVer: Int
    public let archived: Bool

    public init(id: UUID, name: String, baseUnit: String = "个", priceFen: Fen,
                needsReview: Bool = false, trackExpiry: Bool = false, imageVer: Int = 0, archived: Bool = false) throws {
        try Limits.checkText(name, max: Limits.maxNameLength, "名称")
        try Limits.checkText(baseUnit, max: Limits.maxUnitLength, "基本单位")
        try Limits.checkFen(priceFen.raw, "卖价")
        guard imageVer >= 0 else { throw invalid("图片版本不能为负：\(imageVer)") }
        self.id = id; self.name = name; self.baseUnit = baseUnit; self.priceFen = priceFen
        self.needsReview = needsReview; self.trackExpiry = trackExpiry; self.imageVer = imageVer; self.archived = archived
    }

    /// 改几个字段，得到一个新值；不合法就抛 `invalid`，原值不变。
    public func with(name: String? = nil, baseUnit: String? = nil, priceFen: Fen? = nil, needsReview: Bool? = nil,
                     trackExpiry: Bool? = nil, imageVer: Int? = nil, archived: Bool? = nil) throws -> Product {
        try Product(id: id, name: name ?? self.name, baseUnit: baseUnit ?? self.baseUnit, priceFen: priceFen ?? self.priceFen,
                    needsReview: needsReview ?? self.needsReview, trackExpiry: trackExpiry ?? self.trackExpiry,
                    imageVer: imageVer ?? self.imageVer, archived: archived ?? self.archived)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUnit, priceFen, needsReview, trackExpiry, imageVer, archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                      baseUnit: try c.decode(String.self, forKey: .baseUnit), priceFen: try c.decode(Fen.self, forKey: .priceFen),
                      needsReview: try c.decode(Bool.self, forKey: .needsReview), trackExpiry: try c.decode(Bool.self, forKey: .trackExpiry),
                      imageVer: try c.decode(Int.self, forKey: .imageVer), archived: try c.decode(Bool.self, forKey: .archived))
    }
}

/// 商品的私有部分（§3.4 本地表 `product_private`）。**收银员手机上永远没有这些数据**（§4.2），
/// 所以单独成一个类型，不挂在 `Product` 上。字段只读，构造和解码都校验上限和 I3。
public struct ProductPrivate: Hashable, Sendable, Codable {
    public let productId: UUID
    /// 库存数（基本单位，可以为负）
    public let stockQty: Int64
    /// 货值（分）。`costKnown` 为假时恒为 0（I3）
    public let stockValueFen: Fen
    public let lastCostFen: Fen?
    /// 进价是否已知。区分「真的零成本」和「没填」，只看它（§5.2）
    public let costKnown: Bool
    public let stockVer: Int64
    public let lowAt: Int64?
    public let expiryWarnDays: Int64
    public let shelfLifeMonths: Int64?

    public init(productId: UUID, stockQty: Int64 = 0, stockValueFen: Fen = .zero, lastCostFen: Fen? = nil,
                costKnown: Bool = false, stockVer: Int64 = 0, lowAt: Int64? = nil,
                expiryWarnDays: Int64 = 7, shelfLifeMonths: Int64? = nil) throws {
        if let c = lastCostFen { try Limits.checkFen(c.raw, "进价") }
        guard stockVer >= 0 else { throw invalid("版本号不能为负") }
        try checkLowAt(lowAt)
        guard (0...Limits.maxExpiryWarnDays).contains(expiryWarnDays) else { throw invalid("提前提醒天数超出 0…\(Limits.maxExpiryWarnDays)") }
        if let m = shelfLifeMonths, !(1...Limits.maxShelfLifeMonths).contains(m) { throw invalid("保质期月数超出 1…\(Limits.maxShelfLifeMonths)") }
        // I3（§3.3）
        if !costKnown {
            guard stockValueFen == .zero else { throw invalid("进价未知时货值必须为 0（I3）") }
        } else if stockQty > 0 {
            guard stockValueFen >= .zero else { throw invalid("有库存时货值不能为负（I3）") }
        } else {
            guard let c = lastCostFen, stockValueFen.raw == (try Checked.mul(stockQty, c.raw))
            else { throw invalid("库存不为正时货值要等于 数量 × 进价（I3）") }
        }
        self.productId = productId; self.stockQty = stockQty; self.stockValueFen = stockValueFen
        self.lastCostFen = lastCostFen; self.costKnown = costKnown; self.stockVer = stockVer
        self.lowAt = lowAt; self.expiryWarnDays = expiryWarnDays; self.shelfLifeMonths = shelfLifeMonths
    }

    private enum CodingKeys: String, CodingKey {
        case productId, stockQty, stockValueFen, lastCostFen, costKnown, stockVer, lowAt, expiryWarnDays, shelfLifeMonths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(productId: try c.decode(UUID.self, forKey: .productId),
                      stockQty: try c.decode(Int64.self, forKey: .stockQty),
                      stockValueFen: try c.decode(Fen.self, forKey: .stockValueFen),
                      lastCostFen: try c.decodeIfPresent(Fen.self, forKey: .lastCostFen),
                      costKnown: try c.decode(Bool.self, forKey: .costKnown),
                      stockVer: try c.decode(Int64.self, forKey: .stockVer),
                      lowAt: try c.decodeIfPresent(Int64.self, forKey: .lowAt),
                      expiryWarnDays: try c.decode(Int64.self, forKey: .expiryWarnDays),
                      shelfLifeMonths: try c.decodeIfPresent(Int64.self, forKey: .shelfLifeMonths))
    }

    /// 当前单位成本 `u`（§5.2，仅供显示）：`k` 真且 `q > 0` 时 `roundDiv(v, q)`，否则 `c`。
    public func unitCost() throws -> Fen? {
        if costKnown, stockQty > 0 { return Fen(try roundDiv(stockValueFen.raw, stockQty)) }
        return lastCostFen
    }
}

/// 条码 → 商品（§3.2 `product_barcodes`）。单件码 `packQty = 1` 且不带整件价；整件码可以带自己的价，
/// 也可以不带（按「单件卖价 × 换算数量」，§14 S02-5 / S12-1）。解码也走校验构造器。
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

    private enum CodingKeys: String, CodingKey { case barcode, productId, packQty, unitName, packPriceFen }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(barcode: try c.decode(String.self, forKey: .barcode), productId: try c.decode(UUID.self, forKey: .productId),
                      packQty: try c.decode(Int64.self, forKey: .packQty), unitName: try c.decode(String.self, forKey: .unitName),
                      packPriceFen: try c.decodeIfPresent(Fen.self, forKey: .packPriceFen))
    }

    public var isPack: Bool { packQty > 1 }
}
