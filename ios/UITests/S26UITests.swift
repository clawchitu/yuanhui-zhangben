import XCTest

/// S26 盘点（plan-v2 §8 S26 验收，夹具 `-uiCountGoods`：稿子 12a / 12b 的货，红牛账上 2 罐；演示数据另外五样本月数过了）。
/// 交账走假通道 `-uiCountOutcome applied|stale|offline`；对着本机服务器的那几条（账面 2 填 1 → 服务器记盘亏 1、
/// 提交前先传完本机 outbox、另一台手机同时卖出 → stale、没扫的商品不变）在 `S26LiveUITests`（scripts/s26-live.sh）。
@MainActor
final class S26UITests: XCTestCase {
    static let redBull = "6920202888883"

    override func setUpWithError() throws { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(outcome: String = "applied", scan: String? = redBull, route: String? = "count", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", "family", "-uiLargeText", "off", "-uiCountGoods",
                               "-uiCountOutcome", outcome, "-uiCamera", "authorized"]
            + (route.map { ["-uiRoute", $0] } ?? []) + (scan.map { ["-uiScan", $0] } ?? []) + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func press(_ app: XCUIApplication, _ digits: String) {
        for d in digits { el(app, "page.count").buttons[String(d)].tap() }
    }

    private func waitLabel(_ e: XCUIElement, contains s: String, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !(e.exists && e.label.contains(s)) { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(e.exists && e.label.contains(s), "\(e.exists ? e.label : "不存在") 不含 \(s)")
    }

    /// 扫码 → 显示账上数（红牛 2 罐）→ 填 1 → 黄条「比账上少 1 罐」→ 存好 → 回到扫码、进度 +1。键盘没有小数点
    func testScanShowsBookFillCountSavesNext() {
        let app = launch()
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "count.book").label, "2")
        XCTAssertTrue(el(app, "count.name").label.contains("红牛 250ml"))
        XCTAssertEqual(el(app, "count.prompt").label, "货架上实际数了几罐")
        XCTAssertEqual(el(app, "count.done").label, "已经数了 5 种")
        XCTAssertEqual(el(app, "count.left").label, "还有 6 种")
        // 键盘：0–9 和删除，没有小数点
        let keypad = el(app, "page.count")
        for d in 0...9 { XCTAssertTrue(keypad.buttons["\(d)"].exists, "\(d)") }
        XCTAssertTrue(keypad.buttons["删除"].exists)
        XCTAssertFalse(keypad.buttons["点"].exists, "键盘无小数点")
        XCTAssertFalse(el(app, "count.save").isEnabled, "没填数不能存")
        press(app, "1")
        XCTAssertEqual(el(app, "count.input").value as? String, "1")
        XCTAssertTrue(el(app, "count.hint").label.contains("比账上少 1 罐，存好后按实际算"))
        shot(app, "12a")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "「红牛 250ml」存好了")
        XCTAssertTrue(el(app, "count.empty").waitForExistence(timeout: 5), "回到扫下一个")
        waitLabel(el(app, "count.done"), contains: "已经数了 6 种")
        XCTAssertEqual(el(app, "count.left").label, "还有 5 种")
        shot(app, "12a-next")
    }

    /// 「没错」：数的和账上一样，也记一条，进度 +1
    func testSameAsBookCountsToo() {
        let app = launch()
        XCTAssertTrue(el(app, "count.same").waitForExistence(timeout: 10))
        el(app, "count.same").tap()
        waitLabel(el(app, "count.done"), contains: "已经数了 6 种")
    }

    /// 另一台手机这期间卖了一个：「账上现在是 1 罐，你数的还对吗」→「对，就是 1 罐」→ 存好
    func testOtherPhoneSoldAsksAndConfirm() {
        let app = launch(outcome: "stale")
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        press(app, "1")
        el(app, "count.save").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.label, "账上现在是 1 罐，你数的还对吗")
        shot(app, "12a-stale")
        alert.buttons["对，就是 1 罐"].tap()
        waitLabel(el(app, "count.notice"), contains: "存好了")
        waitLabel(el(app, "count.done"), contains: "已经数了 6 种")
    }

    /// stale 后「再数一下」：账上的数换成现在的（1），黄条跟着变，再改再存
    func testStaleRecountShowsNewBook() {
        let app = launch(outcome: "stale")
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        press(app, "3")
        el(app, "count.save").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["再数一下"].tap()
        XCTAssertEqual(el(app, "count.book").label, "1")
        XCTAssertTrue(el(app, "count.hint").label.contains("比账上多 2 罐"))
        el(app, "page.count").buttons["删除"].tap()
        press(app, "1")
        XCTAssertFalse(el(app, "count.hint").exists, "和账上一样不出黄条")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "存好了")
    }

    /// 交到一半没连上（服务器其实记上了）：再点「存好」原样重交同一个 op，拿回「存好了」，不会把自己刚交的当成别的手机的账来问
    func testLostReplyResubmitsSameOp() {
        let app = launch(outcome: "lost")
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        press(app, "1")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "要联网才能盘点，没存上")
        XCTAssertTrue(el(app, "count.card").exists, "没存上，卡还在、数还在")
        XCTAssertEqual(el(app, "count.input").value as? String, "1")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "「红牛 250ml」存好了")
        XCTAssertFalse(app.alerts.firstMatch.exists, "原 op 重交，不问「账上现在是」")
    }

    /// 「正在存」的时候按返回不离开：等结果出来，账上变了的问句照样弹出来（不会人走了、以为存了）
    func testBackWhileSubmittingStaysForAnswer() {
        let app = launch(outcome: "slowStale")
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        press(app, "1")
        el(app, "count.save").tap()
        app.buttons["返回"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertEqual(alert.label, "账上现在是 1 罐，你数的还对吗")
        alert.buttons["对，就是 1 罐"].tap()
        waitLabel(el(app, "count.notice"), contains: "存好了")
    }

    /// 交的时候 epoch 对不上（不是被踢）：提示没存上，卡和数都还在
    func testEpochMismatchSaysNotSaved() {
        let app = launch(outcome: "epoch")
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 10))
        press(app, "1")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "没存上")
        XCTAssertTrue(el(app, "count.card").exists)
        XCTAssertEqual(el(app, "count.input").value as? String, "1")
    }

    /// 必须联网：没网时整页「要联网才能盘点」，扫码不出商品卡
    func testOfflineNeedsNetwork() {
        let app = launch(outcome: "offline")
        XCTAssertTrue(el(app, "count.offline").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "count.offline").label, "要联网才能盘点")
        XCTAssertTrue(el(app, "count.retry").exists)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(el(app, "count.card").exists, "没网不让数")
        XCTAssertTrue(app.staticTexts["没网"].exists, "顶栏写没网")
        shot(app, "12-offline")
    }

    /// 12b：列出没数的（6 种，含账上 9 瓶的二锅头），「去数」直接填；「先到这里，结束盘点」离开
    func testList12bGoCount() {
        let app = launch(scan: nil)
        XCTAssertTrue(el(app, "count.left").waitForExistence(timeout: 10))
        el(app, "count.left").tap()
        XCTAssertTrue(el(app, "page.countList").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "countList.title").label, "还有 6 种没数")
        let rows = (0..<6).map { el(app, "countList.\($0)").label }
        XCTAssertTrue(rows.contains { $0.contains("牛栏山二锅头 500ml") && $0.contains("账上 9 瓶") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0.contains("维达抽纸 3 包装") && $0.contains("账上 15 提") })
        XCTAssertFalse(rows.contains { $0.contains("青岛啤酒") }, "本月数过的不列")
        shot(app, "12b")
        let i = rows.firstIndex { $0.contains("旺仔牛奶") }!
        el(app, "countList.\(i).go").tap()
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "count.name").label.contains("旺仔牛奶 245ml"))
        XCTAssertEqual(el(app, "count.book").label, "11")
        press(app, "11")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.left"), contains: "还有 5 种")
        // 返回（等扫码时）→ 12b → 结束盘点
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.countList").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "countList.title").label, "还有 5 种没数")
        el(app, "countList.finish").tap()
        XCTAssertTrue(el(app, "page.count").waitForNonExistence(timeout: 5))
    }

    /// 设置页「盘点」右边「11月 数了 5 种」从库里算；点进去是盘点页
    func testSettingsSummaryAndEntry() {
        let app = launch(scan: nil, route: "settings")
        let row = el(app, "settings.item.count")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("11月 数了 5 种"), row.label)
        row.tap()
        XCTAssertTrue(el(app, "count.empty").waitForExistence(timeout: 10))
    }
}
