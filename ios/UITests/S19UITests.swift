import XCTest

/// S19 进货（06a / 06b / 06c）的界面验收。码由 Debug 的 FakeScanner 喂进扫码层，outbox 里的进货 op 读调试探针
/// `debug.ledger`（`stockIns / lastPackCount / lastPackQty / lastUnitCost / lastExpiry / lastStock`）。
@MainActor
final class S19UITests: XCTestCase {
    static let colaPack = "6925303770020", carton = "6901028075879", beerPack = "6901035600023"
    static let erguotou = "6901234500011", newCode = "6924743919211"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String], page: String = "page.stockIn") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe", "-uiRoute", "stockIn"] + extra
        app.launch()
        XCTAssertTrue(el(app, page).waitForExistence(timeout: 15), page)
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

    private func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    /// 06a：可乐整箱码 5 箱 × ¥48 → 一共 ¥240.00 / 入账 120 罐，每罐 ¥2.00；数量键盘没有小数点；记进货后 outbox 带件数和每箱单价
    func testColaCase() {
        let app = launch(["-uiScan", Self.colaPack])
        XCTAssertTrue(el(app, "stockIn.qty").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "stockIn.badge").label, "整箱码　1 箱 = 24 罐")
        XCTAssertFalse(app.buttons["点"].exists, "数量键盘没有小数点")
        keys(app, "5")
        el(app, "stockIn.cost").tap()
        XCTAssertTrue(app.buttons["点"].waitForExistence(timeout: 3), "单价键盘有小数点")
        keys(app, "48")
        XCTAssertEqual(el(app, "stockIn.total").label, "¥240.00")
        XCTAssertEqual(el(app, "stockIn.entryLine").label, "入账 120 罐，每罐进价 ¥2.00")
        XCTAssertTrue(el(app, "stockIn.commit").isHittable, "记进货固定在底部可见")
        el(app, "stockIn.commit").tap()
        wait("记上一笔进货") { ledger(app)["stockIns"] == "1" }
        let l = ledger(app)
        XCTAssertEqual(l["lastPackCount"], "5")
        XCTAssertEqual(l["lastPackQty"], "24")
        XCTAssertEqual(l["lastUnitCost"], "4800")
        XCTAssertEqual(l["lastStock"], "150")
        XCTAssertTrue(el(app, "stockIn.empty").waitForExistence(timeout: 3), "记好后回到扫码")
    }

    /// 5 条 × ¥400、原有 6 包 → 临时库存 56 包；标签随单位变（每条）
    func testCartonTempStock() {
        let app = launch(["-uiScan", Self.carton, "-uiStockQty", "5", "-uiStockCost", "400", "-uiStockCommit"])
        wait("记上一笔进货") { ledger(app)["stockIns"] == "1" }
        let l = ledger(app)
        XCTAssertEqual(l["lastStock"], "56")
        XCTAssertEqual(l["lastPackCount"], "5")
        XCTAssertEqual(l["lastUnitCost"], "40000")
        let app2 = launch(["-uiScan", Self.erguotou])
        XCTAssertTrue(app2.staticTexts["每瓶多少钱"].waitForExistence(timeout: 10))
        XCTAssertTrue(app2.staticTexts["进了几瓶"].exists)
    }

    /// 06b / 06c：生产日期 2026-11-12 + 6 个月 = 2027-05-12；年月日自家键盘、填满跳格，填日期时按钮是「填好了」；两种填法可切换
    func testExpiryProducedDate() {
        let app = launch(["-uiScan", Self.beerPack, "-uiStockQty", "3", "-uiStockCost", "55", "-uiStockMonths", "6",
                          "-uiStockField", "none"])
        XCTAssertTrue(el(app, "stockIn.modeProduced").waitForExistence(timeout: 10), "管保质期：有到期日区")
        el(app, "stockIn.month").tap()
        XCTAssertTrue(el(app, "stockIn.doneEditing").waitForExistence(timeout: 3), "填日期时是「填好了」")
        XCTAssertFalse(app.buttons["点"].exists, "日期键盘没有小数点")
        keys(app, "11")
        keys(app, "12")
        XCTAssertEqual(el(app, "stockIn.day").value as? String, "12", "月填满两位自动跳到日")
        el(app, "stockIn.doneEditing").tap()
        XCTAssertEqual(el(app, "stockIn.computed").label, "2027-05-12")
        el(app, "stockIn.modeDirect").tap()
        XCTAssertFalse(el(app, "stockIn.computed").exists, "直接填到期日：没有「算出来到期」")
        el(app, "stockIn.modeProduced").tap()
        el(app, "stockIn.commit").tap()
        wait("记上一笔进货") { ledger(app)["stockIns"] == "1" }
        XCTAssertEqual(ledger(app)["lastExpiry"], "2027-05-12")
    }

    /// 进价填 0：要再确认一次
    func testZeroCostAsks() {
        let app = launch(["-uiScan", Self.erguotou, "-uiStockQty", "2", "-uiStockCost", "0"])
        XCTAssertTrue(el(app, "stockIn.commit").waitForExistence(timeout: 10))
        el(app, "stockIn.commit").tap()
        XCTAssertTrue(app.alerts["进价是 0 元，确定吗？"].waitForExistence(timeout: 3))
        XCTAssertEqual(ledger(app)["stockIns"], "0")
        app.alerts.buttons["确定，是 0 元"].tap()
        wait("确认后记上") { ledger(app)["stockIns"] == "1" }
        XCTAssertEqual(ledger(app)["lastUnitCost"], "0")
    }

    /// 进货中遇到新商品：进 04a，没有「存好，接着卖 / 接着进货」，必须走完 04b
    func testNewProductMustCompleteStep2() {
        let app = launch(["-uiScan", Self.newCode], page: "page.newProduct")
        XCTAssertFalse(el(app, "newProduct.save").exists)
        XCTAssertTrue(el(app, "newProduct.more").exists)
    }

    /// 收银员不能进货：硬塞路由也只出「用不了」
    func testCashierDenied() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", "cashier", "-uiRoute", "stockIn"]
        app.launch()
        XCTAssertTrue(el(app, "page.denied").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "page.stockIn").exists)
    }
}
