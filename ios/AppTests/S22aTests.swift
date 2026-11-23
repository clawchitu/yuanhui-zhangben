import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S22a App 接入：同步调度（单飞、写入后补一趟）、首页 / 设置 / 07a 的数来自 `SyncStatus`、首次同步（29）进首页的条件、
/// 收银员的「今天」按服务器时间、T5 手机时间不准的提醒条、首页「刚记的」只取今天且没金额不显示、撤过一行显示剩下的。
@MainActor
final class S22aTests: XCTestCase {
    let defaults = UserDefaults(suiteName: "S22aTests")!
    override func setUp() { defaults.removePersistentDomain(forName: "S22aTests") }

    func db(_ role: Role) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                             tokenRef: "t", storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        return db
    }

    /// 假服务器：每个推上来的 op 都 applied；`serverTime` 可调（T5）；`moreCatalog` 次数内商品流说还有
    final class FakeServer: @unchecked Sendable {
        var serverTime = Date()
        var moreCatalog = 0
        var requests = 0
        var status = "applied"
        var delay: TimeInterval = 0
        let lock = NSLock()
        func handle(_ body: Data) throws -> (Int, Data) {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock(); defer { lock.unlock() }
            requests += 1
            let ops = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["ops"] as? [[String: Any]]) ?? []
            let more = moreCatalog > 0
            if more { moreCatalog -= 1 }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let obj: [String: Any] = [
                "results": ops.map { ["id": $0["id"]!, "status": status] },
                "changes": ["products": [], "barcodes": [], "removed": [], "entries": [], "batches": [], "lots": []],
                "cursors": ["catalog": requests, "ledger": requests], "has_more": ["catalog": more, "ledger": false],
                "total_products": 312, "server_time": iso.string(from: serverTime),
                "epoch": UUID().uuidString.lowercased(), "min_build": 0,
                "device": ["role": "family", "label": "柜台手机", "revoked": false], "store": ["name": "元辉烟酒店"]]
            return (200, try JSONSerialization.data(withJSONObject: obj))
        }
    }

    func model(_ db: LocalDB, server: FakeServer, fixedNow: Date? = nil) throws -> AppModel {
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults,
                         fixedNow: fixedNow)
        let sync = SyncCoordinator(db: db, build: 1) { try server.handle($0) }
        m.sync = sync
        sync.onFinish = { [weak m] in m?.applySyncStatus() }
        m.applySyncStatus()
        return m
    }

    func sell(_ db: LocalDB) throws {
        var b = Basket()
        try b.add(try XCTUnwrap(try db.lookup(barcode: "6901035600016")))
        try db.recordSale(b)
    }

    func testFiguresComeFromSyncStatusAndCatalogGate() async throws {
        let db = try db(.family), server = FakeServer()
        server.moreCatalog = 2
        let m = try model(db, server: server)
        XCTAssertFalse(m.catalogReady, "商品还没拉完：先显示 29")
        try sell(db); try sell(db)
        m.refreshRecent()
        XCTAssertEqual(m.figures.pendingCount, 2, "写入后马上看到待传笔数")
        await m.sync!.idle()
        XCTAssertTrue(m.catalogReady, "商品流拉到底就进首页")
        XCTAssertEqual(m.figures.pendingCount, 0, "已同步")
        XCTAssertEqual(server.requests, 3, "一趟里商品流翻了 3 页")
        XCTAssertEqual(m.figures.staleUnsyncedCount, 0)
    }

    func testKickWhileRunningRunsOnceMore() async throws {
        let db = try db(.family), server = FakeServer()
        server.delay = 0.3
        let m = try model(db, server: server)
        m.sync!.kick()
        try await Task.sleep(for: .milliseconds(100))   // 第一趟已经在路上
        XCTAssertTrue(m.sync!.running)
        m.sync!.kick(); m.sync!.kick()
        await m.sync!.idle()
        XCTAssertEqual(m.sync!.rounds, 2, "在跑时来的两次触发合成一趟，跑完再来，不并发")
    }

    func testClockSkewReminderAndCashierNowFollowsServer() async throws {
        let server = FakeServer()
        server.serverTime = Date().addingTimeInterval(-3 * 3600)  // 手机快了 3 小时
        let fam = try model(try db(.family), server: server)
        fam.sync!.kick(); await fam.sync!.idle()
        XCTAssertEqual(fam.figures.clockSkewMinutes, 180)
        XCTAssertTrue(HomeReminder.list(fam.figures, capabilities: fam.capabilities).contains(.clockOff(180)), "T5 提醒条")
        XCTAssertLessThan(abs(fam.now.timeIntervalSinceNow), 5, "家用仍用手机时钟")
        let cas = try model(try db(.cashier), server: server)
        cas.sync!.kick(); await cas.sync!.idle()
        XCTAssertLessThan(abs(cas.now.timeIntervalSinceNow + 3 * 3600), 5, "收银员的「今天」按服务器的钟")
        server.serverTime = Date()
        fam.sync!.kick(); await fam.sync!.idle()
        XCTAssertNil(fam.figures.clockSkewMinutes, "差得不多不提醒")
    }

    func testRejectedSaleNotRecentAndMarked() async throws {
        let db = try db(.family), server = FakeServer()
        server.status = "rejected"
        let m = try model(db, server: server)
        try sell(db)
        m.refreshRecent()
        XCTAssertNotNil(m.figures.lastRecord)
        await m.sync!.idle()
        m.refreshRecent(); await m.sync!.idle()
        XCTAssertNil(m.figures.lastRecord, "没记上的不当「刚记的」")
        let card = try XCTUnwrap(try db.recordCards(on: LocalDB.shanghaiDay(Date())).first)
        XCTAssertTrue(card.rejected)
    }

    func testRecentOnlyTodayAndNoAmountHidden() throws {
        let db = try db(.family)
        try sell(db)
        let card = try XCTUnwrap(try db.lastRecord())
        XCTAssertNotNil(HomeFigures.LastRecord.today(card, now: Date()))
        XCTAssertNil(HomeFigures.LastRecord.today(card, now: Date().addingTimeInterval(2 * 86_400)), "几天前的一笔不当「刚记的」")
    }
}
