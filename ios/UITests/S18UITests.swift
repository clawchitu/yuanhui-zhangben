import XCTest

/// S18 新商品登记（04a / 04b / 04c / 25e）和整件码（05）的界面验收。码由 Debug 的 FakeScanner 喂进扫码层，
/// 本地库的情况读调试探针 `debug.ledger`（`upserts / quickUpserts / links / openings`、最后一笔的 `lastBase`）。
@MainActor
final class S18UITests: XCTestCase {
    static let newCode = "6924743919211", cashierCode = "6920152400319", offlineCode = "6901028075831"
    static let cola = "6925303770013", packCode = "6925303770099"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String], page: String = "page.newProduct") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe", "-uiRoute", "sell"] + extra
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

    /// 自家键盘上按这几个键（「.」是「点」）
    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    /// 卖出中扫到新码 → 04a，填卖价后「存好，接着卖」回到卖出且该商品已在篮里；两步都是红色标题栏（截图另证）
    func testScanNewCodeRegisterAndBackInBasket() {
        let app = launch(["-uiScan", Self.newCode])
        wait("查到名称") { (el(app, "newProduct.name").value as? String) == "乐事薯片 原味 70g" }
        XCTAssertFalse(app.buttons["newProduct.save"].isEnabled, "卖价没填不能存")
        keys(app, "7.5")
        XCTAssertEqual(el(app, "newProduct.price").label, "卖价 7.5 元")
        app.buttons["newProduct.save"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        wait("篮里一件") { el(app, "sell.itemCount").label == "一共 1 件" }
        XCTAssertEqual(el(app, "sell.total").label, "7.50 元")
        let l = ledger(app)
        XCTAssertEqual(l["upserts"], "1")
        XCTAssertEqual(l["quickUpserts"], "0")
        XCTAssertEqual(l["openings"], "0")
    }

    /// 「再填进价和库存」进 04b：填了库存没填进价出现黄字；打开「要管保质期」才出现到期日和提前天数；「不知道，先不填」可用
    func testSecondStepWarningAndExpiry() {
        let app = launch(["-uiScan", Self.newCode])
        keys(app, "7.5")
        app.buttons["newProduct.more"].tap()
        XCTAssertTrue(el(app, "page.newProduct2").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "newProduct.costWarning").exists)
        let qty = app.textFields["newProduct.qty"]
        qty.tap()
        qty.typeText("12")
        XCTAssertTrue(el(app, "newProduct.costWarning").waitForExistence(timeout: 3), "填了库存没填进价出现黄字提醒")
        XCTAssertFalse(app.textFields["newProduct.year"].exists, "没打开开关不出到期日")
        XCTAssertFalse(app.staticTexts["提前几天提醒"].exists, "没打开开关不出提前天数")
        app.buttons["newProduct.keyboardDone"].tap()   // 收起系统数字键盘（它会盖住下面的开关）
        let toggle = app.switches["newProduct.trackExpiry"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["newProduct.year"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["newProduct.day"].exists)
        XCTAssertTrue(app.staticTexts["提前几天提醒"].exists)
        app.buttons["newProduct.expiryUnknown"].tap()
        XCTAssertTrue(el(app, "newProduct.expiryUnknownNote").waitForExistence(timeout: 3))
        app.buttons["newProduct.saveMore"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        wait("登记和期初都进了 outbox") { ledger(app)["openings"] == "1" && ledger(app)["upserts"] == "1" }
        wait("篮里一件") { el(app, "sell.itemCount").label == "一共 1 件" }
    }

    /// 04a 的「这是整箱、整条的码」进 05，关联后按 24 个算：记账后这一笔库存变动 = 1 罐 + 24 罐
    func testLinkPackCountsAs24() {
        let app = launch(["-uiScan", "\(Self.cola),\(Self.packCode)", "-uiHoldDone"])
        app.buttons["newProduct.pack"].tap()
        XCTAssertTrue(el(app, "page.linkPack").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "linkPack.productName").label, "可口可乐 330ml", "默认是价签里那一样")
        XCTAssertFalse(app.buttons["linkPack.save"].isEnabled)
        keys(app, "24")
        XCTAssertEqual(el(app, "linkPack.hint").label, "以后扫这个码，进货卖出都按 24 罐 可口可乐 330ml 算")
        XCTAssertEqual(el(app, "linkPack.derived").label, "不填整箱价，就按 24 × ¥3.00 = ¥72.00 卖")
        app.buttons["linkPack.save"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        wait("两行") { el(app, "sell.itemCount").label == "一共 2 件" }
        XCTAssertEqual(el(app, "sell.total").label, "75.00 元", "¥3.00 + 整箱 24 × ¥3.00")
        app.buttons["sell.commit"].tap()
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 5))
        wait("记账") { ledger(app)["batches"] == "1" }
        let l = ledger(app)
        XCTAssertEqual(l["lastBase"], "-25", "1 罐 + 1 箱（24 罐）")
        XCTAssertEqual(l["links"], "1")
        XCTAssertEqual(l["lastPaid"], "7500")
    }

    /// 收银员只有 04c：存好后提示「已记下，回头让家里人补全」，产生的是 quick 的 product_upsert
    func testCashierQuickRegistration() {
        let app = launch(["-uiRole", "cashier", "-uiScan", Self.cashierCode])
        XCTAssertFalse(el(app, "newProduct.more").exists, "收银员没有第二步")
        XCTAssertFalse(el(app, "newProduct.pack").exists, "收银员不能挂整件码")
        let name = el(app, "newProduct.name")
        name.tap()
        name.typeText("白象 老母鸡汤面\n")
        el(app, "newProduct.price").tap()
        keys(app, "4.5")
        app.buttons["newProduct.save"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "sell.notice").waitForExistence(timeout: 3))
        XCTAssertTrue(el(app, "sell.notice").label.contains("已记下，回头让家里人补全"))
        let l = ledger(app)
        XCTAssertEqual(l["quickUpserts"], "1")
        XCTAssertEqual(l["upserts"], "1")
    }

    /// 25e 断网：名称为空也能登记并卖出
    func testOfflineEmptyNameRegistersAndSells() {
        let app = launch(["-uiOffline", "-uiScan", Self.offlineCode, "-uiHoldDone"])
        XCTAssertTrue(el(app, "newProduct.offline").waitForExistence(timeout: 3))
        XCTAssertEqual(el(app, "syncStatus").label, "没网")
        keys(app, "3")
        app.buttons["newProduct.save"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        wait("篮里一件") { el(app, "sell.itemCount").label == "一共 1 件" }
        app.buttons["sell.commit"].tap()
        wait("记账") { ledger(app)["batches"] == "1" }
        let l = ledger(app)
        XCTAssertTrue(l["lastQty"]?.hasPrefix("没写名称 …5831:1") ?? false, l["lastQty"] ?? "")
        XCTAssertEqual(l["lastPaid"], "300")
    }

    /// 返回不登记：篮子不变，页面照常收码
    func testBackWithoutSavingAddsNothing() {
        let app = launch(["-uiScan", Self.newCode])
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "sell.empty").exists)
        XCTAssertEqual(ledger(app)["upserts"], "0")
    }
}
