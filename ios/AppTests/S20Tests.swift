import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S20：记的账页的状态（07a / 07b / 07c / 08）、首页「刚记的」接真数据、路由；T30 进货日子提醒。
@MainActor
final class S20Tests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_795_088_880)   // 2026-11-19 19:48 上海
    let defaults = UserDefaults(suiteName: "S20Tests")!

    override func setUp() { defaults.removePersistentDomain(forName: "S20Tests") }

    func db(_ role: Role) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        let s = try LocalSession(deviceId: UIFixture.demoDeviceId(role), storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                 storeName: "元辉烟酒店", deviceLabel: role == .cashier ? "小王的手机" : "柜台手机")
        try db.beginSession(s)
        try DemoSeed.install(into: db)
        XCTAssertTrue(try UIFixture.installRecords(into: db, session: s, args: ["-uiRecords"]))
        return db
    }

    func testFamilyTodayMatchesDesign07a() throws {
        let m = RecordsModel(db: try db(.family), cashier: false, clock: { Self.now })
        XCTAssertEqual(m.cards.map(\.kindText), ["卖出", "过期扔掉", "进货"])
        XCTAssertEqual(m.cards.map(\.time), ["19:32", "18:55", "18:10"])
        XCTAssertEqual(m.cards.map(\.deviceLabel), ["柜台手机", "柜台手机", "爸爸的手机"], "手机名，不是人名")
        XCTAssertEqual(m.cards.map(\.amountFen), [5300, 640, 24000])
        XCTAssertEqual(m.cards[2].lines[0].quantityText, "5 箱")
        XCTAssertTrue(m.cards.allSatisfy(m.canUndo))
        XCTAssertEqual(RecordsModel.undoSubtitle(m.cards[0]), "19:32 柜台手机记的卖出，实收 ¥53.00")
        XCTAssertEqual(RecordsModel.discountNote(m.cards[0]), "这笔抹了 ¥0.50，撤一样按比例退")
        XCTAssertEqual(m.cards[0].lines.map(\.amountFen), [2476, 2378, 446])
    }

    func testUndoOneLineThenAllAndHomeFollows() throws {
        let db = try db(.family)
        let app = AppModel(db: db, session: try XCTUnwrap(try db.currentSession()), figures: HomeFigures(), today: Self.now,
                           defaults: defaults, fixedNow: Self.now)
        app.refreshRecent()
        XCTAssertEqual(app.figures.lastRecord, .init(time: "19:32", kind: "卖出", itemCount: 3, amountFen: 5300), "刚记的来自真数据")
        let m = RecordsModel(db: db, cashier: false, clock: { Self.now })
        m.onChange = { app.refreshRecent() }
        let pending = m.pendingCount
        m.undo(.entry(m.cards[0].lines[1].id))
        XCTAssertEqual(m.cards[0].lines.map(\.voided), [false, true, false])
        XCTAssertEqual(RecordsModel.discountNote(m.cards[0]), "这笔抹了 ¥0.50，撤一样按比例退", "剩两行仍提示按比例退")
        XCTAssertEqual(m.pendingCount, pending + 1)
        XCTAssertEqual(app.figures.lastRecord?.itemCount, 2)
        m.undoAll(m.cards[0])
        XCTAssertTrue(m.cards[0].allVoided)
        XCTAssertFalse(m.canUndo(m.cards[0]), "撤完的没有撤销按钮")
        m.undoAll(m.cards[0])
        XCTAssertEqual(m.pendingCount, pending + 2, "撤两次第二次无操作")
        XCTAssertEqual(app.figures.lastRecord?.kind, "过期扔掉", "全撤的那笔不再是「刚记的」")
    }

    func testEarlierListsDaysAndPagesBySeven() throws {
        let m = RecordsModel(db: try db(.family), cashier: false, clock: { Self.now })
        m.tab = .yesterday
        XCTAssertEqual(m.cards.count, 12)
        m.tab = .earlier
        XCTAssertTrue(m.showsDayList)
        XCTAssertEqual(m.visibleDays.map { RecordsModel.dayTitle($0.day) }.first, "11月17日 周二")
        XCTAssertEqual(m.visibleDays.map(\.count), [32, 41, 58, 55, 37, 40, 33])
        XCTAssertEqual(m.visibleDays.map(\.saleFen), [110_200, 128_650, 147_900, 144_400, 107_100, 126_800, 115_000])
        XCTAssertTrue(m.hasMoreDays)
        m.moreDays()
        XCTAssertEqual(m.visibleDays.count, 9)
        XCTAssertFalse(m.hasMoreDays)
        m.openDay = m.visibleDays[0].day
        XCTAssertEqual(m.cards.count, 32, "点哪天看哪天")
        XCTAssertTrue(m.canUndo(m.cards[0]), "家用撤前几天的和今天一样")
    }

    func testCashierSeesOnlyOwnSalesOfToday() throws {
        let m = RecordsModel(db: try db(.cashier), cashier: true, clock: { Self.now })
        XCTAssertEqual(m.cards.map(\.time), ["19:32", "19:05", "17:48"])
        XCTAssertEqual(m.cards.map(\.allVoided), [false, false, true])
        XCTAssertEqual(m.cards.map(m.canUndo), [true, true, false])
        XCTAssertEqual(m.days, [], "收银员没有「更早」")
        m.tab = .yesterday
        XCTAssertEqual(m.day, LocalDB.shanghaiDay(Self.now), "收银员没有日期切换")
        // 过了零点：昨天的那几笔都没有撤销按钮
        let tomorrow = RecordsModel(db: m.db, cashier: true, clock: { Self.now.addingTimeInterval(6 * 3600) })
        XCTAssertEqual(tomorrow.cards, [])
        let late = try XCTUnwrap(try m.db.recordCards(on: LocalDB.shanghaiDay(Self.now)).first)
        XCTAssertFalse(tomorrow.canUndo(late))
    }

    func testGroupedAmount() {
        XCTAssertEqual(RecordsModel.grouped(110_200), "1,102.00")
        XCTAssertEqual(RecordsModel.grouped(128_650), "1,286.50")
        XCTAssertEqual(RecordsModel.grouped(5), "0.05")
        XCTAssertEqual(RecordsModel.grouped(-5300), "-53.00")
        XCTAssertEqual(RecordsModel.grouped(123_456_789_01), "123,456,789.01")
    }

    func testUndoLastOpensLatestCard() throws {
        let m = RecordsModel(db: try db(.family), cashier: false, clock: { Self.now })
        m.openLatestUndo()
        XCTAssertEqual(m.undoCard?.time, "19:32")
    }

    func testRecordsRoutesAreRealPages() {
        for role in [Role.family, .cashier, .review] {
            XCTAssertEqual(RouteView.content(for: .records, capabilities: Capabilities(role: role)), .records)
            XCTAssertEqual(RouteView.content(for: .undoLast, capabilities: Capabilities(role: role)), .records)
        }
        XCTAssertNil(Route.records.plannedIn)
        XCTAssertNil(Route.undoLast.plannedIn)
    }

    // MARK: T30：到期日早于今天、生产日期晚于今天，记之前再问一句

    func stockModel() throws -> StockInModel {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        let m = StockInModel(db: db, today: try CalendarDate("2026-11-21"), defaults: defaults)
        XCTAssertEqual(m.handle(Scan(code: "6901035600016", source: .gun)), .known)   // 青岛啤酒：管保质期
        m.fill(qty: "2", cost: "4.2")
        return m
    }

    func testT30PastExpiryAsksBeforeCommit() throws {
        let m = try stockModel()
        m.expiryMode = .direct
        m.fillDate("2026-03-01")   // 忘改年：今年 3 月，已经过了
        XCTAssertEqual(m.dateWarning, "到期日 2026-03-01 已经过了，年份填对了吗？")
        XCTAssertFalse(m.commit(), "先问一句")
        XCTAssertTrue(m.confirmDate)
        XCTAssertEqual(m.commitCount, 0)
        m.cancelDate()
        m.fillDate("2027-03-01")
        XCTAssertNil(m.dateWarning)
        XCTAssertTrue(m.commit())
    }

    func testT30FutureProductionDateAsksAndCanConfirm() throws {
        let m = try stockModel()
        m.expiryMode = .produced
        m.fillDate("2027-11-12", months: "6")
        XCTAssertEqual(m.dateWarning, "生产日期 2027-11-12 在今天之后，年份填对了吗？")
        XCTAssertFalse(m.commit())
        XCTAssertTrue(m.commit(confirmedZero: true, confirmedDate: true), "确认没错就照记")
        XCTAssertEqual(m.commitCount, 1)
        // 今天生产、今天到期都不提醒
        let n = try stockModel()
        n.fillDate("2026-11-21", months: "6")
        XCTAssertNil(n.dateWarning)
        n.expiryMode = .direct
        XCTAssertNil(n.dateWarning)
    }
}
