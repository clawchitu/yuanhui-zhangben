import Foundation
import GRDB

// S25 商品列表（11）、改商品（22）、待确认补全（22b）的本地部分。
//
// - 列表和筛选只读本地库：离线也能看，数和 09 的接口用同一条件（§14 S07-6）。
// - 改商品、删整箱码：本地先改（扫码、按名称找马上用新价），再排 `product_edit` / `barcode_unlink`，同一个事务。
//   单件码不存价（§3.2，plan §14 第 12 条）：卖价只写在商品上，扫任一单件码都读它；整箱码有自己的价就不动。
// - 补全（`product_review_complete`）只能联网，走 `SyncEngine.submitOnline`，不在这里。

/// 11 的筛选标签
public enum ProductFilter: String, CaseIterable, Hashable, Sendable {
    case all, expiring, needsReview, lowStock, noCost
}

/// 11 的一行
public struct ProductListItem: Hashable, Sendable, Identifiable {
    public let product: Product
    /// 显示库存（基线 + 本机未传的增减）；收银员手机没有
    public let stockQty: Int64?
    /// 平均进价（只读，§5.2 的 `u`）；进价未知为 nil
    public let unitCostFen: Fen?
    public let costKnown: Bool
    /// 快没货：与 09 同一条件（§14 S07-6）
    public let lowStock: Bool
    /// 快过期：有批次到了提醒的日子（§5.4 `shouldRemind`，与 09 同一规则）
    public let expiring: Bool
    /// 还没关的批次里最早的到期日（「最早一批 11-24」）
    public let earliestExpiry: CalendarDate?
    /// 整箱 / 整条码（单件码不列）
    public let packs: [BarcodeRecord]
    /// 这个商品有没有单件码（没有的待确认商品，22b 让人挂一个）
    public let hasUnitBarcode: Bool

    public var id: UUID { product.id }

    public func matches(_ f: ProductFilter) -> Bool {
        let live = !product.archived
        switch f {
        case .all: return live
        case .expiring: return live && expiring
        case .needsReview: return live && product.needsReview
        case .lowStock: return lowStock
        case .noCost: return live && !product.needsReview && !costKnown
        }
    }
}

/// 11 顶上各标签的数
public struct ProductCounts: Hashable, Sendable {
    public var all = 0, expiring = 0, needsReview = 0, lowStock = 0, noCost = 0
    public init() {}
    public subscript(_ f: ProductFilter) -> Int {
        switch f {
        case .all: all
        case .expiring: expiring
        case .needsReview: needsReview
        case .lowStock: lowStock
        case .noCost: noCost
        }
    }
}

/// 22 / 22b 一个商品的全部本地数据
public struct ProductDetail: Hashable, Sendable {
    public let product: Product
    public let `private`: ProductPrivate?
    /// 显示库存
    public let stockQty: Int64?
    public let barcodes: [BarcodeRecord]
    public var packs: [BarcodeRecord] { barcodes.filter(\.isPack) }
    public var hasUnitBarcode: Bool { barcodes.contains { !$0.isPack } }
}

extension LocalDB {
    /// 店里默认的快没货提醒线（服务器 `stores.low_stock_default`，同步响应 `store.low_stock_default` 带来）。
    /// 还没从新版服务器拉到过时按建店默认值 3（`0001_init.sql`）
    public static let defaultLowStockDefault: Int64 = 3

    public func lowStockDefault() throws -> Int64 {
        try meta(.lowStockDefault).flatMap { Int64($0) } ?? Self.defaultLowStockDefault
    }

    /// §5.4 的提醒规则（与服务器 `ledger/lots.ts` 的 `shouldRemind` 一致）：有到期日、没关、还剩；
    /// 「过几天再提醒」没到日子不提醒；到期日减提前天数 ≤ 今天就提醒
    public static func shouldRemind(today: CalendarDate, expiry: CalendarDate?, qtyLeft: Int64, snoozedUntil: CalendarDate?,
                                    warnDays: Int64) -> Bool {
        // 和 S27 的快过期清单（20）同一条规则；这里只传没关的批次
        ExpiryRule.shouldRemind(today: today, expiry: expiry, warnDays: warnDays, qtyLeft: qtyLeft, closed: false, snoozedUntil: snoozedUntil)
    }

    /// 快没货（§14 S07-6，与 `reports/today.ts` 同一条件）：没停用、不是待确认、库存动过（`stock_ver > 0`）、
    /// 库存 ≤ 商品自己的提醒线（没设用店里的默认）。库存用显示库存（本机没传的卖出也算）；本机有没传的增减时
    /// 等于库存已经动过（传上去 `stock_ver` 就会 +1）。本机的账传完、拉到底以后与服务器逐条一致；传完之前
    /// 按本机看到的算（例如卖一个又撤掉、增减合计为 0 的新商品，传上去之前不算动过）
    public static func isLowStock(product p: Product, private v: ProductPrivate, stock: DisplayStock, storeDefault: Int64) -> Bool {
        guard !p.archived, !p.needsReview, v.stockVer > 0 || stock.pendingDelta != 0 else { return false }
        return stock.qty <= (v.lowAt ?? storeDefault)
    }

    /// 11 的全部商品（含已停用的，排在最后）和各标签的数。`today` 是上海的今天（快过期用）。
    /// 排序：待确认在前，其余按名称；已停用的最后
    public func productList(today: CalendarDate) throws -> (items: [ProductListItem], counts: ProductCounts) {
        let storeDefault = try lowStockDefault()
        return try writer.read { db in
            let s = try Self.currentSession(db)
            let priv = s?.holdsPrivateData ?? false
            let products = try Row.fetchAll(db, sql: "SELECT * FROM product ORDER BY archived, needs_review DESC, name, id")
                .map(Self.productFrom)
            var privates: [UUID: ProductPrivate] = [:]
            var pending: [UUID: Int64] = [:]
            var lots: [UUID: [(CalendarDate?, Int64, CalendarDate?)]] = [:]
            if priv, let s {
                for r in try Row.fetchAll(db, sql: "SELECT * FROM product_private") {
                    let v = try Self.privateFrom(r); privates[v.productId] = v
                }
                // 本机没传的增减（同 displayStock：当前店的 pending 和还在等新基线的已确认 op；remap 过的旧 id 并到赢家）
                for r in try Row.fetchAll(db, sql: """
                    SELECT COALESCE(m.new_id, e.product_id) AS pid, SUM(e.qty_delta) AS d FROM outbox_effect e
                    JOIN outbox o ON o.store_id = e.store_id AND o.id = e.op_id
                    LEFT JOIN product_remap m ON m.store_id = e.store_id AND m.old_id = e.product_id
                    WHERE e.store_id = ?1
                      AND (o.status = 'pending' OR EXISTS (SELECT 1 FROM effect_hold h
                           WHERE h.store_id = e.store_id AND h.op_id = e.op_id AND h.product_id = e.product_id))
                    GROUP BY pid
                    """, arguments: [s.storeId.uuidString]) {
                    pending[try parseUUID(r["pid"]), default: 0] += r["d"] as Int64
                }
                for r in try Row.fetchAll(db, sql: "SELECT product_id, expiry_date, qty_left, snoozed_until FROM lot") {
                    let e = (r["expiry_date"] as String?).flatMap { try? CalendarDate($0) }
                    let sn = (r["snoozed_until"] as String?).flatMap { try? CalendarDate($0) }
                    lots[try parseUUID(r["product_id"]), default: []].append((e, r["qty_left"], sn))
                }
            }
            var codes: [UUID: [BarcodeRecord]] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT * FROM barcode ORDER BY pack_qty, barcode") {
                let b = try BarcodeRecord(barcode: r["barcode"], productId: try parseUUID(r["product_id"]), packQty: r["pack_qty"],
                                          unitName: r["unit_name"], packPriceFen: (r["pack_price_fen"] as Int64?).map(Fen.init))
                codes[b.productId, default: []].append(b)
            }
            var counts = ProductCounts()
            var items: [ProductListItem] = []
            for p in products {
                let v = privates[p.id]
                let stock = v.map { DisplayStock(baselineQty: $0.stockQty, pendingDelta: pending[p.id] ?? 0) }
                let open = (lots[p.id] ?? []).filter { $0.1 > 0 }
                let expiring = v.map { v in
                    open.contains { Self.shouldRemind(today: today, expiry: $0.0, qtyLeft: $0.1, snoozedUntil: $0.2, warnDays: v.expiryWarnDays) }
                } ?? false
                let low = (v.flatMap { v in stock.map { Self.isLowStock(product: p, private: v, stock: $0, storeDefault: storeDefault) } }) ?? false
                let cs = codes[p.id] ?? []
                let item = ProductListItem(product: p, stockQty: stock?.qty, unitCostFen: try v.flatMap { $0.costKnown ? try $0.unitCost() : nil },
                                           costKnown: v?.costKnown ?? false, lowStock: low, expiring: expiring,
                                           earliestExpiry: open.compactMap(\.0).min(), packs: cs.filter(\.isPack),
                                           hasUnitBarcode: cs.contains { !$0.isPack })
                items.append(item)
                if item.matches(.all) { counts.all += 1 }
                if item.matches(.expiring) { counts.expiring += 1 }
                if item.matches(.needsReview) { counts.needsReview += 1 }
                if item.matches(.lowStock) { counts.lowStock += 1 }
                if priv, item.matches(.noCost) { counts.noCost += 1 }
            }
            return (items, counts)
        }
    }

    /// 11 的搜索框：名称包含，或者条码以输入开头（扫码枪 / 手输条码）。空输入 = 不筛
    public static func searchMatches(_ item: ProductListItem, query: String, barcodes: Set<String>) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if item.product.name.localizedCaseInsensitiveContains(q) { return true }
        return barcodes.contains { $0.hasPrefix(q) }
    }

    /// 各商品挂的全部条码（搜索框按条码找用）
    public func barcodesByProduct() throws -> [UUID: Set<String>] {
        try writer.read { db in
            var out: [UUID: Set<String>] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT barcode, product_id FROM barcode") {
                out[try parseUUID(r["product_id"]), default: []].insert(r["barcode"])
            }
            return out
        }
    }

    /// 22 / 22b 打开时读一个商品
    public func productDetail(_ id: UUID) throws -> ProductDetail? {
        guard let p = try product(id) else { return nil }
        let v = try productPrivate(id)
        let stock = try displayStock(id)
        let codes = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM barcode WHERE product_id = ? ORDER BY pack_qty, barcode", arguments: [id.uuidString])
                .map { r in
                    try BarcodeRecord(barcode: r["barcode"], productId: id, packQty: r["pack_qty"], unitName: r["unit_name"],
                                      packPriceFen: (r["pack_price_fen"] as Int64?).map(Fen.init))
                }
        }
        return ProductDetail(product: p, private: v, stockQty: stock?.qty, barcodes: codes)
    }

    /// 22「存好」/「不卖了」：本地先改，再排 `product_edit`，同一个事务。只改 payload 里带了的字段（S04-4）。
    /// 改基本单位时单件码的单位名跟着改，整件码不动（S04-5）。商品不在本机 → `invalid`，什么都不写。
    public func editProduct(_ edit: ProductEditPayload, at now: Date = Date()) throws {
        let op = Op(occurredAt: now, payload: edit)
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            let id = edit.productId.uuidString
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM product WHERE id = ?)", arguments: [id]) == true
            else { throw invalid("这个商品不在本机") }
            var sets: [String] = [], args: [any DatabaseValueConvertible] = []
            if case .set(let v) = edit.name { sets.append("name = ?"); args.append(v) }
            if case .set(let v) = edit.priceFen { sets.append("price_fen = ?"); args.append(v.raw) }
            if case .set(let v) = edit.baseUnit { sets.append("base_unit = ?"); args.append(v) }
            if case .set(let v) = edit.trackExpiry { sets.append("track_expiry = ?"); args.append(v) }
            if case .set(let v) = edit.archived { sets.append("archived = ?"); args.append(v) }
            if !sets.isEmpty {
                try db.execute(sql: "UPDATE product SET \(sets.joined(separator: ", ")) WHERE id = ?",
                               arguments: StatementArguments(args + [id]))
            }
            if case .set(let v) = edit.baseUnit {
                try db.execute(sql: "UPDATE barcode SET unit_name = ? WHERE product_id = ? AND pack_qty = 1", arguments: [v, id])
            }
            if s.holdsPrivateData {
                var ps: [String] = [], pa: [(any DatabaseValueConvertible)?] = []
                if case .set(let v) = edit.lowAt { ps.append("low_at = ?"); pa.append(v) }
                if case .set(let v) = edit.expiryWarnDays { ps.append("expiry_warn_days = ?"); pa.append(v) }
                if case .set(let v) = edit.shelfLifeMonths { ps.append("shelf_life_months = ?"); pa.append(v) }
                if !ps.isEmpty {
                    try db.execute(sql: "UPDATE product_private SET \(ps.joined(separator: ", ")) WHERE product_id = ?",
                                   arguments: StatementArguments(pa + [id]))
                }
            }
            try Self.enqueue(db, op, session: s, effects: [])
        }
    }

    /// 22 整箱码的「删」：本地去掉这个码，排 `barcode_unlink`，同一个事务。只删整件码（单件码是商品本身，不在这里删）；
    /// 码不在这个商品上 → `invalid`，什么都不写
    public func unlinkPack(barcode: String, productId: UUID, at now: Date = Date()) throws {
        let op = Op(occurredAt: now, payload: try BarcodeUnlinkPayload(barcode: barcode, productId: productId))
        try writer.write { db in
            let s = try Self.requireSession(db)
            try Self.checkCanQueue(db, op, session: s)
            guard let q = try Int64.fetchOne(db, sql: "SELECT pack_qty FROM barcode WHERE barcode = ? AND product_id = ?",
                                             arguments: [barcode, productId.uuidString])
            else { throw invalid("这个码不在这个商品上") }
            guard q > 1 else { throw invalid("单件码不能在这里删") }
            try db.execute(sql: "DELETE FROM barcode WHERE barcode = ?", arguments: [barcode])
            try Self.enqueue(db, op, session: s, effects: [])
        }
    }

    /// 22b：给没有条码的待确认商品（卖出引用未知商品时服务器自动建的，§14 S05-9）挂一个单件码，排 `barcode_link`。
    /// 单件码不带价（§3.2），单位名是商品的基本单位。码已经登记过 → `invalid`，什么都不写。返回 op id（补全前看它有没有被拒）
    @discardableResult
    public func linkUnitBarcode(_ barcode: String, productId: UUID, at now: Date = Date()) throws -> UUID {
        guard BarcodeCharset.isValid(barcode) else { throw invalid("条码只能是数字和字母，最多 \(Limits.maxBarcodeLength) 位") }
        return try writer.write { db in
            let s = try Self.requireSession(db)
            guard let unit = try String.fetchOne(db, sql: "SELECT base_unit FROM product WHERE id = ?", arguments: [productId.uuidString])
            else { throw invalid("这个商品不在本机") }
            let rec = try BarcodeRecord(barcode: barcode, productId: productId, packQty: 1, unitName: unit)
            let op = Op(occurredAt: now, payload: BarcodeLinkPayload(rec))
            try Self.checkCanQueue(db, op, session: s)
            try Self.requireFreeBarcode(db, barcode)
            try db.execute(sql: "INSERT INTO barcode (barcode, product_id, pack_qty, unit_name) VALUES (?, ?, 1, ?)",
                           arguments: [barcode, productId.uuidString, unit])
            try Self.enqueue(db, op, session: s, effects: [])
            return op.id
        }
    }

    /// outbox 里一条 op 现在的结果（22b 补全前看挂码有没有被拒）。不在 outbox 返回 nil
    public func outboxStatus(_ opId: UUID) throws -> (status: OutboxItem.Status, code: String?)? {
        try writer.read { db in
            guard let s = try Self.currentSession(db),
                  let r = try Row.fetchOne(db, sql: "SELECT status, reject_code FROM outbox WHERE store_id = ? AND id = ?",
                                           arguments: [s.storeId.uuidString, opId.uuidString]),
                  let st = OutboxItem.Status(rawValue: r["status"]) else { return nil }
            return (st, r["reject_code"])
        }
    }
}
