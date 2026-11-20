import XCTest
@testable import ShopCore

final class RoundDivTests: XCTestCase {
    /// 验收：rounddiv.json 全部向量通过
    func testRoundDivVectors() throws {
        let root = try loadJSON("contracts/vectors/rounddiv.json") as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 29)
        for c in cases {
            let id = c["id"] as! String
            let factors = (c["numerator_factors"] as! [Any]).map { int64($0)! }
            // 因子乘积可能接近 2^63，用带溢出检查的乘法
            let a = try factors.dropFirst().reduce(factors[0]) { try Checked.mul($0, $1) }
            let b = int64(c["b"])!
            XCTAssertEqual(try roundDiv(a, b), int64(c["expected"])!, id)
        }
    }

    func testSymmetricAndHalfAwayFromZero() throws {
        for a in Int64(-300)...300 {
            for b in Int64(1)...13 {
                let r = try roundDiv(a, b)
                XCTAssertEqual(r, -(try roundDiv(-a, b)), "\(a)/\(b) 对称")
                // |a − r·b| ≤ b/2，且恰好一半时远离零
                let diff2 = 2 * (a - r * b)
                XCTAssertLessThanOrEqual(abs(diff2), b, "\(a)/\(b)")
                if abs(diff2) == b { XCTAssertTrue(a > 0 ? diff2 < 0 : diff2 > 0, "\(a)/\(b) 一半远离零") }
            }
        }
    }

    func testExtremesDoNotOverflow() throws {
        XCTAssertEqual(try roundDiv(.max, 1), .max)
        XCTAssertEqual(try roundDiv(.min, 1), .min)
        XCTAssertEqual(try roundDiv(.max, .max), 1)
        XCTAssertEqual(try roundDiv(.min + 1, .max), -1)
        XCTAssertEqual(try roundDiv(.max, 2), Int64.max / 2 + 1)   // x.5 → 远离零
        XCTAssertInvalid(try roundDiv(1, 0))
        XCTAssertInvalid(try roundDiv(1, -3))
    }

    /// 验收：乘法带溢出检查，溢出按无效输入处理（§5.0）
    func testCheckedArithmeticRejectsOverflow() {
        XCTAssertInvalid(try Checked.mul(.max, 2))
        XCTAssertInvalid(try Checked.mul(3_037_000_500, 3_037_000_500))   // 刚过 2^63
        XCTAssertNoThrow(try Checked.mul(3_037_000_499, 3_037_000_499))
        XCTAssertInvalid(try Checked.add(.max, 1))
        XCTAssertInvalid(try Checked.sub(.min, 1))
        XCTAssertInvalid(try Fen(.max).multiplied(by: 2))
    }

    func testFenFormattingIsIntegerOnly() {
        XCTAssertEqual(Fen(5350).yuanString, "¥53.50")
        XCTAssertEqual(Fen(5).yuanString, "¥0.05")
        XCTAssertEqual(Fen(0).yuanString, "¥0.00")
        XCTAssertEqual(Fen(-50).yuanString, "-¥0.50")
        XCTAssertEqual(Fen(19_999_999_800).yuanString, "¥199999998.00")
        XCTAssertEqual(Fen(.min).yuanString, "-¥92233720368547758.08")
    }
}
