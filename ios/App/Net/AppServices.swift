import Foundation
import Observation
import os
import ShopCore

/// 本机存的几样和登录有关的小东西（UserDefaults）
enum AuthDefaults {
    /// 登录页「账号」框记住的上次用户名（13 稿「记住了」）
    static let lastUsername = "login.lastUsername"
    /// 本机改了名、还没报上服务器的手机名（§14 S15-2）。登录时带上；登录后改名失败也留在这里，回前台再报
    static let pendingDeviceLabel = "pendingDeviceLabel"
}

/// 网络这一层的全局服务（S21）：服务器地址、API 客户端、钥匙串里的令牌、`/v1/config`。
/// 启动时建一次：`APIEnvironment.makeStore()` 在 `init` 里复检本机存的地址，所以第一个请求之前已经复检过。
@MainActor @Observable
final class AppServices {
    let api: APIClient
    let tokens: TokenStore
    let defaults: UserDefaults
    /// 本包的 build 号（CFBundleVersion）
    let build: Int
    /// 最近一次取到的 `/v1/config`；没取到过为 nil
    private(set) var config: RemoteConfig?
    /// 至少取过一次（成不成功都算）
    private(set) var configAttempts = 0
    #if DEBUG
    /// 截图用：不连服务器也当作要更新（`-uiRequireUpdate`）
    var forceUpdate = false
    #endif

    init(api: APIClient, tokens: TokenStore, defaults: UserDefaults = .standard, build: Int = AppServices.bundleBuild) {
        self.api = api
        self.tokens = tokens
        self.defaults = defaults
        self.build = build
    }

    /// 启动时建。包内默认地址不在白名单里（配置写错）时返回 nil，登录页提示「连不上」
    static func make(args: [String] = ProcessInfo.processInfo.arguments) -> AppServices? {
        guard let bases = APIEnvironment.makeStore(args: args) else { return nil }
        let api = APIClient(bases: bases, session: URLSession(configuration: .ephemeral))
        let s = AppServices(api: api, tokens: KeychainTokenStore())
        #if DEBUG
        s.forceUpdate = args.contains("-uiRequireUpdate")
        #endif
        return s
    }

    static var bundleBuild: Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
    }

    /// `min_build` 高于本包：整屏「请更新」
    var needsUpdate: Bool {
        #if DEBUG
        if forceUpdate { return true }
        #endif
        return config?.requiresUpdate(build: build) ?? false
    }

    /// 「看看演示」入口：服务器开关打开才显示（默认关；没取到配置也不显示）
    var demoLoginEnabled: Bool { config?.demoLoginEnabled ?? false }

    /// 登录页「隐私政策」链接：服务器给的；没取到配置时用和服务器默认值一样的地址
    var privacyURL: URL {
        config.flatMap { URL(string: $0.privacyURL) } ?? URL(string: "https://yuanhuishop.cn/privacy")!
    }

    private static let logger = Logger(subsystem: "cn.yuanhuishop.zhangben", category: "config")

    /// 启动和每次回到前台各取一次（§8 S21）。返回了 `api_base` 就交给白名单判断，过了才采用
    func refreshConfig() async {
        do {
            let c = try await api.config()
            api.bases.adopt(c.apiBase)
            config = c
        } catch {
            Self.logger.notice("取配置没成功：\(String(describing: error), privacy: .public)")
        }
        configAttempts += 1
    }

    /// 登录 / 兑码 / 演示登录成功之后：令牌进钥匙串，开本地会话（新设备 id、本地新生成的店 id），记下 epoch。
    /// 登录响应里没有店 id（契约 `Session`），`storeId` 只用于本机 outbox 分组，S22a 再定是否改成服务器下发（PR 已知偏差）。
    func establish(_ grant: SessionGrant, deviceId: UUID, db: LocalDB) throws -> LocalSession {
        let ref = TokenRef.forDevice(deviceId)
        try tokens.save(grant.token, ref: ref)
        let s = try LocalSession(deviceId: deviceId, storeId: UUID(), role: grant.role, tokenRef: ref,
                                 storeName: grant.store.name, deviceLabel: grant.label)
        do {
            try db.beginSession(s)
            try db.setMeta(.serverEpoch, grant.epoch)
        } catch {
            tokens.delete(ref: ref)
            throw error
        }
        return s
    }

    /// 还没报上服务器的手机名（§14 S15-2）
    var pendingDeviceLabel: String? {
        get { defaults.string(forKey: AuthDefaults.pendingDeviceLabel) }
        set {
            if let newValue { defaults.set(newValue, forKey: AuthDefaults.pendingDeviceLabel) }
            else { defaults.removeObject(forKey: AuthDefaults.pendingDeviceLabel) }
        }
    }
}
