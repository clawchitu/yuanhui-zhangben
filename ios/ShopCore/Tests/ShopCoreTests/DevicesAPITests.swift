import Foundation
import Testing
@testable import ShopCore

/// S23a 网络层：出码、轮询、已登录的手机、让它退出（契约 openapi.yaml「设备与开通」）
@Suite(.serialized) struct DevicesAPITests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func client(_ base: String, fallback: String? = nil) -> APIClient {
        let name = "devapi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = APIBaseStore(defaultBase: fallback ?? base, policy: debug, defaults: d)!
        if fallback != nil { _ = store.adopt(base) }
        return APIClient(bases: store)
    }

    /// 出码：带令牌和 {role, label}；回的码拼成 `YHZB1:<code>`，扫码登录那边认得
    @Test func createPairingToken() async throws {
        let id = UUID()
        let stub = try LocalStub { _ in .init(status: 201, body: #"{"id":"\#(id.uuidString.lowercased())","code":"abc_DEF-123","expires_at":"2026-11-26T08:02:00.000Z"}"#) }
        defer { stub.stop() }
        let t = try await client(stub.base).createPairingToken(role: .cashier, label: "小李", token: "tok")
        #expect(t.id == id)
        #expect(t.qrPayload == "YHZB1:abc_DEF-123")
        #expect(PairingCode.parse(t.qrPayload) == "abc_DEF-123")
        #expect(APIClient.date(t.expiresAt) == Date(timeIntervalSince1970: 1_795_680_120))
        let r = try #require(stub.requests.first)
        #expect(r.method == "POST" && r.path == "/v1/pairing-tokens")
        #expect(r.headers["authorization"] == "Bearer tok")
        #expect(try JSONSerialization.jsonObject(with: r.body) as? [String: String] == ["role": "cashier", "label": "小李"])
    }

    /// 出码不是幂等的：下发地址连不上不退回默认地址再出一张
    @Test func createPairingTokenDoesNotFallBack() async throws {
        let fallback = try LocalStub { _ in .init(status: 201, body: "{}") }
        defer { fallback.stop() }
        let api = client("http://127.0.0.1:9", fallback: fallback.base)
        await #expect(throws: APIError.self) { _ = try await api.createPairingToken(role: .family, label: nil, token: "t") }
        #expect(fallback.requests.isEmpty)
    }

    /// 轮询三种状态；used 带用的人的称呼
    @Test func pairingStatus() async throws {
        let id = UUID()
        let stub = try LocalStub { _ in .init(status: 200, body: #"{"status":"used","used_by_label":"小李"}"#) }
        defer { stub.stop() }
        let s = try await client(stub.base).pairingStatus(id: id, token: "t")
        #expect(s == PairingStatus(status: .used, usedByLabel: "小李"))
        #expect(stub.requests.first?.path == "/v1/pairing-tokens/\(id.uuidString.lowercased())")
        let w = try JSONDecoder().decode(PairingStatus.self, from: Data(#"{"status":"expired"}"#.utf8))
        #expect(w == PairingStatus(status: .expired))
    }

    /// 已登录的手机；让它退出回 204（没有响应体）也算成功；不能退自己 → 400 cannot_revoke_self
    @Test func devicesAndRevoke() async throws {
        let me = UUID(), other = UUID()
        let stub = try LocalStub { r in
            if r.method == "GET" {
                return .init(status: 200, body: #"{"devices":[{"id":"\#(me.uuidString.lowercased())","label":"柜台手机","role":"family","created_at":"2026-11-25T01:00:00.000Z","last_seen_at":null,"is_me":true,"revoked":false,"held_count":0},{"id":"\#(other.uuidString.lowercased())","label":"小王","role":"cashier","created_at":"2026-11-25T01:00:00.000Z","last_seen_at":"2026-11-25T11:32:00.000Z","is_me":false,"revoked":true,"held_count":2}]}"#)
            }
            return r.path.contains(me.uuidString.lowercased()) ? .init(status: 400, body: #"{"code":"cannot_revoke_self"}"#) : .init(status: 204, body: "")
        }
        defer { stub.stop() }
        let api = client(stub.base)
        let list = try await api.devices(token: "t")
        #expect(list.map(\.label) == ["柜台手机", "小王"])
        #expect(list[0].isMe && list[0].lastSeenAt == nil)
        #expect(list[1].role == .cashier && list[1].revoked && list[1].heldCount == 2)
        try await api.revokeDevice(id: other, token: "t")
        #expect(stub.requests.last?.path == "/v1/devices/\(other.uuidString.lowercased())/revoke")
        #expect(stub.requests.last?.method == "POST")
        await #expect(throws: APIError.server(status: 400, code: "cannot_revoke_self", lockedUntil: nil, retryAfterS: nil)) {
            try await api.revokeDevice(id: me, token: "t")
        }
    }
}
