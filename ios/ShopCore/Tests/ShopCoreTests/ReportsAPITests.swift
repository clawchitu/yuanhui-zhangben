import Foundation
import Testing
@testable import ShopCore

/// S24：看账接口（契约 openapi.yaml `/v1/reports/today`、`/v1/reports/month`）。数字原样解码成整数分，不重算
@Suite(.serialized) struct ReportsAPITests {
    let debug = APIBasePolicy(hosts: ["api.yuanhuishop.cn"], allowLoopbackHTTP: true)

    private func client(_ base: String) -> APIClient {
        let name = "reportsapi-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return APIClient(bases: APIBaseStore(defaultBase: base, policy: debug, defaults: d)!)
    }

    static let today = #"""
    {"date":"2026-11-20","sold_fen":117750,"profit_fen":27150,"discount_fen":800,"count":2,"cost_missing_count":1,
     "loss_cost_missing_count":3,
     "top_sellers":[{"product_id":"5eed0000-0000-4000-8000-000000000206","name":"农夫山泉 550ml","qty":206,"amount_fen":33350}],
     "low_stock":[{"product_id":"5eed0000-0000-4000-8000-000000000207","name":"红牛 250ml","qty":-1}],
     "expiring":[{"product_id":"5eed0000-0000-4000-8000-000000000208","name":"桃李 醇熟切片面包","qty":4,"expiry_date":"2026-11-22"}]}
    """#

    static let month = #"""
    {"month":"2026-11","sold_fen":2347400,"profit_fen":548700,"stock_value_end_fen":2326200,"discount_fen":4600,
     "expire_loss_fen":5800,"cost_missing_count":0,"loss_cost_missing_count":0,
     "daily":[{"date":"2026-11-01","sold_fen":117350,"profit_fen":27150},{"date":"2026-11-02","sold_fen":-50,"profit_fen":-9}],
     "reconciliation":{"stock_value_start_fen":2567500,"rows":[
       {"key":"stock_in","amount_fen":1592000,"cost_missing_count":0},{"key":"sale","amount_fen":-1798700,"cost_missing_count":0},
       {"key":"count","amount_fen":-12800,"cost_missing_count":0},{"key":"expire_loss","amount_fen":-5800,"cost_missing_count":0},
       {"key":"supplier_return","amount_fen":-16000,"cost_missing_count":0},{"key":"opening_and_adjust","amount_fen":3,"cost_missing_count":0}],
      "stock_value_end_fen":2326203}}
    """#

    @Test func todayDecodesAndAsksTheServersToday() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: Self.today) }
        defer { stub.stop() }
        let api = client(stub.base)
        let t = try await api.reportToday(token: "t")
        #expect(t.date == "2026-11-20" && t.soldFen == Fen(117_750) && t.profitFen == Fen(27_150) && t.discountFen == Fen(800))
        #expect(t.count == 2 && t.costMissingCount == 1 && t.lossCostMissingCount == 3)
        #expect(t.topSellers == [ReportProductAmount(productId: UUID(uuidString: "5EED0000-0000-4000-8000-000000000206")!, name: "农夫山泉 550ml",
                                                     qty: 206, amountFen: Fen(33_350))])
        #expect(t.lowStock.first?.qty == -1)
        #expect(t.expiring.first?.expiryDate == "2026-11-22")
        _ = try await api.reportToday(date: "2026-11-19", token: "t")
        #expect(stub.requests.map(\.path) == ["/v1/reports/today", "/v1/reports/today?date=2026-11-19"])
        #expect(stub.requests.first?.headers["authorization"] == "Bearer t")
    }

    @Test func monthDecodesEveryFigure() async throws {
        let stub = try LocalStub { _ in .init(status: 200, body: Self.month) }
        defer { stub.stop() }
        let m = try await client(stub.base).reportMonth(token: "t")
        #expect(m.month == "2026-11" && m.soldFen == Fen(2_347_400) && m.profitFen == Fen(548_700))
        #expect(m.stockValueEndFen == Fen(2_326_200) && m.discountFen == Fen(4_600) && m.expireLossFen == Fen(5_800))
        #expect(m.daily.map(\.soldFen) == [Fen(117_350), Fen(-50)])
        #expect(m.reconciliation.stockValueStartFen == Fen(2_567_500))
        #expect(m.reconciliation.rows.map(\.key) == [.stockIn, .sale, .count, .expireLoss, .supplierReturn, .openingAndAdjust])
        #expect(m.reconciliation.rows.last?.amountFen == Fen(3))
        #expect(m.reconciliation.stockValueEndFen == Fen(2_326_203))
        #expect(stub.requests.first?.path == "/v1/reports/month")
    }

    /// 收银员（403）、没连上：抛错，不给一份空账
    @Test func forbiddenAndTransportThrow() async throws {
        let stub = try LocalStub { _ in .init(status: 403, body: #"{"code":"forbidden"}"#) }
        let api = client(stub.base)
        await #expect(throws: APIError.self) { _ = try await api.reportToday(token: "t") }
        stub.stop()
        let dead = client("http://127.0.0.1:1")
        await #expect(throws: APIError.self) { _ = try await dead.reportMonth(token: "t") }
    }
}
