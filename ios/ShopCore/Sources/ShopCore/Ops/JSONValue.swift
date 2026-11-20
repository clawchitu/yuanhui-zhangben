import Foundation

/// 编码 op 用的 JSON 值。**只有整数，没有浮点**（§5.0：JSON 里金额和数量都是整数，不带小数点）。
/// 对象保持字段的声明顺序，输出是确定的（同一个 op 每次编码字节相同，重发时 payload 哈希不变）。
public indirect enum JSONValue: Hashable, Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null

    public static func == (l: JSONValue, r: JSONValue) -> Bool {
        switch (l, r) {
        case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    public func hash(into h: inout Hasher) { h.combine(serialized()) }

    public func serialized() -> String {
        var out = ""
        write(&out)
        return out
    }

    public func data() -> Data { Data(serialized().utf8) }

    private func write(_ out: inout String) {
        switch self {
        case .object(let kv):
            out += "{"
            for (i, (k, v)) in kv.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(k, &out); out += ":"; v.write(&out)
            }
            out += "}"
        case .array(let xs):
            out += "["
            for (i, v) in xs.enumerated() { if i > 0 { out += "," }; v.write(&out) }
            out += "]"
        case .string(let s): Self.writeString(s, &out)
        case .int(let n): out += String(n)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    private static func writeString(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

/// 拼对象时省掉 nil 字段的小工具。
struct JSONObjectBuilder {
    var fields: [(String, JSONValue)] = []
    mutating func put(_ k: String, _ v: JSONValue) { fields.append((k, v)) }
    mutating func put(_ k: String, _ v: UUID) { fields.append((k, .string(v.uuidString.lowercased()))) }
    mutating func put(_ k: String, _ v: String) { fields.append((k, .string(v))) }
    mutating func put(_ k: String, _ v: Int64) { fields.append((k, .int(v))) }
    mutating func put(_ k: String, _ v: Fen) { fields.append((k, .int(v.raw))) }
    mutating func put(_ k: String, _ v: Bool) { fields.append((k, .bool(v))) }
    mutating func put(_ k: String, _ v: CalendarDate) { fields.append((k, .string(v.description))) }
    mutating func putIfPresent(_ k: String, _ v: Int64?) { if let v { put(k, v) } }
    mutating func putIfPresent(_ k: String, _ v: Fen?) { if let v { put(k, v) } }
    mutating func putIfPresent(_ k: String, _ v: Bool?) { if let v { put(k, v) } }
    mutating func putIfPresent(_ k: String, _ v: String?) { if let v { put(k, v) } }
    mutating func putIfPresent(_ k: String, _ v: CalendarDate?) { if let v { put(k, v) } }
    var value: JSONValue { .object(fields) }
}
