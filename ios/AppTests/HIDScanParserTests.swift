import XCTest
@testable import YuanhuiZhangben

/// S14 验收：一串数字 + 回车 = 恰好一次扫码；慢速逐个按键不算扫码；扫码枪每次扣扳机都算。
final class HIDScanParserTests: XCTestCase {
    /// 按扫码枪的速度打一串字符再回车，返回途中凑出的所有扫码
    private func type(_ text: String, into p: inout HIDScanParser, from start: TimeInterval = 100,
                      gap: TimeInterval = 0.01, enter: Bool = true) -> (scans: [String], end: TimeInterval) {
        var t = start
        var out: [String] = []
        for c in text {
            if let s = p.feed(.character(c), at: t) { out.append(s) }
            t += gap
        }
        if enter, let s = p.feed(.enter, at: t) { out.append(s) }
        return (out, t)
    }

    func testDigitsThenEnterIsExactlyOneScan() {
        var p = HIDScanParser()
        let r = type("6921168509256", into: &p)
        XCTAssertEqual(r.scans, ["6921168509256"])
        // 回车之后什么都没攒着：再来一个回车不会重复出码
        XCTAssertNil(p.feed(.enter, at: r.end + 0.01))
        XCTAssertEqual(p.buffer, "")
    }

    func testEachCharacterProducesNothingUntilEnter() {
        var p = HIDScanParser()
        let r = type("6921168509256", into: &p, enter: false)
        XCTAssertEqual(r.scans, [])
        XCTAssertEqual(p.buffer, "6921168509256")
    }

    func testAllBarcodeLengths() {
        for code in ["123456", "69012345", "6921168509256", "16921168509253", "ABC-123".filter { $0 != "-" } + "45"] {
            var p = HIDScanParser()
            XCTAssertEqual(type(code, into: &p).scans, [code], code)
        }
    }

    func testSlowKeyByKeyTypingIsNotAScan() {
        var p = HIDScanParser()
        // 人手逐个按：每键 0.3 秒
        XCTAssertEqual(type("6921168509256", into: &p, gap: 0.3).scans, [])
        // 稍快一点的人手（每键 0.12 秒）也不算
        XCTAssertEqual(type("6921168509256", into: &p, from: 200, gap: 0.12).scans, [])
    }

    func testFastDigitsButSlowEnterIsNotAScan() {
        var p = HIDScanParser()
        let r = type("6921168509256", into: &p, enter: false)
        XCTAssertNil(p.feed(.enter, at: r.end + 0.5))
    }

    func testPauseInTheMiddleDiscardsTheFirstPart() {
        var p = HIDScanParser()
        _ = type("692116", into: &p, enter: false)          // 前半截
        let r = type("8509256", into: &p, from: 101)         // 停了约 1 秒后的后半截
        XCTAssertEqual(r.scans, ["8509256"])                  // 只认停顿之后那一串（≥ 6 位）
        var q = HIDScanParser()
        _ = type("69211685", into: &q, enter: false)
        XCTAssertEqual(type("925", into: &q, from: 101).scans, [], "停顿后不够 6 位，不算")
    }

    func testTooShortIsNotAScan() {
        var p = HIDScanParser()
        XCTAssertEqual(type("12345", into: &p).scans, [])
        XCTAssertEqual(type("", into: &p, from: 300).scans, [], "只按回车")
    }

    func testUnknownKeyClearsTheBuffer() {
        var p = HIDScanParser()
        _ = type("692116", into: &p, enter: false)
        XCTAssertNil(p.feed(.other, at: 100.07))
        XCTAssertEqual(type("850", into: &p, from: 100.08).scans, [])
        XCTAssertNil(p.feed(.character(" "), at: 200))
        XCTAssertEqual(p.buffer, "")
        XCTAssertNil(p.feed(.character("号"), at: 200.01))
        XCTAssertEqual(p.buffer, "")
    }

    /// 扫码枪不去重：同一个码连扣两次扳机 = 两次扫码
    func testEveryTriggerCountsEvenTheSameCode() {
        var p = HIDScanParser()
        var t: TimeInterval = 100
        var scans: [String] = []
        for _ in 0..<3 {
            let r = type("6921168509256", into: &p, from: t)
            scans += r.scans
            t = r.end + 0.2   // 两次扣扳机之间 0.2 秒
        }
        XCTAssertEqual(scans, Array(repeating: "6921168509256", count: 3))
    }

    /// 两次扫码之间没有停顿（扫码枪缓存里一口气发出两个码）也是两次
    func testBackToBackScansWithoutPause() {
        var p = HIDScanParser()
        let a = type("6921168509256", into: &p)
        let b = type("6901028075831", into: &p, from: a.end + 0.01)
        XCTAssertEqual(a.scans + b.scans, ["6921168509256", "6901028075831"])
    }

    func testBluetoothJitterWithinGapStillScans() {
        var p = HIDScanParser()
        var t: TimeInterval = 50
        let gaps: [TimeInterval] = [0, 0.001, 0.07, 0.002, 0.06, 0.0, 0.03, 0.075, 0.01, 0.0, 0.05, 0.02, 0.01]
        for (c, g) in zip("6921168509256", gaps) {
            t += g
            XCTAssertNil(p.feed(.character(c), at: t))
        }
        XCTAssertEqual(p.feed(.enter, at: t + 0.04), "6921168509256")
    }

    func testOverlongInputIsDropped() {
        var p = HIDScanParser()
        XCTAssertEqual(type(String(repeating: "1", count: 60), into: &p).scans, [])
    }

    func testTimeGoingBackwardsResets() {
        var p = HIDScanParser()
        _ = type("692116", into: &p, from: 100, enter: false)
        XCTAssertEqual(type("850925", into: &p, from: 10).scans, ["850925"])
    }
}
