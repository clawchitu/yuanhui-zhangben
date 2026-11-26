import Foundation
import XCTest

/// S24 联调（plan-v2 §8 S24 验收「对着 S07 的夹具服务器，页面上每个数字与接口一致，对账各行相加等于最后一行」）：
/// 一台模拟器跑 App，连本机服务端（临时 PG，`scripts/s24-seed.ts` 经 /v1/sync 铺了 S07 的设计稿 10 夹具）。平时跳过；由 `scripts/s24-live.sh` 跑：
///   TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD   本机服务器、测试店账号和密码（密码只从环境变量来）
/// App 这边走真实登录（输入框里打字、点按钮）、真同步、真取账；测试进程自己以另一台手机的身份调报表接口，逐个数字核对页面。
@MainActor
final class S24LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: String { env["YH_LIVE_BASE"]! }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s24-live.sh）")
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func log(_ s: String) { print("S24-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) throws -> [String: Any] {
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
        XCTAssertEqual((out.1 as? HTTPURLResponse)?.statusCode, 200, "\(path)")
        return (try JSONSerialization.jsonObject(with: out.0 ?? Data())) as? [String: Any] ?? [:]
    }

    private lazy var apiToken: String = {
        let r = try! call("POST", "/v1/auth/login", ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                                      "device_id": UUID().uuidString.lowercased(), "label": "S24 核对"])
        return r["token"] as! String
    }()

    private func report(_ path: String) throws -> [String: Any] { try call("GET", path, token: apiToken) }

    /// 登录（真输入）→ 首页 → 看账
    private func openReports(_ extra: [String] = []) -> XCUIApplication {
        if extra.contains("-uiOffline") { return reopenOffline() }
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
        el(app, "home.reports").tap()
        XCTAssertTrue(el(app, "page.reports").waitForExistence(timeout: 10))
        return app
    }

    // MARK: 核对

    private static func yuan(_ fen: Int64, cents: Bool) -> String {
        let a = fen.magnitude
        var whole = String(a / 100), groups: [String] = []
        while whole.count > 3 { groups.insert(String(whole.suffix(3)), at: 0); whole.removeLast(3) }
        groups.insert(whole, at: 0)
        return (fen < 0 ? "-" : "") + groups.joined(separator: ",") + (cents ? "." + String(format: "%02d", Int(a % 100)) : "")
    }
    private static func money(_ fen: Int64) -> String { "¥" + yuan(fen, cents: true) }
    private static func compact(_ fen: Int64) -> String { "¥" + yuan(fen, cents: fen % 100 != 0) }
    private static func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64.min }

    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        let win = app.windows.firstMatch.frame
        for _ in 0..<10 where !(e.exists && e.isHittable && win.contains(e.frame)) { app.swipeUp(velocity: .slow) }
    }

    private func figure(_ app: XCUIApplication, _ id: String, label: String, raw: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let e = el(app, id)
        XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) 存在", file: file, line: line)
        reveal(app, e)
        XCTAssertEqual(e.label, label, id, file: file, line: line)
        XCTAssertEqual(e.value as? String, String(raw), "\(id) 的原值", file: file, line: line)
        log("\(id) 页面「\(e.label)」= 接口 \(raw)")
    }

    private func checkToday(_ app: XCUIApplication, _ t: [String: Any]) {
        figure(app, "reports.sold", label: Self.money(Self.int(t["sold_fen"])), raw: Self.int(t["sold_fen"]))
        figure(app, "reports.profit", label: Self.money(Self.int(t["profit_fen"])), raw: Self.int(t["profit_fen"]))
        figure(app, "reports.records", label: "记了 \(Self.int(t["count"])) 笔", raw: Self.int(t["count"]))
        let discount = Self.int(t["discount_fen"])
        if discount == 0 { XCTAssertFalse(el(app, "reports.discount").exists, "没有优惠不显示优惠卡") }
        else { figure(app, "reports.discount", label: Self.money(discount), raw: discount) }
        let missing = Self.int(t["cost_missing_count"])
        XCTAssertEqual(el(app, "reports.costMissing").exists, missing > 0)
        if missing > 0 { XCTAssertTrue(el(app, "reports.costMissing").label.contains("有 \(missing) 样进价没填")) }
        for (i, it) in ((t["top_sellers"] as? [[String: Any]]) ?? []).enumerated() {
            figure(app, "reports.top.\(i)", label: "\(it["name"] as! String) \(Self.int(it["qty"]))", raw: Self.int(it["qty"]))
        }
        for (i, it) in ((t["low_stock"] as? [[String: Any]]) ?? []).prefix(5).enumerated() {
            let e = el(app, "reports.low.\(i)")
            reveal(app, e)
            XCTAssertTrue(e.label.contains(it["name"] as! String), e.label)
            XCTAssertEqual(e.value as? String, String(Self.int(it["qty"])))
            log("reports.low.\(i)「\(e.label)」")
        }
        for (i, it) in ((t["expiring"] as? [[String: Any]]) ?? []).prefix(2).enumerated() {
            let e = el(app, "reports.expiring.\(i)")
            reveal(app, e)
            XCTAssertTrue(e.label.contains(it["name"] as! String), e.label)
            XCTAssertEqual(e.value as? String, it["expiry_date"] as? String)
            log("reports.expiring.\(i)「\(e.label)」")
        }
    }

    private func checkMonth(_ app: XCUIApplication, _ m: [String: Any], current: Bool) {
        figure(app, "reports.sold", label: Self.money(Self.int(m["sold_fen"])), raw: Self.int(m["sold_fen"]))
        figure(app, "reports.profit", label: Self.compact(Self.int(m["profit_fen"])), raw: Self.int(m["profit_fen"]))
        let rec = m["reconciliation"] as! [String: Any]
        let rows = rec["rows"] as! [[String: Any]]
        let stockIn = rows.first { $0["key"] as? String == "stock_in" }.map { Self.int($0["amount_fen"]) } ?? 0
        figure(app, "reports.stockIn", label: Self.compact(stockIn), raw: stockIn)
        // 10 的店里货值取 stock_value_end_fen（§14 S07-4）
        figure(app, "reports.stockValue", label: Self.compact(Self.int(m["stock_value_end_fen"])), raw: Self.int(m["stock_value_end_fen"]))
        let discount = Self.int(m["discount_fen"])
        if discount == 0 { XCTAssertFalse(el(app, "reports.discount").exists) }
        else { figure(app, "reports.discount", label: Self.compact(discount), raw: discount) }
        figure(app, "reports.expireLoss", label: Self.compact(Self.int(m["expire_loss_fen"])), raw: Self.int(m["expire_loss_fen"]))
        // 对账：第一行 = 月初 + 进货，其余每行 = 接口那一行；各行相加 = 最后一行 = 接口的月末货值
        let start = Self.int(rec["stock_value_start_fen"])
        var expect = [start + stockIn]
        expect += rows.filter { $0["key"] as? String != "stock_in" }.map { Self.int($0["amount_fen"]) }
        var sum: Int64 = 0
        for (i, want) in expect.enumerated() {
            let e = el(app, "reports.recon.\(i)")
            reveal(app, e)
            XCTAssertEqual(e.value as? String, String(want), "对账第 \(i) 行")
            // 「减, 卖掉的货的进价, 17,997」，有没算进价的笔数时后面还跟一句「有 N 笔没算进价」
            let shown = Self.yuan(Int64(want.magnitude), cents: want % 100 != 0)
            XCTAssertTrue(e.label.hasSuffix(", \(shown)") || e.label.contains(", \(shown), 有 "), e.label)
            let missing = Self.int(i == 0 ? 0 : rows.filter { $0["key"] as? String != "stock_in" }[i - 1]["cost_missing_count"])
            XCTAssertEqual(e.label.contains("有 \(missing) 笔没算进价"), missing > 0, e.label)
            sum += Int64(e.value as? String ?? "") ?? 0
            log("reports.recon.\(i)「\(e.label)」= \(want)")
        }
        XCTAssertFalse(el(app, "reports.recon.\(expect.count)").exists)
        let end = el(app, "reports.recon.end")
        reveal(app, end)
        XCTAssertEqual(end.value as? String, String(Self.int(rec["stock_value_end_fen"])))
        XCTAssertEqual(sum, Self.int(rec["stock_value_end_fen"]), "对账各行相加等于最后一行")
        XCTAssertTrue(end.label.contains(current ? "现在店里货值" : "底店里货值"), end.label)
        log("reports.recon.end「\(end.label)」；各行相加 \(sum)")
    }

    // MARK: 用例

    /// 2026-11（S07 夹具那个月）：页面每个数 = 接口 = 设计稿 10（卖了 23,474、赚了 5,487、进货 15,920、货值 23,262、优惠 46、过期 58、
    /// 41,595 − 17,987 − 128 − 58 − 160 = 23,262）
    func testA_month202611MatchesDesignAndAPI() throws {
        let app = openReports(["-uiReportMonth", "2026-11", "-uiReportTab", "month"])
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 20))
        let m = try report("/v1/reports/month?month=2026-11")
        XCTAssertEqual(Self.int(m["sold_fen"]), 2_347_400)
        XCTAssertEqual(Self.int(m["stock_value_end_fen"]), 2_326_200)
        shot(app, "live-10")
        // 指定了月份（-uiReportMonth）就是「11月底店里货值」，不说「现在」
        checkMonth(app, m, current: false)
        figure(app, "reports.sold", label: "¥23,474.00", raw: 2_347_400)
        figure(app, "reports.stockValue", label: "¥23,262", raw: 2_326_200)
        for (i, label) in ["41,595", "17,987", "128", "58", "160"].enumerated() {
            XCTAssertTrue(el(app, "reports.recon.\(i)").label.hasSuffix(", \(label)"))
        }
        shot(app, "live-10-bottom")
    }

    /// 记了今天的几笔以后：今天（服务器的今天）和本月两页，每个数都和接口一致；红牛卖超了显示「没货了」，双汇「还剩 3 根」（单位查本机）
    func testB_todayAndThisMonthMatchAPI() throws {
        let app = openReports()
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 20))
        let t = try report("/v1/reports/today")
        log("接口 今天：\(t)")
        XCTAssertGreaterThan(Self.int(t["count"]), 0)
        checkToday(app, t)
        let low = ((t["low_stock"] as? [[String: Any]]) ?? []).map { $0["name"] as! String }
        let rb = el(app, "reports.low.\(low.firstIndex(of: "S24 红牛 250ml") ?? 99)")
        reveal(app, rb)
        XCTAssertTrue(rb.label.contains("没货了"), rb.label)
        // 双汇是今天在服务器上期初的，手机同步完才知道单位：等同步把商品拉下来，下拉重取一次
        let sh = el(app, "reports.low.\(low.firstIndex(of: "S24 双汇王中王 60g") ?? 99)")
        reveal(app, sh)
        if !sh.label.contains("还剩 3 根") {
            RunLoop.current.run(until: Date().addingTimeInterval(5))
            for _ in 0..<6 { app.swipeDown() }
            el(app, "reports.tab.month").tap()
            XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 20))
            el(app, "reports.tab.today").tap()
            XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 20))
            reveal(app, sh)
        }
        XCTAssertTrue(sh.label.contains("还剩 3 根"), sh.label)
        shot(app, "live-09")
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 20))
        let m = try report("/v1/reports/month")
        log("接口 本月：\(m["month"] ?? "")")
        checkMonth(app, m, current: true)
        shot(app, "live-10-now")
    }

    /// 已经登录过（testB 留下的会话），重开时当作没网（Debug `-uiOffline`：同步那边一开始就知道没网）
    private func reopenOffline() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "on", "-uiOffline"]
        app.launch()
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30), "testB 留下的会话还在")
        el(app, "home.reports").tap()
        XCTAssertTrue(el(app, "page.reports").waitForExistence(timeout: 10))
        return app
    }

    /// 服务器开着、账也有，但手机没网：只显示「要联网才能看账」，换栏、再试都一样，一个旧数都不出（真实的「没网」输入：同步协调器）
    func testC_offlineShowsNeedNetworkNotNumbers() throws {
        let app = openReports(["-uiOffline"])
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "reports.sold").exists)
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "reports.stockValue").exists)
        el(app, "reports.tab.today").tap()
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "reports.sold").exists)
        shot(app, "live-offline")
        el(app, "reports.records").tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 10), "记的账在本机，没网也进得去")
        log("没网：看账只显示「要联网才能看账」，记的账进得去")
    }
}
