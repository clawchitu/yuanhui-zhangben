import XCTest

/// 设置页（家用 21a「更多」、收银员 21b「设置」）的「隐私政策」：和登录页一样用系统浏览器打开隐私政策网页，
/// 不再进 App 里「这一页还在做 / 开发计划 S21 段」的占位页（TestFlight 0.1.0 (11272333) 上强哥发现的）。
/// 用 `-uiFixture settings`（内存库 + 演示数据，没有服务 → 用默认地址 https://yuanhuishop.cn/privacy），不需要服务器。
@MainActor
final class PrivacyLinkUITests: XCTestCase {
    private func assertOpensBrowser(_ role: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "settings", "-uiRole", role]
        app.launch()
        XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10), file: file, line: line)
        let row = app.descendants(matching: .any)["settings.item.privacy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "「隐私政策」能点到", file: file, line: line)
        XCTAssertEqual(row.elementType, .link, "是外链，不是 App 内的导航行", file: file, line: line)
        row.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "点了以后系统浏览器到前台", file: file, line: line)
        // 回到 App：还停在设置页，没有推进占位页
        app.activate()
        XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertFalse(app.otherElements["page.privacy"].exists, "不出 App 内的隐私政策页", file: file, line: line)
        XCTAssertFalse(app.staticTexts["这一页还在做"].exists, "不出占位页", file: file, line: line)
        XCTAssertFalse(app.staticTexts["开发计划 S21 段"].exists, file: file, line: line)
    }

    func testFamilyPrivacyOpensBrowserNotPlaceholder() throws {
        assertOpensBrowser("family")
    }

    func testCashierPrivacyOpensBrowserNotPlaceholder() throws {
        assertOpensBrowser("cashier")
    }
}
