import Foundation
import CoreGraphics
import AppKit

/// A colour as it is stored: sRGB components and alpha, each 0…1.
nonisolated struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let shape = RGBA(r: 0.82, g: 0.81, b: 0.79)
    static let line = RGBA(r: 0.44, g: 0.43, b: 0.41)
    static let shadow = RGBA(r: 0, g: 0, b: 0, a: 0.16)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    /// "#RRGGBB" or "RRGGBB" (also three digits); alpha stays as it is.
    init?(hex: String, alpha: Double = 1) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: alpha)
    }

    var hex: String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func with(alpha: Double) -> RGBA { var c = self; c.a = alpha; return c }

    /// The same colour as hue, saturation and brightness, each 0…1.
    var hsb: (h: Double, s: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
        var h = 0.0
        if d > 0 {
            if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if maxV == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, maxV == 0 ? 0 : d / maxV, maxV)
    }

    init(h: Double, s: Double, b: Double, a: Double = 1) {
        let i = floor(h * 6), f = h * 6 - i
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: self.init(r: b, g: t, b: p, a: a)
        case 1: self.init(r: q, g: b, b: p, a: a)
        case 2: self.init(r: p, g: b, b: t, a: a)
        case 3: self.init(r: p, g: q, b: b, a: a)
        case 4: self.init(r: t, g: p, b: b, a: a)
        default: self.init(r: b, g: p, b: q, a: a)
        }
    }
}

nonisolated struct Fill: Codable, Hashable {
    var on = true
    var color: RGBA
    /// Drawn instead of the colour when there is one.
    var gradient: Gradient?
    /// Drawn instead of the colour or a gradient when there is one.
    var image: ImageFill?
    /// The design's named colour it is, the same wherever that is used; nil is a colour of its
    /// own. See `Style`.
    var named: UUID? = nil

    /// Whether it paints with more than its one colour: a gradient, or a picture.
    var paints: Bool { image != nil || gradient?.stops.isEmpty == false }

    /// The same fill turned over with its layer, left to right or top to bottom.
    func flipped(horizontally: Bool) -> Fill {
        var f = self
        f.gradient = gradient?.flipped(horizontally: horizontally)
        f.image = image?.flipped(horizontally: horizontally)
        return f
    }
}

nonisolated struct GradientStop: Codable, Hashable {
    /// 0 at the start, 1 at the end.
    var offset: Double
    var color: RGBA
}

/// Colours blending across a layer, placed in its frame: 0,0 is the top left and 1,1 the bottom
/// right, so the gradient stretches with the layer.
nonisolated struct Gradient: Codable, Hashable {
    enum Kind: String, Codable { case linear, radial }

    var kind: Kind
    var stops: [GradientStop]
    /// Linear: where the first colour is. Radial: the centre.
    var start: CGPoint
    /// Linear: where the last colour is. Radial: where its first radius ends, once it has `across`.
    var end: CGPoint
    /// Radial only, in the same units, so on a wide layer the circle is a wide ellipse.
    var radius: CGFloat = 0.5
    /// Radial only: where its second radius ends, when it has been turned or stretched; it then
    /// spreads to the ellipse through `end` and this, and `radius` is not used.
    var across: CGPoint? = nil

    /// Where a radial gradient's two radii end, from its centre: as they have been set, or the
    /// circle of `radius` across the layer's box.
    var radii: (CGPoint, CGPoint) {
        if let across { return (end, across) }
        return (CGPoint(x: start.x + radius, y: start.y), CGPoint(x: start.x, y: start.y + radius))
    }

    /// A radial gradient's spread on a layer of `size`: the unit circle, carried onto the layer's
    /// own space as the ellipse its radii make.
    func spread(in size: CGSize) -> CGAffineTransform {
        let (a, b) = radii
        return CGAffineTransform(a: (a.x - start.x) * size.width, b: (a.y - start.y) * size.height,
                                 c: (b.x - start.x) * size.width, d: (b.y - start.y) * size.height,
                                 tx: start.x * size.width, ty: start.y * size.height)
    }

    /// The same colours running the other way across the layer, or the other way down it.
    func flipped(horizontally: Bool) -> Gradient {
        func turn(_ p: CGPoint) -> CGPoint { horizontally ? CGPoint(x: 1 - p.x, y: p.y) : CGPoint(x: p.x, y: 1 - p.y) }
        var g = self
        g.start = turn(start)
        g.end = turn(end)
        g.across = across.map(turn)
        return g
    }
}

/// A picture filling a layer.
nonisolated struct ImageFill: Codable, Hashable {
    enum Mode: String, Codable {
        /// Fills the layer, cropping what overflows.
        case cover
        /// Shows the whole picture inside the layer.
        case fit
        /// Squeezed to the layer's shape.
        case stretch
    }

    /// The file in the design's images folder.
    var asset: String
    var mode: Mode = .cover
    /// The picture's own size, in pixels.
    var size: CGSize
    /// Where the picture sits in the layer when it overflows: -1 at one edge, 1 at the other, 0 in the middle.
    var offset: CGPoint = .zero
    /// Larger than 1 to zoom into the picture beyond what covering needs.
    var scale: CGFloat = 1
    /// Turned over where it is drawn, left to right or top to bottom, as its layer was flipped.
    var flippedX: Bool?
    var flippedY: Bool?
    /// The picture with its background taken away, drawn in its place. See `Cutout`.
    var cutout: Cutout?
    /// How the picture is developed: its light, colours and detail; nil as it was taken. See `Develop`.
    var develop: Develop?

    /// The picture turned over with its layer: it lands on the other side, and faces the other way.
    func flipped(horizontally: Bool) -> ImageFill {
        var i = self
        // Not -0, which a file would keep.
        if horizontally {
            if offset.x != 0 { i.offset.x = -offset.x }
            i.flippedX = flippedX == true ? nil : true
        } else {
            if offset.y != 0 { i.offset.y = -offset.y }
            i.flippedY = flippedY == true ? nil : true
        }
        return i
    }
}

nonisolated struct Border: Codable, Hashable {
    enum Position: String, Codable, CaseIterable { case inside, center, outside }

    var on = false
    var color = RGBA.line
    var width: CGFloat = 1
    var position: Position = .inside
    /// Dash and gap lengths; no dash draws a solid line.
    var dash: CGFloat = 0
    var gap: CGFloat = 0
    /// The design's named colour it is drawn in; nil is a colour of its own. See `Style`.
    var named: UUID? = nil
    /// Drawn instead of the colour when there is one, placed in the layer's frame as a fill's is.
    var gradient: Gradient? = nil
    /// Drawn instead of the colour or a gradient when there is one, covering all the border may
    /// reach: the layer's frame, and as far past it as the border lies outside.
    var image: ImageFill? = nil

    /// What the border is drawn with, as a fill is: one colour, a gradient or a picture.
    var paint: Fill {
        get { Fill(on: on, color: color, gradient: gradient, image: image) }
        set {
            on = newValue.on
            color = newValue.color
            gradient = newValue.gradient
            image = newValue.image
        }
    }

    /// Whether it is drawn with more than its one colour: a gradient, or a picture.
    var paints: Bool { paint.paints }

    /// How far past the layer's frame it reaches, all round, as it lies on a closed outline.
    var reach: CGFloat {
        switch position {
        case .inside: 0
        case .center: width / 2
        case .outside: width
        }
    }

    /// The same border turned over with its layer, its gradient and picture with it.
    func flipped(horizontally: Bool) -> Border {
        var b = self
        b.gradient = gradient?.flipped(horizontally: horizontally)
        b.image = image?.flipped(horizontally: horizontally)
        return b
    }
}

nonisolated struct Shadow: Codable, Hashable {
    var on = false
    var color = RGBA.shadow
    var x: CGFloat = 0
    var y: CGFloat = 3
    var blur: CGFloat = 6
    /// Falling inside the layer, as if it were pressed into the page, rather than under it; nil is under it.
    var inset: Bool?
    /// How much bigger than the layer the shadow is cast from, or smaller below 0: under the layer
    /// its outline grown all round, inside it the hollow narrowed. Only a layer with an outline
    /// of its own has one; nil is none.
    var spread: CGFloat?
    /// The design's named shadow it is; nil is a shadow of its own. See `Style`.
    var named: UUID? = nil

    /// A shadow falling under the layer and out past it.
    var outside: Bool { on && inset != true }
    /// A shadow falling inside the layer.
    var inside: Bool { on && inset == true }
    /// The spread, 0 when there is none.
    var grown: CGFloat { spread ?? 0 }
}

/// A layer held up off the page, as a card is in the hand: tipped back by `x` degrees, its top
/// going away for more than 0, and swung round by `y`, its right side going away, after it is
/// turned in the page; then brought `z` points nearer, or pushed away below 0. See `Perspective`.
nonisolated struct Transform3D: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var z: CGFloat = 0
}

/// How a layer's colours mix with what lies under it.
nonisolated enum BlendMode: String, Codable, CaseIterable {
    case multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, hardLight, softLight
    case difference, exclusion, hue, saturation, color, luminosity

    var cg: CGBlendMode {
        switch self {
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .hardLight: .hardLight
        case .softLight: .softLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }

    var title: String {
        switch self {
        case .multiply: String(localized: "Multiply")
        case .screen: String(localized: "Screen")
        case .overlay: String(localized: "Overlay")
        case .darken: String(localized: "Darken")
        case .lighten: String(localized: "Lighten")
        case .colorDodge: String(localized: "Colour Dodge")
        case .colorBurn: String(localized: "Colour Burn")
        case .hardLight: String(localized: "Hard Light")
        case .softLight: String(localized: "Soft Light")
        case .difference: String(localized: "Difference")
        case .exclusion: String(localized: "Exclusion")
        case .hue: String(localized: "Hue")
        case .saturation: String(localized: "Saturation")
        case .color: String(localized: "Colour")
        case .luminosity: String(localized: "Luminosity")
        }
    }
}

/// A blur of the layer itself, or of what lies behind it, like frosted glass.
nonisolated struct Blur: Codable, Hashable {
    var on = true
    var radius: CGFloat
    var background = false
    /// Background blur only: how much lighter (up to 1) or darker (down to -1) what shows through is.
    var brightness: Double = 0
    /// Background blur only: how much of the layer's own fill lies over the blur, 0…1.
    var fillOpacity: Double = 0
    /// A blur that grows across the layer rather than lying even over all of it; nil is even.
    var ramp: BlurRamp?
}

/// Where a blur grows across its layer: sharp at `start`, blurred by the whole radius at `end`,
/// and as it is beyond either. Both are placed in the layer's box as a gradient's ends are, 0,0
/// its top left and 1,1 its bottom right, so the ramp stretches and turns with the layer.
nonisolated struct BlurRamp: Codable, Hashable {
    var start: CGPoint
    var end: CGPoint

    /// Sharp over most of the layer, blurring toward its bottom edge.
    static let down = BlurRamp(start: CGPoint(x: 0.5, y: 0.35), end: CGPoint(x: 0.5, y: 1))

    /// The same ramp turned to blur toward another edge: 0 the bottom, then the left, top and right.
    static func toward(_ edge: Int) -> BlurRamp {
        func turn(_ p: CGPoint) -> CGPoint {
            switch edge % 4 {
            case 1: CGPoint(x: 1 - p.y, y: p.x)
            case 2: CGPoint(x: 1 - p.x, y: 1 - p.y)
            case 3: CGPoint(x: p.y, y: 1 - p.x)
            default: p
            }
        }
        return BlurRamp(start: turn(down.start), end: turn(down.end))
    }
}

/// How a text layer finds its size: as wide as its words (made by a click), a box of a set width
/// that grows downward (made by dragging), or a box of a set width and height, its words wrapped
/// inside from the top. The inspector calls them Auto size, Fixed width and Fixed size. Resizing
/// from a side wraps the words to a new width; from the top or bottom the letters grow or shrink
/// with the box; from a corner the box is what is dragged, of fixed size, its letters as big as fit.
nonisolated enum TextSizing: String, Codable, CaseIterable {
    case autoWidth, autoHeight, fixed
}

nonisolated enum TextAlign: String, Codable, CaseIterable {
    /// Justified: every line but a paragraph's last runs from side to side.
    case left, center, right, justify
}

/// Where the lines lie in a box of fixed size that is taller, or shorter, than they are.
nonisolated enum TextVertical: String, Codable, CaseIterable {
    case top, middle, bottom
}

nonisolated struct TextStyle: Codable, Hashable {
    /// A family from the Font Book, or `TextStyle.system` for the Mac's own.
    var family = TextStyle.system
    /// A face of the family as the Font Book names it: "Regular", "Bold", "Medium Italic"…
    var face = "Regular"
    var size: CGFloat = 24
    var align: TextAlign = .left
    /// Distance from one baseline to the next; nil keeps the font's own.
    var lineSpacing: CGFloat?
    /// Space between characters in thousandths of the font size, as type designers count it.
    var tracking: CGFloat = 0
    var underline = false
    var sizing: TextSizing = .autoWidth
    /// Set in capitals, small letters, capitalised words or small capitals whatever was typed; nil as typed.
    var letterCase: LetterCase?
    /// A line through the letters; nil is none.
    var strikethrough: Bool?
    /// Space after each paragraph but the last, in points; nil is none.
    var paragraphSpacing: CGFloat?
    /// Where the lines lie in a box of fixed size; nil is at its top.
    var vertical: TextVertical?
    /// OpenType features set by their tags, such as "onum" for old-style figures or "ss01" for a
    /// stylistic set: 1 on, 0 off. Those the font does not have do nothing.
    var features: [String: Int]?
    /// Where a variable font is set along its axes, by their tags, such as "wght" for its weight
    /// and "wdth" for its width. Those the font does not have do nothing.
    var axes: [String: Double]?
    /// The design's named type it is set in, the same wherever that is used; nil is type of its
    /// own. See `Style`.
    var named: UUID? = nil

    static let system = "System"

    /// The same type grown or shrunk by `k`: its size and the distance between its lines, each to a
    /// tenth of a point. Letter spacing goes with the size by itself. Grown with its box, it is no
    /// longer the named type it was, which stays as it is everywhere else.
    func scaled(by k: CGFloat) -> TextStyle {
        var s = self
        if k != 1 { s.named = nil }
        s.size = max(1, (size * k * 10).rounded() / 10)
        s.lineSpacing = lineSpacing.map { max(0, ($0 * k * 10).rounded() / 10) }
        s.paragraphSpacing = paragraphSpacing.map { max(0, ($0 * k * 10).rounded() / 10) }
        return s
    }
}

nonisolated enum LetterCase: String, Codable, CaseIterable {
    /// Small capitals: small letters drawn as capitals of their height, by the font's own where
    /// it has them (`smcp`).
    case upper, lower, title, smallCaps

    func apply(_ text: String) -> String {
        switch self {
        case .upper: text.uppercased()
        case .lower: text.lowercased()
        case .title: text.capitalized
        case .smallCaps: text
        }
    }
}

nonisolated struct Node: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case artboard, rectangle, ellipse, line, text, group, path

        var title: String {
            switch self {
            case .artboard: String(localized: "Artboard")
            case .rectangle: String(localized: "Rectangle")
            case .ellipse: String(localized: "Ellipse")
            case .line: String(localized: "Line")
            case .text: String(localized: "Text")
            case .group: String(localized: "Group")
            case .path: String(localized: "Path")
            }
        }

        /// The undo step that adds one, said whole so each language can put its own words around it.
        var adding: LocalizedStringResource {
            switch self {
            case .artboard: "Add Artboard"
            case .rectangle: "Add Rectangle"
            case .ellipse: "Add Ellipse"
            case .line: "Add Line"
            case .text: "Add Text"
            case .group: "Add Group"
            case .path: "Add Path"
            }
        }

        /// The undo step that deletes one.
        var deleting: LocalizedStringResource {
            switch self {
            case .artboard: "Delete Artboard"
            case .rectangle: "Delete Rectangle"
            case .ellipse: "Delete Ellipse"
            case .line: "Delete Line"
            case .text: "Delete Text"
            case .group: "Delete Group"
            case .path: "Delete Path"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    /// Position and size in the parent: the artboard it sits on, or the canvas itself.
    var frame: CGRect
    /// Degrees clockwise about the frame's centre.
    var rotation: Double = 0
    var fill: Fill
    var border = Border()
    var shadow = Shadow()
    /// More fills lying over `fill`, bottom first, and more borders drawn over `border`; nil while
    /// there is only the one. A picture is only ever in `fill`. See `fills` and `borders`.
    var moreFills: [Fill]?
    var moreBorders: [Border]?
    /// More shadows besides `shadow`, under the layer or inside it, each cast on its own; nil while
    /// there is only the one. See `shadows`.
    var moreShadows: [Shadow]?
    var opacity: Double = 1
    /// Rectangles only.
    var cornerRadius: CGFloat = 0
    /// Rectangles only, when the corners differ: top left, top right, bottom right, bottom left.
    var corners: [CGFloat]?
    /// Rectangles only: how smoothly the corners run into the sides, from 0, a circle's quarter,
    /// to 1; 0.6 is the squircle iOS draws its icons with. See `Squircle`.
    var cornerSmoothing: CGFloat?
    /// Rectangles only: the design's named corners they have, the same wherever those are used;
    /// nil is corners of their own. See `Style`.
    var cornersNamed: UUID?
    /// Lines run from the frame's top left to its bottom right, or, when rising, from its bottom left to its top right.
    var rising = false
    /// Text layers only.
    var text: String?
    var style: TextStyle?
    /// Text layers only, when some letters look different from the rest: the words in runs that
    /// look alike, each with its own words. See `TextSpan`; `runs` lays them onto `text`.
    var spans: [TextSpan]?
    /// What lies on an artboard or in a group, bottom first. A group's frame is always the box
    /// around them, and it is never turned itself: its layers are.
    var children: [Node] = []
    /// Paths only: the outline as SVG path data, drawn so that `pathBox` fills the frame.
    var path: String?
    var pathBox: CGRect?
    /// Paths only: whether overlapping parts of the outline cancel out, or all count as inside.
    var evenOdd: Bool?
    /// Groups only: the shape that cuts off what lies outside it, in the group's coordinates.
    /// (A list of one, as a layer cannot hold another directly.)
    var mask: [Node]?
    /// Groups only: whether the first layer it holds is a mask that shows, holding the rest as a
    /// shape holds its picture: its fill and shadow lie under them, its border over them as a
    /// frame, and they are cut off at its outline. The group is as big as that layer. See `Mask`.
    var clipsToFirst: Bool?
    var blur: Blur?
    /// Turned in depth; nil lies flat in the page. Never for artboards, which are the page.
    var transform3D: Transform3D?
    /// Mixes the layer with what lies under it; nil draws it over as it is.
    var blend: BlendMode?
    var hidden = false
    var locked = false
    /// Artboards only: whether what reaches past the edge is cut off there.
    var clips = true
    /// Artboards only: whether its layers stay where they are when it changes size, rather than
    /// its design being laid out again for the new size (`Adapt`); nil lays it out again.
    var pinsLayers: Bool?
    /// Artboards only: shown dark, every look on it that has a name in its dark look; false shown
    /// light, with the switch to dark kept at hand; nil light, with no switch. See `Style.dark`.
    var dark: Bool?
    /// Carousels only: the size of each slide. The artboard is as many of them side by side as
    /// it is wide, and is exported cut into them. See `Carousel`.
    var slideSize: CGSize?
    /// Repeat grids only: a group whose layers are one layer and its copies in rows and columns.
    /// See `RepeatGrid`.
    var grid: RepeatGrid?
    /// Decks only: an artboard of posts lying one behind another, designed once. See `Deck`.
    var deck: Deck?
    /// Layers lying straight on a deck only: the post they are in, or none for the design that
    /// lies behind every post.
    var post: Int?
    /// Layers of a deck's posts only: what else the layer keeps of its own, by the names of its
    /// properties (`LayerField`), whatever the same layer in other posts does. Its words and
    /// pictures are its own anyway.
    var own: [String]?
    /// Artboards only: the columns, rows and baselines it is laid out on. See `LayoutGrid`.
    var layout: LayoutGrid?
    /// Artboards only: the guides pulled onto it out of the rulers, each by a key of its own, so
    /// that two people adding guides to it at once both keep theirs. See `Guideline`.
    var guides: [String: Guideline]?
    /// The files the layer goes out as whenever what is marked for export is exported, such as
    /// 1×, 2× and 3× PNGs named "@2x" and "@3x"; nil when it is not marked.
    var exports: [ExportPreset]?
    /// Copies of components only: the component it is a copy of, which variant, and how it is
    /// placed. See `Instance`.
    var instance: Instance?
    /// Components only, kept apart from the canvas: its variants. See `Master`.
    var master: Master?
    /// Text layers only: its letters run along a curve rather than straight, bent into an arc of
    /// their own or riding a shape's outline. See `TextCurve`.
    var curve: TextCurve?
    /// Text layers on a curve only: the curve, as path data in the text's own coordinates (its
    /// frame's top left at zero), worked out from its bend or the shape it rides. Kept apart from
    /// `curve`, so that one person reshaping the shape while another slides the text along it
    /// both keep what they did.
    var curvePath: String?

    init(kind: Kind, name: String? = nil, frame: CGRect) {
        self.kind = kind
        self.name = name ?? kind.title
        self.frame = frame
        switch kind {
        case .artboard:
            fill = Fill(color: .white)
        case .rectangle, .ellipse:
            fill = Fill(color: .shape)
        case .line:
            fill = Fill(on: false, color: .shape)
            border = Border(on: true, color: .line, width: 1, position: .center)
        case .text:
            fill = Fill(color: RGBA(r: 0.11, g: 0.106, b: 0.098))
            text = ""
            style = TextStyle()
        case .group:
            fill = Fill(on: false, color: .shape)
        case .path:
            fill = Fill(color: .shape)
        }
    }

    var isArtboard: Bool { kind == .artboard }
    var isGroup: Bool { kind == .group }
    /// Artboards and groups hold other layers.
    var isContainer: Bool { kind == .artboard || kind == .group }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// The two ends of a line, in the parent.
    var lineEnds: (CGPoint, CGPoint) {
        rising ? (CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.minY))
               : (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY))
    }

    mutating func setLineEnds(_ a: CGPoint, _ b: CGPoint) {
        frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        // Rising when the end further left is the lower one.
        let left = a.x <= b.x ? a : b, right = a.x <= b.x ? b : a
        rising = left.y > right.y
    }

    /// A rectangle's four radii: top left, top right, bottom right, bottom left.
    var radii: [CGFloat] {
        get { corners.flatMap { $0.count == 4 ? $0 : nil } ?? Array(repeating: cornerRadius, count: 4) }
        set {
            // Kept as one radius while they are alike, and as the largest beside them when not.
            if Set(newValue).count == 1 {
                cornerRadius = newValue[0]
                corners = nil
            } else {
                cornerRadius = newValue.max() ?? 0
                corners = newValue
            }
        }
    }
}

// MARK: - Codable for CoreGraphics values

/// Stored as plain numbers, so the files stay readable.
extension CGRect {
    var rounded: CGRect {
        func r(_ v: CGFloat) -> CGFloat { (v * 100).rounded() / 100 }
        return CGRect(x: r(origin.x), y: r(origin.y), width: r(size.width), height: r(size.height))
    }
}
