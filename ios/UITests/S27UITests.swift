import XCTest

/// S27 保质期（plan-v2 §8 S27 验收，夹具 `-uiExpiry`：稿子 19 的四批，今天 = 稿子上的 11/19）。
/// 对着本机服务器的那几条（扔掉后月报过期损耗增加、赚了不变；另一台手机已经处理过 → 提示并刷新）在 `S27LiveUITests`（scripts/s27-live.sh）。
@MainActor
final class S27UITests: XCTestCase {
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws { continueAfterFailure = false }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(role: String = "family", route: String? = "expiry", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "off", "-uiExpiry"]
            + (route.map { ["-uiRoute", $0] } ?? []) + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        let win = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable && win.contains(e.frame)) { app.swipeUp(velocity: .slow) }
    }

    private func openPanel(_ app: XCUIApplication, _ row: String) {
        let b = el(app, row + ".handle")
        XCTAssertTrue(b.waitForExistence(timeout: 10), row)
        reveal(app, b)
        b.tap()
        XCTAssertTrue(el(app, "expiry.panel.title").waitForExistence(timeout: 5))
    }

    /// 面板上几个选择从上到下的顺序
    private func order(_ app: XCUIApplication) -> [String] {
        ["soldOut", "discard", "return", "snooze"]
            .map { ($0, el(app, "expiry.choice.\($0)").frame.minY) }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: 19

    /// 首页黄条「有 3 样快过期了」（按商品合并、来自本地库）→ 19：已过期 1 样 / 快过期 2 样 / 过几天再提醒的
    func testHomeBannerOpensList19() {
        let app = launch(route: nil)
        let banner = el(app, "home.banner.expiring")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains("有 3 样快过期了"), banner.label)
        banner.tap()
        XCTAssertTrue(el(app, "page.expiry").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "expiry.expired.header").label, "已过期, 1 样")
        XCTAssertEqual(el(app, "expiry.soon.header").label, "快过期, 2 样")
        let e0 = el(app, "expiry.expired.0").label, s0 = el(app, "expiry.soon.0").label, s1 = el(app, "expiry.soon.1").label
        XCTAssertTrue(e0.contains("光明 新鲜牧场 950ml") && e0.contains("11月17日到期") && e0.contains("过了 2 天 · 账上约 2 盒"), e0)
        XCTAssertTrue(s0.contains("桃李 醇熟切片面包") && s0.contains("还有 2 天 · 账上约 4 袋"), s0)
        XCTAssertTrue(s1.contains("伊利纯牛奶 250ml") && s1.contains("11月24日到期") && s1.contains("还有 5 天"), s1)
        shot(app, "19")
        let z = el(app, "expiry.snoozed.0")
        reveal(app, z)
        XCTAssertTrue(z.label.contains("达利园 法式软面包") && z.label.contains("11月22日再提醒"), z.label)
        XCTAssertFalse(el(app, "expiry.snoozed.0.handle").exists, "过几天再提醒的不在这里处理")
        XCTAssertFalse(el(app, "expiry.soon.2").exists, "演示数据自带的三批已清零，不列")
    }

    // MARK: 20 / 20b

    /// 20：已过期 → 先问实际数（默认账上的 2），突出「下架扔掉」（算亏 ¥19.60）；「先不处理」关面板、清单不变
    func testExpiredPanel20DefaultsToDiscard() {
        let app = launch()
        openPanel(app, "expiry.expired.0")
        XCTAssertEqual(el(app, "expiry.qty").value as? String, "2")
        XCTAssertTrue(el(app, "expiry.panel.days").label.contains("11月17日到期，已经过了 2 天"))
        XCTAssertEqual(el(app, "expiry.panel.book").label, "账上约 2 盒")
        XCTAssertEqual(order(app), ["soldOut", "discard", "return", "snooze"], "照稿子 20 的顺序，突出扔掉")
        XCTAssertEqual(el(app, "expiry.choice.discard").value as? String, "突出")
        XCTAssertTrue(el(app, "expiry.choice.discard").label.contains("扣 2 盒库存，算亏 ¥19.60"), el(app, "expiry.choice.discard").label)
        XCTAssertTrue(el(app, "expiry.choice.return").label.contains("扣 2 盒库存，不算亏"))
        XCTAssertTrue(el(app, "expiry.choice.soldOut").label.contains("这批不再提醒"))
        shot(app, "20")
        el(app, "expiry.later").tap()
        XCTAssertTrue(el(app, "expiry.panel.title").waitForNonExistence(timeout: 5))
        XCTAssertTrue(el(app, "expiry.expired.0").exists, "先不处理：清单不变")
    }

    /// 20b：没过期 → 突出「还在卖，过几天再提醒」（3 天后，11月22日）；扔掉算亏 ¥6.87
    func testSoonPanel20bDefaultsToSnooze() {
        let app = launch()
        openPanel(app, "expiry.soon.1")
        XCTAssertEqual(el(app, "expiry.panel.title").label, "伊利纯牛奶 250ml")
        XCTAssertEqual(el(app, "expiry.qty").value as? String, "3")
        XCTAssertEqual(order(app), ["snooze", "soldOut", "return", "discard"])
        XCTAssertEqual(el(app, "expiry.choice.snooze").value as? String, "突出")
        XCTAssertTrue(el(app, "expiry.choice.snooze").label.contains("3 天后再提醒（11月22日）"), el(app, "expiry.choice.snooze").label)
        XCTAssertTrue(el(app, "expiry.choice.discard").label.contains("算亏 ¥6.87"))
        shot(app, "20b")
    }

    /// 实际数减到 0：突出「卖完了」，扔掉、退货置灰点不了
    func testZeroQtyHighlightsSoldOut() {
        let app = launch()
        openPanel(app, "expiry.expired.0")
        let q = el(app, "expiry.qty")
        for _ in 0..<2 { q.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap() }
        XCTAssertEqual(q.value as? String, "0")
                XCTAssertEqual(el(app, "expiry.choice.soldOut").value as? String, "突出")
        XCTAssertFalse(el(app, "expiry.choice.discard").isEnabled)
        XCTAssertFalse(el(app, "expiry.choice.return").isEnabled)
        XCTAssertTrue(el(app, "expiry.choice.snooze").isEnabled)
        shot(app, "20-zero")
        el(app, "expiry.choice.discard").tap()
        XCTAssertTrue(el(app, "expiry.panel.title").exists, "置灰的点了没反应")
    }

    /// 扔掉：这批从清单消失，回首页黄条少一样（3 → 2）
    func testDiscardRemovesRowAndHomeBannerDropsOne() {
        let app = launch(route: nil)
        el(app, "home.banner.expiring").tap()
        openPanel(app, "expiry.expired.0")
        el(app, "expiry.choice.discard").tap()
        XCTAssertTrue(el(app, "expiry.panel.title").waitForNonExistence(timeout: 5))
        XCTAssertFalse(el(app, "expiry.expired.header").exists, "已过期的那一样处理掉了")
        XCTAssertEqual(el(app, "expiry.soon.header").label, "快过期, 2 样")
        app.buttons["返回"].firstMatch.tap()
        let banner = el(app, "home.banner.expiring")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.label.contains("有 2 样快过期了"), banner.label)
        shot(app, "01-after-discard")
    }

    /// 还在卖：挪到「过几天再提醒的」，按填的数和 3 天后
    func testSnoozeMovesToSnoozedSection() {
        let app = launch()
        openPanel(app, "expiry.soon.0")
        el(app, "expiry.choice.snooze").tap()
        XCTAssertTrue(el(app, "expiry.panel.title").waitForNonExistence(timeout: 5))
        XCTAssertEqual(el(app, "expiry.soon.header").label, "快过期, 1 样")
        let z0 = el(app, "expiry.snoozed.0")
        reveal(app, z0)
        XCTAssertTrue(z0.label.contains("桃李 醇熟切片面包") && z0.label.contains("11月22日再提醒"), z0.label)
    }

    /// 最大辅助字号：19 的「处理」和面板上每个选择、「先不处理」都点得到
    func testMaxAccessibilityTextReachable() {
        let app = launch(extra: Self.maxAX)
        openPanel(app, "expiry.soon.1")
        shot(app, "20b-maxAX")
        for id in ["expiry.choice.snooze", "expiry.choice.soldOut", "expiry.choice.return", "expiry.choice.discard", "expiry.later"] {
            let e = el(app, id)
            reveal(app, e)
            XCTAssertTrue(e.isHittable, id)
        }
    }

    // MARK: 收银员

    /// 收银员手机上没有黄条；硬塞路由也进不去 19
    func testCashierHasNoBannerAndNoPage() {
        let app = launch(role: "cashier", route: nil)
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app, "home.banner.expiring").exists)
        app.terminate()
        let app2 = launch(role: "cashier")
        XCTAssertTrue(el(app2, "page.denied").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app2, "page.expiry").exists)
    }
}
