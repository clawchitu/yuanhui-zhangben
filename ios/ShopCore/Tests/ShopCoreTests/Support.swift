import Foundation
import XCTest
@testable import ShopCore

/// 仓库根目录（测试直接读 contracts/，不复制一份；模拟器上的测试进程也能访问本机文件）。
let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ShopCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // ShopCore
    .deletingLastPathComponent() // ios
    .deletingLastPathComponent() // 仓库根

let shopCoreSources = repoRoot.appendingPathComponent("ios/ShopCore/Sources/ShopCore")

func loadJSON(_ relative: String) throws -> Any {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent(relative))
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// JSON 里的整数（向量文件只有整数）
func int64(_ any: Any?) -> Int64? {
    guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
    return n.int64Value
}

func uuid(_ n: Int) -> UUID {
    let hex = String(n, radix: 16)
    return UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - hex.count) + hex)!
}

func XCTAssertInvalid<T>(_ expr: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expr(), message, file: file, line: line) { err in
        guard case ShopCoreError.invalid = err else {
            return XCTFail("期望 invalid，得到 \(err) \(message)", file: file, line: line)
        }
    }
}

/// 固定种子的随机数（测试工作负载可复现）
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
