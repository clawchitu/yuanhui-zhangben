import Vision
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

    /// 没登记、又进不了登记页的码（S18 起能登记的码直接去 04a，§14 S16-3；这里用 65 位、超过契约条码长度的码）：
    /// 出黄条，篮子不变
    static let unregistrable = String(repeating: "6", count: 65)

    func testUnknownCodeShowsNotice() {
        // 扫码枪一个码最多 48 位（`HIDScanParser`），超长的码只可能从相机来
        let app = launch(["-uiScan", "\(Self.beer),\(Self.unregistrable)", "-uiScanSource", "camera"])
        let notice = el(app, "sell.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("这个码还没登记"), notice.label)
        XCTAssertEqual(el(app, "sell.itemCount").label, "一共 1 件")
    }

    /// 连着扫同一个没登记的码（隔 3 秒）：第二次的黄条从第二次起停满 4 秒，不被第一次的计时提前收掉（Fable 8）
    func testRepeatedUnknownCodeRestartsTheNoticeTimer() {
        let unknown = Self.unregistrable
        let app = launch(["-uiScan", "\(unknown),\(unknown)", "-uiScanGap", "3", "-uiScanSource", "camera"])
        let notice = el(app, "sell.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let first = Date()
        // 第一次计时在约 4 秒时到；第二次在约 3 秒时出，应停到约 7 秒
        RunLoop.current.run(until: first.addingTimeInterval(5.5))
        XCTAssertTrue(notice.exists, "第二次的黄条被第一次的计时提前收掉了")
        XCTAssertTrue(notice.label.contains(unknown))
        wait("黄条最终消失", timeout: 6) { !notice.exists }
    }

    /// 收银员身份的卖出页上没有「进价」「库存」字样（Fable 建议项：防以后有人往价签里加东西）
    func testCashierSellPageShowsNoCostOrStock() {
        let app = launch(["-uiRole", "cashier", "-uiScan", "\(Self.beer),\(Self.noodle)"])
        waitItems(app, 2)
        let texts = app.descendants(matching: .any).allElementsBoundByIndex.map(\.label).joined(separator: "|")
        for word in ["进价", "库存", "成本"] {
            XCTAssertFalse(texts.contains(word), "收银员卖出页出现「\(word)」：\(texts)")
        }
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

    /// 页边距：容器（价签、各行）左右各留 20pt。辅助功能外框在 iPhone 17 上就是画出来的框（20…）；
    /// 在 iPhone 13 上每边外扩 3pt（价签画在 20…370，外框 17…373）。所以允许 17…20（误差 1pt），出了这个范围就是没留够边距（Codex ③）
    private func assertPageMargins(_ app: XCUIApplication, _ e: XCUIElement, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let w = app.windows.firstMatch.frame
        let left = e.frame.minX - w.minX, right = w.maxX - e.frame.maxX
        XCTAssertTrue((16...21).contains(left), "\(what) 左边距 \(left)：\(e.frame)", file: file, line: line)
        XCTAssertTrue((16...21).contains(right), "\(what) 右边距 \(right)：\(e.frame)", file: file, line: line)
    }

    /// 两个元素不重叠
    private func assertNoOverlap(_ a: XCUIElement, _ b: XCUIElement, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let i = a.frame.intersection(b.frame)
        XCTAssertTrue(i.isNull || i.width < 0.5 || i.height < 0.5, "\(what) 重叠：\(a.frame) / \(b.frame)", file: file, line: line)
    }

    /// 把购物篮里的某个元素整个滚进可视区（购物篮的顶到结算区的顶）
    private func scrollIntoBasket(_ app: XCUIApplication, _ e: XCUIElement) -> Bool {
        let basket = el(app, "sell.basket"), checkout = el(app, "sell.checkout")
        for _ in 0..<8 {
            let top = basket.frame.minY, bottom = checkout.frame.minY
            if e.frame.minY >= top - 0.5 && e.frame.maxY <= bottom + 0.5 { return true }
            let up = e.frame.maxY > bottom
            let from = basket.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.8 : 0.2))
            from.press(forDuration: 0.05, thenDragTo: basket.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.7)))
        }
        return false
    }

    /// 元素在屏幕上画出来的字（文字识别，去掉空白）。辅助功能标签截断了也还是全名，所以要读画出来的字（Codex ③）
    private static func renderedText(_ e: XCUIElement) throws -> String {
        let shot = e.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .deleteOnSuccess
        XCTContext.runActivity(named: "识别 \(e.identifier)") { $0.add(attachment) }
        let cg = try XCTUnwrap(shot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 长名里有代表性的几段：开头、中间、结尾都要画出来（截成两行、出「…」都会少）
    static let longNameParts = ["贵州茅台酒", "飞天", "礼盒装", "附赠两只小酒杯", "生肖纪念版"]

    /// 商品名很长时换行不截断（读画出来的字）、金额不出右边距、容器留足 20pt 页边距；
    /// 滚到长名那里能整个看见，不被固定的结算区盖住；总价、抹零按钮、记账按钮互不重叠（长名在下面的行里，和在价签里各一次）
    func testLongNameWrapsAndAmountsStayInside() throws {
        for order in [[Self.long, Self.long, Self.long, Self.erguotou], [Self.erguotou, Self.long, Self.long, Self.long]] {
            let app = launch(["-uiLongName", "-uiScan", order.joined(separator: ",")])
            waitItems(app, 4)
            let name = app.staticTexts[Self.longName]
            XCTAssertTrue(name.exists, "全名在")
            XCTAssertTrue(scrollIntoBasket(app, name), "长名能整个滚进购物篮可视区 \(name.frame)")
            XCTAssertLessThanOrEqual(name.frame.maxY, el(app, "sell.checkout").frame.minY + 0.5, "长名不被结算区盖住")
            let text = try Self.renderedText(name)
            for part in Self.longNameParts {
                XCTAssertTrue(text.contains(part), "画出来的长名缺「\(part)」：\(text)")
            }
            XCTAssertFalse(text.contains("…") || text.contains("..."), "长名被截断：\(text)")
            assertInsideWindow(app, name, margin: 16, "长名")
            let containers = [el(app, "sell.tag")] + app.descendants(matching: .any).matching(identifier: "sell.line").allElementsBoundByIndex
            for c in containers where c.exists { assertPageMargins(app, c, c.identifier) }
            for s in app.descendants(matching: .any).matching(identifier: "sell.subtotal").allElementsBoundByIndex {
                assertInsideWindow(app, s, margin: 16, "小计")
            }
            let total = el(app, "sell.total"), discount = app.buttons["sell.discount"], commit = commitButton(app)
            assertInsideWindow(app, total, margin: 16, "总价")
            assertNoOverlap(total, discount, "总价和抹零按钮")
            assertNoOverlap(total, commit, "总价和记账按钮")
            assertNoOverlap(discount, commit, "抹零按钮和记账按钮")
            XCTAssertEqual(total.label, "30024.97 元")
            app.terminate()
        }
    }

    /// 总价四位数（¥9999.99）：64pt 放不下时先降到 48pt，和「抹零 / 改总价」仍排在同一行，不上下排（S16-10）
    func testFourDigitTotalStaysBesideTheDiscountButton() {
        let app = launch(["-uiLongName", "-uiScan", Self.long])
        waitItems(app, 1)
        let total = el(app, "sell.total"), discount = app.buttons["sell.discount"]
        XCTAssertEqual(total.label, "9999.99 元")
        XCTAssertGreaterThan(total.frame.minX, discount.frame.maxX, "总价在按钮右边：\(total.frame) / \(discount.frame)")
        XCTAssertLessThan(abs(total.frame.midY - discount.frame.midY), 30, "同一行")
        assertInsideWindow(app, total, margin: 16, "总价")
    }

    /// 03（扫码页布局改版后）：大字模式、稿子上的三样商品。清单区变矮，三行不再同屏：
    /// 结算条固定在清单和取景框之间、始终完整可见；清单至少完整露出两行（价签 + 一行），其余滚动可见（S16-10）
    func testDesignBasketCheckoutFixedListScrolls() {
        let app = launch(["-uiScan", [Self.beer, Self.beer, Self.beer, Self.beer, Self.erguotou, Self.noodle].joined(separator: ",")])
        waitItems(app, 6)
        let checkout = el(app, "sell.checkout"), basket = el(app, "sell.basket"), camera = el(app, "sell.camera")
        let w = app.windows.firstMatch.frame
        func assertCheckoutFixed(_ ctx: String) {
            XCTAssertGreaterThanOrEqual(checkout.frame.minY, basket.frame.maxY - 0.5, "\(ctx)：结算条在清单下面 \(checkout.frame)")
            XCTAssertLessThanOrEqual(checkout.frame.maxY, camera.frame.minY + 0.5, "\(ctx)：结算条在取景框上面 \(checkout.frame)")
            XCTAssertLessThanOrEqual(checkout.frame.maxY, w.maxY, ctx)
            XCTAssertTrue(commitButton(app).isHittable, "\(ctx)：记账按钮能点")
            XCTAssertTrue(app.buttons["sell.discount"].isHittable, "\(ctx)：抹零按钮能点")
        }
        let rows = { [self.el(app, "sell.tag")] + app.descendants(matching: .any).matching(identifier: "sell.line").allElementsBoundByIndex }
        XCTAssertEqual(rows().count, 3)
        func visible(_ r: XCUIElement) -> Bool {
            r.frame.minY >= basket.frame.minY - 0.5 && r.frame.maxY <= basket.frame.maxY + 0.5
        }
        assertCheckoutFixed("开始")
        let shown = rows().filter(visible)
        XCTAssertGreaterThanOrEqual(shown.count, 2, "清单至少完整露出两行：\(rows().map(\.frame)) / 清单区 \(basket.frame)")
        XCTAssertTrue(visible(el(app, "sell.tag")), "最新一件（价签）置顶可见")
        XCTAssertTrue(el(app, "sell.qty.focus").isHittable, "价签的数量能点")
        // 滚到底：最后一行完整可见，结算条位置不动
        let before = checkout.frame
        basket.swipeUp()
        wait("最后一行滚得到 \(rows().last!.frame) / \(basket.frame)") { visible(rows().last!) }
        XCTAssertEqual(checkout.frame.minY, before.minY, accuracy: 0.5, "结算条固定，不随清单滚动")
        assertCheckoutFixed("滚到底")
        let lines = app.descendants(matching: .any).matching(identifier: "sell.line").allElementsBoundByIndex
        for l in lines { XCTAssertLessThanOrEqual(l.frame.height, 100, "两行式每行贴稿约 95pt，实际 \(l.frame.height)") }
    }

    /// 最大辅助字号下「记好了」黑卡不参与布局：顶栏返回钮、记账按钮和空篮时在同一位置、整个在屏内、能点；
    /// 黑卡在购物篮区内；黑卡后面的空篮只留虚线框（S16-9）
    func testDoneCardAtMaxSizeDoesNotPushTheBarsOff() {
        var frames: [String: (CGRect, CGRect)] = [:]
        for state in ["empty", "done"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiFixture", "home", "-uiRoute", "sell", "-uiLargeText", "on", "-uiProbe",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                + (state == "done" ? ["-uiScan", [Self.beer, Self.erguotou, Self.noodle].joined(separator: ","), "-uiAutoCommit", "-uiHoldDone"] : [])
            app.launch()
            let commit = commitButton(app), back = app.buttons["返回"].firstMatch
            XCTAssertTrue(commit.waitForExistence(timeout: 10))
            if state == "done" {
                let done = el(app, "sell.done")
                XCTAssertTrue(done.waitForExistence(timeout: 10))
                let box = el(app, "sell.empty")
                XCTAssertTrue(box.exists)
                XCTAssertGreaterThanOrEqual(done.frame.minY, box.frame.minY - 0.5, "黑卡在购物篮区内 \(done.frame) / \(box.frame)")
                XCTAssertLessThanOrEqual(done.frame.maxY, box.frame.maxY + 0.5, "黑卡在购物篮区内 \(done.frame) / \(box.frame)")
                XCTAssertFalse(box.label.contains("扫第一样商品"), "黑卡后面的空篮不露文字：\(box.label)")
            }
            let w = app.windows.firstMatch.frame
            XCTAssertTrue(back.isHittable, "\(state)：返回钮能点")
            XCTAssertGreaterThanOrEqual(back.frame.minY, w.minY + 40, "\(state)：返回钮不进状态栏 \(back.frame)")
            XCTAssertGreaterThanOrEqual(commit.frame.minY, w.minY)
            XCTAssertLessThanOrEqual(commit.frame.maxY, w.maxY + 0.5, "\(state)：记账按钮整个在屏内 \(commit.frame)")
            frames[state] = (back.frame, commit.frame)
            app.terminate()
        }
        if let e = frames["empty"], let d = frames["done"] {
            XCTAssertEqual(e.0, d.0, "黑卡出来时返回钮不动")
            XCTAssertEqual(e.1, d.1, "黑卡出来时记账按钮不动")
        }
    }

    /// ⑨：推到「手输条码」页期间扫码枪扣扳机，码不进购物篮（不出声）；返回后再扫照常进
    func testScansWhileOnTheManualPageAreIgnored() {
        // 1 秒：啤酒（进）；6 秒：方便面（这时在手输页，不进）；11 秒：二锅头（已返回，进）
        let app = launch(["-uiScan", [Self.beer, Self.noodle, Self.erguotou].joined(separator: ","), "-uiScanGap", "5"])
        waitItems(app, 1)
        let start = Date()
        app.buttons["scanner.manual"].tap()
        XCTAssertTrue(app.otherElements["page.manualCode"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: start.addingTimeInterval(6.5))
        app.otherElements["page.manualCode"].buttons["返回"].tap()
        XCTAssertTrue(app.otherElements["page.sell"].waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "sell.itemCount").label, "一共 1 件", "在手输页时扫的码没进购物篮")
        XCTAssertFalse(el(app, "sell.qty.\(Self.noodle)").exists)
        waitItems(app, 2)
        XCTAssertTrue(el(app, "sell.qty.\(Self.erguotou)").exists || el(app, "sell.qty.focus").exists)
        XCTAssertEqual(el(app, "sell.total").label, "31.00 元", "啤酒 6.00 + 二锅头 25.00")
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
