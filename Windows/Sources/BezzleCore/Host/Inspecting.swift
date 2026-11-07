import Foundation

// What the inspector shows of a layer while the design is inspected on Windows, as the Mac's
// InspectInspector (Views/InspectInspector.swift) reads it with the shared `Inspect` and
// `DesignTokens`: where the layer lies, its box in the one round it, its type, its looks and its
// code, each value as it reads and as a click copies it, with the name the design gives it.

extension WindowsCore {
    /// A line of a spec: what it is, its value as it reads and as a click copies it, a colour to
    /// show beside it (0xRRGGBB and its alpha), the name the design gives it as code calls it,
    /// and a word after it.
    public struct SpecLine: Sendable {
        public let label: String
        public let value: String
        public let copy: String
        public var swatch: (hex: UInt32, alpha: Double)? = nil
        public var token: String? = nil
        public var note: String? = nil
    }

    public struct InspectSpec: Sendable {
        /// From the screen down to the layer: each one's id and name.
        public let path: [(id: UUID, name: String)]
        /// The component copy it is, or lies in, and the variant: "Card · Default".
        public let component: String?
        /// Its size (a turned layer's as it is), the name of what it lies in and how far each side
        /// lies inside it (top, right, bottom, left), and where it is on its screen.
        public let size: CGSize
        public let parent: String?
        public let insets: [Double]?
        public let x: Double?
        public let y: Double?
        public let rotation: Double?
        /// For a text: its family and face, and its lines; the words themselves.
        public let font: (family: String, face: String, copyFamily: String, copyWeight: String)?
        public let type: [SpecLine]
        public let words: String?
        public let looks: [SpecLine]
        public let isText: Bool
    }

    public enum InspectPlatform: String, Sendable { case css, swiftui }

    private static func colour(_ c: RGBA) -> (UInt32, Double) {
        func byte(_ x: Double) -> UInt32 { UInt32(min(max(x, 0), 1) * 255 + 0.5) }
        return (byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b), c.a)
    }

    private static func number(_ v: CGFloat) -> String { InspectHand.number(v) }

    /// The colour as it reads (hex), and as a click copies it for the platform.
    private static func colourLine(_ label: String, _ c: RGBA, token: Inspect.Token?, _ p: Inspect.Platform) -> SpecLine {
        var line = SpecLine(label: label, value: Inspect.hex(c), copy: token?.code(p) ?? (p == .css ? Inspect.hex(c) : Inspect.swiftColor(c)))
        line.swatch = colour(c)
        line.token = token?.code(p)
        return line
    }

    public static func inspectSpec(_ id: UUID, platform: InspectPlatform) -> InspectSpec? {
        guard let seen = design, let node = seen.node(id) else { return nil }
        let p: Inspect.Platform = platform == .css ? .css : .swiftui
        let tokens = Inspect.Tokens(seen)
        let path = Inspect.path(of: id, in: seen).map { ($0.id, $0.name) }
        let component = Inspect.component(of: id, in: seen).map { "\($0.master.name) · \($0.variant)" }
        let box = Inspect.box(of: id, in: seen) ?? node.frame
        let size = node.isArtboard || node.rotation == 0 ? box.size : node.frame.size
        let parent = node.isArtboard ? nil : seen.parent(of: id)
        let insets = parent.flatMap { Inspect.box(of: $0.id, in: seen) }.map { Inspect.Insets(of: box, in: $0) }
        let screen = node.isArtboard ? nil : seen.artboard(of: id)

        // The type.
        var font: (String, String, String, String)?
        var type: [SpecLine] = []
        if node.kind == .text {
            let style = node.style ?? TextStyle()
            let token = tokens[style.named]
            font = (style.family == TextStyle.system ? say("System") : style.family, "\(style.face) · \(DesignTokens.weight(style.face))",
                    p == .css ? DesignTokens.fontFamily(style.family) : style.family, "\(DesignTokens.weight(style.face))")
            if let token { type.append(SpecLine(label: say("Style"), value: token.name, copy: token.code(p))) }
            type.append(SpecLine(label: say("Size"), value: number(style.size), copy: p == .css ? Inspect.px(style.size) : number(style.size)))
            if let l = style.lineSpacing {
                type.append(SpecLine(label: say("Line Height"), value: number(l), copy: p == .css ? Inspect.px(l) : number(l)))
            } else {
                let natural = Fonts.naturalLineHeight(style)
                type.append(SpecLine(label: say("Line Height"), value: say("Auto"), copy: number(natural), note: number(natural)))
            }
            if style.tracking != 0 {
                let t = Inspect.tracking(style)
                type.append(SpecLine(label: say("Letter Spacing"), value: number(t),
                                     copy: p == .css ? "\(DesignTokens.number(Double(style.tracking) / 1000, 3))em" : number(t),
                                     note: "\(DesignTokens.number(Double(style.tracking) / 10, 1))%"))
            }
            if style.align != .left {
                type.append(SpecLine(label: say("Align"), value: say(alignTitle(style.align)), copy: p == .css ? style.align.rawValue : alignSwift(style.align)))
            }
            if let c = style.letterCase {
                type.append(SpecLine(label: say("Case"), value: say(caseTitle(c)), copy: p == .css ? caseCSS(c) : caseSwift(c)))
            }
            if let f = node.fills.first {
                if let g = f.gradient, !g.stops.isEmpty {
                    type.append(SpecLine(label: say("Colour"), value: say(g.kind == .linear ? "Linear" : "Radial"),
                                         copy: Inspect.paint(f, size: node.frame.size, tokens: noTokens, platform: p)))
                } else {
                    type.append(colourLine(say("Colour"), f.color, token: tokens[f.named], p))
                }
            }
        }

        // The looks.
        var looks: [SpecLine] = []
        let fills = node.kind == .text ? Array(node.fills.dropFirst()) : Array(node.fills.reversed())
        for f in fills {
            if let image = f.image {
                looks.append(SpecLine(label: say("Fill"), value: image.asset, copy: Inspect.paint(f, size: node.frame.size, tokens: noTokens, platform: p)))
            } else if let g = f.gradient, !g.stops.isEmpty {
                var line = SpecLine(label: say("Fill"), value: say(g.kind == .linear ? "Linear" : "Radial"),
                                    copy: Inspect.paint(f, size: node.frame.size, tokens: noTokens, platform: p))
                line.swatch = g.stops.first.map { colour($0.color) }
                line.token = tokens[f.named]?.code(p)
                looks.append(line)
            } else {
                looks.append(colourLine(say("Fill"), f.color, token: tokens[f.named], p))
            }
        }
        for b in node.borders {
            var line = colourLine(say("Border"), b.gradient?.stops.first?.color ?? b.color, token: tokens[b.named], p)
            line = SpecLine(label: line.label, value: "\(number(b.width)) · \(line.value)", copy: number(b.width), swatch: line.swatch, token: line.token,
                            note: say(b.position == .inside ? "Inside" : b.position == .center ? "Centre" : "Outside"))
            looks.append(line)
        }
        let radii = node.radii
        if node.kind == .rectangle || node.isArtboard, radii.contains(where: { $0 > 0 }) {
            let all = Set(radii).count == 1
            let shown = all ? number(radii[0]) : radii.map(number).joined(separator: " ")
            var line = SpecLine(label: say("Corners"), value: shown, copy: p == .css ? radii.map(Inspect.px).joined(separator: " ") : shown)
            line.token = tokens[node.cornersNamed]?.code(p)
            looks.append(line)
        }
        for s in node.shadows {
            var line = SpecLine(label: say("Shadow"), value: [s.x, s.y, s.blur, s.grown].map(number).joined(separator: " "),
                                copy: Inspect.shadow(s, tokens: noTokens, platform: p))
            line.swatch = colour(s.color)
            line.token = tokens[s.named]?.code(p)
            if s.inset == true { line.note = say("Inside") }
            looks.append(line)
        }
        if node.opacity < 0.999 {
            looks.append(SpecLine(label: say("Opacity"), value: "\(Int((node.opacity * 100).rounded()))%", copy: DesignTokens.number(node.opacity, 2)))
        }
        if let blend = node.blend {
            looks.append(SpecLine(label: say("Blend"), value: blend.title, copy: p == .css ? DesignTokens.kebab(blend.rawValue) : ".\(blend.rawValue)"))
        }
        if let blur = node.blur, blur.on {
            looks.append(SpecLine(label: say("Blur"), value: number(blur.radius), copy: number(blur.radius), note: blur.background ? say("Behind") : nil))
        }

        return InspectSpec(path: path, component: component, size: size, parent: parent?.name,
                           insets: insets.map { [Double($0.top), Double($0.right), Double($0.bottom), Double($0.left)] },
                           x: screen.map { Double(box.minX - $0.frame.minX) }, y: screen.map { Double(box.minY - $0.frame.minY) },
                           rotation: abs(node.rotation) > 0.01 ? node.rotation : nil,
                           font: font.map { (family: $0.0, face: $0.1, copyFamily: $0.2, copyWeight: $0.3) },
                           type: type, words: node.kind == .text ? node.text : nil, looks: looks, isText: node.kind == .text)
    }

    /// The layers from the screen down to this one, by id.
    public static func inspectPath(_ id: UUID) -> [UUID] {
        guard let seen = design else { return [] }
        return Inspect.path(of: id, in: seen).map(\.id)
    }

    /// A layer's name.
    public static func layerName(_ id: UUID) -> String? { design?.node(id)?.name }

    /// The layer written as code for the platform (CSS, or SwiftUI), its looks by the names the design gives them.
    public static func inspectCode(_ id: UUID, platform: InspectPlatform) -> String {
        guard let seen = design, let node = seen.node(id) else { return "" }
        return Inspect.code(node, in: seen, tokens: Inspect.Tokens(seen), for: platform == .css ? .css : .swiftui)
    }

    /// With nothing picked: the design's named colours, and others it uses, as they read and as a
    /// click copies them, as the Mac's Palette card.
    public static func inspectPalette(platform: InspectPlatform) -> [SpecLine] {
        guard let seen = design else { return [] }
        let p: Inspect.Platform = platform == .css ? .css : .swiftui
        let tokens = Inspect.Tokens(seen)
        var out: [SpecLine] = []
        var named: [RGBA] = []
        for style in DesignTokens.styles(seen) where style.kind == .colour {
            guard let c = style.look.paint?.color ?? style.look.paint?.gradient?.stops.first?.color else { continue }
            named.append(c)
            var line = colourLine(style.name, c, token: tokens[style.id], p)
            line = SpecLine(label: style.name, value: line.value, copy: line.copy, swatch: line.swatch, token: line.token)
            out.append(line)
        }
        // Others it uses, the most used first.
        var counts: [String: (RGBA, Int)] = [:]
        func visit(_ n: Node) {
            for f in n.fills where f.on && f.image == nil && f.gradient == nil {
                let key = Inspect.hex(f.color)
                counts[key] = (f.color, (counts[key]?.1 ?? 0) + 1)
            }
            for c in n.children { visit(c) }
        }
        for n in seen.nodes { visit(n) }
        let seenHex = Set(named.map(Inspect.hex))
        for (key, value) in counts.sorted(by: { $0.value.1 > $1.value.1 }).prefix(10) where !seenHex.contains(key) {
            out.append(colourLine("", value.0, token: nil, p))
        }
        return out
    }

    // The Mac's InspectInspector's own words for these (its private extensions).

    private static var noTokens: Inspect.Tokens { Inspect.Tokens(BezzleDocument()) }

    private static func alignTitle(_ a: TextAlign) -> String {
        switch a {
        case .left: "Left"
        case .center: "Centre"
        case .right: "Right"
        case .justify: "Justify"
        }
    }

    private static func alignSwift(_ a: TextAlign) -> String {
        switch a {
        case .left: ".leading"
        case .center: ".center"
        case .right: ".trailing"
        case .justify: ".leading // justified"
        }
    }

    private static func caseTitle(_ c: LetterCase) -> String {
        switch c {
        case .upper: "Uppercase"
        case .lower: "Lowercase"
        case .title: "Title Case"
        case .smallCaps: "Small Caps"
        }
    }

    private static func caseCSS(_ c: LetterCase) -> String {
        switch c {
        case .upper: "uppercase"
        case .lower: "lowercase"
        case .title: "capitalize"
        case .smallCaps: "small-caps"
        }
    }

    private static func caseSwift(_ c: LetterCase) -> String {
        switch c {
        case .upper: ".textCase(.uppercase)"
        case .lower: ".textCase(.lowercase)"
        case .title: ".textCase(nil) // capitalised as typed"
        case .smallCaps: ".font(.body.smallCaps())"
        }
    }
}
