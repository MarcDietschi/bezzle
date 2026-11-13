import Foundation
import CoreGraphics

/// What someone building the design reads off it: how big each layer is and how far it lies from
/// what is round it, its looks by the names the design gives them, and the same written as code.
/// The canvas measures with it while the design is inspected, the inspector writes its specs with
/// it, and the AI server hands it on. Distances are between the upright boxes layers are drawn in,
/// on the canvas, in points.
nonisolated enum Inspect {
    // MARK: Boxes

    /// The upright box a layer is drawn in, on the canvas: turned layers by what they cover.
    static func box(of id: UUID, in doc: BezzleDocument) -> CGRect? {
        guard let n = doc.node(id) else { return nil }
        if n.isArtboard { return n.frame }
        let o = doc.parentOrigin(of: id)
        return Geometry.bounds(of: n, eye: doc.eye(forParentOf: id)).offsetBy(dx: o.x, dy: o.y)
    }

    /// How far each side of a box lies inside another's; less than nothing where it sticks out.
    struct Insets: Equatable {
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat
        var left: CGFloat

        init(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
            self.top = top; self.right = right; self.bottom = bottom; self.left = left
        }

        init(of inner: CGRect, in outer: CGRect) {
            self.init(top: inner.minY - outer.minY, right: outer.maxX - inner.maxX,
                      bottom: outer.maxY - inner.maxY, left: inner.minX - outer.minX)
        }
    }

    // MARK: Measuring

    /// One distance to show, from an edge of one box straight across to an edge of the other.
    struct Span: Equatable {
        var from: CGPoint
        var to: CGPoint
        /// Where the edge measured to stops short of the line: from its end along it to `to`, to
        /// draw dashed, so the line is seen to arrive at that edge.
        var reach: [CGPoint]?

        var length: CGFloat { hypot(to.x - from.x, to.y - from.y) }
        /// Along the page, rather than down it.
        var across: Bool { abs(to.x - from.x) >= abs(to.y - from.y) }
    }

    /// The distances between two boxes, as they are read off a drawing: from each side of the one
    /// inside to the side of the one round it; between the sides facing each other across a gap,
    /// in the middle of where they face, or level with `a`'s middle where they do not; and for
    /// boxes lying partly over each other, how far each side is from the other's.
    static func spans(from a: CGRect, to b: CGRect) -> [Span] {
        let e: CGFloat = 0.01
        var out: [Span] = []
        func add(_ p: CGPoint, _ q: CGPoint, reach: [CGPoint]? = nil) {
            if hypot(q.x - p.x, q.y - p.y) > e { out.append(Span(from: p, to: q, reach: reach)) }
        }
        let holds = b.insetBy(dx: -e, dy: -e).contains(a), held = a.insetBy(dx: -e, dy: -e).contains(b)
        if holds || held {
            let (inner, outer) = holds ? (a, b) : (b, a)
            add(CGPoint(x: inner.minX, y: inner.midY), CGPoint(x: outer.minX, y: inner.midY))
            add(CGPoint(x: inner.maxX, y: inner.midY), CGPoint(x: outer.maxX, y: inner.midY))
            add(CGPoint(x: inner.midX, y: inner.minY), CGPoint(x: inner.midX, y: outer.minY))
            add(CGPoint(x: inner.midX, y: inner.maxY), CGPoint(x: inner.midX, y: outer.maxY))
            return out
        }
        let ys = (max(a.minY, b.minY), min(a.maxY, b.maxY)), xs = (max(a.minX, b.minX), min(a.maxX, b.maxX))
        let sharesY = ys.0 < ys.1, sharesX = xs.0 < xs.1
        if sharesX, sharesY {
            let y = (ys.0 + ys.1) / 2, x = (xs.0 + xs.1) / 2
            add(CGPoint(x: a.minX, y: y), CGPoint(x: b.minX, y: y))
            add(CGPoint(x: a.maxX, y: y), CGPoint(x: b.maxX, y: y))
            add(CGPoint(x: x, y: a.minY), CGPoint(x: x, y: b.minY))
            add(CGPoint(x: x, y: a.maxY), CGPoint(x: x, y: b.maxY))
            return out
        }
        if !sharesX {
            let (fx, tx) = a.maxX <= b.minX ? (a.maxX, b.minX) : (a.minX, b.maxX)
            let y = sharesY ? (ys.0 + ys.1) / 2 : a.midY
            let reach = sharesY ? nil : [CGPoint(x: tx, y: y < b.minY ? b.minY : b.maxY), CGPoint(x: tx, y: y)]
            add(CGPoint(x: fx, y: y), CGPoint(x: tx, y: y), reach: reach)
        }
        if !sharesY {
            let (fy, ty) = a.maxY <= b.minY ? (a.maxY, b.minY) : (a.minY, b.maxY)
            let x = sharesX ? (xs.0 + xs.1) / 2 : a.midX
            let reach = sharesX ? nil : [CGPoint(x: x < b.minX ? b.minX : b.maxX, y: ty), CGPoint(x: x, y: ty)]
            add(CGPoint(x: x, y: fy), CGPoint(x: x, y: ty), reach: reach)
        }
        return out
    }

    /// The room between two boxes facing each other across a gap, to shade as the canvas shades
    /// gaps of the same width (`GapMarks`).
    static func gaps(between a: CGRect, and b: CGRect) -> [CGRect] {
        let ys = (max(a.minY, b.minY), min(a.maxY, b.maxY)), xs = (max(a.minX, b.minX), min(a.maxX, b.maxX))
        var out: [CGRect] = []
        if xs.0 >= xs.1, ys.0 < ys.1 {
            let l = min(a.maxX, b.maxX), r = max(a.minX, b.minX)
            if r - l > 0.01 { out.append(CGRect(x: l, y: ys.0, width: r - l, height: ys.1 - ys.0)) }
        }
        if ys.0 >= ys.1, xs.0 < xs.1 {
            let t = min(a.maxY, b.maxY), d = max(a.minY, b.minY)
            if d - t > 0.01 { out.append(CGRect(x: xs.0, y: t, width: xs.1 - xs.0, height: d - t)) }
        }
        return out
    }

    // MARK: Where a layer is

    /// The layers from its screen down to it: the screen first, the layer last.
    static func path(of id: UUID, in doc: BezzleDocument) -> [Node] {
        doc.ancestors(of: id) + [doc.node(id)].compactMap { $0 }
    }

    /// The copy of a component a layer is, or lies in, nearest first; with its component and variant.
    static func component(of id: UUID, in doc: BezzleDocument) -> (copy: Node, master: Node, variant: String, state: VariantState?)? {
        for n in path(of: id, in: doc).reversed() where n.isCopy {
            guard let inst = n.instance, let master = doc.master(inst.of) else { continue }
            return (n, master, Components.name(of: inst.variant, in: master), Components.state(of: inst.variant, in: master))
        }
        return nil
    }

    // MARK: Names given to looks

    /// A named look, as code calls it.
    struct Token: Equatable {
        let kind: StyleKind
        /// As the design names it.
        let name: String
        /// As CSS names it, "brand-blue".
        let key: String
        /// As Swift names it, "brandBlue".
        let camel: String
        let gradient: Bool

        var css: String {
            switch kind {
            case .colour: gradient ? "var(--gradient-\(key))" : "var(--color-\(key))"
            case .text: ".text-\(key)"
            case .shadow: "var(--shadow-\(key))"
            case .corners: "var(--radius-\(key))"
            }
        }

        var swift: String {
            switch kind {
            case .colour: gradient ? "Tokens.Gradients.\(camel)" : "Tokens.Colors.\(camel)"
            case .text: "Tokens.Typography.\(camel)"
            case .shadow: "Tokens.Shadows.\(camel)"
            case .corners: "Tokens.Corners.\(camel)"
            }
        }

        /// How code of a platform calls it.
        func code(_ platform: Platform) -> String { platform == .css ? css : swift }
    }

    /// Each of the design's named looks by its id, named as `DesignTokens` writes them out.
    struct Tokens {
        let byID: [UUID: Token]

        init(_ doc: BezzleDocument) {
            var byID: [UUID: Token] = [:]
            let all = DesignTokens.styles(doc)
            for kind in StyleKind.allCases {
                let of = all.filter { $0.kind == kind }
                for (style, name) in zip(of, DesignTokens.unique(of.map(\.name))) {
                    let gradient = style.look.paint?.gradient?.stops.isEmpty == false
                    byID[style.id] = Token(kind: kind, name: style.name, key: DesignTokens.kebab(name), camel: DesignTokens.camel(name), gradient: gradient)
                }
            }
            self.byID = byID
        }

        subscript(_ id: UUID?) -> Token? { id.flatMap { byID[$0] } }
    }

    /// What the specs are written for.
    enum Platform: String, CaseIterable {
        case css, swiftui

        var title: String {
            switch self {
            case .css: "CSS"
            case .swiftui: "SwiftUI"
            }
        }
    }

    // MARK: Values as people read them

    static func number(_ v: CGFloat) -> String { DesignTokens.number(v, 2) }

    static func px(_ v: CGFloat) -> String {
        let s = number(v)
        return s == "0" ? "0" : "\(s)px"
    }

    /// A colour as CSS writes it: "#3366FF", or rgba() when it is see-through.
    static func hex(_ c: RGBA) -> String { DesignTokens.hex(c) }

    /// A colour as SwiftUI writes it.
    static func swiftColor(_ c: RGBA) -> String {
        let n = { (x: Double) in DesignTokens.number(x, 3) }
        let rgb = "Color(red: \(n(c.r)), green: \(n(c.g)), blue: \(n(c.b)))"
        return c.a < 0.999 ? "\(rgb).opacity(\(n(c.a)))" : rgb
    }

    /// The line height of type: as set, or the font's own when it is left to the font.
    static func lineHeight(_ style: TextStyle, natural: CGFloat?) -> (value: CGFloat?, set: Bool) {
        if let l = style.lineSpacing { return (l, true) }
        return (natural, false)
    }

    /// Letter spacing in points, from thousandths of the size.
    static func tracking(_ style: TextStyle) -> CGFloat { style.tracking / 1000 * style.size }

    // MARK: CSS

    /// How many layers in a group are written out with it, so a large one does not swamp the code.
    static let codeBudget = 16

    /// A class name for a layer, from its name.
    static func className(_ name: String) -> String {
        let k = DesignTokens.kebab(name)
        return k.first?.isNumber == true ? "_" + k : k
    }

    /// The layer as a CSS rule, its class named after it: its size, its looks, named looks by
    /// their custom properties with the value beside them, and for words, their type. A group
    /// brings what it holds, each placed in it as it lies, a few levels down.
    static func css(_ n: Node, in doc: BezzleDocument, tokens: Tokens) -> String {
        var budget = codeBudget
        return cssRule(n, selector: "." + className(n.name), at: nil, tokens: tokens, depth: 0, budget: &budget)
    }

    private static func cssRule(_ n: Node, selector: String, at origin: CGPoint?, tokens: Tokens, depth: Int, budget: inout Int) -> String {
        var lines = declarations(n, tokens: tokens)
        if let o = origin {
            lines.insert(contentsOf: ["  position: absolute;", "  left: \(px(o.x));", "  top: \(px(o.y));"], at: 0)
        } else if n.isGroup {
            lines.insert("  position: relative;", at: 0)
        }
        var out = "\(selector) {\n" + lines.joined(separator: "\n") + "\n}\n"
        guard n.isGroup, depth < 3 else { return out }
        var left = 0
        for child in n.children where !child.hidden {
            guard budget > 0 else { left += 1; continue }
            budget -= 1
            out += "\n" + cssRule(child, selector: "\(selector) > .\(className(child.name))", at: child.frame.origin, tokens: tokens, depth: depth + 1, budget: &budget)
        }
        if left > 0 { out += "\n/* and \(left) more layer\(left == 1 ? "" : "s") */\n" }
        return out
    }

    /// Whether anything a layer holds, however deep, is turned or lifted in depth.
    private static func holdsDepth(_ n: Node) -> Bool {
        n.children.contains { Perspective.inDepth($0) || holdsDepth($0) }
    }

    /// What a layer's own rule declares.
    private static func declarations(_ n: Node, tokens: Tokens) -> [String] {
        var lines: [String] = []
        func put(_ property: String, _ value: String, _ note: String? = nil) {
            lines.append("  \(property): \(value);" + (note.map { " /* \($0) */" } ?? ""))
        }
        let text = n.kind == .text
        let style = n.style ?? TextStyle()
        let w = n.frame.width, h = n.frame.height

        // How big
        switch n.kind {
        case .text:
            switch style.sizing {
            case .autoWidth: put("white-space", "nowrap")
            case .autoHeight: put("width", px(w))
            case .fixed: put("width", px(w)); put("height", px(h))
            }
        case .line:
            let (a, b) = n.lineEnds
            put("width", px(hypot(b.x - a.x, b.y - a.y)))
            put("height", "0")
        default:
            put("width", px(w))
            put("height", px(h))
        }
        var turn = n.rotation
        if n.kind == .line {
            let (a, b) = n.lineEnds
            turn += atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        }
        let turned = abs(turn.truncatingRemainder(dividingBy: 360)) > 0.01
        if let t = n.transform3D, Perspective.inDepth(n), !t.pinned {
            // Lifted and turned in the artboard's one scene, which the artboard's perspective sees:
            // last of all brought nearer, before that tipped, swung, and first turned in the page.
            var steps: [String] = []
            if t.z != 0 { steps.append("translateZ(\(px(t.z)))") }
            if t.x != 0 { steps.append("rotateX(\(DesignTokens.number(t.x, 2))deg)") }
            if t.y != 0 { steps.append("rotateY(\(DesignTokens.number(t.y, 2))deg)") }
            if turned { steps.append("rotate(\(DesignTokens.number(turn, 2))deg)") }
            put("transform", steps.joined(separator: " "), "in the artboard's perspective")
        } else if turned {
            put("transform", "rotate(\(DesignTokens.number(turn, 2))deg)")
        }
        // An artboard holding anything in depth is its scene: seen from in front of its middle.
        // A group lying flat in it passes the scene on to what it holds.
        if n.isArtboard, Self.holdsDepth(n) {
            put("perspective", px(CGFloat(FilmLens.distance(for: n.frame.size))))
            put("perspective-origin", "center")
        } else if n.isGroup, !Perspective.inDepth(n), Self.holdsDepth(n) {
            put("transform-style", "preserve-3d")
        }

        // What paints it
        let fills = n.fills
        if text {
            if let f = fills.first {
                if let g = f.gradient, !g.stops.isEmpty {
                    put("background", tokens[f.named]?.css ?? DesignTokens.cssGradient(g))
                    put("-webkit-background-clip", "text")
                    put("color", "transparent")
                } else if let t = tokens[f.named] {
                    put("color", t.css, hex(f.color))
                } else {
                    put("color", hex(f.color))
                }
            }
        } else if n.kind == .line {
            if let b = n.borders.first {
                put("border-top", "\(px(b.width)) \(b.dash > 0 ? "dashed" : "solid") \(tokens[b.named]?.css ?? hex(b.color))", tokens[b.named] != nil ? hex(b.color) : nil)
            }
        } else if !fills.isEmpty {
            // CSS lists the one on top first; only the one at the bottom may be a plain colour.
            let top = Array(fills.reversed())
            var layers: [String] = []
            var note: String?
            for (i, f) in top.enumerated() {
                let last = i == top.count - 1
                if let image = f.image {
                    let size = switch image.mode {
                    case .cover: "cover"
                    case .fit: "contain"
                    case .stretch: "100% 100%"
                    }
                    layers.append("url(\"\(image.asset)\") center / \(size) no-repeat")
                } else if let g = f.gradient, !g.stops.isEmpty {
                    layers.append(tokens[f.named]?.css ?? DesignTokens.cssGradient(g))
                } else {
                    let c = tokens[f.named]?.css ?? hex(f.color)
                    if tokens[f.named] != nil, top.count == 1 { note = hex(f.color) }
                    layers.append(last ? c : "linear-gradient(\(c), \(c))")
                }
            }
            put("background", layers.joined(separator: ", "), note)
        }

        // Its edge
        if n.kind != .line, let b = n.borders.first {
            let colour = tokens[b.named]?.css ?? hex(b.gradient?.stops.first?.color ?? b.color)
            let note = tokens[b.named] != nil ? hex(b.color) : nil
            let dash = b.dash > 0 ? "dashed" : "solid"
            if text {
                put("-webkit-text-stroke", "\(px(b.width)) \(colour)", note)
            } else {
                switch b.position {
                case .inside:
                    put("border", "\(px(b.width)) \(dash) \(colour)", note)
                    put("box-sizing", "border-box")
                case .center:
                    put("outline", "\(px(b.width)) \(dash) \(colour)", note)
                    put("outline-offset", px(-b.width / 2))
                case .outside:
                    put("outline", "\(px(b.width)) \(dash) \(colour)", note)
                }
            }
            if n.borders.count > 1 { lines.append("  /* and \(n.borders.count - 1) more border\(n.borders.count > 2 ? "s" : "") */") }
        }
        if n.kind == .ellipse {
            put("border-radius", "50%")
        } else if n.kind == .rectangle || n.isArtboard {
            let r = n.radii
            if let t = tokens[n.cornersNamed] {
                put("border-radius", t.css, px(r[0]))
            } else if Set(r).count == 1 {
                if r[0] > 0 { put("border-radius", px(r[0])) }
            } else {
                put("border-radius", r.map(px).joined(separator: " "))
            }
        }

        // What it casts
        let shadows = n.shadows
        if !shadows.isEmpty {
            if text {
                let outer = shadows.filter(\.outside)
                if !outer.isEmpty {
                    put("text-shadow", outer.map { "\(px($0.x)) \(px($0.y)) \(px($0.blur)) \(hex($0.color))" }.joined(separator: ", "))
                }
            } else {
                put("box-shadow", shadows.map { tokens[$0.named]?.css ?? DesignTokens.cssShadow($0) }.joined(separator: ", "))
            }
        }
        if n.opacity < 0.999 { put("opacity", DesignTokens.number(n.opacity, 2)) }
        if let m = n.blend { put("mix-blend-mode", DesignTokens.kebab(m.rawValue)) }
        if let b = n.blur, b.on, b.radius > 0 {
            put(b.background ? "backdrop-filter" : "filter", "blur(\(px(b.radius)))")
        }
        if (n.isArtboard && n.clips) || n.holder != nil { put("overflow", "hidden") }

        // Its type
        if text {
            let t = tokens[style.named]
            let k = t?.key
            func v(_ part: String, _ literal: String) -> (String, String?) {
                k.map { ("var(--font-\($0)-\(part))", literal) } ?? (literal, nil)
            }
            var (value, note) = v("family", DesignTokens.fontFamily(style.family))
            put("font-family", value, note.map { _ in style.family == TextStyle.system ? "system" : style.family })
            (value, note) = v("size", px(style.size))
            put("font-size", value, note)
            (value, note) = v("weight", "\(DesignTokens.weight(style.face))")
            put("font-weight", value, note)
            if DesignTokens.italic(style.face) { put("font-style", "italic") }
            if let l = style.lineSpacing {
                (value, note) = v("line-height", px(l))
                put("line-height", value, note)
            }
            if style.tracking != 0 || k != nil {
                (value, note) = v("letter-spacing", "\(DesignTokens.number(Double(style.tracking) / 1000, 3))em")
                put("letter-spacing", value, note)
            }
            if style.align != .left { put("text-align", style.align.rawValue) }
            switch style.letterCase {
            case .upper: put("text-transform", "uppercase")
            case .lower: put("text-transform", "lowercase")
            case .title: put("text-transform", "capitalize")
            case .smallCaps: put("font-variant-caps", "small-caps")
            case nil: break
            }
            let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
            if !decorations.isEmpty { put("text-decoration", decorations.joined(separator: " ")) }
            if let p = style.paragraphSpacing, p > 0 { lines.append("  /* \(px(p)) after each paragraph */") }
        }
        return lines
    }

    // MARK: SwiftUI

    /// The layer as a SwiftUI view: a shape filled and edged as it is, its words with their type,
    /// a group as a stack of what it holds, each placed as it lies, a screen as a stack its size;
    /// named looks by the tokens `DesignTokens` writes.
    static func swiftUI(_ n: Node, in doc: BezzleDocument, tokens: Tokens) -> String {
        var budget = codeBudget
        return swiftView(n, tokens: tokens, depth: 0, budget: &budget)
    }

    private static func indent(_ code: String) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
    }

    private static func swiftView(_ n: Node, tokens: Tokens, depth: Int, budget: inout Int) -> String {
        var mods: [String] = []
        func m(_ s: String) { mods.append("    ." + s) }
        let num = { (v: CGFloat) in number(v) }
        func paint(_ f: Fill) -> String { Inspect.paint(f, size: n.frame.size, tokens: tokens, platform: .swiftui) }
        func edgeColor(_ b: Border) -> String { tokens[b.named]?.swift ?? swiftColor(b.color) }
        let w = n.frame.width, h = n.frame.height
        var head: String

        switch n.kind {
        case .text:
            let style = n.style ?? TextStyle()
            let words = (n.text ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            head = "Text(\"\(words)\")"
            if let t = tokens[style.named] {
                m("typeToken(\(t.swift))")
            } else {
                let weight: String = switch DesignTokens.weight(style.face) {
                case 100: ".ultraLight"
                case 200: ".thin"
                case 300: ".light"
                case 500: ".medium"
                case 600: ".semibold"
                case 700: ".bold"
                case 800: ".heavy"
                case 900: ".black"
                default: ".regular"
                }
                let font = style.family == TextStyle.system ? ".system(size: \(num(style.size)), weight: \(weight))"
                    : ".custom(\"\(style.family)\", size: \(num(style.size))).weight(\(weight))"
                m("font(\(font)\(DesignTokens.italic(style.face) ? ".italic()" : ""))")
                if style.tracking != 0 { m("tracking(\(num(tracking(style))))") }
                if let l = style.lineSpacing, l - style.size * 1.2 > 0.05 { m("lineSpacing(\(num(l - style.size * 1.2)))") }
            }
            if let f = n.fills.first { m("foregroundStyle(\(paint(f)))") }
            switch style.align {
            case .center: m("multilineTextAlignment(.center)")
            case .right: m("multilineTextAlignment(.trailing)")
            default: break
            }
            switch style.letterCase {
            case .upper: m("textCase(.uppercase)")
            case .lower: m("textCase(.lowercase)")
            case .smallCaps: m("font(.body.smallCaps())")
            default: break
            }
            if style.underline { m("underline()") }
            if style.strikethrough == true { m("strikethrough()") }
            switch style.sizing {
            case .autoWidth: m("fixedSize()")
            case .autoHeight: m("frame(width: \(num(w)), alignment: \(style.align == .center ? ".center" : style.align == .right ? ".trailing" : ".leading"))")
            case .fixed: m("frame(width: \(num(w)), height: \(num(h)), alignment: .topLeading)")
            }
        case .group, .artboard:
            let count = n.children.count
            var inner = ""
            if n.isGroup, depth < 3 {
                var left = 0
                for child in n.children where !child.hidden {
                    guard budget > 0 else { left += 1; continue }
                    budget -= 1
                    var code = swiftView(child, tokens: tokens, depth: depth + 1, budget: &budget)
                    if child.frame.origin != .zero { code += "    .offset(x: \(num(child.frame.minX)), y: \(num(child.frame.minY)))\n" }
                    inner += indent(code)
                }
                if left > 0 { inner += "    // and \(left) more layer\(left == 1 ? "" : "s")\n" }
            }
            head = "ZStack(alignment: .topLeading) {\n" + (inner.isEmpty ? "    // \(count == 1 ? "1 layer" : "\(count) layers")\n" : inner) + "}"
            m("frame(width: \(num(w)), height: \(num(h)))")
            if let f = n.fills.first { m("background(\(paint(f)))") }
            if n.isArtboard || n.holder != nil { m("clipped()") }
        case .line:
            let (a, b) = n.lineEnds
            head = "Rectangle()"
            if let e = n.borders.first { m("fill(\(edgeColor(e)))") }
            m("frame(width: \(num(hypot(b.x - a.x, b.y - a.y))), height: \(num(n.borders.first?.width ?? 1)))")
            let turn = n.rotation + atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            if abs(turn) > 0.01 { m("rotationEffect(.degrees(\(DesignTokens.number(turn, 2))))") }
        case .path:
            head = "Image(\"\(DesignTokens.kebab(n.name))\") // a drawing: export it as SVG or PDF"
            m("resizable()")
            m("frame(width: \(num(w)), height: \(num(h)))")
        case .rectangle, .ellipse:
            let shape = shapeCode(n, tokens: tokens)
            let fills = n.fills
            if let image = fills.last?.image {
                head = "Image(\"\((image.asset as NSString).deletingPathExtension)\")"
                m("resizable()")
                m(image.mode == .fit ? "scaledToFit()" : image.mode == .stretch ? "frame(width: \(num(w)), height: \(num(h)))" : "scaledToFill()")
                if image.mode != .stretch { m("frame(width: \(num(w)), height: \(num(h)))") }
                m("clipShape(\(shape))")
            } else {
                head = shape
                if let first = fills.first { m("fill(\(paint(first)))") } else { m("fill(.clear)") }
                for f in fills.dropFirst() { m("overlay { \(shape).fill(\(paint(f))) }") }
                m("frame(width: \(num(w)), height: \(num(h)))")
            }
            for b in n.borders {
                let style = b.dash > 0 ? "style: StrokeStyle(lineWidth: \(num(b.width)), dash: [\(num(b.dash)), \(num(b.gap > 0 ? b.gap : b.dash))])" : "lineWidth: \(num(b.width))"
                switch b.position {
                case .inside: m("overlay { \(shape).strokeBorder(\(edgeColor(b)), \(style)) }")
                case .center: m("overlay { \(shape).stroke(\(edgeColor(b)), \(style)) }")
                case .outside: m("overlay { \(shape).inset(by: -\(num(b.width / 2))).stroke(\(edgeColor(b)), \(style)) }")
                }
            }
        }
        if n.kind != .line, abs(n.rotation.truncatingRemainder(dividingBy: 360)) > 0.01 {
            m("rotationEffect(.degrees(\(DesignTokens.number(n.rotation, 2))))")
        }
        for s in n.shadows where s.outside {
            if let t = tokens[s.named] { m("shadowToken(\(t.swift))") }
            else { m("shadow(color: \(swiftColor(s.color)), radius: \(num(s.blur / 2)), x: \(num(s.x)), y: \(num(s.y)))") }
        }
        if n.shadows.contains(where: \.inside) { mods.append("    // and a shadow inside it") }
        if n.opacity < 0.999 { m("opacity(\(DesignTokens.number(n.opacity, 2)))") }
        if let b = n.blend { m("blendMode(.\(b.rawValue))") }
        if let b = n.blur, b.on, b.radius > 0 {
            if b.background { m("background(.ultraThinMaterial) // frosted: blurs what lies behind by \(num(b.radius))") }
            else { m("blur(radius: \(num(b.radius / 2)))") }
        }
        return ([head] + mods).joined(separator: "\n") + "\n"
    }

    /// A gradient as SwiftUI writes it, on a layer of this size.
    static func swiftGradient(_ g: Gradient, size: CGSize) -> String {
        let n3 = { (v: CGFloat) in DesignTokens.number(v, 3) }
        let stops = g.stops.sorted { $0.offset < $1.offset }.map { ".init(color: \(swiftColor($0.color)), location: \(DesignTokens.number($0.offset, 3)))" }.joined(separator: ", ")
        switch g.kind {
        case .linear:
            return "LinearGradient(stops: [\(stops)], startPoint: UnitPoint(x: \(n3(g.start.x)), y: \(n3(g.start.y))), endPoint: UnitPoint(x: \(n3(g.end.x)), y: \(n3(g.end.y))))"
        case .radial:
            return "RadialGradient(stops: [\(stops)], center: UnitPoint(x: \(n3(g.start.x)), y: \(n3(g.start.y))), startRadius: 0, endRadius: \(number(max(size.width, size.height) * g.radius)))"
        }
    }

    /// A fill as code of a platform writes it: by its token where it has a name, else its
    /// gradient, its picture or its colour.
    static func paint(_ f: Fill, size: CGSize, tokens: Tokens, platform: Platform) -> String {
        if let t = tokens[f.named] { return t.code(platform) }
        if let image = f.image {
            return platform == .css ? "url(\"\(image.asset)\")" : "Image(\"\((image.asset as NSString).deletingPathExtension)\")"
        }
        if let g = f.gradient, !g.stops.isEmpty {
            return platform == .css ? DesignTokens.cssGradient(g) : swiftGradient(g, size: size)
        }
        return platform == .css ? hex(f.color) : swiftColor(f.color)
    }

    /// A shadow as code of a platform writes it.
    static func shadow(_ s: Shadow, tokens: Tokens, platform: Platform) -> String {
        if let t = tokens[s.named] { return t.code(platform) }
        if platform == .css { return DesignTokens.cssShadow(s) }
        return ".shadow(color: \(swiftColor(s.color)), radius: \(number(s.blur / 2)), x: \(number(s.x)), y: \(number(s.y)))"
    }

    /// The shape a rectangle or an ellipse is drawn as in SwiftUI.
    static func shapeCode(_ n: Node, tokens: Tokens) -> String {
        if n.kind == .ellipse { return n.frame.width == n.frame.height ? "Circle()" : "Ellipse()" }
        let smooth = (n.cornerSmoothing ?? 0) > 0 ? ", style: .continuous" : ""
        let r = n.radii
        if let t = tokens[n.cornersNamed] { return "RoundedRectangle(cornerRadius: \(t.swift)\(smooth))" }
        if Set(r).count == 1 {
            guard r[0] > 0 else { return "Rectangle()" }
            if r[0] * 2 >= min(n.frame.width, n.frame.height) - 0.01 { return "Capsule()" }
            return "RoundedRectangle(cornerRadius: \(number(r[0]))\(smooth))"
        }
        return "UnevenRoundedRectangle(cornerRadii: .init(topLeading: \(number(r[0])), bottomLeading: \(number(r[3])), bottomTrailing: \(number(r[2])), topTrailing: \(number(r[1])))\(smooth))"
    }

    /// The layer as code for a platform.
    static func code(_ n: Node, in doc: BezzleDocument, tokens: Tokens, for platform: Platform) -> String {
        platform == .css ? css(n, in: doc, tokens: tokens) : swiftUI(n, in: doc, tokens: tokens)
    }
}
