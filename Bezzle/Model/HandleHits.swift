import Foundation
import CoreGraphics

/// What a press on or near the selection takes hold of: a handle to resize it by; just outside a
/// corner, a turn in the page; a line's end; a dot inside a selected rectangle's corner, which
/// rounds the corners; the selected layer's shadow outside the layer itself, which moves the
/// shadow; just outside the middle of a side, a turn in depth.
enum HandleHit: Equatable {
    case resize(Handle)
    case rotate(Handle)
    case lineEnd(Int)
    case corner(Handle)
    case shadow
    case turnInDepth
}

extension BezzleDocument {
    /// A rectangle's corners in the order `Node.radii` keeps them.
    static let cornerOrder: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    /// Whether a layer shows anywhere but where its frame says, turned in depth or in a group that is.
    func inDepth(_ node: Node) -> Bool {
        Perspective.inDepth(node) || liesInDepth(node.id)
    }

    /// The shadow the canvas moves: the one whose card is open (`open`) when it falls outside the
    /// layer, else the first that does.
    static func shadowSlot(of node: Node, open: Int?) -> Int? {
        if let open, open < node.slots(.shadow), node[shadow: open].outside { return open }
        return (0..<node.slots(.shadow)).first { node[shadow: $0].outside }
    }

    /// The dots inside a selected rectangle's corners, on the canvas, each along the diagonal as
    /// far in as its corner is round and never nearer a corner than ten points on screen. Only
    /// for one rectangle, not locked nor in depth, big enough on screen for them not to crowd it.
    func cornerDots(of ids: [UUID], zoom: CGFloat) -> [(Handle, CGPoint)] {
        guard ids.count == 1, let node = node(ids[0]), node.kind == .rectangle, !node.locked, !inDepth(node),
              let frame = absoluteFrame(of: node.id) else { return [] }
        guard frame.width * zoom >= 48, frame.height * zoom >= 48 else { return [] }
        let half = min(frame.width, frame.height) / 2
        return zip(Self.cornerOrder, node.radii).map { h, radius in
            let inset = min(max(min(max(radius, 0), half), 10 / zoom), half)
            let sx: CGFloat = h.unit.x == 0 ? 1 : -1, sy: CGFloat = h.unit.y == 0 ? 1 : -1
            let local = CGPoint(x: (h.unit.x - 0.5) * frame.width + sx * inset, y: (h.unit.y - 0.5) * frame.height + sy * inset)
            let v = Geometry.rotate(local, by: node.rotation)
            return (h, CGPoint(x: frame.midX + v.x, y: frame.midY + v.y))
        }
    }

    /// Whether a canvas point is on the selected layer's shadow (`slot` says which) and not on
    /// the layer itself, within `tolerance` of it: as far out as the shadow shows, and a little
    /// more for a fine one.
    func isOnShadow(_ p: CGPoint, selection ids: [UUID], zoom: CGFloat, tolerance: CGFloat, slot: (Node) -> Int?) -> Bool {
        guard ids.count == 1, let node = node(ids[0]), let slot = slot(node), !node.locked, !node.isArtboard, node.kind != .line,
              !inDepth(node), let frame = absoluteFrame(of: node.id) else { return false }
        let shadow = node[shadow: slot], grown = Renderer.spreads(node, shadow) ? max(shadow.grown, 0) : 0
        let own = Geometry.local(p, in: frame, rotation: node.rotation)
        if abs(own.x) <= frame.width / 2 + tolerance && abs(own.y) <= frame.height / 2 + tolerance { return false }
        let spread = max(shadow.blur / 2, 6 / zoom) + grown
        let shadowFrame = frame.offsetBy(dx: shadow.x, dy: shadow.y)
        let q = Geometry.local(p, in: shadowFrame, rotation: node.rotation)
        return abs(q.x) <= shadowFrame.width / 2 + spread && abs(q.y) <= shadowFrame.height / 2 + spread
    }

    /// The shape of the selected layer where its shadow falls, on the canvas, for drawing it
    /// dashed while the pointer is on it.
    func shadowCorners(of ids: [UUID], slot: (Node) -> Int?) -> [CGPoint]? {
        guard ids.count == 1, let node = node(ids[0]), let slot = slot(node), let frame = absoluteFrame(of: node.id) else { return nil }
        let shadow = node[shadow: slot], grown = Renderer.spreads(node, shadow) ? shadow.grown : 0
        return Geometry.corners(of: frame.offsetBy(dx: shadow.x, dy: shadow.y).insetBy(dx: -grown, dy: -grown), rotation: node.rotation)
    }

    /// What a press at `v` on screen takes hold of, as the Mac's canvas tells (`toView` places
    /// canvas points on screen at `zoom`). `selecting` is whether the select tool is free to round
    /// corners and move shadows; `slot` which shadow a drag moves.
    func handleHit(at v: CGPoint, selection ids: [UUID], zoom: CGFloat, toView: (CGPoint) -> CGPoint, selecting: Bool,
                   slot: (Node) -> Int?, turnedBox: @MainActor (Node) -> (frame: CGRect, rotation: Double) = BezzleDocument.turnedBox) -> HandleHit? {
        if ids.count == 1, let node = node(ids[0]), node.kind == .line {
            guard !node.locked, let ends = shownCorners(of: ids[0], turnedBox: turnedBox)?.map(toView) else { return nil }
            for (i, p) in ends.enumerated() where hypot(p.x - v.x, p.y - v.y) <= 7 { return .lineEnd(i) }
            return nil
        }
        let points = handlePoints(of: ids, zoom: zoom, turnedBox: turnedBox).map { ($0.0, toView($0.1)) }
        for (h, p) in points where abs(p.x - v.x) <= 6 && abs(p.y - v.y) <= 6 { return .resize(h) }
        if selecting {
            for (h, c) in cornerDots(of: ids, zoom: zoom) {
                let p = toView(c)
                if hypot(p.x - v.x, p.y - v.y) <= 6 { return .corner(h) }
            }
        }
        // Just outside a corner, the pointer turns things.
        guard let (frame, rotation, single) = handleFrame(of: ids, turnedBox: turnedBox), single?.isArtboard != true,
              !ids.contains(where: { node($0)?.isArtboard == true }) else { return nil }
        let o = toView(frame.origin)
        let viewFrame = CGRect(x: o.x, y: o.y, width: frame.width * zoom, height: frame.height * zoom)
        let local = Geometry.local(v, in: viewFrame, rotation: rotation)
        var outside = abs(local.x) > viewFrame.width / 2 || abs(local.y) > viewFrame.height / 2
        // Turned in depth, outside the shape it makes.
        if let single, inDepth(single), let corners = shownCorners(of: single.id, turnedBox: turnedBox)?.map(toView) {
            let shape = CGMutablePath()
            shape.addLines(between: corners)
            shape.closeSubpath()
            outside = !shape.contains(v)
        }
        guard outside else { return nil }
        // Text as wide as its words turns from just outside its one handle, as XD has it, and its
        // corners, as anything does.
        let point = Self.pointText(single)
        let around = point ? handlePoints(of: ids, zoom: zoom, every: true, turnedBox: turnedBox).map { ($0.0, toView($0.1)) } : points
        for (h, p) in around where h.isCorner || (point && h == .bottom) {
            let d = hypot(p.x - v.x, p.y - v.y)
            if d > 5 && d < 20 { return .rotate(h) }
        }
        let canvas = CGPoint(x: frame.minX + (v.x - o.x) / zoom, y: frame.minY + (v.y - o.y) / zoom)
        if selecting, isOnShadow(canvas, selection: ids, zoom: zoom, tolerance: 4 / zoom, slot: slot) { return .shadow }
        // Just outside the middle of a side, the pointer turns them in depth, as outside a corner
        // it turns them in the page.
        for (h, p) in around where !h.isCorner && !(point && h == .bottom) {
            let d = hypot(p.x - v.x, p.y - v.y)
            if d > 5 && d < 22 { return .turnInDepth }
        }
        return nil
    }

    // MARK: What the drags do

    /// How far one layer is turned already when a turn begins: a group or a grid as it is seen turned.
    static func turnBase(_ originals: [UUID: Node]) -> Double {
        originals.count == 1 ? originals.values.first.map { $0.grid?.turn ?? ($0.isGroup ? BezzleDocument.turn(of: $0) : $0.rotation) } ?? 0 : 0
    }

    /// Layers turned by `delta` degrees about `center` on the canvas, each from as it was when
    /// the drag began (`originals`, where each lay then `absolute`), then put where that is in
    /// what holds it now: a group holding it is fitted round it as it turns, and moves its own
    /// origin, which would otherwise carry the layer off a little more at every step.
    mutating func turn(_ originals: [UUID: Node], absolute: [UUID: CGRect], by delta: Double, about center: CGPoint) {
        for (id, original) in originals {
            guard let whole = absolute[id] else { continue }
            let began = CGPoint(x: whole.minX - original.frame.minX, y: whole.minY - original.frame.minY)
            let o = parentOrigin(of: id)
            update(id) { node in
                node = BezzleDocument.turned(original, by: delta, about: CGPoint(x: center.x - began.x, y: center.y - began.y))
                node.frame.origin = CGPoint(x: node.frame.origin.x + began.x - o.x, y: node.frame.origin.y + began.y - o.y)
            }
        }
    }

    /// A rectangle's corners as a corner's dot dragged to canvas point `p` rounds them: how far
    /// in along the diagonal the pointer is, measured on each side; every corner alike, or with
    /// `alone` only this one.
    static func cornerRadii(at p: CGPoint, frame: CGRect, rotation: Double, corner: Handle, original: [CGFloat], alone: Bool) -> (radii: [CGFloat], radius: CGFloat) {
        let local = Geometry.local(p, in: frame, rotation: rotation)
        let sx: CGFloat = corner.unit.x == 0 ? 1 : -1, sy: CGFloat = corner.unit.y == 0 ? 1 : -1
        let along = ((local.x - (corner.unit.x - 0.5) * frame.width) * sx + (local.y - (corner.unit.y - 0.5) * frame.height) * sy) / 2
        let radius = min(max(along, 0), min(frame.width, frame.height) / 2).rounded()
        var radii = Array(repeating: radius, count: 4)
        if alone, let i = cornerOrder.firstIndex(of: corner) {
            radii = original
            radii[i] = radius
        }
        return (radii, radius)
    }
}
