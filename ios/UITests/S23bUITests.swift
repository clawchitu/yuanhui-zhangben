import Network
import XCTest

/// S23b-1 账号与密码（plan-v2 §8 S23b 验收，夹具 + 本机桩服务器；注销在 S23b-2）。全部走真实输入：在输入框里打字、点按钮，
/// 断言桩收到的请求。服务器那一侧（改密码不强制其他手机退出、注销期间不应用 op、7 天内可撤回）由 server 的 Vitest 钉住，
/// 这里钉手机：发对请求、不发多余的请求（改密码后不去踢别的手机）、按服务器回的码出对的话、页面去对的地方。
@MainActor
final class S23bUITests: XCTestCase {
    private var stub: AccountStub!
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try AccountStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func idle(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func launch(route: String = "account", role: String = "family", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "on", "-uiAPI", "http://localhost:\(stub.port)"]
        if !route.isEmpty { args += ["-uiRoute", route] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 元素整个在屏幕里、能点、没被键盘挡住（大字、小屏时关键按钮不被挤出去）
    private func assertOnScreen(_ app: XCUIApplication, _ e: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(what) 存在", file: file, line: line)
        XCTAssertTrue(e.isHittable, "\(what) 能点", file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(what) 整个在屏幕里：\(e.frame)", file: file, line: line)
        let kb = app.keyboards.firstMatch
        if kb.exists { XCTAssertLessThanOrEqual(e.frame.maxY, kb.frame.minY + 1, "\(what) 没被键盘挡住", file: file, line: line) }
    }

    /// 往一个密码框里打字（真点框、真打字）
    private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
        let f = app.secureTextFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 10), "\(id) 存在")
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

    private func scrollTo(_ app: XCUIApplication, _ e: XCUIElement) {
        XCTAssertTrue(e.waitForExistence(timeout: 10))
        reveal(app, e)
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

    // MARK: 入口

    /// 21a →「账号与密码」：显示账号名和店；家用号从设置点进来
    func testSettingsEntryShowsUsername() {
        let app = launch(route: "settings")
        let item = el(app, "settings.item.account")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(item.label.contains("改密码、注销"), item.label)
        for _ in 0..<4 where !item.isHittable { app.swipeUp() }
        item.tap()
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "account.username").label.contains("yuanhui"), el(app, "account.username").label)
        XCTAssertTrue(el(app, "account.store").label.contains("元辉烟酒店"))
        shot(app, "account")
    }

    /// 本机没记着账号名（扫码开通的家用手机、升级前登录的）：进页面问 `/v1/me`，用服务器给的 `username`
    func testUsernameFromMe() {
        let app = launch(extra: ["-uiUsername", "none"])
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
        wait("账号名来自 /v1/me") { el(app, "account.username").label.contains("yuanhui") }
        XCTAssertFalse(stub.requests(method: "GET", path: "/v1/me").isEmpty)
    }

    /// 收银员：设置里没有「账号与密码」；硬塞「账号与密码」「注销账号」路由也只有「用不了」，一个账号请求都不发
    func testCashierHasNoAccountEntries() {
        let app = launch(route: "settings", role: "cashier")
        XCTAssertTrue(el(app, "page.settings").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app, "settings.item.account").exists)
        app.terminate()
        for route in ["account"] {
            let a = launch(route: route, role: "cashier")
            XCTAssertTrue(el(a, "page.denied").waitForExistence(timeout: 10), route)
            XCTAssertFalse(el(a, "page.\(route)").exists)
            a.terminate()
        }
        idle(1)
        XCTAssertTrue(stub.requests.filter { $0.path.hasPrefix("/v1/account") || $0.path == "/v1/devices/revoke-others" }.isEmpty)
    }

    /// 审核号（演示店）按权限表和家用一样有入口
    func testReviewHasAccountEntry() {
        let app = launch(route: "settings", role: "review")
        XCTAssertTrue(el(app, "settings.item.account").waitForExistence(timeout: 10))
        let a2 = launch(route: "account", role: "review")
        XCTAssertTrue(el(a2, "page.account").waitForExistence(timeout: 10))
    }

    // MARK: 改密码

    /// 输原密码、两次新密码，点「改密码」：发 {old, new}；改好了说别的手机不用重新登录；没有去踢任何手机
    func testChangePassword() throws {
        let app = launch()
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
        let btn = app.buttons["account.changePassword"]
        XCTAssertFalse(btn.isEnabled, "没填时是灰的")
        type(app, "account.old", "oldpass1")
        type(app, "account.new", "newpass88")
        type(app, "account.again", "newpass88")
        scrollTo(app, btn)
        XCTAssertTrue(btn.isEnabled)
        btn.tap()
        let msg = el(app, "account.passwordMessage")
        XCTAssertTrue(msg.waitForExistence(timeout: 10))
        XCTAssertEqual(msg.label, "密码改好了。别的手机不用重新登录，下次登录用新密码")
        let posts = stub.requests(method: "POST", path: "/v1/account/password")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.json as? [String: String], ["old": "oldpass1", "new": "newpass88"])
        XCTAssertEqual(posts.first?.auth, "Bearer fixture-token")
        XCTAssertTrue(stub.requests(method: "POST", path: "/v1/devices/revoke-others").isEmpty, "改密码不让其他手机退出")
        XCTAssertTrue(stub.requests(method: "POST").filter { $0.path.hasSuffix("/revoke") }.isEmpty)
        shot(app, "account-changed")
    }

    /// 新密码太短、两次不一样：手机上就拦下，不发请求
    func testPasswordRulesCheckedBeforeSending() {
        let app = launch()
        type(app, "account.old", "oldpass1")
        type(app, "account.new", "abc")
        type(app, "account.again", "abc")
        scrollTo(app, app.buttons["account.changePassword"])
        app.buttons["account.changePassword"].tap()
        XCTAssertEqual(el(app, "account.passwordMessage").label, "新密码太短了，至少 8 位")
        type(app, "account.new", "defghijk")       // 新密码 = abcdefghijk
        type(app, "account.again", "defghijX")
        scrollTo(app, app.buttons["account.changePassword"])
        app.buttons["account.changePassword"].tap()
        XCTAssertEqual(el(app, "account.passwordMessage").label, "两次输的新密码不一样，再输一次")
        idle(1)
        XCTAssertTrue(stub.requests(method: "POST", path: "/v1/account/password").isEmpty)
    }

    /// 原密码错（401 bad_credentials）、错多了限速（429，retry_after_s 601 → 11 分钟）：按服务器回的码说
    func testWrongOldPasswordAndRateLimit() {
        let app = launch()
        type(app, "account.old", "wrongpw")
        type(app, "account.new", "newpass88")
        type(app, "account.again", "newpass88")
        scrollTo(app, app.buttons["account.changePassword"])
        app.buttons["account.changePassword"].tap()
        let msg = el(app, "account.passwordMessage")
        wait("原密码错") { msg.exists && msg.label == "密码不对，再输一次" }
        XCTAssertEqual((app.secureTextFields["account.old"].value as? String) ?? "", "", "原密码框清空")
        stub.rateLimited = true
        type(app, "account.old", "wrongpw")
        scrollTo(app, app.buttons["account.changePassword"])
        app.buttons["account.changePassword"].tap()
        wait("限速") { msg.label == "密码错了太多次，11 分钟以后再试" }
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/account/password").count, 2)
    }

    // MARK: 让其他手机全部退出

    /// 先弹 26 确认面板；「不了」不发；确认才发 revoke-others，说退了几台
    func testRevokeOthersAsksFirst() {
        let app = launch()
        let btn = el(app, "account.revokeOthers")
        scrollTo(app, btn)
        btn.tap()
        let title = el(app, "confirm.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "让其他手机全部退出？")
        shot(app, "account-revokeOthers-26")
        el(app, "account.revokeOthers.cancel").tap()
        wait("面板关上") { !self.el(app, "confirm.title").exists }
        XCTAssertTrue(stub.requests(method: "POST", path: "/v1/devices/revoke-others").isEmpty, "点「不了」不发")
        btn.tap()
        XCTAssertTrue(el(app, "account.revokeOthers.confirm").waitForExistence(timeout: 5))
        el(app, "account.revokeOthers.confirm").tap()
        let done = el(app, "account.revokeOthers.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertEqual(done.label, "已经让 3 台手机退出了")
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/devices/revoke-others").count, 1)
        XCTAssertEqual(stub.requests(method: "POST", path: "/v1/devices/revoke-others").first?.auth, "Bearer fixture-token")
    }

    // MARK: 最大辅助字号、小屏：关键按钮都在屏幕里、能点

    func testMaxTextAccount() {
        let app = launch(extra: Self.maxAX)
        XCTAssertTrue(el(app, "page.account").waitForExistence(timeout: 10))
        type(app, "account.old", "oldpass1")
        type(app, "account.new", "newpass88")
        type(app, "account.again", "newpass88")
        let change = app.buttons["account.changePassword"]
        scrollTo(app, change)
        assertOnScreen(app, change, "改密码")
        shot(app, "account-ax")
        change.tap()
        XCTAssertTrue(el(app, "account.passwordMessage").waitForExistence(timeout: 10))
        let revoke = el(app, "account.revokeOthers")
        scrollTo(app, revoke)
        assertOnScreen(app, revoke, "让其他手机全部退出")
    }
}

/// 账号接口的桩（契约 openapi.yaml「账号」，加 `/v1/devices*`、`/v1/me`）。原密码是 oldpass1
final class AccountStub: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: Data
        let auth: String
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    }

    static let password = "oldpass1"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "s23b-account-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private var limited = false
    private var until: String?

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() throws -> AccountStub {
        let s = try AccountStub()
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "AccountStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
    /// 改密码、申请注销一律回 429（15 分钟错 5 次以后，正确密码也是 429）
    var rateLimited: Bool { get { lock.withLock { limited } } set { lock.withLock { limited = newValue } } }
    /// `/v1/me` 回的注销状态；撤回成功后清掉
    var deletePendingUntil: String? { get { lock.withLock { until } } set { lock.withLock { until = newValue } } }
    var requests: [Request] { lock.withLock { log } }
    func requests(method: String, path: String? = nil) -> [Request] {
        lock.withLock { log.filter { $0.method == method && (path == nil || $0.path == path) } }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                func header(_ n: String) -> String {
                    lines.dropFirst().first { $0.lowercased().hasPrefix(n + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                let length = Int(header("content-length")) ?? 0
                let body = b[end.upperBound...]
                if body.count >= length {
                    self.respond(c, lines, auth: header("authorization"), body: Data(body.prefix(length)))
                    return
                }
            }
            if done || err != nil { c.cancel() } else { self.receive(c, b) }
        }
    }

    private func respond(_ c: NWConnection, _ lines: [String], auth: String, body: Data) {
        let first = lines.first?.split(separator: " ") ?? []
        let method = first.first.map(String.init) ?? ""
        let path = String((first.dropFirst().first.map(String.init) ?? "").split(separator: "?").first ?? "")
        let (status, out): (Int, String) = lock.withLock {
            log.append(Request(method: method, path: path, body: body, auth: auth))
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
            let limitedReply = (429, #"{"code":"rate_limited","retry_after_s":601,"message":"密码错了太多次，请稍后再试"}"#)
            let wrong = (401, #"{"code":"bad_credentials","message":"密码不对"}"#)
            switch (method, path) {
            case ("POST", "/v1/account/password"):
                if limited { return limitedReply }
                guard json["old"] == Self.password else { return wrong }
                guard (json["new"] ?? "").unicodeScalars.count >= 8 else { return (400, #"{"code":"invalid"}"#) }
                return (204, "")
            case ("POST", "/v1/account/delete-request"):
                if limited { return limitedReply }
                guard json["password"] == Self.password else { return wrong }
                let u = until ?? "2026-12-03T08:00:00.000Z"
                until = u
                return (200, #"{"delete_pending_until":"\#(u)"}"#)
            case ("POST", "/v1/account/delete-cancel"):
                guard until != nil else { return (409, #"{"code":"not_delete_pending","message":"账号不在注销中"}"#) }
                until = nil
                return (204, "")
            case ("POST", "/v1/devices/revoke-others"):
                return (200, #"{"revoked":3}"#)
            case ("GET", "/v1/me"):
                let d = until.map { #","delete_pending_until":"\#($0)""# } ?? ""
                return (200, #"{"role":"family","store":{"name":"元辉烟酒店","is_demo":false},"label":"柜台手机","username":"yuanhui"\#(d)}"#)
            case ("GET", "/v1/devices"):
                return (200, #"{"devices":[]}"#)
            default:
                return (404, #"{"code":"not_found"}"#)
            }
        }
        let h = status == 204
            ? "HTTP/1.1 204 X\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(out.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + Data(out.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
