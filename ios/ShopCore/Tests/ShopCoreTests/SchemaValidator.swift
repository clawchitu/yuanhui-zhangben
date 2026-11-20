import Foundation

/// 测试用的 JSON Schema（2020-12）校验器，只实现 `ops.schema.json` 用到的关键字；
/// 遇到不认识的关键字直接报错，避免静默放过。它自己的正确性由 contracts/examples 的正反例检验。
indirect enum JV {
    case object([String: JV]), array([JV]), string(String), int(Int64), double(Double), bool(Bool), null

    init(_ any: Any) {
        switch any {
        case let d as [String: Any]: self = .object(d.mapValues(JV.init))
        case let a as [Any]: self = .array(a.map(JV.init))
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.int64Value) }
        case is NSNull: self = .null
        default: fatalError("未知 JSON 值 \(any)")
        }
    }

    static func parse(_ data: Data) throws -> JV { JV(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    var typeNames: Set<String> {
        switch self {
        case .object: return ["object"]
        case .array: return ["array"]
        case .string: return ["string"]
        case .int: return ["integer", "number"]
        case .double(let d): return d == d.rounded() ? ["integer", "number"] : ["number"]
        case .bool: return ["boolean"]
        case .null: return ["null"]
        }
    }
}

extension JV: Equatable {
    static func == (l: JV, r: JV) -> Bool {
        switch (l, r) {
        case let (.object(a), .object(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

struct SchemaValidator {
    let root: [String: Any]

    static let annotations: Set<String> = ["$schema", "$id", "title", "description", "$comment", "examples", "$defs", "default"]
    static let known: Set<String> = annotations.union(["type", "properties", "required", "additionalProperties", "oneOf", "anyOf",
        "allOf", "not", "if", "then", "else", "$ref", "const", "enum", "minimum", "maximum", "minLength", "maxLength",
        "minItems", "maxItems", "items", "minProperties", "format"])

    /// 返回错误列表；空 = 通过
    func validate(_ v: JV) -> [String] { errors(v, root, "$") }

    private func resolve(_ ref: String) -> [String: Any] {
        precondition(ref.hasPrefix("#/"), "只支持本地引用 \(ref)")
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") { node = (node as! [String: Any])[String(part)]! }
        return node as! [String: Any]
    }

    private func num(_ v: JV) -> Double? {
        switch v { case .int(let i): return Double(i); case .double(let d): return d; default: return nil }
    }

    private func errors(_ v: JV, _ s: [String: Any], _ path: String) -> [String] {
        var e: [String] = []
        for k in s.keys where !Self.known.contains(k) { e.append("\(path): 校验器不认识关键字 \(k)") }

        if let ref = s["$ref"] as? String { e += errors(v, resolve(ref), path) }
        if let t = s["type"] {
            let allowed = Set((t as? [String]) ?? [t as! String])
            if allowed.isDisjoint(with: v.typeNames) { e.append("\(path): 类型应为 \(allowed)") }
        }
        if let c = s["const"], JV(c) != v { e.append("\(path): 应等于 \(c)") }
        if let en = s["enum"] as? [Any], !en.contains(where: { JV($0) == v }) { e.append("\(path): 不在枚举里") }
        if let n = num(v) {
            if let m = (s["minimum"] as? NSNumber)?.doubleValue, n < m { e.append("\(path): 小于 \(m)") }
            if let m = (s["maximum"] as? NSNumber)?.doubleValue, n > m { e.append("\(path): 大于 \(m)") }
            // 精确比较整数上限（double 在 2^53 以上会丢精度）
            if case .int(let i) = v {
                if let m = s["maximum"] as? NSNumber, !CFNumberIsFloatType(m), i > m.int64Value { e.append("\(path): 大于 \(m)") }
                if let m = s["minimum"] as? NSNumber, !CFNumberIsFloatType(m), i < m.int64Value { e.append("\(path): 小于 \(m)") }
            }
        }
        if case .string(let str) = v {
            let n = str.unicodeScalars.count
            if let m = s["minLength"] as? Int, n < m { e.append("\(path): 太短") }
            if let m = s["maxLength"] as? Int, n > m { e.append("\(path): 太长") }
            if let f = s["format"] as? String, !Self.checkFormat(f, str) { e.append("\(path): 不符合格式 \(f)") }
        }
        if case .array(let xs) = v {
            if let m = s["minItems"] as? Int, xs.count < m { e.append("\(path): 元素太少") }
            if let m = s["maxItems"] as? Int, xs.count > m { e.append("\(path): 元素太多") }
            if let items = s["items"] as? [String: Any] {
                for (i, x) in xs.enumerated() { e += errors(x, items, "\(path)[\(i)]") }
            }
        }
        if case .object(let o) = v {
            let props = s["properties"] as? [String: Any] ?? [:]
            for (k, sub) in props { if let x = o[k] { e += errors(x, sub as! [String: Any], "\(path).\(k)") } }
            for r in s["required"] as? [String] ?? [] where o[r] == nil { e.append("\(path): 缺 \(r)") }
            if let ap = s["additionalProperties"] as? Bool, !ap {
                for k in o.keys where props[k] == nil { e.append("\(path): 多余字段 \(k)") }
            }
            if let m = s["minProperties"] as? Int, o.count < m { e.append("\(path): 字段太少") }
        }
        if let all = s["allOf"] as? [[String: Any]] { for sub in all { e += errors(v, sub, path) } }
        if let any = s["anyOf"] as? [[String: Any]], !any.contains(where: { errors(v, $0, path).isEmpty }) {
            e.append("\(path): anyOf 一个都不满足")
        }
        if let one = s["oneOf"] as? [[String: Any]] {
            let ok = one.filter { errors(v, $0, path).isEmpty }.count
            if ok != 1 { e.append("\(path): oneOf 满足 \(ok) 个（应恰好 1 个）") }
        }
        if let not = s["not"] as? [String: Any], errors(v, not, path).isEmpty { e.append("\(path): 不应满足 not") }
        if let cond = s["if"] as? [String: Any] {
            if errors(v, cond, path).isEmpty {
                if let t = s["then"] as? [String: Any] { e += errors(v, t, path) }
            } else if let el = s["else"] as? [String: Any] { e += errors(v, el, path) }
        }
        return e
    }

    static func checkFormat(_ f: String, _ s: String) -> Bool {
        func matches(_ re: String) -> Bool { s.range(of: re, options: .regularExpression) != nil }
        switch f {
        case "uuid":
            return matches("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        case "date":
            return (try? CalendarDateProbe.valid(s)) == true
        case "date-time":
            guard matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$") else { return false }
            return (try? CalendarDateProbe.valid(String(s.prefix(10)))) == true
        default:
            return false   // 不认识的格式按失败处理
        }
    }
}

import ShopCore
enum CalendarDateProbe {
    static func valid(_ s: String) throws -> Bool { _ = try CalendarDate(s); return true }
}
