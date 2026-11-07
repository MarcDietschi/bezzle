import Foundation

// Copied from Bezzle/MCP/JSONValue.swift for the AI server on Windows (MCPServer.swift here).

/// JSON as the AI server writes it, its keys in the order given, so that a layer's id and name
/// come before all it holds. What comes in is read with `JSONSerialization` instead.
nonisolated enum JSONValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    /// What `JSONSerialization` read, as JSON again.
    init(_ value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let n as NSNumber: self = n.isBoolean ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue($0) })
        case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, JSONValue(d[$0])) })
        default: self = .string(String(describing: value!))
        }
    }

    /// A value worth writing: not null, an empty list or an empty object.
    var isEmpty: Bool {
        switch self {
        case .null: true
        case .array(let a): a.isEmpty
        case .object(let o): o.isEmpty
        default: false
        }
    }

    var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    var data: Data { Data(text.utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let v): out += Self.number(v)
        case .string(let s): Self.quote(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, (key, value)) in pairs.enumerated() {
                if i > 0 { out += "," }
                Self.quote(key, into: &out)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        }
    }

    /// Whole numbers without a point, others to four places.
    private static func number(_ v: Double) -> String {
        guard v.isFinite else { return "null" }
        let r = (v * 10000).rounded() / 10000
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        return String(r)
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
    init(nilLiteral: ()) { self = .null }
}

nonisolated extension JSONValue {
    // CGFloat is Double here, which `.number` takes as it is.
    static func number(_ v: Int) -> JSONValue { .number(Double(v)) }

    /// An object of only the pairs worth writing.
    static func compact(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        .object(pairs.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } })
    }
}

nonisolated extension NSNumber {
    /// Whether JSON had true or false here, rather than a number: the two read alike otherwise.
    /// Foundation here keeps a Bool as a number of one byte, which JSON's numbers never are.
    var isBoolean: Bool {
        let type = String(cString: objCType)
        return type == "c" || type == "B"
    }
}
