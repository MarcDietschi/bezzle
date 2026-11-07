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
