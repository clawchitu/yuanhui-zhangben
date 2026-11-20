import XCTest

/// S14 扫码层的界面验收，用 Debug 的扫码测试页（`-uiFixture scanner` / `scanner-login`）。
/// 相机被拒用 `-uiCamera denied` 模拟；扫码枪用 FakeScanner 按扫码枪的速度逐键喂进真实的按键解析。
@MainActor
final class S14UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    private func log(_ app: XCUIApplication) -> String {
        app.staticTexts["scanner.log"].label
    }

    private func waitLog(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if log(app) == expected { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("扫码记录是「\(log(app))」，应为「\(expected)」", file: file, line: line)
    }

    /// 验收：相机被拒时显示「没打开相机，扫不了码」+「去打开」，手输条码和扫码枪照常可用（27a）
    func testCameraDeniedShowsNoticeAndGunAndManualStillWork() {
        let app = launch(["-uiFixture", "scanner", "-uiCamera", "denied",
                          "-uiScan", "6921168509256,6921168509256,6900000000000", "-uiScanSource", "gun",
                          "-uiScanGap", "0.3"])
        XCTAssertTrue(app.descendants(matching: .any)["scanner.noCamera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没打开相机，扫不了码"].exists)
        XCTAssertTrue(app.buttons["scanner.openSettings"].exists)
        XCTAssertEqual(app.buttons["scanner.openSettings"].label, "去打开")
        XCTAssertTrue(app.staticTexts["扫码枪照常能用"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["scanner.viewfinder"].exists, "被拒时不出取景框")
        // 扫码枪：同一个码扣两次扳机算两次，没登记的码也收到
        waitLog(app, "6921168509256/gun/known|6921168509256/gun/known|6900000000000/gun/unknown")
        // 手输条码
        app.buttons["scanner.manual"].tap()
        let alert = app.alerts["手输条码"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("6901035600016")
        alert.buttons["加入"].tap()
        waitLog(app, "6921168509256/gun/known|6921168509256/gun/known|6900000000000/gun/unknown|6901035600016/manual/known")
    }

    /// 验收：FakeScanner 能由启动参数喂码；相机来源同码 1.5 秒内只算一次，按码各记各的（§14 S14-1：A、B 交替不来回刷）
    func testFakeScannerFeedsCameraCodesWithDedupe() {
        let app = launch(["-uiFixture", "scanner", "-uiCamera", "authorized",
                          "-uiScan", "6921168509256,6921168509256,6901035600016,6921168509256,6901035600016,6921168509256",
                          "-uiScanSource", "camera", "-uiScanGap", "0.2"])
        XCTAssertTrue(app.descendants(matching: .any)["scanner.viewfinder"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["scanner.noCamera"].exists)
        waitLog(app, "6921168509256/camera/known|6901035600016/camera/known")
    }

    /// 还没问过权限：出取景框位置上的「正在打开相机…」，不出被拒提示
    func testNotDeterminedShowsOpeningState() {
        let app = launch(["-uiFixture", "scanner", "-uiCamera", "notDetermined"])
        let finder = app.descendants(matching: .any)["scanner.viewfinder"]
        XCTAssertTrue(finder.waitForExistence(timeout: 10))
        XCTAssertTrue(finder.label.contains("正在打开相机"), finder.label)
        XCTAssertFalse(app.descendants(matching: .any)["scanner.noCamera"].exists)
    }

    /// 27b：扫码登录页位置上的「没打开相机」卡片；扫码枪照样能喂码
    func testLoginStyleDeniedCard() {
        let app = launch(["-uiFixture", "scanner-login", "-uiCamera", "denied", "-uiScan", "6921168509256"])
        XCTAssertTrue(app.descendants(matching: .any)["scanner.noCameraCard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没打开相机，扫不了码"].exists)
        XCTAssertTrue(app.staticTexts["在系统设置里给「元辉账本」打开相机"].exists)
        XCTAssertEqual(app.buttons["scanner.openSettings"].label, "去打开")
        waitLog(app, "6921168509256/gun/known")
    }
}
