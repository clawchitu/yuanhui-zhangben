import XCTest
@testable import ShopCore

final class AllocationTests: XCTestCase {
    /// 验收：allocation.json 全部向量（含 53.50→53.00、多收、并列、1 分钱、全零购物篮、上限、超限被拒）
    func testAllocationVectors() throws {
        let root = try loadJSON("contracts/vectors/allocation.json") as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        var invalidCount = 0
        for c in cases {
            let id = c["id"] as! String
            let lines = (c["lines"] as! [[String: Any]]).map {
                Allocation.Line(unitPriceFen: int64($0["unit_price_fen"])!, packCount: int64($0["pack_count"])!,
                                packQty: int64($0["pack_qty"]) ?? 1)
            }
            let paid = int64(c["paid_total_fen"])!
            let expect = c["expect"] as! [String: Any]
            if let err = expect["error"] as? String {
                XCTAssertEqual(err, "invalid", id)
                XCTAssertInvalid(try Allocation.allocate(lines: lines, paidTotalFen: paid), id)
                invalidCount += 1
                continue
            }
            let r = try Allocation.allocate(lines: lines, paidTotalFen: paid)
            XCTAssertEqual(r.listFen, (expect["list_fen"] as! [Any]).map { int64($0)! }, "\(id) list_fen")
            XCTAssertEqual(r.listTotalFen, int64(expect["list_total_fen"])!, "\(id) list_total_fen")
            XCTAssertEqual(r.amountFen, (expect["amount_fen"] as! [Any]).map { int64($0)! }, "\(id) amount_fen")
            XCTAssertEqual(r.amountFen.reduce(0, +), paid, "\(id) Σa = P")
            XCTAssertTrue(r.amountFen.allSatisfy { $0 >= 0 }, "\(id) 各行不为负")
        }
        XCTAssertGreaterThan(invalidCount, 0)
    }

    /// 必过向量（设计稿 08）
    func testDesign08MustPass() throws {
        let r = try Allocation.allocate(lines: [.init(unitPriceFen: 2500, packCount: 1),
                                                .init(unitPriceFen: 2400, packCount: 1),
                                                .init(unitPriceFen: 450, packCount: 1)], paidTotalFen: 5300)
        XCTAssertEqual(r.amountFen, [2476, 2378, 446])
    }

    func testEmptyBasketRejected() {
        XCTAssertInvalid(try Allocation.allocate(lines: [], paidTotalFen: 0))
    }
}
