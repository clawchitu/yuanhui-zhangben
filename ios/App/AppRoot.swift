import ShopCore
import SwiftUI

@main
struct YuanhuiZhangbenApp: App {
    init() {
        UIFixture.applyLaunchOverrides()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
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

    init(args: [String] = ProcessInfo.processInfo.arguments) {
        let services = AppRoot.needsServices(args) ? AppServices.make(args: args) : nil
        _services = State(initialValue: services)
        _boot = State(initialValue: AppRoot.makeBoot(args, services: services))
    }

    var body: some View {
        AppShell {
            ZStack {
                switch boot {
                case .gallery(let page):
                    ComponentGallery(page: page)
                case .app(let model, let initialPath):
                    MainView(initialPath: initialPath).environment(model)
                case .signedOut(let login):
                    LoginFlow(model: login)
                case .failed(let message):
                    StartupErrorView(message: message)
                #if DEBUG
                case .scannerLab(let login):
                    ScannerLab(login: login, args: ProcessInfo.processInfo.arguments)
                #endif
                }
                if services?.needsUpdate == true {
                    UpdateRequiredView().transition(.opacity)
                }
            }
        }
        .task { await services?.refreshConfig() }
        .onReceive(NotificationCenter.default.publisher(for: AppRoot.signedIn)) { note in
            // 登录成功：进新会话（还没做完首次进入，先到 16 / 16b）
            guard let db = note.object as? LocalDB, let session = note.userInfo?["session"] as? LocalSession else { return }
            do { boot = .app(try AppRoot.liveModel(db: db, session: session, services: services), []) }
            catch { boot = .failed(String(describing: error)) }
        }
        .onChange(of: scenePhase) { old, phase in
            // 回到前台：再取一次配置、补报没报上的手机名（§14 S15-2）
            guard phase == .active, old == .background else { return }
            Task {
                await services?.refreshConfig()
                if case .app(let model, _) = boot { await model.reportPendingLabel() }
            }
        }
    }

    enum Boot {
        case gallery(Int?)
        case app(AppModel, [Route])
        /// 没有会话：登录页（13）
        case signedOut(LoginModel)
        case failed(String)
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
        let db = try LocalDB(path: directory.appendingPathComponent(liveDBName).path)
        try clearLegacyDemo(directory: directory, db: db, defaults: defaults)
        if let session = try db.currentSession() {
            if tokens.token(ref: session.tokenRef) != nil {
                let model = try liveModel(db: db, session: session, services: services)
                return .app(model, [])
            }
            // 钥匙串里没有这个会话的令牌（重装、换机恢复）：不能当作已登录
            try db.endSession()
        }
        return .signedOut(makeLogin(db: db, services: services))
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
        figures.pendingCount = try db.pendingOps().count
        figures.lastRecord = try db.lastRecord().map(HomeFigures.LastRecord.init)
        let model = AppModel(db: db, session: session, figures: figures)
        model.services = services
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
            figures.staleUnsyncedCount = 5
        }
        let defaults = UserDefaults.standard
        switch screen {
        case .home, .settings: defaults.set(session.deviceId.uuidString, forKey: AppSettings.onboardedDeviceKey)
        case .onboarding: defaults.removeObject(forKey: AppSettings.onboardedDeviceKey)
        default: break
        }
        try UIFixture.installSellExtras(into: db, args: args)
        if args.contains("-uiPriorSales") { figures.pendingCount = try db.pendingOps().count }
        // S20：-uiRecords 装上稿子 07a / 07b / 07c 的账，首页「刚记的」和待传笔数都从库里取
        let liveRecent = try UIFixture.installRecords(into: db, session: session, args: args)
        if liveRecent {
            figures.lastRecord = try db.lastRecord().map(HomeFigures.LastRecord.init)
            figures.pendingCount = try db.pendingOps().count
        }
        let model = AppModel(db: db, session: session, figures: figures, today: UIFixture.designNow, defaults: defaults,
                             scrollToBottom: UIFixture.value(for: "-uiScrollTo", in: args) == "bottom",
                             fixedNow: UIFixture.designNow)
        model.liveRecent = liveRecent
        model.sellFixture = SellFixture.from(args)
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
        if !model.onboarded {
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
