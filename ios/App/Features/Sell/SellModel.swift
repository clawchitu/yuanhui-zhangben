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
        /// 超出 §5.0 上限等，篮子没变
        case rejected(String)
        /// 记账失败（本地库写不进去），购物篮原样留着
        case saveFailed(String)

        var text: String {
            switch self {
            case .unknownBarcode(let code): "这个码还没登记：\(code)"
            case .rejected(let why): "加不进去：\(why)"
            case .saveFailed(let why): "没记上，再按一次试试（\(why)）"
            }
        }
    }

    let db: LocalDB
    private(set) var basket = Basket()
    /// 刚扫的那一行（价签里那一行）
    private(set) var focusId: UUID?
    private(set) var done: Done?
    private(set) var notice: Notice?
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

    /// 扫到一个码（相机、扫码枪、手输都走这里）
    func scan(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        done = nil
        notice = nil
        do {
            guard let conv = try db.lookup(barcode: code) else {
                notice = .unknownBarcode(code)
                return
            }
            let i = try basket.add(conv)
            focusId = basket.lines[i].id
            clearPaidOverride()
        } catch {
            notice = .rejected(Self.describe(error))
        }
    }

    /// 改某一行的件数；0 = 删掉这一行
    func setCount(lineId: UUID, _ n: Int) {
        guard let i = basket.lines.firstIndex(where: { $0.id == lineId }) else { return }
        notice = nil
        do {
            try basket.setCount(at: i, Int64(n))
            if basket.lines.first(where: { $0.id == focusId }) == nil { focusId = basket.lines.last?.id }
            clearPaidOverride()
        } catch {
            notice = .rejected(Self.describe(error))
        }
    }

    /// 篮子一变（扫进新东西、改件数），之前抹的零作废，回到按原价收：抹零是对着当时的原价定的，
    /// 原价变了还留着旧实收，会把多出来的东西白送或把七折检查绕过去（S16 自行决定，PR 里说明）
    private func clearPaidOverride() {
        if basket.paidOverrideFen != nil { try? basket.setPaid(nil) }
    }

    /// 抹零 / 改总价的结果（面板本身在 S17 做；这里只接住结果，03b 的显示和记账要用）
    func setPaid(_ fen: Int64?) throws {
        try basket.setPaid(fen.map(Fen.init))
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
            notice = .saveFailed(Self.describe(error))
            return false
        }
    }

    func dismissDone(_ id: UUID) {
        if done?.id == id { done = nil }
    }

    func dismissNotice() { notice = nil }

    func refreshPending() {
        pendingCount = (try? db.pendingOps().count) ?? pendingCount
        onPendingChange?(pendingCount)
    }

    static func describe(_ error: Error) -> String {
        if case ShopCoreError.invalid(let why) = error { return why }
        return String(describing: error)
    }
}
