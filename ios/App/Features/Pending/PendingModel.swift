import Foundation
import Observation
import ShopCore

/// 「待传的账」面板顶上那句话说的原因（Fable 裁定 5，按优先级）
enum PendingReason: String, Equatable, Sendable, CaseIterable {
    /// 账号正在注销（服务器给了 `delete_pending_until`）：这期间 op 先不推
    case deleting
    /// 登录过期（401 / 读不到令牌）
    case unauthorized
    /// 没网
    case offline
    /// 连不上 / 超时
    case network
    /// 服务器忙和其他错误
    case other
    /// 正在传 / 还没出错
    case normal

    /// 优先级：注销中 → 登录过期 → 没网 → 连不上 / 超时 → 服务器忙和其他 → 正在传
    static func from(deleting: Bool, failure: SyncFailure?, offline: Bool) -> PendingReason {
        if deleting { return .deleting }
        if failure == .unauthorized { return .unauthorized }
        if offline || failure == .offline { return .offline }
        switch failure {
        case .network?: return .network
        case .other?: return .other
        default: return .normal
        }
    }

    /// 顶上的状态句（n = 待传总数）
    func headline(count n: Int) -> String {
        switch self {
        case .deleting: "账号正在注销，这 \(n) 笔先不传。撤回注销后会自动传，账不会丢"
        case .unauthorized: "登录过期了，这 \(n) 笔先传不了。重新登录后会自动传，账不会丢"
        case .offline: "没网。联网后会自动传，账不会丢"
        case .network: "网不好，没传上去。会自动再试，账不会丢"
        case .other: "暂时没传上去。会自动再试，账不会丢"
        case .normal: "正在传，一会儿就好"
        }
    }

    /// 小字「手机会自己接着试，不用管它」：注销中、登录过期时手机自己试也没用，不显示
    var showsFootnote: Bool { self != .deleting && self != .unauthorized }
    /// 「再传一次」：注销中、登录过期时点了也传不上，隐藏（没网照样能点）
    var allowsRetry: Bool { showsFootnote }

    static let footnote = "手机会自己接着试，不用管它"
}

/// 「待传的账」面板（Fable 裁定 3–8、12）：数据全部来自本地库（`LocalDB.pendingOverview`），跟着每趟同步刷新
@MainActor @Observable
final class PendingModel {
    let db: LocalDB
    private let clock: () -> Date
    private(set) var overview: PendingOverview?
    /// 夹具（没有同步协调器）里点「再传一次」：照样变灰停 1 秒
    private(set) var localRetrying = false
    /// 读了几次库（测试看）
    private(set) var loads = 0

    init(db: LocalDB, clock: @escaping () -> Date) {
        self.db = db
        self.clock = clock
    }

    var now: Date { clock() }

    /// 第几次重读：后发的先回来时，先发的那次旧结果不覆盖新的
    private var generation = 0

    /// 重读（库在后台线程读，不卡主线程）
    func reload() async {
        generation += 1
        let mine = generation
        let db = db, now = clock()
        let o = await Task.detached(priority: .userInitiated) { try? db.pendingOverview(now: now) }.value
        loads += 1
        guard mine == generation, let o else { return }
        overview = o
    }

    /// 「再传一次」：马上同步一趟，「正在传…」至少停 1 秒，传完重读
    func retry(sync: SyncCoordinator?) async {
        if let sync {
            await sync.retry()
        } else {
            guard !localRetrying else { return }
            localRetrying = true
            try? await Task.sleep(for: SyncCoordinator.retryMinimum)
            localRetrying = false
        }
        await reload()
    }

    /// 一行：「19:32 卖出 农夫山泉 等 3 样 · 5 件 · ¥53.00」；昨天「昨天 19:32」，更早「11月23日 19:32」
    static func rowText(_ e: PendingEntry, now: Date) -> String {
        let head = [e.timeText(now: now), e.kindText, e.namesText].compactMap { $0 }.joined(separator: " ")
        var tail: [String] = []
        if let q = e.quantity { tail.append([String(q), e.unitName].compactMap { $0 }.joined(separator: " ")) }
        if let a = e.amountFen { tail.append("¥" + Money.yuanString(Int(a))) }
        return ([head] + tail).joined(separator: " · ")
    }

    static func moreText(_ n: Int) -> String { "还有 \(n) 笔，传上去以后能在记的账里看" }
    static func recoveryText(_ m: Int) -> String { "以前登录时还有 \(m) 笔待传，会一起传" }
    static func rejectedText(_ k: Int) -> String { "今天有 \(k) 笔没记上，点这里去看" }
    static let doneText = "都传上去了"
}
