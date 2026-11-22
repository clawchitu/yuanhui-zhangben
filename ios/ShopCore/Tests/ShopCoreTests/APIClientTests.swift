import Foundation
import Testing
@testable import ShopCore

/// S21 网络层：重定向不跟（PR #35 Codex 必须修 1）。用本机桩服务器，不连外网。
@Suite(.serialized) struct APIClientTests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func freshDefaults() -> UserDefaults {
        let name = "apiclient-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func client(default base: String, defaults: UserDefaults? = nil) -> APIClient {
        APIClient(bases: APIBaseStore(defaultBase: base, policy: debug, defaults: defaults ?? freshDefaults())!)
    }

    /// 白名单内的 A 回 307 → 目标 B（白名单外）：客户端不跟，B 一个请求都收不到，登录按「被转走」失败
    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectIsNotFollowed(status: Int) async throws {
        let target = try LocalStub { _ in .init(status: 200, body: #"{"token":"t","epoch":"e","role":"family","store":{"name":"x"},"label":"l"}"#) }
        defer { target.stop() }
        // 目标用 localhost 以外的写法，确认它本身过不了白名单
        let evil = "http://127.0.0.2:\(target.port)"
        #expect(APIBase.accept(evil, policy: debug) == nil)
        let redirector = try LocalStub { _ in .init(status: status, headers: ["Location": "http://127.0.0.1:\(target.port)/v1/auth/login"]) }
        defer { redirector.stop() }
        let api = client(default: "http://localhost:\(redirector.port)")

        await #expect(throws: APIError.redirected(status)) {
            _ = try await api.login(username: "yuanhui", password: "secret-pw", deviceId: UUID(), label: nil)
        }
        #expect(redirector.requests.count == 1)
        #expect(String(decoding: redirector.requests[0].body, as: UTF8.self).contains("secret-pw"))  // 第一跳确实带了密码
        try await Task.sleep(for: .milliseconds(300))
        #expect(target.requests.isEmpty, "不应把请求转给 Location 指的地址")
    }

    /// 外面传进来一个没挂 delegate 的普通会话，任务级的 NoRedirect 照样拦住
    @Test func plainSessionStillRefusesRedirect() async throws {
        let target = try LocalStub { _ in .init(status: 200) }
        defer { target.stop() }
        let redirector = try LocalStub { _ in .init(status: 307, headers: ["Location": "\(target.base)/v1/config"]) }
        defer { redirector.stop() }
        let bases = APIBaseStore(defaultBase: "http://localhost:\(redirector.port)", policy: debug, defaults: freshDefaults())!
        let api = APIClient(bases: bases, session: URLSession(configuration: .ephemeral))
        await #expect(throws: APIError.redirected(307)) { _ = try await api.config() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(target.requests.isEmpty)
    }

    /// 对照：不重定向时桩能正常回（证明桩和查法有效）
    @Test func stubWorks() async throws {
        let a = try LocalStub { _ in
            .init(status: 200, body: #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s"}"#)
        }
        defer { a.stop() }
        let c = try await client(default: "http://localhost:\(a.port)").config()
        #expect(c.minBuild == 1)
        #expect(a.requests.map(\.path) == ["/v1/config"])
    }

    // MARK: 退回默认地址（PR #35 Fable 可选 4）

    static let grant = #"{"token":"t","epoch":"e","role":"family","store":{"name":"x"},"label":"l"}"#

    /// 下发地址 A 收下兑码请求后断开（服务器已处理、回包没到）→ 不退回默认地址 B 重发：兑码接口一共只被调一次
    @Test func redeemIsNotResentOnDefault() async throws {
        let a = try LocalStub { _ in .init(status: 200, body: Self.grant, drop: true) }
        defer { a.stop() }
        let b = try LocalStub { _ in .init(status: 200, body: Self.grant) }
        defer { b.stop() }
        let bases = APIBaseStore(defaultBase: "http://localhost:\(b.port)", policy: debug, defaults: freshDefaults())!
        #expect(bases.adopt(a.base) == .adopted(URL(string: a.base)!))
        let api = APIClient(bases: bases)

        await #expect {
            _ = try await api.redeem(code: "abc", deviceId: UUID())
        } throws: { e in
            if case APIError.transport = e { true } else { false }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.count("/v1/auth/pair/redeem") == 1)
        #expect(b.count("/v1/auth/pair/redeem") == 0, "兑码不应退回默认地址重发")
        #expect(a.count("/v1/auth/pair/redeem") + b.count("/v1/auth/pair/redeem") == 1)
    }

    /// 下发地址连不上（端口没人听）时兑码同样只试一次，默认地址收不到
    @Test func redeemDoesNotFallBackWhenAdoptedUnreachable() async throws {
        let dead = try LocalStub { _ in .init(status: 200) }
        let deadBase = dead.base
        dead.stop()
        try await Task.sleep(for: .milliseconds(100))
        let b = try LocalStub { _ in .init(status: 200, body: Self.grant) }
        defer { b.stop() }
        let bases = APIBaseStore(defaultBase: "http://localhost:\(b.port)", policy: debug, defaults: freshDefaults())!
        _ = bases.adopt(deadBase)
        let api = APIClient(bases: bases)
        await #expect(throws: (any Error).self) { _ = try await api.redeem(code: "abc", deviceId: UUID()) }
        #expect(b.requests.isEmpty)
    }

    /// 对照：读请求（config）在下发地址断开时照旧退回默认地址，证明上面的「没退回」不是桩没起来
    @Test func configStillFallsBack() async throws {
        let a = try LocalStub { _ in .init(status: 200, drop: true) }
        defer { a.stop() }
        let b = try LocalStub { _ in
            .init(status: 200, body: #"{"min_build":1,"demo_login_enabled":false,"privacy_url":"p","support_url":"s"}"#)
        }
        defer { b.stop() }
        let bases = APIBaseStore(defaultBase: "http://localhost:\(b.port)", policy: debug, defaults: freshDefaults())!
        _ = bases.adopt(a.base)
        let c = try await APIClient(bases: bases).config()
        #expect(c.minBuild == 1)
        #expect(a.count("/v1/config") >= 1)  // GET 断连时 URLSession 自己会重试几次，数不定
        #expect(b.count("/v1/config") == 1)
    }
}
