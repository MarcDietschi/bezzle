import Foundation
import CoreGraphics

/// Where the canvas is looked at from: the canvas point at the view's top left, and how many
/// screen points one canvas point takes.
nonisolated struct Viewport: Codable, Equatable {
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1

    static let minZoom: CGFloat = 0.02
    static let maxZoom: CGFloat = 64

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom)
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + origin.x, y: p.y / zoom + origin.y)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    /// Zooms to `zoom` keeping the canvas point under `anchor` (a view point) where it is.
    mutating func zoom(to zoom: CGFloat, keeping anchor: CGPoint) {
        let fixed = toCanvas(anchor)
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        origin = CGPoint(x: fixed.x - anchor.x / self.zoom, y: fixed.y - anchor.y / self.zoom)
    }

    /// Shows `rect` whole in a view of `size`, no closer than `maxZoom`.
    mutating func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 64, maxZoom: CGFloat = 1) {
        guard rect.width > 0 || rect.height > 0, size.width > 0, size.height > 0 else { return }
        let room = CGSize(width: max(size.width - padding * 2, 40), height: max(size.height - padding * 2, 40))
        zoom = min(maxZoom, room.width / max(rect.width, 1), room.height / max(rect.height, 1))
        zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        origin = CGPoint(x: rect.midX - size.width / 2 / zoom, y: rect.midY - size.height / 2 / zoom)
    }
}

/// Where a layer sits: its index on the canvas, then its index in each artboard or group on
/// the way down to it.
nonisolated struct NodePath: Hashable {
    var indices: [Int]

    var top: Int { indices[0] }
    /// The artboard or group it lies in, if any.
    var parent: NodePath? { indices.count > 1 ? NodePath(indices: Array(indices.dropLast())) : nil }
}

/// Where every layer of one version of a document is, worked out the first time it is asked.
/// A large design is looked into hundreds of times a frame; searching it each time is too slow.
private nonisolated final class PathIndex: @unchecked Sendable {
    var paths: [UUID: [Int]]?
}

/// A whole design: artboards and loose layers on the canvas, bottom first.
nonisolated struct BezzleDocument: Codable, Equatable, Sendable {
    static let fileExtension = "bezzle"
    /// Designs saved while the app was called Vellum; they open and save as they are.
    static let oldFileExtension = "vellum"
    static let fileExtensions = [fileExtension, oldFileExtension]
    static let currentVersion = 1

    var version = BezzleDocument.currentVersion
    /// Any change to the layers starts the index again.
    var nodes: [Node] = [] {
        didSet { index = PathIndex() }
    }
    var viewport: Viewport?
    /// The looks the design has given names to, each the same wherever it is used, in the order
    /// they are listed; nil while there are none. See `Style`.
    var styles: [Style]?
    /// The design's components, each a group that every copy of it on the canvas is made from,
    /// never drawn itself; nil while there are none. See `Instance`.
    var components: [Node]?
    /// Notes written in its margins, and their answers; nil while there are none. See `MarginNote`.
    var notes: [MarginNote]?
    private var index = PathIndex()

    enum CodingKeys: String, CodingKey { case version, nodes, viewport, styles, components, notes }

    static func == (a: BezzleDocument, b: BezzleDocument) -> Bool {
        a.version == b.version && a.viewport == b.viewport && a.styles == b.styles && a.nodes == b.nodes && a.components == b.components
            && a.notes == b.notes
    }

    // MARK: Finding layers

    func path(of id: UUID) -> NodePath? {
        if index.paths == nil {
            var paths: [UUID: [Int]] = [:]
            func add(_ nodes: [Node], _ prefix: [Int]) {
                for (i, node) in nodes.enumerated() {
                    let here = prefix + [i]
                    paths[node.id] = here
                    if !node.children.isEmpty { add(node.children, here) }
                }
            }
            add(nodes, [])
            index.paths = paths
        }
        return index.paths?[id].map(NodePath.init)
    }

    /// How many layers there are, without making a list of them.
    var layerCount: Int { Self.layerCount(nodes) }

    /// How many layers these are, with all they hold.
    static func layerCount(_ nodes: [Node]) -> Int { nodes.reduce(nodes.count) { $0 + layerCount($1.children) } }

    subscript(path: NodePath) -> Node {
        get {
            var node = nodes[path.top]
            for i in path.indices.dropFirst() { node = node.children[i] }
            return node
        }
        set { Self.modify(&nodes, path.indices[...]) { $0 = newValue } }
    }

    private static func modify(_ nodes: inout [Node], _ indices: ArraySlice<Int>, _ change: (inout Node) -> Void) {
        guard let i = indices.first else { return }
        if indices.count == 1 { change(&nodes[i]) } else { modify(&nodes[i].children, indices.dropFirst(), change) }
    }

    func node(_ id: UUID) -> Node? { path(of: id).map { self[$0] } }

    /// The artboard or group a layer lies in.
    func parent(of id: UUID) -> Node? {
        path(of: id)?.parent.map { self[$0] }
    }

    /// The artboard a layer lies on, however deep in groups.
    func artboard(of id: UUID) -> Node? {
        guard let p = path(of: id), p.indices.count > 1, nodes[p.top].isArtboard else { return nil }
        return nodes[p.top]
    }

    /// The artboards and groups from the canvas down to a layer, not counting the layer.
    func ancestors(of id: UUID) -> [Node] {
        guard let p = path(of: id) else { return [] }
        var chain: [Node] = []
        for i in p.indices.dropLast() {
            chain.append(chain.last.map { $0.children[i] } ?? nodes[i])
        }
        return chain
    }

    /// Where the parent's own coordinates start on the canvas. Artboards and groups are never
    /// turned, so this is all it takes to go from a layer's frame to the canvas.
    func parentOrigin(of id: UUID) -> CGPoint {
        ancestors(of: id).reduce(.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
    }

    func absoluteFrame(of id: UUID) -> CGRect? {
        guard let n = node(id) else { return nil }
        let o = parentOrigin(of: id)
        return n.frame.offsetBy(dx: o.x, dy: o.y)
    }

    /// Changes the layer with this id in place; nothing happens if there is none. What a layer
    /// holds may change, but not which layers it holds or in what order: the index stays good.
    mutating func update(_ id: UUID, _ change: (inout Node) -> Void) {
        guard let p = path(of: id) else { return }
        let kept = index
        Self.modify(&nodes, p.indices[...], change)
        index = kept
    }

    /// Every layer, each before what it holds.
    var allNodes: [Node] {
        func flatten(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + flatten($0.children) } }
        return flatten(nodes)
    }

    var artboards: [Node] { nodes.filter(\.isArtboard) }

    /// The topmost artboard under a canvas point.
    func artboard(at point: CGPoint) -> Node? {
        nodes.last { $0.isArtboard && !$0.hidden && $0.frame.contains(point) }
    }

    /// Everything on the canvas, as one rectangle.
    var contentBounds: CGRect? {
        var bounds: CGRect?
        for n in nodes where !n.hidden {
            let r = n.isArtboard ? n.frame : Geometry.bounds(of: n)
            bounds = bounds?.union(r) ?? r
        }
        return bounds
    }

    // MARK: Moving layers between parents

    /// Takes a layer out, wherever it is, and returns it with its frame on the canvas.
    mutating func detach(_ id: UUID) -> Node? {
        guard let p = path(of: id) else { return nil }
        let origin = parentOrigin(of: id)
        var taken: Node?
        if let parent = p.parent {
            Self.modify(&nodes, parent.indices[...]) { taken = $0.children.remove(at: p.indices.last!) }
        } else {
            taken = nodes.remove(at: p.top)
        }
        taken?.frame.origin.x += origin.x
        taken?.frame.origin.y += origin.y
        return taken
    }

    /// Puts a layer whose frame is on the canvas into an artboard or group (or onto the canvas
    /// itself when nil), on top unless `index` says where.
    mutating func attach(_ node: Node, to container: UUID?, at index: Int? = nil) {
        var n = node
        if let container, let p = path(of: container) {
            let o = parentOrigin(of: container), frame = self[p].frame
            n.frame.origin.x -= o.x + frame.minX
            n.frame.origin.y -= o.y + frame.minY
            Self.modify(&nodes, p.indices[...]) { $0.children.insert(n, at: min(index ?? $0.children.count, $0.children.count)) }
        } else {
            nodes.insert(n, at: min(index ?? nodes.count, nodes.count))
        }
    }

    /// Puts a layer into the list `path` points into, at the place it names there.
    mutating func insert(_ node: Node, at path: NodePath) {
        if let parent = path.parent {
            Self.modify(&nodes, parent.indices[...]) { $0.children.insert(node, at: min(path.indices.last!, $0.children.count)) }
        } else {
            nodes.insert(node, at: min(path.top, nodes.count))
        }
    }

    // MARK: Groups

    /// A layer turned about a point in its parent. A group is never turned itself: what it
    /// holds is, about the same point, and its frame is fitted around them afterwards.
    @MainActor
    static func turned(_ node: Node, by degrees: Double, about pivot: CGPoint) -> Node {
        var n = node
        if n.isRepeatGrid { return RepeatGrid.turned(n, by: degrees, about: pivot) }
        if n.isGroup {
            let inner = CGPoint(x: pivot.x - n.frame.minX, y: pivot.y - n.frame.minY)
            n.children = n.children.map { turned($0, by: degrees, about: inner) }
            n.mask = n.mask?.map { turned($0, by: degrees, about: inner) }
            return n
        }
        n.frame = CGRect(center: Geometry.rotated(n.frame.center, about: pivot, by: degrees), size: n.frame.size)
        n.rotation = CanvasView.normalized(n.rotation + degrees)
        return n
    }

    /// A layer mirrored in its parent, across the upright line at `axis` when `horizontally`,
    /// else across the level one. It turns the other way, and its outline, corners, gradient and
    /// picture are turned over; words still read forwards. A group is not flipped itself: what it
    /// holds is, across the same line, and its frame is fitted around them afterwards.
    @MainActor
    static func flipped(_ node: Node, horizontally: Bool, about axis: CGFloat) -> Node {
        var n = node
        if n.isRepeatGrid { return RepeatGrid.flipped(n, horizontally: horizontally, about: axis) }
        if n.isGroup {
            let inner = axis - (horizontally ? n.frame.minX : n.frame.minY)
            n.children = n.children.map { flipped($0, horizontally: horizontally, about: inner) }
            n.mask = n.mask?.map { flipped($0, horizontally: horizontally, about: inner) }
            return n
        }
        let c = n.frame.center
        n.frame = CGRect(center: horizontally ? CGPoint(x: 2 * axis - c.x, y: c.y) : CGPoint(x: c.x, y: 2 * axis - c.y), size: n.frame.size)
        // Not -0, which a file would keep.
        if n.rotation != 0 { n.rotation = CanvasView.normalized(-n.rotation) }
        n.fill = n.fill.flipped(horizontally: horizontally)
        n.moreFills = n.moreFills?.map { $0.flipped(horizontally: horizontally) }
        n.border = n.border.flipped(horizontally: horizontally)
        n.moreBorders = n.moreBorders?.map { $0.flipped(horizontally: horizontally) }
        switch n.kind {
        case .rectangle:
            // Top left, top right, bottom right, bottom left.
            if let k = n.corners, k.count == 4 { n.corners = horizontally ? [k[1], k[0], k[3], k[2]] : [k[3], k[2], k[1], k[0]] }
        case .line:
            n.rising.toggle()
        case .path:
            // Turned over within its own box, which stays where it is.
            if let data = n.path {
                let box = n.pathBox ?? PathData.bounds(data)
                n.path = PathData.transformed(data, horizontally ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: box.minX + box.maxX, ty: 0)
                                                                 : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.minY + box.maxY))
            }
        default:
            break
        }
        return n
    }

    /// What a group holds, stretched from the group's old size to its new one.
    @MainActor
    static func scaled(_ nodes: [Node], from old: CGSize, to new: CGSize) -> [Node] {
        let sx = old.width > 0 ? new.width / old.width : 1, sy = old.height > 0 ? new.height / old.height : 1
        return nodes.map { node in
            var n = node
            let f = node.frame
            n.frame = CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy)
            if n.isGroup {
                n.children = scaled(node.children, from: f.size, to: n.frame.size)
                n.mask = node.mask.map { scaled($0, from: f.size, to: n.frame.size) }
                // A grid's gaps grow with its cells.
                n.grid?.columnGap *= sx
                n.grid?.rowGap *= sy
            }
            // Text as wide as its words grows its letters, as it does when resized on its own.
            if n.kind == .text, n.style?.sizing == .autoWidth {
                n.scaleType(by: sy)
                n.refit()
            }
            return n
        }
    }

    /// How far a group is seen turned in the page: as far as most of what it holds, by area, a
    /// quarter turn lying the same way. That is the turn of its largest layer so turned, between
    /// -180° and 180°; 0 when it lies upright or a quarter turn from it.
    @MainActor
    static func turn(of group: Node) -> Double {
        // By hundredths of a degree, round a quarter turn.
        var areas: [Int: CGFloat] = [:], largest: [Int: (area: CGFloat, rotation: Double)] = [:]
        func visit(_ n: Node) {
            if n.isGroup { (n.cutBy.map { [$0] } ?? n.children).forEach(visit); return }
            let area = max(n.frame.width, 1) * max(n.frame.height, 1)
            let r = n.rotation.truncatingRemainder(dividingBy: 90)
            let key = Int(((r < 0 ? r + 90 : r) * 100).rounded()) % 9000
            areas[key, default: 0] += area
            if area > largest[key]?.area ?? 0 { largest[key] = (area, n.rotation) }
        }
        (group.cutBy.map { [$0] } ?? group.children).forEach(visit)
        guard let key = areas.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
              key != 0, let rotation = largest[key]?.rotation else { return 0 }
        return CanvasView.normalized(rotation)
    }

    /// How a layer lies in its parent, as its selection shows: its frame, upright, and how far that
    /// is turned about its middle. A group is never turned itself, but is seen turned as far as its
    /// layers are (`turn(of:)`), in the box round them along that turn. Anything else, a repeat grid
    /// too (which shows its own turn), is its frame and rotation.
    @MainActor
    static func turnedBox(of node: Node) -> (frame: CGRect, rotation: Double) {
        guard node.isGroup, !node.isRepeatGrid else { return (node.frame, node.rotation) }
        let turn = turn(of: node)
        guard turn != 0 else { return (node.frame, 0) }
        let pivot = node.frame.center
        let upright = turned(node, by: -turn, about: pivot)
        // By what the layers in it cover, however deep: a group in it keeps the frame it had
        // turned, until it is fitted again, which is the box round its layers turned, not upright.
        guard let box = (upright.cutBy.map { [$0] } ?? upright.children).map({ RepeatGrid.box(of: $0) }).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) else {
            return (node.frame, 0)
        }
        let middle = Geometry.rotated(CGPoint(x: node.frame.minX + box.midX, y: node.frame.minY + box.midY), about: pivot, by: turn)
        return (CGRect(center: middle, size: box.size), turn)
    }

    /// A group seen turned by `turn` stretched from its box `old` to `new`, both upright in its
    /// parent and turned by `turn` about their middles: turned upright about the old box's middle,
    /// stretched there as any group is, and turned back about the new box's. Its frame is fitted
    /// round what it holds afterwards.
    @MainActor
    static func scaled(_ group: Node, turned turn: Double, from old: CGRect, to new: CGRect) -> Node {
        var g = turned(group, by: -turn, about: old.center)
        // Upright, what it holds fills the old box; measured from that box, it fills the new one.
        let dx = group.frame.minX - old.minX, dy = group.frame.minY - old.minY
        func moved(_ nodes: [Node]) -> [Node] { nodes.map { var n = $0; n.frame = n.frame.offsetBy(dx: dx, dy: dy); return n } }
        g.frame = new
        g.children = scaled(moved(g.children), from: old.size, to: new.size)
        g.mask = g.mask.map { scaled(moved($0), from: old.size, to: new.size) }
        return turned(g, by: turn, about: new.center)
    }

    /// Brings every group's frame back to the box around what it holds, without moving anything
    /// on the canvas, and takes away groups left empty.
    mutating func fitGroups() {
        Self.fit(&nodes, before: nil)
        fitMasters(before: nil)
    }

    /// Fits the components' groups too, which lie apart from the canvas.
    private mutating func fitMasters(before: [Node]?) {
        guard components != nil else { return }
        Self.fit(&components!, before: before)
        if components?.isEmpty == true { components = nil }
    }

    /// The same, only where something changed since `before`, which was fitted already. An
    /// artboard left alone compares equal at once, as it still shares its storage with before.
    mutating func fitGroups(since before: BezzleDocument) {
        // Fitting moves frames, not layers, so where each layer is stays known, unless a group
        // was left empty and went.
        let kept = index
        if !Self.fit(&nodes, before: before.nodes) { index = kept }
        fitMasters(before: before.components)
    }

    /// Whether the two have the same layers in the same places, as far as can be told at once:
    /// false may only mean it was not worked out.
    func hasSameLayers(as other: BezzleDocument) -> Bool { index === other.index }

    /// Returns whether any group was taken away.
    @discardableResult
    private static func fit(_ nodes: inout [Node], before: [Node]?) -> Bool {
        var removed = false
        for i in nodes.indices where !nodes[i].children.isEmpty || nodes[i].isGroup {
            let was = before.flatMap { i < $0.count && $0[i].id == nodes[i].id ? $0[i] : nil }
            if let was, was == nodes[i] { continue }
            if fit(&nodes[i].children, before: was?.children) { removed = true }
            if nodes[i].isGroup { fitGroup(&nodes[i]) }
        }
        if nodes.contains(where: { $0.isGroup && $0.children.isEmpty }) {
            nodes.removeAll { $0.isGroup && $0.children.isEmpty }
            removed = true
        }
        return removed
    }

    private static func fitGroup(_ group: inout Node) {
        // Words riding a shape in it go where the shape now is, before the group fits round them.
        group.followCurves()
        // A masked group is as big as its mask, and a mask as big as its shape.
        let box = group.cutBy.map { Geometry.bounds(of: $0) }
            ?? group.children.map { Geometry.bounds(of: $0) }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        guard let box, box.origin != .zero || box.size != group.frame.size else { return }
        for j in group.children.indices { group.children[j].frame = group.children[j].frame.offsetBy(dx: -box.minX, dy: -box.minY) }
        if group.mask != nil {
            for j in group.mask!.indices { group.mask![j].frame = group.mask![j].frame.offsetBy(dx: -box.minX, dy: -box.minY) }
        }
        group.frame = CGRect(x: group.frame.minX + box.minX, y: group.frame.minY + box.minY, width: box.width, height: box.height)
        // A copy's layers are laid out in a box of its own, which goes with them.
        if let inst = group.instance { group.instance?.box = inst.box.offsetBy(dx: -box.minX, dy: -box.minY) }
    }

    /// Unique names, XD style: "Rectangle 3".
    func nextName(for kind: Node.Kind) -> String {
        let base = kind.title
        let taken = Set(allNodes.map(\.name))
        if kind == .artboard && !taken.contains(base) { return base }
        var i = kind == .artboard ? 2 : 1
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
