import Foundation
import os
import ShopCore

/// 按构建配置分开的服务器地址白名单和包内默认地址（plan-v2 §8 S21、§9.2；PR #33 Fable 交接 4、5）。
///
/// - Release：只允许 `api.yuanhuishop.cn`，默认也是它。IP 字面量只写在 `#if BETA || DEBUG` 里，Release 产物里没有
///   （`scripts/release-check.sh` 查二进制）。
/// - Beta：`api.yuanhuishop.cn` 和 `47.117.184.253` 都允许，默认域名（备案 11/26 通过后从 IP 改过来）。IP 留在白名单里只作回退：
///   域名出问题时服务器可以用 `/v1/config` 的 `api_base` 把内测包指回 IP，不用重新出包。两者都是 Let's Encrypt 公网证书，
///   走系统信任链，没有 ATS 例外，也没有证书 pin。
/// - Debug：同 Beta，另外放行 `http://localhost` / `http://127.0.0.1` 任意端口（只给 XCUITest 桩服务器），默认本机 8787。
/// 白名单写死在包里，不从服务器取；服务器下发的值只能在这里面挑。
enum APIEnvironment {
    static let domainHost = "api.yuanhuishop.cn"

    static var policy: APIBasePolicy {
        #if DEBUG
        APIBasePolicy(hosts: [domainHost, betaIPHost], allowLoopbackHTTP: true)
        #elseif BETA
        APIBasePolicy(hosts: [domainHost, betaIPHost])
        #else
        APIBasePolicy(hosts: [domainHost])
        #endif
    }

    #if BETA || DEBUG
    /// 备案前的服务器地址，现在只是 Beta / Debug 白名单里的回退地址，不再是默认。写成整条地址（长于 15 字节，进常量区）：`release-check.sh` 查 Beta 二进制里有它、
    /// Release 二进制里没有 IP，查法才有效（Swift 把 15 字节以内的字符串直接编进指令，`grep` 查不到）
    static let betaIPBase = "https://47.117.184.253"
    static var betaIPHost: String { URL(string: betaIPBase)!.host! }
    #endif

    /// 包内默认地址。Debug 可用 `-uiAPIBase http://localhost:端口` 换成测试桩的地址（仍要过白名单）
    static func defaultBase(args: [String] = ProcessInfo.processInfo.arguments) -> String {
        #if DEBUG
        if let v = UIFixture.value(for: "-uiAPIBase", in: args) { return v }
        return "http://localhost:8787"
        #else
        return "https://\(domainHost)"
        #endif
    }

    static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "api-base")

    /// 启动时（发第一个请求之前）建一次：已存地址在这里复检
    static func makeStore(defaults: UserDefaults = .standard, args: [String] = ProcessInfo.processInfo.arguments) -> APIBaseStore? {
        #if DEBUG
        // XCUITest：预置一条已存地址（验收「白名单之外的已存地址启动后被删」）
        if let seeded = UIFixture.value(for: "-uiSeedStoredAPIBase", in: args) {
            defaults.set(seeded, forKey: APIBaseStore.storageKey)
        }
        if args.contains("-uiResetStoredAPIBase") { defaults.removeObject(forKey: APIBaseStore.storageKey) }
        #endif
        return APIBaseStore(defaultBase: defaultBase(args: args), policy: policy, defaults: defaults,
                            log: { logger.notice("\($0, privacy: .public)") })
    }
}
