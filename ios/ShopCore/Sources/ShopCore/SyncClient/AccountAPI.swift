import Foundation

// S23b 账号与密码、注销的网络层（契约 openapi.yaml「账号」：`/v1/account/password`、`/v1/account/delete-request`、
// `/v1/account/delete-cancel`，加 `/v1/devices/revoke-others`、`GET /v1/me`）。只有家用、审核能调（permissions.json）。
//
// 三个账号写请求都**不退回默认地址重发**：
// - 改密码：服务器已经改了、回包没到时再发一次，原密码已经不对了，会白占一格「原密码输错」的限速（§14 S03-8）；
// - 申请注销：服务器处理完会让全部设备退出（含本机），重发只会拿到 401；
// - 撤回注销：处理过的再发回 409，会被当成「不在注销中」。

/// 密码长度规则，和服务器 `auth/password.ts` 的 `PASSWORD_MIN` / `PASSWORD_MAX` 一致（契约 minLength 8、maxLength 256）。
/// 长度按码点数（服务器 ajv 的 minLength / maxLength 数的是码点）。
public enum PasswordRule {
    public static let minLength = 8
    public static let maxLength = 256

    public static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// 改密码三个框填得对不对（发请求之前在手机上先拦一道；服务器照样会校验）
    public enum Problem: Equatable, Sendable {
        case oldEmpty
        case tooShort
        case tooLong
        /// 两次输的新密码不一样
        case mismatch
    }

    public static func check(old: String, new: String, again: String) -> Problem? {
        if old.isEmpty { return .oldEmpty }
        if length(old) > maxLength { return .tooLong }
        if length(new) < minLength { return .tooShort }
        if length(new) > maxLength { return .tooLong }
        if new != again { return .mismatch }
        return nil
    }

    /// 截到上限（输入框不让输超过服务器上限的密码）
    public static func clamp(_ s: String) -> String {
        guard length(s) > maxLength else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(maxLength)))
    }
}

/// `GET /v1/me`（契约 components/schemas/Me）：角色、店名、设备名、账号名、注销状态
public struct AccountMe: Decodable, Equatable, Sendable {
    public let role: Role
    public let store: SessionGrant.Store
    public let label: String
    /// 账号名：只有家用设备带（扫码开通的家用手机也有）
    public let username: String?
    /// 账号在注销申请中时才有：到这个时刻为止还能撤回（§7 delete-cancel、§14 S03-4）
    public let deletePendingUntil: String?
    enum CodingKeys: String, CodingKey { case role, store, label, username, deletePendingUntil = "delete_pending_until" }
}

/// 注销申请的状态（`delete_pending_until` 解析后）
public enum DeletionState: Equatable, Sendable {
    /// 没有在注销
    case none
    /// 注销申请中，到 `until` 为止都能撤回（恰好第 7 天整仍可撤回，§14 S03-4）
    case pending(until: Date)
    /// 已经过了 7 天、还没真正删掉：显示「正在删除」，不给撤回按钮（§14 S03-4）
    case deleting

    /// `until` 是服务器给的字符串；解析不了按「在注销中、能撤回」处理（让人能点撤回，由服务器判）
    public static func of(_ until: String?, now: Date) -> DeletionState {
        guard let until else { return .none }
        guard let d = APIClient.date(until) else { return .pending(until: now) }
        return now <= d ? .pending(until: d) : .deleting
    }
}

/// 账号接口失败的原因（界面按它出一句话）。由服务器回的状态码 + `code` 映射
public enum AccountFailure: Equatable, Sendable {
    /// 401 `bad_credentials`：原密码 / 再输的密码不对（不计入登录锁定，§14 S03-8）
    case wrongPassword
    /// 429 `rate_limited`：15 分钟内错了 5 次，限速期内正确密码也是 429。带服务器给的秒数
    case rateLimited(retryAfterS: Int?)
    /// 400 `invalid`：新密码长度不合（手机上已先拦，正常到不了这里）
    case invalid
    /// 403：这台手机没有这个权限（收银员）
    case forbidden
    /// 401 `revoked` / `unauthorized`：这台手机已经被退出、或账号已经清除
    case signedOut
    /// 409 `not_delete_pending`：不在注销中，或者已经过了 7 天不能撤回
    case notDeletePending
    /// 没连上服务器
    case network
    case other

    public init(_ error: Error) {
        switch error as? APIError {
        case .server(401, "bad_credentials", _, _): self = .wrongPassword
        case .server(_, "rate_limited", _, let s), .server(429, _, _, let s): self = .rateLimited(retryAfterS: s)
        case .server(400, _, _, _): self = .invalid
        case .server(403, _, _, _): self = .forbidden
        case .server(401, _, _, _): self = .signedOut
        case .server(409, _, _, _): self = .notDeletePending
        case .transport: self = .network
        default: self = .other
        }
    }

    /// 限速还要等几分钟（向上取整，至少 1 分钟；服务器没给秒数按 15 分钟）
    public var waitMinutes: Int? {
        guard case .rateLimited(let s) = self else { return nil }
        guard let s, s > 0 else { return 15 }
        return max(1, (s + 59) / 60)
    }
}

struct DeletePendingBody: Decodable { let delete_pending_until: String }
struct RevokedCount: Decodable { let revoked: Int }

extension APIClient {
    /// `POST /v1/account/password`（204）。不强制其他手机退出（§7）
    public func changePassword(old: String, new: String, token: String) async throws {
        let body = try JSONEncoder().encode(["old": old, "new": new])
        _ = try await sendRaw("POST", "/v1/account/password", body: body, contentType: "application/json", token: token, fallback: false)
    }

    /// `POST /v1/account/delete-request`：回 `delete_pending_until`。服务器同时让这家店的全部设备退出（含本机）
    public func requestAccountDeletion(password: String, token: String) async throws -> String {
        let body = try JSONEncoder().encode(["password": password])
        let data = try await sendRaw("POST", "/v1/account/delete-request", body: body, contentType: "application/json",
                                     token: token, fallback: false)
        do { return try JSONDecoder().decode(DeletePendingBody.self, from: data).delete_pending_until } catch { throw APIError.badResponse(200) }
    }

    /// `POST /v1/account/delete-cancel`（204）。不在注销中或过了 7 天 → 409 `not_delete_pending`
    public func cancelAccountDeletion(token: String) async throws {
        _ = try await sendRaw("POST", "/v1/account/delete-cancel", body: nil, token: token, fallback: false)
    }

    /// `POST /v1/devices/revoke-others`：让其他手机全部退出，回退出了几台。幂等（已退出的不再算），可以退回默认地址重发
    public func revokeOtherDevices(token: String) async throws -> Int {
        let r: RevokedCount = try await send("POST", "/v1/devices/revoke-others", body: nil as [String: String]?, token: token)
        return r.revoked
    }

    /// `GET /v1/me`：角色、店名、设备名、账号名、注销状态
    public func me(token: String) async throws -> AccountMe {
        try await send("GET", "/v1/me", body: nil as [String: String]?, token: token, timeoutMs: 10_000)
    }
}
