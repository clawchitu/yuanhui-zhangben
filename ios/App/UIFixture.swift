import Foundation
import ShopCore

/// `-uiFixture` 机制：用启动参数直接打开某个界面（截图、UI 测试用），不走登录和同步。
///
/// 所有构建都认的（只换界面状态、不碰会话，§14 S15-7）：
///   -uiFixture gallery | gallery-1 … gallery-5   组件陈列页（全部 / 第 n 页）
///   -uiLargeText on | off                        覆盖「大字模式」设置
///
/// 只在 Debug 构建里编译进去的（会开出会话、换身份或装演示数据，§14 S15-4 / S15-7）：
///   -uiFixture home | home-unsynced              首页（01 / 02 / 25a；已做完首次进入）
///   -uiFixture onboarding                        首次进入（16 / 16b）
///   -uiFixture settings                          设置（21a / 21b）
///   -uiRole family | cashier | review            用内存库 + 演示数据，以这个身份开会话（默认 family）
///   -uiRoute stockIn,settings,…                  开好后把这些路由直接塞进导航栈（测「硬塞路由也进不去」）
///   -uiFreshInstall                              当作刚装好：清掉本机的字号选择和「首次进入做完了」
///   -uiScrollTo bottom                           首页打开后滚到底（截长页用）
///   -uiFixture scanner | scanner-login           扫码测试页（27a / 27b 的样子，S14）
///   -uiCamera denied|authorized|notDetermined    把相机权限当成这个值（S14）
///   -uiScan / -uiScanSource / -uiScanGap / -uiScanDelay   FakeScanner 喂码，见 `FakeScanner`（S14）
/// Beta / Release 里这些参数一律不认：没有会话就出「还没登录」页。
enum UIFixture {
    enum Screen: Equatable {
        case gallery(page: Int?)
        #if DEBUG
        case home(unsynced: Bool)
        case onboarding
        case settings
        case scanner(login: Bool)
        #endif
    }

    static func screen(from args: [String]) -> Screen? {
        guard let value = value(for: "-uiFixture", in: args) else { return nil }
        if value == "gallery" { return .gallery(page: nil) }
        if value.hasPrefix("gallery-"), let page = Int(value.dropFirst("gallery-".count)) {
            return .gallery(page: page)
        }
        #if DEBUG
        switch value {
        case "home": return .home(unsynced: false)
        case "home-unsynced": return .home(unsynced: true)
        case "onboarding": return .onboarding
        case "settings": return .settings
        case "scanner": return .scanner(login: false)
        case "scanner-login": return .scanner(login: true)
        default: break
        }
        #endif
        return nil
    }

    static func largeTextOverride(from args: [String]) -> Bool? {
        switch value(for: "-uiLargeText", in: args) {
        case "on": true
        case "off": false
        default: nil
        }
    }

    static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func applyLaunchOverrides(_ args: [String] = ProcessInfo.processInfo.arguments,
                                     defaults: UserDefaults = .standard) {
        #if DEBUG
        if args.contains("-uiFreshInstall") {
            defaults.removeObject(forKey: AppSettings.largeTextModeKey)
            defaults.removeObject(forKey: AppSettings.onboardedDeviceKey)
        }
        #endif
        if let on = largeTextOverride(from: args) {
            defaults.set(on, forKey: AppSettings.largeTextModeKey)
        }
    }
}

extension UIFixture.Screen {
    var isGallery: Bool {
        if case .gallery = self { return true }
        return false
    }
}

#if DEBUG
/// 下面这些会开出会话（换身份、装演示数据），只在 Debug 构建里有（§14 S15-4 / S15-7）。
extension UIFixture {
    static func role(from args: [String]) -> Role? {
        guard let v = value(for: "-uiRole", in: args) else {
            // 有界面夹具但没写身份：默认家用
            if let s = screen(from: args), !s.isGallery { return .family }
            return nil
        }
        return Role(rawValue: v).flatMap { $0 == .revoked ? nil : $0 }
    }

    /// `-uiRoute a,b`：开好后直接塞进导航栈的路由（认不出的名字忽略）
    static func injectedRoutes(from args: [String]) -> [Route] {
        guard let v = value(for: "-uiRoute", in: args) else { return [] }
        return v.split(separator: ",").compactMap { Route(rawValue: String($0)) }
    }

    /// 演示会话的设备 id：每种身份固定一个，重启后「首次进入做完了」仍认得这台手机
    static func demoDeviceId(_ role: Role) -> UUID {
        switch role {
        case .family: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F001")!
        case .cashier: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F002")!
        case .review, .revoked: UUID(uuidString: "5EED0000-0000-4000-8000-00000000F003")!
        }
    }

    /// 稿子上的时间：2026-11-19 星期四 19:48（上海）
    static let designNow = Date(timeIntervalSince1970: 1_795_088_880)
}
#endif
