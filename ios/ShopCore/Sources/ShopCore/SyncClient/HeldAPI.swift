import Foundation

// S23a：被退出的手机补传上来、等家里人确认的账（契约 openapi.yaml `/v1/held-ops*`，§4.5）。只有家用能看、能处理。

/// `GET /v1/held-ops` 的一笔。`payload` 原样留着（JSON 字节），描述这笔账时和「待传」面板走同一套解析
public struct HeldOp: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceId: UUID
    public let deviceLabel: String
    /// 补传它的手机被退出前的角色（T37）；老服务器没有这个字段
    public let deviceRole: Role?
    public let type: String
    public let occurredAt: String
    /// false：账面已经变了（盘点、期初等），或原来的角色本来做不了这种操作，只能「不要」
    public let canAccept: Bool
    public let payloadJSON: Data

    enum CodingKeys: String, CodingKey {
        case id, type, payload
        case deviceId = "device_id", deviceLabel = "device_label", deviceRole = "device_role"
        case occurredAt = "occurred_at", canAccept = "can_accept"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        deviceId = try c.decode(UUID.self, forKey: .deviceId)
        deviceLabel = try c.decode(String.self, forKey: .deviceLabel)
        deviceRole = try c.decodeIfPresent(Role.self, forKey: .deviceRole)
        type = try c.decode(String.self, forKey: .type)
        occurredAt = try c.decode(String.self, forKey: .occurredAt)
        canAccept = try c.decode(Bool.self, forKey: .canAccept)
        payloadJSON = try JSONEncoder().encode(try c.decode(RawJSON.self, forKey: .payload))
    }

    public init(id: UUID, deviceId: UUID, deviceLabel: String, deviceRole: Role?, type: String, occurredAt: String, canAccept: Bool, payloadJSON: Data) {
        self.id = id; self.deviceId = deviceId; self.deviceLabel = deviceLabel; self.deviceRole = deviceRole
        self.type = type; self.occurredAt = occurredAt; self.canAccept = canAccept; self.payloadJSON = payloadJSON
    }
}

/// 只为原样转存 payload：op 的内容只有整数、字符串、布尔（金额都是整数分），别的数字当成空
enum RawJSON: Codable, Equatable {  // 解码用；编码 op 用 Ops/JSONValue
    case string(String), int(Int64), bool(Bool), null, array([RawJSON]), object([String: RawJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([RawJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: RawJSON].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct HeldList: Decodable { let held: [HeldOp] }

/// 「记上 / 不要」的结果
public enum HeldResolution: Equatable, Sendable {
    case accepted, discarded
    /// 账面已经变了（409 stale）或原角色做不了（403 forbidden）：只能不要
    case onlyDiscard
    /// 已经被别的手机处理过了（404）
    case gone
}

extension APIClient {
    public func heldOps(token: String) async throws -> [HeldOp] {
        let r: HeldList = try await send("GET", "/v1/held-ops", body: nil as [String: String]?, token: token)
        return r.held
    }

    /// 记上 / 不要。服务器在店铺锁里处理、处理过的再处理回 404，所以下发地址连不上时可以退回默认地址重发
    public func resolveHeld(id: UUID, accept: Bool, token: String) async throws -> HeldResolution {
        struct Result: Decodable { let status: String }
        do {
            let r: Result = try await send("POST", "/v1/held-ops/\(id.uuidString.lowercased())/resolve",
                                           body: ["action": accept ? "accept" : "discard"], token: token)
            if !accept { return .discarded }
            return r.status == "applied" ? .accepted : .onlyDiscard
        } catch APIError.server(409, "stale", _, _) {
            return .onlyDiscard
        } catch APIError.server(403, "forbidden", _, _) where accept {
            return .onlyDiscard
        } catch APIError.server(404, _, _, _) {
            return .gone
        }
    }
}

extension LocalDB {
    /// 待确认的一笔 → 和「待传」面板同样的一行（商品名查本机商品表）
    public func heldEntry(_ h: HeldOp) throws -> PendingEntry? {
        guard let type = OpType(rawValue: h.type), let at = APIClient.date(h.occurredAt) else { return nil }
        var data = Data(#"{"payload":"#.utf8)
        data.append(h.payloadJSON)
        data.append(Data("}".utf8))
        return try writer.read { db in try Self.describe(db, seq: 0, type: type, data: data, at: at) }
    }
}
