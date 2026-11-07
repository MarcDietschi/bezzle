import Foundation

// Components on Windows, as on the Mac (the shared Model/ComponentEditing.swift, see
// `Components`): layers made a component, of which they are the first copy; a copy's variants,
// its name, its own looks forgotten, and copies unlinked into groups like any other.

extension WindowsCore {
    /// Whether the layers can be made a component.
    public static func canMakeComponent(_ ids: [UUID]) -> Bool { design?.canMakeComponent(ids) ?? false }

    /// Makes the layers a component, as one step: its first copy, and the groups in the design
    /// that look the same, which could be linked to it.
    public static func makeComponent(_ ids: [UUID]) -> (copy: UUID, lookAlikes: [UUID])? {
        guard canMakeComponent(ids) else { return nil }
        var made: UUID?
        edit { made = $0.makeComponent(from: ids) }
        guard let made, let doc = design, doc.node(made) != nil else { return nil }
        return (made, doc.lookAlikes(of: made))
    }

    /// Makes groups that look the same as a copy's component copies of it, as one step.
    public static func link(_ ids: [UUID], toComponentOf copy: UUID) {
        guard let master = design?.node(copy)?.instance?.of else { return }
        edit { d in for id in ids { d.link(id, to: master) } }
    }

    /// A copy picked, or a layer in one, as its card shows it.
    nonisolated public struct ComponentLook: Sendable {
        public let copy: UUID
        public let name: String
        /// Its component's variants, the one it shows, and each one's name.
        public let variants: [Int?]
        public let names: [String]
        public let current: Int?
        /// Its place among its component's copies, in the order they are read, and how many.
        public let index: Int
        public let count: Int
        /// Whether it keeps anything of its own besides its words and pictures.
        public let ownLooks: Bool
        /// Whether the copy itself is picked, not a layer in it: only then does taking the card
        /// off unlink it.
        public let whole: Bool
        /// The design it was taken from, for a component from a library.
        public let from: String?
        public let locked: Bool
    }

    public static func componentLook(_ selection: [UUID]) -> ComponentLook? {
        guard let doc = design, let copy = doc.selectedCopy(selection), let master = doc.component(of: copy) else { return nil }
        let all = doc.copiesInOrder(of: master.id)
        let variants = Components.variants(of: master)
        return ComponentLook(copy: copy.id, name: master.name, variants: variants,
                             names: variants.map { Components.name(of: $0, in: master) },
                             current: Components.variant(copy.instance?.variant, of: master),
                             index: all.firstIndex(of: copy.id) ?? 0, count: all.count,
                             ownLooks: BezzleDocument.hasOwnLooks(copy), whole: selection == [copy.id],
                             from: master.master?.library?.design, locked: copy.locked)
    }

    public static func renameComponent(of copy: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let doc = design, let c = doc.node(copy), let master = doc.component(of: c), master.name != name else { return }
        edit { $0.renameComponent(master.id, to: name) }
    }

    /// Shows the copies picked as a variant, as one step: what is picked then, in the variant.
    public static func setVariant(_ v: Int?, _ selection: [UUID]) -> [UUID] {
        guard let doc = design else { return selection }
        let copies = doc.selectedCopies(selection).filter { !$0.locked }
        guard !copies.isEmpty else { return selection }
        var moved: [UUID: UUID] = [:]
        edit { moved = $0.setVariant(v, of: copies) }
        return selection.map { moved[$0] ?? $0 }.filter { design?.node($0) != nil }
    }

    /// The copy turned into a variant on the canvas, while its tile is pointed at.
    public static func previewVariant(_ v: Int?, of copy: UUID, _ on: Bool) {
        endPreview()
        guard on, let doc = design, let c = doc.node(copy), let master = doc.component(of: c) else { return }
        preview { $0.update(copy) { $0 = Components.switched($0, to: v, in: master) } }
    }

    /// A new variant of the copy's component, as the copy looks now, shown in it: what is picked
    /// then, in the new variant's layers.
    public static func addVariant(_ selection: [UUID]) -> [UUID] {
        guard let doc = design, let copy = doc.selectedCopy(selection), let inst = copy.instance else { return selection }
        var made: Int?
        edit { made = $0.addVariant(from: copy) }
        guard let made, let now = design else { return selection }
        let k = Deck.key(inst.variant) ^ Deck.key(made)
        return selection.map { id in now.node(id) == nil && now.node(id.mixed(k)) != nil ? id.mixed(k) : id }.filter { now.node($0) != nil }
    }

    public static func renameVariant(_ v: Int?, of copy: UUID, to name: String) {
        guard let doc = design, let c = doc.node(copy), let master = doc.component(of: c) else { return }
        edit { $0.renameVariant(v, of: master.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func removeVariant(_ v: Int, of copy: UUID) {
        guard let doc = design, let c = doc.node(copy), let master = doc.component(of: c), master.master?.variants.contains(v) == true else { return }
        edit { $0.removeVariant(v, of: master.id) }
    }

    /// The copies picked made groups like any other, as one step.
    public static func unlink(_ selection: [UUID]) {
        guard let copies = design?.selectedCopies(selection).map(\.id), !copies.isEmpty else { return }
        edit { $0.unlink(copies) }
    }

    /// The copy looking as its component does again, but for its words and pictures.
    public static func resetCopy(_ id: UUID) {
        guard let c = design?.node(id), c.isCopy, BezzleDocument.hasOwnLooks(c) else { return }
        edit { $0.resetCopy(id) }
    }

    /// The copy `step` on from the one picked among its component's copies, round and round.
    public static func copy(_ step: Int, from selection: [UUID]) -> UUID? {
        guard let doc = design, let copy = doc.selectedCopy(selection), let inst = copy.instance else { return nil }
        let all = doc.copiesInOrder(of: inst.of)
        guard all.count > 1, let i = all.firstIndex(of: copy.id) else { return nil }
        return all[((i + step) % all.count + all.count) % all.count]
    }

    /// The copy as one of its variants, drawn to fit `size` (points) at `scale`, for its tile.
    public static func variantPicture(of copy: UUID, _ v: Int?, size: CGSize, scale: Double,
                                      into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let doc = design, let c = doc.node(copy), let master = doc.component(of: c) else { return false }
        var shown = Components.switched(c, to: v, in: master)
        shown.rotation = 0
        let box = Geometry.bounds(of: shown)
        guard box.width > 0, box.height > 0 else { return false }
        let k = min(size.width / box.width, size.height / box.height)
        shown.frame.origin = CGPoint(x: (size.width / k - box.width) / 2 + (shown.frame.minX - box.minX), y: (size.height / k - box.height) / 2 + (shown.frame.minY - box.minY))
        var holder = Node(kind: .group, name: "", frame: CGRect(origin: .zero, size: CGSize(width: size.width / k, height: size.height / k)))
        holder.children = [shown]
        return drawGlyph([holder], size: CGSize(width: size.width / k, height: size.height / k), scale: scale * Double(k), into: fill)
    }
}

// MARK: - What is offered after a change to a copy

extension WindowsCore {
    /// What is offered for a moment after a change to a copy (the shared `ComponentOffer`): the
    /// copy it is about, the words, and the buttons, the first the one to take.
    nonisolated public struct CopyOffer: Equatable, Sendable {
        public let anchor: UUID
        public let words: String
        public let buttons: [String]
        public let token: UUID
        /// About a style, not a component: shown in the pencil's blue.
        public var style = false
    }

    nonisolated(unsafe) private static var offered: ComponentOffer?

    /// What a style's offer is about (the Mac's StyleOffer.Kind).
    enum StyleOffered {
        /// The styles as they were before, and where the selection names them.
        case onlyHere(styles: [UUID: Style], places: [FoundLook.Use])
        /// Layers that look as a style just named does.
        case nameToo(style: UUID, uses: [FoundLook.Use])
        /// An artboard just made dark, to have a light one beside it as well.
        case lightTwin(UUID)
    }
    nonisolated(unsafe) static var styleOffered: StyleOffered?
    /// A deck's offer to keep a change in the post in front alone (the Mac's DeckOffer).
    nonisolated(unsafe) static var deckOffered: DeckOffer?
    /// An offer made by a step itself (a look named), shown once the step has been looked at.
    nonisolated(unsafe) static var pendingStyleOffer: CopyOffer?
    /// Set while the design's styles are changed from their list, where no offer is made.
    nonisolated(unsafe) public static var stylesFromList = false

    /// What the last step made at once offers, as the Mac's store looks after one: nil when no
    /// step has been made since; else what it offers, if anything, in place of anything offered
    /// before. Each step is looked at once.
    public static func considerCopyOffer(selection: [UUID] = []) -> CopyOffer?? {
        if let pending = pendingStyleOffer {
            pendingStyleOffer = nil
            Editing.lastStep = nil
            offered = nil
            return .some(pending)
        }
        guard let step = Editing.lastStep, let doc = design else { return nil }
        Editing.lastStep = nil
        offered = doc.componentOffer(after: step.before, echo: step.echo)
        styleOffered = nil
        deckOffered = nil
        guard let offer = offered else {
            // A change in the post in front that every post followed: offered to keep it there alone.
            if let deck = deckOffer(after: step.before) {
                deckOffered = deck
                return CopyOffer(anchor: deck.anchor, words: deck.words, buttons: [deck.button], token: deck.token, style: true)
            }
            return .some(styleOffer(after: step.before, selection: selection))
        }
        return CopyOffer(anchor: offer.anchor, words: offer.words, buttons: offer.buttons.map(\.title), token: offer.token)
    }

    /// After a change made through the selected layers to styles they name, as the Mac's
    /// noteStyles: the offer to keep it on them alone.
    private static func styleOffer(after before: BezzleDocument, selection: [UUID]) -> CopyOffer? {
        guard !stylesFromList, let doc = design, doc.styles != nil || before.styles != nil else { return nil }
        let changed = BezzleDocument.stylesChanged(from: before, to: doc).filter { doc.style($0) != nil }
        guard !changed.isEmpty else { return nil }
        let users = doc.styleUsers()
        guard let (anchor, olds, places, others) = doc.onlyHereOffer(before: before, selection: selection, changed: changed,
                                                                     users: { users[$0] ?? [] }) else { return nil }
        styleOffered = .onlyHere(styles: olds, places: places)
        return CopyOffer(anchor: anchor, words: say("Also on %lld more layers", others.count), buttons: [say("Only Here")], token: UUID(), style: true)
    }

    /// A component just made: when other groups look the same, the offer to link them.
    public static func offerLinking(_ copy: UUID, _ found: [UUID]) -> CopyOffer? {
        guard !found.isEmpty else { return nil }
        let offer = ComponentOffer(anchor: copy, kind: .lookAlikes(copy: copy, found: found),
                                   words: String(localized: "\(found.count) more look the same"),
                                   buttons: [(.link, String(localized: "Link Them"))])
        offered = offer
        return CopyOffer(anchor: copy, words: offer.words, buttons: offer.buttons.map(\.title), token: offer.token)
    }

    /// The offer let go of, untaken.
    public static func dropCopyOffer() {
        offered = nil
        styleOffered = nil
    }

    /// Does what the offer's button `index` offers, as one step; what is picked then, if that changes.
    @discardableResult public static func takeCopyOffer(_ index: Int) -> [UUID]? {
        if let deck = deckOffered, offered == nil {
            deckOffered = nil
            guard case .justHere(let changes, let before) = deck.kind else { return nil }
            edit { $0.keepInPost(changes, post: deck.post, deck: deck.deck, before: before) }
            return nil
        }
        if let kind = styleOffered, offered == nil {
            styleOffered = nil
            switch kind {
            case .onlyHere(let styles, let places):
                edit { $0.keepOnlyHere(styles: styles, places: places) }
            case .nameToo(let id, let uses):
                guard design?.style(id) != nil else { return nil }
                edit { $0.nameToo(id, uses: uses) }
            case .lightTwin(let id):
                var made: UUID?
                edit { made = $0.addLightTwin(of: id) }
                return made.map { [$0] }
            }
            return nil
        }
        guard let offer = offered, offer.buttons.indices.contains(index), let doc = design else { return nil }
        offered = nil
        switch (offer.kind, offer.buttons[index].action) {
        case (.reached(let copy, let changes, let before), .onlyHere):
            edit { $0.keepInCopy(changes, copy: copy, before: before) }
        case (.reached(let copy, let changes, let before), .onlyVariant):
            guard let kept = doc.keptInVariant(changes, copy: copy, before: before) else { return nil }
            edit { $0.place(component: kept) }
        case (.reached(let copy, let changes, let before), .newVariant):
            guard let c = doc.node(copy) else { return nil }
            edit { $0.addVariant(from: c, keeping: changes, before: before) }
        case (.reached(let copy, let changes, _), .allVariants):
            guard let taken = doc.takenForEveryVariant(changes, copy: copy) else { return nil }
            edit { $0.giveEveryVariant(taken) }
        case (.kept(let copy, let layers), _):
            guard let given = doc.givenToEveryCopy(layers, from: copy) else { return nil }
            edit { $0.giveEveryCopy(given) }
        case (.lookAlikes(let copy, let found), _):
            link(found, toComponentOf: copy)
        default:
            return nil
        }
        return nil
    }
}

// MARK: - On the canvas

extension WindowsCore {
    /// With a copy picked, every other copy of its component, as its corners on the canvas: what
    /// will change with it, in sight before anything is changed.
    public static func otherCopies(_ selection: [UUID]) -> [[CGPoint]] {
        guard let doc = design, let copy = doc.selectedCopy(selection) ?? doc.selectedCopies(selection).first,
              let inst = copy.instance else { return [] }
        return doc.copies(of: inst.of).filter { $0.id != copy.id && !$0.hidden }.compactMap { doc.shownCorners(of: $0.id) }
    }

    /// The component's name over the copy picked, with the variant it shows when it has several,
    /// and where the copy's top left is on the canvas.
    public static func copyTag(_ selection: [UUID]) -> (text: String, at: CGPoint, width: CGFloat)? {
        guard let doc = design, let copy = doc.selectedCopy(selection), let master = doc.component(of: copy),
              let corners = doc.shownCorners(of: copy.id), let first = corners.first else { return nil }
        var text = master.name
        if (master.master?.variants.isEmpty ?? true) == false { text += "  \u{00B7}  " + Components.name(of: copy.instance?.variant, in: master) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let top = CGPoint(x: xs.min() ?? first.x, y: ys.min() ?? first.y)
        return (text, top, (xs.max() ?? first.x) - top.x)
    }
}

// MARK: - A layer of a copy with looks of its own

extension WindowsCore {
    /// What a layer in a copy keeps of its own, in words ("fill, corners"), as the Mac's card
    /// says it; nil when it keeps nothing or lies in no copy.
    public static func ownLooks(_ id: UUID) -> String? {
        guard let doc = design, let n = doc.node(id), let own = n.own, !own.isEmpty, doc.inCopy(id) else { return nil }
        let words: [String: String] = [
            "frame": "size and place", "fill": "fill", "border": "border", "shadow": "shadow", "opacity": "opacity", "style": "type",
            "moreFills": "fill", "moreBorders": "border", "moreShadows": "shadow", "rotation": "rotation", "cornerRadius": "corners",
            "corners": "corners", "cornerSmoothing": "corners", "hidden": "hidden", "locked": "locked", "blur": "blur",
            "transform3D": "depth", "blend": "blend", "name": "name", "mask": "mask", "path": "outline", "pathBox": "outline",
            "evenOdd": "outline", "rising": "direction", "clips": "clipping", "slideSize": "slides",
        ]
        var seen = Set<String>()
        return own.compactMap { words[$0] ?? $0 }.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// Lets these layers of copies follow their component again in everything they kept of their own.
    public static func followComponent(_ ids: [UUID]) {
        guard let doc = design else { return }
        let layers = ids.filter { doc.node($0)?.own?.isEmpty == false && doc.inCopy($0) }
        guard !layers.isEmpty else { return }
        edit { d in for id in layers { d.update(id) { $0.own = nil } } }
    }
}
