import AppKit

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

extension Components {
    /// A copy of a component made again with new identities: its layers keyed from the component
    /// with a key of its own, as every copy's are, each keeping what it holds.
    static func freshCopy(of copy: Node) -> Node {
        guard let k = key(of: copy), let inst = copy.instance else { return copy }
        let next = freshKey()
        var n = RepeatGrid.copy(copy, k ^ next)
        n.id = inst.of.mixed(next)
        return n
    }

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
        return build(c, master: master, masterWas: nil, masters: masters)
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

extension DocumentStore {
    // MARK: The copy being worked on

    /// The copy the selection is in, or that is selected, when one thing is.
    var selectedCopy: Node? {
        guard selection.count == 1 else { return nil }
        return doc.copy(holding: selection[0])
    }

    /// The selected copies, each once, whatever in them is selected.
    var selectedCopies: [Node] {
        var seen = Set<UUID>(), out: [Node] = []
        for id in selection {
            if let c = doc.copy(holding: id), seen.insert(c.id).inserted { out.append(c) }
        }
        return out
    }

    func master(of copy: Node) -> Node? { copy.instance.flatMap { doc.master($0.of) } }

    /// The copies of a component in the order they are read: artboard by artboard, then from the
    /// top, then from the left.
    func copiesInOrder(of master: UUID) -> [UUID] {
        doc.copies(of: master).compactMap { c in doc.absoluteFrame(of: c.id).map { (c.id, $0) } }
            .sorted { a, b in
                let ba = doc.artboard(of: a.0).flatMap { doc.path(of: $0.id)?.top } ?? Int.max
                let bb = doc.artboard(of: b.0).flatMap { doc.path(of: $0.id)?.top } ?? Int.max
                if ba != bb { return ba < bb }
                if abs(a.1.minY - b.1.minY) > 4 { return a.1.minY < b.1.minY }
                return a.1.minX < b.1.minX
            }
            .map(\.0)
    }

    /// Selects the copy `step` on from the one selected among its component's copies, round and
    /// round, and brings it into view.
    func goToCopy(_ step: Int) {
        guard let copy = selectedCopy, let inst = copy.instance else { return }
        let all = copiesInOrder(of: inst.of)
        guard all.count > 1, let i = all.firstIndex(of: copy.id) else { return }
        let next = all[((i + step) % all.count + all.count) % all.count]
        if let (deck, post) = doc.post(of: next), let post { fronts[deck.id] = post }
        selection = [next]
        show(next)
    }

    /// Tells the canvas what a change did to copies, and with `was`, the design before a change
    /// made at once, so the copies can be seen taking it as the light reaches them.
    func noteEcho(_ echo: ComponentEcho?, was: BezzleDocument? = nil) {
        guard let echo, !echo.to.isEmpty else { return }
        componentEcho = (echo, CACurrentMediaTime(), was)
    }

    // MARK: Making one

    /// Whether the selection can be made a component: layers on one artboard, or the canvas, none
    /// of them an artboard or in a copy already, and not a copy itself.
    var canMakeComponent: Bool {
        guard !isReadOnly, !selection.isEmpty else { return false }
        if selection.count == 1, let n = node(selection[0]) {
            if n.isCopy || n.isArtboard || n.locked || doc.insideCopy(n.id) { return false }
            // A group is a component as it is, wherever it lies, a repeat grid's cell too.
            if n.isGroup, !n.isRepeatGrid, !n.isMask { return true }
        }
        // Copies may go into it, as a button into a card; what lies inside a copy may not.
        return selection.allSatisfy { id in !doc.insideCopy(id) && doc.node(id)?.locked == false }
            && Self.groupable(selection, in: doc) != nil
    }

    /// Makes the selection a component, of which it is then the first copy; and offers to link
    /// any other group in the design that looks the same.
    func makeComponent() {
        guard canMakeComponent else { return }
        canvas?.endEditing()
        var made: UUID?
        edit("Make Component") { doc in made = Self.makeComponent(from: selection, in: &doc) }
        guard let made else { return }
        selection = [made]
        componentEcho = (ComponentEcho(from: [made], to: [], made: true), CACurrentMediaTime(), nil)
        let found = Self.lookAlikes(of: made, in: doc)
        if !found.isEmpty {
            let offer = ComponentOffer(anchor: made, kind: .lookAlikes(copy: made, found: found),
                                       words: String(localized: "\(found.count) more look the same"),
                                       buttons: [(.link, String(localized: "Link Them"))])
            show(offer)
        }
    }

    /// Makes layers a component and returns its first copy: one group as it is, or anything else
    /// put into a group first. A part of a kit is named by `part`, so the same part dropped in
    /// again is another copy.
    @discardableResult
    static func makeComponent(from ids: [UUID], in doc: inout BezzleDocument, name: String? = nil, part: String? = nil) -> UUID? {
        guard !ids.isEmpty, ids.allSatisfy({ !doc.insideCopy($0) }),
              ids.count > 1 || doc.node(ids[0])?.isCopy == false else { return nil }
        let target: UUID
        if ids.count == 1, let n = doc.node(ids[0]), n.isGroup, !n.isRepeatGrid, !n.isMask {
            target = ids[0]
        } else {
            let single = ids.count == 1 ? doc.node(ids[0])?.name : nil
            guard let g = group(ids, in: &doc, name: name ?? single ?? Self.componentName(in: doc)) else { return nil }
            doc.fitGroups()
            target = g
        }
        guard let path = doc.path(of: target) else { return nil }
        var g = doc[path]
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
        doc[path] = g
        doc.masters.append(master)
        return g.id
    }

    /// A name for a new component: "Component 1", the first not taken.
    static func componentName(in doc: BezzleDocument) -> String {
        let taken = Set(doc.masters.map(\.name) + doc.allNodes.map(\.name))
        var i = 1
        while taken.contains(String(localized: "Component \(i)")) { i += 1 }
        return String(localized: "Component \(i)")
    }

    /// The groups in the design that look the same as a copy's component and could be copies of it.
    static func lookAlikes(of copyID: UUID, in doc: BezzleDocument) -> [UUID] {
        guard let copy = doc.node(copyID), let inst = copy.instance, let master = doc.master(inst.of) else { return [] }
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
        visit(doc.nodes, inDeck: false)
        // In a deck, its design behind the posts goes with the posts: those are linked as it is.
        return found.filter { id in doc.post(of: id).map { $0.post != nil } ?? true }
    }

    /// Makes groups that look the same as a component copies of it.
    func link(_ ids: [UUID], to masterID: UUID) {
        var linked: [UUID] = []
        edit("Link to Component") { doc in
            for id in ids { if let made = Self.link(id, to: masterID, in: &doc) { linked.append(made) } }
        }
        let first = doc.copies(of: masterID).first { !linked.contains($0.id) }?.id ?? selection.first ?? masterID
        componentEcho = (ComponentEcho(from: [first], to: linked, made: true), CACurrentMediaTime(), nil)
    }

    @discardableResult
    static func link(_ id: UUID, to masterID: UUID, in doc: inout BezzleDocument) -> UUID? {
        guard let x = doc.node(id), let master = doc.master(masterID), let path = doc.path(of: id) else { return nil }
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
        doc[path] = c
        return c.id
    }

    // MARK: Placing copies

    /// Adds a copy of a component, its middle at a canvas point, or in the middle of what shows of
    /// the artboard being looked at; and selects it.
    @discardableResult
    func placeCopy(of masterID: UUID, variant: Int? = nil, at point: CGPoint? = nil, onto boardID: UUID? = nil) -> UUID? {
        guard !isReadOnly, let master = doc.master(masterID) else { return nil }
        canvas?.endEditing()
        let board: Node? = boardID.flatMap { doc.node($0) } ?? (point.map { doc.artboard(at: $0) } ?? focusedArtboard)
        let usable = board.flatMap { $0.locked ? nil : $0 }
        let center = point ?? {
            guard let usable else { return visibleCanvasRect.center }
            let shown = usable.frame.intersection(visibleCanvasRect)
            return shown.isNull || shown.isEmpty ? usable.frame.center : shown.center
        }()
        let size = Components.box(of: master, variant: variant).size
        let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        let copy = Components.newCopy(of: master, variant: variant, at: origin)
        edit("Add Component") { doc in doc.attach(copy, to: usable?.id) }
        selection = [copy.id]
        return copy.id
    }

    // MARK: Unlinking

    var canUnlink: Bool { !isReadOnly && !selectedCopies.isEmpty }

    /// Makes the selected copies groups like any other, which keep how they look and no longer change
    /// with their component.
    func unlinkComponent(_ ids: [UUID]? = nil) {
        let copies = ids ?? selectedCopies.map(\.id)
        guard !copies.isEmpty else { return }
        edit(copies.count == 1 ? "Unlink Copy" : "Unlink Copies") { doc in
            for id in copies { doc.update(id) { $0 = $0.unlinked() } }
        }
    }

    /// Takes a component out of the design; its copies stay, as groups like any other.
    func deleteComponent(_ masterID: UUID) {
        guard doc.master(masterID) != nil else { return }
        edit("Delete Component") { doc in doc.masters.removeAll { $0.id == masterID } }
    }

    func renameComponent(_ masterID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let master = doc.master(masterID), master.name != name else { return }
        edit("Rename Component") { doc in Self.renameComponent(masterID, to: name, in: &doc) }
    }

    static func renameComponent(_ masterID: UUID, to name: String, in doc: inout BezzleDocument) {
        guard let i = doc.masters.firstIndex(where: { $0.id == masterID }) else { return }
        let old = doc.masters[i].name
        doc.masters[i].name = name
        // Copies still called after it are called after it again.
        for c in doc.copies(of: masterID) where c.name == old { doc.update(c.id) { $0.name = name } }
    }

    // MARK: Variants

    /// Shows these copies as one of their component's variants. What was selected in them is
    /// selected in the variant.
    func setVariant(_ v: Int?, for ids: [UUID]? = nil) {
        let copies = (ids?.compactMap { doc.node($0) } ?? selectedCopies).filter { !$0.locked }
        guard !copies.isEmpty else { return }
        var moved: [UUID: UUID] = [:]
        edit("Change Variant") { doc in
            for c in copies {
                guard let master = master(of: c), let inst = c.instance else { continue }
                let next = Components.switched(c, to: v, in: master)
                guard next.instance != inst else { continue }
                let from = Deck.key(Components.variant(inst.variant, of: master)), to = Deck.key(Components.variant(v, of: master))
                func note(_ n: Node) {
                    moved[n.id] = n.id.mixed(from ^ to)
                    n.children.forEach(note)
                }
                c.children.forEach(note)
                doc.update(c.id) { $0 = next }
            }
        }
        let remapped = selection.map { moved[$0] ?? $0 }.filter { doc.node($0) != nil }
        if remapped != selection { selection = remapped }
    }

    /// Adds a variant to the selected copy's component, as the copy looks now, and shows it in the
    /// copy. Until anything is changed in it, it is the same as the copy was; what is changed first
    /// in it is its own.
    func addVariant(from copyID: UUID? = nil, keeping changes: [UUID: [String]] = [:], restoring before: BezzleDocument? = nil) {
        guard let copy = copyID.flatMap({ doc.node($0) }) ?? selectedCopy, let inst = copy.instance, !isReadOnly else { return }
        var made: Int?
        edit("New Variant") { doc in
            guard let i = doc.masters.firstIndex(where: { $0.id == inst.of }) else { return }
            // From the offer after a change: the other copies go back to how they were.
            var master = before?.master(inst.of) ?? doc.masters[i]
            // It shows as big as it did, though its words are now the variant's own.
            let shown = Components.plan(copy, master: master)?.to
            guard let n = Components.addVariant(from: copy, keeping: changes, to: &master) else { return }
            made = n
            doc.masters[i] = master
            doc.update(copy.id) { c in
                if let shown { c = Components.showing(c, variant: n, of: master, at: shown) } else { c.instance?.variant = n }
                // What it kept of its own is the variant's now.
                c = Node.forgettingOwnLooks(c)
            }
        }
        if let made {
            // What was selected in the copy is selected in the new variant's layers.
            let k = Deck.key(inst.variant) ^ Deck.key(made)
            let remapped = selection.map { id in doc.node(id) == nil && doc.node(id.mixed(k)) != nil ? id.mixed(k) : id }
                .filter { doc.node($0) != nil }
            if remapped != selection { selection = remapped }
        }
    }

    func renameVariant(_ v: Int?, of masterID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit("Rename Variant") { doc in Self.renameVariant(v, of: masterID, to: name, in: &doc) }
    }

    static func renameVariant(_ v: Int?, of masterID: UUID, to name: String, in doc: inout BezzleDocument) {
        guard let i = doc.masters.firstIndex(where: { $0.id == masterID }), var info = doc.masters[i].master else { return }
        var names = info.names ?? [:]
        names[String(Components.variant(v, of: doc.masters[i]) ?? 0)] = name.isEmpty ? nil : name
        info.names = names.isEmpty ? nil : names
        doc.masters[i].master = info
    }

    /// Takes a variant away from a component; its copies show the first variant.
    func removeVariant(_ v: Int, of masterID: UUID) {
        guard doc.master(masterID)?.master?.variants.contains(v) == true else { return }
        edit("Delete Variant") { doc in Self.removeVariant(v, of: masterID, in: &doc) }
    }

    static func removeVariant(_ v: Int, of masterID: UUID, in doc: inout BezzleDocument) {
        guard let master = doc.master(masterID) else { return }
        // Its copies, on the canvas and in other components, show the first variant.
        for c in doc.copies(of: masterID) where c.instance?.variant == v { doc.update(c.id) { $0 = Components.switched($0, to: nil, in: master) } }
        func switching(_ n: Node) -> Node {
            guard n.marksCopy else { return n }
            var m = n.instance?.of == masterID && n.instance?.variant == v ? Components.switched(n, to: nil, in: master) : n
            m.children = m.children.map(switching)
            return m
        }
        for j in doc.masters.indices where doc.masters[j].id != masterID { doc.masters[j].children = doc.masters[j].children.map(switching) }
        guard let i = doc.masters.firstIndex(where: { $0.id == masterID }) else { return }
        doc.masters[i].children.removeAll { $0.post == v }
        doc.masters[i].master?.variants.removeAll { $0 == v }
        doc.masters[i].master?.names?[String(v)] = nil
    }

    // MARK: A copy's own

    /// Whether a copy keeps anything of its own besides its words and pictures.
    func hasOwnLooks(_ copy: Node) -> Bool {
        func any(_ n: Node) -> Bool { n.own?.isEmpty == false || n.children.contains(where: any) }
        return copy.children.contains(where: any)
    }

    /// Lets these layers of copies follow their component again in everything they kept of their own.
    func followComponent(_ ids: [UUID]) {
        let layers = ids.filter { doc.node($0)?.own?.isEmpty == false && doc.inCopy($0) }
        guard !layers.isEmpty else { return }
        edit("Follow Component") { doc in
            for id in layers { doc.update(id) { $0.own = nil } }
        }
    }

    /// Lets the copy look as its component does again in everything it kept of its own; its
    /// words and pictures stay.
    func resetCopy(_ id: UUID) {
        guard let copy = doc.node(id), copy.isCopy, hasOwnLooks(copy), let master = master(of: copy) else { return }
        edit("Reset Copy") { doc in
            var c = Node.forgettingOwnLooks(copy)
            c = Components.build(c, master: master, masterWas: nil, masters: doc.mastersByID)
            doc.update(id) { $0 = c }
        }
    }

    // MARK: Offers

    /// Looks at what a change did to the copy it was made in, and offers what can be made of it:
    /// see `ComponentOffer`. Anything offered before goes.
    func considerComponentOffer(after before: BezzleDocument, echo: ComponentEcho?, action: LocalizedStringResource) {
        componentOffer = nil
        guard let echo, let source = echo.from.first, let copy = doc.node(source), let inst = copy.instance,
              let master = doc.master(inst.of), let was = before.node(source), was.instance?.variant == inst.variant else { return }
        let count = doc.copies(of: master.id).count
        guard count > 1 else { return }
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
            guard style.values.allSatisfy({ $0 == ["frame"] }), let k = Components.key(of: copy) else { return }
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
            guard wasDefault else { return }
            show(ComponentOffer(anchor: source, kind: .kept(copy: source, layers: content),
                                words: String(localized: "Only in this copy"),
                                buttons: [(.everywhere, String(localized: "In All \(count)"))]))
        } else if !style.isEmpty, let v = Components.variant(inst.variant, of: master) {
            // A change in a copy of a variant stays in the variant: offered to every variant.
            var buttons: [(action: ComponentOffer.Action, title: String)] = []
            if !echo.to.isEmpty { buttons.append((.onlyHere, String(localized: "Only This Copy"))) }
            buttons.append((.allVariants, String(localized: "In All Variants")))
            show(ComponentOffer(anchor: source, kind: .reached(copy: source, changes: style, before: before),
                                words: String(localized: "Only \(Components.name(of: v, in: master))"), buttons: buttons))
        } else if !echo.to.isEmpty, !style.isEmpty {
            let reached = echo.to.count + 1
            show(ComponentOffer(anchor: source, kind: .reached(copy: source, changes: style, before: before),
                                words: String(localized: "All \(reached) copies"),
                                buttons: [(.onlyHere, String(localized: "Only This Copy")), (.newVariant, String(localized: "New Variant"))]))
        }
    }

    private func show(_ offer: ComponentOffer) {
        componentOffer = offer
        let token = offer.token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.componentOffer?.token == token { self?.componentOffer = nil }
        }
    }

    /// Does what an offer offers.
    func take(_ offer: ComponentOffer, _ action: ComponentOffer.Action) {
        componentOffer = nil
        switch (offer.kind, action) {
        case (.reached(let copy, let changes, let before), .onlyHere):
            keepInCopy(changes, copy: copy, before: before)
        case (.reached(let copy, let changes, let before), .onlyVariant):
            keepInVariant(changes, copy: copy, before: before)
        case (.reached(let copy, let changes, let before), .newVariant):
            addVariant(from: copy, keeping: changes, restoring: before)
        case (.reached(let copy, let changes, _), .allVariants):
            giveEveryVariant(changes, copy: copy)
        case (.kept(let copy, let layers), _):
            giveEveryCopy(layers, from: copy)
        case (.lookAlikes(let copy, let found), _):
            if let inst = doc.node(copy)?.instance { link(found, to: inst.of) }
        default:
            break
        }
    }

    /// Makes what was changed about these layers of a copy that copy's own, and puts it back in
    /// the component, and so in every other copy, as it was `before`.
    func keepInCopy(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) {
        guard let inst = doc.node(copy)?.instance, let was = before.master(inst.of) else { return }
        edit("Keep in This Copy") { doc in
            if let i = doc.masters.firstIndex(where: { $0.id == inst.of }) { doc.masters[i] = was }
            for (id, names) in changes {
                doc.update(id) { $0.own = Array(Set($0.own ?? []).union(names)).sorted() }
            }
        }
    }

    /// Makes what was changed about these layers of a copy its variant's own: the component's other
    /// variants go back to how they were `before`, and this one keeps the change.
    func keepInVariant(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) {
        guard let c = doc.node(copy), let inst = c.instance, let k = Components.key(of: c),
              let now = doc.master(inst.of), var was = before.master(inst.of) else { return }
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
        edit("Keep in Variant") { doc in
            if let i = doc.masters.firstIndex(where: { $0.id == inst.of }) { doc.masters[i] = was }
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

    /// Makes what was changed about these layers of a copy of a variant the same in every variant:
    /// its first variant takes it, and this one no longer keeps it as its own.
    func giveEveryVariant(_ changes: [UUID: [String]], copy: UUID) {
        guard let c = doc.node(copy), let inst = c.instance, let k = Components.key(of: c), let master = doc.master(inst.of),
              let v = Components.variant(inst.variant, of: master) else { return }
        let kv = Deck.key(v)
        var current: [UUID: Node] = [:]
        func note(_ n: Node) {
            current[n.id] = n
            n.children.forEach(note)
        }
        master.children.filter { $0.post == v }.forEach(note)
        // By the first variant's layer, what to take from this one's.
        var taken: [UUID: (Node, [String])] = [:]
        for (id, names) in changes {
            let vid = id.mixed(k)
            if let source = current[vid] { taken[vid.mixed(kv)] = (source, names) }
        }
        edit("Use in All Variants") { doc in
            guard let i = doc.masters.firstIndex(where: { $0.id == inst.of }) else { return }
            doc.masters[i].children = doc.masters[i].children.map { top in
                if top.post == nil { return Self.taking(top, taken) }
                if top.post == v { return Self.letting(top, taken, kv) }
                return top
            }
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

    /// Gives every copy of a component, and the component itself, the words or picture these
    /// layers of one copy hold.
    func giveEveryCopy(_ layers: [UUID], from copyID: UUID) {
        guard let copy = doc.node(copyID), let inst = copy.instance, let k = Components.key(of: copy),
              let master = doc.master(inst.of) else { return }
        let design = Components.designIDs(of: master)
        let sources: [(UUID, Node)] = layers.compactMap { id in
            guard let n = doc.node(id) else { return nil }
            let mine = id.mixed(k)
            return (design[mine] ?? mine, n)
        }
        edit("Use in All Copies") { doc in
            guard let i = doc.masters.firstIndex(where: { $0.id == inst.of }) else { return }
            for (d, source) in sources {
                for v in Components.variants(of: master) {
                    doc.masters[i].children = doc.masters[i].children.map { Self.giving($0, d.mixed(Deck.key(v)), source) }
                }
            }
            for other in doc.copies(of: inst.of) where other.id != copyID {
                guard let ko = Components.key(of: other) else { continue }
                let kv = Deck.key(Components.variant(other.instance?.variant, of: master))
                for (d, source) in sources { doc.update(d.mixed(kv).mixed(ko)) { Self.give(&$0, source) } }
            }
        }
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
