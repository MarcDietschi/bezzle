import Foundation
import CoreGraphics

/// A repeat grid: one layer, designed once and repeated in columns across and rows down, the same
/// gap apart. It is a group whose layers are its cells, the first at its top left and every other
/// a copy of that one. The copies are layers like any, so a grid draws, exports and is shared as
/// a group is. Whatever is changed in any cell, its look, its size and place, a layer added to it
/// or taken away, is changed in every cell as it happens. What a cell holds is its own: its words
/// and its pictures.
///
/// Each copy's id is the id of the same layer in the first cell mixed with a key of its cell's own
/// (`key(_:)`), all the way down. So the same layer in every other cell is always known with
/// nothing else kept; two Macs that each make a missing copy make the same layer; and a layer put
/// into some cell keeps its id as it becomes part of the first.
nonisolated struct RepeatGrid: Codable, Hashable {
    var columns = 1
    var rows = 1
    /// Between one column and the next, and between one row and the next. Below zero, cells overlap.
    var columnGap: CGFloat = 20
    var rowGap: CGFloat = 20
    /// Which way its rows run, in degrees clockwise from straight across, and so how far its cells
    /// are turned: a grid turned or flipped is turned or flipped as one. Nil runs straight across.
    var angle: Double?

    /// How many columns a grid can have, and how many rows.
    static let counts = 1...100

    struct Cell: Hashable {
        var column: Int
        var row: Int
        static let first = Cell(column: 0, row: 0)
    }

    var count: Int { columns * rows }

    var turn: Double { angle ?? 0 }

    /// Every cell, the first one first, a row at a time from the top, as it is read.
    var cells: [Cell] { (0..<rows).flatMap { r in (0..<columns).map { Cell(column: $0, row: r) } } }

    static func clamped(_ n: Int) -> Int { min(max(n, counts.lowerBound), counts.upperBound) }

    /// A gap that suits a cell of this size: about an eighth of its shorter side, in fours.
    static func gap(for size: CGSize) -> CGFloat {
        min(32, max(4, (min(size.width, size.height) * 0.125 / 4).rounded() * 4))
    }
}

// MARK: - Keys

nonisolated extension RepeatGrid {
    /// What the ids of a cell's layers are mixed with: nothing for the first cell, and for any
    /// other a number of its own that also says which cell it is. Saved grids depend on it, so it
    /// never changes.
    struct Key: Hashable {
        var a: UInt64
        var b: UInt64
        static let none = Key(a: 0, b: 0)

        /// What mixes an id of one cell into the same id of the other.
        static func ^ (a: Key, b: Key) -> Key { Key(a: a.a ^ b.a, b: a.b ^ b.b) }
    }

    static func key(_ cell: Cell) -> Key {
        guard cell != .first, cell.column >= 0, cell.row >= 0 else { return .none }
        let place = UInt64(UInt32(truncatingIfNeeded: cell.column)) << 32 | UInt64(UInt32(truncatingIfNeeded: cell.row))
        let a = mix(place ^ 0x5851_F42D_4C95_7F2D)
        return Key(a: a, b: place ^ mix(a))
    }

    /// The cell a key is the key of, if it is one.
    static func cell(of key: Key) -> Cell? {
        if key == .none { return .first }
        let place = key.b ^ mix(key.a)
        let cell = Cell(column: Int(place >> 32), row: Int(place & 0xFFFF_FFFF))
        return Self.key(cell) == key ? cell : nil
    }

    /// SplitMix64's last step: every number to another, no two to the same one.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated extension UUID {
    /// This id mixed with a cell's key. Mixed with the same key again, it is itself once more.
    func mixed(_ key: RepeatGrid.Key) -> UUID {
        guard key != .none else { return self }
        var u = uuid
        withUnsafeMutableBytes(of: &u) { raw in
            raw.storeBytes(of: raw.loadUnaligned(as: UInt64.self) ^ key.a, as: UInt64.self)
            raw.storeBytes(of: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self) ^ key.b, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: u)
    }

    /// The key that mixes `other` into this id.
    func key(from other: UUID) -> RepeatGrid.Key {
        let x = withUnsafeBytes(of: uuid) { ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        let y = withUnsafeBytes(of: other.uuid) { ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        return RepeatGrid.Key(a: x.0 ^ y.0, b: x.1 ^ y.1)
    }
}

nonisolated extension Node {
    /// A repeat grid: a group whose layers are its cells.
    var isRepeatGrid: Bool { kind == .group && grid != nil }
}

// MARK: - Reading a grid

nonisolated extension RepeatGrid {
    /// Which of a grid's layers is which cell.
    struct Layout {
        /// Where the first cell is among the grid's layers.
        var first: Int
        /// Every other cell, by where it is among them.
        var cells: [Int: Cell]
        /// What is in the grid that is no cell of it, which it keeps as it is.
        var others: [Int]

        /// The cells' places among the grid's layers, read in order.
        var ordered: [(index: Int, cell: Cell)] {
            cells.map { ($0.key, $0.value) }.sorted { ($0.cell.row, $0.cell.column) < ($1.cell.row, $1.cell.column) }
        }
    }

    static func layout(of grid: Node) -> Layout? {
        let children = grid.children
        guard !children.isEmpty else { return nil }
        // The first cell is the one every other is a copy of: the first of them, unless something
        // was put in front of it. Of two alone, either is a copy of the other, so the first it is.
        func copies(of i: Int) -> Int {
            children.indices.reduce(0) { $1 != i && cell(of: children[$1].id.key(from: children[i].id)) != nil ? $0 + 1 : $0 }
        }
        var first = 0
        if children.count > 2, copies(of: 0) < children.count - 1 {
            let counts = children.indices.map(copies(of:))
            first = counts.firstIndex(of: counts.max() ?? 0) ?? 0
        }
        var layout = Layout(first: first, cells: [:], others: [])
        for i in children.indices where i != first {
            if let cell = cell(of: children[i].id.key(from: children[first].id)), cell != .first {
                layout.cells[i] = cell
            } else {
                layout.others.append(i)
            }
        }
        return layout
    }

    /// The cell a layer of a grid lies in, however deep, and which of the grid's layers that cell
    /// is: from its id and the id of the first cell.
    static func cell(of id: UUID, in grid: Node, doc: BezzleDocument) -> (cell: Cell, root: UUID)? {
        guard let layout = layout(of: grid) else { return nil }
        let first = grid.children[layout.first].id
        let chain = doc.ancestors(of: id).map(\.id) + [id]
        guard let at = chain.firstIndex(of: grid.id), at + 1 < chain.count else { return nil }
        let root = chain[at + 1]
        return cell(of: root.key(from: first)).map { ($0, root) }
    }

    /// How far each cell is from the next, along its row and down its column: the size of the
    /// first, upright, and the gap.
    static func step(of first: Node, _ spec: RepeatGrid) -> CGSize {
        let size = upright(first, angle: spec.turn).size
        return CGSize(width: size.width + spec.columnGap, height: size.height + spec.rowGap)
    }

    /// The step of a grid as it is.
    static func step(of grid: Node) -> CGSize? {
        guard let spec = grid.grid, let layout = layout(of: grid) else { return nil }
        return step(of: grid.children[layout.first], spec)
    }

    /// Where a cell lies from the first one, along rows that run at `angle`.
    static func offset(_ cell: Cell, _ step: CGSize, angle: Double = 0) -> CGPoint {
        Geometry.rotate(CGPoint(x: CGFloat(cell.column) * step.width, y: CGFloat(cell.row) * step.height), by: angle)
    }

    /// What a layer covers in its parent, as a group would be fitted round it.
    static func box(of node: Node) -> CGRect {
        guard node.isGroup else { return Geometry.bounds(of: node) }
        let inner = node.mask?.first.map { Geometry.bounds(of: $0) }
            ?? node.children.map(box).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        return (inner ?? .zero).offsetBy(dx: node.frame.minX, dy: node.frame.minY)
    }

    /// What a layer covers, measured along rows that run at `angle`: the box round it in its
    /// parent's coordinates once they are turned back by as much. Straight across, its box.
    static func upright(_ node: Node, angle: Double) -> CGRect {
        guard angle != 0 else { return box(of: node) }
        var lo = CGPoint(x: CGFloat.infinity, y: .infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        func visit(_ n: Node, _ origin: CGPoint) {
            if n.isGroup {
                let inner = origin + n.frame.origin
                if let mask = n.mask?.first { visit(mask, inner) } else { n.children.forEach { visit($0, inner) } }
                return
            }
            for p in Geometry.corners(of: n.frame.offsetBy(dx: origin.x, dy: origin.y), rotation: n.rotation) {
                let q = Geometry.rotate(p, by: -angle)
                lo = CGPoint(x: min(lo.x, q.x), y: min(lo.y, q.y))
                hi = CGPoint(x: max(hi.x, q.x), y: max(hi.y, q.y))
            }
        }
        visit(node, .zero)
        guard lo.x <= hi.x, lo.y <= hi.y else { return .zero }
        // To a thousandth, so the sines' last digits never move cells about.
        func r(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
        return CGRect(x: r(lo.x), y: r(lo.y), width: r(hi.x - lo.x), height: r(hi.y - lo.y))
    }

    /// A layer and all it holds as it is in the cell with this key: every id mixed with it.
    static func copy(_ node: Node, _ key: Key) -> Node {
        var n = node
        n.id = node.id.mixed(key)
        n.children = node.children.map { copy($0, key) }
        n.mask = node.mask?.map { copy($0, key) }
        return n
    }

    /// A grid's layers with new identities, its cells still copies of its first: for a grid duplicated or pasted.
    @MainActor
    static func freshCells(of grid: Node) -> [Node] {
        guard let layout = layout(of: grid) else { return grid.children.map { $0.freshCopy() } }
        let first = grid.children[layout.first]
        let fresh = first.freshCopy()
        var renamed: [UUID: UUID] = [:]
        func pair(_ a: Node, _ b: Node) {
            renamed[a.id] = b.id
            zip(a.children, b.children).forEach(pair)
        }
        pair(first, fresh)
        func rekeyed(_ n: Node, _ key: Key) -> Node {
            var c = n
            c.id = renamed[n.id.mixed(key)].map { $0.mixed(key) } ?? UUID()
            c.children = n.children.map { rekeyed($0, key) }
            return c
        }
        return grid.children.indices.map { i in
            if i == layout.first { return fresh }
            if let cell = layout.cells[i] { return rekeyed(grid.children[i], key(cell)) }
            return grid.children[i].freshCopy()
        }
    }
}

// MARK: - Keeping the cells alike

extension RepeatGrid {
    /// Makes every other cell of a grid the first one again, but for its words and pictures,
    /// `step` apart (the first cell's size and the gaps, unless given). A cell that is new takes
    /// its words and pictures from the cells there were (`Series`). `earlier` is the grid as it
    /// was when a drag began: a cell taken away and brought back in the same drag comes back as it
    /// was, and the cells it makes are the same however the drag got there.
    static func heal(_ grid: inout Node, step given: CGSize? = nil, earlier: Node? = nil, before: Node? = nil) {
        guard let spec = grid.grid, let layout = layout(of: grid) else { return }
        let first = grid.children[layout.first]
        let step = given ?? Self.step(of: first, spec)

        // The first cell's layers as they were before this change, for what was restyled in their words.
        var firstWas: [UUID: Node] = [:]
        func noteFirst(_ n: Node) {
            firstWas[n.id] = n
            n.children.forEach(noteFirst)
        }
        if let before, let l = Self.layout(of: before) { noteFirst(before.children[l.first]) }

        // Every layer of every other cell, as it is or as it was when the drag began.
        var own: [UUID: Node] = [:]
        func note(_ n: Node) {
            own[n.id] = n
            n.children.forEach(note)
        }
        let before = earlier.flatMap { e in Self.layout(of: e).map { (e, $0) } }
        if let (e, l) = before { for (i, _) in l.cells { note(e.children[i]) } }
        for (i, _) in layout.cells { note(grid.children[i]) }

        // What the new cells hold: in the order they are read, on from those there were before.
        let baseline: Set<Cell> = Set((before.map { Array($0.1.cells.values) } ?? Array(layout.cells.values)) + [.first])
        let cells = Array(spec.cells.dropFirst())
        let fresh = cells.filter { !baseline.contains($0) }
        var continued: [UUID: [String]] = [:]
        var pictures: [UUID: [ImageFill?]] = [:]
        if !fresh.isEmpty {
            let kept = spec.cells.filter { baseline.contains($0) }
            func held(_ m: Node, in cell: Cell) -> Node {
                cell == .first ? m : own[m.id.mixed(key(cell))] ?? m
            }
            func survey(_ m: Node) {
                if m.kind == .text {
                    continued[m.id] = Series.continuing(kept.map { held(m, in: $0).text ?? "" }, count: fresh.count)
                }
                let images = kept.map { held(m, in: $0).fill.image }
                if images.contains(where: { $0 != nil }) { pictures[m.id] = Series.repeating(images, count: fresh.count) }
                m.children.forEach(survey)
            }
            survey(first)
        }
        let order = Dictionary(uniqueKeysWithValues: fresh.enumerated().map { ($0.element, $0.offset) })

        var made: [Node] = []
        made.reserveCapacity(cells.count)
        for cell in cells {
            let key = Self.key(cell), shift = offset(cell, step, angle: spec.turn), new = order[cell]
            func build(_ m: Node, root: Bool) -> Node {
                var n = m
                n.id = m.id.mixed(key)
                n.children = m.children.map { build($0, root: false) }
                n.mask = m.mask?.map { copy($0, key) }
                if root { n.frame.origin = n.frame.origin + shift }
                if let new {
                    if let words = continued[m.id] {
                        n.text = words[new]
                        n.spans = m.spans.flatMap { TextSpan.stored(TextSpan.aligned($0, onto: words[new])) }
                    }
                    if let image = pictures[m.id] { n.fill.image = image[new] }
                } else if let was = own[n.id] {
                    // Its words and how their letters look are its own, but for what was changed
                    // of the whole layer, or of the same words, in the first cell.
                    if m.kind == .text, was.kind == .text {
                        n.text = was.text
                        n.spans = was.lettersCarried(from: m, was: firstWas[m.id])
                    }
                    n.fill.image = was.fill.image
                }
                if n.kind == .text, n.text != m.text || n.spans != m.spans { n.refit() }
                return n
            }
            made.append(build(first, root: true))
        }
        grid.children = [first] + made + layout.others.map { grid.children[$0] }
    }

    /// Carries what was changed in the other cells since `before` to the first one, from which
    /// every cell is then made again; `step` is how far apart the cells were laid out. What the
    /// first cell had changed itself, it keeps. Taking a cell away, or the first one, takes away
    /// what the grid repeats: the grid is left empty, and goes.
    static func carry(from before: Node, into grid: inout Node, step: CGSize) {
        guard let was = layout(of: before), let now = layout(of: grid) else { return }
        let angle = before.grid?.turn ?? 0
        let firstWas = before.children[was.first]
        let present = Set(grid.children.map(\.id))
        if !present.contains(firstWas.id) || was.cells.keys.contains(where: { !present.contains(before.children[$0].id) }) {
            grid.children = []
            return
        }
        let earlier = Dictionary(before.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let untouched = grid.children[now.first]
        var first = untouched
        for (i, cell) in now.ordered {
            let x = grid.children[i]
            guard let xb = earlier[x.id], xb != x else { continue }
            carry(cell: x, was: xb, key: key(cell), shift: offset(cell, step, angle: angle), into: &first, firstNow: untouched, firstWas: firstWas)
        }
        grid.children[now.first] = first
    }

    /// One layer of a cell, where it lies: what holds it, where among what else it holds, and
    /// where the coordinates it is placed in start, in the grid's own.
    private struct Placed {
        var node: Node
        var parent: UUID?
        var index: Int
        var origin: CGPoint

        /// Where what it holds is placed from.
        var inner: CGPoint { node.isGroup ? origin + node.frame.origin : origin }
    }

    private static func placed(_ root: Node) -> [UUID: Placed] {
        var out: [UUID: Placed] = [:]
        func visit(_ n: Node, parent: UUID?, index: Int, origin: CGPoint) {
            let p = Placed(node: n, parent: parent, index: index, origin: origin)
            out[n.id] = p
            for (j, c) in n.children.enumerated() { visit(c, parent: n.id, index: j, origin: p.inner) }
        }
        visit(root, parent: nil, index: 0, origin: .zero)
        return out
    }

    private static func carry(cell x: Node, was xb: Node, key: Key, shift: CGPoint, into first: inout Node, firstNow: Node, firstWas: Node) {
        let now = placed(x), then = placed(xb)
        let mineNow = placed(firstNow), mineThen = placed(firstWas)

        // What was changed about layers that were there before.
        for (id, p) in now {
            guard let q = then[id] else { continue }
            let target = id.mixed(key)
            guard let m = mineNow[target] else { continue }
            let mWas = mineThen[target]?.node
            // Only what the first cell did not change itself, nor what the cell keeps as its own,
            // as a deck's post can (`Node.own`).
            let own = Set(p.node.own ?? [])
            func free(_ field: LayerField) -> Bool { mWas.map { field.same($0, m.node) } ?? true }
            var changes: [(inout Node) -> Void] = []
            for field in LayerField.all where !field.same(p.node, q.node) && free(field) && !own.contains(field.name) {
                switch field.name {
                case "text", "spans", "frame", "post", "own":
                    continue
                case "fill":
                    // Its picture is the cell's own.
                    var a = p.node.fill, b = q.node.fill
                    a.image = nil
                    b.image = nil
                    if a != b { changes.append { $0.fill = Fill(on: a.on, color: a.color, gradient: a.gradient, image: $0.fill.image) } }
                case "mask":
                    let mask = p.node.mask?.map { copy($0, key) }
                    changes.append { $0.mask = mask }
                default:
                    let node = p.node
                    changes.append { field.copy(&$0, node) }
                }
            }
            // Letters restyled, or the whole layer: the same in the first cell, where its words are alike.
            if p.node.kind == .text, m.node.kind == .text, !own.contains("spans"),
               p.node.spans != q.node.spans || p.node.style != q.node.style || p.node.fill.color != q.node.fill.color {
                let target = m.node, source = p.node, sourceWas = q.node
                changes.append { $0.spans = target.lettersCarried(from: source, was: sourceWas) }
            }
            // Moved or resized; but not grown or shrunk to its words as they were typed or restyled.
            let typed = p.node.kind == .text && (p.node.text != q.node.text || p.node.spans != q.node.spans)
            if p.node.frame != q.node.frame, !typed, !own.contains("frame"), mWas.map({ $0.frame == m.node.frame }) ?? true {
                let at = p.origin + p.node.frame.origin - shift
                let frame = CGRect(origin: at - m.origin, size: p.node.frame.size)
                changes.append { node in
                    node.frame = frame
                    node.refit()
                }
            }
            if !changes.isEmpty { modify(&first, target) { n in changes.forEach { $0(&n) } } }
        }

        // Layers taken out of the cell, from the first; layers put into it, into the first, where
        // they lie in it; layers moved from one group in it to another, in the first too.
        for (id, q) in then where now[id]?.parent != q.parent {
            remove(id.mixed(key), from: &first)
        }
        for (id, p) in now.sorted(by: { ($0.value.origin.y, $0.value.index) < ($1.value.origin.y, $1.value.index) }) {
            guard let parent = p.parent, then[id]?.parent != parent, now[parent] != nil,
                  then[parent] != nil || then[id] != nil else { continue }
            let mine = placed(first)
            guard mine[id.mixed(key)] == nil, let holder = mine[parent.mixed(key)] else { continue }
            var adopted = copy(p.node, key)
            adopted.frame.origin = p.origin + p.node.frame.origin - shift - holder.inner
            insert(adopted, into: holder.node.id, at: p.index, in: &first)
        }
        // Layers moved up or down among the others in a group of the cell.
        for (id, p) in now where p.node.isGroup {
            guard let q = then[id], p.node.children.map(\.id) != q.node.children.map(\.id) else { continue }
            let order = p.node.children.map { $0.id.mixed(key) }
            modify(&first, id.mixed(key)) { group in
                let placed = Dictionary(group.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let listed = order.compactMap { placed[$0] }
                group.children = listed + group.children.filter { !order.contains($0.id) }
            }
        }
    }

    @discardableResult
    private static func modify(_ root: inout Node, _ id: UUID, _ change: (inout Node) -> Void) -> Bool {
        if root.id == id {
            change(&root)
            return true
        }
        for i in root.children.indices where modify(&root.children[i], id, change) { return true }
        return false
    }

    private static func remove(_ id: UUID, from root: inout Node) {
        if let i = root.children.firstIndex(where: { $0.id == id }) {
            root.children.remove(at: i)
            return
        }
        for i in root.children.indices { remove(id, from: &root.children[i]) }
    }

    private static func insert(_ node: Node, into parent: UUID, at index: Int, in root: inout Node) {
        modify(&root, parent) { $0.children.insert(node, at: min(max(index, 0), $0.children.count)) }
    }

    /// The same cells as there are, with what they are missing put back from the first cell, what
    /// the first cell has not taken away, and as many of them as the grid has. Nothing that is there
    /// is changed: for a grid put together from changes made on several Macs, which each kept its
    /// cells alike. Returns whether anything was missing or left over.
    nonisolated static func repair(_ grid: inout Node) -> Bool {
        guard let spec = grid.grid, let layout = layout(of: grid) else { return false }
        let first = grid.children[layout.first]
        let step = Self.step(of: first, spec)
        var byCell: [Cell: Node] = [:]
        for (i, cell) in layout.cells { byCell[cell] = grid.children[i] }
        var children = [first]
        for cell in spec.cells.dropFirst() {
            let key = Self.key(cell)
            if let x = byCell[cell] {
                var have: [UUID: Node] = [:]
                func note(_ n: Node) {
                    have[n.id] = n
                    n.children.forEach(note)
                }
                note(x)
                func build(_ m: Node) -> Node {
                    var n = have[m.id.mixed(key)] ?? copy(m, key)
                    n.children = m.children.map(build)
                    return n
                }
                children.append(build(first))
            } else {
                var made = copy(first, key)
                made.frame.origin = made.frame.origin + offset(cell, step, angle: spec.turn)
                children.append(made)
            }
        }
        children += layout.others.map { grid.children[$0] }
        guard children != grid.children else { return false }
        grid.children = children
        return true
    }

    // MARK: Turning and flipping

    /// A grid turned as one about a point in its parent: its layers are turned, as any group's
    /// are, and its rows run the new way.
    static func turned(_ grid: Node, by degrees: Double, about pivot: CGPoint) -> Node {
        var g = grid
        let inner = CGPoint(x: pivot.x - g.frame.minX, y: pivot.y - g.frame.minY)
        g.children = g.children.map { BezzleDocument.turned($0, by: degrees, about: inner) }
        let angle = CanvasView.normalized((g.grid?.turn ?? 0) + degrees)
        g.grid?.angle = angle == 0 ? nil : angle
        return g
    }

    /// A grid mirrored as one across a line in its parent. Its layers are mirrored, as any
    /// group's are, which leaves its first cell at the far end of its row (or the foot of its
    /// column); so the cells change places, each keeping what it holds, until the first is at the
    /// start again. Mirrored, its rows run the other way round.
    static func flipped(_ grid: Node, horizontally: Bool, about axis: CGFloat) -> Node {
        var g = grid
        let inner = axis - (horizontally ? g.frame.minX : g.frame.minY)
        g.children = g.children.map { BezzleDocument.flipped($0, horizontally: horizontally, about: inner) }
        guard var spec = g.grid, let layout = layout(of: grid) else { return g }
        func moved(_ n: Node, _ key: Key) -> Node {
            var c = n
            c.id = n.id.mixed(key)
            c.children = n.children.map { moved($0, key) }
            c.mask = n.mask?.map { moved($0, key) }
            return c
        }
        var cells: [(Cell, Node)] = [], others: [Node] = []
        for (i, child) in g.children.enumerated() {
            guard let from = i == layout.first ? Cell.first : layout.cells[i], from.column < spec.columns, from.row < spec.rows else {
                others.append(child)
                continue
            }
            let to = horizontally ? Cell(column: spec.columns - 1 - from.column, row: from.row)
                                  : Cell(column: from.column, row: spec.rows - 1 - from.row)
            cells.append((to, moved(child, key(from) ^ key(to))))
        }
        g.children = cells.sorted { ($0.0.row, $0.0.column) < ($1.0.row, $1.0.column) }.map(\.1) + others
        if spec.turn != 0 { spec.angle = CanvasView.normalized(-spec.turn) }
        g.grid = spec
        return g
    }
}

// MARK: - The whole design

extension BezzleDocument {
    /// Keeps the cells of every repeat grid changed since `before` alike: what was changed in any
    /// cell goes to the first, and every cell is made from it again. `start` is the design as it
    /// was when a drag began: while something in a cell other than the first is dragged, the cells
    /// stay as far apart as they were then, so what is dragged stays under the pointer, and they
    /// settle when it ends (`relayoutGrids`).
    mutating func syncGrids(since before: BezzleDocument, start: BezzleDocument? = nil) {
        var list = nodes
        if Self.syncGrids(&list, before: before, start: start) { nodes = list }
    }

    private static func syncGrids(_ list: inout [Node], before: BezzleDocument, start: BezzleDocument?) -> Bool {
        var changed = false
        for i in list.indices where !list[i].children.isEmpty || list[i].isRepeatGrid {
            let was = before.node(list[i].id)
            if let was, was == list[i] { continue }
            // A grid inside a cell first, then the grid it is in.
            if syncGrids(&list[i].children, before: before, start: start) { changed = true }
            guard list[i].isRepeatGrid else { continue }
            var grid = list[i]
            let earlier = start?.node(grid.id).flatMap { $0.isRepeatGrid ? $0 : nil }
            var held: CGSize?
            if let was, was.isRepeatGrid, copiesChanged(from: was, to: grid) {
                let then = earlier.flatMap(RepeatGrid.step(of:))
                if let step = then ?? RepeatGrid.step(of: was) { RepeatGrid.carry(from: was, into: &grid, step: step) }
                held = then
            }
            RepeatGrid.heal(&grid, step: held, earlier: earlier, before: was)
            if grid != list[i] {
                list[i] = grid
                changed = true
            }
        }
        return changed
    }

    /// Whether any cell but the first was changed.
    private static func copiesChanged(from was: Node, to grid: Node) -> Bool {
        guard let layout = RepeatGrid.layout(of: grid) else { return false }
        let earlier = Dictionary(was.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return layout.cells.keys.contains { earlier[grid.children[$0].id] != grid.children[$0] }
            || was.children.count != grid.children.count
    }

    /// Lays the cells of every grid changed since `start` out again as their first cells are now,
    /// once a drag that held them apart has ended.
    mutating func relayoutGrids(since start: BezzleDocument) {
        var list = nodes
        if Self.relayoutGrids(&list, since: start) { nodes = list }
    }

    private static func relayoutGrids(_ list: inout [Node], since start: BezzleDocument) -> Bool {
        var changed = false
        for i in list.indices where !list[i].children.isEmpty {
            if let was = start.node(list[i].id), was == list[i] { continue }
            if relayoutGrids(&list[i].children, since: start) { changed = true }
            guard list[i].isRepeatGrid else { continue }
            var grid = list[i]
            RepeatGrid.heal(&grid)
            if grid != list[i] {
                list[i] = grid
                changed = true
            }
        }
        return changed
    }
}

nonisolated extension BezzleDocument {
    /// Puts back what any grid's cells are missing, and takes away what they have that their first
    /// cell does not; see `RepeatGrid.repair`.
    mutating func repairGrids() {
        var list = nodes
        if Self.repairGrids(&list) { nodes = list }
    }

    private static func repairGrids(_ list: inout [Node]) -> Bool {
        var changed = false
        for i in list.indices where !list[i].children.isEmpty {
            if repairGrids(&list[i].children) { changed = true }
            if list[i].isRepeatGrid, RepeatGrid.repair(&list[i]) { changed = true }
        }
        return changed
    }
}

// MARK: - What new cells hold

/// What new cells hold, from what the cells before them hold, as they are read: numbers counting
/// on, when every one is the same words around a number a step from the next; anything else the
/// same again, round and round.
nonisolated enum Series {
    static func continuing(_ values: [String], count: Int) -> [String] {
        guard count > 0, !values.isEmpty else { return [] }
        if let counted = counting(values, count: count) { return counted }
        return repeating(values, count: count)
    }

    static func repeating<T>(_ values: [T], count: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        return (0..<count).map { values[$0 % values.count] }
    }

    /// The number in some words: what comes before it, its digits, and what comes after it.
    static func number(in text: String) -> (before: Substring, digits: Substring, after: Substring)? {
        guard let last = text.lastIndex(where: \.isASCIIDigit) else { return nil }
        var start = last
        while start > text.startIndex, text[text.index(before: start)].isASCIIDigit { start = text.index(before: start) }
        let end = text.index(after: last)
        return (text[..<start], text[start..<end], text[end...])
    }

    private static func counting(_ values: [String], count: Int) -> [String]? {
        guard values.count >= 2 else { return nil }
        let parts = values.compactMap(number(in:))
        guard parts.count == values.count, let shape = parts.first,
              parts.allSatisfy({ $0.before == shape.before && $0.after == shape.after }) else { return nil }
        let numbers = parts.compactMap { Int($0.digits) }
        guard numbers.count == parts.count, Set(numbers).count == numbers.count else { return nil }
        let sorted = numbers.sorted()
        let step = sorted[1] - sorted[0]
        guard step > 0, zip(sorted, sorted.dropFirst()).allSatisfy({ $1 - $0 == step }) else { return nil }
        // "07" is counted on as "08": as many digits as the longest, when any starts with a nought.
        let padded = parts.contains { $0.digits.count > 1 && $0.digits.first == "0" }
        let width = parts.map(\.digits.count).max() ?? 1
        return (1...count).map { i in
            var digits = String(sorted.last! + step * i)
            if padded, digits.count < width { digits = String(repeating: "0", count: width - digits.count) + digits }
            return "\(shape.before)\(digits)\(shape.after)"
        }
    }
}

private nonisolated extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
