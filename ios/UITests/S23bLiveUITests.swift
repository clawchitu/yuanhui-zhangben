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

    /// `next: true`：上一个框刚打完字，按键盘上的「下一项」（回车）跳到这个框，和老人的用法一样；
    /// 从一个密码框直接点另一个密码框，模拟器上常常焦点进不去（系统的密码自动填充接管了键盘）
    private func type(_ app: XCUIApplication, _ id: String, _ text: String, next: Bool = false) {
        let f = app.secureTextFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 10), "\(id) 存在")
        if next {
            app.typeText("\n")
            let end = Date().addingTimeInterval(3)
            while Date() < end, (f.value(forKey: "hasKeyboardFocus") as? Bool) != true {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            if (f.value(forKey: "hasKeyboardFocus") as? Bool) == true { f.typeText(text); return }
        }
        reveal(app, f)
        f.tap()
        // 点下去焦点没进框（键盘、自动填充条刚弹出来时位置还在变）：再摆一次、再点，最多 3 次
        for _ in 0..<3 where (f.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            print("S23B-UI \(id) 没拿到焦点：框 \(f.frame)，键盘 \(app.keyboards.firstMatch.exists ? "\(app.keyboards.firstMatch.frame)" : "无")，滚动区 \(app.scrollViews.firstMatch.frame)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            reveal(app, f)
            f.tap()
        }
        f.typeText(text)
    }

    /// 把元素整个拖进看得见的那一段：滚动区顶上（顶栏下面）到键盘上沿之间。只看 isHittable 不够：
    /// 被键盘或顶栏盖住的框也算 hittable，点下去点到的是键盘 / 顶栏，焦点进不去
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        let sv = app.scrollViews.firstMatch
        for _ in 0..<8 {
            let win = app.windows.firstMatch.frame
            let kb = app.keyboards.firstMatch
            let bottom = kb.exists ? kb.frame.minY : (sv.exists ? sv.frame.maxY : win.maxY)
            let top = sv.exists ? sv.frame.minY : win.minY
            let f = e.frame
            let delta: CGFloat
            if f.maxY > bottom - 8 { delta = -min(f.maxY - bottom + 24, (bottom - top) / 2) }
            else if f.minY < top + 8 { delta = min(top - f.minY + 24, (bottom - top) / 2) }
            else { return }
            let from = sv.exists ? sv : app.windows.firstMatch
            let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0)).withOffset(CGVector(dx: 0, dy: (bottom - top) / 2 + (top - from.frame.minY)))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
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

    /// 重开 App 直接进设置（大字首页的齿轮在另一种版式里），再真点「账号与密码」
    private func openAccount(_ app: inout XCUIApplication) {
        app.terminate()
        app = launch(["-uiRoute", "settings"])
        let item = el(app, "settings.item.account")
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        reveal(app, item)
        item.tap()
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
    }

    /// S23b-1：账号页显示服务器给的账号名；改密码后旧密码登录不了、新密码能登录，别的手机不被踢
    func testA_UsernameAndChangePassword() throws {
        let other = try apiLogin(password)
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(other.json["username"] as? String, user, "登录响应带开户时的账号名")
        let otherToken = other.json["token"] as! String

        var app = freshLogin()
        openAccount(&app)
        wait("账号名 \(user)") { el(app, "account.username").label.contains(user) }
        XCTAssertFalse(el(app, "account.username").label.contains(user.uppercased()), "显示开户时的原样，不是输的大写")
        shot(app, "live-account")
        log("账号页显示账号名：\(el(app, "account.username").label)")

        let newPassword = password + "-new"
        type(app, "account.old", password)
        type(app, "account.new", newPassword, next: true)
        type(app, "account.again", newPassword, next: true)
        let change = app.buttons["account.changePassword"]
        reveal(app, change)
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
