import XCTest

/// 新商品名称多行（真机 11/24：04a 名称框单行，「农夫山泉 饮用天然水 550…」被截断）：
/// 显示时最多 3 行、超过才省略；编辑时随内容增高到 4 行，之后框内滚动；名称框不压住下面的卖价和按钮。
/// 顺带核对进货商品卡、04b 摘要卡里长名至少两行。码由 Debug 的 FakeScanner 喂进扫码层
@MainActor
final class NameWrapUITests: XCTestCase {
    /// 演示桩里查不到名称的码（S18 的 cashierCode / offlineCode）
    static let unknown1 = "6920152400319", unknown2 = "6901028075831"
    static let water = "农夫山泉 饮用天然水550ml"
    static let tea = "鸭屎香单枞柠檬茶果味饮料 500ml 整箱 15 瓶装"
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    /// 量的是带 newProduct.name 标识的内层文本框（不含外框上下 12pt 留白）：28pt 粗体单行约 34pt、两行约 67pt，每行约 33pt
    static let line: CGFloat = 33, oneLine: CGFloat = 34
    /// 长名两行起：至少 60pt；显示最多 3 行、编辑最多 4 行（各留 10pt 余量）
    static let twoLinesMin: CGFloat = 60
    static func linesMax(_ n: Int) -> CGFloat { oneLine + CGFloat(n - 1) * line + 10 }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ route: String, _ extra: [String], page: String = "page.newProduct") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiLargeText", "on", "-uiProbe", "-uiRoute", route] + extra
        app.launch()
        XCTAssertTrue(el(app, page).waitForExistence(timeout: 15), page)
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

    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    /// 名称框里是整段长名、框至少两行高；卖价框和「存好」按钮都点得到、不被名称框压住
    private func assertWrapped(_ app: XCUIApplication, _ name: String, _ ctx: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let field = el(app, "newProduct.name")
        wait("\(ctx) 名称填好", file: file, line: line) { (field.value as? String) == name }
        let box = field.frame
        let value = field.value as? String ?? ""
        XCTAssertEqual(value, name, "\(ctx) 名称完整", file: file, line: line)
        XCTAssertFalse(value.contains("…"), "\(ctx) 名称没被截断", file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.height, Self.twoLinesMin, "\(ctx) 长名换行，至少两行高 \(box)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(box.height, Self.linesMax(3), "\(ctx) 显示时最多 3 行 \(box)", file: file, line: line)
        let price = el(app, "newProduct.price"), save = app.buttons["newProduct.save"]
        XCTAssertTrue(price.isHittable, "\(ctx) 卖价框点得到", file: file, line: line)
        XCTAssertTrue(save.isHittable, "\(ctx) 存好按钮点得到", file: file, line: line)
        if field.isHittable {
            XCTAssertLessThanOrEqual(box.maxY, price.frame.minY, "\(ctx) 名称框在卖价上面、不压住", file: file, line: line)
        }
    }

    /// 04a：两个长名在标准 / 最大辅助字号下都换行显示，卖价和按钮不被挡
    func testLongNamesWrapOnNewProductPage() {
        for (name, ax) in [(Self.water, false), (Self.tea, false), (Self.water, true), (Self.tea, true)] {
            let app = launch("sell", ["-uiScan", "\(Self.unknown1),\(Self.unknown2)", "-uiNewName", name] + (ax ? Self.maxAX : []))
            assertWrapped(app, name, "\(name)\(ax ? " 最大辅助字号" : "")")
            app.terminate()
        }
    }

    /// 编辑时框随内容增高，到 4 行封顶（再长在框内滚动）；回车不留换行，照旧收起键盘、自家键盘回来
    func testEditingGrowsToFourLinesThenScrolls() {
        let app = launch("sell", ["-uiScan", Self.unknown1])
        let field = el(app, "newProduct.name")
        let empty = field.frame.height
        XCTAssertEqual(empty, Self.oneLine, accuracy: 4, "空名称是单行框")
        field.tap()
        wait("自家键盘收起") { !el(app, "newProduct.keypad").exists }
        field.typeText(Self.tea)
        let typed = field.frame.height
        XCTAssertGreaterThanOrEqual(typed, Self.twoLinesMin, "打长名时框增高：\(empty) → \(typed)")
        field.typeText(String(repeating: Self.tea, count: 2))
        let capped = field.frame.height
        XCTAssertLessThanOrEqual(capped, Self.linesMax(4), "编辑时最多 4 行高：\(capped)")
        XCTAssertGreaterThanOrEqual(capped, Self.linesMax(4) - 20, "很长时撑到 4 行：\(capped)")
        field.typeText("\n")
        wait("回车收起键盘、自家键盘回来") { el(app, "newProduct.keypad").exists }
        let value = field.value as? String ?? ""
        XCTAssertFalse(value.contains("\n"), "名称里不留换行")
        XCTAssertEqual(value, String(repeating: Self.tea, count: 3))
        XCTAssertLessThanOrEqual(field.frame.height, Self.linesMax(3), "不编辑时回到最多 3 行（超出省略）")
        keys(app, "3")
        XCTAssertTrue(app.buttons["newProduct.save"].isEnabled)
    }

    /// 进货：长名在 04b 摘要卡、进货商品卡里都完整换行（至少两行），不截断
    func testStockInCardShowsWholeLongName() {
        let app = launch("stockIn", ["-uiScan", Self.unknown1, "-uiNewName", Self.tea, "-uiNewPrice", "5",
                                     "-uiNewStep2", "-uiNewQty", "0", "-uiNewMode", "stock"], page: "page.newProduct2")
        let summary = el(app, "newProduct.summary")
        XCTAssertTrue(summary.label.contains(Self.tea), summary.label)
        app.buttons["newProduct.saveMore"].tap()
        let name = el(app, "stockIn.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.label, Self.tea)
        XCTAssertGreaterThanOrEqual(name.frame.height, 2 * 30, "进货商品卡长名至少两行：\(name.frame)")
    }
}
