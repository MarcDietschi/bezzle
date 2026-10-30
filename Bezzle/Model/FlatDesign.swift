import Foundation
import CoreGraphics

/// One property of a layer as JSON holds it, so it can be kept, compared and sent on its own.
nonisolated enum FieldValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FieldValue])
    case object([String: FieldValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FieldValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FieldValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(FieldValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// The same everywhere, to choose between two values when nothing else tells them apart.
    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// One property of a layer that changes on its own: two people changing different properties of
/// the same layer both keep their change. Every stored property of `Node` but its id and what it
/// holds is one; a test makes sure none is forgotten.
// Unchecked: it holds nothing but closures over key paths, set once and never changed.
nonisolated struct LayerField: @unchecked Sendable {
    let name: String
    let same: (Node, Node) -> Bool
    let copy: (inout Node, Node) -> Void
    let write: (inout Node, FieldValue) throws -> Void

    init<T: Codable & Equatable>(_ name: String, _ key: WritableKeyPath<Node, T>) {
        self.name = name
        same = { $0[keyPath: key] == $1[keyPath: key] }
        copy = { $0[keyPath: key] = $1[keyPath: key] }
        write = { node, value in node[keyPath: key] = try value.decoded(as: T.self) }
    }

    static let all: [LayerField] = [
        LayerField("kind", \.kind), LayerField("name", \.name), LayerField("frame", \.frame),
        LayerField("rotation", \.rotation), LayerField("fill", \.fill), LayerField("border", \.border),
        LayerField("shadow", \.shadow), LayerField("opacity", \.opacity), LayerField("cornerRadius", \.cornerRadius),
        LayerField("corners", \.corners), LayerField("cornerSmoothing", \.cornerSmoothing), LayerField("rising", \.rising),
        LayerField("text", \.text), LayerField("style", \.style), LayerField("path", \.path),
        LayerField("pathBox", \.pathBox), LayerField("evenOdd", \.evenOdd), LayerField("mask", \.mask),
        LayerField("blur", \.blur), LayerField("blend", \.blend), LayerField("hidden", \.hidden),
        LayerField("locked", \.locked), LayerField("clips", \.clips), LayerField("slideSize", \.slideSize),
    ]

    /// Each property of a layer, without what it holds, read all at once.
    static func values(of node: Node) -> [String: FieldValue]? {
        var n = node
        n.children = []
        guard case .object(let read)? = try? FieldValue(encoding: n) else { return nil }
        var values: [String: FieldValue] = [:]
        for field in all { values[field.name] = read[field.name] ?? .null }
        return values
    }

    /// The layer these properties make. Any that cannot be read, such as one from a later Bezzle,
    /// is left as a new layer of its kind has it.
    static func node(_ id: UUID, from values: [String: FieldValue]) -> Node {
        var whole = values
        whole["id"] = .string(id.uuidString)
        whole["children"] = .array([])
        if let node = try? FieldValue.object(whole).decoded(as: Node.self) { return node }
        let kind = values["kind"].flatMap { try? $0.decoded(as: Node.Kind.self) } ?? .rectangle
        var node = Node(kind: kind, frame: .zero)
        node.id = id
        for field in all { if let v = values[field.name] { try? field.write(&node, v) } }
        return node
    }
}

/// Every layer of a design by its id: what it lies in, and the layer itself without what it holds,
/// its frame on its artboard (or the canvas) however deep in groups it lies. A group's frame
/// follows from what it holds, and fitting it again moves what it holds the other way; kept like
/// this, a layer in a group stays put on its artboard through that, so one person's change to a
/// group never moves a layer someone else put somewhere in it.
nonisolated struct FlatDesign: Equatable {
    struct Entry: Equatable {
        var parent: UUID?
        var node: Node
    }

    var entries: [UUID: Entry] = [:]
    /// What each artboard and group holds, and the canvas under nil, bottom first.
    var order: [UUID?: [UUID]] = [:]

    init() {}

    init(_ doc: BezzleDocument) {
        add(doc.nodes, in: nil, at: nil)
    }

    private mutating func add(_ nodes: [Node], in parent: UUID?, at origin: CGPoint?) {
        order[parent] = nodes.map(\.id)
        for node in nodes {
            var n = node
            n.children = []
            if let origin { n.frame.origin = n.frame.origin + origin }
            if n.isGroup, let mask = n.mask { n.mask = mask.map { Self.moved($0, by: n.frame.origin) } }
            entries[node.id] = Entry(parent: parent, node: n)
            if !node.children.isEmpty { add(node.children, in: node.id, at: node.isGroup ? n.frame.origin : nil) }
        }
    }

    /// The design these layers make, its groups fitted around what they hold.
    func document() -> BezzleDocument {
        var doc = BezzleDocument()
        var built = Set<UUID>()
        doc.nodes = (order[nil] ?? []).compactMap { build($0, at: nil, &built) }
        doc.fitGroups()
        doc.fitCarousels()
        return doc
    }

    private func build(_ id: UUID, at origin: CGPoint?, _ built: inout Set<UUID>) -> Node? {
        guard let entry = entries[id], built.insert(id).inserted else { return nil }
        var n = entry.node
        let board = n.frame.origin
        if let origin { n.frame.origin = n.frame.origin - origin }
        if n.isGroup, let mask = n.mask { n.mask = mask.map { Self.moved($0, by: CGPoint.zero - board) } }
        n.children = (order[id] ?? []).compactMap { build($0, at: n.isGroup ? board : nil, &built) }
        return n
    }

    private static func moved(_ node: Node, by d: CGPoint) -> Node {
        var n = node
        n.frame.origin = n.frame.origin + d
        return n
    }

    private func index(of id: UUID) -> Int {
        guard let entry = entries[id] else { return 0 }
        return order[entry.parent]?.firstIndex(of: id) ?? 0
    }

    private func depth(of id: UUID) -> Int {
        var depth = 0
        var parent = entries[id]?.parent
        while let p = parent, depth < 64 {
            depth += 1
            parent = entries[p]?.parent
        }
        return depth
    }

    /// Takes a layer out of where it lies, and puts it into `parent` just above `below`, or at the bottom.
    /// Whether `id` is `other` or lies somewhere inside it.
    private func isWithin(_ id: UUID, _ other: UUID) -> Bool {
        var at: UUID? = id
        var steps = 0
        while let a = at, steps < 64 {
            if a == other { return true }
            at = entries[a]?.parent
            steps += 1
        }
        return false
    }

    private mutating func move(_ id: UUID, to parent: UUID?, above below: UUID?) {
        if let entry = entries[id] { order[entry.parent]?.removeAll { $0 == id } }
        var list = order[parent] ?? []
        list.removeAll { $0 == id }
        let at = below.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        list.insert(id, at: at)
        order[parent] = list
        entries[id]?.parent = parent
    }

    private mutating func remove(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        order[entry.parent]?.removeAll { $0 == id }
        for child in order.removeValue(forKey: id) ?? [] { remove(child) }
    }
}

extension FlatDesign {
    /// The changes that lead from `from` to `to`, made to `onto`, which others may have changed
    /// since. A property someone else changed afterwards is left as they made it, and a layer
    /// someone else took away stays away; everything else the change did, it does. With nothing
    /// changed since, this is `to` itself. Undo goes through here, so it only ever takes back
    /// what was done on this Mac.
    static func apply(from: BezzleDocument, to: BezzleDocument, onto: BezzleDocument) -> BezzleDocument {
        if onto == from { return to }
        var result = FlatDesign(onto).applying(from: FlatDesign(from), to: FlatDesign(to)).document()
        result.viewport = onto.viewport
        return result
    }

    func applying(from x: FlatDesign, to y: FlatDesign) -> FlatDesign {
        var out = self
        var toPlace: [UUID] = []
        for (id, ey) in y.entries {
            if let ex = x.entries[id] {
                guard var ec = out.entries[id] else { continue }
                if ex.node != ey.node {
                    for field in LayerField.all where !field.same(ex.node, ey.node) && field.same(ec.node, ex.node) {
                        field.copy(&ec.node, ey.node)
                    }
                    out.entries[id] = ec
                }
                if ex.parent != ey.parent && ec.parent == ex.parent { toPlace.append(id) }
            } else if out.entries[id] == nil {
                out.entries[id] = Entry(parent: ey.parent, node: ey.node)
                toPlace.append(id)
            }
        }
        // Layers moved among the others in the same list, as the longest run left in order tells.
        for (parent, ys) in y.order {
            guard let xs = x.order[parent], xs != ys else { continue }
            var positions: [UUID: Int] = [:]
            for (i, id) in xs.enumerated() { positions[id] = i }
            let common = ys.filter { positions[$0] != nil }
            let kept = longestRise(common.map { positions[$0]! }, less: <)
            for (i, id) in common.enumerated() where !kept.contains(i) && out.entries[id]?.parent == parent {
                toPlace.append(id)
            }
        }
        // Each goes back just above the layer it was above, if that is still there; what holds
        // it goes back before it does.
        for id in toPlace.sorted(by: { (y.depth(of: $0), y.index(of: $0)) < (y.depth(of: $1), y.index(of: $1)) }) {
            guard let ey = y.entries[id] else { continue }
            let parent = ey.parent.flatMap { out.entries[$0] == nil ? nil : $0 }
            // Never into itself, which others moving things meanwhile could otherwise make.
            if let parent, out.isWithin(parent, id) { continue }
            let siblings = y.order[ey.parent] ?? []
            let at = siblings.firstIndex(of: id) ?? 0
            let below = siblings[..<at].last { out.entries[$0]?.parent == parent && out.order[parent]?.contains($0) == true }
            out.move(id, to: parent, above: below)
        }
        for id in x.entries.keys where y.entries[id] == nil { out.remove(id) }
        return out
    }
}
