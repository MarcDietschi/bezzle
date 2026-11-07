import Foundation
import CoreGraphics

extension BezzleDocument {
    /// Whether the layer's outline can be pulled out or in: a shape whose fill closes it in.
    func canOffset(_ id: UUID) -> Bool {
        guard let n = node(id), Self.cuttable.contains(n.kind), !n.locked else { return false }
        return n.kind != .path || n.fill.on || (points(of: id)?.subpaths.allSatisfy(\.closed) ?? false)
    }

    /// A copy of the layer, as `copyID`, with its outline `distance` further out all round, or
    /// further in, named for it: nil when shrinking leaves nothing. Its frame is in its parent.
    func offsetCopy(of id: UUID, by distance: CGFloat, round: Bool, as copyID: UUID) -> Node? {
        guard let n = node(id), let outline = outline(of: id) else { return nil }
        let shape = Outlines.offset(outline, by: distance, round: round)
        var made = shape.flatMap { n.reshaped(to: $0, origin: parentOrigin(of: id)) }
        made?.id = copyID
        made?.name = distance >= 0 ? String(localized: "\(n.name) Outset") : String(localized: "\(n.name) Inset")
        return made
    }

    /// Puts an outline's copy in, in place of the one made before: behind the layer when it goes
    /// out, in front of it when in.
    mutating func place(offset made: Node?, of id: UUID, by distance: CGFloat, replacing copy: UUID?) {
        if let copy { _ = detach(copy) }
        guard var made, let at = path(of: id) else { return }
        let o = parentOrigin(of: id)
        made.frame = made.frame.offsetBy(dx: o.x, dy: o.y)
        let index = at.indices[at.indices.count - 1]
        attach(made, to: at.parent.map { self[$0].id }, at: distance >= 0 ? index : index + 1)
    }
}

/// What working on a shape's outline on a canvas needs of it: the design and what is picked,
/// its points, where the canvas is, the steps of the history, and somewhere to say how far.
@MainActor protocol OutlineHost: AnyObject {
    var doc: BezzleDocument { get }
    var selection: [UUID] { get set }
    /// Whether the select tool is in hand with nothing else under way (no words being typed, no
    /// points edited, no picture placed, no shapes built).
    var selectsFreely: Bool { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    /// A path's points, and new ones for it, on the canvas (the Mac keeps them worked out).
    func points(of id: UUID) -> BezierPath?
    func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource)
    func beginGesture()
    func endGesture(_ action: LocalizedStringResource)
    func cancelGesture()
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void)
    /// What a drag on an outline measures, said beside `box` (on the canvas); nil when it ends.
    func measure(_ what: OutlineMeasure?, _ box: CGRect)
}

/// What working on an outline says: the corners' radius, or how far a copy goes out or in.
enum OutlineMeasure: Equatable {
    case radius(CGFloat)
    case outset(CGFloat)
    case inset(CGFloat)
}

/// What the pointer shows over an outline: a cross on a corner's dot, or a two-headed arrow
/// across the edge (out and in), at an angle in degrees clockwise from across.
enum OutlinePointer: Equatable {
    case cross
    case across(Double)
}

/// Two things done to a selected shape's outline straight on a canvas, shared by every Bezzle:
/// the canvas hands it the pointer and draws what `marks` says shows.
///
/// Corners: while the pointer is on a selected path, a dot shows inside each of its corners,
/// as on a rectangle. Dragging one in rounds every corner alike, or, with Option (Alt), only
/// that one; dragging it back out makes them sharp again. A round made this way, or any round
/// between two straight sides, keeps its dot, so it can be changed later.
///
/// Outlines: with Option (Alt) held, the pointer on a selected shape's edge pulls a copy of the
/// outline out from it (lying behind) or in from it (lying in front), as far as the pointer is
/// from the edge. Corners stay sharp, or round with Shift.
final class OutlineDragging {
    private let host: OutlineHost
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
    private var flags: PenFlags = []

    init(host: OutlineHost) {
        self.host = host
    }

    var dragging: Bool { drag != nil }

    private var zoom: CGFloat { host.zoom }
    private func view(_ p: CGPoint) -> CGPoint { host.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { host.toCanvas(v) }
    private var toView: CGAffineTransform {
        let origin = host.toView(.zero)
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: origin.x, ty: origin.y)
    }

    /// The one selected layer, when the select tool is free to work on it.
    private var single: Node? {
        let selection = host.selection
        guard host.selectsFreely, selection.count == 1, let n = host.doc.node(selection[0]), !n.locked else { return nil }
        return n
    }

    // MARK: - Corners

    /// The selected path's corner dots: each corner, and where its dot is on screen. On the round's
    /// centre, or, for a sharp corner, a little way in; none on a path too small on screen to fit them.
    private func dots() -> [(BezierPath.Corner, CGPoint)] {
        guard let n = single, n.kind == .path, let points = host.points(of: n.id), let frame = host.doc.absoluteFrame(of: n.id),
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
        let doc = host.doc
        guard let n = single, doc.canOffset(n.id), let outline = doc.outline(of: n.id),
              let frame = doc.absoluteFrame(of: n.id), min(frame.width, frame.height) * zoom >= 16 else { return nil }
        var t = toView
        guard let onScreen = outline.copy(using: &t) else { return nil }
        return (n.id, outline, onScreen)
    }

    private func isOnEdge(_ v: CGPoint) -> Bool {
        guard let e = edge() else { return false }
        return e.onScreen.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v)
    }

    // MARK: - The pointer

    /// A press at a point on screen with the select tool: on a corner dot, or on the edge with
    /// Option. False leaves it to the canvas.
    func down(at v: CGPoint, flags: PenFlags) -> Bool {
        self.flags = flags
        if let corner = dot(at: v), let n = single, let base = host.points(of: n.id) {
            host.beginGesture()
            drag = .corner(id: n.id, base: base, corner: corner, alone: flags.contains(.option))
            return true
        }
        if flags.contains(.option), isOnEdge(v), let e = edge() {
            host.beginGesture()
            drag = .offset(id: e.id, outline: e.outline, line: Outlines.samples(of: e.outline, every: max(0.5, 1 / zoom)), copy: nil, distance: 0)
            return true
        }
        return false
    }

    func drag(to v: CGPoint, flags: PenFlags) {
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
            host.setPoints(rounded, of: id, "Round Corners")
            if let frame = host.doc.absoluteFrame(of: id), let node = host.doc.node(id) {
                host.measure(.radius(applied[corner.at] ?? radius), Geometry.bounds(of: frame, rotation: node.rotation))
            }
        case .offset(let id, let outline, let line, let copy, _):
            // As far as the pointer is from the edge: out when outside the shape, in when inside.
            let nearest = line.map { hypot($0.0.x - p.x, $0.0.y - p.y) }.min() ?? 0
            let distance = (outline.contains(p) ? -nearest : nearest).rounded()
            var made = copy
            if distance == 0 {
                if let copy { host.edit("Outset") { _ = $0.detach(copy) } }
                made = nil
            } else {
                made = offsetCopy(of: id, by: distance, round: flags.contains(.shift), replacing: copy)
            }
            drag = .offset(id: id, outline: outline, line: line, copy: made, distance: distance)
            if let made, let frame = host.doc.absoluteFrame(of: made), let node = host.doc.node(made) {
                host.measure(distance > 0 ? .outset(abs(distance)) : .inset(abs(distance)), Geometry.bounds(of: frame, rotation: node.rotation))
            } else {
                host.measure(nil, .zero)
            }
        case nil:
            return
        }
        redraw()
    }

    /// A copy of the layer with its outline further out, behind it, or further in, in front of it,
    /// in place of `copy`: the copy, or nil when shrinking leaves nothing.
    private func offsetCopy(of id: UUID, by distance: CGFloat, round: Bool, replacing copy: UUID?) -> UUID? {
        guard host.doc.node(id) != nil, host.doc.outline(of: id) != nil else { return nil }
        let made = host.doc.offsetCopy(of: id, by: distance, round: round, as: copy ?? UUID())
        host.edit(distance >= 0 ? "Outset" : "Inset") { $0.place(offset: made, of: id, by: distance, replacing: copy) }
        return made?.id
    }

    func up() {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .corner:
            host.endGesture("Round Corners")
        case .offset(_, _, _, let copy, let distance):
            host.endGesture(distance > 0 ? "Outset" : "Inset")
            if let copy, host.doc.node(copy) != nil { host.selection = [copy] }
        }
        host.measure(nil, .zero)
        redraw()
    }

    func cancel() {
        guard drag != nil else { return }
        drag = nil
        host.cancelGesture()
        host.measure(nil, .zero)
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil); whether what shows changed.
    @discardableResult func hover(_ v: CGPoint?, flags: PenFlags) -> Bool {
        self.flags = flags
        var path = false, edge = false
        if let v, drag == nil, let n = single {
            if n.kind == .path, let outline = host.doc.line(of: n.id) {
                var t = toView
                if let onScreen = outline.copy(using: &t) {
                    path = onScreen.contains(v) || onScreen.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v)
                }
                // The dots themselves, which can lie just outside a corner bent inwards.
                if !path { path = dots().contains { hypot($0.1.x - v.x, $0.1.y - v.y) <= 10 } }
            }
            edge = flags.contains(.option) && isOnEdge(v)
        }
        guard path != onPath || edge != onEdge else { return false }
        onPath = path
        onEdge = edge
        redraw()
        return true
    }

    func pointer(at v: CGPoint) -> OutlinePointer? {
        if case .corner = drag { return .cross }
        if case .offset(_, _, let line, _, _) = drag { return Self.across(line, at: canvas(v)) }
        guard single != nil else { return nil }
        if dot(at: v) != nil { return .cross }
        if flags.contains(.option), isOnEdge(v), let e = edge() {
            return Self.across(Outlines.samples(of: e.outline, every: max(0.5, 1 / zoom)), at: canvas(v))
        }
        return nil
    }

    /// A two-headed arrow across the edge where it is nearest `p`: out and in.
    private static func across(_ line: [(CGPoint, CGPoint)], at p: CGPoint) -> OutlinePointer {
        guard let near = line.min(by: { hypot($0.0.x - p.x, $0.0.y - p.y) < hypot($1.0.x - p.x, $1.0.y - p.y) }) else { return .cross }
        let way = near.1
        return .across(atan2(way.x, -way.y) * 180 / .pi)
    }

    // MARK: - What shows

    /// What a canvas draws, on screen: the edge, lit with Option over it (2 points of the canvas's
    /// blue); and the corner dots (7 points, white with a blue ring), while the pointer is on the
    /// path or a corner is dragged.
    struct Marks {
        var edge: CGPath?
        var dots: [CGPoint] = []
    }

    func marks() -> Marks {
        var m = Marks()
        if onEdge, drag == nil, let e = edge() { m.edge = e.onScreen }
        let cornering: Bool = if case .corner = drag { true } else { false }
        if onPath || cornering { m.dots = dots().map(\.1) }
        return m
    }
}
