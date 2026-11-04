import Foundation
import CoreGraphics

/// A layer turned in depth, as if it were a card held up off the page: where each point of it,
/// drawn flat, shows. It is seen from straight in front of its own middle, as CSS's
/// `perspective()` sees a layer, so its middle stays where it is, and it looks the same wherever
/// it lies. Turned and brought nearer, a layer is still flat, so the whole of it moves alike: a
/// homography of its plane, which this is. A layer pinned by its corners, as a mockup's screen is
/// laid onto a photo, is one too, made from where the corners go, and is turned after.
nonisolated struct Perspective {
    /// Where it is seen around, in the layer's parent: the middle of its frame.
    let center: CGPoint
    /// From a point drawn flat, measured from the middle, to where it shows, as homogeneous
    /// coordinates: rows of three.
    private let m: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    let distance: CGFloat
    /// How near the eye anything of it may come, as the third homogeneous coordinate.
    private let nearest: CGFloat
    /// Pinned by its corners, which changes how big it shows from place to place.
    private let pinned: Bool

    /// How far in front of a layer it is seen from: twice as far as it is big, as a card is held
    /// to look at, so a small one shows as much depth as a large one, and no turn ever brings part
    /// of it up to the eye; never nearer than 600 points, so a small thing is not distorted.
    static func viewingDistance(for node: Node) -> CGFloat {
        max(600, max(node.frame.width, node.frame.height) * 2)
    }

    /// Nil for a layer that lies flat in the page, which is drawn as it always was. Artboards are the page.
    init?(_ node: Node, distance: CGFloat? = nil) {
        guard let t = node.transform3D, !node.isArtboard, t.x != 0 || t.y != 0 || t.z != 0 || t.pinned else { return nil }
        self.init(t, frame: node.frame, distance: distance ?? Self.viewingDistance(for: node))
    }

    init(_ t: Transform3D, center: CGPoint, distance d: CGFloat) {
        self.center = center
        self.distance = d
        m = Self.turn(t, distance: d)
        nearest = d * 0.02
        pinned = false
    }

    /// A layer pinned by its corners into `frame`, then turned.
    init(_ t: Transform3D, frame: CGRect, distance d: CGFloat) {
        guard t.pinned, let corners = t.corners, let pin = Self.pin(corners, size: frame.size) else {
            self = Perspective(t, center: frame.center, distance: d)
            return
        }
        center = frame.center
        distance = d
        let turned = Self.multiply(Self.turn(t, distance: d), pin)
        // Its middle in front of the eye, whichever way round the corners were given.
        m = turned.8 < 0 ? Self.scaled(turned, -1) : turned
        nearest = abs(m.8) * 0.02 * d / max(d - min(t.z, d * 0.4), 1)
        pinned = true
    }

    private typealias Matrix = (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)

    /// Turned about the vertical axis, then the horizontal one, and brought nearer.
    private static func turn(_ t: Transform3D, distance d: CGFloat) -> Matrix {
        let a = CGFloat(t.x * .pi / 180), b = CGFloat(t.y * .pi / 180)
        let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
        // The rows of that turn, of which a point in the page (its depth nothing) needs the
        // first two columns.
        let r11 = cb, r12: CGFloat = 0
        let r21 = sa * sb, r22 = ca
        let r31 = -ca * sb, r32 = sa
        // Never so near that the layer reaches the eye.
        let z = min(t.z, d * 0.4)
        return (d * r11, d * r12, 0, d * r21, d * r22, 0, -r31, -r32, d - z)
    }

    /// From a point of a layer of `size`, measured from its middle, to where its corners are
    /// pinned, measured from the same middle: the square-to-quadrilateral mapping, Heckbert's.
    /// Nil when three corners lie on a line, which shows nothing.
    private static func pin(_ corners: [CGPoint], size: CGSize) -> Matrix? {
        guard corners.count == 4, size.width > 0, size.height > 0 else { return nil }
        let q = corners.map { CGPoint(x: ($0.x - 0.5) * size.width, y: ($0.y - 0.5) * size.height) }
        let dx1 = q[1].x - q[2].x, dx2 = q[3].x - q[2].x, dx3 = q[0].x - q[1].x + q[2].x - q[3].x
        let dy1 = q[1].y - q[2].y, dy2 = q[3].y - q[2].y, dy3 = q[0].y - q[1].y + q[2].y - q[3].y
        var g: CGFloat = 0, h: CGFloat = 0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let det = dx1 * dy2 - dx2 * dy1
            guard abs(det) > 1e-9 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        // From the unit square (s, t) to the corners.
        let square: Matrix = (q[1].x - q[0].x + g * q[1].x, q[3].x - q[0].x + h * q[3].x, q[0].x,
                              q[1].y - q[0].y + g * q[1].y, q[3].y - q[0].y + h * q[3].y, q[0].y,
                              g, h, 1)
        // From the layer's own points to the unit square.
        let unit: Matrix = (1 / size.width, 0, 0.5, 0, 1 / size.height, 0.5, 0, 0, 1)
        let out = multiply(square, unit)
        let det = out.0 * (out.4 * out.8 - out.5 * out.7) - out.1 * (out.3 * out.8 - out.5 * out.6) + out.2 * (out.3 * out.7 - out.4 * out.6)
        return abs(det) > 1e-12 && det.isFinite ? out : nil
    }

    private static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix {
        (a.0 * b.0 + a.1 * b.3 + a.2 * b.6, a.0 * b.1 + a.1 * b.4 + a.2 * b.7, a.0 * b.2 + a.1 * b.5 + a.2 * b.8,
         a.3 * b.0 + a.4 * b.3 + a.5 * b.6, a.3 * b.1 + a.4 * b.4 + a.5 * b.7, a.3 * b.2 + a.4 * b.5 + a.5 * b.8,
         a.6 * b.0 + a.7 * b.3 + a.8 * b.6, a.6 * b.1 + a.7 * b.4 + a.8 * b.7, a.6 * b.2 + a.7 * b.5 + a.8 * b.8)
    }

    private static func scaled(_ a: Matrix, _ k: CGFloat) -> Matrix {
        (a.0 * k, a.1 * k, a.2 * k, a.3 * k, a.4 * k, a.5 * k, a.6 * k, a.7 * k, a.8 * k)
    }

    /// Where a point drawn flat, in the layer's parent, shows.
    func shown(_ p: CGPoint) -> CGPoint {
        let u = p.x - center.x, v = p.y - center.y
        let x = m.0 * u + m.1 * v + m.2, y = m.3 * u + m.4 * v + m.5
        // Never behind the eye: what would be is pressed against it.
        let w = max(m.6 * u + m.7 * v + m.8, nearest)
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
        guard m.6 * u + m.7 * v + m.8 > nearest else { return nil }
        return CGPoint(x: center.x + u, y: center.y + v)
    }

    /// How many times bigger the layer shows at a point drawn flat than it is drawn, at most:
    /// what a picture of it has to be made at to stay sharp there.
    func magnification(at p: CGPoint) -> CGFloat {
        let u = p.x - center.x, v = p.y - center.y
        let w = max(m.6 * u + m.7 * v + m.8, nearest)
        guard pinned else { return distance / w }
        // How far a step along the layer goes where it shows, the longer of the two ways.
        let x = m.0 * u + m.1 * v + m.2, y = m.3 * u + m.4 * v + m.5
        let xu = (m.0 * w - x * m.6) / (w * w), xv = (m.1 * w - x * m.7) / (w * w)
        let yu = (m.3 * w - y * m.6) / (w * w), yv = (m.4 * w - y * m.7) / (w * w)
        return max(hypot(xu, yu), hypot(xv, yv))
    }

    /// The upright rectangle around a rectangle drawn flat, as it shows.
    func bounds(of r: CGRect) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(shown)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// An outline drawn flat, as it shows. A turn in depth keeps straight lines straight, so they
    /// are carried by their ends; curves it bends, so they are followed in short straight steps.
    func shown(_ path: CGPath) -> CGPath {
        let out = CGMutablePath()
        var last = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                out.move(to: shown(p[0]))
                last = p[0]
                start = p[0]
            case .addLineToPoint:
                out.addLine(to: shown(p[0]))
                last = p[0]
            case .addQuadCurveToPoint:
                let a = last
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    out.addLine(to: shown(CGPoint(x: u * u * a.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                                  y: u * u * a.y + 2 * u * t * p[0].y + t * t * p[1].y)))
                }
                last = p[1]
            case .addCurveToPoint:
                let a = last
                for i in 1...24 {
                    let t = CGFloat(i) / 24, u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * p[0].x + 3 * u * t * t * p[1].x + t * t * t * p[2].x
                    let y = u * u * u * a.y + 3 * u * u * t * p[0].y + 3 * u * t * t * p[1].y + t * t * t * p[2].y
                    out.addLine(to: shown(CGPoint(x: x, y: y)))
                }
                last = p[2]
            case .closeSubpath:
                out.closeSubpath()
                last = start
            @unknown default:
                break
            }
        }
        return out
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
