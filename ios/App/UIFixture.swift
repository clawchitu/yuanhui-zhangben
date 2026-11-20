import Foundation
import ShopCore

/// `-uiFixture` 机制：用启动参数直接打开某个界面（截图、UI 测试用），不走登录和同步。
///   -uiFixture gallery | gallery-1 … gallery-5   组件陈列页（全部 / 第 n 页）
///   -uiFixture home | home-unsynced              首页（01 / 02 / 25a；已做完首次进入）
///   -uiFixture onboarding                        首次进入（16 / 16b）
///   -uiFixture settings                          设置（21a / 21b）
///   -uiRole family | cashier | review            用内存库 + 演示数据，以这个身份开会话（默认 family）
///   -uiFreshInstall                              当作刚装好：清掉本机的字号选择和「首次进入做完了」
///   -uiLargeText on | off                        覆盖「大字模式」设置
///   -uiScrollTo bottom                           首页打开后滚到底（截长页用）
enum UIFixture {
    enum Screen: Equatable {
        case gallery(page: Int?)
        case home(unsynced: Bool)
        case onboarding
        case settings
    }

    static func screen(from args: [String]) -> Screen? {
        guard let value = value(for: "-uiFixture", in: args) else { return nil }
        switch value {
        case "gallery": return .gallery(page: nil)
        case "home": return .home(unsynced: false)
        case "home-unsynced": return .home(unsynced: true)
        case "onboarding": return .onboarding
        case "settings": return .settings
        default: break
        }
        if value.hasPrefix("gallery-"), let page = Int(value.dropFirst("gallery-".count)) {
            return .gallery(page: page)
        }
        return nil
    }

    static func role(from args: [String]) -> Role? {
        guard let v = value(for: "-uiRole", in: args) else {
            // 有界面夹具但没写身份：默认家用
            if let s = screen(from: args), !s.isGallery { return .family }
            return nil
        }
        return Role(rawValue: v).flatMap { $0 == .revoked ? nil : $0 }
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
        if args.contains("-uiFreshInstall") {
            defaults.removeObject(forKey: AppSettings.largeTextModeKey)
            defaults.removeObject(forKey: AppSettings.onboardedDeviceKey)
        }
        if let on = largeTextOverride(from: args) {
            defaults.set(on, forKey: AppSettings.largeTextModeKey)
        }
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

extension UIFixture.Screen {
    var isGallery: Bool {
        if case .gallery = self { return true }
        return false
    }
}
