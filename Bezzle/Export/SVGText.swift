import AppKit

// The parts of SVGWriter that ask the Mac: text as Text Kit sets it, and pictures as AppKit
// encodes them. Windows and the browser have their own (Web/Sources/BezzleCore/Web/WebSVGText.swift).

nonisolated extension SVGWriter {
    /// Text that stays text: line by line where the canvas sets it, in its font, size and colour,
    /// and letters that look different from the rest in spans of their own; justified lines as
    /// wide as they are set, and the markers of a list's items before them.
    mutating func text(_ node: Node) -> String {
        if let curved = CurvedText.laid(node) { return curvedText(node, curved) }
        let style = node.style ?? TextStyle()
        let laid = TextLayout.layout(node)
        let font = Fonts.font(style)
        let storage = laid.storage
        let string = storage.string as NSString
        let down = TextLayout.offset(node)
        // As the letters are laid out: painted ones are solid, to be painted through.
        let baseColor = node.letterColor
        var lines: [String] = []
        laid.manager.enumerateLineFragments(forGlyphRange: laid.manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            var characters = laid.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // Without the line's breaks, which draw nothing.
            while characters.length > 0, let last = Unicode.Scalar(string.character(at: NSMaxRange(characters) - 1)),
                  CharacterSet.newlines.contains(last) { characters.length -= 1 }
            guard characters.length > 0 else { return }
            let at = laid.manager.location(forGlyphAt: glyphs.location)
            var spans = ""
            storage.enumerateAttributes(in: characters) { attrs, range, _ in
                let words = Self.escape(string.substring(with: range))
                let own = Self.letterAttributes(attrs, against: font, style: style, color: baseColor)
                spans += own.isEmpty ? words : "<tspan \(own.joined(separator: " "))>\(words)</tspan>"
            }
            // A justified line but a paragraph's last is spread to the width it is set at.
            var stretch = ""
            if style.align == .justify, NSMaxRange(characters) < string.length,
               let next = Unicode.Scalar(string.character(at: NSMaxRange(characters))), !CharacterSet.newlines.contains(next) {
                stretch = " textLength=\"\(n(used.width - at.x + used.minX - rect.minX))\" lengthAdjust=\"spacing\""
            }
            // A text of its own each, rather than spans of one: some programs place only the first span.
            lines.append("<text x=\"\(n(rect.minX + at.x))\" y=\"\(n(rect.minY + at.y + down))\"\(stretch)>\(spans)</text>")
        }
        for marker in TextLayout.markers(laid.manager) {
            let own = Self.letterAttributes([.font: marker.font, .foregroundColor: marker.color], against: font, style: style, color: baseColor)
            lines.append("<text x=\"\(n(marker.at.x))\" y=\"\(n(marker.at.y + down))\" \(own.joined(separator: " "))>\(Self.escape(marker.text))</text>")
        }
        guard !lines.isEmpty else { return "" }
        var attrs = ["font-family=\"\(Self.escape(Self.family(of: font, style: style)))\"", "font-size=\"\(n(style.size))\""]
        let weight = Self.weight(of: font)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { attrs.append("font-style=\"italic\"") }
        if style.tracking != 0 { attrs.append("letter-spacing=\"\(n(style.tracking / 1000 * style.size))\"") }
        let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { attrs.append("text-decoration=\"\(decorations.joined(separator: " "))\"") }
        if node.fill.on, node.fill.paints {
            // Letters of the text's own colour painted with its gradient or picture.
            let (fill, opacity) = ink(node.fill, size: node.frame.size, box: Renderer.ink(of: node))
            attrs.append("fill=\"\(fill)\"" + (opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""))
        } else {
            attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        }
        // A box of fixed size too small for its lines hides what is past its top and bottom.
        if node.overflows {
            let clip = newID("clip")
            let w = node.frame.width
            defs.append("<clipPath id=\"\(clip)\"><rect x=\"\(n(-w))\" width=\"\(n(w * 3))\" height=\"\(n(node.frame.height))\"/></clipPath>")
            attrs.append("clip-path=\"url(#\(clip))\"")
        }
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(lines.joined())</g>"
    }

    /// What about some letters differs from the text they are in, as SVG says it.
    static func letterAttributes(_ attrs: [NSAttributedString.Key: Any], against font: NSFont, style: TextStyle, color base: RGBA?) -> [String] {
        var out: [String] = []
        if let f = attrs[.font] as? NSFont, f != font {
            if f.familyName != font.familyName || f.fontName.hasPrefix(".") != font.fontName.hasPrefix(".") {
                var s = style
                s.family = f.familyName.map { $0.hasPrefix(".") ? TextStyle.system : $0 } ?? style.family
                out.append("font-family=\"\(escape(family(of: f, style: s)))\"")
            }
            if f.pointSize != font.pointSize { out.append("font-size=\"\(n(f.pointSize))\"") }
            let w = weight(of: f)
            if w != weight(of: font) { out.append("font-weight=\"\(w)\"") }
            let italic = f.fontDescriptor.symbolicTraits.contains(.italic)
            if italic != font.fontDescriptor.symbolicTraits.contains(.italic) { out.append("font-style=\"\(italic ? "italic" : "normal")\"") }
            if let kern = attrs[.kern] as? CGFloat, abs(kern - style.tracking / 1000 * f.pointSize) > 0.01 { out.append("letter-spacing=\"\(n(kern))\"") }
        } else if let kern = attrs[.kern] as? CGFloat, abs(kern - style.tracking / 1000 * style.size) > 0.01 {
            out.append("letter-spacing=\"\(n(kern))\"")
        }
        if let c = attrs[.foregroundColor] as? NSColor, let base {
            let rgba = RGBA(c)
            if rgba.hex != base.hex || abs(rgba.a - base.a) > 0.002 {
                let a = rgba.a
                out.append("fill=\"#\(rgba.hex)\"" + (a < 1 ? " fill-opacity=\"\(n(a))\"" : ""))
            }
        }
        let under = (attrs[.underlineStyle] as? Int ?? 0) != 0, through = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        if under != style.underline || through != (style.strikethrough == true) {
            let marks = [under ? "underline" : nil, through ? "line-through" : nil].compactMap { $0 }
            out.append("text-decoration=\"\(marks.isEmpty ? "none" : marks.joined(separator: " "))\"")
        }
        return out
    }

    /// The family the design asks for first, for whoever has it, then the face drawn here by its
    /// exact name and its family, then something like it everyone has.
    static func family(of font: NSFont, style: TextStyle) -> String {
        var names: [String] = []
        if style.family != TextStyle.system { names.append(style.family) }
        // The Mac's own face goes by private names; elsewhere it is SF Pro, or the system's.
        if let family = font.familyName, !family.hasPrefix("."), !font.fontName.hasPrefix(".") {
            names += [font.fontName, family]
        } else {
            names.append("SF Pro")
        }
        var seen = Set<String>()
        let quoted = names.filter { seen.insert($0).inserted }.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }
        return (quoted + ["-apple-system", "'Helvetica Neue'", "sans-serif"]).joined(separator: ", ")
    }

    /// The font's weight as CSS counts it, from the Mac's own scale of 0 to 15, where 5 is regular and 9 bold.
    static func weight(of font: NSFont) -> Int {
        switch NSFontManager.shared.weight(of: font) {
        case ...2: 100
        case 3: 200
        case 4: 300
        case 5: 400
        case 6: 500
        case 7, 8: 600
        case 9: 700
        case 10: 800
        default: 900
        }
    }

    /// Words along a curve that stay words: each letter a text of its own, placed and turned
    /// where it lies on the curve, in its font, size and colour.
    mutating func curvedText(_ node: Node, _ laid: CurvedText.Laid) -> String {
        let style = node.style ?? TextStyle()
        let font = Fonts.font(style)
        let words = CurvedText.words(of: node)
        let string = words.string as NSString
        let baseColor = node.letterColor
        var letters: [String] = []
        for letter in laid.letters where NSMaxRange(letter.characters) <= string.length {
            let drawn = string.substring(with: letter.characters)
            guard !drawn.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let attrs = words.attributes(at: letter.characters.location, effectiveRange: nil)
            let own = Self.letterAttributes(attrs, against: font, style: style, color: baseColor)
            // SVG sets letters with y running down, as the layer has it.
            let m = CGAffineTransform(scaleX: 1, y: -1).concatenating(letter.place)
            let place = "transform=\"matrix(\(n(m.a)) \(n(m.b)) \(n(m.c)) \(n(m.d)) \(n(m.tx)) \(n(m.ty)))\""
            letters.append("<text \(([place] + own).joined(separator: " "))>\(Self.escape(drawn))</text>")
        }
        guard !letters.isEmpty else { return "" }
        var attrs = ["font-family=\"\(Self.escape(Self.family(of: font, style: style)))\"", "font-size=\"\(n(style.size))\""]
        let weight = Self.weight(of: font)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { attrs.append("font-style=\"italic\"") }
        let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { attrs.append("text-decoration=\"\(decorations.joined(separator: " "))\"") }
        if node.fill.on, node.fill.paints {
            let (fill, opacity) = ink(node.fill, size: node.frame.size, box: Renderer.ink(of: node))
            attrs.append("fill=\"\(fill)\"" + (opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""))
        } else {
            attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        }
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(letters.joined())</g>"
    }

    /// A picture as a PNG file.
    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A picture as a JPEG file, `quality` from 0 to 1.
    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

nonisolated private func n(_ v: CGFloat) -> String { PathData.number(v) }
nonisolated private func n(_ v: Double) -> String { PathData.number(CGFloat(v)) }
