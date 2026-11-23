import XCTest

/// 扫码页布局方案（负责人 + Fable 定）的界面验收：卖出页、进货页的取景框在下（中心屏高 62–65%）、
/// 手电筒 / 手输条码在框下横排、内容区在上；进货页扫到后商品卡在上、取景框压暗，确认 / 取消后恢复；
/// 卖出页结算条在清单和取景框之间。码由 Debug 的 FakeScanner 喂进扫码层
@MainActor
final class ScanLayoutUITests: XCTestCase {
    static let beer = "6901035600016", erguotou = "6901234500011", noodle = "6902514300011"
    static let colaPack = "6925303770020"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ route: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe", "-uiRoute", route] + extra
        app.launch()
        XCTAssertTrue(el(app, "page.\(route)").waitForExistence(timeout: 15))
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
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

    /// 取景框在屏幕下半：宽约 86%、高约 22–24%（收小时 16%）、中心在 62–65%（收小时下沿不动）；两个按钮紧贴框下 16pt、等宽、≥ 64pt、横排
    private func assertCameraArea(_ app: XCUIApplication, compact: Bool = false, _ ctx: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let w = app.windows.firstMatch.frame
        let finder = el(app, "scanner.viewfinder").frame
        let torch = app.buttons["sell.torch"].frame, manual = app.buttons["scanner.manual"].frame
        XCTAssertEqual(finder.width / w.width, 0.86, accuracy: 0.01, "\(ctx) 取景框宽 \(finder)", file: file, line: line)
        if compact {
            XCTAssertEqual(finder.height / w.height, 0.16, accuracy: 0.01, "\(ctx) 收小的取景框高 \(finder)", file: file, line: line)
            XCTAssertEqual(finder.maxY / w.height, 0.64 + 0.115, accuracy: 0.01, "\(ctx) 收小时下沿不动", file: file, line: line)
        } else {
            XCTAssertTrue((0.22...0.24).contains(finder.height / w.height), "\(ctx) 取景框高 \(finder)", file: file, line: line)
            XCTAssertTrue((0.62...0.65).contains(finder.midY / w.height), "\(ctx) 取景框中心 \(finder.midY / w.height)",
                          file: file, line: line)
        }
        XCTAssertEqual(torch.minY - finder.maxY, 16, accuracy: 1.5, "\(ctx) 手电筒紧贴框下 16pt", file: file, line: line)
        XCTAssertEqual(torch.minY, manual.minY, accuracy: 0.5, "\(ctx) 两个按钮横排", file: file, line: line)
        XCTAssertEqual(torch.width, manual.width, accuracy: 0.5, "\(ctx) 两个按钮等宽", file: file, line: line)
        XCTAssertGreaterThanOrEqual(torch.height, 64, file: file, line: line)
        XCTAssertTrue((0.39...0.43).contains(torch.width / w.width), "\(ctx) 按钮宽 \(torch.width)", file: file, line: line)
        XCTAssertLessThanOrEqual(manual.maxY, w.maxY - 34 - 15, "\(ctx) 按钮离底部安全区至少 16pt", file: file, line: line)
        XCTAssertTrue(app.buttons["sell.torch"].isHittable && app.buttons["scanner.manual"].isHittable, ctx, file: file, line: line)
    }

    // MARK: 进货页

    /// 空态：上方「扫一下送来的货」，下方取景框 + 按钮
    func testStockInEmptyLayout() {
        let app = launch("stockIn", [])
        XCTAssertTrue(el(app, "scanner.viewfinder").waitForExistence(timeout: 10))
        let hint = el(app, "stockIn.empty")
        XCTAssertTrue(hint.exists)
        XCTAssertLessThanOrEqual(hint.frame.maxY, el(app, "scanner.viewfinder").frame.minY, "提示在取景框上面")
        XCTAssertFalse(el(app, "scanner.holding").exists)
        assertCameraArea(app, "进货空态")
    }

    /// 扫到后：上方商品卡（品名、「－ 数量 ＋」、进价、确认入库），取景框压暗写「已扫到，先确认上面这件」；
    /// 点进价出键盘时相机区收起；收起后回到卡片；确认入库后压暗去掉、回到空态
    func testStockInCardHoldsTheCameraUntilConfirmed() {
        let app = launch("stockIn", ["-uiScan", Self.colaPack])
        let holding = el(app, "scanner.holding")
        XCTAssertTrue(holding.waitForExistence(timeout: 10), "取景框压暗")
        XCTAssertEqual(holding.label, "已扫到，先确认上面这件")
        let finder = el(app, "scanner.viewfinder").frame
        for id in ["stockIn.name", "stockIn.stepper", "stockIn.commit"] {
            XCTAssertTrue(el(app, id).exists, id)
            XCTAssertLessThanOrEqual(el(app, id).frame.maxY, finder.minY, "\(id) 在取景框上面")
        }
        XCTAssertFalse(app.buttons["点"].exists, "扫到后不出键盘")
        assertCameraArea(app, compact: true, "进货商品卡")
        // 「－ 数量 ＋」：从 1 加到 3
        let stepper = el(app, "stockIn.stepper")
        XCTAssertEqual(stepper.value as? String, "1")
        let plus = stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        plus.tap(); plus.tap()
        wait("数量 3") { stepper.value as? String == "3" }
        // 点进价：键盘出来，相机区收起
        el(app, "stockIn.cost").tap()
        XCTAssertTrue(app.buttons["点"].waitForExistence(timeout: 3))
        wait("相机区收起") { !el(app, "scanner.viewfinder").isHittable && !app.buttons["sell.torch"].isHittable }
        for c in "48" { app.buttons[String(c)].firstMatch.tap() }
        el(app, "stockIn.hideKeypad").tap()
        XCTAssertTrue(holding.waitForExistence(timeout: 3), "收起键盘回到商品卡，取景框仍压暗")
        XCTAssertEqual(el(app, "stockIn.total").label, "¥144.00")
        el(app, "stockIn.commit").tap()
        XCTAssertTrue(el(app, "stockIn.empty").waitForExistence(timeout: 5), "确认后回到空态")
        wait("压暗去掉") { !holding.exists }
        assertCameraArea(app, "进货确认后")
    }

    /// 「重新扫」（取消）后恢复识别
    func testStockInCancelRestoresTheCamera() {
        let app = launch("stockIn", ["-uiScan", Self.colaPack])
        XCTAssertTrue(el(app, "scanner.holding").waitForExistence(timeout: 10))
        el(app, "stockIn.rescan").tap()
        XCTAssertTrue(el(app, "stockIn.empty").waitForExistence(timeout: 3))
        XCTAssertFalse(el(app, "scanner.holding").exists)
    }

    // MARK: 卖出页

    /// 空态：上方空篮提示，结算条在空篮和取景框之间，取景框 + 按钮在下
    func testSellEmptyLayout() {
        let app = launch("sell", [])
        XCTAssertTrue(el(app, "scanner.viewfinder").waitForExistence(timeout: 10))
        let empty = el(app, "sell.empty"), checkout = el(app, "sell.checkout"), finder = el(app, "scanner.viewfinder")
        XCTAssertLessThanOrEqual(empty.frame.maxY, checkout.frame.minY + 0.5, "空篮在结算条上面")
        XCTAssertLessThanOrEqual(checkout.frame.maxY, finder.frame.minY, "结算条在取景框上面")
        assertCameraArea(app, "卖出空态")
    }

    /// 连续扫：扫到不暂停（不压暗）；最新一件置顶（价签）；结算条固定、不随清单滚动；到第 3 行取景框收到 16%
    func testSellContinuousScanAndFixedCheckout() {
        let app = launch("sell", ["-uiScan", [Self.beer, Self.erguotou].joined(separator: ",")])
        wait("两件") { el(app, "sell.itemCount").label == "一共 2 件" }
        XCTAssertFalse(el(app, "scanner.holding").exists, "卖出页扫到不暂停")
        XCTAssertTrue(el(app, "sell.tag").label.contains("二锅头"), "最新一件置顶：\(el(app, "sell.tag").label)")
        assertCameraArea(app, "卖出两行")
        let app3 = launch("sell", ["-uiScan", [Self.beer, Self.erguotou, Self.noodle].joined(separator: ",")])
        wait("三件") { el(app3, "sell.itemCount").label == "一共 3 件" }
        wait("取景框收小") { el(app3, "scanner.viewfinder").frame.height / app3.windows.firstMatch.frame.height < 0.17 }
        assertCameraArea(app3, compact: true, "卖出三行")
        let checkout = el(app3, "sell.checkout").frame, basket = el(app3, "sell.basket")
        basket.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(el(app3, "sell.checkout").frame, checkout, "结算条不随清单滚动")
        XCTAssertLessThanOrEqual(checkout.maxY, el(app3, "scanner.viewfinder").frame.minY, "结算条在取景框上面")
        XCTAssertLessThanOrEqual(basket.frame.maxY, checkout.minY + 0.5, "清单在结算条上面")
    }

    /// 最大辅助字号：取景框收小，记账按钮、两个相机按钮都在屏内能点（大字模式开 / 关）
    func testMaxAccessibilitySize() {
        for route in ["sell", "stockIn"] {
            for large in ["on", "off"] {
                let app = XCUIApplication()
                app.launchArguments = ["-uiFixture", "home", "-uiRoute", route, "-uiLargeText", large, "-uiProbe",
                                       "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                app.launch()
                XCTAssertTrue(el(app, "scanner.viewfinder").waitForExistence(timeout: 15))
                assertCameraArea(app, compact: true, "\(route) 最大字号 大字\(large)")
                if route == "sell" {
                    XCTAssertTrue(app.buttons["sell.commit"].isHittable, "记账按钮能点（大字 \(large)）")
                }
                app.terminate()
            }
        }
    }
}
