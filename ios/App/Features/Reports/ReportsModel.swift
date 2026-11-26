import Foundation
import Observation
import ShopCore

/// S24 看账（09 / 10）用到的网络调用。正常启动接 `APIClient`，令牌每次从钥匙串现取；UI 测试接桩服务器（`-uiAPI`）
struct ReportsBackend: Sendable {
    var today: @Sendable (_ date: String?) async throws -> ReportToday
    var month: @Sendable (_ month: String?) async throws -> ReportMonth

    static func live(api: APIClient, token: @escaping @Sendable () throws -> String) -> ReportsBackend {
        ReportsBackend(
            today: { date in try await api.reportToday(date: date, token: try token()) },
            month: { month in try await api.reportMonth(month: month, token: try token()) }
        )
    }
}

/// 看账页的状态。账只在服务器上（§0「在线才能看」），手机不存、不重算：
/// 每次进页面、切「今天 / 本月」、下拉、重新联网都现取；取不到（没网、没连上）就显示「要联网才能看账」，**不留旧数**。
@MainActor @Observable
final class ReportsModel {
    enum Tab: String, Sendable { case today, month }

    enum State: Equatable {
        case loading
        /// 没网或没连上服务器（「要联网才能看账」）
        case offline
        /// 连上了但没取到（收银员 403、服务器出错）
        case failed(String)
        case today(ReportToday)
        case month(ReportMonth)
    }

    let backend: ReportsBackend
    /// 只看某一天 / 某个月（夹具和联调用；nil = 服务器的今天、本月）
    let date: String?
    let monthParam: String?
    private(set) var tab: Tab = .today
    private(set) var state: State = .loading
    /// 快没货的单位（商品 id → 基本单位），从本机商品表查；查不到写「个」
    private(set) var units: [UUID: String] = [:]
    private var generation = 0
    var unitLookup: (@Sendable ([UUID]) async -> [UUID: String])?

    init(backend: ReportsBackend, date: String? = nil, month: String? = nil, tab: Tab = .today) {
        self.backend = backend
        self.date = date
        self.monthParam = month
        self.tab = tab
    }

    /// 「快没货 / 快过期」是店里现在的状态，只在看今天时显示（§14 S07-6）
    var showsNow: Bool { date == nil }

    func select(_ t: Tab, offline: Bool) async {
        guard t != tab else { return }
        tab = t
        await load(offline: offline)
    }

    /// 取当前这一栏。`offline`：同步那边已经知道没网，就不发请求，直接说要联网。
    /// 旧数一律先清掉（换栏、重新联网时不让上一份账留在屏幕上），新的到了才显示。
    func load(offline: Bool) async {
        generation += 1
        let gen = generation
        guard !offline else { state = .offline; return }
        state = .loading
        let t = tab
        do {
            let next: State
            switch t {
            case .today:
                let r = try await backend.today(date)
                if let unitLookup {
                    let ids = r.lowStock.map(\.productId)
                    let u = await unitLookup(ids)
                    if gen == generation { units = u }
                }
                next = .today(r)
            case .month:
                next = .month(try await backend.month(monthParam))
            }
            guard gen == generation else { return }
            state = next
        } catch {
            guard gen == generation else { return }
            state = Self.state(for: error)
        }
    }

    /// 同步那边的「没网」变了：没网马上换成「要联网才能看账」，联网了重取
    func networkChanged(offline: Bool) async {
        if offline {
            generation += 1
            state = .offline
        } else if state == .offline {
            await load(offline: false)
        }
    }

    static func state(for error: Error) -> State {
        switch error as? APIError {
        case .transport?, nil: .offline   // 没连上；取不到令牌（钥匙串）也只能当没连上
        case .server(_, "forbidden", _, _)?: .failed("这台手机不能看账")
        case .server(401, _, _, _)?: .failed("这台手机已经退出了，重新登录后再看")
        default: .failed("没取到账，过一会再试")
        }
    }
}

// MARK: - 显示（纯函数，单元测试逐条测）

enum ReportFormat {
    /// 千分位 + 两位小数：「1,286.50」「-3.20」（大数字和 09 的卡片）
    static func yuan(_ fen: Fen) -> String { yuan(fen.raw, cents: true) }

    /// 10 的卡片和对账：整元不写小数（「23,262」），有角分才写（「23,261.85」）。数仍然逐分等于接口
    static func compact(_ fen: Fen) -> String { yuan(fen.raw, cents: fen.raw % 100 != 0) }

    static func yuan(_ fen: Int64, cents: Bool) -> String {
        let neg = fen < 0
        let a = fen.magnitude
        var whole = String(a / 100)
        var groups: [String] = []
        while whole.count > 3 {
            groups.insert(String(whole.suffix(3)), at: 0)
            whole.removeLast(3)
        }
        groups.insert(whole, at: 0)
        let frac = cents ? "." + String(format: "%02d", Int(a % 100)) : ""
        return (neg ? "-" : "") + groups.joined(separator: ",") + frac
    }

    /// 带「¥」
    static func money(_ fen: Fen, compact: Bool = false) -> String { "¥" + (compact ? self.compact(fen) : yuan(fen)) }
}

/// 10「进货对账」的一行
struct ReconLine: Equatable, Identifiable {
    var id: String
    /// 「减」「加」；第一行（月初货值 + 本月进货）没有
    var verb: String?
    var label: String
    /// 显示的数（不带正负号）
    var shown: Fen
    /// 这一行对最后一行的贡献（带正负号）：各行相加 = 最后一行
    var signed: Int64
    /// 这一行里没算进价的笔数（§5.3「有 N 笔没算进价」）
    var costMissing: Int
}

extension ReportMonth {
    /// 进货花了 = 本月进货行（stock_in 的 value_delta 之和，就是进货付的钱）
    var stockInFen: Fen { reconciliation.rows.first { $0.key == .stockIn }?.amountFen ?? .zero }

    /// 10 的对账：第一行「月初货值 + 本月进货」，其余每行按正负写「减 / 加」，最后一行是月末货值（接口的数，不在手机上重算）
    var reconLines: [ReconLine] {
        let r = reconciliation
        var lines = [ReconLine(id: "start", verb: nil, label: "月初货值 + 本月进货",
                               shown: Fen(r.stockValueStartFen.raw + stockInFen.raw),
                               signed: r.stockValueStartFen.raw + stockInFen.raw, costMissing: 0)]
        for row in r.rows where row.key != .stockIn {
            let v = row.amountFen.raw
            lines.append(ReconLine(id: row.key.rawValue, verb: v > 0 ? "加" : "减", label: Self.label(row.key, positive: v > 0),
                                   shown: Fen(Int64(v.magnitude)), signed: v, costMissing: row.costMissingCount))
        }
        return lines
    }

    /// 对账各行相加（单元测试、联调都核对它等于 `reconciliation.stockValueEndFen`）
    var reconSum: Int64 { reconLines.reduce(0) { $0 + $1.signed } }

    static func label(_ k: ReportReconRow.Key, positive: Bool) -> String {
        switch k {
        case .stockIn: "本月进货"
        case .sale: positive ? "撤销卖出退回的进价" : "卖掉的货的进价"
        case .count: positive ? "盘点多出来的" : "盘点少了的"
        case .expireLoss: positive ? "撤销扔掉退回的" : "过期扔掉的"
        case .supplierReturn: positive ? "撤销退货退回的" : "退给供货商的"
        case .openingAndAdjust: "期初登记和调整"
        }
    }

    /// 柱状图的 x 轴：这个月有几天
    var daysInMonth: Int {
        let p = month.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return 31 }
        return CalendarDate.daysIn(year: p[0], month: p[1])
    }

    /// 「11月」
    var monthTitle: String {
        let p = month.split(separator: "-").compactMap { Int($0) }
        return p.count == 2 ? "\(p[1])月" : month
    }
}

/// 柱状图的一根柱子
struct DayBar: Identifiable, Equatable {
    var day: Int
    var date: String
    var soldFen: Int64
    var isToday: Bool
    var id: Int { day }

    static func bars(_ m: ReportMonth, today: String) -> [DayBar] {
        m.daily.compactMap { d in
            guard let day = Int(d.date.suffix(2)) else { return nil }
            return DayBar(day: day, date: d.date, soldFen: d.soldFen.raw, isToday: d.date == today)
        }
    }
}

enum ReportLabels {
    /// 柱状图坐标轴字号（验收：≥ 18pt）
    static let axisFontSize: CGFloat = 18

    /// 快没货的标签：库存 ≤ 0 显示「没货了」，否则「还剩 2 罐」（§14 S07-6）
    static func lowStock(qty: Int64?, unit: String?) -> String {
        let q = qty ?? 0
        return q <= 0 ? "没货了" : "还剩 \(q) \(unit ?? "个")"
    }

    /// 快过期的标签：按服务器的今天（09 响应的 `date`）算差几天
    static func expiring(_ expiry: String?, today: String) -> String {
        guard let e = expiry.flatMap({ try? CalendarDate($0) }), let t = try? CalendarDate(today) else { return "快过期" }
        let days = dayNumber(e) - dayNumber(t)
        if days < 0 { return "已过期" }
        if days == 0 { return "今天到期" }
        return "\(days) 天后"
    }

    /// 公历日序号（只用来相减）
    static func dayNumber(_ d: CalendarDate) -> Int {
        // Fliegel–Van Flandern 儒略日，整数算
        let a = (14 - d.month) / 12
        let y = d.year + 4800 - a
        let m = d.month + 12 * a - 3
        return d.day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// 上海时区「今天」的 YYYY-MM-DD
    static func shanghaiDay(_ now: Date) -> String {
        let c = Calendar.shanghai.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension AppModel {
    /// 看账页的状态。没有网络服务（夹具没给桩）时为 nil，页面只出「要联网才能看账」。
    /// Debug 夹具可以用 `-uiReportDate YYYY-MM-DD`、`-uiReportMonth YYYY-MM` 看某一天 / 某个月，`-uiReportTab month` 一进来就看本月
    func makeReportsModel() -> ReportsModel? {
        guard let services else { return nil }
        let tokens = services.tokens, ref = session.tokenRef
        let backend = ReportsBackend.live(api: services.api) {
            guard let t = try tokens.token(ref: ref) else { throw DeviceBackend.NoToken() }
            return t
        }
        var date: String?, month: String?, tab = ReportsModel.Tab.today
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        date = UIFixture.value(for: "-uiReportDate", in: args)
        month = UIFixture.value(for: "-uiReportMonth", in: args)
        if UIFixture.value(for: "-uiReportTab", in: args) == "month" { tab = .month }
        #endif
        let m = ReportsModel(backend: backend, date: date, month: month, tab: tab)
        let db = db
        // 快没货的单位查本机商品表（不在主线程读库，§8 S22a）
        m.unitLookup = { ids in
            await Task.detached {
                var out: [UUID: String] = [:]
                for id in ids { if let p = try? db.product(id) { out[id] = p.baseUnit } }
                return out
            }.value
        }
        return m
    }
}
