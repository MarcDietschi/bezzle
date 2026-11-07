import AppKit

/// Decks: making an artboard one, adding posts to it, taking them away and moving them about,
/// turning from one to another, and filling them with words. See `Deck`.
extension DocumentStore {
    // MARK: Which post is in front

    /// The post a deck shows: the one turned to here, or else its first.
    func front(of deck: Node) -> Int? { deck.front(in: fronts) }

    /// What lies on an artboard as it is seen: for a deck, the post in front.
    func seenLayers(of board: Node) -> [Node] { board.seenLayers(fronts: fronts) }

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
        let moved = doc.carried(selection, deck: deckID, from: was, to: post)
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

    /// Adds a post after `after` (or the last), a copy of it, and returns its number (the shared
    /// `BezzleDocument.addPost`).
    @discardableResult
    static func addPost(to boardID: UUID, after: Int?, in doc: inout BezzleDocument) -> Int? {
        doc.addPost(to: boardID, after: after)
    }

    /// An artboard made a deck of one post (the shared `BezzleDocument.madeDeck`).
    static func madeDeck(_ board: Node) -> Node { BezzleDocument.madeDeck(board) }

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
        edit("Remove Post") { $0.removePost(post, from: deckID) }
        if doc.node(deckID)?.isDeck != true { fronts[deckID] = nil } else if shown { fronts[deckID] = next }
        selection = carried.filter { doc.node($0) != nil }
        if let id = hovered, doc.node(id) == nil { hovered = nil }
        if let typing, doc.node(typing) != nil { canvas?.beginEditing(typing, action: "Typing") }
    }

    /// Moves a post to another place among a deck's posts, counted before it is moved.
    func movePost(_ post: Int, in deckID: UUID, to index: Int) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        guard let posts = deck.posts(moving: post, to: index) else { return }
        update([deckID], "Move Post") { $0.deck?.posts = posts }
    }

    /// Makes a deck an artboard like any again, of the post in front alone.
    func unstack(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let keep = front(of: deck)
        edit("Keep Only This Post") { $0.unstack(deckID, keeping: keep) }
        fronts[deckID] = nil
    }

    /// Makes each of a deck's posts an artboard of its own, in a row to the right of it; the deck
    /// becomes the artboard of the post in front.
    func spreadOut(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let keep = front(of: deck)
        var made: [UUID] = [deckID]
        edit("Make Artboards of Posts") { made = $0.spreadOut(deckID, keeping: keep) }
        fronts[deckID] = nil
        selection = made
    }

    // MARK: Filling posts

    /// The same layer in each of a deck's posts, in their order, for a layer of any of them.
    func copies(acrossPosts id: UUID) -> [UUID] { doc.copies(acrossPosts: id) }

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
        let pairs = doc.tableFills(table, from: textID)
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

    /// Fills layers of one post, and the same layers in the posts after it, `count` posts in all
    /// (the shared `BezzleDocument.spread`), as one step. Returns the posts filled.
    @discardableResult
    func spread(_ fills: [(layer: UUID, fill: (inout Node, Int) -> Void)], count: Int, action: LocalizedStringResource) -> [Int] {
        var filled: [Int] = []
        edit(action) { doc in filled = doc.spread(fills, count: count) }
        return filled
    }
}

// MARK: - Offers after a change

extension DocumentStore {
    /// Looks at what a change did to the deck it was made on, and offers what can be made of it:
    /// see `DeckOffer`. Anything offered before goes.
    func considerOffer(after before: BezzleDocument) {
        offer = nil
        guard doc.nodes.contains(where: \.isDeck) else { return }
        for board in doc.nodes where board.isDeck {
            guard let was = before.path(of: board.id).map({ before[$0] }), was != board, was.isDeck,
                  let front = front(of: board), board.posts.count > 1 else { continue }
            if let made = DeckOffer.make(for: board, was: was, front: front, before: before) {
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
        edit("Keep in This Post") { $0.keepInPost(changes, post: post, deck: deck, before: before) }
    }

    /// Lets these layers of a post follow the design again in what they kept of their own, or only
    /// in `names`.
    func followDesign(_ ids: [UUID], only names: [String]? = nil) {
        edit("Follow Design") { $0.followDesign(ids, only: names) }
    }

    /// Gives every post, and the design behind them, the words or picture these layers hold.
    func giveEveryPost(_ ids: [UUID]) {
        edit("Use in All Posts") { $0.giveEveryPost(ids) }
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

    static func broken(_ deck: Node) -> Set<Int> { Deck.broken(deck) }
}
