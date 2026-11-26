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

    /// 顶栏的待传笔数（只给顶栏用，带 4 秒延迟，见 `PendingBadge`）；nil = 不显示同步状态，0 = 已同步
    var pendingCount: Int? = 0
    /// 待传实时笔数（当前会话 + 恢复队列）：面板、首页提醒条、退出登录提示用（Fable 裁定 11）
    var livePendingCount = 0
    /// 待传里超过一天的笔数（25a 的提醒条，含恢复队列）
    var staleUnsyncedCount = 0
    /// 快过期的样数（01 的黄条、21a 的「快过期的」）
    var expiringCount = 0
    var lastRecord: LastRecord?
    /// 21a 右侧小字
    var countSummary: String?       // "11月 数了 86 种"
    var deviceCount: Int?           // 3 台
    /// S23a：被退出的手机补传上来、等确认的笔数（设置页「待确认的账」；0 不显示）
    var heldCount = 0
    /// 扫码枪 已连上 / 没连：只有夹具用稿子上的值；nil = 用真实的连接状态（`ScannerGunMonitor`）
    var scannerConnected: Bool?
    /// 手机时钟和服务器差了几分钟（超过 5 分钟才有值，T5 的提醒条）
    var clockSkewMinutes: Int?
    /// S22b：服务器拒收、还没点「知道了」的笔数（「N 笔没记上」提醒条；拒收的不再重试）
    var rejectedCount = 0
    /// S23b：账号在注销申请中（服务器给的 `delete_pending_until`，来自同步响应、登录响应或 `/v1/me`）。
    /// 这期间服务器一笔都不应用，手机不推、留在本机（§4.2、§14 S04-2），首页和卖出页提示
    var deletePendingUntil: String?

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
    /// 「N 笔待传，其中 M 笔超过一天」（N 用实时数），点了开「待传的账」
    case unsynced(total: Int, overdue: Int)
    /// S22b：服务器拒收的笔数（不再重试），点「知道了」收起
    case rejected(Int)
    case expiring(Int)
    /// 手机时间不准（T5）：差了几分钟
    case clockOff(Int)
    /// S23b：账号正在注销（`delete_pending_until`），记的账先存在本机。N = 待传笔数
    case deleting(pending: Int)

    /// 要显示哪些提醒、按什么顺序。快过期只给有「处理快过期」能力的手机（收银员没有黄条，S27）
    static func list(_ f: HomeFigures, capabilities: Capabilities) -> [HomeReminder] {
        var r: [HomeReminder] = []
        // 注销中放最上面：这期间记的账都传不上去（§14 S04-2）
        if f.deletePendingUntil != nil { r.append(.deleting(pending: f.livePendingCount)) }
        if f.rejectedCount > 0 { r.append(.rejected(f.rejectedCount)) }
        if f.staleUnsyncedCount > 0 {
            r.append(.unsynced(total: max(f.livePendingCount, f.staleUnsyncedCount), overdue: f.staleUnsyncedCount))
        }
        if let m = f.clockSkewMinutes { r.append(.clockOff(m)) }
        if f.expiringCount > 0, capabilities.has(.expiry) { r.append(.expiring(f.expiringCount)) }
        return r
    }
}

/// 顶栏待传状态的 4 秒延迟（Fable 裁定 1）：刚记一笔、几秒内就传上去时，顶栏不闪「1 笔待传」。
/// - 0 → 有待传：等一会儿再显示；等的期间传完了就一直是「已同步」；
/// - 已经在显示待传：笔数变了立刻更新；
/// - 回到 0：立刻「已同步」；
/// - 已知没网、或上一次同步刚失败：不等，立刻显示。
enum PendingBadge {
    enum Step: Equatable {
        /// 顶栏马上显示这个数
        case show(Int)
        /// 先不动，等延迟到了再显示当时的实时数
        case wait
    }

    static func next(shown: Int?, live: Int, immediate: Bool) -> Step {
        if live == 0 || (shown ?? 0) > 0 || immediate { return .show(live) }
        return .wait
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
    /// 顶栏待传的延迟（正常启动 4 秒；夹具和单测为 0，带 `-uiPendingDelay` 才开）
    var pendingDelay: Duration = .zero
    static let pendingDelayLive: Duration = .seconds(4)
    private var pendingReveal: Task<Void, Never>?
    /// 待传实时笔数（面板、首页提醒条、退出登录提示用；顶栏用 `figures.pendingCount`）
    var livePendingCount: Int { figures.livePendingCount }
    #if DEBUG
    /// 夹具：「待传的账」面板当作这个原因（`-uiPendingReason offline|network|unauthorized|other|deleting`）
    var pendingReasonFixture: PendingReason?
    #endif
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
    /// S23b：这台手机登录用的账号名（账号密码登录时记下的，见 `AuthDefaults.sessionUsername`）。
    /// 扫码登录的手机不知道账号名（`/v1/me` 不带），为 nil
    var accountName: String?

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
        refreshPending()
    }

    /// 写入之后（卖出、进货、撤销……）：待传笔数从本地库重取，正常启动时顺带踢一趟同步
    func refreshPending() {
        if let sync {
            sync.refreshStatus()
            applySyncStatus()
            sync.kick()
        } else if let t = try? db.pendingTally(now: now) {
            setLivePending(t.total)
        }
    }

    /// 待传实时数变了：面板、提醒条马上用；顶栏按 `PendingBadge` 决定马上显示还是等 `pendingDelay`
    func setLivePending(_ n: Int) {
        figures.livePendingCount = n
        let immediate = pendingDelay == .zero || offline || sync?.lastFailure != nil
        switch PendingBadge.next(shown: figures.pendingCount, live: n, immediate: immediate) {
        case .show(let v):
            pendingReveal?.cancel(); pendingReveal = nil
            if figures.pendingCount != v { figures.pendingCount = v }
        case .wait:
            guard pendingReveal == nil else { return }
            let delay = pendingDelay
            pendingReveal = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.pendingReveal = nil
                let live = self.figures.livePendingCount
                if live > 0 { self.figures.pendingCount = live }
            }
        }
    }

    /// 同步状态 → 首页 / 设置 / 07a 的数（§14 S15-1：来自真数据）
    func applySyncStatus() {
        guard let st = sync?.status else { return }
        setLivePending(st.totalPendingCount)
        figures.staleUnsyncedCount = st.overdueCount
        figures.rejectedCount = (try? db.rejectedUnseenCount()) ?? 0
        figures.deletePendingUntil = st.deletePendingUntil
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
        // 没网了：顶栏正在等的待传马上显示（不等 4 秒）
        sync.onOfflineChange = { [weak self] in
            guard let self else { return }
            self.setLivePending(self.figures.livePendingCount)
        }
        applySyncStatus()
        sync.start()
    }

    /// 网络服务（正常启动才有；夹具为 nil，改名只改本机）
    var services: AppServices?
    /// S22c：商品图（正常启动才有；夹具带 Debug 的 `-uiImages` 才有）
    var images: ProductImages?

    /// 接上商品图：同步成功预取、epoch 重建清掉、开关跟 `/v1/config` 走
    func attachImages(_ images: ProductImages) {
        self.images = images
        if let sync {
            sync.onSynced = { [weak images] in images?.prefetch(); images?.changes?.flush() }
            sync.onRebuilt = { [weak images] in images?.reset() }
        }
        if let changes = images.changes {
            changes.images = images
            changes.kickSync = { [weak sync] in sync?.kick() }
            changes.start()
        }
        services?.onImagesSwitch = { [weak images] on in
            images?.setEnabled(on)
            if on { images?.changes?.flush() }
        }
        if sync?.catalogDone ?? false { images.prefetch() }
        #if DEBUG
        if sync == nil, ProcessInfo.processInfo.arguments.contains("-uiImagesPrefetch") { images.prefetch() }
        #endif
    }

    /// S22d：登记时能不能选图（家用、不是演示店、商品图开关开着）。能的话给这个会话的换图
    var imageChanges: ImageChanges? {
        guard capabilities.has(.productImages), let images, images.enabled else { return nil }
        return images.changes
    }

    /// S23a：开通页、「已登录的手机」页的状态。没有网络服务（夹具没给桩）时为 nil，页面只出一句「要联网」
    func makePairingModel() -> PairingModel? {
        guard let services else { return nil }
        let tokens = services.tokens, ref = session.tokenRef
        let backend = DeviceBackend.live(api: services.api) {
            guard let t = try tokens.token(ref: ref) else { throw DeviceBackend.NoToken() }
            return t
        }
        let m = PairingModel(backend: backend, serverNow: { [weak self] in Date().addingTimeInterval(self?.clockOffset ?? 0) })
        m.onDevicesChanged = { [weak self] list in
            self?.figures.deviceCount = list.filter { !$0.revoked }.count
            self?.figures.heldCount = list.reduce(0) { $0 + $1.heldCount }
        }
        return m
    }

    /// S23a「待确认的账」。记上后马上同步一次（记的账里就有了），设置页的笔数跟着刷新
    func makeHeldModel() -> HeldModel? {
        guard let p = makePairingModel() else { return nil }
        let m = HeldModel(backend: p.backend, db: db, now: { [weak self] in self?.now ?? Date() })
        m.onAccepted = { [weak self] in
            self?.sync?.kick()
            Task { await self?.refreshDeviceCount() }
        }
        return m
    }

    /// 设置页「已登录的手机」右侧的台数（S15-1：来自真数据）。没有网络服务、取不到时不改（夹具保留稿子上的数）
    func refreshDeviceCount() async {
        guard capabilities.has(.manageDevices), !offline, let m = makePairingModel() else { return }
        await m.refreshDevices()
    }

    /// 04a 查名称用哪个：正常启动问服务器（真机热修），夹具 / Debug 的 `-uiOffline` 用桩
    func nameLookup(offline: Bool) -> any ProductNameLookup {
        if let services, !offline { return ServerNameLookup(api: services.api, tokens: services.tokens, tokenRef: session.tokenRef) }
        return StubNameLookup(offline: offline)
    }

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

    // MARK: - S22b 没记上、退出登录

    /// 退出登录、申请注销之前的排空（§4.5、S22b）：停掉定时同步、等在途的那趟跑完，再用当前令牌传一趟（推完 outbox、拉到底）。
    /// 排空时发现这台手机已经被踢：会话已由引擎退役，剩下的用同一个旧令牌由恢复队列补传，返回 true（调用方按被踢走 25b / 25f）。
    /// 开写事务、压缩都在后台线程。之后同步协调器不再通知「退出了」，要接着用就调 `resumeSync()`
    func drainOutbox() async -> Bool {
        sync?.stop()
        await sync?.idle()
        guard let sync else { return false }
        sync.onSignedOut = nil
        let db = db
        let engine = SyncEngine(db: db, appBuild: services?.build ?? 0, transport: sync.transportForDrain)
        let r = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try engine.sync(); return nil } catch { return error }
        }.value
        guard case .revoked(let discard)? = r as? SyncError else { return false }
        if discard { sync.onDiscard?() }   // 演示店重置：令牌也删
        if let recovery = sync.recovery { _ = await recovery.run() }
        return true
    }

    /// 排空之后没退成（申请注销没成功）：同步接着跑，被踢照常通知
    func resumeSync() {
        guard let sync else { return }
        let db = db
        sync.onSignedOut = { NotificationCenter.default.post(name: AppRoot.signedOut, object: db) }
        sync.start()
        sync.kick()
    }

    /// 「N 笔没记上」点「知道了」
    func acknowledgeRejected() {
        try? db.acknowledgeRejected()
        figures.rejectedCount = (try? db.rejectedUnseenCount()) ?? 0
    }

    enum LogoutOutcome: Equatable {
        /// 传完了、令牌已注销
        case done
        /// 没传完（没网）：这几笔进恢复队列，联网后自动补传，传完才注销旧令牌。带的数是本机待传总数（提示用）
        case pending(Int)
        /// 排空时发现这台手机已经被踢：按被踢走（25b / 25f），没传完的留在恢复队列、旧令牌不删
        case kicked
    }

    /// 退出登录（§4.5）：先把 outbox 传完，再调 `logout`；传不完（没网）就推迟 `logout`，未传的进恢复队列。
    /// 两种都结束本地会话（清投影）。开写事务、压缩都在后台线程。
    ///
    /// PR #41 必须修 1：笔数按**这个会话**（设备 + 店）数，不按「当前会话」（排空中被踢，会话已退役，「当前」就是空的）；
    /// 只要这个会话还有没拿到结果的 op，旧令牌一律不删；排空收到被踢就按被踢流程走，不调 logout。
    func logout() async -> LogoutOutcome {
        let db = db, ref = session.tokenRef, deviceId = session.deviceId, storeId = session.storeId
        if await drainOutbox() { return .kicked }
        let pending = (try? db.pendingCount(deviceId: deviceId, storeId: storeId)) ?? 1
        var loggedOut = false
        if pending == 0, let services, let token = try? services.tokens.token(ref: ref) {
            #if DEBUG
            let offline = ProcessInfo.processInfo.arguments.contains("-uiOffline")
            #else
            let offline = false
            #endif
            if !offline, let code = try? await services.api.logout(token: token), code == 204 || code == 200 || code == 401 {
                loggedOut = true
            }
        }
        _ = await Task.detached(priority: .userInitiated) { () -> Void in
            try? db.endSession(logoutPending: !loggedOut)
            // 注销成功也不删令牌、不删会话行：14 天保留期内的 op 换 epoch 后要用它重传；
            // 统一由恢复队列在这个会话的 op 全部清掉后删（PR #41 第二轮必须修）
            if loggedOut { try? db.markRetiredLoggedOut(deviceId: deviceId) }
        }.value
        // 提示里的笔数和顶栏同口径：本机所有待传（这个会话没传完的已进恢复队列，加上更早的恢复队列）
        // （这个会话一笔不剩、只是注销没发出去时仍是 0：提示「联网后会自动退出」）
        let shown = pending > 0 ? max((try? db.pendingTally().total) ?? 0, pending) : 0
        return loggedOut ? .done : .pending(shown)
    }
}
