import Foundation
import CoreGraphics
import AppKit

/// A paragraph set as one item of a list, with its marker before it.
nonisolated enum TextList: String, Codable, CaseIterable {
    case bullet, number
}

/// How some letters of a text differ from the rest of their layer, such as one word in bold or in
/// another colour: each is nil wherever the letters are as the layer's style has them.
nonisolated struct TextLook: Codable, Hashable {
    var family: String?
    var face: String?
    var size: CGFloat?
    var color: RGBA?
    var underline: Bool?
    var strikethrough: Bool?
    /// In thousandths of the font size, as `TextStyle.tracking`.
    var tracking: CGFloat?
    /// The paragraph these letters are in is an item of a list. Every letter of a paragraph holds
    /// the same, the first one's (`TextSpan.tidy`).
    var list: TextList?

    static let plain = TextLook()
    var isPlain: Bool { self == .plain }

    /// Everything about the letters, with the layer's style where they say nothing.
    func resolved(over style: TextStyle, color base: RGBA) -> Letters {
        Letters(family: family ?? style.family, face: face ?? style.face, size: size ?? style.size, color: color ?? base,
                underline: underline ?? style.underline, strikethrough: strikethrough ?? (style.strikethrough ?? false),
                tracking: tracking ?? style.tracking, list: list)
    }

    /// What `letters` have that a layer of `style` and colour `base` does not, and only that.
    init(_ letters: Letters, over style: TextStyle, color base: RGBA) {
        family = letters.family == style.family ? nil : letters.family
        face = letters.face == style.face && family == nil ? nil : letters.face
        size = letters.size == style.size ? nil : letters.size
        color = letters.color == base ? nil : letters.color
        underline = letters.underline == style.underline ? nil : letters.underline
        strikethrough = letters.strikethrough == (style.strikethrough ?? false) ? nil : letters.strikethrough
        tracking = letters.tracking == style.tracking ? nil : letters.tracking
        list = letters.list
    }

    init(family: String? = nil, face: String? = nil, size: CGFloat? = nil, color: RGBA? = nil, underline: Bool? = nil,
         strikethrough: Bool? = nil, tracking: CGFloat? = nil, list: TextList? = nil) {
        self.family = family; self.face = face; self.size = size; self.color = color
        self.underline = underline; self.strikethrough = strikethrough; self.tracking = tracking; self.list = list
    }

    /// The same look, saying nothing more of what `parts` name.
    func without(_ parts: Set<Letters.Part>) -> TextLook {
        var l = self
        if parts.contains(.family) { l.family = nil }
        if parts.contains(.face) { l.face = nil }
        if parts.contains(.size) { l.size = nil }
        if parts.contains(.color) { l.color = nil }
        if parts.contains(.underline) { l.underline = nil }
        if parts.contains(.strikethrough) { l.strikethrough = nil }
        if parts.contains(.tracking) { l.tracking = nil }
        if parts.contains(.list) { l.list = nil }
        return l
    }

    /// The same look, saying what `other` says of `parts`.
    func taking(_ parts: Set<Letters.Part>, from other: TextLook) -> TextLook {
        var l = self
        if parts.contains(.family) { l.family = other.family }
        if parts.contains(.face) { l.face = other.face }
        if parts.contains(.size) { l.size = other.size }
        if parts.contains(.color) { l.color = other.color }
        if parts.contains(.underline) { l.underline = other.underline }
        if parts.contains(.strikethrough) { l.strikethrough = other.strikethrough }
        if parts.contains(.tracking) { l.tracking = other.tracking }
        if parts.contains(.list) { l.list = other.list }
        return l
    }

    /// What two looks say differently.
    static func parts(differing a: TextLook, _ b: TextLook) -> Set<Letters.Part> {
        var d: Set<Letters.Part> = []
        if a.family != b.family { d.insert(.family) }
        if a.face != b.face { d.insert(.face) }
        if a.size != b.size { d.insert(.size) }
        if a.color != b.color { d.insert(.color) }
        if a.underline != b.underline { d.insert(.underline) }
        if a.strikethrough != b.strikethrough { d.insert(.strikethrough) }
        if a.tracking != b.tracking { d.insert(.tracking) }
        if a.list != b.list { d.insert(.list) }
        return d
    }

    /// The same look with its size grown or shrunk by `k`, to a tenth of a point.
    func scaled(by k: CGFloat) -> TextLook {
        var l = self
        l.size = size.map { max(1, ($0 * k * 10).rounded() / 10) }
        return l
    }
}

/// Everything about some letters as they are drawn: their layer's style, with their own look over it.
nonisolated struct Letters: Hashable {
    var family: String
    var face: String
    var size: CGFloat
    var color: RGBA
    var underline: Bool
    var strikethrough: Bool
    var tracking: CGFloat
    var list: TextList?

    /// One thing about letters, to say what was changed.
    enum Part: CaseIterable { case family, face, size, color, underline, strikethrough, tracking, list }

    /// What differs between two.
    static func parts(differing a: Letters, _ b: Letters) -> Set<Part> {
        var d: Set<Part> = []
        if a.family != b.family { d.insert(.family) }
        if a.face != b.face { d.insert(.face) }
        if a.size != b.size { d.insert(.size) }
        if a.color != b.color { d.insert(.color) }
        if a.underline != b.underline { d.insert(.underline) }
        if a.strikethrough != b.strikethrough { d.insert(.strikethrough) }
        if a.tracking != b.tracking { d.insert(.tracking) }
        if a.list != b.list { d.insert(.list) }
        return d
    }

    /// What of a layer's style and colour differ between two, as letters see them.
    static func parts(differing a: TextStyle, _ ca: RGBA, _ b: TextStyle, _ cb: RGBA) -> Set<Part> {
        parts(differing: TextLook.plain.resolved(over: a, color: ca), TextLook.plain.resolved(over: b, color: cb))
    }

    /// A layer's style with these letters' font in it, for finding the font they are drawn in.
    func style(over style: TextStyle) -> TextStyle {
        var s = style
        s.family = family
        s.face = face
        s.size = size
        s.tracking = tracking
        s.underline = underline
        s.strikethrough = strikethrough
        return s
    }
}

/// Some letters of a text that look alike, and the words they make. A text's spans run through it
/// end to end; each holds its own words, so that should the text be changed without them, by
/// someone else at the same time or by anything that only sets words, they can be laid onto the
/// new words again where those still match (`aligned`).
nonisolated struct TextSpan: Hashable {
    var text: String
    var look = TextLook()

    init(text: String, look: TextLook = TextLook()) {
        self.text = text
        self.look = look
    }
}

/// Kept flat, the words beside what is different about them: {"text": "World", "face": "Bold"}.
nonisolated extension TextSpan: Codable {
    private enum Keys: String, CodingKey { case text }

    init(from decoder: Decoder) throws {
        text = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .text)
        look = try TextLook(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(text, forKey: .text)
        try look.encode(to: encoder)
    }
}

nonisolated extension TextSpan {
    /// Spans as they are kept: none empty, none next to one that looks the same, each paragraph's
    /// letters all in its list or none; nil when every letter is as the layer's style has it.
    static func stored(_ runs: [TextSpan]) -> [TextSpan]? {
        let t = tidy(runs)
        return t.allSatisfy(\.look.isPlain) ? nil : t
    }

    /// Spans joined where they look the same, with every paragraph in the list its first letter is in.
    static func tidy(_ runs: [TextSpan]) -> [TextSpan] {
        // Paragraphs first: the letters of each take the list of its first letter.
        var out: [TextSpan] = []
        var list: TextList?
        var atStart = true
        for run in runs where !run.text.isEmpty {
            var rest = Substring(run.text)
            while !rest.isEmpty {
                if atStart { list = run.look.list }
                let end = rest.firstIndex(where: endsParagraph).map { rest.index(after: $0) } ?? rest.endIndex
                var look = run.look
                look.list = list
                append(String(rest[..<end]), look, to: &out)
                atStart = end != rest.endIndex || rest.last.map(endsParagraph) == true
                rest = rest[end...]
            }
        }
        return out
    }

    /// Whether a letter ends a paragraph, as Text Kit counts them: a line break within one, such
    /// as Figma's soft return (U+2028), does not.
    static func endsParagraph(_ c: Character) -> Bool {
        c == "\n" || c == "\r" || c == "\r\n" || c == "\u{2029}" || c == "\u{85}"
    }

    private static func append(_ text: String, _ look: TextLook, to runs: inout [TextSpan]) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.look == look {
            runs[runs.count - 1].text += text
        } else {
            runs.append(TextSpan(text: text, look: look))
        }
    }

    /// Each letter's look, laid onto `text`: letters at its start and end that match the spans'
    /// words keep their looks; letters typed in between take the look of the letter before them,
    /// or after them at the start; and new words in place of all of them take the look most of the
    /// old ones had.
    static func looks(of spans: [TextSpan], onto text: String) -> [TextLook] {
        let new = Array(text)
        var oldChars: [Character] = []
        var oldLooks: [TextLook] = []
        for s in spans {
            for c in s.text {
                oldChars.append(c)
                oldLooks.append(s.look)
            }
        }
        if oldChars == new { return oldLooks }
        let (p, s) = matching(oldChars, new)
        // Between what is alike at the start and the end, words left as they were among those
        // typed keep their looks too; letters that match only here and there are not words kept.
        var kept: [Int?] = Array(repeating: nil, count: new.count)
        for i in 0..<p { kept[i] = i }
        for k in 0..<s { kept[new.count - 1 - k] = oldChars.count - 1 - k }
        let a = Array(oldChars[p..<(oldChars.count - s)]), b = Array(new[p..<(new.count - s)])
        for (i, j) in alike(a, b) { kept[p + j] = p + i }
        let matchedAny = kept.contains { $0 != nil }
        var looks: [TextLook] = []
        looks.reserveCapacity(new.count)
        for j in 0..<new.count {
            if let i = kept[j] {
                looks.append(oldLooks[i])
            } else if let last = looks.last {
                // Typed after a letter: as that letter.
                looks.append(last)
            } else if let next = kept[j...].lazy.compactMap({ $0 }).first {
                // Typed before the first letter kept: as it.
                looks.append(oldLooks[next])
            } else {
                looks.append(matchedAny ? .plain : mostOf(oldLooks))
            }
        }
        return looks
    }

    /// Letters of `a` and `b` that are the same words in the same order, as pairs of their places:
    /// the longest such sequence, in runs of three letters or more. Too long to compare letter by
    /// letter, none.
    private static func alike(_ a: [Character], _ b: [Character]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0, n * m <= 250_000 else { return [] }
        // The longest common sequence, from the end.
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j] ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] { i += 1 }
            else { j += 1 }
        }
        // Only runs of letters next to each other in both.
        var out: [(Int, Int)] = []
        var run: [(Int, Int)] = []
        func close() {
            if run.count >= 3 { out += run }
            run = []
        }
        for pair in pairs {
            if let last = run.last, pair.0 != last.0 + 1 || pair.1 != last.1 + 1 { close() }
            run.append(pair)
        }
        close()
        return out
    }

    /// How many letters at the start, and then at the end, two texts have alike.
    static func matching(_ a: [Character], _ b: [Character]) -> (prefix: Int, suffix: Int) {
        let most = min(a.count, b.count)
        var p = 0
        while p < most, a[p] == b[p] { p += 1 }
        var s = 0
        while s < most - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (p, s)
    }

    private static func mostOf(_ looks: [TextLook]) -> TextLook {
        guard !looks.isEmpty else { return .plain }
        var counts: [TextLook: Int] = [:]
        for l in looks { counts[l, default: 0] += 1 }
        // The first of those most had, so the answer is the same everywhere.
        let most = counts.values.max() ?? 0
        return looks.first { counts[$0] == most } ?? .plain
    }

    /// The spans laid onto `text`, as `looks` does it.
    static func aligned(_ spans: [TextSpan], onto text: String) -> [TextSpan] {
        if spans.map(\.text).joined() == text { return spans }
        return runs(text, looks(of: spans, onto: text))
    }

    /// Letters and their looks, one each, made spans.
    static func runs(_ text: String, _ looks: [TextLook]) -> [TextSpan] {
        var out: [TextSpan] = []
        for (c, look) in zip(text, looks) {
            if let last = out.last, last.look == look {
                out[out.count - 1].text.append(c)
            } else {
                out.append(TextSpan(text: String(c), look: look))
            }
        }
        return out
    }

    /// The words as an attributed string with each letter's look on it (`TextLayout.look`), for
    /// changing some of them by their place.
    static func marked(_ runs: [TextSpan]) -> NSMutableAttributedString {
        let s = NSMutableAttributedString()
        for run in runs {
            s.append(NSAttributedString(string: run.text, attributes: [.bezzleLook: LookBox(run.look)]))
        }
        return s
    }

    /// The spans an attributed string marked with looks makes.
    static func runs(of string: NSAttributedString) -> [TextSpan] {
        var out: [TextSpan] = []
        let whole = string.string as NSString
        string.enumerateAttribute(.bezzleLook, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            let look = (value as? LookBox)?.look ?? .plain
            append(whole.substring(with: range), look, to: &out)
        }
        return out
    }
}

/// A look as an attribute of letters in an attributed string.
nonisolated final class LookBox: NSObject, @unchecked Sendable {
    let look: TextLook
    init(_ look: TextLook) { self.look = look }
    override func isEqual(_ object: Any?) -> Bool { (object as? LookBox)?.look == look }
    override var hash: Int { look.hashValue }
}

nonisolated extension NSAttributedString.Key {
    /// The `TextLook` of the letters, in a `LookBox`.
    static let bezzleLook = NSAttributedString.Key("BezzleLook")
    /// On the letters of a paragraph that is an item of a list: its marker, a `ListMarker`.
    static let bezzleMarker = NSAttributedString.Key("BezzleListMarker")
}

/// What stands before an item of a list, and how far in its words begin.
nonisolated final class ListMarker: NSObject, @unchecked Sendable {
    let text: String
    /// From the marker's right to the words.
    let gap: CGFloat
    init(_ text: String, gap: CGFloat) {
        self.text = text
        self.gap = gap
    }
    override func isEqual(_ object: Any?) -> Bool { (object as? ListMarker).map { $0.text == text && $0.gap == gap } ?? false }
    override var hash: Int { text.hashValue ^ gap.hashValue }
}

// MARK: - Text layers with styled letters

nonisolated extension Node {
    /// A text layer's colour, or none when its colour is off.
    var textColor: RGBA { fill.on ? fill.color : RGBA(r: 0, g: 0, b: 0, a: 0) }

    /// The words in runs that look alike, laid onto the words as they are: one plain run for a
    /// text all of a piece, and none for no words.
    var runs: [TextSpan] {
        let words = text ?? ""
        guard let spans, !spans.isEmpty else { return words.isEmpty ? [] : [TextSpan(text: words)] }
        return TextSpan.aligned(spans, onto: words)
    }

    /// Sets the words and how each letter looks.
    mutating func setRuns(_ runs: [TextSpan]) {
        text = runs.map(\.text).joined()
        spans = TextSpan.stored(runs)
    }

    /// Whether some of its letters look different from the rest.
    var hasStyledLetters: Bool { spans?.contains { !$0.look.isPlain } == true }

    /// Takes away the colours any letters have of their own, so that all of them are the text's
    /// colour, or show its gradient or picture.
    mutating func clearLetterColors() {
        guard spans?.contains(where: { $0.look.color != nil }) == true else { return }
        spans = TextSpan.stored(runs.map { TextSpan(text: $0.text, look: $0.look.without([.color])) })
    }

    /// How the letters in `range` (in UTF-16, as the editor counts), or all of them, are drawn: a
    /// run's worth each.
    func letters(in range: NSRange? = nil) -> [Letters] {
        let style = self.style ?? TextStyle()
        let color = fill.color
        let runs = self.runs
        guard !runs.isEmpty else { return [TextLook.plain.resolved(over: style, color: color)] }
        guard let range else { return runs.map { $0.look.resolved(over: style, color: color) } }
        let marked = TextSpan.marked(runs)
        let whole = NSRange(location: 0, length: marked.length)
        var within = NSIntersectionRange(range, whole)
        // Just the caret: the letters it is after, as typing would continue them.
        if within.length == 0 {
            guard marked.length > 0 else { return [TextLook.plain.resolved(over: style, color: color)] }
            within = NSRange(location: max(0, min(range.location, marked.length) - 1), length: 1)
        }
        var out: [Letters] = []
        marked.enumerateAttribute(.bezzleLook, in: within) { value, _, _ in
            out.append(((value as? LookBox)?.look ?? .plain).resolved(over: style, color: color))
        }
        return out
    }

    /// Changes how letters look: those in `range`, or with none every letter, which changes the
    /// layer's own style and colour and takes away what any letter said otherwise of what changed.
    /// A change to a list goes to whole paragraphs.
    mutating func restyleLetters(in range: NSRange?, _ change: (inout Letters) -> Void) {
        guard kind == .text else { return }
        var style = self.style ?? TextStyle()
        let color = fill.color
        guard let range, range.length > 0 else {
            var base = TextLook.plain.resolved(over: style, color: color)
            let was = base
            change(&base)
            let changed = Letters.parts(differing: was, base)
            guard !changed.isEmpty else { return }
            let lists = changed.contains(.list)
            let rest = changed.subtracting([.list])
            style = base.style(over: style)
            self.style = style
            fill.color = base.color
            if base.color != was.color { fill.on = true }
            spans = TextSpan.stored(self.runs.map { run in
                var look = run.look.without(rest)
                if lists { look.list = base.list }
                return TextSpan(text: run.text, look: look)
            })
            return
        }
        let marked = TextSpan.marked(runs)
        let whole = NSRange(location: 0, length: marked.length)
        var within = NSIntersectionRange(range, whole)
        guard within.length > 0 else { return }
        // Lists are of paragraphs: see whether the change is to one first.
        var probe = TextLook.plain.resolved(over: style, color: color)
        if let at = marked.attribute(.bezzleLook, at: within.location, effectiveRange: nil) as? LookBox {
            probe = at.look.resolved(over: style, color: color)
        }
        let before = probe
        change(&probe)
        if before.list != probe.list {
            within = (marked.string as NSString).paragraphRange(for: within)
        }
        var edits: [(NSRange, TextLook)] = []
        marked.enumerateAttribute(.bezzleLook, in: within) { value, r, _ in
            let look = (value as? LookBox)?.look ?? .plain
            var letters = look.resolved(over: style, color: color)
            change(&letters)
            edits.append((r, TextLook(letters, over: style, color: color)))
        }
        for (r, look) in edits { marked.addAttribute(.bezzleLook, value: LookBox(look), range: r) }
        spans = TextSpan.stored(TextSpan.runs(of: marked))
    }

    /// Puts `replacement` in place of the words in `range` (UTF-16), its letters looking as the
    /// first of those they replace, or as the letter before for words put in.
    mutating func replaceText(in range: NSRange, with replacement: String) {
        let marked = TextSpan.marked(runs)
        let whole = NSRange(location: 0, length: marked.length)
        let r = NSIntersectionRange(range, whole)
        guard r.location <= marked.length else { return }
        var look = TextLook.plain
        if marked.length > 0 {
            let at = r.length > 0 ? r.location : max(r.location - 1, 0)
            look = (marked.attribute(.bezzleLook, at: min(at, marked.length - 1), effectiveRange: nil) as? LookBox)?.look ?? .plain
        }
        marked.replaceCharacters(in: r, with: NSAttributedString(string: replacement, attributes: [.bezzleLook: LookBox(look)]))
        setRuns(TextSpan.runs(of: marked))
    }

    /// The letters' own sizes grown or shrunk by `k`, as the layer's is with them.
    mutating func scaleLetters(by k: CGFloat) {
        guard let spans, spans.contains(where: { $0.look.size != nil }) else { return }
        self.spans = spans.map { TextSpan(text: $0.text, look: $0.look.scaled(by: k)) }
    }

    /// The text's style and letters grown or shrunk by `k`, as when its box is pulled bigger.
    mutating func scaleType(by k: CGFloat) {
        style = style?.scaled(by: k)
        scaleLetters(by: k)
    }
}

// MARK: - Letters in copies

nonisolated extension Node {
    /// How a copy's letters look once its layer is made again from `m`, the layer it is a copy
    /// of: its own spans, `self` being the copy as it was, laid onto its words; with what `m`'s
    /// style and colour changed from the copy's taken away from every letter, as the change was
    /// made to the whole layer; and what was restyled in `m` since `mWas` restyled the same here,
    /// where the copy's words match `m`'s. `keeps` are the properties the copy keeps of its own.
    func lettersCarried(from m: Node, was mWas: Node?, keeps: Set<String> = []) -> [TextSpan]? {
        guard kind == .text, m.kind == .text, !keeps.contains("spans") else { return spans }
        // Nothing about the letters changed: as they were, as nearly always.
        let sameBase = (style ?? TextStyle()) == (m.style ?? TextStyle()) && fill.color == m.fill.color
        if sameBase, mWas.map({ $0.spans == m.spans && $0.text == m.text }) ?? true { return spans }
        let words = text ?? ""
        var looks = spans.map { TextSpan.looks(of: $0, onto: words) } ?? Array(repeating: .plain, count: words.count)
        // A change to the whole layer: what it changed, every letter is again.
        var whole: Set<Letters.Part> = []
        if !keeps.contains("style") { whole.formUnion(Letters.parts(differing: style ?? TextStyle(), fill.color, m.style ?? TextStyle(), fill.color).subtracting([.color])) }
        if !keeps.contains("fill"), fill.color != m.fill.color { whole.insert(.color) }
        if !whole.isEmpty { looks = looks.map { $0.without(whole) } }
        // Letters restyled in the layer copied: the same letters here, where the words match.
        if let mWas, mWas.kind == .text {
            let mWords = Array(m.text ?? "")
            let now = m.spans.map { TextSpan.looks(of: $0, onto: m.text ?? "") } ?? Array(repeating: .plain, count: mWords.count)
            let then = mWas.spans.map { TextSpan.looks(of: $0, onto: m.text ?? "") } ?? Array(repeating: .plain, count: mWords.count)
            if now != then {
                let mine = Array(words)
                let (p, s) = TextSpan.matching(mWords, mine)
                func carry(_ i: Int, _ j: Int) {
                    let parts = TextLook.parts(differing: then[i], now[i]).subtracting(whole)
                    if !parts.isEmpty { looks[j] = looks[j].taking(parts, from: now[i]) }
                }
                for i in 0..<p { carry(i, i) }
                for k in 0..<s { carry(mWords.count - 1 - k, mine.count - 1 - k) }
            }
        }
        return TextSpan.stored(TextSpan.runs(words, looks))
    }
}
