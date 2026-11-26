import XCTest

/// 设置页底部的 App 备案号：家用、收银员都显示「苏ICP备2026094233号-2A」，点了在 Safari 打开工信部备案查询页。
/// 用 `-uiFixture settings`（内存库 + 演示数据），不需要服务器。
@MainActor
final class ICPFooterUITests: XCTestCase {
    private func launch(_ role: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "settings", "-uiRole", role] + extra
        app.launch()
        XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10))
        return app
    }

    /// 备案号在设置页最底下，滑到底能看到，文字一字不差，是可点的链接
    private func assertFooter(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let icp = app.descendants(matching: .any)["settings.icp"]
        XCTAssertTrue(icp.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 where !icp.isHittable { app.swipeUp() }
        XCTAssertTrue(icp.isHittable, "滑到底后备案号能点到", file: file, line: line)
        XCTAssertEqual(icp.label, "苏ICP备2026094233号-2A", file: file, line: line)
        XCTAssertEqual(icp.elementType, .link, "是链接（点了交给系统打开网页）", file: file, line: line)
        return icp
    }

    func testFamilySettingsShowsICPAndOpensSafari() throws {
        let app = launch("family")
        let icp = assertFooter(app)
        // 在版本号下面
        let version = app.staticTexts["settings.versionFooter"]
        XCTAssertTrue(version.exists)
        XCTAssertGreaterThan(icp.frame.minY, version.frame.minY)
        icp.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "点了以后 Safari 到前台")
    }

    func testCashierSettingsShowsICP() throws {
        let app = launch("cashier")
        _ = assertFooter(app)
    }

    /// 最大辅助字号下也能滑到、点到
    func testICPReachableAtMaxAccessibilitySize() throws {
        let app = launch("family", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        _ = assertFooter(app)
    }
}
