import Foundation
import CoreGraphics

/// When a change was made, and on which Mac. A later change has a greater time; two made in the
/// same millisecond are told apart by who made them, the same way on every Mac.
nonisolated struct Stamp: Codable, Hashable, Comparable, Sendable {
    var time: Int64
    var by: String

    init(time: Int64, by: String) {
        self.time = time
        self.by = by
    }

    static func < (a: Stamp, b: Stamp) -> Bool { a.time != b.time ? a.time < b.time : a.by < b.by }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        time = try c.decode(Int64.self)
        by = try c.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(time)
        try c.encode(by)
    }
}

/// A value with the stamp of the change that set it. Wherever two meet, the later one is kept.
nonisolated struct Register<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    var value: Value
    var stamp: Stamp

    enum CodingKeys: String, CodingKey { case value = "v", stamp = "t" }
}

/// Where a layer lies: in which artboard or group (none for the canvas), and where among what
/// else lies there. A layer taken away keeps where it was, so it comes back there.
nonisolated struct Place: Codable, Hashable, Sendable {
    var parent: UUID?
    var key: String
    var removed = false

    enum CodingKeys: String, CodingKey { case parent = "in", key = "at", removed = "gone" }

    var canonical: String { "\(parent?.uuidString ?? "")/\(key)/\(removed)" }
}

/// One layer as it is shared: where it lies, and each of its properties, each kept with the stamp
/// of the change that set it.
nonisolated struct SharedLayer: Codable, Hashable, Sendable {
    var place: Register<Place>?
    var fields: [String: Register<FieldValue>] = [:]

    /// The latest change to any of its properties.
    var lastFieldChange: Stamp? { fields.values.lazy.map(\.stamp).max() }

    /// Takes in another copy's changes; returns whether any was later than what was here.
    mutating func merge(_ other: SharedLayer) -> Bool {
        var changed = false
        if let theirs = other.place, place.map({ Self.wins(theirs, over: $0, \.canonical) }) ?? true {
            place = theirs
            changed = true
        }
        for (name, theirs) in other.fields where fields[name].map({ Self.wins(theirs, over: $0, \.canonical) }) ?? true {
            fields[name] = theirs
            changed = true
        }
        return changed
    }

    /// Whether `a` is to be kept rather than `b`: the later one, and should two ever carry the
    /// same stamp with different values, the same one of them everywhere.
    private static func wins<V>(_ a: Register<V>, over b: Register<V>, _ canonical: (V) -> String) -> Bool {
        if a.stamp != b.stamp { return a.stamp > b.stamp }
        return a.value != b.value && canonical(a.value) > canonical(b.value)
    }
}

/// A shared design as every Mac that has it keeps it. Any two copies merge into the same one,
/// whatever order changes come in and however often the same ones come, so everyone ends with the
/// same design. Changes to different layers, or to different properties of a layer, are all kept;
/// of two changes to the same property of the same layer, the later one is.
///
/// Taking a layer away is a change too: one changed after it was taken away, by someone who had
/// not seen that yet, comes back, with what holds it, so no one's work is lost that way.
nonisolated struct SharedDesign: Codable, Equatable, Sendable {
    var layers: [UUID: SharedLayer] = [:]
    /// The latest stamp met, so a change made here is always later than everything seen.
    var clock = Stamp(time: 0, by: "")

    init() {}

    enum CodingKeys: String, CodingKey { case layers, clock }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: SharedLayer].self, forKey: .layers)
        layers = Dictionary(raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        clock = try c.decodeIfPresent(Stamp.self, forKey: .clock) ?? Stamp(time: 0, by: "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: layers.map { ($0.key.uuidString, $0.value) }), forKey: .layers)
        try c.encode(clock, forKey: .clock)
    }

    var isEmpty: Bool { layers.isEmpty }

    /// Takes in another copy's changes. Returns the layers that changed.
    @discardableResult
    mutating func merge(_ other: SharedDesign) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (id, theirs) in other.layers {
            if var mine = layers[id] {
                if mine.merge(theirs) {
                    layers[id] = mine
                    changed.insert(id)
                }
            } else {
                layers[id] = theirs
                changed.insert(id)
            }
        }
        if other.clock > clock { clock = other.clock }
        return changed
    }

    /// What this Mac changed after `time`, to send to the others.
    func changes(by replica: String, after time: Int64) -> SharedDesign {
        var out = SharedDesign()
        for (id, layer) in layers {
            var part = SharedLayer()
            if let p = layer.place, p.stamp.by == replica, p.stamp.time > time { part.place = p }
            for (name, r) in layer.fields where r.stamp.by == replica && r.stamp.time > time { part.fields[name] = r }
            if part.place != nil || !part.fields.isEmpty { out.layers[id] = part }
        }
        out.clock = clock
        return out
    }

    // MARK: Changes made here

    /// Takes in what was changed on this Mac from `base` to `now`, every change with one new stamp.
    /// `base` is what this copy showed last, so a property not changed here is never written, and
    /// whatever others changed meanwhile stays as they made it. Returns whether anything changed.
    @discardableResult
    mutating func absorb(_ now: FlatDesign, since base: FlatDesign, by replica: String, at time: Int64) -> Bool {
        let stamp = Stamp(time: max(time, clock.time + 1), by: replica)
        var wrote = false

        for (id, entry) in now.entries {
            let was = base.entries[id]?.node
            var node = entry.node
            // Frames in groups go to their artboard's coordinates and back, which can be off in
            // the last place; that is no change.
            if let was { node.keepFrames(of: was) }
            if was == node { continue }
            guard let values = LayerField.values(of: node) else { continue }
            var layer = layers[id] ?? SharedLayer()
            var changed = false
            for field in LayerField.all {
                if let was, field.same(was, node), layer.fields[field.name] != nil { continue }
                let value = values[field.name] ?? .null
                if layer.fields[field.name]?.value == value { continue }
                layer.fields[field.name] = Register(value: value, stamp: stamp)
                changed = true
            }
            if changed {
                layers[id] = layer
                wrote = true
            }
        }

        // Layers taken away keep where they were. Everything inside goes with them, each layer
        // marked, so that if one of them is changed elsewhere it comes back on its own.
        for id in base.entries.keys where now.entries[id] == nil {
            guard var layer = layers[id], var place = layer.place?.value else { continue }
            place.removed = true
            layer.place = Register(value: place, stamp: stamp)
            layers[id] = layer
            wrote = true
        }

        // Where layers lie. In each list that changed, the longest run still in order keeps its
        // keys, and the rest get new ones between their neighbours'.
        for (parent, list) in now.order where base.order[parent] != list {
            let current: [String?] = list.map { id in
                guard base.entries[id]?.parent == parent, let p = layers[id]?.place?.value, p.parent == parent else { return nil }
                return p.key
            }
            let candidates = list.indices.filter { current[$0] != nil }
            let kept = Set(longestRise(candidates.map { current[$0]! }, less: OrderKey.less).map { candidates[$0] })
            var nextKept: [String?] = Array(repeating: nil, count: list.count + 1)
            for i in list.indices.reversed() { nextKept[i] = kept.contains(i) ? current[i] : nextKept[i + 1] }
            var lower: String?
            for (i, id) in list.enumerated() {
                if kept.contains(i) {
                    lower = current[i]
                    continue
                }
                let key = OrderKey.between(lower, nextKept[i + 1])
                var layer = layers[id] ?? SharedLayer()
                layer.place = Register(value: Place(parent: parent, key: key), stamp: stamp)
                layers[id] = layer
                wrote = true
                lower = key
            }
        }

        if wrote { clock = stamp }
        return wrote
    }

    // MARK: What everyone sees

    /// The layers as everyone sees them. A layer is there unless it was taken away and nothing in
    /// it changed since; it lies where its place says, unless two people each put one layer into
    /// the other at once, when the older of those moves gives way and that layer goes onto the
    /// canvas. A layer whose artboard or group is not here yet waits for it, out of sight.
    ///
    /// `decoded` keeps layers already read from their properties, to be read again only when changed.
    func flatDesign(reusing decoded: inout [UUID: (layer: SharedLayer, node: Node)]) -> FlatDesign {
        var up: [UUID: UUID] = [:]
        for (id, layer) in layers { if let p = layer.place?.value.parent { up[id] = p } }

        // Loops, broken where the oldest move into one was.
        func placeStamp(_ id: UUID) -> (Stamp, String) { (layers[id]?.place?.stamp ?? Stamp(time: 0, by: ""), id.uuidString) }
        var done: Set<UUID> = []
        for start in up.keys where !done.contains(start) {
            var path: [UUID] = []
            var onPath: [UUID: Int] = [:]
            var node: UUID? = start
            while let n = node, !done.contains(n) {
                if let i = onPath[n] {
                    let weakest = path[i...].min { placeStamp($0) < placeStamp($1) }!
                    up[weakest] = nil
                    break
                }
                onPath[n] = path.count
                path.append(n)
                node = up[n]
            }
            done.formUnion(path)
        }

        var children: [UUID?: [UUID]] = [:]
        for (id, layer) in layers where layer.place != nil { children[up[id], default: []].append(id) }

        // The latest change in each layer and everything in it, of the layers not taken away or changed since.
        var latest: [UUID: Stamp] = [:]
        func beat(_ id: UUID) -> Stamp? {
            var last: Stamp?
            if let layer = layers[id], let place = layer.place {
                let fields = layer.lastFieldChange
                if !place.value.removed { last = max(place.stamp, fields ?? place.stamp) }
                else if let fields, fields > place.stamp { last = fields }
            }
            for child in children[id] ?? [] {
                if let b = beat(child), last.map({ b > $0 }) ?? true { last = b }
            }
            latest[id] = last
            return last
        }
        for root in children[nil] ?? [] { _ = beat(root) }

        var map = FlatDesign()
        func show(_ ids: [UUID], in parent: UUID?) {
            let alive = ids.compactMap { id -> (UUID, String)? in
                guard let place = layers[id]?.place else { return nil }
                guard !place.value.removed || (latest[id].map { $0 > place.stamp } ?? false) else { return nil }
                return (id, place.value.key)
            }.sorted { a, b in a.1 != b.1 ? OrderKey.less(a.1, b.1) : a.0.uuidString < b.0.uuidString }
            var listed: [UUID] = []
            for (id, _) in alive {
                guard let node = node(id, &decoded) else { continue }
                map.entries[id] = FlatDesign.Entry(parent: parent, node: node)
                listed.append(id)
                if node.isContainer { show(children[id] ?? [], in: id) }
            }
            if !listed.isEmpty || parent == nil { map.order[parent] = listed }
        }
        show(children[nil] ?? [], in: nil)
        return map
    }

    private func node(_ id: UUID, _ decoded: inout [UUID: (layer: SharedLayer, node: Node)]) -> Node? {
        guard let layer = layers[id] else { return nil }
        if let hit = decoded[id], hit.layer.fields == layer.fields { return hit.node }
        let node = LayerField.node(id, from: layer.fields.mapValues(\.value))
        decoded[id] = (layer, node)
        return node
    }

    func flatDesign() -> FlatDesign {
        var decoded: [UUID: (layer: SharedLayer, node: Node)] = [:]
        return flatDesign(reusing: &decoded)
    }
}

private nonisolated extension Node {
    /// Takes the frames of `other`, the same layer, where they differ from these by no more than
    /// rounding: its own and its mask's.
    mutating func keepFrames(of other: Node) {
        if frame != other.frame, Self.nearly(frame, other.frame) { frame = other.frame }
        if let mask, let theirs = other.mask, mask != theirs, mask.count == theirs.count {
            self.mask = zip(mask, theirs).map { m, t in
                var m = m
                if m.frame != t.frame, Self.nearly(m.frame, t.frame) { m.frame = t.frame }
                return m
            }
        }
    }

    private static func nearly(_ a: CGRect, _ b: CGRect) -> Bool {
        func close(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) }
        return close(a.minX, b.minX) && close(a.minY, b.minY) && close(a.width, b.width) && close(a.height, b.height)
    }
}
