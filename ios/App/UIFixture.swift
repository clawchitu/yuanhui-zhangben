import Foundation

/// `-uiFixture` 机制：用启动参数直接打开某个界面（截图、UI 测试用），不走登录和同步。
///   -uiFixture gallery | gallery-1 … gallery-5   组件陈列页（全部 / 第 n 页）
///   -uiLargeText on | off                        覆盖「大字模式」设置
enum UIFixture {
    enum Screen: Equatable {
        case gallery(page: Int?)
    }

    static func screen(from args: [String]) -> Screen? {
        guard let value = value(for: "-uiFixture", in: args) else { return nil }
        if value == "gallery" { return .gallery(page: nil) }
        if value.hasPrefix("gallery-"), let page = Int(value.dropFirst("gallery-".count)) {
            return .gallery(page: page)
        }
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

    static func applyLaunchOverrides() {
        if let on = largeTextOverride(from: ProcessInfo.processInfo.arguments) {
            UserDefaults.standard.set(on, forKey: AppSettings.largeTextModeKey)
        }
    }
}
