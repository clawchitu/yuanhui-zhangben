import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// 待传面板（PR #45，Fable 裁定 1–12）：顶栏 4 秒延迟的状态机、同步失败原因分类、状态句优先级、面板的行和刷新、
/// 「再传一次」至少停 1 秒、各处文案统一成「待传」
@MainActor
final class PendingPanelTests: XCTestCase {
    let defaults = UserDefaults(suiteName: "PendingPanelTests")!
    override func setUp() { defaults.removePersistentDomain(forName: "PendingPanelTests") }

    func db(_ role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                             tokenRef: "t", storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try db.setMeta(.serverEpoch, UUID().uuidString)
        return db
    }

    func sell(_ db: LocalDB, _ codes: [String] = ["6901035600016"], at: Date = Date()) throws {
        var b = Basket()
        for c in codes { try b.add(try XCTUnwrap(try db.lookup(barcode: c))) }
        try db.recordSale(b, at: at)
    }

    func model(_ db: LocalDB, delay: Duration, transport: SyncEngine.Transport? = nil) throws -> AppModel {
        let m = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), defaults: defaults)
        m.pendingDelay = delay
        if let transport {
            let sync = SyncCoordinator(db: db, build: 1, transport: transport)
            m.sync = sync
            sync.onFinish = { [weak m] in m?.applySyncStatus() }
            m.applySyncStatus()
        }
        return m
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: - 顶栏 4 秒延迟（裁定 1、11）

    func testBadgeStepRules() {
        XCTAssertEqual(PendingBadge.next(shown: 0, live: 2, immediate: false), .wait, "0 → 有待传：先等")
        XCTAssertEqual(PendingBadge.next(shown: nil, live: 2, immediate: false), .wait)
        XCTAssertEqual(PendingBadge.next(shown: 0, live: 2, immediate: true), .show(2), "没网 / 上次失败：不等")
        XCTAssertEqual(PendingBadge.next(shown: 3, live: 5, immediate: false), .show(5), "已经在显示：立刻更新")
        XCTAssertEqual(PendingBadge.next(shown: 3, live: 1, immediate: false), .show(1))
        XCTAssertEqual(PendingBadge.next(shown: 3, live: 0, immediate: false), .show(0), "回到 0：立刻已同步")
        XCTAssertEqual(PendingBadge.next(shown: 0, live: 0, immediate: false), .show(0))
    }

    func testTopBarWaitsButLiveCountIsImmediate() async throws {
        let db = try db()
        let m = try model(db, delay: .milliseconds(400))
        try sell(db)
        m.refreshPending()
        XCTAssertEqual(m.figures.pendingCount, 0, "顶栏先不显示")
        XCTAssertEqual(m.livePendingCount, 1, "面板 / 提醒条用实时数，不等")
        await pause(200)
        XCTAssertEqual(m.figures.pendingCount, 0, "还没到时间")
        try sell(db)
        m.refreshPending()
        XCTAssertEqual(m.figures.pendingCount, 0, "等的期间又记一笔：不重新计时，也不提前显示")
        await pause(350)
        XCTAssertEqual(m.figures.pendingCount, 2, "到时间显示当时的实时数")
        try sell(db)
        m.refreshPending()
        XCTAssertEqual(m.figures.pendingCount, 3, "已经在显示：立刻更新")
    }

    func testSyncedWithinDelayNeverFlashes() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        server.delay = 0.1
        let m = try model(db, delay: .milliseconds(800)) { try server.handle($0) }
        var seen: [Int?] = []
        try sell(db)
        m.refreshPending()   // 写入后踢一趟同步
        seen.append(m.figures.pendingCount)
        await m.sync!.idle()
        seen.append(m.figures.pendingCount)
        await pause(1000)
        seen.append(m.figures.pendingCount)
        XCTAssertEqual(m.livePendingCount, 0)
        XCTAssertEqual(seen, [0, 0, 0], "几秒内就传上去了：顶栏一直是「已同步」，不闪「1 笔待传」")
    }

    func testNoWaitWhenLastSyncFailed() async throws {
        let db = try db()
        let m = try model(db, delay: .seconds(30)) { _ in throw APIError.transport("连不上") }
        m.sync!.kick(); await m.sync!.idle()
        XCTAssertEqual(m.sync!.lastFailure, .network)
        try sell(db)
        m.refreshPending()
        XCTAssertEqual(m.figures.pendingCount, 1, "上一次同步刚失败：不等，立刻显示")
    }

    func testBackToZeroIsImmediate() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        let m = try model(db, delay: .seconds(30)) { try server.handle($0) }
        try sell(db); try sell(db)
        m.figures.pendingCount = 2   // 已经在显示
        m.sync!.refreshStatus(); m.applySyncStatus()
        XCTAssertEqual(m.figures.pendingCount, 2)
        m.sync!.kick(); await m.sync!.idle()
        XCTAssertEqual(m.figures.pendingCount, 0, "传完立刻「已同步」")
    }

    func testLiveCountIncludesRecoveryQueue() throws {
        let db = try db()
        try sell(db)
        try db.endSession()   // 旧会话没传完的进恢复队列
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t2",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)   // 结束会话清了投影
        try sell(db)
        let m = try model(db, delay: .zero)
        m.refreshPending()
        XCTAssertEqual(m.livePendingCount, 2, "当前会话 + 恢复队列")
        XCTAssertEqual(m.figures.pendingCount, 2)
    }

    // MARK: - 失败原因（交接 1）

    func testFailureClassification() {
        struct Boom: Error {}
        XCTAssertEqual(SyncFailure(APIError.transport("x"), offline: true), .offline)
        XCTAssertEqual(SyncFailure(APIError.transport("x"), offline: false), .network)
        XCTAssertEqual(SyncFailure(APIError.server(status: 401, code: "unauthorized", lockedUntil: nil, retryAfterS: nil), offline: false),
                       .unauthorized, "读不到令牌（传输里当 401 抛）")
        XCTAssertEqual(SyncFailure(SyncHTTPError(status: 401), offline: false), .unauthorized)
        XCTAssertEqual(SyncFailure(SyncHTTPError(status: 401), offline: true), .unauthorized)
        XCTAssertEqual(SyncFailure(SyncHTTPError(status: 503), offline: false), .other)
        XCTAssertEqual(SyncFailure(SyncHTTPError(status: 429), offline: false), .other)
        XCTAssertEqual(SyncFailure(Boom(), offline: false), .other)
    }

    func testLastFailureSetOnFailureAndClearedOnSuccess() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        final class Mode: @unchecked Sendable { var code = 503 }
        let mode = Mode()
        let sync = SyncCoordinator(db: db, build: 1) { body in
            if mode.code != 200 { return (mode.code, Data()) }
            return try server.handle(body)
        }
        sync.kick(); await sync.idle()
        XCTAssertEqual(sync.lastFailure, .other, "服务器忙")
        mode.code = 401
        sync.kick(); await sync.idle()
        XCTAssertEqual(sync.lastFailure, .unauthorized)
        mode.code = 200
        sync.kick(); await sync.idle()
        XCTAssertNil(sync.lastFailure, "成功后清掉")
    }

    // MARK: - 状态句（裁定 5、6）

    func testReasonPriority() {
        XCTAssertEqual(PendingReason.from(deleting: true, failure: .unauthorized, offline: true), .deleting)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: .unauthorized, offline: true), .unauthorized)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: .network, offline: true), .offline)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: .offline, offline: false), .offline)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: .network, offline: false), .network)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: .other, offline: false), .other)
        XCTAssertEqual(PendingReason.from(deleting: false, failure: nil, offline: false), .normal)
    }

    func testHeadlinesFootnoteAndRetry() {
        XCTAssertEqual(PendingReason.deleting.headline(count: 3), "账号正在注销，这 3 笔先不传。撤回注销后会自动传，账不会丢")
        XCTAssertEqual(PendingReason.unauthorized.headline(count: 3), "登录过期了，这 3 笔先传不了。重新登录后会自动传，账不会丢")
        XCTAssertEqual(PendingReason.offline.headline(count: 3), "没网。联网后会自动传，账不会丢")
        XCTAssertEqual(PendingReason.network.headline(count: 3), "网不好，没传上去。会自动再试，账不会丢")
        XCTAssertEqual(PendingReason.other.headline(count: 3), "暂时没传上去。会自动再试，账不会丢")
        XCTAssertEqual(PendingReason.normal.headline(count: 3), "正在传，一会儿就好")
        for r in PendingReason.allCases {
            let hidden = r == .deleting || r == .unauthorized
            XCTAssertEqual(r.showsFootnote, !hidden, "\(r) 小字")
            XCTAssertEqual(r.allowsRetry, !hidden, "\(r) 再传一次（没网照样能点）")
        }
        XCTAssertEqual(PendingReason.footnote, "手机会自己接着试，不用管它")
    }

    func testRetryShowsAtLeastOneSecond() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        let sync = SyncCoordinator(db: db, build: 1) { try server.handle($0) }
        try sell(db)
        let t0 = ContinuousClock.now
        let task = Task { await sync.retry() }
        await pause(50)
        XCTAssertTrue(sync.retrying, "点后变灰「正在传…」")
        await task.value
        XCTAssertFalse(sync.retrying, "传完恢复")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - t0, .milliseconds(990), "至少停 1 秒")
        XCTAssertEqual(try db.pendingTally().total, 0)
    }

    // MARK: - 面板的行（裁定 7、8、12）

    func testRowTexts() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 20, minute: 0)))
        let today = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 19, minute: 32)))
        func e(_ at: Date, _ type: OpType = .saleBatch, names: [String], qty: Int64?, unit: String?, fen: Int64?) -> PendingEntry {
            PendingEntry(id: 1, occurredAt: at, type: type, names: names, quantity: qty, unitName: unit, amountFen: fen, priceOnlyEdit: false)
        }
        XCTAssertEqual(PendingModel.rowText(e(today, names: ["农夫山泉", "中华", "可乐"], qty: 5, unit: "件", fen: 5300), now: now),
                       "19:32 卖出 农夫山泉 等 3 样 · 5 件 · ¥53.00")
        XCTAssertEqual(PendingModel.rowText(e(today.addingTimeInterval(-86_400), names: ["中华"], qty: 1, unit: "件", fen: 4500), now: now),
                       "昨天 19:32 卖出 中华 · 1 件 · ¥45.00", "只有一样不写「等 N 样」")
        XCTAssertEqual(PendingModel.rowText(e(today.addingTimeInterval(-86_400 * 2), .stockIn, names: ["可乐"], qty: 5, unit: "箱", fen: 24000), now: now),
                       "11月22日 19:32 进货 可乐 · 5 箱 · ¥240.00")
        XCTAssertEqual(PendingModel.rowText(e(today, .void, names: [], qty: nil, unit: nil, fen: nil), now: now), "19:32 撤销")
        XCTAssertEqual(PendingModel.moreText(3), "还有 3 笔，传上去以后能在记的账里看")
        XCTAssertEqual(PendingModel.recoveryText(2), "以前登录时还有 2 笔待传，会一起传")
        XCTAssertEqual(PendingModel.rejectedText(1), "今天有 1 笔没记上，点这里去看")
    }

    func testPanelFollowsSyncAndEmpties() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        let sync = SyncCoordinator(db: db, build: 1) { try server.handle($0) }
        for _ in 0..<22 { try sell(db) }
        let panel = PendingModel(db: db, clock: { Date() })
        await panel.reload()
        let o = try XCTUnwrap(panel.overview)
        XCTAssertEqual(o.total, 22)
        XCTAssertEqual(o.entries.count, 20, "最多列 20 笔")
        XCTAssertEqual(o.moreCount, 2, "还有 2 笔")
        sync.kick(); await sync.idle()
        await panel.reload()
        XCTAssertEqual(panel.overview?.total, 0, "传完的行消失，全部传完 → 都传上去了")
        XCTAssertEqual(panel.overview?.entries, [])
    }

    // MARK: - 提醒条、路由、文案（裁定 2、3、9）

    func testUnsyncedBannerUsesLiveTotal() {
        var f = HomeFigures()
        f.livePendingCount = 7
        f.staleUnsyncedCount = 2
        XCTAssertEqual(HomeReminder.list(f, capabilities: Capabilities(role: .family)), [.unsynced(total: 7, overdue: 2)])
    }

    func testPendingRouteForEveryone() {
        XCTAssertEqual(Route.pending.title(.family), "待传的账")
        XCTAssertEqual(Route.pending.title(.cashier), "待传的账")
        XCTAssertNil(Route.pending.requiredCapability)
        XCTAssertNil(Route.pending.plannedIn)
        for role in Role.allCases {
            XCTAssertEqual(RouteView.content(for: .pending, capabilities: Capabilities(role: role)), .pending)
        }
    }

    func testModeBarTexts() {
        XCTAssertEqual(ModeBar.statusText(pendingCount: 0, offline: false), "已同步")
        XCTAssertEqual(ModeBar.statusText(pendingCount: 3, offline: false), "3 笔待传")
        XCTAssertEqual(ModeBar.statusText(pendingCount: 3, offline: true), "没网 · 3 笔待传")
        XCTAssertEqual(ModeBar.statusText(pendingCount: 0, offline: true), "没网", "N = 0 只写「没网」")
        XCTAssertEqual(ModeBar.statusText(pendingCount: nil, offline: true), "没网")
        XCTAssertNil(ModeBar.statusText(pendingCount: nil, offline: false))
        XCTAssertEqual(ModeBar.tapLabel(pendingCount: 3, offline: false), "3 笔待传，点开看")
        XCTAssertEqual(ModeBar.tapLabel(pendingCount: 0, offline: false), "已同步，点开看")
        XCTAssertEqual(ModeBar.tapLabel(pendingCount: 3, offline: true), "没网，3 笔待传，点开看")
    }

    func testLogoutPendingCountsWholeDevice() async throws {
        let db = try db()
        try sell(db)
        try db.endSession()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t2",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)   // 结束会话清了投影
        try sell(db); try sell(db)
        let m = try model(db, delay: .zero) { _ in throw APIError.transport("没网") }
        let out = await m.logout()
        XCTAssertEqual(out, .pending(3), "提示里的笔数和顶栏同口径（含恢复队列）")
    }

    func testRetryGivesUpWaitingAfterMaximum() async throws {
        let db = try db(), server = S22aTests.FakeServer()
        server.delay = 1.5   // 网一直不回
        let sync = SyncCoordinator(db: db, build: 1) { try server.handle($0) }
        let t0 = ContinuousClock.now
        await sync.retry(minimum: .milliseconds(100), maximum: .milliseconds(400))
        XCTAssertLessThan(ContinuousClock.now - t0, .milliseconds(1200), "到上限就恢复按钮")
        XCTAssertFalse(sync.retrying)
        XCTAssertTrue(sync.running, "同步在后台接着跑")
        await sync.idle()
    }
}
