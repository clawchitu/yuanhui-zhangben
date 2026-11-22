import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S18 新商品登记（04a / 04b / 04c / 25e）和整件码（05）的状态与动作（不碰界面）。
@MainActor
final class S18Tests: XCTestCase {
    static let newCode = "6924743919211", packCode = "6925303770099", cola = "6925303770013"

    private func makeDB(_ role: Role = .family) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: UUID(), storeId: DemoSeed.storeId, role: role, tokenRef: "t",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    private func type(_ m: NewProductModel, _ s: String) {
        for c in s { m.priceKey(c == "." ? .dot : .digit(c.wholeNumberValue!)) }
    }

    private func newModel(_ db: LocalDB, quick: Bool = false, mode: ShopMode = .sell, code: String = newCode) -> NewProductModel {
        NewProductModel(db: db, barcode: code, mode: mode, quick: quick, canLinkPack: !quick)
    }

    // MARK: 卖出页：扫到新码 → 登记页（§14 S16-3）

    func testUnknownCodeGoesToRegistrationWhenAllowedElseBanner() throws {
        let db = try makeDB()
        let full = SellModel(db: db, registration: .full)
        XCTAssertEqual(full.handle(Scan(code: Self.newCode, source: .gun)), .unknown, "仍是低音：不是认得的码")
        XCTAssertEqual(full.registerCode?.code, Self.newCode)
        XCTAssertNil(full.notice, "进得了登记页就不出黄条")
        // 进不了登记页：这台手机不能登记 / 条码太长（整串不收、不截断）
        let none = SellModel(db: db, registration: .none)
        _ = none.handle(Scan(code: Self.newCode, source: .gun))
        XCTAssertNil(none.registerCode)
        XCTAssertEqual(none.notice, .unknownBarcode(Self.newCode))
        let long = String(repeating: "6", count: 65)
        _ = full.handle(Scan(code: long, source: .gun))
        XCTAssertEqual(full.notice, .unknownBarcode(long))
    }

    /// 04a「存好，接着卖」→ 回到卖出且已在篮里；抹过的零作废（篮子变了）
    func testSaveBasicPutsProductInBasket() throws {
        let db = try makeDB()
        let sell = SellModel(db: db, registration: .full)
        _ = sell.handle(Scan(code: SellModelTests.beer, source: .gun))
        try sell.setPaid(500)
        _ = sell.handle(Scan(code: Self.newCode, source: .gun))
        let m = newModel(db)
        m.applyLookup(.found(name: "乐事薯片 原味 70g", unit: "包"))
        XCTAssertFalse(m.canSaveBasic, "卖价没填不能存")
        type(m, "7.5")
        let conv = try XCTUnwrap(m.saveBasic())
        sell.finishRegistration(.registered(conv, quick: false))
        XCTAssertNil(sell.registerCode)
        XCTAssertEqual(sell.basket.lines.count, 2)
        XCTAssertEqual(sell.focusLine?.name, "乐事薯片 原味 70g")
        XCTAssertEqual(SellModel.unitPriceFen(try XCTUnwrap(sell.focusLine)), 750)
        XCTAssertNil(sell.basket.paidOverrideFen)
        XCTAssertEqual(sell.notice, .paidCleared)
        // 再扫一次这个码：认得了，同一行 +1
        XCTAssertEqual(sell.handle(Scan(code: Self.newCode, source: .gun)), .known)
        XCTAssertEqual(sell.focusLine?.packCount, 2)
        XCTAssertEqual(conv.product.baseUnit, "包", "查到的规格单位当基本单位")
    }

    func testBackFromRegistrationAddsNothing() throws {
        let sell = SellModel(db: try makeDB(), registration: .full)
        _ = sell.handle(Scan(code: Self.newCode, source: .gun))
        sell.finishRegistration(nil)
        XCTAssertNil(sell.registerCode)
        XCTAssertTrue(sell.basket.isEmpty)
    }

    func testLookupFillsNameOnlyIfNotEdited() throws {
        let m = newModel(try makeDB())
        m.name = "我自己写的"
        m.applyLookup(.found(name: "乐事", unit: nil))
        XCTAssertEqual(m.name, "我自己写的")
        XCTAssertEqual(m.nameLabel, "名称（自动查到的，不对点一下改）")
        let m2 = newModel(try makeDB())
        m2.applyLookup(.offline)
        XCTAssertEqual(m2.name, "")
        XCTAssertEqual(m2.nameLabel, "名称")
    }

    func testTitlesAndModes() throws {
        let db = try makeDB()
        let fam = newModel(db)
        XCTAssertEqual(fam.title, "新商品 1/2")
        XCTAssertTrue(fam.offersQuickSave)
        XCTAssertTrue(fam.offersSecondStep)
        XCTAssertTrue(fam.canLinkPack)
        type(fam, "3"); fam.goMore()
        XCTAssertEqual(fam.title, "新商品 2/2")
        XCTAssertEqual(fam.mode, .sell, "从卖出进来两步都是朱红")
        XCTAssertTrue(fam.back())
        XCTAssertEqual(fam.step, .basic)
        let stock = newModel(db, mode: .stock)
        XCTAssertEqual(stock.mode, .stock, "从进货进来两步都是靛青")
        XCTAssertFalse(stock.offersQuickSave, "进货中遇到新商品必须走完 04b")
        XCTAssertEqual(LinkPackModel(db: db, barcode: Self.packCode, mode: .stock, product: nil).mode, .stock)
        let cashier = newModel(try makeDB(.cashier), quick: true)
        XCTAssertEqual(cashier.title, "新商品")
        XCTAssertFalse(cashier.offersSecondStep, "收银员只有 04c")
        XCTAssertFalse(cashier.canLinkPack)
        XCTAssertEqual(cashier.heading, "店里没登记过，先记个名字和价钱")
    }

    // MARK: 04b

    func testSecondStepWarningAndExpiryFields() throws {
        let db = try makeDB()
        let m = newModel(db)
        type(m, "7.5"); m.goMore()
        XCTAssertFalse(m.missingCostWarning)
        m.qtyText = "12"
        XCTAssertTrue(m.missingCostWarning, "填了库存没填进价出现黄字")
        m.cost = YuanInput("5.2")
        XCTAssertFalse(m.missingCostWarning)
        m.cost = YuanInput()
        XCTAssertFalse(m.showsExpiryFields, "没打开「要管保质期」不出到期日")
        m.trackExpiry = true
        XCTAssertTrue(m.showsExpiryFields)
        m.year = "2027"; m.month = "02"; m.day = "30"
        XCTAssertNil(m.saveMore(), "2 月 30 日不是真的日子")
        XCTAssertNotNil(m.error)
        m.expiryUnknown = true    // 「不知道，先不填」
        m.warnDays = 15
        let conv = try XCTUnwrap(m.saveMore())
        let ops = try db.pendingOps()
        XCTAssertEqual(ops.map(\.type), [.productUpsert, .opening])
        let opening = try XCTUnwrap(try JSONSerialization.jsonObject(with: ops[1].opJSON) as? [String: Any])["payload"] as? [String: Any]
        XCTAssertEqual(opening?["counted_qty"] as? Int, 12)
        XCTAssertNil(opening?["unit_cost_fen"])
        XCTAssertNil(opening?["expiry_date"])
        XCTAssertEqual(try db.productPrivate(conv.product.id)?.expiryWarnDays, 15)
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, 12)
    }

    func testDigitsInputDropsNonDigits() throws {
        let m = newModel(try makeDB())
        m.qtyText = "1２a3.4"
        XCTAssertEqual(m.qtyText, "134")
        m.qtyText = "123456789"
        XCTAssertEqual(m.qtyText, "1234567", "≤ 9,999,999（§5.0）")
        m.year = "20270"
        XCTAssertEqual(m.year, "2027")
    }

    func testYuanInputIsIntegerFenAndCapped() {
        var y = YuanInput("999999.99")
        XCTAssertEqual(y.fen, Limits.maxFen)
        XCTAssertFalse(y.overLimit)
        y.key(.digit(9))
        XCTAssertEqual(y.fen, Limits.maxFen, "小数最多两位")
        var z = YuanInput("1234567")
        XCTAssertEqual(z.text, "123456", "整数最多 6 位")
        z.key(.dot); z.key(.digit(0)); z.key(.digit(5))
        XCTAssertEqual(z.fen, 12_345_605)
        XCTAssertEqual(YuanInput("0.1").fen, 10)
        XCTAssertEqual(YuanInput("7.5").fen, 750)
    }

    // MARK: 04c / 25e

    func testCashierQuickSaveShowsNotice() throws {
        let db = try makeDB(.cashier)
        let sell = SellModel(db: db, registration: .quick)
        _ = sell.handle(Scan(code: "6920152400319", source: .gun))
        let m = newModel(db, quick: true, code: "6920152400319")
        m.applyLookup(.notFound)
        m.name = "白象 老母鸡汤面"
        type(m, "4.5")
        XCTAssertNil(m.saveMore(), "收银员没有第二步")
        let conv = try XCTUnwrap(m.saveBasic())
        sell.finishRegistration(.registered(conv, quick: true))
        XCTAssertEqual(sell.notice, .quickSaved)
        XCTAssertEqual(sell.notice?.text, "已记下，回头让家里人补全")
        XCTAssertEqual(try db.pendingOps().map(\.type), [.productUpsert])
        XCTAssertTrue(conv.product.needsReview)
    }

    func testOfflineEmptyNameRegistersAndSells() throws {
        let db = try makeDB()
        let sell = SellModel(db: db, registration: .full)
        _ = sell.handle(Scan(code: "6901028075831", source: .gun))
        let m = newModel(db, code: "6901028075831")
        m.applyLookup(.offline)
        type(m, "3")
        let conv = try XCTUnwrap(m.saveBasic())
        XCTAssertTrue(ProductNaming.isPlaceholder(conv.product.name))
        sell.finishRegistration(.registered(conv, quick: false))
        XCTAssertTrue(sell.commit())
        XCTAssertEqual(try db.pendingOps().map(\.type), [.productUpsert, .saleBatch])
        XCTAssertEqual(try db.entries().first?.amountFen, Fen(300))
    }

    // MARK: 05

    func testLinkPackCountsAs24AndPriceMatchesShopCore() throws {
        let db = try makeDB()
        let sell = SellModel(db: db, registration: .full)
        _ = sell.handle(Scan(code: Self.cola, source: .gun))
        _ = sell.handle(Scan(code: Self.packCode, source: .gun))
        let colaProduct = try XCTUnwrap(sell.focusLine?.conversion.product)
        let m = LinkPackModel(db: db, barcode: Self.packCode, mode: .sell, product: colaProduct)
        m.key(.dot)
        XCTAssertEqual(m.packQty, nil, "数量没有小数点")
        m.key(.digit(1))
        XCTAssertEqual(m.problem, "整箱至少是 2 个")
        XCTAssertFalse(m.canSave)
        m.key(.delete); m.key(.digit(2)); m.key(.digit(4))
        XCTAssertEqual(m.conversionHint, "以后扫这个码，进货卖出都按 24 罐 可口可乐 330ml 算")
        XCTAssertEqual(m.derivedPriceHint, "不填整箱价，就按 24 × ¥3.00 = ¥72.00 卖")
        m.active = .price
        m.key(.digit(6)); m.key(.digit(0))
        XCTAssertNil(m.derivedPriceHint)
        let conv = try XCTUnwrap(m.save())
        sell.finishRegistration(.linked(conv))
        XCTAssertEqual(sell.handle(Scan(code: Self.packCode, source: .gun)), .known, "关联后扫该码认得")
        let line = try XCTUnwrap(sell.basket.lines.first { $0.barcode == Self.packCode })
        XCTAssertEqual(line.packCount, 2)
        XCTAssertEqual(try line.baseQty(), 48, "每箱按 24 个算")
        XCTAssertEqual(SellModel.lineAmountFen(line), 12000)
        XCTAssertEqual(SellModel.unitPriceFen(line), try conv.unitPrice().raw)
        XCTAssertEqual(try db.pendingOps().map(\.type), [.barcodeLink])
    }

    func testLinkPackQtyCappedAt9999() throws {
        let db = try makeDB()
        let m = LinkPackModel(db: db, barcode: Self.packCode, mode: .sell, product: nil)
        for _ in 0..<6 { m.key(.digit(9)) }
        XCTAssertEqual(m.packQty, 9999)
        XCTAssertFalse(m.canSave, "没选商品不能存")
    }

    func testStubLookup() async {
        let found = await StubNameLookup().lookup(Self.newCode)
        XCTAssertEqual(found, .found(name: "乐事薯片 原味 70g", unit: "包"))
        let off = await StubNameLookup(offline: true).lookup(Self.newCode)
        XCTAssertEqual(off, .offline)
        let nf = await StubNameLookup().lookup("6920152400319")
        XCTAssertEqual(nf, .notFound)
    }
}
