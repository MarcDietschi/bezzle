import Foundation
import CoreGraphics

/// A deck: one artboard that is many posts, lying one behind another, of which only the one in
/// front is seen. They are designed once. A change to the look of anything in any post is made in
/// every post; what a post holds is its own: its words and its pictures, and anything else it was
/// told to keep (`Node.own`). However many posts there are, the canvas holds one artboard.
///
/// The posts are layers like any, lying on the artboard. Behind them all lies the design they are
/// made from, which is never seen: the artboard's layers that are in no post (`Node.post`). Each
/// post's layers are the design's, every id mixed with the post's key all the way down, as a
/// repeat grid's cells are (`RepeatGrid.key`). So what is changed in a post is carried to the
/// design, and from there to every other post, the way a grid's cells are kept alike; and two Macs
/// that each make a post's missing layer make the same one.
///
/// A post is numbered once, at random, and keeps its number wherever it is moved among the others.
/// Taking one away or moving it changes no other post's layers, so nothing someone else is changing
/// in them meanwhile goes astray, and two people who each add a post at once add two.
nonisolated struct Deck: Codable, Hashable {
    /// The posts, by number, in the order they are turned through.
    var posts: [Int]

    /// What mixes the ids of the design's layers into a post's; nothing for the design itself.
    static func key(_ post: Int?) -> RepeatGrid.Key {
        guard let post, post > 0 else { return .none }
        return RepeatGrid.key(RepeatGrid.Cell(column: post, row: 0))
    }

    /// What mixes a layer of one post into the same layer of another.
    static func key(from a: Int?, to b: Int?) -> RepeatGrid.Key { key(a) ^ key(b) }

    /// A number for a new post that no post has.
    static func number(besides taken: [Int]) -> Int {
        let used = Set(taken)
        while true {
            let n = Int.random(in: 1...Int(Int32.max))
            if !used.contains(n) { return n }
        }
    }

    /// What a layer's own properties are called, for keeping them (`Node.own`).
    static let fields = Dictionary(LayerField.all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    /// Of a layer's properties, those a post can keep as its own: not what it holds or where it lies
    /// among the others, nor its words and pictures, which are its own anyway.
    static let keepable: Set<String> = Set(LayerField.all.map(\.name)).subtracting(["kind", "text", "post", "own", "deck", "grid", "layout", "guides", "instance", "master", "flow", "starts"])
}

nonisolated extension Node {
    /// A deck: an artboard of posts lying one behind another.
    var isDeck: Bool { kind == .artboard && deck != nil }

    /// A deck's posts, by number, in the order they are turned through: those it lists, and then
    /// any it has layers of without listing them, as one added on another Mac while posts were being
    /// moved about on this one would be.
    var posts: [Int] {
        guard let deck else { return [] }
        var seen = Set<Int>(), order: [Int] = []
        for p in deck.posts where p > 0 && seen.insert(p).inserted { order.append(p) }
        var more: [Int] = []
        for c in children { if let p = c.post, p > 0, seen.insert(p).inserted { more.append(p) } }
        return order + more.sorted()
    }

    /// The layers of one of a deck's posts, bottom first; of none, the design behind them.
    func layers(of post: Int?) -> [Node] { children.filter { $0.post == post } }

    /// A deck as one of its posts shows it: an artboard with only that post's layers on it.
    func showing(_ post: Int?) -> Node {
        var n = self
        n.deck = nil
        n.children = layers(of: post)
        return n
    }

    /// A deck as its first post shows it, and anything else as it is: for drawing it where nobody
    /// has turned to another post, as on the home screen.
    var shownAlone: Node { isDeck ? showing(posts.first) : self }

    /// This layer, and all it holds, forgetting what it kept of its own in a post.
    func forgettingOwn() -> Node {
        var n = self
        n.own = nil
        n.children = children.map { $0.forgettingOwn() }
        return n
    }

    /// The same, but for the layers in `known` that are in it, which keep what they kept, and
    /// nothing in it marked as being in a post: for layers put together on a deck out of some
    /// that were on it, as a group made in a post is.
    func forgettingOwn(but known: [UUID: Node]) -> Node {
        var n = self
        if known[id] == nil { n.own = nil }
        n.children = children.map {
            var c = $0.forgettingOwn(but: known)
            c.post = nil
            return c
        }
        return n
    }

    /// Whether this layer or anything it holds is marked as being in a deck.
    var marksDeck: Bool { post != nil || own != nil || children.contains(where: \.marksDeck) }
}

// MARK: - Keeping the posts alike

extension Deck {
    /// Keeps a deck's posts alike after a change, `was` being the deck before it (nil for one just
    /// made, or changed so it cannot be told). A layer put onto it goes into the post `front`, or the
    /// first. What was changed in a post is carried to the design, unless the post keeps it as its
    /// own, and every post is made from the design again with what it holds.
    static func sync(_ board: inout Node, was: Node?, front: Int?) {
        let posts = board.posts
        guard !posts.isEmpty else { return }
        let into = front.flatMap { posts.contains($0) ? $0 : nil } ?? posts[0]
        if let was {
            let before = Set(was.children.map(\.id))
            let present = Set(board.children.map(\.id))
            // The design's layers: those it had, and one new to it that every post has a copy of,
            // as a layer duplicated in every post at once is.
            let design = Set(board.children.filter { c in
                c.post == nil && (before.contains(c.id) || posts.allSatisfy { present.contains(c.id.mixed(key($0))) })
            }.map(\.id))
            // What lay in a post before, however deep, stays in that post and keeps what it kept of
            // its own wherever it moved in it, as into a group made there or out of one.
            var known: [UUID: Node] = [:], inPost: [UUID: Int] = [:]
            for c in was.children {
                guard let p = c.post else { continue }
                var here: [UUID: Node] = [:]
                note(c, in: &here)
                known.merge(here) { a, _ in a }
                for id in here.keys { inPost[id] = p }
            }
            for i in board.children.indices where !before.contains(board.children[i].id) {
                let c = board.children[i]
                if c.post == nil, design.contains(c.id) { continue }
                if let p = c.post, posts.contains(p), design.contains(c.id.mixed(key(p))) { continue }
                var n = c.forgettingOwn(but: known)
                n.post = inPost[c.id].flatMap { posts.contains($0) ? $0 : nil } ?? into
                board.children[i] = n
            }
        }

        var designWas: [UUID: Node] = [:]
        if let was { for layer in was.layers(of: nil) { note(layer, in: &designWas) } }
        var design = board.layers(of: nil)
        if let was {
            let then = wrapped(was, posts: posts)
            var now = wrapped(board, posts: posts)
            RepeatGrid.carry(from: then, into: &now, step: .zero)
            // Layers that came into the design from a post, as one grouped there does, came as that
            // post has them: what the post keeps of its own is the design's again.
            if let first = now.children.first { design = first.children.map { designs($0, was: designWas) } }
        }
        board.children = made(from: design, posts: posts, holding: board, designWas: designWas)
    }

    /// A layer of the design as the design has it: what it kept of its own in the post it came
    /// from as it was in the design, and nothing in it marked as being in a post.
    private static func designs(_ n: Node, was: [UUID: Node]) -> Node {
        var d = n
        if let own = d.own, let then = was[d.id] {
            for name in own { fields[name]?.copy(&d, then) }
            if d.kind == .text { d.refit() }
        }
        d.own = nil
        d.post = nil
        d.children = n.children.map { designs($0, was: was) }
        return d
    }

    /// The same deck with what any post is missing put back from the design, and what a post has
    /// that the design has not taken away. Nothing that is there is changed: for a deck put together
    /// from changes made on several Macs, each of which kept its posts alike. Returns whether
    /// anything was missing or left over.
    nonisolated static func repair(_ board: inout Node) -> Bool {
        let posts = board.posts
        guard !posts.isEmpty else { return false }
        let design = board.layers(of: nil)
        var children = design
        for p in posts {
            let k = key(p)
            var have: [UUID: Node] = [:]
            for c in board.children where c.post == p { note(c, in: &have) }
            func build(_ m: Node) -> Node {
                var n = have[m.id.mixed(k)] ?? RepeatGrid.copy(m, k)
                n.children = m.children.map(build)
                return n
            }
            for m in design {
                var n = build(m)
                n.post = p
                children.append(n)
            }
        }
        guard children != board.children else { return false }
        board.children = children
        return true
    }

    /// A deck's layers with new identities, its posts still copies of the design, each with what
    /// it holds: for a deck duplicated or pasted.
    static func freshPosts(of board: Node) -> [Node] {
        var renamed: [UUID: UUID] = [:]
        func pair(_ a: Node, _ b: Node) {
            renamed[a.id] = b.id
            zip(a.children, b.children).forEach(pair)
            zip(a.mask ?? [], b.mask ?? []).forEach(pair)
        }
        var fresh: [UUID: Node] = [:]
        for layer in board.layers(of: nil) {
            let copy = layer.freshCopy()
            pair(layer, copy)
            fresh[layer.id] = copy
        }
        func rekeyed(_ n: Node, _ k: RepeatGrid.Key) -> Node {
            var c = n
            c.id = renamed[n.id.mixed(k)].map { $0.mixed(k) } ?? UUID()
            c.children = n.children.map { rekeyed($0, k) }
            c.mask = n.mask?.map { rekeyed($0, k) }
            return c
        }
        return board.children.map { c in
            guard let p = c.post else { return fresh[c.id] ?? c.freshCopy() }
            return rekeyed(c, key(p))
        }
    }

    /// Copies a layer of a deck's post, and with it the same layer in the design and in every other
    /// post, each copy just over the layer it copies and moved by `offset`, so that each post's copy
    /// holds what that post's layer holds. Returns the copy in the post the layer is in.
    static func duplicate(_ id: UUID, in doc: inout BezzleDocument, offset: CGPoint) -> UUID? {
        // In a repeat grid, the grid keeps its cells alike itself.
        guard let (deck, post) = doc.post(of: id), let post, !doc.ancestors(of: id).contains(where: \.isRepeatGrid) else { return nil }
        let k = key(post)
        guard let original = doc.node(id.mixed(k)) else { return nil }
        // The design's copy has new identities; every post's copy is keyed from them, as the
        // posts' layers are from the design's.
        let fresh = original.freshCopy()
        var renamed: [UUID: UUID] = [:]
        func pair(_ a: Node, _ b: Node) {
            renamed[a.id] = b.id
            zip(a.children, b.children).forEach(pair)
            zip(a.mask ?? [], b.mask ?? []).forEach(pair)
        }
        pair(original, fresh)
        func rekeyed(_ n: Node, _ k: RepeatGrid.Key) -> Node {
            var c = n
            c.id = renamed[n.id.mixed(k)].map { $0.mixed(k) } ?? UUID()
            c.children = n.children.map { rekeyed($0, k) }
            c.mask = n.mask?.map { rekeyed($0, k) }
            return c
        }
        var made: UUID?
        for q in [nil] + deck.posts {
            let at = id.mixed(key(from: post, to: q))
            guard let path = doc.path(of: at) else { continue }
            var copy = q == nil ? fresh : rekeyed(doc[path], key(q))
            copy.frame.origin.x += offset.x
            copy.frame.origin.y += offset.y
            var above = path
            above.indices[above.indices.count - 1] += 1
            doc.insert(copy, at: above)
            if q == post { made = copy.id }
        }
        return made
    }

    /// Every post made from the design, keeping what each holds of its own.
    private static func made(from design: [Node], posts: [Int], holding board: Node, designWas: [UUID: Node] = [:]) -> [Node] {
        var children = design
        children.reserveCapacity(design.count * (posts.count + 1))
        var have: [Int: [UUID: Node]] = [:]
        for c in board.children { if let p = c.post { note(c, in: &have[p, default: [:]]) } }
        for p in posts {
            let k = key(p), held = have[p] ?? [:]
            for m in design {
                var n = build(m, k, held, designWas)
                n.post = p
                children.append(n)
            }
        }
        return children
    }

    private nonisolated static func note(_ n: Node, in have: inout [UUID: Node]) {
        have[n.id] = n
        for c in n.children { note(c, in: &have) }
    }

    /// A layer of the design as it is in the post with key `k`: its words and pictures, and what
    /// else it keeps of its own, from the post's layer as it was.
    private static func build(_ m: Node, _ k: RepeatGrid.Key, _ held: [UUID: Node], _ designWas: [UUID: Node]) -> Node {
        var n = m
        n.id = m.id.mixed(k)
        n.children = m.children.map { build($0, k, held, designWas) }
        n.mask = m.mask?.map { RepeatGrid.copy($0, k) }
        n.post = nil
        n.own = nil
        if let was = held[n.id] {
            // How its letters look is its own too, but for what was changed of the whole layer, or
            // of the same words, in the design.
            if m.kind == .text, was.kind == .text {
                n.text = was.text
                n.spans = was.lettersCarried(from: m, was: designWas[m.id], keeps: Set(was.own ?? []))
            }
            n.fill.image = was.fill.image
            n.flow = was.flow
            if let own = was.own {
                for name in own { fields[name]?.copy(&n, was) }
                n.own = own
            }
        }
        if n.kind == .text, n.text != m.text || n.spans != m.spans { n.refit() }
        return n
    }

    /// A deck as a repeat grid whose cells lie on top of each other: the design first, then each
    /// post, every one a group as big as the artboard, so the grid's own way of carrying a change in
    /// one cell to the first can be used for it.
    private static func wrapped(_ board: Node, posts: [Int]) -> Node {
        let page = CGRect(origin: .zero, size: board.frame.size)
        var grid = Node(kind: .group, frame: page)
        grid.grid = RepeatGrid()
        var byPost: [Int: [Node]] = [:]
        var design: [Node] = []
        for c in board.children {
            var n = c
            n.post = nil
            if let p = c.post { byPost[p, default: []].append(n) } else { design.append(n) }
        }
        func cell(_ post: Int?, _ layers: [Node]) -> Node {
            var w = Node(kind: .group, frame: page)
            w.id = board.id.mixed(key(post))
            w.children = layers
            return w
        }
        grid.children = [cell(nil, design)] + posts.map { cell($0, byPost[$0] ?? []) }
        return grid
    }
}

// MARK: - The whole design

extension BezzleDocument {
    /// Keeps the posts of every deck changed since `before` alike (`Deck.sync`); a layer put onto a
    /// deck goes into the post in front of it, by `fronts`. A layer that came off a deck, and lies
    /// somewhere else now, forgets it was in one.
    mutating func syncDecks(since before: BezzleDocument, fronts: [UUID: Int] = [:]) {
        var list = nodes
        var changed = false
        for i in list.indices {
            let was = before.path(of: list[i].id).map { before[$0] }
            if let was, was == list[i] { continue }
            if list[i].isDeck {
                var board = list[i]
                Deck.sync(&board, was: was?.isDeck == true ? was : nil, front: fronts[board.id])
                if board != list[i] {
                    list[i] = board
                    changed = true
                }
            } else if Self.forgetDecks(in: &list[i], was: was) {
                changed = true
            }
        }
        if changed { nodes = list }
    }

    /// Takes away what marks a layer new here as being in a deck: on an artboard, its new layers.
    private static func forgetDecks(in node: inout Node, was: Node?) -> Bool {
        if !node.isArtboard {
            guard was == nil, node.marksDeck else { return false }
            node.post = nil
            node = node.forgettingOwn()
            return true
        }
        let before = Set(was?.children.map(\.id) ?? [])
        var changed = false
        for i in node.children.indices where !before.contains(node.children[i].id) && node.children[i].marksDeck {
            node.children[i].post = nil
            node.children[i] = node.children[i].forgettingOwn()
            changed = true
        }
        return changed
    }
}

nonisolated extension BezzleDocument {
    /// Puts back what any deck's posts are missing, and takes away what they have that the design
    /// behind them does not; see `Deck.repair`.
    mutating func repairDecks() {
        var list = nodes
        var changed = false
        for i in list.indices where list[i].isDeck {
            if Deck.repair(&list[i]) { changed = true }
        }
        if changed { nodes = list }
    }

    /// The deck a layer lies in, however deep, and the post it is in there; nil for a layer on no deck.
    func post(of id: UUID) -> (deck: Node, post: Int?)? {
        guard let p = path(of: id), p.indices.count > 1, nodes[p.top].isDeck else { return nil }
        let deck = nodes[p.top]
        return (deck, deck.children[p.indices[1]].post)
    }
}
