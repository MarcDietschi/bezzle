import Foundation
import CoreGraphics

/// A layer turned in depth, as if it were a card held up off the page: where each point of it,
/// drawn flat, shows. It is seen from straight in front of its own middle, as CSS's
/// `perspective()` sees a layer, so its middle stays where it is, and it looks the same wherever
/// it lies. Turned and brought nearer, a layer is still flat, so the whole of it moves alike: a
/// homography of its plane, which this is.
nonisolated struct Perspective {
    /// Where it is seen around, in the layer's parent: the middle of its frame.
    let center: CGPoint
    /// From a point drawn flat, measured from the middle, to where it shows, as homogeneous
    /// coordinates: rows of three.
    private let m: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    let distance: CGFloat

    /// How far in front of a layer it is seen from: twice as far as it is big, as a card is held
    /// to look at, so a small one shows as much depth as a large one, and no turn ever brings part
    /// of it up to the eye; never nearer than 600 points, so a small thing is not distorted.
    static func viewingDistance(for node: Node) -> CGFloat {
        max(600, max(node.frame.width, node.frame.height) * 2)
    }

    /// Nil for a layer that lies flat in the page, which is drawn as it always was. Artboards are the page.
    init?(_ node: Node, distance: CGFloat? = nil) {
        guard let t = node.transform3D, !node.isArtboard, t.x != 0 || t.y != 0 || t.z != 0 else { return nil }
        self.init(t, center: node.frame.center, distance: distance ?? Self.viewingDistance(for: node))
    }

    init(_ t: Transform3D, center: CGPoint, distance d: CGFloat) {
        self.center = center
        self.distance = d
        let a = CGFloat(t.x * .pi / 180), b = CGFloat(t.y * .pi / 180)
        let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
        // Turned about the vertical axis, then the horizontal one: the rows of that turn, of
        // which a point in the page (its depth nothing) needs the first two columns.
        let r11 = cb, r12: CGFloat = 0
        let r21 = sa * sb, r22 = ca
        let r31 = -ca * sb, r32 = sa
        // Never so near that the layer reaches the eye.
        let z = min(t.z, d * 0.4)
        m = (d * r11, d * r12, 0, d * r21, d * r22, 0, -r31, -r32, d - z)
    }

    /// Where a point drawn flat, in the layer's parent, shows.
    func shown(_ p: CGPoint) -> CGPoint {
        let u = p.x - center.x, v = p.y - center.y
        let x = m.0 * u + m.1 * v + m.2, y = m.3 * u + m.4 * v + m.5
        // Never behind the eye: what would be is pressed against it.
        let w = max(m.6 * u + m.7 * v + m.8, distance * 0.02)
        return CGPoint(x: center.x + x / w, y: center.y + y / w)
    }

    /// Where on the layer drawn flat a point that shows lies: what is under the pointer. Nil
    /// where nothing of its plane shows, past its horizon.
    func flat(_ p: CGPoint) -> CGPoint? {
        let sx = p.x - center.x, sy = p.y - center.y
        // shown = (row 1, row 2) / row 3, two equations in the two unknowns.
        let a = m.0 - sx * m.6, b = m.1 - sx * m.7, e = sx * m.8 - m.2
        let c = m.3 - sy * m.6, d = m.4 - sy * m.7, f = sy * m.8 - m.5
        let det = a * d - b * c
        guard abs(det) > 1e-9 else { return nil }
        let u = (e * d - b * f) / det, v = (a * f - e * c) / det
        guard m.6 * u + m.7 * v + m.8 > distance * 0.02 else { return nil }
        return CGPoint(x: center.x + u, y: center.y + v)
    }

    /// How many times bigger the layer shows at a point drawn flat than it is drawn, at most:
    /// what a picture of it has to be made at to stay sharp there.
    func magnification(at p: CGPoint) -> CGFloat {
        let w = max(m.6 * (p.x - center.x) + m.7 * (p.y - center.y) + m.8, distance * 0.02)
        return distance / w
    }

    /// The upright rectangle around a rectangle drawn flat, as it shows.
    func bounds(of r: CGRect) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(shown)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Where a point drawn flat in a layer's parent shows, the layer turned in depth or not.
    static func shown(_ p: CGPoint, of node: Node) -> CGPoint {
        Perspective(node)?.shown(p) ?? p
    }

    static func flat(_ p: CGPoint, of node: Node) -> CGPoint? {
        guard let perspective = Perspective(node) else { return p }
        return perspective.flat(p)
    }

    /// A layer's four corners as it shows, in its parent: turned in the page, then in depth.
    static func corners(of node: Node) -> [CGPoint] {
        let flat = Geometry.corners(of: node.frame, rotation: node.rotation)
        guard let perspective = Perspective(node) else { return flat }
        return flat.map(perspective.shown)
    }
}

nonisolated extension BezzleDocument {
    /// Where a point given in what `id` holds shows on the canvas: moved by its frame and by
    /// each artboard's and group's above it, and turned in depth with any that is.
    func shown(_ p: CGPoint, inside id: UUID) -> CGPoint {
        guard let container = node(id) else { return p }
        return (ancestors(of: id) + [container]).reversed().reduce(p) { q, c in Perspective.shown(q + c.frame.origin, of: c) }
    }

    /// The other way: a point of the canvas in what `id` holds. Nil where that is seen edge on.
    func placed(_ p: CGPoint, inside id: UUID) -> CGPoint? {
        guard let container = node(id) else { return p }
        var q = p
        for c in ancestors(of: id) + [container] {
            guard let flat = Perspective.flat(q, of: c) else { return nil }
            q = flat - c.frame.origin
        }
        return q
    }

    /// The same for what a layer lies in, or the canvas itself.
    func shown(_ p: CGPoint, inParentOf id: UUID) -> CGPoint {
        parent(of: id).map { shown(p, inside: $0.id) } ?? p
    }

    func placed(_ p: CGPoint, inParentOf id: UUID) -> CGPoint? {
        parent(of: id).map { placed(p, inside: $0.id) } ?? p
    }

    /// Whether anything a layer lies in is turned in depth, so that it shows somewhere other than its frame says.
    func liesInDepth(_ id: UUID) -> Bool {
        ancestors(of: id).contains { Perspective($0) != nil }
    }
}
