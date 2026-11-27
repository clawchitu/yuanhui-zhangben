import Foundation
import XCTest

/// S31 验收「Release 包连域名走通 S28 剧本的精简版」（plan-v2 §8 S31、§9.3 第 3–4 步）。
/// 只在 `scripts/s31-release-live.sh` 里跑：Release 配置构建的 App（scheme `YuanhuiZhangben-ReleaseCheck`），没有任何测试夹具，
/// 包内默认地址就是 `https://api.yuanhuishop.cn`，全程只点界面：
///   全新安装 → 账号密码登录 → 首次同步 → 起名 → 进货（手输条码）→ 卖两样（手输条码）→ 撤掉其中一行 → 看账（本月）。
/// 测试进程自己以另一台设备登录同一个域名核对服务器：进货、卖出、冲销各恰好一条，库存变化对，月报对账成立、
/// 月报期末货值等于各商品货值之和，看账页上的「卖了」和服务器月报逐分一致。
///   TEST_RUNNER_YH_S31_USER / TEST_RUNNER_YH_S31_PASSWORD   线上测试店的账号和密码（运行时从钥匙串读，不写文件）
///   TEST_RUNNER_YH_S31_BASE                                 核对用的服务器地址，默认 https://api.yuanhuishop.cn（旧 Beta 模式默认 IP）
///   TEST_RUNNER_YH_S31_OLD_BETA=1                           旧 Beta 包模式（`scripts/s31-release-live.sh --old-beta`）：被测 App 换成
///     f6dc700（#54）之前的 Beta 构建，包内默认 https://47.117.184.253（TestFlight 上家里人装的就是这种），核对也走 IP。
///     那时看账还是占位页（S24 才做），第 7 步改成核对占位页出得来；其余断言不变。
/// 最后在界面上退出登录（设置 → 退出登录），并在服务器上核对 App 那台设备的会话已注销，不在测试店留有效会话。
/// 店里要有至少两样不管保质期、有卖价的商品（线上「联调测试店甲」现成就有）。只写假数据，不测锁定。
@MainActor
final class S31ReleaseLiveUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var oldBeta: Bool { env["YH_S31_OLD_BETA"] == "1" }
    private static let domainBase = "https://api.yuanhuishop.cn", ipBase = "https://47.117.184.253"
    private var base: String { env["YH_S31_BASE"] ?? (oldBeta ? Self.ipBase : Self.domainBase) }

    override func setUpWithError() throws {
        try XCTSkipIf(env["YH_S31_USER"] == nil, "只在 scripts/s31-release-live.sh 里跑（设 TEST_RUNNER_YH_S31_USER）")
        continueAfterFailure = false
    }

    // MARK: - 小工具

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                      _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func tapWhenReady(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "找不到 \(what)", file: file, line: line)
        wait("\(what) 可点", timeout: timeout, file: file, line: line) { e.isEnabled && e.isHittable }
        e.tap()
    }

    /// 自家数字键盘（手输条码、进货数量和单价都是它）
    private func keys(_ app: XCUIApplication, _ s: String) {
        for c in s { app.buttons[c == "." ? "点" : String(c)].firstMatch.tap() }
    }

    private func syncLabel(_ app: XCUIApplication) -> String {
        let l = app.descendants(matching: .any).matching(identifier: "syncStatus").allElementsBoundByIndex.map(\.label).joined(separator: " ")
        for k in ["已同步", "没网"] where l.contains(k) { return k }
        if let r = l.range(of: #"\d+ 笔待传"#, options: .regularExpression) { return String(l[r]) }
        return l
    }

    private func waitSynced(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 90) {
        XCTAssertTrue(el(app, "syncStatus").waitForExistence(timeout: 20), "首页右上角有同步状态")
        wait("\(what)：已同步（现在「\(syncLabel(app))」）", timeout: timeout) { syncLabel(app) == "已同步" }
    }

    /// 从卖出页或进货页的相机区点「手输条码」，按数字键输入整条码，等唯一候选自动选中后「就是它，加进去」
    private func manualCode(_ app: XCUIApplication, _ code: String) {
        tapWhenReady(app.buttons["scanner.manual"], "手输条码")
        XCTAssertTrue(el(app, "manual.keypad").waitForExistence(timeout: 10), "手输页的键盘")
        keys(app, code)
        let pick = app.buttons["manual.pick"]
        wait("\(code) 只有一个候选，自动选中") { pick.isEnabled }
        pick.tap()
    }

    private func backHome(_ app: XCUIApplication) {
        for _ in 0..<4 where !el(app, "page.home").exists {
            let back = app.navigationBars.buttons.firstMatch
            if back.exists && back.isHittable { back.tap() } else { app.buttons["返回"].firstMatch.tap() }
            _ = el(app, "page.home").waitForExistence(timeout: 3)
        }
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 10), "回到首页")
    }

    // MARK: - 服务器核对（测试进程自己当一台手机，连同一个域名）

    private struct Server {
        let base: String, token: String, epoch: String

        static func login(base: String, user: String, password: String) throws -> Server {
            let r = try call(base, "POST", "/v1/auth/login", ["username": user, "password": password,
                                                              "device_id": UUID().uuidString.lowercased(), "label": "S31 核对"])
            return Server(base: base, token: try XCTUnwrap(r["token"] as? String, "登录失败：\(r)"), epoch: try XCTUnwrap(r["epoch"] as? String))
        }

        static func call(_ base: String, _ method: String, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) throws -> [String: Any] {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = method
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Data?, Error?)
            URLSession.shared.dataTask(with: req) { d, _, e in out = (d, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.1 { throw e }
            return try JSONSerialization.jsonObject(with: out.0 ?? Data()) as? [String: Any] ?? [:]
        }

        func get(_ path: String) throws -> [String: Any] { try Self.call(base, "GET", path, token: token) }

        /// 测试店里登录着的设备，去掉核对用的这台
        func otherDevices() throws -> Set<String> {
            let ds = try get("/v1/devices")["devices"] as? [[String: Any]] ?? []
            return Set(ds.filter { $0["is_me"] as? Bool != true }.compactMap { $0["id"] as? String })
        }

        func logout() { _ = try? Self.call(base, "POST", "/v1/auth/logout", [:], token: token) }

        /// 从头拉到底：商品、条码、流水
        func pullAll() throws -> (products: [[String: Any]], barcodes: [[String: Any]], entries: [[String: Any]]) {
            var cur: [String: Any] = ["catalog": 0, "ledger": 0]
            var p: [[String: Any]] = [], b: [[String: Any]] = [], e: [[String: Any]] = []
            for _ in 0..<200 {
                let r = try Self.call(base, "POST", "/v1/sync", ["epoch": epoch, "cursors": cur, "app_build": 1, "pull": true, "ops": []], token: token)
                let c = try XCTUnwrap(r["changes"] as? [String: Any], "同步失败：\(r)")
                p += c["products"] as! [[String: Any]]; b += c["barcodes"] as! [[String: Any]]; e += c["entries"] as! [[String: Any]]
                cur = r["cursors"] as! [String: Any]
                let more = r["has_more"] as! [String: Bool]
                if !more["catalog"]! && !more["ledger"]! { break }
            }
            // 同一个 id 后来的版本覆盖先前的
            var latest: [String: [String: Any]] = [:]
            for x in p { latest[x["id"] as! String] = x }
            return (Array(latest.values), b, e)
        }
    }

    private struct Item { let id: String, barcode: String, name: String, priceFen: Int }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    private func stock(_ products: [[String: Any]], _ id: String) -> (qty: Int, value: Int) {
        let p = products.first { $0["id"] as? String == id }
        let v = p?["private"] as? [String: Any]
        return (Self.int(v?["stock_qty"]), Self.int(v?["stock_value_fen"]))
    }

    // MARK: - 剧本

    func testReleaseBuildRunsLiteScriptOverDomain() throws {
        let user = try XCTUnwrap(env["YH_S31_USER"]), password = try XCTUnwrap(env["YH_S31_PASSWORD"])
        if oldBeta {
            XCTAssertTrue(base.hasPrefix(Self.ipBase), "旧 Beta 模式：核对和旧包一样走 IP：\(base)")
        } else {
            XCTAssertTrue(base.hasPrefix(Self.domainBase), "核对也走域名：\(base)")
        }
        print("S31 模式：\(oldBeta ? "旧 Beta 包（连 IP）" : "Release 包（连域名）")，核对走 \(base)")
        let server = try Server.login(base: base, user: user, password: password)
        defer { server.logout() }

        // 挑两样：不管保质期、没停用、有卖价、只有一个单件条码（手输整条码只出一个候选）
        let before = try server.pullAll()
        var items: [Item] = []
        for p in before.products.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
            guard p["track_expiry"] as? Bool == false, p["archived"] as? Bool == false, Self.int(p["price_fen"]) > 0 else { continue }
            let codes = before.barcodes.filter { $0["product_id"] as? String == p["id"] as? String && Self.int($0["pack_qty"]) <= 1 }
            guard codes.count == 1, let code = codes[0]["barcode"] as? String, code.count == 13 else { continue }
            items.append(Item(id: p["id"] as! String, barcode: code, name: p["name"] as? String ?? "", priceFen: Self.int(p["price_fen"])))
            if items.count == 2 { break }
        }
        XCTAssertEqual(items.count, 2, "店里要有两样不管保质期、有卖价的商品")
        let (a, b) = (items[0], items[1])
        let month0 = try server.get("/v1/reports/month")
        let entries0 = Set(before.entries.compactMap { $0["id"] as? String })
        let devices0 = try server.otherDevices()
        print("S31 商品 A=\(a.name) \(a.barcode) ¥\(a.priceFen)  B=\(b.name) \(b.barcode) ¥\(b.priceFen)  月报卖了 \(Self.int(month0["sold_fen"]))")

        // 1. 全新安装（脚本先卸载）→ 登录页 → 账号密码登录 → 首次同步 → 起名 → 首页
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 20), "全新安装出登录页")
        let u = app.textFields["login.username"]
        u.tap(); u.typeText(user)
        let pw = app.secureTextFields["login.password"]
        pw.tap(); pw.typeText(password)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(el(app, "page.onboarding").waitForExistence(timeout: 120), "登录成功、首次同步完进起名页")
        tapWhenReady(app.buttons["onboarding.done"], "起好了")
        XCTAssertTrue(el(app, "page.home").waitForExistence(timeout: 20))
        waitSynced(app, "登录后")
        let appDevices = try server.otherDevices().subtracting(devices0)
        XCTAssertEqual(appDevices.count, 1, "App 登录后服务器上多出一台设备")

        // 2. 进货：A 进 2 个，每个 ¥3.21
        tapWhenReady(el(app, "home.stockIn"), "首页「进货」")
        manualCode(app, a.barcode)
        tapWhenReady(el(app, "stockIn.qty"), "填数量")
        keys(app, "2")
        tapWhenReady(el(app, "stockIn.cost"), "填单价")
        keys(app, "3.21")
        tapWhenReady(app.buttons["stockIn.commit"], "确认入库")
        XCTAssertTrue(el(app, "stockIn.notice").waitForExistence(timeout: 15), "进货「记好了」")
        backHome(app)
        waitSynced(app, "进货后")

        // 3. 卖出：A、B 各一个，不抹零，「收好钱了，记账」
        tapWhenReady(el(app, "home.sell"), "首页「卖出」")
        manualCode(app, a.barcode)
        wait("一共 1 件") { el(app, "sell.itemCount").label == "一共 1 件" }
        manualCode(app, b.barcode)
        wait("一共 2 件") { el(app, "sell.itemCount").label == "一共 2 件" }
        tapWhenReady(app.buttons["sell.commit"], "记账")
        XCTAssertTrue(el(app, "sell.done").waitForExistence(timeout: 20), "卖出「记好了」")
        backHome(app)
        waitSynced(app, "卖出后")

        // 4. 撤一行：记的账 → 最新一张卡 → 记错了 → 撤掉 A 那一行
        tapWhenReady(el(app, "home.records"), "首页「记的账」")
        let card = el(app, "records.card.0")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        tapWhenReady(card.buttons["records.undo"], "撤销")
        XCTAssertTrue(el(app, "undo.sheet").waitForExistence(timeout: 10))
        var line: XCUIElement?
        // 每行的退款字样「×1    退 ¥3.00」按卖价认出 A 那一行（两样卖价不同），点它旁边的「只撤这样」
        let aRefund = "退 ¥\(a.priceFen / 100).\(String(format: "%02d", a.priceFen % 100))"
        XCTAssertNotEqual(a.priceFen, b.priceFen, "两样卖价要不同才认得出")
        for i in 0...3 where el(app, "undo.refund.\(i)").exists && el(app, "undo.refund.\(i)").label.contains(aRefund) { line = el(app, "undo.line.\(i)") }
        tapWhenReady(try XCTUnwrap(line, "撤销面板里找不到 \(aRefund)"), "撤 \(a.name) 那一行")
        XCTAssertTrue(el(app, "records.notice").waitForExistence(timeout: 15), "撤好了")
        backHome(app)
        waitSynced(app, "撤销后")

        // 5. 服务器核对：新流水恰好进货 1、卖出 2、冲销 1；库存 A +2 -1 +1 = +2、B -1
        let after = try server.pullAll()
        let fresh = after.entries.filter { !entries0.contains($0["id"] as? String ?? "") }
        let types = fresh.map { "\($0["type"] ?? "?")\($0["reverses_entry_id"] is NSNull ? "" : "-冲销")" }.sorted()
        print("S31 新流水：\(types)")
        XCTAssertEqual(fresh.filter { $0["type"] as? String == "stock_in" }.count, 1, "\(types)")
        XCTAssertEqual(fresh.filter { $0["type"] as? String == "sale" && $0["reverses_entry_id"] is NSNull }.count, 2, "\(types)")
        XCTAssertEqual(fresh.filter { !($0["reverses_entry_id"] is NSNull) && $0["reverses_entry_id"] != nil }.count, 1, "\(types)")
        let (a0, a1) = (stock(before.products, a.id), stock(after.products, a.id))
        let (b0, b1) = (stock(before.products, b.id), stock(after.products, b.id))
        XCTAssertEqual(a1.qty - a0.qty, 2, "A 进 2、卖 1、撤回 1")
        XCTAssertEqual(b1.qty - b0.qty, -1, "B 卖 1")

        // 6. 月报：卖了只多 B 的价；对账成立；期末货值 = 各商品货值之和
        let month1 = try server.get("/v1/reports/month")
        XCTAssertEqual(Self.int(month1["sold_fen"]) - Self.int(month0["sold_fen"]), b.priceFen, "月报卖了只多 B")
        // 货值按流水核对（不用月报自己的对账行，那个按定义恒成立）：A 货值变化 = 进货 2 × ¥3.21 − 卖出成本 + 撤回成本，
        // B 货值变化 = −卖出成本；月报期末货值的变化 = 两样之和
        let cogs = { (e: [String: Any]) in abs(Self.int(e["cogs_fen"])) }
        let saleA = fresh.filter { $0["type"] as? String == "sale" && $0["reverses_entry_id"] is NSNull && $0["product_id"] as? String == a.id }
        let saleB = fresh.filter { $0["type"] as? String == "sale" && $0["reverses_entry_id"] is NSNull && $0["product_id"] as? String == b.id }
        let revA = fresh.filter { !($0["reverses_entry_id"] is NSNull) && $0["reverses_entry_id"] != nil && $0["product_id"] as? String == a.id }
        XCTAssertEqual(saleA.count, 1); XCTAssertEqual(saleB.count, 1); XCTAssertEqual(revA.count, 1, "冲销的是 A 那一行")
        XCTAssertEqual(revA[0]["reverses_entry_id"] as? String, saleA[0]["id"] as? String, "冲销指向 A 的卖出")
        XCTAssertEqual(cogs(revA[0]), cogs(saleA[0]), "撤回按原成本回库")
        XCTAssertEqual(a1.value - a0.value, 642 - cogs(saleA[0]) + cogs(revA[0]), "A 货值变化 = 进货 642 − 卖出成本 + 撤回成本")
        XCTAssertEqual(b1.value - b0.value, -cogs(saleB[0]), "B 货值变化 = −卖出成本")
        XCTAssertEqual(Self.int(month1["stock_value_end_fen"]) - Self.int(month0["stock_value_end_fen"]),
                       (a1.value - a0.value) + (b1.value - b0.value), "月报期末货值的变化 = A、B 货值变化之和")
        print("S31 货值变化：A \(a1.value - a0.value) 分（卖出成本 \(cogs(saleA[0]))，撤回 \(cogs(revA[0]))）  B \(b1.value - b0.value) 分")
        let total = after.products.reduce(0) { $0 + stock(after.products, $1["id"] as! String).value }
        XCTAssertEqual(Self.int(month1["stock_value_end_fen"]), total, "月报期末货值 = 各商品货值之和")

        // 7. 手机上的看账（本月）和服务器逐分一致
        tapWhenReady(el(app, "home.reports"), "首页「看账」")
        let sold = Self.int(month1["sold_fen"])
        if oldBeta {
            // 旧 Beta 包（6382c15）的看账还是占位页「这一页还在做 / 开发计划 S24 段」，没有数字可核对
            XCTAssertTrue(el(app, "page.reports").waitForExistence(timeout: 15), "旧包的看账占位页")
            XCTAssertTrue(app.staticTexts["这一页还在做"].exists, "旧包看账是占位页")
            print("S31 看账（旧包是占位页「这一页还在做」，不出数字）；服务器月报卖了 \(sold) 分")
        } else {
            tapWhenReady(el(app, "reports.tab.month"), "本月")
            let soldEl = el(app, "reports.sold")
            wait("看账「卖了」是 \(sold) 分（现在「\(soldEl.label)」\(String(describing: soldEl.value))）") { soldEl.exists && soldEl.value as? String == String(sold) }
            print("S31 看账本月卖了：\(soldEl.label)；服务器 \(sold) 分")
        }
        backHome(app)

        // 8. 界面上退出登录（更多 → 退出登录 → 确认），服务器上 App 那台设备的会话已注销
        tapWhenReady(el(app, "home.more"), "首页「更多」")
        let logoutItem = el(app, "settings.item.logout")
        XCTAssertTrue(logoutItem.waitForExistence(timeout: 15), "设置里的退出登录")
        for _ in 0..<4 where !logoutItem.isHittable { app.swipeUp() }   // 在设置页底部，可能要往下翻
        tapWhenReady(logoutItem, "退出登录")
        tapWhenReady(el(app, "logout.confirm"), "确认退出登录")
        XCTAssertTrue(el(app, "page.login").waitForExistence(timeout: 30), "退出后回登录页")
        wait("服务器上 App 那台设备已注销") { (try? server.otherDevices().isDisjoint(with: appDevices)) == true }
        print("S31 界面退出登录：回到登录页，服务器上 App 设备已注销")
    }
}
