import Foundation
import Observation
import ShopCore

/// 记的账（07a / 07b / 07c）和撤销（08）的状态。数全部来自本地库（S20）。
@MainActor @Observable
final class RecordsModel {
    enum Tab: String, CaseIterable, Hashable { case today, yesterday, earlier }

    let db: LocalDB
    /// 收银员版式：只有「我今天记的」，没有日期切换（07b）
    let cashier: Bool
    private let clock: () -> Date

    var tab: Tab = .today { didSet { if tab != oldValue { openDay = nil; reload() } } }
    /// 07c 里点开的那一天
    var openDay: CalendarDate? { didSet { if openDay != oldValue { reload() } } }
    private(set) var cards: [RecordCard] = []
    private(set) var days: [LedgerDay] = []
    /// 07c 一次显示几天（「再往前 7 天」）
    private(set) var shownDays = 7
    /// 08 正在撤的这张卡
    var undoCard: RecordCard?
    private(set) var notice: String?
    private(set) var pendingCount = 0
    var onChange: (() -> Void)?

    init(db: LocalDB, cashier: Bool, clock: @escaping () -> Date) {
        self.db = db
        self.cashier = cashier
        self.clock = clock
        reload()
    }

    var now: Date { clock() }

    /// 正在看的那一天
    var day: CalendarDate {
        let today = LocalDB.shanghaiDay(now)
        if cashier { return today }
        switch tab {
        case .today: return today
        case .yesterday: return LocalDB.shanghaiDay(now.addingTimeInterval(-86_400))
        case .earlier: return openDay ?? today
        }
    }

    /// 07c 的日列表（不是点开某一天时）
    var showsDayList: Bool { !cashier && tab == .earlier && openDay == nil }
    var visibleDays: [LedgerDay] { Array(days.prefix(shownDays)) }
    var hasMoreDays: Bool { days.count > shownDays }

    func moreDays() { shownDays += 7 }

    func reload() {
        do {
            cards = showsDayList ? [] : try db.recordCards(on: day)
            days = cashier ? [] : try db.ledgerDays(now: now)
            pendingCount = try db.pendingOps().count
        } catch {
            notice = SellModel.describe(error)
        }
    }

    func canUndo(_ card: RecordCard) -> Bool { (try? db.canVoid(card, now: now)) ?? false }

    /// 首页「记错了」：最近一张能撤的卡，直接打开 08
    func openLatestUndo() {
        guard let last = try? db.lastRecord(), canUndo(last) else { return }
        if !cashier { tab = .today; openDay = nil }
        if !cashier, last.day != LocalDB.shanghaiDay(now).description {
            if last.day == LocalDB.shanghaiDay(now.addingTimeInterval(-86_400)).description { tab = .yesterday }
            else { tab = .earlier; openDay = try? CalendarDate(last.day) }
        }
        undoCard = last
    }

    /// 「整笔都撤销」/「只撤这样」
    func undo(_ target: VoidTarget) {
        do {
            switch try db.void(target, at: now) {
            case .voided: notice = "撤销了，库存已加回"
            case .alreadyVoided: notice = "这笔已经撤过了"
            }
        } catch {
            notice = SellModel.describe(error)
        }
        undoCard = nil
        reload()
        onChange?()
    }

    /// 整笔撤：卖出按批次撤（只撤还没撤的行）；别的类型按那一行撤
    func undoAll(_ card: RecordCard) {
        if let b = card.batchId { undo(.batch(b)) } else if let l = card.openLines.first { undo(.entry(l.id)) }
    }

    func dismissNotice() { notice = nil }

    // MARK: 文字

    static func dayTitle(_ d: CalendarDate) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day))!
        let wd = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: date) - 1]
        return "\(d.month)月\(d.day)日 \(wd)"
    }

    /// 08 的副标题「19:32 柜台手机记的卖出，实收 ¥53.00」
    static func undoSubtitle(_ c: RecordCard) -> String {
        var s = "\(c.time) \(c.deviceLabel)记的\(c.kindText)"
        if let a = c.amountFen, c.type == .sale { s += "，实收 ¥\(Money.yuanString(Int(a)))" }
        return s
    }

    /// 08 的黄条：「这笔抹了 ¥0.50，撤一样按比例退」；多收「这笔多收了 ¥x」；没改价、只有一行不显示
    static func discountNote(_ c: RecordCard) -> String? {
        guard c.type == .sale, c.openLines.count > 1, c.discountFen != 0 else { return nil }
        let d = Money.yuanString(Int(abs(c.discountFen)))
        return c.discountFen > 0 ? "这笔抹了 ¥\(d)，撤一样按比例退" : "这笔多收了 ¥\(d)，撤一样按比例退"
    }
}
