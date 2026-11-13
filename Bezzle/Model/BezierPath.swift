import CoreGraphics
import Foundation

/// An outline as the points it runs through, each with the handles that pull the curves on
/// either side of it: what the pen puts down and point editing moves. Read from the SVG path
/// data a path layer keeps, and written back to it.
nonisolated struct BezierPath: Equatable {
    struct Anchor: Equatable {
        var point: CGPoint
        /// The handle pulling the curve that arrives here; nil when it arrives straight.
        var handleIn: CGPoint?
        /// The handle pulling the curve that leaves; nil when it leaves straight.
        var handleOut: CGPoint?

        init(_ point: CGPoint, in handleIn: CGPoint? = nil, out handleOut: CGPoint? = nil) {
            self.point = point
            self.handleIn = handleIn
            self.handleOut = handleOut
        }

        /// The handle on one side: `out` for the curve leaving.
        func handle(out: Bool) -> CGPoint? { out ? handleOut : handleIn }

        mutating func setHandle(out: Bool, _ p: CGPoint?) {
            if out { handleOut = p } else { handleIn = p }
        }

        /// The same anchor moved by `d`, its handles with it.
        func offset(by d: CGPoint) -> Anchor {
            Anchor(point + d, in: handleIn.map { $0 + d }, out: handleOut.map { $0 + d })
        }
    }

    /// One unbroken run of the outline.
    struct Subpath: Equatable {
        var anchors: [Anchor]
        /// Whether the run comes back round from its last anchor to its first.
        var closed = false

        /// How many curves or lines join the anchors.
        var segmentCount: Int { anchors.isEmpty ? 0 : closed ? anchors.count : anchors.count - 1 }

        /// Where an anchor's neighbours are along the run, nil past an open end.
        func before(_ i: Int) -> Int? { i > 0 ? i - 1 : closed && anchors.count > 1 ? anchors.count - 1 : nil }
        func after(_ i: Int) -> Int? { i < anchors.count - 1 ? i + 1 : closed && anchors.count > 1 ? 0 : nil }
    }

    var subpaths: [Subpath] = []

    init(subpaths: [Subpath] = []) { self.subpaths = subpaths }

    init(_ data: String) { self.init(PathData.cgPath(data)) }

    init(_ path: CGPath) {
        var runs: [Subpath] = []
        var current: Subpath?
        var start = CGPoint.zero
        // After a close, a line or curve starts a new run where the closed one began.
        func open() -> Subpath { current ?? Subpath(anchors: [Anchor(start)]) }
        path.applyWithBlock { element in
            let e = element.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                if let c = current { runs.append(c) }
                current = Subpath(anchors: [Anchor(pts[0])])
                start = pts[0]
            case .addLineToPoint:
                var c = open()
                c.anchors.append(Anchor(pts[0]))
                current = c
            case .addQuadCurveToPoint:
                // A quadratic curve is the cubic whose handles lie two thirds of the way to its one control.
                var c = open()
                let p0 = c.anchors[c.anchors.count - 1].point, q = pts[0], p = pts[1]
                let k: CGFloat = 2.0 / 3.0
                let c1 = CGPoint(x: p0.x + (q.x - p0.x) * k, y: p0.y + (q.y - p0.y) * k)
                let c2 = CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)
                c.anchors[c.anchors.count - 1].handleOut = c1
                c.anchors.append(Anchor(p, in: c2))
                current = c
            case .addCurveToPoint:
                var c = open()
                c.anchors[c.anchors.count - 1].handleOut = pts[0]
                c.anchors.append(Anchor(pts[2], in: pts[1]))
                current = c
            case .closeSubpath:
                guard var c = current else { break }
                // A run that ends where it began has that anchor once, with both its handles.
                if c.anchors.count > 1, let last = c.anchors.last, Self.same(last.point, c.anchors[0].point) {
                    c.anchors[0].handleIn = last.handleIn
                    c.anchors.removeLast()
                }
                c.closed = true
                runs.append(c)
                current = nil
            @unknown default:
                break
            }
        }
        if let c = current { runs.append(c) }
        // A handle lying on its anchor pulls nothing.
        for s in runs.indices {
            for i in runs[s].anchors.indices {
                let a = runs[s].anchors[i]
                if let h = a.handleIn, Self.same(h, a.point) { runs[s].anchors[i].handleIn = nil }
                if let h = a.handleOut, Self.same(h, a.point) { runs[s].anchors[i].handleOut = nil }
            }
        }
        subpaths = runs
    }

    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }

    /// These points as path data keeps them, and reading it back gives: an open run has no handle
    /// into its first point or out of its last, and a handle on its anchor is none.
    var stored: BezierPath {
        var p = self
        for s in p.subpaths.indices {
            for i in p.subpaths[s].anchors.indices {
                let a = p.subpaths[s].anchors[i]
                if let h = a.handleIn, Self.same(h, a.point) { p.subpaths[s].anchors[i].handleIn = nil }
                if let h = a.handleOut, Self.same(h, a.point) { p.subpaths[s].anchors[i].handleOut = nil }
            }
            if !p.subpaths[s].closed, !p.subpaths[s].anchors.isEmpty {
                p.subpaths[s].anchors[0].handleIn = nil
                p.subpaths[s].anchors[p.subpaths[s].anchors.count - 1].handleOut = nil
            }
        }
        return p
    }

    // MARK: Writing

    var cgPath: CGPath {
        let path = CGMutablePath()
        for s in subpaths where !s.anchors.isEmpty {
            path.move(to: s.anchors[0].point)
            for i in 0..<s.segmentCount {
                let a = s.anchors[i], b = s.anchors[(i + 1) % s.anchors.count]
                if a.handleOut == nil && b.handleIn == nil {
                    // The straight way back round is the close itself.
                    if !(s.closed && i == s.anchors.count - 1) { path.addLine(to: b.point) }
                } else {
                    path.addCurve(to: b.point, control1: a.handleOut ?? a.point, control2: b.handleIn ?? b.point)
                }
            }
            if s.closed { path.closeSubpath() }
        }
        return path
    }

    /// As SVG path data.
    var data: String { PathData.string(cgPath) }

    /// The box the outline runs through, not counting handles that pull from outside it.
    var bounds: CGRect { cgPath.boundingBoxOfPath }

    func applying(_ t: CGAffineTransform) -> BezierPath {
        var p = self
        for s in p.subpaths.indices {
            p.subpaths[s].anchors = p.subpaths[s].anchors.map { a in
                Anchor(a.point.applying(t), in: a.handleIn?.applying(t), out: a.handleOut?.applying(t))
            }
        }
        return p
    }

    // MARK: Anchors

    subscript(p: PathPoint) -> Anchor {
        get { subpaths[p.subpath].anchors[p.index] }
        set { subpaths[p.subpath].anchors[p.index] = newValue }
    }

    func contains(_ p: PathPoint) -> Bool {
        subpaths.indices.contains(p.subpath) && subpaths[p.subpath].anchors.indices.contains(p.index)
    }

    var allPoints: [PathPoint] {
        subpaths.indices.flatMap { s in subpaths[s].anchors.indices.map { PathPoint(subpath: s, index: $0) } }
    }

    var anchorCount: Int { subpaths.reduce(0) { $0 + $1.anchors.count } }

    /// Whether an anchor ends an open run, so the pen can carry on from it.
    func isEnd(_ p: PathPoint) -> Bool {
        let s = subpaths[p.subpath]
        return !s.closed && (p.index == 0 || p.index == s.anchors.count - 1)
    }

    /// The four points of the curve from anchor `i` of a run to the next.
    func segment(_ subpath: Int, _ i: Int) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let s = subpaths[subpath], a = s.anchors[i], b = s.anchors[(i + 1) % s.anchors.count]
        return (a.point, a.handleOut ?? a.point, b.handleIn ?? b.point, b.point)
    }

    func isStraight(_ subpath: Int, _ i: Int) -> Bool {
        let s = subpaths[subpath]
        return s.anchors[i].handleOut == nil && s.anchors[(i + 1) % s.anchors.count].handleIn == nil
    }

    static func point(on c: (CGPoint, CGPoint, CGPoint, CGPoint), at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
        return CGPoint(x: a * c.0.x + b * c.1.x + d * c.2.x + e * c.3.x, y: a * c.0.y + b * c.1.y + d * c.2.y + e * c.3.y)
    }

    /// A place on the outline: which curve, how far along it, and where that is.
    struct Spot: Equatable {
        var subpath: Int
        var segment: Int
        var t: CGFloat
        var point: CGPoint
        var distance: CGFloat
    }

    /// The place on the outline nearest `p`. With `within`, curves further away than that are
    /// not looked along, which on a long outline saves the most time.
    func nearest(to p: CGPoint, within: CGFloat? = nil) -> Spot? {
        var best: Spot?
        for s in subpaths.indices {
            for i in 0..<subpaths[s].segmentCount {
                let c = segment(s, i)
                // A curve lies inside the box round its four points.
                if let within {
                    let xs = [c.0.x, c.1.x, c.2.x, c.3.x], ys = [c.0.y, c.1.y, c.2.y, c.3.y]
                    let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    if !box.insetBy(dx: -within, dy: -within).contains(p) { continue }
                }
                // A straight line is measured along itself, the way `insert` places a point on one.
                if isStraight(s, i) {
                    let a = c.0, d = c.3 - c.0
                    let len2 = d.x * d.x + d.y * d.y
                    let t = len2 > 0 ? min(max(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2, 0), 1) : 0
                    let q = a + d * t
                    let dist = hypot(q.x - p.x, q.y - p.y)
                    if best == nil || dist < best!.distance { best = Spot(subpath: s, segment: i, t: t, point: q, distance: dist) }
                    continue
                }
                func distance(_ t: CGFloat) -> CGFloat {
                    let q = Self.point(on: c, at: t)
                    return hypot(q.x - p.x, q.y - p.y)
                }
                // Sampled along the curve, then narrowed down about the closest sample.
                let steps = 32
                var t = CGFloat(0), d = distance(0)
                for k in 1...steps {
                    let tk = CGFloat(k) / CGFloat(steps), dk = distance(tk)
                    if dk < d { t = tk; d = dk }
                }
                var lo = max(0, t - 1 / CGFloat(steps)), hi = min(1, t + 1 / CGFloat(steps))
                for _ in 0..<16 {
                    let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                    if distance(m1) < distance(m2) { hi = m2 } else { lo = m1 }
                }
                let tf = (lo + hi) / 2, df = distance(tf)
                if df < d { t = tf; d = df }
                if best == nil || d < best!.distance {
                    best = Spot(subpath: s, segment: i, t: t, point: Self.point(on: c, at: t), distance: d)
                }
            }
        }
        return best
    }

    // MARK: Changing it

    /// Puts a new anchor on a curve `t` of the way along it, without changing the outline's
    /// shape, and returns where it went.
    @discardableResult
    mutating func insert(_ subpath: Int, segment i: Int, t: CGFloat) -> PathPoint {
        let count = subpaths[subpath].anchors.count
        let j = (i + 1) % count
        let added: Anchor
        if isStraight(subpath, i) {
            let (a, _, _, b) = segment(subpath, i)
            added = Anchor(a + (b - a) * t)
        } else {
            // Cut in two the way de Casteljau does: the handles either side shorten to fit.
            let (p0, c1, c2, p3) = segment(subpath, i)
            let p01 = p0 + (c1 - p0) * t, p12 = c1 + (c2 - c1) * t, p23 = c2 + (p3 - c2) * t
            let p012 = p01 + (p12 - p01) * t, p123 = p12 + (p23 - p12) * t
            let p = p012 + (p123 - p012) * t
            subpaths[subpath].anchors[i].handleOut = Self.same(p01, p0) ? nil : p01
            subpaths[subpath].anchors[j].handleIn = Self.same(p23, p3) ? nil : p23
            added = Anchor(p, in: Self.same(p012, p) ? nil : p012, out: Self.same(p123, p) ? nil : p123)
        }
        subpaths[subpath].anchors.insert(added, at: i + 1)
        return PathPoint(subpath: subpath, index: i + 1)
    }

    /// Takes anchors away, joining the ones either side. A run left with fewer than two goes too.
    mutating func remove(_ points: Set<PathPoint>) {
        for s in subpaths.indices.reversed() {
            for i in subpaths[s].anchors.indices.reversed() where points.contains(PathPoint(subpath: s, index: i)) {
                subpaths[s].anchors.remove(at: i)
            }
            if subpaths[s].anchors.count < 2 { subpaths.remove(at: s) }
        }
    }

    /// The run drawn the other way, so that its first anchor is its last.
    mutating func reverse(_ subpath: Int) {
        subpaths[subpath].anchors = subpaths[subpath].anchors.reversed().map { Anchor($0.point, in: $0.handleOut, out: $0.handleIn) }
    }

    /// Whether the outline runs through an anchor without a bend: its two handles in one line,
    /// or, at the end of an open run, the one handle there is.
    func isSmooth(_ p: PathPoint) -> Bool {
        let a = self[p], s = subpaths[p.subpath]
        switch (a.handleIn, a.handleOut) {
        case let (i?, o?):
            let u = i - a.point, v = o - a.point
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 0.0001, lv > 0.0001 else { return false }
            // Within two degrees of a straight line.
            return (u.x * v.x + u.y * v.y) / (lu * lv) < -0.9994
        case (nil, _?): return s.before(p.index) == nil
        case (_?, nil): return s.after(p.index) == nil
        case (nil, nil): return false
        }
    }

    /// A sharp corner: the handles taken away, so the lines either side run straight in.
    mutating func makeCorner(_ p: PathPoint) {
        self[p].handleIn = nil
        self[p].handleOut = nil
    }

    /// The handles lined up so the outline runs through smoothly: along the handles there are,
    /// or else along the way from the anchor before to the one after, a third of the way to each.
    mutating func makeSmooth(_ p: PathPoint) {
        let s = subpaths[p.subpath], a = s.anchors[p.index], at = a.point
        let prev = s.before(p.index).map { s.anchors[$0].point }, next = s.after(p.index).map { s.anchors[$0].point }
        var way: CGPoint = .zero
        if let i = a.handleIn, let o = a.handleOut { way = Self.unit(o - at) - Self.unit(i - at) }
        if Self.length(way) < 0.0001, let o = a.handleOut { way = o - at }
        if Self.length(way) < 0.0001, let i = a.handleIn { way = at - i }
        if Self.length(way) < 0.0001, let prev, let next { way = next - prev }
        if Self.length(way) < 0.0001, let next { way = next - at }
        if Self.length(way) < 0.0001, let prev { way = at - prev }
        guard Self.length(way) > 0.0001 else { return }
        let u = Self.unit(way)
        if let prev {
            let l = a.handleIn.map { Self.length($0 - at) } ?? Self.length(at - prev) / 3
            self[p].handleIn = at - u * l
        } else {
            self[p].handleIn = nil
        }
        if let next {
            let l = a.handleOut.map { Self.length($0 - at) } ?? Self.length(next - at) / 3
            self[p].handleOut = at + u * l
        } else {
            self[p].handleOut = nil
        }
    }

    /// One handle moved to `to`. On a smooth anchor the other handle turns with it and keeps
    /// its length, unless it is moved `alone`, which leaves a bend there. A handle let go on its
    /// anchor is taken away.
    mutating func moveHandle(_ p: PathPoint, out: Bool, to: CGPoint, alone: Bool) {
        let smooth = isSmooth(p), a = self[p]
        if Self.same(to, a.point) {
            self[p].setHandle(out: out, nil)
            return
        }
        self[p].setHandle(out: out, to)
        if smooth, !alone, let other = a.handle(out: !out) {
            let l = Self.length(other - a.point)
            self[p].setHandle(out: !out, a.point - Self.unit(to - a.point) * l)
        }
    }

    static func length(_ v: CGPoint) -> CGFloat { hypot(v.x, v.y) }

    static func unit(_ v: CGPoint) -> CGPoint {
        let l = length(v)
        return l > 0 ? CGPoint(x: v.x / l, y: v.y / l) : .zero
    }
}

/// One anchor of a path: which run it is on, and where along it.
nonisolated struct PathPoint: Hashable, Comparable {
    var subpath: Int
    var index: Int

    static func < (a: PathPoint, b: PathPoint) -> Bool {
        a.subpath != b.subpath ? a.subpath < b.subpath : a.index < b.index
    }
}

nonisolated extension CGPoint {
    static func * (p: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
}

// MARK: - Path layers

nonisolated extension Node {
    /// Where the frame's own upright coordinates, its top left at zero, land in the parent.
    var placement: CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: Geometry.radians(rotation))
            .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
    }

    /// Paths only: where the outline's own coordinates land in the parent. Its box fills the frame.
    var pathPlacement: CGAffineTransform {
        let box = pathBox ?? PathData.bounds(path ?? "")
        return CGAffineTransform(scaleX: box.width > 0 ? frame.width / box.width : 1, y: box.height > 0 ? frame.height / box.height : 1)
            .translatedBy(x: -box.minX, y: -box.minY)
            .concatenating(placement)
    }

    /// A new path layer through `points`, which are in the coordinates of the parent it goes into.
    static func path(_ points: BezierPath, name: String) -> Node {
        let data = points.data
        let box = PathData.bounds(data)
        var n = Node(kind: .path, name: name, frame: box)
        n.path = data
        n.pathBox = box
        // Drawn with a line, as a pen does, until it is given a fill.
        n.fill.on = false
        n.border = Border(on: true, color: .line, width: 1, position: .center)
        return n
    }

    /// The same layer as a path, for shapes that can be one: its outline becomes points to edit.
    func asPath() -> Node? {
        guard [.rectangle, .ellipse, .line].contains(kind) else { return nil }
        var n = self
        let size = frame.size
        let outline: CGPath
        switch kind {
        case .ellipse:
            outline = CGPath(ellipseIn: CGRect(origin: .zero, size: size), transform: nil)
        case .line:
            let p = CGMutablePath()
            if rising { p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) }
            else { p.move(to: .zero); p.addLine(to: CGPoint(x: size.width, y: size.height)) }
            outline = p
        default:
            let r = CGRect(origin: .zero, size: size)
            let radius = min(max(cornerRadius, 0), min(size.width, size.height) / 2)
            if let smoothing = cornerSmoothing, smoothing > 0 {
                outline = Squircle.path(in: r, corners: corners.flatMap { $0.count == 4 ? $0 : nil } ?? Array(repeating: cornerRadius, count: 4),
                                        smoothing: smoothing)
            } else if let corners, corners.count == 4 {
                outline = Self.roundedOutline(r, corners: corners)
            } else {
                outline = radius > 0 ? CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGPath(rect: r, transform: nil)
            }
        }
        n.kind = .path
        n.path = PathData.string(outline)
        n.pathBox = CGRect(origin: .zero, size: size)
        n.cornerRadius = 0
        n.corners = nil
        n.cornerSmoothing = nil
        n.rising = false
        return n
    }

    /// This path as `shape` again, the rectangle, ellipse or line `asPath()` made it from, with
    /// everything else that has changed on it since, such as its fill.
    func asShape(_ shape: Node) -> Node {
        var n = self
        n.kind = shape.kind
        n.path = shape.path
        n.pathBox = shape.pathBox
        n.cornerRadius = shape.cornerRadius
        n.corners = shape.corners
        n.cornerSmoothing = shape.cornerSmoothing
        n.rising = shape.rising
        return n
    }

    /// A rectangle whose corners are each rounded their own way, as the renderer draws it.
    private static func roundedOutline(_ r: CGRect, corners: [CGFloat]) -> CGPath {
        let most = min(r.width, r.height) / 2
        let tl = min(max(corners[0], 0), most), tr = min(max(corners[1], 0), most)
        let br = min(max(corners[2], 0), most), bl = min(max(corners[3], 0), most)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
        p.closeSubpath()
        return p
    }
}

nonisolated extension BezzleDocument {
    /// A path layer's points, on the canvas.
    func points(of id: UUID) -> BezierPath? {
        guard let n = node(id), n.kind == .path, let data = n.path else { return nil }
        let o = parentOrigin(of: id)
        return BezierPath(data).applying(n.pathPlacement.concatenating(CGAffineTransform(translationX: o.x, y: o.y)))
    }

    /// Gives a path layer new points, on the canvas. Its frame is fitted round them again and it
    /// keeps its turn; with no points left, the layer goes.
    mutating func setPoints(_ points: BezierPath, of id: UUID) {
        guard let n = node(id), n.kind == .path else { return }
        guard points.anchorCount > 0 else { _ = detach(id); return }
        let o = parentOrigin(of: id)
        // Into the frame's own upright coordinates, where the new box is measured.
        let toFrame = n.placement.concatenating(CGAffineTransform(translationX: o.x, y: o.y)).inverted()
        let placed = points.applying(toFrame)
        let data = placed.data
        // Measured from the points themselves rather than read back from what was just written.
        let box = placed.cgPath.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return }
        let centre = CGPoint(x: box.midX, y: box.midY).applying(n.placement)
        // Its Shape keys go with its points: each with the point it was made for.
        let before = n[track: .shape] != nil ? self.points(of: id)?.anchorPoints : nil
        update(id) { node in
            node.frame = CGRect(center: centre, size: box.size)
            node.path = data
            node.pathBox = box
            if let before, let keys = node[track: .shape] { node[track: .shape] = keys.realigned(from: before, to: points.anchorPoints) }
        }
    }
}
