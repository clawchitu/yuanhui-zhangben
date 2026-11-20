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
            case .failed(let message):
                StartupErrorView(message: message)
            }
        }
    }

    enum Boot {
        case gallery(Int?)
        case app(AppModel, [Route])
        case failed(String)
    }

    @MainActor static func makeBoot(_ args: [String]) -> Boot {
        let screen = UIFixture.screen(from: args)
        if case .gallery(let page) = screen { return .gallery(page) }
        do {
            if let role = UIFixture.role(from: args) {
                return .app(try fixtureModel(role: role, screen: screen, args: args), screen == .settings ? [.settings] : [])
            }
            return .app(try liveModel(), [])
        } catch {
            return .failed(String(describing: error))
        }
    }

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
        return AppModel(db: db, session: session, figures: figures, today: UIFixture.designNow, defaults: defaults,
                        scrollToBottom: UIFixture.value(for: "-uiScrollTo", in: args) == "bottom")
    }

    /// 正常启动（C 阶段还没有登录，S21 接）：打开本机库；还没有会话就开一个家用演示会话并装上演示数据。
    @MainActor static func liveModel() throws -> AppModel {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let db = try LocalDB(path: dir.appendingPathComponent("zhangben.sqlite").path)
        if try db.currentSession() == nil {
            try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family,
                                                 tokenRef: "demo-local", storeName: "元辉烟酒店", deviceLabel: "新手机"))
            try DemoSeed.install(into: db)
        }
        guard let session = try db.currentSession() else { throw ShopCoreError.invalid("没有会话") }
        var figures = HomeFigures()
        figures.pendingCount = try db.pendingOps().count
        return AppModel(db: db, session: session, figures: figures)
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
