import Foundation
import Observation
import ShopCore

/// 卖出页（03 系列）的状态和动作：扫码进购物篮、改件数、记账。不碰界面，单元测试直接测它。
///
/// - 扫到的码按 §14 S12-2 的合并键并进购物篮（同码再扫 = 那一行 +1），刚扫的那一行放在最上面的价签里（03）。
/// - 步进器减到 0 删掉这一行。
/// - 「收好钱了，记账」：`LocalDB.recordSale` 一个事务写批次、各行流水和 `sale_batch` op；成功后清空购物篮、
///   显示「记好了 ¥xx」（03d），停在卖出页。正在记账时和购物篮为空时再按都不会多记一笔。
@MainActor @Observable
final class SellModel {
    /// 03d「记好了」黑卡上的内容
    struct Done: Equatable, Identifiable {
        let id: UUID          // 批次 id
        let paidFen: Int64
        let kinds: Int        // 卖出 3 样
        let items: Int64      // 6 件
    }

    /// 页面上方的一句提示（黄条），下一次扫码或几秒后消失
    enum Notice: Equatable {
        /// 没登记过的码（登记新商品在 S18 接：扫到后去 04a）
        case unknownBarcode(String)
        /// 超出 §5.0 上限，篮子没变。原因是店里人看得懂的话（`limitReason`），不是 ShopCore 的内部原因（§14 S16-6）
        case rejected(String)
        /// 记账失败（本地库写不进去），购物篮原样留着
        case saveFailed(String)
        /// 抹零后篮子变了，抹的零作废、回到按原价收（§14 S16-1：不悄悄变）
        case paidCleared

        var text: String {
            switch self {
            case .unknownBarcode(let code): "这个码还没登记：\(code)"
            case .rejected(let why): "加不进去：\(why)"
            case .saveFailed(let why): "没记上，再按一次试试（\(why)）"
            case .paidCleared: "东西变了，刚才抹的零取消了，要抹请再抹一次"
            }
        }

        /// 停几秒：「抹的零取消了」要让人看见，停 8 秒；其余 4 秒
        var seconds: Double { self == .paidCleared ? 8 : 4 }
    }

    let db: LocalDB
    private(set) var basket = Basket()
    /// 刚扫的那一行（价签里那一行）
    private(set) var focusId: UUID?
    private(set) var done: Done?
    private(set) var notice: Notice?
    /// 每出一次黄条加一（同样的黄条再出一次也加），界面按它重新计时（Fable 8）
    private(set) var noticeSeq = 0
    /// 顶栏「N 笔待传」（来自本地库）
    private(set) var pendingCount: Int
    /// 记账次数（测试、调试探针用）
    private(set) var commitCount = 0
    private var committing = false
    /// 待传笔数变了（首页顶栏跟着变）
    var onPendingChange: ((Int) -> Void)?

    init(db: LocalDB) {
        self.db = db
        pendingCount = (try? db.pendingOps().count) ?? 0
    }

    // MARK: - 读

    /// 价签里那一行（没有就是篮子里最后加的那一行）
    var focusLine: Basket.Line? {
        basket.lines.first { $0.id == focusId } ?? basket.lines.last
    }

    /// 价签下面的各行：除价签那一行外，新加的在上
    var otherLines: [Basket.Line] {
        let f = focusLine?.id
        return basket.lines.reversed().filter { $0.id != f }
    }

    var itemCount: Int64 { basket.itemCount }
    var listTotalFen: Int64 { (try? basket.listTotal().raw) ?? 0 }
    var paidTotalFen: Int64 { (try? basket.paidTotal().raw) ?? 0 }
    /// 抹了多少（03b「优惠 ¥0.50」）；没改价是 nil。多收时为负
    var discountFen: Int64? {
        guard basket.paidOverrideFen != nil else { return nil }
        return listTotalFen - paidTotalFen
    }
    /// 空篮时记账按钮置灰
    var canCommit: Bool { !basket.isEmpty && !committing }
    /// 抹零 / 改总价：空篮、全是零价商品时不可用（§5.1 第 0 步）
    var canChangePaid: Bool { (try? basket.canChangePaid()) ?? false }

    static func lineAmountFen(_ l: Basket.Line) -> Int64 { (try? l.listAmount().raw) ?? 0 }
    static func unitPriceFen(_ l: Basket.Line) -> Int64 { (try? l.unitPrice().raw) ?? 0 }

    // MARK: - 动作

    /// 页面这会儿收不收码：推到手输条码 / 抹零页、被面板盖住时为假，扫到的码返回 `.ignored`（不出声）。
    /// 相机另由 `CameraViewfinder(paused:)` 停掉，这里只管扫码枪和已经排着的码（§14 S14-3 ⑨）
    var accepting = true

    /// 扫码层（`ScanHub.handler`）交来一个码：相机（已按 1.5 秒去重）、扫码枪、手输都走这里。
    /// 返回给扫码层决定提示音：进了购物篮 `.known`；没登记的码、超上限加不进去 `.unknown`（低音 + 警告触感，
    /// 收银员要看黄条）；页面不收码 `.ignored`。
    func handle(_ scan: Scan) -> ScanOutcome {
        guard accepting else { return .ignored }
        let code = scan.code
        done = nil
        notice = nil
        do {
            guard let conv = try db.lookup(barcode: code) else {
                show(.unknownBarcode(code))
                return .unknown
            }
            let reason = limitReason(adding: conv)
            let i: Int
            do {
                i = try basket.add(conv)
            } catch {
                show(.rejected(reason ?? "超出上限"))
                return .unknown
            }
            focusId = basket.lines[i].id
            clearPaidOverride()
            return .known
        } catch {
            show(.rejected(Self.describe(error)))
            return .unknown
        }
    }

    /// 某一行现在的件数；这一行已经删掉时是 0
    func count(lineId: UUID) -> Int64 {
        basket.lines.first { $0.id == lineId }?.packCount ?? 0
    }

    /// 改某一行的件数；0 = 删掉这一行
    func setCount(lineId: UUID, _ n: Int) {
        guard let i = basket.lines.firstIndex(where: { $0.id == lineId }) else { return }
        notice = nil
        let line = basket.lines[i]
        do {
            try basket.setCount(at: i, Int64(n))
            if basket.lines.first(where: { $0.id == focusId }) == nil { focusId = basket.lines.last?.id }
            clearPaidOverride()
        } catch {
            show(.rejected(Self.limitReason(line.conversion, count: Int64(n)) ?? "超出上限"))
        }
    }

    /// 篮子一变（扫进新东西、改件数），之前抹的零作废，回到按原价收：抹零是对着当时的原价定的，
    /// 原价变了还留着旧实收，会把多出来的东西白送或把七折检查绕过去。作废的那一刻出黄条（§14 S16-1）
    private func clearPaidOverride() {
        guard basket.paidOverrideFen != nil else { return }
        try? basket.setPaid(nil)
        show(.paidCleared)
    }

    private func show(_ n: Notice) {
        notice = n
        noticeSeq &+= 1
    }

    /// 扫到 `conv` 时会超哪条 §5.0 上限，用店里人看得懂的话说（§14 S16-6）；不超是 nil
    private func limitReason(adding conv: PackConversion) -> String? {
        let same = basket.lines.first {
            $0.conversion.product.id == conv.product.id && $0.packQty == conv.packQty
                && $0.conversion.barcode.unitName == conv.barcode.unitName
                && (try? $0.unitPrice()) == (try? conv.unitPrice())
        }
        if same == nil, basket.lines.count >= Limits.maxSaleLines {
            return "一单最多 \(Limits.maxSaleLines) 样，先把这一单记了再扫"
        }
        return Self.limitReason(conv, count: (same?.packCount ?? 0) + 1)
    }

    /// 一行买 `count` 件时会超哪条上限：件数、按基本单位的数量、这一行的金额
    static func limitReason(_ conv: PackConversion, count: Int64) -> String? {
        if count > Limits.maxPackCount { return "这一样最多 \(Limits.maxPackCount) 件" }
        let (base, o1) = conv.packQty.multipliedReportingOverflow(by: count)
        if o1 || base > Limits.maxBaseQty {
            return "这一样最多 \(Limits.maxBaseQty) \(conv.product.baseUnit)"
        }
        let price = (try? conv.unitPrice().raw) ?? 0
        let (amount, o2) = price.multipliedReportingOverflow(by: count)
        if o2 || amount > Limits.maxFen {
            return "这一行最多 ¥\(Money.yuanString(Int(Limits.maxFen)))，分两单记"
        }
        return nil
    }

    /// 抹零 / 改总价的结果（面板本身在 S17 做；这里只接住结果，03b 的显示和记账要用）
    func setPaid(_ fen: Int64?) throws {
        try basket.setPaid(fen.map(Fen.init))
    }

    /// 抹零面板（18 / 28）关掉时的结果：定了实收，或「不抹了」恢复原价。面板里已经按 §5.0 上限和七折规则把过关，
    /// 这里再交给 ShopCore 校验一次（校验不过就不改，按原价收）
    func applyDiscount(_ outcome: DiscountModel.Outcome) {
        notice = nil
        switch outcome {
        case .paid(let p): try? basket.setPaid(Fen(p))
        case .restore: try? basket.setPaid(nil)
        }
    }

    /// 「收好钱了，记账」。返回这一笔有没有记上。
    @discardableResult
    func commit(at now: Date = Date()) -> Bool {
        guard canCommit else { return false }
        committing = true
        defer { committing = false }
        do {
            let paid = try basket.paidTotal().raw
            let kinds = basket.lines.count, items = basket.itemCount
            let payload = try db.recordSale(basket, at: now)
            basket.clear()
            focusId = nil
            notice = nil
            done = Done(id: payload.batchId, paidFen: paid, kinds: kinds, items: items)
            commitCount += 1
            refreshPending()
            return true
        } catch {
            show(.saveFailed(Self.describe(error)))
            return false
        }
    }

    func dismissDone(_ id: UUID) {
        if done?.id == id { done = nil }
    }

    func dismissNotice() { notice = nil }

    /// 计时到了收黄条：只收那一次的（期间又出了新黄条就不收）
    func dismissNotice(seq: Int) {
        if seq == noticeSeq { notice = nil }
    }

    func refreshPending() {
        pendingCount = (try? db.pendingOps().count) ?? pendingCount
        onPendingChange?(pendingCount)
    }

    static func describe(_ error: Error) -> String {
        if case ShopCoreError.invalid(let why) = error { return why }
        return String(describing: error)
    }
}
