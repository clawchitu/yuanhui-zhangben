import Foundation
import XCTest

/// S25 联调（plan-v2 §8 S25 验收）：一台模拟器跑 App，连本机服务端（临时 PG；`scripts/s25-seed.ts` 以另一台手机 B 的身份铺了商品，
/// B 随后「断网」）。平时跳过；由 `scripts/s25-live.sh` 跑：
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   本机服务器、测试店账号和密码（密码只从环境变量来）
/// App 走真实登录、真同步、真交补全；测试进程以第三台手机的身份调 /v1/reports/today 核对 11 的「快没货 / 快过期」数。
/// B 再联网后拿到的新价、整箱码价不变、旧流水原名原价、服务器上的 opening，由 `s25-seed.ts --check` 核对（脚本里跑）。
@MainActor
final class S25LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: String { env["YH_LIVE_BASE"]! }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s25-live.sh）")
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func log(_ s: String) { print("S25-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

    private func call(_ path: String, _ body: [String: Any]? = nil, token: String? = nil) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = body == nil ? "GET" : "POST"
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw e }
        XCTAssertEqual((out.1 as? HTTPURLResponse)?.statusCode, 200, path)
        return (try JSONSerialization.jsonObject(with: out.0 ?? Data())) as? [String: Any] ?? [:]
    }

    private func reportToday() throws -> [String: Any] {
        let t = try call("/v1/auth/login", ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                             "device_id": UUID().uuidString.lowercased(), "label": "S25 核对"])["token"] as! String
        return try call("/v1/reports/today", token: t)
    }

    private func login(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "on", "-uiFreshInstall", "-uiResetStoredAPIBase"] + extra
        app.launch()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20))
        let u = app.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
        let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
        app.buttons["login.submit"].tap()
        let end = Date().addingTimeInterval(60)
        while Date() < end, !el(app, "page.home").exists {
            if el(app, "page.onboarding").exists, el(app, "onboarding.done").exists { el(app, "onboarding.done").tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        return app
    }

    private func waitLabel(_ e: XCUIElement, _ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !(e.exists && e.label == label) { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertEqual(e.label, label, file: file, line: line)
    }

    private func row(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'products.row.' AND label CONTAINS %@", name)).firstMatch
    }

    private func editRow(_ app: XCUIApplication, name: String) {
        let q = el(app, "products.search")
        q.tap()
        if let cur = q.value as? String, !cur.isEmpty, cur != "搜名称，或者扫条码" { el(app, "products.search.clear").tap(); q.tap() }
        q.typeText(name)
        let edit = app.buttons.matching(NSPredicate(format: "label == %@", "改 \(name)")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), name)
        edit.tap()
    }

    private func typeYuan(_ app: XCUIApplication, _ id: String, _ text: String, clear: Bool = false) {
        let f = app.textFields[id]
        f.tap()
        f.typeText((clear ? String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) : "") + text)
    }

    func testA_listEditReviewArchive() throws {
        let app = login(["-uiReviewStaleOnce"])
        el(app, "home.products").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 10))
        // 11 的数：快没货、快过期和 09 的接口同一条件（§14 S07-6），待确认 2 样（收银员式临时登记 + 卖出时自动建的）
        let today = try reportToday()
        let low = (today["low_stock"] as? [Any])?.count ?? -1, exp = (today["expiring"] as? [Any])?.count ?? -1
        log("接口：快没货 \(low) 样、快过期 \(exp) 样")
        XCTAssertEqual(low, 1); XCTAssertEqual(exp, 1)
        waitLabel(el(app, "products.chip.lowStock"), "快没货 \(low)")
        waitLabel(el(app, "products.chip.expiring"), "快过期 \(exp)")
        waitLabel(el(app, "products.chip.needsReview"), "待确认 2")
        waitLabel(el(app, "products.chip.all"), "全部 5")
        shot(app, "11-live")
        log("11：\(el(app, "products.chip.all").label)、\(el(app, "products.chip.lowStock").label)、\(el(app, "products.chip.expiring").label)、\(el(app, "products.chip.needsReview").label)")

        // 22：改卖价 6.00 → 6.50
        editRow(app, name: "S25 青岛啤酒 500ml")
        XCTAssertTrue(el(app, "page.productEdit").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "edit.averageCost").label, "平均进价 4.20 元")
        typeYuan(app, "edit.price", "6.5", clear: true)
        el(app, "edit.keyboardDone").tap()
        el(app, "edit.save").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 10))
        log("22：青岛改成 6.50")

        // 22b：收银员登记的白象，进价 3.2、货架上 8 袋；第一次故意带旧版本 → 服务器回 stale → 面板「账上现在是 …」→ 对，就是
        editRow(app, name: "S25 白象 老母鸡汤面")
        XCTAssertTrue(el(app, "page.productReview").waitForExistence(timeout: 10))
        typeYuan(app, "review.cost", "3.2")
        el(app, "review.keyboardDone").tap()
        let counted = el(app, "review.counted")
        // 步进器整体是一个可调元素：点右边的加号 8 下
        for _ in 0..<8 { counted.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(counted.value as? String, "8")
        el(app, "review.save").tap()
        XCTAssertTrue(el(app, "confirm.sheet").waitForExistence(timeout: 20), "真服务器回 stale")
        log("22b stale：\(el(app, "confirm.title").label)")
        shot(app, "22b-stale-live")
        el(app, "review.stale.ok").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 20))
        waitLabel(el(app, "products.chip.needsReview"), "待确认 1")

        // 22b：卖出时自动建的（卖价 0、没条码）：先填卖价、挂单件码，再补全
        el(app, "products.chip.needsReview").tap()
        el(app, "products.search.clear").tap()
        let auto = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '改 '")).firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        auto.tap()
        XCTAssertTrue(el(app, "page.productReview").waitForExistence(timeout: 10))
        typeYuan(app, "review.price", "4.5")
        typeYuan(app, "review.cost", "3")
        let code = app.textFields["review.barcode"]; code.tap(); code.typeText("6970000250041")
        el(app, "review.keyboardDone").tap()
        el(app, "review.save").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 20))
        waitLabel(el(app, "products.chip.needsReview"), "待确认 0")
        log("22b：两样都补全了，待确认 0")

        // 22：不卖了（先确认）
        el(app, "products.chip.all").tap()
        editRow(app, name: "S25 红牛 250ml")
        XCTAssertTrue(el(app, "page.productEdit").waitForExistence(timeout: 10))
        let archive = el(app, "edit.archive")
        for _ in 0..<6 where !archive.isHittable { app.swipeUp() }
        archive.tap()
        XCTAssertTrue(el(app, "edit.archive.ok").waitForExistence(timeout: 5))
        el(app, "edit.archive.ok").tap()
        XCTAssertTrue(el(app, "page.products").waitForExistence(timeout: 10))
        // 等本机的账全传上去（顶栏「已同步」）
        let end = Date().addingTimeInterval(40)
        while Date() < end, !app.staticTexts["已同步"].exists { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertTrue(app.staticTexts["已同步"].exists, "改价、停用都传上去了")
        log("22：红牛停用；已同步")
    }

    /// 扫任一单件码用新价、整箱码价不变；扫到停用的照卖并提示已停用（重开 App，已登录，假扫码喂三个码）
    func testB_scanUsesNewPrice() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "on", "-uiRoute", "sell",
                               "-uiScan", "6970000250002,6970000250001,6970000250003", "-uiScanDelay", "3"]
        app.launch()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 20))
        let total = el(app, "sell.total")
        let end = Date().addingTimeInterval(30)
        while Date() < end, !(total.exists && total.label.contains("145.00")) { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        log("卖出页：两个单件码 + 整箱码合计 \(total.label)（6.50 + 6.50 + 132.00）")
        XCTAssertTrue(total.label.contains("145.00"), total.label)
        shot(app, "sell-new-price")
        app.terminate()
        let app2 = XCUIApplication()
        app2.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "on", "-uiRoute", "sell", "-uiScan", "6970000250011", "-uiScanDelay", "3"]
        app2.launch()
        let off = app2.staticTexts.matching(NSPredicate(format: "label CONTAINS '已停用'")).firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 20), "停用的照卖，标已停用")
        log("扫停用的红牛：\(off.label)")
    }
}
