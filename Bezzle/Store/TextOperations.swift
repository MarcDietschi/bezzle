import AppKit

// MARK: - Styling letters

extension DocumentStore {
    /// The letters picked out in the text being typed into, when there are any: those the text
    /// card and its colour change, rather than the whole layer.
    var pickedLetters: NSRange? {
        guard editingText != nil, restyleTyped != nil, typingSelection.length > 0 else { return nil }
        return typingSelection
    }

    /// How the letters the text card changes look, a run's worth each: those picked out while
    /// typing, or every letter of `nodes`.
    func lettersShown(in nodes: [Node]) -> [Letters] {
        if let range = pickedLetters, let id = editingText, let node = node(id) { return node.letters(in: range) }
        return nodes.filter { $0.kind == .text }.flatMap { $0.letters() }
    }

    /// Changes how letters look: those picked out while typing, or with `typing` what is typed
    /// next where only the caret is; otherwise every letter of the selected text layers, which
    /// changes their own style and colour.
    func restyleLetters(_ action: LocalizedStringResource, typing: Bool = false, _ change: @escaping (inout Letters) -> Void) {
        if editingText != nil, let restyle = restyleTyped, typing || typingSelection.length > 0 {
            restyle(action, change)
            return
        }
        updateSelection(action) { n in n.restyleLetters(in: nil, change) }
    }

    /// The letters a keyboard command such as Bold acts on: those picked out while typing, those
    /// before the caret, or every letter of the selected text layers.
    private var lettersToToggle: [Letters] {
        if let id = editingText, let node = node(id) { return node.letters(in: typingSelection) }
        return lettersShown(in: selection.compactMap { node($0) })
    }

    /// Whether there is text to style: some being typed into, or text layers selected.
    var canStyleText: Bool {
        !isReadOnly && (editingText != nil || selection.contains { node($0)?.kind == .text })
    }

    func toggleBold() {
        let letters = lettersToToggle
        guard canStyleText, !letters.isEmpty else { return }
        let bold = !letters.allSatisfy { Fonts.isBold($0.face, of: $0.family) }
        restyleLetters(bold ? "Bold" : "Remove Bold", typing: true) { $0.face = Fonts.face($0.face, of: $0.family, bold: bold) }
    }

    func toggleItalic() {
        let letters = lettersToToggle
        guard canStyleText, !letters.isEmpty else { return }
        let italic = !letters.allSatisfy { Fonts.isItalic($0.face, of: $0.family) }
        restyleLetters(italic ? "Italic" : "Remove Italic", typing: true) { $0.face = Fonts.face($0.face, of: $0.family, italic: italic) }
    }

    func toggleUnderline() {
        let letters = lettersToToggle
        guard canStyleText, !letters.isEmpty else { return }
        let on = !letters.allSatisfy(\.underline)
        restyleLetters(on ? "Underline" : "Remove Underline", typing: true) { $0.underline = on }
    }

    func toggleStrikethrough() {
        let letters = lettersToToggle
        guard canStyleText, !letters.isEmpty else { return }
        let on = !letters.allSatisfy(\.strikethrough)
        restyleLetters(on ? "Strikethrough" : "Remove Strikethrough", typing: true) { $0.strikethrough = on }
    }

    /// Makes the paragraphs picked out while typing, or every paragraph of the selected texts,
    /// items of a list of this kind, or no longer when they all are.
    func toggleList(_ kind: TextList) {
        let letters = lettersToToggle
        guard canStyleText, !letters.isEmpty else { return }
        let on = !letters.allSatisfy { $0.list == kind }
        let action: LocalizedStringResource = !on ? "Remove List" : kind == .bullet ? "Bulleted List" : "Numbered List"
        restyleLetters(action, typing: true) { $0.list = on ? kind : nil }
    }

    /// Makes the letters a point bigger, or smaller; each keeps its size beside the others.
    func growLetters(by step: CGFloat) {
        guard canStyleText else { return }
        let action: LocalizedStringResource = step > 0 ? "Bigger" : "Smaller"
        if editingText != nil, restyleTyped != nil {
            restyleLetters(action, typing: true) { $0.size = max(1, $0.size + step) }
            return
        }
        updateSelection(action) { n in n.growLetters(by: step) }
    }
}

nonisolated extension Node {
    /// The layer's letters, and every one with a size of its own, `step` points bigger.
    mutating func growLetters(by step: CGFloat) {
        guard kind == .text else { return }
        let size = style?.size ?? 24
        style?.size = max(1, size + step)
        spans = spans.map { $0.map { span in
            var s = span
            s.look.size = span.look.size.map { max(1, $0 + step) }
            return s
        } }
    }
}

// MARK: - Finding and replacing

/// Looking through a design's words for some, or for misspelt ones, and putting others in
/// their place. The design's own find bar shows it (`FindBar`), and the canvas marks what it finds.
@MainActor @Observable
final class TextFinder {
    /// Some letters found: in which text layer, and where among its words as typed, in UTF-16.
    struct Match: Hashable {
        let layer: UUID
        let range: NSRange
    }

    var query = ""
    var replacement = ""
    var matchCase = false
    var wholeWords = false
    /// Looking for misspelt words rather than for `query`.
    var spelling = false
    /// Which match is picked out, by its place among them all.
    var current: Int?
    /// Raised to give the find field the keyboard.
    var focus = 0
    /// Raised when a word is ignored or learnt, so the words are checked again.
    var checked = 0

    @ObservationIgnored let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    @ObservationIgnored private var kept: (doc: BezzleDocument, key: Key, matches: [Match])?
    @ObservationIgnored private var misspelt: [String: [NSRange]] = [:]

    private struct Key: Equatable {
        let query: String, matchCase: Bool, wholeWords: Bool, spelling: Bool, checked: Int
    }

    /// Everything found in a design, in reading order: artboard by artboard, and on each from the
    /// top down and from the left.
    func matches(in doc: BezzleDocument) -> [Match] {
        let key = Key(query: query, matchCase: matchCase, wholeWords: wholeWords, spelling: spelling, checked: checked)
        if let kept, kept.key == key, kept.doc == doc { return kept.matches }
        if kept?.key.checked != checked { misspelt = [:] }
        var out: [Match] = []
        if spelling || !query.isEmpty {
            for (id, words) in Self.texts(in: doc) {
                for range in spelling ? misspellings(in: words) : found(in: words) { out.append(Match(layer: id, range: range)) }
            }
        }
        kept = (doc, key, out)
        return out
    }

    private func found(in words: String) -> [NSRange] {
        let ns = words as NSString
        var out: [NSRange] = []
        var from = 0
        let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        while from < ns.length {
            let r = ns.range(of: query, options: options, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            if !wholeWords || Self.isWhole(r, in: ns) { out.append(r) }
            from = NSMaxRange(r)
        }
        return out
    }

    private static func isWhole(_ r: NSRange, in s: NSString) -> Bool {
        let letters = CharacterSet.alphanumerics
        func wordy(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let scalar = Unicode.Scalar(s.character(at: i)) else { return false }
            return letters.contains(scalar)
        }
        return !wordy(r.location - 1) && !wordy(NSMaxRange(r))
    }

    /// The misspelt words of a text, each checked in the language the text is written in.
    private func misspellings(in words: String) -> [NSRange] {
        if let known = misspelt[words] { return known }
        let found = NSSpellChecker.shared.check(words, range: NSRange(location: 0, length: (words as NSString).length),
                                                types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil,
                                                inSpellDocumentWithTag: spellTag, orthography: nil, wordCount: nil)
        let out = found.filter { $0.resultType == .spelling && $0.range.length > 0 }.map(\.range)
        if misspelt.count > 5000 { misspelt = [:] }
        misspelt[words] = out
        return out
    }

    /// The language a text is written in, as the spelling checker makes it out.
    func language(of words: String) -> String? {
        var orthography: NSOrthography?
        _ = NSSpellChecker.shared.check(words, range: NSRange(location: 0, length: (words as NSString).length),
                                        types: NSTextCheckingResult.CheckingType.orthography.rawValue, options: nil,
                                        inSpellDocumentWithTag: spellTag, orthography: &orthography, wordCount: nil)
        return orthography?.dominantLanguage
    }

    /// The text layers whose words can be seen, in reading order, with their words.
    static func texts(in doc: BezzleDocument) -> [(UUID, String)] {
        struct Found { let id: UUID, words: String, top: Int, post: Int, at: CGPoint }
        var found: [Found] = []
        func visit(_ n: Node, top: Int, post: Int, origin: CGPoint) {
            guard !n.hidden else { return }
            let at = origin + n.frame.origin
            if n.kind == .text, let words = n.text, !words.isEmpty {
                found.append(Found(id: n.id, words: words, top: top, post: post, at: at))
            }
            for c in n.children { visit(c, top: top, post: post, origin: n.isGroup ? at : origin) }
        }
        let tops = doc.nodes.enumerated().sorted { a, b in
            let fa = a.element.frame, fb = b.element.frame
            return (fa.minY.rounded(), fa.minX, a.offset) < (fb.minY.rounded(), fb.minX, b.offset)
        }
        for (rank, (_, top)) in tops.enumerated() {
            guard !top.hidden else { continue }
            if top.kind == .text, let words = top.text, !words.isEmpty {
                found.append(Found(id: top.id, words: words, top: rank, post: 0, at: .zero))
                continue
            }
            let posts = top.posts
            for c in top.children {
                // The design behind a deck's posts is not seen; each post is.
                if top.isDeck, c.post == nil { continue }
                let post = c.post.flatMap { posts.firstIndex(of: $0) } ?? 0
                visit(c, top: rank, post: post, origin: top.isArtboard ? top.frame.origin : .zero)
            }
        }
        found.sort { a, b in
            (a.top, a.post, (a.at.y / 4).rounded(), a.at.x) < (b.top, b.post, (b.at.y / 4).rounded(), b.at.x)
        }
        return found.map { ($0.id, $0.words) }
    }
}

extension DocumentStore {
    /// Opens the find bar, or turns it to looking for misspelt words. With letters picked out
    /// while typing, it looks for them.
    func openFind(spelling: Bool = false) {
        let finder = self.finder ?? TextFinder()
        if !spelling, let id = editingText, typingSelection.length > 0, let words = node(id)?.text {
            let ns = words as NSString
            if NSMaxRange(typingSelection) <= ns.length { finder.query = ns.substring(with: typingSelection) }
        }
        finder.spelling = spelling
        finder.current = nil
        finder.focus += 1
        self.finder = finder
        if spelling { findNext() }
    }

    func closeFind() {
        finder = nil
    }

    /// What the find bar finds in the design as it is now.
    var foundText: [TextFinder.Match] { finder?.matches(in: doc) ?? [] }

    /// Picks out the next thing found, or the one before, showing its layer.
    func findNext(forward: Bool = true) {
        guard let finder else { return }
        let matches = foundText
        guard !matches.isEmpty else { finder.current = nil; return }
        let i: Int
        if let c = finder.current, c < matches.count {
            i = (c + (forward ? 1 : matches.count - 1)) % matches.count
        } else if let at = selection.first, let j = matches.firstIndex(where: { $0.layer == at }) {
            // From the layer selected.
            i = forward ? j : (j + matches.count - 1) % matches.count
        } else {
            i = forward ? 0 : matches.count - 1
        }
        pick(i, of: matches)
    }

    private func pick(_ i: Int, of matches: [TextFinder.Match]) {
        guard let finder, matches.indices.contains(i) else { return }
        finder.current = i
        let m = matches[i]
        if selection != [m.layer] { selection = [m.layer] }
        show(m.layer)
    }

    /// The thing found that is picked out, if it is still there.
    var currentFind: TextFinder.Match? {
        guard let c = finder?.current else { return nil }
        let matches = foundText
        return matches.indices.contains(c) ? matches[c] : nil
    }

    /// Puts the replacement in place of what is picked out, and goes on to the next.
    func replaceFound(with replacement: String? = nil) {
        guard let finder else { return }
        guard let m = currentFind else { findNext(); return }
        let words = replacement ?? finder.replacement
        let at = finder.current ?? 0
        update([m.layer], finder.spelling ? "Correct Spelling" : "Replace") { $0.replaceText(in: m.range, with: words) }
        let after = foundText
        if after.isEmpty { finder.current = nil } else { pick(min(at, after.count - 1), of: after) }
    }

    /// Puts the replacement in place of everything found, as one step. Returns how many.
    @discardableResult
    func replaceAllFound() -> Int {
        guard let finder, !finder.spelling else { return 0 }
        let matches = foundText
        guard !matches.isEmpty else { return 0 }
        var byLayer: [UUID: [NSRange]] = [:]
        for m in matches { byLayer[m.layer, default: []].append(m.range) }
        let words = finder.replacement
        edit("Replace All") { doc in
            for (id, ranges) in byLayer {
                doc.update(id) { n in
                    // From the end, so the places of those before stay as they are.
                    for r in ranges.sorted(by: { $0.location > $1.location }) { n.replaceText(in: r, with: words) }
                    n.refit()
                }
            }
        }
        finder.current = nil
        return matches.count
    }

    /// The misspelt word picked out, as it is spelt.
    var misspeltWord: String? {
        guard finder?.spelling == true, let m = currentFind, let words = node(m.layer)?.text else { return nil }
        let ns = words as NSString
        return NSMaxRange(m.range) <= ns.length ? ns.substring(with: m.range) : nil
    }

    /// How the misspelt word picked out might be spelt, likeliest first.
    var spellingGuesses: [String] {
        guard let finder, finder.spelling, let m = currentFind, let words = node(m.layer)?.text else { return [] }
        return NSSpellChecker.shared.guesses(forWordRange: m.range, in: words, language: finder.language(of: words),
                                             inSpellDocumentWithTag: finder.spellTag) ?? []
    }

    /// Leaves the misspelt word picked out as it is, here and everywhere in this design while it is open.
    func ignoreMisspelt() {
        guard let finder, let word = misspeltWord else { return }
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: finder.spellTag)
        moveOnAfterSpelling()
    }

    /// Adds the misspelt word picked out to the Mac's dictionary.
    func learnMisspelt() {
        guard let word = misspeltWord else { return }
        NSSpellChecker.shared.learnWord(word)
        moveOnAfterSpelling()
    }

    private func moveOnAfterSpelling() {
        guard let finder else { return }
        let at = finder.current ?? 0
        finder.checked += 1
        let after = foundText
        if after.isEmpty { finder.current = nil } else { pick(min(at, after.count - 1), of: after) }
    }
}
