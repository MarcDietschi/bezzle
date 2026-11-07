import Foundation

// The design's styles on Windows, as the Mac's inspector offers them (Views/StyleViews.swift):
// a card whose look has a name says it, and open, first offers the design's styles of its kind,
// to use, point at, rename or let go of, and to name its own look. The changes themselves are
// the shared ones (Model/StyleEditing.swift).

extension WindowsCore {
    /// A place on layers that can have a name, by the key the inspector's cards use: "fill:0",
    /// "border:1", "shadow:0", "text", "corners".
    static func stylePlace(_ key: String) -> StylePlace? {
        let parts = key.split(separator: ":")
        let slot = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "fill": return .fill(slot)
        case "border": return .border(slot)
        case "shadow": return .shadow(slot)
        case "text": return .text
        case "corners": return .corners
        default: return nil
        }
    }

    /// The selected layers that have the place.
    private static func holding(_ place: StylePlace, _ selection: [UUID]) -> [Node] {
        guard let doc = design else { return [] }
        return selection.compactMap { doc.node($0) }.filter { place.look(of: $0) != nil }
    }

    /// The style every selected layer with the place has there, when they share one.
    private static func sharedStyle(_ place: StylePlace, _ selection: [UUID]) -> Style? {
        let those = holding(place, selection)
        guard let id = those.first.flatMap(place.named(in:)), those.allSatisfy({ place.named(in: $0) == id }) else { return nil }
        return design?.style(id)
    }

    /// A style's look in small, as its chip shows it: a colour (or gradient), a type in itself, a
    /// shadow, or corners.
    nonisolated public struct StyleSample: Sendable {
        public let kind: String
        public let paint: PaintLook?
        public let family: String?
        public let weight: Int
        public let italic: Bool
        public let size: Double
        public let shadow: (y: Double, blur: Double, inset: Bool)?
        public let radius: Double
    }

    static func sample(_ look: StyleLook) -> StyleSample {
        switch look {
        case .colour(let c):
            var fill = Fill(color: c.color, gradient: c.gradient)
            fill.on = true
            return StyleSample(kind: "colour", paint: paintLook(fill), family: nil, weight: 400, italic: false, size: 0, shadow: nil, radius: 0)
        case .text(let t):
            let traits = Fonts.traits(named: t.face)
            let weights = [2: 100, 3: 200, 4: 300, 5: 400, 6: 500, 7: 600, 8: 600, 9: 700, 10: 800, 11: 900, 12: 900]
            return StyleSample(kind: "type", paint: nil, family: t.family, weight: weights[traits.weight] ?? 400, italic: traits.italic,
                               size: Double(t.size), shadow: nil, radius: 0)
        case .shadow(let s):
            return StyleSample(kind: "shadow", paint: nil, family: nil, weight: 400, italic: false, size: 0,
                               shadow: (Double(s.y), Double(s.blur), s.inset == true), radius: 0)
        case .corners(let c):
            return StyleSample(kind: "corners", paint: nil, family: nil, weight: 400, italic: false, size: 0, shadow: nil, radius: Double(c.radius))
        }
    }

    /// One of the design's styles, as a card's row offers it.
    nonisolated public struct StyleChip: Sendable {
        public let id: UUID
        public let name: String
        public let active: Bool
        public let sample: StyleSample
    }

    /// What a card's row of styles shows: the styles the selection can be given there (the one it
    /// has among the first few, in a long row), whether the look can be named, how many wait.
    nonisolated public struct StyleRowLook: Sendable {
        public let chips: [StyleChip]
        public let current: UUID?
        public let hidden: Int
        /// The look as it is, to be named, when it has no name.
        public let unnamed: StyleSample?
    }

    /// How many of a kind's styles show before the rest wait behind a chip that counts them.
    public static let stylesShownCount = 5
    static var stylesShown: Int { stylesShownCount }

    public static func styleRow(_ key: String, _ selection: [UUID], all: Bool) -> StyleRowLook? {
        guard let doc = design, let place = stylePlace(key) else { return nil }
        let those = holding(place, selection)
        guard !those.isEmpty else { return nil }
        let options = doc.styles(of: place.kind).filter { s in those.allSatisfy { place.takes(s.look, in: $0) } }
        let current = sharedStyle(place, selection)
        let dark = those.first.map { doc.isDark($0.id) } ?? false
        let many = options.count > stylesShown + 1
        var visible = options
        if many, !all {
            visible = Array(options.prefix(stylesShown))
            if let id = current?.id, !visible.contains(where: { $0.id == id }), let s = options.first(where: { $0.id == id }) {
                visible[visible.count - 1] = s
            }
        }
        let unnamed = current == nil ? those.first.flatMap(place.look(of:)).map(sample) : nil
        return StyleRowLook(chips: visible.map { StyleChip(id: $0.id, name: $0.name, active: $0.id == current?.id, sample: sample($0.look(dark: dark))) },
                            current: current?.id, hidden: many ? options.count - visible.count : 0, unnamed: unnamed)
    }

    /// The name of the style the selection shares at a card's place, for the card to say.
    public static func styleName(at key: String, _ selection: [UUID]) -> String? {
        guard let place = stylePlace(key) else { return nil }
        return sharedStyle(place, selection)?.name
    }

    /// The selection given a style at a place, as one step.
    public static func useStyle(_ id: UUID, at key: String, _ selection: [UUID]) {
        guard let place = stylePlace(key), let style = design?.style(id) else { return }
        endPreview()
        edit { $0.use(style, at: place, on: selection) }
    }

    /// The canvas showing the selection with a style, while its chip is pointed at.
    public static func previewStyle(_ id: UUID, at key: String, _ selection: [UUID], _ on: Bool) {
        endPreview()
        guard on, let doc = design, let place = stylePlace(key), let style = doc.style(id) else { return }
        preview { d in
            for n in holding(place, selection) {
                let look = style.look(dark: doc.isDark(n.id))
                d.update(n.id) { if place.look(of: $0) != nil, place.takes(look, in: $0) { place.apply(look, to: &$0) } }
            }
        }
    }

    /// The selection keeps its look at a place, named nothing.
    public static func unnameStyle(at key: String, _ selection: [UUID]) {
        guard let place = stylePlace(key) else { return }
        edit { $0.unname(at: place, on: selection) }
    }

    public static func renameStyle(_ id: UUID, to name: String) {
        guard let doc = design, let style = doc.style(id), BezzleDocument.tidiedStyleName(name, or: style.name) != style.name else { return }
        edit { $0.renameStyle(id, to: name) }
    }

    /// What a look at a place is called before it has a name of its own.
    public static func suggestedStyleName(at key: String, _ selection: [UUID]) -> String {
        guard let doc = design, let place = stylePlace(key), let look = holding(place, selection).first.flatMap(place.look(of:))?.kept else { return "" }
        return doc.suggestedName(for: look)
    }

    /// Gives the look the selection has at a place a name, as one step; then, when other layers
    /// look the same, what is offered: their uses and how many layers they are.
    @discardableResult
    public static func nameLook(at key: String, _ name: String, _ selection: [UUID]) -> (style: UUID, alike: Int)? {
        guard let doc = design, let place = stylePlace(key), let first = holding(place, selection).first, let look = place.look(of: first)?.kept else { return nil }
        let style = doc.styleNaming(look, name, on: selection)
        edit { $0.name(style, at: place, on: selection) }
        let alike = design?.looksAlike(look, besides: Set(selection)) ?? []
        let count = Set(alike.map(\.layer)).count
        // The step made, the offer comes once it has been looked at.
        Editing.lastStep = nil
        if count > 0, let anchor = selection.first {
            styleOffered = .nameToo(style: style.id, uses: alike)
            pendingStyleOffer = CopyOffer(anchor: anchor, words: say("%lld more layers look the same", count), buttons: [say("Name Them Too")],
                                          token: UUID(), style: true)
        }
        return (style.id, count)
    }
}

extension WindowsCore {
    /// Every layer that uses a style, as its corners on the canvas, as the Mac's StyleMarks
    /// outlines them while the style is pointed at.
    public static func styleUserOutlines(_ id: UUID) -> [[CGPoint]] {
        guard let doc = design else { return [] }
        return (doc.styleUsers()[id] ?? []).compactMap { doc.shownCorners(of: $0) }
    }
}

// MARK: - The kit, with nothing picked

extension WindowsCore {
    /// One of the design's styles in the kit, or a look several layers have alike without a name.
    nonisolated public struct KitEntry: Sendable {
        /// The style's; nil for a look found.
        public let id: UUID?
        public let name: String?
        public let sample: StyleSample
        /// Its look in the dark, while the design shows anything dark.
        public let dark: StyleSample?
        /// How many layers use it, or have it alike.
        public let uses: Int
        /// The hex of a colour, "Gradient", or a type's size.
        public let detail: String
        /// What a type is, by family and face.
        public let typeName: String
    }

    /// The kit's cards: each kind that has styles or looks found, with them, the most found first.
    public static func styleKit() -> [(kind: String, named: [KitEntry], found: [KitEntry])] {
        guard let doc = design else { return [] }
        let found = doc.foundLooks()
        let uses = doc.styleUses
        let dark = doc.hasDark
        func detail(_ look: StyleLook) -> String {
            switch look {
            case .colour(let c): return c.gradient != nil ? say("Gradient") : "#\(c.color.hex)"
            case .text(let t): return said(Double(t.size))
            default: return ""
            }
        }
        func typeName(_ look: StyleLook) -> String {
            guard case .text(let t) = look else { return "" }
            return "\(Fonts.displayName(t.family)) \(t.face)"
        }
        var out: [(String, [KitEntry], [KitEntry])] = []
        for kind in StyleKind.allCases {
            let named = doc.styles(of: kind).map { s in
                KitEntry(id: s.id, name: s.name, sample: sample(s.look), dark: dark ? sample(s.look(dark: true)) : nil,
                         uses: uses[s.id] ?? 0, detail: detail(s.look), typeName: typeName(s.look))
            }
            let ghosts = (found[kind] ?? []).prefix(kind == .colour ? 8 : 4).map { f in
                KitEntry(id: nil, name: nil, sample: sample(f.look), dark: nil, uses: f.count, detail: detail(f.look), typeName: typeName(f.look))
            }
            if !named.isEmpty || !ghosts.isEmpty { out.append((kind.rawValue, named, Array(ghosts))) }
        }
        return out
    }

    private static func said(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)
    }

    private static func found(_ kind: String, _ index: Int) -> FoundLook? {
        guard let k = StyleKind(rawValue: kind), let list = design?.foundLooks()[k], list.indices.contains(index) else { return nil }
        return list[index]
    }

    /// The layers a look found lies on, to outline while it is pointed at.
    public static func foundLayers(_ kind: String, _ index: Int) -> [UUID] {
        found(kind, index).map { Array(Set($0.uses.map(\.layer))) } ?? []
    }

    /// Names a look found on several layers, giving each of them the new style, as one step.
    @discardableResult public static func nameFound(_ kind: String, _ index: Int) -> UUID? {
        guard let doc = design, let f = found(kind, index) else { return nil }
        let style = doc.styleNaming(f, nil)
        stylesFromList = true
        defer { stylesFromList = false }
        edit { $0.name(f, as: style) }
        return style.id
    }

    /// A style opened in the kit, to be changed: its name and what makes its look, as it is in the
    /// light or, with `dark`, in the dark.
    nonisolated public struct StyleEdit: Sendable {
        public let name: String
        public let kind: String
        public let colour: Colour?
        public let gradient: Bool
        public let family: String
        public let face: String
        public let size: Double
        public let line: Double?
        public let tracking: Double
        public let shadow: (colour: Colour, x: Double, y: Double, blur: Double, spread: Double)?
        public let radius: Double
        public let smooth: Bool
        /// Whether its look in the dark is its own, made by hand.
        public let ownDark: Bool
        /// Whether it has a look in the dark to change: a colour or a shadow, while the design shows anything dark.
        public let darkens: Bool
    }

    public static func styleEdit(_ id: UUID, dark: Bool) -> StyleEdit? {
        guard let doc = design, let s = doc.style(id) else { return nil }
        let darkens = doc.hasDark && (s.kind == .colour || s.kind == .shadow)
        let look = s.look(dark: darkens && dark)
        var e = (colour: Colour?.none, gradient: false, family: "", face: "", size: 0.0, line: Double?.none, tracking: 0.0,
                 shadow: (colour: Colour, x: Double, y: Double, blur: Double, spread: Double)?.none, radius: 0.0, smooth: false)
        switch look {
        case .colour(let c): e.colour = Colour(c.color); e.gradient = c.gradient != nil
        case .text(let t):
            e.family = t.family; e.face = t.face; e.size = Double(t.size); e.line = t.lineSpacing.map { Double($0) }; e.tracking = Double(t.tracking)
        case .shadow(let sh): e.shadow = (Colour(sh.color), Double(sh.x), Double(sh.y), Double(sh.blur), Double(sh.spread ?? 0))
        case .corners(let c): e.radius = Double(c.radius); e.smooth = (c.smoothing ?? 0) > 0
        }
        return StyleEdit(name: s.name, kind: s.kind.rawValue, colour: e.colour, gradient: e.gradient, family: e.family, face: e.face, size: e.size,
                         line: e.line, tracking: e.tracking, shadow: e.shadow, radius: e.radius, smooth: e.smooth, ownDark: s.dark != nil, darkens: darkens)
    }

    /// A change to a style from the kit, to every layer that uses it.
    public enum StyleChange {
        case colour(Colour)
        case family(String), face(String), size(Double), line(Double), tracking(Double)
        case shadowColour(Colour), shadowX(Double), shadowY(Double), shadowBlur(Double), shadowSpread(Double)
        case radius(Double), smooth(Bool)
    }

    public static func changeStyle(_ id: UUID, dark: Bool, _ change: StyleChange) {
        guard let doc = design, let s = doc.style(id) else { return }
        let darkens = doc.hasDark && (s.kind == .colour || s.kind == .shadow)
        stylesFromList = true
        defer { stylesFromList = false }
        edit { d in
            d.changeStyleLook(id, dark: darkens && dark) { look in
                switch (look, change) {
                case (.colour, .colour(let c)): look = .colour(ColourLook(color: RGBA(c)))
                case (.text(var t), _):
                    switch change {
                    case .family(let f): t.face = Fonts.face(like: t.face, of: t.family, in: f); t.family = f
                    case .face(let f): t.face = f
                    case .size(let v): t.size = CGFloat(v)
                    case .line(let v): t.lineSpacing = CGFloat(v)
                    case .tracking(let v): t.tracking = CGFloat(v)
                    default: return
                    }
                    look = .text(t)
                case (.shadow(var sh), _):
                    switch change {
                    case .shadowColour(let c): sh.color = RGBA(c)
                    case .shadowX(let v): sh.x = CGFloat(v)
                    case .shadowY(let v): sh.y = CGFloat(v)
                    case .shadowBlur(let v): sh.blur = CGFloat(v)
                    case .shadowSpread(let v): sh.spread = v == 0 ? nil : CGFloat(v)
                    default: return
                    }
                    look = .shadow(sh)
                case (.corners(var c), _):
                    switch change {
                    case .radius(let v): c.radius = CGFloat(v)
                    case .smooth(let on): c.smoothing = on ? Presets.squircle : nil
                    default: return
                    }
                    look = .corners(c)
                default:
                    return
                }
            }
        }
    }

    /// A style's look in the dark follows its look again.
    public static func followInTheDark(_ id: UUID) {
        stylesFromList = true
        defer { stylesFromList = false }
        edit { $0.followInTheDark(id) }
    }

    /// A style taken away; its layers keep their looks.
    public static func removeStyle(_ id: UUID) { edit { $0.removeStyle(id) } }
}

extension WindowsCore {
    /// Layers as their corners on the canvas.
    public static func layerOutlines(_ ids: [UUID]) -> [[CGPoint]] {
        guard let doc = design else { return [] }
        return ids.compactMap { doc.shownCorners(of: $0) }
    }
}

// MARK: - Light and dark

extension WindowsCore {
    /// How an artboard shows: dark or light (nil: with no dark look), and of the styles its
    /// layers use, how many and how many have been made dark by hand.
    public static func boardAppearance(_ id: UUID) -> (dark: Bool?, shows: Bool, named: Int, own: Int, locked: Bool)? {
        guard let doc = design, let board = doc.node(id), board.isArtboard else { return nil }
        var used = Set<UUID>()
        func visit(_ n: Node) {
            for place in StylePlace.all(in: n) { if let s = place.named(in: n) { used.insert(s) } }
            n.children.forEach(visit)
        }
        visit(board)
        let styles = (doc.styles ?? []).filter { used.contains($0.id) }
        // Kept as it is in the light, as words on a button are, is no change made by hand.
        return (board.dark, board.showsDark, styles.count, styles.filter { $0.dark != nil && $0.dark != $0.look }.count, board.locked)
    }

    /// Shows an artboard dark, or light again, keeping the switch between them, as one step; made
    /// dark, its colours without a name get one, so each can be dark by itself. Made dark while
    /// it is picked, the offer of a light one beside it follows.
    @discardableResult public static func showDark(_ id: UUID, _ dark: Bool, picked: Bool) -> Bool {
        guard let board = design?.node(id), board.isArtboard, board.showsDark != dark || board.dark == nil, !board.locked else { return false }
        endPreview()
        edit { $0.show(id, dark: dark, name: StyleNames.base) }
        guard design?.node(id)?.showsDark == dark else { return false }
        Editing.lastStep = nil
        if dark, picked {
            styleOffered = .lightTwin(id)
            pendingStyleOffer = CopyOffer(anchor: id, words: say("A light one beside it"), buttons: [say("Add")], token: UUID(), style: true)
        }
        return true
    }

    /// The canvas showing an artboard dark while the choice is pointed at.
    public static func previewDark(_ id: UUID, _ on: Bool) {
        endPreview()
        guard on else { return }
        preview { $0.previewDark(id, dark: true) }
    }

    /// An artboard light for good, with no switch to dark any more; its styles stay as they are.
    public static func forgetDark(_ id: UUID) {
        guard let board = design?.node(id), board.isArtboard, board.dark != nil, !board.locked else { return }
        edit { $0.update(id) { $0.dark = nil } }
    }

    /// A light copy of an artboard, beside it, as one step: what is picked then.
    @discardableResult public static func addLightTwin(_ id: UUID) -> UUID? {
        var made: UUID?
        edit { made = $0.addLightTwin(of: id) }
        return made
    }
}

// MARK: - The wave

extension WindowsCore {
    /// A change carried to every layer that has a style, as the Mac's StyleShow.Wave: shown as
    /// light running out over them from where it was made (nil: from the inspector's side).
    nonisolated public struct StyleWave: Sendable {
        public let origin: CGPoint?
        public let layers: [UUID]
        /// Dragged in, it was seen coming all along: glow only.
        public let dragged: Bool
    }

    /// What the last step settled did to the design's styles, as the Mac's noteStyles: a wave
    /// over every layer it reached, when it reached more than one, or came from the list. Each
    /// step is looked at once.
    public static func considerStyleWave(selection: [UUID]) -> StyleWave? {
        guard let step = Editing.lastSettled, let doc = design else { return nil }
        Editing.lastSettled = nil
        guard doc.styles != nil || step.before.styles != nil else { return nil }
        let changed = BezzleDocument.stylesChanged(from: step.before, to: doc).filter { doc.style($0) != nil }
        guard !changed.isEmpty else { return nil }
        let users = doc.styleUsers()
        let reached = Array(Set(changed.flatMap { users[$0] ?? [] }))
        guard reached.count > 1 || step.fromList else { return nil }
        let origin = step.fromList ? nil : doc.bounds(of: selection).map { CGPoint(x: $0.midX, y: $0.midY) }
        return StyleWave(origin: origin, layers: reached, dragged: step.dragged)
    }
}
