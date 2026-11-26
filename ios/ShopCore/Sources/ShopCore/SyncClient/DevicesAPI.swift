import Foundation

// S23a 开通与设备管理的网络层（契约 openapi.yaml「设备与开通」：`/v1/pairing-tokens*`、`/v1/devices*`、`/v1/held-ops*`）。
// 时间一律保留服务器给的字符串（ShopCore 不碰浮点），App 用 `APIClient.date(_:)` 解析。

/// `POST /v1/pairing-tokens` 的响应：二维码内容是 `YHZB1:<code>`
public struct PairingToken: Decodable, Equatable, Sendable {
    public let id: UUID
    public let code: String
    public let expiresAt: String
    enum CodingKeys: String, CodingKey { case id, code, expiresAt = "expires_at" }

    /// 二维码里放的字符串（扫码登录那边 `PairingCode.parse` 认它）
    public var qrPayload: String { "YHZB1:\(code)" }
}

/// `GET /v1/pairing-tokens/:id`：等人扫 / 已经用了（谁用的）/ 过期了
public struct PairingStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case waiting, used, expired }
    public let status: State
    public let usedByLabel: String?
    enum CodingKeys: String, CodingKey { case status, usedByLabel = "used_by_label" }
    public init(status: State, usedByLabel: String? = nil) {
        self.status = status
        self.usedByLabel = usedByLabel
    }
}

/// `GET /v1/devices` 的一行：没退出的手机，和退出了但还有待确认的账的手机
public struct DeviceInfo: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let role: Role
    public let createdAt: String
    public let lastSeenAt: String?
    public let isMe: Bool
    public let revoked: Bool
    public let heldCount: Int
    enum CodingKeys: String, CodingKey {
        case id, label, role, revoked
        case createdAt = "created_at", lastSeenAt = "last_seen_at", isMe = "is_me", heldCount = "held_count"
    }
    public init(id: UUID, label: String, role: Role, createdAt: String, lastSeenAt: String?, isMe: Bool, revoked: Bool, heldCount: Int) {
        self.id = id; self.label = label; self.role = role; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt
        self.isMe = isMe; self.revoked = revoked; self.heldCount = heldCount
    }
}

struct DeviceList: Decodable { let devices: [DeviceInfo] }

extension APIClient {
    /// 契约里的时间字符串 → Date（解析不了为 nil）
    public static func date(_ s: String) -> Date? { parseDate(s) }

    /// 出码（只有家用 / 审核能出，收银员码必须带称呼）。不是幂等的写请求：下发地址连不上不退回默认地址重发
    public func createPairingToken(role: Role, label: String?, token: String) async throws -> PairingToken {
        var body = ["role": role.rawValue]
        if let label { body["label"] = label }
        return try await send("POST", "/v1/pairing-tokens", body: body, token: token, fallback: false)
    }

    /// 轮询一张码的状态
    public func pairingStatus(id: UUID, token: String) async throws -> PairingStatus {
        try await send("GET", "/v1/pairing-tokens/\(id.uuidString.lowercased())", body: nil as [String: String]?, token: token, timeoutMs: 10_000)
    }

    /// 已登录的手机（和退出了但还有待确认的账的）
    public func devices(token: String) async throws -> [DeviceInfo] {
        let r: DeviceList = try await send("GET", "/v1/devices", body: nil as [String: String]?, token: token)
        return r.devices
    }

    /// 让一台手机退出（幂等：已经退出的再退一次也是 204）。不能让自己退出（服务器回 400 cannot_revoke_self）
    public func revokeDevice(id: UUID, token: String) async throws {
        _ = try await sendRaw("POST", "/v1/devices/\(id.uuidString.lowercased())/revoke", body: nil, token: token)
    }
}
