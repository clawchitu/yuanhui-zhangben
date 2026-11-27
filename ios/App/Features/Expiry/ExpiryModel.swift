import Foundation
import Observation
import ShopCore

/// 19 快过期的 / 20、20b 处理面板的状态。清单只看本机（拉下来的批次 + 本机没传的处理），没网也能看能处理；
/// 处理写进 outbox，下一趟同步传上去。服务器拒 stale（另一台手机已经处理过这批）时，这一趟同步已经把批次的最新状态拉下来，
/// 页面提示「这批已经处理过了」并按最新的重新列（§5.4、S27 验收）。
@MainActor @Observable
final class ExpiryModel {
    let db: LocalDB
    private let clock: () -> Date
    /// 写完一笔（首页黄条、待传笔数重取，正常启动时顺带踢同步）
    var onWrite: (() -> Void)?

    private(set) var board: ExpiryBoard?
    /// 正在处理的批次（20 / 20b 面板）；nil = 面板关着
    var handling: ExpiryItem?
    /// 「货架上这批实际还有几个」：打开面板时 = 账上的数，人再改
    var actualQty = 0
    /// 页面顶上的提示（另一台手机已经处理过这批……）；点了收起
    var notice: String?
    /// 本页记下、还没有结果的处理：op id → 批次
    private(set) var watching: [UUID: UUID] = [:]
    /// 写进 outbox 失败（本机库出错之类）
    private(set) var failure: String?

    static let staleNotice = "这批已经处理过了（另一台手机处理的），下面是现在的"
    static let rejectedNotice = "刚才那次处理没记上，请再处理一次"

    init(db: LocalDB, clock: @escaping () -> Date) {
        self.db = db
        self.clock = clock
    }

    var today: CalendarDate { LocalDB.shanghaiDay(clock()) }

    func load() {
        board = try? db.expiryBoard(today: today)
    }

    func open(_ item: ExpiryItem) {
        actualQty = Int(clamping: item.qtyLeft)
        failure = nil
        handling = item
    }

    /// 步进器的范围：0 … 账上的数和 9999 里大的那个（不超过数量上限）
    func stepperRange(_ item: ExpiryItem) -> ClosedRange<Int> {
        0...Int(clamping: min(max(item.qtyLeft, 9_999), Limits.maxBaseQty))
    }

    /// 面板上从上到下的顺序（照稿子）：20 已过期「卖完了、扔掉、退货、还在卖」；20b 没过期「还在卖、卖完了、退货、扔掉」
    func choices(_ item: ExpiryItem) -> [ExpiryChoice] {
        item.expired ? [.soldOut, .discard, .return, .snooze] : [.snooze, .soldOut, .return, .discard]
    }

    /// 突出哪一个（ShopCore `ExpiryChoice.order` 的第一个）：已过期突出扔掉，没过期突出再提醒，实际数为 0 突出卖完了
    func emphasized(_ item: ExpiryItem) -> ExpiryChoice {
        ExpiryChoice.order(expired: item.expired, actualQty: Int64(actualQty))[0]
    }

    /// 「算亏 ¥19.60」：按本机的进价基线预计；进价不知道时为 nil
    func lossEstimate(_ item: ExpiryItem) -> Fen? {
        guard actualQty > 0, let b = try? db.productPrivate(item.productId) else { return nil }
        return try? ExpiryLoss.estimate(b, qty: Int64(actualQty))
    }

    func choose(_ choice: ExpiryChoice) {
        guard let item = handling, choice.enabled(actualQty: Int64(actualQty)) else { return }
        do {
            let op = try db.handleExpiry(item, choice: choice, actualQty: Int64(actualQty), at: clock())
            watching[op] = item.lotId
            handling = nil
            notice = nil
            load()
            onWrite?()
        } catch {
            failure = "没记上：\(error.localizedDescription)"
        }
    }

    /// 同步跑完一趟：重新列（拉下来的批次可能变了），看本页记的处理有没有结果
    func syncFinished() {
        load()
        for (op, _) in watching {
            guard let st = try? db.opStatus(op) else { watching[op] = nil; continue }
            switch st.status {
            case .pending: continue
            case .rejected: notice = st.code == "stale" ? Self.staleNotice : Self.rejectedNotice
            case .applied, .held: break
            }
            watching[op] = nil
        }
        // 面板开着的那批被别的手机处理掉了（拉下来已关闭）：关面板并提示
        if let h = handling, let b = board, !(b.expired + b.soon + b.snoozed).contains(where: { $0.lotId == h.lotId }) {
            handling = nil
            notice = Self.staleNotice
        }
    }

    // MARK: 文案

    static func dateText(_ d: CalendarDate) -> String { "\(d.month)月\(d.day)日" }

    /// 「过了 2 天」「今天到期」「还有 5 天」
    static func daysText(_ item: ExpiryItem) -> String {
        if item.daysLeft < 0 { return "过了 \(-item.daysLeft) 天" }
        if item.daysLeft == 0 { return "今天到期" }
        return "还有 \(item.daysLeft) 天"
    }

    /// 面板第二行：「11月17日到期，已经过了 2 天」
    static func panelDaysText(_ item: ExpiryItem) -> String {
        let d = dateText(item.expiryDate) + "到期"
        if item.daysLeft < 0 { return d + "，已经过了 \(-item.daysLeft) 天" }
        if item.daysLeft == 0 { return "今天到期" }
        return d + "，还有 \(item.daysLeft) 天"
    }

    func title(_ c: ExpiryChoice) -> String {
        switch c {
        case .soldOut: "卖完了，没有了"
        case .discard: "下架扔掉"
        case .return: "退给供货商"
        case .snooze: "还在卖，过几天再提醒"
        }
    }

    func detail(_ c: ExpiryChoice, item: ExpiryItem) -> String {
        switch c {
        case .soldOut: return "这批不再提醒"
        case .discard:
            guard actualQty > 0 else { return "没有可扔的" }
            let base = "扣 \(actualQty) \(item.unit)库存"
            return lossEstimate(item).map { base + "，算亏 " + $0.yuanString } ?? base
        case .return:
            guard actualQty > 0 else { return "没有可退的" }
            return "扣 \(actualQty) \(item.unit)库存，不算亏"
        case .snooze:
            let until = (try? today.adding(days: Int(ExpiryRule.snoozeDays))).map { "（\(Self.dateText($0))）" } ?? ""
            return "\(ExpiryRule.snoozeDays) 天后再提醒\(until)"
        }
    }

    static func icon(_ c: ExpiryChoice) -> String {
        switch c {
        case .soldOut: "checkmark"
        case .discard: "trash"
        case .return: "truck.box"
        case .snooze: "clock"
        }
    }
}
