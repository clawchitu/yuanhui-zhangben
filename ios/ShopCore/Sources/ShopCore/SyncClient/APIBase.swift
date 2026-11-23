import Foundation

/// 服务器地址白名单（plan-v2 §8 S21「服务器地址由服务器配置下发」，PR #33 Fable 交接 1–5）。
///
/// 白名单写死在包里、不从服务器取。ShopCore 会编进 Release 包，所以这里**不写任何主机字面量**：
/// 允许哪些主机由 App 按构建配置（`#if BETA` / `#if DEBUG`）传进来，Release 产物里不出现 IP（S30 归档检查）。
public struct APIBasePolicy: Sendable, Equatable {
    /// 允许的 https 主机，整串比较（不做前缀、后缀、包含匹配，不转小写）
    public let hosts: Set<String>
    /// 只给 Debug：放行 `http://localhost` 和 `http://127.0.0.1` 的任意端口（XCUITest 桩服务器用）
    public let allowLoopbackHTTP: Bool

    public init(hosts: Set<String>, allowLoopbackHTTP: Bool = false) {
        self.hosts = hosts
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]
}

public enum APIBase {
    /// 校验并归一（交接 1、2）。通过时返回归一后的地址：无端口 443、无末尾 `/`（`https://主机`、Debug 的 `http://localhost:端口`）；
    /// 任何一条不满足、或解析失败，返回 nil。服务器下发的、本机存着的、包内默认的都走这一个函数。
    public static func accept(_ raw: String, policy: APIBasePolicy) -> URL? {
        guard let c = URLComponents(string: raw), let scheme = c.scheme, let host = c.host else { return nil }
        // 百分号编码的主机（%2e 之类）一律不收：编码前后必须一样
        guard c.percentEncodedHost == host, !host.isEmpty else { return nil }
        guard c.user == nil, c.password == nil else { return nil }
        guard c.path.isEmpty || c.path == "/" else { return nil }
        guard c.query == nil, c.fragment == nil else { return nil }
        if scheme == "https", policy.hosts.contains(host) {
            guard c.port == nil || c.port == 443 else { return nil }
            return URL(string: "https://\(host)")
        }
        if policy.allowLoopbackHTTP, scheme == "http", APIBasePolicy.loopbackHosts.contains(host) {
            guard let port = c.port else { return URL(string: "http://\(host)") }
            guard (1...65535).contains(port) else { return nil }
            return URL(string: "http://\(host):\(port)")
        }
        return nil
    }

    /// 拼接口路径：`base` 已归一（无末尾 `/`），`path` 以 `/` 开头，不会出现 `//v1/…`
    public static func url(_ base: URL, path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + (path.hasPrefix("/") ? path : "/" + path))!
    }
}

/// 当前用哪个服务器地址：包内默认地址 + 本机存的下发地址（UserDefaults）。
///
/// - 启动时（发第一个请求之前）`init` 就复检已存地址，不通过就删掉、退回默认（交接 3）。
/// - `adopt` 处理 `/v1/config` 的 `api_base`：过白名单、归一，和当前的不一样才存。不在白名单的丢掉、记一条本地日志。
/// - 新地址连不上时 `APIClient` 这一次退回默认地址重发，已存的合法地址不删，下次再试。
public final class APIBaseStore: @unchecked Sendable {
    public static let storageKey = "apiBase.adopted"

    public let defaultBase: URL
    public let policy: APIBasePolicy
    private let defaults: UserDefaults
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stored: URL?

    public enum AdoptResult: Equatable, Sendable { case absent, unchanged, adopted(URL), rejected }

    /// `defaultBase` 也过一遍白名单：包内配置写错时 `init` 失败，不带着坏地址跑
    public init?(defaultBase raw: String, policy: APIBasePolicy, defaults: UserDefaults = .standard,
                 log: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let base = APIBase.accept(raw, policy: policy) else { return nil }
        self.defaultBase = base
        self.policy = policy
        self.defaults = defaults
        self.log = log
        if let s = defaults.string(forKey: Self.storageKey) {
            if let ok = APIBase.accept(s, policy: policy) {
                stored = ok == base ? nil : ok
                if stored == nil { defaults.removeObject(forKey: Self.storageKey) }
            } else {
                defaults.removeObject(forKey: Self.storageKey)
                log("本机存的服务器地址不在白名单里，已删掉，改用包内默认地址")
            }
        }
    }

    /// 现在请求打到哪里
    public var current: URL { lock.withLock { stored ?? defaultBase } }

    /// 用的是下发的地址（不是包内默认）
    public var usingAdopted: Bool { lock.withLock { stored != nil } }

    @discardableResult
    public func adopt(_ value: String?) -> AdoptResult {
        guard let value else { return .absent }
        guard let ok = APIBase.accept(value, policy: policy) else {
            log("服务器下发的地址不在白名单里，没有采用")
            return .rejected
        }
        return lock.withLock {
            if ok == (stored ?? defaultBase) { return .unchanged }
            if ok == defaultBase {
                stored = nil
                defaults.removeObject(forKey: Self.storageKey)
            } else {
                stored = ok
                defaults.set(ok.absoluteString, forKey: Self.storageKey)
            }
            return .adopted(ok)
        }
    }
}
