import Network
import XCTest

/// 设置页（家用 21a「更多」、收银员 21b「设置」）的「隐私政策」：和登录页一样用系统浏览器打开隐私政策网页，
/// 不再进 App 里「这一页还在做 / 开发计划 S21 段」的占位页（TestFlight 0.1.0 (11272333) 上强哥发现的）。
/// 用 `-uiFixture settings`（内存库 + 演示数据，没有服务 → 用默认地址 https://yuanhuishop.cn/privacy），不需要服务器。
@MainActor
final class PrivacyLinkUITests: XCTestCase {
    private func assertOpensBrowser(_ role: String, extraArgs: [String] = [], expect: String = "yuanhuishop.cn/privacy",
                                    beforeTap: (() -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "settings", "-uiRole", role] + extraArgs
        app.launch()
        XCTAssertTrue(app.otherElements["page.settings"].waitForExistence(timeout: 10), file: file, line: line)
        let row = app.descendants(matching: .any)["settings.item.privacy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "「隐私政策」能点到", file: file, line: line)
        XCTAssertEqual(row.elementType, .link, "是外链，不是 App 内的导航行", file: file, line: line)
        beforeTap?()
        row.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "点了以后系统浏览器到前台", file: file, line: line)
        // 打开的是隐私政策地址（夹具没有服务 → 默认地址；带 -uiAPI 桩 → 服务器下发的地址）
        // 底栏地址条平时只显示域名，点一下进编辑态，地址框里才是完整 URL（没网也一样）
        let bar = safari.descendants(matching: .any)["TabBarItemTitle"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "Safari 地址条", file: file, line: line)
        bar.tap()
        let field = safari.textFields["URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Safari 地址框", file: file, line: line)
        XCTAssertTrue((field.value as? String ?? "").contains(expect),
                      "打开的是隐私政策地址：\(field.value ?? "")", file: file, line: line)
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

    /// 服务器下发了别的隐私政策地址：设置页打开的是下发的那个（和登录页同一来源），不是写死的默认地址
    func testPrivacyOpensServerProvidedURL() throws {
        let stub = try ConfigStub.start(privacyURL: "https://yuanhuishop.cn/privacy-from-server")
        defer { stub.stop() }
        assertOpensBrowser("family", extraArgs: ["-uiAPI", "http://localhost:\(stub.port)", "-uiConfig"],
                           expect: "yuanhuishop.cn/privacy-from-server",
                           beforeTap: {
                               let end = Date().addingTimeInterval(10)
                               while stub.configRequests == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
                               XCTAssertGreaterThan(stub.configRequests, 0, "App 取过配置")
                               Thread.sleep(forTimeInterval: 0.5)   // 回包解析完
                           })
    }
}

/// 只回 `/v1/config` 的桩：隐私政策地址换成测试给的；别的路径一律 404
final class ConfigStub: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "privacy-config-stub")
    private let lock = NSLock()
    private let privacyURL: String
    private var configCount = 0

    private init(privacyURL: String) throws {
        self.privacyURL = privacyURL
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(privacyURL: String) throws -> ConfigStub {
        let s = try ConfigStub(privacyURL: privacyURL)
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ConfigStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var configRequests: Int { lock.withLock { configCount } }
    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = String(decoding: data ?? Data(), as: UTF8.self)
            let isConfig = head.hasPrefix("GET /v1/config")
            var status = "404 X", body = Data("{}".utf8)
            if isConfig {
                lock.withLock { configCount += 1 }
                status = "200 OK"
                body = (try? JSONSerialization.data(withJSONObject: [
                    "min_build": 1, "demo_login_enabled": false,
                    "privacy_url": privacyURL, "support_url": "https://yuanhuishop.cn/support"])) ?? body
            }
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(resp.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
