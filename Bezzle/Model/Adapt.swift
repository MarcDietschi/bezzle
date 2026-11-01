import Foundation
import CoreGraphics

/// A design laid out again when its artboard takes a new size, with the design in mind rather
/// than each layer pinned to an edge.
///
/// The design is read first, as a designer reads it (`plan`): what covers the whole artboard (a
/// backdrop, which goes on covering it), what bleeds off its edges (kept bleeding off the same
/// edge or corner), and the rest as blocks in rows and columns, found by cutting the artboard
/// along the empty space between them. A block is a layer, a few that overlap and so belong
/// together, or a shape holding others, which is a little design of its own. Between blocks, a
/// gap is tight when it binds them (a heading and the line under it) or loose when it is room to
/// breathe; across a row or a column, each block keeps to the side it lies near, its middle, or
/// both sides.
///
/// Laid out at a new size (`compose`), the design grows or shrinks as a whole, its type with it,
/// by as much as suits the new size and still fits: a poster keeps its weight on the page, a
/// screen keeps its type the size it reads at. Tight gaps keep their proportion; the room left
/// goes to the loose ones, or around a block standing on its own. What stretches stretches: bars
/// and panels run edge to edge, text set to a width wraps to the new one, a picture is cropped
/// again around what it shows. Where the design no longer fits as it is, it is arranged again:
/// a picture above its words goes beside them on a wide format and back above them on a tall
/// one, and cards in a row wrap into a grid.
///
/// The same design at the same size is the same design: nothing moves until the size does, and
/// coming back to the size it was made at gives it back exactly.
enum Adapt {
    /// How a design takes a new size: as a composition, whose parts grow and shrink with the page
    /// (posts, print, slides), or as an interface, whose type stays the size it reads at and which
    /// gains room or loses it (screens and pages).
    enum Mode: Equatable { case composition, interface }

    enum Axis: Equatable {
        /// Side by side, along the width.
        case x
        /// One under another, down the height.
        case y

        var other: Axis { self == .x ? .y : .x }
    }

    /// Where something keeps its place across what holds it.
    enum Anchor: Equatable {
        /// At the distance it was from the side it lies near.
        case start, end
        /// In the middle.
        case center
        /// From one side to the other, as far in from each as it was.
        case span
        /// As far along the room it leaves as it was: 0 at the start, 1 at the end.
        case share(CGFloat)
    }

    struct Place: Equatable {
        var anchor: Anchor
        /// How far it was from the start side and from the end side.
        var before: CGFloat
        var after: CGFloat
    }

    struct Insets: Equatable {
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
        static let zero = Insets()
    }

    /// Layers side by side in one coordinate space, as an artboard or a group holds them.
    struct Layers {
        var nodes: [Node]
        /// What each covers, turned layers by the box around them; a cut-out picture, as much of
        /// its box as what it shows covers.
        var boxes: [CGRect]
        /// The cut-out pictures among them: a person without a background, which keeps its shape.
        var cutouts: Set<Int> = []
        /// For a cut-out, where most of what it shows is: a person's body, without the arm they
        /// hold out. What lies beside that, over their picture's empty part, lies beside them.
        var cores: [Int: CGRect] = [:]

        init(_ nodes: [Node]) {
            self.nodes = nodes
            boxes = nodes.map { Geometry.bounds(of: $0) }
        }
    }

    /// One or more layers that are laid out as one.
    struct Unit {
        indirect enum Shape {
            /// Grows and shrinks as a whole, as a picture of it would.
            case rigid
            /// A plain shape or a picture, which takes any size.
            case stretchy
            /// Text set to a width: takes a new width, its height following its words.
            case text
            /// A shape holding the others, which are laid out again inside it.
            case holder(Int, Frame)
            /// A group whose layers are laid out again inside it.
            case group(Layers, Frame)
        }

        var members: [Int]
        var box: CGRect
        var shape: Shape
        /// How far it reached past the edges of what holds it, which it is held to.
        var bleed = Insets.zero
        /// A panel running across the whole artboard: how much of the artboard it takes along
        /// the way the blocks stack.
        var share: CGFloat?
        var picture = false
        /// Whether it takes a fair part of what holds it, so that the eye goes to it.
        var prominent = false
        /// Made of paths and shapes, without words: an illustration, a mark.
        var drawing = false
        /// Where most of it is, for cutting blocks apart: a cut-out's body; else all of it.
        var core: CGRect = .null
        /// What it is made of, to tell blocks that are alike.
        var signature: [Node.Kind] = []
        /// A text alone, growing and shrinking as a whole: measured at each scale, as its letters
        /// do not grow quite in step with it.
        var words: Words?
        /// Words to be read, set in a column: a text, or a group of them. On a page, its lines
        /// keep a length that reads well, whatever room the page gives them.
        var reads = false

        var isHolder: Bool {
            if case .holder = shape { return true }
            return false
        }
    }

    /// A text's size at each scale it is tried at.
    final class Words {
        let node: Node
        private var sizes: [Int: CGSize] = [:]

        init(_ node: Node) { self.node = node }

        func size(_ k: CGFloat) -> CGSize {
            let key = Int((k * 100_000).rounded())
            if let s = sizes[key] { return s }
            let s = Geometry.bounds(of: Adapt.scaled(node, by: k)).size
            sizes[key] = s
            return s
        }
    }

    /// Blocks in a row (`x`) or a column (`y`), cut apart along the empty space between them.
    struct Stack {
        var axis: Axis
        var children: [Piece]
        /// The empty space between each block and the next.
        var gaps: [CGFloat]
        /// Which of those gaps are room to breathe rather than what binds two blocks.
        var loose: [Bool]
        /// Where each block lies across the stack.
        var places: [Place]
        var box: CGRect
        /// The room before the first block and after the last, along the stack: the margins, for
        /// the stack an artboard's whole design lies in.
        var ends: (CGFloat, CGFloat) = (0, 0)
        /// Whether its blocks are alike, as cards in a row are, and so can wrap into a grid.
        var alike = false
    }

    indirect enum Piece {
        case unit(Unit)
        case stack(Stack)

        var box: CGRect {
            switch self {
            case .unit(let u): u.box
            case .stack(let s): s.box
            }
        }
    }

    /// What lies in a box: an artboard, or a shape holding other layers.
    struct Frame {
        var box: CGRect
        /// Layers covering it, which go on covering it.
        var backdrops: [Int] = []
        /// Layers bleeding off its edges, or hidden: each kept to the sides it lies near.
        var loose: [(Int, Place, Place)] = []
        /// Bands running from side to side at one edge, under what lies over them, such as hills
        /// along the foot of a poster: kept at that edge, run across it again at any size. Along
        /// `x` for one running across, and whether it keeps to the far edge (the foot, the right).
        var bands: [(Int, Axis, Bool)] = []
        /// The rest, as blocks in rows and columns.
        var flow: Stack?
    }

    /// A design read, ready to be laid out at any size.
    struct Plan {
        let board: Node
        /// Which of the artboard's layers are laid out: all of them, or of a deck, the design
        /// behind its posts, which the posts follow.
        let indices: [Int]
        let layers: Layers
        let root: Frame
        let mode: Mode
        /// Where in each picture what it shows lies, 0…1 across and down, by the picture's file.
        let focus: [String: CGPoint]
        /// The way to the first stack of alike blocks, by the index of each block on the way.
        let wrapPath: [Int]?
        /// The ways to the stacks that can turn: the design's own, and those with a picture at an end.
        let turnPaths: [[Int]]
    }

    /// How the design is arranged at a size.
    struct Arrangement: Hashable {
        /// The stack whose two parts go side by side where they were one under the other, or the
        /// other way, by the way to it (none for the design's own stack); nil for none.
        var turned: [Int]?
        /// How many alike blocks go in a row, where they wrap.
        var columns: Int?

        static let original = Arrangement()
    }

    /// What was understood of the design, as it is laid out now, to be drawn while it changes.
    struct Skeleton: Equatable {
        /// The blocks.
        var blocks: [CGRect] = []
        /// Loose gaps, which give and take room, and the way each runs.
        var springs: [(rect: CGRect, axis: Axis)] = []
        /// Tight gaps, which hold blocks together.
        var bonds: [(rect: CGRect, axis: Axis)] = []

        static func == (a: Skeleton, b: Skeleton) -> Bool {
            a.blocks == b.blocks && a.springs.map(\.rect) == b.springs.map(\.rect) && a.bonds.map(\.rect) == b.bonds.map(\.rect)
        }
    }

    struct Result {
        /// The artboard at its new size, its layers laid out for it.
        var board: Node
        var arrangement: Arrangement
        var skeleton: Skeleton
        /// How much the design grew (above 1) or shrank.
        var scale: CGFloat
    }

    // MARK: - Reading the design

    /// Reads an artboard's design. A deck's design behind its posts is read; the posts follow it.
    /// `shapes` says, by each picture's file, where in it what it shows lies, 0…1 across and down,
    /// for pictures with a transparent ground; `focus`, what in it draws the eye.
    static func plan(_ board: Node, mode: Mode? = nil, focus: [String: CGPoint] = [:], shapes: [String: CGRect] = [:],
                     cores: [String: CGRect] = [:]) -> Plan {
        let indices = board.children.indices.filter { !board.isDeck || board.children[$0].post == nil }
        let box = CGRect(origin: .zero, size: board.frame.size)
        // A large photo that the artboard crops, most of it past its edges, is read as what shows
        // of it: a panel of the page, laid out with the rest.
        var layers = Layers(indices.map { i in
            let n = board.children[i]
            let shown = n.frame.intersection(box)
            guard !shown.isNull, shown.area >= box.area * 0.15, shown.area < n.frame.area * 0.7, let c = clipped(n, to: box) else { return n }
            return c
        })
        // A cut-out, a person without a background, is as big as the person: what lies beside
        // them, over the empty part of their picture, lies beside them.
        for (i, n) in layers.nodes.enumerated() {
            guard let image = n.fill.image, image.mode != .stretch, n.rotation == 0, n.transform3D == nil, let shape = shapes[image.asset],
                  shape.minX > 0.04 || shape.minY > 0.04 || shape.maxX < 0.96 || shape.maxY < 0.96 else { continue }
            let drawn = Renderer.imageRect(image, in: n.frame.size).offsetBy(dx: n.frame.minX, dy: n.frame.minY)
            let shown = CGRect(x: drawn.minX + shape.minX * drawn.width, y: drawn.minY + shape.minY * drawn.height,
                               width: shape.width * drawn.width, height: shape.height * drawn.height).intersection(n.frame)
            guard !shown.isNull, shown.width > 1, shown.height > 1 else { continue }
            layers.boxes[i] = shown
            layers.cutouts.insert(i)
            if let core = cores[image.asset] {
                let c = CGRect(x: drawn.minX + core.minX * drawn.width, y: drawn.minY + core.minY * drawn.height,
                               width: core.width * drawn.width, height: core.height * drawn.height).intersection(shown)
                if !c.isNull, c.width > 1, c.height > 1 { layers.cores[i] = c }
            }
        }
        let mode = mode ?? Self.mode(of: board)
        var root = frame(Array(layers.nodes.indices), in: box, layers: layers, depth: 0)
        // A screen's bars keep the height they read at, rather than a share of the screen.
        if mode == .interface, var flow = root.flow {
            for i in flow.children.indices {
                if case .unit(var u) = flow.children[i], u.share != nil { u.share = nil; flow.children[i] = .unit(u) }
            }
            root.flow = flow
        }
        var wrapPath: [Int]?, turnPaths: [[Int]] = []
        if let flow = root.flow {
            wrapPath = alikePath(in: .stack(flow), path: [])
            if flow.children.count >= 2 { turnPaths.append([]) }
            func visit(_ s: Stack, _ path: [Int]) {
                for (i, c) in s.children.enumerated() {
                    guard case .stack(let t) = c, turnPaths.count < 3 else { continue }
                    if t.children.count >= 2, visual(t.children[0]) || visual(t.children[t.children.count - 1]), !t.alike {
                        turnPaths.append(path + [i])
                    }
                    visit(t, path + [i])
                }
            }
            visit(flow, [])
        }
        return Plan(board: board, indices: indices, layers: layers, root: root,
                    mode: mode, focus: focus, wrapPath: wrapPath, turnPaths: turnPaths)
    }

    /// Screens and pages are interfaces; posts, print and slides are compositions. Told by the
    /// size, when it is a device's or a platform's, else by the type: a screen's reads at a size
    /// of its own, small beside the page, where a poster's is drawn to the page.
    static func mode(of board: Node, to size: CGSize? = nil) -> Mode {
        func kind(_ s: CGSize) -> Preset.Kind? { Preset.matching(s)?.group.kind }
        let own = board.frame.size
        if let k = kind(own) ?? size.flatMap(kind) { return k == .devices ? .interface : .composition }
        if own.height >= own.width * 1.9 { return .interface }
        var sizes: [CGFloat] = []
        func visit(_ n: Node) {
            if n.kind == .text, let s = n.style?.size { sizes.append(s) }
            n.children.forEach(visit)
        }
        board.children.forEach(visit)
        guard !sizes.isEmpty else { return .composition }
        let middle = sizes.sorted()[sizes.count / 2]
        return middle < min(own.width, own.height) * 0.026 ? .interface : .composition
    }

    /// What lies in `box` of the layers `members`, which are bottom first.
    private static func frame(_ members: [Int], in box: CGRect, layers: Layers, depth: Int) -> Frame {
        var f = Frame(box: box)
        var flow: [Int] = []
        let tol = max(1, min(box.width, box.height) * 0.004)
        for i in members {
            let n = layers.nodes[i], b = layers.boxes[i]
            let inside = b.intersection(box)
            if n.hidden || inside.isNull || inside.area < b.area * 0.5 && b.area > 0 {
                f.loose.append((i, place(b, in: box, along: .x, stretches: false), place(b, in: box, along: .y, stretches: false)))
                continue
            }
            if n.kind != .text, n.kind != .line, inside.area >= box.area * 0.85 {
                f.backdrops.append(i)
                continue
            }
            let over = Insets(top: box.minY - b.minY, left: box.minX - b.minX, bottom: b.maxY - box.maxY, right: b.maxX - box.maxX)
            // Reaching both sides, flush with them or past them, it runs across.
            let acrossX = over.left > -tol && over.right > -tol, acrossY = over.top > -tol && over.bottom > -tol
            let past = over.top > tol || over.left > tol || over.bottom > tol || over.right > tol
            // Bleeding off a side or a corner without running across: kept there, as it is.
            if past && !acrossX && !acrossY {
                f.loose.append((i, place(b, in: box, along: .x, stretches: false), place(b, in: box, along: .y, stretches: false)))
                continue
            }
            flow.append(i)
        }
        // A band along an edge, running across, that other blocks lie over, lies under them as a
        // ground does: it runs across at any size, and they are laid out over it.
        for i in flow {
            let n = layers.nodes[i], b = layers.boxes[i]
            guard n.kind != .text, n.fill.image == nil, n.rotation.truncatingRemainder(dividingBy: 360) == 0, n.transform3D == nil else { continue }
            let acrossX = b.minX <= box.minX + tol && b.maxX >= box.maxX - tol, acrossY = b.minY <= box.minY + tol && b.maxY >= box.maxY - tol
            let top = b.minY <= box.minY + tol, foot = b.maxY >= box.maxY - tol, left = b.minX <= box.minX + tol, right = b.maxX >= box.maxX - tol
            let axis: Axis
            if acrossX && (top != foot) && b.height < box.height * 0.6 { axis = .x } else if acrossY && (left != right) && b.width < box.width * 0.6 { axis = .y } else { continue }
            let under = flow.contains { j in j > i && layers.boxes[j].insetBy(dx: 0.5, dy: 0.5).intersects(b.insetBy(dx: 0.5, dy: 0.5)) }
            guard under else { continue }
            f.bands.append((i, axis, axis == .x ? foot : right))
        }
        flow.removeAll { i in f.bands.contains { $0.0 == i } }


        guard !flow.isEmpty else { return f }
        let units = clusters(flow, in: box, layers: layers, depth: depth)
        var root: Stack
        switch cut(units, in: box) {
        case .stack(let s): root = s
        case .unit(let u):
            root = Stack(axis: .y, children: [.unit(u)], gaps: [], loose: [], places: [], box: u.box)
        }
        // The design's own stack lies in the whole box: its blocks are placed across the box,
        // and the room before and after them along it is its margins.
        let main = root.axis, cross = main.other
        root.places = root.children.map { place($0.box, in: box, along: cross, stretches: stretches($0, cross)) }
        root.ends = (lo(root.box, main) - lo(box, main), hi(box, main) - hi(root.box, main))
        root.loose = looseness(root.gaps, length: length(box, main))
        let edge = max(tol, 2)
        for i in root.children.indices {
            guard case .unit(var u) = root.children[i], root.places[i].before <= edge, root.places[i].after <= edge,
                  stretches(.unit(u), cross) else { continue }
            u.share = length(u.box, main) / max(length(box, main), 1)
            root.children[i] = .unit(u)
        }
        f.flow = root
        return f
    }

    /// The layers `flow` as blocks: those that overlap belong together.
    private static func clusters(_ flow: [Int], in box: CGRect, layers: Layers, depth: Int) -> [Unit] {
        var parent = Dictionary(uniqueKeysWithValues: flow.map { ($0, $0) })
        func find(_ i: Int) -> Int {
            var r = i
            while let p = parent[r], p != r { r = p }
            return r
        }
        let held = flow.map { (layers.cores[$0] ?? layers.boxes[$0]).intersection(box).insetBy(dx: 0.5, dy: 0.5) }
        for a in flow.indices {
            for b in flow.indices where b > a {
                let ra = held[a], rb = held[b]
                // Lines lying on a shape belong to it; two that only touch do not.
                let overlap = ra.intersects(rb) || ra.height <= 0 && rb.contains(ra.center) || rb.height <= 0 && ra.contains(rb.center)
                if overlap { parent[find(flow[b])] = find(flow[a]) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in flow { groups[find(i), default: []].append(i) }
        return groups.values.map { members in
            unit(members.sorted(), in: box, layers: layers, depth: depth)
        }
    }

    private static func unit(_ members: [Int], in box: CGRect, layers: Layers, depth: Int) -> Unit {
        let whole = members.map { layers.boxes[$0] }.reduce(CGRect.null) { $0.union($1) }
        var u = Unit(members: members, box: whole.intersection(box), shape: .rigid)
        if u.box.isNull { u.box = whole }
        u.core = members.map { layers.cores[$0] ?? layers.boxes[$0] }.reduce(CGRect.null) { $0.union($1) }.intersection(u.box)
        if u.core.isNull { u.core = u.box }
        u.bleed = Insets(top: max(0, box.minY - whole.minY), left: max(0, box.minX - whole.minX),
                         bottom: max(0, whole.maxY - box.maxY), right: max(0, whole.maxX - box.maxX))
        u.picture = members.contains { layers.nodes[$0].fill.image != nil }
        u.prominent = u.box.area >= box.area * 0.12
        // A drawing, paths and shapes without words, is a picture of its own.
        u.drawing = members.allSatisfy { m in
            let n = layers.nodes[m]
            func wordless(_ n: Node) -> Bool { n.kind != .text && n.children.allSatisfy(wordless) }
            return n.kind != .text && n.kind != .rectangle && wordless(n)
        }
        u.signature = members.map { layers.nodes[$0].kind }
        if members.count == 1 {
            let n = layers.nodes[members[0]]
            u.shape = shape(of: n, depth: depth)
            if case .stretchy = u.shape, n.fill.image != nil, u.box.area < box.area * 0.08 || layers.cutouts.contains(members[0]) { u.shape = .rigid }
            if case .rigid = u.shape, n.kind == .text, n.transform3D == nil { u.words = Words(n) }
            switch u.shape {
            case .text: u.reads = true
            case .group: u.reads = n.children.allSatisfy { $0.kind != .ellipse } && n.children.contains { $0.kind == .text && $0.style?.sizing != .autoWidth }
            default: break
            }
            return u
        }
        // A shape lying under all the others, which lie in it, holds them.
        let h = members[0], hb = layers.boxes[h]
        let holds = members.dropFirst().allSatisfy { i in
            let b = layers.boxes[i]
            return b.intersection(hb).area >= b.area * 0.85 || b.height <= 0 && hb.insetBy(dx: -1, dy: -1).contains(b.center)
        }
        if holds, depth < 4, case .stretchy = shape(of: layers.nodes[h], depth: depth), layers.nodes[h].kind != .line {
            let inner = frame(Array(members.dropFirst()), in: hb, layers: layers, depth: depth + 1)
            u.shape = .holder(h, inner)
            u.box = hb.intersection(box).isNull ? hb : hb.intersection(box)
        }
        return u
    }

    /// How a layer on its own takes a new size.
    private static func shape(of n: Node, depth: Int) -> Unit.Shape {
        let flat = n.rotation.truncatingRemainder(dividingBy: 360) == 0 && n.transform3D == nil
        switch n.kind {
        case .text:
            return flat && n.style?.sizing != .autoWidth ? .text : .rigid
        case .rectangle:
            return flat ? .stretchy : .rigid
        case .line:
            // A rule runs along its length; a slash keeps its slant.
            return flat && (n.frame.width <= 0.5 || n.frame.height <= 0.5) ? .stretchy : .rigid
        case .group:
            // A copy of a component is laid out inside as its component says.
            guard flat, !n.isRepeatGrid, !n.isCopy, n.clipsToFirst != true, n.mask == nil, depth < 4,
                  BezzleDocument.turn(of: n) == 0, n.children.count > 1 else { return .rigid }
            let inside = Layers(n.children)
            let f = frame(Array(inside.nodes.indices), in: CGRect(origin: .zero, size: n.frame.size), layers: inside, depth: depth + 1)
            // A group takes another shape only if what it holds can: a ring of circles, or a
            // drawing of paths, grows and shrinks as a whole.
            let grounds = f.backdrops.map { shape(of: inside.nodes[$0], depth: 9) }
            if grounds.contains(where: { if case .stretchy = $0 { return false } else { return true } }) { return .rigid }
            // A bar or a card, on a plain ground, is laid out again inside; so is a column or a
            // line of words, with rules between them. A drawing, an illustration of paths and
            // shapes, is not: it grows and shrinks as a whole.
            let words = n.children.allSatisfy { c in
                c.kind == .text || [.line, .path, .rectangle].contains(c.kind) && min(c.frame.width, c.frame.height) <= 2
            } && n.children.contains { $0.kind == .text }
            let gives = !grounds.isEmpty || words && (f.flow.map { stretches(.stack($0), .x) || stretches(.stack($0), .y) } ?? false)
            return gives ? .group(inside, f) : .rigid
        default:
            return .rigid
        }
    }

    /// Blocks cut apart along the widest empty space between them, again and again: rows of
    /// columns of rows.
    private static func cut(_ units: [Unit], in box: CGRect) -> Piece {
        guard units.count > 1 else { return .unit(units[0]) }
        let byY = bands(units, along: .y), byX = bands(units, along: .x)
        let choice: (Axis, [[Unit]], [CGFloat])?
        switch (byY.groups.count > 1, byX.groups.count > 1) {
        case (true, false): choice = (.y, byY.groups, byY.gaps)
        case (false, true): choice = (.x, byX.groups, byX.gaps)
        case (true, true):
            // The way with more room between its parts, as a reader sees it first; down, when alike.
            let wy = (byY.gaps.max() ?? 0) / max(box.height, 1), wx = (byX.gaps.max() ?? 0) / max(box.width, 1)
            choice = wx > wy * 1.25 ? (.x, byX.groups, byX.gaps) : (.y, byY.groups, byY.gaps)
        default: choice = nil
        }
        guard let (axis, groups, gaps) = choice else { return .unit(merged(units)) }
        let children = groups.map { cut($0, in: box) }
        let union = children.map(\.box).reduce(CGRect.null) { $0.union($1) }
        var s = Stack(axis: axis, children: children, gaps: gaps, loose: looseness(gaps, length: length(union, axis)),
                      places: [], box: union)
        s.places = children.map { place($0.box, in: union, along: axis.other, stretches: stretches($0, axis.other)) }
        s.alike = isAlike(children)
        return .stack(s)
    }

    /// Blocks as bands along `axis`, with the empty space between each band and the next.
    private static func bands(_ units: [Unit], along axis: Axis) -> (groups: [[Unit]], gaps: [CGFloat]) {
        // Cut apart where blocks mostly are, a cut-out by its body; the gap is as their boxes have
        // it, less than nothing where the empty part of one reaches under the next.
        func core(_ u: Unit) -> CGRect { u.core.isNull ? u.box : u.core }
        let sorted = units.sorted { lo(core($0), axis) < lo(core($1), axis) }
        var groups: [[Unit]] = [[sorted[0]]], gaps: [CGFloat] = []
        var end = hi(core(sorted[0]), axis), reach = hi(sorted[0].box, axis)
        for u in sorted.dropFirst() {
            if lo(core(u), axis) >= end - 0.5 {
                gaps.append(lo(u.box, axis) - reach)
                groups.append([u])
                reach = hi(u.box, axis)
            } else {
                groups[groups.count - 1].append(u)
                reach = max(reach, hi(u.box, axis))
            }
            end = max(end, hi(core(u), axis))
        }
        return (groups, gaps)
    }

    /// Blocks that cannot be cut apart, as one that grows and shrinks as a whole.
    private static func merged(_ units: [Unit]) -> Unit {
        var u = Unit(members: units.flatMap(\.members).sorted(), box: units.map(\.box).reduce(CGRect.null) { $0.union($1) }, shape: .rigid)
        u.core = units.map { $0.core.isNull ? $0.box : $0.core }.reduce(CGRect.null) { $0.union($1) }
        u.picture = units.contains(where: \.picture)
        u.prominent = units.contains(where: \.prominent)
        u.drawing = units.allSatisfy(\.drawing)
        u.signature = units.flatMap(\.signature)
        u.bleed = Insets(top: units.map(\.bleed.top).max() ?? 0, left: units.map(\.bleed.left).max() ?? 0,
                         bottom: units.map(\.bleed.bottom).max() ?? 0, right: units.map(\.bleed.right).max() ?? 0)
        return u
    }

    /// Which gaps are room to breathe: clearly wider than the narrowest, and a fair share of the
    /// length. One gap alone is loose when it is a fifth of the length.
    private static func looseness(_ gaps: [CGFloat], length: CGFloat) -> [Bool] {
        guard let least = gaps.min() else { return [] }
        if gaps.count == 1 { return [gaps[0] >= length * 0.2] }
        let tight = max(least * 1.8, length * 0.12)
        return gaps.map { $0 > tight }
    }

    private static func isAlike(_ children: [Piece]) -> Bool {
        guard children.count >= 3 else { return false }
        let units = children.compactMap { p -> Unit? in if case .unit(let u) = p { return u }; return nil }
        guard units.count == children.count, let first = units.first else { return false }
        return units.allSatisfy { u in
            u.signature == first.signature && abs(u.box.width - first.box.width) <= first.box.width * 0.12
                && abs(u.box.height - first.box.height) <= first.box.height * 0.12
        }
    }

    private static func alikePath(in piece: Piece, path: [Int]) -> [Int]? {
        guard case .stack(let s) = piece else { return nil }
        if s.alike { return path }
        for (i, c) in s.children.enumerated() {
            if let p = alikePath(in: c, path: path + [i]) { return p }
        }
        return nil
    }

    /// Where a box lies across `parent` along `axis`.
    private static func place(_ child: CGRect, in parent: CGRect, along axis: Axis, stretches: Bool) -> Place {
        let b = lo(child, axis) - lo(parent, axis), a = hi(parent, axis) - hi(child, axis)
        let l = length(parent, axis)
        let tol = max(2, l * 0.02)
        let anchor: Anchor
        if stretches && max(b, a) <= max(tol, l * 0.15) { anchor = .span }
        // Nearly from side to side, it keeps to the side it starts from: on a wider page, the
        // room it gains is not shared out round it.
        else if max(b, a) <= max(tol, l * 0.15) && abs(b - a) > tol { anchor = .start }
        else if abs(b - a) <= tol { anchor = .center }
        else if b <= a * 0.5 { anchor = .start }
        else if a <= b * 0.5 { anchor = .end }
        else { anchor = .share(b / max(b + a, 0.001)) }
        return Place(anchor: anchor, before: b, after: a)
    }

    /// Whether a piece can take another length along `axis` than its own.
    private static func stretches(_ p: Piece, _ axis: Axis) -> Bool {
        switch p {
        case .unit(let u):
            switch u.shape {
            case .rigid: return false
            case .stretchy:
                // A line runs only along its length.
                if u.box.height <= 0.5 { return axis == .x }
                if u.box.width <= 0.5 { return axis == .y }
                return true
            case .text: return axis == .x
            case .holder, .group: return true
            }
        case .stack(let s):
            if s.axis == axis { return s.loose.contains(true) || s.children.contains { stretches($0, axis) } }
            return s.children.indices.contains { s.places[$0].anchor == .span && stretches(s.children[$0], axis) }
        }
    }

    // MARK: - Laying out

    /// The design laid out at `size`. `current` is the arrangement it was in a moment ago, which it
    /// keeps unless another suits the size clearly better, so that a drag back and forth does not
    /// flicker between two.
    static func compose(_ plan: Plan, to size: CGSize, keeping current: Arrangement? = nil) -> Result {
        let size = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        var board = plan.board
        let old = board.frame.size
        board.frame.size = size
        guard size != old, old.width > 0, old.height > 0 else {
            var r = Result(board: plan.board, arrangement: .original, skeleton: Skeleton(), scale: 1)
            r.skeleton = laidOut(plan, flow: plan.root.flow, k: 1, size: old).skeleton
            return r
        }
        let wanted = preferredScale(from: old, to: size, mode: plan.mode)
        var options = Self.options(plan, to: size, keeping: current)
        if options.isEmpty { options.append((.original, plan.root.flow, wanted, 0)) }
        let best = options.max { $0.3 < $1.3 }!
        var k = best.2
        var laid = laidOut(plan, flow: best.1, k: k, size: size)
        // Words wrapped to a narrower width take more lines than reckoned: then smaller still.
        for _ in 0..<10 {
            guard let over = laid.overflow(in: size), k > 0.021 else { break }
            k = max(0.02, k * min(over, 0.99))
            laid = laidOut(plan, flow: best.1, k: k, size: size)
        }
        var children = plan.board.children
        for (i, n) in zip(plan.indices, laid.nodes) { children[i] = n }
        board.children = children
        return Result(board: board, arrangement: best.0, skeleton: laid.skeleton, scale: k)
    }

    /// Each way the design could be arranged at `size`, with how big it can be in it and how well it suits.
    static func options(_ plan: Plan, to size: CGSize, keeping current: Arrangement? = nil) -> [(Arrangement, Stack?, CGFloat, Double)] {
        let wanted = preferredScale(from: plan.board.frame.size, to: size, mode: plan.mode)
        var options: [(Arrangement, Stack?, CGFloat, Double)] = []
        let narrower = size.width / max(plan.board.frame.width, 1)
        for a in arrangements(of: plan) {
            guard var flow = arranged(plan, a) else { continue }
            if plan.mode == .interface, narrower < 1 { flow = narrowed(flow, by: sqrt(narrower)) }
            let k = fit(flow, frame: plan.root.box, into: size, wanted: wanted, mode: plan.mode)
            var sc = score(a, k: k, wanted: wanted, current: current, mode: plan.mode)
            // A last row of fewer than half its cells looks left behind.
            if let c = a.columns, let path = plan.wrapPath, let root = plan.root.flow, case .stack(let w)? = piece(at: path, in: .stack(root)),
               w.children.count % c != 0, Double(w.children.count % c) < Double(c) / 2 + 0.01 { sc -= 0.03 }
            options.append((a, flow, k, sc))
        }
        return options
    }

    /// The design's stack with its side margins narrowed by `f`, as a screen's are on a narrower one.
    private static func narrowed(_ s: Stack, by f: CGFloat) -> Stack {
        var out = s
        if s.axis == .y {
            out.places = s.places.map { p in Place(anchor: p.anchor, before: p.before * f, after: p.after * f) }
        } else {
            out.ends = (s.ends.0 * f, s.ends.1 * f)
        }
        return out
    }

    /// How much the design would grow to suit the new size: a composition keeps the share of the
    /// page it covers; an interface keeps its type the size it reads at.
    private static func preferredScale(from old: CGSize, to new: CGSize, mode: Mode) -> CGFloat {
        let sx = new.width / old.width, sy = new.height / old.height
        switch mode {
        case .composition: return sqrt(sx * sy)
        case .interface: return 1
        }
    }

    private static func arrangements(of plan: Plan) -> [Arrangement] {
        guard let flow = plan.root.flow else { return [.original] }
        var columns: [Int?] = [nil]
        if let path = plan.wrapPath, case .stack(let s)? = piece(at: path, in: .stack(flow)) {
            let n = s.children.count
            for c in 1...n where !(s.axis == .x && c == n) && !(s.axis == .y && c == 1) { columns.append(c) }
        }
        var all: [Arrangement] = []
        for c in columns {
            all.append(Arrangement(turned: nil, columns: c))
            for t in plan.turnPaths where t != plan.wrapPath { all.append(Arrangement(turned: t, columns: c)) }
        }
        return all
    }

    /// How well an arrangement suits: as big as wanted is best; the design as it was made is
    /// preferred, and the one it is in now, so that it changes only for something clearly better.
    private static func score(_ a: Arrangement, k: CGFloat, wanted: CGFloat, current: Arrangement?, mode: Mode) -> Double {
        let reached = Double(min(k / max(wanted, 0.0001), 1))
        var s: Double
        switch mode {
        case .composition:
            s = reached
            if a.turned != nil { s -= 0.07 }
            if a.columns != nil { s -= 0.05 }
        case .interface:
            // Type that stays the size it reads at matters most on a screen; arranging the screen
            // again is what screens of other sizes do anyway.
            s = reached * reached
            if a.turned != nil { s -= 0.03 }
            if a.columns != nil { s -= 0.03 }
        }
        if a == (current ?? .original) { s += 0.04 }
        return s
    }

    private static func piece(at path: [Int], in p: Piece) -> Piece? {
        guard let first = path.first else { return p }
        guard case .stack(let s) = p, s.children.indices.contains(first) else { return nil }
        return piece(at: Array(path.dropFirst()), in: s.children[first])
    }

    /// The design's stack, arranged another way.
    private static func arranged(_ plan: Plan, _ a: Arrangement) -> Stack? {
        guard var flow = plan.root.flow else { return nil }
        if let c = a.columns, let path = plan.wrapPath {
            guard let wrapped = replacing(flow, at: path, { wrap($0, columns: c, isRoot: $1) }) else { return nil }
            flow = wrapped
        }
        if let path = a.turned {
            let frame = plan.root.box
            guard let t = replacing(flow, at: path, { turned($0, frame: frame, isRoot: $1) }) else { return nil }
            flow = t
        }
        return flow
    }

    /// Alike blocks in rows of `columns`.
    private static func wrap(_ s: Stack, columns c: Int, isRoot: Bool) -> Stack? {
        let n = s.children.count
        let gap = s.gaps.isEmpty ? 0 : s.gaps.reduce(0, +) / CGFloat(s.gaps.count)
        let cell = s.children[0].box.size
        var rows: [Piece] = []
        var start = 0
        while start < n {
            let items = Array(s.children[start..<min(start + c, n)])
            if items.count == 1 {
                rows.append(items[0])
            } else {
                let box = CGRect(x: 0, y: 0, width: CGFloat(items.count) * cell.width + CGFloat(items.count - 1) * gap, height: cell.height)
                rows.append(.stack(Stack(axis: .x, children: items, gaps: Array(repeating: gap, count: items.count - 1),
                                         loose: Array(repeating: false, count: items.count - 1),
                                         places: Array(repeating: Place(anchor: .start, before: 0, after: 0), count: items.count), box: box)))
            }
            start += c
        }
        let width = CGFloat(min(c, n)) * cell.width + CGFloat(min(c, n) - 1) * gap
        let height = CGFloat(rows.count) * cell.height + CGFloat(rows.count - 1) * gap
        // Cells that can widen fill their row, as cards do on a narrower screen.
        let widen = stretches(s.children[0], .x)
        var out = Stack(axis: .y, children: rows, gaps: Array(repeating: gap, count: rows.count - 1),
                        loose: Array(repeating: false, count: rows.count - 1),
                        places: rows.map { widen ? Place(anchor: .span, before: 0, after: 0) : Place(anchor: .start, before: 0, after: max(0, width - $0.box.width)) },
                        box: CGRect(x: s.box.minX, y: s.box.minY, width: width, height: height))
        if isRoot {
            // The grid lies in the artboard where the row did, as far in from its sides.
            let p = s.places.first ?? Place(anchor: .center, before: 0, after: 0)
            out.places = rows.map { _ in Place(anchor: widen ? .span : .center, before: p.before, after: p.after) }
            out.ends = s.axis == .y ? s.ends : (s.places.map(\.before).min() ?? 0, s.places.map(\.after).min() ?? 0)
        }
        return out
    }

    /// The design's two parts side by side where they were one under the other, or the other way:
    /// its picture, or the largest block at either end, beside or above the rest. The design's own
    /// stack keeps its margins from the artboard's edges; one inside it keeps to the room it has.
    private static func turned(_ s: Stack, frame: CGRect, isRoot: Bool) -> Stack? {
        guard s.children.count >= 2 else { return nil }
        let main = s.axis, cross = main.other
        let last = s.children.count - 1
        let ends = [0, last].filter { visual(s.children[$0]) }
        guard let li = ends.max(by: { s.children[$0].box.area < s.children[$1].box.area }) ?? (s.children.count == 2 ? 0 : nil) else { return nil }
        let leadFirst = li == 0
        var lead = s.children[li]
        let rest = s.children.indices.filter { $0 != li }
        let flushStart = isRoot && (leadFirst ? s.ends.0 <= 2 : s.ends.1 <= 2)
        let isPanel: Bool = { if case .unit(let u) = lead { return u.share != nil }; return false }()
        // The side margin the rest keeps from the artboard's edges.
        // Room beside a centred block is not a margin: none is wider than a twelfth of the page.
        let sides = rest.flatMap { [s.places[$0].before, s.places[$0].after] }.filter { $0 > 2 }
        let page = min(frame.width, frame.height)
        let margin = isRoot ? min(sides.min() ?? max(s.ends.0, s.ends.1), page * 0.08) : 0
        // What lay across the whole design keeps to its column the same way, as far in as the margin.
        func kept(_ p: Place) -> Place {
            guard isRoot else { return p }
            let anchor: Anchor = if case .share = p.anchor { .center } else { p.anchor }
            return Place(anchor: anchor, before: min(p.before, margin), after: min(p.after, margin))
        }
        // Between the lead and the rest, as there was.
        // Laid side by side the other way, what overlapped no longer does.
        let overlapping = s.gaps.isEmpty ? margin : (leadFirst ? s.gaps[0] : s.gaps[s.gaps.count - 1])
        let between = overlapping < 0 ? (isRoot ? margin : 0) : overlapping
        if case .unit(var u) = lead, u.share != nil {
            // A panel takes as much of the artboard the new way as it took the old way.
            u.share = length(u.box, main) / max(length(frame, main), 1)
            lead = .unit(u)
        }
        // Across the new way, the lead runs from side to side where it can.
        let spans = isPanel || !isRoot && stretches(lead, main)
        let leadAcross = spans ? Place(anchor: .span, before: 0, after: 0)
                               : Place(anchor: .center, before: isRoot ? margin : 0, after: isRoot ? margin : 0)

        var out: Stack
        if main == .y {
            // Above the rest, it goes beside it.
            let restPiece: Piece
            if rest.count == 1 {
                restPiece = s.children[rest[0]]
            } else {
                let kids = rest.map { s.children[$0] }
                let box = kids.map(\.box).reduce(CGRect.null) { $0.union($1) }
                restPiece = .stack(Stack(axis: .y, children: kids, gaps: rest.dropLast().map { s.gaps[$0] },
                                         loose: rest.dropLast().map { s.loose[$0] }, places: rest.map { kept(s.places[$0]) }, box: box))
            }
            let restAcross = Place(anchor: .center, before: margin, after: margin)
            let kids = leadFirst ? [lead, restPiece] : [restPiece, lead]
            let places = leadFirst ? [leadAcross, restAcross] : [restAcross, leadAcross]
            let leadEnd: CGFloat = flushStart || !isRoot ? 0 : margin
            // The rest carries its own side margins; a single block keeps its margin round it.
            let gap: CGFloat = isRoot ? (rest.count == 1 && !isPanel ? margin : 0) : between
            out = Stack(axis: .x, children: kids, gaps: [gap], loose: [false], places: places,
                        box: s.box, ends: leadFirst ? (leadEnd, 0) : (0, leadEnd))
            if isRoot, rest.count == 1 { out.ends = leadFirst ? (leadEnd, margin) : (margin, leadEnd) }
            // A design centred on the page stays centred, its two parts side by side in the middle.
            let centred = rest.filter { s.places[$0].anchor == .center }.count * 2 > rest.count
            if isRoot, centred, !isPanel {
                out.gaps = [margin]
                out.ends = (margin, margin)
                if case .stack(var column) = restPiece {
                    column.places = column.places.map { Place(anchor: $0.anchor, before: 0, after: 0) }
                    out.children[leadFirst ? 1 : 0] = .stack(column)
                }
            }
        } else {
            // Beside the rest, it goes above it; or under it, when it stands on the foot of the
            // page, as someone cut off by its edge does.
            let tol = max(2, frame.height * 0.01)
            let standing = isRoot && abs(hi(lead.box, .y) - hi(frame, .y)) <= tol && abs(lo(lead.box, .y) - lo(frame, .y)) > tol
            let leadFirst = standing ? false : leadFirst
            var restKids: [(Piece, Place)] = []
            var restGaps: [CGFloat] = [], restLoose: [Bool] = []
            for r in rest {
                if case .stack(let column) = s.children[r], column.axis == .y {
                    if !restKids.isEmpty { restGaps.append(between); restLoose.append(false) }
                    for (c, p) in zip(column.children, column.places) {
                        restKids.append((c, Place(anchor: p.anchor, before: p.before + margin, after: p.after + margin)))
                    }
                    restGaps += column.gaps
                    restLoose += column.loose
                } else {
                    if !restKids.isEmpty { restGaps.append(between); restLoose.append(false) }
                    let p = isRoot ? Place(anchor: .center, before: margin, after: margin) : Place(anchor: .start, before: 0, after: 0)
                    restKids.append((s.children[r], p))
                }
            }
            let kids = leadFirst ? [lead] + restKids.map(\.0) : restKids.map(\.0) + [lead]
            let places = leadFirst ? [leadAcross] + restKids.map(\.1) : restKids.map(\.1) + [leadAcross]
            let gaps = leadFirst ? [between] + restGaps : restGaps + [between]
            let loose = leadFirst ? [false] + restLoose : restLoose + [false]
            guard gaps.count == kids.count - 1, loose.count == gaps.count else { return nil }
            let leadEnd: CGFloat = flushStart || standing || !isRoot ? 0 : margin
            let restEnd: CGFloat = isRoot ? margin : 0
            out = Stack(axis: .y, children: kids, gaps: gaps, loose: loose, places: places, box: s.box,
                        ends: leadFirst ? (leadEnd, restEnd) : (restEnd, leadEnd))
        }
        // The box it would have, laid out as it now is at the size the design was made at.
        let along = out.children.map { length($0.box, out.axis) }.reduce(0, +) + out.gaps.reduce(0, +)
        let thick = out.children.map { length($0.box, out.axis.other) }.max() ?? 0
        out.box = out.axis == .x ? CGRect(x: s.box.minX, y: s.box.minY, width: along, height: thick)
                                 : CGRect(x: s.box.minX, y: s.box.minY, width: thick, height: along)
        _ = cross
        return out
    }

    /// Whether a block is what the eye goes to: a picture, a shape holding others, a panel.
    private static func visual(_ p: Piece) -> Bool {
        guard case .unit(let u) = p else { return false }
        return (u.picture || u.drawing) && u.prominent || u.isHolder || u.share != nil
    }

    /// The stack at `path` arranged anew by `change`.
    private static func replacing(_ s: Stack, at path: [Int], _ change: (Stack, Bool) -> Stack?, isRoot: Bool = true) -> Stack? {
        guard let first = path.first else { return change(s, isRoot) }
        guard s.children.indices.contains(first), case .stack(let inner) = s.children[first],
              let w = replacing(inner, at: Array(path.dropFirst()), change, isRoot: false) else { return nil }
        var out = s
        out.children[first] = .stack(w)
        // What overlapped the stack, over the empty part of a cut-out in it, may not overlap what
        // now lies first in it: arranged anew, it keeps clear.
        let clear = s.gaps.filter { $0 > 0 }.min() ?? 0
        if first > 0, out.gaps[first - 1] < 0 { out.gaps[first - 1] = clear }
        if first < out.gaps.count, out.gaps[first] < 0 { out.gaps[first] = clear }
        return out
    }

    // MARK: Measuring

    /// How long a piece would like to be along `axis` at scale `k`, and how short it can be.
    private static func length(of p: Piece, _ axis: Axis, k: CGFloat, frame: CGSize, parentMain: Axis?) -> (pref: CGFloat, min: CGFloat) {
        switch p {
        case .unit(let u):
            if let share = u.share, axis == parentMain {
                let pref = share * (axis == .x ? frame.width : frame.height)
                return (pref, pref * 0.75)
            }
            let base = length(u.box, axis) * k
            switch u.shape {
            case .rigid:
                if let words = u.words {
                    let s = words.size(k)
                    let l = axis == .x ? s.width : s.height
                    return (l, l)
                }
                return (base, base)
            case .text: return axis == .x ? (base, base * 0.6) : (base, base)
            case .stretchy: return (base, u.picture ? base * 0.7 : base * 0.5)
            case .holder, .group: return (base, base * 0.85)
            }
        case .stack(let s):
            if s.axis == axis {
                var pref: CGFloat = 0, least: CGFloat = 0
                for c in s.children {
                    let m = length(of: c, axis, k: k, frame: frame, parentMain: axis)
                    pref += m.pref
                    least += m.min
                }
                for (g, loose) in zip(s.gaps, s.loose) {
                    pref += g * k
                    least += loose ? g * k * 0.35 : g * k
                }
                pref += (s.ends.0 + s.ends.1) * k
                least += (s.ends.0 + s.ends.1) * k * 0.6
                return (pref, least)
            }
            var pref: CGFloat = 0, least: CGFloat = 0
            for (c, place) in zip(s.children, s.places) {
                let m = length(of: c, axis, k: k, frame: frame, parentMain: s.axis)
                let (fb, fa) = fixed(place)
                pref = max(pref, m.pref + (place.before + place.after) * k)
                least = max(least, m.min + (fb + fa) * k * 0.6)
            }
            return (pref, least)
        }
    }

    /// What of the room on either side of a block across its stack is a margin to keep, rather
    /// than space left over.
    private static func fixed(_ p: Place) -> (CGFloat, CGFloat) {
        switch p.anchor {
        case .start: (p.before, 0)
        case .end: (0, p.after)
        case .span: (p.before, p.after)
        case .center, .share: (min(p.before, p.after), min(p.before, p.after))
        }
    }

    /// The largest scale up to `wanted` at which the design still fits the new size, with its
    /// loose gaps and margins giving up as much as half of what they can.
    private static func fit(_ flow: Stack?, frame: CGRect, into size: CGSize, wanted: CGFloat, mode: Mode) -> CGFloat {
        guard let flow else { return wanted }
        func fits(_ k: CGFloat) -> Bool {
            let p = Piece.stack(flow)
            let main = length(of: p, flow.axis, k: k, frame: size, parentMain: nil)
            let across = length(of: p, flow.axis.other, k: k, frame: size, parentMain: nil)
            let snugMain = (main.pref + main.min) / 2, snugAcross = (across.pref + across.min) / 2
            return snugMain <= length(size, flow.axis) + 0.5 && snugAcross <= length(size, flow.axis.other) + 0.5
        }
        if fits(wanted) { return wanted }
        var lo: CGFloat = 0.02, hi = wanted
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: Placing

    /// Where a layer goes.
    enum Placement {
        /// Grown or shrunk by `k` as a whole, the top left of what it covers at `origin`.
        case rigid(origin: CGPoint, k: CGFloat)
        /// Taking the box `rect`, its corners, borders and shadows grown by `k`.
        case box(CGRect, k: CGFloat)
        /// A group taking `rect`, with its layers laid out again in it.
        case group(CGRect, children: [Node], k: CGFloat)
        /// Stretched to `rect`, what it holds with it, as a band running across is.
        case band(CGRect, k: CGFloat)
    }

    /// Layers laid out, with what was understood of them.
    struct Laid {
        var nodes: [Node]
        var skeleton: Skeleton
        /// What the blocks cover, together.
        var used: CGRect

        /// How much smaller it would have to be to fit `size`, where it does not.
        func overflow(in size: CGSize) -> CGFloat? {
            guard !used.isNull, used.width > 0, used.height > 0 else { return nil }
            // How far it reaches, past either side, margins and all.
            let reachX = max(used.maxX, size.width) - min(used.minX, 0), reachY = max(used.maxY, size.height) - min(used.minY, 0)
            let sx = reachX > size.width + 0.5 ? size.width / reachX : 1
            let sy = reachY > size.height + 0.5 ? size.height / reachY : 1
            let s = min(sx, sy)
            return s < 1 ? s : nil
        }
    }

    /// How tall words are at a width, worked out once for each layout.
    private final class Measures {
        private var heights: [String: CGFloat] = [:]

        func text(_ i: Int, width: CGFloat, k: CGFloat, _ measure: () -> CGFloat) -> CGFloat {
            let key = "\(i) \((width * 2).rounded()) \((k * 1000).rounded())"
            if let h = heights[key] { return h }
            let h = measure()
            heights[key] = h
            return h
        }
    }

    private struct Context {
        let layers: Layers
        let mode: Mode
        let frame: CGSize
        let focus: [String: CGPoint]
        var cache = Measures()
        var placements: [Int: Placement] = [:]
        var skeleton = Skeleton()
        var used = CGRect.null
        /// The layers of blocks that keep inside their frame, to see where they came to lie.
        var inside: [Int] = []
        var record = true
    }

    private static func laidOut(_ plan: Plan, flow: Stack?, k: CGFloat, size: CGSize) -> Laid {
        var root = plan.root
        root.flow = flow
        var ctx = Context(layers: plan.layers, mode: plan.mode, frame: size, focus: plan.focus)
        lay(root, into: CGRect(origin: .zero, size: size), k: k, ctx: &ctx, isRoot: true)
        let nodes = apply(ctx.placements, to: plan.layers, focus: plan.focus)
        // Where they came to lie, words measured and all.
        var used = ctx.used
        // A cut-out by what it shows, which its block already is; its empty edges may run past the page.
        for i in ctx.inside where nodes.indices.contains(i) && !nodes[i].hidden && !plan.layers.cutouts.contains(i) {
            used = used.union(Geometry.bounds(of: nodes[i]))
        }
        return Laid(nodes: nodes, skeleton: ctx.skeleton, used: used)
    }

    /// Lays out what lies in a frame, which now takes `rect`.
    private static func lay(_ f: Frame, into rect: CGRect, k: CGFloat, ctx: inout Context, isRoot: Bool) {
        let old = f.box
        for i in f.backdrops {
            let b = ctx.layers.boxes[i]
            let target = CGRect(x: rect.minX + (b.minX - old.minX) * k, y: rect.minY + (b.minY - old.minY) * k,
                                width: 0, height: 0)
            let right = rect.maxX - (old.maxX - b.maxX) * k, bottom = rect.maxY - (old.maxY - b.maxY) * k
            let cover = CGRect(x: target.minX, y: target.minY, width: max(1, right - target.minX), height: max(1, bottom - target.minY))
            if case .stretchy = shape(of: ctx.layers.nodes[i], depth: 9) {
                ctx.placements[i] = .box(cover, k: k)
            } else if case .group = ctx.layers.nodes[i].kind, ctx.layers.nodes[i].rotation == 0, ctx.layers.nodes[i].transform3D == nil,
                      case .group(let inner, let frame) = shape(of: ctx.layers.nodes[i], depth: 0) {
                ctx.placements[i] = .group(cover, children: composed(frame, layers: inner, into: cover.size, k: k, ctx: ctx), k: k)
            } else {
                // What cannot stretch grows until it covers as it did, about its middle.
                let kc = max(cover.width / max(b.width, 1), cover.height / max(b.height, 1))
                ctx.placements[i] = .rigid(origin: CGPoint(x: cover.midX - b.width * kc / 2, y: cover.midY - b.height * kc / 2), k: kc)
            }
        }
        for (i, axis, far) in f.bands {
            let b = ctx.layers.boxes[i]
            // Across: as far past each side as it was. Along: a ground without words takes as much
            // of the page as it took, so a page split in two stays split where it was; one with
            // words in it is as thick as the design grows, so they do not stretch.
            func wordless(_ n: Node) -> Bool { n.kind != .text && n.children.allSatisfy(wordless) }
            // A screen's bars keep the height they read at.
            let share = ctx.mode == .composition && wordless(ctx.layers.nodes[i])
            let r: CGRect
            if axis == .x {
                let x0 = rect.minX + (b.minX - old.minX) * k, x1 = rect.maxX + (b.maxX - old.maxX) * k
                let h = share ? b.height / max(old.height, 1) * rect.height : b.height * k
                let y = far ? rect.maxY + (b.maxY - old.maxY) * k - h : rect.minY + (b.minY - old.minY) * k
                r = CGRect(x: x0, y: y, width: max(1, x1 - x0), height: h)
            } else {
                let y0 = rect.minY + (b.minY - old.minY) * k, y1 = rect.maxY + (b.maxY - old.maxY) * k
                let w = share ? b.width / max(old.width, 1) * rect.width : b.width * k
                let x = far ? rect.maxX + (b.maxX - old.maxX) * k - w : rect.minX + (b.minX - old.minX) * k
                r = CGRect(x: x, y: y0, width: w, height: max(1, y1 - y0))
            }

            let n = ctx.layers.nodes[i]
            if n.isRepeatGrid || n.clipsToFirst == true || n.mask != nil {
                // What must keep its shape grows to run across, from its edge.
                let kc = axis == .x ? r.width / max(b.width, 1) : r.height / max(b.height, 1)
                ctx.placements[i] = .rigid(origin: CGPoint(x: axis == .x ? r.minX : (far ? r.maxX - b.width * kc : r.minX),
                                                           y: axis == .x ? (far ? r.maxY - b.height * kc : r.minY) : r.minY), k: kc)
            } else {
                ctx.placements[i] = .band(r, k: k)
            }
        }
        for (i, px, py) in f.loose {
            let b = ctx.layers.boxes[i]
            let x = position(px, size: b.width * k, from: rect.minX, length: rect.width, k: k)
            let y = position(py, size: b.height * k, from: rect.minY, length: rect.height, k: k)
            ctx.placements[i] = .rigid(origin: CGPoint(x: x, y: y), k: k)
        }
        if let flow = f.flow {
            lay(flow, into: rect, k: k, ctx: &ctx, isRoot: true, rootOfFrame: true, topLevel: isRoot)
        }
    }

    private static func position(_ p: Place, size: CGFloat, from start: CGFloat, length l: CGFloat, k: CGFloat) -> CGFloat {
        switch p.anchor {
        case .start: return start + p.before * k
        case .end: return start + l - p.after * k - size
        case .center, .span: return start + (l - size) / 2 + (p.before - p.after) / 2 * k
        case .share(let f): return start + f * (l - size)
        }
    }

    /// Where a stack's blocks go in `rect`: along it, the room before each and how long each is;
    /// across it, where each lies and how long. Down a column, each block's width is settled
    /// first, which settles how tall words wrapped to it are; along a row, each block's width is
    /// shared out first, and how tall it is follows.
    private struct Arranged {
        var spans: [(CGFloat, CGFloat)] = []
        var across: [(CGFloat, CGFloat)] = []
        /// What everything along the stack would like to take, together.
        var wanted: CGFloat = 0
        var grows = (CGFloat(0), CGFloat(0))
        var spacer: Int?
    }

    private static func arrange(_ s: Stack, in rect: CGRect, k: CGFloat, ctx: Context, rootOfFrame: Bool, topLevel: Bool,
                                measuring: Bool = false) -> Arranged {
        let main = s.axis, cross = main.other
        let frame = ctx.frame
        let room = length(rect, cross)
        var out = Arranged()

        // Across: where a block lies and how long it is, its length along the stack known for a row.
        func across(_ i: Int, along: CGFloat?) -> (CGFloat, CGFloat) {
            let c = s.children[i], given = s.places[i]
            var m = length(of: c, cross, k: k, frame: frame, parentMain: main)
            if cross == .y, let along {
                let h = natural(c, width: along, k: k, ctx: ctx, parentMain: main)
                m = (h, max(m.min, h))
            }
            if given.anchor == .span, stretches(c, cross) {
                var size = max(m.min, room - (given.before + given.after) * k)
                // On a page, lines of words grow only so long: a column keeps a length that reads
                // well, and keeps to the side it starts from.
                if ctx.mode == .composition, cross == .x, case .unit(let u) = c, u.reads { size = min(size, max(m.min, m.pref * 1.25)) }
                return (lo(rect, cross) + given.before * k, size)
            }
            // What ran from side to side but cannot stretch keeps to the side it starts from, as
            // the blocks that do stretch beside it do.
            let place = given.anchor == .span ? Place(anchor: .start, before: given.before, after: given.after) : given
            let (fb, fa) = fixed(place)
            let free = room - (fb + fa) * k
            let size = cross == .x && stretches(c, cross) ? min(m.pref, max(m.min, free)) : m.pref
            var at = position(place, size: size, from: lo(rect, cross), length: room, k: k)
            // Kept inside, where it can be.
            if size <= room {
                at = min(max(at, lo(rect, cross) + min(fb * k, room - size)), hi(rect, cross) - size - min(fa * k, max(0, room - size - fb * k)))
            }
            return (at, size)
        }
        if main == .y { out.across = s.children.indices.map { across($0, along: nil) } }

        // Along: each block as long as it would like, given how wide it now is.
        var items: [(pref: CGFloat, min: CGFloat, grow: CGFloat)] = []
        let interface = ctx.mode == .interface && main == .y && topLevel
        let anyLoose = s.loose.contains(true)
        let (e0, e1) = s.ends
        var grows0: CGFloat = 0, grows1: CGFloat = 0
        // A row running from side to side, with nothing loose in it, grows what can grow in it, as
        // a card's words take the room a wider card gives them.
        let whole = e0 + e1 + length(s.box, main)
        let rowSpans = main == .x && !anyLoose && max(e0, e1) <= whole * 0.15
        func grower(_ c: Piece, pictures: Bool) -> CGFloat {
            guard rowSpans, stretches(c, main) else { return 0 }
            if case .unit(let u) = c {
                if u.share != nil { return 0 }
                if case .stretchy = u.shape, u.picture, !pictures { return 0 }
                // A button, a shape holding one label, stays the size it is; a card, holding more,
                // or a panel takes the room.
                if u.isHolder, u.members.count <= 2, length(u.box, main) < whole * 0.4 { return 0 }
            }
            return length(c.box, main)
        }
        // Words and what holds them take the room first; a picture only where nothing else can.
        var growing = s.children.map { grower($0, pictures: false) }
        if !growing.contains(where: { $0 > 0 }) { growing = s.children.map { grower($0, pictures: true) } }
        let rowGrows = growing.contains { $0 > 0 }
        // An interface gains room above what keeps to its foot, as a tab bar does, or else below it all.
        if interface {
            if rootOfFrame, s.children.count > 1, footing(s, s.children.count - 1) { out.spacer = s.children.count - 2 } else { grows1 = 1 }
        } else if !anyLoose && !rowGrows {
            // The room before and after, as margins: a block standing on its own keeps to the side
            // it lies near, or to where it lies between the two.
            if e0 <= e1 * 0.5 { grows1 = 1 } else if e1 <= e0 * 0.5 { grows0 = 1 } else { grows0 = e0; grows1 = e1 }
        }
        items.append((e0 * k, e0 * k * 0.6, grows0))
        for (i, c) in s.children.enumerated() {
            var m = length(of: c, main, k: k, frame: frame, parentMain: main)
            if main == .y {
                let h = natural(c, width: out.across[i].1, k: k, ctx: ctx, parentMain: main)
                // Words wrapped to more lines take them all: a row, words and what holds them never
                // get shorter than that; only the gaps between them give.
                if h > m.pref + 0.5 { m = (h, m.min + h - m.pref) } else if h < m.pref - 0.5 { m = (h, min(m.min, h)) }
                switch c {
                case .stack(let st) where st.axis == .x: m.min = m.pref
                case .unit(let u):
                    switch u.shape {
                    case .text, .holder, .rigid: m.min = m.pref
                    default: break
                    }
                default: break
                }
            }
            items.append((m.pref, m.min, growing[i]))
            if i < s.gaps.count {
                let g = s.gaps[i], loose = s.loose[i]
                let w: CGFloat = interface ? (out.spacer == i ? 1 : 0) : (loose ? g : 0)
                items.append((g * k, loose || out.spacer == i ? g * k * 0.35 : g * k, w))
            }
        }
        items.append((e1 * k, e1 * k * 0.6, grows1))
        // Nothing to grow at all: the widest gaps take the room, as the design's breathing room.
        if items.allSatisfy({ $0.grow == 0 }), !s.gaps.isEmpty, rootOfFrame, e0 + e1 <= 0.5, let widest = s.gaps.max(), widest > 0 {
            for (i, g) in s.gaps.enumerated() where g >= widest * 0.8 { items[2 + i * 2].grow = g }
        }
        out.wanted = items.reduce(0) { $0 + $1.pref }
        out.grows = (items.first?.grow ?? 0, items.last?.grow ?? 0)
        // Measured, a column takes what it would like; a row still shares out the width it has.
        // Words to be read on a page grow only so long along a row.
        var longest: [CGFloat?] = Array(repeating: nil, count: items.count)
        if ctx.mode == .composition, main == .x {
            for (i, c) in s.children.enumerated() {
                if case .unit(let u) = c, u.reads { longest[1 + i * 2] = items[1 + i * 2].pref * 1.25 }
            }
        }
        let sizes = measuring && main == .y ? items.map(\.pref) : flex(items, into: length(rect, main), longest: longest)
        var cursor = lo(rect, main)
        for (j, size) in sizes.enumerated() {
            if j % 2 == 1 { out.spans.append((cursor, size)) }
            cursor += size
        }
        // Left over, when nothing grew: the stack keeps to its side of the room.
        let left = length(rect, main) - sizes.reduce(0, +)
        if left > 0.5, !measuring {
            let shift = left * (e0 + e1 > 0 ? e0 / (e0 + e1) : 0)
            out.spans = out.spans.map { ($0.0 + shift, $0.1) }
        }
        if main == .x { out.across = s.children.indices.map { across($0, along: out.spans[$0].1) } }
        return out
    }

    /// How tall a block is once it is `width` wide: words wrapped to it, what a shape holds laid
    /// out in it, a row's tallest block, a column's blocks and gaps together.
    private static func natural(_ p: Piece, width: CGFloat, k: CGFloat, ctx: Context, parentMain: Axis) -> CGFloat {
        let pref = length(of: p, .y, k: k, frame: ctx.frame, parentMain: parentMain).pref
        switch p {
        case .unit(let u):
            // Measured always: the system's type changes its cut with its size, so words wrap
            // a little differently at every scale, whatever the width.
            switch u.shape {
            case .text: return ctx.cache.text(u.members[0], width: width, k: k) { textHeight(ctx.layers.nodes[u.members[0]], width: width, k: k) }
            case .holder(_, let inner): return max(pref, innerHeight(inner, width: width, k: k, ctx: ctx))
            default: return pref
            }
        case .stack(let st):
            let a = arrange(st, in: CGRect(x: 0, y: 0, width: width, height: pref), k: k, ctx: ctx, rootOfFrame: false, topLevel: false, measuring: true)
            if st.axis == .y { return a.wanted }
            // A row is as tall as its tallest block with the margins it keeps, and its padding.
            var tall: CGFloat = 0, highest: CGFloat = 0
            for ((_, size), place) in zip(a.across, st.places) {
                let (fb, fa) = fixed(place)
                tall = max(tall, size + (place.anchor == .span ? place.before + place.after : fb + fa) * k)
                highest = max(highest, size)
            }
            let padding = ((st.places.map(\.before).min() ?? 0) + (st.places.map(\.after).min() ?? 0)) * k
            return max(tall, highest + padding)
        }
    }

    /// Lays out a stack in `rect`.
    private static func lay(_ s: Stack, into rect: CGRect, k: CGFloat, ctx: inout Context, isRoot: Bool, rootOfFrame: Bool, topLevel: Bool) {
        let main = s.axis
        let a = arrange(s, in: rect, k: k, ctx: ctx, rootOfFrame: rootOfFrame, topLevel: topLevel)
        let spans = a.spans
        for (i, c) in s.children.enumerated() {
            let (at, size) = a.across[i]
            let r = main == .x ? CGRect(x: spans[i].0, y: at, width: spans[i].1, height: size)
                               : CGRect(x: at, y: spans[i].0, width: size, height: spans[i].1)
            switch c {
            case .unit(let u): place(u, in: r, k: k, ctx: &ctx)
            case .stack(let inner): lay(inner, into: r, k: k, ctx: &ctx, isRoot: false, rootOfFrame: false, topLevel: false)
            }
        }
        // What was understood, for the canvas to show while the size changes.
        guard ctx.record else { return }
        for i in s.gaps.indices {
            let start = spans[i].0 + spans[i].1, end = spans[i + 1].0
            let (a0, l0) = a.across[i], (a1, l1) = a.across[i + 1]
            let x0 = max(a0, a1), x1 = min(a0 + l0, a1 + l1)
            let (c0, c1) = x1 > x0 ? (x0, x1) : (min(a0, a1), max(a0 + l0, a1 + l1))
            let gap = main == .y ? CGRect(x: c0, y: start, width: c1 - c0, height: max(0, end - start))
                                 : CGRect(x: start, y: c0, width: max(0, end - start), height: c1 - c0)
            if s.loose[i] || a.spacer == i { ctx.skeleton.springs.append((gap, main)) } else { ctx.skeleton.bonds.append((gap, main)) }
        }
        if rootOfFrame && topLevel, let first = spans.first, let last = spans.last {
            let before = main == .y ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first.0 - rect.minY)
                                    : CGRect(x: rect.minX, y: rect.minY, width: first.0 - rect.minX, height: rect.height)
            let end = last.0 + last.1
            let after = main == .y ? CGRect(x: rect.minX, y: end, width: rect.width, height: rect.maxY - end)
                                   : CGRect(x: end, y: rect.minY, width: rect.maxX - end, height: rect.height)
            if a.grows.0 > 0, before.width > 1, before.height > 1 { ctx.skeleton.springs.append((before, main)) }
            if a.grows.1 > 0, after.width > 1, after.height > 1 { ctx.skeleton.springs.append((after, main)) }
        }
    }

    /// Whether a block keeps to the foot of the artboard, as a tab bar does.
    private static func footing(_ s: Stack, _ i: Int) -> Bool {
        guard i == s.children.count - 1 else { return false }
        return s.ends.1 <= 2
    }

    /// Shares out `total` among items: the room over what they would like goes to those that grow,
    /// by how much each does; short of room, each gives up its share of what it can.
    private static func flex(_ items: [(pref: CGFloat, min: CGFloat, grow: CGFloat)], into total: CGFloat, longest: [CGFloat?] = []) -> [CGFloat] {
        let pref = items.reduce(0) { $0 + $1.pref }
        if total >= pref {
            // The room over goes to those that grow, by how much each does, none past its longest;
            // what is left is left over.
            var sizes = items.map(\.pref)
            var growing = Set(items.indices.filter { items[$0].grow > 0 })
            var extra = total - pref
            while extra > 0.01, !growing.isEmpty {
                let grow = growing.reduce(0) { $0 + items[$1].grow }
                var capped = false
                var given: CGFloat = 0
                for i in growing {
                    var add = extra * items[i].grow / grow
                    if let cap = longest[safe: i] ?? nil, sizes[i] + add > cap {
                        add = max(0, cap - sizes[i])
                        growing.remove(i)
                        capped = true
                    }
                    sizes[i] += add
                    given += add
                }
                extra -= given
                if !capped { break }
            }
            return sizes
        }
        let give = items.reduce(0) { $0 + max(0, $1.pref - $1.min) }
        guard give > 0 else { return items.map(\.pref) }
        let t = min(1, (pref - total) / give)
        return items.map { $0.pref - t * max(0, $0.pref - $0.min) }
    }

    /// Places a block in `rect`.
    private static func place(_ u: Unit, in rect: CGRect, k: CGFloat, ctx: inout Context) {
        let bled = CGRect(x: rect.minX - u.bleed.left * k, y: rect.minY - u.bleed.top * k,
                          width: rect.width + (u.bleed.left + u.bleed.right) * k, height: rect.height + (u.bleed.top + u.bleed.bottom) * k)
        ctx.used = ctx.used.union(rect)
        if ctx.record {
            ctx.skeleton.blocks.append(rect)
            if u.bleed == .zero { ctx.inside += u.members }
        }
        let natural = abs(rect.width - u.box.width * k) < 0.5 && abs(rect.height - u.box.height * k) < 0.5
        switch u.shape {
        case .stretchy where !natural, .text where !natural:
            ctx.placements[u.members[0]] = .box(bled, k: k)
        case .holder(let h, let inner) where !natural:
            ctx.placements[h] = .box(bled, k: k)
            var innerCtx = ctx
            innerCtx.record = false
            lay(inner, into: rect, k: k, ctx: &innerCtx, isRoot: false)
            ctx.placements = innerCtx.placements
        case .group(let inner, let frame) where !natural:
            let i = u.members[0]
            ctx.placements[i] = .group(bled, children: composed(frame, layers: inner, into: bled.size, k: k, ctx: ctx), k: k)
        default:
            for m in u.members {
                let b = ctx.layers.boxes[m]
                ctx.placements[m] = .rigid(origin: CGPoint(x: rect.minX + (b.minX - u.box.minX) * k, y: rect.minY + (b.minY - u.box.minY) * k), k: k)
            }
        }
    }

    /// A group's layers laid out again in its new size.
    private static func composed(_ f: Frame, layers: Layers, into size: CGSize, k: CGFloat, ctx: Context) -> [Node] {
        var inner = Context(layers: layers, mode: ctx.mode, frame: size, focus: ctx.focus)
        inner.record = false
        lay(f, into: CGRect(origin: .zero, size: size), k: k, ctx: &inner, isRoot: false)
        return apply(inner.placements, to: layers, focus: ctx.focus)
    }

    /// How tall what a shape holds is once it is `width` wide.
    private static func innerHeight(_ f: Frame, width: CGFloat, k: CGFloat, ctx: Context) -> CGFloat {
        guard let flow = f.flow else { return 0 }
        return natural(.stack(flow), width: width, k: k, ctx: ctx, parentMain: .y)
    }

    /// How tall a text is with its type grown by `k` and its words wrapped to `width`.
    private static func textHeight(_ node: Node, width: CGFloat, k: CGFloat) -> CGFloat {
        var n = node
        n.scaleType(by: k)
        // A box of fixed size keeps its height, unless its words need more.
        let fixed = n.style?.sizing == .fixed
        if fixed { n.style?.sizing = .autoHeight }
        n.frame.size.width = width
        n.refit()
        return fixed ? max(n.frame.height, node.frame.height * k) : n.frame.height
    }

    // MARK: - Making the layers

    private static func apply(_ placements: [Int: Placement], to layers: Layers, focus: [String: CGPoint]) -> [Node] {
        layers.nodes.enumerated().map { i, node in
            guard let p = placements[i] else { return node }
            var n: Node
            switch p {
            case .rigid(let origin, let k):
                n = scaled(node, by: k)
                let b = Geometry.bounds(of: n)
                // What it shows goes to `origin`: a cut-out's empty edges lie past it.
                let whole = Geometry.bounds(of: node), shown = layers.boxes[i]
                let dx = (shown.minX - whole.minX) * k, dy = (shown.minY - whole.minY) * k
                n.frame.origin = CGPoint(x: n.frame.minX + origin.x - dx - b.minX, y: n.frame.minY + origin.y - dy - b.minY)
                // Grown as a whole, it keeps its proportions to the last: only where it lies is rounded.
                n.frame.origin = CGPoint(x: (n.frame.minX * 2).rounded() / 2, y: (n.frame.minY * 2).rounded() / 2)
            case .box(let rect, let k):
                n = rounded(stretched(node, to: rect, k: k, focus: focus))
            case .group(let rect, let children, let k):
                n = looks(node, by: k)
                n.frame = rect
                n.children = children
                n = rounded(n)
            case .band(let rect, let k):
                n = node.isCopy ? node : looks(node, by: k)
                if node.isGroup, node.frame.width > 0, node.frame.height > 0 {
                    n.children = BezzleDocument.scaled(node.children, from: node.frame.size, to: rect.size)
                    n.mask = node.mask.map { BezzleDocument.scaled($0, from: node.frame.size, to: rect.size) }
                }
                n.frame = rect
                if let image = node.fill.image { n.fill.image = recropped(image, from: node.frame.size, to: rect.size, focus: focus[image.asset]) }
                n = rounded(n)
            }
            // However small the artboard, what had a size keeps one: a point at least.
            if node.frame.width >= 0.5, n.frame.width < 1 { n.frame.size.width = 1 }
            if node.frame.height >= 0.5, n.frame.height < 1 { n.frame.size.height = 1 }
            return n
        }
    }

    /// A layer taking a new box: a shape stretched to it, its picture cropped again; text wrapped
    /// to its width.
    private static func stretched(_ node: Node, to rect: CGRect, k: CGFloat, focus: [String: CGPoint]) -> Node {
        var n = looks(node, by: k)
        switch node.kind {
        case .text:
            n.scaleType(by: k)
            n.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: node.style?.sizing == .fixed ? max(rect.height, 1) : node.frame.height * k)
            if n.style?.sizing == .fixed {
                // A box of fixed size grows to hold its words, wrapped to the new width.
                var probe = n
                probe.style?.sizing = .autoHeight
                probe.refit()
                n.frame.size.height = max(rect.height, probe.frame.height)
            }
            n.refit()
            n.frame.origin = rect.origin
        case .line:
            n.frame = CGRect(x: rect.minX, y: rect.minY, width: node.frame.width > 0 ? rect.width : 0, height: node.frame.height > 0 ? rect.height : 0)
        default:
            n.frame = rect
            if let image = node.fill.image {
                n.fill.image = recropped(image, from: node.frame.size, to: rect.size, focus: focus[image.asset])
            }
        }
        return n
    }

    /// A layer grown or shrunk by `k` all through, as a picture of it would be: its size, its
    /// type, its corners, borders, shadows and blur, and all it holds. Its top left stays put.
    static func scaled(_ node: Node, by k: CGFloat) -> Node {
        guard abs(k - 1) > 0.0001 else { return node }
        // A copy of a component is resized as its handles resize it: its component lays out what
        // it holds, and its look stays the component's, the same in every copy.
        if node.isCopy, node.frame.width > 0, node.frame.height > 0 {
            var n = node
            let size = CGSize(width: node.frame.width * k, height: node.frame.height * k)
            n.children = BezzleDocument.scaled(node.children, from: node.frame.size, to: size)
            n.mask = node.mask.map { BezzleDocument.scaled($0, from: node.frame.size, to: size) }
            n.frame.size = size
            return n
        }
        var n = looks(node, by: k)
        n.frame.size = CGSize(width: node.frame.width * k, height: node.frame.height * k)
        switch node.kind {
        case .text:
            n.scaleType(by: k)
            n.refit()
            // In proportion to the box it had, however its words measured in it: text brought in
            // from another app keeps its box, and grows only as its letters do, which is not
            // quite in step with their size.
            var then = node
            then.refit()
            if then.frame.width > 0.5, then.frame.height > 0.5, node.frame.width > 0.5, node.frame.height > 0.5 {
                n.frame.size = CGSize(width: node.frame.width * n.frame.width / then.frame.width,
                                      height: node.frame.height * n.frame.height / then.frame.height)
            }
            // Words keep their place by the side they are aligned to.
            n.frame.origin = node.frame.origin
        case .group:
            n.children = node.children.map { c in
                var s = scaled(c, by: k)
                s.frame.origin = CGPoint(x: c.frame.minX * k, y: c.frame.minY * k)
                return s
            }
            n.mask = node.mask?.map { m in
                var s = scaled(m, by: k)
                s.frame.origin = CGPoint(x: m.frame.minX * k, y: m.frame.minY * k)
                return s
            }
            n.grid?.columnGap *= k
            n.grid?.rowGap *= k
        default:
            break
        }
        return n
    }

    /// A layer's look grown by `k`: its corners, borders, shadows, blur and depth.
    private static func looks(_ node: Node, by k: CGFloat) -> Node {
        guard abs(k - 1) > 0.0001 else { return node }
        var n = node
        n.cornerRadius = node.cornerRadius * k
        n.corners = node.corners?.map { $0 * k }
        func border(_ b: Border) -> Border {
            var b = b
            b.width *= k
            b.dash *= k
            b.gap *= k
            return b
        }
        func shadow(_ s: Shadow) -> Shadow {
            var s = s
            s.x *= k
            s.y *= k
            s.blur *= k
            s.spread = s.spread.map { $0 * k }
            return s
        }
        n.border = border(node.border)
        n.moreBorders = node.moreBorders?.map(border)
        n.shadow = shadow(node.shadow)
        n.moreShadows = node.moreShadows?.map(shadow)
        if let blur = node.blur { n.blur?.radius = blur.radius * k }
        if let t = node.transform3D { n.transform3D?.z = t.z * k }
        return n
    }

    /// A photo cut down to what shows of it in `page`, looking just as it did: the same picture,
    /// as big and in the same place, in a smaller frame whose new edges lie on the page's. Only a
    /// plain one: upright, square-cornered, with no border or blur to show the cut. A shadow may
    /// stay: what casts it is the picture, as it was.
    static func clipped(_ n: Node, to page: CGRect) -> Node? {
        guard n.kind == .rectangle, let image = n.fill.image, image.mode == .cover, n.rotation == 0, n.transform3D == nil,
              n.cornerRadius == 0, n.corners == nil, !n.borders.contains(where: \.on), n.blur == nil,
              image.size.width > 0, image.size.height > 0 else { return nil }
        let shown = n.frame.intersection(page)
        guard !shown.isNull, shown.width > 1, shown.height > 1 else { return nil }
        let drawn = Renderer.imageRect(image, in: n.frame.size).offsetBy(dx: n.frame.minX, dy: n.frame.minY)
        let cover = max(shown.width / image.size.width, shown.height / image.size.height)
        var g = image
        // A hair larger than exact, so that rounding never leaves a sliver at its edge.
        g.scale = drawn.width / (image.size.width * cover) * 1.002
        guard g.scale >= 0.999 else { return nil }
        let r = drawn.offsetBy(dx: -shown.minX, dy: -shown.minY)
        g.offset = CGPoint(x: (r.minX - (shown.width - r.width) / 2) / shown.width, y: (r.minY - (shown.height - r.height) / 2) / shown.height)
        var c = n
        c.frame = shown
        c.fill.image = g
        return c
    }

    /// A picture covering a layer that takes a new size, cropped again so that what it shows stays
    /// where it was in the layer: `focus`, 0…1 across and down the picture, or else what was in
    /// the middle of the layer.
    static func recropped(_ image: ImageFill, from old: CGSize, to new: CGSize, focus: CGPoint?) -> ImageFill {
        guard image.mode == .cover, old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return image }
        let r0 = Renderer.imageRect(image, in: old)
        guard r0.width > 0, r0.height > 0 else { return image }
        let f = focus ?? CGPoint(x: (old.width / 2 - r0.minX) / r0.width, y: (old.height / 2 - r0.minY) / r0.height)
        let u = CGPoint(x: (r0.minX + f.x * r0.width) / old.width, y: (r0.minY + f.y * r0.height) / old.height)
        var g = image
        g.offset = .zero
        let r1 = Renderer.imageRect(g, in: new)
        var x = u.x * new.width - f.x * r1.width, y = u.y * new.height - f.y * r1.height
        x = min(0, max(new.width - r1.width, x))
        y = min(0, max(new.height - r1.height, y))
        let ox = (x - (new.width - r1.width) / 2) / new.width, oy = (y - (new.height - r1.height) / 2) / new.height
        g.offset = CGPoint(x: abs(ox) < 0.00001 ? 0 : ox, y: abs(oy) < 0.00001 ? 0 : oy)
        return g
    }

    /// Whole points, as a design lands on the pixel grid; text keeps the size its words take.
    private static func rounded(_ n: Node) -> Node {
        var n = n
        if n.kind == .text {
            n.frame.origin = CGPoint(x: n.frame.minX.rounded(), y: n.frame.minY.rounded())
        } else if n.rotation == 0 {
            n.frame = Geometry.snapToPixels(n.frame)
        } else {
            n.frame.origin = CGPoint(x: (n.frame.minX * 2).rounded() / 2, y: (n.frame.minY * 2).rounded() / 2)
        }
        return n
    }

    /// The tree, in words, for looking at what was understood.
    static func describe(_ p: Piece, _ depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch p {
        case .unit(let u):
            let shape: String = switch u.shape {
            case .rigid: "rigid"
            case .stretchy: "stretchy"
            case .text: "text"
            case .holder(let h, _): "holder(\(h))"
            case .group: "group"
            }
            return "\(pad)unit \(u.members) \(shape) \(u.box.integral)\(u.share.map { " share \($0)" } ?? "")"
        case .stack(let s):
            let places = s.places.map { "\($0.anchor)" }.joined(separator: ",")
            return "\(pad)stack \(s.axis) gaps \(s.gaps.map { Int($0) }) loose \(s.loose) places [\(places)] ends \(s.ends) \(s.box.integral)\n"
                + s.children.map { describe($0, depth + 1) }.joined(separator: "\n")
        }
    }

    // MARK: - Measures

    static func lo(_ r: CGRect, _ a: Axis) -> CGFloat { a == .x ? r.minX : r.minY }
    static func hi(_ r: CGRect, _ a: Axis) -> CGFloat { a == .x ? r.maxX : r.maxY }
    static func length(_ r: CGRect, _ a: Axis) -> CGFloat { a == .x ? r.width : r.height }
    static func length(_ s: CGSize, _ a: Axis) -> CGFloat { a == .x ? s.width : s.height }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
