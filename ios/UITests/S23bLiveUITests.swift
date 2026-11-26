import Foundation
import XCTest

/// S23b 联调（plan-v2 §8 S23b 验收）：一台模拟器跑 App，连本机服务端（临时 PG）。平时跳过；由 `scripts/s23b-live.sh` 跑：
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   本机服务器、测试店账号和密码（密码只从环境变量来）
/// 按名字顺序跑；App 这边全走真实输入（输入框里打字、点按钮），服务器那边由测试进程直接调 API 核对。
@MainActor
final class S23bLiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: String { env["YH_LIVE_BASE"]! }
    private var user: String { env["YH_LIVE_USER"]! }
    private var password: String { env["YH_LIVE_PASSWORD"]! }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s23b-live.sh）")
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "on"]
            + (fresh ? ["-uiFreshInstall", "-uiResetStoredAPIBase"] : []) + extra
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ ok: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func log(_ s: String) { print("S23B-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) throws -> (status: Int, json: [String: Any]) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw e }
        return ((out.1 as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: out.0 ?? Data())) as? [String: Any] ?? [:])
    }

    private func apiLogin(_ pw: String) throws -> (status: Int, json: [String: Any]) {
        try call("POST", "/v1/auth/login", ["username": user, "password": pw, "device_id": UUID().uuidString.lowercased(), "label": "S23B 乙"])
    }

    private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
        let f = app.secureTextFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 10), "\(id) 存在")
        for _ in 0..<4 where !f.isHittable { app.swipeUp() }
        f.tap()
        f.typeText(text)
    }

    /// 全新安装、账号密码登录（用户名故意打成大写：服务器不分大小写，账号页显示的是开户时的原样），到首页
    private func freshLogin() -> XCUIApplication {
        let app = launch(fresh: true)
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        let u = app.textFields["login.username"]; u.tap(); u.typeText(user.uppercased())
        let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(password)
        app.buttons["login.submit"].tap()
        wait("首页或 16", timeout: 60) { el(app, "page.home").exists || el(app, "page.onboarding").exists }
        if el(app, "page.onboarding").exists { app.buttons["onboarding.done"].tap() }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        return app
    }

    /// 设置 →「账号与密码」（真点）
    private func openAccount(_ app: XCUIApplication) {
        let settings = el(app, "home.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let item = el(app, "settings.item.account")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        for _ in 0..<4 where !item.isHittable { app.swipeUp() }
        item.tap()
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
    }

    /// S23b-1：账号页显示服务器给的账号名；改密码后旧密码登录不了、新密码能登录，别的手机不被踢
    func testA_UsernameAndChangePassword() throws {
        let other = try apiLogin(password)
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(other.json["username"] as? String, user, "登录响应带开户时的账号名")
        let otherToken = other.json["token"] as! String

        let app = freshLogin()
        openAccount(app)
        wait("账号名 \(user)") { el(app, "account.username").label.contains(user) }
        XCTAssertFalse(el(app, "account.username").label.contains(user.uppercased()), "显示开户时的原样，不是输的大写")
        shot(app, "live-account")
        log("账号页显示账号名：\(el(app, "account.username").label)")

        let newPassword = password + "-new"
        type(app, "account.old", password)
        type(app, "account.new", newPassword)
        type(app, "account.again", newPassword)
        let change = app.buttons["account.changePassword"]
        for _ in 0..<4 where !change.isHittable { app.swipeUp() }
        change.tap()
        let msg = el(app, "account.passwordMessage")
        XCTAssertTrue(msg.waitForExistence(timeout: 20))
        XCTAssertTrue(msg.label.contains("密码改好了"), msg.label)
        log("改密码：\(msg.label)")

        XCTAssertEqual(try apiLogin(password).status, 401, "旧密码登录不了")
        XCTAssertEqual(try apiLogin(newPassword).status, 200, "新密码能登录")
        XCTAssertEqual(try call("GET", "/v1/me", token: otherToken).status, 200, "别的手机不被踢")
        // 改回去，后面的用例接着用环境变量里的密码
        let back = try call("POST", "/v1/account/password", ["old": newPassword, "new": password], token: otherToken)
        XCTAssertEqual(back.status, 204)
        log("旧密码 401、新密码 200、另一台 /v1/me 200；已改回")
    }
}
