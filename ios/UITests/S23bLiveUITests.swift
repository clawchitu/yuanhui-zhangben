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
            // 键盘上面还有一条系统的「Passwords」自动填充条（约 44pt），不算在键盘的 frame 里
            let bottom = kb.exists ? kb.frame.minY - 56 : (sv.exists ? sv.frame.maxY : win.maxY)
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

    // MARK: S23b-2 注销

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }

    private func syncLabel(_ app: XCUIApplication) -> String {
        let l = app.descendants(matching: .any).matching(identifier: "syncStatus").allElementsBoundByIndex.map(\.label).joined(separator: " ")
        for k in ["已同步", "没网"] where l.contains(k) { return k }
        if let r = l.range(of: #"\d+ 笔待传"#, options: .regularExpression) { return String(l[r]) }
        return l
    }

    private func entries(_ token: String, epoch: String) throws -> Int {
        let r = try call("POST", "/v1/sync", ["epoch": epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "ops": []], token: token)
        XCTAssertEqual(r.status, 200)
        return ((r.json["changes"] as? [String: Any])?["entries"] as? [Any])?.count ?? -1
    }

    /// S23b-2：手机上有 1 笔没传 → 确认注销：先排空（这笔入账）再申请，回登录页（说怎么撤回）；
    /// 7 天内重新登录：首页「账号正在注销」，照样能卖，卖的留在手机上不入账；点提醒条进「账号与密码」撤回 → 自动补传、入账
    func testB_DeleteRequestHoldsSalesUntilCancel() throws {
        // 另一台手机（测试进程）登记一个商品
        let other = try apiLogin(password)
        let token = other.json["token"] as! String, epoch = other.json["epoch"] as! String
        let pid = UUID().uuidString.lowercased(), code = "69" + String(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000_000)
        let up = try call("POST", "/v1/sync", ["epoch": epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": false,
                                               "ops": [["id": UUID().uuidString.lowercased(), "type": "product_upsert", "occurred_at": Self.iso(Date()),
                                                        "payload": ["product_id": pid, "barcode": code, "name": "S23B 注销联调水", "price_fen": 300,
                                                                    "quick": false, "base_unit": "瓶"]]]], token: token)
        XCTAssertEqual((up.json["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")
        let before = try entries(token, epoch: epoch)
        XCTAssertGreaterThanOrEqual(before, 0, "拉得到流水")

        // App：登录，同步拉到商品后断网卖 1 笔（留在本机待传）
        var app = freshLogin()
        wait("已同步", timeout: 60) { syncLabel(app) == "已同步" }
        app.terminate()
        app = launch(["-uiOffline", "-uiRoute", "sell", "-uiScan", code, "-uiAutoCommit", "-uiProbe"])
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 20), "断网也记好了")
        app.terminate()

        // 联网 → 设置 → 账号与密码 → 注销账号 → 输密码 → 确认注销
        app = launch()
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        openAccount(&app)
        let link = el(app, "settings.item.deleteAccount")
        reveal(app, link)
        link.tap()
        XCTAssertTrue(el(app, "page.deleteAccount").waitForExistence(timeout: 10))
        type(app, "deleteAccount.password", password)
        app.buttons["deleteAccount.confirm"].tap()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 60), "申请后回登录页")
        let notice = el(app, "login.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("可以撤回"), notice.label)
        shot(app, "live-login-after-delete")
        log("登录页：\(notice.label)")
        XCTAssertEqual(try call("GET", "/v1/me", token: token).status, 401, "申请注销让全部手机退出（含另一台）")
        // 7 天内重新登录：注销中（拉取照常，用新令牌数流水）
        let again = try apiLogin(password)
        XCTAssertNotNil(again.json["delete_pending_until"], "注销中登录响应带 delete_pending_until")
        let token2 = again.json["token"] as! String, epoch2 = again.json["epoch"] as! String
        XCTAssertEqual(try entries(token2, epoch: epoch2), before + 1, "申请之前先把没传的那笔传上去了")

        // App 重新登录：照样能卖，卖的不入账
        app.terminate()
        app = freshLogin()
        let banner = el(app, "home.banner.deleting")
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "首页提示账号正在注销")
        app.terminate()
        app = launch(["-uiRoute", "sell", "-uiScan", code, "-uiAutoCommit", "-uiProbe"])
        XCTAssertTrue(el(app, "sell.deleting").waitForExistence(timeout: 20), "卖出页提示注销中")
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 20), "注销中照样能卖")
        app.terminate()
        app = launch()
        XCTAssertTrue(el(app, "home.banner.deleting").waitForExistence(timeout: 30))
        wait("首页提醒条说 1 笔还没记上", timeout: 30) { el(app, "home.banner.deleting").label.contains("1 笔还没记上") }
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertEqual(try entries(token2, epoch: epoch2), before + 1, "注销中卖的不入账")

        // 点提醒条进「账号与密码」撤回 → 自动补传
        el(app, "home.banner.deleting").tap()
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
        let cancel = app.buttons["account.cancelDeletion"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let msg = el(app, "account.cancelMessage")
        XCTAssertTrue(msg.waitForExistence(timeout: 20))
        log("撤回：\(msg.label)")
        XCTAssertNil(try call("GET", "/v1/me", token: token2).json["delete_pending_until"], "服务器上撤回了")
        try wait("撤回后自动补传、入账", timeout: 60) { try entries(token2, epoch: epoch2) == before + 2 }
        log("流水：申请前 \(before)，排空后 +1，撤回补传后 +2")
    }
}
