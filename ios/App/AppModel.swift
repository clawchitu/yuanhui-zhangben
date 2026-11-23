import Foundation
import Observation
import ShopCore

/// 首页和设置页上显示的几个数。S15 只有界面：待传笔数、快过期样数、「刚记的」、设置页右侧的小字
/// 在 `-uiFixture` 下用稿子上的数；正常启动时只有待传笔数来自本地库，其余在后面的段接真数据
/// （刚记的 → S20，快过期 → S27，同步状态 → S22a，已登录的手机 → S23a）。扫码枪连接状态 S16 起来自
/// `ScannerGunMonitor`（见 `AppModel.scannerConnected`）。
struct HomeFigures: Equatable, Sendable {
    struct LastRecord: Equatable, Sendable {
        var time: String          // "19:32"
        var kind: String          // "卖出"
        var itemCount: Int        // 3 样
        var amountFen: Int?       // 5300；盘点、期初这类没有金额的为 nil，不显示（PR #34 Fable 可选 4）
    }

    /// 待传笔数；nil = 不显示同步状态，0 = 已同步
    var pendingCount: Int? = 0
    /// 超过一天没传上去的笔数（25a 的提醒条）
    var staleUnsyncedCount = 0
    /// 快过期的样数（01 的黄条、21a 的「快过期的」）
    var expiringCount = 0
    var lastRecord: LastRecord?
    /// 21a 右侧小字
    var countSummary: String?       // "11月 数了 86 种"
    var deviceCount: Int?           // 3 台
    /// 扫码枪 已连上 / 没连：只有夹具用稿子上的值；nil = 用真实的连接状态（`ScannerGunMonitor`）
    var scannerConnected: Bool?
    /// 手机时钟和服务器差了几分钟（超过 5 分钟才有值，T5 的提醒条）
    var clockSkewMinutes: Int?

    /// 设计稿 01 / 02 / 21a 上的数
    static let design = HomeFigures(pendingCount: 0, staleUnsyncedCount: 0, expiringCount: 3,
                                    lastRecord: .init(time: "19:32", kind: "卖出", itemCount: 3, amountFen: 5300),
                                    countSummary: "11月 数了 86 种", deviceCount: 3, scannerConnected: true)
}

extension HomeFigures.LastRecord {
    /// 本地库最近一张卡 → 首页「刚记的 19:32 / 卖出 3 样 ¥53.00」
    init(_ c: RecordCard) {
        self.init(time: c.time, kind: c.kindText, itemCount: c.openLines.count, amountFen: c.amountFen.map { Int($0) })
    }

    /// 首页「刚记的」只取今天的（只有时间没有日期，几天前的一笔会被看成今天的，PR #34 Fable 可选 5）；
    /// 服务器拒收的（没记上）不算
    static func today(_ c: RecordCard?, now: Date) -> Self? {
        guard let c, !c.rejected, c.day == LocalDB.shanghaiDay(now).description else { return nil }
        return Self(c)
    }
}

/// 首页提醒条（25a）。规则：「没同步」在「快过期」上面。
enum HomeReminder: Hashable, Sendable {
    case unsynced(Int)
    case expiring(Int)
    /// 手机时间不准（T5）：差了几分钟
    case clockOff(Int)

    /// 要显示哪些提醒、按什么顺序。快过期只给有「处理快过期」能力的手机（收银员没有黄条，S27）
    static func list(_ f: HomeFigures, capabilities: Capabilities) -> [HomeReminder] {
        var r: [HomeReminder] = []
        if f.staleUnsyncedCount > 0 { r.append(.unsynced(f.staleUnsyncedCount)) }
        if let m = f.clockSkewMinutes { r.append(.clockOff(m)) }
        if f.expiringCount > 0, capabilities.has(.expiry) { r.append(.expiring(f.expiringCount)) }
        return r
    }
}

/// 首页（01 / 02）、设置页（21a / 21b）和各页标题用哪种版式。所有地方都从 `AppModel.layout` 取，判断依据只有一个：
/// 有进货能力的是家用版式；没有的（收银员，以及被踢设备）一律收银员版式。
enum ShellLayout: Equatable, Sendable {
    case family, cashier

    init(_ capabilities: Capabilities) {
        self = capabilities.has(.stockIn) ? .family : .cashier
    }
}

/// App 的状态：当前会话（角色、店名、手机名）、能力表、首次进入有没有做完。
@MainActor @Observable
final class AppModel {
    private(set) var session: LocalSession
    private(set) var capabilities: Capabilities
    private(set) var onboarded: Bool
    var figures: HomeFigures
    let today: Date
    /// 夹具固定的「现在」（稿子上的时间）；正常启动为 nil，用真时间
    let fixedNow: Date?
    /// 「刚记的」从本地库取（正常启动，和带 `-uiRecords` 的夹具）；false = 夹具用稿子上的数
    var liveRecent = true
    /// 「现在」。收银员按服务器的钟算（S22a：收银员的「今天」——07b 列哪天、能不能撤——以服务器为准，
    /// 手机时钟不准时不和服务器的判断打架）；家用仍用手机时钟（记账时间由服务器按 §4.4 校正）
    var now: Date {
        if let fixedNow { return fixedNow }
        if layout == .cashier, let off = clockOffset { return Date().addingTimeInterval(off) }
        return Date()
    }
    /// 服务器时间 − 手机时间（上次同步时量的，秒）
    var clockOffset: TimeInterval? {
        guard let st = sync?.status, let server = st.serverTimeAtSync, let local = st.lastSyncAt else { return nil }
        return server.timeIntervalSince(local)
    }
    /// T5：差多少才提醒（服务器把比它快 5 分钟以上的 occurred_at 改成收到时间，§4.4；慢的分不出来，只能靠人校）
    static let clockSkewThreshold: TimeInterval = 5 * 60
    /// 同步调度（正常启动才有；夹具为 nil）
    var sync: SyncCoordinator?
    /// 首次同步的商品流拉完了没有（没拉完先显示 29，拉完就能进首页开卖）。夹具一律当作拉完了
    var catalogReady: Bool { firstSyncFixture == nil && (sync?.catalogDone ?? true) }
    /// 截 29 用：稿子上的 194 / 312
    var firstSyncFixture: (done: Int, total: Int)?
    /// 网络不通：右上角「↑ 没网」
    var offline: Bool { sync?.offline ?? false }
    /// `-uiScrollTo bottom`：首页一打开就滚到底（截最大辅助字号下的整页用）
    let scrollToBottom: Bool
    /// 卖出页的测试夹具（只在 Debug 下由启动参数填，正式构建永远是空的）
    var sellFixture = SellFixture.none
    /// 扫码枪连接状态（§14 S15-1：设置页「扫码枪」右侧的字接真实状态）
    let gun: ScannerGunMonitor

    let db: LocalDB
    private let defaults: UserDefaults

    var role: Role { session.role }
    /// 首页 / 设置页的版式（唯一来源）
    var layout: ShellLayout { ShellLayout(capabilities) }
    /// 设置页「扫码枪」右侧：夹具用稿子上的值，正常启动用真实的连接状态
    var scannerConnected: Bool { figures.scannerConnected ?? gun.connected }

    init(db: LocalDB, session: LocalSession, figures: HomeFigures, today: Date = Date(),
         defaults: UserDefaults = .standard, scrollToBottom: Bool = false, gun: ScannerGunMonitor = ScannerGunMonitor(),
         fixedNow: Date? = nil) {
        self.fixedNow = fixedNow
        self.db = db
        self.gun = gun
        self.session = session
        self.capabilities = Capabilities(role: session.role)
        self.figures = figures
        self.today = today
        self.defaults = defaults
        self.scrollToBottom = scrollToBottom
        self.onboarded = defaults.string(forKey: AppSettings.onboardedDeviceKey) == session.deviceId.uuidString
    }

    /// 16 / 16b「好了，开始用」：字号选择存在本机（UserDefaults），家用手机顺带改名。
    func finishOnboarding(largeText: Bool, deviceName: String?) throws {
        if let deviceName, capabilities.has(.renameDevice), deviceName != session.deviceLabel {
            try rename(deviceName)
        }
        defaults.set(largeText, forKey: AppSettings.largeTextModeKey)
        defaults.set(session.deviceId.uuidString, forKey: AppSettings.onboardedDeviceKey)
        onboarded = true
    }

    /// 首页「刚记的」和待传笔数从本地库重取（§14 S15-1：刚记的接真数据，S20）
    /// 正常启动时顺带踢一趟同步（写入之后回到首页 / 记的账里撤销之后都会走到这里）
    func refreshRecent() {
        guard liveRecent else { return }
        figures.lastRecord = HomeFigures.LastRecord.today((try? db.lastRecord()) ?? nil, now: now)
        if let sync {
            sync.refreshStatus()
            applySyncStatus()
            sync.kick()
        } else if let n = try? db.pendingOps().count {
            figures.pendingCount = n
        }
    }

    /// 同步状态 → 首页 / 设置 / 07a 的数（§14 S15-1：来自真数据）
    func applySyncStatus() {
        guard let st = sync?.status else { return }
        figures.pendingCount = st.pendingCount
        figures.staleUnsyncedCount = st.overdueCount
        if let off = clockOffset, abs(off) >= Self.clockSkewThreshold {
            figures.clockSkewMinutes = Int((abs(off) / 60).rounded())
        } else {
            figures.clockSkewMinutes = nil
        }
    }

    /// 接上同步：每跑完一趟刷新首页的数和「刚记的」（拉下来的流水可能换掉了本机的行）
    func attach(_ sync: SyncCoordinator) {
        self.sync = sync
        sync.onFinish = { [weak self] in
            guard let self else { return }
            self.applySyncStatus()
            self.figures.lastRecord = HomeFigures.LastRecord.today((try? self.db.lastRecord()) ?? nil, now: self.now)
        }
        applySyncStatus()
        sync.start()
    }

    /// 网络服务（正常启动才有；夹具为 nil，改名只改本机）
    var services: AppServices?

    /// 改手机名（§14 S15-2）：先改本机，再报服务器（`PATCH /v1/devices/me`），名字以服务器返回的为准（重名会加序号）。
    /// 报不上就留在 `pendingDeviceLabel`，回前台再报。收银员本机拒改（`renameCurrentDevice` 里拦）。
    func rename(_ name: String) throws {
        try db.renameCurrentDevice(name)
        if let s = try db.currentSession() { session = s }
        guard let services else { return }
        services.pendingDeviceLabel = session.deviceLabel
        Task { await reportPendingLabel() }
    }

    /// 正在报的那一趟（在途保护，PR #35 评审修 5）：同一时间只有一个 `PATCH /v1/devices/me` 在路上
    private var labelReport: Task<Void, Never>?
    /// 实际发出去的补报次数（测试看）
    private(set) var labelReportsSent = 0

    /// 把没报上的手机名报给服务器；成功后清掉。失败（断网、服务器拒）留着，下次回前台再试。
    ///
    /// 回前台、登录后、改名几处可能同时触发：已经有一趟在路上时不再另发，等那一趟结束（PR #35 评审修 5）。
    /// 那一趟回来时如果名字又改了（`pendingDeviceLabel` 不是发出去的那个），旧响应不写回本机，接着报新名字（Codex 可选 1）。
    func reportPendingLabel() async {
        if let running = labelReport { return await running.value }
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainPendingLabel()
            // 和 drain 的最后一次检查在同一段主线程执行里，中间没有挂起点：之后来的调用一定会另起一趟
            self.labelReport = nil
        }
        labelReport = t
        await t.value
    }

    private func drainPendingLabel() async {
        while let services, let pending = services.pendingDeviceLabel, capabilities.has(.renameDevice) {
            guard let label = LoginModel.validLabel(pending),
                  let token = try? services.tokens.token(ref: session.tokenRef) else { return }  // 读不出来也留着，下次再报
            labelReportsSent += 1
            let final: String
            do {
                final = try await services.api.renameDevice(label, token: token)
            } catch {
                return  // 留在 pendingDeviceLabel，回前台再报
            }
            // 在路上时又改了名：这次的响应是旧名字，不写回，接着报新的
            guard services.pendingDeviceLabel == pending else { continue }
            services.pendingDeviceLabel = nil
            if final != session.deviceLabel {
                try? db.renameCurrentDevice(final)
                if let s = try? db.currentSession() { session = s }
            }
            return
        }
    }
}
