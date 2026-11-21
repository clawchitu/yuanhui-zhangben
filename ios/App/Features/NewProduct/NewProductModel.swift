import Foundation
import Observation
import ShopCore

// MARK: - 查名称（协议 + 桩；真实网络在 S21 接 `GET /v1/barcode-lookup/:code`）

enum NameLookupResult: Equatable, Sendable {
    /// 查到了：名称，可能还有规格里的单位（「包」）
    case found(name: String, unit: String?)
    case notFound
    /// 没网（25e）
    case offline
}

protocol ProductNameLookup: Sendable {
    func lookup(_ barcode: String) async -> NameLookupResult
}

/// 桩实现：Debug 下认几个演示码（设计稿 04a 的乐事），其余「没查到」；`offline` 时一律「没网」。
struct StubNameLookup: ProductNameLookup {
    var offline = false

    static let demo: [String: (String, String?)] = {
        #if DEBUG
        ["6924743919211": ("乐事薯片 原味 70g", "包")]
        #else
        [:]
        #endif
    }()

    func lookup(_ barcode: String) async -> NameLookupResult {
        if offline { return .offline }
        guard let (name, unit) = Self.demo[barcode] else { return .notFound }
        return .found(name: name, unit: unit)
    }
}

// MARK: - 元输入（自家键盘）

/// 金额输入框：「元」，整数部分最多 6 位（§5.0 单价上限 ¥999,999.99），小数最多 2 位。全程整数分，不经过浮点；
/// 换算用 `DiscountModel.parseFen`（和抹零面板同一套）。
struct YuanInput: Equatable {
    private(set) var text = ""
    static let maxIntegerDigits = 6

    var fen: Int64? { DiscountModel.parseFen(text) }
    /// 超 §5.0 上限（整数 6 位以内只有 999999.99 以上才会超，等于上限时放行）
    var overLimit: Bool { (fen ?? 0) > Limits.maxFen }
    var isEmpty: Bool { text.isEmpty }

    init(_ text: String = "") {
        for c in text {
            if c == "." { key(.dot) } else if let d = c.wholeNumberValue, c.isASCII { key(.digit(d)) }
        }
    }

    mutating func key(_ k: Keypad.Key) {
        switch k {
        case .delete: if !text.isEmpty { text.removeLast() }
        case .dot:
            if text.contains(".") { return }
            text = text.isEmpty ? "0." : text + "."
        case .digit(let d):
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 2 {
                if parts[1].count >= 2 { return }
            } else if text == "0" {
                text = ""
            } else if text.count >= Self.maxIntegerDigits {
                return
            }
            text += String(d)
        }
    }

    mutating func clear() { text = "" }
}

/// 只收数字的输入（数量、年月日）：去掉别的字符、限位数。系统数字键盘、粘贴进来的都过一遍
enum DigitsInput {
    static func sanitize(_ s: String, maxDigits: Int) -> String {
        String(s.filter { $0.isASCII && $0.isNumber }.prefix(maxDigits))
    }
}

// MARK: - 新商品登记（04a / 04b / 04c / 25e）

/// 新商品登记页的状态和动作。不碰界面，单元测试直接测它。
///
/// - 家用：04a 填名称和卖价 →「存好，接着卖」（完整登记，不带第二步）或「再填进价和库存」→ 04b → 「存好」（带期初）。
/// - 收银员：只有 04c，`quick` 登记（只发名称和卖价）。
/// - 名称为空（没网、没查到也没写）照样能存：ShopCore 换成占位名（`ProductNaming`）。
/// - 从卖出进来朱红，从进货进来靛青（`mode`），两步一样。
@MainActor @Observable
final class NewProductModel {
    enum Step: Equatable { case basic, more }
    enum LookupState: Equatable { case loading, found, notFound, offline }

    let db: LocalDB
    let barcode: String
    let mode: ShopMode
    /// 收银员临时登记（04c）
    let quick: Bool
    /// 能不能挂整件码（05）：家用 / 审核
    let canLinkPack: Bool

    var step: Step = .basic
    private(set) var lookup: LookupState = .loading
    /// 名称框里的字；查到的名称只在还没手动改过时填进去
    var name = "" { didSet { if name != autoName { nameEdited = true } } }
    private var autoName: String?
    private var nameEdited = false
    /// 基本单位：查到的规格里有就用，否则「个」（`product_edit` 以后能改）
    private(set) var baseUnit = "个"
    var price = YuanInput() { didSet { error = nil } }

    // 04b
    var cost = YuanInput() { didSet { error = nil } }
    var qtyText = "" { didSet { if qtyText != DigitsInput.sanitize(qtyText, maxDigits: 7) { qtyText = DigitsInput.sanitize(qtyText, maxDigits: 7) } } }
    var trackExpiry = false
    var year = "" { didSet { if year != DigitsInput.sanitize(year, maxDigits: 4) { year = DigitsInput.sanitize(year, maxDigits: 4) } } }
    var month = "" { didSet { if month != DigitsInput.sanitize(month, maxDigits: 2) { month = DigitsInput.sanitize(month, maxDigits: 2) } } }
    var day = "" { didSet { if day != DigitsInput.sanitize(day, maxDigits: 2) { day = DigitsInput.sanitize(day, maxDigits: 2) } } }
    /// 「不知道，先不填」：管保质期，但这批的到期日不填
    var expiryUnknown = false
    var warnDays = 7

    /// 存不进去时的一句话
    private(set) var error: String?

    init(db: LocalDB, barcode: String, mode: ShopMode, quick: Bool, canLinkPack: Bool) {
        self.db = db; self.barcode = barcode; self.mode = mode; self.quick = quick; self.canLinkPack = canLinkPack && !quick
    }

    // MARK: 读

    var priceFen: Int64? { price.fen }

    var title: String {
        if quick { return "新商品" }
        return step == .basic ? "新商品 1/2" : "新商品 2/2"
    }

    var heading: String { quick ? "店里没登记过，先记个名字和价钱" : "第一次扫到，登记一下" }

    var nameLabel: String {
        switch lookup {
        case .found: "名称（自动查到的，不对点一下改）"
        case .offline: "名称"
        case .loading, .notFound: "名称（看包装写一下）"
        }
    }

    var priceLabel: String { quick ? "卖多少钱（看价签）" : "卖多少钱" }

    /// 从进货进来：新商品必须走完 04b（S19），所以第一步没有「存好，接着卖」
    var offersQuickSave: Bool { mode != .stock }
    /// 第二步只有家用
    var offersSecondStep: Bool { !quick }

    var priceMessage: String? {
        price.overLimit ? "卖价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))" : nil
    }

    var canSaveBasic: Bool { priceFen != nil && priceMessage == nil }

    var qty: Int64? { Int64(qtyText) }

    /// 04b 黄字：填了库存没填进价
    var missingCostWarning: Bool { (qty ?? 0) > 0 && cost.isEmpty }

    /// 只有打开「要管保质期」才出现到期日和提前天数
    var showsExpiryFields: Bool { trackExpiry }

    // MARK: 动作

    func applyLookup(_ r: NameLookupResult) {
        switch r {
        case .found(let n, let unit):
            lookup = .found
            if let unit, !unit.isEmpty { baseUnit = unit }
            if !nameEdited || name.isEmpty {
                autoName = n
                name = n
                nameEdited = false
            }
        case .notFound: lookup = .notFound
        case .offline: lookup = .offline
        }
    }

    func priceKey(_ k: Keypad.Key) { price.key(k) }

    /// 「再填进价和库存」
    func goMore() {
        guard canSaveBasic, offersSecondStep else { return }
        error = nil
        step = .more
    }

    func back() -> Bool {
        guard step == .more else { return false }
        step = .basic
        return true
    }

    /// 04a / 04c「存好，接着卖」：不带第二步。返回登记好的码（调用方放进购物篮）
    func saveBasic() -> PackConversion? {
        guard canSaveBasic, let p = priceFen else { return nil }
        return save { try NewProduct(barcode: barcode, name: name, priceFen: Fen(p), baseUnit: baseUnit) }
    }

    /// 04b「存好」：带期初（货架数量、进价、到期日）和保质期设置
    func saveMore() -> PackConversion? {
        guard canSaveBasic, let p = priceFen, !quick else { return nil }
        if cost.overLimit { error = "进价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))"; return nil }
        var expiryDate: CalendarDate?
        if trackExpiry, !expiryUnknown, !(year.isEmpty && month.isEmpty && day.isEmpty) {
            guard let y = Int(year), let m = Int(month), let d = Int(day), year.count == 4,
                  let date = try? CalendarDate(year: y, month: m, day: d)
            else { error = "到期日不对，年要 4 位，月日要是真的日子"; return nil }
            expiryDate = date
        }
        let hasOpening = qty != nil || cost.fen != nil || expiryDate != nil
        return save {
            let expiry = trackExpiry ? try ExpirySettings(trackExpiry: true, expiryWarnDays: Int64(warnDays)) : nil
            let opening = hasOpening
                ? try NewProduct.Opening(countedQty: qty ?? 0, unitCostFen: cost.fen.map(Fen.init), expiryDate: expiryDate) : nil
            return try NewProduct(barcode: barcode, name: name, priceFen: Fen(p), baseUnit: baseUnit, expiry: expiry,
                                  opening: opening)
        }
    }

    private func save(_ make: () throws -> NewProduct) -> PackConversion? {
        do {
            return try db.registerProduct(try make(), quick: quick)
        } catch {
            self.error = "没存上：\(SellModel.describe(error))"
            return nil
        }
    }
}

// MARK: - 整箱 / 整条（05）

/// 05 的状态和动作：这个码是哪个商品的整箱、一整是箱 / 条 / 提 / 盒、一箱几个、整箱卖多少钱（可不填）。
/// 数量和价钱用自家键盘（数量没有小数点）；换算和价格口径全交给 ShopCore（`PackLink`、`PackConversion`）。
@MainActor @Observable
final class LinkPackModel {
    enum Field: Equatable { case qty, price }

    static let units = ["箱", "条", "提", "盒"]

    let db: LocalDB
    let barcode: String
    let mode: ShopMode
    var product: Product? { didSet { error = nil } }
    var unitName = "箱"
    private(set) var qtyText = ""
    private(set) var price = YuanInput()
    var active: Field = .qty
    private(set) var error: String?

    init(db: LocalDB, barcode: String, mode: ShopMode, product: Product?) {
        self.db = db; self.barcode = barcode; self.mode = mode; self.product = product
    }

    var packQty: Int64? { Int64(qtyText) }

    func key(_ k: Keypad.Key) {
        error = nil
        switch active {
        case .price: price.key(k)
        case .qty:
            switch k {
            case .delete: if !qtyText.isEmpty { qtyText.removeLast() }
            case .dot: return
            case .digit(let d):
                if qtyText == "0" { qtyText = "" }
                if qtyText.count < 4 { qtyText += String(d) }   // ≤ 9,999（§5.0）
            }
        }
    }

    func choose(_ conv: PackConversion?) {
        if let conv { product = conv.product }
    }

    /// 「以后扫这个码，进货卖出都按 24 罐 算」
    var conversionHint: String? {
        guard let p = product, let q = packQty, q >= 2 else { return nil }
        return "以后扫这个码，进货卖出都按 \(q) \(p.baseUnit) 算"
    }

    /// 整箱价没填时按「单价 × 换算」卖：写给人看（和 ShopCore 同一个算法）
    var derivedPriceHint: String? {
        guard price.isEmpty, let p = product, let q = packQty, q >= 2,
              let link = try? PackLink(barcode: barcode, productId: p.id, unitName: unitName, packQty: q, packPriceFen: nil),
              let fen = try? link.effectivePrice(unitPriceFen: p.priceFen)
        else { return nil }
        return "不填整\(unitName)价，就按 \(q) × ¥\(Money.yuanString(Int(p.priceFen.raw))) = ¥\(Money.yuanString(Int(fen.raw))) 卖"
    }

    /// 输入不对时的一句话（没填完不算错）
    var problem: String? {
        if let error { return error }
        if let q = packQty, q < 2 { return "整\(unitName)至少是 2 个" }
        if price.overLimit { return "整\(unitName)价最多 ¥\(Money.yuanString(Int(Limits.maxFen)))" }
        return nil
    }

    var canSave: Bool { product != nil && (packQty ?? 0) >= 2 && problem == nil }

    func save() -> PackConversion? {
        guard canSave, let p = product, let q = packQty else { return nil }
        do {
            let link = try PackLink(barcode: barcode, productId: p.id, unitName: unitName, packQty: q,
                                    packPriceFen: price.fen.map(Fen.init))
            _ = try link.effectivePrice(unitPriceFen: p.priceFen)
            return try db.linkPack(link)
        } catch {
            self.error = "没存上：\(SellModel.describe(error))"
            return nil
        }
    }
}
