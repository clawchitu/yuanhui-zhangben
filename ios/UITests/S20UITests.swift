import XCTest

/// S20 记的账与撤销的界面验收（夹具 `-uiRecords` 装的是稿子 07a / 07b / 07c 的账，时间固定在 2026-11-19 19:48）。
@MainActor
final class S20UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String], page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiLargeText", "on"] + args
        app.launch()
        XCTAssertTrue(el(app, page).waitForExistence(timeout: 15), page)
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func card(_ app: XCUIApplication, _ i: Int) -> XCUIElement { el(app, "records.card.\(i)") }

    /// 家用：首页「刚记的」整条可点进 07a（没有提醒条），整笔撤：划线仍可见、「已撤销」、撤销按钮没了，首页刚记的换成下一笔
    func testFamilyUndoWholeSaleFromHomeRecent() {
        let app = launch(["-uiFixture", "home", "-uiRecords"], page: "page.home")
        XCTAssertFalse(el(app, "home.banner.unsynced").exists, "没有提醒条")
        let recent = el(app, "home.records")
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.label.contains("19:32"), recent.label)
        recent.tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 5))
        XCTAssertTrue(card(app, 2).waitForExistence(timeout: 5), "07a 今天三张卡")
        XCTAssertTrue(card(app, 2).staticTexts["爸爸的手机"].exists, "卡片上是手机名")
        card(app, 0).buttons["records.undo"].tap()
        XCTAssertTrue(el(app, "undo.sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这笔抹了 ¥0.50，撤一样按比例退"].exists)
        XCTAssertTrue(el(app, "undo.refund.1").label.contains("退 ¥23.78"), el(app, "undo.refund.1").label)
        el(app, "undo.all").tap()
        XCTAssertTrue(card(app, 0).descendants(matching: .any)["records.voided"].waitForExistence(timeout: 5), "原流水划线仍可见")
        XCTAssertFalse(card(app, 0).buttons["records.undo"].exists, "撤过的没有撤销按钮，撤不了第二次")
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(el(app, "home.records").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "home.records").label.contains("18:55"), "刚记的换成下一笔：\(el(app, "home.records").label)")
    }

    /// 「只撤这样」：08 里撤青岛啤酒一行，卡上只有那一行划线，再开 08 只剩两行
    func testUndoOneLine() {
        let app = launch(["-uiFixture", "home", "-uiRecords", "-uiRoute", "records"], page: "page.records")
        card(app, 0).buttons["records.undo"].tap()
        XCTAssertTrue(el(app, "undo.line.1").waitForExistence(timeout: 5))
        el(app, "undo.line.1").tap()
        XCTAssertTrue(el(app, "records.notice").waitForExistence(timeout: 5))
        XCTAssertFalse(card(app, 0).descendants(matching: .any)["records.voided"].exists, "整张卡还没撤完")
        card(app, 0).buttons["records.undo"].tap()
        XCTAssertTrue(el(app, "undo.line.1").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "undo.line.2").exists, "只剩两行")
        XCTAssertTrue(el(app, "undo.refund.1").label.contains("退 ¥4.46"), el(app, "undo.refund.1").label)
        el(app, "undo.cancel").tap()
        XCTAssertFalse(el(app, "undo.sheet").waitForExistence(timeout: 1))
    }

    /// 收银员 07b：只有本机今天的卖出，没有日期切换，撤过的那笔没有撤销按钮
    func testCashierRecords() {
        let app = launch(["-uiFixture", "home", "-uiRole", "cashier", "-uiRecords"], page: "page.home")
        el(app, "home.records").tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 5))
        XCTAssertTrue(card(app, 2).waitForExistence(timeout: 5))
        XCTAssertFalse(card(app, 3).exists, "昨天的不列")
        XCTAssertFalse(el(app, "records.tab.yesterday").exists, "没有日期切换")
        XCTAssertFalse(el(app, "records.device").exists, "收银员卡片不写手机名")
        XCTAssertTrue(card(app, 2).descendants(matching: .any)["records.voided"].exists)
        XCTAssertFalse(card(app, 2).buttons["records.undo"].exists)
        XCTAssertTrue(card(app, 1).buttons["records.undo"].exists)
    }

    /// 07c：更早每天一行、点开那天能撤；「再往前 7 天」之后到本地的头了
    func testEarlierDays() {
        let app = launch(["-uiFixture", "home", "-uiRecords", "-uiRoute", "records"], page: "page.records")
        el(app, "records.tab.earlier").tap()
        XCTAssertTrue(el(app, "records.day.6").waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "records.day.7").exists, "一次 7 天")
        XCTAssertTrue(el(app, "records.day.0").label.contains("11月17日"), el(app, "records.day.0").label)
        el(app, "records.more").tap()
        XCTAssertTrue(el(app, "records.day.8").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "records.offlineLimit").exists, "离线只到本地 35 天")
        el(app, "records.day.0").tap()
        XCTAssertTrue(card(app, 0).buttons["records.undo"].waitForExistence(timeout: 5), "前几天的也能撤")
    }

    /// 还没有任何流水、首页没有「刚记的」条：从看账页进记的账（§14 S15-6）
    func testNoRecordsReachRecordsFromReports() {
        let app = launch(["-uiFixture", "home", "-uiRecords", "none"], page: "page.home")
        XCTAssertFalse(el(app, "home.recent").exists, "没有流水，条不显示")
        el(app, "home.reports").tap()
        XCTAssertTrue(el(app, "reports.records").waitForExistence(timeout: 5))
        el(app, "reports.records").tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "records.empty").exists)
    }

    /// 最大辅助字号：08 的「整笔都撤销」「不撤了」都能点到
    func testUndoSheetAtMaxAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiLargeText", "off", "-uiFixture", "home", "-uiRecords", "-uiRoute", "undoLast",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(el(app, "undo.sheet").waitForExistence(timeout: 15))
        for _ in 0..<6 where !el(app, "undo.cancel").isHittable { el(app, "undo.sheet").swipeUp() }
        XCTAssertTrue(el(app, "undo.all").exists)
        XCTAssertTrue(el(app, "undo.cancel").isHittable)
    }
}
