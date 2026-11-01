import AppKit

/// Decks: making an artboard one, adding posts to it, taking them away and moving them about,
/// turning from one to another, and filling them with words. See `Deck`.
extension DocumentStore {
    // MARK: Which post is in front

    /// The post a deck shows: the one turned to here, or else its first.
    func front(of deck: Node) -> Int? {
        let posts = deck.posts
        if let f = fronts[deck.id], posts.contains(f) { return f }
        return posts.first
    }

    /// What lies on an artboard as it is seen: for a deck, the post in front.
    func seenLayers(of board: Node) -> [Node] {
        board.isDeck ? board.layers(of: front(of: board)) : board.children
    }

    /// The design as it is seen: each deck with only the post in front of it on it.
    var seenDoc: BezzleDocument {
        if let seen = seenWorkedOut, seen.version == version, seen.fronts == fronts { return seen.doc }
        var seen = doc
        if seen.nodes.contains(where: \.isDeck) {
            seen.nodes = seen.nodes.map { $0.isDeck ? $0.showing(front(of: $0)) : $0 }
        }
        seenWorkedOut = (version, fronts, seen)
        return seen
    }

    /// The deck the selection is on, or that is selected.
    var selectedDeck: Node? {
        guard let first = selection.first else { return nil }
        if let n = doc.node(first), n.isDeck { return n }
        return doc.post(of: first)?.deck
    }

    /// The deck the arrows and Page Up and Down turn: the selected one, or the one looked at most.
    var turnableDeck: Node? {
        selectedDeck ?? focusedArtboard.flatMap { $0.isDeck ? $0 : nil }
    }

    /// The artboard a post would be added to: the deck being worked on, or the artboard selected
    /// or the selection is on.
    var postableBoard: Node? {
        if let deck = selectedDeck { return deck.locked ? nil : deck }
        guard let first = selection.first else { return turnableDeck }
        let board = doc.node(first).flatMap { $0.isArtboard ? $0 : nil } ?? doc.artboard(of: first)
        return board.flatMap { $0.locked ? nil : $0 }
    }

    /// Turns a deck to one of its posts. What was selected in the post that was in front is
    /// selected in this one, and a text being typed into goes on being typed into there.
    func turn(_ deckID: UUID, to post: Int) {
        guard let deck = doc.node(deckID), deck.isDeck, deck.posts.contains(post) else { return }
        let was = front(of: deck)
        guard was != post else { return }
        // Typing into a post that goes behind: left there, the words typed would go on landing in
        // a post no longer seen, over the one now in front. It ends there and goes on in the same
        // words of the post coming to the front.
        var typing: UUID?
        if let id = editingText, let found = doc.post(of: id), found.deck.id == deckID, let from = found.post, from != post {
            typing = id.mixed(Deck.key(from: from, to: post))
            canvas?.endEditing()
        }
        let k = Deck.key(from: was, to: post)
        let moved = selection.map { id in
            guard let found = doc.post(of: id), found.deck.id == deckID, found.post == was else { return id }
            return id.mixed(k)
        }
        fronts[deckID] = post
        if moved != selection { selection = moved.filter { doc.node($0) != nil } }
        if let id = hovered, let found = doc.post(of: id), found.deck.id == deckID { hovered = nil }
        if let typing, doc.node(typing) != nil { canvas?.beginEditing(typing, action: "Typing") }
    }

    /// Turns the deck being worked on `by` posts on, or back; nothing past the first or the last.
    func turnPage(by steps: Int) {
        guard let deck = turnableDeck, let at = front(of: deck) else { return }
        let posts = deck.posts
        guard let i = posts.firstIndex(of: at) else { return }
        let j = min(max(i + steps, 0), posts.count - 1)
        if j != i { turn(deck.id, to: posts[j]) }
    }

    /// Where the post in front is among a deck's posts, from 0, and how many there are.
    func place(in deck: Node) -> (index: Int, count: Int) {
        let posts = deck.posts
        return (front(of: deck).flatMap { posts.firstIndex(of: $0) } ?? 0, posts.count)
    }

    // MARK: Making and unmaking

    /// Adds a post to an artboard, after the one in front, as a copy of it: what it holds, it
    /// holds too, to be changed. An artboard that is no deck yet becomes one, its layers its first
    /// post. The new post comes to the front.
    func addPost(to boardID: UUID) {
        guard let board = doc.node(boardID), board.isArtboard, !board.locked else { return }
        // Typing on the board, what was typed is a step of its own, before the post is added; the
        // typing goes on in the same words of the new post.
        let typing = editingText.flatMap { doc.artboard(of: $0)?.id == boardID ? $0 : nil }
        if typing != nil { canvas?.endEditing() }
        let after = board.isDeck ? front(of: board) : nil
        var added: Int?
        edit(board.isDeck ? "Add Post" : "Make Deck") { doc in added = Self.addPost(to: boardID, after: after, in: &doc) }
        if let added {
            // The layers selected in the post copied are selected in the copy.
            if let after { fronts[boardID] = after }
            turn(boardID, to: added)
            if let typing, let from = doc.post(of: typing)?.post, from != added {
                let next = typing.mixed(Deck.key(from: from, to: added))
                if doc.node(next) != nil { canvas?.beginEditing(next, action: "Typing") }
            }
        }
    }

    /// Adds a post after `after` (or the last), a copy of it, and returns its number.
    @discardableResult
    static func addPost(to boardID: UUID, after: Int?, in doc: inout BezzleDocument) -> Int? {
        guard let path = doc.path(of: boardID), path.indices.count == 1 else { return nil }
        var board = doc[path]
        guard board.isArtboard else { return nil }
        if !board.isDeck { board = madeDeck(board) }
        var posts = board.posts
        guard let from = after.flatMap({ posts.contains($0) ? $0 : nil }) ?? posts.last else { return nil }
        let n = Deck.number(besides: posts)
        let k = Deck.key(from: from, to: n)
        board.children += board.layers(of: from).map { layer in
            var copy = RepeatGrid.copy(layer, k)
            copy.post = n
            return copy
        }
        posts.insert(n, at: (posts.firstIndex(of: from) ?? posts.count - 1) + 1)
        board.deck = Deck(posts: posts)
        doc[path] = board
        return n
    }

    /// An artboard made a deck of one post: its layers, as they are, are that post, and a copy of
    /// them is the design behind it.
    static func madeDeck(_ board: Node) -> Node {
        var b = board
        let p = Deck.number(besides: [])
        let k = Deck.key(p)
        let layers = board.children.map { c in
            var n = c.forgettingOwn()
            n.post = p
            return n
        }
        let design = layers.map { layer in
            var d = RepeatGrid.copy(layer, k)
            d.post = nil
            return d
        }
        b.children = design + layers
        b.deck = Deck(posts: [p])
        return b
    }

    /// Takes a post away from a deck; the one after it comes to the front, or else the one before.
    /// The last post stays. Undone, the post is back in front if it was, with what was selected in it.
    func removePost(_ post: Int, from deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let posts = deck.posts
        guard posts.count > 1, let i = posts.firstIndex(of: post) else { return }
        let next = i + 1 < posts.count ? posts[i + 1] : posts[i - 1]
        let shown = front(of: deck) == post
        // What was selected or typed into in it goes on in the same layers of the next post. Turned
        // only once it is gone, so that the step remembers it in front, and undoing shows it again.
        let k = Deck.key(from: post, to: next)
        func inIt(_ id: UUID) -> Bool { doc.post(of: id).map { $0.deck.id == deckID && $0.post == post } ?? false }
        var typing: UUID?
        if let id = editingText, inIt(id) {
            typing = id.mixed(k)
            canvas?.endEditing()
        }
        let carried = selection.map { inIt($0) ? $0.mixed(k) : $0 }
        edit("Remove Post") { doc in
            guard let path = doc.path(of: deckID) else { return }
            var board = doc[path]
            board.children.removeAll { $0.post == post }
            board.deck?.posts.removeAll { $0 == post }
            // With one post left it is no stack any more, but an artboard like any.
            if board.posts.count == 1 { Self.unstack(&board, keeping: board.posts[0]) }
            doc[path] = board
        }
        if doc.node(deckID)?.isDeck != true { fronts[deckID] = nil } else if shown { fronts[deckID] = next }
        selection = carried.filter { doc.node($0) != nil }
        if let id = hovered, doc.node(id) == nil { hovered = nil }
        if let typing, doc.node(typing) != nil { canvas?.beginEditing(typing, action: "Typing") }
    }

    /// Moves a post to another place among a deck's posts, counted before it is moved.
    func movePost(_ post: Int, in deckID: UUID, to index: Int) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        var posts = deck.posts
        guard let i = posts.firstIndex(of: post) else { return }
        posts.remove(at: i)
        posts.insert(post, at: min(max(index > i ? index - 1 : index, 0), posts.count))
        guard posts != deck.posts else { return }
        update([deckID], "Move Post") { $0.deck?.posts = posts }
    }

    /// Makes a deck an artboard like any again, of the post in front alone.
    func unstack(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let keep = front(of: deck)
        edit("Keep Only This Post") { doc in
            guard let path = doc.path(of: deckID) else { return }
            var board = doc[path]
            Self.unstack(&board, keeping: keep)
            doc[path] = board
        }
        fronts[deckID] = nil
    }

    /// A deck made an artboard like any again, holding one of its posts' layers as they are.
    private static func unstack(_ board: inout Node, keeping post: Int?) {
        board.children = board.layers(of: post).map { layer in
            var n = layer.forgettingOwn()
            n.post = nil
            return n
        }
        board.deck = nil
    }

    /// Makes each of a deck's posts an artboard of its own, in a row to the right of it; the deck
    /// becomes the artboard of the post in front.
    func spreadOut(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let keep = front(of: deck)
        var made: [UUID] = [deckID]
        edit("Make Artboards of Posts") { doc in
            guard let path = doc.path(of: deckID) else { return }
            var board = doc[path]
            let others = board.posts.filter { $0 != keep }
            func plain(_ layers: [Node]) -> [Node] {
                layers.map { layer in
                    var n = layer.forgettingOwn()
                    n.post = nil
                    return n
                }
            }
            // Each in the first place along the row that lands on nothing else on the canvas.
            var taken = doc.nodes.filter { $0.id != deckID }.map { Geometry.bounds(of: $0) }
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
            doc[path] = board
            doc.nodes.insert(contentsOf: boards, at: path.top + 1)
        }
        fronts[deckID] = nil
        selection = made
    }

    // MARK: Filling posts

    /// The same layer in each of a deck's posts, in their order, for a layer of any of them.
    func copies(acrossPosts id: UUID) -> [UUID] {
        guard let (deck, post) = doc.post(of: id), let post else { return [] }
        return deck.posts.map { id.mixed(Deck.key(from: post, to: $0)) }.filter { doc.node($0) != nil }
    }

    /// Gives a text layer `values`, one each, in its own post and the posts after it, adding as many
    /// posts at the end as there are values left over. An artboard that is no deck becomes one.
    /// Returns the posts filled, the first being the text's own.
    @discardableResult
    func spread(_ values: [String], from textID: UUID, action: LocalizedStringResource = "Make Posts") -> [Int] {
        guard doc.node(textID)?.kind == .text else { return [] }
        return spread([(textID, { n, i in
            guard n.kind == .text else { return }
            n.text = values[i]
            n.refit()
        })], count: values.count, action: action)
    }

    /// Gives a shape a picture each in its own post and the posts after it, adding posts at the end
    /// as there are pictures left over. An artboard that is no deck becomes one.
    @discardableResult
    func spread(_ pictures: [ImageFill], from shapeID: UUID, action: LocalizedStringResource = "Make Posts") -> [Int] {
        spread([(shapeID, { n, i in
            n.fill.on = true
            n.fill.image = pictures[i]
        })], count: pictures.count, action: action)
    }

    /// Gives text layers of one post the columns of a table, a row each, in their own post and the
    /// posts after it, adding posts as there are rows left over: each column to the text layer named
    /// as it is, and the rest in order from `textID` on. Returns how many columns found a layer.
    @discardableResult
    func spread(table: DataTable, from textID: UUID) -> Int {
        guard let board = doc.artboard(of: textID) else { return 0 }
        let post = doc.post(of: textID)?.post
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
        let count = pairs.map(\.1.count).max() ?? 0
        guard count > 0 else { return 0 }
        spread(pairs.map { id, values in
            (id, { (n: inout Node, i: Int) in
                guard n.kind == .text, i < values.count else { return }
                n.text = values[i]
                n.refit()
            })
        }, count: count, action: "Make Posts")
        return pairs.count
    }

    /// Fills layers of one post, and the same layers in the posts after it, `count` posts in all,
    /// adding posts at the end as needed: `fill` is given each post's copy of a layer and which post
    /// of them it is, from 0. An artboard that is no deck becomes one. Returns the posts filled.
    @discardableResult
    func spread(_ fills: [(layer: UUID, fill: (inout Node, Int) -> Void)], count: Int, action: LocalizedStringResource) -> [Int] {
        guard count > 0, let first = fills.first?.layer, let board = doc.artboard(of: first) else { return [] }
        let own = board.isDeck ? doc.post(of: first)?.post : nil
        var filled: [Int] = []
        edit(action) { doc in
            if !(doc.node(board.id)?.isDeck ?? false), let path = doc.path(of: board.id) {
                doc[path] = Self.madeDeck(doc[path])
            }
            guard let deck = doc.node(board.id), let start = own ?? deck.posts.first else { return }
            var posts = deck.posts
            var at = posts.firstIndex(of: start) ?? 0
            for i in 0..<count {
                if i > 0 {
                    at += 1
                    if at >= posts.count {
                        guard let n = Self.addPost(to: board.id, after: posts.last, in: &doc) else { break }
                        posts.append(n)
                    }
                }
                let p = posts[at]
                for (layer, fill) in fills {
                    // The layer as it is in the design behind every post, and then in this one.
                    doc.update(layer.mixed(Deck.key(start)).mixed(Deck.key(p))) { fill(&$0, i) }
                }
                filled.append(p)
            }
        }
        return filled
    }
}

// MARK: - Offers after a change

/// What is offered for a moment after a change made to every post of a deck from the one in front:
/// to keep it in that post alone.
struct DeckOffer {
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
}

extension DocumentStore {
    /// Looks at what a change did to the deck it was made on, and offers what can be made of it:
    /// see `DeckOffer`. Anything offered before goes.
    func considerOffer(after before: BezzleDocument) {
        offer = nil
        guard doc.nodes.contains(where: \.isDeck) else { return }
        for board in doc.nodes where board.isDeck {
            guard let was = before.path(of: board.id).map({ before[$0] }), was != board, was.isDeck,
                  let front = front(of: board), board.posts.count > 1 else { continue }
            if let made = Self.offer(for: board, was: was, front: front, before: before) {
                offer = made
                let token = made.token
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(7))
                    if self?.offer?.token == token { self?.offer = nil }
                }
            }
            return
        }
    }

    private static func offer(for board: Node, was: Node, front: Int, before: BezzleDocument) -> DeckOffer? {
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

    /// Does what an offer offers.
    func take(_ offer: DeckOffer) {
        self.offer = nil
        switch offer.kind {
        case .justHere(let changes, let before):
            keepInPost(changes, post: offer.post, deck: offer.deck, before: before)
        }
    }

    /// Makes what was changed about these layers of a post that post's own, and puts it back in
    /// every other post and the design behind them as it was `before`.
    func keepInPost(_ changes: [UUID: [String]], post: Int, deck: UUID, before: BezzleDocument) {
        guard let board = doc.node(deck), board.isDeck else { return }
        let others: [Int?] = [nil] + board.posts.filter { $0 != post }
        edit("Keep in This Post") { doc in
            for (id, names) in changes {
                doc.update(id) { $0.own = Array(Set($0.own ?? []).union(names)).sorted() }
                for q in others {
                    let other = id.mixed(Deck.key(from: post, to: q))
                    guard let old = before.node(other) else { continue }
                    doc.update(other) { n in
                        for name in names { Deck.fields[name]?.copy(&n, old) }
                        n.refit()
                    }
                }
            }
        }
    }

    /// Lets these layers of a post follow the design again in what they kept of their own, or only
    /// in `names`.
    func followDesign(_ ids: [UUID], only names: [String]? = nil) {
        edit("Follow Design") { doc in
            for id in ids {
                guard let (_, post) = doc.post(of: id), let post, let layer = doc.node(id), let own = layer.own else { continue }
                let back = names.map { Set($0).intersection(own) } ?? Set(own)
                guard !back.isEmpty, let design = doc.node(id.mixed(Deck.key(post))) else { continue }
                doc.update(id) { n in
                    let left = own.filter { !back.contains($0) }
                    n.own = left.isEmpty ? nil : left
                    for name in back { Deck.fields[name]?.copy(&n, design) }
                    if n.kind == .text { n.text = layer.text }
                    n.fill.image = layer.fill.image
                    n.refit()
                }
            }
        }
    }

    /// Gives every post, and the design behind them, the words or picture these layers hold.
    func giveEveryPost(_ ids: [UUID]) {
        let sources = ids.compactMap { id in doc.node(id).map { (id, $0) } }
        edit("Use in All Posts") { doc in
            for (id, source) in sources {
                guard let (deck, post) = doc.post(of: id), let post else { continue }
                for q in [nil] + deck.posts where q != post {
                    doc.update(id.mixed(Deck.key(from: post, to: q))) { n in
                        if source.kind == .text, n.kind == .text { n.text = source.text }
                        n.fill.image = source.fill.image
                        n.refit()
                    }
                }
            }
        }
    }

    // MARK: Posts that came out broken

    /// The posts of a deck something no longer fits on: words cut off at the edge of their own
    /// box, or reaching past the artboard's. Worked out once per change.
    func brokenPosts(of deck: Node) -> Set<Int> {
        if let worked = brokenWorkedOut[deck.id], worked.node == deck { return worked.posts }
        let broken = Self.broken(deck)
        brokenWorkedOut[deck.id] = (deck, broken)
        return broken
    }

    static func broken(_ deck: Node) -> Set<Int> {
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
