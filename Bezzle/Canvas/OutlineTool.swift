import AppKit

/// Two things done to a selected shape's outline straight on the canvas.
///
/// Corners: while the pointer is on a selected path, a dot shows inside each of its corners,
/// as on a rectangle. Dragging one in rounds every corner alike, or, with Option, only that
/// one; dragging it back out makes them sharp again. A round made this way, or any round
/// between two straight sides, keeps its dot, so it can be changed later.
///
/// Outlines: with Option held, the pointer on a selected shape's edge pulls a copy of the
/// outline out from it (lying behind) or in from it (lying in front), as far as the pointer is
/// from the edge. Corners stay sharp, or round with Shift.
final class OutlineTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}

    private enum Drag {
        case corner(id: UUID, base: BezierPath, corner: BezierPath.Corner, alone: Bool)
        /// `line` is the edge as it was, as points along it, to measure the pointer from.
        case offset(id: UUID, outline: CGPath, line: [(CGPoint, CGPoint)], copy: UUID?, distance: CGFloat)
    }

    private var drag: Drag?
    /// Whether the pointer is on the selected path, so its corner dots show.
    private var onPath = false
    /// Whether Option is held with the pointer on the selected shape's edge, which is then outlined.
    private var onEdge = false
    private var flags: NSEvent.ModifierFlags = []
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        self.store = store
    }

    var dragging: Bool { drag != nil }

    private var zoom: CGFloat { store.viewport.zoom }
    private func view(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }

    /// The one selected layer, when the select tool is free to work on it.
    private var single: Node? {
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.editingPicture == nil,
              store.building == nil, store.selection.count == 1, let n = store.node(store.selection[0]), !n.locked else { return nil }
        return n
    }

    // MARK: - Corners

    /// The selected path's corner dots: each corner, and where its dot is on screen. On the round's
    /// centre, or, for a sharp corner, a little way in; none on a path too small on screen to fit them.
    private func dots() -> [(BezierPath.Corner, CGPoint)] {
        guard let n = single, n.kind == .path, let points = store.points(of: n.id), let frame = store.doc.absoluteFrame(of: n.id),
              max(frame.width, frame.height) * zoom >= 40 else { return [] }
        let corners = points.corners
        guard corners.count <= 64 else { return [] }
        return corners.map { c in
            let half = max(sin(c.angle / 2), 0.05)
            let distance = max(c.radius / half, min(10 / zoom / half, 24 / zoom))
            return (c, view(c.tip + c.inward * distance))
        }
    }

    private func dot(at v: CGPoint) -> BezierPath.Corner? {
        dots().first { hypot($0.1.x - v.x, $0.1.y - v.y) <= 6 }?.0
    }

    // MARK: - Edges

    /// The selected shape's outline, when it can be pulled out or in: on the canvas, and on screen.
    private func edge() -> (id: UUID, outline: CGPath, onScreen: CGPath)? {
        guard let n = single, store.canOffset(n.id), let outline = store.doc.outline(of: n.id),
              let frame = store.doc.absoluteFrame(of: n.id), min(frame.width, frame.height) * zoom >= 16 else { return nil }
        let vp = store.viewport
        var toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        guard let onScreen = outline.copy(using: &toView) else { return nil }
        return (n.id, outline, onScreen)
    }

    private func isOnEdge(_ v: CGPoint) -> Bool {
        guard let e = edge() else { return false }
        return e.onScreen.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v)
    }

    // MARK: - The pointer

    /// A press with the select tool: on a corner dot, or on the edge with Option. False leaves
    /// it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        flags = event.modifierFlags
        if let corner = dot(at: v), let n = single, let base = store.points(of: n.id) {
            store.beginGesture()
            drag = .corner(id: n.id, base: base, corner: corner, alone: flags.contains(.option))
            return true
        }
        if flags.contains(.option), isOnEdge(v), let e = edge() {
            store.beginGesture()
            drag = .offset(id: e.id, outline: e.outline, line: Outlines.samples(of: e.outline, every: max(0.5, 1 / zoom)), copy: nil, distance: 0)
            return true
        }
        return false
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        self.flags = flags
        let p = canvas(v)
        switch drag {
        case .corner(let id, let base, let corner, let alone):
            // How far in from the tip the pointer is, along the way the dot goes.
            let d = p - corner.tip, inward = corner.inward
            let along = d.x * inward.x + d.y * inward.y
            let radius = max(0, along * sin(corner.angle / 2)).rounded()
            var radii: [PathPoint: CGFloat] = [:]
            for k in alone ? [corner.at] : base.corners.map(\.at) { radii[k] = radius }
            let (rounded, applied) = base.rounding(radii)
            store.setPoints(rounded, of: id, "Round Corners")
            if let frame = store.doc.absoluteFrame(of: id), let node = store.node(id) {
                store.measurement = ("Radius \(CanvasView.number(applied[corner.at] ?? radius))", Geometry.bounds(of: frame, rotation: node.rotation))
            }
        case .offset(let id, let outline, let line, let copy, _):
            // As far as the pointer is from the edge: out when outside the shape, in when inside.
            let nearest = line.map { hypot($0.0.x - p.x, $0.0.y - p.y) }.min() ?? 0
            let distance = (outline.contains(p) ? -nearest : nearest).rounded()
            var made = copy
            if distance == 0 {
                if let copy { store.edit("Outset") { _ = $0.detach(copy) } }
                made = nil
            } else {
                made = store.offsetCopy(of: id, by: distance, round: flags.contains(.shift), replacing: copy)
            }
            drag = .offset(id: id, outline: outline, line: line, copy: made, distance: distance)
            if let made, let frame = store.doc.absoluteFrame(of: made), let node = store.node(made) {
                store.measurement = ("\(distance > 0 ? "Outset" : "Inset") \(CanvasView.number(abs(distance)))", Geometry.bounds(of: frame, rotation: node.rotation))
            } else {
                store.measurement = nil
            }
        case nil:
            return
        }
        redraw()
    }

    func up() {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .corner:
            store.endGesture("Round Corners")
        case .offset(_, _, _, let copy, let distance):
            store.endGesture(distance > 0 ? "Outset" : "Inset")
            if let copy, store.node(copy) != nil { store.selection = [copy] }
        }
        store.measurement = nil
        redraw()
    }

    func cancel() {
        guard drag != nil else { return }
        drag = nil
        store.cancelGesture()
        store.measurement = nil
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil).
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        self.flags = flags
        var path = false, edge = false
        if let v, drag == nil, let n = single {
            if n.kind == .path, let outline = store.doc.line(of: n.id) {
                let vp = store.viewport
                var toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
                if let onScreen = outline.copy(using: &toView) {
                    path = onScreen.contains(v) || onScreen.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v)
                }
                // The dots themselves, which can lie just outside a corner bent inwards.
                if !path { path = dots().contains { hypot($0.1.x - v.x, $0.1.y - v.y) <= 10 } }
            }
            edge = flags.contains(.option) && isOnEdge(v)
        }
        if path != onPath || edge != onEdge {
            onPath = path
            onEdge = edge
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if case .corner = drag { return .crosshair }
        if case .offset(_, _, let line, _, _) = drag { return Self.across(line, at: canvas(v)) }
        guard single != nil else { return nil }
        if dot(at: v) != nil { return .crosshair }
        if flags.contains(.option), isOnEdge(v), let e = edge() {
            return Self.across(Outlines.samples(of: e.outline, every: max(0.5, 1 / zoom)), at: canvas(v))
        }
        return nil
    }

    /// A two-headed arrow across the edge where it is nearest `p`: out and in.
    private static func across(_ line: [(CGPoint, CGPoint)], at p: CGPoint) -> NSCursor {
        guard let near = line.min(by: { hypot($0.0.x - p.x, $0.0.y - p.y) < hypot($1.0.x - p.x, $1.0.y - p.y) }) else { return .crosshair }
        let way = near.1
        return Cursors.resize(atan2(way.x, -way.y) * 180 / .pi)
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if onEdge, drag == nil, let e = edge() {
            ctx.addPath(e.onScreen)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
        let cornering: Bool = if case .corner = drag { true } else { false }
        guard onPath || cornering else { return }
        for (_, p) in dots() {
            let rect = CGRect(center: p, size: CGSize(width: 7, height: 7))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
