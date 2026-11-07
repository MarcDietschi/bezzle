import Foundation

// Looking through a design's words for some, and putting others in their place, as the design
// itself: what is found and in which order, and everything found replaced as one change. The
// Mac's find bar (`TextFinder`), its MCP tools and Windows call these; checking spelling is each
// one's own, since each asks its own system.

/// What to look for among a design's words.
nonisolated struct TextSearch: Hashable, Sendable {
    /// Some letters found: in which text layer, and where among its words as typed, in UTF-16.
    struct Match: Hashable, Sendable {
        let layer: UUID
        let range: NSRange
    }

    var query = ""
    var matchCase = false
    var wholeWords = false

    /// Everything found in a design, in reading order (`texts(in:)`).
    func matches(in doc: BezzleDocument) -> [Match] {
        guard !query.isEmpty else { return [] }
        var out: [Match] = []
        for (id, words) in Self.texts(in: doc) {
            for range in found(in: words) { out.append(Match(layer: id, range: range)) }
        }
        return out
    }

    /// Where the query is in some words.
    func found(in words: String) -> [NSRange] {
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

    /// The text layers whose words can be seen, in reading order, with their words: artboard by
    /// artboard, and on each from the top down and from the left.
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

extension BezzleDocument {
    /// Puts `words` in place of everything in `matches`, each text fitted again after.
    mutating func replace(_ matches: [TextSearch.Match], with words: String) {
        var byLayer: [UUID: [NSRange]] = [:]
        var order: [UUID] = []
        for m in matches {
            if byLayer[m.layer] == nil { order.append(m.layer) }
            byLayer[m.layer, default: []].append(m.range)
        }
        for id in order {
            update(id) { n in
                // From the end, so the places of those before stay as they are.
                for r in (byLayer[id] ?? []).sorted(by: { $0.location > $1.location }) { n.replaceText(in: r, with: words) }
                n.refit()
            }
        }
    }
}
