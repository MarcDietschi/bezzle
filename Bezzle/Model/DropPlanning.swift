import Foundation
import CoreGraphics

// Things dragged in from elsewhere, shared by every Bezzle: what letting go of pictures or words
// on the canvas would do (`dropPlan`), and doing it; the layers each cell of a repeat grid holds
// of its own and how words from a table go into them; and filling a deck's posts one after another.
// The Mac's DocumentStore and the Windows app both work these out the same way.

/// What letting go of something dragged in would do, worked out once, so that what the canvas
/// shows while it is held over a place is what happens when it is let go there.
enum DropPlan {
    /// The pictures fill these shapes, the first picture the first shape and round again: one
    /// shape, or the same shape in every cell of a repeat grid.
    case fill([UUID])
    /// Each picture is a layer of its own, at these frames on the canvas, on an artboard or on
    /// the canvas itself.
    case place([CGRect], onto: UUID?)
    /// The words go into these text layers of a grid's cells, a line or a column each.
    case words(grid: UUID, layers: [UUID], columns: Int, lines: Int)
    /// Several pictures, each into this shape in a post of its own, from the post it is in on:
    /// the artboard becomes a deck if it is not one, and gains posts as it needs. See `Deck`.
    case posts(shape: UUID, count: Int)
    /// Lines, or the rows of a table, each into this text in a post of its own, the same way.
    case postWords(text: UUID, count: Int)
}

extension BezzleDocument {
    // MARK: What a grid's cells hold

    /// What a grid's cells each hold of their own: its first cell's text layers and the shapes
    /// that can hold a picture, as they are read, top to bottom and left to right.
    func slots(of grid: Node) -> [Node] {
        guard let layout = RepeatGrid.layout(of: grid) else { return [] }
        let first = grid.children[layout.first]
        let cell = RepeatGrid.box(of: first).size
        var found: [(Node, CGPoint)] = []
        func visit(_ n: Node, at origin: CGPoint) {
            let here = CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY)
            // A shape as big as the cell is what the cell is drawn on, not a place for a picture,
            // unless one is there already.
            let backing = n.frame.width * n.frame.height >= cell.width * cell.height * 0.85 && n.id != first.id
            if n.kind == .text || ([.rectangle, .ellipse, .path].contains(n.kind) && (!backing || n.fill.image != nil)) { found.append((n, here)) }
            if n.isGroup { for c in n.children { visit(c, at: here) } }
        }
        visit(first, at: .zero)
        return found.sorted { a, b in abs(a.1.y - b.1.y) > 2 ? a.1.y < b.1.y : a.1.x < b.1.x }.map(\.0)
    }

    /// The same layer in each of a grid's cells, as they are read: the first cell's layer is `slot`.
    func copies(of slot: UUID, in grid: Node) -> [UUID] {
        (grid.grid?.cells ?? []).map { slot.mixed(RepeatGrid.key($0)) }.filter { node($0) != nil }
    }

    /// A layer of some cell, as it is in the first.
    func slot(of id: UUID) -> UUID? {
        guard let grid = grid(holding: id), grid.id != id, let found = RepeatGrid.cell(of: id, in: grid, doc: self) else { return nil }
        return id.mixed(RepeatGrid.key(found.cell))
    }

    /// Which of a grid's text layers words from text go to, and what each gets: a line each, or,
    /// for a table with a heading row such as a CSV file, a column each, to the text layer named as
    /// the column is, and the rest in order.
    func assignments(from text: String, in grid: Node, startingWith preferred: UUID? = nil) -> [(slot: UUID, values: [String])] {
        let texts = slots(of: grid).filter { $0.kind == .text }
        guard !texts.isEmpty else { return [] }
        if let table = DataTable(text), table.columns.count > 1 {
            var filled: [(slot: UUID, values: [String])] = []
            var left = texts
            var columns = table.columns
            for (i, column) in columns.enumerated().reversed() {
                if let at = left.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(column.title) == .orderedSame }) {
                    filled.append((left[at].id, column.values))
                    left.remove(at: at)
                    columns.remove(at: i)
                }
            }
            for (slot, column) in zip(left, columns) { filled.append((slot.id, column.values)) }
            return filled.filter { !$0.values.isEmpty }
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        return [(preferred.flatMap { p in texts.contains { $0.id == p } ? p : nil } ?? texts[0].id, lines)]
    }

    // MARK: Decks

    /// Adds a post after `after` (or the last), a copy of it, and returns its number.
    @discardableResult
    mutating func addPost(to boardID: UUID, after: Int?) -> Int? {
        guard let path = path(of: boardID), path.indices.count == 1 else { return nil }
        var board = self[path]
        guard board.isArtboard else { return nil }
        if !board.isDeck { board = Self.madeDeck(board) }
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
        self[path] = board
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

    /// Fills layers of one post, and the same layers in the posts after it, `count` posts in all,
    /// adding posts at the end as needed: `fill` is given each post's copy of a layer and which post
    /// of them it is, from 0. An artboard that is no deck becomes one. Returns the posts filled.
    @discardableResult
    mutating func spread(_ fills: [(layer: UUID, fill: (inout Node, Int) -> Void)], count: Int) -> [Int] {
        guard count > 0, let first = fills.first?.layer, let board = artboard(of: first) else { return [] }
        let own = board.isDeck ? post(of: first)?.post : nil
        var filled: [Int] = []
        do {
            if !(node(board.id)?.isDeck ?? false), let path = path(of: board.id) {
                self[path] = Self.madeDeck(self[path])
            }
            guard let deck = node(board.id), let start = own ?? deck.posts.first else { return [] }
            var posts = deck.posts
            var at = posts.firstIndex(of: start) ?? 0
            for i in 0..<count {
                if i > 0 {
                    at += 1
                    if at >= posts.count {
                        guard let n = addPost(to: board.id, after: posts.last) else { break }
                        posts.append(n)
                    }
                }
                let p = posts[at]
                for (layer, fill) in fills {
                    // The layer as it is in the design behind every post, and then in this one.
                    update(layer.mixed(Deck.key(start)).mixed(Deck.key(p))) { fill(&$0, i) }
                }
                filled.append(p)
            }
        }
        return filled
    }

    // MARK: Dropping

    /// The topmost mockup screen under a canvas point, whatever lies over it there: where a
    /// picture let go over it goes. Hidden and locked ones are passed over, as is any outside the
    /// artboard that cuts it off.
    func screen(at p: CGPoint) -> UUID? {
        var found: UUID?
        func look(_ nodes: [Node]) {
            for n in nodes where !n.hidden {
                if n.screen == true, !n.locked, let local = placed(p, inParentOf: n.id), Geometry.contains(n, local, tolerance: 0, eye: eye(forParentOf: n.id)) {
                    found = n.id
                }
                if !n.children.isEmpty { look(n.children) }
            }
        }
        for n in nodes where !n.hidden {
            if n.isArtboard, n.clips, !n.frame.contains(p) { continue }
            look([n])
        }
        return found
    }

    /// What dropping pictures (each its size in pixels, upright) or words at a canvas point, on a
    /// layer (or on nothing), would do: pictures fill the shape or the letters of the text they
    /// are dropped on, one each for one repeated in a grid or a post each on an artboard, and
    /// anywhere else are each a layer of their own; words fill a grid's text layers, or a text a
    /// post each. Nil where it can go nowhere.
    func dropPlan(pictures sizes: [CGSize], text: String?, at p: CGPoint, on target: UUID?) -> DropPlan? {
        if !sizes.isEmpty {
            // Over a mockup's screen, into the screen, through the glare and shadows lying over it.
            let target = screen(at: p) ?? target
            if let target, let node = node(target), [.rectangle, .ellipse, .path, .text].contains(node.kind), !node.locked {
                if sizes.count > 1, let grid = grid(holding: target), let slot = slot(of: target) {
                    return .fill(copies(of: slot, in: grid))
                }
                // Several onto a shape on an artboard: a post each.
                if sizes.count > 1, artboard(of: target).map({ !$0.locked }) == true {
                    return .posts(shape: target, count: sizes.count)
                }
                return .fill([target])
            }
            // As big as each is, a point a pixel, but no more than about half the artboard either
            // way, so a photo comes in beside what is there rather than over all of it; fanned out a little.
            let board = artboard(at: p)
            let room = board.map { CGSize(width: $0.frame.width * 0.6, height: $0.frame.height * 0.6) } ?? CGSize(width: 480, height: 480)
            let frames = sizes.enumerated().map { i, own -> CGRect in
                let k = min(1, room.width / max(own.width, 1), room.height / max(own.height, 1))
                let size = CGSize(width: max(1, (own.width * k).rounded()), height: max(1, (own.height * k).rounded()))
                return CGRect(origin: CGPoint(x: (p.x - size.width / 2).rounded() + CGFloat(i * 24), y: (p.y - size.height / 2).rounded() + CGFloat(i * 24)),
                              size: size)
            }
            return .place(frames, onto: board?.id)
        }
        guard let text, let target else { return nil }
        guard let grid = grid(holding: target) else {
            // Onto a text on an artboard: a line, or a table's row, a post.
            guard node(target)?.kind == .text, artboard(of: target).map({ !$0.locked }) == true else { return nil }
            let rows = DataTable(text).flatMap { $0.columns.count > 1 ? $0.columns.map(\.values.count).max() : nil }
                ?? text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return rows > 1 ? .postWords(text: target, count: rows) : nil
        }
        let slot = slot(of: target).flatMap { node($0)?.kind == .text ? $0 : nil }
        let filled = assignments(from: text, in: grid, startingWith: slot)
        guard !filled.isEmpty else { return nil }
        return .words(grid: grid.id, layers: filled.flatMap { copies(of: $0.slot, in: grid) },
                      columns: filled.count, lines: filled.map(\.values.count).max() ?? 0)
    }

    /// Pictures let go on shapes: each shape filled with the next, and round again. All of a
    /// text's letters show it.
    mutating func fill(_ shapes: [UUID], withPictures fills: [ImageFill]) {
        guard !fills.isEmpty else { return }
        for (i, id) in shapes.enumerated() {
            update(id) { n in
                n.fill.on = true
                n.fill.image = fills[i % fills.count]
                n.clearLetterColors()
            }
        }
    }

    /// Pictures let go elsewhere: each a layer of its own, named as its file, at its frame on the
    /// canvas, on an artboard or on the canvas itself. Returns the new layers.
    @discardableResult
    mutating func place(pictures: [(name: String, frame: CGRect, image: ImageFill)], onto board: UUID?) -> [UUID] {
        var made: [UUID] = []
        for (name, frame, image) in pictures {
            var node = Node(kind: .rectangle, name: name, frame: frame)
            node.fill = Fill(color: .shape, image: image)
            attach(node, to: board)
            made.append(node.id)
        }
        return made
    }

    /// Gives a shape a picture each in its own post and the posts after it (see `spread`).
    @discardableResult
    mutating func spread(_ pictures: [ImageFill], from shapeID: UUID) -> [Int] {
        spread([(shapeID, { n, i in
            n.fill.on = true
            n.fill.image = pictures[i]
        })], count: pictures.count)
    }
}

/// A table read from CSV or tab-separated text: its first row names its columns.
nonisolated struct DataTable {
    struct Column {
        var title: String
        var values: [String]
    }

    var columns: [Column]

    /// Nil for text that is no table: lines without a comma, semicolon or tab between columns.
    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let head = lines[0]
        let separator: Character? = ["\t", ";", ","].first { c in head.contains(c) && lines.dropFirst().allSatisfy { $0.contains(c) } }
        guard let separator else { return nil }
        let rows = lines.map { Self.fields(of: $0, separator: separator) }
        columns = rows[0].enumerated().map { i, title in
            Column(title: title.trimmingCharacters(in: .whitespaces), values: rows.dropFirst().map { i < $0.count ? $0[i].trimmingCharacters(in: .whitespaces) : "" })
        }
    }

    /// The fields of one line, with quoted fields that hold the separator or doubled quotes.
    static func fields(of line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                fields.append(field)
                field = ""
            } else {
                field.append(c)
            }
        }
        fields.append(field)
        return fields
    }
}
