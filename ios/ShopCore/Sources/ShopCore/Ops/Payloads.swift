import Foundation

/// 每种 op 的 payload（§4.3、`contracts/ops.schema.json`）。
/// 所有构造器都会做 §5.0 的上限校验和 schema 表达不了的乘积校验，不合法直接抛 `invalid`，
/// 所以只要拿到了一个 payload 值，它编码出的 JSON 就能通过 `ops.schema.json`。
public protocol OpPayload: Sendable {
    static var opType: OpType { get }
    var json: JSONValue { get }
}

// MARK: sale_batch

public struct SaleLine: Hashable, Sendable {
    public let entryId: UUID
    public let productId: UUID
    public let barcode: String
    public let name: String
    public let unitName: String
    public let packQty: Int64
    public let packCount: Int64
    public let unitPriceFen: Fen

    public init(entryId: UUID, productId: UUID, barcode: String, name: String, unitName: String,
                packQty: Int64, packCount: Int64, unitPriceFen: Fen) throws {
        try Limits.checkText(barcode, max: Limits.maxBarcodeLength, "条码")
        try Limits.checkText(name, max: Limits.maxNameLength, "名称")
        try Limits.checkText(unitName, max: Limits.maxUnitLength, "单位名")
        try Limits.baseQty(packQty: packQty, packCount: packCount)
        try Limits.lineAmount(unitFen: unitPriceFen.raw, packCount: packCount)
        self.entryId = entryId; self.productId = productId; self.barcode = barcode; self.name = name
        self.unitName = unitName; self.packQty = packQty; self.packCount = packCount; self.unitPriceFen = unitPriceFen
    }

    var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("entry_id", entryId); b.put("product_id", productId); b.put("barcode", barcode)
        b.put("name", name); b.put("unit_name", unitName); b.put("pack_qty", packQty)
        b.put("pack_count", packCount); b.put("unit_price_fen", unitPriceFen)
        return b.value
    }
}

public struct SaleBatchPayload: OpPayload, Hashable {
    public static let opType = OpType.saleBatch
    public let batchId: UUID
    public let paidTotalFen: Fen
    public let lines: [SaleLine]

    public init(batchId: UUID, paidTotalFen: Fen, lines: [SaleLine]) throws {
        // 行数、实收上限、L = 0 而 P ≠ 0：都按分摊规则校验一遍
        _ = try Allocation.allocate(
            lines: lines.map { Allocation.Line(unitPriceFen: $0.unitPriceFen.raw, packCount: $0.packCount, packQty: $0.packQty) },
            paidTotalFen: paidTotalFen.raw)
        self.batchId = batchId; self.paidTotalFen = paidTotalFen; self.lines = lines
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("batch_id", batchId); b.put("paid_total_fen", paidTotalFen)
        b.put("lines", .array(lines.map(\.json)))
        return b.value
    }
}

// MARK: void

public struct VoidPayload: OpPayload, Hashable {
    public static let opType = OpType.void
    public enum Target: Hashable, Sendable { case batch(UUID), entry(UUID) }
    public let target: Target
    public init(target: Target) { self.target = target }

    public var json: JSONValue {
        var t = JSONObjectBuilder()
        switch target {
        case .batch(let id): t.put("batch_id", id)
        case .entry(let id): t.put("entry_id", id)
        }
        return .object([("target", t.value)])
    }
}

// MARK: product_upsert

/// 保质期设置（§3.2）。
public struct ExpirySettings: Hashable, Sendable {
    public let trackExpiry: Bool
    public let expiryWarnDays: Int64
    public let shelfLifeMonths: Int64?
    public init(trackExpiry: Bool, expiryWarnDays: Int64 = 7, shelfLifeMonths: Int64? = nil) throws {
        guard (0...Limits.maxExpiryWarnDays).contains(expiryWarnDays) else { throw invalid("提前提醒天数超出 0…\(Limits.maxExpiryWarnDays)") }
        if let m = shelfLifeMonths, !(1...Limits.maxShelfLifeMonths).contains(m) { throw invalid("保质期月数超出 1…\(Limits.maxShelfLifeMonths)") }
        self.trackExpiry = trackExpiry; self.expiryWarnDays = expiryWarnDays; self.shelfLifeMonths = shelfLifeMonths
    }

    func put(into b: inout JSONObjectBuilder) {
        b.put("track_expiry", trackExpiry)
        b.put("expiry_warn_days", expiryWarnDays)
        if let m = shelfLifeMonths { b.put("shelf_life_months", m) }
    }
}

func checkLowAt(_ v: Int64?) throws {
    if let v, !(0...Limits.maxLowAt).contains(v) { throw invalid("低库存提醒数超出 0…\(Limits.maxLowAt)") }
}

public struct ProductUpsertPayload: OpPayload, Hashable {
    public static let opType = OpType.productUpsert
    public let productId: UUID
    public let barcode: String
    public let name: String
    public let priceFen: Fen
    public let quick: Bool
    public let baseUnit: String?
    public let expiry: ExpirySettings?
    public let lowAt: Int64?

    private init(productId: UUID, barcode: String, name: String, priceFen: Fen, quick: Bool,
                 baseUnit: String?, expiry: ExpirySettings?, lowAt: Int64?) throws {
        try Limits.checkText(barcode, max: Limits.maxBarcodeLength, "条码")
        try Limits.checkText(name, max: Limits.maxNameLength, "名称")
        try Limits.checkFen(priceFen.raw, "卖价")
        if let u = baseUnit { try Limits.checkText(u, max: Limits.maxUnitLength, "基本单位") }
        try checkLowAt(lowAt)
        self.productId = productId; self.barcode = barcode; self.name = name; self.priceFen = priceFen
        self.quick = quick; self.baseUnit = baseUnit; self.expiry = expiry; self.lowAt = lowAt
    }

    /// 收银员临时登记（04c）：只有名称和卖价，不带基本单位（服务器默认「个」）和任何家用字段。
    public static func quick(productId: UUID, barcode: String, name: String, priceFen: Fen) throws -> Self {
        try Self(productId: productId, barcode: barcode, name: name, priceFen: priceFen, quick: true,
                 baseUnit: nil, expiry: nil, lowAt: nil)
    }

    /// 家用完整登记（04a / 04b）：必带基本单位。
    public static func full(productId: UUID, barcode: String, name: String, priceFen: Fen, baseUnit: String,
                            expiry: ExpirySettings? = nil, lowAt: Int64? = nil) throws -> Self {
        try Self(productId: productId, barcode: barcode, name: name, priceFen: priceFen, quick: false,
                 baseUnit: baseUnit, expiry: expiry, lowAt: lowAt)
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("product_id", productId); b.put("barcode", barcode); b.put("name", name)
        b.put("price_fen", priceFen); b.put("quick", quick)
        b.putIfPresent("base_unit", baseUnit)
        expiry?.put(into: &b)
        b.putIfPresent("low_at", lowAt)
        return b.value
    }
}

// MARK: product_edit

/// 一个字段要不要改；`.set(nil)` 表示改成空（只用于可空字段）。
public enum Patch<T: Hashable & Sendable>: Hashable, Sendable {
    case unchanged
    case set(T)
    var isSet: Bool { if case .set = self { return true } else { return false } }
}

public struct ProductEditPayload: OpPayload, Hashable {
    public static let opType = OpType.productEdit
    public let productId: UUID
    public let name: Patch<String>
    public let priceFen: Patch<Fen>
    public let baseUnit: Patch<String>
    public let lowAt: Patch<Int64?>
    public let trackExpiry: Patch<Bool>
    public let expiryWarnDays: Patch<Int64>
    public let shelfLifeMonths: Patch<Int64?>
    public let archived: Patch<Bool>

    /// 只带要改的字段，逐字段后写者赢；一个都不改就拒。
    public init(productId: UUID, name: Patch<String> = .unchanged, priceFen: Patch<Fen> = .unchanged,
                baseUnit: Patch<String> = .unchanged, lowAt: Patch<Int64?> = .unchanged,
                trackExpiry: Patch<Bool> = .unchanged, expiryWarnDays: Patch<Int64> = .unchanged,
                shelfLifeMonths: Patch<Int64?> = .unchanged, archived: Patch<Bool> = .unchanged) throws {
        if case .set(let v) = name { try Limits.checkText(v, max: Limits.maxNameLength, "名称") }
        if case .set(let v) = priceFen { try Limits.checkFen(v.raw, "卖价") }
        if case .set(let v) = baseUnit { try Limits.checkText(v, max: Limits.maxUnitLength, "基本单位") }
        if case .set(let v) = lowAt { try checkLowAt(v) }
        if case .set(let v) = expiryWarnDays, !(0...Limits.maxExpiryWarnDays).contains(v) { throw invalid("提前提醒天数超出范围") }
        if case .set(let v?) = shelfLifeMonths, !(1...Limits.maxShelfLifeMonths).contains(v) { throw invalid("保质期月数超出范围") }
        let any = [name.isSet, priceFen.isSet, baseUnit.isSet, lowAt.isSet, trackExpiry.isSet,
                   expiryWarnDays.isSet, shelfLifeMonths.isSet, archived.isSet].contains(true)
        guard any else { throw invalid("product_edit 至少要改一个字段") }
        self.productId = productId; self.name = name; self.priceFen = priceFen; self.baseUnit = baseUnit
        self.lowAt = lowAt; self.trackExpiry = trackExpiry; self.expiryWarnDays = expiryWarnDays
        self.shelfLifeMonths = shelfLifeMonths; self.archived = archived
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("product_id", productId)
        if case .set(let v) = name { b.put("name", v) }
        if case .set(let v) = priceFen { b.put("price_fen", v) }
        if case .set(let v) = baseUnit { b.put("base_unit", v) }
        if case .set(let v) = lowAt { b.put("low_at", v.map(JSONValue.int) ?? .null) }
        if case .set(let v) = trackExpiry { b.put("track_expiry", v) }
        if case .set(let v) = expiryWarnDays { b.put("expiry_warn_days", v) }
        if case .set(let v) = shelfLifeMonths { b.put("shelf_life_months", v.map(JSONValue.int) ?? .null) }
        if case .set(let v) = archived { b.put("archived", v) }
        return b.value
    }
}

// MARK: barcode_link / barcode_unlink

public struct BarcodeLinkPayload: OpPayload, Hashable {
    public static let opType = OpType.barcodeLink
    public let record: BarcodeRecord

    /// 按 `ops.schema.json`：单件码（`pack_qty = 1`）不带价；整件码可以带自己的价，也可以不带
    /// （读价时按「单件卖价 × 换算数量」，§14 S02-5 / S12-1）。这些都由 `BarcodeRecord` 的构造器保证。
    public init(_ record: BarcodeRecord) {
        self.record = record
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("barcode", record.barcode); b.put("product_id", record.productId)
        b.put("pack_qty", record.packQty); b.put("unit_name", record.unitName)
        b.putIfPresent("pack_price_fen", record.packPriceFen)
        return b.value
    }
}

public struct BarcodeUnlinkPayload: OpPayload, Hashable {
    public static let opType = OpType.barcodeUnlink
    public let barcode: String
    public let productId: UUID
    public init(barcode: String, productId: UUID) throws {
        try Limits.checkText(barcode, max: Limits.maxBarcodeLength, "条码")
        self.barcode = barcode; self.productId = productId
    }
    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("barcode", barcode); b.put("product_id", productId)
        return b.value
    }
}

// MARK: stock_in

public struct StockInPayload: OpPayload, Hashable {
    public static let opType = OpType.stockIn
    public let entryId: UUID
    public let productId: UUID
    public let barcode: String
    public let packQty: Int64
    public let packCount: Int64
    /// 每件（条 / 箱）单价
    public let unitCostFen: Fen
    public let expiryDate: CalendarDate?

    public init(entryId: UUID, productId: UUID, barcode: String, packQty: Int64, packCount: Int64,
                unitCostFen: Fen, expiryDate: CalendarDate? = nil) throws {
        try Limits.checkText(barcode, max: Limits.maxBarcodeLength, "条码")
        try Limits.baseQty(packQty: packQty, packCount: packCount)
        try Limits.lineAmount(unitFen: unitCostFen.raw, packCount: packCount)   // 进货总价 ≤ 上限
        // 进货 0 件：这批单位成本 roundDiv(T, 0) 无定义，服务器拒 invalid（§14 S05-3）；卖出行 0 件不拒
        guard packCount >= 1 else { throw invalid("进货件数至少 1：\(packCount)") }
        self.entryId = entryId; self.productId = productId; self.barcode = barcode; self.packQty = packQty
        self.packCount = packCount; self.unitCostFen = unitCostFen; self.expiryDate = expiryDate
    }

    /// 用扫到的码构造（整件码自动带换算）
    public init(entryId: UUID, conversion: PackConversion, packCount: Int64, unitCostFen: Fen,
                expiryDate: CalendarDate? = nil) throws {
        try self.init(entryId: entryId, productId: conversion.product.id, barcode: conversion.barcode.barcode,
                      packQty: conversion.packQty, packCount: packCount, unitCostFen: unitCostFen, expiryDate: expiryDate)
    }

    /// 入账的基本单位数（5 箱 × 24 = 120 罐）
    public var baseQty: Int64 { packQty * packCount }          // 构造时已校验不溢出、不超限
    /// 进货总价（5 × ¥48 = ¥240.00）
    public var totalFen: Fen { Fen(unitCostFen.raw * packCount) } // 同上
    /// 这批的单位成本 `b = roundDiv(T, n)`（§5.2）；n = 0 时没有
    public func batchUnitCost() throws -> Fen? {
        baseQty > 0 ? Fen(try roundDiv(totalFen.raw, baseQty)) : nil
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("entry_id", entryId); b.put("product_id", productId); b.put("barcode", barcode)
        b.put("pack_qty", packQty); b.put("pack_count", packCount); b.put("unit_cost_fen", unitCostFen)
        b.putIfPresent("expiry_date", expiryDate)
        return b.value
    }
}

// MARK: opening / product_review_complete / count

public struct OpeningPayload: OpPayload, Hashable {
    public static let opType = OpType.opening
    public let entryId: UUID
    public let productId: UUID
    public let countedQty: Int64
    /// nil = 没填进价；0 = 明确零成本（§5.2）
    public let unitCostFen: Fen?
    public let expiryDate: CalendarDate?
    public let baseVer: Int64?
    public let baseQty: Int64?

    public init(entryId: UUID, productId: UUID, countedQty: Int64, unitCostFen: Fen? = nil,
                expiryDate: CalendarDate? = nil, baseVer: Int64? = nil, baseQty: Int64? = nil) throws {
        try Limits.checkQty(countedQty, "期初数")
        if let c = unitCostFen { try Limits.checkFen(c.raw, "进价") }
        if let v = baseVer, v < 0 { throw invalid("版本号不能为负") }
        if let q = baseQty { try Limits.checkBaseQty(q) }
        self.entryId = entryId; self.productId = productId; self.countedQty = countedQty
        self.unitCostFen = unitCostFen; self.expiryDate = expiryDate; self.baseVer = baseVer; self.baseQty = baseQty
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("entry_id", entryId); b.put("product_id", productId); b.put("counted_qty", countedQty)
        b.putIfPresent("unit_cost_fen", unitCostFen); b.putIfPresent("expiry_date", expiryDate)
        b.putIfPresent("base_ver", baseVer); b.putIfPresent("base_qty", baseQty)
        return b.value
    }
}

public struct ProductReviewCompletePayload: OpPayload, Hashable {
    public static let opType = OpType.productReviewComplete
    public let entryId: UUID
    public let productId: UUID
    /// 必填，可以为 0（§14 Q3）
    public let unitCostFen: Fen
    public let countedQty: Int64
    public let baseVer: Int64
    public let baseQty: Int64?
    public let expiry: ExpirySettings?
    public let expiryDate: CalendarDate?

    public init(entryId: UUID, productId: UUID, unitCostFen: Fen, countedQty: Int64, baseVer: Int64,
                baseQty: Int64? = nil, expiry: ExpirySettings? = nil, expiryDate: CalendarDate? = nil) throws {
        try Limits.checkFen(unitCostFen.raw, "进价")
        try Limits.checkQty(countedQty, "数到的数")
        guard baseVer >= 0 else { throw invalid("版本号不能为负") }
        if let q = baseQty { try Limits.checkBaseQty(q) }
        self.entryId = entryId; self.productId = productId; self.unitCostFen = unitCostFen
        self.countedQty = countedQty; self.baseVer = baseVer; self.baseQty = baseQty
        self.expiry = expiry; self.expiryDate = expiryDate
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("entry_id", entryId); b.put("product_id", productId); b.put("unit_cost_fen", unitCostFen)
        b.put("counted_qty", countedQty); b.put("base_ver", baseVer); b.putIfPresent("base_qty", baseQty)
        expiry?.put(into: &b)
        b.putIfPresent("expiry_date", expiryDate)
        return b.value
    }
}

public struct CountPayload: OpPayload, Hashable {
    public static let opType = OpType.count
    public let entryId: UUID
    public let productId: UUID
    public let countedQty: Int64
    public let baseQty: Int64
    public let baseVer: Int64

    public init(entryId: UUID, productId: UUID, countedQty: Int64, baseQty: Int64, baseVer: Int64) throws {
        try Limits.checkQty(countedQty, "盘点数")
        try Limits.checkBaseQty(baseQty)
        guard baseVer >= 0 else { throw invalid("版本号不能为负") }
        self.entryId = entryId; self.productId = productId; self.countedQty = countedQty
        self.baseQty = baseQty; self.baseVer = baseVer
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("entry_id", entryId); b.put("product_id", productId); b.put("counted_qty", countedQty)
        b.put("base_qty", baseQty); b.put("base_ver", baseVer)
        return b.value
    }
}

// MARK: expiry_dispose / lot_snooze

public struct ExpiryDisposePayload: OpPayload, Hashable {
    public static let opType = OpType.expiryDispose
    public enum Action: String, Hashable, Sendable, CaseIterable { case soldOut = "sold_out", discard, `return` }
    public let lotId: UUID
    public let handleVer: Int64
    public let actualQty: Int64
    public let action: Action
    public let entryId: UUID

    public init(lotId: UUID, handleVer: Int64, actualQty: Int64, action: Action, entryId: UUID) throws {
        guard handleVer >= 0 else { throw invalid("版本号不能为负") }
        try Limits.checkQty(actualQty, "实际数")
        self.lotId = lotId; self.handleVer = handleVer; self.actualQty = actualQty; self.action = action; self.entryId = entryId
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("lot_id", lotId); b.put("handle_ver", handleVer); b.put("actual_qty", actualQty)
        b.put("action", action.rawValue); b.put("entry_id", entryId)
        return b.value
    }
}

public struct LotSnoozePayload: OpPayload, Hashable {
    public static let opType = OpType.lotSnooze
    public let lotId: UUID
    public let handleVer: Int64
    public let actualQty: Int64
    public let days: Int64

    public init(lotId: UUID, handleVer: Int64, actualQty: Int64, days: Int64) throws {
        guard handleVer >= 0 else { throw invalid("版本号不能为负") }
        try Limits.checkQty(actualQty, "实际数")
        guard (1...Limits.maxSnoozeDays).contains(days) else { throw invalid("推迟天数超出 1…\(Limits.maxSnoozeDays)") }
        self.lotId = lotId; self.handleVer = handleVer; self.actualQty = actualQty; self.days = days
    }

    public var json: JSONValue {
        var b = JSONObjectBuilder()
        b.put("lot_id", lotId); b.put("handle_ver", handleVer); b.put("actual_qty", actualQty); b.put("days", days)
        return b.value
    }
}
