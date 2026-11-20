import XCTest
@testable import ShopCore

final class LimitsTests: XCTestCase {
    /// 验收：超出 §5.0 上限的输入在模型层被拒（limits.json 向量：进货总价、基本单位数量、单行金额）
    func testLimitsVectors() throws {
        let root = try loadJSON("contracts/vectors/limits.json") as! [String: Any]
        for c in root["cases"] as! [[String: Any]] {
            let id = c["id"] as! String
            let f = c["fields"] as! [String: Any]
            let ok = (c["expected"] as! String) == "ok"
            let build: () throws -> Void
            switch c["op_type"] as! String {
            case "stock_in":
                build = { _ = try StockInPayload(entryId: uuid(1), productId: uuid(2), barcode: "6900000000001",
                                                 packQty: int64(f["pack_qty"])!, packCount: int64(f["pack_count"])!,
                                                 unitCostFen: Fen(int64(f["unit_cost_fen"])!)) }
            case "sale_line":
                build = { _ = try SaleLine(entryId: uuid(1), productId: uuid(2), barcode: "6900000000001", name: "x",
                                           unitName: "个", packQty: int64(f["pack_qty"])!, packCount: int64(f["pack_count"])!,
                                           unitPriceFen: Fen(int64(f["unit_price_fen"])!)) }
            default:
                XCTFail("未知 op_type \(id)"); continue
            }
            if ok { XCTAssertNoThrow(try build(), id) } else { XCTAssertInvalid(try build(), id) }
        }
    }

    func testFieldLimitsRejectedAtModelLayer() throws {
        let p = uuid(2)
        // 单价、件数、换算、基本单位数量、实收
        XCTAssertInvalid(try Product(id: p, name: "x", priceFen: Fen(100_000_000)))
        XCTAssertInvalid(try Product(id: p, name: "x", priceFen: Fen(-1)))
        XCTAssertInvalid(try BarcodeRecord(barcode: "1", productId: p, packQty: 10_000, unitName: "箱", packPriceFen: Fen(1)))
        XCTAssertInvalid(try BarcodeRecord(barcode: "1", productId: p, packQty: 0, unitName: "箱"))
        XCTAssertInvalid(try BarcodeRecord(barcode: "1", productId: p, packQty: 1, unitName: "罐", packPriceFen: Fen(1)))
        XCTAssertInvalid(try SaleLine(entryId: uuid(1), productId: p, barcode: "1", name: "x", unitName: "个",
                                      packQty: 1, packCount: 100_000, unitPriceFen: Fen(1)))
        let line = try SaleLine(entryId: uuid(1), productId: p, barcode: "1", name: "x", unitName: "个",
                                packQty: 1, packCount: 1, unitPriceFen: Fen(99_999_999))
        XCTAssertNoThrow(try SaleBatchPayload(batchId: uuid(3), paidTotalFen: Fen(19_999_999_800), lines: [line]))
        XCTAssertInvalid(try SaleBatchPayload(batchId: uuid(3), paidTotalFen: Fen(19_999_999_801), lines: [line]))
        XCTAssertInvalid(try SaleBatchPayload(batchId: uuid(3), paidTotalFen: Fen(-1), lines: [line]))
        XCTAssertInvalid(try SaleBatchPayload(batchId: uuid(3), paidTotalFen: Fen(1), lines: Array(repeating: line, count: 201)))
        XCTAssertInvalid(try SaleBatchPayload(batchId: uuid(3), paidTotalFen: Fen(0), lines: []))
        // 盘点数、账面数、期初数、实际数、推迟天数
        XCTAssertInvalid(try CountPayload(entryId: uuid(1), productId: p, countedQty: 10_000_000, baseQty: 0, baseVer: 0))
        XCTAssertInvalid(try CountPayload(entryId: uuid(1), productId: p, countedQty: -1, baseQty: 0, baseVer: 0))
        XCTAssertNoThrow(try CountPayload(entryId: uuid(1), productId: p, countedQty: 0, baseQty: -9_999_999, baseVer: 0))
        XCTAssertInvalid(try CountPayload(entryId: uuid(1), productId: p, countedQty: 0, baseQty: -10_000_000, baseVer: 0))
        XCTAssertInvalid(try OpeningPayload(entryId: uuid(1), productId: p, countedQty: 10_000_000))
        XCTAssertInvalid(try OpeningPayload(entryId: uuid(1), productId: p, countedQty: 1, unitCostFen: Fen(100_000_000)))
        XCTAssertInvalid(try ExpiryDisposePayload(lotId: uuid(1), handleVer: 0, actualQty: 10_000_000, action: .discard, entryId: uuid(2)))
        XCTAssertInvalid(try LotSnoozePayload(lotId: uuid(1), handleVer: 0, actualQty: 1, days: 0))
        XCTAssertInvalid(try LotSnoozePayload(lotId: uuid(1), handleVer: 0, actualQty: 1, days: 366))
        XCTAssertInvalid(try ProductUpsertPayload.quick(productId: p, barcode: "", name: "x", priceFen: Fen(1)))
        XCTAssertInvalid(try ProductUpsertPayload.quick(productId: p, barcode: "1", name: String(repeating: "长", count: 201), priceFen: Fen(1)))
        XCTAssertInvalid(try ProductEditPayload(productId: p))     // 一个字段都不改
        XCTAssertInvalid(try CalendarDate("2026-02-29"))
        XCTAssertNoThrow(try CalendarDate("2028-02-29"))
        XCTAssertInvalid(try CalendarDate("2026-1-05"))
    }
}
