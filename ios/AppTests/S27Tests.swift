import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S27 快过期：19 / 20 / 20b 的状态（打开面板先填账上的数、处理后黄条跟着变、另一台手机处理过 → 提示并刷新）、
/// 首页黄条来自本地库（夹具以外不出稿子上的 3，§14 S15-1）、收银员没有黄条。
@MainActor
final class S27Tests: XCTestCase {
    /// 稿子上的 11/19 19:48
    static let now = UIFixture.designNow
    private let defaults = UserDefaults(suiteName: "S27Tests")!

    override func setUp() { defaults.removePersistentDomain(forName: "S27Tests") }

    func db(_ role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role,
                                             tokenRef: "t27", storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        try UIFixture.installExpiry(into: db)
        return db
    }

    func app(_ db: LocalDB) throws -> AppModel {
        AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), today: Self.now,
                 defaults: defaults, fixedNow: Self.now)
    }

    func testHomeBannerComesFromLocalLots() throws {
        let db = try db()
        let app = try app(db)
        XCTAssertEqual(app.figures.expiringCount, 0, "没算之前是 0，不是稿子上的 3")
        app.refreshExpiring()
        XCTAssertEqual(app.figures.expiringCount, 3)
        XCTAssertEqual(HomeReminder.list(app.figures, capabilities: app.capabilities), [.expiring(3)])
        // 夹具（不带 -uiExpiry）：用稿子上的数，不从库里算
        app.liveExpiry = false
        app.figures.expiringCount = 9
        app.refreshExpiring()
        XCTAssertEqual(app.figures.expiringCount, 9)
    }

    func testCashierHasNoBanner() throws {
        let db = try db(.cashier)
        let app = try app(db)
        app.figures.expiringCount = 3
        XCTAssertEqual(HomeReminder.list(app.figures, capabilities: app.capabilities), [], "收银员没有黄条")
        app.refreshExpiring()
        XCTAssertEqual(app.figures.expiringCount, 0)
        XCTAssertEqual(RouteView.content(for: .expiry, capabilities: app.capabilities), .denied)
        XCTAssertEqual(RouteView.content(for: .expiry, capabilities: Capabilities(role: .family)), .expiry)
    }

    func testPanelStartsAtBookQtyAndDiscardUpdatesBanner() throws {
        let db = try db()
        let app = try app(db)
        app.refreshExpiring()
        let m = ExpiryModel(db: db, clock: { Self.now })
        m.onWrite = { app.refreshExpiring() }
        m.load()
        let b = try XCTUnwrap(m.board)
        XCTAssertEqual(b.expired.map(\.name), ["光明 新鲜牧场 950ml"])
        XCTAssertEqual(b.soon.map(\.name), ["桃李 醇熟切片面包", "伊利纯牛奶 250ml"])
        XCTAssertEqual(b.snoozed.map(\.name), ["达利园 法式软面包"])
        let milk = b.expired[0]
        m.open(milk)
        XCTAssertEqual(m.actualQty, 2, "先填账上的数")
        XCTAssertEqual(m.choices(milk), [.soldOut, .discard, .return, .snooze], "照稿子 20")
        XCTAssertEqual(m.emphasized(milk), .discard)
        XCTAssertEqual(m.detail(.discard, item: milk), "扣 2 盒库存，算亏 ¥19.60")
        XCTAssertEqual(m.detail(.return, item: milk), "扣 2 盒库存，不算亏")
        XCTAssertEqual(m.detail(.snooze, item: milk), "3 天后再提醒（11月22日）")
        XCTAssertEqual(ExpiryModel.panelDaysText(milk), "11月17日到期，已经过了 2 天")
        m.actualQty = 0
        XCTAssertEqual(m.emphasized(milk), .soldOut)
        m.choose(.discard)
        XCTAssertNotNil(m.handling, "0 个时扔掉点不了")
        m.actualQty = 2
        m.choose(.discard)
        XCTAssertNil(m.handling)
        XCTAssertEqual(m.watching.count, 1)
        XCTAssertTrue(m.board?.expired.isEmpty ?? false)
        XCTAssertEqual(app.figures.expiringCount, 2, "扔掉后黄条少一样")
        XCTAssertEqual(try db.displayStock(milk.productId)?.qty, 0)
    }

    func testSoonPanelAndDaysText() throws {
        let m = ExpiryModel(db: try db(), clock: { Self.now })
        m.load()
        let ili = try XCTUnwrap(m.board?.soon.last)
        m.open(ili)
        XCTAssertEqual(m.choices(ili), [.snooze, .soldOut, .return, .discard], "照稿子 20b")
        XCTAssertEqual(m.emphasized(ili), .snooze)
        XCTAssertEqual(m.detail(.discard, item: ili), "扣 3 盒库存，算亏 ¥6.87")
        XCTAssertEqual(ExpiryModel.daysText(ili), "还有 5 天")
        XCTAssertEqual(ExpiryModel.panelDaysText(ili), "11月24日到期，还有 5 天")
        XCTAssertEqual(m.stepperRange(ili), 0...9_999)
    }

    /// 另一台手机已经处理过同一批：这一趟同步拒 stale → 提示「这批已经处理过了」，清单按拉下来的重新列
    func testStaleResultShowsNoticeAndReloads() throws {
        let db = try db()
        let m = ExpiryModel(db: db, clock: { Self.now })
        m.load()
        let bread = try XCTUnwrap(m.board?.soon.first)
        m.open(bread)
        m.choose(.discard)
        XCTAssertEqual(m.board?.soon.count, 1)
        let op = try XCTUnwrap(m.watching.keys.first)
        m.syncFinished()
        XCTAssertNil(m.notice, "还没结果不提示")
        try db.recordResults([try OpResult(id: op, status: .rejected, code: "stale")], storeId: DemoSeed.storeId)
        // 拉下来的是另一台手机处理后的样子：再提醒到 11/22、剩 1 袋
        try db.applyBaseline(CatalogBaseline(lots: [try LocalLot(id: bread.lotId, productId: bread.productId, expiryDate: bread.expiryDate,
                                                                 qtyIn: 4, qtyLeft: 1, snoozedUntil: try CalendarDate("2026-11-22"), handleVer: 1)]))
        m.syncFinished()
        XCTAssertEqual(m.notice, ExpiryModel.staleNotice)
        XCTAssertTrue(m.watching.isEmpty)
        XCTAssertEqual(m.board?.snoozed.first { $0.lotId == bread.lotId }?.qtyLeft, 1, "按最新的重新列")
        XCTAssertEqual(try db.displayStock(bread.productId)?.qty, 4, "被拒的不扣库存")
    }

    /// 面板开着时这批被另一台手机处理掉了（同步拉下来已关闭）：关面板并提示
    func testOpenPanelClosesWhenLotGoneAfterSync() throws {
        let db = try db()
        let m = ExpiryModel(db: db, clock: { Self.now })
        m.load()
        let milk = try XCTUnwrap(m.board?.expired.first)
        m.open(milk)
        // 清单里没有这批了（这里用本机直接处理掉来模拟；同步拉到 closed_at 时本地删行，效果一样）
        try db.handleExpiry(milk, choice: .soldOut, actualQty: 0)
        m.syncFinished()
        XCTAssertNil(m.handling)
        XCTAssertEqual(m.notice, ExpiryModel.staleNotice)
    }
}
