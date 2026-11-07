import AppKit
import Observation

/// What the canvas shows of the design's styles over the work: every layer that has the style
/// the pointer is on, a change rippling out to every layer that has it, and what is offered for a
/// moment after one.
@Observable final class StyleShow {
    /// The style the pointer is on, in the inspector: every layer that uses it is outlined.
    var pointed: UUID?
    /// Layers outlined for a moment besides, such as those an offer is about.
    var lit: [UUID] = []
    var wave: Wave?
    var offer: StyleOffer?
    /// The styles a drag going on changes, whose layers are outlined while it does.
    var live: Set<UUID> = []
    /// Set while a change is made from the inspector's list of the design's styles, so the wave
    /// comes from there.
    @ObservationIgnored var fromList = false
    @ObservationIgnored var foundWorkedOut: (version: Int, found: [StyleKind: [FoundLook]])?
    @ObservationIgnored var usesWorkedOut: (version: Int, uses: [UUID: Int])?
    @ObservationIgnored var usersWorkedOut: (version: Int, users: [UUID: [UUID]])?

    /// A change carried to every layer that has a style, shown as light running out over them
    /// from where it was made.
    struct Wave: Equatable {
        /// Where it starts, on the canvas; nil from the inspector's side of the view.
        let origin: CGPoint?
        let layers: [UUID]
        /// The artboards as they looked before, in the part of them on screen, which the canvas
        /// draws ahead of the wave: the change comes in behind it, as paint washing over them.
        var washes: [Wash] = []
        let token = UUID()
        let start = Date()

        static func == (a: Wave, b: Wave) -> Bool { a.token == b.token }
    }

    /// An artboard as it looked before a change, over a part of the canvas.
    struct Wash {
        let image: CGImage
        let rect: CGRect
    }
}

/// What is offered for a moment after a change to a named look: to keep it on the selected layers
/// alone, or to give the name to every other layer that looks the same.
struct StyleOffer {
    enum Kind {
        /// The styles as they were before, and where the selection names them.
        case onlyHere(styles: [UUID: Style], places: [FoundLook.Use])
        /// Layers that look as a style just named does.
        case nameToo(style: UUID, uses: [FoundLook.Use])
        /// An artboard just made dark, to have a light one beside it as well.
        case lightTwin(UUID)
    }

    /// The layer it shows beside.
    let anchor: UUID
    let kind: Kind
    let words: String
    let button: String
    /// The layers it is about, outlined while the button is pointed at.
    let layers: [UUID]
    let token = UUID()
}

extension DocumentStore {
    // MARK: Reading

    /// The design's styles of a kind, in their order.
    func styles(of kind: StyleKind) -> [Style] { doc.styles(of: kind) }

    func style(_ id: UUID) -> Style? { doc.style(id) }

    /// The selected layers that have a place, as its card shows them.
    func holding(_ place: StylePlace) -> [Node] {
        selectedNodes.filter { place.look(of: $0) != nil }
    }

    /// The style every selected layer with the place has there, when they share one.
    func sharedStyle(at place: StylePlace) -> Style? {
        let those = holding(place)
        guard let id = those.first.flatMap(place.named(in:)), those.allSatisfy({ place.named(in: $0) == id }) else { return nil }
        return doc.style(id)
    }

    /// The styles of a kind the selection can be given at a place: letters and borders take one
    /// colour only.
    func styles(for place: StylePlace) -> [Style] {
        let those = holding(place)
        guard !those.isEmpty else { return [] }
        return styles(of: place.kind).filter { s in those.allSatisfy { place.takes(s.look, in: $0) } }
    }

    /// The layers that use a style, worked out for every style at once, once per change.
    func layers(using id: UUID) -> [UUID] {
        if let worked = styleShow.usersWorkedOut, worked.version == version { return worked.users[id] ?? [] }
        let users = doc.styleUsers()
        styleShow.usersWorkedOut = (version, users)
        return users[id] ?? []
    }

    // MARK: Naming

    /// Gives the look the selection has at a place a name, making a style of it that every selected
    /// layer with the same look uses; offers then to name the others that look the same.
    @discardableResult
    func nameLook(at place: StylePlace, _ name: String) -> UUID? {
        guard let first = holding(place).first, let look = place.look(of: first)?.kept else { return nil }
        let ids = selection
        let style = doc.styleNaming(look, name, on: ids)
        edit("Name Style") { $0.name(style, at: place, on: ids) }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        let alike = doc.looksAlike(look, besides: Set(ids))
        let count = Set(alike.map(\.layer)).count
        if count > 0, let anchor = ids.first {
            show(StyleOffer(anchor: anchor, kind: .nameToo(style: style.id, uses: alike),
                            words: String(localized: "\(count) more layers look the same"), button: String(localized: "Name Them Too"),
                            layers: Array(Set(alike.map(\.layer)))))
        }
        return style.id
    }

    /// Gives the selection a style at a place: its look, and its name.
    func use(_ style: Style, at place: StylePlace) {
        let ids = selection
        edit("Use Style") { $0.use(style, at: place, on: ids) }
    }

    /// The selection keeps its look at a place, named nothing.
    func unname(at place: StylePlace) {
        let ids = selection
        edit("Remove Style Name") { $0.unname(at: place, on: ids) }
    }

    func renameStyle(_ id: UUID, to name: String) {
        guard let style = doc.style(id), BezzleDocument.tidiedStyleName(name, or: style.name) != style.name else { return }
        edit("Rename Style") { $0.renameStyle(id, to: name) }
    }

    /// Takes a style away. Its layers keep looking as they do.
    func removeStyle(_ id: UUID) {
        edit("Remove Style") { $0.removeStyle(id) }
    }

    /// Changes a style from the inspector's list, and so every layer that uses it: its look, or
    /// its look in the dark, made its own from then on.
    func changeStyle(_ id: UUID, _ action: LocalizedStringResource, dark: Bool = false, _ change: (inout StyleLook) -> Void) {
        styleShow.fromList = true
        defer { styleShow.fromList = false }
        edit(action) { $0.changeStyleLook(id, dark: dark, change) }
    }

    /// Lets a style's look in the dark follow its look again, made dark by itself.
    func followInTheDark(_ id: UUID) {
        styleShow.fromList = true
        defer { styleShow.fromList = false }
        edit("Automatic in the Dark") { $0.followInTheDark(id) }
    }

    /// Whether the design shows anything dark, or has a style made for the dark by hand.
    var hasDark: Bool { doc.hasDark }

    /// Whether the selected layers with a place lie on a dark artboard, as the first does.
    func showsDark(_ place: StylePlace) -> Bool {
        holding(place).first.map { doc.isDark($0.id) } ?? false
    }

    /// Names a look found on several layers, giving each of them the new style.
    @discardableResult
    func name(_ found: FoundLook, _ name: String? = nil) -> UUID {
        let style = doc.styleNaming(found, name)
        edit("Name Style") { $0.name(found, as: style) }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        styleShow.wave = StyleShow.Wave(origin: nil, layers: Array(Set(found.uses.map(\.layer))))
        return style.id
    }

    // MARK: After a change

    /// Looks at what a change did to the design's styles: while a drag goes on, which it is
    /// changing; once it is made, a wave over every layer it reached, and what can be made of it.
    func noteStyles(after before: BezzleDocument, settled: Bool, dragged: Bool = false) {
        guard doc.styles != nil || before.styles != nil else { return }
        let changed = BezzleDocument.stylesChanged(from: before, to: doc).filter { doc.style($0) != nil }
        if !settled {
            if !changed.isEmpty { styleShow.live.formUnion(changed) }
            return
        }
        styleShow.live = []
        if styleShow.offer != nil { styleShow.offer = nil }
        guard !changed.isEmpty else { return }
        var reached: [UUID] = []
        for id in changed { reached.append(contentsOf: layers(using: id)) }
        reached = Array(Set(reached))
        let origin = styleShow.fromList ? nil : selectionBounds.map { CGPoint(x: $0.midX, y: $0.midY) }
        if reached.count > 1 || styleShow.fromList {
            // A change made at once washes in; one dragged in was seen coming all along.
            styleShow.wave = StyleShow.Wave(origin: origin, layers: reached, washes: dragged ? [] : washes(of: reached, before: before))
        }
        guard !styleShow.fromList, offer == nil else { return }

        // Changed through the selection: offer to keep it there alone.
        guard let (anchor, olds, places, others) = doc.onlyHereOffer(before: before, selection: selection, changed: changed,
                                                                     users: { self.layers(using: $0) }) else { return }
        show(StyleOffer(anchor: anchor, kind: .onlyHere(styles: olds, places: places),
                        words: String(localized: "Also on \(others.count) more layers"), button: String(localized: "Only Here"),
                        layers: Array(others)))
    }

    /// Lets a change already made to an artboard wash over it, from its top right corner, as it
    /// does when it is made dark or light by hand.
    func washIn(_ boardID: UUID, before: BezzleDocument) {
        guard let board = doc.node(boardID) else { return }
        styleShow.wave = StyleShow.Wave(origin: CGPoint(x: board.frame.maxX, y: board.frame.minY), layers: [boardID],
                                        washes: washes(of: [boardID], before: before))
    }

    /// The artboards these layers lie on, as they looked `before`, in the part of each on screen.
    private func washes(of layers: [UUID], before: BezzleDocument) -> [StyleShow.Wash] {
        let view = visibleCanvasRect
        let scale = viewport.zoom * (canvas?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        var boards: [UUID] = []
        for id in layers {
            guard let board = doc.node(id).flatMap({ $0.isArtboard ? $0 : nil }) ?? doc.artboard(of: id), !boards.contains(board.id) else { continue }
            boards.append(board.id)
        }
        var pixels: CGFloat = 0
        var out: [StyleShow.Wash] = []
        for id in boards {
            guard let was = before.node(id), was.isArtboard, !was.hidden else { continue }
            let part = was.frame.intersection(view)
            guard !part.isNull, part.width > 1, part.height > 1 else { continue }
            pixels += part.width * part.height * scale * scale
            // Too much to draw at once; the wave alone shows the change.
            guard pixels < 24_000_000 else { return [] }
            let shown = was.isDeck ? was.showing(front(of: was)) : was
            if let image = Renderer.image(of: shown, part: part, scale: scale, assets: assets) { out.append(StyleShow.Wash(image: image, rect: part)) }
        }
        return out
    }

    private func show(_ offer: StyleOffer) {
        styleShow.offer = offer
        let token = offer.token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.styleShow.offer?.token == token { self?.styleShow.offer = nil }
        }
    }

    /// Does what a style's offer offers.
    func take(_ offer: StyleOffer) {
        styleShow.offer = nil
        styleShow.lit = []
        switch offer.kind {
        case .onlyHere(let styles, let places):
            edit("Only Here") { $0.keepOnlyHere(styles: styles, places: places) }
        case .lightTwin(let id):
            guard let board = doc.node(id), board.isArtboard else { return }
            var made: UUID?
            edit("Add Light Version") { doc in made = doc.addLightTwin(of: id) }
            if let made { styleShow.wave = StyleShow.Wave(origin: CGPoint(x: board.frame.maxX, y: board.frame.midY), layers: [made]) }
        case .nameToo(let id, let uses):
            guard doc.style(id) != nil else { return }
            edit("Name Style") { $0.nameToo(id, uses: uses) }
            styleShow.wave = StyleShow.Wave(origin: doc.absoluteFrame(of: offer.anchor).map { CGPoint(x: $0.midX, y: $0.midY) },
                                            layers: Array(Set(uses.map(\.layer)).union([offer.anchor])))
        }
    }

    // MARK: Light and dark

    /// Shows an artboard dark, or light again, keeping the switch between them: the change washes
    /// over it from its top right corner. Made dark, its colours without a name get one, so each
    /// can be dark by itself.
    func show(_ boardID: UUID, dark: Bool) {
        guard let board = doc.node(boardID), board.isArtboard, board.showsDark != dark || board.dark == nil, !board.locked else { return }
        let before = doc
        edit(dark ? "Make Dark" : "Make Light") { doc in doc.show(boardID, dark: dark, name: StyleNames.base) }
        guard doc.node(boardID)?.showsDark == dark else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        styleShow.offer = nil
        styleShow.wave = StyleShow.Wave(origin: CGPoint(x: board.frame.maxX, y: board.frame.minY), layers: [boardID],
                                        washes: washes(of: [boardID], before: before))
        if dark, selection.contains(boardID) {
            show(StyleOffer(anchor: boardID, kind: .lightTwin(boardID), words: String(localized: "A light one beside it"),
                            button: String(localized: "Add"), layers: [boardID]))
        }
    }

    /// An artboard light for good, with no switch to dark any more; its styles stay as they are.
    func forgetDark(_ boardID: UUID) {
        guard let board = doc.node(boardID), board.isArtboard, board.dark != nil, !board.locked else { return }
        let before = doc
        edit("Remove Dark") { $0.update(boardID) { $0.dark = nil } }
        if board.showsDark { washIn(boardID, before: before) }
    }

    /// The design with an artboard dark, or light again, as `show` would make it, for the canvas
    /// to show while the choice is pointed at.
    func previewing(_ boardID: UUID, dark: Bool) -> (inout BezzleDocument) -> Void {
        { $0.previewDark(boardID, dark: dark) }
    }

    /// A light copy of an artboard, beside it and clear of the others in its row; returns its id.
    static func lightTwin(of id: UUID, in doc: inout BezzleDocument) -> UUID? { doc.addLightTwin(of: id) }

    // MARK: Names

    /// A name for a look not named yet: what a colour is called, what a size of type is for, the
    /// shadow or corners it is among the choices; never one another style of its kind has.
    func suggestedName(for look: StyleLook) -> String { doc.suggestedName(for: look) }
}
