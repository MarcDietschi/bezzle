import Foundation
import CoreGraphics

/// What is offered for a moment after a change to a copy of a component: to narrow what the change
/// reached, or to widen it. A change to a copy's look reaches every copy, so the word offers to keep
/// it in this one alone, or to make it a variant of its own; a change to its words or picture stays
/// in it, so the word offers it to every copy; and a component just made offers to link the groups
/// that look the same as it.
struct ComponentOffer {
    enum Kind {
        /// What each layer of the copy had changed, and the design as it was before.
        case reached(copy: UUID, changes: [UUID: [String]], before: BezzleDocument)
        /// The copy's layers whose words or picture changed.
        case kept(copy: UUID, layers: [UUID])
        /// Groups that look the same as the copy, the component just made of it.
        case lookAlikes(copy: UUID, found: [UUID])
    }

    enum Action: Hashable {
        /// In this copy alone.
        case onlyHere
        /// In this copy's variant alone.
        case onlyVariant
        /// A new variant, of this copy as it is.
        case newVariant
        /// The words and pictures in every copy.
        case everywhere
        /// What was changed in a variant, in every variant.
        case allVariants
        /// The look-alikes linked to the component.
        case link
    }

    /// The copy it is about, beside which it shows.
    let anchor: UUID
    let kind: Kind
    let words: String
    let buttons: [(action: Action, title: String)]
    let token = UUID()
}

/// What can be made of a change to a copy of a component, and doing it, shared by every Bezzle:
/// the Mac's store offers it for a moment under the copy, as Windows does.
extension BezzleDocument {
    /// Looks at what a change did to the copy it was made in, and what can be made of it: see
    /// `ComponentOffer`. `before` is the design before the change, `echo` what the change did to
    /// copies (`syncComponents`).
    func componentOffer(after before: BezzleDocument, echo: ComponentEcho?) -> ComponentOffer? {
        guard let echo, let source = echo.from.first, let copy = node(source), let inst = copy.instance,
              let master = master(inst.of), let was = before.node(source), was.instance?.variant == inst.variant else { return nil }
        let count = copies(of: master.id).count
        guard count > 1 else { return nil }
        var then: [UUID: Node] = [:]
        func note(_ n: Node) {
            then[n.id] = n
            n.children.forEach(note)
        }
        was.children.forEach(note)
        var style: [UUID: [String]] = [:], content: [UUID] = []
        func visit(_ n: Node) {
            defer { n.children.forEach(visit) }
            guard let q = then[n.id], q != n else { return }
            let words = n.kind == .text && n.text != q.text
            var a = n.fill, b = q.fill
            a.image = nil
            b.image = nil
            let picture = n.fill.image != q.fill.image
            let names = LayerField.all.filter { field in
                Components.keepable.contains(field.name) && !field.same(n, q)
                    && !(field.name == "fill" && a == b)
                    && !(field.name == "spans" && words)
            }.map(\.name)
            if words || picture { content.append(n.id) }
            if !names.isEmpty { style[n.id] = names }
        }
        copy.children.forEach(visit)
        if !content.isEmpty {
            // Words or a picture, and what moved round them: every other copy has its own. Offered
            // to them all only where the copy still held the component's own, as a label first
            // changed does; words already its own are what this copy is for.
            guard style.values.allSatisfy({ $0 == ["frame"] }), let k = Components.key(of: copy) else { return nil }
            let design = Components.designIDs(of: master)
            var held: [UUID: Node] = [:]
            func noteMaster(_ n: Node) {
                held[n.id] = n
                n.children.forEach(noteMaster)
            }
            master.children.forEach(noteMaster)
            let wasDefault = content.contains { id in
                guard let q = then[id] else { return false }
                let mine = id.mixed(k), d = design[mine] ?? mine
                guard let m = held[mine] ?? held[d] else { return false }
                return q.text == m.text && q.fill.image == m.fill.image
            }
            guard wasDefault else { return nil }
            return ComponentOffer(anchor: source, kind: .kept(copy: source, layers: content),
                                words: String(localized: "Only in this copy"),
                                buttons: [(.everywhere, String(localized: "In All \(count)"))])
        } else if !style.isEmpty, let v = Components.variant(inst.variant, of: master) {
            // A change in a copy of a variant stays in the variant: offered to every variant.
            var buttons: [(action: ComponentOffer.Action, title: String)] = []
            if !echo.to.isEmpty { buttons.append((.onlyHere, String(localized: "Only This Copy"))) }
            buttons.append((.allVariants, String(localized: "In All Variants")))
            return ComponentOffer(anchor: source, kind: .reached(copy: source, changes: style, before: before),
                                words: String(localized: "Only \(Components.name(of: v, in: master))"), buttons: buttons)
        } else if !echo.to.isEmpty, !style.isEmpty {
            let reached = echo.to.count + 1
            return ComponentOffer(anchor: source, kind: .reached(copy: source, changes: style, before: before),
                                words: String(localized: "All \(reached) copies"),
                                buttons: [(.onlyHere, String(localized: "Only This Copy")), (.newVariant, String(localized: "New Variant"))])
        }
        return nil
    }

    /// Makes what was changed about these layers of a copy that copy's own, and puts it back in
    /// the component, and so in every other copy, as it was `before`.
    mutating func keepInCopy(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) {
        guard let inst = node(copy)?.instance, let was = before.master(inst.of) else { return }
        if let i = masters.firstIndex(where: { $0.id == inst.of }) { masters[i] = was }
        for (id, names) in changes {
            update(id) { $0.own = Array(Set($0.own ?? []).union(names)).sorted() }
        }
    }

    /// The component, as what was changed about these layers of a copy its variant's own makes it:
    /// its other variants as they were `before`, and this one keeping the change.
    func keptInVariant(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) -> Node? {
        guard let c = node(copy), let inst = c.instance, let k = Components.key(of: c),
              let now = master(inst.of), var was = before.master(inst.of) else { return nil }
        let v = Components.variant(inst.variant, of: now)
        var current: [UUID: Node] = [:]
        func note(_ n: Node) {
            current[n.id] = n
            n.children.forEach(note)
        }
        now.children.filter { $0.post == v }.forEach(note)
        let named = Dictionary(changes.map { ($0.key.mixed(k), $0.value) }, uniquingKeysWith: { a, b in a + b })
        func keep(_ n: inout Node) {
            if let names = named[n.id], let source = current[n.id] {
                for name in names { Deck.fields[name]?.copy(&n, source) }
                n.own = Array(Set(n.own ?? []).union(names)).sorted()
            }
            for i in n.children.indices { keep(&n.children[i]) }
        }
        for i in was.children.indices where was.children[i].post == v { keep(&was.children[i]) }
        return was
    }

    /// A component in place of the one it was made from.
    mutating func place(component: Node) {
        if let i = masters.firstIndex(where: { $0.id == component.id }) { masters[i] = component }
    }

    /// What making a change to a copy of a variant the same in every variant takes: by the first
    /// variant's layer, the layer of this variant to take from, and what of it.
    struct EveryVariant {
        let master: UUID
        let variant: Int
        let key: RepeatGrid.Key
        let taken: [UUID: (Node, [String])]
    }

    func takenForEveryVariant(_ changes: [UUID: [String]], copy: UUID) -> EveryVariant? {
        guard let c = node(copy), let inst = c.instance, let k = Components.key(of: c), let master = master(inst.of),
              let v = Components.variant(inst.variant, of: master) else { return nil }
        let kv = Deck.key(v)
        var current: [UUID: Node] = [:]
        func note(_ n: Node) {
            current[n.id] = n
            n.children.forEach(note)
        }
        master.children.filter { $0.post == v }.forEach(note)
        var taken: [UUID: (Node, [String])] = [:]
        for (id, names) in changes {
            let vid = id.mixed(k)
            if let source = current[vid] { taken[vid.mixed(kv)] = (source, names) }
        }
        return EveryVariant(master: inst.of, variant: v, key: kv, taken: taken)
    }

    /// Makes what was changed in a variant the same in every variant: its first variant takes it,
    /// and this one no longer keeps it as its own.
    mutating func giveEveryVariant(_ e: EveryVariant) {
        guard let i = masters.firstIndex(where: { $0.id == e.master }) else { return }
        masters[i].children = masters[i].children.map { top in
            if top.post == nil { return Self.taking(top, e.taken) }
            if top.post == e.variant { return Self.letting(top, e.taken, e.key) }
            return top
        }
    }

    /// A layer of the first variant, and all it holds, taking what `taken` says from another's.
    private static func taking(_ n: Node, _ taken: [UUID: (Node, [String])]) -> Node {
        var m = n
        if let (source, names) = taken[n.id] { for name in names { Deck.fields[name]?.copy(&m, source) } }
        m.children = n.children.map { taking($0, taken) }
        return m
    }

    /// A layer of another variant, and all it holds, no longer keeping as its own what `taken` says.
    private static func letting(_ n: Node, _ taken: [UUID: (Node, [String])], _ kv: RepeatGrid.Key) -> Node {
        var m = n
        if let (_, names) = taken[n.id.mixed(kv)], let own = m.own {
            let left = own.filter { !names.contains($0) }
            m.own = left.isEmpty ? nil : left
        }
        m.children = n.children.map { letting($0, taken, kv) }
        return m
    }

    /// What giving every copy the words or picture some layers of one copy hold takes: the copy,
    /// its component, and by the component's own layer, the layer to give from.
    struct EveryCopy {
        let copy: UUID
        let master: Node
        let sources: [(UUID, Node)]
    }

    func givenToEveryCopy(_ layers: [UUID], from copyID: UUID) -> EveryCopy? {
        guard let copy = node(copyID), let inst = copy.instance, let k = Components.key(of: copy),
              let master = master(inst.of) else { return nil }
        let design = Components.designIDs(of: master)
        let sources: [(UUID, Node)] = layers.compactMap { id in
            guard let n = node(id) else { return nil }
            let mine = id.mixed(k)
            return (design[mine] ?? mine, n)
        }
        return EveryCopy(copy: copyID, master: master, sources: sources)
    }

    /// Gives every copy of a component, and the component itself, those words or pictures.
    mutating func giveEveryCopy(_ e: EveryCopy) {
        let master = e.master
        guard let i = masters.firstIndex(where: { $0.id == master.id }) else { return }
        for (d, source) in e.sources {
            for v in Components.variants(of: master) {
                masters[i].children = masters[i].children.map { Self.giving($0, d.mixed(Deck.key(v)), source) }
            }
        }
        for other in copies(of: master.id) where other.id != e.copy {
            guard let ko = Components.key(of: other) else { continue }
            let kv = Deck.key(Components.variant(other.instance?.variant, of: master))
            for (d, source) in e.sources { update(d.mixed(kv).mixed(ko)) { Self.give(&$0, source) } }
        }
    }

    private static func giving(_ n: Node, _ id: UUID, _ source: Node) -> Node {
        var m = n
        if m.id == id { give(&m, source) }
        m.children = m.children.map { giving($0, id, source) }
        return m
    }

    private static func give(_ n: inout Node, _ source: Node) {
        if source.kind == .text, n.kind == .text {
            n.text = source.text
            n.spans = source.spans
        }
        n.fill.image = source.fill.image
        n.refit()
    }
}
