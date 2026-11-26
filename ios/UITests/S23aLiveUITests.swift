import Foundation
import XCTest

/// S23a 联调（plan-v2 §8 S23a 验收里两台手机的几条）：一台模拟器跑 App，测试进程自己当另一台手机走 API。
/// 只连本机服务端（临时 PG），平时跳过；由 `scripts/s23a-live.sh` 跑：
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   本机服务器、测试店账号和密码（密码只从环境变量来）
/// 按名字顺序跑；App 这边全走真实输入：扫码登录页 + 假相机喂 `YHZB1:<码>`（`-uiLoginCode`）、真实点按。
@MainActor
final class S23aLiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s23a-live.sh）")
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", env["YH_LIVE_BASE"]!, "-uiLargeText", "on", "-uiCamera", "authorized"]
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

    private func log(_ s: String) { print("S23A-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

    /// 登录页 → 「扫家里人手机上的码」→ 相机认出 `code`（真实的扫码登录路径）
    private func scan(_ code: String) -> XCUIApplication {
        let app = launch(["-uiLoginCode", code], fresh: true)
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        el(app, "login.scan").tap()
        // 假相机一进页就认出码：兑码成功时扫码页可能一闪就换成 16 / 首页，三者之一出现就算进了扫码路径
        wait("扫码页（或兑码后已进 16 / 首页）", timeout: 15) {
            el(app, "page.scanLogin").exists || el(app, "page.onboarding").exists || el(app, "page.home").exists
        }
        return app
    }

    /// 首次进入点完，到首页「已同步」
    private func toHome(_ app: XCUIApplication) {
        wait("首页或 16", timeout: 60) { el(app, "page.home").exists || el(app, "page.onboarding").exists }
        if el(app, "page.onboarding").exists { app.buttons["onboarding.done"].tap() }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
    }

    // MARK: 测试进程当另一台手机

    struct Phone {
        let base: String, token: String, epoch: String, deviceId: String
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
            return ((out.1 as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: out.0 ?? Data())) as? [String: Any] ?? [:])
        }
        static func login(_ env: [String: String]) throws -> Phone {
            let id = UUID().uuidString.lowercased()
            let r = try call(env["YH_LIVE_BASE"]!, "POST", "/v1/auth/login", ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                                                             "device_id": id, "label": "S23A 甲"]).json
            return Phone(base: env["YH_LIVE_BASE"]!, token: r["token"] as! String, epoch: r["epoch"] as! String, deviceId: id)
        }
        /// 另一台手机扫码（兑码）
        static func redeem(_ base: String, _ qr: String) throws -> (status: Int, phone: Phone?, code: String?) {
            let id = UUID().uuidString.lowercased()
            let r = try call(base, "POST", "/v1/auth/pair/redeem", ["code": String(qr.dropFirst("YHZB1:".count)), "device_id": id])
            guard r.status == 200 else { return (r.status, nil, r.json["code"] as? String) }
            return (200, Phone(base: base, token: r.json["token"] as! String, epoch: r.json["epoch"] as! String, deviceId: id), nil)
        }
        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> (status: Int, json: [String: Any]) {
            try Self.call(base, method, path, body, token: token)
        }
        func push(_ ops: [[String: Any]]) throws -> [[String: Any]] {
            let r = try call("POST", "/v1/sync", ["epoch": epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": false, "ops": ops])
            return r.json["results"] as? [[String: Any]] ?? []
        }
        func pairCode(role: String, label: String? = nil) throws -> String {
            var body: [String: Any] = ["role": role]; if let label { body["label"] = label }
            let r = try call("POST", "/v1/pairing-tokens", body)
            XCTAssertEqual(r.status, 201)
            return "YHZB1:" + (r.json["code"] as! String)
        }
        func devices() throws -> [[String: Any]] { try call("GET", "/v1/devices").json["devices"] as? [[String: Any]] ?? [] }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }
    static func op(_ type: String, _ payload: [String: Any], at: Date = Date()) -> [String: Any] {
        ["id": UUID().uuidString.lowercased(), "type": type, "occurred_at": iso(at), "payload": payload]
    }
    /// 甲登记一个商品（名字带时间，记的账里认得出）
    static func newProduct(_ a: Phone, name: String) throws -> (id: String, barcode: String) {
        let id = UUID().uuidString.lowercased(), code = "69" + String(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000_000)
        let r = try a.push([op("product_upsert", ["product_id": id, "barcode": code, "name": name, "price_fen": 500, "quick": false, "base_unit": "瓶"])])
        XCTAssertEqual(r.first?["status"] as? String, "applied")
        return (id, code)
    }
    static func sale(_ p: (id: String, barcode: String), name: String, at: Date = Date()) -> [String: Any] {
        op("sale_batch", ["batch_id": UUID().uuidString.lowercased(), "paid_total_fen": 500,
                          "lines": [["entry_id": UUID().uuidString.lowercased(), "product_id": p.id, "barcode": p.barcode, "name": name,
                                     "unit_name": "瓶", "pack_qty": 1, "pack_count": 1, "unit_price_fen": 500]]], at: at)
    }

    /// 记的账（看账页里的入口）里等到一张卡含 `text`
    private func waitRecord(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) {
        if !el(app, "page.records").exists {
            el(app, "home.reports").tap()
            el(app, "reports.records").tap()
        }
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 10))
        // 卡片容器本身的 label 不含商品名（RecordCardView 不合并子元素），要看卡片里的文字
        let found = {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'records.card.'"))
                .containing(NSPredicate(format: "label CONTAINS %@", text)).count > 0
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !found() { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        if !found() { shot(app, "records-timeout"); print(app.debugDescription) }
        XCTAssertTrue(found(), "记的账里出现「\(text)」")
    }

    // MARK: 用例

    /// A 出家人码，B（App）扫后 20 秒内看到 A 的流水
    func test1FamilyCodeSeesARecords() throws {
        let a = try Phone.login(env)
        let name = "S23A 甲卖的 \(Int(Date().timeIntervalSince1970) % 100_000)"
        let p = try Self.newProduct(a, name: name)
        XCTAssertEqual(try a.push([Self.sale(p, name: name)]).first?["status"] as? String, "applied")
        let code = try a.pairCode(role: "family")
        let app = scan(code)
        toHome(app)
        let t0 = Date()
        log("B 进了首页")
        waitRecord(app, name, timeout: 20)
        log("B 看到甲的卖出，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(t0), 20)
        shot(app, "s23a-live-b-sees-a")
        // 同一个码再扫：另一台扫失败
        let again = try Phone.redeem(a.base, code)
        XCTAssertEqual(again.status, 410)
        XCTAssertEqual(again.code, "pairing_used")
    }

    /// 同一个码，另一台先扫了：App 再扫失败，说「这个码已经用过了」
    func test2UsedCodeFailsOnSecondPhone() throws {
        let a = try Phone.login(env)
        let code = try a.pairCode(role: "family")
        XCTAssertEqual(try Phone.redeem(a.base, code).status, 200, "第一台扫成功")
        let app = scan(code)
        let msg = app.staticTexts["scanLogin.message"]
        XCTAssertTrue(msg.waitForExistence(timeout: 15))
        XCTAssertEqual(msg.label, "这个码已经用过了，让家里人换一个新码")
        shot(app, "s23a-live-used")
    }

    /// B 扫收银员码 → 02 收银员首页（只有卖出，没有进货、看账）
    func test3CashierCodeOpensCashierHome() throws {
        let a = try Phone.login(env)
        let code = try a.pairCode(role: "cashier", label: "小李")
        let app = scan(code)
        toHome(app)
        XCTAssertTrue(el(app, "home.sell").exists, "收银员首页有卖出")
        XCTAssertFalse(el(app, "home.stockIn").exists, "收银员首页没有进货")
        XCTAssertFalse(el(app, "home.reports").exists, "收银员首页没有看账")
        shot(app, "s23a-live-02")
        let me = try a.devices().filter { $0["role"] as? String == "cashier" && ($0["label"] as? String)?.hasPrefix("小李") == true }
        XCTAssertFalse(me.isEmpty, "服务器上多了一台收银员")
    }

    /// App 当 A：账号密码登录 → 开通页出码 → 测试进程读出二维码里的码去兑 → App 显示对方已登录、列表多一台；
    /// 再「让它退出」（先确认）→ 那台之后记的账被拒（不能再记账）
    func test4AppIssuesCodeThenRevokes() throws {
        let login = launch(fresh: true)
        XCTAssertTrue(el(login, "page.login").waitForExistence(timeout: 20))
        let u = login.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
        let p = login.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
        login.buttons["login.submit"].tap()
        toHome(login)
        login.terminate()
        let app = launch(["-uiRoute", "pairing"])
        let qr = el(app, "pairing.qr")
        XCTAssertTrue(qr.waitForExistence(timeout: 20))
        let code = try XCTUnwrap(qr.value as? String)
        XCTAssertTrue(code.hasPrefix("YHZB1:"))
        let b = try XCTUnwrap(Phone.redeem(env["YH_LIVE_BASE"]!, code).phone, "另一台扫 App 出的码")
        let used = el(app, "pairing.used")
        XCTAssertTrue(used.waitForExistence(timeout: 10), "App 轮询到被扫了")
        let label = try XCTUnwrap(try b.call("POST", "/v1/sync", ["epoch": b.epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": false, "ops": []]).json["device"] as? [String: Any])["label"] as? String
        XCTAssertEqual(used.label, "「\(label ?? "")」已经登录了")
        let revoke = el(app, "devices.revoke.\(label ?? "")")
        XCTAssertTrue(revoke.waitForExistence(timeout: 10), "列表里多了这台")
        shot(app, "s23a-live-used")
        revoke.tap()
        el(app, "devices.revoke.cancel").tap()
        XCTAssertTrue(try b.devices().count > 0, "点「不了」后那台还能用")
        revoke.tap()
        el(app, "devices.revoke.confirm").tap()
        wait("列表里这台没了") { !self.el(app, "devices.revoke.\(label ?? "")").exists }
        // 被退出的手机：之后记的账一律拒收；令牌只能补传
        let a = try Phone.login(env)
        let prod = try Self.newProduct(a, name: "S23A 退出后")
        let r = try b.push([Self.sale(prod, name: "S23A 退出后", at: Date().addingTimeInterval(5))])
        XCTAssertEqual(r.first?["status"] as? String, "rejected")
        XCTAssertEqual(r.first?["code"] as? String, "forbidden")
        XCTAssertEqual(try b.call("GET", "/v1/devices").status, 401, "被退出的手机别的接口都 401")
        try b.deviceId.write(toFile: "/tmp/yh-s23a-revoked-device", atomically: true, encoding: .utf8)
    }

    /// 被退出的手机补传了进货（退出前记的）→ App「已登录的手机」里那台「去看看」→ 逐笔「记上」→ 记的账里出现这笔进货
    func test5HeldAcceptShowsInRecords() throws {
        let a = try Phone.login(env)
        let name = "S23A 补传进货 \(Int(Date().timeIntervalSince1970) % 100_000)"
        let prod = try Self.newProduct(a, name: name)
        let code = try a.pairCode(role: "family")
        let x = try XCTUnwrap(Phone.redeem(a.base, code).phone)
        let before = Date()
        XCTAssertEqual(try a.call("POST", "/v1/devices/\(x.deviceId)/revoke").status, 204)
        let stock = Self.op("stock_in", ["entry_id": UUID().uuidString.lowercased(), "product_id": prod.id, "barcode": prod.barcode,
                                         "pack_qty": 1, "pack_count": 4, "unit_cost_fen": 300], at: before.addingTimeInterval(-60))
        XCTAssertEqual(try x.push([stock]).first?["status"] as? String, "held")
        let label = try XCTUnwrap(try a.devices().first { $0["id"] as? String == x.deviceId }?["label"] as? String)
        let app = launch(["-uiRoute", "devices"])
        let go = el(app, "devices.held.\(label)")
        XCTAssertTrue(go.waitForExistence(timeout: 20))
        go.tap()
        XCTAssertTrue(el(app, "page.held").waitForExistence(timeout: 10))
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'held.text' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "列出这笔进货")
        shot(app, "s23a-live-held")
        app.buttons["held.accept"].firstMatch.tap()
        XCTAssertTrue(el(app, "held.flash").waitForExistence(timeout: 10))
        app.terminate()
        let again = launch(["-uiRoute", "records"])
        waitRecord(again, name, timeout: 30)
        shot(again, "s23a-live-held-in-records")
        let held = try a.call("GET", "/v1/held-ops").json["held"] as? [[String: Any]] ?? []
        XCTAssertFalse(held.contains { $0["id"] as? String == stock["id"] as? String }, "服务器上这笔已处理")
    }
}
