/// 带溢出检查的 Int64 运算（§5.0：手机端乘法一律带溢出检查，溢出按无效输入处理）。
/// 本包所有金额、数量的乘加都走这里，不用 `*` / `+` 直接算，更不碰浮点。
public enum Checked {
    public static func mul(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        if o { throw invalid("乘法溢出：\(a) × \(b)") }
        return r
    }

    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        if o { throw invalid("加法溢出：\(a) + \(b)") }
        return r
    }

    public static func sub(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (r, o) = a.subtractingReportingOverflow(b)
        if o { throw invalid("减法溢出：\(a) − \(b)") }
        return r
    }

    public static func sum<S: Sequence>(_ xs: S) throws -> Int64 where S.Element == Int64 {
        try xs.reduce(0) { try add($0, $1) }
    }
}

/// `roundDiv(a, b)`（§5.0，规则）：`b > 0`，四舍五入到整数，恰好一半时远离零；
/// 负数对称：`roundDiv(−a, b) = −roundDiv(a, b)`。只用整数运算，任何 Int64 输入都不溢出。
public func roundDiv(_ a: Int64, _ b: Int64) throws -> Int64 {
    guard b > 0 else { throw invalid("roundDiv 的除数必须为正：\(b)") }
    let q = a / b          // 向零截断
    let r = a % b          // 与 a 同号，|r| < b
    let absR = r < 0 ? -r : r   // |r| < b ≤ Int64.max，不会溢出
    // 2|r| >= b  ⇔  |r| >= b − |r|（这样写避免 2|r| 溢出）
    if absR >= b - absR {
        return a < 0 ? q - 1 : q + 1   // |q| ≤ |a|/b，b ≥ 2 时 ±1 不会溢出；b = 1 时 r = 0 不进这里
    }
    return q
}
