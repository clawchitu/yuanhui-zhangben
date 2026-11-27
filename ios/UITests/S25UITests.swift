import XCTest

/// S25 商品（11）、改商品（22）、待确认补全（22b）的界面（夹具，不连服务器；22b 用 `-uiReviewOutcome` 假通道）。
/// 对着真服务器的那几条（另一台手机用新价、服务器记的是 opening、stale）在 `S25LiveUITests`（scripts/s25-live.sh）。
@MainActor
final class S25UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(role: String = "family", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "on", "-uiReviewGoods",
                               "-uiRoute", "products"] + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        let win = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable && win.contains(e.frame)) { app.swipeUp(velocity: .slow) }
    }

    private func row(_ app: XCUIApplication, _ hex: String) -> XCUIElement {
        el(app, "products.row.5EED0000-0000-4000-8000-\(hex)")
    }

    private func chip(_ app: XCUIApplication, _ f: String) -> XCUIElement { el(app, "products.chip.\(f)") }

    /// 11：各标签的数（演示数据 6 样 + 2 样待确认）；点「快没货」只剩农夫山泉（库存 -2，写「没货了」）；「待确认」两样排在前面
    func testList11ChipsAndFilters() {
        let app = launch()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 10))
        XCTAssertTrue(chip(app, "all").waitForExistence(timeout: 5))
        XCTAssertEqual(chip(app, "all").label, "全部 8")
        XCTAssertEqual(chip(app, "needsReview").label, "待确认 2")
        XCTAssertEqual(chip(app, "lowStock").label, "快没货 1", "待确认的不算快没货（§14 S07-6）")
        XCTAssertEqual(chip(app, "noCost").label, "没进价 1")
        shot(app, "11-products")
        chip(app, "lowStock").tap()
        XCTAssertTrue(row(app, "000000000206").waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, "000000000202").exists)
        XCTAssertTrue(row(app, "000000000206").staticTexts["没货了"].exists)
        chip(app, "needsReview").tap()
        XCTAssertTrue(row(app, "0000000003A1").waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "0000000003A1").staticTexts["进价和库存没填"].exists)
        XCTAssertTrue(row(app, "0000000003A2").staticTexts["卖出时自动建的"].exists)
        // 扫码枪 / 手输条码进搜索框也能找到
        chip(app, "all").tap()
        el(app, "products.search").tap()
        el(app, "products.search").typeText("6901035600023")
        XCTAssertTrue(row(app, "000000000202").waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, "000000000204").exists)
    }

    /// 22：改卖价存好 → 列表上是新价；平均进价只读；删整箱码先确认；「不卖了」在最下面单独一行，点了先确认，停用后排到最后标「已停用」
    func testEdit22PriceDeletePackAndArchive() {
        let app = launch(extra: ["-uiProductsQuery", "青岛"])
        let beer = row(app, "000000000202")
        XCTAssertTrue(beer.waitForExistence(timeout: 10))
        beer.buttons["products.row.edit"].tap()
        XCTAssertTrue(el(app, "page.productEdit").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "edit.averageCost").label, "平均进价 4.20 元")
        shot(app, "22-edit")
        let price = app.textFields["edit.price"]
        price.tap()
        price.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "6.5")
        el(app, "edit.keyboardDone").tap()
        // 删整箱码：先确认，「不删了」什么都不动
        let pack = el(app, "edit.pack.6901035600023")
        reveal(app, pack)
        pack.buttons["edit.pack.delete"].tap()
        XCTAssertTrue(el(app, "confirm.sheet").waitForExistence(timeout: 5))
        el(app, "edit.unlink.cancel").tap()
        XCTAssertTrue(pack.waitForExistence(timeout: 5))
        let save = el(app, "edit.save")
        reveal(app, save)
        save.tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 5))
        XCTAssertTrue(beer.waitForExistence(timeout: 5))
        XCTAssertEqual(beer.descendants(matching: .any)["products.row.price"].firstMatch.label, "6.50 元")
        // 不卖了
        beer.buttons["products.row.edit"].tap()
        let archive = el(app, "edit.archive")
        reveal(app, archive)
        let saveFrame = el(app, "edit.save").frame
        XCTAssertGreaterThan(archive.frame.minY, saveFrame.maxY, "「不卖了」在「存好」下面单独一行")
        archive.tap()
        XCTAssertTrue(el(app, "confirm.sheet").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "confirm.title").label, "不卖了？")
        shot(app, "22-archive-confirm")
        el(app, "edit.archive.ok").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 5))
        XCTAssertTrue(beer.waitForExistence(timeout: 5))
        XCTAssertTrue(beer.staticTexts["已停用"].exists)
        el(app, "products.search.clear").tap()
        XCTAssertEqual(chip(app, "all").label, "全部 7")
    }

    /// 22b：进价必填；账面数变了（stale）弹「账上现在是 5 袋」，确认后存好，「待确认」数减一
    func testReview22bStaleThenDone() {
        let app = launch(extra: ["-uiReviewOutcome", "stale"])
        XCTAssertTrue(chip(app, "needsReview").waitForExistence(timeout: 10))
        XCTAssertEqual(chip(app, "needsReview").label, "待确认 2")
        let a = row(app, "0000000003A1")
        a.buttons["products.row.edit"].tap()
        XCTAssertTrue(el(app, "page.productReview").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["收银员登记的，补全后就不再提醒"].waitForExistence(timeout: 5))
        el(app, "review.save").tap()
        XCTAssertTrue(el(app, "review.error").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "review.error").label, "进价要填（真是白拿的填 0）")
        let cost = app.textFields["review.cost"]
        cost.tap()
        cost.typeText("3.2")
        el(app, "review.keyboardDone").tap()
        shot(app, "22b-review")
        el(app, "review.save").tap()
        XCTAssertTrue(el(app, "confirm.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "confirm.title").label.hasPrefix("账上现在是 5 袋"))
        shot(app, "22b-stale")
        el(app, "review.stale.ok").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 10))
        XCTAssertTrue(chip(app, "needsReview").waitForExistence(timeout: 5))
        let n = NSPredicate(format: "label == %@", "待确认 1")
        expectation(for: n, evaluatedWith: chip(app, "needsReview"))
        waitForExpectations(timeout: 5)
    }

    /// 22b 自动建的（卖价 0）：卖价框是空的，先填卖价；没网不发请求，只提示要联网
    func testReview22bAutoCreatedNeedsPriceAndNetwork() {
        let app = launch()   // 夹具没有网络服务：和没网一样
        let b = row(app, "0000000003A2")
        XCTAssertTrue(b.waitForExistence(timeout: 10))
        b.buttons["products.row.edit"].tap()
        XCTAssertTrue(el(app, "page.productReview").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "review.barcode").exists, "没有单件码的让人挂一个")
        let cost = app.textFields["review.cost"]
        cost.tap()
        cost.typeText("1")
        el(app, "review.keyboardDone").tap()
        el(app, "review.save").tap()
        XCTAssertEqual(el(app, "review.error").label, "先填卖多少钱")
        let price = app.textFields["review.price"]
        price.tap()
        price.typeText("2")
        el(app, "review.keyboardDone").tap()
        el(app, "review.save").tap()
        XCTAssertEqual(el(app, "review.error").label, "要联网才能补全，连上网再点")
        XCTAssertTrue(el(app, "page.productReview").exists, "没网留在这一页")
    }

    /// 收银员：没有商品页（入口按能力，硬塞路由也只出「用不了」）
    func testCashierHasNoProductsPage() {
        let app = launch(role: "cashier")
        XCTAssertTrue(el(app, "page.denied").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app, "page.products").exists)
    }
}
