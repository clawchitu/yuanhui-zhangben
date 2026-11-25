import Foundation

/// `GET /v1/config`（契约 components/schemas/Config）
public struct RemoteConfig: Decodable, Equatable, Sendable {
    public let minBuild: Int
    public let demoLoginEnabled: Bool
    public let privacyURL: String
    public let supportURL: String
    public let apiBase: String?
    /// 商品图开关（S22d-server 加，T11）。可选解析：缺字段（老服务器）当 false
    public let productImagesEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case minBuild = "min_build", demoLoginEnabled = "demo_login_enabled", privacyURL = "privacy_url"
        case supportURL = "support_url", apiBase = "api_base", productImagesEnabled = "product_images_enabled"
    }

    /// 开关是否打开（缺字段当关）
    public var imagesEnabled: Bool { productImagesEnabled ?? false }

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

/// `GET /v1/barcode-lookup/:barcode`（契约 components/schemas/BarcodeLookup）。收银员只有 found、name、spec、has_image
public struct BarcodeLookupResult: Decodable, Equatable, Sendable {
    public let found: Bool
    public let name: String?
    public let spec: String?
    public let brand: String?
    public let hasImage: Bool?
    /// found=false 时服务器这次没问到外部条码库（超时、出错、没配 AppCode）：不是明确没查到，别记住，下次再查
    public let retryLater: Bool?
    /// 商品图候选（S22d）：家用、审核才有；收银员的响应不带
    public let imageCandidates: ImageCandidates?
    enum CodingKeys: String, CodingKey {
        case found, name, spec, brand, hasImage = "has_image", retryLater = "retry_later", imageCandidates = "image_candidates"
    }
    public init(found: Bool, name: String? = nil, spec: String? = nil, brand: String? = nil, hasImage: Bool? = nil, retryLater: Bool? = nil,
                imageCandidates: ImageCandidates? = nil) {
        self.found = found; self.name = name; self.spec = spec; self.brand = brand; self.hasImage = hasImage; self.retryLater = retryLater
        self.imageCandidates = imageCandidates
    }
}

/// 商品图候选（契约 components/schemas/ImageCandidates，S22d）。`ids` 按快鸟给的顺序，最多 6 个。
/// 认不出的 `state` 当 `none`；不合规的 id（不是 16 位小写十六进制）丢掉，不拿它拼地址
public struct ImageCandidates: Decodable, Equatable, Sendable {
    public enum State: String, Sendable { case none, pending, ready }
    public let state: State
    public let ids: [String]

    public init(state: State, ids: [String]) {
        self.state = state
        var seen = Set<String>()
        self.ids = Array(ids.filter { Self.isCandidateId($0) && seen.insert($0).inserted }.prefix(Self.maxCount))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .state)
        self.init(state: State(rawValue: raw) ?? .none, ids: try c.decodeIfPresent([String].self, forKey: .ids) ?? [])
    }
    enum CodingKeys: String, CodingKey { case state, ids }

    public static let maxCount = 6
    public static let empty = ImageCandidates(state: .none, ids: [])

    /// 契约 CandidateId：`^[0-9a-f]{16}$`
    public static func isCandidateId(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// `POST /v1/images/:id/select`、`PUT /v1/images/:id` 的响应（契约 ImageVer）
struct ImageVerBody: Decodable { let image_ver: Int }

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
/// **兑码不退回重发**：传输错误也可能是服务器已经处理、回包没到（超时、连接中途断）。兑码是一次性的，
/// 重发只会得到 `pairing_used`，用户看到「已经用过了」其实已经兑成功。所以兑码只发一次，失败让用户重扫（PR #35 Fable 可选 4）。
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
        try await send("POST", "/v1/auth/pair/redeem", body: ["code": code, "device_id": deviceId.uuidString.lowercased()],
                       token: nil, fallback: false)
    }

    public func demoLogin(deviceId: UUID) async throws -> SessionGrant {
        try await send("POST", "/v1/auth/demo", body: ["device_id": deviceId.uuidString.lowercased()], token: nil)
    }

    struct Label: Decodable { let label: String }

    /// 条码查询只认这些字符（契约 Barcode：1–64 个可见 ASCII，服务器按 `^[0-9A-Za-z._-]+$` 校验）
    public static func isLookupBarcode(_ code: String) -> Bool {
        (1...64).contains(code.count) && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// `GET /v1/barcode-lookup/:barcode`（真机热修：S21 起就该接，之前一直是桩）。服务器先查自家缓存、没有再调快鸟（2 秒超时），
    /// 所以这里 5 秒就不等了：超时按连不上处理，界面让人手填。下发地址连不上、退回默认地址重发时，两次加起来也不超过 5 秒。
    /// 码不合法直接当没查到，不发请求
    public func barcodeLookup(_ code: String, token: String) async throws -> BarcodeLookupResult {
        guard Self.isLookupBarcode(code) else { return BarcodeLookupResult(found: false) }
        return try await send("GET", "/v1/barcode-lookup/\(code)", body: nil as [String: String]?, token: token, timeoutMs: Self.lookupBudgetMs)
    }
    /// 查码的总时限（毫秒），含退回默认地址的那一次
    public static let lookupBudgetMs = 5_000

    // MARK: - 商品图（S22d）

    /// 一张候选缩图最多多大（服务器存 200px JPEG，约 10 KB；和商品图下载器同一上限）
    public static let candidateMaxBytes = 256 * 1024
    /// 拍照上传的硬上限（服务器 1 MB，超了 413）
    public static let uploadMaxBytes = 1024 * 1024

    /// `GET /v1/barcode-lookup/:barcode/images`：候选现状（只读库、不调快鸟，供轮询）。码不合法当没有
    public func imageCandidates(_ code: String, token: String) async throws -> ImageCandidates {
        guard Self.isLookupBarcode(code) else { return .empty }
        return try await send("GET", "/v1/barcode-lookup/\(code)/images", body: nil as [String: String]?, token: token, timeoutMs: 5_000)
    }

    /// `GET /v1/barcode-lookup/:barcode/images/:cid`：一张候选缩图（JPEG 字节）。不是 JPEG 或超过上限按坏响应
    public func candidateImage(_ code: String, cid: String, token: String) async throws -> Data {
        guard Self.isLookupBarcode(code), ImageCandidates.isCandidateId(cid) else { throw APIError.badResponse(0) }
        let data = try await sendRaw("GET", "/v1/barcode-lookup/\(code)/images/\(cid)", body: nil, token: token, timeoutMs: 10_000)
        guard data.count <= Self.candidateMaxBytes, ProductImageLoader.looksLikeJPEG(data) else { throw APIError.badResponse(200) }
        return data
    }

    /// `POST /v1/images/:product_id/select`：把一张候选设成商品图，回新的 `image_ver`。幂等（内容相同不升版本），
    /// 所以下发地址连不上时可以退回默认地址重发
    public func selectImage(productId: UUID, barcode: String, candidateId: String, token: String) async throws -> Int {
        guard Self.isLookupBarcode(barcode), ImageCandidates.isCandidateId(candidateId) else { throw APIError.badResponse(0) }
        let r: ImageVerBody = try await send("POST", "/v1/images/\(productId.uuidString.lowercased())/select",
                                             body: ["barcode": barcode, "candidate_id": candidateId], token: token)
        return r.image_ver
    }

    /// `PATCH /v1/devices/me`（§14 S15-2）。返回服务器定下的名字（重名会加序号）
    public func renameDevice(_ label: String, token: String) async throws -> String {
        let r: Label = try await send("PATCH", "/v1/devices/me", body: ["label": label], token: token)
        return r.label
    }

    /// `POST /v1/sync`（S22a）：请求体是 `LocalDB.syncRequestBody` 拼好的原样字节，回 (HTTP 状态, 响应体)。
    /// 非 2xx 不抛，交给 `SyncEngine` 判断（409 epoch、413 等）；30x 照样不跟。同一批 op 重发是幂等的（op id），
    /// 所以下发地址连不上时可以退回默认地址重发。
    public func sync(body: Data, token: String) async throws -> (Int, Data) {
        let primary = bases.current
        do {
            return try await syncOnce(base: primary, body: body, token: token)
        } catch APIError.transport where primary != bases.defaultBase {
            return try await syncOnce(base: bases.defaultBase, body: body, token: token)
        }
    }

    /// `POST /v1/auth/logout`（S22b）：作废这个令牌，回 HTTP 状态（204 成功；401 = 令牌已经不认了）。
    /// 退出登录先把 outbox 传完再调；没传完的推迟到恢复队列传完后用旧令牌调（§4.5）
    public func logout(token: String) async throws -> Int {
        var req = URLRequest(url: APIBase.url(bases.current, path: "/v1/auth/logout"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let resp: URLResponse
        do { (_, resp) = try await session.data(for: req, delegate: NoRedirect.shared) } catch { throw APIError.transport(String(describing: error)) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(0) }
        if (300..<400).contains(http.statusCode) { throw APIError.redirected(http.statusCode) }
        return http.statusCode
    }

    func syncOnce(base: URL, body: Data, token: String) async throws -> (Int, Data) {
        var req = URLRequest(url: APIBase.url(base, path: "/v1/sync"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req, delegate: NoRedirect.shared) } catch { throw APIError.transport(String(describing: error)) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(0) }
        if (300..<400).contains(http.statusCode) { throw APIError.redirected(http.statusCode) }
        return (http.statusCode, data)
    }

    /// `fallback`：下发地址连不上时是否退回默认地址重发一次。一次性的写请求（兑码）传 false。
    /// `timeoutMs`：总时限（整数毫秒，ShopCore 不用浮点类型），退回默认地址那一次只用剩下的时间；剩下不到 1 毫秒就不再发
    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, token: String?,
                                          fallback: Bool = true, timeoutMs: Int = 15_000) async throws -> T {
        let primary = bases.current
        let clock = ContinuousClock()
        let start = clock.now
        do {
            return try await sendOnce(method, base: primary, path, body: body, token: token, timeoutMs: timeoutMs)
        } catch let APIError.transport(why) where fallback && primary != bases.defaultBase {
            let left = timeoutMs - Self.millis(clock.now - start)
            guard left > 0 else { throw APIError.transport(why) }
            return try await sendOnce(method, base: bases.defaultBase, path, body: body, token: token, timeoutMs: left)
        }
    }

    /// 回原始字节的请求（图片）：和 `send` 一样的时限、退回默认地址、不跟重定向；非 2xx 按契约 Error 解析抛出
    func sendRaw(_ method: String, _ path: String, body: Data?, contentType: String? = nil, token: String?,
                 timeoutMs: Int = 15_000) async throws -> Data {
        let primary = bases.current
        let clock = ContinuousClock()
        let start = clock.now
        do {
            return try await sendRawOnce(method, base: primary, path, body: body, contentType: contentType, token: token, timeoutMs: timeoutMs)
        } catch let APIError.transport(why) where primary != bases.defaultBase {
            let left = timeoutMs - Self.millis(clock.now - start)
            guard left > 0 else { throw APIError.transport(why) }
            return try await sendRawOnce(method, base: bases.defaultBase, path, body: body, contentType: contentType, token: token, timeoutMs: left)
        }
    }

    func sendRawOnce(_ method: String, base: URL, _ path: String, body: Data?, contentType: String?, token: String?,
                     timeoutMs: Int) async throws -> Data {
        var req = URLRequest(url: APIBase.url(base, path: path))
        req.timeoutInterval = .init(timeoutMs) / 1000
        req.httpMethod = method
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req, delegate: NoRedirect.shared) } catch { throw APIError.transport(String(describing: error)) }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(0) }
        if (300..<400).contains(http.statusCode) { throw APIError.redirected(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
        return data
    }

    /// Duration → 整数毫秒（向上取整，宁可少给后一次时间）
    static func millis(_ d: Duration) -> Int {
        let (s, atto) = d.components
        return Int(s) * 1000 + Int((atto + 999_999_999_999_999) / 1_000_000_000_000_000)
    }

    func sendOnce<B: Encodable, T: Decodable>(_ method: String, base: URL, _ path: String, body: B?, token: String?,
                                              timeoutMs: Int = 15_000) async throws -> T {
        var req = URLRequest(url: APIBase.url(base, path: path))
        req.timeoutInterval = .init(timeoutMs) / 1000
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
