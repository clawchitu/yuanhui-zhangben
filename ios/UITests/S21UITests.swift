import Foundation
import Network
import XCTest

/// S21 的界面验收（plan-v2 §8 S21）：登录、锁定、扫码登录、请更新、看看演示，以及服务器地址下发。
/// 测试进程里用 `NWListener` 起两个本机桩服务器 A、B（任选端口），按契约回 config / login / redeem / demo。
/// App 用 `-uiAPIBase http://localhost:A` 把包内默认地址换成 A（只在 Debug 认），每次都 `-uiFreshInstall`（清钥匙串）
/// 和 `-uiResetStoredAPIBase`（清已存地址），互不影响。
@MainActor
final class S21UITests: XCTestCase {
    private var a: StubServer!
    private var b: StubServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try StubServer.start(name: "A")
        b = try StubServer.start(name: "B")
    }

    override func tearDown() {
        a?.stop()
        b?.stop()
    }

    private var baseA: String { "http://localhost:\(a.port)" }
    private var baseB: String { "http://localhost:\(b.port)" }

    private func launch(fresh: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", baseA] + (fresh ? ["-uiFreshInstall", "-uiResetStoredAPIBase"] : []) + extra
        app.launch()
        return app
    }

    /// 等桩服务器收到某个路径的第 n 次请求
    private func waitFor(_ s: StubServer, _ path: String, count n: Int = 1, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if s.count(path) >= n { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("\(s.name) 没在 \(timeout) 秒内收到第 \(n) 次 \(path)（现在 \(s.count(path)) 次）", file: file, line: line)
    }

    private func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func signIn(_ app: XCUIApplication, user: String = "yuanhui", password: String = "123456789") {
        XCTAssertTrue(app.descendants(matching: .any)["page.login"].waitForExistence(timeout: 10))
        let u = app.textFields["login.username"]
        u.tap()
        u.typeText(user)
        typePassword(app, password)
        app.buttons["login.submit"].tap()
    }

    private func typePassword(_ app: XCUIApplication, _ password: String) {
        let p = app.secureTextFields["login.password"]
        XCTAssertTrue(p.waitForExistence(timeout: 5))
        p.tap()
        p.typeText(password)
    }

    private func assertSignedIn(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let ok = app.descendants(matching: .any)["page.onboarding"].waitForExistence(timeout: 10)
        if !ok { print("没进 16，界面：\n\(app.debugDescription)") }
        XCTAssertTrue(ok, "登录后应进 16", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["page.login"].exists, file: file, line: line)
    }

    // MARK: - 账号密码登录、服务器地址下发

    /// A 下发 B → 登录打到 B、进 16 → 杀掉重开仍是登录状态，配置也去 B 取
    func testAdoptedBaseUsedForLoginAndAfterRelaunch() {
        let nb = baseB
        a.update { $0.apiBase = nb }
        let app = launch()
        waitFor(a, "/v1/config")
        pause(0.5)
        signIn(app)
        waitFor(b, "/v1/auth/login")
        XCTAssertEqual(a.count("/v1/auth/login"), 0, "登录不该打到 A")
        assertSignedIn(app)
        XCTAssertEqual(b.lastBody("/v1/auth/login")?["username"] as? String, "yuanhui")

        app.terminate()
        let configA = a.count("/v1/config"), configB = b.count("/v1/config")
        let again = launch(fresh: false)
        assertSignedIn(again)
        waitFor(b, "/v1/config", count: configB + 1)
        XCTAssertEqual(a.count("/v1/config"), configA, "重开后仍用 B，不该再去 A 取配置")
    }

    /// 新地址不通时退回包内默认地址能登录
    func testFallsBackToDefaultWhenAdoptedBaseIsDown() {
        let nb = baseB
        a.update { $0.apiBase = nb }
        let app = launch()
        waitFor(a, "/v1/config")
        pause(0.5)
        b.stop()
        signIn(app)
        waitFor(a, "/v1/auth/login")
        assertSignedIn(app)
    }

    /// 服务器下发白名单之外的地址（原文五个）：不采用，登录仍打到 A
    func testRejectsNonWhitelistedBases() {
        let bad = ["https://evil.example", "https://api.yuanhuishop.cn.evil.example", "https://api.yuanhuishop.cn@evil.example",
                   "https://evil.api.yuanhuishop.cn", "https://evil.example@api.yuanhuishop.cn"]
        for (i, base) in bad.enumerated() {
            a.update { $0.apiBase = base }
            let configs = a.count("/v1/config")
            let app = launch()
            waitFor(a, "/v1/config", count: configs + 1)
            pause(0.5)
            signIn(app)
            waitFor(a, "/v1/auth/login", count: i + 1)
            assertSignedIn(app)
            app.terminate()
        }
        XCTAssertEqual(b.total, 0)
    }

    /// 本机预置一条白名单之外的已存地址：启动后删掉，请求打到默认地址 A
    func testSeededInvalidStoredBaseIsDropped() {
        let app = launch(fresh: false, ["-uiFreshInstall", "-uiSeedStoredAPIBase", "https://evil.example"])
        waitFor(a, "/v1/config")
        signIn(app)
        waitFor(a, "/v1/auth/login")
        assertSignedIn(app)
    }

    // MARK: - 登录页

    /// 没有「注册」、没有店名、副标题、隐私政策、密码可显示
    func testLoginPageContents() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["page.login"].waitForExistence(timeout: 10))
        waitFor(a, "/v1/config")
        XCTAssertTrue(app.staticTexts["小店扫码记账"].exists, "副标题")
        XCTAssertTrue(app.staticTexts["账号由店里开通"].exists, "页脚")
        let all = app.descendants(matching: .any)
        for word in ["注册", StubServer.storeName, "元辉烟酒店"] {
            XCTAssertFalse(all.containing(NSPredicate(format: "label CONTAINS %@", word)).firstMatch.exists, "登录页不该有「\(word)」")
        }
        XCTAssertTrue(app.links["隐私政策"].exists || app.descendants(matching: .any)["login.privacy"].exists, "隐私政策链接")
        typePassword(app, "abc123")
        XCTAssertFalse(app.textFields["login.passwordPlain"].exists)
        app.buttons["login.showPassword"].tap()
        let plain = app.textFields["login.passwordPlain"]
        XCTAssertTrue(plain.waitForExistence(timeout: 3))
        XCTAssertEqual(plain.value as? String, "abc123", "点「显示」后密码明文可见")
        XCTAssertFalse(app.descendants(matching: .any)["login.demo"].exists, "开关默认关：没有「看看演示」")
    }

    /// 密码错 5 次：黄条写锁到几点（上海时间），按钮「登录（锁定中）」并禁用
    func testFiveWrongPasswordsShowLockedUntil() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["page.login"].waitForExistence(timeout: 10))
        let u = app.textFields["login.username"]
        u.tap()
        u.typeText("yuanhui")
        for n in 1...5 {
            typePassword(app, "wrong\(n)")
            app.buttons["login.submit"].tap()
            waitFor(a, "/v1/auth/login", count: n)
            if n < 5 {
                XCTAssertTrue(app.staticTexts["login.message"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["login.message"].label, "账号或密码不对")
            }
        }
        let banner = app.descendants(matching: .any)["login.locked"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let until = try! XCTUnwrap(a.lockedUntil)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm"
        let hhmm = f.string(from: until)
        XCTAssertTrue(banner.label.contains("\(hhmm) 以后再试"), "黄条应写「\(hhmm) 以后再试」：\(banner.label)")
        XCTAssertTrue(banner.label.contains("密码错了 5 次"))
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.label.contains("登录（锁定中）"), submit.label)
        XCTAssertFalse(submit.isEnabled)
    }

    // MARK: - 扫码登录

    /// 过期码给 25d 的提示；用过的码另一句；好码登录进 16
    func testScanLoginCodes() {
        let expired = launch(["-uiLoginScreen", "scan", "-uiCamera", "authorized", "-uiLoginCode", "YHZB1:expired-code"])
        XCTAssertTrue(expired.descendants(matching: .any)["page.scanLogin"].waitForExistence(timeout: 10))
        let msg = expired.staticTexts["scanLogin.message"]
        XCTAssertTrue(msg.waitForExistence(timeout: 10))
        XCTAssertEqual(msg.label, "这个码过期了，让家里人换一个新码")
        XCTAssertEqual(a.lastBody("/v1/auth/pair/redeem")?["code"] as? String, "expired-code", "去掉 YHZB1: 前缀再兑")
        expired.terminate()

        let used = launch(["-uiLoginScreen", "scan", "-uiCamera", "authorized", "-uiLoginCode", "YHZB1:used-code"])
        let usedMsg = used.staticTexts["scanLogin.message"]
        XCTAssertTrue(usedMsg.waitForExistence(timeout: 10))
        XCTAssertEqual(usedMsg.label, "这个码已经用过了，让家里人换一个新码")
        used.terminate()

        let notOurs = launch(["-uiLoginScreen", "scan", "-uiCamera", "authorized", "-uiLoginCode", "6921168509256"])
        XCTAssertTrue(notOurs.staticTexts["scanLogin.message"].waitForExistence(timeout: 10))
        XCTAssertTrue(notOurs.staticTexts["scanLogin.message"].label.contains("不是元辉账本的登录码"))
        notOurs.terminate()

        let redeems = a.count("/v1/auth/pair/redeem")
        let good = launch(["-uiLoginScreen", "scan", "-uiCamera", "authorized", "-uiLoginCode", "YHZB1:good-code"])
        waitFor(a, "/v1/auth/pair/redeem", count: redeems + 1)
        assertSignedIn(good)
    }

    // MARK: - 配置

    /// `min_build` 高于本包：整屏「请更新」
    func testMinBuildShowsUpdateRequired() {
        a.update { $0.minBuild = 999_999 }
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["page.updateRequired"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["请更新"].exists)
    }

    /// 回到前台再取一次 `/v1/config`（PR #35 Fable 实测：原来回前台从不重取）。按 Home 再拉回来，系统走的是
    /// background → inactive → active；每回来一次桩上多一次 config，回来时新下发的 `min_build` 立刻生效
    func testReturningToForegroundRefetchesConfig() {
        let app = launch()
        waitFor(a, "/v1/config", count: 1)
        XCTAssertTrue(app.descendants(matching: .any)["page.login"].waitForExistence(timeout: 10))
        pause(1)
        XCTAssertEqual(a.count("/v1/config"), 1, "冷启动只取一次")
        for n in 2...3 {
            XCUIDevice.shared.press(.home)
            pause(1.5)
            app.activate()
            waitFor(a, "/v1/config", count: n)
        }
        a.update { $0.minBuild = 999_999 }
        XCUIDevice.shared.press(.home)
        pause(1.5)
        app.activate()
        waitFor(a, "/v1/config", count: 4)
        XCTAssertTrue(app.descendants(matching: .any)["page.updateRequired"].waitForExistence(timeout: 10))
    }

    /// 「看看演示」：开关开时能进演示小店，关时界面上找不到
    func testDemoEntryFollowsSwitch() {
        let off = launch()
        waitFor(a, "/v1/config")
        pause(1)
        XCTAssertFalse(off.descendants(matching: .any)["login.demo"].exists)
        XCTAssertFalse(off.staticTexts["看看演示"].exists)
        off.terminate()

        a.update { $0.demoEnabled = true }
        let on = launch()
        let demo = on.buttons["login.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        waitFor(a, "/v1/auth/demo")
        assertSignedIn(on)
    }
}

// MARK: - 本机桩服务器

/// 极简 HTTP/1.1 桩：一个连接一个请求，回完就关。行为由 `Behavior` 定，收到的请求都记下来。
final class StubServer: @unchecked Sendable {
    struct Behavior {
        var apiBase: String?
        var minBuild = 1
        var demoEnabled = false
    }

    struct Request {
        let method: String
        let path: String
        let body: [String: Any]?
    }

    static let storeName = "测试店甲小卖部"

    let name: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var behavior = Behavior()
    private var requests: [Request] = []
    private var failedLogins = 0
    private var lockedUntilValue: Date?

    private init(name: String) throws {
        self.name = name
        listener = try NWListener(using: .tcp, on: .any)
        queue = DispatchQueue(label: "stub-\(name)")
    }

    static func start(name: String) throws -> StubServer {
        let s = try StubServer(name: name)
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success, s.listener.port != nil else {
            throw NSError(domain: "StubServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "桩 \(name) 没起来"])
        }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func stop() { listener.cancel() }

    func update(_ f: (inout Behavior) -> Void) { lock.withLock { f(&behavior) } }

    func count(_ path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }
    var total: Int { lock.withLock { requests.count } }
    func lastBody(_ path: String) -> [String: Any]? { lock.withLock { requests.last { $0.path == path }?.body } }
    var lockedUntil: Date? { lock.withLock { lockedUntilValue } }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.respond(c, req)
            } else if done || error != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    /// 头收全、body 按 Content-Length 收全才算一个请求
    private static func parse(_ buf: Data) -> Request? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buf[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let json = length > 0 ? (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] : nil
        return Request(method: String(parts[0]), path: String(parts[1]), body: json)
    }

    private func respond(_ c: NWConnection, _ req: Request) {
        let (status, payload) = lock.withLock { () -> (Int, [String: Any]) in
            requests.append(req)
            return route(req)
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 204 { head = "HTTP/1.1 204 X\r\nConnection: close\r\n\r\n" }
        c.send(content: Data(head.utf8) + (status == 204 ? Data() : body), completion: .contentProcessed { _ in c.cancel() })
    }

    private func session(role: String = "family", label: String = "新手机", demo: Bool = false) -> [String: Any] {
        ["token": "tok-\(UUID().uuidString)", "epoch": UUID().uuidString.lowercased(), "role": role,
         "store": ["name": demo ? "演示小店" : Self.storeName, "is_demo": demo], "label": label]
    }

    /// 在锁里调
    private func route(_ req: Request) -> (Int, [String: Any]) {
        switch (req.method, req.path) {
        case ("GET", "/v1/config"):
            var c: [String: Any] = ["min_build": behavior.minBuild, "demo_login_enabled": behavior.demoEnabled,
                                    "privacy_url": "https://yuanhuishop.cn/privacy", "support_url": "https://yuanhuishop.cn/support"]
            if let b = behavior.apiBase { c["api_base"] = b }
            return (200, c)
        case ("POST", "/v1/auth/login"):
            if let until = lockedUntilValue, until > Date() {
                return (423, ["code": "locked", "locked_until": ISO8601DateFormatter().string(from: until)])
            }
            guard req.body?["password"] as? String == "123456789" else {
                failedLogins += 1
                if failedLogins >= 5 {
                    // 和服务器一样：第 5 次输错本身就回 423，锁 15 分钟
                    failedLogins = 0
                    let until = Date().addingTimeInterval(15 * 60)
                    lockedUntilValue = until
                    return (423, ["code": "locked", "locked_until": ISO8601DateFormatter().string(from: until)])
                }
                return (401, ["code": "bad_credentials"])
            }
            failedLogins = 0
            return (200, session(label: (req.body?["label"] as? String) ?? "新手机"))
        case ("POST", "/v1/auth/pair/redeem"):
            switch req.body?["code"] as? String {
            case "expired-code": return (410, ["code": "pairing_expired"])
            case "used-code": return (410, ["code": "pairing_used"])
            case "good-code": return (200, session(role: "family", label: "妈妈的手机"))
            default: return (404, ["code": "not_found"])
            }
        case ("POST", "/v1/auth/demo"):
            guard behavior.demoEnabled else { return (404, ["code": "not_found"]) }
            return (200, session(demo: true))
        case ("PATCH", "/v1/devices/me"):
            return (200, ["label": (req.body?["label"] as? String) ?? "新手机"])
        default:
            return (404, ["code": "not_found"])
        }
    }
}
