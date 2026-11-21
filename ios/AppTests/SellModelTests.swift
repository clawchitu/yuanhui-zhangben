import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S16 卖出页的状态和动作（不碰界面）：扫码进购物篮、同码合并、步进器减到 0 删除、抹零后改篮子恢复原价、
/// 记账写批次和 outbox、空篮 / 连点不多记、没登记的码出黄条、提示音结果。
@MainActor
final class SellModelTests: XCTestCase {
    static let beer = "6901035600016", beerCase = "6901035600023", erguotou = "6901234500011", noodle = "6902514300011"

    private func makeDB() throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: .family, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    private func makeModel() throws -> SellModel { SellModel(db: try makeDB()) }

    @discardableResult
    private func scan(_ m: SellModel, _ code: String, _ source: ScanSource = .gun) -> ScanOutcome {
        m.handle(Scan(code: code, source: source))
    }

    func testThreeCodesThenCommitWritesOneBatchWithThreeLinesAndOneSaleBatchOp() throws {
        let m = try makeModel()
        let before = try m.db.allOutbox().filter { $0.type == .saleBatch }.count
        for c in [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle] { XCTAssertEqual(scan(m, c), .known) }
        XCTAssertEqual(m.basket.lines.count, 3)
        XCTAssertEqual(m.itemCount, 6)
        XCTAssertEqual(m.listTotalFen, 5350, "稿子 03：¥53.50")
        XCTAssertTrue(m.commit())
        let sales = try m.db.entries().filter { $0.type == .sale }
        XCTAssertEqual(sales.count, 3)
        XCTAssertEqual(Set(sales.compactMap(\.batchId)).count, 1, "三行同一个批次")
        XCTAssertEqual(sales.reduce(0) { $0 + $1.amountFen.raw }, 5350)
        XCTAssertEqual(try m.db.allOutbox().filter { $0.type == .saleBatch }.count, before + 1, "outbox 多一条 sale_batch")
        XCTAssertEqual(m.done?.paidFen, 5350)
        XCTAssertEqual(m.done?.kinds, 3)
        XCTAssertEqual(m.done?.items, 6)
        XCTAssertTrue(m.basket.isEmpty, "记完清空，停在卖出页")
        XCTAssertEqual(m.pendingCount, try m.db.pendingOps().count)
    }

    func testSameCodeTwiceIsQuantityTwoAndFocusIsTheLastScanned() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        scan(m, Self.erguotou)
        XCTAssertEqual(m.focusLine?.barcode, Self.erguotou)
        scan(m, Self.beer)
        XCTAssertEqual(m.basket.lines.count, 2)
        XCTAssertEqual(m.focusLine?.barcode, Self.beer, "再扫一次的那一行回到价签")
        XCTAssertEqual(m.focusLine?.packCount, 2)
        XCTAssertEqual(m.otherLines.map(\.barcode), [Self.erguotou])
    }

    func testCaseCodeIsASeparateLineFromTheSingleCan() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        scan(m, Self.beerCase)
        XCTAssertEqual(m.basket.lines.count, 2, "§14 S12-2：换算数量不同分行")
        XCTAssertEqual(m.itemCount, 2)
        XCTAssertEqual(m.listTotalFen, 600 + 13200)
    }

    func testStepperDownToZeroRemovesTheLine() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        scan(m, Self.erguotou)
        let id = try XCTUnwrap(m.focusLine?.id)
        m.setCount(lineId: id, 3)
        XCTAssertEqual(m.focusLine?.packCount, 3)
        m.setCount(lineId: id, 0)
        XCTAssertEqual(m.basket.lines.map(\.barcode), [Self.beer])
        XCTAssertEqual(m.focusLine?.barcode, Self.beer, "价签那一行删了，换成剩下的最后一行")
        m.setCount(lineId: try XCTUnwrap(m.focusLine?.id), 0)
        XCTAssertTrue(m.basket.isEmpty)
        XCTAssertFalse(m.canCommit)
    }

    func testEmptyBasketCannotCommitOrChangePaid() throws {
        let m = try makeModel()
        XCTAssertFalse(m.canCommit)
        XCTAssertFalse(m.canChangePaid)
        XCTAssertFalse(m.commit())
        XCTAssertTrue(try m.db.entries().filter { $0.type == .sale }.isEmpty)
    }

    func testCommitTwiceInARowRecordsOnlyOneSale() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        XCTAssertTrue(m.commit())
        XCTAssertFalse(m.commit(), "第二下篮子已空，不再记")
        XCTAssertEqual(m.commitCount, 1)
        XCTAssertEqual(Set(try m.db.entries().filter { $0.type == .sale }.compactMap(\.batchId)).count, 1)
    }

    /// §14 带过来的（S12 PR #7 裁定）：抹零后改购物篮，已填的实收清掉，回到按原价收
    func testChangingTheBasketAfterDiscountClearsThePaidAmount() throws {
        let m = try makeModel()
        for c in [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle] { scan(m, c) }
        try m.setPaid(5300)
        XCTAssertEqual(m.paidTotalFen, 5300)
        XCTAssertEqual(m.discountFen, 50, "03b：优惠 ¥0.50")
        scan(m, Self.noodle)
        XCTAssertNil(m.discountFen, "再扫码：抹零作废")
        XCTAssertEqual(m.paidTotalFen, 5800)

        try m.setPaid(5700)
        XCTAssertEqual(m.discountFen, 100)
        m.setCount(lineId: try XCTUnwrap(m.focusLine?.id), 1)
        XCTAssertNil(m.discountFen, "改数量：抹零作废")
        XCTAssertEqual(m.paidTotalFen, m.listTotalFen)
    }

    func testDiscountedCommitRecordsThePaidAmount() throws {
        let m = try makeModel()
        for c in [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle] { scan(m, c) }
        try m.setPaid(5300)
        XCTAssertTrue(m.commit())
        let sales = try m.db.entries().filter { $0.type == .sale }
        XCTAssertEqual(sales.reduce(0) { $0 + $1.amountFen.raw }, 5300)
        XCTAssertEqual(sales.reduce(0) { $0 + $1.listAmountFen.raw }, 5350)
        XCTAssertEqual(m.done?.paidFen, 5300, "03d 黑卡是实收")
    }

    func testUnknownCodeShowsNoticeAndPlaysTheLowTone() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        XCTAssertEqual(scan(m, "6900000000000"), .unknown)
        XCTAssertEqual(m.notice, .unknownBarcode("6900000000000"))
        XCTAssertEqual(m.basket.lines.count, 1, "篮子不变")
        XCTAssertEqual(scan(m, Self.beer), .known)
        XCTAssertNil(m.notice, "下一次扫码黄条消失")
    }

    func testNotAcceptingReturnsIgnoredAndLeavesTheBasketAlone() throws {
        let m = try makeModel()
        m.accepting = false
        XCTAssertEqual(scan(m, Self.beer), .ignored)
        XCTAssertTrue(m.basket.isEmpty)
        m.accepting = true
        XCTAssertEqual(scan(m, Self.beer), .known)
    }

    func testNextScanReplacesTheDoneCard() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        m.commit()
        let done = try XCTUnwrap(m.done)
        scan(m, Self.noodle)
        XCTAssertNil(m.done)
        m.dismissDone(done.id)
        XCTAssertNil(m.done)
    }

    func testArchivedProductStillSellsAndIsMarked() throws {
        let db = try makeDB()
        let p = try Product(id: UUID(), name: "旧包装饼干", baseUnit: "包", priceFen: Fen(350), archived: true)
        try db.applyBaseline(CatalogBaseline(products: [p], barcodes: [try BarcodeRecord(barcode: "6900000000208", productId: p.id,
                                                                                            unitName: "包")]))
        let m = SellModel(db: db)
        XCTAssertEqual(scan(m, "6900000000208"), .known, "停用商品照卖")
        XCTAssertEqual(m.focusLine?.conversion.product.archived, true)
        XCTAssertTrue(FocusLineCard.caption(for: try XCTUnwrap(m.focusLine)).hasSuffix("已停用"))
    }

    func testOverLimitIsRejectedWithNotice() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        let id = try XCTUnwrap(m.focusLine?.id)
        m.setCount(lineId: id, Int(Limits.maxPackCount))
        XCTAssertEqual(m.focusLine?.packCount, Limits.maxPackCount)
        XCTAssertEqual(scan(m, Self.beer), .unknown, "超上限加不进去：低音提醒")
        guard case .rejected = m.notice else { return XCTFail("应出「加不进去」黄条，实际 \(String(describing: m.notice))") }
        XCTAssertEqual(m.focusLine?.packCount, Limits.maxPackCount)
    }

    /// 经扫码层：相机同码 1.5 秒内只进一次，扫码枪每扣一次都进（S14-1 接到购物篮上）
    func testThroughTheHubCameraDedupesAndGunDoesNot() throws {
        let m = try makeModel()
        var now: TimeInterval = 1000
        let hub = ScanHub(feedback: nil, clock: { now })
        hub.handler = { m.handle($0) }
        XCTAssertEqual(hub.receive(Self.beer, from: .camera), .known)
        now += 0.5
        XCTAssertNil(hub.receive(Self.beer, from: .camera))
        XCTAssertEqual(m.focusLine?.packCount, 1)
        for _ in 0..<2 {
            for c in Self.beer { hub.key(.character(c), at: now); now += 0.01 }
            hub.key(.enter, at: now)
        }
        XCTAssertEqual(m.focusLine?.packCount, 3)
        XCTAssertNil(hub.receive("ABC-" + Self.beer, from: .manual), "S14-5：带符号的码不收")
        XCTAssertEqual(m.focusLine?.packCount, 3)
    }
    // MARK: 步进器绑定（Codex ①）

    /// 同一个绑定在界面重建前连按两次「+」：两次都要算上（不能都写成「原数 + 1」）
    func testHeldCountBindingIncrementsTwice() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        let line = try XCTUnwrap(m.focusLine)
        let b = m.countBinding(for: line)
        b.wrappedValue += 1
        b.wrappedValue += 1
        XCTAssertEqual(m.focusLine?.packCount, 3)
        XCTAssertEqual(b.wrappedValue, 3, "绑定读的是篮子里现在的数")
        XCTAssertEqual(m.listTotalFen, 1800)
    }

    /// 扫码和步进器交错：扫码加了一件之后，旧按钮再按「+」是在新数上加，不把扫进来的那件覆盖掉
    func testHeldCountBindingAfterAScanAddsOnTopOfTheScan() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        let b = m.countBinding(for: try XCTUnwrap(m.focusLine))
        scan(m, Self.beer)
        XCTAssertEqual(m.focusLine?.packCount, 2)
        b.wrappedValue += 1
        XCTAssertEqual(m.focusLine?.packCount, 3, "扫进来的那件还在")
        scan(m, Self.beer)
        b.wrappedValue -= 1
        XCTAssertEqual(m.focusLine?.packCount, 3)
        XCTAssertEqual(m.itemCount, 3)
        XCTAssertEqual(m.listTotalFen, 1800)
    }

    /// 那一行被删掉以后，旧绑定读到 0、写不进去
    func testCountBindingOfARemovedLine() throws {
        let m = try makeModel()
        scan(m, Self.beer)
        scan(m, Self.noodle)
        let beer = try XCTUnwrap(m.basket.lines.first { $0.barcode == Self.beer })
        let b = m.countBinding(for: beer)
        m.setCount(lineId: beer.id, 0)
        XCTAssertEqual(b.wrappedValue, 0)
        b.wrappedValue += 1
        XCTAssertEqual(m.basket.lines.map(\.barcode), [Self.noodle], "删掉的行不会被旧按钮加回来")
    }
}
