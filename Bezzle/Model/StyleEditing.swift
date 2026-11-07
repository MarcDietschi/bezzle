import Foundation
import CoreGraphics

/// Giving looks names and changing the design's styles (see `Style`), shared by every Bezzle: the
/// Mac's store calls these inside its steps of the history, as Windows does. What the canvas
/// shows of a change (its wave, the offers) stays each app's own.
extension BezzleDocument {
    // MARK: Reading

    /// The design's styles of a kind, in their order.
    func styles(of kind: StyleKind) -> [Style] {
        (styles ?? []).filter { $0.kind == kind }.sorted { ($0.rank, $0.id.uuidString) < ($1.rank, $1.id.uuidString) }
    }

    /// The layers that use each style, by style.
    func styleUsers() -> [UUID: [UUID]] {
        var users: [UUID: [UUID]] = [:]
        func visit(_ n: Node) {
            var seen = Set<UUID>()
            for place in StylePlace.all(in: n) { if let s = place.named(in: n), seen.insert(s).inserted { users[s, default: []].append(n.id) } }
            n.children.forEach(visit)
        }
        if styles != nil { nodes.forEach(visit) }
        return users
    }

    /// Whether the design shows anything dark, or has a style made for the dark by hand.
    var hasDark: Bool {
        nodes.contains(where: \.showsDark) || (styles ?? []).contains { $0.dark != nil }
    }

    // MARK: Names

    static func tidiedStyleName(_ name: String, or fallback: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : String(t.prefix(60))
    }

    /// A name for a look not named yet: what a colour is called, what a size of type is for, the
    /// shadow or corners it is among the choices; never one another style of its kind has.
    func suggestedName(for look: StyleLook) -> String {
        freshName(StyleNames.base(look), kind: look.kind)
    }

    // MARK: Naming

    /// The style that naming `look` on the layers `ids` makes: named as asked, or as the look is
    /// called. Named on a dark artboard, it is that look in the dark: naming changes nothing to
    /// be seen.
    func styleNaming(_ look: StyleLook, _ name: String, on ids: [UUID]) -> Style {
        var style = Style(name: Self.tidiedStyleName(name, or: suggestedName(for: look)), look: look)
        if ids.contains(where: isDark) { style.dark = look }
        return style
    }

    /// Adds `style` and gives its name to every layer of `ids` whose place takes its look.
    mutating func name(_ style: Style, at place: StylePlace, on ids: [UUID]) {
        addStyle(style)
        for id in ids {
            update(id) { n in
                if place.look(of: n) != nil, place.takes(style.look, in: n) { place.name(style.id, in: &n) }
            }
        }
    }

    /// Gives the layers a style at a place: its look, as it is on their artboards, and its name.
    mutating func use(_ style: Style, at place: StylePlace, on ids: [UUID]) {
        let before = self
        for id in ids {
            update(id) { n in
                let shown = style.look(dark: before.isDark(n.id))
                if place.look(of: n) != nil, place.takes(shown, in: n) {
                    place.name(style.id, in: &n)
                    place.apply(shown, to: &n)
                    // Named type is the whole layer's: letters set apart in size or font follow it again.
                    if place == .text, let spans = n.spans {
                        let parts: Set<Letters.Part> = [.family, .face, .size, .tracking, .underline, .strikethrough]
                        n.spans = TextSpan.stored(TextSpan.tidy(spans.map { TextSpan(text: $0.text, look: $0.look.without(parts)) }))
                        n.refit()
                    }
                }
                n.refit()
            }
        }
    }

    /// The layers keep their look at a place, named nothing.
    mutating func unname(at place: StylePlace, on ids: [UUID]) {
        for id in ids {
            update(id) { n in
                place.name(nil, in: &n)
                n.refit()
            }
        }
    }

    /// A style's name, tidied; whether it changed.
    @discardableResult mutating func renameStyle(_ id: UUID, to name: String) -> Bool {
        guard let style = style(id) else { return false }
        let new = Self.tidiedStyleName(name, or: style.name)
        guard new != style.name else { return false }
        changeStyle(id) { $0.name = new }
        return true
    }

    /// Changes a style's look, or its look in the dark, made its own from then on.
    mutating func changeStyleLook(_ id: UUID, dark: Bool, _ change: (inout StyleLook) -> Void) {
        changeStyle(id) { s in
            if dark {
                var look = s.look(dark: true)
                change(&look)
                s.dark = look
            } else {
                change(&s.look)
            }
        }
    }

    /// Lets a style's look in the dark follow its look again, made dark by itself.
    mutating func followInTheDark(_ id: UUID) {
        changeStyle(id) { $0.dark = nil }
    }

    /// The style naming a look found on several layers makes.
    func styleNaming(_ found: FoundLook, _ name: String?) -> Style {
        var style = Style(name: Self.tidiedStyleName(name ?? "", or: suggestedName(for: found.look)), look: found.look.kept)
        if found.uses.contains(where: { isDark($0.layer) }) { style.dark = style.look }
        return style
    }

    /// Adds `style` and gives its name to each place a look was found.
    mutating func name(_ found: FoundLook, as style: Style) {
        addStyle(style)
        for use in found.uses { update(use.layer) { use.place.name(style.id, in: &$0) } }
    }

    // MARK: After a change

    /// What to offer after a change made through the selected layers to styles they name: to keep
    /// it on them alone. The places they name a changed style, the styles as they were, the layer
    /// to show the offer beside, and the other layers the change reached. `users` gives the
    /// layers that use a style now.
    func onlyHereOffer(before: BezzleDocument, selection: [UUID], changed: Set<UUID>, users: (UUID) -> [UUID])
        -> (anchor: UUID, styles: [UUID: Style], places: [FoundLook.Use], others: Set<UUID>)? {
        var places: [FoundLook.Use] = [], olds: [UUID: Style] = [:]
        for id in selection {
            guard let n = node(id), let was = before.node(id) else { continue }
            let dark = isDark(id)
            for place in StylePlace.all(in: n) {
                guard let s = place.named(in: n), changed.contains(s), place.named(in: was) == s,
                      let old = before.style(s), !place.shows(old.look(dark: dark), in: n) else { continue }
                places.append(FoundLook.Use(layer: id, place: place))
                olds[s] = old
            }
        }
        let mine = Set(places.map(\.layer))
        let others = Set(olds.keys.flatMap { users($0) }).subtracting(mine)
        guard let anchor = places.first?.layer, !others.isEmpty else { return nil }
        return (anchor, olds, places, others)
    }

    /// The change kept where it was made: those places named nothing, the styles as they were.
    mutating func keepOnlyHere(styles: [UUID: Style], places: [FoundLook.Use]) {
        for use in places { update(use.layer) { use.place.name(nil, in: &$0) } }
        for (id, old) in styles { changeStyle(id) { $0.look = old.look; $0.dark = old.dark } }
    }

    /// A style just named, given to the places that look the same.
    mutating func nameToo(_ id: UUID, uses: [FoundLook.Use]) {
        for use in uses { update(use.layer) { use.place.name(id, in: &$0) } }
    }

    // MARK: Light and dark

    /// The design with an artboard dark, or light again, as making it so does, for the canvas
    /// to show while the choice is pointed at.
    mutating func previewDark(_ board: UUID, dark: Bool) {
        let before = self
        show(board, dark: dark, name: StyleNames.base)
        _ = keepStyles(since: before)
    }

    /// A light copy of an artboard, beside it and clear of the others in its row; returns its id.
    mutating func addLightTwin(of id: UUID) -> UUID? {
        guard let p = path(of: id), p.indices.count == 1 else { return nil }
        let board = self[p]
        var copy = board.freshCopy()
        copy.dark = nil
        copy.name = String(localized: "\(board.name) Light")
        let row = nodes.filter { $0.id != id && !$0.hidden && $0.frame.maxY > board.frame.minY && $0.frame.minY < board.frame.maxY }
        let right = row.filter { $0.frame.minX >= board.frame.minX }.map(\.frame.maxX).max() ?? board.frame.maxX
        copy.frame.origin.x = max(board.frame.maxX, right) + 80
        var at = p
        at.indices[0] += 1
        insert(copy, at: at)
        return copy.id
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
