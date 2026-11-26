import Network
import XCTest

/// S24 看账（plan-v2 §8 S24 验收，夹具 + 本机桩服务器，桩回稿子 09 / 10 的数）。
/// 对着 S07 夹具的真服务器逐个数字核对的那条在 `S24LiveUITests`（scripts/s24-live.sh）。
@MainActor
final class S24UITests: XCTestCase {
    private var stub: ReportStub!
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try ReportStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(role: String = "family", api: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "on", "-uiReportGoods",
                               "-uiAPI", api ?? "http://localhost:\(stub.port)", "-uiRoute", "reports"] + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// 往下滚到元素整个露出来（最多 8 次）
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        let win = app.windows.firstMatch.frame
        for _ in 0..<8 where !(e.exists && e.isHittable && win.contains(e.frame)) { app.swipeUp(velocity: .slow) }
    }

    private func value(_ e: XCUIElement) -> String { (e.value as? String) ?? "" }

    /// 一个数：显示的字 + 辅助功能 value 里的原值（整数分），两样都和接口一致
    private func assertFigure(_ app: XCUIApplication, _ id: String, label: String, raw: Int64,
                              file: StaticString = #filePath, line: UInt = #line) {
        let e = el(app, id)
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) 存在", file: file, line: line)
        reveal(app, e)
        XCTAssertEqual(e.label, label, id, file: file, line: line)
        XCTAssertEqual(value(e), String(raw), "\(id) 的原值", file: file, line: line)
    }

    // MARK: 09

    /// 09：卖了、赚了、记了 N 笔（ReportToday.count）、优惠；卖得最好；快没货（单位查本机）；快过期（按服务器的今天算）；口径小字
    func testToday09MatchesTheServer() {
        let app = launch()
        XCTAssertTrue(el(app, "page.reports").waitForExistence(timeout: 10))
        assertFigure(app, "reports.sold", label: "¥1,286.50", raw: 128_650)
        assertFigure(app, "reports.profit", label: "¥312.40", raw: 31_240)
        assertFigure(app, "reports.records", label: "记了 87 笔", raw: 87)
        assertFigure(app, "reports.discount", label: "¥3.20", raw: 320)
        shot(app, "09")
        XCTAssertEqual(el(app, "reports.formula").label, "赚了 = 卖出 − 进价，损耗和盘点少的另算")
        XCTAssertFalse(el(app, "reports.costMissing").exists)
        for (i, name, n) in [(0, "农夫山泉 550ml", 48), (1, "青岛啤酒 500ml", 29), (2, "康师傅红烧牛肉面", 21)] {
            assertFigure(app, "reports.top.\(i)", label: "\(name) \(n)", raw: Int64(n))
        }
        let low0 = el(app, "reports.low.0"), low1 = el(app, "reports.low.1")
        reveal(app, low1)
        XCTAssertTrue(low0.label.contains("红牛 250ml") && low0.label.contains("还剩 2 罐"), low0.label)
        XCTAssertTrue(low1.label.contains("双汇王中王 60g") && low1.label.contains("还剩 3 根"), low1.label)
        XCTAssertTrue(el(app, "reports.low.header").label.contains("共 2 种"))
        let ex0 = el(app, "reports.expiring.0"), ex1 = el(app, "reports.expiring.1")
        reveal(app, ex1)
        XCTAssertTrue(ex0.label.contains("光明 新鲜牧场 950ml") && ex0.label.contains("已过期"), ex0.label)
        XCTAssertTrue(ex1.label.contains("桃李 醇熟切片面包") && ex1.label.contains("2 天后"), ex1.label)
        XCTAssertFalse(el(app, "reports.expiring.2").exists, "列前 2 样，其余进 19 看")
        XCTAssertTrue(el(app, "reports.expiring.header").label.contains("共 3 样"))
        shot(app, "09-bottom")
        let r = stub.requests(path: "/v1/reports/today")
        XCTAssertEqual(r.first?.query, "", "看今天不带日期：服务器的今天")
        XCTAssertEqual(r.first?.auth, "Bearer fixture-token")
    }

    /// 「记了 N 笔」点进记的账（07a）
    func testCountCardOpensRecords() {
        let app = launch()
        let c = el(app, "reports.records")
        XCTAssertTrue(c.waitForExistence(timeout: 10))
        c.tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 10))
    }

    /// 没有优惠时优惠卡不显示（今天、本月都是）
    func testNoDiscountHidesTheCard() {
        stub.noDiscount = true
        let app = launch()
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "reports.records").exists)
        XCTAssertFalse(el(app, "reports.discount").exists, "今天没有优惠：不显示优惠卡")
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app, "reports.discount").exists, "本月没有优惠：不显示优惠卡")
        XCTAssertTrue(el(app, "reports.expireLoss").exists, "过期损耗照样显示")
    }

    /// 快没货里库存 ≤ 0 的显示「没货了」
    func testOutOfStockShowsNoneLeft() {
        stub.outOfStock = true
        let app = launch()
        let low0 = el(app, "reports.low.0"), low1 = el(app, "reports.low.1")
        XCTAssertTrue(low0.waitForExistence(timeout: 10))
        reveal(app, low1)
        XCTAssertTrue(low0.label.contains("没货了") && !low0.label.contains("还剩"), low0.label)
        XCTAssertTrue(low1.label.contains("没货了"), "库存是负数也是「没货了」：\(low1.label)")
    }

    /// 看过去的某一天：快没货、快过期是现在的状态，不显示（§14 S07-6）；请求带这一天
    func testPastDayHidesNowSections() {
        let app = launch(extra: ["-uiReportDate", "2026-11-18"])
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["11月18日卖了（实收）"].exists)
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(el(app, "reports.top.0").exists)
        XCTAssertFalse(el(app, "reports.low.0").exists)
        XCTAssertFalse(el(app, "reports.low.header").exists)
        XCTAssertFalse(el(app, "reports.expiring.0").exists)
        XCTAssertEqual(stub.requests(path: "/v1/reports/today").first?.query, "date=2026-11-18")
    }

    // MARK: 10

    /// 10：三张卡（店里货值取 stock_value_end_fen）、优惠和过期损耗、对账各行相加等于最后一行、柱状图点了显示数值
    func testMonth10MatchesTheServer() {
        let app = launch()
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 10))
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 10))
        assertFigure(app, "reports.sold", label: "¥23,474.00", raw: 2_347_400)
        assertFigure(app, "reports.profit", label: "¥5,487", raw: 548_700)
        assertFigure(app, "reports.stockIn", label: "¥15,920", raw: 1_592_000)
        assertFigure(app, "reports.stockValue", label: "¥23,262", raw: 2_326_200)
        assertFigure(app, "reports.discount", label: "¥46", raw: 4_600)
        assertFigure(app, "reports.expireLoss", label: "¥58", raw: 5_800)
        XCTAssertTrue(app.staticTexts["11月卖了（到今天，实收）"].exists)
        XCTAssertEqual(el(app, "reports.formula").label, "赚了 = 卖出 − 进价，损耗和盘点少的另算")
        shot(app, "10")
        let expect: [(String, Int64)] = [("月初货值 + 本月进货 41,595", 4_159_500), ("减 卖掉的货的进价 17,987", -1_798_700),
                                         ("减 盘点少了的 128", -12_800), ("减 过期扔掉的 58", -5_800), ("减 退给供货商的 160", -16_000)]
        var sum: Int64 = 0
        for (i, (label, raw)) in expect.enumerated() {
            let e = el(app, "reports.recon.\(i)")
            reveal(app, e)
            XCTAssertEqual(e.label.replacingOccurrences(of: ", ", with: " "), label)
            XCTAssertEqual(value(e), String(raw))
            sum += Int64(value(e)) ?? 0
        }
        XCTAssertFalse(el(app, "reports.recon.5").exists, "期初登记和调整为 0：不显示")
        let end = el(app, "reports.recon.end")
        reveal(app, end)
        XCTAssertEqual(value(end), "2326200")
        XCTAssertTrue(end.label.contains("现在店里货值") && end.label.contains("23,262"), end.label)
        XCTAssertEqual(sum, 2_326_200, "对账各行相加等于最后一行")
        shot(app, "10-bottom")
        XCTAssertEqual(stub.requests(path: "/v1/reports/month").first?.query, "")
    }

    /// 点柱子显示那天的数（和接口的 daily 一致），再点一次收起
    func testTapBarShowsItsValue() {
        let app = launch(extra: ["-uiReportTab", "month"])
        let chart = el(app, "reports.chart")
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        reveal(app, chart)
        XCTAssertTrue(el(app, "reports.chart.today").label.contains("今天 1,286.50"), el(app, "reports.chart.today").label)
        XCTAssertTrue(el(app, "reports.chart.max").label.contains("最多 1,532"), el(app, "reports.chart.max").label)
        XCTAssertFalse(el(app, "reports.chart.selected").exists)
        // 柱子画在图的右边一大半（左边是 y 轴的字），点在中间偏右：落在某一天上
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        let sel = el(app, "reports.chart.selected")
        XCTAssertTrue(sel.waitForExistence(timeout: 5), "点了显示数值")
        let day = Int(sel.label.components(separatedBy: "月")[1].components(separatedBy: "日")[0]) ?? 0
        XCTAssertEqual(value(sel), String(ReportStub.daily[day - 1]), "第 \(day) 天：\(sel.label)")
        XCTAssertTrue(sel.label.hasPrefix("11月\(day)日卖了 ¥"), sel.label)
        shot(app, "10-tap")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        XCTAssertFalse(sel.waitForExistence(timeout: 2), "再点一次收起")
    }

    /// 有没填进价的卖出、没算进价的损耗：卡片下写出 N，和接口一致（今天、本月各一次）；对账卖出行注明「有 N 笔没算进价」
    func testCostMissingNotesMatchTheServer() {
        stub.costMissing = true
        let app = launch()
        XCTAssertTrue(el(app, "reports.costMissing").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "reports.costMissing").label, "有 2 样进价没填，卖的钱没算进「赚了」")
        XCTAssertEqual(el(app, "reports.lossMissing").label, "有 1 笔损耗没算进价")
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "reports.costMissing").label, "有 3 样进价没填，卖的钱没算进「赚了」")
        XCTAssertEqual(el(app, "reports.lossMissing").label, "有 4 笔损耗没算进价")
        let sale = el(app, "reports.recon.1")
        reveal(app, sale)
        XCTAssertTrue(sale.label.contains("卖掉的货的进价") && sale.label.contains("有 5 笔没算进价"), sale.label)
    }

    /// 金额很长、最大辅助字号：每个数整个在屏幕里（并排放不下就一张一行），显示的字照样逐分等于接口
    func testLongAmountsFitAtMaxSize() {
        stub.big = true
        let app = launch(extra: Self.maxAX)
        assertFigure(app, "reports.sold", label: "¥123,456.78", raw: 12_345_678)
        assertFigure(app, "reports.discount", label: "¥1,234.56", raw: 123_456)
        for id in ["reports.sold", "reports.profit", "reports.discount"] {
            let e = el(app, id)
            reveal(app, e)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(id) 整个在屏幕里：\(e.frame)")
        }
        shot(app, "09-big-ax")
        for _ in 0..<6 { app.swipeDown() }
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 10))
        assertFigure(app, "reports.discount", label: "¥123,456.78", raw: 12_345_678)
        assertFigure(app, "reports.expireLoss", label: "¥34,567.89", raw: 3_456_789)
        for id in ["reports.discount", "reports.expireLoss"] {
            let e = el(app, id)
            reveal(app, e)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(id) 整个在屏幕里：\(e.frame)")
        }
        shot(app, "10-big-ax")
    }

    // MARK: 离线、身份

    /// 没连上服务器：只显示「要联网才能看账」，不是空白；记的账照样进得去
    func testOfflineSaysNeedNetwork() {
        let app = launch(api: "http://localhost:1")
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 20))
        XCTAssertEqual(el(app, "reports.offline").label, "要联网才能看账")
        XCTAssertFalse(el(app, "reports.sold").exists)
        XCTAssertTrue(el(app, "reports.retry").exists)
        shot(app, "offline")
        el(app, "reports.records").tap()
        XCTAssertTrue(el(app, "page.records").waitForExistence(timeout: 10))
    }

    /// 看着账断了网：换栏、下拉都只出「要联网才能看账」，不留上一次的数；联网后「再试一次」又取到
    func testLosingNetworkDropsOldFigures() {
        let app = launch()
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 10))
        stub.down = true
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "reports.sold").exists)
        el(app, "reports.tab.today").tap()
        XCTAssertTrue(el(app, "reports.offline").waitForExistence(timeout: 20))
        XCTAssertFalse(el(app, "reports.sold").exists, "回到今天也不显示刚才的数")
        XCTAssertFalse(el(app, "reports.profit").exists)
        stub.down = false
        el(app, "reports.retry").tap()
        XCTAssertTrue(el(app, "reports.sold").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "reports.sold").label, "¥1,286.50")
    }

    /// 收银员进不了看账：硬塞路由也只出「用不了」页，一个看账请求都不发
    func testCashierCannotSeeReports() {
        let app = launch(role: "cashier")
        XCTAssertTrue(el(app, "page.denied").waitForExistence(timeout: 10))
        XCTAssertFalse(el(app, "page.reports").exists)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(stub.requests(path: "/v1/reports/today").isEmpty && stub.requests(path: "/v1/reports/month").isEmpty)
    }

    /// 最大辅助字号：卡片一张一行，数字整个露出来；对账各行照样在
    func testMaxAccessibilitySize() {
        let app = launch(extra: Self.maxAX)
        let sold = el(app, "reports.sold")
        XCTAssertTrue(sold.waitForExistence(timeout: 10))
        for id in ["reports.sold", "reports.profit", "reports.records", "reports.discount"] {
            let e = el(app, id)
            reveal(app, e)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(id) 整个在屏幕里：\(e.frame)")
        }
        shot(app, "09-ax")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        el(app, "reports.tab.month").tap()
        XCTAssertTrue(el(app, "reports.stockValue").waitForExistence(timeout: 10))
        for id in ["reports.profit", "reports.stockIn", "reports.stockValue", "reports.recon.end"] {
            let e = el(app, id)
            reveal(app, e)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(e.frame), "\(id) 整个在屏幕里：\(e.frame)")
        }
        shot(app, "10-ax")
    }
}

/// 看账接口的桩：回稿子 09 / 10 的数（契约 openapi.yaml ReportToday / ReportMonth）
final class ReportStub: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: String
        let auth: String
    }

    /// 10 的柱子：1–19 日，8 日最多 1,532、19 日（稿子上的今天）1,286.50，合计 = 卖了 23,474
    static let daily: [Int64] = {
        var d: [Int64] = [118_000, 112_000, 108_000, 124_000, 131_000, 119_000, 147_000, 153_200, 121_000, 112_000,
                          123_000, 128_000, 116_000, 143_000, 145_000, 128_000, 118_000, 0, 128_650]
        d[17] = 2_347_400 - d.reduce(0, +)
        return d
    }()

    private let listener: NWListener
    private let queue = DispatchQueue(label: "s24-report-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private var flags = (noDiscount: false, outOfStock: false, down: false, costMissing: false, big: false)

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() throws -> ReportStub {
        let s = try ReportStub()
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ReportStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
    var noDiscount: Bool { get { lock.withLock { flags.noDiscount } } set { lock.withLock { flags.noDiscount = newValue } } }
    var outOfStock: Bool { get { lock.withLock { flags.outOfStock } } set { lock.withLock { flags.outOfStock = newValue } } }
    /// 有没填进价的卖出、没算进价的损耗（今天 2 样 / 1 笔，本月 3 样 / 4 笔，对账卖出行 5 笔）
    var costMissing: Bool { get { lock.withLock { flags.costMissing } } set { lock.withLock { flags.costMissing = newValue } } }
    /// 金额很长（十几万、带角分），看窄屏大字时放不放得下
    var big: Bool { get { lock.withLock { flags.big } } set { lock.withLock { flags.big = newValue } } }
    /// 当作断网：收到请求不回、直接断开（App 那边是没连上）
    var down: Bool { get { lock.withLock { flags.down } } set { lock.withLock { flags.down = newValue } } }
    func requests(path: String) -> [Request] { lock.withLock { log.filter { $0.path == path } } }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: b[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let auth = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
                    .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
                self.respond(c, lines.first ?? "", auth: auth)
                return
            }
            if done || err != nil { c.cancel() } else { self.receive(c, b) }
        }
    }

    private func respond(_ c: NWConnection, _ first: String, auth: String) {
        let parts = first.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.dropFirst().first.map(String.init) ?? ""
        let pq = target.split(separator: "?", maxSplits: 1)
        let path = pq.first.map(String.init) ?? "", query = pq.count > 1 ? String(pq[1]) : ""
        let (status, out, drop): (Int, String, Bool) = lock.withLock {
            log.append(Request(method: method, path: path, query: query, auth: auth))
            if flags.down { return (0, "", true) }
            switch path {
            case "/v1/reports/today": return (200, today(date: query.hasPrefix("date=") ? String(query.dropFirst(5)) : "2026-11-19"), false)
            case "/v1/reports/month": return (200, month(), false)
            default: return (404, #"{"code":"not_found"}"#, false)
            }
        }
        if drop { c.cancel(); return }
        let body = Data(out.utf8)
        var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 204 { head = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" }
        c.send(content: Data(head.utf8) + (status == 204 ? Data() : body), completion: .contentProcessed { _ in c.cancel() })
    }

    private static func pid(_ n: Int) -> String { String(format: "5eed0000-0000-4000-8000-%012x", n) }

    private func today(date: String) -> String {
        let discount = flags.noDiscount ? 0 : flags.big ? 123_456 : 320
        let low = flags.outOfStock ? (0, -1) : (2, 3)
        let cm = flags.costMissing ? (2, 1) : (0, 0)
        let (sold, profit) = flags.big ? (12_345_678, 2_345_678) : (128_650, 31_240)
        return """
        {"date":"\(date)","sold_fen":\(sold),"profit_fen":\(profit),"discount_fen":\(discount),"count":87,"cost_missing_count":\(cm.0),"loss_cost_missing_count":\(cm.1),
         "top_sellers":[{"product_id":"\(Self.pid(0x206))","name":"农夫山泉 550ml","qty":48,"amount_fen":9600},
                        {"product_id":"\(Self.pid(0x202))","name":"青岛啤酒 500ml","qty":29,"amount_fen":17400},
                        {"product_id":"\(Self.pid(0x203))","name":"康师傅红烧牛肉面","qty":21,"amount_fen":9450}],
         "low_stock":[{"product_id":"\(Self.pid(0x2F1))","name":"红牛 250ml","qty":\(low.0)},
                      {"product_id":"\(Self.pid(0x2F2))","name":"双汇王中王 60g","qty":\(low.1)}],
         "expiring":[{"product_id":"\(Self.pid(0x303))","name":"光明 新鲜牧场 950ml","qty":2,"expiry_date":"2026-11-18"},
                     {"product_id":"\(Self.pid(0x2F3))","name":"桃李 醇熟切片面包","qty":4,"expiry_date":"2026-11-21"},
                     {"product_id":"\(Self.pid(0x202))","name":"青岛啤酒 500ml","qty":48,"expiry_date":"2026-11-25"}]}
        """
    }

    private func month() -> String {
        let discount = flags.noDiscount ? 0 : flags.big ? 12_345_678 : 4600
        let expire = flags.big ? 3_456_789 : 5800
        let cm = flags.costMissing ? (3, 4, 5) : (0, 0, 0)
        let daily = Self.daily.enumerated().map { i, f in
            #"{"date":"2026-11-\#(String(format: "%02d", i + 1))","sold_fen":\#(f),"profit_fen":\#(f / 4)}"#
        }.joined(separator: ",")
        return """
        {"month":"2026-11","sold_fen":2347400,"profit_fen":548700,"stock_value_end_fen":2326200,"discount_fen":\(discount),
         "expire_loss_fen":\(expire),"cost_missing_count":\(cm.0),"loss_cost_missing_count":\(cm.1),"daily":[\(daily)],
         "reconciliation":{"stock_value_start_fen":2567500,"rows":[
           {"key":"stock_in","amount_fen":1592000,"cost_missing_count":0},{"key":"sale","amount_fen":-1798700,"cost_missing_count":\(cm.2)},
           {"key":"count","amount_fen":-12800,"cost_missing_count":0},{"key":"expire_loss","amount_fen":-5800,"cost_missing_count":0},
           {"key":"supplier_return","amount_fen":-16000,"cost_missing_count":0}],"stock_value_end_fen":2326200}}
        """
    }
}
