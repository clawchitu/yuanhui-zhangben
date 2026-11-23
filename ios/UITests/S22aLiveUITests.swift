import Foundation
import XCTest

/// S22a 联调（plan-v2 §8 S22a 验收）：连本机服务端（破坏性用例）或线上测试店（只跑正常同步、首次同步）。平时跳过。
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   服务器地址、账号、密码（密码运行时从钥匙串读，不写文件）
///   TEST_RUNNER_YH_S22A_DESTRUCTIVE=1               另跑断网、强杀、拒绝、remap、进货（只对本机服务端）
///   TEST_RUNNER_YH_S22A_OBSERVER=1                  只跑「第二台」：在 07a 等别的手机记的账出现（另一台模拟器同时跑断网三笔）
/// 店里要先用 `scripts/s22a-seed.ts` 铺好 312 样商品（见 `scripts/s22a-live.sh`）。用例按名字顺序跑，第一条做全新登录。
/// 服务器上的事实（每条流水恰好一条、库存、别名）由测试进程自己以另一台设备登录、拉流水来核对。
@MainActor
final class S22aLiveUITests: XCTestCase {
    static let beer = "6970000099010", zhCarton = "6970000099002"
    static let demoBeer = "6901035600016"   // 演示数据里的青岛啤酒：服务器上没有这个商品，卖它会被拒
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var destructive: Bool { env["YH_S22A_DESTRUCTIVE"] == "1" }
    private var observer: Bool { env["YH_S22A_OBSERVER"] == "1" }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（设 TEST_RUNNER_YH_LIVE_BASE）")
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

    private func wait(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    private func probe(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in el(app, "debug.ledger").label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func syncLabel(_ app: XCUIApplication) -> String { el(app, "syncStatus").label }

    /// 断网卖一笔（-uiOffline：同步请求一律连不上）：开到卖出页、假扫码、自动收款，等「记好了」
    private func sellOffline(_ code: String, extra: [String] = []) {
        let app = launch(["-uiOffline", "-uiRoute", "sell", "-uiScan", code, "-uiAutoCommit", "-uiProbe"] + extra)
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 20), "断网也记好了")
        app.terminate()
    }

    /// 带 -uiCrashAt 启动：同步走到那个点进程自己退出（和划掉 App 一样）
    private func crash(at point: String) {
        let app = launch(["-uiCrashAt", point])
        wait("在 \(point) 退出", timeout: 60) { app.state == .notRunning }
    }

    /// 正常启动到首页，等「已同步」
    @discardableResult
    private func syncedHome(_ extra: [String] = [], timeout: TimeInterval = 60) -> XCUIApplication {
        let app = launch(extra)
        XCTAssertTrue(el(app, "syncStatus").waitForExistence(timeout: 20))
        wait("已同步（现在「\(syncLabel(app))」）", timeout: timeout) { syncLabel(app) == "已同步" }
        return app
    }

    // MARK: - 服务器核对（测试进程自己当一台手机）

    private struct Server {
        let base: String, token: String, epoch: String
        static func login(_ env: [String: String]) throws -> Server {
            let r = try call(env["YH_LIVE_BASE"]!, "/v1/auth/login", ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                                                     "device_id": UUID().uuidString.lowercased(), "label": "S22A 核对"])
            return Server(base: env["YH_LIVE_BASE"]!, token: r["token"] as! String, epoch: r["epoch"] as! String)
        }
        static func call(_ base: String, _ path: String, _ body: [String: Any], token: String? = nil) throws -> [String: Any] {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Data?, Error?)
            URLSession.shared.dataTask(with: req) { d, _, e in out = (d, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.1 { throw e }
            return try JSONSerialization.jsonObject(with: out.0 ?? Data()) as? [String: Any] ?? [:]
        }
        func sync(_ ops: [[String: Any]] = []) throws -> [String: Any] {
            try Self.call(base, "/v1/sync", ["epoch": epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": true, "ops": ops], token: token)
        }
        /// 从头拉到底：商品、条码、流水
        func pullAll() throws -> (products: [[String: Any]], barcodes: [[String: Any]], entries: [[String: Any]]) {
            var cur: [String: Any] = ["catalog": 0, "ledger": 0]
            var p: [[String: Any]] = [], b: [[String: Any]] = [], e: [[String: Any]] = []
            for _ in 0..<50 {
                let r = try Self.call(base, "/v1/sync", ["epoch": epoch, "cursors": cur, "app_build": 1, "pull": true, "ops": []], token: token)
                let c = r["changes"] as! [String: Any]
                p += c["products"] as! [[String: Any]]; b += c["barcodes"] as! [[String: Any]]; e += c["entries"] as! [[String: Any]]
                cur = r["cursors"] as! [String: Any]
                let more = r["has_more"] as! [String: Bool]
                if !more["catalog"]! && !more["ledger"]! { break }
            }
            return (p, b, e)
        }
        func productId(barcode: String) throws -> String? {
            try pullAll().barcodes.last { $0["barcode"] as? String == barcode }?["product_id"] as? String
        }
        /// 这个商品的卖出原行（不含冲销行）
        func sales(of pid: String) throws -> [[String: Any]] {
            try pullAll().entries.filter { $0["product_id"] as? String == pid && $0["type"] as? String == "sale" && $0["reverses_entry_id"] is NSNull }
        }
        func stock(of pid: String) throws -> (qty: Int, value: Int) {
            let p = try XCTUnwrap(pullAll().products.last { $0["id"] as? String == pid })
            let v = try XCTUnwrap(p["private"] as? [String: Any])
            return ((v["stock_qty"] as! NSNumber).intValue, (v["stock_value_fen"] as! NSNumber).intValue)
        }
    }

    // MARK: - 用例

    /// 首次同步：全新登录后先见 29「n / 312 样」，商品拉完进 16，做完首次进入到首页「已同步」
    func test1FirstSync() throws {
        let app = launch(["-uiSyncDelayMs", "400"], fresh: true)
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 15))
        let u = app.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
        let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(el(app, "page.firstSync").waitForExistence(timeout: 20), "登录后先进 29")
        let count = el(app, "firstSync.count")
        wait("进度「n / 312 样」（现在「\(count.label)」）") { count.label.range(of: #"^\d+ / \d+ 样$"#, options: .regularExpression) != nil }
        print("S22A 首次同步进度：\(count.label)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "29-first-sync-live"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(el(app, "page.onboarding").waitForExistence(timeout: 120), "商品拉完进 16")
        app.buttons["onboarding.done"].tap()
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 15))
        wait("已同步", timeout: 120) { syncLabel(app) == "已同步" }
    }

    /// 断网卖三笔 → 联网 → 服务器上每条流水恰好一条（另一台模拟器同时跑 observer，看 20 秒内出现）
    func test2OfflineThreeSalesThenUpload() throws {
        try XCTSkipIf(observer || !destructive)
        let server = try Server.login(env)
        let pid = try XCTUnwrap(server.productId(barcode: Self.beer))
        let before = try server.sales(of: pid).count
        for _ in 0..<3 { sellOffline(Self.beer) }
        let off = launch(["-uiOffline"])
        XCTAssertTrue(el(off, "syncStatus").waitForExistence(timeout: 15))
        XCTAssertEqual(syncLabel(off), "没网")
        off.terminate()
        let t0 = Date()
        syncedHome()
        print("S22A 联网后 \(Int(Date().timeIntervalSince(t0))) 秒传完")
        let after = try server.sales(of: pid)
        XCTAssertEqual(after.count, before + 3, "服务器上三笔各一条")
        XCTAssertEqual(Set(after.compactMap { $0["op_id"] as? String }).count, after.count, "没有重复的 op")
        try FileManager.default.createDirectory(atPath: "/tmp/yh-s22a-signal", withIntermediateDirectories: true)
        try? "\(t0.timeIntervalSince1970)".write(toFile: "/tmp/yh-s22a-signal/uploaded", atomically: true, encoding: .utf8)
    }

    /// 三处强杀：请求发出后 / 响应到达后本地提交前 / 本地提交中途。重启后不漏拉、不重复扣临时库存、服务器上不重复记账
    func test3CrashPoints() throws {
        try XCTSkipIf(observer || !destructive)
        let server = try Server.login(env)
        let pid = try XCTUnwrap(server.productId(barcode: Self.beer))
        for point in ["afterSend", "beforeCommit", "midCommit"] {
            let before = try server.sales(of: pid).count
            sellOffline(Self.beer)
            crash(at: point)
            syncedHome()
            let after = try server.sales(of: pid).count
            XCTAssertEqual(after, before + 1, "\(point)：服务器上恰好一条")
            // 本机显示库存 = 服务器库存（基线换成服务器的、待传增减消失，没有重复扣）
            let app = launch(["-uiRoute", "sell", "-uiProbe"])
            XCTAssertTrue(el(app, "debug.ledger").waitForExistence(timeout: 15))
            let stock = try server.stock(of: pid).qty
            wait("\(point)：本机库存 \(probe(app)["lastStock"] ?? "?") = 服务器 \(stock)") { probe(app)["lastStock"] == String(stock) && probe(app)["pending"] == "0" }
            app.terminate()
        }
    }

    /// 服务器已拒绝但响应丢失 → 重试拿到的仍是拒绝，本地标「没记上」，临时库存被纠正
    func test4RejectedReplay() throws {
        try XCTSkipIf(observer || !destructive)
        sellOffline(Self.demoBeer, extra: ["-uiInjectDemo"])
        crash(at: "beforeCommit")
        let app = syncedHome(["-uiRoute", "records"])
        XCTAssertTrue(el(app, "records.rejected").waitForExistence(timeout: 15), "07a 这笔标「没记上」")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "07a-rejected-live"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        let s = launch(["-uiRoute", "sell", "-uiProbe", "-uiScan", Self.demoBeer])
        XCTAssertTrue(el(s, "debug.ledger").waitForExistence(timeout: 15))
        wait("被拒的那笔不再扣库存（\(probe(s))）") { probe(s)["pending"] == "0" }
    }

    /// remap：本机离线登记的条码服务器上已被另一台登记 → remap；响应丢失后重试仍得到 remap，库存记在赢家上
    func test5RemapReplay() throws {
        try XCTSkipIf(observer || !destructive)
        let code = "69799" + String(Int(Date().timeIntervalSince1970) % 100_000_000).padding(toLength: 8, withPad: "0", startingAt: 0)
        let app = launch(["-uiOffline", "-uiRoute", "sell", "-uiScan", code])
        let name = app.textFields["newProduct.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap(); name.typeText("S22A 后到登记\n")
        el(app, "newProduct.price").tap()
        keys(app, "6")
        app.buttons["newProduct.save"].tap()
        XCTAssertTrue(app.buttons["sell.commit"].waitForExistence(timeout: 10))
        app.buttons["sell.commit"].tap()
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 10))
        app.terminate()
        // 另一台先登记了同一个码（赢家）
        let server = try Server.login(env)
        let winner = UUID().uuidString.lowercased()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let r = try server.sync([["id": UUID().uuidString.lowercased(), "type": "product_upsert", "occurred_at": iso.string(from: Date()),
                                  "payload": ["product_id": winner, "barcode": code, "name": "S22A 先到登记", "price_fen": 700,
                                              "quick": false, "base_unit": "个"]]])
        XCTAssertEqual((r["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")
        crash(at: "beforeCommit")
        syncedHome()
        XCTAssertEqual(try server.productId(barcode: code), winner, "条码归赢家")
        XCTAssertEqual(try server.sales(of: winner).count, 1, "本机那笔卖出记在赢家上，恰好一条")
        // 重启后本机扫这个码是赢家的名字（remap 改写了本机引用）
        let s = launch(["-uiRoute", "sell", "-uiScan", code])
        wait("本机扫码认出赢家") { s.staticTexts["S22A 先到登记"].exists }
    }

    /// 进货：原 6 包货值 ¥242.80，进 5 条 × ¥400 → 服务器平均进价 ¥40.05（cost.json 第一条），手机显示服务器的数
    func test6StockInAverage() throws {
        try XCTSkipIf(observer || !destructive)
        let server = try Server.login(env)
        let pid = try XCTUnwrap(server.productId(barcode: Self.zhCarton))
        let s0 = try server.stock(of: pid)
        try XCTSkipUnless(s0 == (6, 24280), "这个用例只在铺货后的起始状态跑（现在 \(s0)）")
        let app = launch(["-uiRoute", "stockIn", "-uiScan", Self.zhCarton])
        XCTAssertTrue(el(app, "stockIn.qty").waitForExistence(timeout: 20))
        keys(app, "5")
        el(app, "stockIn.cost").tap()
        keys(app, "400")
        XCTAssertTrue(el(app, "stockIn.average").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "stockIn.average").label.contains("40.05"), "预计平均进价按服务器的基线算：\(el(app, "stockIn.average").label)")
        app.buttons["stockIn.commit"].tap()
        app.terminate()
        syncedHome()
        let s1 = try server.stock(of: pid)
        XCTAssertEqual(s1.qty, 56)
        XCTAssertEqual(s1.value, 224_280)
        XCTAssertEqual((s1.value * 2 + s1.qty) / (s1.qty * 2), 4005, "服务器平均进价 ¥40.05（四舍五入整除）")
    }

    /// 第二台：停在 07a，另一台（另一个模拟器上的 test2）传上来的三笔 20 秒内出现在这里
    func testObserverSeesOtherPhone() throws {
        try XCTSkipUnless(observer)
        let server = try Server.login(env)
        let pid = try XCTUnwrap(server.productId(barcode: Self.beer))
        let app = syncedHome(["-uiRoute", "records"])
        let cards = app.descendants(matching: .any).matching(identifier: "records.amount")
        let n0 = cards.count
        let base = try server.sales(of: pid).count
        // 等服务器上出现那三笔（记下时刻），再看本机 07a
        var seenOnServer: Date?
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, seenOnServer == nil {
            if try server.sales(of: pid).count >= base + 3 { seenOnServer = Date() } else { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        }
        let t = try XCTUnwrap(seenOnServer, "另一台一直没传上来")
        wait("07a 出现另一台的三笔", timeout: 20) { cards.count >= n0 + 3 }
        print("S22A 第二台：服务器入账后 \(String(format: "%.1f", Date().timeIntervalSince(t))) 秒出现在 07a")
    }
}
