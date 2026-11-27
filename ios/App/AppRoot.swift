import ShopCore
import SwiftUI

@main
struct YuanhuiZhangbenApp: App {
    /// 启动时建一次（热修：同步风暴）。不能放进 `AppRoot.init`：`WindowGroup { AppRoot() }` 在 `App.body` 里，
    /// `App.body` 每重算一次就再调一次 `AppRoot.init`；而 `@State(initialValue:)` 的初值每次都会算（只是第一次之后被丢掉）。
    /// 原来 `AppRoot.init` 里直接走 `makeBoot` → `liveModel` → `attach`：每重算一次就开一个本机库、建一个新的
    /// `SyncCoordinator` 并马上同步一趟；建的过程中读了 `sync.status`（`applySyncStatus`），Observation 把它记成
    /// `App.body` 的依赖 → 这趟同步改了 `status` → `App.body` 重算 → 又一个新 `SyncCoordinator` → 又同步……
    /// 已登录状态下打开 App 就停不下来（真机 ~150ms 一次 `/v1/sync`）。`App.init` 只调一次、不在任何 body 里，读什么都不会被记成依赖。
    private let launch: AppLaunch

    init() {
        UIFixture.applyLaunchOverrides()
        launch = AppLaunch.make()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(launch: launch)
        }
    }
}

/// 进程启动时建一次的东西：网络服务和首屏（见 `YuanhuiZhangbenApp.launch`）。`AppRoot.init` 只拿它的值，不建任何东西
@MainActor
struct AppLaunch {
    let services: AppServices?
    let boot: AppRoot.Boot

    static func make(args: [String] = ProcessInfo.processInfo.arguments) -> AppLaunch {
        let services = AppRoot.needsServices(args) ? AppServices.make(args: args) : nil
        return AppLaunch(services: services, boot: AppRoot.makeBoot(args, services: services))
    }
}

enum AppSettings {
    /// 大字模式开关，默认开（§设计：老人用，大字是默认）。
    static let largeTextModeKey = "largeTextMode"
    /// 做完首次进入（16 / 16b）的那个会话的设备 id。每次登录设备 id 都是新的，所以重新登录后会再选一次。
    static let onboardedDeviceKey = "onboardedDeviceId"
}

/// 所有界面的根外壳：读「大字模式」设置并套上字号范围、浅色外观。
/// AppRoot 用它包住全部内容；字号测试也直接测它，保证测的就是实际生效链路。
struct AppShell<Content: View>: View {
    @AppStorage(AppSettings.largeTextModeKey) private var largeTextMode = true
    /// 套范围之前的系统字号（16 页预览两种模式要用）
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.systemTypeSize, systemTypeSize)
            .largeTextMode(largeTextMode)
            .preferredColorScheme(.light)
    }
}

struct AppRoot: View {
    static let title = "元辉账本"

    @State private var boot: Boot
    /// 网络服务（地址、令牌、配置）。夹具和组件陈列页不连服务器，为 nil
    @State private var services: AppServices?
    @Environment(\.scenePhase) private var scenePhase
    @State private var foreground = ForegroundRefresh()
    /// 钥匙串读不出来时点过几次「再试一次」（PR #35 Fable 可选 1：试过还不行给「重新登录」出口）
    @State private var tokenAttempts = 0

    /// 只接 `AppLaunch` 建好的值：本 init 会随 `App.body` 重算被反复调用，这里不许开库、建模型、建同步（热修：同步风暴）
    init(launch: AppLaunch) {
        _services = State(initialValue: launch.services)
        _boot = State(initialValue: launch.boot)
    }

    var body: some View {
        AppShell {
            ZStack {
                switch boot {
                case .gallery(let page):
                    ComponentGallery(page: page)
                case .app(let model, let initialPath):
                    MainView(initialPath: initialPath).environment(model).environment(\.productImages, model.images)
                case .signedOut(let login):
                    LoginFlow(model: login)
                case .kicked(let k):
                    KickedView(model: k)
                case .failed(let message):
                    StartupErrorView(message: message)
                case .tokenUnavailable:
                    TokenUnavailableView(attempts: tokenAttempts, retry: { tokenAttempts += 1; retryBoot() },
                                         relogin: { relogin() })
                #if DEBUG
                case .scannerLab(let login):
                    ScannerLab(login: login, args: ProcessInfo.processInfo.arguments)
                #endif
                }
                if services?.needsUpdate == true {
                    UpdateRequiredView().transition(.opacity)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-uiSyncProbe") { SyncProbe() }
                if ProcessInfo.processInfo.arguments.contains("-uiFrameProbe"), case .app(let model, _) = boot { ImageProbe(images: model.images) }
                #endif
            }
        }
        .task {
            await services?.refreshConfig()
            await recoverSignedOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRoot.signedOut)) { note in
            // S22b：被踢 / 演示店重置 / 退出登录：旧会话的同步停掉，进 25b / 25f 或登录页
            guard let db = note.object as? LocalDB else { return }
            if case .app(let model, _) = boot { model.sync?.stop(); model.images?.shutdown() }
            boot = AppRoot.afterSignOut(db: db, services: services)
            // S23b：刚申请了注销，登录页顶上说一句怎么撤回
            if case .signedOut(let login) = boot, let notice = note.userInfo?["notice"] as? String { login.notice = notice }
            Task { await recoverSignedOut() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRoot.showLogin)) { note in
            guard let db = note.object as? LocalDB else { return }
            let login = AppRoot.makeLogin(db: db, services: services)
            login.scanOpen = (note.userInfo?["scan"] as? Bool) ?? false
            boot = .signedOut(login)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRoot.signedIn)) { note in
            // 登录成功：进新会话（还没做完首次进入，先到 16 / 16b）
            guard let db = note.object as? LocalDB, let session = note.userInfo?["session"] as? LocalSession else { return }
            if case .app(let old, _) = boot { old.images?.shutdown() }   // 换身份：旧会话的图清掉
            do { boot = .app(try AppRoot.liveModel(db: db, session: session, services: services), []) }
            catch { boot = .failed(String(describing: error)) }
        }
        .onChange(of: scenePhase) { _, phase in
            // S22c：进后台就停下载，回前台接着下（不用 background URLSession / BGTask）
            if case .app(let model, _) = boot {
                if phase == .background { model.images?.enterBackground() }
                if phase == .active { model.images?.enterForeground() }
            }
            // 回到前台（进过后台、又变成 active）：再取一次配置、补报没报上的手机名（§14 S15-2）
            guard foreground.shouldRefresh(on: phase) else { return }
            Task { await onReturnToForeground() }
        }
    }

    /// 回到前台要做的事
    @MainActor private func onReturnToForeground() async {
        if case .tokenUnavailable = boot { retryBoot() }
        RecoveryRunner.requestProbe()   // 回前台：旧会话那家店换没换 epoch 再探一次
        await services?.refreshConfig()
        await recoverSignedOut()
        if case .app(let model, _) = boot {
            model.sync?.kick()  // S22a：回前台同步一趟
            await model.reportPendingLabel()
        }
    }

    /// S22b：没有当前会话时（登录页、25b / 25f）也要传恢复队列：每次打开 App、回到前台都试一遍（§4.5）。
    /// 有会话时由 `SyncCoordinator` 在每趟同步之前传
    @MainActor private func recoverSignedOut() async {
        guard let services else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiNoLaunchRecovery") { return }
        #endif
        let db: LocalDB
        switch boot {
        case .signedOut(let l): db = l.db
        case .kicked(let k): db = k.db
        default: return
        }
        _ = await RecoveryRunner.live(db: db, services: services).run()
        if case .kicked(let k) = boot { k.refresh() }
    }

    /// 「重新登录」：结束本地会话（清投影、会话退役，outbox 不动——未传的账按 S22b 的退役会话补传，不丢），回登录页
    @MainActor private func relogin() {
        do {
            let db = try LocalDB(path: try AppRoot.storeDirectory().appendingPathComponent(AppRoot.liveDBName).path)
            try db.endSession()
            Task.detached(priority: .utility) { ProductImageDisk(storeId: UUID()).removeAll() }   // 会话结束：商品图缓存整个删掉（不在主线程）
            boot = .signedOut(AppRoot.makeLogin(db: db, services: services))
        } catch {
            boot = .failed(String(describing: error))
        }
    }

    /// 钥匙串读不出来时重走一遍启动（会话没结束，读出来就直接进）
    @MainActor private func retryBoot() {
        boot = AppRoot.makeBoot(ProcessInfo.processInfo.arguments, services: services)
    }

    enum Boot {
        case gallery(Int?)
        case app(AppModel, [Route])
        /// 没有会话：登录页（13）
        case signedOut(LoginModel)
        /// S22b：被踢了，25b（家用）/ 25f（收银员）
        case kicked(KickedModel)
        case failed(String)
        /// 有会话，但钥匙串这会儿读不出来（例如重启后还没解锁）：会话不动，提示后重试（PR #35 Fable 可选 2）
        case tokenUnavailable
        #if DEBUG
        /// 扫码测试页（S14，只在 Debug）
        case scannerLab(login: Bool)
        #endif
    }

    /// 只有正常启动连服务器；组件陈列页、扫码测试页、Debug 夹具不连
    static func needsServices(_ args: [String]) -> Bool {
        guard UIFixture.screen(from: args) != nil else {
            #if DEBUG
            return UIFixture.role(from: args) == nil
            #else
            return true
            #endif
        }
        return false
    }

    /// 本机正式库所在目录（Application Support）
    static func storeDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }

    @MainActor static func makeBoot(_ args: [String], services: AppServices? = nil) -> Boot {
        let screen = UIFixture.screen(from: args)
        if case .gallery(let page) = screen { return .gallery(page) }
        #if DEBUG
        if case .scanner(let login) = screen { return .scannerLab(login: login) }
        #endif
        do {
            #if DEBUG
            if let role = UIFixture.role(from: args) {
                let initial = (screen == .settings ? [Route.settings] : []) + UIFixture.injectedRoutes(from: args)
                return .app(try fixtureModel(role: role, screen: screen, args: args), initial)
            }
            #endif
            let tokens = services?.tokens ?? KeychainTokenStore()
            let boot = try liveBoot(directory: try storeDirectory(), tokens: tokens,
                                    defaults: services?.defaults ?? .standard, services: services)
            #if DEBUG
            // S22b 联调：被踢页（25f）上带着要兑的码重开，等同点了「扫家里人给的码」再扫
            if case .kicked(let k) = boot, UIFixture.value(for: "-uiRedeemCode", in: args) != nil {
                try? k.db.clearSignOutReason()
                let login = makeLogin(db: k.db, services: services)
                UIFixture.applyLoginFixture(login, args: args)
                return .signedOut(login)
            }
            if case .signedOut(let login) = boot { UIFixture.applyLoginFixture(login, args: args) }
            #endif
            return boot
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// 正常启动：打开本机正式库，有会话且钥匙串里有它的令牌就进；否则出登录页。
    /// `tokenRef` 为 `demo-local` 的遗留会话（S15 时 Debug 包自动建的演示会话）不当作已登录，清掉（§14 S15-4）；
    /// 它改过的手机名留到 `pendingDeviceLabel`，第一次登录时带上（§14 S15-2）。
    @MainActor static func liveBoot(directory: URL, tokens: TokenStore, defaults: UserDefaults = .standard,
                                    services: AppServices? = nil) throws -> Boot {
        let db = try LocalDB(path: directory.appendingPathComponent(liveDBName).path, faultHook: crashHook())
        try clearLegacyDemo(directory: directory, db: db, defaults: defaults)
        if let session = try db.currentSession() {
            let token: String?
            do { token = try tokens.token(ref: session.tokenRef) } catch { return .tokenUnavailable }
            if token != nil {
                let model = try liveModel(db: db, session: session, services: services)
                #if DEBUG
                return .app(model, UIFixture.injectedRoutes(from: ProcessInfo.processInfo.arguments))  // 联调 XCUITest 直接开到某页
                #else
                return .app(model, [])
                #endif
            }
            // 钥匙串里没有这个会话的令牌（重装、换机恢复）：不能当作已登录
            try db.endSession()
        }
        return afterSignOut(db: db, services: services)
    }

    /// 没有当前会话时进哪一页：被踢 → 25b / 25f（重启后也是）；演示店重置、退出登录 → 登录页
    @MainActor static func afterSignOut(db: LocalDB, services: AppServices?) -> Boot {
        switch try? db.signOutReason() {
        case .kickedFamily?, .kickedCashier?:
            let cashier = (try? db.signOutReason()) == .kickedCashier
            return .kicked(KickedModel(db: db, cashier: cashier) {
                NotificationCenter.default.post(name: AppRoot.showLogin, object: db, userInfo: ["scan": cashier])
            })
        case .demoReset?:
            try? db.clearSignOutReason()
            return .signedOut(makeLogin(db: db, services: services))
        case nil:
            return .signedOut(makeLogin(db: db, services: services))
        }
    }

    /// 被踢 / 演示店重置 / 退出登录完成的通知（object 是本机库）
    static let signedOut = Notification.Name("yh.signedOut")
    /// 25b / 25f 点了按钮：进登录页（收银员直接开扫码）
    static let showLogin = Notification.Name("yh.showLogin")

    /// 强杀验收「本地提交中途」：处理同步响应的事务里直接退出进程（只在 Debug 带 `-uiCrashAt midCommit` 时）
    static func crashHook(_ args: [String] = ProcessInfo.processInfo.arguments) -> (@Sendable (LocalDBFaultPoint) throws -> Void)? {
        guard CrashPoint.from(args) == .midCommit else { return nil }
        return { p in if p == .midSyncCommit { CrashPoint.die(.midCommit) } }
    }

    @MainActor static func makeLogin(db: LocalDB, services: AppServices?) -> LoginModel {
        LoginModel(services: services, db: db) { session in
            NotificationCenter.default.post(name: AppRoot.signedIn, object: db, userInfo: ["session": session])
        }
    }

    /// 登录成功的通知：`AppRoot` 收到后切到首页
    static let signedIn = Notification.Name("yh.signedIn")

    /// S15 留下的演示会话：正式库里的 `demo-local` 会话结束掉；Debug 的演示库整个删掉
    static func clearLegacyDemo(directory: URL, db: LocalDB, defaults: UserDefaults) throws {
        func keepLabel(_ s: LocalSession) {
            if s.deviceLabel != legacyDefaultLabel, defaults.string(forKey: AuthDefaults.pendingDeviceLabel) == nil {
                defaults.set(s.deviceLabel, forKey: AuthDefaults.pendingDeviceLabel)
            }
        }
        if let s = try db.currentSession(), s.tokenRef == legacyDemoTokenRef {
            keepLabel(s)
            try db.endSession()
        }
        #if DEBUG
        let demoPath = directory.appendingPathComponent(demoDBName).path
        if FileManager.default.fileExists(atPath: demoPath) {
            if let s = try? LocalDB(path: demoPath).currentSession() { keepLabel(s) }
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: demoPath + suffix) }
        }
        #endif
    }

    static let legacyDemoTokenRef = "demo-local"
    /// S15 演示会话的默认手机名：没改过就不用补报
    static let legacyDefaultLabel = "新手机"

    /// 本机正式库的文件名（登录后的真账都在这里）
    static let liveDBName = "zhangben.sqlite"

    @MainActor static func liveModel(db: LocalDB, session: LocalSession, services: AppServices?) throws -> AppModel {
        var figures = HomeFigures()
        let tally = try db.pendingTally()
        figures.pendingCount = tally.total
        figures.livePendingCount = tally.total
        figures.lastRecord = HomeFigures.LastRecord.today(try db.lastRecord(), now: Date())
        let model = AppModel(db: db, session: session, figures: figures)
        model.services = services
        model.accountName = services?.username(deviceId: session.deviceId)
        model.pendingDelay = AppModel.pendingDelayLive  // 顶栏 0 → N 等 4 秒（Fable 裁定 1）
        #if DEBUG
        // 联调（S22a XCUITest）：真会话下也能用假扫码、调试探针；-uiInjectDemo 往本机塞服务器上没有的演示商品（卖它会被拒）
        let args = ProcessInfo.processInfo.arguments
        if UIFixture.value(for: "-uiScan", in: args) != nil || args.contains("-uiProbe") || args.contains("-uiOffline") {
            model.sellFixture = SellFixture.from(args)
        }
        if args.contains("-uiInjectDemo") { try DemoSeed.install(into: db) }
        #endif
        if let services {
            let sync = SyncCoordinator.live(db: db, services: services, tokenRef: session.tokenRef,
                                            crash: CrashPoint.from(ProcessInfo.processInfo.arguments))
            sync.onSignedOut = { NotificationCenter.default.post(name: AppRoot.signedOut, object: db) }
            model.attach(sync)
            let busy = sync.busy
            model.attachImages(ProductImages.live(db: db, session: session, services: services, syncBusy: { busy.value }))
        }
        Task { await model.reportPendingLabel() }
        return model
    }

    #if DEBUG
    /// Debug 的演示库，和正式库分开
    static let demoDBName = "zhangben-demo.sqlite"

    /// 夹具：内存库 + 演示数据 + 稿子上的数和时间
    @MainActor static func fixtureModel(role: Role, screen: UIFixture.Screen?, args: [String]) throws -> AppModel {
        let db = try LocalDB.inMemory()
        let label = role == .cashier ? "小王的手机" : "柜台手机"
        let session = try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                       tokenRef: "demo-\(role.rawValue)", storeName: "元辉烟酒店", deviceLabel: label)
        try db.beginSession(session)
        try DemoSeed.install(into: db)
        var figures = HomeFigures.design
        if role == .cashier { figures.scannerConnected = false }  // 21b 稿子上是「没连」
        if screen == .home(unsynced: true) {
            figures.pendingCount = 5
            figures.livePendingCount = 5
            figures.staleUnsyncedCount = 5
        }
        let defaults = UserDefaults.standard
        switch screen {
        case .home, .settings: defaults.set(session.deviceId.uuidString, forKey: AppSettings.onboardedDeviceKey)
        case .onboarding: defaults.removeObject(forKey: AppSettings.onboardedDeviceKey)
        default: break
        }
        try UIFixture.installSellExtras(into: db, args: args)
        // -uiOverdueSales N：真记 N 笔前天的卖出（25a 提醒条点开「待传的账」看得到这几笔）
        if let n = UIFixture.value(for: "-uiOverdueSales", in: args).flatMap(Int.init), n > 0 {
            try UIFixture.installOverdueSales(n, into: db)
        }
        if args.contains("-uiPriorSales") || args.contains("-uiOverdueSales") {
            let t = try db.pendingTally(now: UIFixture.designNow)
            figures.pendingCount = t.total; figures.livePendingCount = t.total; figures.staleUnsyncedCount = t.overdue
        }
        // S20：-uiRecords 装上稿子 07a / 07b / 07c 的账，首页「刚记的」和待传笔数都从库里取
        let liveRecent = try UIFixture.installRecords(into: db, session: session, args: args)
        if liveRecent {
            figures.lastRecord = HomeFigures.LastRecord.today(try db.lastRecord(), now: UIFixture.designNow)
            let t = try db.pendingTally(now: UIFixture.designNow)
            figures.pendingCount = t.total; figures.livePendingCount = t.total
        }
        let model = AppModel(db: db, session: session, figures: figures, today: UIFixture.designNow, defaults: defaults,
                             scrollToBottom: UIFixture.value(for: "-uiScrollTo", in: args) == "bottom",
                             fixedNow: UIFixture.designNow)
        model.liveRecent = liveRecent
        // S27：-uiExpiry 时首页黄条的样数从库里算（其余夹具仍用稿子上的 3）
        model.liveExpiry = args.contains("-uiExpiry")
        model.refreshExpiring()
        // S26：-uiCountGoods 时设置页「11月 数了 N 种」从库里算（其余夹具仍用稿子上的 86 种）
        model.liveCount = args.contains("-uiCountGoods")
        model.refreshCountSummary()
        model.sellFixture = SellFixture.from(args)
        // S23b：账号名、注销申请中
        let username = UIFixture.value(for: "-uiUsername", in: args) ?? (role == .cashier ? "none" : "yuanhui")
        model.accountName = username == "none" ? nil : username
        if let until = UIFixture.value(for: "-uiDeletePending", in: args) {
            try db.setMeta(.deletePendingUntil, until)
            model.figures.deletePendingUntil = until
        }
        // 顶栏待传的 4 秒延迟：夹具里默认不等，带 -uiPendingDelay [秒] 才开
        if args.contains("-uiPendingDelay") {
            model.pendingDelay = .seconds(UIFixture.value(for: "-uiPendingDelay", in: args).flatMap(Double.init) ?? 4)
        }
        model.pendingReasonFixture = UIFixture.value(for: "-uiPendingReason", in: args).flatMap(PendingReason.init(rawValue:))
        if args.contains("-uiFirstSync") { model.firstSyncFixture = (194, 312) }  // 29 稿子上的数
        if UIFixture.value(for: "-uiAPI", in: args) != nil {
            model.services = UIFixture.fixtureServices(session: session, args: args)   // S23a：开通、设备打桩
        }
        if let images = try UIFixture.fixtureImages(db: db, session: session, args: args) {
            model.services = UIFixture.fixtureServices(session: session, args: args)   // S22d：查码打桩
            model.attachImages(images)
            UIFixture.confirmUpserts(db: db, session: session, images: images, args: args)
        }
        return model
    }
    #endif
}


/// 首次进入没做完 → 16 / 16b；做完 → 首页和它下面的各页（导航骨架）。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route]

    init(initialPath: [Route]) {
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        if !model.catalogReady {
            FirstSyncView()  // 29：商品拉完才能开卖，流水在后台接着拉
        } else if !model.onboarded {
            OnboardingView()
        } else {
            NavigationStack(path: $path) {
                HomeView()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
        }
    }
}

#if DEBUG
/// 联调探针（`-uiSyncProbe`）：本进程发过几次 `/v1/sync`、建过几个同步协调器。每秒刷新，读屏标签「requests=N;coordinators=M」
private struct SyncProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = "requests=\(SyncStats.shared.requests);coordinators=\(SyncCoordinator.created)"
            Text(text)
                .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                .accessibilityLabel(text)
                .accessibilityIdentifier("debug.sync")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
    }
}
#endif

#if DEBUG
/// 商品图探针（`-uiFrameProbe`）：卡顿（主线程两帧最长间隔）、屏幕上显示着真图的 Thumb 数。每 0.5 秒刷新，
/// 读屏标签「frames=state;maxGapMs=N;frameCount=N;shown=N;enabled=0|1」
private struct ImageProbe: View {
    let images: ProductImages?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let m = FrameMonitor.shared
            let text = "frames=\(m.state);maxGapMs=\(m.maxGapMs);frameCount=\(m.frames);shown=\(images?.debugShown ?? -1);enabled=\(images?.enabled == true ? 1 : 0)"
            Text(text)
                .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                .accessibilityLabel(text)
                .accessibilityIdentifier("debug.images")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}
#endif

/// 钥匙串暂时读不出来：不退出登录，解锁后再试
private struct TokenUnavailableView: View {
    let attempts: Int
    let retry: () -> Void
    let relogin: () -> Void
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手机还没准备好").font(TypeScale.title)
            Text("刚开机的手机要先解锁一次。解锁以后点「再试一次」，账和登录都还在。")
                .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            Button("再试一次", action: retry).accessibilityIdentifier("tokenUnavailable.retry")
            if attempts >= 2 {
                // 一直读不出来（钥匙串条目坏了）：给出口。没传的账留在本机，重新登录后自动补传
                Button("还是不行，重新登录") { confirming = true }
                    .accessibilityIdentifier("tokenUnavailable.relogin")
                    .confirmationDialog("重新登录？", isPresented: $confirming, titleVisibility: .visible) {
                        Button("重新登录", action: relogin)
                        Button("不了", role: .cancel) {}
                    } message: {
                        Text("这台手机上待传的账不会丢，重新登录后会自动补传。")
                    }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityIdentifier("page.tokenUnavailable")
    }
}

private struct StartupErrorView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本机的账本打不开").font(TypeScale.title)
            Text(message).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Palette.paper.ignoresSafeArea())
    }
}
