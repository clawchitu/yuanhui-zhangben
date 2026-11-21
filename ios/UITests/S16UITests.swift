import XCTest

/// S16 卖出页的界面验收。码由 Debug 的 FakeScanner 喂进扫码层（默认当作扫码枪，走真实的按键解析；
/// 开页先等 1 秒，每码 0.3 秒，§14 S14-3 ⑫），记账结果读调试探针 `debug.ledger`（本地库里的卖出批次和 outbox）。
@MainActor
final class S16UITests: XCTestCase {
    static let beer = "6901035600016", erguotou = "6901234500011", noodle = "6902514300011", long = "6900000000017"
    static let longName = "贵州茅台酒（飞天）53%vol 500ml 礼盒装 附赠两只小酒杯 生肖纪念版"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String], home: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe"] + (home ? [] : ["-uiRoute", "sell"]) + extra
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func ledger(_ app: XCUIApplication) -> [String: String] {
        let label = el(app, "debug.ledger").label
        var out: [String: String] = [:]
        for part in label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// 等到某个元素的文字 / 值满足条件
    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func waitItems(_ app: XCUIApplication, _ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        wait("一共 \(n) 件（现在「\(el(app, "sell.itemCount").label)」）", file: file, line: line) {
            el(app, "sell.itemCount").label == "一共 \(n) 件"
        }
    }

    private func commitButton(_ app: XCUIApplication) -> XCUIElement { app.buttons["sell.commit"] }

    // MARK: 验收

    /// 喂三个码后记账 → 本地一笔批次三行，合计正确，outbox 多一条 sale_batch；记完显示「记好了」并清空、停在卖出页
    func testThreeCodesCommitOneBatchOfThreeLines() {
        let app = launch(["-uiScan", [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle].joined(separator: ","),
                          "-uiHoldDone"])
        XCTAssertTrue(app.otherElements["page.sell"].waitForExistence(timeout: 10))
        XCTAssertEqual(ledger(app)["saleOps"], "0")
        waitItems(app, 6)
        XCTAssertEqual(el(app, "sell.total").label, "53.50 元")
        commitButton(app).tap()
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "sell.done").label.contains("记好了"))
        XCTAssertTrue(el(app, "sell.done").label.contains("53.50"))
        let l = ledger(app)
        XCTAssertEqual(l["batches"], "1")
        XCTAssertEqual(l["lastLines"], "3")
        XCTAssertEqual(l["lastList"], "5350")
        XCTAssertEqual(l["lastPaid"], "5350")
        XCTAssertEqual(l["saleOps"], "1", "outbox 多一条 sale_batch")
        XCTAssertTrue(el(app, "sell.empty").exists, "清空购物篮")
        XCTAssertTrue(app.otherElements["page.sell"].exists, "停在卖出页")
        XCTAssertEqual(el(app, "sell.itemCount").label, "一共 0 件")
    }

    /// 同码扫两次数量为 2（扫码枪每扣一次都算）
    func testSameCodeTwiceIsQuantityTwo() {
        let app = launch(["-uiScan", "\(Self.beer),\(Self.beer)"])
        waitItems(app, 2)
        XCTAssertEqual(el(app, "sell.qty.focus").value as? String, "2")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "sell.line").count, 0, "只有价签一行")
        XCTAssertEqual(el(app, "sell.total").label, "12.00 元")
    }

    /// 相机来源同码 1.5 秒内只进一次（§14 S14-1 接到购物篮上）：A、A、B → A 1 件、B 1 件
    func testCameraSameCodeWithinWindowCountsOnce() {
        let app = launch(["-uiScan", "\(Self.beer),\(Self.beer),\(Self.noodle)", "-uiScanSource", "camera"])
        waitItems(app, 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(el(app, "sell.itemCount").label, "一共 2 件")
        XCTAssertEqual(el(app, "sell.total").label, "10.50 元")
    }

    /// 从首页卖一样东西共两次点击：点「卖出」→（扫码）→ 点「收好钱了，记账」
    func testSellOneThingFromHomeInTwoTaps() {
        let app = launch(["-uiScan", Self.beer], home: true)
        let sell = app.buttons["home.sell"]
        XCTAssertTrue(sell.waitForExistence(timeout: 10))
        sell.tap()                                                 // 第 1 次
        XCTAssertTrue(app.otherElements["page.sell"].waitForExistence(timeout: 5))
        waitItems(app, 1)
        commitButton(app).tap()                                    // 第 2 次
        wait("记上一笔") { ledger(app)["batches"] == "1" }
        XCTAssertEqual(ledger(app)["lastQty"], "青岛啤酒 500ml:1")
        XCTAssertEqual(ledger(app)["saleOps"], "1")
    }

    /// 连点两次记账只产生一笔
    func testDoubleTapCommitRecordsOnlyOne() {
        let app = launch(["-uiScan", "\(Self.beer),\(Self.noodle)"])
        waitItems(app, 2)
        commitButton(app).doubleTap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if commitButton(app).isEnabled { commitButton(app).tap() }   // 第三下（篮子已空，按钮应已置灰）
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let l = ledger(app)
        XCTAssertEqual(l["batches"], "1")
        XCTAssertEqual(l["commits"], "1")
        XCTAssertEqual(l["saleOps"], "1")
        XCTAssertEqual(l["lastLines"], "2")
    }

    /// 空篮时记账按钮置灰（抹零 / 改总价也置灰）；扫进东西后可点
    func testEmptyBasketGreysOutCommit() {
        let app = launch(["-uiScan", Self.beer, "-uiScanDelay", "3"])
        XCTAssertTrue(commitButton(app).waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "sell.empty").exists)
        XCTAssertFalse(commitButton(app).isEnabled)
        XCTAssertFalse(app.buttons["sell.discount"].isEnabled)
        commitButton(app).tap()
        XCTAssertEqual(ledger(app)["batches"], "0", "置灰时按了也不记")
        waitItems(app, 1)
        XCTAssertTrue(commitButton(app).isEnabled)
        XCTAssertTrue(app.buttons["sell.discount"].isEnabled)
    }

    /// 没登记的码：出黄条（S18 再接登记页），篮子不变
    func testUnknownCodeShowsNotice() {
        let app = launch(["-uiScan", "\(Self.beer),6900000000000"])
        let notice = el(app, "sell.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("这个码还没登记"), notice.label)
        XCTAssertEqual(el(app, "sell.itemCount").label, "一共 1 件")
    }

    /// 连着扫同一个没登记的码（隔 3 秒）：第二次的黄条从第二次起停满 4 秒，不被第一次的计时提前收掉（Fable 8）
    func testRepeatedUnknownCodeRestartsTheNoticeTimer() {
        let unknown = "6900000000000"
        let app = launch(["-uiScan", "\(unknown),\(unknown)", "-uiScanGap", "3"])
        let notice = el(app, "sell.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let first = Date()
        // 第一次计时在约 4 秒时到；第二次在约 3 秒时出，应停到约 7 秒
        RunLoop.current.run(until: first.addingTimeInterval(5.5))
        XCTAssertTrue(notice.exists, "第二次的黄条被第一次的计时提前收掉了")
        XCTAssertTrue(notice.label.contains(unknown))
        wait("黄条最终消失", timeout: 6) { !notice.exists }
    }

    /// 相机被拒：27a（S14 的 NoCameraBand），扫码枪照常进购物篮
    func testCameraDeniedShowsBandAndGunStillSells() {
        let app = launch(["-uiCamera", "denied", "-uiScan", Self.beer])
        XCTAssertTrue(el(app, "scanner.noCamera").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["scanner.openSettings"].exists)
        XCTAssertTrue(app.buttons["scanner.manual"].exists)
        XCTAssertFalse(el(app, "scanner.viewfinder").exists)
        waitItems(app, 1)
    }

    /// 相机允许：取景框是 S14 的 CameraViewfinder（模拟器上没有相机画面），没有示意条码
    func testViewfinderIsTheScannerLayer() {
        let app = launch([])
        XCTAssertTrue(el(app, "scanner.viewfinder").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sell.torch"].exists)
        XCTAssertTrue(app.buttons["scanner.manual"].exists)
    }

    // MARK: 长名、最大辅助字号

    /// 文字的辅助功能外框比字形每边宽约 3pt，页边距 20pt 的东西按 16pt 判（出了 16pt 就是真出了边距）
    private func assertInsideWindow(_ app: XCUIApplication, _ e: XCUIElement, margin: CGFloat = 0, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let w = app.windows.firstMatch.frame
        XCTAssertTrue(e.exists, "\(what) 不在", file: file, line: line)
        XCTAssertGreaterThanOrEqual(e.frame.minX, w.minX + margin - 0.5, "\(what) 出了左边距 \(e.frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(e.frame.maxX, w.maxX - margin + 0.5, "\(what) 出了右边距 \(e.frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(e.frame.maxY, w.maxY + 0.5, "\(what) 出了屏幕底 \(e.frame)", file: file, line: line)
    }

    /// 商品名很长时换行不截断、金额不出右边距（长名在下面的行里，和在价签里各一次）
    func testLongNameWrapsAndAmountsStayInside() {
        for order in [[Self.long, Self.long, Self.long, Self.erguotou], [Self.erguotou, Self.long, Self.long, Self.long]] {
            let app = launch(["-uiLongName", "-uiScan", order.joined(separator: ",")])
            waitItems(app, 4)
            let name = app.staticTexts[Self.longName]
            XCTAssertTrue(name.exists, "全名在（没被截成「…」）")
            XCTAssertGreaterThan(name.frame.height, 40, "长名换了行")
            assertInsideWindow(app, name, margin: 16, "长名")
            for s in app.descendants(matching: .any).matching(identifier: "sell.subtotal").allElementsBoundByIndex {
                assertInsideWindow(app, s, margin: 16, "小计")
            }
            assertInsideWindow(app, el(app, "sell.total"), margin: 16, "总价")
            XCTAssertEqual(el(app, "sell.total").label, "30024.97 元")
            app.terminate()
        }
    }

    /// 系统最大辅助字号下总价和记账按钮完整可见（大字模式开 / 关各一次）
    func testMaxAccessibilitySizeKeepsTotalAndCommitVisible() {
        for large in ["on", "off"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiFixture", "home", "-uiRoute", "sell", "-uiLargeText", large, "-uiProbe",
                                   "-uiLongName", "-uiScan", [Self.beer, Self.erguotou, Self.long].joined(separator: ","),
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            waitItems(app, 3)
            let total = el(app, "sell.total"), commit = commitButton(app)
            assertInsideWindow(app, total, margin: 16, "总价（大字 \(large)）")
            assertInsideWindow(app, commit, "记账按钮（大字 \(large)）")
            XCTAssertTrue(commit.isHittable, "记账按钮能点（大字 \(large)）")
            XCTAssertGreaterThanOrEqual(commit.frame.height, 56)
            XCTAssertEqual(total.label, "10030.99 元")
            commit.tap()
            wait("最大字号下也能记账") { ledger(app)["batches"] == "1" }
            app.terminate()
        }
    }
}
