/// 金额，单位「分」，64 位有符号整数（§5.0）。
/// 只提供整数构造和带溢出检查的运算，没有任何从浮点数构造或转成浮点数的入口。
public struct Fen: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let raw: Int64

    public init(_ raw: Int64) { self.raw = raw }

    public static let zero = Fen(0)

    public static func < (l: Fen, r: Fen) -> Bool { l.raw < r.raw }

    public func adding(_ o: Fen) throws -> Fen { Fen(try Checked.add(raw, o.raw)) }
    public func subtracting(_ o: Fen) throws -> Fen { Fen(try Checked.sub(raw, o.raw)) }
    public func multiplied(by n: Int64) throws -> Fen { Fen(try Checked.mul(raw, n)) }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    /// 「¥53.50」「-¥0.50」。纯整数拆分元和分，不经过浮点。
    public var yuanString: String {
        let neg = raw < 0
        // Int64.min 取不了绝对值，用 magnitude（UInt64）
        let m = raw.magnitude
        let yuan = m / 100
        let cents = m % 100
        let centsStr = cents < 10 ? "0\(cents)" : "\(cents)"
        return (neg ? "-¥" : "¥") + "\(yuan).\(centsStr)"
    }

    public var description: String { yuanString }
}
