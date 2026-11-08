import Foundation
import CBezzleHost

// Typing into a text on the canvas, as the Mac's editor does it (CanvasView's TypingView and the
// store's restyleTyped and Format commands, Store/TextOperations.swift): the words and how each
// letter of them looks, the letters picked out, how what is typed next looks where only the
// caret is, and the editor's own Undo, which takes back each change while typing, as the whole
// typing is one step of the design's history once it ends. The canvas draws the words as they
// are (straight, for a text on a curve, as the Mac types it) and the caret and the letters
// picked out over them, from where the core lays the letters. Runs are cut and joined as spans
// (RichText's TextSpan.cut and joined, Node.restyleLetters and replaceText), never on attributed
// strings, which Foundation on Windows cannot hold looks of their own in.

extension WindowsCore {
    /// The text being typed into, while it is.
    public final class Typing {
        public let id: UUID
        /// The letters picked out, or where the caret is when none are (UTF-16, as the text counts).
        public internal(set) var picked: NSRange
        /// How what is typed next looks, once a look was asked for where only the caret is (the
        /// Mac's typingAttributes); nil: as the letter before it.
        var typed: TextLook?
        /// Whether letters typed now are the same step of the editor's history as those before
        /// them (the Mac's Undo Typing takes back a run of typing at once), and where they go on.
        var joining = false
        var expected: NSRange?
        /// Drags in the cards while typing (a dial, a colour): each is made again from where it
        /// began, as gestures are, and is one change of the typing.
        var nested = 0
        var nestedFrom: Moment?
        var undos: [Moment] = []
        var redos: [Moment] = []
        /// Misspelt words left as they are while typing, as the Mac's text view's Ignore Spelling.
        var ignored = Set<String>()

        init(id: UUID, picked: NSRange) {
            self.id = id
            self.picked = picked
        }
    }

    /// The words and looks of the text typed into, and what was picked out, at one moment.
    struct Moment: Equatable {
        var runs: [TextSpan]
        var picked: NSRange
    }

    public internal(set) static var typing: Typing?

    /// Typing into a text begins, every letter picked out (as the Mac's editor selects all): one
    /// step of the history for all of it. Answers its words.
    @discardableResult public static func beginTyping(_ id: UUID) -> String? {
        guard !isReadOnly, let node = design?.node(id), node.kind == .text else { return nil }
        endTyping()
        beginGesture()
        typing = Typing(id: id, picked: NSRange(location: 0, length: ((node.text ?? "") as NSString).length))
        // Lines broken as the field breaks them, one letter each, so its places are the text's.
        if (node.text ?? "").contains("\r") {
            let runs = node.runs.map { TextSpan(text: $0.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), look: $0.look) }
            edit { d in d.update(id) { n in n.setRuns(runs); n.refit() } }
        }
        let words = design?.node(id)?.text ?? ""
        typing?.picked = NSRange(location: 0, length: (words as NSString).length)
        // An empty item of a list at the end shows its marker while it is typed, as on the Mac.
        if TextLayout.typedTrailing == nil {
            TextLayout.typedTrailing = { node in
                guard Thread.isMainThread else { return nil }
                return MainActor.assumeIsolated { WindowsCore.typedLook(of: node) }
            }
        }
        return words
    }

    /// The look what is typed next in `node` has, while it is typed into: as the letters before
    /// the caret, unless a look was given for it (the Mac's typing attributes).
    static func typedLook(of node: Node) -> TextLook? {
        guard let t = typing, t.id == node.id else { return nil }
        let runs = node.runs
        return t.typed ?? (runs.isEmpty ? nil : TextSpan.look(at: max(t.picked.location - 1, 0), in: runs))
    }

    /// Typing is done: everything typed, and every look given while typing, is one step.
    public static func endTyping() {
        guard typing != nil else { return }
        typing = nil
        Editing.gestureBase = nil
        endGesture()
    }

    /// The words of the text typed into, as they are now.
    public static var typingWords: String? {
        guard let t = typing else { return nil }
        return design?.node(t.id)?.text ?? ""
    }

    /// The letters picked out while typing, when there are any: what the Text card and the
    /// letters' colour change, rather than the whole layer (the Mac's pickedLetters).
    public static var pickedLetters: NSRange? {
        guard let t = typing, t.picked.length > 0 else { return nil }
        return t.picked
    }

    /// Whether `ids` are the text typed into, alone.
    static func typingInto(_ ids: [UUID]) -> Bool { typing.map { ids == [$0.id] } ?? false }

    /// A range kept within words `length` long.
    private static func clamped(_ r: NSRange, _ length: Int) -> NSRange {
        let at = min(max(r.location, 0), length)
        return NSRange(location: at, length: min(max(r.length, 0), length - at))
    }

    // MARK: Words typed

    /// The words in the field typed into changed to `words`, its caret (or what it picks out)
    /// now at `caret`: the change is found where the letters were picked out, and its letters
    /// look as the first of those they replace, or as the letter before them (or as asked for
    /// with only the caret there), as the Mac's text view types them.
    public static func typed(_ words: String, caret: NSRange) {
        beginChange()
        guard let t = typing, let node = design?.node(t.id) else { return }
        let old = node.text ?? ""
        guard words != old else { pick(caret); return }
        let a = Array(old.utf16), b = Array(words.utf16)
        let most = min(a.count, b.count)
        let was = clamped(t.picked, a.count)
        // Alike before the change, which began where the letters were picked out and ends
        // before the caret; and alike after it, past what was picked out.
        var p = 0
        let before = min(was.location, caret.location, most)
        while p < before, a[p] == b[p] { p += 1 }
        var s = 0
        let after = min(most - p, a.count - NSMaxRange(was))
        while s < after, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let removed = NSRange(location: p, length: a.count - s - p)
        let inserted = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        let count = (inserted as NSString).length
        // Typing on where it left off is the same step; words put in at once (pasted) are one of
        // their own, as are words typed elsewhere.
        let pasted = count > 1
        let goesOn = t.joining && !pasted && t.expected.map { $0.location == removed.location || $0.location == NSMaxRange(removed) } == true
        if !goesOn { record(t) }
        let look = t.typed
        edit { d in
            d.update(t.id) { n in
                replace(&n, in: removed, with: inserted)
                if let look, count > 0 {
                    let parts = TextSpan.cut(n.runs, at: NSRange(location: removed.location, length: count))
                    n.setRuns(TextSpan.joined(parts.before, [TextSpan(text: inserted, look: look)], parts.after))
                }
                n.refit()
            }
        }
        t.typed = nil
        t.joining = !pasted
        t.picked = clamped(caret, b.count)
        t.expected = t.picked
    }

    /// Puts `replacement` in place of the words in `range`, its letters looking as the first of
    /// those they replace, or as the letter before for words put in: Node.replaceText, but with
    /// the range kept within the words by hand, since Foundation on Windows takes an empty range
    /// at the very end (NSIntersectionRange) to lie at the start, which put letters typed at the
    /// end of a text at its start.
    private static func replace(_ n: inout Node, in range: NSRange, with replacement: String) {
        let runs = n.runs
        let length = TextSpan.length(of: runs)
        let r = clamped(range, length)
        var look = TextLook.plain
        if length > 0 {
            let at = r.length > 0 ? r.location : max(r.location - 1, 0)
            look = TextSpan.look(at: min(at, length - 1), in: runs)
        }
        let parts = TextSpan.cut(runs, at: r)
        n.setRuns(TextSpan.joined(parts.before, [TextSpan(text: replacement, look: look)], parts.after))
    }

    /// The letters picked out in the field, or where its caret is, as it moves. Answers whether
    /// what the cards show changes with it: the letters picked out, or the whole layer with none.
    @discardableResult public static func pick(_ range: NSRange) -> Bool {
        guard let t = typing else { return false }
        let r = clamped(range, ((design?.node(t.id)?.text ?? "") as NSString).length)
        guard r != t.picked else { return false }
        let was = t.picked
        t.picked = r
        // The caret moved elsewhere: typing there is a new step, and the letters typed look as
        // those they go among.
        if r != t.expected {
            t.joining = false
            t.typed = nil
        }
        t.expected = nil
        return was.length > 0 || r.length > 0
    }

    // MARK: Looks

    /// Changes how letters look while typing: those picked out; with `caret`, where only the
    /// caret is, how what is typed next looks, or for a list the paragraph the caret is in (the
    /// Mac's restyleTyped). False when nothing is being typed into, or when no letters are
    /// picked out and `caret` is not asked for: the change is then the whole layer's.
    @discardableResult static func restyleTyped(_ change: (inout Letters) -> Void, caret: Bool) -> Bool {
        beginChange()
        guard let t = typing, let node = design?.node(t.id) else { return false }
        guard caret || t.picked.length > 0 else { return false }
        let style = node.style ?? TextStyle(), color = node.fill.color
        let runs = node.runs
        var range = clamped(t.picked, TextSpan.length(of: runs))
        if range.length == 0 {
            // What the change does, tried on the letters typed next.
            let typed = t.typed ?? (runs.isEmpty ? .plain : TextSpan.look(at: max(range.location - 1, 0), in: runs))
            var probe = typed.resolved(over: style, color: color)
            let before = probe
            change(&probe)
            if probe.list != before.list { range = ((node.text ?? "") as NSString).paragraphRange(for: range) }
            if range.length == 0 {
                t.typed = TextLook(probe, over: style, color: color)
                t.joining = false
                return true
            }
        }
        record(t)
        t.joining = false
        edit { d in d.update(t.id) { n in n.restyleLetters(in: range, change); n.refit() } }
        return true
    }

    // MARK: The editor's history

    /// Keeps the text as it is, before a change while typing, for the editor's Undo.
    private static func record(_ t: Typing) {
        guard t.nested == 0, let node = design?.node(t.id) else { return }
        t.undos.append(Moment(runs: node.runs, picked: t.picked))
        if t.undos.count > 500 { t.undos.removeFirst() }
        t.redos = []
    }

    /// Takes back the last change made while typing (Ctrl+Z in the text): the words and their
    /// looks as they were, and what was picked out then. Nil with nothing to take back.
    public static func undoTyping() -> (words: String, picked: NSRange)? { stepTyping(back: true) }

    /// Makes a change taken back while typing again (Ctrl+Y).
    public static func redoTyping() -> (words: String, picked: NSRange)? { stepTyping(back: false) }

    private static func stepTyping(back: Bool) -> (words: String, picked: NSRange)? {
        beginChange()
        guard let t = typing, t.nested == 0, let node = design?.node(t.id) else { return nil }
        guard let m = back ? t.undos.popLast() : t.redos.popLast() else { return nil }
        let now = Moment(runs: node.runs, picked: t.picked)
        if back { t.redos.append(now) } else { t.undos.append(now) }
        edit { d in d.update(t.id) { n in n.setRuns(m.runs); n.refit() } }
        t.typed = nil
        t.joining = false
        t.picked = m.picked
        t.expected = m.picked
        return (m.runs.map(\.text).joined(), m.picked)
    }

    // A drag in a card while typing (`beginGesture` and the rest call these): made again from
    // where it began, and one change of the typing once let go.

    static func typingGestureBegins(_ t: Typing) {
        t.nested += 1
        guard t.nested == 1, let doc = design else { return }
        Editing.gestureBase = doc
        t.nestedFrom = doc.node(t.id).map { Moment(runs: $0.runs, picked: t.picked) }
    }

    static func typingGestureEnds(_ t: Typing) {
        guard t.nested > 0 else { return }
        t.nested -= 1
        guard t.nested == 0 else { return }
        if let from = t.nestedFrom, let node = design?.node(t.id), node.runs != from.runs {
            t.undos.append(from)
            t.redos = []
            t.joining = false
        }
        t.nestedFrom = nil
        Editing.gestureBase = design
    }

    static func typingGestureCancelled(_ t: Typing) {
        guard t.nested > 0 else { return }
        if let base = Editing.gestureBase { design = base }
        t.nested = 0
        t.nestedFrom = nil
    }

    // MARK: The Format menu

    /// The Mac's Format menu: each acts on the letters picked out while typing, on what is typed
    /// next where only the caret is, or on every letter of the selected texts.
    public enum TextFormat: Sendable {
        case bold, italic, underline, strikethrough, bigger, smaller, bulletList, numberList
    }

    /// Whether there is text to style: some being typed into, or text layers selected (the
    /// Mac's canStyleText).
    public static func canFormat(_ ids: [UUID]) -> Bool {
        guard !isReadOnly, let doc = design else { return false }
        return typing != nil || ids.contains { doc.node($0)?.kind == .text }
    }

    /// The letters a command of the Format menu goes by: those picked out while typing, the
    /// one before the caret, or every letter of the selected text layers.
    private static func lettersToFormat(_ ids: [UUID]) -> [Letters] {
        guard let doc = design else { return [] }
        if let t = typing, let node = doc.node(t.id) { return node.letters(in: t.picked) }
        return ids.compactMap { doc.node($0) }.filter { $0.kind == .text }.flatMap { $0.letters() }
    }

    /// Bold, italic, underline or a list made, or taken away when every letter has it; or the
    /// letters a point bigger or smaller, each keeping its size beside the others. Answers
    /// whether there was text to do it to.
    @discardableResult public static func format(_ f: TextFormat, _ ids: [UUID]) -> Bool {
        guard canFormat(ids) else { return false }
        let letters = lettersToFormat(ids)
        guard !letters.isEmpty else { return false }
        let change: (inout Letters) -> Void
        switch f {
        case .bold:
            let bold = !letters.allSatisfy { Fonts.isBold($0.face, of: $0.family) }
            change = { $0.face = Fonts.face($0.face, of: $0.family, bold: bold) }
        case .italic:
            let italic = !letters.allSatisfy { Fonts.isItalic($0.face, of: $0.family) }
            change = { $0.face = Fonts.face($0.face, of: $0.family, italic: italic) }
        case .underline:
            let on = !letters.allSatisfy(\.underline)
            change = { $0.underline = on }
        case .strikethrough:
            let on = !letters.allSatisfy(\.strikethrough)
            change = { $0.strikethrough = on }
        case .bulletList, .numberList:
            let kind: TextList = f == .bulletList ? .bullet : .number
            let on = !letters.allSatisfy { $0.list == kind }
            change = { $0.list = on ? kind : nil }
        case .bigger, .smaller:
            let step: CGFloat = f == .bigger ? 1 : -1
            if restyleTyped({ $0.size = max(1, $0.size + step) }, caret: true) { return true }
            edit { d in for id in ids { d.update(id) { n in grow(&n, by: step) } } }
            return true
        }
        if restyleTyped(change, caret: true) { return true }
        edit { d in
            for id in ids {
                d.update(id) { n in
                    guard n.kind == .text else { return }
                    n.restyleLetters(in: nil, change)
                    n.refit()
                }
            }
        }
        return true
    }

    /// A text's letters, and every one with a size of its own, `step` points bigger (the Mac's
    /// Node.growLetters, in Store/TextOperations.swift).
    private static func grow(_ n: inout Node, by step: CGFloat) {
        guard n.kind == .text else { return }
        let size = n.style?.size ?? 24
        n.style?.size = max(1, size + step)
        n.spans = n.spans.map { $0.map { span in
            var s = span
            s.look.size = span.look.size.map { max(1, $0 + step) }
            return s
        } }
        n.refit()
    }

    // MARK: Where the letters are

    /// The text typed into as the canvas shows it while it is typed into (straight, for one on
    /// a curve, as the Mac's CurvedText.straight), and the design as seen, which it lies in.
    static func typedNode() -> (node: Node, doc: BezzleDocument, id: UUID)? {
        guard let t = typing, let doc = seen ?? design, var node = doc.node(t.id), node.kind == .text else { return nil }
        if node.isCurved { node = LetterFlights.straight(node, frame: node.frame).node }
        return (node, doc, t.id)
    }

    /// A point of a text's own, from its frame's top left, on the canvas.
    private static func onCanvas(_ q: CGPoint, of node: Node, in doc: BezzleDocument, id: UUID) -> CGPoint {
        let p = CGPoint(x: node.frame.minX + q.x, y: node.frame.minY + q.y)
        let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
        return doc.shown(Perspective.shown(Geometry.rotated(p, about: center, by: node.rotation), of: node), inParentOf: id)
    }

    /// A point of the canvas in a text's own coordinates, from its frame's top left; nil where
    /// it is seen edge on.
    private static func inText(_ p: CGPoint, of node: Node, in doc: BezzleDocument, id: UUID) -> CGPoint? {
        guard let parent = doc.placed(p, inParentOf: id), let flat = Perspective.flat(parent, of: node) else { return nil }
        let l = Geometry.local(flat, in: node.frame, rotation: node.rotation)
        return CGPoint(x: l.x + node.frame.width / 2, y: l.y + node.frame.height / 2)
    }

    /// Where some letters are along their lines, as the host lays them: each line they are on,
    /// and where they begin and end along it.
    private static func boxes(_ laid: TextLayout.Laid, _ s: Int, _ e: Int) -> [(line: Int, left: CGFloat, right: CGFloat)] {
        guard e > s, laid.id != 0 else { return [] }
        var out = [Double](repeating: 0, count: 64 * 3)
        let n = out.withUnsafeMutableBufferPointer { Int(bz_text_boxes(Int32(laid.id), Int32(s), Int32(e), $0.baseAddress, 64)) }
        return (0..<min(n, 64)).map { (Int(out[$0 * 3]), CGFloat(out[$0 * 3 + 1]), CGFloat(out[$0 * 3 + 2])) }
    }

    /// The line letter `i` (or the caret before it) is on.
    private static func line(of i: Int, in laid: TextLayout.Laid) -> Int {
        var k = 0
        for (j, l) in laid.lines.enumerated() where l.start <= i { k = j }
        return k
    }

    /// Whether line `k` is of a paragraph read from right to left, as Text Kit takes it, and the
    /// host sets it (host.cpp's rightToLeft): by its first letter that reads one way or the other.
    private static func backwards(_ k: Int, in laid: TextLayout.Laid) -> Bool {
        let units = Array(laid.string.utf16)
        func ends(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x2029 || u == 0x85 || (0x1C...0x1E).contains(u) }
        var start = min(laid.lines[k].start, units.count)
        while start > 0, !ends(units[start - 1]) { start -= 1 }
        var i = start
        while i < units.count, !ends(units[i]) {
            let u = units[i]
            if (0x0590...0x08FF).contains(u) || (0xFB1D...0xFDFF).contains(u) || (0xFE70...0xFEFE).contains(u) { return true }
            if (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) || ((0xC0...0x24F).contains(u) && u != 0xD7 && u != 0xF7)
                || (0x370...0x58F).contains(u) || (0x900...0x1FFF).contains(u) || (0x3040...0xD7FF).contains(u) { return false }
            i += 1
        }
        return false
    }

    /// How far along line `k` the caret before letter `i` stands: after the letters before it,
    /// on their left where the line reads from right to left.
    private static func caretX(_ i: Int, line k: Int, in laid: TextLayout.Laid, node: Node) -> CGFloat {
        let line = laid.lines[k]
        let back = backwards(k, in: laid)
        if i > line.start, let b = boxes(laid, line.start, i).first(where: { $0.line == k }) { return back ? b.left : b.right }
        if let b = boxes(laid, i, i + 1).first(where: { $0.line == k }) { return back ? b.right : b.left }
        // A line with no letters: where its alignment would put them, an item of a list's further in.
        switch node.style?.align ?? .left {
        case .center: return line.indent + (node.frame.width - line.indent) / 2
        case .right: return node.frame.width
        default: return line.indent
        }
    }

    /// The last place the caret can stand on line `k`: before the break or the space it wraps at.
    private static func lineEnd(_ k: Int, in laid: TextLayout.Laid, length: Int) -> Int {
        let line = laid.lines[k]
        var end = min(line.end, length)
        if k < laid.lines.count - 1, end > line.start { end -= 1 }
        return max(end, line.start)
    }

    /// The place on line `k` nearest `x` along it, never inside a letter made of several.
    private static func index(onLine k: Int, x: CGFloat, in laid: TextLayout.Laid, node: Node) -> Int {
        let words = (node.text ?? "") as NSString
        let lo = laid.lines[k].start, hi = lineEnd(k, in: laid, length: words.length)
        // Along the way the line reads: leftward where it reads from right to left.
        let way: CGFloat = backwards(k, in: laid) ? -1 : 1
        var a = lo, b = hi
        while a < b {
            let m = (a + b) / 2
            if way * caretX(m, line: k, in: laid, node: node) < way * x { a = m + 1 } else { b = m }
        }
        var i = a
        if i > lo, way * (x - caretX(i - 1, line: k, in: laid, node: node)) < way * (caretX(i, line: k, in: laid, node: node) - x) { i -= 1 }
        if i > 0, i < words.length {
            let whole = words.rangeOfComposedCharacterSequence(at: i)
            if whole.location < i { i = NSMaxRange(whole) - i < i - whole.location ? NSMaxRange(whole) : whole.location }
        }
        return i
    }

    /// The letter, or the place between two, at a point of the canvas, as a click on the text
    /// typed into puts the caret there; nil away from it (`slack` round it, in canvas points).
    public static func typingIndex(at p: CGPoint, slack: CGFloat = 0) -> Int? {
        guard let (node, doc, id) = typedNode(), let q = inText(p, of: node, in: doc, id: id) else { return nil }
        let box = CGRect(origin: .zero, size: node.frame.size).insetBy(dx: -slack, dy: -slack)
        guard slack < 0 || box.contains(q) else { return nil }
        let laid = TextLayout.layout(node)
        guard !laid.lines.isEmpty else { return 0 }
        let y = q.y - TextLayout.offset(node)
        let k = laid.lines.firstIndex { y < $0.top + $0.height } ?? laid.lines.count - 1
        return index(onLine: k, x: q.x, in: laid, node: node)
    }

    /// Whether a point of the canvas is on the text typed into, `slack` round it (canvas points):
    /// where a press puts the caret and the pointer is an I-beam.
    public static func typingCovers(_ p: CGPoint, slack: CGFloat) -> Bool {
        guard let (node, doc, id) = typedNode(), let q = inText(p, of: node, in: doc, id: id) else { return false }
        return CGRect(origin: .zero, size: node.frame.size).insetBy(dx: -slack, dy: -slack).contains(q)
    }

    /// Where the caret goes a line up or down from letter `i` (`by` lines), keeping as far along
    /// as `x` (as far as it is now, with none); past the first or last line, to the very start or
    /// end. Answers the place, and how far along to keep to.
    public static func typingLine(from i: Int, by step: Int, x: CGFloat?) -> (index: Int, x: CGFloat) {
        guard let (node, _, _) = typedNode() else { return (i, x ?? 0) }
        let laid = TextLayout.layout(node)
        let length = ((node.text ?? "") as NSString).length
        guard !laid.lines.isEmpty else { return (i, x ?? 0) }
        let k = line(of: i, in: laid)
        let along = x ?? caretX(i, line: k, in: laid, node: node)
        let to = k + step
        if to < 0 { return (0, along) }
        if to >= laid.lines.count { return (length, along) }
        return (index(onLine: to, x: along, in: laid, node: node), along)
    }

    /// The start, or the end, of the line letter `i` is on.
    public static func typingLineEdge(from i: Int, end: Bool) -> Int {
        guard let (node, _, _) = typedNode() else { return i }
        let laid = TextLayout.layout(node)
        guard !laid.lines.isEmpty else { return i }
        let k = line(of: i, in: laid)
        return end ? lineEnd(k, in: laid, length: ((node.text ?? "") as NSString).length) : laid.lines[k].start
    }

    /// The word letter `i` is in (or the run of spaces or the mark), as a double click picks it out.
    public static func typingWord(at i: Int) -> NSRange {
        let words = (typingWords ?? "") as NSString
        guard words.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(max(i, 0), words.length - 1)
        func kind(_ k: Int) -> Int {
            guard let u = UnicodeScalar(words.character(at: k)) else { return 0 }
            if CharacterSet.alphanumerics.contains(u) || u == "'" || u == "’" || u == "_" { return 0 }
            if CharacterSet.whitespaces.contains(u) { return 1 }
            if CharacterSet.newlines.contains(u) { return 3 }
            return 2
        }
        var at = start
        // Just after a word, as a click on a letter's right half puts it: that word.
        if kind(at) != 0, at > 0, kind(at - 1) == 0 { at -= 1 }
        let want = kind(at)
        guard want != 3 else { return NSRange(location: at, length: 1) }
        var a = at, b = at + 1
        while a > 0, kind(a - 1) == want { a -= 1 }
        while b < words.length, kind(b) == want { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Where the caret goes a word on or back from `i`, as Ctrl and the arrows move it on Windows:
    /// to the start of the next word, or of the word it is in or the one before.
    public static func typingWordStep(from i: Int, forward: Bool) -> Int {
        let words = (typingWords ?? "") as NSString
        func isWord(_ k: Int) -> Bool {
            guard k >= 0, k < words.length, let u = UnicodeScalar(words.character(at: k)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "'" || u == "’" || u == "_"
        }
        var k = min(max(i, 0), words.length)
        if forward {
            while k < words.length, isWord(k) { k += 1 }
            while k < words.length, !isWord(k) { k += 1 }
        } else {
            while k > 0, !isWord(k - 1) { k -= 1 }
            while k > 0, isWord(k - 1) { k -= 1 }
        }
        return k
    }

    /// The paragraph letter `i` is in, as a triple click picks it out.
    public static func typingParagraph(at i: Int) -> NSRange {
        let words = (typingWords ?? "") as NSString
        return words.paragraphRange(for: NSRange(location: min(max(i, 0), words.length), length: 0))
    }

    /// One step on from `i` by a whole letter (an emoji is one, though two in UTF-16).
    public static func typingLetterStep(from i: Int, forward: Bool) -> Int {
        let words = (typingWords ?? "") as NSString
        if forward {
            guard i < words.length else { return words.length }
            return NSMaxRange(words.rangeOfComposedCharacterSequence(at: max(i, 0)))
        }
        guard i > 0 else { return 0 }
        return words.rangeOfComposedCharacterSequence(at: min(i, words.length) - 1).location
    }

    // MARK: Marks

    /// What the canvas marks over the text typed into, on the canvas: the caret, or each line's
    /// worth of the letters picked out, as four corners; and the misspelt words, and words said
    /// twice when grammar is checked too, each a line's worth.
    public struct TypingMarks {
        public let caret: [CGPoint]?
        public let picked: [[CGPoint]]
        public let misspelt: [[CGPoint]]
        public let repeated: [[CGPoint]]
    }

    /// The marks at `zoom`, for a caret a pixel wide (at least) on the screen.
    public static func typingMarks(zoom: Double) -> TypingMarks? {
        guard let t = typing, let (node, doc, id) = typedNode() else { return nil }
        let laid = TextLayout.layout(node)
        let words = node.text ?? ""
        let length = (words as NSString).length
        let picked = clamped(t.picked, length)
        let down = TextLayout.offset(node)
        var caret: [CGPoint]?
        if picked.length == 0 {
            let top: CGFloat, height: CGFloat, x: CGFloat
            if laid.lines.isEmpty {
                let style = node.style ?? TextStyle()
                top = 0
                height = style.lineSpacing ?? Fonts.naturalLineHeight(style)
                switch style.align {
                case .center: x = node.frame.width / 2
                case .right: x = node.frame.width
                default: x = 0
                }
            } else {
                let k = line(of: picked.location, in: laid)
                top = laid.lines[k].top
                height = laid.lines[k].height
                x = caretX(picked.location, line: k, in: laid, node: node)
            }
            let w = CGFloat(max(1 / max(zoom, 0.01), 1)) / 2
            caret = [CGPoint(x: x - w, y: top + down), CGPoint(x: x + w, y: top + down),
                     CGPoint(x: x + w, y: top + down + height), CGPoint(x: x - w, y: top + down + height)]
                .map { onCanvas($0, of: node, in: doc, id: id) }
        }
        let lit = picked.length > 0 ? Finder.quads(of: picked, in: node, id: id, doc: doc) : []
        var misspelt: [[CGPoint]] = [], repeated: [[CGPoint]] = []
        if checksSpelling {
            let found = typingSpelling(words)
            // The word the caret is at the end of is still being typed: it is checked once it is done.
            func done(_ r: NSRange) -> Bool { !(picked.length == 0 && NSMaxRange(r) == picked.location) }
            let ns = words as NSString
            for r in found.misspelt where done(r) && NSMaxRange(r) <= length && !t.ignored.contains(ns.substring(with: r)) {
                misspelt += Finder.quads(of: r, in: node, id: id, doc: doc)
            }
            if checksGrammar {
                for r in found.repeated where done(r) && NSMaxRange(r) <= length { repeated += Finder.quads(of: r, in: node, id: id, doc: doc) }
            }
        }
        return TypingMarks(caret: caret, picked: lit, misspelt: misspelt, repeated: repeated)
    }

    // MARK: Spelling while typing

    /// Whether misspelt words are marked as they are typed, as last set (the Mac's Edit menu
    /// keeps it, by the same name).
    public static var checksSpelling: Bool {
        get { UserDefaults.standard.object(forKey: "BezzleChecksSpelling") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "BezzleChecksSpelling") }
    }

    /// Whether grammar is checked with the spelling: Windows' spell checkers know of words said
    /// twice, which are marked then.
    public static var checksGrammar: Bool {
        get { UserDefaults.standard.bool(forKey: "BezzleChecksGrammar") }
        set { UserDefaults.standard.set(newValue, forKey: "BezzleChecksGrammar") }
    }

    nonisolated(unsafe) private static var spelt: (words: String, language: String?, misspelt: [NSRange], repeated: [NSRange])?

    /// The misspelt words of the text typed into, and those said twice, in the language it is
    /// written in; kept while its words stay the same.
    private static func typingSpelling(_ words: String) -> (language: String?, misspelt: [NSRange], repeated: [NSRange]) {
        if let spelt, spelt.words == words { return (spelt.language, spelt.misspelt, spelt.repeated) }
        let found = Spelling.check(words)
        let repeated = Spelling.repeats(words, in: found.language)
        spelt = (words, found.language, found.ranges, repeated)
        return (found.language, found.ranges, repeated)
    }

    /// A misspelt word at letter `i` of the text typed into (or a word said twice, with grammar
    /// checked), and how it might be spelt, likeliest first; for the right-click menu.
    public static func typingMisspelt(at i: Int) -> (range: NSRange, word: String, guesses: [String], repeated: Bool)? {
        guard let t = typing, checksSpelling, let words = typingWords else { return nil }
        let found = typingSpelling(words)
        let ns = words as NSString
        func holds(_ r: NSRange) -> Bool { i >= r.location && i <= NSMaxRange(r) && NSMaxRange(r) <= ns.length }
        if let r = found.misspelt.first(where: holds), !t.ignored.contains(ns.substring(with: r)) {
            let word = ns.substring(with: r)
            return (r, word, Spelling.guesses(word, in: found.language), false)
        }
        if checksGrammar, let r = found.repeated.first(where: holds) {
            return (r, ns.substring(with: r), [], true)
        }
        return nil
    }

    /// Leaves a misspelt word as it is while typing goes on.
    public static func ignoreTyped(_ word: String) { typing?.ignored.insert(word) }

    /// Adds a misspelt word to the dictionary.
    public static func learnTyped(_ word: String) {
        guard let words = typingWords else { return }
        Spelling.learn(word, in: typingSpelling(words).language)
        spelt = nil
    }

    /// Puts `words` in place of some letters of the text typed into, as one change of the
    /// typing (a spelling chosen from the right-click menu; nothing for a word said twice, with
    /// the space before it). Answers the words and where the caret is then.
    public static func replaceTyped(_ range: NSRange, with words: String) -> (words: String, picked: NSRange)? {
        beginChange()
        guard let t = typing, let node = design?.node(t.id) else { return nil }
        let length = ((node.text ?? "") as NSString).length
        var r = clamped(range, length)
        // A word said twice goes with the space before it.
        if words.isEmpty, r.location > 0, ((node.text ?? "") as NSString).character(at: r.location - 1) == 32 {
            r = NSRange(location: r.location - 1, length: r.length + 1)
        }
        record(t)
        t.joining = false
        t.typed = nil
        edit { d in d.update(t.id) { n in replace(&n, in: r, with: words); n.refit() } }
        t.picked = NSRange(location: r.location + (words as NSString).length, length: 0)
        t.expected = t.picked
        return (typingWords ?? "", t.picked)
    }

    /// Return on an empty item of a list, or Backspace at the start of one, ends the list there,
    /// as on the Mac. Answers whether it did, when the key is not to type.
    public static func typingEndsList(onReturn: Bool) -> Bool {
        guard let t = typing, t.picked.length == 0, let node = design?.node(t.id) else { return false }
        let words = (node.text ?? "") as NSString
        let caret = min(t.picked.location, words.length)
        let paragraph = words.paragraphRange(for: NSRange(location: caret, length: 0))
        let said = words.substring(with: paragraph).trimmingCharacters(in: .newlines)
        let runs = node.runs
        // The empty line at the end has no letters: what is typed there says.
        let look: TextLook? = paragraph.length > 0 && paragraph.location < words.length
            ? TextSpan.look(at: paragraph.location, in: runs)
            : t.typed ?? (runs.isEmpty ? nil : TextSpan.look(at: max(caret - 1, 0), in: runs))
        let ends = onReturn ? said.isEmpty : caret == paragraph.location
        guard look?.list != nil, ends else { return false }
        return restyleTyped({ $0.list = nil }, caret: true)
    }

    /// Whether the text typed into is in a post of a deck, where Tab goes on to the next post.
    public static var typingInPost: Bool {
        guard let t = typing else { return false }
        return design?.post(of: t.id)?.post != nil
    }

    /// In a deck, the same text in the next post (or the one before), to go on typing in, as Tab
    /// goes on on the Mac: its deck, which post, and its id; nil past the first or the last, or
    /// outside a deck.
    public static func typingNextPost(forward: Bool) -> (deck: UUID, post: Int, id: UUID)? {
        guard let t = typing, let doc = design, let (deck, post) = doc.post(of: t.id), let post,
              let i = deck.posts.firstIndex(of: post) else { return nil }
        let j = i + (forward ? 1 : -1)
        guard deck.posts.indices.contains(j) else { return nil }
        let next = t.id.mixed(Deck.key(from: post, to: deck.posts[j]))
        return (deck.id, deck.posts[j], next)
    }

    /// Whether a text left empty is kept when typing ends: one in a grid's cell or a deck's
    /// post holds that cell's, or that post's, words.
    public static func keepsWhenEmpty(_ id: UUID) -> Bool {
        guard let doc = design else { return false }
        return doc.grid(holding: id) != nil || doc.post(of: id)?.post != nil
    }
}
