import Foundation

// CGPath kept in Swift: its elements, as Core Graphics lists them. What only Skia knows how to do
// (outlines of strokes, dashes, union and difference) goes to the page.

nonisolated public enum CGPathElementType: Int32, Sendable {
    case moveToPoint, addLineToPoint, addQuadCurveToPoint, addCurveToPoint, closeSubpath
}

nonisolated public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>
}

nonisolated public enum CGPathFillRule: Int32, Sendable { case winding, evenOdd }
nonisolated public enum CGLineJoin: Int32, Sendable { case miter, round, bevel }
nonisolated public enum CGLineCap: Int32, Sendable { case butt, round, square }

nonisolated public class CGPath: Equatable, Hashable, @unchecked Sendable {
    public internal(set) var types: [CGPathElementType] = []
    /// One point per line and move, two per quad curve, three per curve.
    public internal(set) var points: [CGPoint] = []

    public init() {}

    init(types: [CGPathElementType], points: [CGPoint]) {
        self.types = types
        self.points = points
    }

    public static func == (a: CGPath, b: CGPath) -> Bool { a.types == b.types && a.points == b.points }
    public func hash(into h: inout Hasher) {
        h.combine(types.count)
        h.combine(points.count)
        if let p = points.first { h.combine(p.x); h.combine(p.y) }
    }

    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        appendRect(rect, transform?.pointee ?? .identity)
    }

    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        appendEllipse(rect, transform?.pointee ?? .identity)
    }

    public convenience init(roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: UnsafePointer<CGAffineTransform>?) {
        self.init()
        appendRoundedRect(rect, cornerWidth, cornerHeight, transform?.pointee ?? .identity)
    }

    // MARK: Reading

    public var isEmpty: Bool { types.isEmpty }

    public var currentPoint: CGPoint {
        guard let last = types.last else { return .zero }
        if last == .closeSubpath { return subpathStart() }
        return points.last ?? .zero
    }

    /// Where the subpath being added to began.
    func subpathStart() -> CGPoint {
        var k = 0, start = CGPoint.zero
        for t in types {
            if t == .moveToPoint { start = points[k] }
            k += Self.count(t)
        }
        return start
    }

    static func count(_ t: CGPathElementType) -> Int {
        switch t {
        case .moveToPoint, .addLineToPoint: 1
        case .addQuadCurveToPoint: 2
        case .addCurveToPoint: 3
        case .closeSubpath: 0
        }
    }

    public func applyWithBlock(_ block: (UnsafePointer<CGPathElement>) -> Void) {
        let buffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: 3)
        defer { buffer.deallocate() }
        var k = 0
        for t in types {
            let n = Self.count(t)
            for i in 0..<n { buffer[i] = points[k + i] }
            k += n
            var element = CGPathElement(type: t, points: buffer)
            withUnsafePointer(to: &element) { block($0) }
        }
    }

    /// Every point, control points too.
    public var boundingBox: CGRect {
        guard !points.isEmpty else { return .null }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Only where the path goes: curves by their extremes.
    public var boundingBoxOfPath: CGRect {
        guard !points.isEmpty else { return .null }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func add(_ p: CGPoint) { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        var k = 0, current = CGPoint.zero, start = CGPoint.zero
        for t in types {
            switch t {
            case .moveToPoint:
                current = points[k]; start = current
                // A move alone draws nothing, but Core Graphics counts it all the same.
                add(current)
            case .addLineToPoint:
                current = points[k]; add(current)
            case .addQuadCurveToPoint:
                let c = points[k], e = points[k + 1]
                for s in Self.quadExtremes(current, c, e) { add(Self.quad(current, c, e, s)) }
                add(e); current = e
            case .addCurveToPoint:
                let c1 = points[k], c2 = points[k + 1], e = points[k + 2]
                for s in Self.cubicExtremes(current, c1, c2, e) { add(Self.cubic(current, c1, c2, e, s)) }
                add(e); current = e
            case .closeSubpath:
                current = start
            }
            k += Self.count(t)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    static func quadExtremes(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint) -> [CGFloat] {
        var out: [CGFloat] = []
        for (a, b, e) in [(p0.x, c.x, p1.x), (p0.y, c.y, p1.y)] {
            let den = a - 2 * b + e
            if abs(den) > 1e-12 { let t = (a - b) / den; if t > 0 && t < 1 { out.append(t) } }
        }
        return out
    }

    static func cubicExtremes(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) -> [CGFloat] {
        var out: [CGFloat] = []
        for (a, b, c, d) in [(p0.x, c1.x, c2.x, p1.x), (p0.y, c1.y, c2.y, p1.y)] {
            // The derivative's roots: 3(-a + 3b - 3c + d)t² + 6(a - 2b + c)t + 3(b - a).
            let qa = -a + 3 * b - 3 * c + d, qb = 2 * (a - 2 * b + c), qc = b - a
            if abs(qa) < 1e-12 {
                if abs(qb) > 1e-12 { let t = -qc / qb; if t > 0 && t < 1 { out.append(t) } }
                continue
            }
            let disc = qb * qb - 4 * qa * qc
            guard disc >= 0 else { continue }
            let s = sqrt(disc)
            for t in [(-qb + s) / (2 * qa), (-qb - s) / (2 * qa)] where t > 0 && t < 1 { out.append(t) }
        }
        return out
    }

    /// The path as straight lines, curves cut into short ones.
    func polygons(tolerance: CGFloat = 0.1) -> [[CGPoint]] {
        var out: [[CGPoint]] = [], poly: [CGPoint] = []
        var k = 0, current = CGPoint.zero
        func steps(_ length: CGFloat) -> Int { max(2, min(1024, Int((length / max(tolerance * 8, 1e-6)).squareRoot().rounded(.up)) * 2)) }
        for t in types {
            switch t {
            case .moveToPoint:
                if poly.count > 1 { out.append(poly) }
                current = points[k]; poly = [current]
            case .addLineToPoint:
                current = points[k]; poly.append(current)
            case .addQuadCurveToPoint:
                let c = points[k], e = points[k + 1]
                let n = steps(hypot(c.x - current.x, c.y - current.y) + hypot(e.x - c.x, e.y - c.y))
                for i in 1...n { poly.append(Self.quad(current, c, e, CGFloat(i) / CGFloat(n))) }
                current = e
            case .addCurveToPoint:
                let c1 = points[k], c2 = points[k + 1], e = points[k + 2]
                let n = steps(hypot(c1.x - current.x, c1.y - current.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(e.x - c2.x, e.y - c2.y))
                for i in 1...n { poly.append(Self.cubic(current, c1, c2, e, CGFloat(i) / CGFloat(n))) }
                current = e
            case .closeSubpath:
                if poly.count > 1 { out.append(poly) }
                current = poly.first ?? current
                poly = [current]
            }
            k += Self.count(t)
        }
        if poly.count > 1 { out.append(poly) }
        return out
    }

    public func contains(_ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity) -> Bool {
        let p = point.applying(transform.inverted())
        var winding = 0, crossings = 0
        // Cut fine, so a point just inside a curve is inside, as Core Graphics finds it.
        for poly in polygons(tolerance: 1e-5) {
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if a.y <= p.y {
                    if b.y > p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1; crossings += 1 }
                } else if b.y <= p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1; crossings += 1
                }
            }
        }
        return rule == .winding ? winding != 0 : crossings % 2 == 1
    }

    // MARK: Copies

    public func copy() -> CGPath? { CGPath(types: types, points: points) }

    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        let t = transform?.pointee ?? .identity
        return CGPath(types: types, points: t.isIdentity ? points : points.map { $0.applying(t) })
    }

    public func mutableCopy() -> CGMutablePath? {
        let m = CGMutablePath()
        m.types = types
        m.points = points
        return m
    }

    public func mutableCopy(using transform: UnsafePointer<CGAffineTransform>?) -> CGMutablePath? {
        let m = CGMutablePath()
        m.types = types
        let t = transform?.pointee ?? .identity
        m.points = t.isIdentity ? points : points.map { $0.applying(t) }
        return m
    }

    public func copy(strokingWithWidth width: CGFloat, lineCap: CGLineCap, lineJoin: CGLineJoin, miterLimit: CGFloat,
                     transform: CGAffineTransform = .identity) -> CGPath {
        // Skia's path operations drop an outline thinner than about a hundredth of a point as
        // nothing, where Core Graphics keeps it: the knife's blade is a thousandth wide.
        let out = Skia.op(.stroke, self, nil, params: [Double(max(width, 0.02)), Double(lineCap.rawValue), Double(lineJoin.rawValue), Double(miterLimit)])
        return transform.isIdentity ? out : (out.copy(using: [transform]) ?? out)
    }

    public func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat], transform: CGAffineTransform = .identity) -> CGPath {
        let out = Skia.op(.dash, self, nil, params: [Double(phase)] + lengths.map { Double($0) })
        return transform.isIdentity ? out : (out.copy(using: [transform]) ?? out)
    }

    public func union(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { Skia.op(.union, self, other, rule: rule) }
    public func intersection(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { Skia.op(.intersect, self, other, rule: rule) }
    public func subtracting(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { Skia.op(.difference, self, other, rule: rule) }
    public func symmetricDifference(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { Skia.op(.xor, self, other, rule: rule) }
    public func normalized(using rule: CGPathFillRule = .winding) -> CGPath { Skia.op(.simplify, self, nil, rule: rule) }
    public func intersects(_ other: CGPath, using rule: CGPathFillRule = .winding) -> Bool { !intersection(other, using: rule).isEmpty }

    /// Lines of this path that lie inside `other`, and outside it. Skia has neither; for now the
    /// line is cut only by the other's bounding box.
    public func lineIntersection(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { self }
    public func lineSubtracting(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath { self }

    public func flattened(threshold: CGFloat) -> CGPath {
        let m = CGMutablePath()
        for poly in polygons(tolerance: threshold) { m.addLines(between: poly) }
        return m
    }

    public func componentsSeparated(using rule: CGPathFillRule = .winding) -> [CGPath] {
        var out: [CGPath] = []
        var k = 0, current: CGMutablePath?
        for t in types {
            if t == .moveToPoint {
                if let current { out.append(current) }
                current = CGMutablePath()
            }
            let n = Self.count(t)
            current?.types.append(t)
            current?.points.append(contentsOf: points[k..<(k + n)])
            k += n
        }
        if let current { out.append(current) }
        return out
    }

    // MARK: Adding

    func append(_ t: CGPathElementType, _ p: [CGPoint]) {
        types.append(t)
        points.append(contentsOf: p)
    }

    func appendRect(_ r: CGRect, _ t: CGAffineTransform) {
        let r = r.standardized
        append(.moveToPoint, [CGPoint(x: r.minX, y: r.minY).applying(t)])
        append(.addLineToPoint, [CGPoint(x: r.maxX, y: r.minY).applying(t)])
        append(.addLineToPoint, [CGPoint(x: r.maxX, y: r.maxY).applying(t)])
        append(.addLineToPoint, [CGPoint(x: r.minX, y: r.maxY).applying(t)])
        append(.closeSubpath, [])
    }

    static let kappa: CGFloat = 0.5522847498

    func appendEllipse(_ r: CGRect, _ t: CGAffineTransform) {
        let r = r.standardized
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2, kx = rx * Self.kappa, ky = ry * Self.kappa
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        append(.moveToPoint, [p(cx + rx, cy)])
        append(.addCurveToPoint, [p(cx + rx, cy + ky), p(cx + kx, cy + ry), p(cx, cy + ry)])
        append(.addCurveToPoint, [p(cx - kx, cy + ry), p(cx - rx, cy + ky), p(cx - rx, cy)])
        append(.addCurveToPoint, [p(cx - rx, cy - ky), p(cx - kx, cy - ry), p(cx, cy - ry)])
        append(.addCurveToPoint, [p(cx + kx, cy - ry), p(cx + rx, cy - ky), p(cx + rx, cy)])
        append(.closeSubpath, [])
    }

    func appendRoundedRect(_ r: CGRect, _ cw: CGFloat, _ ch: CGFloat, _ t: CGAffineTransform) {
        let r = r.standardized
        let w = min(max(cw, 0), r.width / 2), h = min(max(ch, 0), r.height / 2)
        guard w > 0, h > 0 else { appendRect(r, t); return }
        let kx = w * Self.kappa, ky = h * Self.kappa
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        append(.moveToPoint, [p(r.maxX, r.midY)])
        append(.addLineToPoint, [p(r.maxX, r.maxY - h)])
        append(.addCurveToPoint, [p(r.maxX, r.maxY - h + ky), p(r.maxX - w + kx, r.maxY), p(r.maxX - w, r.maxY)])
        append(.addLineToPoint, [p(r.minX + w, r.maxY)])
        append(.addCurveToPoint, [p(r.minX + w - kx, r.maxY), p(r.minX, r.maxY - h + ky), p(r.minX, r.maxY - h)])
        append(.addLineToPoint, [p(r.minX, r.minY + h)])
        append(.addCurveToPoint, [p(r.minX, r.minY + h - ky), p(r.minX + w - kx, r.minY), p(r.minX + w, r.minY)])
        append(.addLineToPoint, [p(r.maxX - w, r.minY)])
        append(.addCurveToPoint, [p(r.maxX - w + kx, r.minY), p(r.maxX, r.minY + h - ky), p(r.maxX, r.minY + h)])
        append(.closeSubpath, [])
    }

    /// An arc as curves of a quarter turn at most, from `start` to `end` in radians, the way given.
    /// An arc from `start` to `end`, in radians, the way given, as Core Graphics draws one: the
    /// way it goes taken as the angles say, past a whole turn too when the end is further on
    /// that way, and the rest of a turn when it lies back the other way.
    func appendArc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool, _ t: CGAffineTransform) {
        // Clockwise in Core Graphics' own space, y up: towards smaller angles.
        let d = clockwise ? start - end : end - start
        var sweep: CGFloat
        if d >= 0 {
            sweep = d
        } else {
            sweep = fmod(d, 2 * .pi)
            if sweep < 0 { sweep += 2 * .pi }
            if sweep == 0 { sweep = 2 * .pi }
        }
        appendSweep(center: center, radius: radius, start: start, sweep: clockwise ? -sweep : sweep, t)
    }

    func appendSweep(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, _ t: CGAffineTransform) {
        let first = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)).applying(t)
        if types.isEmpty || types.last == .closeSubpath { append(.moveToPoint, [first]) } else { append(.addLineToPoint, [first]) }
        appendCurves(center: center, radius: radius, start: start, sweep: sweep, t)
    }

    /// The curves of an arc, as Core Graphics makes them: a quarter turn each from its start,
    /// then one for what is left, when that is more than √ε of a radian.
    func appendCurves(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, _ t: CGAffineTransform) {
        let quarter = CGFloat.pi / 2, least = CGFloat.ulpOfOne.squareRoot(), way: CGFloat = sweep < 0 ? -1 : 1
        var left = abs(sweep), a = start
        func place(_ q: CGPoint) -> CGPoint { CGPoint(x: center.x + radius * q.x, y: center.y + radius * q.y).applying(t) }
        while left > least {
            let step = way * Swift.min(left, quarter), b = a + step
            let k = 4.0 / 3.0 * tan(step / 4)
            let p0 = CGPoint(x: cos(a), y: sin(a)), p1 = CGPoint(x: cos(b), y: sin(b))
            let c1 = CGPoint(x: p0.x - k * p0.y, y: p0.y + k * p0.x), c2 = CGPoint(x: p1.x + k * p1.y, y: p1.y - k * p1.x)
            append(.addCurveToPoint, [place(c1), place(c2), place(p1)])
            left -= abs(step)
            a = b
        }
    }
}

nonisolated public final class CGMutablePath: CGPath, @unchecked Sendable {
    public override init() { super.init() }

    public func move(to p: CGPoint, transform t: CGAffineTransform = .identity) { append(.moveToPoint, [p.applying(t)]) }

    public func addLine(to p: CGPoint, transform t: CGAffineTransform = .identity) {
        if types.isEmpty { append(.moveToPoint, [p.applying(t)]); return }
        append(.addLineToPoint, [p.applying(t)])
    }

    public func addLines(between list: [CGPoint], transform t: CGAffineTransform = .identity) {
        guard let first = list.first else { return }
        append(.moveToPoint, [first.applying(t)])
        for p in list.dropFirst() { append(.addLineToPoint, [p.applying(t)]) }
    }

    public func addQuadCurve(to p: CGPoint, control: CGPoint, transform t: CGAffineTransform = .identity) {
        append(.addQuadCurveToPoint, [control.applying(t), p.applying(t)])
    }

    public func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint, transform t: CGAffineTransform = .identity) {
        append(.addCurveToPoint, [control1.applying(t), control2.applying(t), p.applying(t)])
    }

    public func closeSubpath() {
        guard !types.isEmpty, types.last != .closeSubpath else { return }
        append(.closeSubpath, [])
    }

    public func addRect(_ r: CGRect, transform t: CGAffineTransform = .identity) { appendRect(r, t) }
    public func addRects(_ rs: [CGRect], transform t: CGAffineTransform = .identity) { for r in rs { appendRect(r, t) } }
    public func addEllipse(in r: CGRect, transform t: CGAffineTransform = .identity) { appendEllipse(r, t) }

    public func addRoundedRect(in r: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform t: CGAffineTransform = .identity) {
        appendRoundedRect(r, cornerWidth, cornerHeight, t)
    }

    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool,
                       transform t: CGAffineTransform = .identity) {
        appendArc(center: center, radius: radius, start: startAngle, end: endAngle, clockwise: clockwise, t)
    }

    public func addRelativeArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, delta: CGFloat, transform t: CGAffineTransform = .identity) {
        appendSweep(center: center, radius: radius, start: startAngle, sweep: delta, t)
    }

    /// The arc of `radius` that meets the line from the current point to `tangent1End` and the
    /// line from there to `tangent2End`, with a line to where it begins.
    public func addArc(tangent1End p1: CGPoint, tangent2End p2: CGPoint, radius: CGFloat, transform t: CGAffineTransform = .identity) {
        // The current point is already placed; work back in the arc's own space.
        let back = t.inverted()
        let p0 = currentPoint.applying(back)
        let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y), v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
        // Begun at its own corner, Core Graphics draws a line there and curves that stay there, as
        // many as an arc turning from +x to the way out would take.
        if l1 == 0, radius > 0, l2 > 0 {
            let q = p1.applying(t)
            append(.addLineToPoint, [q])
            var left = abs(atan2(v2.y, v2.x))
            while left > CGFloat.ulpOfOne.squareRoot() {
                append(.addCurveToPoint, [q, q, q])
                left -= Swift.min(left, .pi / 2)
            }
            return
        }
        guard radius > 0, l1 > 0, l2 > 0 else { addLine(to: p1, transform: t); return }
        let u1 = CGPoint(x: v1.x / l1, y: v1.y / l1), u2 = CGPoint(x: v2.x / l2, y: v2.y / l2)
        let cosA = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
        let angle = acos(cosA)
        guard angle > 1e-6, angle < .pi - 1e-6 else { addLine(to: p1, transform: t); return }
        let dist = radius / tan(angle / 2)
        let t1 = CGPoint(x: p1.x + u1.x * dist, y: p1.y + u1.y * dist), t2 = CGPoint(x: p1.x + u2.x * dist, y: p1.y + u2.y * dist)
        let bis = CGPoint(x: u1.x + u2.x, y: u1.y + u2.y), bl = hypot(bis.x, bis.y)
        let reach = radius / sin(angle / 2)
        let c = CGPoint(x: p1.x + bis.x / bl * reach, y: p1.y + bis.y / bl * reach)
        let a0 = atan2(t1.y - c.y, t1.x - c.x), a1 = atan2(t2.y - c.y, t2.x - c.x)
        var sweep = a1 - a0
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        append(.addLineToPoint, [t1.applying(t)])
        appendCurves(center: c, radius: radius, start: a0, sweep: sweep, t)
    }

    public func addPath(_ path: CGPath, transform t: CGAffineTransform = .identity) {
        types.append(contentsOf: path.types)
        points.append(contentsOf: t.isIdentity ? path.points : path.points.map { $0.applying(t) })
    }
}

// MARK: Skia's path operations, in the page

nonisolated public enum Skia {
    public enum Op: Int {
        case union = 1, intersect, difference, xor, simplify, stroke, dash
    }

    /// Paths as the page reads them: CanvasKit's verbs, each followed by its points.
    public static func encode(_ path: CGPath, into out: inout [Double]) {
        var k = 0
        for t in path.types {
            switch t {
            case .moveToPoint: out.append(0)
            case .addLineToPoint: out.append(1)
            case .addQuadCurveToPoint: out.append(2)
            case .addCurveToPoint: out.append(4)
            case .closeSubpath: out.append(5)
            }
            for i in 0..<CGPath.count(t) { out.append(Double(path.points[k + i].x)); out.append(Double(path.points[k + i].y)) }
            k += CGPath.count(t)
        }
    }

    public static func decode(_ v: ArraySlice<Double>) -> CGMutablePath {
        let path = CGMutablePath()
        var i = v.startIndex
        func p() -> CGPoint { defer { i += 2 }; return CGPoint(x: v[i], y: v[i + 1]) }
        while i < v.endIndex {
            let verb = v[i]; i += 1
            switch verb {
            case 0: path.append(.moveToPoint, [p()])
            case 1: path.append(.addLineToPoint, [p()])
            case 2: let c = p(), e = p(); path.append(.addQuadCurveToPoint, [c, e])
            case 3:
                // A conic, as Skia makes for round caps and joins: as near as a curve comes to it.
                let start = path.currentPoint, c = p(), e = p()
                let w = v[i]; i += 1
                let k = 4 * w / (3 * (1 + w))
                path.append(.addCurveToPoint, [CGPoint(x: start.x + (c.x - start.x) * k, y: start.y + (c.y - start.y) * k),
                                               CGPoint(x: e.x + (c.x - e.x) * k, y: e.y + (c.y - e.y) * k), e])
            case 4: let c1 = p(), c2 = p(), e = p(); path.append(.addCurveToPoint, [c1, c2, e])
            case 5: path.append(.closeSubpath, [])
            default: return path
            }
        }
        return path
    }

    static func op(_ op: Op, _ a: CGPath, _ b: CGPath?, rule: CGPathFillRule = .winding, params: [Double] = []) -> CGPath {
        var a1: [Double] = [], b1: [Double] = []
        encode(a, into: &a1)
        if let b { encode(b, into: &b1) }
        let message = [Double(op.rawValue), Double(rule.rawValue), Double(a1.count)] + a1 + [Double(b1.count)] + b1 + [Double(params.count)] + params
        return decode(Host.call(.pathOp, doubles: message)[...])
    }
}
