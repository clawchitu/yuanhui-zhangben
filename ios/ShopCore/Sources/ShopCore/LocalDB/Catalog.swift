import Foundation
import GRDB

/// 本地的保质期批次（§3.4 `lot`，仅家用号）
public struct LocalLot: Hashable, Sendable {
    public let id: UUID
    public let productId: UUID
    public let expiryDate: CalendarDate?
    public let qtyIn: Int64
    public let qtyLeft: Int64
    public let snoozedUntil: CalendarDate?
    public let handleVer: Int64
    public init(id: UUID, productId: UUID, expiryDate: CalendarDate?, qtyIn: Int64, qtyLeft: Int64,
                snoozedUntil: CalendarDate? = nil, handleVer: Int64 = 0) throws {
        try Limits.checkQty(qtyIn, "批次数量")
        try Limits.checkQty(qtyLeft, "批次剩余")
        guard handleVer >= 0 else { throw invalid("版本号不能为负") }
        self.id = id; self.productId = productId; self.expiryDate = expiryDate; self.qtyIn = qtyIn
        self.qtyLeft = qtyLeft; self.snoozedUntil = snoozedUntil; self.handleVer = handleVer
    }
}

/// 拉取得到的一批基线（S21 的同步、演示种子数据都走这里）。
public struct CatalogBaseline: Sendable {
    public var products: [Product]
    public var barcodes: [BarcodeRecord]
    /// 收银员会话下必须为空（服务器根本不下发）；不为空就拒
    public var privates: [ProductPrivate]
    public var lots: [LocalLot]
    public init(products: [Product] = [], barcodes: [BarcodeRecord] = [], privates: [ProductPrivate] = [], lots: [LocalLot] = []) {
        self.products = products; self.barcodes = barcodes; self.privates = privates; self.lots = lots
    }
}

/// 本地显示的库存（§4.1 第 6 条）：服务器基线 + 本机未确认 op 的增减，两者分开存、现算相加。
public struct DisplayStock: Hashable, Sendable {
    public let baselineQty: Int64
    public let pendingDelta: Int64
    public var qty: Int64 { baselineQty + pendingDelta }
}

extension LocalDB {
    // MARK: - 写基线

    /// 写入（覆盖）商品、条码、私有数据和批次的服务器基线，一个事务。
    /// 收银员会话下带了私有数据或批次 → 抛 `invalid`，什么都不写（§3.4：收银员手机上 `product_private` 永远是空的）。
    public func applyBaseline(_ b: CatalogBaseline) throws {
        try writer.write { db in
            let s = try Self.requireSession(db)
            if !s.holdsPrivateData, !(b.privates.isEmpty && b.lots.isEmpty) {
                throw invalid("收银员手机不存进价、库存和批次")
            }
            for p in b.products {
                try db.execute(sql: """
                    INSERT INTO product (id, name, base_unit, price_fen, needs_review, track_expiry, image_ver, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, base_unit = excluded.base_unit,
                      price_fen = excluded.price_fen, needs_review = excluded.needs_review,
                      track_expiry = excluded.track_expiry, image_ver = excluded.image_ver, archived = excluded.archived
                    """, arguments: [p.id.uuidString, p.name, p.baseUnit, p.priceFen.raw, p.needsReview, p.trackExpiry,
                                     p.imageVer, p.archived])
            }
            for c in b.barcodes {
                try db.execute(sql: """
                    INSERT INTO barcode (barcode, product_id, pack_qty, unit_name, pack_price_fen) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(barcode) DO UPDATE SET product_id = excluded.product_id, pack_qty = excluded.pack_qty,
                      unit_name = excluded.unit_name, pack_price_fen = excluded.pack_price_fen
                    """, arguments: [c.barcode, c.productId.uuidString, c.packQty, c.unitName, c.packPriceFen?.raw])
            }
            for v in b.privates {
                try db.execute(sql: """
                    INSERT INTO product_private (product_id, stock_qty, stock_value_fen, last_cost_fen, cost_known, stock_ver,
                      low_at, expiry_warn_days, shelf_life_months) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(product_id) DO UPDATE SET stock_qty = excluded.stock_qty, stock_value_fen = excluded.stock_value_fen,
                      last_cost_fen = excluded.last_cost_fen, cost_known = excluded.cost_known, stock_ver = excluded.stock_ver,
                      low_at = excluded.low_at, expiry_warn_days = excluded.expiry_warn_days,
                      shelf_life_months = excluded.shelf_life_months
                    """, arguments: [v.productId.uuidString, v.stockQty, v.stockValueFen.raw, v.lastCostFen?.raw, v.costKnown,
                                     v.stockVer, v.lowAt, v.expiryWarnDays, v.shelfLifeMonths])
            }
            for l in b.lots {
                try db.execute(sql: """
                    INSERT INTO lot (id, product_id, expiry_date, qty_in, qty_left, snoozed_until, handle_ver) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET product_id = excluded.product_id, expiry_date = excluded.expiry_date,
                      qty_in = excluded.qty_in, qty_left = excluded.qty_left, snoozed_until = excluded.snoozed_until,
                      handle_ver = excluded.handle_ver
                    """, arguments: [l.id.uuidString, l.productId.uuidString, l.expiryDate?.description, l.qtyIn, l.qtyLeft,
                                     l.snoozedUntil?.description, l.handleVer])
            }
        }
    }

    // MARK: - 查

    /// S22c：要有图的商品（`image_ver > 0`、未归档）和它们的图片版本，预取用。不在主线程调
    public func imageWants() throws -> [ImageKey] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, image_ver FROM product WHERE image_ver > 0 AND archived = 0").compactMap { r in
                (r["id"] as String?).flatMap(UUID.init(uuidString:)).map { ImageKey($0, r["image_ver"]) }
            }
        }
    }

    public func product(_ id: UUID) throws -> Product? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM product WHERE id = ?", arguments: [id.uuidString]).map(Self.productFrom)
        }
    }

    public func productPrivate(_ id: UUID) throws -> ProductPrivate? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM product_private WHERE product_id = ?", arguments: [id.uuidString]).map(Self.privateFrom)
        }
    }

    /// 测试用（表名直接拼进 SQL，不对外）
    func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    static let lookupSQL = """
        SELECT b.barcode, b.product_id, b.pack_qty, b.unit_name, b.pack_price_fen, p.*
        FROM barcode b JOIN product p ON p.id = b.product_id WHERE b.barcode = ?
        """
    /// 条码是主键：用 [输入, 输入 + U+10FFFF) 的范围走索引，只扫前缀区间；substr 再精确比对一次
    static let prefixMatchSQL = """
        SELECT b.barcode, b.product_id, b.pack_qty, b.unit_name, b.pack_price_fen, p.*
        FROM barcode b JOIN product p ON p.id = b.product_id
        WHERE b.barcode >= ? AND b.barcode < ? AND substr(b.barcode, 1, ?) = ? AND p.archived = 0
        ORDER BY b.barcode
        """

    /// 扫到一个码：条码 → 商品和换算（主键查找）。没登记过返回 nil。
    /// **有意不过滤已停用的商品**（`prefixMatch` / `searchByName` 过滤）：扫到实物上的码总要认出是什么，
    /// 停用商品扫到后怎么处理由 S16 定，界面看 `product.archived`。
    public func lookup(barcode: String) throws -> PackConversion? {
        try writer.read { db in
            try Row.fetchOne(db, sql: Self.lookupSQL, arguments: [barcode]).map(Self.conversionFrom)
        }
    }

    /// 手输条码前缀匹配（§5.5）：满 8 位起，取出所有以输入为前缀的条码，交给 `BarcodeMatch`。
    public func prefixMatch(_ input: String) throws -> BarcodeMatch.Result {
        guard input.count >= BarcodeMatch.minPrefixLength else { return .notListed }
        let rows = try writer.read { db in
            // 条码是主键：用 [输入, 输入 + U+10FFFF) 的范围走索引，只扫前缀区间；substr 再精确比对一次
            try Row.fetchAll(db, sql: Self.prefixMatchSQL, arguments: [input, input + "\u{10FFFF}", input.count, input])
        }
        return try BarcodeMatch.match(input: input, among: rows.map(Self.conversionFrom))
    }

    /// 按名称找（设计稿 15b）：名称包含输入的、没停用的商品，每个「商品 + 换算 + 卖价 + 单位名」一行，
    /// 代表条码取最小的那个。一个商品有两个单件码只出一行，卖价就是商品的卖价。结果不带库存字样。
    public func searchByName(_ text: String, limit: Int = 50) throws -> [PackConversion] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.barcode, b.product_id, b.pack_qty, b.unit_name, b.pack_price_fen, p.*
                FROM product p JOIN barcode b ON b.product_id = p.id
                WHERE instr(p.name, ?) > 0 AND p.archived = 0
                ORDER BY p.name, p.id, b.pack_qty, b.barcode
                """, arguments: [q])
        }
        var seen = Set<Basket.MergeKey>()
        var out: [PackConversion] = []
        for c in try rows.map(Self.conversionFrom) where seen.insert(try Basket.MergeKey(c)).inserted {
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }

    /// 显示用库存：基线（`product_private.stock_qty`，只由拉取更新）+ 当前店在本机的全部未确认 op 的增减
    /// （包括同店以前的会话留在恢复队列里的；别的店的不算）。挂在已经 remap 成这个商品的旧 id 上的增减也算进来（S22a）。
    /// 收银员手机没有基线，返回 nil（界面本来也不显示库存）。
    public func displayStock(_ productId: UUID) throws -> DisplayStock? {
        try writer.read { db in
            guard let s = try Self.currentSession(db), s.holdsPrivateData,
                  let base = try Int64.fetchOne(db, sql: "SELECT stock_qty FROM product_private WHERE product_id = ?",
                                                arguments: [productId.uuidString])
            else { return nil }
            let pending = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(e.qty_delta), 0) FROM outbox_effect e
                JOIN outbox o ON o.store_id = e.store_id AND o.id = e.op_id
                WHERE e.store_id = ?1
                  AND (o.status = 'pending' OR EXISTS (SELECT 1 FROM effect_hold h
                       WHERE h.store_id = e.store_id AND h.op_id = e.op_id AND h.product_id = e.product_id))
                  AND (e.product_id = ?2
                       OR e.product_id IN (SELECT old_id FROM product_remap WHERE store_id = ?1 AND new_id = ?2))
                """, arguments: [s.storeId.uuidString, productId.uuidString]) ?? 0
            return DisplayStock(baselineQty: base, pendingDelta: pending)
        }
    }

    // MARK: - 行 → 模型

    static func productFrom(_ r: Row) throws -> Product {
        try Product(id: try parseUUID(r["id"]), name: r["name"], baseUnit: r["base_unit"], priceFen: Fen(r["price_fen"]),
                    needsReview: r["needs_review"], trackExpiry: r["track_expiry"], imageVer: r["image_ver"], archived: r["archived"])
    }

    static func privateFrom(_ r: Row) throws -> ProductPrivate {
        try ProductPrivate(productId: try parseUUID(r["product_id"]), stockQty: r["stock_qty"], stockValueFen: Fen(r["stock_value_fen"]),
                           lastCostFen: (r["last_cost_fen"] as Int64?).map(Fen.init), costKnown: r["cost_known"],
                           stockVer: r["stock_ver"], lowAt: r["low_at"], expiryWarnDays: r["expiry_warn_days"],
                           shelfLifeMonths: r["shelf_life_months"])
    }

    static func conversionFrom(_ r: Row) throws -> PackConversion {
        let p = try productFrom(r)
        let b = try BarcodeRecord(barcode: r["barcode"], productId: try parseUUID(r["product_id"]), packQty: r["pack_qty"],
                                  unitName: r["unit_name"], packPriceFen: (r["pack_price_fen"] as Int64?).map(Fen.init))
        return try PackConversion(product: p, barcode: b)
    }
}
