import Foundation
import CoreGraphics

// MARK: - Looks given a name

/// A look the design has given a name to: a colour, a type, a shadow or corners. Wherever it is
/// used it is the same, and a change to it anywhere, on any layer that has it or in the design's
/// list of them, is a change to it everywhere.
///
/// A layer keeps the look itself as well as the name of what it uses (`Fill.named` and the
/// others), so it is drawn, exported and shared as any other layer is, and the design keeps
/// every one alike (`syncStyles`). Two people changing the same style both see the later change;
/// two people naming different looks both keep theirs.
nonisolated struct Style: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var look: StyleLook
    /// Where it comes among those of its kind, the lowest first.
    var rank: Double = 0
    /// How it looks on an artboard shown dark (`Node.dark`), as made there; nil follows `look`,
    /// made dark by itself (`StyleLook.darkened`).
    var dark: StyleLook?
    /// The design it was taken from, when it came from another one; nil for one named here. See
    /// `LibraryLink`.
    var library: LibraryLink?

    var kind: StyleKind { look.kind }

    /// How it looks in the light, or in the dark.
    func look(dark: Bool) -> StyleLook {
        dark ? (self.dark ?? look.darkened) : look
    }
}

/// What a style can be.
nonisolated enum StyleKind: String, Codable, CaseIterable, Hashable {
    case colour, text, shadow, corners
}

/// The look a style holds, as layers that use it have it.
nonisolated enum StyleLook: Codable, Hashable {
    /// One colour, or colours blending: what fills a layer, or the colour of its letters or border.
    case colour(ColourLook)
    case text(TypeLook)
    case shadow(Shadow)
    case corners(CornerLook)

    var kind: StyleKind {
        switch self {
        case .colour: .colour
        case .text: .text
        case .shadow: .shadow
        case .corners: .corners
        }
    }

    /// The same look as a style keeps it: a shadow on and named nothing.
    var kept: StyleLook {
        switch self {
        case .shadow(var s):
            s.on = true
            s.named = nil
            s.inset = s.inset == true ? true : nil
            s.spread = s.spread.flatMap { $0 == 0 ? nil : $0 }
            return .shadow(s)
        case .text(let t):
            return .text(TypeLook(t.style))
        case .corners(var c):
            c.smoothing = c.smoothing.flatMap { $0 > 0 ? $0 : nil }
            return .corners(c)
        case .colour:
            return self
        }
    }

    var paint: ColourLook? { if case .colour(let p) = self { p } else { nil } }
    var type: TypeLook? { if case .text(let t) = self { t } else { nil } }
    var shadow: Shadow? { if case .shadow(let s) = self { s } else { nil } }
    var corners: CornerLook? { if case .corners(let c) = self { c } else { nil } }
}

/// A colour, or a gradient over it, as a fill paints a layer.
nonisolated struct ColourLook: Codable, Hashable {
    var color: RGBA
    var gradient: Gradient?

    init(color: RGBA, gradient: Gradient? = nil) {
        self.color = color
        self.gradient = gradient
    }

    /// A fill's paint. Under a gradient its own colour is not seen, and the gradient's first
    /// stands for it.
    init(_ fill: Fill) {
        gradient = fill.gradient
        color = fill.gradient?.stops.first?.color ?? fill.color
    }

    /// Whether two paint alike: the same colour, or the same colours blending the same way.
    /// Where on a layer a gradient runs is the layer's own.
    func same(as other: ColourLook) -> Bool {
        if let g = gradient, let h = other.gradient { return g.kind == h.kind && g.stops == h.stops }
        return gradient == nil && other.gradient == nil && color == other.color
    }

    /// One colour only, as letters and borders take.
    var isSolid: Bool { gradient == nil }
}

/// What a named type sets: the font, its size, and how the letters and lines are spaced. Where the
/// words lie in their box, and how the box finds its size, are each layer's own.
nonisolated struct TypeLook: Codable, Hashable {
    var family: String
    var face: String
    var size: CGFloat
    var lineSpacing: CGFloat?
    var tracking: CGFloat
    var letterCase: LetterCase?
    var paragraphSpacing: CGFloat?
    var underline: Bool
    var strikethrough: Bool?
    var features: [String: Int]?
    var axes: [String: Double]?

    init(_ s: TextStyle) {
        family = s.family
        face = s.face
        size = s.size
        lineSpacing = s.lineSpacing
        tracking = s.tracking
        letterCase = s.letterCase
        paragraphSpacing = s.paragraphSpacing
        underline = s.underline
        strikethrough = s.strikethrough == true ? true : nil
        features = s.features?.isEmpty == true ? nil : s.features
        axes = s.axes?.isEmpty == true ? nil : s.axes
    }

    func apply(to s: inout TextStyle) {
        s.family = family
        s.face = face
        s.size = size
        s.lineSpacing = lineSpacing
        s.tracking = tracking
        s.letterCase = letterCase
        s.paragraphSpacing = paragraphSpacing
        s.underline = underline
        s.strikethrough = strikethrough
        s.features = features
        s.axes = axes
    }

    /// The type as a layer of it sets it, for drawing it in small.
    var style: TextStyle {
        var s = TextStyle()
        apply(to: &s)
        return s
    }
}

/// How round a rectangle's corners are, all four alike.
nonisolated struct CornerLook: Codable, Hashable {
    var radius: CGFloat
    /// How smoothly they run into the sides; nil is a circle's quarter. See `Node.cornerSmoothing`.
    var smoothing: CGFloat?
}

// MARK: - Where a layer has a look

/// A place on a layer that can have a named look: one of its fills, the colour of one of its
/// borders, one of its shadows, its type, or its corners.
nonisolated enum StylePlace: Hashable {
    case fill(Int), border(Int), shadow(Int), text, corners

    var kind: StyleKind {
        switch self {
        case .fill, .border: .colour
        case .shadow: .shadow
        case .text: .text
        case .corners: .corners
        }
    }

    /// Every place a layer has that could be named, named or not.
    static func all(in node: Node) -> [StylePlace] {
        var places: [StylePlace] = []
        for i in 0..<node.slots(.fill) { places.append(.fill(i)) }
        for i in 0..<node.slots(.border) { places.append(.border(i)) }
        for i in 0..<node.slots(.shadow) { places.append(.shadow(i)) }
        if node.kind == .text { places.append(.text) }
        if node.kind == .rectangle { places.append(.corners) }
        return places
    }

    /// The properties of a layer (`LayerField`) it lies in, as a post of a deck keeps its own.
    var fields: [String] {
        switch self {
        case .fill(let i): [i == 0 ? "fill" : "moreFills"]
        case .border(let i): [i == 0 ? "border" : "moreBorders"]
        case .shadow(let i): [i == 0 ? "shadow" : "moreShadows"]
        case .text: ["style"]
        case .corners: ["cornerRadius", "corners", "cornerSmoothing", "cornersNamed"]
        }
    }

    /// The style named here, if any.
    func named(in node: Node) -> UUID? {
        switch self {
        case .fill(let i): node[fill: i].named
        case .border(let i): node[border: i].named
        case .shadow(let i): node[shadow: i].named
        case .text: node.style?.named
        case .corners: node.cornersNamed
        }
    }

    func name(_ id: UUID?, in node: inout Node) {
        switch self {
        case .fill(let i): node[fill: i].named = id
        case .border(let i): node[border: i].named = id
        case .shadow(let i): node[shadow: i].named = id
        case .text: if node.style != nil { node.style?.named = id }
        case .corners: if node.kind == .rectangle || id == nil { node.cornersNamed = id }
        }
    }

    /// The look the layer has here, as a style would keep it; nil where there is nothing a style
    /// can be, as a picture or a slot it does not have.
    func look(of node: Node) -> StyleLook? {
        switch self {
        case .fill(let i):
            guard i < node.slots(.fill) else { return nil }
            let f = node[fill: i]
            guard f.image == nil else { return nil }
            return .colour(ColourLook(f))
        case .border(let i):
            guard i < node.slots(.border) else { return nil }
            let b = node[border: i]
            guard b.image == nil else { return nil }
            return .colour(ColourLook(Fill(color: b.color, gradient: b.gradient)))
        case .shadow(let i):
            guard i < node.slots(.shadow) else { return nil }
            return StyleLook.shadow(node[shadow: i]).kept
        case .text:
            guard node.kind == .text, let s = node.style else { return nil }
            return .text(TypeLook(s))
        case .corners:
            guard node.kind == .rectangle else { return nil }
            let r = node.radii
            return .corners(CornerLook(radius: r.max() ?? 0, smoothing: node.cornerSmoothing))
        }
    }

    /// Whether the layer looks here as `look` is: the same paint, type, shadow or corners.
    func shows(_ look: StyleLook, in node: Node) -> Bool {
        switch (self, look) {
        case (.fill(let i), .colour(let p)):
            guard i < node.slots(.fill) else { return true }
            let f = node[fill: i]
            if f.image != nil { return true }
            return ColourLook(f).same(as: p)
        case (.border(let i), .colour(let p)):
            guard i < node.slots(.border) else { return true }
            let b = node[border: i]
            if b.image != nil { return true }
            return ColourLook(Fill(color: b.color, gradient: b.gradient)).same(as: p)
        case (.shadow(let i), .shadow(let s)):
            guard i < node.slots(.shadow) else { return true }
            let mine = node[shadow: i]
            return mine.color == s.color && mine.x == s.x && mine.y == s.y && mine.blur == s.blur
                && (mine.inset == true) == (s.inset == true) && mine.grown == s.grown
        case (.text, .text(let t)):
            guard node.kind == .text else { return true }
            return node.style.map(TypeLook.init) == t
        case (.corners, .corners(let c)):
            guard node.kind == .rectangle else { return true }
            return node.corners == nil && node.cornerRadius == c.radius && (node.cornerSmoothing ?? 0) == (c.smoothing ?? 0)
        default:
            // A style of another kind is no style for this place.
            return true
        }
    }

    /// Gives the layer `look` here, keeping what is its own: whether a fill or shadow is on, where a
    /// gradient runs on it, where its words lie.
    func apply(_ look: StyleLook, to node: inout Node) {
        switch (self, look) {
        case (.fill(let i), .colour(let p)):
            guard i < node.slots(.fill) else { return }
            var f = node[fill: i]
            guard f.image == nil else { return }
            f.color = p.color
            f.gradient = Self.blend(p.gradient, over: f.gradient)
            node[fill: i] = f
        case (.border(let i), .colour(let p)):
            guard i < node.slots(.border) else { return }
            var b = node[border: i]
            guard b.image == nil else { return }
            b.color = p.color
            b.gradient = Self.blend(p.gradient, over: b.gradient)
            node[border: i] = b
        case (.shadow(let i), .shadow(let s)):
            guard i < node.slots(.shadow) else { return }
            var mine = node[shadow: i]
            mine.color = s.color
            mine.x = s.x
            mine.y = s.y
            mine.blur = s.blur
            mine.inset = s.inset == true ? true : nil
            mine.spread = s.spread
            node[shadow: i] = mine
        case (.text, .text(let t)):
            guard node.kind == .text else { return }
            var s = node.style ?? TextStyle()
            t.apply(to: &s)
            node.style = s
        case (.corners, .corners(let c)):
            guard node.kind == .rectangle else { return }
            node.radii = Array(repeating: c.radius, count: 4)
            node.cornerSmoothing = c.smoothing.flatMap { $0 > 0 ? $0 : nil }
        default:
            break
        }
    }

    /// A style's gradient as a layer has it: its colours, running where the layer's own ran when
    /// it had one of the same kind.
    private static func blend(_ g: Gradient?, over mine: Gradient?) -> Gradient? {
        guard let g else { return nil }
        guard var mine, mine.kind == g.kind else { return g }
        mine.stops = g.stops
        return mine
    }

    /// Whether a style of this look can be used here: not on a picture.
    func takes(_ look: StyleLook, in node: Node) -> Bool {
        guard look.kind == kind else { return false }
        switch self {
        case .fill(let i):
            return !(i < node.slots(.fill) && node[fill: i].image != nil)
        case .border(let i):
            return !(i < node.slots(.border) && node[border: i].image != nil)
        default: return true
        }
    }
}

// MARK: - Keeping every layer alike

nonisolated extension BezzleDocument {
    func style(_ id: UUID) -> Style? { styles?.first { $0.id == id } }

    /// The styles by their ids.
    var stylesByID: [UUID: Style] {
        Dictionary((styles ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Changes one style, if the design has it.
    mutating func changeStyle(_ id: UUID, _ change: (inout Style) -> Void) {
        guard var all = styles, let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        all[i].look = all[i].look.kept
        all[i].dark = all[i].dark?.kept
        styles = all
    }

    /// Adds a style at the end of those of its kind.
    mutating func addStyle(_ style: Style) {
        var s = style
        s.look = s.look.kept
        s.rank = ((styles ?? []).filter { $0.kind == s.kind }.map(\.rank).max() ?? -1) + 1
        styles = (styles ?? []) + [s]
    }

    mutating func removeStyle(_ id: UUID) {
        let left = (styles ?? []).filter { $0.id != id }
        styles = left.isEmpty ? nil : left
    }

    /// Keeps every layer that uses a style looking as it does, after a change from `before`. A
    /// style changed itself is carried to every layer that uses it. A layer whose named look was
    /// changed changes its style, and so every other layer using it, as a change to one cell of a
    /// repeat grid is a change to all of them. A layer newly given a name takes on its look; a style
    /// taken away leaves its layers looking as they do, named nothing. Returns the text layers
    /// whose type changed, to be fitted to their words again.
    mutating func keepStyles(since before: BezzleDocument) -> [UUID] {
        guard styles != nil || before.styles != nil else { return [] }
        let was = before.stylesByID
        var now = stylesByID
        var changed: Set<UUID> = []
        for (id, s) in now where was[id]?.look != s.look || was[id]?.dark != s.dark { changed.insert(id) }
        let gone = Set(was.keys).subtracting(now.keys)

        // What was changed through the layers that use them, in the light and in the dark, and
        // layers named anew. An artboard turned dark or light again shows every look anew.
        var through: [UUID: StyleLook] = [:], throughDark: [UUID: StyleLook] = [:]
        var named = false
        func visit(_ n: Node, _ old: Node?, dark: Bool) {
            if let old, old == n { return }
            let own = Set(n.own ?? [])
            for place in StylePlace.all(in: n) {
                guard let id = place.named(in: n) else { continue }
                // Taken away, or kept by a deck's post as its own: the name goes.
                if gone.contains(id) || place.fields.contains(where: own.contains) { named = true; continue }
                guard let style = now[id] else { continue }
                guard let old, place.named(in: old) == id else { named = true; continue }
                // Moved from a light artboard to a dark one, or back: it shows its other look.
                if before.isDark(old.id) != dark { named = true; continue }
                // Corners made to differ from each other are corners of its own.
                if place == .corners, n.corners != nil { named = true; continue }
                if changed.contains(id) || (dark ? throughDark[id] : through[id]) != nil { continue }
                let shown = style.look(dark: dark)
                guard !place.shows(shown, in: n), place.shows(shown, in: old),
                      let look = place.look(of: n), look.kind == style.kind else { continue }
                if dark { throughDark[id] = look.kept } else { through[id] = look.kept }
            }
            let oldKids = old?.children ?? []
            for (i, c) in n.children.enumerated() {
                visit(c, i < oldKids.count && oldKids[i].id == c.id ? oldKids[i] : before.node(c.id), dark: dark)
            }
        }
        var tops: [UUID: Node] = [:]
        for n in before.nodes { tops[n.id] = n }
        for n in before.components ?? [] { tops[n.id] = n }
        for n in nodes {
            let old = tops[n.id]
            if n.isArtboard, (old?.dark == true) != (n.dark == true) { named = true }
            visit(n, old, dark: n.showsDark)
        }
        // What every copy of a component is made from uses styles as the canvas does, in the light.
        for n in components ?? [] { visit(n, tops[n.id], dark: false) }

        if !through.isEmpty || !throughDark.isEmpty, var all = styles {
            for i in all.indices {
                let id = all[i].id
                // Changed in the light, a style that follows it in the dark goes on following it.
                if let look = through[id] { all[i].look = look }
                if let look = throughDark[id] { all[i].dark = look }
                if through[id] != nil || throughDark[id] != nil {
                    now[id] = all[i]
                    changed.insert(id)
                }
            }
            styles = all
        }
        guard !changed.isEmpty || !gone.isEmpty || named else { return [] }
        var list = nodes
        var retyped: [UUID] = []
        if Self.keepAlike(&list, styles: now, gone: gone, retyped: &retyped) { nodes = list }
        if var masters = components, Self.keepAlike(&masters, styles: now, gone: gone, retyped: &retyped, dark: false) { components = masters }
        return retyped
    }

    /// Gives every layer that uses a style its look, as after others' changes were merged in, when
    /// two people may have changed a style and the layers that use it apart.
    mutating func repairStyles() {
        guard let styles, !styles.isEmpty else { return }
        var list = nodes
        var retyped: [UUID] = []
        if Self.keepAlike(&list, styles: stylesByID, gone: [], retyped: &retyped) { nodes = list }
        if var masters = components, Self.keepAlike(&masters, styles: stylesByID, gone: [], retyped: &retyped, dark: false) { components = masters }
    }

    /// Every layer named after a style looking as it does; names of styles in `gone` taken away,
    /// and of those a deck's post keeps of its own. Returns whether any layer changed.
    private static func keepAlike(_ list: inout [Node], styles: [UUID: Style], gone: Set<UUID>, retyped: inout [UUID],
                                  dark inherited: Bool? = nil) -> Bool {
        var changed = false
        for i in list.indices {
            var n = list[i]
            // What lies on a dark artboard is dark, all the way down.
            let dark = inherited ?? n.showsDark
            let own = Set(n.own ?? [])
            for place in StylePlace.all(in: n) {
                guard let id = place.named(in: n) else { continue }
                if gone.contains(id) || place.fields.contains(where: own.contains) || (place == .corners && n.corners != nil) {
                    place.name(nil, in: &n)
                } else if let style = styles[id] {
                    let shown = style.look(dark: dark)
                    // A style of another kind, or a colour that cannot go here, is no name for it.
                    if !place.takes(shown, in: n) {
                        place.name(nil, in: &n)
                    } else if !place.shows(shown, in: n) {
                        place.apply(shown, to: &n)
                        if place == .text { retyped.append(n.id) }
                    }
                }
            }
            if !n.children.isEmpty { _ = keepAlike(&n.children, styles: styles, gone: gone, retyped: &retyped, dark: dark) }
            if n != list[i] {
                list[i] = n
                changed = true
            }
        }
        return changed
    }

    /// Every layer that uses the style, and where.
    func uses(of id: UUID) -> [(layer: UUID, place: StylePlace)] {
        var out: [(UUID, StylePlace)] = []
        func visit(_ n: Node) {
            for place in StylePlace.all(in: n) where place.named(in: n) == id { out.append((n.id, place)) }
            n.children.forEach(visit)
        }
        nodes.forEach(visit)
        return out
    }

    /// How many layers use each style.
    var styleUses: [UUID: Int] {
        guard let styles, !styles.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        func visit(_ n: Node) {
            var seen = Set<UUID>()
            for place in StylePlace.all(in: n) { if let id = place.named(in: n), seen.insert(id).inserted { counts[id, default: 0] += 1 } }
            n.children.forEach(visit)
        }
        nodes.forEach(visit)
        return counts
    }

    /// The styles whose looks differ between two versions of the design, or that only one has.
    static func stylesChanged(from a: BezzleDocument, to b: BezzleDocument) -> Set<UUID> {
        guard a.styles != b.styles else { return [] }
        let x = a.stylesByID, y = b.stylesByID
        var changed: Set<UUID> = []
        for (id, s) in y where x[id]?.look != s.look || x[id]?.dark != s.dark { changed.insert(id) }
        for id in x.keys where y[id] == nil { changed.insert(id) }
        return changed
    }

    /// Whether a layer is shown dark: it lies on, or is, an artboard shown dark.
    func isDark(_ id: UUID) -> Bool {
        guard let p = path(of: id) else { return false }
        return nodes[p.top].showsDark
    }
}

nonisolated extension Node {
    /// An artboard shown dark, and so everything on it.
    var showsDark: Bool { isArtboard && dark == true }

    /// This layer, and all it holds, with the looks `other` has, the same layer as it was, at every
    /// place both name after the same style: as a copy of a component on a dark artboard keeps the
    /// dark looks of its styles, whatever its component's layers have.
    func keepingNamedLooks(of other: Node, deep: Bool = true) -> Node {
        var n = self
        for place in StylePlace.all(in: n) {
            guard let id = place.named(in: n), place.named(in: other) == id, let look = place.look(of: other) else { continue }
            if !place.shows(look, in: n) { place.apply(look, to: &n) }
        }
        if deep, !n.children.isEmpty, !other.children.isEmpty {
            var theirs: [UUID: Node] = [:]
            for c in other.children { theirs[c.id] = c }
            n.children = n.children.map { c in theirs[c.id].map { c.keepingNamedLooks(of: $0) } ?? c }
        }
        return n
    }
}

extension BezzleDocument {
    /// Keeps every layer that uses a style looking as it does (`keepStyles`), text fitted to its
    /// words again where its type changed.
    mutating func syncStyles(since before: BezzleDocument) {
        for id in keepStyles(since: before) {
            if path(of: id) != nil {
                update(id) { $0.refit() }
            } else if var masters = components {
                Self.refit(id, in: &masters)
                components = masters
            }
        }
    }

    private static func refit(_ id: UUID, in list: inout [Node]) {
        for i in list.indices {
            if list[i].id == id { list[i].refit(); return }
            refit(id, in: &list[i].children)
        }
    }
}

// MARK: - Looks the design uses again and again

/// A look several layers of a design have alike without a name, which naming makes a style of
/// those layers at once.
nonisolated struct FoundLook: Identifiable, Hashable {
    var look: StyleLook
    /// The layers that have it, and where.
    var uses: [Use]

    struct Use: Hashable {
        var layer: UUID
        var place: StylePlace
    }

    var id: Int { look.hashValue }
    var count: Int { Set(uses.map(\.layer)).count }
}

nonisolated extension BezzleDocument {
    /// The looks layers have alike, without a name, the most used first: of each kind, those at
    /// least `least` layers have.
    func foundLooks(least: Int = 2) -> [StyleKind: [FoundLook]] {
        var groups: [StyleKind: [StyleLook: [FoundLook.Use]]] = [:]
        var order: [StyleKind: [StyleLook]] = [:]
        let known = Set((styles ?? []).map(\.id))
        func note(_ look: StyleLook, _ use: FoundLook.Use) {
            let kind = look.kind
            if groups[kind]?[look] == nil { order[kind, default: []].append(look) }
            groups[kind, default: [:]][look, default: []].append(use)
        }
        func visit(_ n: Node) {
            defer { n.children.forEach(visit) }
            for place in StylePlace.all(in: n) {
                if let id = place.named(in: n), known.contains(id) { continue }
                guard var look = place.look(of: n) else { continue }
                switch place {
                case .fill(let i):
                    let f = n[fill: i]
                    guard f.on, f.color.a > 0 else { continue }
                    // Where a gradient runs is each layer's own.
                    if var p = look.paint, var g = p.gradient {
                        g.start = .zero; g.end = CGPoint(x: 0, y: 1); g.radius = 0.5; g.across = nil
                        p.gradient = g
                        look = .colour(p)
                    }
                case .border(let i):
                    guard n[border: i].on else { continue }
                case .shadow(let i):
                    guard n[shadow: i].on else { continue }
                case .corners:
                    guard n.corners == nil, n.cornerRadius > 0 else { continue }
                case .text:
                    break
                }
                note(look, FoundLook.Use(layer: n.id, place: place))
            }
        }
        nodes.forEach(visit)
        var out: [StyleKind: [FoundLook]] = [:]
        for (kind, looks) in order {
            let found = looks.compactMap { look -> FoundLook? in
                let f = FoundLook(look: look, uses: groups[kind]?[look] ?? [])
                return f.count >= least ? f : nil
            }
            out[kind] = found.enumerated().sorted { a, b in a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset }.map(\.element)
        }
        return out
    }

    /// The layers without a name that look as `look` does at a place of its kind, but for `besides`.
    func looksAlike(_ look: StyleLook, besides: Set<UUID>) -> [FoundLook.Use] {
        var out: [FoundLook.Use] = []
        let known = Set((styles ?? []).map(\.id))
        func visit(_ n: Node) {
            defer { n.children.forEach(visit) }
            guard !besides.contains(n.id) else { return }
            for place in StylePlace.all(in: n) where place.kind == look.kind {
                if let id = place.named(in: n), known.contains(id) { continue }
                guard place.takes(look, in: n), place.look(of: n) != nil, place.shows(look, in: n) else { continue }
                switch place {
                case .fill(let i): guard n[fill: i].on else { continue }
                case .border(let i): guard n[border: i].on else { continue }
                case .shadow(let i): guard n[shadow: i].on else { continue }
                default: break
                }
                out.append(FoundLook.Use(layer: n.id, place: place))
            }
        }
        nodes.forEach(visit)
        return out
    }
}

// MARK: - Shared

nonisolated extension Style {
    /// Its properties as a shared design keeps them, each changed on its own (see `SharedDesign`):
    /// two people, one renaming a style and the other changing its colour, both keep their change.
    static let nameField = "style.name", lookField = "style.look", rankField = "style.rank", goneField = "style.gone"
    static let darkField = "style.dark", libraryField = "style.library"

    func fields() -> [String: FieldValue] {
        var out: [String: FieldValue] = [
            Self.nameField: .string(name),
            Self.rankField: .number(rank),
            Self.goneField: .bool(false),
        ]
        if let look = try? FieldValue(encoding: look) { out[Self.lookField] = look }
        out[Self.darkField] = dark.flatMap { try? FieldValue(encoding: $0) } ?? .null
        out[Self.libraryField] = library.flatMap { try? FieldValue(encoding: $0) } ?? .null
        return out
    }

    /// The style a shared design keeps under `id`, unless it was taken away and nothing about it
    /// changed since; nil too for what is no style.
    static func read(_ id: UUID, from layer: SharedLayer) -> Style? {
        guard layer.place == nil, let lookValue = layer.fields[lookField]?.value,
              let look = try? lookValue.decoded(as: StyleLook.self) else { return nil }
        if let gone = layer.fields[goneField], gone.value == .bool(true),
           !layer.fields.contains(where: { $0.key != goneField && $0.value.stamp > gone.stamp }) {
            return nil
        }
        var style = Style(id: id, name: "", look: look)
        if case .string(let name)? = layer.fields[nameField]?.value { style.name = name }
        if case .number(let rank)? = layer.fields[rankField]?.value { style.rank = rank }
        if let d = layer.fields[darkField]?.value, d != .null { style.dark = try? d.decoded(as: StyleLook.self) }
        if let l = layer.fields[libraryField]?.value, l != .null { style.library = try? l.decoded(as: LibraryLink.self) }
        return style
    }
}

// MARK: - Carried to another design

nonisolated extension Node {
    /// The styles this layer and everything in it are named after.
    var stylesUsed: Set<UUID> {
        var ids = Set<UUID>()
        func visit(_ n: Node) {
            for place in StylePlace.all(in: n) { if let id = place.named(in: n) { ids.insert(id) } }
            n.children.forEach(visit)
        }
        visit(self)
        return ids
    }

    /// The same layer, and all it holds, named after other styles: by `map`, old id to new.
    func renamingStyles(_ map: [UUID: UUID]) -> Node {
        guard !map.isEmpty else { return self }
        var n = self
        for place in StylePlace.all(in: n) {
            if let id = place.named(in: n), let to = map[id] { place.name(to, in: &n) }
        }
        n.children = n.children.map { $0.renamingStyles(map) }
        return n
    }
}

nonisolated extension BezzleDocument {
    /// Takes in the styles layers brought from another design use: one this design has already
    /// stays as it is here, and the layers take its look; one of the same kind and name stands in
    /// for it; any other comes along. Returns how the layers' names are to change.
    mutating func takeIn(_ brought: [Style]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for s in brought {
            if style(s.id) != nil { continue }
            if let same = (styles ?? []).first(where: { $0.kind == s.kind && $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
                map[s.id] = same.id
            } else {
                addStyle(s)
            }
        }
        return map
    }
}

// MARK: - In the dark

nonisolated extension StyleLook {
    /// The same look made for the dark by itself, until one is made there by hand: pale grounds
    /// go deep, keeping which lies over which (a card stays lighter than its page); dark inks go
    /// pale; colours in between brighten a little, to read on the dark. Shadows deepen. Type and
    /// corners stay as they are.
    var darkened: StyleLook {
        switch self {
        case .colour(var p):
            p.color = p.color.darkened
            if var g = p.gradient {
                g.stops = g.stops.map { GradientStop(offset: $0.offset, color: $0.color.darkened) }
                p.gradient = g
            }
            return .colour(p)
        case .shadow(var s):
            s.color = RGBA(r: 0, g: 0, b: 0, a: min(0.75, s.color.a * 2.4 + 0.08))
            return .shadow(s)
        case .text, .corners:
            return self
        }
    }
}

nonisolated extension RGBA {
    /// This colour as it is made for the dark (`StyleLook.darkened`), measured by how light it
    /// looks rather than by its numbers: in OKLab, whose lightness runs as the eye sees it.
    var darkened: RGBA {
        let (l, a, b) = oklab
        let chroma = hypot(a, b)
        var l2: Double, k: Double
        if l >= 0.85 {
            // A ground: deep, in the same order as before.
            l2 = 0.2 + (l - 0.85) / 0.15 * 0.1
            k = 0.5
        } else if l <= 0.5 {
            // An ink: pale, the darker the paler.
            l2 = 0.96 - l * 0.5
            k = 0.85
        } else {
            l2 = min(max(l + 0.06, 0.55), 0.86)
            k = 0.95
        }
        // Very colourful pale grounds would glow in the dark; keep a hint of their hue.
        let c2 = min(chroma * k, l >= 0.85 ? 0.035 : 0.4)
        let scale = chroma > 0 ? c2 / chroma : 0
        return RGBA(oklab: (l2, a * scale, b * scale), alpha: self.a)
    }

    /// Lightness and the two opponent axes of OKLab.
    var oklab: (l: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(min(max(self.r, 0), 1)), g = lin(min(max(self.g, 0), 1)), bl = lin(min(max(self.b, 0), 1))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    init(oklab c: (l: Double, a: Double, b: Double), alpha: Double = 1) {
        let l_ = c.l + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m_ = c.l - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s_ = c.l - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        func gamma(_ x: Double) -> Double {
            let v = min(max(x, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        // To the thousandth, so the same colour made on two Macs is the same colour.
        func round(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        self.init(r: round(gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
                  g: round(gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
                  b: round(gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)), a: alpha)
    }
}

nonisolated extension BezzleDocument {
    /// A name for a look not named yet, `base` as it is or numbered on, that no other style of its
    /// kind has.
    func freshName(_ base: String, kind: StyleKind) -> String {
        let taken = Set((styles ?? []).filter { $0.kind == kind }.map(\.name))
        guard taken.contains(base) else { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Shows an artboard dark, or light again. Turned dark, every colour on it without a name is
    /// given one first (`name`, from its look), with every layer of the design that has it and is
    /// not dark already: so all of it can be dark, each colour by itself, and each still the same
    /// on every light artboard. Words keep their colour in the dark where that reads better on
    /// what they lie on there, as white on a blue button does; a colour of words that keeps is a
    /// style apart from the same colour turning dark. Returns the styles it made.
    @discardableResult
    mutating func show(_ board: UUID, dark: Bool, name: (StyleLook) -> String) -> [UUID] {
        guard let p = path(of: board), p.indices.count == 1, self[p].isArtboard else { return [] }
        var made: [UUID] = []
        if dark {
            struct Key: Hashable { var look: StyleLook; var keeps: Bool }
            let named = stylesByID
            /// The colours of a design's layers without a name, how each would be in the dark, and where.
            func unnamed(in root: Node) -> [(Key, FoundLook.Use)] {
                var out: [(Key, FoundLook.Use)] = []
                func visit(_ n: Node) {
                    for place in StylePlace.all(in: n) where place.kind == .colour {
                        if let id = place.named(in: n), named[id] != nil { continue }
                        guard var look = place.look(of: n) else { continue }
                        switch place {
                        case .fill(let i): guard n[fill: i].on else { continue }
                        case .border(let i): guard n[border: i].on else { continue }
                        default: break
                        }
                        if var c = look.paint, var g = c.gradient {
                            g.start = .zero; g.end = CGPoint(x: 0, y: 1); g.radius = 0.5; g.across = nil
                            c.gradient = g
                            look = .colour(c)
                        }
                        let keeps = n.kind == .text && place == .fill(0) && keepsInTheDark(n.id, look)
                        out.append((Key(look: look, keeps: keeps), FoundLook.Use(layer: n.id, place: place)))
                    }
                    n.children.forEach(visit)
                }
                visit(root)
                return out
            }
            var order: [Key] = []
            var uses: [Key: [FoundLook.Use]] = [:]
            for (key, use) in unnamed(in: self[p]) {
                if uses[key] == nil { order.append(key) }
                uses[key, default: []].append(use)
            }
            // The same colour, in the same part, wherever it is light, takes the name too; on
            // another dark artboard it is that artboard's own, and stays so.
            for top in nodes where top.id != board && !top.showsDark {
                for (key, use) in unnamed(in: top) where uses[key] != nil { uses[key]?.append(use) }
            }
            for key in order {
                var style = Style(name: freshName(name(key.look), kind: .colour), look: key.look.kept)
                if key.keeps { style.dark = key.look.kept }
                addStyle(style)
                made.append(style.id)
                for use in uses[key] ?? [] { update(use.layer) { use.place.name(style.id, in: &$0) } }
            }
        }
        update(board) { $0.dark = dark }
        return made
    }

    /// Whether words in a colour read better in the dark kept as they are than made dark, on what
    /// they lie on as that is in the dark: white words on a blue button stay white, black words on a
    /// white page turn pale.
    func keepsInTheDark(_ id: UUID, _ look: StyleLook) -> Bool {
        guard let mine = look.paint?.color else { return false }
        let ground = colourBehind(id)
        let groundDark = ground.named.flatMap { style($0)?.look(dark: true).paint?.color } ?? ground.color.darkened
        let l = groundDark.oklab.l
        return abs(mine.oklab.l - l) > abs(mine.darkened.oklab.l - l)
    }

    /// The colour a layer lies on, on its artboard: of the topmost layer drawn before it whose box
    /// holds its middle, filled with one colour; else the artboard's own. With the style it is named
    /// after, if any.
    func colourBehind(_ id: UUID) -> (color: RGBA, named: UUID?) {
        guard let p = path(of: id), nodes[p.top].isArtboard, let frame = absoluteFrame(of: id) else { return (.white, nil) }
        let board = nodes[p.top]
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        var found: (RGBA, UUID?) = (board.fill.color, board.fill.named)
        var reached = false
        func visit(_ n: Node, origin: CGPoint) {
            guard !reached else { return }
            if n.id == id { reached = true; return }
            if n.isGroup {
                let inner = CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY)
                for c in n.children { visit(c, origin: inner) }
                return
            }
            guard !n.hidden, [.rectangle, .ellipse, .path].contains(n.kind),
                  n.frame.offsetBy(dx: origin.x, dy: origin.y).contains(middle) else { return }
            if let f = n.fills.last(where: { $0.image == nil && $0.gradient == nil && $0.color.a > 0.5 }) {
                found = (f.color, f.named)
            }
        }
        for c in board.children { visit(c, origin: board.frame.origin) }
        return found
    }
}
