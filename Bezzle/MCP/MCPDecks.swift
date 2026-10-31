import Foundation

/// Decks for the assistant: making an artboard one, adding, taking away and moving its posts,
/// bringing one to the front, and giving its posts words and pictures. See `Deck`.
extension MCPTools {
    func deck(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let ref = try args.string("layer")
        let id = try ref.map { try Self.layer($0, in: store.doc) } ?? store.selection.first
        guard let id, let board = store.doc.node(id)?.isArtboard == true ? store.doc.node(id) : store.doc.artboard(of: id) else {
            throw MCPError("Give an artboard, or a layer on one, as layer.")
        }
        let deckID = board.id
        /// A post by where it is among them, from 1.
        func post(_ n: Int, in deck: Node) throws -> Int {
            let posts = deck.posts
            guard n >= 1, n <= posts.count else { throw MCPError("\(deck.name) has \(posts.count) posts; give one from 1 to \(posts.count).") }
            return posts[n - 1]
        }

        if let how = try args.string("unstack") {
            guard board.isDeck else { throw MCPError("\(board.name) is not a deck.") }
            switch how {
            case "keep_front": _ = try onSelection(store, [deckID], "Keep Only This Post") { $0.unstack(deckID) }
            case "artboards": _ = try onSelection(store, [deckID], "Make Artboards of Posts") { $0.spreadOut(deckID) }
            default: throw MCPError("unstack is keep_front or artboards.")
            }
            return described([deckID], in: store, depth: 1)
        }

        if let count = try args.int("add") {
            guard (1...100).contains(count) else { throw MCPError("add from 1 to 100 posts at a time.") }
            let after = try args.int("after").map { try post($0, in: board) }
            _ = try onSelection(store, store.selection, count == 1 ? "Add Post" : "Add Posts") { copy in
                if let after { copy.fronts[deckID] = after }
                for _ in 0..<count { copy.addPost(to: deckID) }
            }
        }
        if let n = try args.int("remove") {
            guard let deck = store.doc.node(deckID), deck.isDeck else { throw MCPError("\(board.name) is not a deck.") }
            guard deck.posts.count > 1 else { throw MCPError("A deck keeps its last post. unstack makes it an artboard like any.") }
            let p = try post(n, in: deck)
            _ = try onSelection(store, store.selection, "Remove Post") { $0.removePost(p, from: deckID) }
        }
        if let moving = try args.strings("move") {
            guard let deck = store.doc.node(deckID), deck.isDeck else { throw MCPError("\(board.name) is not a deck.") }
            guard moving.count == 2, let from = Int(moving[0]), let to = Int(moving[1]) else { throw MCPError("move is [from, to], places from 1.") }
            let p = try post(from, in: deck)
            let place = min(max(to, 1), deck.posts.count)
            let index = place - 1 >= (deck.posts.firstIndex(of: p) ?? 0) ? place : place - 1
            _ = try onSelection(store, store.selection, "Move Post") { $0.movePost(p, in: deckID, to: index) }
        }

        // Words or pictures, one a post, from the post given on.
        let start = try args.int("from") ?? 1
        if let values = try args.strings("values") {
            guard let textRef = try args.string("text_layer") else { throw MCPError("Give the text layer the words go into as text_layer.") }
            let text = try target(textRef, start: start, deckID: deckID, store: store)
            guard store.doc.node(text)?.kind == .text else { throw MCPError("\(textRef) is not a text layer.") }
            _ = try onSelection(store, store.selection, "Make Posts") { $0.spread(values, from: text) }
        }
        if let files = try args.strings("pictures") {
            guard let shapeRef = try args.string("shape_layer") else { throw MCPError("Give the shape the pictures go into as shape_layer.") }
            let shape = try target(shapeRef, start: start, deckID: deckID, store: store)
            guard let kind = store.doc.node(shape)?.kind, [.rectangle, .ellipse, .path].contains(kind) else { throw MCPError("Pictures fill rectangles, ellipses and paths.") }
            let urls = DocumentStore.pictureFiles(in: files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            let pictures = urls.compactMap { store.importPicture($0) }
            guard !pictures.isEmpty else { throw MCPError("None of those is a picture Bezzle can read.\(Self.unreachable)") }
            _ = try onSelection(store, store.selection, "Make Posts") { $0.spread(pictures, from: shape) }
        }

        if let n = try args.int("show") {
            guard let deck = store.doc.node(deckID), deck.isDeck else { throw MCPError("\(board.name) is not a deck.") }
            store.turn(deckID, to: try post(n, in: deck))
        }
        // Asked for one post's layers, with their ids, to change them.
        if let n = try args.int("post"), let deck = store.doc.node(deckID), deck.isDeck {
            let p = try post(n, in: deck)
            let layers = deck.layers(of: p).map { Self.describe($0, in: store.doc, full: false, depth: 2) }
            return [.text(JSONValue.compact([("post", .number(n)), ("of", .number(deck.posts.count)), ("layers", .array(layers))]).text)]
        }
        return described([deckID], in: store, depth: 1)
    }

    /// The layer named `ref` in the deck's post `start`, from 1; on an artboard that is no deck
    /// yet, the layer itself.
    private func target(_ ref: String, start: Int, deckID: UUID, store: DocumentStore) throws -> UUID {
        let id = try Self.layer(ref, in: store.doc)
        guard let deck = store.doc.node(deckID), deck.isDeck else { return id }
        let posts = deck.posts
        guard (1...posts.count).contains(start) else { throw MCPError("from is a post from 1 to \(posts.count).") }
        guard let (_, post) = store.doc.post(of: id) else { throw MCPError("\(ref) is not on \(deck.name).") }
        return id.mixed(Deck.key(from: post, to: posts[start - 1]))
    }

    // MARK: Describing decks

    /// What a deck is beyond an artboard: how many posts, which is in front, what each post's text
    /// layers say, and which posts something no longer fits on.
    static func deckDetails(_ deck: Node, front: Int?, broken: Set<Int>) -> [(String, JSONValue?)] {
        let posts = deck.posts
        var texts: [(String, JSONValue)] = []
        func visit(_ n: Node) {
            if n.kind == .text {
                let words = posts.map { p -> JSONValue in
                    deck.layers(of: p).lazy.compactMap { find(n.id.mixed(Deck.key(p)), in: $0) }.first?.text.map { .string($0) } ?? .null
                }
                texts.append((n.name, .array(words)))
            }
            n.children.forEach(visit)
        }
        deck.layers(of: nil).forEach(visit)
        let cut = posts.enumerated().filter { broken.contains($0.element) }.map { JSONValue.number($0.offset + 1) }
        return [("deck", .compact([
            ("posts", .number(posts.count)),
            ("inFront", front.flatMap { posts.firstIndex(of: $0) }.map { .number($0 + 1) }),
            ("postTexts", texts.isEmpty ? nil : .object(texts)),
            ("brokenPosts", cut.isEmpty ? nil : .array(cut)),
            ("note", .string("layers lists the first post only. Every post is the same design: a change to a layer's look in any post is made in all of them, but each post's words and pictures are its own. deck with post gives one post's layers and ids.")),
        ]))]
    }

    private static func find(_ id: UUID, in n: Node) -> Node? {
        n.id == id ? n : n.children.lazy.compactMap { find(id, in: $0) }.first
    }
}
