import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S22b App 接入：恢复队列在第一次拉取之前用旧令牌传、传不完不拦；被踢后通知外面、未传的用旧令牌接着补；
/// 退出登录的排空（传完再注销 / 没网推迟注销）；首页「N 笔没记上」；25b / 25f 的字；没有会话时进哪页。
@MainActor
final class S22bTests: XCTestCase {
    let defaults = UserDefaults(suiteName: "S22bTests")!
    override func setUp() { defaults.removePersistentDomain(forName: "S22bTests") }

    func session(_ role: Role, _ n: UInt8, token: String) throws -> LocalSession {
        try LocalSession(deviceId: UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)), storeId: UUID(), role: role,
                         tokenRef: token, storeName: "元辉烟酒店", deviceLabel: "手机\(n)")
    }

    func db(_ role: Role, token: String = "tNow") throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try session(role, 1, token: token))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        return db
    }

    func sell(_ db: LocalDB) throws {
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b, at: Date())
    }

    /// 假服务器：按令牌记下每次请求；`revoked` 时说设备被踢
    final class Server: @unchecked Sendable {
        let lock = NSLock()
        var log: [(token: String, pull: Bool, ops: Int)] = []
        var revoked = false
        var offline = false
        /// 账号注销期间：一个都不应用、results 为空
        var deletePending = false
        var logouts: [String] = []
        func sync(token: String, body: Data) throws -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            if offline { throw URLError(.notConnectedToInternet) }
            let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let ops = obj["ops"] as? [[String: Any]] ?? []
            log.append((token, obj["pull"] as? Bool ?? true, ops.count))
            var r: [String: Any] = [
                "results": deletePending ? [] : ops.map { ["id": $0["id"]!, "status": "applied"] },
                "changes": ["products": [], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
                "cursors": ["catalog": 1, "ledger": 1], "has_more": ["catalog": false, "ledger": false],
                "total_products": 0, "server_time": "2026-11-23T02:00:00.000Z", "epoch": obj["epoch"] ?? "",
                "min_build": 0, "device": ["role": "family", "label": "手机", "revoked": revoked], "store": ["name": "店"]]
            if deletePending { r["delete_pending_until"] = "2026-11-30T02:00:00.000Z" }
            return (200, try JSONSerialization.data(withJSONObject: r))
        }
    }

    func coordinator(_ db: LocalDB, _ server: Server, tokens: MemoryTokenStore) -> SyncCoordinator {
        let c = SyncCoordinator(db: db, build: 1) { try server.sync(token: "token-now", body: $0) }
        c.recovery = RecoveryRunner(uploader: RecoveryUploader(db: db, tokens: tokens, appBuild: 1) { call in
            switch call {
            case .sync(let t, let b): return try server.sync(token: t, body: b)
            case .logout(let t): server.lock.withLock { server.logouts.append(t) }; return (204, Data())
            }
        })
        return c
    }

    /// 家用改扫收银员码：兑码后第一次拉取之前，先用旧令牌、只推不拉传恢复队列；之后才是当前会话的拉取
    func testRecoveryBeforeFirstPull() async throws {
        let db = try db(.family, token: "tOld")
        try sell(db); try sell(db)
        try db.endSession(logoutPending: true)
        try db.beginSession(try session(.cashier, 2, token: "tNow"))
        try db.setMeta(.serverEpoch, UUID().uuidString)
        let tokens = MemoryTokenStore(); try tokens.save("token-old", ref: "tOld")
        let server = Server()
        let c = coordinator(db, server, tokens: tokens)
        c.kick(); await c.idle()
        XCTAssertEqual(server.log.first?.token, "token-old")
        XCTAssertEqual(server.log.first?.pull, false)
        XCTAssertEqual(server.log.first?.ops, 2)
        XCTAssertEqual(server.log.dropFirst().first?.token, "token-now", "之后才拉当前会话")
        XCTAssertEqual(server.logouts, ["token-old"], "传完才注销旧令牌")
        XCTAssertNil(try tokens.token(ref: "tOld"))
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
    }

    /// 恢复队列传不上去（没网）不拦：当前会话照常同步（这里服务器对当前令牌是通的）
    func testRecoveryFailureDoesNotBlock() async throws {
        let db = try db(.family, token: "tOld")
        try sell(db)
        try db.endSession(logoutPending: true)
        try db.beginSession(try session(.family, 2, token: "tNow"))
        try db.setMeta(.serverEpoch, UUID().uuidString)
        let tokens = MemoryTokenStore()  // 钥匙串里没有旧令牌：传不了，留着
        let server = Server()
        let c = coordinator(db, server, tokens: tokens)
        c.kick(); await c.idle()
        XCTAssertEqual(server.log.map(\.token), ["token-now"])
        XCTAssertEqual(try db.recoveryPendingCount(), 1, "留着，不丢")
        XCTAssertNil(c.lastError)
    }

    /// 被踢：协调器停下、通知外面；原因记成 kicked_family（25b）
    func testRevokedStopsAndNotifies() async throws {
        let db = try db(.family)
        try sell(db)
        let server = Server(); server.revoked = true
        let c = coordinator(db, server, tokens: MemoryTokenStore())
        var notified = false
        c.onSignedOut = { notified = true }
        c.kick(); await c.idle()
        XCTAssertTrue(notified)
        XCTAssertNil(try db.currentSession())
        XCTAssertEqual(try db.signOutReason(), .kickedFamily)
        guard case .afterSignOut = AppRootBootKind(AppRoot.afterSignOut(db: db, services: nil)) else { return XCTFail() }
    }

    /// 退出登录：联网时先传完再调 logout，会话结束、令牌删掉
    func testLogoutOnlineDrainsThenLogsOut() async throws {
        let db = try db(.family)
        try sell(db)
        let server = Server()
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server, tokens: MemoryTokenStore())
        // 没有 services（测试里不连真服务器）：传完了但调不了 logout → 当作推迟，会话照样结束、标 logout_pending
        let out = await m.logout()
        XCTAssertEqual(out, .pending(0))
        XCTAssertEqual(server.log.first?.ops, 1, "退出前先把 outbox 传完")
        XCTAssertNil(try db.currentSession())
        XCTAssertEqual(try db.retiredSession(deviceId: m.session.deviceId)?.logoutPending, true)
    }

    /// 断网退出：提示 N 笔，未传的进恢复队列，logout 推迟
    func testLogoutOfflineKeepsOpsInRecovery() async throws {
        let db = try db(.family)
        try sell(db); try sell(db)
        let server = Server(); server.offline = true
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server, tokens: MemoryTokenStore())
        let out = await m.logout()
        XCTAssertEqual(out, .pending(2))
        XCTAssertEqual(try db.recoveryPendingCount(), 2)
        XCTAssertEqual(try db.retiredSession(deviceId: m.session.deviceId)?.logoutPending, true)
        XCTAssertEqual(try db.productCount(), 0, "投影清空")
    }

    /// PR #41 必须修 1：退出登录排空时才发现被踢（且账号在注销期间，这批一笔都没应用）：按被踢走，不调 logout，
    /// 旧令牌不删，没传的 3 笔全部留在恢复队列，之后还能用旧令牌补传
    func testLogoutDrainFindsRevokedKeepsTokenAndOps() async throws {
        let db = try db(.family)
        try sell(db); try sell(db); try sell(db)
        let server = Server(); server.revoked = true; server.deletePending = true
        let tokens = MemoryTokenStore(); try tokens.save("token-now", ref: "tNow")
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server, tokens: tokens)
        let out = await m.logout()
        XCTAssertEqual(out, .kicked)
        XCTAssertEqual(try db.signOutReason(), .kickedFamily, "按被踢走（25b）")
        XCTAssertEqual(try db.recoveryPendingCount(), 3, "一笔不丢")
        XCTAssertEqual(try tokens.token(ref: "tNow"), "token-now", "还有没拿到结果的 op，旧令牌不删")
        XCTAssertTrue(server.logouts.isEmpty, "被踢不调 logout")
        // 撤回注销后：恢复队列用旧令牌补传
        server.deletePending = false
        _ = await m.sync?.recovery?.run()
        XCTAssertEqual(try db.recoveryPendingCount(), 0)
        XCTAssertEqual(server.log.last?.token, "token-now")
    }

    /// 排空时被踢、待传超过一批（201 笔）：先推上去的 200 笔有结果，第 201 笔留给恢复队列用旧令牌补传，旧令牌不提前删
    func testLogoutDrainRevokedMidwayOver200() async throws {
        let db = try db(.family)
        for _ in 0..<201 { try sell(db) }
        let server = Server(); server.revoked = true
        let tokens = MemoryTokenStore(); try tokens.save("token-now", ref: "tNow")
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        m.sync = coordinator(db, server, tokens: tokens)
        let out = await m.logout()
        XCTAssertEqual(out, .kicked)
        XCTAssertEqual(server.log.map(\.ops), [200, 1], "第二批由恢复队列用同一个旧令牌补")
        XCTAssertEqual(try db.allOutbox().filter { $0.status == .pending }.count, 0)
        XCTAssertNotNil(try tokens.token(ref: "tNow"), "保留期内的 op 还在，令牌留着")
    }

    func testRejectedReminderAndAck() throws {
        let db = try db(.family)
        try sell(db)
        let op = try XCTUnwrap(try db.pendingOps().first)
        try db.recordResults([try OpResult(id: op.id, status: .rejected, code: "forbidden")], storeId: op.storeId)
        var f = HomeFigures()
        f.rejectedCount = try db.rejectedUnseenCount()
        f.staleUnsyncedCount = 1
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)), [.rejected(1), .unsynced(1)])
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: f, defaults: defaults)
        m.acknowledgeRejected()
        XCTAssertEqual(m.figures.rejectedCount, 0)
        XCTAssertNil(try db.nextPushBatch(), "被拒的不再重试")
    }

    func testKickedTexts() {
        XCTAssertEqual(KickedModel.warning(pending: 2, cashier: false), "还有 2 笔没传上去，没网传不了。先别删 App，连上网重新登录会自动补传")
        XCTAssertEqual(KickedModel.warning(pending: 2, cashier: true), "还有 2 笔没传上去。先别删 App，让家里人重新出一个收银员码，扫了以后会自动补传")
        XCTAssertNil(KickedModel.warning(pending: 0, cashier: false))
        XCTAssertEqual(RouteView.content(for: .logout, capabilities: Capabilities(role: .cashier)), .logout)
    }

    /// 重启后：被踢的进 25b / 25f；演示店重置、退出登录进登录页
    func testBootAfterSignOut() throws {
        for (reason, want) in [(SignOutReason.kickedFamily, "kicked"), (.kickedCashier, "kickedCashier"), (.demoReset, "login")] {
            let db = try db(reason == .kickedCashier ? .cashier : .family)
            try db.endSession(reason: reason, revoked: true)
            switch AppRoot.afterSignOut(db: db, services: nil) {
            case .kicked(let k): XCTAssertEqual(k.cashier ? "kickedCashier" : "kicked", want)
            case .signedOut: XCTAssertEqual("login", want); XCTAssertNil(try db.signOutReason())
            default: XCTFail()
            }
        }
    }
}

/// 只为断言用：被踢后进的是 25b / 25f
enum AppRootBootKind {
    case afterSignOut, other
    @MainActor init(_ b: AppRoot.Boot) { if case .kicked = b { self = .afterSignOut } else { self = .other } }
}
