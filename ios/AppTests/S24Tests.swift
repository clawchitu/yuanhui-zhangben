import ShopCore
import XCTest
@testable import YuanhuiZhangben

/// S24 看账：显示规则（纯函数）和取账的状态机（离线不留旧数、换栏时晚到的旧响应不覆盖）
@MainActor
final class S24Tests: XCTestCase {
    static func month(rows: [ReportReconRow], start: Int64, end: Int64, daily: String = "[]") throws -> ReportMonth {
        let r = rows.map { #"{"key":"\#($0.key.rawValue)","amount_fen":\#($0.amountFen.raw),"cost_missing_count":\#($0.costMissingCount)}"# }
            .joined(separator: ",")
        let json = """
        {"month":"2026-11","sold_fen":2347400,"profit_fen":548700,"stock_value_end_fen":\(end),"discount_fen":0,"expire_loss_fen":5800,
         "cost_missing_count":0,"loss_cost_missing_count":0,"daily":\(daily),
         "reconciliation":{"stock_value_start_fen":\(start),"rows":[\(r)],"stock_value_end_fen":\(end)}}
        """
        return try JSONDecoder().decode(ReportMonth.self, from: Data(json.utf8))
    }

    static func today(discount: Int64 = 320, date: String = "2026-11-19") throws -> ReportToday {
        let json = """
        {"date":"\(date)","sold_fen":128650,"profit_fen":31240,"discount_fen":\(discount),"count":87,"cost_missing_count":0,
         "top_sellers":[],"low_stock":[{"product_id":"5eed0000-0000-4000-8000-0000000002f1","name":"红牛 250ml","qty":0}],"expiring":[]}
        """
        return try JSONDecoder().decode(ReportToday.self, from: Data(json.utf8))
    }

    // MARK: 金额怎么写

    func testYuanFormatting() {
        XCTAssertEqual(ReportFormat.yuan(Fen(128_650)), "1,286.50")
        XCTAssertEqual(ReportFormat.yuan(Fen(2_347_400)), "23,474.00")
        XCTAssertEqual(ReportFormat.yuan(Fen(-320)), "-3.20")
        XCTAssertEqual(ReportFormat.yuan(Fen(5)), "0.05")
        XCTAssertEqual(ReportFormat.yuan(Fen(123_456_789_01)), "123,456,789.01")
        XCTAssertEqual(ReportFormat.compact(Fen(2_326_200)), "23,262")
        XCTAssertEqual(ReportFormat.compact(Fen(2_326_185)), "23,261.85", "有角分就写出来，显示的数逐分等于接口")
        XCTAssertEqual(ReportFormat.compact(Fen(-1_798_700)), "-17,987")
        XCTAssertEqual(ReportFormat.compact(Fen(0)), "0")
        XCTAssertEqual(ReportFormat.money(Fen(4_600), compact: true), "¥46")
    }

    // MARK: 10 对账

    /// 设计稿 10：月初 + 进货 41,595，减四行，最后一行 23,262；各行相加 = 最后一行
    func testReconLinesDesign10() throws {
        let m = try Self.month(rows: [.init(key: .stockIn, amountFen: Fen(1_592_000)), .init(key: .sale, amountFen: Fen(-1_798_700)),
                                      .init(key: .count, amountFen: Fen(-12_800)), .init(key: .expireLoss, amountFen: Fen(-5_800)),
                                      .init(key: .supplierReturn, amountFen: Fen(-16_000))],
                               start: 2_567_500, end: 2_326_200)
        let l = m.reconLines
        XCTAssertEqual(l.map(\.label), ["月初货值 + 本月进货", "卖掉的货的进价", "盘点少了的", "过期扔掉的", "退给供货商的"])
        XCTAssertEqual(l.map(\.verb), [nil, "减", "减", "减", "减"])
        XCTAssertEqual(l.map { ReportFormat.compact($0.shown) }, ["41,595", "17,987", "128", "58", "160"])
        XCTAssertEqual(m.reconSum, 2_326_200)
        XCTAssertEqual(m.reconSum, m.reconciliation.stockValueEndFen.raw)
        XCTAssertEqual(m.stockInFen, Fen(1_592_000), "进货花了 = 进货行")
        XCTAssertEqual(m.stockValueEndFen, Fen(2_326_200))
    }

    /// 正数的行写「加」（盘点多了、撤销上个月的卖出），期初和调整非零才有；各行相加照样等于最后一行（逐分，带角分）
    func testReconLinesWithPositiveRowsAndCents() throws {
        let rows: [ReportReconRow] = [.init(key: .stockIn, amountFen: Fen(0)), .init(key: .sale, amountFen: Fen(1_205)),
                                      .init(key: .count, amountFen: Fen(333)), .init(key: .expireLoss, amountFen: Fen(-7)),
                                      .init(key: .supplierReturn, amountFen: Fen(0)), .init(key: .openingAndAdjust, amountFen: Fen(-1_001), costMissingCount: 0)]
        let start: Int64 = 99_999
        let end = start + rows.reduce(0) { $0 + $1.amountFen.raw }
        let m = try Self.month(rows: rows, start: start, end: end)
        let l = m.reconLines
        XCTAssertEqual(l.map(\.verb), [nil, "加", "加", "减", "减", "减"])
        XCTAssertEqual(l[1].label, "撤销卖出退回的进价")
        XCTAssertEqual(l[2].label, "盘点多出来的")
        XCTAssertEqual(l[5].label, "期初登记和调整")
        XCTAssertEqual(l.map { ReportFormat.compact($0.shown) }, ["999.99", "12.05", "3.33", "0.07", "0", "10.01"])
        XCTAssertEqual(m.reconSum, end)
        // 「减 X」的 X 是正数、「加 X」也是正数：带上动词的 ± 和 signed 一致
        for line in l.dropFirst() {
            XCTAssertEqual(line.verb == "加" ? line.shown.raw : -line.shown.raw, line.signed)
        }
    }

    /// 随机对账：各行相加恒等于最后一行（服务器保证 start + Σ rows = end，手机拆行时不能丢分）
    func testReconSumProperty() throws {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let keys: [ReportReconRow.Key] = [.stockIn, .sale, .count, .expireLoss, .supplierReturn, .openingAndAdjust]
            let rows = keys.map { ReportReconRow(key: $0, amountFen: Fen(Int64.random(in: -9_999_999...9_999_999, using: &g)),
                                                 costMissingCount: Int.random(in: 0...3, using: &g)) }
            let start = Int64.random(in: -9_999_999...99_999_999, using: &g)
            let end = start + rows.reduce(0) { $0 + $1.amountFen.raw }
            let m = try Self.month(rows: rows, start: start, end: end)
            XCTAssertEqual(m.reconSum, end)
            XCTAssertEqual(m.reconLines.dropFirst().map(\.costMissing), rows.dropFirst().map(\.costMissingCount))
        }
    }

    // MARK: 柱状图

    func testBarsMarkOnlyTodayAndAxisFont() throws {
        let m = try Self.month(rows: [], start: 0, end: 0, daily: """
        [{"date":"2026-11-01","sold_fen":100,"profit_fen":1},{"date":"2026-11-19","sold_fen":128650,"profit_fen":2},{"date":"2026-11-20","sold_fen":-5,"profit_fen":0}]
        """)
        let bars = DayBar.bars(m, today: "2026-11-19")
        XCTAssertEqual(bars.map(\.day), [1, 19, 20])
        XCTAssertEqual(bars.map(\.isToday), [false, true, false], "只有今天是朱红，其余灰")
        XCTAssertEqual(bars.map(\.soldFen), [100, 128_650, -5])
        XCTAssertEqual(m.daysInMonth, 30)
        XCTAssertEqual(m.monthTitle, "11月")
        XCTAssertGreaterThanOrEqual(ReportLabels.axisFontSize, 18, "坐标轴字号 ≥ 18pt")
        XCTAssertEqual(ReportLabels.shanghaiDay(UIFixture.designNow), "2026-11-19")
    }

    // MARK: 09 标签

    func testLowStockAndExpiryLabels() {
        XCTAssertEqual(ReportLabels.lowStock(qty: 2, unit: "罐"), "还剩 2 罐")
        XCTAssertEqual(ReportLabels.lowStock(qty: 3, unit: nil), "还剩 3 个")
        XCTAssertEqual(ReportLabels.lowStock(qty: 0, unit: "罐"), "没货了")
        XCTAssertEqual(ReportLabels.lowStock(qty: -4, unit: "罐"), "没货了", "库存 ≤ 0 一律「没货了」")
        XCTAssertEqual(ReportLabels.expiring("2026-11-18", today: "2026-11-19"), "已过期")
        XCTAssertEqual(ReportLabels.expiring("2026-11-19", today: "2026-11-19"), "今天到期")
        XCTAssertEqual(ReportLabels.expiring("2026-11-21", today: "2026-11-19"), "2 天后")
        XCTAssertEqual(ReportLabels.expiring("2027-03-01", today: "2027-02-27"), "2 天后", "跨月")
        XCTAssertEqual(ReportLabels.expiring("2028-03-01", today: "2028-02-28"), "2 天后", "闰年")
        XCTAssertEqual(ReportLabels.expiring("2027-01-01", today: "2026-12-31"), "1 天后", "跨年")
    }

    // MARK: 状态机

    /// 没网：不发请求，直接「要联网才能看账」；联网了重取。看着账断网：旧数马上清掉
    func testOfflineNeverShowsOldFigures() async throws {
        let calls = Counter()
        let t = try Self.today()
        let m = ReportsModel(backend: ReportsBackend(today: { _ in calls.bump(); return t }, month: { _ in throw APIError.transport("x") }))
        await m.load(offline: true)
        XCTAssertEqual(m.state, .offline)
        XCTAssertEqual(calls.n, 0, "没网不发请求")
        await m.networkChanged(offline: false)
        XCTAssertEqual(m.state, .today(t))
        await m.networkChanged(offline: true)
        XCTAssertEqual(m.state, .offline, "断网：不留旧数")
        await m.networkChanged(offline: false)
        XCTAssertEqual(m.state, .today(t))
        // 换到本月没连上：旧的今天的数不留着
        await m.select(.month, offline: false)
        XCTAssertEqual(m.state, .offline)
        await m.select(.today, offline: false)
        XCTAssertEqual(m.state, .today(t))
    }

    func testErrorsMapToMessages() {
        XCTAssertEqual(ReportsModel.state(for: APIError.transport("x")), .offline)
        XCTAssertEqual(ReportsModel.state(for: DeviceBackend.NoToken()), .offline)
        XCTAssertEqual(ReportsModel.state(for: APIError.server(status: 403, code: "forbidden", lockedUntil: nil, retryAfterS: nil)), .failed("这台手机不能看账"))
        XCTAssertEqual(ReportsModel.state(for: APIError.server(status: 500, code: "internal", lockedUntil: nil, retryAfterS: nil)), .failed("没取到账，过一会再试"))
    }

    /// 先点本月、马上点回今天：本月的响应晚到，不能盖住今天
    func testLateResponseFromOtherTabIsDropped() async throws {
        let t = try Self.today()
        let mo = try Self.month(rows: [], start: 0, end: 0)
        let gate = Gate()
        let m = ReportsModel(backend: ReportsBackend(today: { _ in t }, month: { _ in await gate.wait(); return mo }))
        await m.load(offline: false)
        let slow = Task { await m.select(.month, offline: false) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(m.state, .loading, "换栏时先清掉旧数")
        await m.select(.today, offline: false)
        await gate.open()
        await slow.value
        XCTAssertEqual(m.tab, .today)
        XCTAssertEqual(m.state, .today(t))
    }

    /// 快没货的单位查本机；看过去的某一天时不显示快没货、快过期
    func testUnitsAndShowsNow() async throws {
        let t = try Self.today()
        let m = ReportsModel(backend: ReportsBackend(today: { _ in t }, month: { _ in throw APIError.transport("x") }))
        m.unitLookup = { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, "罐") }) }
        await m.load(offline: false)
        XCTAssertEqual(m.units[UUID(uuidString: "5EED0000-0000-4000-8000-0000000002F1")!], "罐")
        XCTAssertTrue(m.showsNow)
        let past = ReportsModel(backend: m.backend, date: "2026-11-18")
        XCTAssertFalse(past.showsNow)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var n: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
