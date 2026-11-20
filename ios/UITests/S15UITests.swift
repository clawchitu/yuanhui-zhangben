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

    /// 验收：收银员形态下遍历所有可点元素，到不了进货、看账、商品、盘点、快过期、开通
    func testCashierTraversalNeverReachesFamilyPages() throws {
        let walker = Walker(args: ["-uiFixture", "home", "-uiRole", "cashier", "-uiLargeText", "off"])
        let visited = walker.run()
        print("收银员能到的页：\(visited.sorted())")
        XCTAssertTrue(visited.isDisjoint(with: Self.cashierForbidden), "收银员到了：\(visited.intersection(Self.cashierForbidden))")
        XCTAssertFalse(visited.contains("page.denied"), "收银员界面上出现了没能力的入口")
        // 遍历本身确实走到了收银员该到的地方
        XCTAssertTrue(visited.isSuperset(of: ["page.home", "page.sell", "page.settings", "page.records", "page.undoLast",
                                              "page.scanner", "page.privacy", "page.logout"]), "\(visited)")
    }

    /// 验收：家用形态下这些页都能到
    func testFamilyTraversalReachesEveryPage() throws {
        let walker = Walker(args: ["-uiFixture", "home", "-uiRole", "family", "-uiLargeText", "off"])
        let visited = walker.run()
        print("家用能到的页：\(visited.sorted())")
        XCTAssertTrue(visited.isSuperset(of: Self.cashierForbidden), "家用到不了：\(Self.cashierForbidden.subtracting(visited))")
        XCTAssertTrue(visited.isSuperset(of: ["page.home", "page.sell", "page.settings", "page.records", "page.undoLast",
                                              "page.scanner", "page.privacy", "page.logout"]), "\(visited)")
        XCTAssertFalse(visited.contains("page.denied"))
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
        let app = launch(["-uiFixture", "onboarding", "-uiRole", "cashier"])
        XCTAssertTrue(app.otherElements["page.onboarding"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["onboarding.large"].value as? String, "已选")
        XCTAssertFalse(app.staticTexts["给这台手机起个名字"].exists)
        XCTAssertFalse(app.buttons["name.custom"].exists)
        XCTAssertFalse(app.buttons["name.柜台手机"].exists)
        XCTAssertTrue(app.otherElements["onboarding.cashierDevice"].exists || app.staticTexts["小王的手机"].exists)
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
        for n in ["柜台手机", "爸爸的手机", "妈妈的手机", "自己填…"] {
            XCTAssertTrue(app.buttons["name.\(n)"].exists, n)
        }
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
        XCTAssertTrue(app.staticTexts["5 笔待传"].exists || app.descendants(matching: .any)["syncStatus"].label.contains("5 笔待传"))
    }

    // MARK: - 最大辅助字号

    /// 验收：系统最大辅助字号下首页两个大按钮不被截断（大字 / 标准 × 家用 / 收银员）
    func testHomeBigButtonsFitAtMaxAccessibilitySize() throws {
        for role in ["family", "cashier"] {
            for mode in ["on", "off"] {
                let app = launch(["-uiFixture", "home-unsynced", "-uiRole", role, "-uiLargeText", mode] + Self.maxAXSize)
                XCTAssertTrue(app.otherElements["page.home"].waitForExistence(timeout: 10))
                let window = app.windows.firstMatch.frame
                let cards = role == "family" ? ["home.sell", "home.stockIn"] : ["home.sell"]
                for id in cards {
                    let card = app.buttons[id]
                    XCTAssertTrue(card.exists, "\(role) \(mode) \(id)")
                    var tries = 0
                    while !card.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
                    XCTAssertTrue(card.isHittable, "\(role) \(mode) \(id) 可点")
                    let f = card.frame
                    XCTAssertGreaterThanOrEqual(f.minX, window.minX + 19, "\(id) 左边不出屏")
                    XCTAssertLessThanOrEqual(f.maxX, window.maxX - 19, "\(id) 右边不出屏")
                    XCTAssertGreaterThanOrEqual(f.height, 150, "\(role) \(mode) \(id) 高度")
                    XCTAssertTrue(card.label.contains("点这里扫码"), "按钮文字完整：\(card.label)")
                }
                app.terminate()
            }
        }
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

/// 从首页出发，把每一页上所有能点的东西（按钮、链接、开关、单元格）都点一遍，记下到过哪些页。
/// 页面根视图带 `page.*` 标识；点完一个回到原来那页（按「返回」，回不去就重启后按原路重走）。
@MainActor
final class Walker {
    struct Key: Hashable, CustomStringConvertible {
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        var description: String { identifier.isEmpty ? label : identifier }
    }

    let args: [String]
    var app: XCUIApplication
    var visited: Set<String> = []
    var tapped = 0
    let maxDepth = 4

    init(args: [String]) {
        self.args = args
        app = XCUIApplication()
    }

    func run() -> Set<String> {
        relaunch()
        explore(path: [])
        print("遍历共点了 \(tapped) 次")
        return visited
    }

    private func relaunch() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        _ = app.otherElements["page.home"].waitForExistence(timeout: 10)
    }

    private func settle() { Thread.sleep(forTimeInterval: 0.7) }

    /// 当前最上面那一页的标识
    func currentPage() -> String {
        let pages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'page.'"))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        return pages.last?.identifier ?? pages.first?.identifier ?? "?"
    }

    private func tappables() -> [Key] {
        guard let snap = try? app.snapshot() else { return [] }
        var out: [Key] = []
        var seen = Set<Key>()
        func walk(_ s: XCUIElementSnapshot) {
            if [.button, .link, .switch, .cell].contains(s.elementType), s.isEnabled, !s.frame.isEmpty,
               s.label != "返回" {
                let k = Key(type: s.elementType, identifier: s.identifier, label: s.label)
                if seen.insert(k).inserted { out.append(k) }
            }
            s.children.forEach(walk)
        }
        walk(snap)
        return out
    }

    private func find(_ k: Key) -> XCUIElement {
        let q = app.descendants(matching: k.type)
        return k.identifier.isEmpty ? q.matching(NSPredicate(format: "label == %@", k.label)).firstMatch
                                    : q.matching(identifier: k.identifier).firstMatch
    }

    private func dismissAlerts() {
        let alert = app.alerts.firstMatch
        if alert.exists {
            let cancel = alert.buttons["不填了"]
            (cancel.exists ? cancel : alert.buttons.firstMatch).tap()
            settle()
        }
    }

    private func explore(path: [Key]) {
        let here = currentPage()
        visited.insert(here)
        guard path.count < maxDepth else { return }
        for key in tappables() {
            ensureAt(path: path, page: here)
            let el = find(key)
            guard el.exists, el.isHittable else { continue }
            el.tap()
            tapped += 1
            settle()
            dismissAlerts()
            let now = currentPage()
            if now != here {
                if !visited.contains(now) {
                    explore(path: path + [key])
                } else {
                    visited.insert(now)
                }
            }
        }
    }

    private func ensureAt(path: [Key], page: String) {
        if currentPage() == page { return }
        for _ in 0..<6 {
            let back = app.buttons.matching(NSPredicate(format: "label == '返回'")).allElementsBoundByIndex.last { $0.isHittable }
            guard let back else { break }
            back.tap()
            settle()
            if currentPage() == page { return }
        }
        relaunch()
        for k in path {
            let el = find(k)
            if el.exists && el.isHittable { el.tap(); settle() }
        }
    }
}
