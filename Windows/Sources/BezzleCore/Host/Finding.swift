import Foundation
import CBezzleHost

// MARK: - Finding and replacing

extension WindowsCore {
    /// Looking through the design's words for some, or for misspelt ones, and putting others in
    /// their place: the Mac's TextFinder with its part of DocumentStore (Store/TextOperations.swift),
    /// for the find bar (FindBar.swift) and the marks on the canvas. What is found and in which
    /// order is the shared `TextSearch`; spelling asks Windows' own spell checkers.
    public final class Finder {
        public var query = "" { didSet { if query != oldValue { current = nil } } }
        public var replacement = ""
        public var matchCase = false { didSet { current = nil } }
        public var wholeWords = false { didSet { current = nil } }
        /// Looking for misspelt words rather than for `query`.
        public var spelling = false { didSet { if spelling != oldValue { current = nil } } }
        /// Which match is picked out, by its place among them all.
        public internal(set) var current: Int?
        /// Raised when a word is ignored or learnt, so the words are checked again.
        private var checked = 0
        private var kept: (doc: BezzleDocument, key: Key, matches: [TextSearch.Match])?
        /// Each text's misspelt words, and the language it was checked in.
        private var misspelt: [String: (language: String?, ranges: [NSRange])] = [:]
        /// Words left as they are while the bar is open, as the Mac's spell document tag keeps them.
        private var ignored = Set<String>()

        private struct Key: Equatable {
            let query: String, matchCase: Bool, wholeWords: Bool, spelling: Bool, checked: Int
        }

        /// Everything found in the design as it is now, in reading order.
        func matches(in doc: BezzleDocument) -> [TextSearch.Match] {
            let key = Key(query: query, matchCase: matchCase, wholeWords: wholeWords, spelling: spelling, checked: checked)
            if let kept, kept.key == key, kept.doc == doc { return kept.matches }
            if kept?.key.checked != checked { misspelt = [:] }
            let out: [TextSearch.Match]
            if spelling {
                out = TextSearch.texts(in: doc).flatMap { id, words in
                    misspellings(in: words).ranges.map { TextSearch.Match(layer: id, range: $0) }
                }
            } else {
                out = TextSearch(query: query, matchCase: matchCase, wholeWords: wholeWords).matches(in: doc)
            }
            kept = (doc, key, out)
            return out
        }

        var matches: [TextSearch.Match] { WindowsCore.design.map(matches(in:)) ?? [] }

        /// How many things are found.
        public var count: Int { matches.count }

        /// The thing found that is picked out, if it is still there.
        var currentMatch: TextSearch.Match? {
            guard let current else { return nil }
            let all = matches
            return all.indices.contains(current) ? all[current] : nil
        }

        /// Picks out the next thing found, or the one before, from the one picked out or the
        /// layer selected. Answers its layer, to select and bring into sight.
        public func next(forward: Bool = true, from selection: [UUID]) -> UUID? {
            let all = matches
            guard !all.isEmpty else { current = nil; return nil }
            let i: Int
            if let c = current, c < all.count {
                i = (c + (forward ? 1 : all.count - 1)) % all.count
            } else if let at = selection.first, let j = all.firstIndex(where: { $0.layer == at }) {
                i = forward ? j : (j + all.count - 1) % all.count
            } else {
                i = forward ? 0 : all.count - 1
            }
            current = i
            return all[i].layer
        }

        /// Puts the replacement (or `words`) in place of what is picked out, and goes on to the
        /// next. Answers the layer then picked out.
        public func replace(with words: String? = nil, from selection: [UUID]) -> UUID? {
            guard let m = currentMatch else { return next(from: selection) }
            let words = words ?? replacement
            let at = current ?? 0
            WindowsCore.edit { doc in doc.update(m.layer) { n in n.replaceText(in: m.range, with: words); n.refit() } }
            let after = matches
            guard !after.isEmpty else { current = nil; return nil }
            current = min(at, after.count - 1)
            return after[current!].layer
        }

        /// Puts the replacement in place of everything found, as one step. Answers how many.
        @discardableResult public func replaceAll() -> Int {
            guard !spelling else { return 0 }
            let all = matches
            guard !all.isEmpty else { return 0 }
            let words = replacement
            WindowsCore.edit { $0.replace(all, with: words) }
            current = nil
            return all.count
        }

        // MARK: Spelling

        /// The misspelt word picked out, as it is spelt.
        public var misspeltWord: String? {
            guard spelling, let m = currentMatch, let words = WindowsCore.design?.node(m.layer)?.text else { return nil }
            let ns = words as NSString
            return NSMaxRange(m.range) <= ns.length ? ns.substring(with: m.range) : nil
        }

        /// How the misspelt word picked out might be spelt, likeliest first.
        public var guesses: [String] {
            guard let word = misspeltWord, let m = currentMatch, let words = WindowsCore.design?.node(m.layer)?.text else { return [] }
            return Spelling.guesses(word, in: misspellings(in: words).language)
        }

        /// Leaves the misspelt word picked out as it is, everywhere in the design, while the bar is open.
        public func ignore(from selection: [UUID]) -> UUID? {
            guard let word = misspeltWord else { return nil }
            ignored.insert(word)
            return moveOn(from: selection)
        }

        /// Adds the misspelt word picked out to the dictionary.
        public func learn(from selection: [UUID]) -> UUID? {
            guard let word = misspeltWord, let m = currentMatch, let words = WindowsCore.design?.node(m.layer)?.text else { return nil }
            Spelling.learn(word, in: misspellings(in: words).language)
            return moveOn(from: selection)
        }

        private func moveOn(from selection: [UUID]) -> UUID? {
            let at = current ?? 0
            checked += 1
            let after = matches
            guard !after.isEmpty else { current = nil; return nil }
            current = min(at, after.count - 1)
            return after[current!].layer
        }

        private func misspellings(in words: String) -> (language: String?, ranges: [NSRange]) {
            if let known = misspelt[words] { return known }
            var found = Spelling.check(words)
            let ns = words as NSString
            found.ranges.removeAll { NSMaxRange($0) <= ns.length && ignored.contains(ns.substring(with: $0)) }
            if misspelt.count > 5000 { misspelt = [:] }
            misspelt[words] = found
            return found
        }

        // MARK: Marks

        /// Something found, as the canvas marks it: the boxes its letters take, each a line's
        /// worth, as four corners on the canvas; whether it is the one picked out.
        public struct Mark {
            public let quads: [[CGPoint]]
            public let picked: Bool
        }

        /// What is found in `view` (on the canvas), but the words being typed into.
        public func marks(in view: CGRect, editing: UUID?) -> [Mark] {
            guard let doc = WindowsCore.seen else { return [] }
            let all = matches
            let picked = currentMatch
            var out: [Mark] = []
            for m in all where m.layer != editing {
                guard let node = doc.node(m.layer), node.kind == .text, let frame = doc.absoluteFrame(of: m.layer),
                      frame.insetBy(dx: -40, dy: -40).intersects(view) else { continue }
                out.append(Mark(quads: Self.quads(of: m.range, in: node, id: m.layer, doc: doc), picked: m == picked))
            }
            return out
        }

        /// The boxes some letters of a text take, each a line's worth, as four corners on the
        /// canvas (the Mac's CanvasView.quads).
        static func quads(of range: NSRange, in node: Node, id: UUID, doc: BezzleDocument) -> [[CGPoint]] {
            let laid = TextLayout.layout(node)
            guard laid.id != 0, !laid.lines.isEmpty else { return [] }
            var boxes = [Double](repeating: 0, count: 64 * 3)
            let count = boxes.withUnsafeMutableBufferPointer {
                Int(bz_text_boxes(Int32(laid.id), Int32(range.location), Int32(NSMaxRange(range)), $0.baseAddress, 64))
            }
            let down = TextLayout.offset(node)
            let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
            return (0..<min(count, 64)).compactMap { k in
                let line = Int(boxes[k * 3])
                guard laid.lines.indices.contains(line) else { return nil }
                let l = laid.lines[line]
                let r = CGRect(x: boxes[k * 3 + 1], y: Double(l.top), width: boxes[k * 3 + 2] - boxes[k * 3 + 1], height: Double(l.height))
                let box = r.offsetBy(dx: node.frame.minX, dy: node.frame.minY + down).insetBy(dx: -1, dy: 0)
                return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                    .map { doc.shown(Perspective.shown(Geometry.rotated($0, about: center, by: node.rotation), of: node), inParentOf: id) }
            }
        }
    }

    /// The find bar's, while it is open.
    public internal(set) static var finder: Finder?

    /// Opens the find bar, or turns it to looking for misspelt words.
    @discardableResult public static func openFind(spelling: Bool = false) -> Finder {
        let f = finder ?? Finder()
        f.spelling = spelling
        f.current = nil
        finder = f
        return f
    }

    public static func closeFind() { finder = nil }
}

// MARK: - Spelling

/// Windows' spell checkers, as the Mac's find bar asks NSSpellChecker: each text checked in the
/// language it is written in, made out as the one, of those the person reads and Bezzle's own,
/// in which the fewest of its words are misspelt.
enum Spelling {
    /// The languages to check in, those the person reads first.
    static let languages: [String] = {
        var bytes = [CChar](repeating: 0, count: 4096)
        let n = Int(bz_spell_languages(&bytes, Int32(bytes.count)))
        let list = String(decoding: bytes.prefix(min(n, bytes.count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let supported = list.split(separator: ",").map(String.init)
        guard !supported.isEmpty else { return [] }
        func base(_ tag: String) -> String { String(tag.lowercased().split(separator: "-").first ?? "") }
        var out: [String] = []
        for wanted in Locale.preferredLanguages + ["en-US", "de-CH", "fr-CH", "it-CH"] {
            // The exact one, else one of the same language.
            let pick = supported.first { $0.lowercased() == wanted.lowercased() } ?? supported.first { base($0) == base(wanted) }
            if let pick, !out.contains(pick) { out.append(pick) }
            if out.count == 4 { break }
        }
        return out
    }()

    static func check(_ words: String) -> (language: String?, ranges: [NSRange]) {
        let units = Array(words.utf16)
        guard !units.isEmpty else { return (nil, []) }
        var best: (language: String?, ranges: [NSRange])?
        for language in languages {
            var ranges = [Int32](repeating: 0, count: 2 * 512)
            let n = Int(language.withCString { tag in
                units.withUnsafeBufferPointer { bz_spell_check(tag, $0.baseAddress, Int32($0.count), &ranges, 512) }
            })
            guard n >= 0 else { continue }
            let found = (0..<min(n, 512)).map { NSRange(location: Int(ranges[$0 * 2]), length: Int(ranges[$0 * 2 + 1])) }
                .filter { !isKey($0, in: words as NSString) }
            if best == nil || found.count < best!.ranges.count { best = (language, found) }
            if found.isEmpty { break }
        }
        return best ?? (nil, [])
    }

    /// Whether a word found misspelt is a key as Windows names it where the Mac writes a symbol
    /// (Ctrl+B for ⌘B, as the welcome tour has them), which the Mac's spelling passes over and
    /// no dictionary has.
    private static func isKey(_ r: NSRange, in words: NSString) -> Bool {
        guard NSMaxRange(r) <= words.length else { return false }
        let word = words.substring(with: r)
        return word.contains("+") || ["Ctrl", "Alt", "Shift", "Esc", "Enter"].contains(word)
    }

    /// The words said twice in a row (the second of each), as Windows' checker for `language` finds them.
    static func repeats(_ words: String, in language: String?) -> [NSRange] {
        guard let language = language ?? languages.first else { return [] }
        let units = Array(words.utf16)
        guard !units.isEmpty else { return [] }
        var ranges = [Int32](repeating: 0, count: 2 * 256)
        let n = Int(language.withCString { tag in
            units.withUnsafeBufferPointer { bz_spell_repeats(tag, $0.baseAddress, Int32($0.count), &ranges, 256) }
        })
        return (0..<min(max(n, 0), 256)).map { NSRange(location: Int(ranges[$0 * 2]), length: Int(ranges[$0 * 2 + 1])) }
    }

    static func guesses(_ word: String, in language: String?) -> [String] {
        guard let language = language ?? languages.first else { return [] }
        let units = Array(word.utf16)
        var bytes = [CChar](repeating: 0, count: 8192)
        let n = Int(language.withCString { tag in
            units.withUnsafeBufferPointer { bz_spell_guesses(tag, $0.baseAddress, Int32($0.count), &bytes, Int32(bytes.count)) }
        })
        let list = String(decoding: bytes.prefix(min(n, bytes.count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return list.split(separator: "\n").map(String.init).filter { $0 != word }
    }

    static func learn(_ word: String, in language: String?) {
        guard let language = language ?? languages.first else { return }
        let units = Array(word.utf16)
        language.withCString { tag in units.withUnsafeBufferPointer { bz_spell_learn(tag, $0.baseAddress, Int32($0.count)) } }
    }
}
