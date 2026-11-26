import XCTest

/// 真机 11/26：卖出页价签上的商品名折成两行（「农夫山泉 饮用天然水550ml」）时黄色价签变高，
/// 「买几个」那一栏的加减按钮被下面的结算条（一共 N 件 / 抹零 / 收好钱了）遮住一半。
/// 验收：不管名字多长、开不开大字模式、是不是小屏（iPhone SE），不滚动时加减按钮都整个露在购物篮区里（结算条上面），
/// 点「+」真的加一件。要在 iPhone SE（第 3 代）和 iPhone 16 Pro 上各跑一遍。码由 Debug 的 FakeScanner 喂进扫码层（和真扫码同一条路）
@MainActor
final class SellTagFitUITests: XCTestCase {
    static let wrap = "6900000000024", long = "6900000000017", beer = "6901035600016", noodle = "6902514300011"
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(largeText: Bool, ax: Bool, scan: [String], role: String = "family", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", largeText ? "on" : "off", "-uiRoute", "sell",
                               "-uiWrapName", "-uiLongName", "-uiScan", scan.joined(separator: ",")] + (ax ? Self.maxAX : []) + extra
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func isSmall(_ app: XCUIApplication) -> Bool { app.windows.firstMatch.frame.height < 700 }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(isSmall(app) ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 等布局稳定（取景框第 3 行起收小带 0.2 秒动画）
    private func waitStable(_ app: XCUIApplication, _ e: XCUIElement) {
        var last = CGRect.null
        wait("位置稳定") {
            let f = e.frame
            defer { last = f }
            return f == last
        }
    }

    private func check(_ ctx: String, largeText: Bool, ax: Bool, scan: [String], items: Int, extra: [String] = []) {
        let app = launch(largeText: largeText, ax: ax, scan: scan, extra: extra)
        wait("\(ctx)：一共 \(items) 件（现在「\(el(app, "sell.itemCount").label)」）") {
            el(app, "sell.itemCount").label == "一共 \(items) 件"
        }
        let stepper = el(app, "sell.qty.focus"), basket = el(app, "sell.basket"), checkout = el(app, "sell.checkout")
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), ctx)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        waitStable(app, checkout)
        shot(app, ctx)
        let s = stepper.frame, b = basket.frame, c = checkout.frame
        XCTAssertGreaterThanOrEqual(s.minY, b.minY - 0.5, "\(ctx)：加减按钮上沿在购物篮区里 \(s) / \(b)")
        XCTAssertLessThanOrEqual(s.maxY, b.maxY + 0.5, "\(ctx)：加减按钮整个露在购物篮区里（不被结算条盖住）\(s) / 篮 \(b)")
        XCTAssertLessThanOrEqual(s.maxY, c.minY + 0.5, "\(ctx)：加减按钮在结算条上面 \(s) / 结算条 \(c)")
        XCTAssertGreaterThanOrEqual(s.height, 56 - 0.5, "\(ctx)：步进器不缩小 \(s)")
        // 相机区让高度也有底线：取景框最矮 72pt，手电筒、手输条码照样能点（§14 S16-13）
        let finder = el(app, "scanner.viewfinder").frame
        XCTAssertGreaterThanOrEqual(finder.height, 72 - 0.5, "\(ctx)：取景框最矮 72pt \(finder)")
        XCTAssertGreaterThanOrEqual(finder.minY, c.maxY - 0.5, "\(ctx)：取景框在结算条下面 \(finder) / \(c)")
        XCTAssertTrue(app.buttons["sell.torch"].isHittable && app.buttons["scanner.manual"].isHittable, "\(ctx)：相机按钮能点")
        // 名字开头永远看得到
        let name = el(app, "priceTag.name")
        XCTAssertTrue(name.exists, ctx)
        XCTAssertGreaterThanOrEqual(name.frame.minY, b.minY - 0.5, "\(ctx)：名称在篮子区里")
        // 真点「+」（右端那个圆钮的中心）：数量加一
        let before = stepper.value as? String
        stepper.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: s.width - 28, dy: s.height / 2)).tap()
        wait("\(ctx)：点「+」后一共 \(items + 1) 件（现在「\(el(app, "sell.itemCount").label)」，步进器 \(before ?? "")）") {
            el(app, "sell.itemCount").label == "一共 \(items + 1) 件"
        }
        app.terminate()
    }

    /// 只有一样：长名两种 × 大字模式 / 标准 / 最大辅助字号
    func testFocusStepperFullyVisibleOneLine() {
        for (code, n) in [(Self.wrap, "water"), (Self.long, "maotai")] {
            check("\(n)-large", largeText: true, ax: false, scan: [code], items: 1)
            check("\(n)-standard", largeText: false, ax: false, scan: [code], items: 1)
            check("\(n)-axmax", largeText: true, ax: true, scan: [code], items: 1)
        }
    }

    /// 篮子里已经有别的（价签下面还有行；第 3 行起取景框收小）：最新扫的长名在价签里，步进器照样整个露出来
    /// S23b-2：注销申请中卖出页顶上多一条提示，价签和加减按钮照样整个露在结算条上面（顶栏连提示条一起量）
    func testFocusStepperFullyVisibleWhileDeletePending() {
        let until = ["-uiDeletePending", "2099-01-01T00:00:00.000Z"]
        check("deleting-water-axmax", largeText: true, ax: true, scan: [Self.wrap], items: 1, extra: until)
        check("deleting-maotai-3lines-axmax", largeText: true, ax: true, scan: [Self.beer, Self.noodle, Self.long], items: 3, extra: until)
    }

    func testFocusStepperFullyVisibleWithOtherLines() {
        check("water-2lines-large", largeText: true, ax: false, scan: [Self.beer, Self.wrap], items: 2)
        check("water-3lines-large", largeText: true, ax: false, scan: [Self.beer, Self.noodle, Self.wrap], items: 3)
        check("maotai-3lines-axmax", largeText: true, ax: true, scan: [Self.beer, Self.noodle, Self.long], items: 3)
    }

    /// CI 回归（#60）：收银员、大字模式、普通长度的名字——价签用 0 档（照稿子），缩略图在；不能一上来就收到去掉缩略图的 3 档
    func testCashierNormalNameKeepsThumb() {
        let app = launch(largeText: true, ax: false, scan: [Self.noodle], role: "cashier")
        wait("一共 1 件") { el(app, "sell.itemCount").label == "一共 1 件" }
        XCTAssertTrue(el(app, "sell.qty.focus").waitForExistence(timeout: 5))
        waitStable(app, el(app, "sell.checkout"))
        shot(app, "cashier-noodle-large")
        // 缩略图读屏不读、找不到元素：看名称左边让没让出缩略图的位置（3 档没缩略图，名称贴左边距 16）
        let tag = el(app, "sell.tag").frame, name = el(app, "priceTag.name").frame
        XCTAssertGreaterThanOrEqual(name.minX - tag.minX, 16 + 40, "名称左边留着缩略图 \(name) / 价签 \(tag)")
    }
}
