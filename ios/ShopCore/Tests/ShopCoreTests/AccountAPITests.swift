import Foundation
import Testing
@testable import ShopCore

/// S23b 网络层：改密码、申请 / 撤回注销、让其他手机全部退出、`/v1/me`（契约 openapi.yaml「账号」）。
/// 每个接口都对着本机桩：请求的方法、路径、令牌、请求体逐项核对；服务器回的各种状态码映射成 `AccountFailure`。
@Suite(.serialized) struct AccountAPITests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func client(_ base: String, fallback: String? = nil) -> APIClient {
        let name = "acctapi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = APIBaseStore(defaultBase: fallback ?? base, policy: debug, defaults: d)!
        if fallback != nil { _ = store.adopt(base) }
        return APIClient(bases: store)
    }

    private func failure(_ body: () async throws -> Void) async -> AccountFailure? {
        do { try await body(); return nil } catch { return AccountFailure(error) }
    }

    // MARK: 改密码

    /// 204 = 改好了；请求体正好是 {old, new}，带本机令牌
    @Test func changePasswordSendsOldAndNew() async throws {
        let stub = try LocalStub { _ in .init(status: 204, body: "") }
        defer { stub.stop() }
        try await client(stub.base).changePassword(old: "旧密码123", new: "newpass88", token: "tok")
        let r = try #require(stub.requests.first)
        #expect(r.method == "POST" && r.path == "/v1/account/password")
        #expect(r.headers["authorization"] == "Bearer tok")
        #expect(r.headers["content-type"] == "application/json")
        #expect(try JSONSerialization.jsonObject(with: r.body) as? [String: String] == ["old": "旧密码123", "new": "newpass88"])
    }

    /// 原密码错（401 bad_credentials）、限速（429 带 retry_after_s）、新密码不合（400）、收银员（403）、被退出（401 revoked）、连不上
    @Test func changePasswordFailures() async throws {
        let cases: [(Int, String, AccountFailure)] = [
            (401, #"{"code":"bad_credentials","message":"密码不对"}"#, .wrongPassword),
            (429, #"{"code":"rate_limited","retry_after_s":601,"message":"密码错了太多次，请稍后再试"}"#, .rateLimited(retryAfterS: 601)),
            (400, #"{"code":"invalid"}"#, .invalid),
            (403, #"{"code":"forbidden"}"#, .forbidden),
            (401, #"{"code":"revoked"}"#, .signedOut),
            (401, #"{"code":"unauthorized"}"#, .signedOut),
            (500, "oops", .other),
        ]
        for (status, body, want) in cases {
            let stub = try LocalStub { _ in .init(status: status, body: body) }
            let got = await failure { try await client(stub.base).changePassword(old: "a", new: "abcdefgh", token: "t") }
            stub.stop()
            #expect(got == want, "\(status) \(body)")
        }
        let none = await failure { try await client("http://127.0.0.1:9").changePassword(old: "a", new: "abcdefgh", token: "t") }
        #expect(none == .network)
    }

    /// 限速的等待分钟：向上取整、至少 1 分钟；没给秒数按 15 分钟
    @Test func rateLimitMinutes() {
        #expect(AccountFailure.rateLimited(retryAfterS: 601).waitMinutes == 11)
        #expect(AccountFailure.rateLimited(retryAfterS: 60).waitMinutes == 1)
        #expect(AccountFailure.rateLimited(retryAfterS: 5).waitMinutes == 1)
        #expect(AccountFailure.rateLimited(retryAfterS: nil).waitMinutes == 15)
        #expect(AccountFailure.wrongPassword.waitMinutes == nil)
    }

    /// 改密码不退回默认地址重发（服务器可能已经改了，再发会白占一格限速）
    @Test func accountWritesDoNotFallBack() async throws {
        let fallback = try LocalStub { _ in .init(status: 204, body: "") }
        defer { fallback.stop() }
        let api = client("http://127.0.0.1:9", fallback: fallback.base)
        #expect(await failure { try await api.changePassword(old: "a", new: "abcdefgh", token: "t") } == .network)
        #expect(await failure { _ = try await api.requestAccountDeletion(password: "a", token: "t") } == .network)
        #expect(await failure { try await api.cancelAccountDeletion(token: "t") } == .network)
        #expect(fallback.requests.isEmpty)
    }

    // MARK: 密码长度规则（和服务器 PASSWORD_MIN 8 / PASSWORD_MAX 256 一致，按码点数）

    @Test func passwordRule() {
        #expect(PasswordRule.minLength == 8 && PasswordRule.maxLength == 256)
        #expect(PasswordRule.check(old: "", new: "abcdefgh", again: "abcdefgh") == .oldEmpty)
        #expect(PasswordRule.check(old: "x", new: "abcdefg", again: "abcdefg") == .tooShort)
        #expect(PasswordRule.check(old: "x", new: "abcdefgh", again: "abcdefgi") == .mismatch)
        #expect(PasswordRule.check(old: "x", new: "abcdefgh", again: "abcdefgh") == nil)
        // 8 个汉字 = 8 个码点，够长
        #expect(PasswordRule.check(old: "x", new: "一二三四五六七八", again: "一二三四五六七八") == nil)
        let long = String(repeating: "a", count: 257)
        #expect(PasswordRule.check(old: "x", new: long, again: long) == .tooLong)
        #expect(PasswordRule.check(old: long, new: "abcdefgh", again: "abcdefgh") == .tooLong)
        #expect(PasswordRule.length(PasswordRule.clamp(long)) == 256)
        // 一个带 ZWJ 的表情是 1 个字符、好几个码点：按码点截
        let family = "👨‍👩‍👧"
        #expect(PasswordRule.length(family) == 5)
    }

    // MARK: 注销

    /// 申请注销：请求体 {password}，回 delete_pending_until
    @Test func requestDeletion() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: #"{"delete_pending_until":"2026-12-02T08:00:00.000Z"}"#) }
        defer { stub.stop() }
        let until = try await client(stub.base).requestAccountDeletion(password: "pw", token: "tok")
        #expect(until == "2026-12-02T08:00:00.000Z")
        let r = try #require(stub.requests.first)
        #expect(r.method == "POST" && r.path == "/v1/account/delete-request")
        #expect(r.headers["authorization"] == "Bearer tok")
        #expect(try JSONSerialization.jsonObject(with: r.body) as? [String: String] == ["password": "pw"])
    }

    /// 申请注销的密码错、限速与改密码共用一个计数（同样的码）；回包看不懂按坏响应
    @Test func requestDeletionFailures() async throws {
        for (status, body, want) in [(401, #"{"code":"bad_credentials"}"#, AccountFailure.wrongPassword),
                                     (429, #"{"code":"rate_limited","retry_after_s":120}"#, .rateLimited(retryAfterS: 120)),
                                     (403, #"{"code":"forbidden"}"#, .forbidden),
                                     (200, #"{}"#, .other)] {
            let stub = try LocalStub { _ in .init(status: status, body: body) }
            let got = await failure { _ = try await client(stub.base).requestAccountDeletion(password: "pw", token: "t") }
            stub.stop()
            #expect(got == want, "\(status) \(body)")
        }
    }

    /// 撤回：204 成功；409 not_delete_pending（不在注销中 / 过了 7 天）
    @Test func cancelDeletion() async throws {
        let stub = try LocalStub { _ in .init(status: 204, body: "") }
        try await client(stub.base).cancelAccountDeletion(token: "tok")
        #expect(stub.requests.first?.method == "POST" && stub.requests.first?.path == "/v1/account/delete-cancel")
        #expect(stub.requests.first?.headers["authorization"] == "Bearer tok")
        stub.stop()
        let gone = try LocalStub { _ in .init(status: 409, body: #"{"code":"not_delete_pending","message":"已经超过 7 天，不能撤回"}"#) }
        defer { gone.stop() }
        #expect(await failure { try await client(gone.base).cancelAccountDeletion(token: "t") } == .notDeletePending)
    }

    /// 注销状态：到期之前（含恰好到期那一刻）能撤回；过了就是「正在删除」；没有就是不在注销中
    @Test func deletionState() {
        let until = "2026-12-02T08:00:00.000Z"
        let d = APIClient.date(until)!
        #expect(DeletionState.of(nil, now: d) == .none)
        #expect(DeletionState.of(until, now: d.addingTimeInterval(-60)) == .pending(until: d))
        #expect(DeletionState.of(until, now: d) == .pending(until: d), "恰好第 7 天整仍可撤回")
        #expect(DeletionState.of(until, now: d.addingTimeInterval(1)) == .deleting)
    }

    // MARK: 让其他手机全部退出、/v1/me

    @Test func revokeOthers() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: #"{"revoked":3}"#) }
        defer { stub.stop() }
        let n = try await client(stub.base).revokeOtherDevices(token: "tok")
        #expect(n == 3)
        #expect(stub.requests.first?.method == "POST" && stub.requests.first?.path == "/v1/devices/revoke-others")
        #expect(stub.requests.first?.headers["authorization"] == "Bearer tok")
        let cashier = try LocalStub { _ in .init(status: 403, body: #"{"code":"forbidden"}"#) }
        defer { cashier.stop() }
        #expect(await failure { _ = try await client(cashier.base).revokeOtherDevices(token: "t") } == .forbidden)
    }

    @Test func meWithAndWithoutDeletePending() async throws {
        let stub = try LocalStub { _ in
            .init(status: 200, body: #"{"role":"family","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机","username":"YuanHui","delete_pending_until":"2026-12-02T08:00:00.000Z"}"#)
        }
        defer { stub.stop() }
        let me = try await client(stub.base).me(token: "tok")
        #expect(me.role == .family && me.store.name == "元辉烟酒店" && me.label == "柜台手机")
        #expect(me.username == "YuanHui")
        #expect(me.deletePendingUntil == "2026-12-02T08:00:00.000Z")
        #expect(stub.requests.first?.method == "GET" && stub.requests.first?.path == "/v1/me")
        let plain = try JSONDecoder().decode(AccountMe.self, from: Data(#"{"role":"review","store":{"name":"演示小店","is_demo":true},"label":"x"}"#.utf8))
        #expect(plain.deletePendingUntil == nil && plain.role == .review && plain.username == nil)
    }

    /// 登录 / 兑码响应的 `username`（S23b）：家用会话带，收银员没有
    @Test func sessionGrantUsername() throws {
        let fam = try JSONDecoder().decode(SessionGrant.self, from: Data(#"{"token":"t","epoch":"e","role":"family","store":{"name":"元辉烟酒店"},"label":"柜台","username":"yuanhui"}"#.utf8))
        #expect(fam.username == "yuanhui")
        let cas = try JSONDecoder().decode(SessionGrant.self, from: Data(#"{"token":"t","epoch":"e","role":"cashier","store":{"name":"元辉烟酒店"},"label":"小王"}"#.utf8))
        #expect(cas.username == nil)
    }
}
