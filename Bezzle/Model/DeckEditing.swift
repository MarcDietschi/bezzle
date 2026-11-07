import Foundation

// What is done to decks, as the design itself: taking posts away, moving them, unstacking,
// spreading the posts out into artboards, carrying a selection from post to post, filling posts
// from a table, keeping a change in one post, and the posts something no longer fits on. The Mac's
// store (Store/DeckOperations.swift) and Windows call these. See `Deck`.

extension Node {
    /// A deck made an artboard like any again, holding one of its posts' layers as they are.
    nonisolated mutating func unstack(keeping post: Int?) {
        children = layers(of: post).map { layer in
            var n = layer.forgettingOwn()
            n.post = nil
            return n
        }
        deck = nil
    }

    /// The deck's posts with `post` moved to another place among them, counted before it moved;
    /// nil when that moves nothing.
    nonisolated func posts(moving post: Int, to index: Int) -> [Int]? {
        var posts = self.posts
        guard let i = posts.firstIndex(of: post) else { return nil }
        posts.remove(at: i)
        posts.insert(post, at: min(max(index > i ? index - 1 : index, 0), posts.count))
        return posts == self.posts ? nil : posts
    }
}

extension BezzleDocument {
    /// The same layers in another post: those of deck `deckID`'s post `from` become their copies
    /// in post `to`; the rest stay as they are.
    nonisolated func carried(_ ids: [UUID], deck deckID: UUID, from: Int?, to: Int?) -> [UUID] {
        let k = Deck.key(from: from, to: to)
        return ids.map { id in
            guard let found = post(of: id), found.deck.id == deckID, found.post == from else { return id }
            return id.mixed(k)
        }
    }

    /// Takes a post away from a deck; with one post left, it is no stack any more, but an
    /// artboard like any.
    nonisolated mutating func removePost(_ post: Int, from deckID: UUID) {
        guard let path = path(of: deckID) else { return }
        var board = self[path]
        board.children.removeAll { $0.post == post }
        board.deck?.posts.removeAll { $0 == post }
        if board.posts.count == 1 { board.unstack(keeping: board.posts[0]) }
        self[path] = board
    }

    /// Makes a deck an artboard like any again, of one post alone.
    nonisolated mutating func unstack(_ deckID: UUID, keeping post: Int?) {
        guard let path = path(of: deckID) else { return }
        var board = self[path]
        board.unstack(keeping: post)
        self[path] = board
    }

    /// Makes each of a deck's posts an artboard of its own, in a row to the right of it, each in
    /// the first place along the row that lands on nothing else on the canvas; the deck becomes
    /// the artboard of post `keep`. Returns the artboards, the deck first.
    @discardableResult
    mutating func spreadOut(_ deckID: UUID, keeping keep: Int?) -> [UUID] {
        guard let path = path(of: deckID) else { return [] }
        var made: [UUID] = [deckID]
        var board = self[path]
        let others = board.posts.filter { $0 != keep }
        func plain(_ layers: [Node]) -> [Node] {
            layers.map { layer in
                var n = layer.forgettingOwn()
                n.post = nil
                return n
            }
        }
        var taken = nodes.filter { $0.id != deckID }.map { Geometry.bounds(of: $0) }
        var x = board.frame.maxX + 80
        var boards: [Node] = []
        for (i, p) in others.enumerated() {
            var b = board
            b.id = UUID()
            b.deck = nil
            b.name = "\(board.name) \(i + 2)"
            var spot = CGRect(origin: CGPoint(x: x, y: board.frame.minY), size: board.frame.size)
            while let hit = taken.first(where: { $0.intersects(spot.insetBy(dx: -40, dy: -40)) }) {
                spot.origin.x = (hit.maxX + 80).rounded()
            }
            b.frame.origin = spot.origin
            b.children = plain(board.layers(of: p)).map { $0.freshCopy() }
            taken.append(spot)
            x = spot.maxX + 80
            boards.append(b)
            made.append(b.id)
        }
        board.children = plain(board.layers(of: keep))
        board.deck = nil
        self[path] = board
        nodes.insert(contentsOf: boards, at: path.top + 1)
        return made
    }

    /// The same layer in each of a deck's posts, in their order, for a layer of any of them.
    nonisolated func copies(acrossPosts id: UUID) -> [UUID] {
        guard let (deck, post) = post(of: id), let post else { return [] }
        return deck.posts.map { id.mixed(Deck.key(from: post, to: $0)) }.filter { node($0) != nil }
    }

    /// Which text layers of a text's post take which column of a table: each column the text
    /// layer named as it is, and the rest in order from `textID` on.
    nonisolated func tableFills(_ table: DataTable, from textID: UUID) -> [(UUID, [String])] {
        guard let board = artboard(of: textID) else { return [] }
        let post = post(of: textID)?.post
        var texts: [Node] = []
        func visit(_ n: Node) {
            if n.kind == .text { texts.append(n) }
            n.children.forEach(visit)
        }
        (board.isDeck ? board.layers(of: post) : board.children).forEach(visit)
        var left = texts.filter { $0.id != textID }
        if let own = texts.first(where: { $0.id == textID }) { left.insert(own, at: 0) }
        var columns = table.columns
        var pairs: [(UUID, [String])] = []
        for (i, column) in columns.enumerated().reversed() {
            if let at = left.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(column.title) == .orderedSame }) {
                pairs.append((left[at].id, column.values))
                left.remove(at: at)
                columns.remove(at: i)
            }
        }
        for (text, column) in zip(left, columns) { pairs.append((text.id, column.values)) }
        return pairs
    }

    /// Makes what was changed about these layers of a post that post's own, and puts it back in
    /// every other post and the design behind them as it was `before`.
    mutating func keepInPost(_ changes: [UUID: [String]], post: Int, deck: UUID, before: BezzleDocument) {
        guard let board = node(deck), board.isDeck else { return }
        let others: [Int?] = [nil] + board.posts.filter { $0 != post }
        for (id, names) in changes {
            update(id) { $0.own = Array(Set($0.own ?? []).union(names)).sorted() }
            for q in others {
                let other = id.mixed(Deck.key(from: post, to: q))
                guard let old = before.node(other) else { continue }
                update(other) { n in
                    for name in names { Deck.fields[name]?.copy(&n, old) }
                    n.refit()
                }
            }
        }
    }

    /// Lets these layers of a post follow the design again in what they kept of their own, or only
    /// in `names`.
    mutating func followDesign(_ ids: [UUID], only names: [String]? = nil) {
        for id in ids {
            guard let (_, post) = post(of: id), let post, let layer = node(id), let own = layer.own else { continue }
            let back = names.map { Set($0).intersection(own) } ?? Set(own)
            guard !back.isEmpty, let design = node(id.mixed(Deck.key(post))) else { continue }
            update(id) { n in
                let left = own.filter { !back.contains($0) }
                n.own = left.isEmpty ? nil : left
                for name in back { Deck.fields[name]?.copy(&n, design) }
                if n.kind == .text { n.text = layer.text }
                n.fill.image = layer.fill.image
                n.refit()
            }
        }
    }

    /// Gives every post, and the design behind them, the words or picture these layers hold.
    mutating func giveEveryPost(_ ids: [UUID]) {
        let sources = ids.compactMap { id in node(id).map { (id, $0) } }
        for (id, source) in sources {
            guard let (deck, post) = post(of: id), let post else { continue }
            for q in [nil] + deck.posts where q != post {
                update(id.mixed(Deck.key(from: post, to: q))) { n in
                    if source.kind == .text, n.kind == .text { n.text = source.text }
                    n.fill.image = source.fill.image
                    n.refit()
                }
            }
        }
    }
}

extension Deck {
    /// The posts of a deck something no longer fits on: words cut off at the edge of their own
    /// box, or reaching past the artboard's.
    nonisolated static func broken(_ deck: Node) -> Set<Int> {
        var broken = Set<Int>()
        let page = CGRect(origin: .zero, size: deck.frame.size).insetBy(dx: -1, dy: -1)
        for p in deck.posts {
            func cut(_ n: Node, at origin: CGPoint) -> Bool {
                guard !n.hidden else { return false }
                if n.kind == .text, !(n.text ?? "").isEmpty {
                    let frame = n.frame.offsetBy(dx: origin.x, dy: origin.y)
                    if deck.clips, !page.contains(Geometry.bounds(of: Node.with(n, frame: frame))) { return true }
                    if n.style?.sizing == .fixed, TextLayout.height(n, width: n.frame.width) > n.frame.height + 1 { return true }
                }
                let inner = n.isGroup ? origin + n.frame.origin : origin
                return n.children.contains { cut($0, at: inner) }
            }
            if deck.layers(of: p).contains(where: { cut($0, at: .zero) }) { broken.insert(p) }
        }
        return broken
    }
}

// MARK: - Offers after a change

/// What is offered for a moment after a change made to every post of a deck from the one in front:
/// to keep it in that post alone.
nonisolated struct DeckOffer {
    enum Kind {
        /// What each layer of the post in front had changed, and the design as it was before.
        case justHere([UUID: [String]], before: BezzleDocument)
    }

    let deck: UUID
    let post: Int
    /// The layer it is about, which it shows beside; or the deck.
    let anchor: UUID
    let kind: Kind
    let words: String
    let button: String
    let token = UUID()

    /// What a change to a deck, made in post `front`, offers: when it changed only what layers are
    /// like, in the post in front, and the other posts followed it.
    static func make(for board: Node, was: Node, front: Int, before: BezzleDocument) -> DeckOffer? {
        // Only a change to what layers are like: none added, taken away or moved among the posts.
        guard board.posts == was.posts, board.children.map(\.id) == was.children.map(\.id) else { return nil }
        var then: [UUID: Node] = [:]
        func note(_ n: Node) {
            then[n.id] = n
            n.children.forEach(note)
        }
        was.children.forEach(note)
        var style: [UUID: [String]] = [:], content: [UUID] = [], othersHeld = false, othersFollowed = false
        func visit(_ n: Node, inFront: Bool) {
            defer { n.children.forEach { visit($0, inFront: inFront) } }
            guard let q = then[n.id], q != n else { return }
            let words = n.kind == .text && n.text != q.text
            var a = n.fill, b = q.fill
            a.image = nil
            b.image = nil
            let picture = n.fill.image != q.fill.image
            let names = LayerField.all.filter { field in
                Deck.keepable.contains(field.name) && !field.same(n, q)
                    && !(field.name == "fill" && a == b) && !(field.name == "frame" && n.kind == .text && (words || n.spans != q.spans))
            }.map(\.name)
            if inFront {
                if words || picture { content.append(n.id) }
                if !names.isEmpty { style[n.id] = names }
            } else if words || picture {
                othersHeld = true
            } else if !names.isEmpty {
                othersFollowed = true
            }
        }
        for c in board.children { visit(c, inFront: c.post == front) }
        guard !othersHeld else { return nil }
        let count = board.posts.count
        guard !style.isEmpty, content.isEmpty, othersFollowed, let anchor = style.keys.first else { return nil }
        return DeckOffer(deck: board.id, post: front, anchor: anchor, kind: .justHere(style, before: before),
                         words: String(localized: "All \(count) posts"), button: String(localized: "Only This One"))
    }
}
