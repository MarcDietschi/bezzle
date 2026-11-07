import Foundation
import CBezzleHost

// MARK: - Decks

extension WindowsCore {
    /// The post each deck shows here, as the Mac's `store.fronts`: one viewer's, never saved.
    nonisolated(unsafe) public static var fronts: [UUID: Int] = [:]

    /// A deck as the canvas and the inspector show it.
    nonisolated public struct DeckLook: Sendable, Equatable {
        public let id: UUID
        /// Its posts in turning order, and the one in front.
        public let posts: [Int]
        public let front: Int?
        public let locked: Bool
        public let frame: CGRect
        /// The paper its posts are on: its fill, or white.
        public let paper: (rgb: UInt32, alpha: Double)
        public let hidden: Bool
        /// Where the post in front is among the posts, from 0.
        public var index: Int { front.flatMap { posts.firstIndex(of: $0) } ?? 0 }
        public var count: Int { posts.count }

        public static func == (a: DeckLook, b: DeckLook) -> Bool {
            a.id == b.id && a.posts == b.posts && a.front == b.front && a.locked == b.locked && a.frame == b.frame && a.hidden == b.hidden
        }
    }

    static func look(_ n: Node) -> DeckLook {
        let c = n.fill.on ? n.fill.color : RGBA(r: 1, g: 1, b: 1)
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return DeckLook(id: n.id, posts: n.posts, front: n.front(in: fronts), locked: n.locked, frame: n.frame,
                        paper: (byte(Double(c.r)) << 16 | byte(Double(c.g)) << 8 | byte(Double(c.b)), Double(c.a)), hidden: n.hidden)
    }

    /// An artboard as the row under it needs it, deck or not: its frame, whether it is locked or
    /// hidden, and its paper.
    public static func boardLook(_ id: UUID) -> DeckLook? {
        guard let n = design?.node(id), n.isArtboard else { return nil }
        return look(n)
    }

    /// Draws one post of a deck, its whole artboard, at `scale` pixels a point, into pixels the
    /// caller has (premultiplied BGRA, rows top first), as `render(board:)` does.
    public static func render(post: Int?, of deckID: UUID, scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let deck = design?.node(deckID), deck.isDeck else { return false }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = Renderer.image(of: deck.showing(post), scale: CGFloat(scale), assets: assets) else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }

    /// The deck with this id, if it is one.
    public static func deck(_ id: UUID) -> DeckLook? {
        guard let n = design?.node(id), n.isDeck else { return nil }
        return look(n)
    }

    /// Every deck on the canvas.
    public static func decks() -> [DeckLook] {
        (design?.nodes ?? []).filter { $0.isDeck && !$0.hidden }.map(look)
    }

    /// The design as it is seen: each deck with only the post in front of it on it.
    static var seen: BezzleDocument? {
        guard var doc = design else { return nil }
        if doc.nodes.contains(where: \.isDeck) {
            doc.nodes = doc.nodes.map { $0.isDeck ? $0.showing($0.front(in: fronts)) : $0 }
        }
        return doc
    }

    /// A top layer as it is drawn: a deck as its post in front.
    static func seen(_ n: Node) -> Node { n.isDeck ? n.showing(n.front(in: fronts)) : n }

    /// The deck the selection is on, or that is selected.
    public static func selectedDeck(_ selection: [UUID]) -> UUID? {
        guard let first = selection.first, let doc = design else { return nil }
        if let n = doc.node(first), n.isDeck { return n.id }
        return doc.post(of: first)?.deck.id
    }

    /// The deck the arrows and Page Up and Down turn: the selected one, or the artboard looked at.
    public static func turnableDeck(_ selection: [UUID], focused board: Int?) -> UUID? {
        if let deck = selectedDeck(selection) { return deck }
        guard let board, let doc = design, board >= 0, board < doc.nodes.count, doc.nodes[board].isDeck else { return nil }
        return doc.nodes[board].id
    }

    /// The artboard a post would be added to: the deck being worked on, or the artboard selected
    /// or the selection is on.
    public static func postableBoard(_ selection: [UUID], focused board: Int?) -> UUID? {
        guard let doc = design else { return nil }
        if let deck = selectedDeck(selection) { return doc.node(deck)?.locked == true ? nil : deck }
        guard let first = selection.first else { return turnableDeck(selection, focused: board) }
        let found = doc.node(first).flatMap { $0.isArtboard ? $0 : nil } ?? doc.artboard(of: first)
        return found.flatMap { $0.locked ? nil : $0.id }
    }

    /// While a layer of a post is moved, resized or typed into (`id`), the same layer in every
    /// other post where it lies or reaches elsewhere, as four corners on the canvas each: for faint
    /// dashes, so the longest words show from any post (the Mac's DeckTool.drawEchoes).
    public static func echoes(of id: UUID?) -> [[CGPoint]] {
        guard Editing.gestureStart != nil, let id, let doc = design, let (deck, post) = doc.post(of: id), let post,
              deck.posts.count > 1, deck.posts.count <= 400, let mine = doc.absoluteFrame(of: id) else { return [] }
        var seen = Set<[Int]>()
        func key(_ r: CGRect) -> [Int] { [r.minX, r.minY, r.width, r.height].map { Int((Double($0) * 2).rounded()) } }
        seen.insert(key(mine))
        var out: [[CGPoint]] = []
        for q in deck.posts where q != post {
            let other = id.mixed(Deck.key(from: post, to: q))
            guard let n = doc.node(other), let frame = doc.absoluteFrame(of: other), seen.insert(key(frame)).inserted else { continue }
            out.append(Geometry.corners(of: frame, rotation: n.rotation))
        }
        return out
    }

    /// The selection as it is picked, as the Mac's selectionChanged keeps it: a layer of a post
    /// not in front brings that post to the front; one of the design behind the posts is the same
    /// layer in the post in front.
    public static func selecting(_ ids: [UUID]) -> [UUID] {
        guard let doc = design, let first = ids.first, let (deck, post) = doc.post(of: first) else { return ids }
        if let post, post != deck.front(in: fronts) {
            fronts[deck.id] = post
        } else if post == nil, let front = deck.front(in: fronts) {
            return ids.map { id in doc.post(of: id)?.post == nil && doc.post(of: id) != nil ? id.mixed(Deck.key(front)) : id }
        }
        return ids
    }

    /// Turns a deck to one of its posts; what was selected in the post that was in front is
    /// selected in this one. Returns the selection.
    public static func turn(_ deckID: UUID, to post: Int, selection: [UUID]) -> [UUID] {
        guard let doc = design, let deck = doc.node(deckID), deck.isDeck, deck.posts.contains(post) else { return selection }
        let was = deck.front(in: fronts)
        guard was != post else { return selection }
        let moved = doc.carried(selection, deck: deckID, from: was, to: post)
        fronts[deckID] = post
        return moved == selection ? selection : moved.filter { doc.node($0) != nil }
    }

    /// Turns a deck `by` posts on, or back; nothing past the first or the last. Nil when it did not turn.
    public static func turnPage(by steps: Int, deck deckID: UUID, selection: [UUID]) -> [UUID]? {
        guard let deck = design?.node(deckID), deck.isDeck, let at = deck.front(in: fronts), let i = deck.posts.firstIndex(of: at) else { return nil }
        let j = min(max(i + steps, 0), deck.posts.count - 1)
        guard j != i else { return nil }
        return turn(deckID, to: deck.posts[j], selection: selection)
    }

    /// Turns a deck to the post at `index` among its posts.
    public static func turn(_ deckID: UUID, toIndex index: Int, selection: [UUID]) -> [UUID] {
        guard let deck = design?.node(deckID), deck.isDeck, deck.posts.indices.contains(index) else { return selection }
        return turn(deckID, to: deck.posts[index], selection: selection)
    }

    /// Adds a post to an artboard, after the one in front, as a copy of it; an artboard that is no
    /// deck yet becomes one, its layers its first post. The new post comes to the front, the
    /// layers selected in the post copied selected in the copy. Returns the selection.
    public static func addPost(to boardID: UUID, selection: [UUID]) -> [UUID] {
        guard let board = design?.node(boardID), board.isArtboard, !board.locked else { return selection }
        let after = board.isDeck ? board.front(in: fronts) : nil
        var added: Int?
        edit { added = $0.addPost(to: boardID, after: after) }
        guard let added else { return selection }
        if let after { fronts[boardID] = after }
        return turn(boardID, to: added, selection: selection)
    }

    /// Takes a post away from a deck; the one after it comes to the front, or else the one before.
    /// The last post stays. Returns the selection, carried to the next post.
    public static func removePost(_ post: Int, from deckID: UUID, selection: [UUID]) -> [UUID] {
        guard let doc = design, let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return selection }
        let posts = deck.posts
        guard posts.count > 1, let i = posts.firstIndex(of: post) else { return selection }
        let next = i + 1 < posts.count ? posts[i + 1] : posts[i - 1]
        let shown = deck.front(in: fronts) == post
        let k = Deck.key(from: post, to: next)
        let carried = selection.map { id in doc.post(of: id).map { $0.deck.id == deckID && $0.post == post } == true ? id.mixed(k) : id }
        // Turned only once it is gone, so that the step remembers it in front.
        edit { $0.removePost(post, from: deckID) }
        if design?.node(deckID)?.isDeck != true { fronts[deckID] = nil } else if shown { fronts[deckID] = next }
        return carried.filter { design?.node($0) != nil }
    }

    /// Moves a post to another place among a deck's posts, counted before it is moved.
    public static func movePost(_ post: Int, in deckID: UUID, to index: Int) {
        guard let deck = design?.node(deckID), deck.isDeck, !deck.locked, let posts = deck.posts(moving: post, to: index) else { return }
        edit { $0.update(deckID) { $0.deck?.posts = posts } }
    }

    /// Makes a deck an artboard like any again, of the post in front alone.
    public static func unstack(_ deckID: UUID) {
        guard let deck = design?.node(deckID), deck.isDeck, !deck.locked else { return }
        let keep = deck.front(in: fronts)
        edit { $0.unstack(deckID, keeping: keep) }
        fronts[deckID] = nil
    }

    /// Makes each of a deck's posts an artboard of its own, in a row to the right of it. Returns
    /// the artboards, to select.
    public static func spreadOut(_ deckID: UUID) -> [UUID] {
        guard let deck = design?.node(deckID), deck.isDeck, !deck.locked else { return [] }
        let keep = deck.front(in: fronts)
        var made: [UUID] = [deckID]
        edit { made = $0.spreadOut(deckID, keeping: keep) }
        fronts[deckID] = nil
        return made
    }

    /// The same layer in each of a deck's posts, in their order.
    public static func copies(acrossPosts id: UUID) -> [UUID] { design?.copies(acrossPosts: id) ?? [] }

    /// Lets these layers of a post follow the design again in what they kept of their own.
    public static func followDesign(_ ids: [UUID]) { edit { $0.followDesign(ids) } }

    /// Gives every post, and the design behind them, the words or picture these layers hold.
    public static func giveEveryPost(_ ids: [UUID]) { edit { $0.giveEveryPost(ids) } }

    /// What a layer of a post keeps of its own, as the inspector names it; nil when it keeps
    /// nothing (the Mac's PostLayerCard).
    public static func ownWords(_ id: UUID) -> String? {
        guard let n = design?.node(id), n.post != nil, let own = n.own, !own.isEmpty else { return nil }
        let words: [String: String] = [
            "frame": "size and place", "fill": "fill", "border": "border", "shadow": "shadow", "opacity": "opacity",
            "style": "type", "moreFills": "fill", "moreBorders": "border", "moreShadows": "shadow", "rotation": "rotation",
            "cornerRadius": "corners", "corners": "corners", "cornerSmoothing": "corners", "hidden": "hidden", "locked": "locked",
            "blur": "blur", "transform3D": "depth", "blend": "blend", "name": "name", "mask": "mask", "path": "outline",
            "pathBox": "outline", "evenOdd": "outline", "rising": "direction", "clips": "clipping", "slideSize": "slides",
        ]
        var seen = Set<String>()
        return own.compactMap { words[$0].map { say($0) } ?? $0 }.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// Whether a layer is one of a deck's posts' own.
    public static func inPost(_ id: UUID) -> Bool { design?.post(of: id)?.post != nil }

    /// Whether a layer holds words or a picture, to give every post.
    public static func holdsWordsOrPicture(_ id: UUID) -> Bool {
        guard let n = design?.node(id) else { return false }
        return n.kind == .text || n.fill.image != nil
    }

    /// The posts of a deck something no longer fits on: words cut off, or reaching past its edge.
    public static func brokenPosts(_ deckID: UUID) -> Set<Int> {
        guard let deck = design?.node(deckID), deck.isDeck else { return [] }
        return Deck.broken(deck)
    }

    /// After a change made to every post of a deck from the one in front, as the Mac's
    /// considerOffer: the offer to keep it in that post alone.
    static func deckOffer(after before: BezzleDocument) -> DeckOffer? {
        guard let doc = design, doc.nodes.contains(where: \.isDeck) else { return nil }
        for board in doc.nodes where board.isDeck {
            guard let was = before.node(board.id), was != board, was.isDeck,
                  let front = board.front(in: fronts), board.posts.count > 1 else { continue }
            return DeckOffer.make(for: board, was: was, front: front, before: before)
        }
        return nil
    }
}
