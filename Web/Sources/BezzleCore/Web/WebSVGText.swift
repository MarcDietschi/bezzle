import Foundation
import AppKit

// The parts of SVGWriter each platform has its own of (the Mac's are Bezzle/Export/SVGText.swift),
// for Windows and the browser: text as the page's paragraphs set it (WebText.swift), and pictures
// encoded by the host, which Windows does and the browser's page does not (it writes no files).

nonisolated extension SVGWriter {
    /// Text that stays text: line by line where the canvas sets it, in its font, size and colour,
    /// and letters that look different from the rest in spans of their own; justified lines as
    /// wide as they are set, and the markers of a list's items before them.
    mutating func text(_ node: Node) -> String {
        if let curved = CurvedText.laid(node) { return curvedText(node, curved) }
        let style = node.style ?? TextStyle()
        let laid = TextLayout.layout(node)
        let base = TextLook.plain.resolved(over: style, color: node.letterColor ?? RGBA(r: 0, g: 0, b: 0))
        let down = TextLayout.offset(node)
        let string = laid.string as NSString
        let runs = Self.laidRuns(node, laid.string)
        // As wide as the page sets the lines, which it lines them up in.
        let width = style.sizing == .autoWidth ? TextLayout.naturalWidth(node) + 0.5 : max(node.frame.width, 1)
        var lines: [String] = []
        for line in laid.lines {
            var end = min(line.end, string.length)
            // Without the line's breaks, which draw nothing.
            while end > line.start, let last = Unicode.Scalar(string.character(at: end - 1)), CharacterSet.newlines.contains(last) { end -= 1 }
            guard end > line.start else { continue }
            let range = NSRange(location: line.start, length: end - line.start)
            let within = TextSpan.cut(runs, at: range).within
            var spans = ""
            for run in within {
                let words = Self.escape(run.text)
                let own = Self.letterAttributes(run.look.resolved(over: style, color: base.color), against: base, coloured: node.letterColor != nil)
                spans += own.isEmpty ? words : "<tspan \(own.joined(separator: " "))>\(words)</tspan>"
            }
            // Where the page puts the line: from the left, less half the first letter's spacing,
            // as Skia sets it; or in the middle, or at the right; an item of a list's further in.
            let x: CGFloat
            switch style.align {
            case .center: x = line.indent + (width - line.indent - line.width) / 2
            case .right: x = width - line.width
            case .left, .justify:
                let first = within.first.map { $0.look.resolved(over: style, color: base.color) } ?? base
                x = line.indent - first.tracking / 1000 * first.size / 2
            }
            // A justified line but a paragraph's last is as wide as it is set: spread to the width
            // it is set at, or, one that cannot be spread (Courier without spaces, nothing after
            // its last tab), as wide as its letters, as the Mac writes its used width.
            var stretch = ""
            if style.align == .justify, end < string.length,
               let next = Unicode.Scalar(string.character(at: end)), !CharacterSet.newlines.contains(next) {
                stretch = " textLength=\"\(n(line.width))\" lengthAdjust=\"spacing\""
            }
            // A text of its own each, rather than spans of one: some programs place only the first span.
            lines.append("<text x=\"\(n(x))\" y=\"\(n(line.drawn + down))\"\(stretch)>\(spans)</text>")
        }
        // Each marker in its item's first letters' font and colour, and nothing else of theirs,
        // as the Mac writes it.
        for marker in laid.markers {
            var letters = marker.look.resolved(over: style, color: base.color)
            letters.tracking = base.tracking
            letters.underline = false
            letters.strikethrough = false
            let own = Self.letterAttributes(letters, against: base, coloured: node.letterColor != nil)
            lines.append("<text x=\"\(n(marker.at.x))\" y=\"\(n(marker.at.y + down))\" \(own.joined(separator: " "))>\(Self.escape(marker.text))</text>")
        }
        guard !lines.isEmpty else { return "" }
        var attrs = textAttributes(node, style: style, base: base)
        if style.tracking != 0 { attrs.append("letter-spacing=\"\(n(style.tracking / 1000 * style.size))\"") }
        // A box of fixed size too small for its lines hides what is past its top and bottom.
        if node.overflows {
            let clip = newID("clip")
            let w = node.frame.width
            defs.append("<clipPath id=\"\(clip)\"><rect x=\"\(n(-w))\" width=\"\(n(w * 3))\" height=\"\(n(node.frame.height))\"/></clipPath>")
            attrs.append("clip-path=\"url(#\(clip))\"")
        }
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(lines.joined())</g>"
    }

    /// Words along a curve that stay words: each letter a text of its own, placed and turned
    /// where it lies on the curve, in its colour.
    mutating func curvedText(_ node: Node, _ laid: CurvedText.Laid) -> String {
        let style = node.style ?? TextStyle()
        let base = TextLook.plain.resolved(over: style, color: node.letterColor ?? RGBA(r: 0, g: 0, b: 0))
        // The page sets a letter for each of the words' letters, but where letters join into one.
        let characters = Array(Self.laidRuns(node, nil).map(\.text).joined())
        var letters: [String] = []
        for (k, letter) in laid.letters.enumerated() where k < characters.count {
            let drawn = String(characters[k])
            guard !drawn.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var own: [String] = []
            if letter.own, node.letterColor != nil, let c = letter.color.components, c.count >= 3 {
                let rgba = RGBA(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]), a: Double(c.count > 3 ? c[3] : 1))
                if rgba.hex != base.color.hex || abs(rgba.a - base.color.a) > 0.002 {
                    own.append("fill=\"#\(rgba.hex)\"" + (rgba.a < 1 ? " fill-opacity=\"\(n(rgba.a))\"" : ""))
                }
            }
            // Its own space has y running down, as the layer's.
            let m = letter.place
            let place = "transform=\"matrix(\(n(m.a)) \(n(m.b)) \(n(m.c)) \(n(m.d)) \(n(m.tx)) \(n(m.ty)))\""
            letters.append("<text \(([place] + own).joined(separator: " "))>\(Self.escape(drawn))</text>")
        }
        guard !letters.isEmpty else { return "" }
        let attrs = textAttributes(node, style: style, base: base)
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(letters.joined())</g>"
    }

    /// What every letter of a text has unless it says otherwise: its family, size, weight,
    /// slant, lines through or under it, and its colour, gradient or picture.
    private mutating func textAttributes(_ node: Node, style: TextStyle, base: Letters) -> [String] {
        var attrs = ["font-family=\"\(Self.escape(Self.family(style.family)))\"", "font-size=\"\(n(style.size))\""]
        let traits = Fonts.traits(of: base.face, in: base.family)
        let weight = Self.cssWeight(traits.weight)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if traits.italic { attrs.append("font-style=\"italic\"") }
        let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { attrs.append("text-decoration=\"\(decorations.joined(separator: " "))\"") }
        if node.fill.on, node.fill.paints {
            // Letters of the text's own colour painted with its gradient or picture.
            let (fill, opacity) = ink(node.fill, size: node.frame.size, box: Renderer.ink(of: node))
            attrs.append("fill=\"\(fill)\"" + (opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""))
        } else {
            attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        }
        return attrs
    }

    /// The text's runs over its words as the page lays them (`laid`, in the letter case asked
    /// for), each its look; the words as typed when the case changes their length.
    private static func laidRuns(_ node: Node, _ laid: String?) -> [TextSpan] {
        let runs = node.runs
        guard let laid, laid != runs.map(\.text).joined() else { return runs }
        guard TextSpan.length(of: runs) == (laid as NSString).length else { return [TextSpan(text: laid, look: runs.first?.look ?? .plain)] }
        var at = 0
        let all = laid as NSString
        return runs.map { run in
            let n = (run.text as NSString).length
            defer { at += n }
            return TextSpan(text: all.substring(with: NSRange(location: at, length: n)), look: run.look)
        }
    }

    /// What about some letters differs from the text they are in, as SVG says it.
    private static func letterAttributes(_ letters: Letters, against base: Letters, coloured: Bool) -> [String] {
        var out: [String] = []
        if letters.family != base.family { out.append("font-family=\"\(escape(family(letters.family)))\"") }
        if letters.size != base.size { out.append("font-size=\"\(n(letters.size))\"") }
        let mine = Fonts.traits(of: letters.face, in: letters.family), theirs = Fonts.traits(of: base.face, in: base.family)
        if cssWeight(mine.weight) != cssWeight(theirs.weight) { out.append("font-weight=\"\(cssWeight(mine.weight))\"") }
        if mine.italic != theirs.italic { out.append("font-style=\"\(mine.italic ? "italic" : "normal")\"") }
        let kern = letters.tracking / 1000 * letters.size
        if abs(kern - base.tracking / 1000 * letters.size) > 0.01 { out.append("letter-spacing=\"\(n(kern))\"") }
        if coloured, letters.color.hex != base.color.hex || abs(letters.color.a - base.color.a) > 0.002 {
            let a = letters.color.a
            out.append("fill=\"#\(letters.color.hex)\"" + (a < 1 ? " fill-opacity=\"\(n(a))\"" : ""))
        }
        if letters.underline != base.underline || letters.strikethrough != base.strikethrough {
            let marks = [letters.underline ? "underline" : nil, letters.strikethrough ? "line-through" : nil].compactMap { $0 }
            out.append("text-decoration=\"\(marks.isEmpty ? "none" : marks.joined(separator: " "))\"")
        }
        return out
    }

    /// The family the design asks for first, for whoever has it, then something like it everyone has.
    private static func family(_ family: String) -> String {
        let name = family == TextStyle.system ? "SF Pro" : family
        return (["'\(name.replacingOccurrences(of: "'", with: ""))'", "-apple-system", "'Segoe UI'", "'Helvetica Neue'", "sans-serif"]).joined(separator: ", ")
    }

    /// A weight as CSS counts it, from the Mac's own scale of 0 to 15, where 5 is regular and 9 bold.
    private static func cssWeight(_ weight: Int) -> Int {
        switch weight {
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

    /// A picture as a PNG file, which the host makes; none from the browser's page.
    static func png(_ image: CGImage) -> Data? { encoded(image, format: 0, quality: 1) }

    /// A picture as a JPEG file, `quality` from 0 to 1.
    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? { encoded(image, format: 1, quality: Double(quality)) }

    private static func encoded(_ image: CGImage, format: Double, quality: Double) -> Data? {
        let ask = [Double(image.id), Double(image.width), Double(image.height), format, quality]
        let bytes = ask.withUnsafeBytes { Array($0) }
        let out = Host.call(.encodePicture, bytes: bytes)
        return out.isEmpty ? nil : Data(out)
    }
}

/// A number as SVG writes it; one for CGFloat and Double alike, which are one type on Windows and in the browser.
nonisolated private func n<V: BinaryFloatingPoint>(_ v: V) -> String { PathData.number(CGFloat(v)) }
