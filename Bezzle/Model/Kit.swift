import Foundation
import CoreGraphics

/// A library of ready-made parts of an interface, such as the controls and bars of iOS, laid out
/// in sections. Dropped into a design, a part becomes ordinary layers, grouped and named, which
/// are the design's own from then on.
nonisolated struct Kit: Identifiable, Sendable {
    /// Stable and English, for the AI: "bezzle", "ios", "macos", "android".
    let id: String
    let title: LocalizedStringResource
    /// What its parts are seen on, light and dark: the screen of the platform.
    let paper: RGBA
    let darkPaper: RGBA
    let sections: [KitSection]

    var components: [Component] { sections.flatMap(\.components) }
}

nonisolated struct KitSection: Identifiable, Sendable {
    let title: LocalizedStringResource
    let components: [Component]
    var id: String { components.first?.id ?? "\(title.key)" }
}

/// What a part is made for: how wide, and whether light or dark.
nonisolated struct KitLook: Hashable, Sendable {
    var width: CGFloat
    var dark = false
}

/// One part of a kit: what it is called, how big it is made, how it lands on an artboard, and
/// the layers it is made of.
nonisolated struct Component: Identifiable, Sendable {
    /// How a part lands on the artboard it is dropped onto.
    enum Fit: Hashable, Sendable {
        /// Where it is let go, as it was made.
        case free
        /// Across the artboard, as wide as it less `margin` on either side, where it is let go
        /// up and down: a list or a field on a phone's screen.
        case across(margin: CGFloat)
        /// Along the artboard's top or bottom edge, as wide as it, under or over what lies along
        /// that edge already: a status bar, then a navigation bar under it.
        case top, bottom
    }

    /// Stable and English, the kit's id first: "ios.tab-bar".
    let id: String
    let title: LocalizedStringResource
    /// As it is made when nothing else asks: its width is the one `make` is given.
    let size: CGSize
    var fit: Fit = .free
    /// The narrowest it can be made, for the parts that fit an artboard's width.
    var minWidth: CGFloat? = nil
    /// The layers, in one group whose top left is at 0, 0.
    let make: @Sendable (KitLook) -> Node

    var stretches: Bool { fit != .free }

    /// Made for a look, named after the part.
    func node(_ look: KitLook) -> Node {
        var n = make(look)
        n.name = String(localized: title)
        return n
    }

    func node(width: CGFloat? = nil, dark: Bool = false) -> Node {
        node(KitLook(width: stretches ? max(width ?? size.width, minWidth ?? 1) : size.width, dark: dark))
    }
}

nonisolated enum Kits {
    static let all: [Kit] = [BezzleKit.kit, IOSKit.kit, MacKit.kit, AndroidKit.kit]

    static func kit(_ id: String) -> Kit? { all.first { $0.id == id } }

    static func component(_ id: String) -> Component? {
        for kit in all { if let c = kit.components.first(where: { $0.id == id }) { return c } }
        return nil
    }

    /// The parts whose names, or whose kit's name, fit everything typed.
    static func search(_ query: String) -> [(kit: Kit, component: Component)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var found: [(Kit, Component)] = []
        for kit in all {
            let kitWords = "\(kit.id) \(String(localized: kit.title))".lowercased()
            for section in kit.sections {
                let sectionWords = String(localized: section.title).lowercased()
                for c in section.components {
                    let own = "\(String(localized: c.title)) \(c.id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ".", with: " "))".lowercased()
                    let all = "\(own) \(sectionWords) \(kitWords)"
                    if words.allSatisfy({ all.contains($0) }) { found.append((kit, c)) }
                }
            }
        }
        return found
    }

    /// Whether an artboard's own colour is dark, so that parts dropped onto it come dark too.
    static func isDark(_ board: Node?) -> Bool {
        guard let board, board.fill.on, board.fill.image == nil else { return false }
        let c = board.fill.gradient?.stops.first?.color ?? board.fill.color
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.42
    }
}

// MARK: - Making parts

/// The few things every kit's parts are made of, measured in the part's own points, its top
/// left at 0, 0. Text is measured as it is drawn, so it can be centred where it belongs.
nonisolated enum Parts {
    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A rectangle, its corners rounded; `smooth` rounds them as iOS does, running into the sides.
    static func rect(_ name: String, _ r: CGRect, _ color: RGBA, radius: CGFloat = 0, smooth: Bool = false) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: r)
        n.fill = Fill(color: color)
        n.cornerRadius = min(radius, min(r.width, r.height) / 2)
        if smooth && radius > 0 { n.cornerSmoothing = 0.6 }
        return n
    }

    /// A rectangle that draws nothing, giving a part the size it is placed by: the whole width
    /// of a bar that floats inside it, or the room around a control.
    static func frame(_ w: CGFloat, _ h: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> Node {
        var n = Node(kind: .rectangle, name: "Frame", frame: CGRect(x: x, y: y, width: w, height: h))
        n.fill.on = false
        return n
    }

    /// A rectangle whose corners differ: top left, top right, bottom right, bottom left.
    static func rect(_ name: String, _ r: CGRect, _ color: RGBA, corners: [CGFloat]) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: r)
        n.fill = Fill(color: color)
        n.radii = corners
        return n
    }

    /// A rounded box as round as it can be: a pill, or a circle when square.
    static func pill(_ name: String, _ r: CGRect, _ color: RGBA) -> Node {
        rect(name, r, color, radius: min(r.width, r.height) / 2)
    }

    static func oval(_ name: String, _ r: CGRect, _ color: RGBA) -> Node {
        var n = Node(kind: .ellipse, name: name, frame: r)
        n.fill = Fill(color: color)
        return n
    }

    static func circle(_ name: String, center c: CGPoint, radius: CGFloat, _ color: RGBA) -> Node {
        oval(name, CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2), color)
    }

    /// A line from one point to another, round at its ends.
    static func line(_ name: String, from a: CGPoint, to b: CGPoint, _ color: RGBA, width: CGFloat = 1) -> Node {
        var n = Node(kind: .line, name: name, frame: .zero)
        n.setLineEnds(a, b)
        n.border = Border(on: true, color: color, width: width, position: .center)
        return n
    }

    /// A hairline across, a point or less tall, as a filled rectangle so it stays crisp.
    static func rule(_ name: String = "Separator", x: CGFloat, y: CGFloat, width: CGFloat, _ color: RGBA, thickness: CGFloat = 0.5) -> Node {
        rect(name, CGRect(x: x, y: y, width: width, height: thickness), color)
    }

    /// An outline of SVG path data, `box` of it filling `r`.
    static func shape(_ name: String, _ data: String, box: CGRect? = nil, in r: CGRect, _ color: RGBA, evenOdd: Bool = false) -> Node {
        var n = Node(kind: .path, name: name, frame: r)
        n.path = data
        n.pathBox = box ?? PathData.bounds(data)
        n.fill = Fill(color: color)
        if evenOdd { n.evenOdd = true }
        return n
    }

    // MARK: Words

    /// Words on one line, as wide as they are. `x` is where the line starts, or its middle when
    /// centred, or its end when set right; `y` is its top.
    static func text(_ s: String, name: String? = nil, x: CGFloat, y: CGFloat, size: CGFloat, weight: String = "Regular",
                     color: RGBA, family: String = TextStyle.system, align: TextAlign = .left, tracking: CGFloat = 0,
                     line: CGFloat? = nil) -> Node {
        var n = Node(kind: .text, name: name ?? String(s.prefix(40)), frame: CGRect(x: x, y: y, width: 0, height: 0))
        n.text = s
        n.fill = Fill(color: color)
        var style = TextStyle()
        style.family = family
        style.face = weight
        style.size = size
        style.align = align
        style.tracking = tracking
        style.lineSpacing = line
        style.sizing = .autoWidth
        n.style = style
        let fitted = TextLayout.fittedFrame(n)
        switch align {
        case .center: n.frame = CGRect(x: x - fitted.width / 2, y: y, width: fitted.width, height: fitted.height)
        case .right: n.frame = CGRect(x: x - fitted.width, y: y, width: fitted.width, height: fitted.height)
        default: n.frame = fitted
        }
        return n
    }

    /// Words on one line in the middle of `r` from top to bottom, and at its left, middle or
    /// right as they are set.
    static func text(_ s: String, name: String? = nil, in r: CGRect, size: CGFloat, weight: String = "Regular", color: RGBA,
                     family: String = TextStyle.system, align: TextAlign = .left, tracking: CGFloat = 0) -> Node {
        let x = align == .center ? r.midX : align == .right ? r.maxX : r.minX
        var n = text(s, name: name, x: x, y: 0, size: size, weight: weight, color: color, family: family, align: align, tracking: tracking)
        n.frame.origin.y = (r.midY - n.frame.height / 2).rounded(.toNearestOrEven)
        return n
    }

    /// Words wrapped to a width, growing downward.
    static func paragraph(_ s: String, name: String? = nil, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                          weight: String = "Regular", color: RGBA, family: String = TextStyle.system, align: TextAlign = .left,
                          line: CGFloat? = nil, tracking: CGFloat = 0) -> Node {
        var n = text(s, name: name, x: x, y: y, size: size, weight: weight, color: color, family: family, align: .left, tracking: tracking, line: line)
        n.style?.align = align
        n.style?.sizing = .autoHeight
        n.frame = CGRect(x: x, y: y, width: width, height: 0)
        n.frame = TextLayout.fittedFrame(n)
        return n
    }

    /// How wide words would be, set this way.
    static func width(of s: String, size: CGFloat, weight: String = "Regular", family: String = TextStyle.system, tracking: CGFloat = 0) -> CGFloat {
        text(s, x: 0, y: 0, size: size, weight: weight, color: .black, family: family, tracking: tracking).frame.width
    }

    // MARK: Icons

    /// An icon from one of the sets, its square at `r`. A name the set does not have draws
    /// nothing, which the kits' test looks out for.
    static func icon(_ name: String, _ set: IconSetID = .lucide, _ r: CGRect, _ color: RGBA, style: Int? = nil, weight: CGFloat? = nil) -> Node {
        guard let icon = Icons.icon(name, in: set) else {
            missing.with { $0.insert("\(set.rawValue)/\(name)") }
            var n = rect(name, r, color)
            n.fill.on = false
            return n
        }
        var s = Icons.set(set).defaultStyle
        if let style { s.index = style }
        if let weight { s.weight = weight }
        return Icons.node(icon, style: s, frame: r, color: color)
    }

    static func icon(_ name: String, _ set: IconSetID = .lucide, center c: CGPoint, size: CGFloat, _ color: RGBA,
                     style: Int? = nil, weight: CGFloat? = nil) -> Node {
        icon(name, set, CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size), color, style: style, weight: weight)
    }

    /// Icons asked for by name that no set has; for the kits' test.
    static let missing = Shared(Set<String>())

    // MARK: Groups

    /// The layers as one group, its frame the box around them, they placed in it as they were
    /// placed in the part.
    static func group(_ name: String, _ children: [Node]) -> Node {
        var g = Node(kind: .group, name: name, frame: .zero)
        let kept = children.filter { !($0.isGroup && $0.children.isEmpty) }
        guard let box = kept.map({ Geometry.bounds(of: $0) }).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) else { return g }
        g.frame = box
        g.children = kept.map { var c = $0; c.frame = c.frame.offsetBy(dx: -box.minX, dy: -box.minY); return c }
        return g
    }

    /// The layers as the whole part: a group whose top left is at 0, 0 however they lie, as the
    /// part is placed by it. The first layer is usually its background.
    static func part(_ children: [Node]) -> Node {
        var g = group("Part", children)
        // Whatever reaches above or left of 0, 0 stays where it is in the part.
        g.frame.origin = CGPoint(x: min(g.frame.minX, 0), y: min(g.frame.minY, 0))
        return g
    }

    // MARK: Looks

    static func shadow(x: CGFloat = 0, y: CGFloat, blur: CGFloat, _ color: RGBA, spread: CGFloat? = nil) -> Shadow {
        Shadow(on: true, color: color, x: x, y: y, blur: blur, inset: nil, spread: spread)
    }

    static func border(_ color: RGBA, width: CGFloat = 1, position: Border.Position = .inside) -> Border {
        Border(on: true, color: color, width: width, position: position)
    }
}

nonisolated extension Node {
    /// The same layer with a border.
    func outlined(_ color: RGBA, width: CGFloat = 1, position: Border.Position = .inside) -> Node {
        var n = self
        n.border = Parts.border(color, width: width, position: position)
        return n
    }

    /// The same layer casting shadows, the first first.
    func casting(_ shadows: Shadow...) -> Node {
        var n = self
        n.shadows = shadows
        return n
    }

    /// The same layer, frosted: what lies behind it blurred by `radius`, and its own fill over
    /// that at `tint` of its strength.
    func frosted(_ radius: CGFloat, tint: Double = 0.7, brightness: Double = 0) -> Node {
        var n = self
        n.blur = Blur(on: true, radius: radius, background: true, brightness: brightness, fillOpacity: tint)
        return n
    }

    func faded(_ opacity: Double) -> Node {
        var n = self
        n.opacity = opacity
        return n
    }

    func named(_ name: String) -> Node {
        var n = self
        n.name = name
        return n
    }

    /// The same layer moved by `dx`, `dy`.
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> Node {
        var n = self
        n.frame = n.frame.offsetBy(dx: dx, dy: dy)
        return n
    }
}

nonisolated extension RGBA {
    /// "#RRGGBB" or "#RRGGBBAA", for the kits' palettes; a string that is not one is magenta, so it shows.
    static func hex(_ s: String) -> RGBA {
        var t = s.hasPrefix("#") ? String(s.dropFirst()) : s
        var alpha = 1.0
        if t.count == 8, let a = UInt32(t.suffix(2), radix: 16) {
            alpha = Double(a) / 255
            t = String(t.prefix(6))
        }
        return RGBA(hex: t, alpha: alpha) ?? RGBA(r: 1, g: 0, b: 1)
    }
}
