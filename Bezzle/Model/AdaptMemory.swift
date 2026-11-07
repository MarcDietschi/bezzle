import Foundation

/// What the pictures on an artboard show, as laying its design out again takes them: where in
/// each what draws the eye lies (0…1 across and down), and for a cut-out picture where what it
/// shows lies and where most of it is. Each platform finds what it can.
struct AdaptPictures {
    var focus: [String: CGPoint] = [:]
    var shapes: [String: CGRect] = [:]
    var cores: [String: CGRect] = [:]
}

/// Laying an artboard's design out again when it takes a new size; see `Adapt`.
@MainActor
enum Adapting {
    /// Posted with the artboards (`ids`) whose layers were just laid out again, for the canvas to
    /// move them there rather than jump.
    static let laidOut = Notification.Name("Bezzle.adaptLaidOut")

    /// The design as it was made, by artboard, and the artboard as it was last laid out from it.
    /// While the artboard is left as it was laid out, its next size is laid out from the design as
    /// it was made, so that going back to that size gives the design back exactly.
    private static var made: [UUID: (source: Node, laid: Node)] = [:]
    /// The artboards remembered, the one laid out last at the end; only so many are kept.
    private static var order: [UUID] = []
    static let kept = 64
    static var remembered: Int { made.count }

    /// Whether an artboard's design is laid out again when it changes size: not a carousel, whose
    /// slides are added and taken away, nor one told to keep its layers where they are.
    static func adapts(_ board: Node) -> Bool {
        board.isArtboard && !board.isCarousel && board.pinsLayers != true && !board.children.isEmpty
    }

    /// The design to lay an artboard out from: as it was made, while it is as it was last laid out.
    static func source(of board: Node) -> Node {
        guard let kept = made[board.id], kept.laid.frame.size == board.frame.size,
              kept.laid.layers(of: nil) == board.layers(of: nil) else { return board }
        var s = board
        s.frame.size = kept.source.frame.size
        // Its posts as they were too, while nothing in them has changed since.
        if kept.laid.children == board.children {
            s.children = kept.source.children
            return s
        }
        // Else a deck's posts are as they are now: only the design behind them is laid out.
        let design = Dictionary(kept.source.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard kept.source.layers(of: nil).count == board.layers(of: nil).count else { return board }
        s.children = board.children.map { c in c.post == nil ? design[c.id] ?? c : c }
        return s
    }

    /// Notes that `laid` was laid out from `source`, to lay it out from that again next time.
    static func remember(source: Node, laid: Node) {
        order.removeAll { $0 == laid.id }
        if source.frame.size == laid.frame.size && source.layers(of: nil) == laid.layers(of: nil) {
            made[laid.id] = nil
        } else {
            made[laid.id] = (source, laid)
            order.append(laid.id)
            while order.count > kept { made[order.removeFirst()] = nil }
        }
    }

    /// An artboard at a new size: its design laid out again for it, or its layers left where they
    /// are on it, from its top left.
    ///
    /// `pictures` says what the pictures on the design it is laid out from show, where a platform
    /// can tell (the Mac looks with Vision); without it, they are taken as a whole.
    static func resized(_ board: Node, to size: CGSize, pictures: (Node) -> AdaptPictures = { _ in AdaptPictures() },
                        remembering: Bool = true) -> Node {
        var out = board
        out.frame.size = size
        guard adapts(board), size != board.frame.size, size.width >= 1, size.height >= 1 else { return out }
        let source = source(of: board)
        let seen = pictures(source)
        let plan = Adapt.plan(source, mode: Adapt.mode(of: source, to: size), focus: seen.focus, shapes: seen.shapes, cores: seen.cores)
        // What a post keeps of its own goes from the design as it was made, never from a step on
        // the way, so nothing creeps.
        out.children = merged(Adapt.compose(plan, to: size).board, into: source, from: source)
        if remembering { remember(source: source, laid: out) }
        return out
    }

    /// What lies on `board` with the design's layers as `laid` has them, and a deck's posts as
    /// `board` has them, for the deck to make them again from the design. What a post's layer
    /// keeps of its own, its place or its type, goes as the same layer of the design went from
    /// `original`, the artboard as it was before it took its new size.
    static func merged(_ laid: Node, into board: Node, from original: Node? = nil) -> [Node] {
        let original = original ?? board
        let design = Dictionary(laid.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let then = Dictionary(original.layers(of: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let was = Dictionary(original.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return board.children.map { c in
            guard let post = c.post else { return design[c.id] ?? c }
            let twin = c.id.mixed(Deck.key(post))
            guard let old = then[twin], let new = design[twin], let own = was[c.id] else { return c }
            return carried(c, own: own, from: old, to: new, key: Deck.key(post))
        }
    }

    /// A post's layer, `now`, with what it keeps of its own as it was (`own`) carried as its
    /// twin in the design went from `old` to `new`; and so for what it holds.
    private static func carried(_ now: Node, own: Node, from old: Node, to new: Node, key: RepeatGrid.Key) -> Node {
        var n = now
        let kept = Set(own.own ?? [])
        if kept.contains("frame"), old.frame.width > 0 || old.frame.height > 0 {
            var f = Geometry.map(own.frame, from: old.frame, to: new.frame)
            if old.frame.width <= 0 { f.size.width = own.frame.width }
            if old.frame.height <= 0 { f.size.height = own.frame.height }
            n.frame = f
        }
        if kept.contains("style") || kept.contains("spans"), let a = old.style?.size, let b = new.style?.size, a > 0, abs(b / a - 1) > 0.0001 {
            n.style = own.style
            n.spans = own.spans
            n.scaleType(by: b / a)
        }
        guard !now.children.isEmpty else { return n }
        let olds = Dictionary(old.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let news = Dictionary(new.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let owns = Dictionary(own.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        n.children = now.children.map { c in
            let twin = c.id.mixed(key)
            guard let o = olds[twin], let w = news[twin], let k = owns[c.id] else { return c }
            return carried(c, own: k, from: o, to: w, key: key)
        }
        return n
    }

    /// Tells the canvas these artboards were just laid out again.
    static func announce(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // The browser's Foundation posts no notifications, and has no canvas to tell.
        #if !os(WASI)
        NotificationCenter.default.post(name: laidOut, object: nil, userInfo: ["ids": ids])
        #endif
    }

    // MARK: Dragging

    /// An artboard being resized by a drag: its design read once, and laid out at each size the
    /// drag reaches, keeping the arrangement it is in unless another suits clearly better.
    final class Session {
        let id: UUID
        let source: Node
        let plan: Adapt.Plan
        private(set) var arrangement: Adapt.Arrangement = .original
        private(set) var last: Adapt.Result?

        init?(_ board: Node, pictures: (Node) -> AdaptPictures = { _ in AdaptPictures() }) {
            guard Adapting.adapts(board) else { return nil }
            id = board.id
            source = Adapting.source(of: board)
            let seen = pictures(source)
            plan = Adapt.plan(source, focus: seen.focus, shapes: seen.shapes, cores: seen.cores)
        }

        /// The design laid out at `size`, and whether it is arranged another way than a moment ago.
        func compose(_ size: CGSize) -> (result: Adapt.Result, rearranged: Bool) {
            let r = Adapt.compose(plan, to: size, keeping: arrangement)
            let rearranged = r.arrangement != arrangement
            arrangement = r.arrangement
            last = r
            return (r, rearranged)
        }
    }
}

extension Adapting {
    /// Artboards at new sizes, each design laid out again: by artboard, the design each was laid
    /// out from, for `finish(_:in:)` once the change is made. Carousels keep whole slides, and
    /// are left to their own rows.
    static func resize(_ doc: inout BezzleDocument, _ ids: [UUID], to size: (Node) -> CGSize,
                       pictures: (Node) -> AdaptPictures = { _ in AdaptPictures() }) -> [UUID: Node] {
        var laid: [UUID: Node] = [:]
        for id in ids {
            doc.update(id) { b in
                guard b.isArtboard, !b.isCarousel else { return }
                let s = size(b)
                guard s != b.frame.size, s.width >= 1, s.height >= 1 else { return }
                let source = Adapting.source(of: b)
                b = Adapting.resized(b, to: s, pictures: pictures)
                laid[id] = source
            }
        }
        return laid
    }

    /// Remembers what the artboards just resized were laid out from, as the design ended up (its
    /// decks' posts made again from it), and tells the canvas.
    static func finish(_ laid: [UUID: Node], in doc: BezzleDocument) {
        for (id, source) in laid { if let n = doc.node(id) { Adapting.remember(source: source, laid: n) } }
        Adapting.announce(laid.keys.filter { doc.node($0).map(Adapting.adapts) ?? false })
    }

    /// The artboard as it would be at `size`, its design laid out again, for showing what a size
    /// would do before it is chosen; nil when it would not change.
    static func preview(_ doc: BezzleDocument, of id: UUID, to size: CGSize,
                        pictures: (Node) -> AdaptPictures = { _ in AdaptPictures() }) -> ((inout BezzleDocument) -> Void)? {
        guard let b = doc.node(id), b.isArtboard, !b.isCarousel, size != b.frame.size else { return nil }
        let shown = Adapting.resized(b, to: size, pictures: pictures, remembering: false)
        return { doc in
            let before = doc
            doc.update(id) { $0 = shown }
            // A deck shows a post, which follows the design.
            doc.syncDecks(since: before)
        }
    }
}
