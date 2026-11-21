import Foundation
import Observation
import ShopCore

/// 进货页（06a / 06b / 06c）的状态和动作。不碰界面，单元测试直接测它。
///
/// - 扫到的码（相机、扫码枪、手输都走 `ScanHub`）→ 商品卡 +「进了几箱」「每箱多少钱」；标签随单位变（箱 / 条 / 瓶）。
///   整件码按码上的换算入账（5 箱 × 24 = 120 罐）。数量键盘没有小数点。
/// - 蓝卡：一共、入账多少、每个进价、「加上原来的，平均进价」——全部由 ShopCore 的 `StockInPreview` 算（整数分），
///   平均只是预计值，不写入流水。
/// - 管保质期的商品出现到期日区：直接填到期日，或填生产日期 + 保质期月数（`CalendarDate.adding(months:)`）。
///   年月日用自家键盘，填满自动跳格；年份默认今年；保质期月数记住上次的值（按商品）。
/// - 没登记的码：进货必须走完 04b（新商品登记页从进货进来没有「存好，接着卖」）；挂整件码（05）存好后直接接着进货。
/// - 「记进货」：`LocalDB.recordStockIn` 一个事务写流水和 `stock_in` op。进价填 0 要再确认一次。
@MainActor @Observable
final class StockInModel {
    enum Field: Hashable { case qty, cost, year, month, day, months }
    enum ExpiryMode: Hashable { case direct, produced }

    enum Notice: Equatable {
        case unknownBarcode(String)
        case rejected(String)
        case saved(String)
        case registered(String)
        /// 04b 没填数量（或填 0）：只登记了商品，库存还没记，接着在进货页填这一批（PR #31 Fable 必须改 2）
        case registeredNoStock(String)

        var text: String {
            switch self {
            case .unknownBarcode(let c): "这个码还没登记：\(c)"
            case .rejected(let why): "记不了：\(why)"
            case .saved(let what): "记好了：\(what)"
            case .registered(let name): "登记好了：\(name)，刚填的库存已记上"
            case .registeredNoStock(let name): "登记好了：\(name)，库存还没记，接着填这一批"
            }
        }
        var isError: Bool {
            switch self { case .unknownBarcode, .rejected: true; case .saved, .registered, .registeredNoStock: false }
        }
    }

    struct RegisterRequest: Identifiable, Hashable {
        let code: String
        var id: String { code }
    }

    let db: LocalDB
    /// 能不能登记新商品（家用 / 审核）。收银员根本进不来这一页
    var canRegister = true
    var registerCode: RegisterRequest?
    var accepting = true
    private let defaults: UserDefaults
    private let today: CalendarDate

    private(set) var conversion: PackConversion?
    private(set) var baseline: ProductPrivate?
    private(set) var stockBefore: Int64?
    /// 这一样在本机有没上传的库存变动（§14 S19-1）
    private(set) var hasPendingStock = false
    private(set) var qtyText = ""
    private(set) var cost = YuanInput()
    var active: Field? = .qty
    var expiryMode: ExpiryMode = .produced
    private(set) var year = ""
    private(set) var month = ""
    private(set) var day = ""
    private(set) var monthsText = ""
    /// 「不知道，先不填」
    var expiryUnknown = false
    /// 进价填 0 时等人确认（「进价是 0 元，确定吗」）
    private(set) var confirmZeroCost = false
    private(set) var notice: Notice?
    private(set) var noticeSeq = 0
    private(set) var pendingCount: Int
    private(set) var commitCount = 0
    var onPendingChange: ((Int) -> Void)?

    /// 上海时区的今天（年份默认今年）
    static func shanghaiToday(_ now: Date) -> CalendarDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return (try? CalendarDate(year: c.year ?? 2026, month: c.month ?? 1, day: c.day ?? 1)) ?? (try! CalendarDate("2026-01-01"))
    }

    init(db: LocalDB, today: CalendarDate, defaults: UserDefaults = .standard) {
        self.db = db
        self.today = today
        self.defaults = defaults
        pendingCount = (try? db.pendingOps().count) ?? 0
    }

    // MARK: - 读

    var product: Product? { conversion?.product }
    /// 这个码的单位（箱 / 条 / 瓶）
    var packUnit: String { conversion?.barcode.unitName ?? "件" }
    var baseUnit: String { product?.baseUnit ?? "个" }
    var qtyLabel: String { "进了几\(packUnit)" }
    var costLabel: String { "每\(packUnit)多少钱" }
    var packCount: Int64? { Int64(qtyText).flatMap { $0 > 0 ? $0 : nil } }
    var costFen: Int64? { cost.fen }
    var showsExpiry: Bool { product?.trackExpiry ?? false }
    var keypadShowsDot: Bool { active == .cost }
    var editingDate: Bool { [.year, .month, .day, .months].contains(active) }

    /// 商品卡第二行：「单罐卖 ¥3.00　店里还有 6 罐」
    var cardSubtitle: String {
        guard let p = product else { return "" }
        var s = "单\(p.baseUnit)卖 ¥\(Money.yuanString(Int(p.priceFen.raw)))"
        if let q = stockBefore { s += "　店里还有 \(q) \(p.baseUnit)" }
        return s
    }

    /// 黄签「整箱码　1 箱 = 24 罐」；单件码没有
    var packBadge: String? {
        guard let c = conversion, c.packQty > 1 else { return nil }
        return "整\(c.barcode.unitName)码　1 \(c.barcode.unitName) = \(c.packQty) \(baseUnit)"
    }

    /// 蓝卡（件数和单价都填了、不超上限时才有）
    var preview: StockInPreview? {
        guard let c = conversion, let n = packCount, let f = costFen, !cost.overLimit else { return nil }
        return try? StockInPreview(conversion: c, packCount: n, unitCostFen: Fen(f), baseline: baseline, stockBefore: stockBefore)
    }

    var totalText: String? { preview.map { "¥" + Money.yuanString(Int($0.totalFen.raw)) } }
    /// 「入账 120 罐，每罐进价 ¥2.00」
    var entryLine: String? {
        preview.map { "入账 \($0.baseQty) \(baseUnit)，每\(baseUnit)进价 ¥\(Money.yuanString(Int($0.batchUnitCostFen.raw)))" }
    }
    /// 「加上原来的，平均进价 ¥2.01」（仅供显示；进价未知或库存不为正时没有）。
    /// 本机有没上传的库存变动时也没有：基线货值配不上临时库存，除出来是错的（§14 S19-1）
    var averageLine: String? {
        guard !hasPendingStock else { return nil }
        return preview?.averageCostFen.map { "加上原来的，平均进价 ¥\(Money.yuanString(Int($0.raw)))" }
    }

    /// 输入超了上限时的一句话（没填完不算错）
    var problem: String? {
        if let n = Int64(qtyText), n > Limits.maxPackCount { return "一次最多进 \(Limits.maxPackCount) \(packUnit)" }
        if cost.overLimit { return "每\(packUnit)最多 ¥\(Money.yuanString(Int(Limits.maxFen)))" }
        guard let c = conversion, let n = packCount else { return nil }
        let (base, o) = c.packQty.multipliedReportingOverflow(by: n)
        if o || base > Limits.maxBaseQty { return "一次最多入账 \(Limits.maxBaseQty) \(baseUnit)" }
        if let f = costFen {
            let (t, o2) = f.multipliedReportingOverflow(by: n)
            if o2 || t > Limits.maxFen { return "一笔最多 ¥\(Money.yuanString(Int(Limits.maxFen)))，分两笔记" }
        }
        return nil
    }

    var shelfMonths: Int64? { Int64(monthsText).flatMap { (1...Limits.maxShelfLifeMonths).contains($0) ? $0 : nil } }

    /// 填好的日子（直接填的到期日或生产日期）；没填是 nil，填了一半或不是真的日子抛错
    private func enteredDate() throws -> CalendarDate? {
        if month.isEmpty && day.isEmpty { return nil }
        guard year.count == 4, let y = Int(year), let m = Int(month), let d = Int(day),
              let date = try? CalendarDate(year: y, month: m, day: d)
        else { throw ShopCoreError.invalid("日子不对，年要 4 位，月日要是真的日子") }
        return date
    }

    /// 算出来的到期日（06b「算出来到期 2027-05-12」）
    var computedExpiry: CalendarDate? {
        guard expiryMode == .produced, let start = try? enteredDate(), let m = shelfMonths else { return nil }
        return try? start.adding(months: m)
    }

    /// 这一批记进去的到期日：不管保质期 / 不知道 / 没填 = nil
    func expiryDate() throws -> CalendarDate? {
        guard showsExpiry, !expiryUnknown else { return nil }
        guard let d = try enteredDate() else { return nil }
        switch expiryMode {
        case .direct: return d
        case .produced:
            guard let m = shelfMonths else { throw ShopCoreError.invalid("保质期几个月还没填") }
            return try d.adding(months: m)
        }
    }

    var canCommit: Bool { conversion != nil && preview != nil && problem == nil }

    // MARK: - 扫码

    func handle(_ scan: Scan) -> ScanOutcome {
        guard accepting else { return .ignored }
        notice = nil
        do {
            guard let conv = try db.lookup(barcode: scan.code) else {
                if canRegister, NewProduct.isRegistrable(scan.code) {
                    registerCode = RegisterRequest(code: scan.code)
                } else {
                    show(.unknownBarcode(scan.code))
                }
                return .unknown
            }
            load(conv)
            return .known
        } catch {
            show(.rejected(SellModel.describe(error)))
            return .unknown
        }
    }

    /// 登记页关掉：挂了整件码（05）就接着进这一箱；登记了新商品：04b 记了数量（> 0）出「库存已记上」，
    /// 没记数量就接着在进货页填这一批（这时不会重复入账）；返回什么都不做
    func finishRegistration(_ outcome: RegistrationOutcome?) {
        registerCode = nil
        guard let outcome else { return }
        switch outcome {
        case .linked(let conv): load(conv)
        case .registered(let conv, _):
            if ((try? db.displayStock(conv.product.id))?.qty ?? 0) > 0 {
                show(.registered(conv.product.name))
            } else {
                load(conv)
                show(.registeredNoStock(conv.product.name))
            }
        }
        refreshPending()
    }

    /// 换成这个码（新扫到的码替换没记的输入）
    func load(_ conv: PackConversion) {
        conversion = conv
        baseline = try? db.productPrivate(conv.product.id)
        let stock = try? db.displayStock(conv.product.id)
        stockBefore = stock?.qty
        hasPendingStock = (stock?.pendingDelta ?? 0) != 0
        qtyText = ""
        cost = YuanInput()
        confirmZeroCost = false
        active = .qty
        expiryUnknown = false
        expiryMode = .produced
        year = String(today.year)
        month = ""; day = ""
        monthsText = rememberedMonths(conv.product.id).map(String.init) ?? ""
    }

    /// 「重新扫」：清掉当前商品
    func clear() {
        conversion = nil
        baseline = nil
        stockBefore = nil
        hasPendingStock = false
        qtyText = ""
        cost = YuanInput()
        confirmZeroCost = false
        active = .qty
    }

    // MARK: - 键盘

    func key(_ k: Keypad.Key) {
        guard let f = active else { return }
        confirmZeroCost = false
        switch f {
        case .cost: cost.key(k)
        case .qty: qtyText = Self.digits(qtyText, k, max: 6)
        case .months: monthsText = Self.digits(monthsText, k, max: 4)
        case .year:
            year = Self.digits(year, k, max: 4, keepZero: true)
            if year.count == 4, case .digit = k { active = .month }
        case .month:
            month = Self.digits(month, k, max: 2, keepZero: true)
            if month.count == 2, case .digit = k { active = .day }
        case .day:
            day = Self.digits(day, k, max: 2, keepZero: true)
        }
    }

    /// 只收数字：没有小数点；件数开头的 0 去掉（年月日的 0 保留：「06」月）
    static func digits(_ s: String, _ k: Keypad.Key, max: Int, keepZero: Bool = false) -> String {
        switch k {
        case .dot: return s
        case .delete: return String(s.dropLast())
        case .digit(let d):
            var t = s
            if !keepZero, t == "0" { t = "" }
            return t.count >= max ? t : t + String(d)
        }
    }

    /// 点某一格开始填；点年月日时那一格从头填
    func focus(_ f: Field) {
        active = f
        if f == .month { month = "" }
        if f == .day { day = "" }
    }

    /// 06c「填好了」：收起键盘
    func doneEditing() { active = nil }

    // MARK: - 记进货

    /// 「记进货」。进价是 0 的第一次只请人确认，返回 false；`confirmedZero` 为真时照记。
    @discardableResult
    func commit(confirmedZero: Bool = false, at now: Date = Date()) -> Bool {
        guard canCommit, let conv = conversion, let n = packCount, let f = costFen else { return false }
        if f == 0, !confirmedZero {
            confirmZeroCost = true
            return false
        }
        confirmZeroCost = false
        do {
            let payload = try StockInPayload(entryId: UUID(), conversion: conv, packCount: n, unitCostFen: Fen(f),
                                             expiryDate: try expiryDate())
            try db.recordStockIn(payload, name: conv.product.name, unitName: conv.barcode.unitName, at: now)
            if showsExpiry, expiryMode == .produced, let m = shelfMonths { remember(months: m, for: conv.product.id) }
            commitCount += 1
            let what = "\(conv.product.name) \(n) \(conv.barcode.unitName)"
            clear()
            show(.saved(what))
            refreshPending()
            return true
        } catch {
            show(.rejected(SellModel.describe(error)))
            return false
        }
    }

    func cancelZeroCost() { confirmZeroCost = false }

    // MARK: - 其他

    private func show(_ n: Notice) {
        notice = n
        noticeSeq &+= 1
    }

    func dismissNotice(seq: Int) { if seq == noticeSeq { notice = nil } }

    func refreshPending() {
        pendingCount = (try? db.pendingOps().count) ?? pendingCount
        onPendingChange?(pendingCount)
    }

    /// 保质期月数记住上次的值：按商品记在本机；没记过用商品上的设置
    static func monthsKey(_ id: UUID) -> String { "stockIn.shelfMonths.\(id.uuidString)" }

    private func rememberedMonths(_ id: UUID) -> Int64? {
        let v = defaults.integer(forKey: Self.monthsKey(id))
        if v > 0 { return Int64(v) }
        return baseline?.shelfLifeMonths
    }

    private func remember(months: Int64, for id: UUID) {
        defaults.set(Int(months), forKey: Self.monthsKey(id))
    }

    /// 测试夹具用：直接填
    func fill(qty: String? = nil, cost: String? = nil) {
        if let qty { qtyText = qty.filter(\.isNumber) }
        if let cost { self.cost = YuanInput(cost) }
    }

    func fillDate(_ s: String, months: String? = nil) {
        let parts = s.split(separator: "-").map(String.init)
        if parts.count == 3 { year = parts[0]; month = parts[1]; day = parts[2] }
        if let months { monthsText = months }
    }
}
