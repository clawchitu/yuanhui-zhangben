import Foundation
import XCTest

/// S21 联调：连真服务器（本机起的服务端，或线上测试店）。平时跳过；手工跑时经 xcodebuild 的 `TEST_RUNNER_` 前缀环境变量给参数：
///   TEST_RUNNER_YH_LIVE_BASE      服务器地址（本机 `http://localhost:端口`，线上 `https://47.117.184.253`）
///   TEST_RUNNER_YH_LIVE_USER / TEST_RUNNER_YH_LIVE_PASSWORD   账号和密码（运行时从钥匙串读，不写文件）
///   TEST_RUNNER_YH_LIVE_LOCK=1    另跑「错 5 次锁定」（只对本机服务端：线上会把测试号锁 15 分钟）
///   TEST_RUNNER_YH_LIVE_CODE      另跑扫码登录，给一个已过期的 `YHZB1:` 码（本机服务端出码后在库里改过期）
@MainActor
final class S21LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（设 TEST_RUNNER_YH_LIVE_BASE）")
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", env["YH_LIVE_BASE"]!, "-uiFreshInstall", "-uiResetStoredAPIBase"] + extra
        app.launch()
        return app
    }

    private func type(_ app: XCUIApplication, user: String, password: String) {
        XCTAssertTrue(app.descendants(matching: .any)["page.login"].waitForExistence(timeout: 15))
        let u = app.textFields["login.username"]
        u.tap()
        u.typeText(user)
        let p = app.secureTextFields["login.password"]
        XCTAssertTrue(p.waitForExistence(timeout: 5))
        p.tap()
        p.typeText(password)
        app.buttons["login.submit"].tap()
    }

    func testLiveLoginSucceeds() throws {
        let user = try XCTUnwrap(env["YH_LIVE_USER"]), password = try XCTUnwrap(env["YH_LIVE_PASSWORD"])
        let app = launch()
        type(app, user: user, password: password)
        XCTAssertTrue(app.descendants(matching: .any)["page.onboarding"].waitForExistence(timeout: 20), "登录成功应进 16")
        app.terminate()
        // 杀掉重开仍是登录状态
        let again = XCUIApplication()
        again.launchArguments = ["-uiAPIBase", env["YH_LIVE_BASE"]!]
        again.launch()
        XCTAssertTrue(again.descendants(matching: .any)["page.onboarding"].waitForExistence(timeout: 15))
    }

    func testLiveLockoutShowsUntil() throws {
        try XCTSkipUnless(env["YH_LIVE_LOCK"] == "1", "锁定只对本机服务端测")
        let user = try XCTUnwrap(env["YH_LIVE_USER"])
        let app = launch()
        let start = Date()
        for n in 1...5 {
            if n == 1 { type(app, user: user, password: "wrong-pass-\(n)") } else {
                let p = app.secureTextFields["login.password"]
                p.tap()
                p.typeText("wrong-pass-\(n)")
                app.buttons["login.submit"].tap()
            }
            if n < 5 { XCTAssertTrue(app.staticTexts["login.message"].waitForExistence(timeout: 15)) }
            sleep(1)
        }
        let banner = app.descendants(matching: .any)["login.locked"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm"
        let candidates = (14...16).map { f.string(from: start.addingTimeInterval(Double($0) * 60)) }
        XCTAssertTrue(candidates.contains { banner.label.contains("\($0) 以后再试") }, "\(candidates) / \(banner.label)")
        print("联调锁定黄条：\(banner.label)")
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
    }

    func testLiveExpiredCode() throws {
        let code = env["YH_LIVE_CODE"] ?? ""
        try XCTSkipIf(code.isEmpty, "没给过期码（TEST_RUNNER_YH_LIVE_CODE）")
        let app = launch(["-uiLoginScreen", "scan", "-uiCamera", "authorized", "-uiLoginCode", code])
        let msg = app.staticTexts["scanLogin.message"]
        XCTAssertTrue(msg.waitForExistence(timeout: 15))
        XCTAssertEqual(msg.label, "这个码过期了，让家里人换一个新码")
    }
}
