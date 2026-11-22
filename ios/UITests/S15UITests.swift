import Vision
import XCTest

/// S15 的界面验收：权限遍历、首次进入、设置、提醒顺序、最大辅助字号、小号步进器点按区域。
/// 全部用 `-uiFixture` / `-uiRole`（内存库 + 演示数据），不需要服务器。
@MainActor
final class S15UITests: XCTestCase {
    /// 收银员到不了的页（S15 验收逐项列出的 6 个 + 设备管理、账号、改名）
    static let cashierForbidden: Set<String> = ["page.stockIn", "page.reports", "page.products", "page.count",
                                                "page.expiry", "page.pairing", "page.devices", "page.account",
                                                "page.deviceName"]

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    private static let maxAXSize = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    // MARK: - 权限遍历

    /// 收银员该到的页（遍历确实走到了，不是空跑）
    static let cashierReachable: Set<String> = ["page.home", "page.sell", "page.settings", "page.records", "page.undoLast",
                                                "page.scanner", "page.privacy", "page.logout"]

    private func assertCashierWalk(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) {
        let walker = Walker(args: ["-uiFixture", fixture, "-uiRole", "cashier", "-uiLargeText", "off"])
        let visited = walker.run()
        print("收银员（\(fixture)）能到的页：\(visited.sorted())")
        walker.assertEverythingCovered(file: file, line: line)
        XCTAssertTrue(visited.isDisjoint(with: Self.cashierForbidden),
                      "收银员到了：\(visited.intersection(Self.cashierForbidden))", file: file, line: line)
        XCTAssertFalse(visited.contains("page.denied"), "收银员界面上出现了没能力的入口", file: file, line: line)
        XCTAssertTrue(visited.isSuperset(of: Self.cashierReachable), "\(visited)", file: file, line: line)
        assertSellEmptyGreyed(walker, file: file, line: line)
    }

    /// 卖出页空篮：记账和抹零按钮置灰是允许的（遍历时记为「置灰（允许）」，不算没点到）
    private func assertSellEmptyGreyed(_ walker: Walker, file: StaticString, line: UInt) {
        for id in ["sell.commit", "sell.discount"] {
            XCTAssertTrue(walker.covered(page: "page.sell", label: id), "\(id) 应被列为允许置灰", file: file, line: line)
        }
    }

    /// 验收：收银员形态下遍历所有可点元素，到不了进货、看账、商品、盘点、快过期、开通（普通首页 02）
    func testCashierTraversalNeverReachesFamilyPages() throws {
        assertCashierWalk("home")
    }

    /// 同上，未同步首页（多一条可点的「没传上去」提醒条）
    func testCashierTraversalNeverReachesFamilyPagesUnsynced() throws {
        assertCashierWalk("home-unsynced")
    }

    private func assertFamilyWalk(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) -> Walker {
        let walker = Walker(args: ["-uiFixture", fixture, "-uiRole", "family", "-uiLargeText", "off"])
        let visited = walker.run()
        print("家用（\(fixture)）能到的页：\(visited.sorted())")
        walker.assertEverythingCovered(file: file, line: line)
        XCTAssertTrue(visited.isSuperset(of: Self.cashierForbidden),
                      "家用到不了：\(Self.cashierForbidden.subtracting(visited))", file: file, line: line)
        // S20（§14 S15-6）：家用首页没有提醒条时「刚记的」整条可点进记的账，必达集合加回 page.records
        XCTAssertTrue(visited.isSuperset(of: ["page.home", "page.sell", "page.settings", "page.records", "page.undoLast",
                                              "page.scanner", "page.privacy", "page.logout"]), "\(visited)", file: file, line: line)
        XCTAssertFalse(visited.contains("page.denied"), file: file, line: line)
        assertSellEmptyGreyed(walker, file: file, line: line)
        // 弹窗分支（「自己填…」）每个按钮都按过，填的名字出现后也被点过
        XCTAssertTrue(walker.covered(page: "alert.给这台手机起个名字", label: "不填了"), file: file, line: line)
        XCTAssertTrue(walker.covered(page: "alert.给这台手机起个名字", label: "好了"), file: file, line: line)
        XCTAssertTrue(walker.covered(page: "page.deviceName", label: "name.\(Walker.typedName)"), "填的名字成了新的一块并被点过",
                      file: file, line: line)
        return walker
    }

    /// 验收：家用形态下这些页都能到（普通首页 01）
    func testFamilyTraversalReachesEveryPage() throws {
        _ = assertFamilyWalk("home")
    }

    /// 同上，未同步首页（25a）：「没传上去」提醒条进得了记的账
    func testFamilyTraversalReachesEveryPageUnsynced() throws {
        let walker = assertFamilyWalk("home-unsynced")
        XCTAssertTrue(walker.visited.contains("page.records"))
        XCTAssertTrue(walker.covered(page: "page.home", label: "home.banner.unsynced"))
    }

    /// 第二道防线：把收银员没能力的路由直接塞进导航栈，出的是「用不了」页；返回再回到它时仍然是「用不了」，
    /// 退回首页和设置页上也没有它的入口
    func testInjectedForbiddenRoutesStayDenied() throws {
        for route in Self.cashierForbidden.sorted() {
            let r = String(route.dropFirst("page.".count))
            // 栈：首页 → 设置 → 硬塞的 r → 设置
            let app = launch(["-uiFixture", "home", "-uiRole", "cashier", "-uiRoute", "settings,\(r),settings"])
            let back = { app.buttons.matching(NSPredicate(format: "label == '返回'")).allElementsBoundByIndex.last { $0.isHittable } }
            XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10), r)
            back()?.tap()
            let denied = app.otherElements["page.denied"]
            XCTAssertTrue(denied.waitForExistence(timeout: 5), "\(r)：返回到硬塞的路由，仍是「用不了」")
            XCTAssertTrue(denied.isHittable, r)
            XCTAssertFalse(app.otherElements[route].exists, "\(r) 的真页面不应出现")
            back()?.tap()
            XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 5), r)
            XCTAssertFalse(app.otherElements["page.denied"].exists, r)
            XCTAssertFalse(app.descendants(matching: .any)["settings.item.\(r)"].exists, "设置页上没有 \(r) 的入口")
            back()?.tap()
            XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 5), r)
            XCTAssertFalse(app.descendants(matching: .any)["home.\(r)"].exists, "首页没有 \(r) 的入口")
            app.terminate()
        }
        // 对照：家用塞同样的路由进得去（证明 -uiRoute 真把路由塞进了栈）
        let app = launch(["-uiFixture", "home", "-uiRole", "family", "-uiRoute", "stockIn"])
        XCTAssertTrue(app.otherElements["page.stockIn"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["page.denied"].exists)
    }

    // MARK: - 16 / 16b

    /// 验收：16 默认选中大字，选择保存在本机，重启后保持
    func testOnboardingDefaultsToLargeAndChoiceSurvivesRestart() throws {
        var app = launch(["-uiRole", "family", "-uiFreshInstall"])
        XCTAssertTrue(app.otherElements["page.onboarding"].waitForExistence(timeout: 10))
        let large = app.buttons["onboarding.large"], standard = app.buttons["onboarding.standard"]
        XCTAssertEqual(large.value as? String, "已选", "刚装好时默认选中大字")
        XCTAssertTrue(large.isSelected)
        XCTAssertEqual(standard.value as? String, "没选")
        XCTAssertTrue(app.buttons["name.柜台手机"].isSelected, "默认名字是稿子上的「柜台手机」")

        standard.tap()
        XCTAssertEqual(standard.value as? String, "已选")
        XCTAssertEqual(large.value as? String, "没选")
        app.buttons["name.妈妈的手机"].tap()
        app.buttons["onboarding.done"].tap()
        XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["妈妈的手机"].exists, "起的名字出现在首页")
        try assertLargeTextSwitch(app, on: false)

        // 重启：不再出 16，标准模式仍然生效
        app.terminate()
        app = launch(["-uiRole", "family"])
        XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 10), "重启后直接进首页")
        XCTAssertFalse(app.otherElements["page.onboarding"].exists)
        try assertLargeTextSwitch(app, on: false)

        // 再装一次（清掉本机设置）：又是默认大字
        app.terminate()
        app = launch(["-uiRole", "family", "-uiFreshInstall"])
        XCTAssertTrue(app.otherElements["page.onboarding"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["onboarding.large"].value as? String, "已选")
    }

    private func assertLargeTextSwitch(_ app: XCUIApplication, on: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        app.buttons["home.more"].tap()
        let toggle = app.switches["settings.item.largeText"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "设置里的大字模式开关", file: file, line: line)
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// 验收：16b 不出现起名
    func testCashierOnboardingHasNoNaming() throws {
        let app = launch(["-uiFixture", "onboarding", "-uiRole", "cashier", "-uiFreshInstall"])
        XCTAssertTrue(app.otherElements["page.onboarding"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["onboarding.large"].value as? String, "已选")
        XCTAssertFalse(app.staticTexts["给这台手机起个名字"].exists)
        XCTAssertFalse(app.buttons["name.custom"].exists)
        XCTAssertFalse(app.buttons["name.柜台手机"].exists)
        // 只显示开通时起的称呼（会话里的手机名「小王的手机」），不能改
        let device = app.descendants(matching: .any)["onboarding.cashierDevice"]
        XCTAssertTrue(device.exists, "16b 有收银员手机卡")
        // 卡片读出来是「手机名, 收银员 · 名字是开通时起的」：第一段必须正好是会话里的手机名
        let name = device.label.components(separatedBy: ", ").first
        XCTAssertEqual(name, "小王的手机", "手机卡上是会话里的手机名：\(device.label)")
        XCTAssertFalse(device.label.contains("柜台手机"))
        // 收银员看不到库存：样例下面写的是「刚扫的 · 单价」，不是「还剩 126 罐」
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '还剩'")).firstMatch.exists)
        app.buttons["onboarding.done"].tap()
        XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 5))
    }

    /// 家用 16 有起名
    func testFamilyOnboardingHasNaming() throws {
        let app = launch(["-uiFixture", "onboarding", "-uiRole", "family"])
        XCTAssertTrue(app.otherElements["page.onboarding"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["给这台手机起个名字"].exists)
        for n in ["柜台手机", "爸爸的手机", "妈妈的手机"] {
            XCTAssertTrue(app.buttons["name.\(n)"].exists, n)
        }
        XCTAssertTrue(app.buttons["name.custom"].exists, "自己填…")
    }

    // MARK: - 21b

    /// 验收：21b 恰好五项
    func testCashierSettingsHasExactlyFiveItems() throws {
        let app = launch(["-uiFixture", "settings", "-uiRole", "cashier"])
        XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10))
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.item.'"))
        let ids = Set(items.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(items.count, 5, "\(ids)")
        XCTAssertEqual(ids, ["settings.item.largeText", "settings.item.scanner", "settings.item.privacy",
                             "settings.item.logout", "settings.item.version"])
    }

    // MARK: - 25a

    /// 验收：「没同步」和「快过期」两条提醒同时出现时没同步的在上
    func testUnsyncedReminderAboveExpiring() throws {
        let app = launch(["-uiFixture", "home-unsynced", "-uiRole", "family"])
        let unsynced = app.buttons["home.banner.unsynced"], expiring = app.buttons["home.banner.expiring"]
        XCTAssertTrue(unsynced.waitForExistence(timeout: 10))
        XCTAssertTrue(expiring.exists)
        XCTAssertLessThan(unsynced.frame.maxY, expiring.frame.minY + 0.5, "没同步的在上")
        // 顶栏同步状态（占位用的隐藏副本也带同一标识，取看得见的那个）
        let sync = app.descendants(matching: .any).matching(identifier: "syncStatus").allElementsBoundByIndex
            .filter(\.isHittable)
        XCTAssertEqual(sync.count, 1, "顶栏只有一个看得见的同步状态")
        XCTAssertTrue(sync.first?.label.contains("5 笔待传") == true, "顶栏同步状态：\(sync.map(\.label))")
    }

    // MARK: - 最大辅助字号

    /// 验收：系统最大辅助字号下首页两个大按钮不被截断（大字 / 标准 × 家用 / 收银员）。
    /// 卡片整个在屏内、左右不出边距；卡片上实际画出来的字用文字识别读出来，必须完整（被截断会少字或出「…」）。
    func testHomeBigButtonsFitAtMaxAccessibilitySize() throws {
        let expected: [String: [String]] = [
            "home.sell": ["卖出", "顾客买东西", "点这里扫码"],
            "home.stockIn": ["进货", "货送到了", "点这里扫码"],
        ]
        for role in ["family", "cashier"] {
            for mode in ["on", "off"] {
                let app = launch(["-uiFixture", "home-unsynced", "-uiRole", role, "-uiLargeText", mode] + Self.maxAXSize)
                XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 10))
                let window = app.windows.firstMatch.frame
                let cards = role == "family" ? ["home.sell", "home.stockIn"] : ["home.sell"]
                for id in cards {
                    let card = app.buttons[id]
                    XCTAssertTrue(card.exists, "\(role) \(mode) \(id)")
                    let visible = Self.scrollFullyIntoView(card, in: app)
                    XCTAssertTrue(visible, "\(role) \(mode) \(id) 能整个滚进屏幕")
                    let f = card.frame
                    XCTAssertGreaterThanOrEqual(f.minX, window.minX + 19, "\(id) 左边不出屏")
                    XCTAssertLessThanOrEqual(f.maxX, window.maxX - 19, "\(id) 右边不出屏")
                    XCTAssertGreaterThanOrEqual(f.height, 150, "\(role) \(mode) \(id) 高度")
                    let text = try Self.recognizedText(card)
                    var parts = expected[id]!
                    if role == "cashier" { parts.append("抹零也在这里面") }
                    for part in parts {
                        XCTAssertTrue(text.contains(part), "\(role) \(mode) \(id) 画出来的字缺「\(part)」：\(text)")
                    }
                    XCTAssertFalse(text.contains("…") || text.contains("..."), "\(role) \(mode) \(id) 被截断：\(text)")
                }
                app.terminate()
            }
        }
    }

    /// 把元素整个滚进首页的可视区（标题栏下面到屏幕底）
    private static func scrollFullyIntoView(_ el: XCUIElement, in app: XCUIApplication) -> Bool {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 {
            let area = scroll.exists ? scroll.frame : app.windows.firstMatch.frame
            let f = el.frame
            if f.minY >= area.minY - 0.5 && f.maxY <= area.maxY + 0.5 { return true }
            scroll.edgeDrag(showMoreBelow: f.maxY > area.maxY)
        }
        return false
    }

    /// 元素在屏幕上画出来的字（文字识别，去掉空白）
    static func recognizedText(_ el: XCUIElement) throws -> String {
        let shot = el.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .deleteOnSuccess
        XCTContext.runActivity(named: "识别 \(el.identifier)") { $0.add(attachment) }
        let cg = try XCTUnwrap(shot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    // MARK: - 小号步进器

    /// 验收：小号步进器（46pt 圆钮）的点按区域不小于 56pt —— 点在圆钮外、56pt 框内也算按到
    func testCompactStepperHitAreaExtendsBeyondCircle() throws {
        let app = launch(["-uiFixture", "gallery-3", "-uiLargeText", "on"])
        let stepper = app.descendants(matching: .any)["gallery.stepperCompact"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 10))
        XCTAssertEqual(stepper.value as? String, "4")
        XCTAssertGreaterThanOrEqual(stepper.frame.height, 56)
        // 「−」圆钮中心在 (28, 中线)；点它正上方 26pt：在 46pt 圆（半径 23）外，在 56pt 框（半边 28）内
        let origin = stepper.coordinate(withNormalizedOffset: .zero)
        let midY = stepper.frame.height / 2
        origin.withOffset(CGVector(dx: 28, dy: midY - 26)).tap()
        XCTAssertEqual(stepper.value as? String, "3", "圆钮外 3pt 也能按到「−」")
        // 「＋」圆钮正下方 26pt
        origin.withOffset(CGVector(dx: stepper.frame.width - 28, dy: midY + 26)).tap()
        XCTAssertEqual(stepper.value as? String, "4", "圆钮外 3pt 也能按到「＋」")
    }
}


/// 从首页出发，把每一页上所有能点的东西（按钮、链接、开关、单元格，以及弹窗里的按钮）都点一遍，记下到过哪些页。
/// - 每页先从顶滚到底收集入口（屏外的也算），点完一个就重新枚举一次（开关、选名字这类会改变页面的操作之后，新冒出来的入口也要点）。
/// - 点出弹窗时，弹窗里每个按钮都分别走一遍（要填字的先填上），不是直接关掉。
/// - 找到的每个入口都要有结果：点到了哪一页 / 留在本页 / 弹窗；点不到、找不到的记进 `uncovered`，测试据此失败，不静默跳过。
/// - 页面根视图带 `page.*` 标识；点完回到原来那页（按「返回」，回不去就重启后按原路重走）。
@MainActor
final class Walker {
    struct Key: Hashable, CustomStringConvertible {
        let type: XCUIElement.ElementType
        /// 有标识用标识；没有才用文字（文字会随状态变，例如设置行右边的小字）
        let identifier: String
        let label: String
        init(type: XCUIElement.ElementType, identifier: String, label: String) {
            self.type = type
            self.identifier = identifier
            self.label = identifier.isEmpty ? label : ""
        }
        var description: String {
            if !identifier.isEmpty { return identifier }
            let kind = [.switch: "开关", .button: "按钮", .cell: "单元格", .link: "链接"][type] ?? "\(type.rawValue) 号元素"
            return label.isEmpty ? "（没有文字的\(kind)）" : label
        }
    }

    /// 一条路：从首页起依次点哪些入口（`alertButton` 非空 = 点开弹窗后再按这个按钮）
    struct Step { let key: Key; let alertButton: String? }

    struct Record: CustomStringConvertible {
        let page: String
        let item: String
        let outcome: String
        var description: String { "\(page) · \(item) → \(outcome)" }
    }

    /// 「自己填…」弹窗里填的名字
    static let typedName = "遍历填的名"
    /// 只用来导航的「返回」：不当作待测入口（每次回原页都在按它）
    static let navigationOnly: Set<String> = ["返回"]
    /// 允许置灰的入口（页面 · 标识）：卖出页空篮时的「收好钱了，记账」和「抹零 / 改总价」（S16 验收：空篮置灰）
    /// 空篮时记账、改价灰；手输条码页没选中候选时「加进去」灰（§5.5，S17）
    static let allowedDisabled: Set<String> = ["page.sell · sell.commit", "page.sell · sell.discount", "page.manualCode · manual.pick"]

    let args: [String]
    var app: XCUIApplication
    private(set) var visited: Set<String> = []
    private(set) var records: [Record] = []
    private(set) var uncovered: [String] = []
    private(set) var tapped = 0
    let maxDepth = 5

    init(args: [String]) {
        self.args = args
        app = XCUIApplication()
    }

    func run() -> Set<String> {
        relaunch()
        explore(path: [])
        print("遍历共点了 \(tapped) 次，记录 \(records.count) 条：\n" + records.map(\.description).joined(separator: "\n"))
        return visited
    }

    func covered(page: String, label: String) -> Bool {
        records.contains { $0.page == page && $0.item == label }
    }

    func assertEverythingCovered(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(uncovered.isEmpty, "这些入口没点到：\(uncovered)", file: file, line: line)
        XCTAssertGreaterThan(records.count, 5, "遍历没有真正点东西", file: file, line: line)
    }

    // MARK: 启动、等待、当前页

    private func relaunch() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        _ = app.otherElements["page.home"].waitForExistence(timeout: 10)
    }

    private func settle() { Thread.sleep(forTimeInterval: 0.6) }

    private var alert: XCUIElement { app.alerts.firstMatch }

    /// 当前最上面那一页的标识
    func currentPage() -> String {
        let pages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'page.'"))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        return pages.last?.identifier ?? pages.first?.identifier ?? "?"
    }

    // MARK: 枚举入口（从顶滚到底）

    private static let tappableTypes: [XCUIElement.ElementType] = [.button, .link, .switch, .cell]

    /// 取快照，失败重试几次；仍失败就记进 `uncovered`（不当成「没有入口」或「滚到底了」静默放过）
    private func snapshot(of el: XCUIElement, _ what: String) -> XCUIElementSnapshot? {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try el.snapshot() } catch { lastError = error }
            if attempt < 2 { settle() }
        }
        uncovered.append("\(currentPage())：\(what)取快照失败 3 次（\(lastError.map { "\($0)" } ?? "?")）")
        return nil
    }

    private func snapshotKeys(into out: inout [Key], seen: inout Set<Key>) -> [String]? {
        guard let snap = snapshot(of: app, "枚举入口时") else { return nil }
        var signature: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if Self.tappableTypes.contains(s.elementType), !s.frame.isEmpty {
                let k = Key(type: s.elementType, identifier: s.identifier, label: s.label)
                signature.append("\(k)@\(Int(s.frame.minY))")
                if seen.insert(k).inserted { out.append(k) }
                if !s.isEnabled {
                    let item = "\(currentPage()) · \(k)"
                    if Self.allowedDisabled.contains(item) {
                        if !records.contains(where: { "\($0.page) · \($0.item)" == item }) {
                            records.append(Record(page: currentPage(), item: k.description, outcome: "置灰（允许）"))
                        }
                    } else {
                        uncovered.append("\(item) 不可用（灰）")
                    }
                }
            }
            s.children.forEach(walk)
        }
        walk(snap)
        return signature
    }

    private var scrollView: XCUIElement? {
        let s = app.scrollViews.firstMatch
        return s.exists && s.isHittable ? s : nil
    }

    /// 滚动视图里内容的上下沿（SwiftUI 的 ScrollView 里不是懒加载的，屏外的元素也在树里）
    private func contentExtent(_ scroll: XCUIElement) -> (top: CGFloat, bottom: CGFloat)? {
        guard let snap = snapshot(of: scroll, "判断能否滚动时") else { return nil }
        var top = CGFloat.infinity, bottom = -CGFloat.infinity
        func walk(_ s: XCUIElementSnapshot) {
            if !s.frame.isEmpty { top = min(top, s.frame.minY); bottom = max(bottom, s.frame.maxY) }
            s.children.forEach(walk)
        }
        snap.children.forEach(walk)
        return top.isFinite ? (top, bottom) : nil
    }

    /// 上面还有没露出来的内容
    private func canScrollUp(_ scroll: XCUIElement) -> Bool {
        guard let e = contentExtent(scroll) else { return false }
        return e.top < scroll.frame.minY - 1
    }

    /// 下面还有没露出来的内容
    private func canScrollDown(_ scroll: XCUIElement) -> Bool {
        guard let e = contentExtent(scroll) else { return false }
        return e.bottom > scroll.frame.maxY + 1
    }

    private func scrollToTop() {
        guard let s = scrollView else { return }
        var n = 0
        while n < 10 && canScrollUp(s) { s.edgeDrag(showMoreBelow: false); n += 1 }
    }

    func enumerate() -> [Key] {
        var keys: [Key] = [], seen = Set<Key>()
        scrollToTop()
        let page = currentPage()
        // 取不到快照已记进 uncovered；不再往下滚，免得把失败当成到底
        guard var sig = snapshotKeys(into: &keys, seen: &seen) else { return [] }
        // 内容比可视区高：一段一段滚到底，每段都收集一遍
        if let s = scrollView, canScrollDown(s) {
            for _ in 0..<12 {
                s.edgeDrag(showMoreBelow: true)
                if currentPage() != page { uncovered.append("\(page)：滚动时误点进了 \(currentPage())"); break }
                guard let next = snapshotKeys(into: &keys, seen: &seen) else { break }
                if next == sig || !canScrollDown(s) { break }  // 到底了
                sig = next
            }
            scrollToTop()
        }
        return keys.filter { !Self.navigationOnly.contains($0.label) }
    }

    private func find(_ k: Key, in root: XCUIElement? = nil) -> XCUIElement {
        let q = (root ?? app).descendants(matching: k.type)
        return k.identifier.isEmpty ? q.matching(NSPredicate(format: "label == %@", k.label)).firstMatch
                                    : q.matching(identifier: k.identifier).firstMatch
    }

    /// 把元素滚到能点的位置
    private func reveal(_ el: XCUIElement) -> Bool {
        guard el.exists else { return false }
        if el.isHittable { return true }
        guard let s = scrollView else { return false }
        scrollToTop()
        for _ in 0..<12 {
            if el.isHittable || !canScrollDown(s) { break }
            s.edgeDrag(showMoreBelow: true)
        }
        return el.isHittable
    }

    // MARK: 遍历

    private func explore(path: [Step]) {
        let here = currentPage()
        visited.insert(here)
        var done = Set<Key>()
        while true {
            guard ensureAt(path: path, page: here) else {
                uncovered.append("\(here)：回不到这一页（路径 \(path.map(\.key))）")
                return
            }
            // 每点一次都重新枚举：状态变了（开关、选名字、填了名字）冒出来的新入口也要点
            guard let key = enumerate().first(where: { !done.contains($0) }) else { break }
            done.insert(key)
            guard path.count < maxDepth else {
                uncovered.append("\(here) · \(key) 太深（\(path.count) 层）没点")
                continue
            }
            let el = find(key)
            guard reveal(el) else {
                uncovered.append("\(here) · \(key) 点不到")
                continue
            }
            el.tap()
            tapped += 1
            settle()
            if alert.exists {
                exploreAlert(opener: key, path: path, page: here)
                continue
            }
            let now = currentPage()
            records.append(Record(page: here, item: key.description, outcome: now == here ? "留在本页" : now))
            if now != here && !visited.contains(now) {
                explore(path: path + [Step(key: key, alertButton: nil)])
            }
            visited.insert(now)
        }
    }

    /// 弹窗：每个按钮分别走一遍（有输入框的先填字），按完看去了哪儿
    private func exploreAlert(opener: Key, path: [Step], page: String) {
        let title = alert.label
        let alertPage = "alert.\(title)"
        visited.insert(alertPage)
        records.append(Record(page: page, item: opener.description, outcome: alertPage))
        let buttons = alert.buttons.allElementsBoundByIndex.map(\.label)
        if buttons.isEmpty { uncovered.append("\(alertPage) 没有按钮") }
        for (i, label) in buttons.enumerated() {
            if i > 0 {
                // 重新打开弹窗
                guard ensureAt(path: path, page: page) else {
                    uncovered.append("\(alertPage) · \(label)：回不到 \(page)")
                    continue
                }
                let el = find(opener)
                guard reveal(el) else { uncovered.append("\(alertPage) · \(label)：重新打开弹窗时点不到 \(opener)"); continue }
                el.tap()
                settle()
            }
            guard alert.waitForExistence(timeout: 3) else {
                uncovered.append("\(alertPage) · \(label)：弹窗没再出来")
                continue
            }
            let field = alert.textFields.firstMatch
            if field.exists {
                field.tap()
                field.typeText(Self.typedName)
            }
            let button = alert.buttons[label]
            guard button.exists else { uncovered.append("\(alertPage) · \(label) 找不到"); continue }
            button.tap()
            tapped += 1
            settle()
            let now = alert.exists ? alertPage : currentPage()
            if alert.exists { uncovered.append("\(alertPage) · \(label) 按了弹窗没关") }
            records.append(Record(page: alertPage, item: label, outcome: now == page ? "回到本页" : now))
            if now != page && now != alertPage && !visited.contains(now) {
                explore(path: path + [Step(key: opener, alertButton: label)])
            }
            visited.insert(now)
        }
    }

    /// 回到 `page`：先按「返回」，回不去就重启按原路重走。到不了返回 false。
    private func ensureAt(path: [Step], page: String) -> Bool {
        if alert.exists { alert.buttons.firstMatch.tap(); settle() }
        if currentPage() == page { return true }
        for _ in 0..<6 {
            let back = app.buttons.matching(NSPredicate(format: "label == '返回'")).allElementsBoundByIndex.last { $0.isHittable }
            guard let back else { break }
            back.tap()
            settle()
            if currentPage() == page { return true }
        }
        relaunch()
        for step in path {
            let el = find(step.key)
            guard reveal(el) else { return false }
            el.tap()
            settle()
            if let label = step.alertButton {
                guard alert.waitForExistence(timeout: 3) else { return false }
                let field = alert.textFields.firstMatch
                if field.exists { field.tap(); field.typeText(Self.typedName) }
                alert.buttons[label].tap()
                settle()
            }
        }
        return currentPage() == page
    }
}

extension XCUIElement {
    /// 贴着滚动视图左边缘拖半屏、停住再松手（没有惯性，一次挪多少可预期）。
    /// 不从中间拖：内容放得下时滚动视图不接手势，从大卡片上拖会被当成点了卡片。
    func edgeDrag(showMoreBelow: Bool) {
        let a = coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: showMoreBelow ? 0.8 : 0.3))
        let b = coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: showMoreBelow ? 0.3 : 0.8))
        a.press(forDuration: 0.01, thenDragTo: b, withVelocity: .default, thenHoldForDuration: 0.15)
    }
}
