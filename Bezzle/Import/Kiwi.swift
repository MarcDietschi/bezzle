import Foundation

/// Reads Kiwi, the compact binary format Figma keeps a design in. A file brings the schema it was
/// written with, so every field is read as the version of Figma that wrote it meant it.
nonisolated enum Kiwi {
    enum Failure: Error, LocalizedError {
        /// What is damaged, in words.
        case damaged(LocalizedStringResource)

        var errorDescription: String? {
            switch self {
            case .damaged(let what): String(localized: "The design data is damaged: \(String(localized: what)).")
            }
        }
    }

    /// A value as the schema types it. Every kind of whole number is an `int`.
    indirect enum Value {
        case bool(Bool)
        case int(Int)
        case float(Double)
        case string(String)
        case bytes(Data)
        /// One of an enum's cases, by its name.
        case name(String)
        case object(Object)
        case array([Value])

        var number: Double? {
            switch self {
            case .int(let i): Double(i)
            case .float(let f): f
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }

        var int: Int? {
            switch self {
            case .int(let i): i
            case .float(let f): f.isFinite && abs(f) < 1e15 ? Int(f) : nil
            default: nil
            }
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        /// A string, or the name of an enum's case.
        var string: String? {
            switch self {
            case .string(let s), .name(let s): s
            default: nil
            }
        }

        var data: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }

        var object: Object? {
            if case .object(let o) = self { return o }
            return nil
        }

        var array: [Value] {
            if case .array(let a) = self { return a }
            return []
        }

        var objects: [Object] { array.compactMap(\.object) }
    }

    /// A message or a struct: the fields it has, each by its number in its type.
    struct Object {
        let type: Definition
        var fields: [(id: Int, value: Value)]

        subscript(name: String) -> Value? {
            guard let id = type.ids[name] else { return nil }
            return fields.first { $0.id == id }?.value
        }

        /// The same, with the fields `other` has laid over its own, other than those named.
        /// Both are of the one type.
        func merged(with other: Object, except: Set<String> = []) -> Object {
            guard other.type === type else { return self }
            var out = self
            for field in other.fields {
                if !except.isEmpty, let name = type.names[field.id], except.contains(name) { continue }
                if let i = out.fields.firstIndex(where: { $0.id == field.id }) {
                    out.fields[i].value = field.value
                } else {
                    out.fields.append(field)
                }
            }
            return out
        }

        /// The same with one field set, or taken away when `value` is nil. Nothing changes if the
        /// type has no such field.
        func setting(_ name: String, _ value: Value?) -> Object {
            guard let id = type.ids[name] else { return self }
            var out = self
            out.fields.removeAll { $0.id == id }
            if let value { out.fields.append((id, value)) }
            return out
        }
    }

    /// One type of the schema: an enum, a struct, whose fields are all there in order, or a
    /// message, which has only some of its fields, each tagged with its number.
    final class Definition {
        enum Kind: UInt8 { case enumeration = 0, structure = 1, message = 2 }

        struct Field {
            let name: String
            /// The index of its type in the schema, or below 0 for a plain value: -1 is a bool,
            /// then byte, int, uint, float, string, int64 and uint64.
            let type: Int
            let array: Bool
            /// A message's field number, or an enum case's value.
            let value: Int
        }

        let name: String
        let kind: Kind
        let fields: [Field]
        /// Each field's id: its number in a message, its place in a struct.
        let ids: [String: Int]
        /// The other way round: each field's name by its id, or each enum case's by its value.
        let names: [Int: String]
        /// For messages, where each field is in `fields`, by its number.
        let places: [Int: Int]

        init(name: String, kind: Kind, fields: [Field]) {
            self.name = name
            self.kind = kind
            self.fields = fields
            var ids: [String: Int] = [:], names: [Int: String] = [:], places: [Int: Int] = [:]
            for (i, f) in fields.enumerated() {
                let id = kind == .structure ? i : f.value
                ids[f.name] = id
                names[id] = f.name
                places[f.value] = i
            }
            self.ids = ids
            self.names = names
            self.places = places
        }
    }

    struct Schema {
        let definitions: [Definition]

        init(_ data: Data) throws {
            var r = Reader(data)
            let count = try r.count()
            var definitions: [Definition] = []
            for _ in 0..<count {
                let name = try r.string()
                guard let kind = Definition.Kind(rawValue: try r.byte()) else { throw Failure.damaged("the kind of \(name)") }
                var fields: [Definition.Field] = []
                for _ in 0..<(try r.count()) {
                    let field = try r.string()
                    let type = try r.int32()
                    let array = try r.byte() != 0
                    let value = try r.varint()
                    fields.append(Definition.Field(name: field, type: Int(type), array: array, value: Int(truncatingIfNeeded: value)))
                }
                definitions.append(Definition(name: name, kind: kind, fields: fields))
            }
            for d in definitions {
                for f in d.fields where f.type >= definitions.count || f.type < -8 {
                    throw Failure.damaged("the type of \(d.name).\(f.name)")
                }
            }
            self.definitions = definitions
        }

        /// The message of the type named `root` that `data` holds.
        func read(_ data: Data, as root: String) throws -> Object {
            guard let type = definitions.firstIndex(where: { $0.name == root && $0.kind == .message }) else {
                throw Failure.damaged("there is no \(root) in its schema")
            }
            var r = Reader(data)
            guard let message = try r.value(type, array: false, in: definitions, depth: 0).object else { throw Failure.damaged(.verbatim(root)) }
            return message
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var p = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        /// Nested deeper than this, a file is taken to be damaged rather than run the stack out.
        private static let deepest = 100

        mutating func byte() throws -> UInt8 {
            guard p < bytes.count else { throw Failure.damaged("it ends too soon") }
            defer { p += 1 }
            return bytes[p]
        }

        /// Seven bits to a byte, the lowest first, as long as the top bit is set.
        mutating func varint() throws -> UInt64 {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let b = try byte()
                if shift < 64 { v |= UInt64(b & 0x7F) << shift }
                if b < 0x80 { return v }
                shift += 7
                guard shift < 70 else { throw Failure.damaged("a number runs on") }
            }
        }

        /// Signed numbers fold into unsigned ones: 0, -1, 1, -2…
        mutating func int32() throws -> Int32 {
            let v = UInt32(truncatingIfNeeded: try varint())
            return Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
        }

        mutating func int64() throws -> Int64 {
            let v = try varint()
            return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
        }

        /// Zero is one byte; any other float is its four bytes with the exponent moved to the front.
        mutating func float() throws -> Float {
            let first = try byte()
            guard first != 0 else { return 0 }
            guard p + 3 <= bytes.count else { throw Failure.damaged("it ends too soon") }
            let bits = UInt32(first) | UInt32(bytes[p]) << 8 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 24
            p += 3
            return Float(bitPattern: bits << 23 | bits >> 9)
        }

        mutating func string() throws -> String {
            guard let end = bytes[p...].firstIndex(of: 0) else { throw Failure.damaged("a string runs on") }
            defer { p = end + 1 }
            return String(decoding: bytes[p..<end], as: UTF8.self)
        }

        /// How many of something follow, no more than there are bytes left for.
        mutating func count() throws -> Int {
            let n = try varint()
            guard n <= UInt64(bytes.count - p) else { throw Failure.damaged("a list is longer than the file") }
            return Int(n)
        }

        mutating func value(_ type: Int, array: Bool, in schema: [Definition], depth: Int) throws -> Value {
            if array {
                let n = try count()
                if type == -2 {
                    defer { p += n }
                    return .bytes(Data(bytes[p..<(p + n)]))
                }
                var out: [Value] = []
                out.reserveCapacity(n)
                for _ in 0..<n { out.append(try value(type, array: false, in: schema, depth: depth)) }
                return .array(out)
            }
            switch type {
            case -1: return .bool(try byte() != 0)
            case -2: return .int(Int(try byte()))
            case -3: return .int(Int(try int32()))
            case -4: return .int(Int(UInt32(truncatingIfNeeded: try varint())))
            case -5: return .float(Double(try float()))
            case -6: return .string(try string())
            case -7: return .int(Int(try int64()))
            case -8: return .int(Int(truncatingIfNeeded: try varint()))
            default: break
            }
            guard depth < Self.deepest else { throw Failure.damaged("it is nested too deep") }
            let d = schema[type]
            switch d.kind {
            case .enumeration:
                let v = Int(truncatingIfNeeded: try varint())
                guard let name = d.names[v] else { throw Failure.damaged("\(d.name) has no case \(v)") }
                return .name(name)
            case .structure:
                var fields: [(id: Int, value: Value)] = []
                fields.reserveCapacity(d.fields.count)
                for (i, f) in d.fields.enumerated() {
                    fields.append((i, try value(f.type, array: f.array, in: schema, depth: depth + 1)))
                }
                return .object(Object(type: d, fields: fields))
            case .message:
                var fields: [(id: Int, value: Value)] = []
                while true {
                    let id = Int(truncatingIfNeeded: try varint())
                    if id == 0 { break }
                    guard let i = d.places[id] else { throw Failure.damaged("\(d.name) has no field \(id)") }
                    let f = d.fields[i]
                    fields.append((id, try value(f.type, array: f.array, in: schema, depth: depth + 1)))
                }
                return .object(Object(type: d, fields: fields))
            }
        }
    }
}
