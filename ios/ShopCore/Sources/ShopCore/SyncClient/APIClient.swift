import Foundation

/// `GET /v1/config`（契约 components/schemas/Config）
public struct RemoteConfig: Decodable, Equatable, Sendable {
    public let minBuild: Int
    public let demoLoginEnabled: Bool
    public let privacyURL: String
    public let supportURL: String
    public let apiBase: String?

    enum CodingKeys: String, CodingKey {
        case minBuild = "min_build", demoLoginEnabled = "demo_login_enabled", privacyURL = "privacy_url"
        case supportURL = "support_url", apiBase = "api_base"
    }

    /// 本包的 build 号低于 `min_build` 时要显示「请更新」
    public func requiresUpdate(build: Int) -> Bool { build < minBuild }
}

/// 登录 / 兑码 / 演示登录成功的响应（契约 components/responses/Session）
public struct SessionGrant: Decodable, Equatable, Sendable {
    public struct Store: Decodable, Equatable, Sendable {
        public let name: String
        public let isDemo: Bool?
        enum CodingKeys: String, CodingKey { case name, isDemo = "is_demo" }
    }
    public let token: String
    public let epoch: String
    public let role: Role
    public let store: Store
    public let label: String
    public let deletePendingUntil: String?
    enum CodingKeys: String, CodingKey { case token, epoch, role, store, label, deletePendingUntil = "delete_pending_until" }
}

/// 服务器的错误响应（契约 components/schemas/Error），或者连不上
public enum APIError: Error, Equatable, Sendable {
    case server(status: Int, code: String, lockedUntil: Date?, retryAfterS: Int?)
    case transport(String)
    case badResponse(Int)
    /// 服务器回了 30x 要把请求转去别处：一律不跟（白名单只认第一跳，跟过去就可能把密码发到白名单外）
    case redirected(Int)

    public var code: String? { if case .server(_, let c, _, _) = self { c } else { nil } }
}

/// 扫码登录的码：`YHZB1:<code>`（契约 /v1/auth/pair/redeem）。别的码一律不认
public enum PairingCode {
    public static let prefix = "YHZB1:"
    public static func parse(_ raw: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let code = String(raw.dropFirst(prefix.count))
        guard !code.isEmpty, code.count <= 128, code.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return code
    }
}

/// 网络层（S21）：基址来自 `APIBaseStore`。请求先打当前地址；用的是下发地址且**连不上**（传输错误，不是 HTTP 错误）时，
/// 这一次退回包内默认地址重发，已存地址不删，下次再试（§8 S21）。本段不做同步（S22a）。
///
/// **不跟随重定向**：会话和每个任务都挂 `NoRedirect`，30x 原样交回来，按 `APIError.redirected` 失败处理，
/// 请求不会发往 `Location` 指的地址（PR #35 Codex 评审必须修 1）。
public final class APIClient: Sendable {
    public let bases: APIBaseStore
    let session: URLSession

    public init(bases: APIBaseStore, session: URLSession = APIClient.makeSession()) {
        self.bases = bases
        self.session = session
    }

    /// 本 App 发 API 请求用的会话：ephemeral（不落 cookie、缓存），拒绝一切重定向
    public static func makeSession(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration, delegate: NoRedirect.shared, delegateQueue: nil)
    }

    /// 收到 30x 时告诉系统「不跟」：`completionHandler(nil)`，任务带着 30x 响应结束
    final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirect()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func config() async throws -> RemoteConfig {
        try await send("GET", "/v1/config", body: nil as [String: String]?, token: nil)
    }

    public func login(username: String, password: String, deviceId: UUID, label: String?) async throws -> SessionGrant {
        var body = ["username": username, "password": password, "device_id": deviceId.uuidString.lowercased()]
        if let label { body["label"] = label }
        return try await send("POST", "/v1/auth/login", body: body, token: nil)
    }

    public func redeem(code: String, deviceId: UUID) async throws -> SessionGrant {
        try await send("POST", "/v1/auth/pair/redeem", body: ["code": code, "device_id": deviceId.uuidString.lowercased()], token: nil)
    }

    public func demoLogin(deviceId: UUID) async throws -> SessionGrant {
        try await send("POST", "/v1/auth/demo", body: ["device_id": deviceId.uuidString.lowercased()], token: nil)
    }

    struct Label: Decodable { let label: String }

    /// `PATCH /v1/devices/me`（§14 S15-2）。返回服务器定下的名字（重名会加序号）
    public func renameDevice(_ label: String, token: String) async throws -> String {
        let r: Label = try await send("PATCH", "/v1/devices/me", body: ["label": label], token: token)
        return r.label
    }

    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, token: String?) async throws -> T {
        let primary = bases.current
        do {
            return try await sendOnce(method, base: primary, path, body: body, token: token)
        } catch APIError.transport(let why) where primary != bases.defaultBase {
            _ = why
            return try await sendOnce(method, base: bases.defaultBase, path, body: body, token: token)
        }
    }

    func sendOnce<B: Encodable, T: Decodable>(_ method: String, base: URL, _ path: String, body: B?, token: String?) async throws -> T {
        var req = URLRequest(url: APIBase.url(base, path: path), timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        // 任务级也挂上：外面传进来的会话没带 delegate 时同样不跟
        do { (data, resp) = try await session.data(for: req, delegate: NoRedirect.shared) } catch { throw APIError.transport(String(describing: error)) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(0) }
        if (300..<400).contains(http.statusCode) { throw APIError.redirected(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.badResponse(http.statusCode) }
    }

    struct ErrorBody: Decodable {
        let code: String
        let locked_until: String?
        let retry_after_s: Int?
    }

    static func error(status: Int, data: Data) -> APIError {
        guard let e = try? JSONDecoder().decode(ErrorBody.self, from: data) else { return .badResponse(status) }
        return .server(status: status, code: e.code, lockedUntil: e.locked_until.flatMap(parseDate), retryAfterS: e.retry_after_s)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
