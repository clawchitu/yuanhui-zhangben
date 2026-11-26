import Foundation
import XCTest

/// S22b 联调（plan-v2 §8 S22b 验收）：只连本机服务端（SCRAM 临时 PG），平时跳过。由 `scripts/s22b-live.sh` 跑：
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   本机服务器、测试店账号和密码（密码只从环境变量来）
///   TEST_RUNNER_YH_DEMO_USER                        演示店审核号（密码同上）
/// 店里要先用 `scripts/s22a-seed.ts` 铺好测试啤酒。要动数据库的两步（换 epoch、演示店重置）由脚本看信号文件做：
/// 测试写 `/tmp/yh-s22b-signal/<名字>`，脚本做完写 `<名字>.done`。
/// 服务器上的事实由测试进程自己以另一台设备登录、走 API 核对。
@MainActor
final class S22bLiveUITests: XCTestCase {
    static let beer = "6970000099010"
    static let demoErguotou = "6901234500011"   // 演示数据里的二锅头：服务器上没有这个商品
    static let signalDir = "/tmp/yh-s22b-signal"
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s22b-live.sh）")
        continueAfterFailure = false
    }

    // MARK: - 小工具

    private func launch(_ extra: [String] = [], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", env["YH_LIVE_BASE"]!, "-uiLargeText", "on"]
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

    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    private func syncLabel(_ app: XCUIApplication) -> String {
        let l = app.descendants(matching: .any).matching(identifier: "syncStatus").allElementsBoundByIndex.map(\.label).joined(separator: " ")
        for k in ["已同步", "没网"] where l.contains(k) { return k }
        if let r = l.range(of: #"\d+ 笔待传"#, options: .regularExpression) { return String(l[r]) }
        return l
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// 首次进入（16 / 16b）点完，到首页「已同步」
    private func toSyncedHome(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        wait("首页或 16", timeout: timeout) { el(app, "page.home").exists || el(app, "page.onboarding").exists }
        if el(app, "page.onboarding").exists { app.buttons["onboarding.done"].tap() }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        wait("已同步（现在「\(syncLabel(app))」）", timeout: timeout) { syncLabel(app) == "已同步" }
    }

    /// 全新安装、账号密码登录，到首页已同步
    private func freshLogin() {
        let app = launch(fresh: true)
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        let u = app.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
        let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        toSyncedHome(app)
        app.terminate()
    }

    private func sellOffline(_ code: String) {
        let app = launch(["-uiOffline", "-uiRoute", "sell", "-uiScan", code, "-uiAutoCommit", "-uiProbe"])
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 20), "断网也记好了")
        app.terminate()
    }

    private func stockInOffline(_ code: String, qty: String, cost: String, extra: [String] = []) {
        let app = launch(["-uiOffline", "-uiRoute", "stockIn", "-uiScan", code] + extra)
        XCTAssertTrue(el(app, "stockIn.qty").waitForExistence(timeout: 20))
        el(app, "stockIn.qty").tap()   // 单件码是步进器 + 键盘按钮：先打开键盘
        keys(app, qty)
        el(app, "stockIn.cost").tap()
        keys(app, cost)
        el(app, "stockIn.commit").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.terminate()
    }

    /// 断网退出登录：设置 → 退出登录 → 确认 → 「还有 N 笔待传」→ 知道了 → 登录页
    private func logoutOffline(expect n: Int) {
        let app = launch(["-uiOffline", "-uiRoute", "settings,logout"])
        XCTAssertTrue(el(app, "page.logout").waitForExistence(timeout: 20))
        // S23a 起确认在 26 面板里（进页自动弹出），等面板出来再点
        XCTAssertTrue(el(app, "logout.confirm").waitForExistence(timeout: 10))
        el(app, "logout.confirm").tap()
        XCTAssertTrue(el(app, "logout.pending").waitForExistence(timeout: 30))
        XCTAssertEqual(el(app, "logout.pending").label, "还有 \(n) 笔待传，联网后会自动补传")
        shot(app, "logout-offline-pending")
        el(app, "logout.ok").tap()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20), "回登录页")
        app.terminate()
    }

    /// 等脚本做完要动数据库的那一步
    private func signal(_ name: String, timeout: TimeInterval = 120) throws {
        try FileManager.default.createDirectory(atPath: Self.signalDir, withIntermediateDirectories: true)
        try "1".write(toFile: "\(Self.signalDir)/\(name)", atomically: true, encoding: .utf8)
        wait("脚本做完 \(name)", timeout: timeout) { FileManager.default.fileExists(atPath: "\(Self.signalDir)/\(name).done") }
    }

    // MARK: - 服务器核对（测试进程自己当一台家用手机）

    struct Server {
        let base: String, token: String, epoch: String
        static func login(_ env: [String: String], user: String? = nil) throws -> Server {
            let r = try call(env["YH_LIVE_BASE"]!, "POST", "/v1/auth/login", ["username": user ?? env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                                                             "device_id": UUID().uuidString.lowercased(), "label": "S22B 核对"]).json
            return Server(base: env["YH_LIVE_BASE"]!, token: r["token"] as! String, epoch: r["epoch"] as! String)
        }
        static func call(_ base: String, _ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) throws -> (status: Int, json: [String: Any]) {
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
            let status = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: out.0 ?? Data())) as? [String: Any] ?? [:]
            return (status, json)
        }
        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> (status: Int, json: [String: Any]) {
            try Self.call(base, method, path, body, token: token)
        }
        func pullAll() throws -> (barcodes: [[String: Any]], entries: [[String: Any]]) {
            var cur: [String: Any] = ["catalog": 0, "ledger": 0]
            var b: [[String: Any]] = [], e: [[String: Any]] = []
            for _ in 0..<50 {
                let r = try call("POST", "/v1/sync", ["epoch": epoch, "cursors": cur, "app_build": 1, "pull": true, "ops": []]).json
                let c = r["changes"] as! [String: Any]
                b += c["barcodes"] as! [[String: Any]]; e += c["entries"] as! [[String: Any]]
                cur = r["cursors"] as! [String: Any]
                let more = r["has_more"] as! [String: Bool]
                if !more["catalog"]! && !more["ledger"]! { break }
            }
            return (b, e)
        }
        /// 这个设备记的原行（不含冲销行）
        func entries(device: String) throws -> [[String: Any]] {
            try pullAll().entries.filter { $0["device_id"] as? String == device && $0["reverses_entry_id"] is NSNull }
        }
        /// 已登录的手机（含被退出但还有待确认的）
        func devices() throws -> [[String: Any]] { try call("GET", "/v1/devices").json["devices"] as? [[String: Any]] ?? [] }
        /// App 那台手机：最新的、不是核对用的
        func appDevice(role: String = "family") throws -> String {
            let ds = try devices().filter { $0["role"] as? String == role && ($0["label"] as? String)?.hasPrefix("S22") != true && $0["is_me"] as? Bool != true }
            return try XCTUnwrap(ds.max { ($0["created_at"] as! String) < ($1["created_at"] as! String) }?["id"] as? String)
        }
        func revoke(_ id: String) throws { XCTAssertEqual(try call("POST", "/v1/devices/\(id)/revoke").status, 204) }
        func pairCode(role: String, label: String? = nil) throws -> String {
            var body: [String: Any] = ["role": role]; if let label { body["label"] = label }
            let r = try call("POST", "/v1/pairing-tokens", body)
            XCTAssertEqual(r.status, 201)
            return "YHZB1:" + (r.json["code"] as! String)
        }
    }

    private func late(_ e: [String: Any]) -> Bool { (e["flags"] as? [String: Any])?["late_from_revoked"] as? Bool == true }

    // MARK: - 用例（按名字顺序跑）

    /// 被踢的家用手机：下一次同步后进 25b，有没传的显示笔数；联网补传后卖出带补传标记入账，进货变待确认，家用确认后才入账
    func test1KickedFamily() throws {
        freshLogin()
        let server = try Server.login(env)
        let device = try server.appDevice()
        sellOffline(Self.beer); sellOffline(Self.beer)
        stockInOffline(Self.beer, qty: "2", cost: "3")
        try server.revoke(device)
        // 一批只推 1 笔、恢复队列连不上：第一笔推上去才知道被踢，剩下 2 笔留在恢复队列
        let app = launch(["-uiMaxBatchOps", "1", "-uiRecoveryOffline"])
        XCTAssertTrue(el(app, "page.kicked").waitForExistence(timeout: 40), "进 25b")
        XCTAssertTrue(el(app, "kicked.pending").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "kicked.pending").label.contains("还有 2 笔待传"), el(app, "kicked.pending").label)
        shot(app, "25b-kicked-live")
        app.terminate()
        // 重开（联网）：启动时用旧令牌补传，黄卡消失
        let again = launch()
        XCTAssertTrue(el(again, "page.kicked").waitForExistence(timeout: 20), "重启后仍是 25b")
        wait("补传完、黄卡消失") { !el(again, "kicked.pending").exists }
        shot(again, "25b-kicked-drained-live")
        let es = try server.entries(device: device)
        let sales = es.filter { $0["type"] as? String == "sale" }
        XCTAssertEqual(sales.count, 2, "两笔卖出都入账")
        XCTAssertTrue(sales.allSatisfy(late), "带补传标记")
        XCTAssertTrue(es.filter { $0["type"] as? String == "stock_in" }.isEmpty, "进货没直接入账")
        let held = try server.call("GET", "/v1/held-ops").json["held"] as? [[String: Any]] ?? []
        let mine = held.filter { $0["device_id"] as? String == device }
        XCTAssertEqual(mine.map { $0["type"] as? String }, ["stock_in"], "进货待确认")
        let id = try XCTUnwrap(mine.first?["id"] as? String)
        XCTAssertEqual(try server.call("POST", "/v1/held-ops/\(id)/resolve", ["action": "accept"]).status, 200)
        let after = try server.entries(device: device).filter { $0["type"] as? String == "stock_in" }
        XCTAssertEqual(after.count, 1, "家用确认后才入账")
        XCTAssertTrue(after.allSatisfy(late))
        // 25b「重新登录」→ 登录页
        el(again, "kicked.continue").tap()
        XCTAssertTrue(el(again, "page.login").waitForExistence(timeout: 10))
    }

    /// 断网退出登录：提示 N 笔没传；联网后用旧令牌补传成功，然后才注销旧令牌（先后由脚本在库里核对时间）
    func test2OfflineLogout() throws {
        freshLogin()
        let server = try Server.login(env)
        let device = try server.appDevice()
        sellOffline(Self.beer); sellOffline(Self.beer)
        logoutOffline(expect: 2)
        XCTAssertTrue(try server.devices().contains { $0["id"] as? String == device }, "没网：旧令牌还没注销")
        XCTAssertEqual(try server.entries(device: device).count, 0)
        let app = launch()   // 联网打开 App（登录页）：启动时补传
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        try wait("补传完并注销") { try !server.devices().contains { $0["id"] as? String == device } }
        let es = try server.entries(device: device)
        XCTAssertEqual(es.count, 2, "两笔都以原设备入账")
        XCTAssertFalse(es.contains(where: late), "退出前记的，不是被踢补传")
        try "\(device)".write(toFile: "\(Self.signalDir)/logout-device", atomically: true, encoding: .utf8)
    }

    /// 家用手机改扫收银员码：投影清空、原来未传的仍以原设备入账；兑码后第一次拉取前先用旧令牌传，照常进首页（02）
    func test3FamilyToCashier() throws {
        freshLogin()
        let server = try Server.login(env)
        let family = try server.appDevice()
        sellOffline(Self.beer); sellOffline(Self.beer)
        logoutOffline(expect: 2)
        let code = try server.pairCode(role: "cashier", label: "小王")
        // 启动时不补传：留给兑码之后、第一次拉取之前那一趟
        let app = launch(["-uiNoLaunchRecovery", "-uiRedeemCode", code])
        toSyncedHome(app)
        shot(app, "02-cashier-after-redeem-live")
        let cashier = try server.appDevice(role: "cashier")
        XCTAssertNotEqual(cashier, family)
        let es = try server.entries(device: family)
        XCTAssertEqual(es.count, 2, "两笔以原家用设备入账")
        XCTAssertTrue(try server.entries(device: cashier).isEmpty, "不会变成收银员的流水")
        try wait("旧令牌传完后注销") { try !server.devices().contains { $0["id"] as? String == family } }
        try "\(cashier)".write(toFile: "\(Self.signalDir)/cashier-device", atomically: true, encoding: .utf8)
    }

    /// 收银员被踢后重新扫码：旧 op 归在旧设备名下（补传标记），新会话是新设备；被踢进 25f
    func test4CashierKickedRescan() throws {
        let server = try Server.login(env)
        let old = try String(contentsOfFile: "\(Self.signalDir)/cashier-device", encoding: .utf8)
        sellOffline(Self.beer)
        try server.revoke(old)
        let app = launch()
        XCTAssertTrue(el(app, "page.kickedCashier").waitForExistence(timeout: 40), "进 25f")
        shot(app, "25f-kicked-cashier-live")
        app.terminate()
        let code = try server.pairCode(role: "cashier", label: "小王")
        let again = launch(["-uiRedeemCode", code])
        toSyncedHome(again)
        let new = try server.appDevice(role: "cashier")
        XCTAssertNotEqual(new, old, "新会话是新设备")
        let es = try server.entries(device: old)
        XCTAssertEqual(es.count, 1, "旧 op 归在旧设备名下")
        XCTAssertTrue(es.allSatisfy(late))
        XCTAssertTrue(try server.entries(device: new).isEmpty)
    }

    /// 换登另一家店（审核号）：原店未传的 op 不进演示店，用原店旧令牌补到原店
    func test5SwitchToDemoStore() throws {
        freshLogin()
        let server = try Server.login(env)
        let family = try server.appDevice()
        sellOffline(Self.beer)
        logoutOffline(expect: 1)
        let app = launch(["-uiNoLaunchRecovery", "-uiDemoLogin"])
        toSyncedHome(app)
        let demo = try Server.login(env, user: env["YH_DEMO_USER"]!)
        let demoEntries = try demo.pullAll().entries
        XCTAssertFalse(demoEntries.contains { $0["barcode"] as? String == Self.beer }, "原店的卖出不进演示店")
        XCTAssertEqual(try server.entries(device: family).count, 1, "补到原店、原设备")
    }

    /// 演示店重置（discard_outbox）：手机丢弃 outbox，不重放，回登录页
    func test6DemoReset() throws {
        let demo = try Server.login(env, user: env["YH_DEMO_USER"]!)
        let code = try XCTUnwrap(demo.pullAll().barcodes.first { ($0["pack_qty"] as? Int) == 1 }?["barcode"] as? String)
        let before = try demo.pullAll().entries.count
        sellOffline(code)
        try signal("demo-reset")
        let app = launch()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 40), "回登录页")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let demo2 = try Server.login(env, user: env["YH_DEMO_USER"]!)
        XCTAssertEqual(try demo2.pullAll().entries.count, before, "不重放")
    }

    /// 被拒的 op：首页提示「N 笔没记上」，不再重试，「知道了」收起
    func test7RejectedPrompt() throws {
        freshLogin()
        stockInOffline(Self.demoErguotou, qty: "2", cost: "10", extra: ["-uiInjectDemo"])
        let app = launch()
        toSyncedHome(app)
        XCTAssertTrue(el(app, "home.banner.rejected").waitForExistence(timeout: 30), "首页提示没记上")
        XCTAssertTrue(el(app, "home.banner.rejected.text").label.hasPrefix("1 笔没记上"))
        shot(app, "home-rejected-live")
        el(app, "home.banner.rejected.ok").tap()
        wait("收起") { !el(app, "home.banner.rejected").exists }
        XCTAssertEqual(syncLabel(app), "已同步", "被拒的不算待传、不再重试")
    }

    /// 服务器换 epoch（从备份恢复）：手机握手、重建投影、重传保留的 op；备份之后的流水补回，服务器上不重复
    func test8EpochChange() throws {
        freshLogin()
        let server0 = try Server.login(env)
        let device = try server0.appDevice()
        let a = launch(["-uiRoute", "sell", "-uiScan", Self.beer, "-uiAutoCommit", "-uiProbe"])
        XCTAssertTrue(el(a, "sell.done").waitForExistence(timeout: 20)); a.terminate()
        toSyncedHome(launch())
        XCUIApplication().terminate()
        try signal("backup")        // 脚本 pg_dump
        let b = launch(["-uiRoute", "sell", "-uiScan", Self.beer, "-uiAutoCommit", "-uiProbe"])
        XCTAssertTrue(el(b, "sell.done").waitForExistence(timeout: 20)); b.terminate()
        toSyncedHome(launch())
        XCUIApplication().terminate()
        XCTAssertEqual(try server0.entries(device: device).count, 2)
        try signal("restore")       // 脚本停服务器、pg_restore、换 epoch、再起服务器
        let server = try Server.login(env)
        XCTAssertEqual(try server.entries(device: device).count, 1, "恢复后只剩备份前那一笔")
        let app = launch()
        toSyncedHome(app, timeout: 120)
        let es = try server.entries(device: device)
        XCTAssertEqual(es.count, 2, "备份之后那笔补回")
        XCTAssertEqual(Set(es.compactMap { $0["op_id"] as? String }).count, 2, "服务器上不重复")
    }
}
