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

    @State private var boot: Boot = AppRoot.makeBoot(ProcessInfo.processInfo.arguments)

    var body: some View {
        AppShell {
            switch boot {
            case .gallery(let page):
                ComponentGallery(page: page)
            case .app(let model, let initialPath):
                MainView(initialPath: initialPath).environment(model)
            case .signedOut:
                SignedOutView()
            case .failed(let message):
                StartupErrorView(message: message)
            #if DEBUG
            case .scannerLab(let login):
                ScannerLab(login: login, args: ProcessInfo.processInfo.arguments)
            #endif
            }
        }
    }

    enum Boot {
        case gallery(Int?)
        case app(AppModel, [Route])
        /// 没有会话（Beta / Release）：「还没登录」占位页，S21 换成登录页
        case signedOut
        case failed(String)
        #if DEBUG
        /// 扫码测试页（S14，只在 Debug）
        case scannerLab(login: Bool)
        #endif
    }

    /// 本机正式库所在目录（Application Support）
    static func storeDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }

    @MainActor static func makeBoot(_ args: [String]) -> Boot {
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
            return try liveBoot(directory: try storeDirectory(), policy: .current)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// 正常启动（C 阶段还没有登录，S21 接）：打开本机正式库，有会话就进；没有会话按 `policy` 办（§14 S15-4）。
    @MainActor static func liveBoot(directory: URL, policy: NoSessionPolicy) throws -> Boot {
        let db = try LocalDB(path: directory.appendingPathComponent(liveDBName).path)
        if let session = try db.currentSession() {
            return .app(try liveModel(db: db, session: session), [])
        }
        switch policy {
        case .signedOut:
            return .signedOut
        #if DEBUG
        case .demoSession:
            // 演示会话放在单独的演示库里，正式库一个字也不写
            let demo = try LocalDB(path: directory.appendingPathComponent(demoDBName).path)
            if try demo.currentSession() == nil {
                try demo.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family,
                                                       tokenRef: "demo-local", storeName: "元辉烟酒店", deviceLabel: "新手机"))
                try DemoSeed.install(into: demo)
            }
            guard let session = try demo.currentSession() else { throw ShopCoreError.invalid("没有会话") }
            return .app(try liveModel(db: demo, session: session), [])
        #endif
        }
    }

    /// 本机正式库的文件名（登录后的真账都在这里）
    static let liveDBName = "zhangben.sqlite"

    @MainActor private static func liveModel(db: LocalDB, session: LocalSession) throws -> AppModel {
        var figures = HomeFigures()
        figures.pendingCount = try db.pendingOps().count
        figures.lastRecord = try db.lastRecord().map(HomeFigures.LastRecord.init)
        return AppModel(db: db, session: session, figures: figures)
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

/// 本机没有会话时怎么办（§14 S15-4）。
enum NoSessionPolicy: Equatable {
    /// Beta / Release：出「还没登录」页，不建会话、不写演示数据
    case signedOut
    #if DEBUG
    /// 只有 Debug 构建有：在单独的演示库里开一个家用演示会话、装上演示数据
    case demoSession
    #endif

    /// 当前构建用哪种。非 Debug 构建里根本没有 `demoSession` 这个分支
    static var current: NoSessionPolicy {
        #if DEBUG
        .demoSession
        #else
        .signedOut
        #endif
    }
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

/// 没有会话时的中性占位页（Beta / Release）。不建会话、不写演示数据；S21 换成登录页。
struct SignedOutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppRoot.title).font(TypeScale.title.weight(.bold))
            Text("还没登录").font(TypeScale.body)
            Text("这一版还不能登录，请等新版本。")
                .font(TypeScale.secondary)
                .foregroundStyle(Tokens.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.signedOut")
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
