import XCTest

/// 「待传的账」面板（PR #45，Fable 裁定 2–9、12）。要在 iPhone SE（第 3 代）和 iPhone 16 Pro 上各跑一遍；
/// 每条测试里默认字号、最大辅助字号都跑。夹具：-uiPriorSales N 先记 N 笔没传的卖出，home-unsynced 是 5 笔前天的
@MainActor
final class PendingPanelUITests: XCTestCase {
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String], ax: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiLargeText", "on"] + args + (ax ? Self.maxAX : [])
        app.launch()
        XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 15) || el(app, "page.sell").exists)
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func all(_ app: XCUIApplication, _ id: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
    }

    private func isSmall(_ app: XCUIApplication) -> Bool { app.windows.firstMatch.frame.height < 700 }

    private func ctx(_ app: XCUIApplication, _ ax: Bool) -> String {
        "\(isSmall(app) ? "SE" : "大屏") \(ax ? "最大辅助字号" : "默认字号")"
    }

    private func shot(_ app: XCUIApplication, _ state: String, ax: Bool) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(isSmall(app) ? "se" : "16pro")-pending-\(state)-\(ax ? "axmax" : "standard")"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 首页右上角看得见的那个同步状态（一行版式里有一份隐藏的占位副本）
    private func homeStatus(_ app: XCUIApplication) -> XCUIElement {
        let s = app.buttons.matching(identifier: "syncStatus").allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(s.count, 1, "首页只有一个能点的同步状态")
        return s.first ?? app.buttons["syncStatus"]
    }

    /// 元素整块在屏内（左右不出边）
    private func assertOnScreen(_ app: XCUIApplication, _ e: XCUIElement, _ what: String) {
        let w = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(e.frame.minX, w.minX - 0.5, "\(what) 左边出屏 \(e.frame)")
        XCTAssertLessThanOrEqual(e.frame.maxX, w.maxX + 0.5, "\(what) 右边出屏 \(e.frame)")
    }

    /// 首页点右上角「N 笔待传」→ 待传的账：状态句、小字、再传一次、每一行；返回回首页
    func testHomeStatusOpensPanelAndBack() {
        for ax in [false, true] {
            let app = launch(["-uiFixture", "home", "-uiPriorSales", "3"], ax: ax)
            let c = ctx(app, ax)
            let status = homeStatus(app)
            XCTAssertEqual(status.label, "3 笔待传，点开看", "\(c) 读屏标签")
            XCTAssertGreaterThanOrEqual(status.frame.height, 44 - 0.5, "\(c) 按钮够大 \(status.frame)")
            assertOnScreen(app, status, "\(c) 同步状态")
            shot(app, "home", ax: ax)
            status.tap()
            XCTAssertTrue(app.otherElements["page.pending"].waitForExistence(timeout: 5), "\(c) 进了待传的账")
            XCTAssertTrue(el(app, "pending.headline").waitForExistence(timeout: 5))
            XCTAssertEqual(el(app, "pending.headline").label, "正在传，一会儿就好", c)
            XCTAssertEqual(el(app, "pending.footnote").label, "手机会自己接着试，不用管它", c)
            XCTAssertTrue(app.buttons["pending.retry"].exists, "\(c) 有「再传一次」")
            let rows = all(app, "pending.row")
            XCTAssertEqual(rows.count, 3, "\(c) 三行")
            for r in rows {
                XCTAssertNotNil(r.label.range(of: #"^19:\d{2} 卖出 .+ · 1 件 · ¥\d+\.\d{2}$"#, options: .regularExpression),
                                "\(c) 行内容：\(r.label)")
                XCTAssertFalse(r.label.contains("…"), c)
                assertOnScreen(app, r, "\(c) 行")
            }
            XCTAssertFalse(el(app, "pending.more").exists, "\(c) 不到 20 笔没有「还有 N 笔」")
            shot(app, "panel", ax: ax)
            app.buttons["返回"].firstMatch.tap()
            XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 5), "\(c) 返回首页")
            app.terminate()
        }
    }

    /// 已同步也能点：面板写「都传上去了」，没有「再传一次」
    func testSyncedStatusOpensAllDone() {
        for ax in [false, true] {
            let app = launch(["-uiFixture", "home"], ax: ax)
            let c = ctx(app, ax)
            let status = homeStatus(app)
            XCTAssertEqual(status.label, "已同步，点开看", c)
            status.tap()
            XCTAssertTrue(el(app, "pending.done").waitForExistence(timeout: 5), c)
            XCTAssertTrue(el(app, "pending.done").label.contains("都传上去了"), c)
            XCTAssertFalse(app.buttons["pending.retry"].exists, c)
            XCTAssertEqual(all(app, "pending.row").count, 0, c)
            shot(app, "done", ax: ax)
            app.terminate()
        }
    }

    /// 25a 提醒条「N 笔待传，其中 M 笔超过一天」点了开面板；前天的写「11月17日 19:48」这样
    func testBannerOpensPanelWithOlderDates() {
        for ax in [false, true] {
            let app = launch(["-uiFixture", "home-unsynced"], ax: ax)
            let c = ctx(app, ax)
            let banner = app.buttons["home.banner.unsynced"]
            XCTAssertTrue(banner.waitForExistence(timeout: 5), c)
            XCTAssertTrue(banner.label.contains("5 笔待传，其中 5 笔超过一天"), "\(c) \(banner.label)")
            banner.tap()
            XCTAssertTrue(app.otherElements["page.pending"].waitForExistence(timeout: 5), c)
            XCTAssertTrue(el(app, "pending.headline").waitForExistence(timeout: 5), c)
            let rows = all(app, "pending.row")
            XCTAssertEqual(rows.count, 5, c)
            for r in rows { XCTAssertTrue(r.label.hasPrefix("11月17日 "), "\(c) 更早的写几月几日：\(r.label)") }
            shot(app, "banner", ax: ax)
            app.terminate()
        }
    }

    /// 超过 20 笔：只列 20 行，底下「还有 N 笔，传上去以后能在记的账里看」（滚到底看得到）
    func testMoreThanTwentyRows() {
        for ax in [false, true] {
            let app = launch(["-uiFixture", "home", "-uiPriorSales", "23"], ax: ax)
            let c = ctx(app, ax)
            XCTAssertEqual(homeStatus(app).label, "23 笔待传，点开看", c)
            homeStatus(app).tap()
            XCTAssertTrue(el(app, "pending.headline").waitForExistence(timeout: 5), c)
            XCTAssertEqual(all(app, "pending.row").count, 20, "\(c) 最多 20 行")
            let more = el(app, "pending.more")
            XCTAssertEqual(more.label, "还有 3 笔，传上去以后能在记的账里看", c)
            var n = 0
            while !more.isHittable && n < 15 { app.scrollViews.firstMatch.swipeUp(); n += 1 }
            XCTAssertTrue(more.isHittable, "\(c) 滚到底看得到「还有 N 笔」")
            assertOnScreen(app, more, "\(c) 还有 N 笔")
            shot(app, "more", ax: ax)
            app.terminate()
        }
    }

    /// 登录过期：状态句带笔数，没有小字和「再传一次」；没网：有「再传一次」，点了变灰写「正在传…」，过一会儿恢复
    func testReasonsAndRetry() {
        for ax in [false, true] {
            var app = launch(["-uiFixture", "home", "-uiPriorSales", "2", "-uiPendingReason", "unauthorized", "-uiRoute", "pending"], ax: ax)
            let c = ctx(app, ax)
            XCTAssertTrue(el(app, "pending.headline").waitForExistence(timeout: 5), c)
            XCTAssertEqual(el(app, "pending.headline").label, "登录过期了，这 2 笔先传不了。重新登录后会自动传，账不会丢", c)
            XCTAssertFalse(el(app, "pending.footnote").exists, c)
            XCTAssertFalse(app.buttons["pending.retry"].exists, "\(c) 登录过期时隐藏「再传一次」")
            shot(app, "unauthorized", ax: ax)
            app.terminate()

            app = launch(["-uiFixture", "home", "-uiPriorSales", "2", "-uiPendingReason", "offline", "-uiRoute", "pending"], ax: ax)
            XCTAssertTrue(el(app, "pending.headline").waitForExistence(timeout: 5), c)
            XCTAssertEqual(el(app, "pending.headline").label, "没网。联网后会自动传，账不会丢", c)
            let retry = app.buttons["pending.retry"]
            XCTAssertTrue(retry.isHittable, "\(c) 没网照样能点")
            XCTAssertGreaterThanOrEqual(retry.frame.height, 60, c)
            assertOnScreen(app, retry, "\(c) 再传一次")
            XCTAssertTrue(retry.label.contains("再传一次"), c)
            retry.tap()
            XCTAssertTrue(retry.label.contains("正在传…"), "\(c) 点后写「正在传…」：\(retry.label)")
            XCTAssertFalse(retry.isEnabled, "\(c) 点后变灰")
            shot(app, "retrying", ax: ax)
            let back = NSPredicate(format: "label CONTAINS '再传一次' AND enabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: back, evaluatedWith: retry)], timeout: 5), .completed, "\(c) 传完恢复")
            app.terminate()
        }
    }

    /// 只有首页的状态能点：卖出页顶栏的「N 笔待传」只是字（在扫码，不让误触跳走）
    func testSellPageStatusIsNotTappable() {
        let app = launch(["-uiFixture", "home", "-uiPriorSales", "2", "-uiRoute", "sell"], ax: false)
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 10))
        let status = all(app, "syncStatus").filter(\.isHittable)
        XCTAssertEqual(status.count, 1)
        XCTAssertTrue(status.first?.label.contains("2 笔待传") == true, "\(status.map(\.label))")
        XCTAssertNotEqual(status.first?.elementType, .button, "卖出页的同步状态不是按钮")
        XCTAssertFalse(app.buttons["syncStatus"].exists, "卖出页没有能点的同步状态")
    }
}
