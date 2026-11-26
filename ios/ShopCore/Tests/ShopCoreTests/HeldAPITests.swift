import Foundation
import GRDB
import Testing
@testable import ShopCore

/// S23a：待确认的账（契约 openapi.yaml `/v1/held-ops*`）
@Suite(.serialized) struct HeldAPITests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func client(_ base: String) -> APIClient {
        let name = "heldapi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return APIClient(bases: APIBaseStore(defaultBase: base, policy: debug, defaults: d)!)
    }

    static func heldJSON(id: UUID, productId: UUID, canAccept: Bool = true, role: String? = "cashier") -> String {
        let r = role.map { #","device_role":"\#($0)""# } ?? ""
        return #"{"held":[{"id":"\#(id.uuidString.lowercased())","device_id":"66666666-7777-4888-8999-aaaaaaaaaaaa","device_label":"小王"\#(r),"type":"stock_in","occurred_at":"2026-11-25T11:32:00.000Z","payload":{"entry_id":"aaaaaaaa-0000-4000-8000-000000000001","product_id":"\#(productId.uuidString.lowercased())","barcode":"6901035600016","pack_qty":1,"pack_count":3,"unit_cost_fen":1200,"note":{"x":[1,true,null,"s"]}},"can_accept":\#(canAccept)}]}"#
    }

    /// 列表：payload 原样留着（嵌套、布尔、null 都不丢）；老服务器没有 device_role 也能解
    @Test func listDecodes() async throws {
        let id = UUID(), pid = UUID()
        let stub = try LocalStub { _ in .init(status: 200, body: Self.heldJSON(id: id, productId: pid, canAccept: false, role: nil)) }
        defer { stub.stop() }
        let list = try await client(stub.base).heldOps(token: "t")
        let h = try #require(list.first)
        #expect(h.id == id && h.deviceLabel == "小王" && h.deviceRole == nil && !h.canAccept && h.type == "stock_in")
        let p = try JSONSerialization.jsonObject(with: h.payloadJSON) as? [String: Any]
        #expect(p?["pack_count"] as? Int == 3)
        #expect(((p?["note"] as? [String: Any])?["x"] as? [Any])?.count == 4)
        #expect(stub.requests.first?.path == "/v1/held-ops")
    }

    /// 记上 / 不要：发 {action}；409 stale、403 forbidden（记上时）= 只能不要；404 = 已经处理过了；记上回 rejected = 已了结
    @Test func resolveOutcomes() async throws {
        let id = UUID()
        let replies: [(Int, String)] = [(200, #"{"id":"x","status":"applied"}"#), (200, #"{"id":"x","status":"rejected","code":"discarded"}"#),
                                        (409, #"{"code":"stale"}"#), (403, #"{"code":"forbidden"}"#), (404, #"{"code":"not_found"}"#),
                                        (200, #"{"id":"x","status":"rejected","code":"invalid"}"#)]
        let n = LockedCounter()
        let stub = try LocalStub { _ in let r = replies[n.next()]; return .init(status: r.0, body: r.1) }
        defer { stub.stop() }
        let api = client(stub.base)
        #expect(try await api.resolveHeld(id: id, accept: true, token: "t") == .accepted)
        #expect(try await api.resolveHeld(id: id, accept: false, token: "t") == .discarded)
        #expect(try await api.resolveHeld(id: id, accept: true, token: "t") == .onlyDiscard)
        #expect(try await api.resolveHeld(id: id, accept: true, token: "t") == .onlyDiscard)
        #expect(try await api.resolveHeld(id: id, accept: true, token: "t") == .gone)
        // 记上后服务器跑了没收（invalid 等）：已经了结，不是「只能不要」
        #expect(try await api.resolveHeld(id: id, accept: true, token: "t") == .rejected("invalid"))
        let bodies = stub.requests.map { try? JSONSerialization.jsonObject(with: $0.body) as? [String: String] }
        #expect(bodies.map { $0?["action"] } == ["accept", "discard", "accept", "accept", "accept", "accept"])
        #expect(stub.requests.first?.path == "/v1/held-ops/\(id.uuidString.lowercased())/resolve")
    }

    /// 描述一笔：和「待传」面板同样的一行（进货：商品名查本机、3 件、¥36.00）
    @Test func entryDescribesLikePendingPanel() throws {
        let db = try LocalDB(writer: try DatabaseQueue(configuration: LocalDB.configuration()), faultHook: nil)
        try db.beginSession(try LocalSession(deviceId: uuid(0x5A1), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        let conv = try #require(try db.lookup(barcode: "6901035600016"))
        let h = try JSONDecoder().decode(HeldList.self, from: Data(Self.heldJSON(id: UUID(), productId: conv.product.id).utf8)).held[0]
        let e = try #require(try db.heldEntry(h))
        #expect(e.kindText == "进货")
        #expect(e.names == [conv.product.name])
        #expect(e.quantity == 3)
        #expect(e.amountFen == 3600)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
