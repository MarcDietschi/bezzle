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
        /// The artboards as they looked before, in the part of them on screen, laid over the canvas
        /// until the wave has passed: the change comes in behind it, as paint washing over them.
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
    func styles(of kind: StyleKind) -> [Style] {
        (doc.styles ?? []).filter { $0.kind == kind }.sorted { ($0.rank, $0.id.uuidString) < ($1.rank, $1.id.uuidString) }
    }

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
        var users: [UUID: [UUID]] = [:]
        func visit(_ n: Node) {
            var seen = Set<UUID>()
            for place in StylePlace.all(in: n) { if let s = place.named(in: n), seen.insert(s).inserted { users[s, default: []].append(n.id) } }
            n.children.forEach(visit)
        }
        if doc.styles != nil { doc.nodes.forEach(visit) }
        styleShow.usersWorkedOut = (version, users)
        return users[id] ?? []
    }

    // MARK: Naming

    /// Gives the look the selection has at a place a name, making a style of it that every selected
    /// layer with the same look uses; offers then to name the others that look the same.
    @discardableResult
    func nameLook(at place: StylePlace, _ name: String) -> UUID? {
        guard let first = holding(place).first, let look = place.look(of: first)?.kept else { return nil }
        var style = Style(name: Self.tidied(name, or: suggestedName(for: look)), look: look)
        let ids = selection
        // Named on a dark artboard, it is that look in the dark: naming changes nothing to be seen.
        if ids.contains(where: doc.isDark) { style.dark = look }
        edit("Name Style") { doc in
            doc.addStyle(style)
            for id in ids {
                doc.update(id) { n in
                    if place.look(of: n) != nil, place.takes(look, in: n) { place.name(style.id, in: &n) }
                }
            }
        }
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
        let doc = doc
        updateSelection("Use Style") { n in
            let shown = style.look(dark: doc.isDark(n.id))
            guard place.look(of: n) != nil, place.takes(shown, in: n) else { return }
            place.name(style.id, in: &n)
            place.apply(shown, to: &n)
            // Named type is the whole layer's: letters set apart in size or font follow it again.
            if place == .text, let spans = n.spans {
                let parts: Set<Letters.Part> = [.family, .face, .size, .tracking, .underline, .strikethrough]
                n.spans = TextSpan.stored(TextSpan.tidy(spans.map { TextSpan(text: $0.text, look: $0.look.without(parts)) }))
                n.refit()
            }
        }
    }

    /// The selection keeps its look at a place, named nothing.
    func unname(at place: StylePlace) {
        updateSelection("Remove Style Name") { place.name(nil, in: &$0) }
    }

    func renameStyle(_ id: UUID, to name: String) {
        guard let style = doc.style(id) else { return }
        let new = Self.tidied(name, or: style.name)
        guard new != style.name else { return }
        edit("Rename Style") { $0.changeStyle(id) { $0.name = new } }
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
        edit(action) { doc in
            doc.changeStyle(id) { s in
                if dark {
                    var look = s.look(dark: true)
                    change(&look)
                    s.dark = look
                } else {
                    change(&s.look)
                }
            }
        }
    }

    /// Lets a style's look in the dark follow its look again, made dark by itself.
    func followInTheDark(_ id: UUID) {
        styleShow.fromList = true
        defer { styleShow.fromList = false }
        edit("Automatic in the Dark") { $0.changeStyle(id) { $0.dark = nil } }
    }

    /// Whether the design shows anything dark, or has a style made for the dark by hand.
    var hasDark: Bool {
        doc.nodes.contains(where: \.showsDark) || (doc.styles ?? []).contains { $0.dark != nil }
    }

    /// Whether the selected layers with a place lie on a dark artboard, as the first does.
    func showsDark(_ place: StylePlace) -> Bool {
        holding(place).first.map { doc.isDark($0.id) } ?? false
    }

    /// Names a look found on several layers, giving each of them the new style.
    @discardableResult
    func name(_ found: FoundLook, _ name: String? = nil) -> UUID {
        var style = Style(name: Self.tidied(name ?? "", or: suggestedName(for: found.look)), look: found.look.kept)
        if found.uses.contains(where: { doc.isDark($0.layer) }) { style.dark = style.look }
        edit("Name Style") { doc in
            doc.addStyle(style)
            for use in found.uses { doc.update(use.layer) { use.place.name(style.id, in: &$0) } }
        }
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
        var places: [FoundLook.Use] = [], olds: [UUID: Style] = [:]
        for id in selection {
            guard let n = doc.node(id), let was = before.node(id) else { continue }
            let dark = doc.isDark(id)
            for place in StylePlace.all(in: n) {
                guard let s = place.named(in: n), changed.contains(s), place.named(in: was) == s,
                      let old = before.style(s), !place.shows(old.look(dark: dark), in: n) else { continue }
                places.append(FoundLook.Use(layer: id, place: place))
                olds[s] = old
            }
        }
        let mine = Set(places.map(\.layer))
        let others = Set(olds.keys.flatMap { layers(using: $0) }).subtracting(mine)
        guard let anchor = places.first?.layer, !others.isEmpty else { return }
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
            edit("Only Here") { doc in
                for use in places { doc.update(use.layer) { use.place.name(nil, in: &$0) } }
                for (id, old) in styles { doc.changeStyle(id) { $0.look = old.look; $0.dark = old.dark } }
            }
        case .lightTwin(let id):
            guard let board = doc.node(id), board.isArtboard else { return }
            var made: UUID?
            edit("Add Light Version") { doc in made = Self.lightTwin(of: id, in: &doc) }
            if let made { styleShow.wave = StyleShow.Wave(origin: CGPoint(x: board.frame.maxX, y: board.frame.midY), layers: [made]) }
        case .nameToo(let id, let uses):
            guard doc.style(id) != nil else { return }
            edit("Name Style") { doc in
                for use in uses { doc.update(use.layer) { use.place.name(id, in: &$0) } }
            }
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
        { doc in
            let before = doc
            doc.show(boardID, dark: dark, name: StyleNames.base)
            _ = doc.keepStyles(since: before)
        }
    }

    /// A light copy of an artboard, beside it and clear of the others in its row; returns its id.
    static func lightTwin(of id: UUID, in doc: inout BezzleDocument) -> UUID? {
        guard let p = doc.path(of: id), p.indices.count == 1 else { return nil }
        let board = doc[p]
        var copy = board.freshCopy()
        copy.dark = nil
        copy.name = String(localized: "\(board.name) Light")
        let row = doc.nodes.filter { $0.id != id && !$0.hidden && $0.frame.maxY > board.frame.minY && $0.frame.minY < board.frame.maxY }
        let right = row.filter { $0.frame.minX >= board.frame.minX }.map(\.frame.maxX).max() ?? board.frame.maxX
        copy.frame.origin.x = max(board.frame.maxX, right) + 80
        var at = p
        at.indices[0] += 1
        doc.insert(copy, at: at)
        return copy.id
    }

    // MARK: Names

    private static func tidied(_ name: String, or fallback: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : String(t.prefix(60))
    }

    /// A name for a look not named yet: what a colour is called, what a size of type is for, the
    /// shadow or corners it is among the choices; never one another style of its kind has.
    func suggestedName(for look: StyleLook) -> String {
        doc.freshName(StyleNames.base(look), kind: look.kind)
    }
}

/// What a look is called before it is given a name of one's own.
enum StyleNames {
    /// What a look is, in a word or two: the colour, what a size of type is for, the shadow or
    /// corners it is among the choices.
    static func base(_ look: StyleLook) -> String {
        switch look {
        case .colour(let p): return p.gradient != nil ? String(localized: "Gradient") : colour(p.color)
        case .text(let t): return type(t.size)
        case .shadow(let s):
            let presets = s.inset == true ? Presets.innerShadows : Presets.shadows
            if let p = presets.first(where: { Presets.isShadow($0, s) }) { return String(localized: p.name) }
            return s.inset == true ? String(localized: "Inner shadow") : String(localized: "Shadow")
        case .corners(let c):
            if let p = Presets.corners.first(where: { $0.radius == c.radius && $0.radius != 0 }) { return String(localized: p.name) }
            return String(localized: "Corners \(Int(c.radius.rounded()))")
        }
    }

    /// A colour's everyday name: the hue, lighter or darker, or the grey it is.
    static func colour(_ c: RGBA) -> String {
        // As the eye sees it: lightness, how colourful, and which way round the hues.
        let (l, a, b) = c.oklab
        let chroma = hypot(a, b)
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        if chroma < 0.03 {
            if l > 0.985 { return String(localized: "White") }
            // A white with a little warmth in it, as paper has.
            if l > 0.93 { return chroma > 0.006 && (40..<120).contains(hue) ? String(localized: "Ivory") : String(localized: "Off-white") }
            if l > 0.82 { return chroma > 0.012 && (40..<110).contains(hue) ? String(localized: "Beige") : String(localized: "Light grey") }
            if l < 0.3 { return String(localized: "Black") }
            if l < 0.48 { return String(localized: "Dark grey") }
            return String(localized: "Grey")
        }
        // Pale and deep are both soft: a pure yellow is yellow, however light it is.
        let light = l > 0.82 && chroma < 0.12, dark = l < 0.48 && chroma < 0.2
        // Brown and beige are orange, darker or paler and not very colourful.
        if (35..<95).contains(hue), dark || (l < 0.62 && chroma < 0.12) { return String(localized: "Brown") }
        if (40..<110).contains(hue), light, chroma < 0.07 { return String(localized: "Beige") }
        switch hue {
        case 345..., ..<15:
            return light ? String(localized: "Light pink") : dark ? String(localized: "Dark pink") : String(localized: "Pink")
        case 15..<45:
            return light ? String(localized: "Light red") : dark ? String(localized: "Dark red") : String(localized: "Red")
        case 45..<85:
            return light ? String(localized: "Light orange") : dark ? String(localized: "Dark orange") : String(localized: "Orange")
        case 85..<120:
            return light ? String(localized: "Light yellow") : dark ? String(localized: "Olive") : String(localized: "Yellow")
        case 120..<175:
            return light ? String(localized: "Light green") : dark ? String(localized: "Dark green") : String(localized: "Green")
        case 175..<225:
            return light ? String(localized: "Light teal") : dark ? String(localized: "Dark teal") : String(localized: "Teal")
        case 225..<290:
            return light ? String(localized: "Light blue") : dark ? String(localized: "Dark blue") : String(localized: "Blue")
        default:
            return light ? String(localized: "Light purple") : dark ? String(localized: "Dark purple") : String(localized: "Purple")
        }
    }

    /// What type of a size is most often for.
    static func type(_ size: CGFloat) -> String {
        switch size {
        case 48...: String(localized: "Display")
        case 32..<48: String(localized: "Title")
        case 24..<32: String(localized: "Heading")
        case 19..<24: String(localized: "Subheading")
        case 15..<19: String(localized: "Body")
        case 12..<15: String(localized: "Small")
        default: String(localized: "Caption")
        }
    }
}
