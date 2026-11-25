import Foundation
import Testing
@testable import ShopCore

/// S22d 网络层：候选现状、候选缩图、选图（契约 openapi.yaml `/v1/barcode-lookup/{barcode}/images*`、`/v1/images/{id}/select`）
@Suite(.serialized) struct ImageAPITests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func client(_ base: String) -> APIClient {
        let name = "imageapi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return APIClient(bases: APIBaseStore(defaultBase: base, policy: debug, defaults: d)!)
    }

    /// 查码响应里的候选：可选解析；认不出的 state 当 none；不合规的 id 丢掉；收银员没有这个键
    @Test func lookupDecodesCandidates() throws {
        let d = JSONDecoder()
        let a = try d.decode(BarcodeLookupResult.self, from: Data(#"{"found":true,"name":"茶","has_image":true,"image_candidates":{"state":"ready","ids":["0123456789abcdef","ZZ","0123456789abcdef","1111111111111111"]}}"#.utf8))
        #expect(a.imageCandidates == ImageCandidates(state: .ready, ids: ["0123456789abcdef", "1111111111111111"]))
        let b = try d.decode(BarcodeLookupResult.self, from: Data(#"{"found":true,"name":"茶","has_image":false}"#.utf8))
        #expect(b.imageCandidates == nil)
        let c = try d.decode(ImageCandidates.self, from: Data(#"{"state":"weird","ids":[]}"#.utf8))
        #expect(c.state == .none)
        let many = ImageCandidates(state: .ready, ids: (0..<9).map { String(format: "%016x", $0) })
        #expect(many.ids.count == 6, "最多 6 个")
        #expect(!ImageCandidates.isCandidateId("0123456789ABCDEF"), "只认小写")
        #expect(!ImageCandidates.isCandidateId("../../etc/passwd"))
    }

    /// 选图：POST 到 /v1/images/<小写 id>/select，带令牌和 {barcode, candidate_id}，回 image_ver；404 按契约错误抛出
    @Test func selectSendsBodyAndParsesVersion() async throws {
        let stub = try LocalStub { r in r.path.hasSuffix("/select") ? .init(status: 200, body: #"{"image_ver":3}"#) : .init(status: 404, body: #"{"code":"not_found"}"#) }
        defer { stub.stop() }
        let id = UUID()
        let v = try await client(stub.base).selectImage(productId: id, barcode: "6920152400319", candidateId: "0123456789abcdef", token: "tok")
        #expect(v == 3)
        let r = try #require(stub.requests.first)
        #expect(r.method == "POST")
        #expect(r.path == "/v1/images/\(id.uuidString.lowercased())/select")
        let body = try JSONSerialization.jsonObject(with: r.body) as? [String: String]
        #expect(body == ["barcode": "6920152400319", "candidate_id": "0123456789abcdef"])
        let bad = try LocalStub { _ in .init(status: 404, body: #"{"code":"not_found"}"#) }
        defer { bad.stop() }
        await #expect(throws: APIError.server(status: 404, code: "not_found", lockedUntil: nil, retryAfterS: nil)) {
            _ = try await client(bad.base).selectImage(productId: id, barcode: "6920152400319", candidateId: "0123456789abcdef", token: "tok")
        }
    }

    /// 不合规的 cid / 条码：不发请求（不拿服务器给的字符串拼路径）
    @Test func invalidIdsSendNothing() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: "{}") }
        defer { stub.stop() }
        let api = client(stub.base)
        await #expect(throws: APIError.self) { _ = try await api.candidateImage("6920152400319", cid: "../x", token: "t") }
        await #expect(throws: APIError.self) { _ = try await api.selectImage(productId: UUID(), barcode: "a/b", candidateId: "0123456789abcdef", token: "t") }
        #expect(try await api.imageCandidates("a b", token: "t") == .empty)
        #expect(stub.requests.isEmpty)
    }

    /// 候选现状和候选缩图：路径对、缩图要是 JPEG（不是就按坏响应；正常的 JPEG 由 S22dUITests 的桩覆盖）
    @Test func candidatesAndThumbnail() async throws {
        let stub = try LocalStub { r in
            if r.path.hasSuffix("/images") { return .init(status: 200, body: #"{"state":"pending","ids":["0123456789abcdef"]}"#) }
            if r.path.hasSuffix("/1111111111111111") { return .init(status: 200, body: "not a jpeg") }
            return .init(status: 404, body: #"{"code":"not_found"}"#)
        }
        defer { stub.stop() }
        let api = client(stub.base)
        let c = try await api.imageCandidates("6920152400319", token: "t")
        #expect(c == ImageCandidates(state: .pending, ids: ["0123456789abcdef"]))
        await #expect(throws: APIError.badResponse(200)) { _ = try await api.candidateImage("6920152400319", cid: "1111111111111111", token: "t") }
        #expect(stub.requests.map(\.path) == ["/v1/barcode-lookup/6920152400319/images", "/v1/barcode-lookup/6920152400319/images/1111111111111111"])
    }

    /// 拍照上传：PUT /v1/images/<小写 id>，请求体就是 JPEG 字节，回 image_ver；不是 JPEG、超过 1 MB 不发
    @Test func uploadPutsJPEGBytes() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: #"{"image_ver":5}"#) }
        defer { stub.stop() }
        let api = client(stub.base), id = UUID()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        #expect(try await api.uploadImage(productId: id, jpeg: jpeg, token: "t") == 5)
        let r = try #require(stub.requests.first)
        #expect(r.method == "PUT")
        #expect(r.path == "/v1/images/\(id.uuidString.lowercased())")
        #expect(r.body == jpeg)
        #expect(r.headers["content-type"] == "image/jpeg", "服务器按 Content-Type 认图片裸体")
        #expect(r.headers["authorization"] == "Bearer t")
        await #expect(throws: APIError.badResponse(0)) { _ = try await api.uploadImage(productId: id, jpeg: Data("png".utf8), token: "t") }
        await #expect(throws: APIError.badResponse(0)) {
            _ = try await api.uploadImage(productId: id, jpeg: Data([0xFF, 0xD8]) + Data(count: APIClient.uploadMaxBytes), token: "t")
        }
        #expect(stub.requests.count == 1)
    }
}
