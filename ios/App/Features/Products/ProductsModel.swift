import Foundation
import Observation
import ShopCore

/// 11 商品列表：本机商品表 + 筛选（全部 / 快过期 / 待确认 / 快没货 / 没进价）+ 搜名称或条码。离线也能看。
/// 读库都在后台线程（§8 S22a）。
@MainActor @Observable
final class ProductsModel {
    let db: LocalDB
    private(set) var items: [ProductListItem] = []
    private(set) var counts = ProductCounts()
    private(set) var codes: [UUID: Set<String>] = [:]
    private(set) var loaded = false
    var filter: ProductFilter = .all
    var query = ""

    init(db: LocalDB) { self.db = db }

    /// 现在显示的行：先按标签筛，再按搜索框筛。「全部」把已停用的也列在最后（点进去能「重新卖」）
    var shown: [ProductListItem] {
        items.filter { it in
            (filter == .all ? true : it.matches(filter))
                && LocalDB.searchMatches(it, query: query, barcodes: codes[it.id] ?? [])
        }
    }

    /// 标签的顺序和文字（设计稿 11：全部、快过期、待确认、快没货、没进价）
    static let chips: [(ProductFilter, String)] = [(.all, "全部"), (.expiring, "快过期"), (.needsReview, "待确认"),
                                                   (.lowStock, "快没货"), (.noCost, "没进价")]

    func reload(today: CalendarDate) async {
        let db = db
        let r = await Task.detached { () -> (([ProductListItem], ProductCounts), [UUID: Set<String>])? in
            guard let list = try? db.productList(today: today), let codes = try? db.barcodesByProduct() else { return nil }
            return ((list.items, list.counts), codes)
        }.value
        guard let r else { return }
        items = r.0.0; counts = r.0.1; codes = r.1; loaded = true
    }

    // MARK: 行上的字（纯函数，单元测试逐条测）

    /// 第二行：「进价 ¥2.29 还剩 75 盒」。待确认的不写（第三行写「进价和库存没填」）；库存 ≤ 0 写「没货了」
    static func stockLine(_ it: ProductListItem) -> String? {
        guard !it.product.needsReview, let q = it.stockQty else { return nil }
        let cost = it.unitCostFen.map { "进价 ¥\(Money.yuanString(Int($0.raw)))" } ?? "进价没填"
        if it.lowStock { return cost }   // 库存放进黄块（`lowStockBadge`）
        return q <= 0 ? "\(cost) 没货了" : "\(cost) 还剩 \(q) \(it.product.baseUnit)"
    }

    /// 快没货的黄块：「还剩 2 罐」，≤ 0 写「没货了」
    static func lowStockBadge(_ it: ProductListItem) -> String? {
        guard it.lowStock, let q = it.stockQty else { return nil }
        return q <= 0 ? "没货了" : "还剩 \(q) \(it.product.baseUnit)"
    }

    /// 「最早一批 11-24」
    static func earliestText(_ it: ProductListItem) -> String? {
        it.earliestExpiry.map { "最早一批 " + String(format: "%02d-%02d", $0.month, $0.day) }
    }

    /// 「整箱码 1 箱 = 24 罐」「整条码 1 条 = 10 包」（只写第一个整件码）
    static func packText(_ it: ProductListItem) -> String? {
        it.packs.first.map { "整\($0.unitName)码 1 \($0.unitName) = \($0.packQty) \(it.product.baseUnit)" }
    }

    /// 待确认的来历：卖出时服务器自动建的（卖价 0、没有单件码，§14 S05-9）；否则是收银员临时登记的（04c）
    static func reviewSource(_ it: ProductListItem) -> String {
        it.product.priceFen == .zero && !it.hasUnitBarcode ? "卖出时自动建的" : "收银员登记"
    }
}

// MARK: - 22 改商品

/// 22 改商品：名称、卖价、快没货提醒线、保质期设置、整箱码（删）、不卖了。平均进价只读。
/// 存的时候只发改了的字段（`product_edit` 逐字段后写者赢，S04-4），本地先改，扫码、按名称找马上用新价。
@MainActor @Observable
final class EditProductModel {
    let db: LocalDB
    private(set) var detail: ProductDetail
    let storeLowDefault: Int64

    var name: String { didSet { error = nil } }
    var price: YuanInput { didSet { error = nil; confirmZeroPrice = false } }
    var lowAt: Int
    var trackExpiry: Bool
    var warnDays: Int
    /// 保质期几个月；没填过是 nil（界面写「没填」，点了才从 12 个月起），没动过就不发
    var shelfMonths: Int?
    private let initialLowAt: Int
    private let initialShelfMonths: Int?
    /// 保质期没填时点「填」从这里起
    static let defaultShelfMonths = 12

    private(set) var error: String?
    private(set) var confirmZeroPrice = false
    /// 等人确认要删的整箱码
    var confirmUnlink: PackAsk?
    struct PackAsk: Identifiable { let record: BarcodeRecord; var id: String { record.barcode } }
    /// 等人确认「不卖了」
    var confirmArchive = false

    init(db: LocalDB, detail: ProductDetail, storeLowDefault: Int64) {
        self.db = db; self.detail = detail; self.storeLowDefault = storeLowDefault
        let p = detail.product, v = detail.private
        name = p.name
        price = YuanInput(Money.yuanString(Int(p.priceFen.raw)))
        initialLowAt = Int(v?.lowAt ?? storeLowDefault)
        lowAt = initialLowAt
        trackExpiry = p.trackExpiry
        warnDays = Int(v?.expiryWarnDays ?? 7)
        initialShelfMonths = v?.shelfLifeMonths.map(Int.init)
        shelfMonths = initialShelfMonths
    }

    var product: Product { detail.product }
    var archived: Bool { detail.product.archived }

    /// 平均进价（只读）：进价已知才有
    var averageCostText: String {
        guard let v = detail.private, v.costKnown, let u = try? v.unitCost() else { return "没填" }
        return Money.yuanString(Int(u.raw))
    }

    var unit: String { detail.product.baseUnit }

    /// 「1 箱 = 24 盒，整箱卖 ¥72」；没填整箱价写「按单价 × 24 算」
    func packLine(_ b: BarcodeRecord) -> String {
        let price = b.packPriceFen.map { "整\(b.unitName)卖 ¥\(Money.yuanString(Int($0.raw)))" } ?? "按单价 × \(b.packQty) 算"
        return "1 \(b.unitName) = \(b.packQty) \(unit)，\(price)"
    }

    /// 要发的 `product_edit`：只带改了的字段；什么都没改返回 nil
    func edit() throws -> ProductEditPayload? {
        let p = detail.product
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw ShopCoreError.invalid("名称不能空着") }
        guard let f = price.fen else { throw ShopCoreError.invalid("卖价不能空着") }
        guard f <= Limits.maxFen else { throw ShopCoreError.invalid("卖价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))") }
        let v = detail.private
        let trackChanged = trackExpiry != p.trackExpiry
        let e = try ProductEditPayload(
            productId: p.id,
            name: n != p.name ? .set(n) : .unchanged,
            priceFen: f != p.priceFen.raw ? .set(Fen(f)) : .unchanged,
            lowAt: lowAt != initialLowAt ? .set(Int64(lowAt)) : .unchanged,
            trackExpiry: trackChanged ? .set(trackExpiry) : .unchanged,
            expiryWarnDays: trackExpiry && Int64(warnDays) != (v?.expiryWarnDays ?? 7) ? .set(Int64(warnDays)) : .unchanged,
            shelfLifeMonths: trackExpiry && shelfMonths != nil && shelfMonths != initialShelfMonths ? .set(shelfMonths.map(Int64.init)) : .unchanged)
        return e
    }

    /// 「存好」。卖价是 0 第一次只请人确认，返回 false；存好了返回 true
    @discardableResult
    func save(confirmedZero: Bool = false, at now: Date = Date()) async -> Bool {
        // 什么都没改：不发 op（`ProductEditPayload` 要求至少一个字段）
        if noChanges() { return true }
        let payload: ProductEditPayload
        do { guard let p = try edit() else { return true }; payload = p } catch { self.error = Self.describe(error); return false }
        if case .set(let f) = payload.priceFen, f == .zero, !confirmedZero { confirmZeroPrice = true; return false }
        confirmZeroPrice = false
        return await write { db in try db.editProduct(payload, at: now) }
    }

    /// 名称、卖价合规且一样都没改
    private func noChanges() -> Bool {
        let p = detail.product
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let f = price.fen, f <= Limits.maxFen else { return false }
        return n == p.name && f == p.priceFen.raw && lowAt == initialLowAt && trackExpiry == p.trackExpiry
            && (!trackExpiry || (Int64(warnDays) == (detail.private?.expiryWarnDays ?? 7) && shelfMonths == initialShelfMonths))
    }

    func cancelZeroPrice() { confirmZeroPrice = false }

    /// 「不卖了」/「重新卖」（先确认）
    @discardableResult
    func setArchived(_ on: Bool, at now: Date = Date()) async -> Bool {
        let id = detail.product.id
        return await write { db in try db.editProduct(try ProductEditPayload(productId: id, archived: .set(on)), at: now) }
    }

    /// 整箱码的「删」（先确认）
    func unlink(_ b: BarcodeRecord, at now: Date = Date()) async {
        _ = await write { db in try db.unlinkPack(barcode: b.barcode, productId: b.productId, at: now) }
        if let d = await Self.load(db, detail.product.id) { detail = d }
    }

    private func write(_ f: @escaping @Sendable (LocalDB) throws -> Void) async -> Bool {
        let db = db
        let err = await Task.detached { () -> String? in
            do { try f(db); return nil } catch { return Self.describe(error) }
        }.value
        error = err
        return err == nil
    }

    nonisolated static func load(_ db: LocalDB, _ id: UUID) async -> ProductDetail? {
        await Task.detached { try? db.productDetail(id) }.value
    }

    nonisolated static func describe(_ e: Error) -> String {
        if case ShopCoreError.invalid(let m) = e { return m }
        return "没存上，再试一次"
    }
}

// MARK: - 22b 待确认补全

/// 22b 交补全的通道：真机上先排空 outbox 再单独交（`SyncEngine.drainForOnline / submitOnline`），测试里换成假的
struct ReviewBackend: Sendable {
    var drain: @Sendable () async throws -> Void
    var submit: @Sendable (Op) async throws -> OnlineOutcome
    /// 排空成功后不管交没交（挂码被拒、已经不是待确认……）都调一次：真机上让停掉的定时同步接着跑
    var finish: @Sendable () async -> Void = {}
}

/// 22b 待确认补全：名称、卖价（收银员填的，不对可以改）、进价（必填，可以填 0）、货架上现在有几个、要管保质期。
/// **必须联网**（§5.6）：先把名称 / 卖价的修改（`product_edit`）和挂码（`barcode_link`）排进 outbox，排空后读服务器现在的
/// 账面版本，再单独交 `product_review_complete`；遇到 `stale` 让人看着新的账面数重新确认（§14 S05-9、§5.6 第 2 条）。
@MainActor @Observable
final class ReviewProductModel {
    enum Phase: Equatable {
        case editing
        case submitting
        /// 别的手机刚又记了账：账上现在是 `stockQty`，问「你数的还对吗」
        case stale(stockQty: Int64, stockVer: Int64)
        case done
    }

    let db: LocalDB
    private(set) var detail: ProductDetail
    let backend: ReviewBackend?

    var name: String { didSet { error = nil } }
    var price: YuanInput { didSet { error = nil; confirmZero = nil } }
    var cost = YuanInput() { didSet { error = nil; confirmZero = nil } }
    var counted: Int
    var trackExpiry: Bool
    /// 没有单件码的（卖出时自动建的）挂一个：扫码枪扫进来或手输
    var barcode = "" { didSet { if barcode != Self.sanitize(barcode) { barcode = Self.sanitize(barcode) }; error = nil } }

    private(set) var phase: Phase = .editing
    #if DEBUG
    /// `-uiReviewStaleOnce`：第一次交补全时带旧一版的版本（联调对着真服务器演 stale）
    var debugStaleOnce = false
    #endif
    private(set) var error: String?
    /// 卖价或进价填了 0：再问一句（和进货页、04a 一样）
    enum ZeroField: Equatable { case price, cost }
    private(set) var confirmZero: ZeroField?
    private var zeroConfirmed: Set<ZeroField> = []
    /// 已经排进 outbox 的修改（重按「确认」不重复排）
    private var queuedName: String?
    private var queuedPrice: Int64?
    private var linkOp: UUID?
    private var linkedCode: String?

    init(db: LocalDB, detail: ProductDetail, backend: ReviewBackend?) {
        self.db = db; self.detail = detail; self.backend = backend
        let p = detail.product
        autoCreated = p.priceFen == .zero && !detail.hasUnitBarcode
        name = p.name
        // 卖出时自动建的卖价是 0：框里留空，让人先填卖价（§14 S05-9）
        price = p.priceFen == .zero ? YuanInput() : YuanInput(Money.yuanString(Int(p.priceFen.raw)))
        counted = Int(max(0, detail.stockQty ?? 0))
        trackExpiry = p.trackExpiry
    }

    var product: Product { detail.product }
    var unit: String { detail.product.baseUnit }
    /// 打开页面时是不是卖出时服务器自动建的（卖价 0、没单件码，§14 S05-9）；补全过程中填了价、挂了码也不变
    let autoCreated: Bool
    var needsBarcode: Bool { !detail.hasUnitBarcode && linkedCode == nil }

    static func sanitize(_ s: String) -> String {
        String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(Limits.maxBarcodeLength))
    }

    /// 「确认，存好」。`offline` 时不发任何请求，只提示要联网
    func confirm(offline: Bool, at now: Date = Date()) async {
        guard phase == .editing else { return }
        error = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { error = "名称不能空着"; return }
        guard let p = price.fen else { error = "先填卖多少钱"; return }
        guard p <= Limits.maxFen else { error = "卖价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))"; return }
        guard let c = cost.fen else { error = "进价要填（真是白拿的填 0）"; return }
        guard c <= Limits.maxFen else { error = "进价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))"; return }
        if p == 0, !zeroConfirmed.contains(.price) { confirmZero = .price; return }
        if c == 0, !zeroConfirmed.contains(.cost) { confirmZero = .cost; return }
        let code = barcode
        if needsBarcode, !code.isEmpty, !BarcodeCharset.isValid(code) { error = "条码只能是数字和字母"; return }
        guard let backend, !offline else { error = "要联网才能补全，连上网再点"; return }
        phase = .submitting
        // 1. 名称、卖价、挂码排进 outbox（本地先改）；交补全前随 outbox 一起传上去
        let pid = product.id, db = db
        let editName = n != (queuedName ?? product.name) ? n : nil
        let editPrice = p != (queuedPrice ?? product.priceFen.raw) ? p : nil
        let link = needsBarcode && !code.isEmpty ? code : nil
        // 人是对着页面上这一版的账面数数的：排空后服务器版本变了（别的手机又卖了/进了），先让人重新确认，不拿新版本直接交
        let seenVer = detail.private?.stockVer ?? 0
        let queued = await Task.detached { () -> Result<UUID?, Error> in
            do {
                if editName != nil || editPrice != nil {
                    try db.editProduct(try ProductEditPayload(productId: pid, name: editName.map { .set($0) } ?? .unchanged,
                                                              priceFen: editPrice.map { .set(Fen($0)) } ?? .unchanged), at: now)
                }
                return .success(try link.map { try db.linkUnitBarcode($0, productId: pid, at: now) })
            } catch { return .failure(error) }
        }.value
        switch queued {
        case .failure(let e): phase = .editing; error = EditProductModel.describe(e); return
        case .success(let op):
            if editName != nil { queuedName = n }
            if editPrice != nil { queuedPrice = p }
            if let op { linkOp = op; linkedCode = code; barcode = "" }
        }
        await submit(counted: Int64(counted), costFen: c, baseVer: nil, seenVer: seenVer, at: now)
    }

    /// stale 之后「对，就是 N 个」：带服务器给的新版本重交
    func confirmStale(at now: Date = Date()) async {
        guard case .stale(let q, let v) = phase, let c = cost.fen else { return }
        phase = .submitting
        await submit(counted: Int64(counted), costFen: c, baseVer: (v, q), seenVer: nil, at: now)
    }

    /// stale 之后「再数一下」：回到页面改数，改好再点「确认，存好」
    func recount() { if case .stale = phase { phase = .editing } }

    func acceptZero() {
        if let z = confirmZero { zeroConfirmed.insert(z) }
        confirmZero = nil
    }

    func cancelZero() { confirmZero = nil }

    /// `baseVer`：stale 后人确认过的服务器版本；`seenVer`：第一次交时页面上显示的账面版本（排空后变了就先回 stale 让人确认）
    private func submit(counted: Int64, costFen: Int64, baseVer: (Int64, Int64)?, seenVer: Int64?, at now: Date) async {
        guard let backend else { phase = .editing; return }
        needsResume = false
        await submitSteps(backend, counted: counted, costFen: costFen, baseVer: baseVer, seenVer: seenVer, at: now)
        if needsResume { await backend.finish() }
    }

    /// 排空成功了、但没走到 `backend.submit`（挂码被拒、已经不是待确认、商品不在了……）：结束时要让停掉的定时同步接着跑。
    /// 走到了 submit 就由 submit 自己接着跑（被踢了不能再起同步），这里不再重复
    private var needsResume = false

    private func submitSteps(_ backend: ReviewBackend, counted: Int64, costFen: Int64, baseVer: (Int64, Int64)?, seenVer: Int64?,
                             at now: Date) async {
        let pid = product.id, db = db, track = trackExpiry
        do {
            // 2. 先把本机的账（含上面的修改）传完、拉到底；之后本机的基线就是服务器现在的
            try await backend.drain()
            needsResume = true
            if let op = linkOp, let st = await Task.detached(operation: { try? db.outboxStatus(op) }).value, st.status == .rejected {
                linkOp = nil; linkedCode = nil
                if let d = await EditProductModel.load(db, pid) { detail = d }
                phase = .editing
                error = "这个条码已经登记在别的商品上了，换一个或者不填"
                return
            }
            guard let d = await EditProductModel.load(db, pid) else { phase = .editing; error = "这个商品不在了"; return }
            detail = d
            // 已经不是待确认（上一次其实交上去了、或者别的手机先补全了）：不再交第二次
            guard d.product.needsReview else { phase = .done; return }
            let base = baseVer ?? (d.private?.stockVer ?? 0, d.stockQty ?? 0)
            // 排空拉到了别的手机的新账（版本和人数货时看到的不一样）：不交，先问「账上现在是 N 个，你数的还对吗」
            if baseVer == nil, let seenVer, base.0 != seenVer {
                phase = .stale(stockQty: base.1, stockVer: base.0)
                return
            }
            var ver = base.0
            let qty = base.1
            #if DEBUG
            // 联调（S25LiveUITests）：第一次故意带旧一版的账面版本，让真服务器回 stale
            if debugStaleOnce, baseVer == nil, ver > 0 { ver -= 1; debugStaleOnce = false }
            #endif
            let expiry = try ExpirySettings(trackExpiry: track, expiryWarnDays: d.private?.expiryWarnDays ?? 7,
                                            shelfLifeMonths: d.private?.shelfLifeMonths)
            let op = Op(occurredAt: now, payload: try ProductReviewCompletePayload(
                entryId: UUID(), productId: pid, unitCostFen: Fen(costFen), countedQty: counted, baseVer: ver, baseQty: qty,
                expiry: expiry))
            // 3. 单独交补全（submit 交完自己让同步接着跑）
            needsResume = false
            switch try await backend.submit(op) {
            case .applied, .held: phase = .done
            case .stale(let q, let v): phase = .stale(stockQty: q, stockVer: v)
            case .rejected(let code): phase = .editing; error = Self.rejectMessage(code)
            }
        } catch OnlineSubmitError.outboxNotDrained {
            phase = .editing; error = "还有账没传上去，等传完再补全（看看网）"
        } catch OnlineSubmitError.deletePending {
            phase = .editing; error = "账号在注销中，不能记账"
        } catch OnlineSubmitError.resynced {
            phase = .editing; error = "刚跟服务器重新对了一次账，看一眼再点「确认，存好」"
        } catch let e as ShopCoreError {
            phase = .editing; error = EditProductModel.describe(e)
        } catch {
            phase = .editing; self.error = "没连上，没补全。连上网再点一次"
        }
    }

    static func rejectMessage(_ code: String?) -> String {
        switch code {
        case "forbidden": "这台手机不能补全商品"
        default: "服务器没收（\(code ?? "原因不明")），回头再试"
        }
    }
}

#if DEBUG
extension ReviewBackend {
    /// UI 测试的假通道（`-uiReviewOutcome applied|stale`）：不连服务器。`stale` 第一次回「账上现在是 5 个」、确认后成功；
    /// 成功时把这样商品在本机改成不是待确认（像服务器的拉取带回来那样），列表上「待确认」数减一
    static func fixture(outcome: String, db: LocalDB) -> ReviewBackend {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        return ReviewBackend(
            drain: {},
            submit: { op in
                count.n += 1
                if outcome == "stale", count.n == 1 { return .stale(stockQty: 5, stockVer: 99) }
                guard let p = op.payload as? ProductReviewCompletePayload else { return .rejected(code: "invalid") }
                try await Task.detached { try Self.markReviewed(db, p) }.value
                return .applied
            })
    }

    nonisolated private static func markReviewed(_ db: LocalDB, _ p: ProductReviewCompletePayload) throws {
        guard let prod = try db.product(p.productId) else { return }
        let product: [String: Any] = [
            "id": prod.id.uuidString.lowercased(), "name": prod.name, "base_unit": prod.baseUnit, "price_fen": prod.priceFen.raw,
            "needs_review": false, "track_expiry": prod.trackExpiry, "image_ver": prod.imageVer, "archived": prod.archived, "rev": 1,
            "private": ["stock_qty": p.countedQty, "stock_value_fen": p.countedQty * p.unitCostFen.raw, "last_cost_fen": p.unitCostFen.raw,
                        "cost_known": true, "stock_ver": p.baseVer + 1, "low_at": NSNull(), "expiry_warn_days": 7,
                        "shelf_life_months": NSNull()] as [String: Any]]
        let cur = try db.meta(.catalogCursor).flatMap { Int($0) } ?? 0
        let led = try db.meta(.ledgerCursor).flatMap { Int($0) } ?? 0
        let obj: [String: Any] = [
            "results": [], "changes": ["products": [product], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
            "cursors": ["catalog": cur, "ledger": led], "has_more": ["catalog": false, "ledger": false], "total_products": 0,
            "server_time": Op.formatTimestamp(Date()), "epoch": (try db.meta(.serverEpoch)) ?? UUID().uuidString, "min_build": 0,
            "device": ["role": "family", "label": "测试", "revoked": false], "store": ["name": "测试"]]
        try db.applySyncResponse(try SyncResponse.decode(try JSONSerialization.data(withJSONObject: obj)), sent: nil)
    }
}
#endif
