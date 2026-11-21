import Foundation
import GRDB

/// 条码字符集（§14 S14-5）：只收 ASCII 数字和大小写字母，大小写原样保留；长度 1…64（ops.schema.json）。
/// 不合规的码整串不收、不截断。扫码层（`HIDScanParser.isCodeCharacter`）是同一套规则，这里是登记前的最后一道。
public enum BarcodeCharset {
    public static func isValid(_ code: String) -> Bool {
        let s = code.unicodeScalars
        return (1...Limits.maxBarcodeLength).contains(s.count)
            && s.allSatisfy { ("0"..."9").contains($0) || ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    }
}

/// 名称为空（25e 断网登记、没查到也没写）时的占位名。契约要求名称至少 1 个字（ops.schema.json `name`），
/// 所以不发空串，发「没写名称 …尾号」：记的账里分得清，家里人补全时一眼看出要改；缩略图对它显示占位图标（§14 S16-5）。
public enum ProductNaming {
    public static let placeholderPrefix = "没写名称"

    public static func placeholder(barcode: String) -> String { "\(placeholderPrefix) …\(barcode.suffix(4))" }

    public static func isPlaceholder(_ name: String) -> Bool { name.hasPrefix(placeholderPrefix) }
}

/// 一次新商品登记（04a / 04b / 04c / 25e）的内容。构造时按 §5.0 和契约校验，不合规抛 `invalid`。
public struct NewProduct: Hashable, Sendable {
    /// 04b 第二步：货架上现在有几个、进价、这批哪天到期 → 一条不带 `base_ver` 的 `opening`（§5.6 第 3 条）
    public struct Opening: Hashable, Sendable {
        public let countedQty: Int64
        /// nil = 没填（进价未知）；0 = 明确零成本（§5.2）
        public let unitCostFen: Fen?
        public let expiryDate: CalendarDate?
        public init(countedQty: Int64, unitCostFen: Fen? = nil, expiryDate: CalendarDate? = nil) throws {
            try Limits.checkQty(countedQty, "货架上的数量")
            if let c = unitCostFen { try Limits.checkFen(c.raw, "进价") }
            self.countedQty = countedQty; self.unitCostFen = unitCostFen; self.expiryDate = expiryDate
        }
    }

    public let productId: UUID
    public let barcode: String
    /// 去掉首尾空白；空的换成占位名
    public let name: String
    public let priceFen: Fen
    /// 完整登记用；`quick` 登记不发（服务器默认「个」），本地也记成「个」
    public let baseUnit: String
    public let expiry: ExpirySettings?
    public let opening: Opening?

    public init(productId: UUID = UUID(), barcode: String, name: String, priceFen: Fen, baseUnit: String = "个",
                expiry: ExpirySettings? = nil, opening: Opening? = nil) throws {
        guard BarcodeCharset.isValid(barcode) else { throw invalid("条码只能是数字和字母，最多 \(Limits.maxBarcodeLength) 位") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = trimmed.isEmpty ? ProductNaming.placeholder(barcode: barcode) : trimmed
        try Limits.checkText(n, max: Limits.maxNameLength, "名称")
        try Limits.checkFen(priceFen.raw, "卖价")
        try Limits.checkText(baseUnit, max: Limits.maxUnitLength, "基本单位")
        self.productId = productId; self.barcode = barcode; self.name = n; self.priceFen = priceFen
        self.baseUnit = baseUnit; self.expiry = expiry; self.opening = opening
    }

    /// 能不能拿这个码去登记（扫到没登记的码时，进不了登记页的才出黄条，§14 S16-3）
    public static func isRegistrable(_ barcode: String) -> Bool { BarcodeCharset.isValid(barcode) }

    /// 04b 黄字「没填进价，赚多少先算不出来」：填了库存（> 0）没填进价
    public var missingCostWarning: Bool {
        guard let o = opening else { return false }
        return o.countedQty > 0 && o.unitCostFen == nil
    }
}

/// 05 整箱 / 整条码：把一个新码挂到已有商品上，1 件 = `packQty` 个基本单位。
public struct PackLink: Hashable, Sendable {
    public let record: BarcodeRecord

    public init(barcode: String, productId: UUID, unitName: String, packQty: Int64, packPriceFen: Fen?) throws {
        guard BarcodeCharset.isValid(barcode) else { throw invalid("条码只能是数字和字母，最多 \(Limits.maxBarcodeLength) 位") }
        guard packQty >= 2 else { throw invalid("整件至少是 2 个") }
        record = try BarcodeRecord(barcode: barcode, productId: productId, packQty: packQty, unitName: unitName,
                                   packPriceFen: packPriceFen)
    }

    /// 扫这个码卖 1 件的价：填了整件价用它，没填 = 单件卖价 × 换算数量（和 `PackConversion.unitPrice` 同一口径），
    /// 超 §5.0 单价上限抛 `invalid`
    public func effectivePrice(unitPriceFen: Fen) throws -> Fen {
        if let p = record.packPriceFen { return p }
        let v = try Checked.mul(unitPriceFen.raw, record.packQty)
        try Limits.checkFen(v, "整件卖价")
        return Fen(v)
    }
}

extension LocalDB {
    /// 登记新商品：写本地商品、单件码（家用再写一份零库存、进价未知的基线）、`product_upsert`，
    /// 带了第二步时再写 `opening` 流水和 op —— **同一个事务**，任何一步不行整笔回滚。
    /// `quick` = 收银员临时登记（04c）：只发名称和卖价，本地标待确认；不能带第二步。
    /// 条码已经在本地登记过 → 抛 `invalid`，什么都不写。
    @discardableResult
    public func registerProduct(_ r: NewProduct, quick: Bool = false, at now: Date = Date()) throws -> PackConversion {
        if quick, r.opening != nil || r.expiry != nil { throw invalid("临时登记只有名称和卖价") }
        let upsert: ProductUpsertPayload = quick
            ? try .quick(productId: r.productId, barcode: r.barcode, name: r.name, priceFen: r.priceFen)
            : try .full(productId: r.productId, barcode: r.barcode, name: r.name, priceFen: r.priceFen, baseUnit: r.baseUnit,
                        expiry: r.expiry)
        let unit = quick ? "个" : r.baseUnit
        let product = try Product(id: r.productId, name: r.name, baseUnit: unit, priceFen: r.priceFen, needsReview: quick,
                                  trackExpiry: r.expiry?.trackExpiry ?? false)
        let code = try BarcodeRecord(barcode: r.barcode, productId: r.productId, packQty: 1, unitName: unit)
        let upsertOp = Op(occurredAt: now, payload: upsert)
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, upsertOp, session: s)
            try Self.requireFreeBarcode(db, r.barcode)
            try db.execute(sql: """
                INSERT INTO product (id, name, base_unit, price_fen, needs_review, track_expiry) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [product.id.uuidString, product.name, unit, product.priceFen.raw, quick, product.trackExpiry])
            try db.execute(sql: "INSERT INTO barcode (barcode, product_id, pack_qty, unit_name) VALUES (?, ?, 1, ?)",
                           arguments: [r.barcode, product.id.uuidString, unit])
            if s.holdsPrivateData {
                try db.execute(sql: """
                    INSERT INTO product_private (product_id, stock_qty, stock_value_fen, cost_known, stock_ver, expiry_warn_days,
                      shelf_life_months) VALUES (?, 0, 0, 0, 0, ?, ?)
                    """, arguments: [product.id.uuidString, r.expiry?.expiryWarnDays ?? 7, r.expiry?.shelfLifeMonths])
            }
            try Self.enqueue(db, upsertOp, session: s, effects: [])
            guard let o = r.opening else { return }
            let opening = try OpeningPayload(entryId: UUID(), productId: product.id, countedQty: o.countedQty,
                                             unitCostFen: o.unitCostFen, expiryDate: o.expiryDate)
            let op = Op(occurredAt: now, payload: opening)
            try Self.checkCanQueue(db, op, session: s)
            try db.execute(sql: """
                INSERT INTO entry (id, op_id, type, product_id, barcode, name_snapshot, unit_name, pack_qty, pack_count, qty_delta,
                  list_amount_fen, amount_fen, unit_cost_fen, expiry_date, device_id, occurred_at)
                VALUES (?, ?, 'opening', ?, ?, ?, ?, 1, ?, ?, 0, 0, ?, ?, ?, ?)
                """, arguments: [opening.entryId.uuidString, op.id.uuidString, product.id.uuidString, r.barcode, product.name,
                                 unit, o.countedQty, o.countedQty, o.unitCostFen?.raw, o.expiryDate?.description,
                                 s.deviceId.uuidString, Op.formatTimestamp(now)])
            try faultHook?(.afterEntriesBeforeOutbox)
            try Self.enqueue(db, op, session: s, effects: [StockEffect(productId: product.id, qtyDelta: o.countedQty)])
        }
        return try PackConversion(product: product, barcode: code)
    }

    /// 05：把整箱 / 整条码挂到本地已有的商品上，写条码 + `barcode_link`，同一个事务。
    /// 条码已经挂在别的商品上 → 拒，不挪（§4.4）；商品不在本地 → 拒。只有家用 / 审核能挂。
    @discardableResult
    public func linkPack(_ link: PackLink, at now: Date = Date()) throws -> PackConversion {
        let op = Op(occurredAt: now, payload: BarcodeLinkPayload(link.record))
        let r = link.record
        return try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            try Self.requireFreeBarcode(db, r.barcode)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM product WHERE id = ?", arguments: [r.productId.uuidString])
            else { throw invalid("这个商品不在本机") }
            let product = try Self.productFrom(row)
            let conv = try PackConversion(product: product, barcode: r)
            _ = try conv.unitPrice()   // 没填整件价时「单价 × 换算」也要在上限内
            try db.execute(sql: "INSERT INTO barcode (barcode, product_id, pack_qty, unit_name, pack_price_fen) VALUES (?, ?, ?, ?, ?)",
                           arguments: [r.barcode, r.productId.uuidString, r.packQty, r.unitName, r.packPriceFen?.raw])
            try Self.enqueue(db, op, session: s, effects: [])
            return conv
        }
    }

    static func requireFreeBarcode(_ db: Database, _ code: String) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM barcode WHERE barcode = ?)", arguments: [code]) == true {
            throw invalid("这个码已经登记过了")
        }
    }
}
