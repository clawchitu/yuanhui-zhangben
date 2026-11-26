import ShopCore
import SwiftUI
import XCTest
@testable import YuanhuiZhangben

/// S23b 账号与密码、注销（plan-v2 §8 S23b）的 App 层：改密码的校验和错误码、撤回注销、申请注销先排空再结束会话、
/// 注销申请期间的提示和停推、登录带回 `delete_pending_until`、23 页的按钮样式和期限文字、收银员没有入口。
@MainActor
final class S23bTests: XCTestCase {
    let defaults = UserDefaults(suiteName: "S23bTests")!
    override func setUp() { defaults.removePersistentDomain(forName: "S23bTests") }

    /// 假账号接口：按调用记下，按设定回
    final class FakeAccount: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        var passwordError: Error?
        var cancelError: Error?
        var meUntil: String?
        var revoked = 2
        func log(_ s: String) { lock.withLock { calls.append(s) } }
        var backend: AccountBackend {
            AccountBackend(
                changePassword: { old, new in self.log("password \(old)->\(new)"); if let e = self.lock.withLock({ self.passwordError }) { throw e } },
                revokeOthers: { self.log("revokeOthers"); return self.lock.withLock { self.revoked } },
                cancelDeletion: { self.log("cancel"); if let e = self.lock.withLock({ self.cancelError }) { throw e } },
                me: {
                    self.log("me")
                    let until = self.lock.withLock { self.meUntil }
                    let json = #"{"role":"family","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机""#
                        + (until.map { #","delete_pending_until":"\#($0)""# } ?? "") + "}"
                    return try JSONDecoder().decode(AccountMe.self, from: Data(json.utf8))
                })
        }
    }

    private let now = Date(timeIntervalSince1970: 1_795_088_880)   // 2026-11-19 19:48 上海

    // MARK: 改密码

    /// 手机上先按服务器的长度规则拦（8–256 位）、两次要一样；拦下的不发请求
    func testPasswordValidatedLocallyBeforeSending() async {
        let fake = FakeAccount()
        let m = AccountModel(backend: fake.backend, deletePendingUntil: nil, now: { self.now })
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
        let m = AccountModel(backend: fake.backend, deletePendingUntil: nil, now: { self.now })
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
            let m = AccountModel(backend: fake.backend, deletePendingUntil: nil, now: { self.now })
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
        let m = AccountModel(backend: fake.backend, deletePendingUntil: nil, now: { self.now })
        m.askRevokeOthers = .init()
        await m.revokeOthersConfirmed()
        XCTAssertEqual(fake.calls, ["revokeOthers"])
        XCTAssertNil(m.askRevokeOthers, "面板关上")
        XCTAssertEqual(m.revokeDone, "已经让 2 台手机退出了")
    }

    // MARK: 撤回注销

    /// 注销申请中能撤回；撤回成功本机清掉注销状态（同步恢复推送）
    func testCancelDeletion() async {
        let fake = FakeAccount()
        let until = "2026-11-26T11:48:00.000Z"
        let m = AccountModel(backend: fake.backend, deletePendingUntil: until, now: { self.now })
        var changed: [String?] = []
        m.onDeletionChanged = { changed.append($0) }
        guard case .pending = m.deletion else { return XCTFail("应在注销中") }
        await m.cancelDeletion()
        XCTAssertEqual(fake.calls, ["cancel"])
        XCTAssertEqual(m.deletion, .none)
        XCTAssertEqual(changed, [nil])
        XCTAssertEqual(m.cancelMessage, "已经撤回，账号照常用。没传上去的账会自动补传")
    }

    /// 过了 7 天：「正在删除」，不给撤回（点了也不发）；409 时以 /v1/me 为准
    func testCancelAfterGraceAndConflict() async {
        let fake = FakeAccount()
        let past = "2026-11-19T11:00:00.000Z"   // 早于 now
        let m = AccountModel(backend: fake.backend, deletePendingUntil: past, now: { self.now })
        XCTAssertEqual(m.deletion, .deleting)
        await m.cancelDeletion()
        XCTAssertTrue(fake.calls.isEmpty)

        let f2 = FakeAccount()
        f2.cancelError = APIError.server(status: 409, code: "not_delete_pending", lockedUntil: nil, retryAfterS: nil)
        f2.meUntil = nil   // 别的手机已经撤回了
        let m2 = AccountModel(backend: f2.backend, deletePendingUntil: "2026-11-26T11:48:00.000Z", now: { self.now })
        await m2.cancelDeletion()
        XCTAssertEqual(f2.calls, ["cancel", "me"])
        XCTAssertEqual(m2.deletion, .none)
        XCTAssertEqual(m2.cancelMessage, "已经撤回了，账号照常用")
    }

    // MARK: 申请注销（先排空，再结束会话）

    func store(_ role: Role = .family) throws -> (LocalDB, LocalSession) {
        let db = try LocalDB.inMemory()
        let s = try LocalSession(deviceId: UUID(), storeId: UUID(), role: role, tokenRef: "tNow", storeName: "元辉烟酒店", deviceLabel: "柜台手机")
        try db.beginSession(s)
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        return (db, s)
    }

    func sell(_ db: LocalDB) throws {
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b, at: Date())
    }

    func coordinator(_ db: LocalDB, _ server: S22bTests.Server) -> SyncCoordinator {
        SyncCoordinator(db: db, build: 1) { try server.sync(token: "token-now", body: $0) }
    }

    /// 确认注销：先把待传的 2 笔传上去（申请之后服务器一笔都不收），再发申请；成功后本机会话结束、回登录页（不是 25b）
    func testDeletionDrainsFirstThenEndsSession() async throws {
        let (db, s) = try store()
        try sell(db); try sell(db)
        let server = S22bTests.Server()
        let m = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server)
        var pushedBeforeRequest = -1
        let out = await m.requestAccountDeletion {
            pushedBeforeRequest = server.lock.withLock { server.log.map(\.ops).reduce(0, +) }
            return "2026-11-26T11:48:00.000Z"
        }
        XCTAssertEqual(out, .done(until: "2026-11-26T11:48:00.000Z"))
        XCTAssertEqual(pushedBeforeRequest, 2, "申请之前先排空")
        XCTAssertNil(try db.currentSession(), "本机会话结束")
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
        XCTAssertNil(try db.signOutReason(), "不是被踢：回登录页")
        guard case .other = AppRootBootKind(AppRoot.afterSignOut(db: db, services: nil)) else { return XCTFail("应回登录页") }
        XCTAssertEqual(try db.retiredSession(deviceId: s.deviceId)?.revoked, true, "令牌服务器已作废，恢复队列不再调 logout")
    }

    /// 没网排空不了、申请也没发成：会话不动、同步接着跑，账一笔不少
    func testDeletionFailureKeepsSession() async throws {
        let (db, s) = try store()
        try sell(db)
        let server = S22bTests.Server(); server.offline = true
        let m = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server)
        let out = await m.requestAccountDeletion { throw APIError.transport("offline") }
        XCTAssertEqual(out, .failed(.network))
        XCTAssertNotNil(try db.currentSession())
        XCTAssertEqual(try db.pendingCount(deviceId: s.deviceId, storeId: s.storeId), 1)
        XCTAssertNotNil(m.sync?.onSignedOut, "同步恢复，被踢照常通知")
        m.sync?.stop()
    }

    /// 排空时发现已经被踢：不发申请，按被踢走（25b）
    func testDeletionDrainFindsKicked() async throws {
        let (db, s) = try store()
        try sell(db)
        let server = S22bTests.Server(); server.revoked = true
        let m = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server)
        var sent = false
        let out = await m.requestAccountDeletion { sent = true; return "x" }
        XCTAssertEqual(out, .kicked)
        XCTAssertFalse(sent)
        XCTAssertEqual(try db.signOutReason(), .kickedFamily)
    }

    /// 申请成功时还有没传上去的（排空那一趟被服务器说「注销中」挡住）：留在恢复队列，撤回后用旧令牌补传，一笔不丢
    func testDeletionKeepsUnsentOpsForAfterCancel() async throws {
        let (db, s) = try store()
        try sell(db)
        let server = S22bTests.Server(); server.deletePending = true
        let m = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server)
        let out = await m.requestAccountDeletion { "2026-11-26T11:48:00.000Z" }
        XCTAssertEqual(out, .done(until: "2026-11-26T11:48:00.000Z"))
        XCTAssertEqual(try db.recoveryPendingCount(), 1, "留着，不丢")
    }

    // MARK: 注销申请期间

    /// 登录响应带 delete_pending_until：开会话时就记下（首页马上提示；第一趟同步就不推）
    func testLoginGrantDeletePendingStored() async throws {
        let db = try LocalDB.inMemory()
        let bases = try XCTUnwrap(APIBaseStore(defaultBase: "https://api.yuanhuishop.cn",
                                               policy: APIBasePolicy(hosts: ["api.yuanhuishop.cn"]), defaults: defaults))
        let services = AppServices(api: APIClient(bases: bases), tokens: MemoryTokenStore(), defaults: defaults, build: 1)
        let grant = try JSONDecoder().decode(SessionGrant.self, from: Data(#"""
            {"token":"t","role":"family","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机","epoch":"\#(UUID().uuidString)",
             "delete_pending_until":"2026-11-26T11:48:00.000Z"}
            """#.utf8))
        let id = UUID()
        _ = try await services.establish(grant, deviceId: id, db: db)
        XCTAssertEqual(try db.syncStatus().deletePendingUntil, "2026-11-26T11:48:00.000Z")
        services.rememberUsername("yuanhui", deviceId: id)
        XCTAssertEqual(services.username(deviceId: id), "yuanhui")
        XCTAssertNil(services.username(deviceId: UUID()), "换了会话不认")
    }

    /// 注销申请期间：首页提醒条排在最上面，有撤回能力的点进「账号与密码」；同步不推、账留在本机
    func testDeletingReminderAndNoPush() async throws {
        var f = HomeFigures()
        f.deletePendingUntil = "2026-11-26T11:48:00.000Z"
        f.livePendingCount = 3; f.rejectedCount = 1; f.expiringCount = 2
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)).first, .deleting(pending: 3))
        XCTAssertEqual(HomeView.deletingText(pending: 3, canCancel: true), "账号正在注销，3 笔还没记上，撤回后会自动补传。点这里撤回")
        XCTAssertEqual(HomeView.deletingText(pending: 0, canCancel: false), "账号正在注销，现在记的账传不上去，撤回后会自动补传。")

        let (db, s) = try store()
        try db.setMeta(.deletePendingUntil, "2026-11-26T11:48:00.000Z")
        try sell(db)
        let server = S22bTests.Server(); server.deletePending = true
        let m = AppModel(db: db, session: s, figures: HomeFigures(), defaults: defaults)
        let c = coordinator(db, server)
        m.attach(c)
        c.kick(); await c.idle()
        c.stop()
        XCTAssertEqual(server.log.map(\.ops).reduce(0, +), 0, "注销中一笔都不推")
        XCTAssertEqual(try db.pendingCount(deviceId: s.deviceId, storeId: s.storeId), 1, "留在本机")
        XCTAssertEqual(m.figures.deletePendingUntil, "2026-11-30T02:00:00.000Z", "跟着同步响应")
        // 撤回后：本机清掉注销状态，下一趟就补传
        server.deletePending = false
        m.setDeletePending(nil)
        for _ in 0..<100 where (try? db.pendingCount(deviceId: s.deviceId, storeId: s.storeId)) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        await c.idle()
        XCTAssertEqual(try db.pendingCount(deviceId: s.deviceId, storeId: s.storeId), 0, "撤回后自动补传")
    }

    // MARK: 23 页、权限

    /// 「不注销了」实心、「确认注销」描边；期限文字和 §9.4 一致（7 天可撤回、备份 35 天内清除）
    func testDeletePageStylesAndDeadline() {
        XCTAssertEqual(DeleteAccountView.keepStyle, .dark)
        XCTAssertEqual(DeleteAccountView.confirmStyle, .ghost)
        XCTAssertTrue(DeleteAccountView.deadline.contains("7 天内可以撤回"))
        XCTAssertTrue(DeleteAccountView.deadline.contains("7 天后删除服务器上的账和商品图"))
        XCTAssertTrue(DeleteAccountView.deadline.contains("备份在之后 35 天内清除"))
        XCTAssertEqual(DeleteAccountView.loginNotice(until: "2026-11-26T11:48:00.000Z"),
                       "已经申请注销。11月26日 19:48 之前用账号密码登录，可以撤回。")
    }

    /// 入口按权限表：家用、审核有「账号与密码」和注销页；收银员、被踢设备没有（硬塞路由也是「用不了」）
    func testAccountRoutesFollowPermissions() {
        for role in [Role.family, .review] {
            let caps = Capabilities(role: role)
            XCTAssertEqual(RouteView.content(for: .account, capabilities: caps), .account, "\(role)")
            XCTAssertEqual(RouteView.content(for: .deleteAccount, capabilities: caps), .deleteAccount, "\(role)")
            XCTAssertTrue(caps.has(.manageDevices), "\(role) 有「让其他手机全部退出」")
        }
        for role in [Role.cashier, .revoked] {
            let caps = Capabilities(role: role)
            XCTAssertEqual(RouteView.content(for: .account, capabilities: caps), .denied, "\(role)")
            XCTAssertEqual(RouteView.content(for: .deleteAccount, capabilities: caps), .denied, "\(role)")
        }
        XCTAssertNil(Route.account.plannedIn)
        XCTAssertNil(Route.deleteAccount.plannedIn)
    }
}
