import Foundation
import XCTest

/// S27 联调（plan-v2 §8 S27 验收）：一台模拟器跑 App，连本机服务端（临时 PG，`scripts/s27-seed.ts` 经 /v1/sync 铺了四样管保质期的货）。
/// 平时跳过；由 `scripts/s27-live.sh` 跑：TEST_RUNNER_YH_LIVE_BASE / _USER / _PASSWORD。
/// App 走真实登录、真同步；测试进程自己以另一台手机的身份调接口：核对 09「快过期了」、月报，并在 testB 里抢先处理同一批。
///   testA：首页黄条 = 服务器 09 的快过期样数（3）；19 的三段和服务器一致；扔掉已过期的那批 → 月报过期损耗 + ¥19.60、赚了不变、黄条 3 → 2
///   testB：手机打开处理面板后，另一台手机先把同一批「过几天再提醒」→ 手机再处理被拒 stale → 「这批已经处理过了」，清单按最新的列
@MainActor
final class S27LiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: String { env["YH_LIVE_BASE"]! }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_LIVE_BASE"] == nil, "只在手工联调时跑（scripts/s27-live.sh）")
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func log(_ s: String) { print("S27-LIVE \(ISO8601DateFormatter().string(from: Date())) \(s)") }

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
                                                      "device_id": UUID().uuidString.lowercased(), "label": "S27 核对"])
        return (r["token"] as! String, r["epoch"] as! String)
    }()

    private func report(_ path: String) throws -> [String: Any] { try call("GET", path, token: other.token) }
    private static func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64.min }

    /// 登录（真输入）→ 首页，等首次同步把批次拉下来（黄条出来）
    private func login() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiAPIBase", base, "-uiLargeText", "off", "-uiFreshInstall", "-uiResetStoredAPIBase"]
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
        XCTAssertTrue(el(app, "home.banner.expiring").waitForExistence(timeout: 30), "首次同步后黄条出来")
        return app
    }

    /// 等首页黄条变成这句（同步之后才变）
    private func waitBanner(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !el(app, "home.banner.expiring").label.contains(text) { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertTrue(el(app, "home.banner.expiring").label.contains(text), el(app, "home.banner.expiring").label)
    }

    func testA_listMatchesServerAndDiscardBooksLoss() throws {
        let app = login()
        // 首页黄条 = 服务器 09「快过期了」的样数（按商品合并）
        let t = try report("/v1/reports/today")
        let expiring = (t["expiring"] as? [[String: Any]]) ?? []
        XCTAssertEqual(expiring.map { $0["name"] as? String ?? "" }, ["S27 光明鲜牛奶", "S27 桃李面包", "S27 伊利纯牛奶"])
        waitBanner(app, "有 \(expiring.count) 样快过期了")
        log("首页黄条「\(el(app, "home.banner.expiring").label)」= 服务器 09 快过期 \(expiring.count) 样")
        shot(app, "live-01")
        // 09 的「快过期了」：真数据（共 3 样，前两样的名字和服务器一致）
        el(app, "home.reports").tap()
        XCTAssertTrue(el(app, "reports.expiring.header").waitForExistence(timeout: 20))
        XCTAssertTrue(el(app, "reports.expiring.header").label.contains("共 3 样"), el(app, "reports.expiring.header").label)
        XCTAssertTrue(el(app, "reports.expiring.0").label.contains("S27 光明鲜牛奶"))
        log("09 快过期「\(el(app, "reports.expiring.header").label)」")
        app.buttons["返回"].firstMatch.tap()
        // 19
        el(app, "home.banner.expiring").tap()
        XCTAssertTrue(el(app, "page.expiry").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "expiry.expired.header").label, "已过期, 1 样")
        XCTAssertEqual(el(app, "expiry.soon.header").label, "快过期, 2 样")
        XCTAssertTrue(el(app, "expiry.expired.0").label.contains("S27 光明鲜牛奶") && el(app, "expiry.expired.0").label.contains("过了 2 天 · 账上约 2 盒"))
        XCTAssertTrue(el(app, "expiry.soon.0").label.contains("S27 桃李面包"))
        XCTAssertTrue(el(app, "expiry.soon.1").label.contains("S27 伊利纯牛奶"))
        XCTAssertFalse(el(app, "expiry.soon.2").exists, "可乐还早，不提醒")
        shot(app, "live-19")
        // 扔掉之前的月报
        let m0 = try report("/v1/reports/month")
        let loss0 = Self.int(m0["expire_loss_fen"]), profit0 = Self.int(m0["profit_fen"])
        XCTAssertEqual(profit0, 100, "铺的那罐可乐赚 ¥1.00")
        log("扔掉前：月报过期损耗 \(loss0) 分、赚了 \(profit0) 分")
        el(app, "expiry.expired.0.handle").tap()
        XCTAssertTrue(el(app, "expiry.choice.discard").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "expiry.choice.discard").value as? String, "突出")
        XCTAssertTrue(el(app, "expiry.choice.discard").label.contains("算亏 ¥19.60"))
        shot(app, "live-20")
        el(app, "expiry.choice.discard").tap()
        XCTAssertTrue(el(app, "expiry.panel.title").waitForNonExistence(timeout: 5))
        XCTAssertFalse(el(app, "expiry.expired.header").exists)
        // 传上去以后：月报过期损耗 + 1960（2 盒 × ¥9.80），赚了不变
        var m1: [String: Any] = [:]
        let end = Date().addingTimeInterval(40)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            m1 = try report("/v1/reports/month")
        } while Date() < end && Self.int(m1["expire_loss_fen"]) == loss0
        XCTAssertEqual(Self.int(m1["expire_loss_fen"]), loss0 + 1960, "月报过期损耗增加 ¥19.60")
        XCTAssertEqual(Self.int(m1["profit_fen"]), profit0, "赚了不变")
        log("扔掉后：月报过期损耗 \(Self.int(m1["expire_loss_fen"])) 分（+1960）、赚了 \(Self.int(m1["profit_fen"])) 分（不变）")
        let t1 = try report("/v1/reports/today")
        XCTAssertEqual(((t1["expiring"] as? [[String: Any]]) ?? []).count, 2, "服务器 09 也少一样")
        app.buttons["返回"].firstMatch.tap()
        waitBanner(app, "有 2 样快过期了")
        log("首页黄条「\(el(app, "home.banner.expiring").label)」（3 → 2）")
        shot(app, "live-01-after")
    }

    func testB_otherPhoneHandledFirstShowsNotice() throws {
        let app = login()
        el(app, "home.banner.expiring").tap()
        XCTAssertTrue(el(app, "page.expiry").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "expiry.soon.0").label.contains("S27 桃李面包"))
        el(app, "expiry.soon.0.handle").tap()
        XCTAssertTrue(el(app, "expiry.choice.discard").waitForExistence(timeout: 5))
        // 面板开着时，另一台手机先把这批「过几天再提醒」（实际数 1）
        var cursors: [String: Any] = ["catalog": 0, "ledger": 0]
        var products: [[String: Any]] = [], lots: [[String: Any]] = []
        for _ in 0..<50 {
            let r = try call("POST", "/v1/sync", ["epoch": other.epoch, "cursors": cursors, "app_build": 1, "pull": true, "ops": []], token: other.token)
            let ch = r["changes"] as? [String: Any] ?? [:]
            products += ch["products"] as? [[String: Any]] ?? []
            lots += ch["lots"] as? [[String: Any]] ?? []
            cursors = r["cursors"] as? [String: Any] ?? cursors
            let more = r["has_more"] as? [String: Bool] ?? [:]
            if !(more["catalog"] ?? false) && !(more["ledger"] ?? false) { break }
        }
        let productId = try XCTUnwrap(products.first { $0["name"] as? String == "S27 桃李面包" }?["id"] as? String)
        let target = try XCTUnwrap(lots.last { $0["product_id"] as? String == productId && $0["closed_at"] is NSNull }, "找到桃李那批")
        let snooze: [String: Any] = ["id": UUID().uuidString.lowercased(), "type": "lot_snooze",
                                     "occurred_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30)),
                                     "payload": ["lot_id": target["id"]!, "handle_ver": target["handle_ver"]!, "actual_qty": 1, "days": 3]]
        let r = try call("POST", "/v1/sync", ["epoch": other.epoch, "cursors": ["catalog": 0, "ledger": 0], "app_build": 1, "pull": false,
                                              "ops": [snooze]], token: other.token)
        XCTAssertEqual((r["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")
        log("另一台手机先处理了桃李那批（再提醒，handle_ver \(target["handle_ver"]!) → +1）")
        let m0 = try report("/v1/reports/month")
        // 手机这边再处理：扔掉 → 传上去被拒 stale
        el(app, "expiry.choice.discard").tap()
        let notice = el(app, "expiry.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 40), "出现「这批已经处理过了」")
        XCTAssertTrue(notice.label.contains("这批已经处理过了"), notice.label)
        log("手机提示「\(notice.label)」")
        // 刷新：桃李按服务器最新的列在「过几天再提醒的」
        let z = el(app, "expiry.snoozed.0")
        XCTAssertTrue(z.waitForExistence(timeout: 10))
        XCTAssertTrue(z.label.contains("S27 桃李面包"), z.label)
        shot(app, "live-stale")
        let m1 = try report("/v1/reports/month")
        XCTAssertEqual(Self.int(m1["expire_loss_fen"]), Self.int(m0["expire_loss_fen"]), "被拒的扔掉没记账")
        log("被拒后月报过期损耗不变：\(Self.int(m1["expire_loss_fen"])) 分")
    }
}
