import Foundation
import AppKit

// Text in the browser: the same questions the Mac's TextLayout answers (how wide, how tall,
// where the lines break, where the first baseline is), answered by Skia's paragraphs in the page
// instead of Text Kit. Skia breaks the lines and shapes their letters; where each line sits is
// worked out here, the way Text Kit places it (see `place`), so a design measures alike on both.

nonisolated enum Fonts {
    static let systemFaces = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]

    static var families: [String] { [TextStyle.system] + NSFontManager.shared.availableFontFamilies }

    static func faces(of family: String) -> [String] {
        if family == TextStyle.system { return systemFaces.flatMap { [$0, "\($0) Italic"] } }
        return NSFontManager.shared.families[family] ?? []
    }

    static func displayName(_ family: String) -> String { family == TextStyle.system ? "SF Pro" : family }
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

    /// How far the letters are raised in lines set further apart than the font's own, as on the Mac.
    private static func lift(_ style: TextStyle, natural: CGFloat) -> CGFloat {
        guard let spacing = style.lineSpacing, spacing > 0 else { return 0 }
        return (spacing - natural) / 2
    }

    /// The runs of a text, as the page sets them: each with its own look over the text's style.
    private static func runs(_ node: Node) -> [[String: Any]] {
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
        return zip(runs, texts).map { run, text in
            let letters = run.look.resolved(over: style, color: color ?? .black)
            var r: [String: Any] = [
                "text": text, "family": letters.family, "face": letters.face, "size": Double(letters.size),
                "tracking": Double(letters.tracking / 1000 * letters.size),
                "underline": letters.underline, "strike": letters.strikethrough,
            ]
            if color != nil { r["color"] = [letters.color.r, letters.color.g, letters.color.b, letters.color.a] }
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
        let lines = place(metrics, style: style)
        // Text Kit counts a line's width without the spaces that end it, and the text as tall as its lines.
        let used = CGSize(width: lines.map(\.width).max() ?? 0, height: lines.last.map { $0.top + $0.height } ?? 0)
        let laid = Laid(id: id, lines: lines, usedSize: used, string: runs.compactMap { $0["text"] as? String }.joined())
        // The page draws each line where it is placed here.
        _ = Host.call(.textLayout, string: "{\"place\":\(id),\"baselines\":\(Recording.json(lines.map { Double($0.drawn) }))}")
        return laid
    }

    /// Where each line lies, as Text Kit sets lines: as tall as the font's ascent and descent,
    /// each rounded to whole points, and its leading, which is not; the baseline the ascent down.
    /// Lines set apart by a line spacing are exactly that tall, the baseline the descent and
    /// leading up from their bottom, raised by `lift` when they are set further apart than the
    /// font's own lines, and not lowered when they are set closer: as Text Kit measured the
    /// sample designs (Bodoni 72 at 132 on 124, Avenir Next at 28 on 40, SF Pro at 15 on 22).
    /// `metrics` per line: start, end, width, ascent, descent, leading, the font's own.
    private static func place(_ metrics: [[Double]], style: TextStyle) -> [Line] {
        var y: CGFloat = 0
        return metrics.map { m in
            let ascent = CGFloat(m[3]), descent = CGFloat(m[4]), leading = CGFloat(m[5])
            let a = ascent.rounded(), d = descent.rounded()
            var height = a + d + leading
            var baseline = a, drawn = a
            if let spacing = style.lineSpacing, spacing > 0 {
                let natural = (ascent + descent + leading).rounded(.up)
                height = spacing
                // Raised into the middle of lines set further apart; set closer, not lowered.
                baseline = spacing - d - leading - max(lift(style, natural: natural), 0)
                drawn = baseline
            }
            defer { y += height }
            return Line(start: Int(m[0]), end: Int(m[1]), top: y, height: height, width: CGFloat(m[2]), baseline: y + baseline, drawn: y + drawn)
        }
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
        (layout(node).lines.first?.baseline ?? 0) + offset(node)
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
