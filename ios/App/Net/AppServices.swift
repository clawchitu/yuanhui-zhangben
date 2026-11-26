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
    /// 上次取到的 `/v1/config` 商品图开关（S22c / T11）。从没取到过按关，离线沿用上次值
    static let productImagesEnabled = "config.productImagesEnabled"
    /// 演示店（审核号）会话的设备 id：商品图直接不请求（S22c，Fable 裁定 8）
    static let demoDeviceId = "session.demoDeviceId"
    /// S23b：账号密码登录的会话用的账号名，值是「设备 id 换行 账号名」（只认同一个设备 id 的，换了会话就不算）
    static let sessionUsername = "session.username"
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
        self.imagesEnabled = defaults.bool(forKey: AuthDefaults.productImagesEnabled)
    }

    /// 启动时建。包内默认地址不在白名单里（配置写错）时返回 nil，登录页提示「连不上」
    static func make(args: [String] = ProcessInfo.processInfo.arguments) -> AppServices? {
        guard let bases = APIEnvironment.makeStore(args: args) else { return nil }
        let api = APIClient(bases: bases)  // 会话：ephemeral、不跟重定向（APIClient.makeSession）
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

    /// 商品图开关：上次取到的 `product_images_enabled`；从没取到过按关（T11）
    private(set) var imagesEnabled = false
    /// 开关变了的回调（当前会话的 `ProductImages.setEnabled`）
    @ObservationIgnored var onImagesSwitch: ((Bool) -> Void)?

    /// 这个设备的会话是不是演示店的（登录时记下）
    func isDemoSession(_ deviceId: UUID) -> Bool { defaults.string(forKey: AuthDefaults.demoDeviceId) == deviceId.uuidString }

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
            if c.imagesEnabled != imagesEnabled || defaults.object(forKey: AuthDefaults.productImagesEnabled) == nil {
                defaults.set(c.imagesEnabled, forKey: AuthDefaults.productImagesEnabled)
                imagesEnabled = c.imagesEnabled
                onImagesSwitch?(c.imagesEnabled)
            }
        } catch {
            Self.logger.notice("取配置没成功：\(String(describing: error), privacy: .public)")
        }
        configAttempts += 1
    }

    /// 登录 / 兑码 / 演示登录成功之后：令牌进钥匙串，开本地会话（新设备 id、本地新生成的店 id），记下 epoch。
    /// 登录响应里没有店 id（契约 `Session`），`storeId` 只用于本机 outbox 分组，S22a 再定是否改成服务器下发（PR 已知偏差）。
    /// S22b：开会话（清投影、压缩）不在主线程做（PR #9 约束），放到后台任务里等它。
    func establish(_ grant: SessionGrant, deviceId: UUID, db: LocalDB) async throws -> LocalSession {
        let ref = TokenRef.forDevice(deviceId)
        try tokens.save(grant.token, ref: ref)
        if grant.store.isDemo == true { defaults.set(deviceId.uuidString, forKey: AuthDefaults.demoDeviceId) }
        else { defaults.removeObject(forKey: AuthDefaults.demoDeviceId) }
        let s = try LocalSession(deviceId: deviceId, storeId: UUID(), role: grant.role, tokenRef: ref,
                                 storeName: grant.store.name, deviceLabel: grant.label)
        do {
            let epoch = grant.epoch
            let deletePending = grant.deletePendingUntil
            try await Task.detached(priority: .userInitiated) {
                try db.beginSession(s)
                try db.setMeta(.serverEpoch, epoch)
                // S23b：账号在注销申请中（7 天内登录）：开会话时就记下，首页马上提示、可撤回；第一趟同步之前就不推（§14 S04-2）
                try db.setMeta(.deletePendingUntil, deletePending)
            }.value
        } catch {
            tokens.delete(ref: ref)
            throw error
        }
        return s
    }

    /// S23b：账号密码登录成功后记下账号名（「账号与密码」页、23 注销页显示）
    func rememberUsername(_ name: String, deviceId: UUID) {
        defaults.set("\(deviceId.uuidString)\n\(name)", forKey: AuthDefaults.sessionUsername)
    }

    /// 这个会话的账号名（不是账号密码登录的会话为 nil）
    func username(deviceId: UUID) -> String? {
        guard let v = defaults.string(forKey: AuthDefaults.sessionUsername) else { return nil }
        let parts = v.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == deviceId.uuidString else { return nil }
        return parts[1]
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
