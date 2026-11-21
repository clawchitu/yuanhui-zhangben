import XCTest

/// S17 抹零面板（18 / 28）和手输条码（15 / 15b）的界面验收。码由 Debug 的 FakeScanner 喂进扫码层，
/// 记账结果读调试探针 `debug.ledger`（`lastAmounts` 是最后一笔各行实收，按扫进来的先后）。
@MainActor
final class S17UITests: XCTestCase {
    static let beer = "6901035600016", erguotou = "6901234500011", noodle = "6902514300011"
    static var design: String { [beer, beer, beer, beer, erguotou, noodle].joined(separator: ",") }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String], page: String = "page.sell") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe", "-uiRoute", "sell"] + extra
        app.launch()
        XCTAssertTrue(el(app, page).waitForExistence(timeout: 10), page)
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func ledger(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in el(app, "debug.ledger").label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func waitItems(_ app: XCUIApplication, _ n: Int) {
        wait("一共 \(n) 件") { el(app, "sell.itemCount").label == "一共 \(n) 件" }
    }

    /// 18：点「抹零 / 改总价」→「抹到 ¥53」→「就收这么多」→ 记账，本地库三行实收 24.76 / 23.78 / 4.46（扫的顺序：啤酒、二锅头、面）
    func testRoundToYuanThroughPanelRecordsDesignAllocation() {
        let app = launch(["-uiScan", Self.design, "-uiHoldDone"])
        waitItems(app, 6)
        app.buttons["sell.discount"].tap()
        XCTAssertTrue(el(app, "page.discount").waitForExistence(timeout: 5))
        app.buttons["discount.roundYuan"].tap()
        app.buttons["discount.submit"].tap()
        wait("实收 53.00") { el(app, "sell.total").label == "53.00 元" }
        app.buttons["sell.commit"].tap()
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 5))
        let l = ledger(app)
        XCTAssertEqual(l["lastPaid"], "5300")
        XCTAssertEqual(l["lastAmounts"], "2378|2476|446")
    }

    /// 28：53 输成 5 → 出确认，「输错了，重填」回到键盘；再输 5 →「没错，就收 ¥5.00」定下
    func testBelowSeventyPercentAsksThenConfirm() {
        let app = launch(["-uiScan", Self.design])
        waitItems(app, 6)
        app.buttons["sell.discount"].tap()
        XCTAssertTrue(el(app, "page.discount").waitForExistence(timeout: 5))
        app.buttons["5"].firstMatch.tap()
        app.buttons["discount.submit"].tap()
        XCTAssertTrue(el(app, "page.discountConfirm").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "discount.confirm.detail").label.contains("少按了一位"))
        app.buttons["discount.refill"].tap()
        XCTAssertTrue(el(app, "discount.keypad").waitForExistence(timeout: 5))
        app.buttons["5"].firstMatch.tap()
        app.buttons["discount.submit"].tap()
        XCTAssertTrue(app.buttons["discount.confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discount.confirm"].label.contains("¥5.00"))
        app.buttons["discount.confirm"].tap()
        wait("实收 5.00") { el(app, "sell.total").label == "5.00 元" }
    }

    /// 「不抹了」恢复原价
    func testRestoreGoesBackToListPrice() {
        let app = launch(["-uiScan", Self.design, "-uiPaid", "5300"])
        wait("实收 53.00") { el(app, "sell.total").label == "53.00 元" }
        app.buttons["sell.discount"].tap()
        app.buttons["discount.restore"].tap()
        wait("回到原价 53.50") { el(app, "sell.total").label == "53.50 元" }
    }

    /// 抹零后再加一样（从手输页加，走扫码层）：黄条「抹的零取消了」出现，实收回到原价（§14 S16-1）
    func testAddAfterDiscountShowsPaidClearedBanner() {
        let app = launch(["-uiScan", Self.design, "-uiPaid", "5300", "-uiManual", "code", "-uiManualInput", Self.noodle], page: "page.manualCode")
        XCTAssertTrue(app.buttons["manual.pick"].waitForExistence(timeout: 15))
        wait("只有一个候选，自动选中") { app.buttons["manual.pick"].isEnabled }
        app.buttons["manual.pick"].tap()
        XCTAssertTrue(el(app, "sell.notice").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "sell.notice").label.contains("刚才抹的零取消了"))
        wait("回到原价 58.00") { el(app, "sell.total").label == "58.00 元" }
        XCTAssertEqual(el(app, "sell.totalLabel").label, "零取消了，按原价收", "总价上面也说一句")
    }

    /// 全是零价商品时改价按钮不可用
    func testZeroPriceBasketCannotChangePaid() {
        let app = launch(["-uiMoreGoods", "-uiScan", "6900000000024"])
        waitItems(app, 1)
        XCTAssertFalse(app.buttons["sell.discount"].isEnabled)
        XCTAssertTrue(app.buttons["sell.commit"].isEnabled)
    }

    /// 15：前缀 69025143 命中两个，两个都列、主按钮灰；点第二行后可加入，进的是那一样
    func testManualPrefixTwoHitsThenPick() {
        let app = launch(["-uiMoreGoods", "-uiManual", "code", "-uiManualInput", "69025143"], page: "page.manualCode")
        XCTAssertTrue(el(app, "page.manualCode").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "manual.row.6902514300011").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "manual.row.6902514300028").exists)
        XCTAssertFalse(app.buttons["manual.pick"].isEnabled, "两个时不自动选")
        app.buttons["manual.row.6902514300028"].tap()
        wait("点一行后主按钮可用") { app.buttons["manual.pick"].isEnabled }
        app.buttons["manual.pick"].tap()
        waitItems(app, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "老坛酸菜")).firstMatch.exists, "进篮的是点的那一样")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "红烧牛肉面")).firstMatch.exists)
    }

    /// 15b：按名称找用系统键盘；收银员形态结果行没有库存字样
    func testNameSearchCashierHasNoStock() {
        let app = launch(["-uiRole", "cashier", "-uiMoreGoods", "-uiManual", "name"], page: "page.manualCode")
        XCTAssertTrue(el(app, "page.manualCode").waitForExistence(timeout: 10))
        let field = el(app, "manual.query")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "系统键盘")
        field.typeText("牛奶")
        wait("出结果") { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'manual.name.'")).count >= 2 }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'manual.name.'"))
        for i in 0..<rows.count {
            XCTAssertFalse(rows.element(boundBy: i).label.contains("库存"), rows.element(boundBy: i).label)
            XCTAssertFalse(rows.element(boundBy: i).label.contains("还剩"), rows.element(boundBy: i).label)
        }
    }
}
