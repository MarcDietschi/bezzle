import Foundation
import CoreGraphics

// MARK: - Components

/// A component: something designed once and used in many places, such as a button. Every place it
/// is used is a copy, a group like any other on the canvas, and no copy is the original: whatever
/// is changed in any of them, its look, the layers it holds, where they lie in it, is changed in
/// every one, as it happens. What a copy holds is its own: its words and its pictures, and anything
/// else it was told to keep (`Node.own`), as a deck's post keeps it. Where it lies, how big it is,
/// how far it is turned and whether it is flipped are its own too, and its layers are laid out in
/// it as they lie in the component (`Pinning`): what spans it stretches, what sits at an edge stays
/// there, what is in its middle stays in its middle.
///
/// What every copy is made from is kept in the design, apart from the canvas
/// (`BezzleDocument.components`): a group marked as a component (`Node.master`), never drawn. It
/// holds the layers as the component's first variant has them, and any other variant's layers
/// after them, as a deck holds its design and its posts: each the same layers, every id mixed with
/// the variant's key (`Deck.key`), and keeping of its own what it looks like otherwise (`Node.own`).
///
/// A copy's id is the component's id mixed with a key of the copy's own, chosen at random, and the
/// ids of its layers are those of its variant's layers mixed with the same key, all the way down.
/// So the same layer in the component, and in every other copy, is always known with nothing else
/// kept; and a grid or a deck that mixes a copy's ids again, to make copies of it in its cells or
/// posts, makes copies of the component.
nonisolated struct Instance: Codable, Hashable {
    /// The component it is a copy of: the id of its group in `BezzleDocument.components`.
    var of: UUID
    /// Which of the component's variants it shows, by number; nil for the first.
    var variant: Int?
    /// The box its layers are laid out in, upright, in the copy's own coordinates, before it is
    /// flipped and turned. It moves with what the copy holds (`fitGroup`).
    var box: CGRect
    /// How far it is turned, in degrees clockwise about the middle of its box; nil is upright.
    var turn: Double?
    /// Turned over left to right, about the middle of its box, before it is turned.
    var flipX: Bool?
    /// Turned over top to bottom, about the middle of its box, before it is turned.
    var flipY: Bool?
}

/// What marks a group in `BezzleDocument.components` as a component.
nonisolated struct Master: Codable, Hashable {
    /// The variants after the first, by number, in the order they are shown. Like a deck's posts,
    /// each is numbered once, at random, and keeps its number.
    var variants: [Int] = []
    /// What the variants are called, by number, "0" for the first; one not named is called by
    /// where it is among them.
    var names: [String: String]?
    /// The part of a kit it was made of, with how it was made ("ios.button", "ios.button/dark"):
    /// the same part dropped into the design again is another copy of it.
    var part: String?
    /// The design it was taken from, when it came from another one; nil for one made here. See
    /// `LibraryLink`.
    var library: LibraryLink?
}

nonisolated extension Node {
    /// A copy of a component.
    var isCopy: Bool { kind == .group && instance != nil }

    /// A component's own group, kept apart from the canvas.
    var isMaster: Bool { master != nil }

    /// This copy as a group like any other, keeping nothing of its own: it no longer changes with
    /// its component. Copies of other components in it, as a button in a card, stay copies of theirs.
    func unlinked() -> Node {
        var n = self
        n.instance = nil
        n.own = nil
        n.children = children.map { $0.instance != nil ? $0 : $0.unlinked() }
        return n
    }

    /// The copies of components this layer is or holds, however deep, and so the components it uses.
    var componentsUsed: [UUID] {
        (instance.map { [$0.of] } ?? []) + children.flatMap(\.componentsUsed)
    }
}

nonisolated extension BezzleDocument {
    /// The design's components, each a group never drawn; empty while there are none.
    var masters: [Node] {
        get { components ?? [] }
        set { components = newValue.isEmpty ? nil : newValue }
    }

    /// The group of the component with this id.
    func master(_ id: UUID) -> Node? { components?.first { $0.id == id } }

    /// Every component, by its id.
    var mastersByID: [UUID: Node] { Dictionary(masters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// The copy a layer lies in, however deep, or the layer itself if it is one.
    func copy(holding id: UUID) -> Node? {
        if let n = node(id), n.isCopy { return n }
        return ancestors(of: id).last(where: \.isCopy)
    }

    /// Every copy of a component on the canvas, in the order they are met: in copies of other
    /// components too, as the buttons in every copy of a card.
    func copies(of master: UUID) -> [Node] {
        var out: [Node] = []
        func visit(_ nodes: [Node]) {
            for n in nodes {
                if n.instance?.of == master { out.append(n) }
                if !n.children.isEmpty { visit(n.children) }
            }
        }
        visit(nodes)
        return out
    }

    /// Every copy of any component, by the component.
    var allCopies: [UUID: [Node]] {
        var out: [UUID: [Node]] = [:]
        func visit(_ nodes: [Node]) {
            for n in nodes {
                if let i = n.instance { out[i.of, default: []].append(n) }
                if !n.children.isEmpty { visit(n.children) }
            }
        }
        visit(nodes)
        return out
    }

    /// The components a component uses, however deep: those it holds copies of, and theirs.
    func uses(_ id: UUID) -> Set<UUID> {
        var seen = Set<UUID>(), queue = master(id)?.componentsUsed ?? []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            queue += master(next)?.componentsUsed ?? []
        }
        return seen
    }

    /// Whether any layer lies in a copy, or is one.
    func inCopy(_ id: UUID) -> Bool { copy(holding: id) != nil }

    /// Whether a layer lies inside a copy, whether or not it is one itself.
    func insideCopy(_ id: UUID) -> Bool { ancestors(of: id).contains(where: \.isCopy) }
}

// MARK: - Keys and variants

nonisolated enum Components {
    /// A key of a copy's own, at random.
    static func freshKey() -> RepeatGrid.Key {
        RepeatGrid.Key(a: .random(in: 1...UInt64.max), b: .random(in: 1...UInt64.max))
    }

    /// What mixes the component's ids into a copy's.
    static func key(of copy: Node) -> RepeatGrid.Key? {
        copy.instance.map { copy.id.key(from: $0.of) }
    }

    /// A variant a component has, or nil, its first.
    static func variant(_ v: Int?, of master: Node) -> Int? {
        guard let v, master.master?.variants.contains(v) == true else { return nil }
        return v
    }

    /// The layers a variant is made of, as the component holds them.
    static func layers(of master: Node, variant: Int?) -> [Node] {
        master.children.filter { $0.post == Self.variant(variant, of: master) }
    }

    /// The box round some layers lying in one group, as the group would be fitted round them.
    static func box(of layers: [Node]) -> CGRect {
        layers.map { RepeatGrid.box(of: $0) }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? .zero
    }

    /// The box a variant's layers take up in the component, on the canvas the component lies on.
    static func box(of master: Node, variant: Int?) -> CGRect {
        box(of: layers(of: master, variant: variant)).offsetBy(dx: master.frame.minX, dy: master.frame.minY)
    }

    /// Of every layer in a component, the layer of its first variant it is: by its id, that id.
    static func designIDs(of master: Node) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for c in master.children {
            let k = Deck.key(c.post)
            func visit(_ n: Node) {
                out[n.id] = n.id.mixed(k)
                n.children.forEach(visit)
                n.mask?.forEach(visit)
            }
            visit(c)
        }
        return out
    }

    /// What a component's variant is called.
    static func name(of variant: Int?, in master: Node) -> String {
        let v = Self.variant(variant, of: master)
        if let named = master.master?.names?[String(v ?? 0)], !named.isEmpty { return named }
        guard let v, let i = master.master?.variants.firstIndex(of: v) else { return String(localized: "Default") }
        return String(localized: "Variant \(i + 2)")
    }

    /// Every variant of a component, its first first.
    static func variants(of master: Node) -> [Int?] {
        [nil] + (master.master?.variants ?? []).map { Optional($0) }
    }

    /// The properties a copy can keep of its own: what a deck's post can, but its place among the
    /// component's layers.
    static let keepable: Set<String> = Deck.keepable.subtracting(["instance", "master"])
}

// MARK: - Laying a copy out

/// Where a layer stays when what holds it is made bigger or smaller, along one way.
nonisolated enum Pin: UInt8, Hashable, Sendable {
    /// As far from the start (the left, or the top) as it was.
    case start
    /// As far from the end (the right, or the bottom).
    case end
    /// As far from the middle.
    case middle
    /// As far from both, growing and shrinking with what holds it.
    case stretch
    /// Its middle as far along, by its share of the length: one of several spread along a bar.
    case spread
}

nonisolated struct Pins: Hashable, Sendable {
    var x: Pin
    var y: Pin
}

/// How a copy's layers are laid out in a box of another size than the component's: worked out from
/// where each lies in the component, so nothing has to be set up. A layer that spans most of its
/// box stretches with it, one in the middle stays in the middle, one near an edge stays as far from
/// it, and any other keeps its share of the way along, as the tabs of a bar do.
nonisolated enum Pinning {
    /// Whether a layer can grow and shrink along a way: not words as long as they are, nor
    /// anything turned, nor a repeat grid.
    static func canStretch(_ n: Node, horizontally: Bool) -> Bool {
        guard n.rotation.truncatingRemainder(dividingBy: 360) == 0, n.transform3D == nil, !n.isRepeatGrid else { return false }
        if n.kind == .text {
            let sizing = n.style?.sizing ?? .autoWidth
            return horizontally ? sizing != .autoWidth : sizing == .fixed
        }
        return true
    }

    /// Where a layer stays in its box, worked out from where it lies in it.
    static func infer(_ n: Node, in box: CGRect) -> Pins {
        let b = RepeatGrid.box(of: n)
        func pin(_ lo: CGFloat, _ hi: CGFloat, _ start: CGFloat, _ end: CGFloat, stretches: Bool) -> Pin {
            let length = end - start, size = hi - lo
            guard length > 0.5 else { return .start }
            if stretches, size >= length * 0.5 { return .stretch }
            let middle = (lo + hi) / 2 - (start + end) / 2
            if abs(middle) <= max(0.5, length * 0.01) { return .middle }
            let before = lo - start, after = end - hi
            if before <= after, before <= length * 0.25 { return .start }
            if after < before, after <= length * 0.25 { return .end }
            return .spread
        }
        return Pins(x: pin(b.minX, b.maxX, box.minX, box.maxX, stretches: canStretch(n, horizontally: true)),
                    y: pin(b.minY, b.maxY, box.minY, box.maxY, stretches: canStretch(n, horizontally: false)))
    }

    /// Where every layer stays, by its id, all the way down: each in the box it lies in, a group's
    /// layers in the group.
    static func table(_ layers: [Node], in box: CGRect, into out: inout [UUID: Pins]) {
        for n in layers {
            out[n.id] = infer(n, in: box)
            if n.isGroup, !n.children.isEmpty, !n.isRepeatGrid {
                table(n.children, in: CGRect(origin: .zero, size: n.frame.size), into: &out)
            }
        }
    }

    /// Where a stretch of a layer from `lo`, `size` long, lands when its box runs from `t0` for
    /// `tl` rather than from `f0` for `fl`.
    static func map(_ lo: CGFloat, _ size: CGFloat, _ pin: Pin, from f0: CGFloat, _ fl: CGFloat, to t0: CGFloat, _ tl: CGFloat) -> (CGFloat, CGFloat) {
        switch pin {
        case .start: return (t0 + (lo - f0), size)
        case .end: return (t0 + tl - (f0 + fl - lo), size)
        case .middle: return (t0 + tl / 2 + (lo - (f0 + fl / 2)), size)
        case .stretch: return (t0 + (lo - f0), max(0, size + tl - fl))
        case .spread:
            let share = fl > 0 ? (lo + size / 2 - f0) / fl : 0.5
            return (t0 + share * tl - size / 2, size)
        }
    }

    /// Layers lying in the box `from` as they lie in the box `to`, each where it stays (`pins`, by
    /// its id mixed with `key`, so a copy's layers are found by the component's ids). What a
    /// stretched group holds is laid out in it the same way.
    static func laidOut(_ layers: [Node], from: CGRect, to: CGRect, pins: [UUID: Pins], key: RepeatGrid.Key) -> [Node] {
        guard from != to else { return layers }
        return layers.map { n in
            let p = pins[n.id.mixed(key)] ?? infer(n, in: from)
            var m = n
            if canStretch(n, horizontally: true) || canStretch(n, horizontally: false) {
                let (x, w) = map(n.frame.minX, n.frame.width, canStretch(n, horizontally: true) ? p.x : nonStretch(p.x),
                                 from: from.minX, from.width, to: to.minX, to.width)
                let (y, h) = map(n.frame.minY, n.frame.height, canStretch(n, horizontally: false) ? p.y : nonStretch(p.y),
                                 from: from.minY, from.height, to: to.minY, to.height)
                m.frame = CGRect(x: x, y: y, width: w, height: h)
            } else {
                // Turned or as long as its words: moved as its box is, never stretched.
                let b = RepeatGrid.box(of: n)
                let (x, _) = map(b.minX, b.width, nonStretch(p.x), from: from.minX, from.width, to: to.minX, to.width)
                let (y, _) = map(b.minY, b.height, nonStretch(p.y), from: from.minY, from.height, to: to.minY, to.height)
                m.frame = n.frame.offsetBy(dx: x - b.minX, dy: y - b.minY)
            }
            if n.isGroup, !n.isRepeatGrid, m.frame.size != n.frame.size {
                if var inst = n.instance {
                    // A copy of another component, as a button in a card, is laid out in its own
                    // box, which grows with it, by its own component, when it is made again.
                    inst.box.size = CGSize(width: max(1, inst.box.width + m.frame.width - n.frame.width),
                                           height: max(1, inst.box.height + m.frame.height - n.frame.height))
                    m.instance = inst
                } else {
                    let inner = CGRect(origin: .zero, size: n.frame.size), outer = CGRect(origin: .zero, size: m.frame.size)
                    m.children = laidOut(n.children, from: inner, to: outer, pins: pins, key: key)
                    m.mask = n.mask?.map { var k = $0; k.frame = Geometry.map($0.frame, from: inner, to: outer); return k }
                }
            }
            return m
        }
    }

    private static func nonStretch(_ p: Pin) -> Pin { p == .stretch ? .start : p }
}

// MARK: - Making copies

extension Components {
    /// What a copy is laid out from: the component's layers of its variant, the box they take up,
    /// where each stays, the copy's layers by the component's ids they are copies of, and the box
    /// its layers are laid out in, grown or shrunk round words longer or shorter than the
    /// component's (`hugged`).
    struct Plan {
        var key: RepeatGrid.Key
        var variant: Int?
        var layers: [Node]
        var from: CGRect
        var pins: [UUID: Pins]
        var held: [UUID: Node]
        var to: CGRect
        var instance: Instance
    }

    static func plan(_ copy: Node, master: Node, instance: Instance? = nil) -> Plan? {
        guard let inst = instance ?? copy.instance else { return nil }
        let k = copy.id.key(from: master.id)
        let v = variant(inst.variant, of: master)
        let layers = layers(of: master, variant: v)
        let from = box(of: layers)
        var pins: [UUID: Pins] = [:]
        Pinning.table(layers, in: from, into: &pins)
        // Which words it grows round is the component's, the same in every variant, however long
        // the words are in one: told by its first variant.
        var labels = labels(layers, pins: pins)
        if let v {
            let first = Self.layers(of: master, variant: nil)
            var firstPins: [UUID: Pins] = [:]
            Pinning.table(first, in: box(of: first), into: &firstPins)
            let found = Self.labels(first, pins: firstPins), kv = Deck.key(v)
            labels = (Set(found.x.map { $0.mixed(kv) }), Set(found.y.map { $0.mixed(kv) }))
        }
        aligningLabels(layers, pins: &pins, labels: labels.x)
        // The copy's layers by the layer of this variant they are, whichever variant it showed.
        let design = designIDs(of: master), kv = Deck.key(v)
        var held: [UUID: Node] = [:]
        func note(_ n: Node) {
            let mine = n.id.mixed(k)
            held[(design[mine] ?? mine).mixed(kv)] = n
            n.children.forEach(note)
        }
        copy.children.forEach(note)
        let to = hugged(inst.box, layers: layers, pins: pins, held: held, labels: labels)
        return Plan(key: k, variant: v, layers: layers, from: from, pins: pins, held: held, to: to, instance: inst)
    }

    /// A copy's box grown or shrunk by as much as its words are longer or shorter than the
    /// component's, where they are what the layer round them is as big as: a button's label, which
    /// its shape is a little bigger than all round. Words in a field much wider than they are leave
    /// it as it is.
    static func hugged(_ box: CGRect, layers: [Node], pins: [UUID: Pins], held: [UUID: Node], labels: (x: Set<UUID>, y: Set<UUID>)) -> CGRect {
        var dx: CGFloat = 0, dy: CGFloat = 0, ax = Pin.start, ay = Pin.start
        // Words anywhere in the copy, as long as every group they lie in stretches with it that way.
        func look(_ siblings: [Node], acrossX: Bool, acrossY: Bool) {
            for m in siblings where !m.hidden {
                // A copy of another component grows round its own words, not this one.
                if m.instance != nil { continue }
                if m.isGroup, !m.isRepeatGrid, let p = pins[m.id] {
                    let sx = acrossX && p.x == .stretch, sy = acrossY && p.y == .stretch
                    if sx || sy { look(m.children, acrossX: sx, acrossY: sy) }
                    continue
                }
                guard m.kind == .text, let h = held[m.id], h.kind == .text, h.text != m.text || h.spans != m.spans, let p = pins[m.id] else { continue }
                var t = m
                t.text = h.text
                t.spans = h.spans
                t.refit()
                let sizing = m.style?.sizing ?? .autoWidth
                let gw = sizing == .autoWidth ? t.frame.width - m.frame.width : 0
                let gh = sizing != .fixed ? t.frame.height - m.frame.height : 0
                if acrossX, gw != 0, p.x != .stretch, abs(gw) > abs(dx), labels.x.contains(m.id) { dx = gw; ax = p.x }
                if acrossY, gh != 0, p.y != .stretch, abs(gh) > abs(dy), labels.y.contains(m.id) { dy = gh; ay = p.y }
            }
        }
        look(layers, acrossX: true, acrossY: true)
        func grow(_ lo: CGFloat, _ size: CGFloat, _ by: CGFloat, _ pin: Pin) -> (CGFloat, CGFloat) {
            let s = max(1, size + by), d = s - size
            switch pin {
            case .start, .stretch: return (lo, s)
            case .end: return (lo - d, s)
            case .middle, .spread: return (lo - d / 2, s)
            }
        }
        let (x, w) = grow(box.minX, box.width, dx, ax), (y, h) = grow(box.minY, box.height, dy, ay)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A button's words, which a stretching shape a little bigger lies round, stay where they are
    /// aligned to, as they do while they are typed: left-aligned words keep their place from the
    /// left, and the button grows to the right round them; right-aligned words from the right;
    /// centred ones about their middle. Words that lie in the middle of their shape stay there
    /// however they are aligned. Where they are only near an edge, or a share of the way along, says
    /// less than how they are aligned: next to an icon, words a little past a quarter of the way in
    /// would otherwise keep their share and creep towards it as they grow.
    static func aligningLabels(_ layers: [Node], pins: inout [UUID: Pins], labels: Set<UUID>) {
        for m in layers where !m.hidden {
            if m.isGroup, !m.isRepeatGrid, m.instance == nil {
                aligningLabels(m.children, pins: &pins, labels: labels)
                continue
            }
            guard m.kind == .text, m.curve == nil, (m.style?.sizing ?? .autoWidth) == .autoWidth, var p = pins[m.id], p.x != .middle,
                  labels.contains(m.id) else { continue }
            switch m.style?.align ?? .left {
            case .center: p.x = .middle
            case .right: p.x = .end
            case .left, .justify: p.x = .start
            }
            pins[m.id] = p
        }
    }

    /// Words refitted to what they say, grown or shrunk round where they stay: a label in the
    /// middle stays in the middle.
    static func refit(_ n: inout Node, pins: Pins?) {
        let before = n.frame
        n.refit()
        guard let p = pins else { return }
        switch p.x {
        case .middle, .spread: n.frame.origin.x = before.midX - n.frame.width / 2
        case .end: n.frame.origin.x = before.maxX - n.frame.width
        default: n.frame.origin.x = before.minX
        }
        switch p.y {
        case .middle, .spread: n.frame.origin.y = before.midY - n.frame.height / 2
        case .end: n.frame.origin.y = before.maxY - n.frame.height
        default: n.frame.origin.y = before.minY
        }
    }

    /// A copy shown as a variant of its component, its box such that it shows as big as `shown`
    /// with its words, which may be longer or shorter than the variant's.
    static func showing(_ copy: Node, variant v: Int?, of master: Node, at shown: CGRect) -> Node {
        var c = copy
        guard c.instance != nil else { return c }
        c.instance?.variant = v
        c.instance?.box = shown
        // How much its words grow it does not hang on its box: taken off once, it shows as it was.
        if let to = plan(c, master: master)?.to, to != shown {
            c.instance?.box = CGRect(x: shown.minX - (to.minX - shown.minX), y: shown.minY - (to.minY - shown.minY),
                                     width: max(1, shown.width - (to.width - shown.width)), height: max(1, shown.height - (to.height - shown.height)))
        }
        return c
    }

    /// The words a stretching layer a little bigger lies round, along each way, however deep: a
    /// button's label, which a copy grows round as its words grow.
    static func labels(_ layers: [Node], pins: [UUID: Pins]) -> (x: Set<UUID>, y: Set<UUID>) {
        var x = Set<UUID>(), y = Set<UUID>()
        func visit(_ siblings: [Node]) {
            for m in siblings where !m.hidden {
                if m.isGroup, !m.isRepeatGrid, m.instance == nil {
                    visit(m.children)
                    continue
                }
                guard m.kind == .text else { continue }
                if holds(m, in: siblings, pins: pins, horizontally: true) { x.insert(m.id) }
                if holds(m, in: siblings, pins: pins, horizontally: false) { y.insert(m.id) }
            }
        }
        visit(layers)
        return (x, y)
    }

    /// Whether a stretching layer lies round `m` and is little bigger than it, along a way: by a
    /// share of it, or across by no more than a few letters' room, as round a short label in a
    /// button made wide enough to tap ("OK", "Save"), but not a field or a bar much wider than
    /// what is written in it.
    private static func holds(_ m: Node, in layers: [Node], pins: [UUID: Pins], horizontally: Bool) -> Bool {
        let a = RepeatGrid.box(of: m)
        let room = CGFloat(m.style?.size ?? 16) * 7
        return layers.contains { c in
            guard c.id != m.id, !c.hidden, let p = pins[c.id], (horizontally ? p.x : p.y) == .stretch else { return false }
            let b = RepeatGrid.box(of: c)
            return horizontally
                ? b.minX <= a.minX + 0.5 && b.maxX >= a.maxX - 0.5 && (a.width >= b.width * 0.3 || b.width - a.width <= room)
                : b.minY <= a.minY + 0.5 && b.maxY >= a.maxY - 0.5 && a.height >= b.height * 0.3
        }
    }

    /// A copy made again from its component: its variant's layers laid out in its box, flipped and
    /// turned as it is, each keeping what the copy's layer held of its own, its words and pictures
    /// and anything else it keeps. `masterWas` is the component as it was before the change, for
    /// what was restyled in its words. Copies of other components in it, as the buttons in a card,
    /// are made again from theirs, found in `masters` (and as they were, in `mastersWas`); one whose
    /// component is not there is a group like any other.
    static func build(_ copy: Node, master: Node, masterWas: Node?, masters: [UUID: Node] = [:], mastersWas: [UUID: Node] = [:], depth: Int = 0) -> Node {
        guard let plan = plan(copy, master: master) else { return copy }
        var then: [UUID: Node] = [:]
        if let masterWas {
            func note(_ n: Node) {
                then[n.id] = n
                n.children.forEach(note)
            }
            masterWas.children.forEach(note)
        }
        var originals: [UUID: Node] = [:]
        func noteOriginal(_ n: Node) {
            originals[n.id] = n
            n.children.forEach(noteOriginal)
        }
        plan.layers.forEach(noteOriginal)
        let laid = Pinning.laidOut(plan.layers, from: plan.from, to: plan.to, pins: plan.pins, key: .none)

        func make(_ m: Node) -> Node {
            var n = m
            n.id = m.id.mixed(plan.key)
            n.post = nil
            n.own = nil
            // A copy of another component in it stays one; anything else is a layer of this copy.
            n.master = nil
            n.mask = m.mask?.map { RepeatGrid.copy($0, plan.key) }
            n.children = m.children.map(make)
            let original = originals[m.id] ?? m
            if let was = plan.held[m.id] {
                if m.kind == .text, was.kind == .text {
                    n.text = was.text
                    n.spans = was.lettersCarried(from: original, was: then[m.id], keeps: Set(was.own ?? []))
                }
                n.fill.image = was.fill.image
                // Where it goes in the prototype is the copy's own, as its words are, and how it moves in time.
                n.flow = was.flow
                n.motion = was.motion
                if let own = was.own {
                    for name in own where keepable.contains(name) { Deck.fields[name]?.copy(&n, was) }
                    n.own = own
                }
                // Its named looks are its styles', as they look where the copy lies: dark on a dark artboard.
                n = n.keepingNamedLooks(of: was, deep: false)
            }
            if n.kind == .text, n.text != original.text || n.spans != original.spans || n.style != original.style
                || n.frame.size != original.frame.size {
                // Grown or shrunk round where it stays: a label in the middle stays in the middle.
                refit(&n, pins: plan.pins[m.id])
            }
            return n
        }
        var kids = laid.map(make)
        // Copies of other components in it, made again from theirs as it lies upright; turned and
        // flipped with it after.
        if depth < 8 { kids = kids.map { rebuildingNested($0, masters: masters, mastersWas: mastersWas, depth: depth + 1) } }
        kids = placed(kids, plan.instance)
        var out = copy
        out.children = kids
        out.post = copy.post
        return out
    }

    /// The copies of components in a layer, however deep, placed as `placements` say, by their ids.
    static func place(_ n: inout Node, _ placements: [UUID: Instance]) {
        for i in n.children.indices {
            if let p = placements[n.children[i].id], n.children[i].instance != nil { n.children[i].instance = p }
            if n.children[i].marksCopy { place(&n.children[i], placements) }
        }
    }

    /// A layer with every copy of a component in it, however deep, made again from its component.
    static func rebuildingNested(_ n: Node, masters: [UUID: Node], mastersWas: [UUID: Node], depth: Int) -> Node {
        if let inst = n.instance {
            guard let master = masters[inst.of] else { return masters.isEmpty ? n : n.unlinked() }
            return build(n, master: master, masterWas: mastersWas[inst.of], masters: masters, mastersWas: mastersWas, depth: depth)
        }
        guard n.marksCopy else { return n }
        var m = n
        m.children = n.children.map { rebuildingNested($0, masters: masters, mastersWas: mastersWas, depth: depth) }
        return m
    }

    /// Layers laid out in a copy's box, flipped and turned as the copy is.
    static func placed(_ layers: [Node], _ inst: Instance) -> [Node] {
        var kids = layers
        let c = inst.box.center
        if inst.flipX == true { kids = kids.map { flip($0, horizontally: true, about: c.x) } }
        if inst.flipY == true { kids = kids.map { flip($0, horizontally: false, about: c.y) } }
        if let t = inst.turn, t != 0 { kids = kids.map { turn($0, by: t, about: c) } }
        return kids
    }

    /// The other way: a copy's layers as they would lie in its component, turned back, flipped back
    /// and laid out in the component's box again, laid out by `plan` (the copy's, or as it was).
    static func unplaced(_ layers: [Node], _ plan: Plan) -> [Node] {
        var kids = layers
        let inst = plan.instance, c = inst.box.center
        if let t = inst.turn, t != 0 { kids = kids.map { turn($0, by: -t, about: c) } }
        if inst.flipY == true { kids = kids.map { flip($0, horizontally: false, about: c.y) } }
        if inst.flipX == true { kids = kids.map { flip($0, horizontally: true, about: c.x) } }
        return Pinning.laidOut(kids, from: plan.to, to: plan.from, pins: plan.pins, key: plan.key)
    }

    /// A layer turned as `BezzleDocument.turned` turns it, and every copy of a component in it told
    /// so, so that made again from its component it lies as turned.
    static func turn(_ n: Node, by t: Double, about c: CGPoint) -> Node {
        var m = BezzleDocument.turned(n, by: t, about: c)
        func tell(_ x: inout Node, _ origin: CGPoint) {
            guard x.isGroup else { return }
            let o = origin + x.frame.origin
            if var inst = x.instance {
                let moved = Geometry.rotated(o + inst.box.center, about: c, by: t)
                inst.box = CGRect(center: moved - o, size: inst.box.size)
                let turned = Geometry.normalized((inst.turn ?? 0) + t)
                inst.turn = abs(turned) < 1e-9 ? nil : turned
                x.instance = inst
            }
            for i in x.children.indices { tell(&x.children[i], o) }
        }
        tell(&m, .zero)
        return m
    }

    /// A layer flipped as `BezzleDocument.flipped` flips it, every copy in it told so.
    static func flip(_ n: Node, horizontally h: Bool, about axis: CGFloat) -> Node {
        var m = BezzleDocument.flipped(n, horizontally: h, about: axis)
        func tell(_ x: inout Node, _ origin: CGPoint) {
            guard x.isGroup else { return }
            let o = origin + x.frame.origin
            if var inst = x.instance {
                let c = o + inst.box.center
                let mirrored = h ? CGPoint(x: 2 * axis - c.x, y: c.y) : CGPoint(x: c.x, y: 2 * axis - c.y)
                inst.box = CGRect(center: mirrored - o, size: inst.box.size)
                if h { inst.flipX = inst.flipX == true ? nil : true } else { inst.flipY = inst.flipY == true ? nil : true }
                if let t = inst.turn, t != 0 { inst.turn = Geometry.normalized(-t) }
                x.instance = inst
            }
            for i in x.children.indices { tell(&x.children[i], o) }
        }
        tell(&m, .zero)
        return m
    }

    /// A copy's layers with what each copy of another component in them holds as it was: what is
    /// changed inside such a copy, as a button in a card, is a change to its own component, which
    /// keeps its copies alike itself. Where it lies, how big and which variant are the card's.
    static func masked(_ now: [Node], was: [Node]) -> [Node] {
        var then: [UUID: Node] = [:]
        func note(_ n: Node) {
            then[n.id] = n
            n.children.forEach(note)
        }
        was.forEach(note)
        func mask(_ n: Node) -> Node {
            var m = n
            if n.instance != nil {
                if let w = then[n.id], w.instance != nil { m.children = w.children }
                return m
            }
            guard n.marksCopy else { return n }
            m.children = n.children.map(mask)
            return m
        }
        return now.map(mask)
    }

    /// Carries what was changed in a copy since `was` to its component's layers of its variant, so
    /// that every copy can be made from them again. What the copy keeps of its own, its words and
    /// pictures among it, stays with the copy; what was moved, resized, put into it or taken out of
    /// it goes to the component, as it would lie there.
    static func carry(from was: Node, to now: Node, into master: inout Node) {
        guard let plan = plan(was, master: master) else { return }
        let then = unplaced(was.children, plan)
        // Named looks are kept alike by their styles, and differ only as light and dark do.
        let after = unplaced(masked(now.keepingNamedLooks(of: was).children, was: was.children), plan)
        // As a repeat grid of two cells, the component's layers first, so the grid's own way of
        // carrying a change in a cell to its first can be used.
        let kc = RepeatGrid.key(RepeatGrid.Cell(column: 1, row: 0)), remix = plan.key ^ kc
        let page = CGRect(x: 0, y: 0, width: 1, height: 1)
        let firstID = master.id.mixed(Deck.key(plan.variant))
        func wrap(_ id: UUID, _ kids: [Node]) -> Node {
            var w = Node(kind: .group, frame: page)
            w.id = id
            w.children = kids
            return w
        }
        var gridThen = Node(kind: .group, frame: page)
        gridThen.grid = RepeatGrid()
        gridThen.children = [wrap(firstID, plan.layers), wrap(firstID.mixed(kc), then.map { RepeatGrid.copy($0, remix) })]
        var gridNow = gridThen
        gridNow.children[1] = wrap(firstID.mixed(kc), after.map { RepeatGrid.copy($0, remix) })
        RepeatGrid.carry(from: gridThen, into: &gridNow, step: .zero)
        guard gridNow.children.count == 2 else { return }
        var made = gridNow.children[0].children
        settleWords(&made, as: after, plan)
        for i in made.indices { made[i].post = plan.variant }
        master.children = master.children.filter { $0.post != plan.variant } + made
        master.children = ordered(master)
    }

    /// Words moved in a copy whose words are its own, longer or shorter than the component's, go
    /// where they stay in the copy, by their pins: their middle where its middle went, for a label
    /// in the middle. Carried as the copy has them, the component's words were refitted round the
    /// copy's left edge, and a label centred by hand came to lie off its middle in every copy by half
    /// the difference.
    private static func settleWords(_ made: inout [Node], as copy: [Node], _ plan: Plan) {
        var theirs: [UUID: Node] = [:], was: [UUID: Node] = [:]
        func note(_ n: Node, _ into: inout [UUID: Node], _ key: RepeatGrid.Key) {
            into[n.id.mixed(key)] = n
            n.children.forEach { note($0, &into, key) }
        }
        copy.forEach { note($0, &theirs, plan.key) }
        plan.layers.forEach { note($0, &was, .none) }
        func settle(_ n: inout Node) {
            if n.kind == .text, let c = theirs[n.id], c.kind == .text, c.text != n.text || c.spans != n.spans,
               let before = was[n.id], before.frame != n.frame, let p = plan.pins[n.id] {
                switch p.x {
                case .end: n.frame.origin.x = c.frame.maxX - n.frame.width
                case .middle, .spread: n.frame.origin.x = c.frame.midX - n.frame.width / 2
                case .start, .stretch: n.frame.origin.x = c.frame.minX
                }
                switch p.y {
                case .end: n.frame.origin.y = c.frame.maxY - n.frame.height
                case .middle, .spread: n.frame.origin.y = c.frame.midY - n.frame.height / 2
                case .start, .stretch: n.frame.origin.y = c.frame.minY
                }
            }
            for i in n.children.indices { settle(&n.children[i]) }
        }
        for i in made.indices { settle(&made[i]) }
    }

    /// Marks as a variant's own whatever was changed in its layers, so a change made in a copy of a
    /// variant stays in that variant, and the others stay as they are. (A change made in a copy of
    /// the first variant reaches every variant, but for what each keeps of its own.)
    static func keepInVariant(_ master: inout Node, was: Node, variant v: Int) {
        let then = was.children.filter { $0.post == v }
        guard !then.isEmpty else { return }
        var before: [UUID: Node] = [:]
        func note(_ n: Node) {
            before[n.id] = n
            n.children.forEach(note)
        }
        then.forEach(note)
        func mark(_ n: inout Node) {
            if let q = before[n.id] {
                var a = n.fill, b = q.fill
                a.image = nil
                b.image = nil
                let typed = n.kind == .text && (n.text != q.text || n.spans != q.spans)
                let names = LayerField.all.filter { f in
                    keepable.contains(f.name) && f.name != "spans" && !(f.name == "frame" && typed) && !f.same(n, q) && !(f.name == "fill" && a == b)
                }.map(\.name)
                if !names.isEmpty { n.own = Array(Set(n.own ?? []).union(names)).sorted() }
            }
            for i in n.children.indices { mark(&n.children[i]) }
        }
        for i in master.children.indices where master.children[i].post == v { mark(&master.children[i]) }
    }

    /// A component's layers in the order its variants are: its first variant's, then each other's.
    static func ordered(_ master: Node) -> [Node] {
        let order = variants(of: master)
        return order.flatMap { v in master.children.filter { $0.post == v } }
    }
}

// MARK: - A copy moved, resized, turned or flipped whole

extension Components {
    private struct Leaf {
        var id: UUID
        var frame: CGRect
        var rotation: Double
        var text: Bool
        /// For words, where along them they stay put as they grow: 0 their left, 0.5 their middle,
        /// 1 their right.
        var anchor: CGFloat = 0
    }

    /// The layers a copy holds that hold nothing, placed in the copy, every group's place added.
    private static func leaves(_ nodes: [Node], at origin: CGPoint = .zero, into out: inout [Leaf]) {
        for n in nodes {
            if n.isGroup {
                leaves(n.children, at: origin + n.frame.origin, into: &out)
            } else {
                var anchor: CGFloat = 0
                if n.kind == .text, n.style?.sizing ?? .autoWidth == .autoWidth {
                    switch n.style?.align ?? .left {
                    case .center: anchor = 0.5
                    case .right: anchor = 1
                    default: anchor = 0
                    }
                }
                out.append(Leaf(id: n.id, frame: n.frame.offsetBy(dx: origin.x, dy: origin.y), rotation: n.rotation, text: n.kind == .text, anchor: anchor))
            }
        }
    }

    /// Whether two lists of layers are the same layers, alike in everything but `skip`.
    private static func alike(_ a: [Node], _ b: [Node], but skip: Set<String>) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.id == y.id else { return false }
            if x == y { continue }
            for field in LayerField.all where !skip.contains(field.name) && !field.same(x, y) { return false }
            if !alike(x.children, y.children, but: skip) { return false }
        }
        return true
    }

    /// How a copy was placed after a change that moved, resized, turned or flipped it as a whole,
    /// and not some of the layers in it; nil after any other.
    static func wholeChange(from was: Node, to now: Node, master: Node) -> Instance? {
        // Moved between a light artboard and a dark one, its named looks are no change of its own.
        let now = now.keepingNamedLooks(of: was)
        guard let inst = was.instance, now.instance?.of == inst.of, now.instance?.variant == inst.variant,
              let plan = plan(was, master: master) else { return nil }
        var a: [Leaf] = [], b: [Leaf] = []
        leaves(was.children, into: &a)
        leaves(now.children, into: &b)
        guard !a.isEmpty, a.count == b.count, zip(a, b).allSatisfy({ $0.id == $1.id }) else { return nil }
        // Every tool that resizes a copy whole gives the copy itself its new frame, and stretches
        // what it holds from its old one exactly; a layer resized in it leaves the copy's own frame
        // as it was until it is fitted round it, after this. So a shape resized in a copy, however
        // little at a time, as a drag does, is never taken for the copy resized.
        if was.frame != now.frame, alike(was.children, now.children, but: ["frame", "style", "spans", "grid", "mask"]),
           let found = scaling(a, b, plan) { return found }
        if alike(was.children, now.children, but: ["frame", "rotation"]), let found = turning(a, b, inst) { return found }
        // A flip turns a shape's keys over with its outline (`Node.shapeKeysFlipped`).
        let flipping: Set<String> = ["frame", "rotation", "fill", "moreFills", "border", "moreBorders", "corners", "rising", "path", "pathBox", "motion"]
        if alike(was.children, now.children, but: flipping),
           let found = flipped(a, b, inst, turnedOver: { turnedOver(was.children, now.children, horizontally: $0) }) { return found }
        return nil
    }

    /// Whether what a flip turns over in a layer, its outline, its corners and its gradients, is
    /// in `b` what that flip makes of it in `a`. A layer flipped about its own middle goes
    /// nowhere: only by this is its flip told from a colour changed, and one way from the other.
    private static func turnedOver(_ a: [Node], _ b: [Node], horizontally: Bool) -> Bool {
        let looks: Set<String> = ["fill", "moreFills", "border", "moreBorders", "corners", "rising", "path", "pathBox"]
        let others = Set(LayerField.all.map(\.name)).subtracting(looks)
        let flipped = a.map { BezzleDocument.flipped($0, horizontally: horizontally, about: 0) }
        // Flipped, something that looks the same either way is as it was: no flip to keep.
        guard !alike(flipped, a, but: others.subtracting(["rotation"])) else { return false }
        return alike(flipped, b, but: others)
    }

    private static func close(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat = 1) -> Bool { abs(x - y) <= 0.6 + 0.002 * abs(scale) }

    /// As close as stretching by arithmetic leaves things: a resize moves every layer exactly, and
    /// one layer changed in a copy moves the others not at all, which by a pixel at a time is less
    /// than `close` could tell apart.
    private static func exact(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat = 1) -> Bool { abs(x - y) <= 0.02 + 1e-4 * abs(scale) }

    /// Stretched or moved along its own upright ways: every layer's middle by the same line, every
    /// shape's size by the same share.
    private static func scaling(_ a: [Leaf], _ b: [Leaf], _ plan: Plan) -> Instance? {
        let inst = plan.instance, turn = inst.turn ?? 0
        func upright(_ p: CGPoint) -> CGPoint { Geometry.rotate(p, by: -turn) }
        let shapes = a.indices.filter { !a[$0].text }
        guard !shapes.isEmpty else { return nil }
        let ca = shapes.map { upright(a[$0].frame.center) }, cb = shapes.map { upright(b[$0].frame.center) }
        func fit(_ xs: [CGFloat], _ ys: [CGFloat], _ sizes: [(CGFloat, CGFloat)]) -> (CGFloat, CGFloat)? {
            let mx = xs.reduce(0, +) / CGFloat(xs.count), my = ys.reduce(0, +) / CGFloat(ys.count)
            var s: CGFloat
            if (xs.max()! - xs.min()!) > 1 {
                var num: CGFloat = 0, den: CGFloat = 0
                for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
                s = num / den
            } else if let big = sizes.max(by: { $0.0 < $1.0 }), big.0 > 0.5 {
                s = big.1 / big.0
            } else {
                s = 1
            }
            guard s.isFinite, s > 0.001 else { return nil }
            return (s, my - s * mx)
        }
        guard let (sx, tx) = fit(ca.map(\.x), cb.map(\.x), shapes.map { (a[$0].frame.width, b[$0].frame.width) }),
              let (sy, ty) = fit(ca.map(\.y), cb.map(\.y), shapes.map { (a[$0].frame.height, b[$0].frame.height) }) else { return nil }
        let span = max(plan.to.width, plan.to.height)
        for (i, j) in shapes.enumerated() {
            guard exact(sx * ca[i].x + tx, cb[i].x, span), exact(sy * ca[i].y + ty, cb[i].y, span),
                  exact(sx * a[j].frame.width, b[j].frame.width, span), exact(sy * a[j].frame.height, b[j].frame.height, span) else { return nil }
        }
        // Words go where the rest went too, by the point they stay put at, as they do when the
        // whole is stretched; words left where they were mean only a shape was resized.
        if turn == 0 {
            for (x, y) in zip(a, b) where x.text {
                let ax = x.frame.minX + x.anchor * x.frame.width, bx = y.frame.minX + y.anchor * y.frame.width
                guard exact(sx * ax + tx, bx, span), exact(sy * x.frame.minY + ty, y.frame.minY, span) else { return nil }
            }
        }
        // Moved alone would have left every layer where it lies in the copy.
        guard abs(sx - 1) > 1e-4 || abs(sy - 1) > 1e-4 || abs(tx) > 1e-4 || abs(ty) > 1e-4 else { return nil }
        // The box as it shows, words and all, goes where the layers went; what the words add to it stays.
        let shown = plan.to, box = inst.box
        let middle = Geometry.rotate(CGPoint(x: sx * upright(shown.center).x + tx, y: sy * upright(shown.center).y + ty), by: turn)
        let size = CGSize(width: shown.width * sx, height: shown.height * sy)
        let grown = (l: box.minX - shown.minX, t: box.minY - shown.minY, r: shown.maxX - box.maxX, b: shown.maxY - box.maxY)
        let newShown = CGRect(center: middle, size: size)
        var next = inst
        next.box = CGRect(x: newShown.minX + grown.l, y: newShown.minY + grown.t,
                          width: max(1, newShown.width - grown.l - grown.r), height: max(1, newShown.height - grown.t - grown.b))
        return next
    }

    /// Turned as a whole about some point: every layer by as much, and its middle about that point.
    private static func turning(_ a: [Leaf], _ b: [Leaf], _ inst: Instance) -> Instance? {
        let delta = Geometry.normalized(b[0].rotation - a[0].rotation)
        guard abs(delta) > 0.01 else { return nil }
        let r = Geometry.radians(delta), c = cos(r), s = sin(r)
        // c' - p = R(c - p): (I - R)p = c' - Rc.
        let p0 = a[0].frame.center, p1 = b[0].frame.center
        let rc = CGPoint(x: c * p0.x - s * p0.y, y: s * p0.x + c * p0.y)
        let v = CGPoint(x: p1.x - rc.x, y: p1.y - rc.y)
        let m00 = 1 - c, m01 = s, m10 = -s, m11 = 1 - c
        let det = m00 * m11 - m01 * m10
        guard abs(det) > 1e-9 else { return nil }
        let pivot = CGPoint(x: (m11 * v.x - m01 * v.y) / det, y: (-m10 * v.x + m00 * v.y) / det)
        for (x, y) in zip(a, b) {
            guard abs(Geometry.normalized(y.rotation - x.rotation - delta)) < 0.05,
                  abs(x.frame.width - y.frame.width) < 0.01, abs(x.frame.height - y.frame.height) < 0.01 else { return nil }
            let moved = Geometry.rotated(x.frame.center, about: pivot, by: delta)
            guard close(moved.x, y.frame.center.x), close(moved.y, y.frame.center.y) else { return nil }
        }
        var next = inst
        let t = Geometry.normalized((inst.turn ?? 0) + delta)
        next.turn = abs(t) < 1e-9 ? nil : t
        next.box = CGRect(center: Geometry.rotated(inst.box.center, about: pivot, by: delta), size: inst.box.size)
        return next
    }

    /// Flipped as a whole across an upright or a level line.
    private static func flipped(_ a: [Leaf], _ b: [Leaf], _ inst: Instance, turnedOver: (Bool) -> Bool) -> Instance? {
        for horizontally in [true, false] {
            let axis = horizontally ? (a[0].frame.midX + b[0].frame.midX) / 2 : (a[0].frame.midY + b[0].frame.midY) / 2
            let fits = zip(a, b).allSatisfy { x, y in
                let mx = horizontally ? 2 * axis - x.frame.midX : x.frame.midX
                let my = horizontally ? x.frame.midY : 2 * axis - x.frame.midY
                // Exactly: a centred label lies across the line, so a shape in a copy moved half a
                // pixel, as a pull on its edge snapped to whole pixels does, was nearly a flip.
                return exact(mx, y.frame.midX) && exact(my, y.frame.midY)
                    && abs(x.frame.width - y.frame.width) < 0.01 && abs(x.frame.height - y.frame.height) < 0.01
                    && abs(Geometry.normalized(y.rotation + x.rotation)) < 0.05
            }
            // Something lying across the line itself stays where it is. With nothing gone anywhere,
            // as one layer alone flipped about its own middle, what was turned over in it shows
            // that it was flipped, and which way: a colour changed in it is no flip.
            guard fits, zip(a, b).contains(where: { abs($0.frame.midX - $1.frame.midX) > 0.01 || abs($0.frame.midY - $1.frame.midY) > 0.01 })
                    || turnedOver(horizontally) else { continue }
            var next = inst
            let c = inst.box.center
            if horizontally {
                next.flipX = inst.flipX == true ? nil : true
                next.box = CGRect(center: CGPoint(x: 2 * axis - c.x, y: c.y), size: inst.box.size)
            } else {
                next.flipY = inst.flipY == true ? nil : true
                next.box = CGRect(center: CGPoint(x: c.x, y: 2 * axis - c.y), size: inst.box.size)
            }
            if let t = inst.turn, t != 0 { next.turn = Geometry.normalized(-t) }
            return next
        }
        return nil
    }
}

// MARK: - Keeping every copy alike


/// What a change did to the copies of components, for the canvas to show: the copies changed by
/// hand, and the copies that followed.
struct ComponentEcho {
    var from: [UUID]
    var to: [UUID]
    /// Whether these were just made copies, by making a component or linking to one.
    var made = false
}

extension BezzleDocument {
    /// Keeps every copy of every component alike after a change, `before` being the design before
    /// it and `start` as it was when a drag began. A change to some of the layers in a copy is
    /// carried to its component, and every copy of that component is made from it again; a copy
    /// moved, resized, turned or flipped as a whole keeps that as its own and is laid out again in
    /// its new box. A copy whose component is gone is a group like any other. Returns what changed.
    @discardableResult
    mutating func syncComponents(since before: BezzleDocument, start: BezzleDocument? = nil) -> ComponentEcho? {
        guard components != nil || before.components != nil else { return nil }
        var list = masters
        let wasMasters = Dictionary(before.masters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set(list.filter { wasMasters[$0.id] != $0 }.map(\.id))
        let present = Set(list.map(\.id))

        // The copies changed since, however deep: a button in a card before the card.
        var found: [(was: Node?, now: Node, depth: Int)] = []
        func look(_ nodes: [Node], depth: Int) {
            for n in nodes {
                let was = before.node(n.id)
                if let was, was == n { continue }
                if n.instance != nil { found.append((was, n, depth)) }
                if !n.children.isEmpty { look(n.children, depth: depth + 1) }
            }
        }
        look(nodes, depth: 0)
        let edited = found.enumerated().sorted { ($0.element.depth, -$0.offset) > ($1.element.depth, -$1.offset) }.map { ($0.element.was, $0.element.now) }
        guard !edited.isEmpty || !changed.isEmpty || wasMasters.count != list.count || wasMasters.keys.contains(where: { !present.contains($0) }) else { return nil }

        var rebuild = Set<UUID>(), placements: [UUID: Instance] = [:], sources: [UUID] = [], fronts: [UUID: Int?] = [:]
        for (was, now) in edited {
            guard let inst = now.instance, let i = list.firstIndex(where: { $0.id == inst.of }) else { continue }
            guard let then = was, let wi = then.instance, wi.of == inst.of else {
                rebuild.insert(now.id)
                continue
            }
            // A tool that works from the copy as the drag began, as a handle does, puts that back
            // first and changes it from there: what it did is measured from there too.
            let began = start?.node(now.id)
            let was = wi != inst && began?.instance == inst ? began! : then
            if was.instance != inst || was.children == now.children {
                if was.instance != inst || then.children != now.children { rebuild.insert(now.id) }
                continue
            }
            // A copy left empty is going.
            if now.children.isEmpty { continue }
            // Only from what this step began with: a layer dragged in a copy is set back where the
            // drag began each step, but the copy's other layers are as the last step laid them out,
            // round it as it had grown by then, and from where the drag began, that would look like
            // the whole copy stretched. Taken so at one step and not at the next, the copy and its
            // component drifted apart further at every step, and every copy grew without end.
            if let placed = Components.wholeChange(from: was, to: now, master: list[i]) {
                placements[now.id] = placed
                rebuild.insert(now.id)
                continue
            }
            var m = list[i]
            // A copy in it placed anew, as a button resized in a card, is placed so in its
            // component: it is made again from its own when that is.
            var now = now
            if !placements.isEmpty { Components.place(&now, placements) }
            Components.carry(from: was, to: now, into: &m)
            rebuild.insert(now.id)
            sources.append(now.id)
            if m != list[i] {
                list[i] = m
                changed.insert(m.id)
                if fronts[m.id] == nil { fronts[m.id] = Components.variant(inst.variant, of: m) }
            }
        }

        // Each variant made again from the first, keeping what it looks like otherwise; and every
        // component fitted round what it holds.
        for i in list.indices where changed.contains(list[i].id) {
            var m = list[i]
            if let variants = m.master?.variants, !variants.isEmpty {
                let front = fronts[m.id] ?? nil
                // What is changed in a copy of a variant is that variant's own: the others stay as they are.
                if let front, let was = wasMasters[m.id] { Components.keepInVariant(&m, was: was, variant: front) }
                m.deck = Deck(posts: variants)
                var was = wasMasters[m.id]
                if let info = was?.master { was?.deck = Deck(posts: info.variants) }
                Deck.sync(&m, was: front == nil ? nil : was, front: front)
                m.deck = nil
            }
            list[i] = Self.fitted(m)
        }
        // A component never holds a copy of itself, however deep: one put in, as a card dragged into
        // a button in it, is a group like any other.
        Self.breakCycles(&list, changed: &changed)
        // Copies held by components made again from theirs, so a card holding buttons changes as its
        // buttons do; and those holding it after them.
        for _ in 0..<6 {
            var progress = false
            let current = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in list.indices where list[i].children.contains(where: \.marksCopy) {
                let used = Set(list[i].componentsUsed)
                // A component changed itself, as by a copy of another in it shown as another variant,
                // makes that copy again too.
                guard !used.isDisjoint(with: changed) || changed.contains(list[i].id) || used.contains(where: { current[$0] == nil }) else { continue }
                let kids = list[i].children.map { Components.rebuildingNested($0, masters: current, mastersWas: wasMasters, depth: 1) }
                guard kids != list[i].children else { continue }
                var m = list[i]
                m.children = kids
                list[i] = Self.fitted(m)
                changed.insert(m.id)
                progress = true
            }
            if !progress { break }
        }
        if list != masters { masters = list }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Every copy of a changed component, and every copy changed, made again.
        var updates: [(NodePath, Node)] = []
        var followed: [UUID] = []
        func visit(_ nodes: [Node], _ at: [Int]) {
            for (j, n) in nodes.enumerated() {
                guard let inst = n.instance else {
                    if !n.children.isEmpty { visit(n.children, at + [j]) }
                    continue
                }
                let path = NodePath(indices: at + [j])
                guard let master = byID[inst.of] else {
                    // Its component is gone: a group like any other, and copies in it made again.
                    updates.append((path, Components.rebuildingNested(n.unlinked(), masters: byID, mastersWas: wasMasters, depth: 1)))
                    continue
                }
                guard changed.contains(inst.of) || rebuild.contains(n.id) else {
                    // Not made again itself: copies of others in it may be.
                    if !n.children.isEmpty { visit(n.children, at + [j]) }
                    continue
                }
                var copy = n
                if let placed = placements[n.id] { copy.instance = placed }
                // The component grown or shrunk at an edge: the copy too, by as much.
                if let was = wasMasters[inst.of], was != master, var placed = copy.instance,
                   !Components.layers(of: was, variant: placed.variant).isEmpty {
                    let a = Components.box(of: was, variant: placed.variant), b = Components.box(of: master, variant: placed.variant)
                    if a != b {
                        placed.box = CGRect(x: placed.box.minX + (b.minX - a.minX), y: placed.box.minY + (b.minY - a.minY),
                                            width: max(1, placed.box.width + (b.width - a.width)), height: max(1, placed.box.height + (b.height - a.height)))
                        copy.instance = placed
                    }
                }
                let built = Components.build(copy, master: master, masterWas: wasMasters[inst.of], masters: byID, mastersWas: wasMasters)
                if built != n {
                    updates.append((path, built))
                    // Only what followed a change made elsewhere lights up: not a copy moved, turned
                    // or resized itself, nor one just made.
                    if !rebuild.contains(n.id), changed.contains(inst.of) { followed.append(n.id) }
                }
            }
        }
        visit(nodes, [])
        guard !updates.isEmpty || !sources.isEmpty else { return ComponentEcho(from: sources, to: followed) }
        if !updates.isEmpty {
            let sameLayers = updates.allSatisfy { path, node in Self.sameIDs(self[path], node) }
            if sameLayers {
                for (path, node) in updates { update(self[path].id) { $0 = node } }
            } else {
                var all = nodes
                for (path, node) in updates { Self.put(node, at: path.indices[...], in: &all) }
                nodes = all
            }
        }
        return ComponentEcho(from: sources, to: followed)
    }

    /// A component's group fitted round what it holds.
    static func fitted(_ m: Node) -> Node {
        var d = BezzleDocument()
        d.nodes = [m]
        d.fitGroups()
        return d.nodes.first ?? m
    }

    /// Unlinks every copy a component holds, however deep, whose own component holds this one, or
    /// is it: what would make a copy of a thing inside the thing itself.
    static func breakCycles(_ list: inout [Node], changed: inout Set<UUID>) {
        var doc = BezzleDocument()
        doc.masters = list
        for i in list.indices where list[i].children.contains(where: \.marksCopy) {
            let me = list[i].id
            func clean(_ n: Node) -> Node {
                if let inst = n.instance, inst.of == me || doc.uses(inst.of).contains(me) { return clean(n.unlinked()) }
                guard n.marksCopy else { return n }
                var m = n
                m.children = n.children.map(clean)
                return m
            }
            let kids = list[i].children.map(clean)
            if kids != list[i].children {
                list[i].children = kids
                changed.insert(me)
                doc.masters = list
            }
        }
    }

    private static func put(_ node: Node, at indices: ArraySlice<Int>, in list: inout [Node]) {
        guard let i = indices.first, i < list.count else { return }
        if indices.count == 1 { list[i] = node } else { put(node, at: indices.dropFirst(), in: &list[i].children) }
    }

    /// Whether two layers hold the same layers, by id, in the same order, all the way down.
    private static func sameIDs(_ a: Node, _ b: Node) -> Bool {
        a.id == b.id && a.children.count == b.children.count && zip(a.children, b.children).allSatisfy { sameIDs($0, $1) }
    }

    /// Makes every copy changed since `before` again from its component, as it is now, carrying
    /// nothing to the component: for what lays copies out again by rules of its own, as a repeat
    /// grid lays its cells out anew as the first once a drag ends. A button in a cell grows round
    /// its words again, as it did while they were typed.
    mutating func remakeCopies(since before: BezzleDocument) {
        guard let list = components, !list.isEmpty else { return }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var updates: [(NodePath, Node)] = []
        func visit(_ nodes: [Node], _ at: [Int]) {
            for (j, n) in nodes.enumerated() {
                if let was = before.node(n.id), was == n { continue }
                guard let inst = n.instance, let master = byID[inst.of] else {
                    if !n.children.isEmpty { visit(n.children, at + [j]) }
                    continue
                }
                let built = Components.build(n, master: master, masterWas: nil, masters: byID)
                if built != n { updates.append((NodePath(indices: at + [j]), built)) }
            }
        }
        visit(nodes, [])
        guard !updates.isEmpty else { return }
        var all = nodes
        for (path, node) in updates { Self.put(node, at: path.indices[...], in: &all) }
        nodes = all
    }

    /// Makes every copy that does not hold what its component's variant holds again, as on a
    /// design put together from changes made on several Macs, which each kept their copies alike.
    mutating func reconcileComponents() {
        guard let list = components, !list.isEmpty else {
            if components == nil, nodes.contains(where: { $0.marksCopy }) { stripCopies() }
            return
        }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var updates: [(NodePath, Node)] = []
        func visit(_ nodes: [Node], _ at: [Int]) {
            for (j, n) in nodes.enumerated() {
                guard let inst = n.instance else {
                    if !n.children.isEmpty { visit(n.children, at + [j]) }
                    continue
                }
                let path = NodePath(indices: at + [j])
                guard let master = byID[inst.of] else {
                    updates.append((path, Components.rebuildingNested(n.unlinked(), masters: byID, mastersWas: [:], depth: 1)))
                    continue
                }
                guard let k = Components.key(of: n) else { continue }
                let expected = Components.layers(of: master, variant: inst.variant).map { RepeatGrid.copy($0, k) }
                // By the layers of this copy alone: what copies in it hold is theirs to put right.
                func ids(_ ns: [Node]) -> [UUID] { ns.flatMap { [$0.id] + ($0.instance == nil ? ids($0.children) : []) } }
                guard ids(expected) != ids(n.children) else {
                    if !n.children.isEmpty { visit(n.children, at + [j]) }
                    continue
                }
                updates.append((path, Components.build(n, master: master, masterWas: nil, masters: byID)))
            }
        }
        visit(nodes, [])
        guard !updates.isEmpty else { return }
        var all = nodes
        for (path, node) in updates { Self.put(node, at: path.indices[...], in: &all) }
        nodes = all
    }

    private mutating func stripCopies() {
        nodes = nodes.map { $0.withoutCopies() }
    }
}

nonisolated extension Node {
    /// Whether this layer or anything it holds is a copy of a component.
    var marksCopy: Bool { instance != nil || children.contains(where: \.marksCopy) }

    /// This layer with every copy in it, however deep, made a group like any other.
    func withoutCopies() -> Node {
        guard marksCopy else { return self }
        var n = instance != nil ? unlinked() : self
        n.children = n.children.map { $0.withoutCopies() }
        return n
    }
}

nonisolated extension BezzleDocument {
    /// Takes away what could not be put together from changes made on several Macs: copies of
    /// components no longer there are groups like any other, and components list only the variants
    /// they hold.
    mutating func repairComponents() {
        let ids = Set(masters.map(\.id))
        func strip(_ n: Node) -> Node {
            guard n.marksCopy else { return n }
            var m = n
            if let i = n.instance, !ids.contains(i.of) { m = n.unlinked() }
            m.children = m.children.map(strip)
            return m
        }
        if nodes.contains(where: { $0.marksCopy }) {
            let fixed = nodes.map(strip)
            if fixed != nodes { nodes = fixed }
        }
        guard var list = components else { return }
        var changed = false
        for i in list.indices where list[i].children.contains(where: \.marksCopy) {
            let kids = list[i].children.map(strip)
            if kids != list[i].children {
                list[i].children = kids
                changed = true
            }
        }
        for i in list.indices {
            guard var info = list[i].master else { continue }
            let held = Set(list[i].children.compactMap(\.post))
            let kept = info.variants.filter { held.contains($0) } + held.subtracting(info.variants).sorted()
            if kept != info.variants {
                info.variants = kept
                list[i].master = info
                changed = true
            }
        }
        if changed { components = list }
    }
}
