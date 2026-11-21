import XCTest

/// §14 S15-4 / S15-7：Beta / Release 构建里没有会话时只出「还没登录」页；会开出会话、换身份、装演示数据的
/// 夹具参数一律不认，也不往本机写东西。只在 `scripts/release-check.sh` 里跑（Release 配置构建的 App，
/// scheme `YuanhuiZhangben-ReleaseCheck` 设了 `YH_RELEASE_CHECK=1`）；Debug 的 ios-ci 里跳过。
@MainActor
final class ReleaseBuildUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YH_RELEASE_CHECK"] == "1",
                          "只在 Release 构建检查（scripts/release-check.sh）里跑")
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    func testReleaseBuildHasNoDemoSessionOrSessionFixtures() throws {
        let attempts: [[String]] = [
            [],
            ["-uiFixture", "home", "-uiRole", "family"],
            ["-uiFixture", "home-unsynced", "-uiRole", "cashier"],
            ["-uiFixture", "settings", "-uiRole", "cashier", "-uiRoute", "stockIn"],
            ["-uiFixture", "onboarding", "-uiRole", "family"],
            ["-uiRole", "family", "-uiFreshInstall"],
            ["-uiRole", "review"],
            // S14：扫码测试页、FakeScanner 喂码、强制相机权限都只在 Debug
            ["-uiFixture", "scanner", "-uiCamera", "denied", "-uiScan", "6921168509256"],
            ["-uiFixture", "scanner-login", "-uiScan", "6921168509256", "-uiScanSource", "camera"],
            [],  // 上面都试过之后再正常启动一次：本机库里仍然没有会话
        ]
        for args in attempts {
            let app = launch(args)
            XCTAssertTrue(app.otherElements["page.signedOut"].waitForExistence(timeout: 10), "\(args) 应出「还没登录」页")
            XCTAssertTrue(app.staticTexts["还没登录"].exists, "\(args)")
            for page in ["page.home", "page.onboarding", "page.settings", "page.stockIn", "page.denied", "page.scannerLab"] {
                XCTAssertFalse(app.otherElements[page].exists, "\(args) 不应出 \(page)")
            }
            app.terminate()
        }
    }

    /// 只换界面状态、不碰会话的夹具（组件陈列页）在 Release 里照常可用（S15-7）
    func testReleaseBuildKeepsGalleryFixture() throws {
        let app = launch(["-uiFixture", "gallery-3"])
        XCTAssertTrue(app.descendants(matching: .any)["gallery.stepperCompact"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["page.signedOut"].exists)
    }
}
