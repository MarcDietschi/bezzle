import Foundation
import AppKit

// Text in the browser: the same questions the Mac's TextLayout answers (how wide, how tall,
// where the lines break, where the first baseline is), answered by Skia's paragraphs in the page
// instead of Text Kit. Skia breaks the lines and shapes their letters; where each line sits is
// worked out here, the way Text Kit places it (see `place`), from the Mac's own fonts' measures
// where they are known (MacFonts.swift), so a design measures alike on both, whatever fonts stand
// in for the Mac's here.

nonisolated enum Fonts {
    static let systemFaces = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]

    static var families: [String] { [TextStyle.system] + NSFontManager.shared.availableFontFamilies }

    static func faces(of family: String) -> [String] {
        if family == TextStyle.system { return systemFaces.flatMap { [$0, "\($0) Italic"] } }
        return NSFontManager.shared.families[family] ?? []
    }

    static func displayName(_ family: String) -> String { family == TextStyle.system ? "SF Pro" : family }

    /// How heavy a face is and whether it leans, as the Mac's font manager counts weight (5
    /// regular, 9 bold): here read from the face's name, the open fonts' faces being named as
    /// the Mac's are.
    static func traits(of face: String, in family: String) -> (weight: Int, italic: Bool) {
        traits(named: face)
    }

    nonisolated(unsafe) static var lineHeights: [String: CGFloat] = [:]

    /// The font's own line height, which a text has until one is set: its ascent, descent and
    /// leading, rounded up, as the Mac measures it.
    static func naturalLineHeight(_ style: TextStyle) -> CGFloat {
        let key = "\(style.family)/\(style.face)/\(style.size)"
        if let known = lineHeights[key] { return known }
        var s = style
        s.lineSpacing = nil
        var probe = Node(kind: .text, name: "", frame: .zero)
        probe.text = "A"
        probe.style = s
        probe.spans = nil
        let height = TextLayout.ownLineHeight(probe)
        lineHeights[key] = height
        return height
    }
}

nonisolated enum TextLayout {
    /// One line as laid: its letters in the words as laid (UTF-16), and where it lies, from the text's top.
    struct Line: Hashable {
        var start: Int, end: Int
        var top: CGFloat, height: CGFloat
        var width: CGFloat
        /// Where Text Kit says the baseline is, from the text's top.
        var baseline: CGFloat
        /// Where the letters are drawn on it: raised or lowered as lines set apart are.
        var drawn: CGFloat
    }

    final class Laid: @unchecked Sendable {
        /// The page's paragraphs, one per line, by number.
        let id: Int
        let lines: [Line]
        let usedSize: CGSize
        /// The words as laid: in the letter case asked for.
        let string: String

        init(id: Int, lines: [Line], usedSize: CGSize, string: String) {
            self.id = id
            self.lines = lines
            self.usedSize = usedSize
            self.string = string
        }

        /// Draws with the text's top left at `origin`, y down, into the context the renderer made current.
        func draw(at origin: CGPoint, painting: ((CGContext) -> Void)? = nil) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.drawText(id, at: origin, color: nil)
        }
    }

    private struct Key: Hashable {
        let text: String
        let spans: [TextSpan]?
        let style: TextStyle
        let color: RGBA?
        let width: CGFloat?
    }

    nonisolated(unsafe) private static var kept: [Key: Laid] = [:]

    /// Forgets every text set so far, as when the page has fonts it had not: each is set again.
    static func forget() {
        kept = [:]
        Fonts.lineHeights = [:]
        CurvedText.forget()
    }

    /// How far the letters are raised in lines set further apart than the font's own, as on the Mac.
    private static func lift(_ style: TextStyle, natural: CGFloat) -> CGFloat {
        guard let spacing = style.lineSpacing, spacing > 0 else { return 0 }
        return (spacing - natural) / 2
    }

    /// The runs of a text, as the page sets them: each with its own look over the text's style.
    static func runs(_ node: Node) -> [[String: Any]] {
        let style = node.style ?? TextStyle()
        let color = node.letterColor
        var runs = node.runs
        var texts = runs.map(\.text)
        if let letterCase = style.letterCase, letterCase != .smallCaps {
            let whole = texts.joined(), set = letterCase.apply(whole)
            if set.utf16.count == whole.utf16.count {
                var at = set.utf16.startIndex
                texts = texts.map { t in
                    let end = set.utf16.index(at, offsetBy: t.utf16.count)
                    defer { at = end }
                    return String(set.utf16[at..<end]) ?? t
                }
            } else {
                texts = texts.map(letterCase.apply)
            }
        }
        if runs.isEmpty { runs = [TextSpan(text: "")]; texts = [""] }
        // The layer's OpenType features (small capitals among them) and its font's axes, as
        // "tag=value" lists, as the Mac's Fonts.font sets them.
        var wanted = style.features ?? [:]
        if style.letterCase == .smallCaps, wanted["smcp"] == nil { wanted["smcp"] = 1 }
        let axes = (style.axes ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return zip(runs, texts).map { run, text in
            let letters = run.look.resolved(over: style, color: color ?? .black)
            // The Mac always sets letters' spacing (Text Kit's kern), and set to nought, Core Text
            // leaves out the font's own kerning between pairs such as "Te"; set to anything else,
            // it keeps it. Said here, as the letters' spacing below also has what makes a
            // stand-in as wide as the Mac's face.
            var own = wanted
            if letters.tracking == 0, own["kern"] == nil { own["kern"] = 0 }
            let features = own.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            let spacing = letters.tracking / 1000 * letters.size + MacFonts.spacing(family: letters.family, face: letters.face, size: letters.size)
            var r: [String: Any] = [
                "text": text, "family": letters.family, "face": letters.face, "size": Double(letters.size),
                "tracking": Double(spacing),
                "underline": letters.underline, "strike": letters.strikethrough,
            ]
            if color != nil { r["color"] = [letters.color.r, letters.color.g, letters.color.b, letters.color.a] }
            if !features.isEmpty { r["features"] = features }
            if !axes.isEmpty { r["axes"] = axes }
            return r
        }
    }

    private static func lay(_ node: Node, width: CGFloat) -> Laid {
        let style = node.style ?? TextStyle()
        let runs = runs(node)
        let spec: [String: Any] = [
            "width": Double(width), "align": style.align.rawValue,
            "lineSpacing": Double(style.lineSpacing ?? 0), "paragraphSpacing": Double(style.paragraphSpacing ?? 0),
            "runs": runs,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: spec)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let answer = Host.call(.textLayout, string: json)
        guard let data = answer.data(using: .utf8), let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Laid(id: 0, lines: [], usedSize: .zero, string: "")
        }
        let id = reply["id"] as? Int ?? 0
        let metrics = (reply["lines"] as? [[Double]]) ?? []
        let string = runs.compactMap { $0["text"] as? String }.joined()
        let lines = place(metrics, runs: runs, string: string, style: style)
        // Text Kit counts a line's width without the spaces that end it, and the text as tall as its
        // lines; an empty text, which has none, as tall as a line of its font.
        let used = CGSize(width: lines.map(\.width).max() ?? 0, height: lines.last.map { $0.top + $0.height } ?? emptyHeight(style))
        let laid = Laid(id: id, lines: lines, usedSize: used, string: string)
        // The page draws each line where it is placed here.
        _ = Host.call(.textLayout, string: "{\"place\":\(id),\"baselines\":\(Recording.json(lines.map { Double($0.drawn) }))}")
        return laid
    }

    /// Where each line lies, as Text Kit sets lines (measured on the Mac for every face the open
    /// fonts stand in for, at sizes from 4 to 132 points): as tall as its fonts' ascent and
    /// descent, each rounded to whole points, and their leading, which is not, below; the
    /// baseline the ascent down. With several fonts on a line, as tall as the most any of them
    /// has above the baseline and the most below. A few old faces have a fifth more room above
    /// (MacFonts.Face.fifth). A line of nothing but its paragraph's end is as tall rounded. Lines
    /// set apart by a line spacing are that tall and their leading, the baseline the descent up
    /// from the spacing, raised by `lift` when they are set further apart than the font's own
    /// lines, and not lowered when they are set closer. The last line of each paragraph but the
    /// last has the paragraph spacing below it.
    ///
    /// The fonts' measures are the Mac's own where they are known (MacFonts), for the faces the
    /// open fonts stand in for, else the host's. `metrics` per line: start, end, width, ascent,
    /// descent, leading, the host font's own; `runs` as `runs(_:)` makes them, `string` their words.
    private static func place(_ metrics: [[Double]], runs: [[String: Any]], string: String, style: TextStyle) -> [Line] {
        // Where each run lies in the words (UTF-16), and its face on the Mac.
        var spans: [(start: Int, end: Int, face: MacFonts.Face?, size: CGFloat)] = []
        var at = 0
        for r in runs {
            let n = (r["text"] as? String ?? "").utf16.count
            let face = MacFonts.face(family: r["family"] as? String ?? TextStyle.system, face: r["face"] as? String ?? "")
            spans.append((at, at + n, face, CGFloat((r["size"] as? Double) ?? Double(style.size))))
            at += n
        }
        let units = Array(string.utf16)
        func ends(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x2029 || u == 0x2028 }
        let natural = Fonts.naturalLineHeight(style)
        var y: CGFloat = 0
        return metrics.enumerated().map { k, m in
            let start = Int(m[0]), end = Int(m[1])
            // The runs on the line; on one with no letters, the run its end is in.
            var on = spans.filter { $0.end > start && $0.start < max(end, start + 1) }
            if on.isEmpty, let last = spans.last(where: { $0.start <= start }) ?? spans.last { on = [last] }
            var above: CGFloat = 0, below: CGFloat = 0, descent: CGFloat = 0
            if !on.isEmpty, on.allSatisfy({ $0.face != nil }) {
                for s in on {
                    let r = s.face!.rise(at: s.size)
                    above = max(above, r.above)
                    below = max(below, r.below)
                    descent = max(descent, r.descent)
                }
            } else {
                descent = CGFloat(m[4]).rounded()
                above = CGFloat(m[3]).rounded()
                below = descent + CGFloat(m[5])
            }
            let letters = units[min(start, units.count)..<min(max(end, start), units.count)]
            let blank = letters.allSatisfy(ends)
            var height = above + below, baseline = above
            if let spacing = style.lineSpacing, spacing > 0 {
                height = spacing + below - descent
                // Raised into the middle of lines set further apart; set closer, not lowered.
                baseline = spacing - descent - max(lift(style, natural: natural), 0)
            }
            if blank {
                // Its end, which is all it has, Text Kit puts at the line's bottom.
                height = height.rounded()
                baseline = height
            }
            if k < metrics.count - 1, let after = style.paragraphSpacing, after > 0, let last = letters.last, last != 0x2028, ends(last) {
                height += after
            }
            defer { y += height }
            return Line(start: start, end: end, top: y, height: height, width: CGFloat(m[2]), baseline: y + baseline, drawn: y + baseline)
        }
    }

    /// How tall an empty text is: a line of its font, rounded, as Text Kit's default line height.
    private static func emptyHeight(_ style: TextStyle) -> CGFloat {
        guard let face = MacFonts.face(family: style.family, face: style.face) else { return Fonts.naturalLineHeight(style) }
        let r = face.rise(at: max(style.size, 1))
        return (r.above + r.below).rounded()
    }

    /// The first line's own height, as the font sets it: for `Fonts.naturalLineHeight`. The Mac's
    /// font's where it is known.
    static func ownLineHeight(_ node: Node) -> CGFloat {
        let style = node.style ?? TextStyle()
        if let face = MacFonts.face(family: style.family, face: style.face) { return face.naturalLineHeight(at: style.size) }
        let spec: [String: Any] = ["width": 100_000.0, "align": "left", "lineSpacing": 0.0, "paragraphSpacing": 0.0, "runs": runs(node)]
        let json = (try? JSONSerialization.data(withJSONObject: spec)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let answer = Host.call(.textLayout, string: json)
        guard let data = answer.data(using: .utf8), let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = (reply["lines"] as? [[Double]])?.first, m.count >= 6 else { return ceil((node.style?.size ?? 12) * 1.2) }
        return CGFloat(m[3] + m[4] + m[5]).rounded(.up)
    }

    static func height(_ node: Node, width: CGFloat) -> CGFloat {
        ceil(lay(node, width: max(width, 1)).usedSize.height)
    }

    static func layout(_ node: Node) -> Laid {
        let style = node.style ?? TextStyle()
        let width = style.sizing == .autoWidth ? naturalWidth(node) + 0.5 : max(node.frame.width, 1)
        let key = Key(text: node.text ?? "", spans: node.spans, style: style, color: node.letterColor, width: width)
        if let laid = kept[key] { return laid }
        let laid = lay(node, width: width)
        kept[key] = laid
        return laid
    }

    static func naturalWidth(_ node: Node) -> CGFloat {
        var style = node.style ?? TextStyle()
        style.align = .left
        var probe = node
        probe.style = style
        let key = Key(text: node.text ?? "", spans: node.spans, style: style, color: nil, width: nil)
        if let laid = kept[key] { return ceil(laid.usedSize.width) }
        let laid = lay(probe, width: 100_000)
        kept[key] = laid
        return ceil(laid.usedSize.width)
    }

    static func offset(_ node: Node) -> CGFloat {
        guard let style = node.style, style.sizing == .fixed, let vertical = style.vertical, vertical != .top else { return 0 }
        let room = node.frame.height - layout(node).usedSize.height
        return vertical == .middle ? (room / 2).rounded() : room.rounded()
    }

    static func firstBaseline(_ node: Node) -> CGFloat {
        let laid = layout(node)
        // An empty text has no letters to set on a line: its font's ascent down, as on the Mac.
        let style = node.style ?? TextStyle()
        if laid.string.isEmpty, let face = MacFonts.face(family: style.family, face: style.face) {
            return CGFloat(face.ascent) * max(style.size, 1) + offset(node)
        }
        return (laid.lines.first?.baseline ?? 0) + offset(node)
    }

    static func fittedFrame(_ node: Node) -> CGRect {
        guard node.kind == .text else { return node.frame }
        let style = node.style ?? TextStyle()
        var frame = node.frame
        if style.sizing == .autoWidth { frame.size.width = max(naturalWidth(node), 1) }
        if style.sizing != .fixed { frame.size.height = ceil(layout(Node.with(node, frame: frame)).usedSize.height) }
        return frame
    }
}

// The same as the Mac's, but for `breakWhereWrapped`, which reads the lines from Skia's layout.
extension Node {
    nonisolated var letterColor: RGBA? {
        guard fill.on else { return nil }
        return fill.paints ? fill.color.with(alpha: 1) : fill.color
    }

    nonisolated static func with(_ node: Node, frame: CGRect) -> Node {
        var n = node
        n.frame = frame
        return n
    }

    nonisolated var overflows: Bool {
        guard kind == .text, curve == nil, style?.sizing == .fixed else { return false }
        return TextLayout.layout(self).usedSize.height > frame.height + 0.5
    }

    mutating func resizeText(to size: CGSize, byHeight: Bool) {
        let old = frame
        guard kind == .text, old.width > 0, old.height > 0, size != old.size else { return }
        switch style?.sizing ?? .autoWidth {
        case .autoWidth:
            scaleType(by: byHeight || size.width == old.width ? size.height / old.height : size.width / old.width)
        case .autoHeight:
            if size.height != old.height { style?.sizing = .fixed }
            frame.size = size
        case .fixed:
            frame.size = size
        }
        refit()
    }

    mutating func setSizing(_ sizing: TextSizing) {
        guard kind == .text, (style ?? TextStyle()).sizing != sizing else { return }
        if sizing == .autoWidth, curve == nil { breakWhereWrapped() }
        style?.sizing = sizing
        refit()
    }

    mutating func breakWhereWrapped() {
        guard kind == .text, style?.sizing != .autoWidth, let words = text, !words.isEmpty else { return }
        let laid = TextLayout.layout(self)
        let shown = laid.string as NSString
        guard shown.length == (words as NSString).length else { return }
        var wraps: [Int] = []
        for line in laid.lines {
            let end = line.end
            guard end > 0, end < shown.length, let last = Unicode.Scalar(shown.character(at: end - 1)),
                  !CharacterSet.newlines.contains(last) else { continue }
            wraps.append(end)
        }
        for end in wraps.reversed() {
            let space = Unicode.Scalar(shown.character(at: end - 1)).map { CharacterSet.whitespaces.contains($0) } ?? false
            replaceText(in: space ? NSRange(location: end - 1, length: 1) : NSRange(location: end, length: 0), with: "\n")
        }
    }

    mutating func refit() {
        guard kind == .text else { return }
        if curve != nil {
            refitCurve()
            return
        }
        let old = frame
        let fitted = TextLayout.fittedFrame(self)
        if style?.sizing == .autoWidth {
            switch style?.align ?? .left {
            case .left, .justify: frame = fitted
            case .center: frame = CGRect(x: old.midX - fitted.width / 2, y: old.minY, width: fitted.width, height: fitted.height)
            case .right: frame = CGRect(x: old.maxX - fitted.width, y: old.minY, width: fitted.width, height: fitted.height)
            }
        } else {
            frame = fitted
        }
    }
}
