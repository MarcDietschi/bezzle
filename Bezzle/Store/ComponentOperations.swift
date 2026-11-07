import AppKit

extension DocumentStore {
    // MARK: The copy being worked on

    /// The copy the selection is in, or that is selected, when one thing is (the shared
    /// `BezzleDocument.selectedCopy`, as the rest of these: Model/ComponentEditing.swift).
    var selectedCopy: Node? { doc.selectedCopy(selection) }

    /// The selected copies, each once, whatever in them is selected.
    var selectedCopies: [Node] { doc.selectedCopies(selection) }

    func master(of copy: Node) -> Node? { doc.component(of: copy) }

    /// The copies of a component in the order they are read: artboard by artboard, then from the
    /// top, then from the left.
    func copiesInOrder(of master: UUID) -> [UUID] { doc.copiesInOrder(of: master) }

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
    var canMakeComponent: Bool { !isReadOnly && doc.canMakeComponent(selection) }

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
        doc.makeComponent(from: ids, name: name, part: part)
    }

    /// A name for a new component: "Component 1", the first not taken.
    static func componentName(in doc: BezzleDocument) -> String { doc.componentName() }

    /// The groups in the design that look the same as a copy's component and could be copies of it.
    static func lookAlikes(of copyID: UUID, in doc: BezzleDocument) -> [UUID] { doc.lookAlikes(of: copyID) }

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
    static func link(_ id: UUID, to masterID: UUID, in doc: inout BezzleDocument) -> UUID? { doc.link(id, to: masterID) }

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
        edit(copies.count == 1 ? "Unlink Copy" : "Unlink Copies") { $0.unlink(copies) }
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
        doc.renameComponent(masterID, to: name)
    }

    // MARK: Variants

    /// Shows these copies as one of their component's variants. What was selected in them is
    /// selected in the variant.
    func setVariant(_ v: Int?, for ids: [UUID]? = nil) {
        let copies = (ids?.compactMap { doc.node($0) } ?? selectedCopies).filter { !$0.locked }
        guard !copies.isEmpty else { return }
        var moved: [UUID: UUID] = [:]
        edit("Change Variant") { doc in moved = doc.setVariant(v, of: copies) }
        let remapped = selection.map { moved[$0] ?? $0 }.filter { doc.node($0) != nil }
        if remapped != selection { selection = remapped }
    }

    /// Adds a variant to the selected copy's component, as the copy looks now, and shows it in the
    /// copy. Until anything is changed in it, it is the same as the copy was; what is changed first
    /// in it is its own.
    func addVariant(from copyID: UUID? = nil, keeping changes: [UUID: [String]] = [:], restoring before: BezzleDocument? = nil) {
        guard let copy = copyID.flatMap({ doc.node($0) }) ?? selectedCopy, let inst = copy.instance, !isReadOnly else { return }
        var made: Int?
        edit("New Variant") { doc in made = doc.addVariant(from: copy, keeping: changes, before: before) }
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
        doc.renameVariant(v, of: masterID, to: name)
    }

    /// Takes a variant away from a component; its copies show the first variant.
    func removeVariant(_ v: Int, of masterID: UUID) {
        guard doc.master(masterID)?.master?.variants.contains(v) == true else { return }
        edit("Delete Variant") { doc in Self.removeVariant(v, of: masterID, in: &doc) }
    }

    static func removeVariant(_ v: Int, of masterID: UUID, in doc: inout BezzleDocument) {
        doc.removeVariant(v, of: masterID)
    }

    // MARK: A copy's own

    /// Whether a copy keeps anything of its own besides its words and pictures.
    func hasOwnLooks(_ copy: Node) -> Bool { BezzleDocument.hasOwnLooks(copy) }

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
        guard let copy = doc.node(id), copy.isCopy, hasOwnLooks(copy), master(of: copy) != nil else { return }
        edit("Reset Copy") { $0.resetCopy(id) }
    }

    // MARK: Offers

    /// Looks at what a change did to the copy it was made in, and offers what can be made of it:
    /// see `ComponentOffer`. Anything offered before goes.
    func considerComponentOffer(after before: BezzleDocument, echo: ComponentEcho?, action: LocalizedStringResource) {
        componentOffer = nil
        if let offer = doc.componentOffer(after: before, echo: echo) { show(offer) }
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
    /// the component, and so in every other copy, as it was `before` (the shared
    /// `BezzleDocument.keepInCopy`, as the rest: Model/ComponentOffers.swift).
    func keepInCopy(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) {
        guard doc.node(copy)?.instance.flatMap({ before.master($0.of) }) != nil else { return }
        edit("Keep in This Copy") { $0.keepInCopy(changes, copy: copy, before: before) }
    }

    /// Makes what was changed about these layers of a copy its variant's own.
    func keepInVariant(_ changes: [UUID: [String]], copy: UUID, before: BezzleDocument) {
        guard let kept = doc.keptInVariant(changes, copy: copy, before: before) else { return }
        edit("Keep in Variant") { $0.place(component: kept) }
    }

    /// Makes what was changed about these layers of a copy of a variant the same in every variant.
    func giveEveryVariant(_ changes: [UUID: [String]], copy: UUID) {
        guard let taken = doc.takenForEveryVariant(changes, copy: copy) else { return }
        edit("Use in All Variants") { $0.giveEveryVariant(taken) }
    }

    /// Gives every copy of a component, and the component itself, the words or picture these
    /// layers of one copy hold.
    func giveEveryCopy(_ layers: [UUID], from copyID: UUID) {
        guard let given = doc.givenToEveryCopy(layers, from: copyID) else { return }
        edit("Use in All Copies") { $0.giveEveryCopy(given) }
    }
}
