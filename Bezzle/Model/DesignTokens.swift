import Foundation
import CoreGraphics

/// The design's named looks (`Style`) written out for code: CSS custom properties, SwiftUI
/// constants, and the W3C design tokens format as JSON. Each style's dark look goes with it
/// wherever the design has dark artboards or a dark look was made.
nonisolated enum DesignTokens {
    enum Format: String, CaseIterable {
        case css, swiftui, json
    }

    static func write(_ doc: BezzleDocument, named name: String, as format: Format) -> String {
        switch format {
        case .css: css(doc, named: name)
        case .swiftui: swiftUI(doc, named: name)
        case .json: json(doc)
        }
    }

    /// The styles in the order the design lists them, kind by kind.
    static func styles(_ doc: BezzleDocument) -> [Style] {
        let kinds = StyleKind.allCases
        return (doc.styles ?? []).sorted {
            let a = kinds.firstIndex(of: $0.kind) ?? 0, b = kinds.firstIndex(of: $1.kind) ?? 0
            return a != b ? a < b : $0.rank < $1.rank
        }
    }

    /// Whether the design is seen dark anywhere, so the styles' dark looks go out too.
    static func hasDark(_ doc: BezzleDocument) -> Bool {
        doc.artboards.contains { $0.dark == true } || (doc.styles ?? []).contains { $0.dark != nil }
    }

    // MARK: Names

    static func words(_ name: String) -> [String] {
        let folded = name.folding(options: [.diacriticInsensitive], locale: nil)
        var out: [String] = [], word = ""
        var lastLower = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                // "darkBlue" is two words.
                if ch.isUppercase, lastLower, !word.isEmpty { out.append(word); word = "" }
                word.append(ch)
                lastLower = ch.isLowercase
            } else {
                if !word.isEmpty { out.append(word); word = "" }
                lastLower = false
            }
        }
        if !word.isEmpty { out.append(word) }
        return out.map { $0.lowercased() }
    }

    static func kebab(_ name: String) -> String {
        let w = words(name)
        return w.isEmpty ? "style" : w.joined(separator: "-")
    }

    static func camel(_ name: String) -> String {
        let w = words(name)
        guard let first = w.first else { return "style" }
        var s = first + w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if s.first?.isNumber == true { s = "_" + s }
        let reserved: Set<String> = ["default", "class", "struct", "enum", "let", "var", "func", "init", "self", "case", "in", "is", "as", "if", "for", "return", "static", "extension", "protocol", "import", "operator", "where", "while", "repeat", "switch", "true", "false", "nil", "primary", "secondary", "accentColor", "clear", "white", "black"]
        return reserved.contains(s) ? "`\(s)`" : s
    }

    /// Names made unique within one kind: "Blue", "Blue 2".
    static func unique(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { n in
            let k = n.lowercased()
            seen[k, default: 0] += 1
            return seen[k]! > 1 ? "\(n) \(seen[k]!)" : n
        }
    }

    // MARK: Values

    static func hex(_ c: RGBA) -> String {
        c.a >= 0.999 ? "#\(c.hex)" : String(format: "rgba(%d, %d, %d, %@)", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()), number(c.a, 3))
    }

    static func number(_ x: Double, _ places: Int = 2) -> String {
        let p = pow(10, Double(places))
        let r = (x * p).rounded() / p
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.\(places)f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func number(_ x: CGFloat, _ places: Int = 2) -> String { number(Double(x), places) }

    /// How heavy a face is, from its name, as CSS counts it.
    static func weight(_ face: String) -> Int {
        let f = face.lowercased().replacingOccurrences(of: " ", with: "")
        if f.contains("thin") || f.contains("hairline") { return 100 }
        if f.contains("extralight") || f.contains("ultralight") { return 200 }
        if f.contains("light") { return 300 }
        if f.contains("medium") { return 500 }
        if f.contains("semibold") || f.contains("demibold") { return 600 }
        if f.contains("extrabold") || f.contains("ultrabold") { return 800 }
        if f.contains("black") || f.contains("heavy") { return 900 }
        if f.contains("bold") { return 700 }
        return 400
    }

    static func italic(_ face: String) -> Bool { face.lowercased().contains("italic") || face.lowercased().contains("oblique") }

    static func cssGradient(_ g: Gradient) -> String {
        let stops = g.stops.sorted { $0.offset < $1.offset }.map { "\(hex($0.color)) \(number($0.offset * 100, 1))%" }.joined(separator: ", ")
        switch g.kind {
        case .linear:
            let dx = g.end.x - g.start.x, dy = g.end.y - g.start.y
            // CSS measures from the top, turning clockwise; y points down here as it does there.
            let degrees = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return "linear-gradient(\(number(Double(degrees), 1))deg, \(stops))"
        case .radial:
            return "radial-gradient(circle at \(number(g.start.x * 100, 1))% \(number(g.start.y * 100, 1))%, \(stops))"
        }
    }

    static func cssShadow(_ s: Shadow) -> String {
        let parts = "\(number(s.x))px \(number(s.y))px \(number(s.blur))px\(s.spread.map { " \(number($0))px" } ?? "") \(hex(s.color))"
        return s.inset == true ? "inset " + parts : parts
    }

    static func fontFamily(_ family: String) -> String {
        family == TextStyle.system ? "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif" : "\"\(family)\", sans-serif"
    }

    // MARK: CSS

    static func css(_ doc: BezzleDocument, named design: String) -> String {
        let all = styles(doc)
        guard !all.isEmpty else { return "/* \(design) has no named styles yet. Give a colour, a type, a shadow or corners a name in Bezzle. */\n" }
        let dark = hasDark(doc)
        var root: [String] = [], night: [String] = [], classes: [String] = []
        for kind in StyleKind.allCases {
            let of = all.filter { $0.kind == kind }
            guard !of.isEmpty else { continue }
            let names = unique(of.map(\.name))
            root.append("  /* \(kind.tokenTitle) */")
            for (style, name) in zip(of, names) {
                let k = kebab(name)
                let lines = cssLines(style.look, key: k)
                root += lines
                if dark {
                    let d = cssLines(style.look(dark: true), key: k)
                    if d != lines { night += d.map { "  " + $0 } }
                }
                if case .text(let t) = style.look {
                    classes.append(".text-\(k) {\n  font-family: var(--font-\(k)-family);\n  font-size: var(--font-\(k)-size);\n  font-weight: var(--font-\(k)-weight);\(t.lineSpacing != nil ? "\n  line-height: var(--font-\(k)-line-height);" : "")\n  letter-spacing: var(--font-\(k)-letter-spacing);\(italic(t.face) ? "\n  font-style: italic;" : "")\(t.letterCase.map { "\n  " + cssCase($0) } ?? "")\n}")
                }
            }
        }
        var out = "/* Design tokens from \(design), written by Bezzle. */\n:root {\n" + root.joined(separator: "\n") + "\n}\n"
        if !night.isEmpty {
            out += "\n@media (prefers-color-scheme: dark) {\n  :root {\n" + night.joined(separator: "\n") + "\n  }\n}\n"
        }
        if !classes.isEmpty { out += "\n" + classes.joined(separator: "\n\n") + "\n" }
        return out
    }

    private static func cssCase(_ c: LetterCase) -> String {
        switch c {
        case .upper: "text-transform: uppercase;"
        case .lower: "text-transform: lowercase;"
        case .title: "text-transform: capitalize;"
        case .smallCaps: "font-variant-caps: small-caps;"
        }
    }

    private static func cssLines(_ look: StyleLook, key k: String) -> [String] {
        switch look {
        case .colour(let c):
            if let g = c.gradient, !g.stops.isEmpty { return ["  --gradient-\(k): \(cssGradient(g));"] }
            return ["  --color-\(k): \(hex(c.color));"]
        case .text(let t):
            var lines = ["  --font-\(k)-family: \(fontFamily(t.family));",
                         "  --font-\(k)-size: \(number(t.size))px;",
                         "  --font-\(k)-weight: \(weight(t.face));"]
            if let l = t.lineSpacing { lines.append("  --font-\(k)-line-height: \(number(l))px;") }
            lines.append("  --font-\(k)-letter-spacing: \(number(Double(t.tracking) / 1000, 3))em;")
            return lines
        case .shadow(let s):
            return ["  --shadow-\(k): \(cssShadow(s));"]
        case .corners(let c):
            return ["  --radius-\(k): \(number(c.radius))px;"]
        }
    }

    // MARK: SwiftUI

    static func swiftUI(_ doc: BezzleDocument, named design: String) -> String {
        let all = styles(doc)
        guard !all.isEmpty else { return "// \(design) has no named styles yet. Give a colour, a type, a shadow or corners a name in Bezzle.\n" }
        let dark = hasDark(doc)
        func color(_ c: RGBA) -> String {
            "Color(.sRGB, red: \(number(c.r, 3)), green: \(number(c.g, 3)), blue: \(number(c.b, 3)), opacity: \(number(c.a, 3)))"
        }
        var colours: [String] = [], gradients: [String] = [], type: [String] = [], shadows: [String] = [], corners: [String] = []
        for kind in StyleKind.allCases {
            let of = all.filter { $0.kind == kind }
            for (style, name) in zip(of, unique(of.map(\.name))) {
                let n = camel(name)
                let light = style.look, night = style.look(dark: true)
                switch light {
                case .colour(let c):
                    if let g = c.gradient, !g.stops.isEmpty {
                        let stops = g.stops.sorted { $0.offset < $1.offset }.map { ".init(color: \(color($0.color)), location: \(number($0.offset, 3)))" }.joined(separator: ", ")
                        switch g.kind {
                        case .linear:
                            gradients.append("        static let \(n) = LinearGradient(stops: [\(stops)], startPoint: UnitPoint(x: \(number(g.start.x, 3)), y: \(number(g.start.y, 3))), endPoint: UnitPoint(x: \(number(g.end.x, 3)), y: \(number(g.end.y, 3))))")
                        case .radial:
                            gradients.append("        static let \(n) = RadialGradient(stops: [\(stops)], center: UnitPoint(x: \(number(g.start.x, 3)), y: \(number(g.start.y, 3))), startRadius: 0, endRadius: 200)")
                        }
                    } else if dark, case .colour(let d) = night, d.color != c.color {
                        colours.append("        static let \(n) = Color(light: \(color(c.color)), dark: \(color(d.color)))")
                    } else {
                        colours.append("        static let \(n) = \(color(c.color))")
                    }
                case .text(let t):
                    let w: String = switch weight(t.face) {
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
                    let font = t.family == TextStyle.system
                        ? "Font.system(size: \(number(t.size)), weight: \(w))"
                        : "Font.custom(\"\(t.family)\", size: \(number(t.size))).weight(\(w))"
                    let lineSpacing = t.lineSpacing.map { number(max(0, $0 - t.size * 1.2)) } ?? "0"
                    type.append("        static let \(n) = TypeToken(font: \(font)\(italic(t.face) ? ".italic()" : ""), size: \(number(t.size)), lineSpacing: \(lineSpacing), tracking: \(number(Double(t.tracking) / 1000 * Double(t.size), 2)))")
                case .shadow(let s):
                    shadows.append("        static let \(n) = ShadowToken(color: \(color(s.color)), radius: \(number(s.blur / 2)), x: \(number(s.x)), y: \(number(s.y)))")
                case .corners(let c):
                    corners.append("        static let \(n): CGFloat = \(number(c.radius))")
                }
            }
        }
        var out = "// Design tokens from \(design), written by Bezzle.\nimport SwiftUI\n\nenum Tokens {\n"
        func section(_ name: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += "    enum \(name) {\n" + lines.joined(separator: "\n") + "\n    }\n\n"
        }
        section("Colors", colours)
        section("Gradients", gradients)
        section("Type", type)
        section("Shadows", shadows)
        section("Corners", corners)
        if out.hasSuffix("\n\n") { out.removeLast() }
        out += "}\n"
        if !type.isEmpty {
            out += """

            struct TypeToken {
                let font: Font
                let size: CGFloat
                /// Added between lines, past the font's own.
                let lineSpacing: CGFloat
                let tracking: CGFloat
            }

            extension View {
                func typeToken(_ t: TypeToken) -> some View {
                    font(t.font).lineSpacing(t.lineSpacing).tracking(t.tracking)
                }
            }

            """
        }
        if !shadows.isEmpty {
            out += """

            struct ShadowToken {
                let color: Color
                let radius: CGFloat
                let x: CGFloat
                let y: CGFloat
            }

            extension View {
                func shadowToken(_ s: ShadowToken) -> some View {
                    shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
                }
            }

            """
        }
        if colours.contains(where: { $0.contains("Color(light:") }) {
            out += """

            extension Color {
                /// One colour in the light and another in the dark.
                init(light: Color, dark: Color) {
                    #if canImport(UIKit)
                    self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
                    #else
                    self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
                    #endif
                }
            }

            """
        }
        return out
    }

    // MARK: JSON

    /// The W3C Design Tokens Community Group format.
    static func json(_ doc: BezzleDocument) -> String {
        let all = styles(doc)
        let dark = hasDark(doc)
        var groups: [(String, [(String, Any)])] = []
        for kind in StyleKind.allCases {
            let of = all.filter { $0.kind == kind }
            guard !of.isEmpty else { continue }
            var entries: [(String, Any)] = []
            for (style, name) in zip(of, unique(of.map(\.name))) {
                var token = jsonToken(style.look)
                if dark {
                    let d = jsonToken(style.look(dark: true))
                    if (d["$value"] as? NSObject) != (token["$value"] as? NSObject) { token["$extensions"] = ["com.bezzle.dark": d["$value"] as Any] }
                }
                token["$description"] = name
                entries.append((kebab(name), token))
            }
            groups.append((kind.jsonGroup, entries))
        }
        var root: [String: Any] = [:]
        for (g, entries) in groups { root[g] = Dictionary(entries, uniquingKeysWith: { a, _ in a }) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func jsonToken(_ look: StyleLook) -> [String: Any] {
        switch look {
        case .colour(let c):
            if let g = c.gradient, !g.stops.isEmpty {
                return ["$type": "gradient", "$value": g.stops.sorted { $0.offset < $1.offset }.map { ["color": hex($0.color), "position": $0.offset] }]
            }
            return ["$type": "color", "$value": hex(c.color)]
        case .text(let t):
            var v: [String: Any] = ["fontFamily": t.family == TextStyle.system ? "system-ui" : t.family, "fontSize": "\(number(t.size))px",
                                    "fontWeight": weight(t.face), "letterSpacing": "\(number(Double(t.tracking) / 1000, 3))em"]
            if let l = t.lineSpacing { v["lineHeight"] = "\(number(l))px" }
            return ["$type": "typography", "$value": v]
        case .shadow(let s):
            return ["$type": "shadow", "$value": ["color": hex(s.color), "offsetX": "\(number(s.x))px", "offsetY": "\(number(s.y))px",
                                                   "blur": "\(number(s.blur))px", "spread": "\(number(s.spread ?? 0))px", "inset": s.inset == true]]
        case .corners(let c):
            return ["$type": "dimension", "$value": "\(number(c.radius))px"]
        }
    }

    /// How many tokens the design has.
    static func count(_ doc: BezzleDocument) -> Int { doc.styles?.count ?? 0 }
}

nonisolated extension StyleKind {
    var tokenTitle: String {
        switch self {
        case .colour: "Colours"
        case .text: "Type"
        case .shadow: "Shadows"
        case .corners: "Corners"
        }
    }

    var jsonGroup: String {
        switch self {
        case .colour: "color"
        case .text: "typography"
        case .shadow: "shadow"
        case .corners: "radius"
        }
    }
}
