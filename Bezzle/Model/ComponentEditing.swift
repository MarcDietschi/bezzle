import Foundation
import CoreGraphics

/// Making and changing components (see `Components`), shared by every Bezzle: the Mac's store
/// calls these inside its steps of the history, as Windows does.
extension BezzleDocument {
    // MARK: The copy being worked on

    /// The copy the selection is in, or that is selected, when one thing is.
    func selectedCopy(_ selection: [UUID]) -> Node? {
        guard selection.count == 1 else { return nil }
        return copy(holding: selection[0])
    }

    /// The selected copies, each once, whatever in them is selected.
    func selectedCopies(_ selection: [UUID]) -> [Node] {
        var seen = Set<UUID>(), out: [Node] = []
        for id in selection {
            if let c = copy(holding: id), seen.insert(c.id).inserted { out.append(c) }
        }
        return out
    }

    /// The component a copy is a copy of.
    func component(of copy: Node) -> Node? { copy.instance.flatMap { master($0.of) } }

    /// The copies of a component in the order they are read: artboard by artboard, then from the
    /// top, then from the left.
    func copiesInOrder(of master: UUID) -> [UUID] {
        copies(of: master).compactMap { c in absoluteFrame(of: c.id).map { (c.id, $0) } }
            .sorted { a, b in
                let ba = artboard(of: a.0).flatMap { path(of: $0.id)?.top } ?? Int.max
                let bb = artboard(of: b.0).flatMap { path(of: $0.id)?.top } ?? Int.max
                if ba != bb { return ba < bb }
                if abs(a.1.minY - b.1.minY) > 4 { return a.1.minY < b.1.minY }
                return a.1.minX < b.1.minX
            }
            .map(\.0)
    }

    // MARK: Making one

    /// Whether layers can be made a component: on one artboard, or the canvas, none of them an
    /// artboard or in a copy already, and not a copy itself.
    func canMakeComponent(_ selection: [UUID]) -> Bool {
        guard !selection.isEmpty else { return false }
        if selection.count == 1, let n = node(selection[0]) {
            if n.isCopy || n.isArtboard || n.locked || insideCopy(n.id) { return false }
            // A group is a component as it is, wherever it lies, a repeat grid's cell too.
            if n.isGroup, !n.isRepeatGrid, !n.isMask { return true }
        }
        // Copies may go into it, as a button into a card; what lies inside a copy may not.
        return selection.allSatisfy { id in !insideCopy(id) && node(id)?.locked == false } && groupable(selection) != nil
    }

    /// Makes layers a component and returns its first copy: one group as it is, or anything else
    /// put into a group first. A part of a kit is named by `part`, so the same part dropped in
    /// again is another copy.
    @discardableResult
    mutating func makeComponent(from ids: [UUID], name: String? = nil, part: String? = nil) -> UUID? {
        guard !ids.isEmpty, ids.allSatisfy({ !insideCopy($0) }),
              ids.count > 1 || node(ids[0])?.isCopy == false else { return nil }
        let target: UUID
        if ids.count == 1, let n = node(ids[0]), n.isGroup, !n.isRepeatGrid, !n.isMask {
            target = ids[0]
        } else {
            let single = ids.count == 1 ? node(ids[0])?.name : nil
            guard let g = group(ids, name: name ?? single ?? componentName()) else { return nil }
            fitGroups()
            target = g
        }
        guard let path = path(of: target) else { return nil }
        var g = self[path]
        let k = Components.freshKey()
        var master = RepeatGrid.copy(g, k).forgettingOwn()
        master.post = nil
        master.hidden = false
        master.locked = false
        master.exports = nil
        master.instance = nil
        master.frame.origin = .zero
        master.master = Master(part: part)
        master.children = master.children.map { var c = $0; c.post = nil; return c }
        if let name { master.name = name }
        g.name = master.name
        g.instance = Instance(of: master.id, variant: nil, box: CGRect(origin: .zero, size: g.frame.size))
        self[path] = g
        masters.append(master)
        return g.id
    }

    /// A name for a new component: "Component 1", the first not taken.
    func componentName() -> String {
        let taken = Set(masters.map(\.name) + allNodes.map(\.name))
        var i = 1
        while taken.contains(String(localized: "Component \(i)")) { i += 1 }
        return String(localized: "Component \(i)")
    }

    /// The groups in the design that look the same as a copy's component and could be copies of it.
    func lookAlikes(of copyID: UUID) -> [UUID] {
        guard let copy = node(copyID), let inst = copy.instance, let master = master(inst.of) else { return [] }
        let layers = Components.layers(of: master, variant: nil)
        var found: [UUID] = []
        func visit(_ nodes: [Node], inDeck: Bool) {
            for n in nodes {
                if n.isCopy || n.id == copyID { continue }
                if n.isGroup, !n.locked, Components.looksAlike(n, layers) {
                    found.append(n.id)
                    continue
                }
                if !n.isRepeatGrid { visit(inDeck ? n.layers(of: nil) + n.children.filter { $0.post != nil } : n.children, inDeck: false) }
            }
        }
        visit(nodes, inDeck: false)
        // In a deck, its design behind the posts goes with the posts: those are linked as it is.
        return found.filter { id in post(of: id).map { $0.post != nil } ?? true }
    }

    /// Makes a group that looks the same as a component a copy of it; the copy.
    @discardableResult
    mutating func link(_ id: UUID, to masterID: UUID) -> UUID? {
        guard let x = node(id), let master = master(masterID), let path = path(of: id) else { return nil }
        let layers = Components.layers(of: master, variant: nil)
        guard Components.looksAlike(x, layers) else { return nil }
        let k = Components.freshKey()
        func rekeyed(_ a: Node, _ b: Node) -> Node {
            var n = a
            n.id = b.id.mixed(k)
            n.own = nil
            n.post = nil
            n.children = zip(a.children, b.children).map { rekeyed($0, $1) }
            if let am = a.mask, let bm = b.mask, am.count == bm.count { n.mask = zip(am, bm).map { rekeyed($0, $1) } }
            return n
        }
        var c = x
        c.id = masterID.mixed(k)
        c.children = zip(x.children, layers).map { rekeyed($0, $1) }
        let box = CGRect(origin: .zero, size: x.frame.size)
        c.instance = Instance(of: masterID, variant: nil, box: box)
        // Its words may be longer than the component's, and the box grows round them by as much
        // again when it is laid out: kept as big as it would be with the component's words.
        if let shown = Components.plan(c, master: master)?.to, shown != box {
            c.instance?.box = CGRect(x: box.minX - (shown.minX - box.minX), y: box.minY - (shown.minY - box.minY),
                                     width: max(1, box.width - (shown.width - box.width)), height: max(1, box.height - (shown.height - box.height)))
        }
        self[path] = c
        return c.id
    }

    // MARK: Unlinking and naming

    /// Makes copies groups like any other, which keep how they look and no longer change with
    /// their component.
    mutating func unlink(_ copies: [UUID]) {
        for id in copies { update(id) { $0 = $0.unlinked() } }
    }

    mutating func renameComponent(_ masterID: UUID, to name: String) {
        guard let i = masters.firstIndex(where: { $0.id == masterID }) else { return }
        let old = masters[i].name
        masters[i].name = name
        // Copies still called after it are called after it again.
        for c in copies(of: masterID) where c.name == old { update(c.id) { $0.name = name } }
    }

    // MARK: Variants

    /// Shows these copies as one of their component's variants. Returns where each layer of them
    /// went (the same layer in the variant shown), so what was selected in them can be selected
    /// in it.
    @discardableResult
    mutating func setVariant(_ v: Int?, of copies: [Node]) -> [UUID: UUID] {
        var moved: [UUID: UUID] = [:]
        for c in copies where !c.locked {
            guard let master = component(of: c), let inst = c.instance else { continue }
            let next = Components.switched(c, to: v, in: master)
            guard next.instance != inst else { continue }
            let from = Deck.key(Components.variant(inst.variant, of: master)), to = Deck.key(Components.variant(v, of: master))
            func note(_ n: Node) {
                moved[n.id] = n.id.mixed(from ^ to)
                n.children.forEach(note)
            }
            c.children.forEach(note)
            update(c.id) { $0 = next }
        }
        return moved
    }

    /// Adds a variant to a copy's component, as the copy looks now, and shows it in the copy;
    /// the variant. Until anything is changed in it, it is the same as the copy was; what is
    /// changed first in it is its own. `before`, from the offer after a change: the component as
    /// it was, so the other copies go back to how they were.
    @discardableResult
    mutating func addVariant(from copy: Node, keeping changes: [UUID: [String]] = [:], before: BezzleDocument? = nil) -> Int? {
        guard let inst = copy.instance, let i = masters.firstIndex(where: { $0.id == inst.of }) else { return nil }
        var master = before?.master(inst.of) ?? masters[i]
        // It shows as big as it did, though its words are now the variant's own.
        let shown = Components.plan(copy, master: master)?.to
        guard let n = Components.addVariant(from: copy, keeping: changes, to: &master) else { return nil }
        masters[i] = master
        update(copy.id) { c in
            if let shown { c = Components.showing(c, variant: n, of: master, at: shown) } else { c.instance?.variant = n }
            // What it kept of its own is the variant's now.
            c = Node.forgettingOwnLooks(c)
        }
        return n
    }

    mutating func renameVariant(_ v: Int?, of masterID: UUID, to name: String) {
        guard let i = masters.firstIndex(where: { $0.id == masterID }), var info = masters[i].master else { return }
        var names = info.names ?? [:]
        names[String(Components.variant(v, of: masters[i]) ?? 0)] = name.isEmpty ? nil : name
        info.names = names.isEmpty ? nil : names
        masters[i].master = info
    }

    /// Takes a variant away from a component; its copies, on the canvas and in other components,
    /// show the first variant.
    mutating func removeVariant(_ v: Int, of masterID: UUID) {
        guard let master = master(masterID) else { return }
        for c in copies(of: masterID) where c.instance?.variant == v { update(c.id) { $0 = Components.switched($0, to: nil, in: master) } }
        func switching(_ n: Node) -> Node {
            guard n.marksCopy else { return n }
            var m = n.instance?.of == masterID && n.instance?.variant == v ? Components.switched(n, to: nil, in: master) : n
            m.children = m.children.map(switching)
            return m
        }
        for j in masters.indices where masters[j].id != masterID { masters[j].children = masters[j].children.map(switching) }
        guard let i = masters.firstIndex(where: { $0.id == masterID }) else { return }
        masters[i].children.removeAll { $0.post == v }
        masters[i].master?.variants.removeAll { $0 == v }
        masters[i].master?.names?[String(v)] = nil
    }

    // MARK: A copy's own

    /// Whether a copy keeps anything of its own besides its words and pictures.
    static func hasOwnLooks(_ copy: Node) -> Bool {
        func any(_ n: Node) -> Bool { n.own?.isEmpty == false || n.children.contains(where: any) }
        return copy.children.contains(where: any)
    }

    /// Lets a copy look as its component does again in everything it kept of its own; its words
    /// and pictures stay.
    mutating func resetCopy(_ id: UUID) {
        guard let copy = node(id), copy.isCopy, Self.hasOwnLooks(copy), let master = component(of: copy) else { return }
        var c = Node.forgettingOwnLooks(copy)
        c = Components.build(c, master: master, masterWas: nil, masters: mastersByID)
        update(id) { $0 = c }
    }
}

nonisolated extension Node {
    /// A copy forgetting what its layers kept of their own besides their words and pictures.
    static func forgettingOwnLooks(_ copy: Node) -> Node {
        var c = copy
        c.children = copy.children.map { $0.forgettingOwn() }
        return c
    }
}

extension Components {
    /// A new copy of a component, its top left at `origin` on the canvas, as big as the component
    /// unless `size` says otherwise, with the component's words.
    static func newCopy(of master: Node, variant: Int? = nil, at origin: CGPoint, size: CGSize? = nil, masters: [UUID: Node] = [:]) -> Node {
        let k = freshKey()
        let v = Self.variant(variant, of: master)
        let layers = layers(of: master, variant: v)
        let from = box(of: layers)
        let s = size ?? from.size
        var c = Node(kind: .group, name: master.name, frame: CGRect(origin: origin, size: s))
        c.id = master.id.mixed(k)
        c.instance = Instance(of: master.id, variant: v, box: CGRect(origin: .zero, size: s))
        // Laid where the component has them, then out into the copy's box.
        c.children = layers.map { var n = RepeatGrid.copy($0, k); n.post = nil; n.own = nil; return n }
        c.children = c.children.map { var n = $0; n.frame = n.frame.offsetBy(dx: -from.minX, dy: -from.minY); return n }
        return followingOutlines(build(c, master: master, masterWas: nil, masters: masters), from: c)
    }

    /// A new copy, laid out in its box, with the Shape keys of each of its layers going with the
    /// outline it has there, as they go with a layer resized in the design
    /// (`Node.shapeKeys(following:)`): `made` is the copy as it was before it was laid out, its
    /// layers as large as the component's. A copy made at another size than the component's has
    /// no outline before it in the design for `BezzleDocument.followOutlines` to go by.
    static func followingOutlines(_ copy: Node, from made: Node) -> Node {
        guard copy.holdsShapeKeys else { return copy }
        var was: [UUID: Node] = [:]
        func note(_ n: Node) {
            was[n.id] = n
            n.children.forEach(note)
        }
        made.children.forEach(note)
        func follow(_ n: Node) -> Node {
            var m = n
            if let then = was[n.id], let keys = n.shapeKeys(following: then) { m[track: .shape] = keys }
            m.children = n.children.map(follow)
            return m
        }
        var out = copy
        out.children = copy.children.map(follow)
        return out
    }

    /// The layers a component would be given that are alike in every way but where they are, how
    /// big, and their words and pictures: whether a group could be a copy of it.
    static func looksAlike(_ group: Node, _ layers: [Node]) -> Bool {
        guard group.isGroup, !group.isCopy, !group.isRepeatGrid, group.children.count == layers.count else { return false }
        return zip(group.children, layers).allSatisfy { alike($0, $1) }
    }

    private static let loose: Set<String> = ["frame", "text", "spans", "name", "exports", "hidden", "locked", "post", "own", "instance", "master"]

    private static func alike(_ a: Node, _ b: Node) -> Bool {
        guard a.kind == b.kind, a.children.count == b.children.count,
              a.instance?.of == b.instance?.of, a.instance?.variant == b.instance?.variant else { return false }
        for field in LayerField.all where !loose.contains(field.name) && !field.same(a, b) {
            if field.name == "fill" {
                var f = a.fill, g = b.fill
                f.image = nil
                g.image = nil
                if f == g { continue }
            }
            return false
        }
        return zip(a.children, b.children).allSatisfy { alike($0, $1) }
    }

    /// A component's variant made from a copy as it is now: what the copy keeps of its own, and what
    /// `changes` names of its layers, by their ids, are the variant's, as the copy has them; and its
    /// words and pictures are what new copies of the variant hold. Returns its number.
    static func addVariant(from copy: Node, keeping changes: [UUID: [String]], named name: String? = nil, to master: inout Node) -> Int? {
        guard var info = master.master, let plan = plan(copy, master: master) else { return nil }
        let n = Deck.number(besides: info.variants)
        let k0 = Deck.key(plan.variant), kn = Deck.key(n)
        let laid = unplaced(copy.children, plan)
        var byLayer: [UUID: Node] = [:]
        func note(_ c: Node) {
            byLayer[c.id.mixed(plan.key)] = c
            c.children.forEach(note)
        }
        laid.forEach(note)
        let named = Dictionary(changes.map { ($0.key.mixed(plan.key), $0.value) }, uniquingKeysWith: { a, b in a + b })
        func make(_ m: Node, top: Bool) -> Node {
            var x = m
            x.id = m.id.mixed(k0 ^ kn)
            x.children = m.children.map { make($0, top: false) }
            x.mask = m.mask?.map { RepeatGrid.copy($0, k0 ^ kn) }
            x.post = top ? n : nil
            if let c = byLayer[m.id] {
                var own = Set(m.own ?? [])
                for name in (named[m.id] ?? []) + (c.own ?? []) where keepable.contains(name) {
                    Deck.fields[name]?.copy(&x, c)
                    own.insert(name)
                }
                if c.kind == .text, x.kind == .text, c.text != x.text || c.spans != x.spans {
                    x.text = c.text
                    x.spans = c.spans
                    // As big as its words, round where it stays, as the variant's layers are made
                    // again from the first's (`Deck.sync`).
                    refit(&x, pins: plan.pins[m.id])
                }
                x.fill.image = c.fill.image
                x.own = own.isEmpty ? nil : own.sorted()
            }
            return x
        }
        master.children += plan.layers.map { make($0, top: true) }
        info.variants.append(n)
        if let name, !name.isEmpty {
            var names = info.names ?? [:]
            names[String(n)] = name
            info.names = names
        }
        master.master = info
        master.children = ordered(master)
        return n
    }

    /// A copy shown as another variant: its box grown or shrunk at its edges as the variant's
    /// layers take up more or less room than its own did, its words and pictures kept.
    static func switched(_ copy: Node, to v: Int?, in master: Node) -> Node {
        guard let inst = copy.instance else { return copy }
        let to = variant(v, of: master)
        guard to != variant(inst.variant, of: master) else { return copy }
        let a = box(of: master, variant: inst.variant), b = box(of: master, variant: to)
        // From the size it shows, its words and all: the variant's words may be longer or shorter
        // than those of the one it showed, and its box is what its words grow it from.
        let shown = plan(copy, master: master)?.to ?? inst.box
        let next = CGRect(x: shown.minX + (b.minX - a.minX), y: shown.minY + (b.minY - a.minY),
                          width: max(1, shown.width + b.width - a.width), height: max(1, shown.height + b.height - a.height))
        return showing(copy, variant: to, of: master, at: next)
    }
}
