import ShopCore
import SwiftUI
import XCTest
@testable import YuanhuiZhangben

/// S23b-1 账号与密码（plan-v2 §8 S23b）的 App 层：改密码的校验和错误码、让其他手机全部退出、账号名、收银员没有入口。
@MainActor
final class S23bTests: XCTestCase {
    let defaults = UserDefaults(suiteName: "S23bTests")!
    override func setUp() { defaults.removePersistentDomain(forName: "S23bTests") }

    /// 假账号接口：按调用记下，按设定回
    final class FakeAccount: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        var passwordError: Error?
        var meUntil: String?
        var meUsername: String? = "yuanhui"
        var revoked = 2
        func log(_ s: String) { lock.withLock { calls.append(s) } }
        var backend: AccountBackend {
            AccountBackend(
                changePassword: { old, new in self.log("password \(old)->\(new)"); if let e = self.lock.withLock({ self.passwordError }) { throw e } },
                revokeOthers: { self.log("revokeOthers"); return self.lock.withLock { self.revoked } },
                me: {
                    self.log("me")
                    let (until, name) = self.lock.withLock { (self.meUntil, self.meUsername) }
                    let json = #"{"role":"family","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机""#
                        + (name.map { #","username":"\#($0)""# } ?? "")
                        + (until.map { #","delete_pending_until":"\#($0)""# } ?? "") + "}"
                    return try JSONDecoder().decode(AccountMe.self, from: Data(json.utf8))
                })
        }
    }


    // MARK: 改密码

    /// 手机上先按服务器的长度规则拦（8–256 位）、两次要一样；拦下的不发请求
    func testPasswordValidatedLocallyBeforeSending() async {
        let fake = FakeAccount()
        let m = AccountModel(backend: fake.backend)
        m.oldPassword = "old"; m.newPassword = "short"; m.newAgain = "short"
        await m.changePassword()
        XCTAssertEqual(m.passwordMessage, "新密码太短了，至少 8 位")
        m.newPassword = "abcdefgh"; m.newAgain = "abcdefgX"
        await m.changePassword()
        XCTAssertEqual(m.passwordMessage, "两次输的新密码不一样，再输一次")
        XCTAssertTrue(fake.calls.isEmpty, "没过规则的不发")
        m.newPassword = String(repeating: "a", count: 300)
        XCTAssertEqual(PasswordRule.length(m.newPassword), 256, "输入框截到服务器上限")
    }

    /// 改好了：三个框清空，说「别的手机不用重新登录」（服务器不强制其他手机退出，§7）
    func testPasswordChanged() async {
        let fake = FakeAccount()
        let m = AccountModel(backend: fake.backend)
        m.oldPassword = "oldpass"; m.newPassword = "newpass88"; m.newAgain = "newpass88"
        await m.changePassword()
        XCTAssertEqual(fake.calls, ["password oldpass->newpass88"])
        XCTAssertTrue(m.passwordChanged)
        XCTAssertEqual(m.passwordMessage, "密码改好了。别的手机不用重新登录，下次登录用新密码")
        XCTAssertEqual([m.oldPassword, m.newPassword, m.newAgain], ["", "", ""])
    }

    /// 服务器回的码 → 一句话：原密码错（清掉原密码框）、限速（几分钟后再试）、被退出、没网
    func testPasswordServerErrors() async {
        let cases: [(Error, String)] = [
            (APIError.server(status: 401, code: "bad_credentials", lockedUntil: nil, retryAfterS: nil), "密码不对，再输一次"),
            (APIError.server(status: 429, code: "rate_limited", lockedUntil: nil, retryAfterS: 601), "密码错了太多次，11 分钟以后再试"),
            (APIError.server(status: 401, code: "revoked", lockedUntil: nil, retryAfterS: nil), "这台手机已经退出登录了，重新登录后再改密码"),
            (APIError.transport("x"), "没连上服务器，联网后再试"),
        ]
        for (err, text) in cases {
            let fake = FakeAccount(); fake.passwordError = err
            let m = AccountModel(backend: fake.backend)
            m.oldPassword = "oldpass"; m.newPassword = "newpass88"; m.newAgain = "newpass88"
            await m.changePassword()
            XCTAssertEqual(m.passwordMessage, text)
            XCTAssertFalse(m.passwordChanged)
            if case .server(401, "bad_credentials", _, _)? = err as? APIError {
                XCTAssertEqual(m.oldPassword, "", "原密码错：清掉原密码框")
                XCTAssertEqual(m.newPassword, "newpass88", "新密码不用重输")
            }
        }
    }

    /// 让其他手机全部退出：确认后才发，说退了几台
    func testRevokeOthers() async {
        let fake = FakeAccount()
        let m = AccountModel(backend: fake.backend)
        m.askRevokeOthers = .init()
        await m.revokeOthersConfirmed()
        XCTAssertEqual(fake.calls, ["revokeOthers"])
        XCTAssertNil(m.askRevokeOthers, "面板关上")
        XCTAssertEqual(m.revokeDone, "已经让 2 台手机退出了")
    }

    /// 账号名（S23b-1）：登录 / 兑码响应带 `username` 就记下（只认这个会话的设备 id）；收银员的响应不带，不记
    func testGrantUsernameRemembered() async throws {
        let db = try LocalDB.inMemory()
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn",
                                               policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn"]), defaults: defaults))
        let services = AppServices(api: APIClient(bases: bases), tokens: MemoryTokenStore(), defaults: defaults, build: 1)
        func grant(_ extra: String, role: String = "family") throws -> SessionGrant {
            try JSONDecoder().decode(SessionGrant.self, from: Data(#"""
                {"token":"t","role":"\#(role)","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机","epoch":"\#(UUID().uuidString)"\#(extra)}
                """#.utf8))
        }
        let id = UUID()
        _ = try await services.establish(try grant(#","username":"YuanHui""#), deviceId: id, db: db)
        XCTAssertEqual(services.username(deviceId: id), "YuanHui")
        let cashier = UUID()
        _ = try await services.establish(try grant("", role: "cashier"), deviceId: cashier, db: db)
        XCTAssertNil(services.username(deviceId: cashier))
    }

    /// 本机没记着账号名：进「账号与密码」问 `/v1/me`，拿到就交给 App 记下；没给（旧服务器）不动
    func testRefreshPassesUsername() async {
        let fake = FakeAccount()
        let m = AccountModel(backend: fake.backend)
        var got: [String] = []
        m.onUsername = { got.append($0) }
        await m.refresh()
        XCTAssertEqual(got, ["yuanhui"])
        fake.meUsername = nil
        await m.refresh()
        XCTAssertEqual(got, ["yuanhui"])
    }

    /// 入口按权限表：家用、审核有「账号与密码」；收银员、被踢设备没有（硬塞路由也是「用不了」）
    func testAccountRoutesFollowPermissions() {
        for role in [Role.family, .review] {
            let caps = Capabilities(role: role)
            XCTAssertEqual(RouteView.content(for: .account, capabilities: caps), .account, "\(role)")
            XCTAssertTrue(caps.has(.manageDevices), "\(role) 有「让其他手机全部退出」")
        }
        for role in [Role.cashier, .revoked] {
            let caps = Capabilities(role: role)
            XCTAssertEqual(RouteView.content(for: .account, capabilities: caps), .denied, "\(role)")
        }
        XCTAssertNil(Route.account.plannedIn)
    }
}
