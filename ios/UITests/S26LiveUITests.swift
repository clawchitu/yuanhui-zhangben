import Foundation
import XCTest

/// S26 联调（plan-v2 §8 S26 验收）：一台模拟器跑 App，连本机服务端（临时 PG，`scripts/s26-seed.ts` 以另一台手机的身份铺了
/// S26 红牛 3 罐、S26 可乐 5 罐、S26 面包 4 袋）。平时跳过；由 `scripts/s26-live.sh` 跑：TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD。
/// App 走真实登录、真同步；测试进程自己以另一台手机的身份调 /v1/sync：核对服务器上的库存和流水，testB 里在盘点时卖出。
///   testA：没网 →「要联网才能盘点」、服务器没收到盘点；离线卖 1 罐红牛（留在 outbox，服务器还是 3）→ 联网进盘点：先传完卖出，
///          账上 2 → 数 1 → 服务器记盘亏 1（count qty -1），卖出流水在盘点之前、盘点的账面是 2
///   testB：盘点可乐时另一台手机卖了 1 罐 →「账上现在是 4 罐，你数的还对吗」→ 确认 → 服务器盘盈 1、库存 5；
///          `-uiCountStaleOnce` 让真服务器回 stale → 同样的问句 → 确认后记上；12b 列出面包（账上 4 袋），面包一直没扫，服务器上不变
@MainActor
final class S26LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: String { env["YH_LIVE_BASE"]! }
    static let redBull = "6970000260001", cola = "6970000260002"

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s26-live.sh）")
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func log(_ s: String) { print("S26-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

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

    /// 另一台手机（测试进程）的登录：令牌 + epoch
    private lazy var other: (token: String, epoch: String) = {
        let r = try! call("POST", "/v1/auth/login", ["username": env["YH_LIVE_USER"]!, "password": env["YH_LIVE_PASSWORD"]!,
                                                      "device_id": UUID().uuidString.lowercased(), "label": "S26 另一台手机"])
        return (r["token"] as! String, r["epoch"] as! String)
    }()

    private static func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64.min }

    /// 服务器上现在的商品（按名称）和全部流水（另一台手机从头拉一遍）
    private func server() throws -> (products: [String: [String: Any]], entries: [[String: Any]]) {
        var cursors: [String: Any] = ["catalog": 0, "ledger": 0]
        var products: [String: [String: Any]] = [:], entries: [[String: Any]] = []
        for _ in 0..<50 {
            let r = try call("POST", "/v1/sync", ["epoch": other.epoch, "cursors": cursors, "app_build": 1, "pull": true, "ops": []],
                             token: other.token)
            let ch = r["changes"] as? [String: Any] ?? [:]
            for p in ch["products"] as? [[String: Any]] ?? [] { products[p["name"] as? String ?? ""] = p }
            entries += ch["entries"] as? [[String: Any]] ?? []
            cursors = r["cursors"] as? [String: Any] ?? cursors
            let more = r["has_more"] as? [String: Bool] ?? [:]
            if !(more["catalog"] ?? false) && !(more["ledger"] ?? false) { break }
        }
        return (products, entries)
    }

    private func stock(_ p: [String: Any]?) -> (qty: Int64, ver: Int64) {
        let v = p?["private"] as? [String: Any]
        return (Self.int(v?["stock_qty"]), Self.int(v?["stock_ver"]))
    }

    private func counts(_ entries: [[String: Any]], _ productId: Any?) -> [[String: Any]] {
        entries.filter { $0["type"] as? String == "count" && $0["product_id"] as? String == productId as? String }
    }

    /// 起 App（已登录就直接进；没登录先真输入登录）
    private func launch(_ extra: [String], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "off"] + (fresh ? ["-uiFreshInstall", "-uiResetStoredAPIBase"] : []) + extra
        app.launch()
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            if el(app, "page.login").exists {
                let u = app.textFields["login.username"]; u.tap(); u.typeText(env["YH_LIVE_USER"]!)
                let p = app.secureTextFields["login.password"]; p.tap(); p.typeText(env["YH_LIVE_PASSWORD"]!)
                app.buttons["login.submit"].tap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                continue
            }
            if el(app, "page.onboarding").exists, el(app, "onboarding.done").exists { el(app, "onboarding.done").tap() }
            if el(app, "page.home").exists || el(app, "page.count").exists || el(app, "page.sell").exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return app
    }

    private func press(_ app: XCUIApplication, _ digits: String) {
        for d in digits { el(app, "page.count").buttons[String(d)].tap() }
    }

    private func waitLabel(_ e: XCUIElement, contains s: String, timeout: TimeInterval = 30) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !(e.exists && e.label.contains(s)) { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertTrue(e.exists && e.label.contains(s), "\(e.exists ? e.label : "不存在") 不含 \(s)")
    }

    func testA_offlineThenDrainOutboxThenCountLoss() throws {
        // 0. 真登录，首次同步拉完
        var app = launch([], fresh: true)
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["已同步"].waitForExistence(timeout: 40))
        app.terminate()
        // 1. 没网：要联网才能盘点，不让数
        app = launch(["-uiOffline", "-uiRoute", "count", "-uiScan", Self.redBull, "-uiScanDelay", "3"])
        XCTAssertTrue(el(app, "count.offline").waitForExistence(timeout: 30))
        XCTAssertEqual(el(app, "count.offline").label, "要联网才能盘点")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(el(app, "count.card").exists, "没网不出商品卡")
        shot(app, "live-offline")
        log("没网：页面「\(el(app, "count.offline").label)」，扫码不出商品卡")
        app.terminate()
        // 2. 还是没网：卖 1 罐红牛，留在本机 outbox
        app = launch(["-uiOffline", "-uiRoute", "sell", "-uiScan", Self.redBull, "-uiScanDelay", "3", "-uiAutoCommit"])
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 30))
        let status = el(app, "syncStatus")
        waitLabel(status, contains: "1 笔待传")
        log("离线卖 1 罐红牛：顶栏「\(status.label)」")
        var s = try server()
        let red = s.products["S26 红牛"]
        XCTAssertEqual(stock(red).qty, 3, "卖出还没传上去，服务器上还是 3")
        XCTAssertTrue(counts(s.entries, red?["id"]).isEmpty, "没网时服务器没收到盘点")
        app.terminate()
        // 3. 联网进盘点：先传完卖出、拉到底 → 账上 2 → 数 1 → 存
        app = launch(["-uiRoute", "count", "-uiScan", Self.redBull, "-uiScanDelay", "3"])
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 40))
        XCTAssertEqual(el(app, "count.book").label, "2", "先传完本机的卖出，账上是 2")
        press(app, "1")
        XCTAssertTrue(el(app, "count.hint").label.contains("比账上少 1 罐"))
        shot(app, "live-12a")
        el(app, "count.save").tap()
        waitLabel(el(app, "count.notice"), contains: "「S26 红牛」存好了")
        waitLabel(el(app, "count.done"), contains: "已经数了 1 种")
        log("手机：红牛账上 2、数 1、存好；进度「\(el(app, "count.done").label) / \(el(app, "count.left").label)」")
        // 服务器：卖出在前、盘点在后；盘亏 1，库存 1
        s = try server()
        XCTAssertEqual(stock(s.products["S26 红牛"]).qty, 1)
        let redId = s.products["S26 红牛"]?["id"]
        let c = counts(s.entries, redId)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Self.int(c.first?["qty_delta"]), -1, "服务器记盘亏 1 个")
        XCTAssertEqual(Self.int(c.first?["value_delta_fen"]), -400, "盘亏 1 罐按进价 ¥4.00")
        let sale = s.entries.first { $0["type"] as? String == "sale" && $0["product_id"] as? String == redId as? String }
        XCTAssertNotNil(sale, "离线那笔卖出传上去了")
        XCTAssertLessThan(Self.int(sale?["seq"]), Self.int(c.first?["seq"]), "卖出先入账（提交前先传完本机 outbox）")
        log("服务器：红牛库存 1；卖出 seq \(Self.int(sale?["seq"])) < 盘点 seq \(Self.int(c.first?["seq"]))，盘点 qty -1、value -400")
    }

    func testB_otherPhoneSoldAsksAndConfirm() throws {
        let before = try server()
        let bread0 = stock(before.products["S26 面包"])
        let colaId = try XCTUnwrap(before.products["S26 可乐"]?["id"] as? String)
        // 1. 开始数可乐：账上 5
        var app = launch(["-uiRoute", "count", "-uiScan", Self.cola, "-uiScanDelay", "3"])
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 40))
        XCTAssertEqual(el(app, "count.book").label, "5")
        press(app, "5")
        // 2. 这期间另一台手机卖了 1 罐可乐
        let sale: [String: Any] = ["id": UUID().uuidString.lowercased(), "type": "sale_batch",
                                   "occurred_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)),
                                   "payload": ["batch_id": UUID().uuidString.lowercased(), "paid_total_fen": 300,
                                               "lines": [["entry_id": UUID().uuidString.lowercased(), "product_id": colaId, "barcode": Self.cola,
                                                          "name": "S26 可乐", "unit_name": "罐", "pack_qty": 1, "pack_count": 1, "unit_price_fen": 300]]]]
        let r = try call("POST", "/v1/sync", ["epoch": other.epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": false,
                                              "ops": [sale]], token: other.token)
        XCTAssertEqual((r["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")
        log("另一台手机卖了 1 罐可乐（服务器 5 → 4）")
        // 3. 存 →「账上现在是 4 罐，你数的还对吗」→ 对
        el(app, "count.save").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        XCTAssertEqual(alert.label, "账上现在是 4 罐，你数的还对吗")
        shot(app, "live-stale")
        log("手机提示「\(alert.label)」")
        alert.buttons["对，就是 5 罐"].tap()
        waitLabel(el(app, "count.notice"), contains: "「S26 可乐」存好了")
        var s = try server()
        XCTAssertEqual(stock(s.products["S26 可乐"]).qty, 5, "按数的算：库存 5")
        let cc = counts(s.entries, colaId)
        XCTAssertEqual(cc.count, 1)
        XCTAssertEqual(Self.int(cc.first?["qty_delta"]), 1, "盘盈 1（账上 4、数 5）")
        log("服务器：可乐库存 5，盘点 qty +1")
        app.terminate()
        // 4. 交上去被真服务器拒 stale（-uiCountStaleOnce 第一次带旧一版）→ 同样问 → 确认后记上（红牛账上 1，「没错」）
        app = launch(["-uiRoute", "count", "-uiScan", Self.redBull, "-uiScanDelay", "3", "-uiCountStaleOnce"])
        XCTAssertTrue(el(app, "count.card").waitForExistence(timeout: 40))
        XCTAssertEqual(el(app, "count.book").label, "1")
        el(app, "count.same").tap()
        let alert2 = app.alerts.firstMatch
        XCTAssertTrue(alert2.waitForExistence(timeout: 30))
        XCTAssertEqual(alert2.label, "账上现在是 1 罐，你数的还对吗")
        log("服务器回 stale：手机提示「\(alert2.label)」")
        alert2.buttons["对，就是 1 罐"].tap()
        waitLabel(el(app, "count.notice"), contains: "「S26 红牛」存好了")
        // 5. 12b：还没数的只剩面包（账上 4 袋）
        XCTAssertTrue(el(app, "count.empty").waitForExistence(timeout: 10))
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.countList").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "countList.title").label, "还有 1 种没数")
        XCTAssertTrue(el(app, "countList.0").label.contains("S26 面包") && el(app, "countList.0").label.contains("账上 4 袋"))
        shot(app, "live-12b")
        el(app, "countList.finish").tap()
        XCTAssertTrue(el(app, "page.count").waitForNonExistence(timeout: 10))
        // 6. 没扫的面包：服务器上数量、版本都没变，没有盘点流水
        s = try server()
        let bread = s.products["S26 面包"]
        XCTAssertEqual(stock(bread).qty, bread0.qty)
        XCTAssertEqual(stock(bread).ver, bread0.ver, "没扫的商品不变")
        XCTAssertTrue(counts(s.entries, bread?["id"]).isEmpty)
        let redCounts = counts(s.entries, s.products["S26 红牛"]?["id"])
        XCTAssertEqual(redCounts.count, 2, "红牛又记了一条 d = 0 的盘点")
        XCTAssertEqual(Self.int(redCounts.last?["qty_delta"]), 0)
        log("服务器：面包 \(stock(bread).qty) 袋 stock_ver \(stock(bread).ver)（和开始时一样）；红牛第二条盘点 qty 0")
    }
}
