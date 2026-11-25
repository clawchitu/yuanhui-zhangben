import Foundation
import XCTest

/// S22d 联调（选商品图）：连本机服务端（图片开关开、本机目录对象存储、临时 Postgres），由 `scripts/s22d-live.sh` 建店、铺候选、起服务端。
/// 平时跳过。用例按名字顺序跑：
///   1. 全新登录 → 卖出页扫码 A → 查码带回两张 ready 候选 → 04a 存好 → 选第二张 → 同步确认登记后发 select →
///      服务器上这个商品 image_ver = 1，`GET /v1/images` 的字节和第二张候选缩图逐字节一致；同步拉回新版本
///   2. 扫码 B 选第二张时同步故意慢（`-uiSyncDelayMs`，登记还没传上去）→ 马上强杀 → 服务器上还没有 B →
///      正常重开 → 同步确认登记后补发 select → 服务器上 B 的 image_ver = 1（暂存跨重启）
/// 服务器上的事实由测试进程自己以另一台设备登录核对（拉商品、取图）。
@MainActor
final class S22dLiveUITests: XCTestCase {
    static let codeA = "6970000220011", codeB = "6970000220028"
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s22d-live.sh）")
        continueAfterFailure = false
    }

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

    // MARK: 服务器核对

    private struct Server {
        let base: String, token: String, epoch: String
        static func login(_ env: [String: String]) throws -> Server {
            let (d, _) = try call(env["YH_LIVE_BASE"]!, "POST", "/v1/auth/login",
                                  body: ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                         "device_id": UUID().uuidString.lowercased(), "label": "S22D 核对"])
            let r = try JSONSerialization.jsonObject(with: d) as! [String: Any]
            return Server(base: env["YH_LIVE_BASE"]!, token: r["token"] as! String, epoch: r["epoch"] as! String)
        }
        static func call(_ base: String, _ method: String, _ path: String, body: [String: Any]? = nil, token: String? = nil) throws -> (Data, Int) {
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
            return (out.0 ?? Data(), (out.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }
        /// 从头拉到底：商品 id → image_ver，条码 → 商品 id
        func catalog() throws -> (vers: [String: Int], codes: [String: String]) {
            var cur: [String: Any] = ["catalog": 0, "ledger": 0]
            var vers: [String: Int] = [:], codes: [String: String] = [:]
            for _ in 0..<50 {
                let (d, _) = try Self.call(base, "POST", "/v1/sync", body: ["epoch": epoch, "cursors": cur, "app_build": 1, "pull": true, "ops": []], token: token)
                let r = try JSONSerialization.jsonObject(with: d) as! [String: Any]
                let c = r["changes"] as! [String: Any]
                for p in c["products"] as! [[String: Any]] { vers[p["id"] as! String] = (p["image_ver"] as? NSNumber)?.intValue ?? 0 }
                for b in c["barcodes"] as! [[String: Any]] { codes[b["barcode"] as! String] = b["product_id"] as? String }
                cur = r["cursors"] as! [String: Any]
                let more = r["has_more"] as! [String: Bool]
                if !more["catalog"]! && !more["ledger"]! { break }
            }
            return (vers, codes)
        }
        func get(_ path: String) throws -> (Data, Int) { try Self.call(base, "GET", path, token: token) }
    }

    /// 卖出页扫这个码 → 04a 等查码填名称 → 填卖价 3.5 存好 → 第三步选第二张
    private func registerAndPickSecond(_ app: XCUIApplication, _ code: String) {
        let field = el(app, "newProduct.name")
        XCTAssertTrue(field.waitForExistence(timeout: 30), "进了 04a")
        wait("查码填上名称") { ((field.value as? String) ?? "").hasPrefix("E2E 选图测试") }
        for c in "35" { app.buttons[String(c)].firstMatch.tap() }
        app.buttons["newProduct.save"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 15), "出选图页")
        wait("两张候选") { el(app, "imageChoice.option.1").exists }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "s22d-live-pick-\(code)"; shot.lifetime = .keepAlways; add(shot)
        el(app, "imageChoice.option.1").tap()
        app.buttons["imageChoice.use"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 10), "回卖出页")
    }

    /// 服务器上这个码的商品：image_ver、图的字节是不是第二张候选
    private func check(_ server: Server, _ code: String) throws -> (ver: Int, matchesSecond: Bool) {
        let (vers, codes) = try server.catalog()
        guard let pid = codes[code] else { return (-1, false) }
        let ver = vers[pid] ?? 0
        guard ver > 0 else { return (ver, false) }
        let (c, _) = try server.get("/v1/barcode-lookup/\(code)/images")
        let ids = (try JSONSerialization.jsonObject(with: c) as? [String: Any])?["ids"] as? [String] ?? []
        guard ids.count == 2 else { return (ver, false) }
        let (second, s1) = try server.get("/v1/barcode-lookup/\(code)/images/\(ids[1])")
        let (img, s2) = try server.get("/v1/images/\(pid)?v=\(ver)")
        return (ver, s1 == 200 && s2 == 200 && second == img)
    }

    func test1PickOnline() throws {
        let app = launch(fresh: true)
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 15))
        let u = app.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
        let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        if el(app, "page.onboarding").waitForExistence(timeout: 60) { app.buttons["onboarding.done"].tap() }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        app.terminate()
        let server = try Server.login(env)
        let before = try check(server, Self.codeA)
        print("S22D 写前读 A：ver=\(before.ver)（-1 = 服务器上还没有这个商品）")
        XCTAssertEqual(before.ver, -1)
        let t0 = Date()
        let sell = launch(["-uiRoute", "sell", "-uiScan", Self.codeA, "-uiProbe"])
        registerAndPickSecond(sell, Self.codeA)
        var after = (ver: 0, matchesSecond: false)
        try wait("服务器上 A 换好图", timeout: 60) { after = try check(server, Self.codeA); return after.ver == 1 }
        print("S22D 写后读 A：ver=\(after.ver) 图和第二张候选逐字节一致=\(after.matchesSecond) 用时 \(Int(Date().timeIntervalSince(t0)))s")
        XCTAssertTrue(after.matchesSecond, "商品图就是选的第二张")
        sell.terminate()
    }

    func test2PickThenKillThenResend() throws {
        let server = try Server.login(env)
        XCTAssertEqual(try check(server, Self.codeB).ver, -1, "写前读：服务器上还没有 B")
        // 同步每个请求前先等 20 秒：登记传不上去，选完图马上强杀
        let app = launch(["-uiRoute", "sell", "-uiScan", Self.codeB, "-uiProbe", "-uiSyncDelayMs", "20000"])
        registerAndPickSecond(app, Self.codeB)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.terminate()
        let mid = try check(server, Self.codeB)
        print("S22D 强杀后读 B：ver=\(mid.ver)（-1 = 登记还没传上去）")
        XCTAssertEqual(mid.ver, -1, "强杀前登记没传上去")
        let t0 = Date()
        let again = launch()
        XCTAssertTrue(el(again, "page.home").waitForExistence(timeout: 30))
        var after = (ver: 0, matchesSecond: false)
        try wait("重开后补发，服务器上 B 换好图", timeout: 90) { after = try check(server, Self.codeB); return after.ver == 1 }
        print("S22D 重开后读 B：ver=\(after.ver) 图和第二张候选逐字节一致=\(after.matchesSecond) 用时 \(Int(Date().timeIntervalSince(t0)))s")
        XCTAssertTrue(after.matchesSecond)
        again.terminate()
    }
}
