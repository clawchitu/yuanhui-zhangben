import Foundation
import XCTest
@testable import ShopCore

/// S19 进货：蓝卡上的数（一共、入账、这批单位成本、临时库存、预计平均）和契约向量逐分一致；
/// 生产日期 + 保质期月数和 expiry.json 一致；outbox 里的 `stock_in` 带件数和每件单价；收银员不能进货。
final class StockInTests: XCTestCase {
    static let colaPack = "6925303770020"      // 可口可乐整箱码，1 箱 = 24 罐
    static let zhonghuaCarton = "6901028075879" // 中华整条码，1 条 = 10 包；演示库存 6 包
    static let water = "6921168509256"          // 农夫山泉：库存 −2，进价没填

    func db(_ role: Role) throws -> LocalDB {
        let db = try LocalDB.inMemory()
        try db.beginSession(try LocalSession(deviceId: uuid(0xD19), storeId: DemoSeed.storeId, role: role, tokenRef: "t19",
                                             storeName: "元辉烟酒店", deviceLabel: "柜台手机"))
        try DemoSeed.install(into: db)
        return db
    }

    // MARK: cost.json：每一组第一步是进货的，蓝卡的数和服务器算出来的逐分一致

    func testPreviewMatchesCostVectors() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/cost.json") as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        var checked = 0, averaged = 0
        for c in cases {
            guard let initial = c["initial"] as? [String: Any], let step = (c["steps"] as? [[String: Any]])?.first,
                  let action = step["action"] as? [String: Any], action["type"] as? String == "stock_in",
                  let expect = step["expect"] as? [String: Any], let state = expect["state"] as? [String: Any],
                  let entries = expect["entries"] as? [[String: Any]],
                  let stockIn = entries.first(where: { $0["type"] as? String == "stock_in" })
            else { continue }
            let id = c["id"] as? String ?? "?"
            let q = try XCTUnwrap(int64(initial["q"])), v = try XCTUnwrap(int64(initial["v"]))
            let k = try XCTUnwrap(initial["k"] as? Bool)
            let cFen = int64(initial["c"]).map(Fen.init)
            guard let base = try? ProductPrivate(productId: uuid(1), stockQty: q, stockValueFen: Fen(v), lastCostFen: cFen,
                                                 costKnown: k, stockVer: 1) else { continue }
            let packQty = int64(action["pack_qty"]) ?? 1
            let packCount = try XCTUnwrap(int64(action["pack_count"]), id)
            let unit = try XCTUnwrap(int64(action["unit_cost_fen"]), id)
            let p = try StockInPreview(packQty: packQty, packCount: packCount, unitCostFen: Fen(unit), baseline: base, stockBefore: q)
            XCTAssertEqual(p.totalFen.raw, int64(stockIn["amount_fen"]), "\(id) 一共")
            XCTAssertEqual(p.baseQty, int64(stockIn["qty_delta"]), "\(id) 入账")
            XCTAssertEqual(p.newStockQty, int64(state["q"]), "\(id) 临时库存")
            XCTAssertEqual(p.batchUnitCostFen.raw, int64(state["c"]), "\(id) 这批单位成本 b = c")
            if k && q > 0 {
                XCTAssertEqual(p.averageCostFen?.raw, int64(state["u"]), "\(id) 预计平均 = 服务器算的 u")
                averaged += 1
            } else {
                XCTAssertNil(p.averageCostFen, "\(id) 进价未知或库存不为正：不显示平均")
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "cost.json 里至少有两组是先进货的")
        XCTAssertGreaterThanOrEqual(averaged, 1)
    }

    /// 06a：可乐 5 箱 × ¥48 → 一共 ¥240.00，入账 120 罐，每罐 ¥2.00
    func testColaCaseFiveTimes48() throws {
        let db = try db(.family)
        let conv = try XCTUnwrap(db.lookup(barcode: Self.colaPack))
        let priv = try db.productPrivate(conv.product.id)
        let p = try StockInPreview(conversion: conv, packCount: 5, unitCostFen: Fen(4800), baseline: priv,
                                   stockBefore: try db.displayStock(conv.product.id)?.qty)
        XCTAssertEqual(p.totalFen.raw, 24000)
        XCTAssertEqual(p.baseQty, 120)
        XCTAssertEqual(p.batchUnitCostFen.raw, 200)
        XCTAssertEqual(p.newStockQty, 150, "演示库存 30 罐 + 120")
    }

    /// §5.2 必过：原有 6 包、货值 ¥242.80，进 5 条 × ¥400 → 56 包，每包 ¥40.00，平均 ¥40.05
    func testCartonAverage() throws {
        let base = try ProductPrivate(productId: uuid(2), stockQty: 6, stockValueFen: Fen(24280), lastCostFen: Fen(4000),
                                      costKnown: true, stockVer: 1)
        let p = try StockInPreview(packQty: 10, packCount: 5, unitCostFen: Fen(40000), baseline: base, stockBefore: 6)
        XCTAssertEqual(p.newStockQty, 56)
        XCTAssertEqual(p.batchUnitCostFen.raw, 4000)
        XCTAssertEqual(p.averageCostFen?.raw, 4005)
    }

    func testNoAverageWhenCostUnknownOrStockNotPositive() throws {
        let db = try db(.family)
        let conv = try XCTUnwrap(db.lookup(barcode: Self.water))
        let p = try StockInPreview(conversion: conv, packCount: 3, unitCostFen: Fen(100),
                                   baseline: try db.productPrivate(conv.product.id),
                                   stockBefore: try db.displayStock(conv.product.id)?.qty)
        XCTAssertNil(p.averageCostFen)
        XCTAssertEqual(p.newStockQty, 1, "−2 + 3")
        let known = try ProductPrivate(productId: uuid(3), stockQty: 0, stockValueFen: .zero, lastCostFen: Fen(300),
                                       costKnown: true, stockVer: 1)
        XCTAssertNil(try StockInPreview(packQty: 1, packCount: 2, unitCostFen: Fen(300), baseline: known, stockBefore: 0).averageCostFen)
        XCTAssertNil(try StockInPreview(packQty: 1, packCount: 2, unitCostFen: Fen(300), baseline: nil, stockBefore: nil).newStockQty,
                     "收银员手机没有基线")
    }

    func testPreviewLimits() {
        XCTAssertInvalid(try StockInPreview(packQty: 1, packCount: 0, unitCostFen: Fen(100), baseline: nil, stockBefore: nil), "0 件")
        XCTAssertInvalid(try StockInPreview(packQty: 1, packCount: Limits.maxPackCount + 1, unitCostFen: Fen(1), baseline: nil,
                                            stockBefore: nil))
        XCTAssertInvalid(try StockInPreview(packQty: 9_999, packCount: 99_999, unitCostFen: Fen(1), baseline: nil, stockBefore: nil),
                         "入账超 9,999,999")
        XCTAssertInvalid(try StockInPreview(packQty: 1, packCount: 2, unitCostFen: Fen(Limits.maxFen), baseline: nil, stockBefore: nil),
                         "总价超上限")
        XCTAssertNoThrow(try StockInPreview(packQty: 1, packCount: 1, unitCostFen: Fen(Limits.maxFen), baseline: nil, stockBefore: nil))
    }

    // MARK: 记进货：临时库存、outbox

    /// 5 条 × ¥400、原有 6 包 → 临时库存 56 包；outbox 的 stock_in 带件数和每条单价（不是包数和每包价）
    func testRecordCartonStockIn() throws {
        let db = try db(.family)
        let conv = try XCTUnwrap(db.lookup(barcode: Self.zhonghuaCarton))
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, 6)
        let si = try StockInPayload(entryId: uuid(0x19), conversion: conv, packCount: 5, unitCostFen: Fen(40000))
        try db.recordStockIn(si, name: conv.product.name, unitName: conv.barcode.unitName)
        XCTAssertEqual(try db.displayStock(conv.product.id)?.qty, 56)
        let item = try XCTUnwrap(try db.allOutbox().last)
        XCTAssertEqual(item.type, .stockIn)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: item.opJSON) as? [String: Any])
        let p = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(int64(p["pack_count"]), 5)
        XCTAssertEqual(int64(p["pack_qty"]), 10)
        XCTAssertEqual(int64(p["unit_cost_fen"]), 40000)
        XCTAssertEqual(p["barcode"] as? String, Self.zhonghuaCarton)
        XCTAssertNil(p["expiry_date"])
        XCTAssertEqual(OpsSchemaTests.validator.validate(try JV.parse(item.opJSON)), [])
        let e = try XCTUnwrap(try db.entries().first)
        XCTAssertEqual(e.type, .stockIn)
        XCTAssertEqual(e.qtyDelta, 50)
        XCTAssertEqual(e.amountFen.raw, 200000)
    }

    /// 管保质期的进货带到期日（服务器按它建批次，§5.4）
    func testStockInCarriesExpiryDate() throws {
        let db = try db(.family)
        let conv = try XCTUnwrap(db.lookup(barcode: Self.colaPack))
        let date = try CalendarDate("2026-11-12").adding(months: 6)
        try db.recordStockIn(try StockInPayload(entryId: uuid(0x20), conversion: conv, packCount: 3, unitCostFen: Fen(5500),
                                                expiryDate: date), name: conv.product.name, unitName: "箱")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(db.allOutbox().last).opJSON) as? [String: Any])
        XCTAssertEqual((obj["payload"] as? [String: Any])?["expiry_date"] as? String, "2027-05-12")
    }

    func testCashierCannotStockIn() throws {
        let db = try db(.cashier)
        let conv = try XCTUnwrap(db.lookup(barcode: Self.colaPack))
        let si = try StockInPayload(entryId: uuid(0x21), conversion: conv, packCount: 1, unitCostFen: Fen(4800))
        XCTAssertThrowsError(try db.recordStockIn(si, name: conv.product.name, unitName: "箱"))
        XCTAssertEqual(try db.allOutbox().filter { $0.type == .stockIn }.count, 0)
        XCTAssertTrue(try db.entries().isEmpty)
        XCTAssertNil(try db.displayStock(conv.product.id), "收银员没有库存基线")
    }

    // MARK: expiry.json：生产日期 + 保质期月数

    func testAddMonthsVectors() throws {
        let root = try XCTUnwrap(try loadJSON("contracts/vectors/expiry.json") as? [String: Any])
        let cases = try XCTUnwrap(root["add_months"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 2)
        for c in cases {
            let start = try CalendarDate(try XCTUnwrap(c["start"] as? String))
            let got = try start.adding(months: try XCTUnwrap(int64(c["months"])))
            XCTAssertEqual(got.description, c["expected"] as? String, c["id"] as? String ?? "?")
        }
        XCTAssertEqual(try CalendarDate("2026-11-12").adding(months: 6).description, "2027-05-12")
        XCTAssertInvalid(try CalendarDate("2026-11-12").adding(months: 0))
        XCTAssertInvalid(try CalendarDate("9999-06-01").adding(months: 12))
    }
}
