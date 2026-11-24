import XCTest

/// 新商品名称多行（真机 11/24：04a 名称框单行，「农夫山泉 饮用天然水 550…」被截断）。
/// PR #43 Fable 决定：写名称时只留名称框和「写好了」；平时按可用高度显示 3→2→1 整行，开头永远可见，放不下先压矮数字键。
/// 要在 iPhone SE（第 3 代）和 iPhone 16 Pro 上各跑一遍；每条测试里默认字号、最大辅助字号都跑。
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

    /// 截图留在测试结果里（docs/screenshots/name-wrap/ 下的图从这里导出）
    private func shot(_ app: XCUIApplication, _ state: String, ax: Bool, name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(isSmall(app) ? "se" : "16pro")-\(state)-\(name == Self.tea ? "tea" : "water")-\(ax ? "axmax" : "standard")"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 小屏（iPhone SE 第 3 代，窗口高 667）
    private func isSmall(_ app: XCUIApplication) -> Bool { app.windows.firstMatch.frame.height < 700 }

    /// 内层文本框高度折成整行数（每行约 33.4pt）；不是整行返回 nil
    private func wholeLines(_ h: CGFloat) -> Int? {
        let n = Int((h / 33.4).rounded())
        return n >= 1 && abs(h - CGFloat(n) * 33.4) <= 4 ? n : nil
    }

    private func ctxName(_ app: XCUIApplication, _ name: String, _ ax: Bool) -> String {
        "\(isSmall(app) ? "SE" : "大屏") \(ax ? "最大辅助字号" : "默认字号") \(name)"
    }

    /// 平时：名称标签和整个名称框落在滚动区里（开头不被滚掉），整行显示；卖价、数字键、存好不用滚就点得到，键不低于 44pt
    func testDisplayKeepsWholeNameBoxOnScreen() {
        for ax in [false, true] {
            for name in [Self.water, Self.tea] {
                let app = launch("sell", ["-uiScan", "\(Self.unknown1),\(Self.unknown2)", "-uiNewName", name] + (ax ? Self.maxAX : []))
                let ctx = ctxName(app, name, ax)
                let field = el(app, "newProduct.name")
                wait("\(ctx) 名称填好") { (field.value as? String) == name }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let value = field.value as? String ?? ""
                XCTAssertEqual(value, name, "\(ctx) 名称值完整")
                XCTAssertFalse(value.contains("…"), "\(ctx) 名称值没被截断")
                let scroll = el(app, "newProduct.scroll").frame, label = el(app, "newProduct.nameLabel").frame, box = field.frame
                XCTAssertGreaterThanOrEqual(label.minY, scroll.minY - 1, "\(ctx) 名称标签没被滚出去 \(label) \(scroll)")
                XCTAssertLessThanOrEqual(box.maxY, scroll.maxY + 1, "\(ctx) 名称框整块在滚动区里 \(box) \(scroll)")
                let lines = wholeLines(box.height)
                XCTAssertNotNil(lines, "\(ctx) 名称框是整行高 \(box)")
                let n = lines ?? 0
                XCTAssertLessThanOrEqual(n, 3, "\(ctx) 显示时最多 3 行")
                if !isSmall(app) && !ax && name == Self.tea { XCTAssertEqual(n, 3, "\(ctx) 大屏三行名显示满 3 行") }
                if isSmall(app) && !ax { XCTAssertGreaterThanOrEqual(n, 2, "\(ctx) SE 默认字号不少于 2 行") }
                XCTAssertGreaterThanOrEqual(n, 1, "\(ctx) 至少 1 行")
                XCTAssertTrue(el(app, "newProduct.price").isHittable, "\(ctx) 卖价框点得到")
                XCTAssertTrue(el(app, "newProduct.keypad").exists, "\(ctx) 数字键盘在")
                XCTAssertTrue(app.buttons["newProduct.save"].isHittable, "\(ctx) 存好按钮点得到")
                let one = app.buttons["1"].firstMatch
                XCTAssertTrue(one.isHittable, "\(ctx) 数字键点得到")
                XCTAssertGreaterThanOrEqual(one.frame.height, 44 - 0.5, "\(ctx) 数字键不低于 44pt \(one.frame)")
                XCTAssertLessThanOrEqual(box.maxY, el(app, "newProduct.price").frame.minY, "\(ctx) 名称框在卖价上面")
                shot(app, "display", ax: ax, name: name)
                app.terminate()
            }
        }
    }

    /// 写名称时只留名称框和「写好了」：其它都收起来；名称框在顶栏和「写好了」之间完整可见，2～4 行；「写好了」不被键盘挡
    func testEditingShowsOnlyNameAndDoneButton() {
        for ax in [false, true] {
            let app = launch("sell", ["-uiScan", Self.unknown1, "-uiNewName", Self.tea] + (ax ? Self.maxAX : []))
            let ctx = ctxName(app, Self.tea, ax)
            let field = el(app, "newProduct.name")
            wait("\(ctx) 名称填好") { (field.value as? String) == Self.tea }
            field.tap()
            let done = app.buttons["newProduct.nameDone"]
            wait("\(ctx) 出现「写好了」") { done.exists && app.keyboards.firstMatch.exists }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            for id in ["newProduct.price", "newProduct.keypad", "newProduct.save", "newProduct.more", "newProduct.pack", "newProduct.code"] {
                XCTAssertFalse(el(app, id).exists, "\(ctx) 写名称时 \(id) 收起来")
            }
            XCTAssertTrue(done.isHittable, "\(ctx) 「写好了」点得到")
            XCTAssertGreaterThanOrEqual(done.frame.height, 56, "\(ctx) 「写好了」不低于 56pt \(done.frame)")
            let kb = app.keyboards.firstMatch.frame
            XCTAssertLessThanOrEqual(done.frame.maxY, kb.minY + 1, "\(ctx) 「写好了」在键盘上面 \(done.frame) \(kb)")
            let scroll = el(app, "newProduct.scroll").frame
            func checkBox(_ what: String, atLeast: Int) {
                let box = field.frame
                XCTAssertGreaterThanOrEqual(box.minY, scroll.minY - 1, "\(ctx) \(what) 名称框顶在顶栏下面 \(box) \(scroll)")
                XCTAssertLessThanOrEqual(box.maxY, done.frame.minY, "\(ctx) \(what) 名称框在「写好了」上面 \(box)")
                XCTAssertGreaterThanOrEqual(box.height, Self.oneLine + CGFloat(atLeast - 1) * Self.line - 4,
                                            "\(ctx) \(what) 至少 \(atLeast) 行 \(box)")
                XCTAssertLessThanOrEqual(box.height, Self.linesMax(4), "\(ctx) \(what) 最多 4 行 \(box)")
            }
            checkBox("三行名", atLeast: !isSmall(app) && !ax ? 3 : 2)
            shot(app, "editing", ax: ax, name: Self.tea)
            field.typeText(String(repeating: Self.tea, count: 2))
            checkBox("很长的名", atLeast: !isSmall(app) && !ax ? 4 : 2)
            XCTAssertEqual(field.value as? String, String(repeating: Self.tea, count: 3), "\(ctx) 打的字都在")
            done.tap()
            wait("\(ctx) 点「写好了」回到平时") { el(app, "newProduct.keypad").exists && !app.keyboards.firstMatch.exists }
            XCTAssertLessThanOrEqual(field.frame.height, Self.linesMax(3), "\(ctx) 平时回到最多 3 行")
            app.terminate()
        }
    }

    /// 「写好了」、扫码枪回车（\n）、键盘回车三条路一样：收键盘、名称不留换行、做名称检查、卖价和数字键回来；先填的卖价不丢
    func testThreeWaysToFinishNameAreTheSame() {
        let typed = "可乐6920152400319"
        for way in ["写好了", "扫码枪回车", "键盘回车"] {
            for ax in [false, true] {
                let app = launch("sell", ["-uiScan", Self.unknown1] + (ax ? Self.maxAX : []))
                let ctx = "\(isSmall(app) ? "SE" : "大屏") \(ax ? "最大辅助字号" : "默认字号") \(way)"
                keys(app, "12.5")
                let field = el(app, "newProduct.name")
                field.tap()
                wait("\(ctx) 进入写名称") { app.buttons["newProduct.nameDone"].exists && app.keyboards.firstMatch.exists }
                field.typeText(typed)
                switch way {
                case "写好了": app.buttons["newProduct.nameDone"].tap()
                case "扫码枪回车": field.typeText("\n")
                default:
                    let ret = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "done", "完成", "Return", "return", "换行"])).firstMatch
                    XCTAssertTrue(ret.exists, "\(ctx) 键盘上有回车键")
                    ret.tap()
                }
                wait("\(ctx) 收键盘、回到平时") { !app.keyboards.firstMatch.exists && el(app, "newProduct.keypad").exists }
                let value = field.value as? String ?? ""
                XCTAssertFalse(value.contains("\n"), "\(ctx) 名称不留换行")
                XCTAssertEqual(value, typed, "\(ctx) 名称和打的一样")
                XCTAssertTrue(el(app, "newProduct.nameNotice").waitForExistence(timeout: 3), "\(ctx) 做了名称检查（末尾像条码）")
                XCTAssertTrue(el(app, "newProduct.price").isHittable, "\(ctx) 卖价框回来")
                XCTAssertTrue(el(app, "newProduct.price").label.contains("12.5"), "\(ctx) 卖价没丢：\(el(app, "newProduct.price").label)")
                XCTAssertTrue(app.buttons["1"].firstMatch.isHittable, "\(ctx) 数字键回来")
                app.terminate()
            }
        }
    }

    /// 写名称中途往下拖收键盘：回到平时布局，名称和卖价都不丢
    func testDragDownKeepsNameAndPrice() {
        let app = launch("sell", ["-uiScan", Self.unknown1])
        keys(app, "12.5")
        let field = el(app, "newProduct.name")
        field.tap()
        wait("进入写名称") { app.buttons["newProduct.nameDone"].exists && app.keyboards.firstMatch.exists }
        field.typeText("雪碧 330ml")
        let scroll = el(app, "newProduct.scroll")
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).withOffset(CGVector(dx: 0, dy: 400)))
        wait("往下拖收起键盘") { !app.keyboards.firstMatch.exists && el(app, "newProduct.keypad").exists }
        XCTAssertEqual(field.value as? String, "雪碧 330ml", "名称不丢")
        XCTAssertTrue(el(app, "newProduct.price").label.contains("12.5"), "卖价不丢")
    }

    /// 名称 28pt 不随辅助字号变：空名单行框默认字号和最大辅助字号一样高
    func testNameFontDoesNotScaleWithAccessibilitySize() {
        var heights: [CGFloat] = []
        for ax in [false, true] {
            let app = launch("sell", ["-uiScan", Self.unknown1] + (ax ? Self.maxAX : []))
            heights.append(el(app, "newProduct.name").frame.height)
            app.terminate()
        }
        XCTAssertEqual(heights[0], Self.oneLine, accuracy: 4, "空名单行框")
        XCTAssertEqual(heights[0], heights[1], accuracy: 1, "两种字号名称框一样高：\(heights)")
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
