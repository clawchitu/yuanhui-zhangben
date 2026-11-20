import XCTest

/// 验收：金额类型没有任何浮点运算。扫描 ShopCore 全部源码（去掉注释），不许出现浮点类型。
final class NoFloatTests: XCTestCase {
    func testNoFloatingPointInShopCoreSources() throws {
        let banned = ["Double", "Float", "CGFloat", "Float32", "Float64", "Float80", "Decimal", "NSDecimalNumber", "NSNumber", "TimeInterval", "timeIntervalSince"]
        let fm = FileManager.default
        let files = try XCTUnwrap(fm.enumerator(atPath: shopCoreSources.path)).compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 5)
        for f in files {
            let text = try String(contentsOf: shopCoreSources.appendingPathComponent(f), encoding: .utf8)
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.components(separatedBy: "//").first ?? ""
                for word in banned where line.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                    XCTFail("\(f):\(n + 1) 出现浮点相关的 \(word)：\(raw)")
                }
                // 浮点字面量，如 0.5
                if line.range(of: "(?<![\\w.$\"])[0-9]+\\.[0-9]+(?![\\w\"])", options: .regularExpression) != nil,
                   !line.contains("\"") {
                    XCTFail("\(f):\(n + 1) 出现浮点字面量：\(raw)")
                }
            }
        }
    }
}
