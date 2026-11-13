import CoreGraphics
import Foundation

// Animate: shapes whose outline changes in time. A path, or a rectangle, ellipse or line, whose
// outline is points too, has two properties of its own. Its Shape moves its points and their
// handles, so one outline becomes another, as a shape posed by moving its points on the
// canvas at the playhead. Its Draw says how much of its outline is drawn, so its line is drawn
// on as a pen draws it. Each key holds a change from the design, as every key does: a layer with
// no keys is drawn as designed, and the design's outline is never changed by them.

nonisolated extension BezierPath {
    /// How many numbers a change of one anchor takes: where the anchor is, then the handle in,
    /// then the handle out, each across and down.
    static let numbersPerAnchor = 6

    /// The same outline with each anchor and its handles moved by `change`, six numbers to an
    /// anchor in the outline's order (`numbersPerAnchor`). A handle that comes to lie on its
    /// anchor is none, and one moved off an anchor that had none pulls the curve from there. Nil
    /// for a change of another number of anchors: one made for another outline.
    func changed(by change: [Double]) -> BezierPath? {
        guard change.count == anchorCount * Self.numbersPerAnchor else { return nil }
        var out = self
        var k = 0
        for s in out.subpaths.indices {
            for i in out.subpaths[s].anchors.indices {
                let a = out.subpaths[s].anchors[i]
                func moved(_ p: CGPoint, _ at: Int) -> CGPoint { CGPoint(x: p.x + CGFloat(change[at]), y: p.y + CGFloat(change[at + 1])) }
                let point = moved(a.point, k)
                let handleIn = moved(a.handleIn ?? a.point, k + 2), handleOut = moved(a.handleOut ?? a.point, k + 4)
                out.subpaths[s].anchors[i] = Anchor(point, in: Self.same(handleIn, point) ? nil : handleIn,
                                                    out: Self.same(handleOut, point) ? nil : handleOut)
                k += Self.numbersPerAnchor
            }
        }
        return out
    }

    /// How far each anchor of `other`, and its handles, are from this outline's: what
    /// `changed(by:)` takes to make this one into that. Nil when the two have not the same runs
    /// of anchors. Handles no curve is drawn with, into an open run's first anchor and out of its
    /// last, are no change.
    func change(to other: BezierPath) -> [Double]? {
        guard subpaths.count == other.subpaths.count,
              zip(subpaths, other.subpaths).allSatisfy({ $0.anchors.count == $1.anchors.count }) else { return nil }
        var out: [Double] = []
        out.reserveCapacity(anchorCount * Self.numbersPerAnchor)
        for (s, run) in subpaths.enumerated() {
            let to = other.subpaths[s]
            let last = run.anchors.count - 1
            for i in run.anchors.indices {
                let a = run.anchors[i], b = to.anchors[i]
                let open = !(run.closed || to.closed)
                let handleIn = open && i == 0 ? CGPoint.zero : (b.handleIn ?? b.point) - (a.handleIn ?? a.point)
                let handleOut = open && i == last ? CGPoint.zero : (b.handleOut ?? b.point) - (a.handleOut ?? a.point)
                let point = b.point - a.point
                out += [point.x, point.y, handleIn.x, handleIn.y, handleOut.x, handleOut.y].map(Double.init)
            }
        }
        return out
    }

    /// The part of the outline from `from` to `to` of its whole length, each 0 to 1, as a pen
    /// draws it: one run after another, in their order, each from its first anchor. All of it is
    /// the outline itself; nothing of it, from a place to that place or past it, is no outline.
    func trimmed(from: Double, to: Double) -> BezierPath {
        let from = min(max(from.isFinite ? from : 0, 0), 1), to = min(max(to.isFinite ? to : 1, 0), 1)
        if from <= 0, to >= 1 { return self }
        guard to > from else { return BezierPath() }
        // Each curve measured along itself, at enough places to find any length along it.
        struct Measured { var subpath: Int; var segment: Int; var straight: Bool; var lengths: [Double] }
        let steps = 24
        var measured: [[Measured]] = []
        var whole = 0.0
        for s in subpaths.indices {
            var run: [Measured] = []
            for i in 0..<subpaths[s].segmentCount {
                let c = segment(s, i)
                if isStraight(s, i) {
                    let length = Double(hypot(c.3.x - c.0.x, c.3.y - c.0.y))
                    run.append(Measured(subpath: s, segment: i, straight: true, lengths: [0, length]))
                } else {
                    var lengths = [0.0]
                    var last = c.0
                    for k in 1...steps {
                        let p = Self.point(on: c, at: CGFloat(k) / CGFloat(steps))
                        lengths.append(lengths[lengths.count - 1] + Double(hypot(p.x - last.x, p.y - last.y)))
                        last = p
                    }
                    run.append(Measured(subpath: s, segment: i, straight: false, lengths: lengths))
                }
                whole += run[run.count - 1].lengths.last ?? 0
            }
            measured.append(run)
        }
        guard whole > 1e-9 else { return BezierPath() }
        let start = from * whole, end = to * whole
        // Where along a curve `length` of it has been drawn: by the lengths measured along it.
        func place(_ m: Measured, _ length: Double) -> CGFloat {
            let total = m.lengths[m.lengths.count - 1]
            guard total > 1e-12 else { return 0 }
            if m.straight { return CGFloat(min(max(length / total, 0), 1)) }
            guard length > 0 else { return 0 }
            guard length < total else { return 1 }
            var k = 1
            while k < m.lengths.count - 1, m.lengths[k] < length { k += 1 }
            let a = m.lengths[k - 1], b = m.lengths[k]
            let u = b > a ? (length - a) / (b - a) : 0
            return CGFloat((Double(k - 1) + u) / Double(m.lengths.count - 1))
        }
        var runs: [Subpath] = []
        var travelled = 0.0
        for (s, run) in measured.enumerated() {
            let length = run.reduce(0) { $0 + ($1.lengths.last ?? 0) }
            let begins = travelled
            travelled += length
            guard length > 1e-12, travelled > start, begins < end else { continue }
            // Drawn whole: the run as it is, closed if it is.
            if begins >= start, travelled <= end {
                runs.append(subpaths[s])
                continue
            }
            var anchors: [Anchor] = []
            var at = begins
            for m in run {
                let total = m.lengths.last ?? 0
                let s0 = at, s1 = at + total
                at = s1
                guard total > 1e-12, s1 > start, s0 < end else { continue }
                let t0 = place(m, start - s0), t1 = place(m, end - s0)
                let c = segment(m.subpath, m.segment)
                let piece: (CGPoint, CGPoint?, CGPoint?, CGPoint)
                if m.straight {
                    piece = (c.0 + (c.3 - c.0) * t0, nil, nil, c.0 + (c.3 - c.0) * t1)
                } else {
                    let part = Self.part(of: c, from: t0, to: t1)
                    piece = (part.0, part.1, part.2, part.3)
                }
                if anchors.isEmpty {
                    anchors.append(Anchor(piece.0))
                }
                let handleOut = piece.1.flatMap { Self.same($0, piece.0) ? nil : $0 }
                anchors[anchors.count - 1].handleOut = handleOut
                anchors.append(Anchor(piece.3, in: piece.2.flatMap { Self.same($0, piece.3) ? nil : $0 }))
            }
            if anchors.count >= 2 { runs.append(Subpath(anchors: anchors, closed: false)) }
        }
        return BezierPath(subpaths: runs)
    }

    /// The part of a curve between two places along it, `t0` to `t1` of the way, as a curve of
    /// its own: cut the way de Casteljau does.
    static func part(of c: (CGPoint, CGPoint, CGPoint, CGPoint), from t0: CGFloat, to t1: CGFloat) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        func before(_ c: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: CGFloat) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            let p01 = c.0 + (c.1 - c.0) * t, p12 = c.1 + (c.2 - c.1) * t, p23 = c.2 + (c.3 - c.2) * t
            let p012 = p01 + (p12 - p01) * t, p123 = p12 + (p23 - p12) * t
            return (c.0, p01, p012, p012 + (p123 - p012) * t)
        }
        func after(_ c: (CGPoint, CGPoint, CGPoint, CGPoint), _ t: CGFloat) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
            let p01 = c.0 + (c.1 - c.0) * t, p12 = c.1 + (c.2 - c.1) * t, p23 = c.2 + (c.3 - c.2) * t
            let p012 = p01 + (p12 - p01) * t, p123 = p12 + (p23 - p12) * t
            return (p012 + (p123 - p012) * t, p123, p23, c.3)
        }
        let head = before(c, t1)
        return t1 > 1e-9 ? after(head, t0 / t1) : (c.0, c.0, c.0, c.0)
    }
}

// MARK: - A shape's outline in time

nonisolated extension Node {
    /// Whether its outline can change in time: a path's, or a rectangle's, ellipse's or line's,
    /// which is points too (`asPath`).
    var canReshape: Bool {
        switch kind {
        case .path: path != nil
        case .rectangle, .ellipse, .line: true
        default: false
        }
    }

    /// Its outline as the design has it, in its own upright points: its frame's top left at
    /// zero, before it is turned. What its Shape keys change.
    var ownOutline: BezierPath? {
        switch kind {
        case .path:
            guard let path else { return nil }
            let box = pathBox ?? PathData.bounds(path)
            let fit = CGAffineTransform(scaleX: box.width > 0 ? frame.width / box.width : 1, y: box.height > 0 ? frame.height / box.height : 1)
                .translatedBy(x: -box.minX, y: -box.minY)
            return BezierPath(path).applying(fit)
        case .rectangle, .ellipse, .line:
            return asPath()?.ownOutline
        default:
            return nil
        }
    }

    /// No change of its Shape: every point where it is.
    var shapeRest: [Double] {
        Array(repeating: 0, count: (ownOutline?.anchorCount ?? 0) * BezierPath.numbersPerAnchor)
    }

    /// Whether its outline changes in the film: its Shape or its Draw has keys.
    var reshapes: Bool {
        guard let motion, motion[MotionProperty.shape.rawValue] != nil || motion[MotionProperty.draw.rawValue] != nil else { return false }
        return canReshape
    }

    /// Its outline at a moment, in its own upright points: the design's, with its points where
    /// its Shape keys have them. Keys made for another outline, one with other points, change nothing.
    func outline(at t: Double) -> BezierPath? {
        guard let design = ownOutline else { return nil }
        guard self[track: .shape] != nil else { return design }
        return design.changed(by: value(of: .shape, at: t)) ?? design
    }

    /// The change of its Shape that makes its outline `outline`, in its own upright points; nil
    /// for an outline with other points than the design's.
    func shapeChange(to outline: BezierPath) -> [Double]? {
        ownOutline?.change(to: outline)
    }

    /// The layer as its Shape and Draw have it at a moment, for drawing it: a path through its
    /// points where they are then, as much of it drawn as is drawn then. Its frame grows to hold
    /// points that go past it, keeping where everything else is, so its picture holds them;
    /// what is turned or grown in the film still turns and grows about the design's middle
    /// (`posed`). Where they change nothing, the layer as it is.
    func reshaped(at t: Double) -> Node {
        guard reshapes, let design = ownOutline else { return self }
        var outline = design
        var moved = false
        if self[track: .shape] != nil {
            let change = value(of: .shape, at: t)
            if change.contains(where: { abs($0) > 1e-9 }), let changed = design.changed(by: change) {
                outline = changed
                moved = true
            }
        }
        let draw = value(of: .draw, at: t)
        let trims = draw[0] > 1e-6 || draw[1] < 1 - 1e-6
        guard moved || trims else { return self }
        var n = kind == .path ? self : (asPath() ?? self)
        // Its own box, grown to what the moved points reach: what lay in it stays where it was.
        var box = CGRect(origin: .zero, size: frame.size)
        if moved {
            let reach = outline.bounds
            if !reach.isNull, reach.minX.isFinite, reach.maxX.isFinite, reach.minY.isFinite, reach.maxY.isFinite { box = box.union(reach) }
        }
        if trims { outline = outline.trimmed(from: draw[0], to: draw[1]) }
        n.path = outline.applying(CGAffineTransform(translationX: -box.minX, y: -box.minY)).data
        n.pathBox = CGRect(origin: .zero, size: box.size)
        if box != CGRect(origin: .zero, size: frame.size) {
            n.frame = CGRect(center: CGPoint(x: box.midX, y: box.midY).applying(placement), size: box.size)
        }
        return n
    }

    /// Poses its Shape at a moment so that its outline is `outline` there, in its own upright
    /// points, as moving its points on the canvas does. Returns false, changing nothing, for an
    /// outline with other points than the design's: points are added and taken away in the design.
    @discardableResult
    mutating func poseShape(_ outline: BezierPath, at time: Double) -> Bool {
        guard canReshape, let change = shapeChange(to: outline) else { return false }
        pose(.shape, change, at: time)
        return true
    }
}

// MARK: - When the design's points change

nonisolated extension MotionTrack {
    /// The keys of a Shape made for an outline whose anchors were `before`, for the outline they
    /// are now, `after`: each anchor's change goes with the anchor. An anchor is told by where it
    /// is, so one added, taken away or run the other way round leaves the others' changes with
    /// them; where none is found there, as when points were dragged, by its place in the outline,
    /// if the number of anchors is the same. A new anchor goes as the anchors either side of it do.
    func realigned(from before: [CGPoint], to after: [CGPoint]) -> MotionTrack {
        let n = BezierPath.numbersPerAnchor
        guard before != after else { return self }
        var from = [Int?](repeating: nil, count: after.count)
        var used = Set<Int>()
        for j in after.indices {
            if let i = before.indices.first(where: { !used.contains($0) && BezierPath.same(before[$0], after[j]) }) {
                from[j] = i
                used.insert(i)
            }
        }
        if before.count == after.count {
            for j in after.indices where from[j] == nil && !used.contains(j) {
                from[j] = j
                used.insert(j)
            }
        }
        var out = self
        for k in out.keys.indices {
            let v = out.keys[k].v
            guard v.count == before.count * n else { continue }
            var next = [Double](repeating: 0, count: after.count * n)
            for j in after.indices {
                if let i = from[j] {
                    for c in 0..<n { next[j * n + c] = v[i * n + c] }
                    continue
                }
                // Between the anchors either side that are known: where they are moved, halfway.
                let earlier = (0..<j).reversed().first { from[$0] != nil }.flatMap { from[$0] }
                let later = ((j + 1)..<after.count).first { from[$0] != nil }.flatMap { from[$0] }
                let near = [earlier, later].compactMap { $0 }
                guard !near.isEmpty else { continue }
                let dx = near.map { v[$0 * n] }.reduce(0, +) / Double(near.count)
                let dy = near.map { v[$0 * n + 1] }.reduce(0, +) / Double(near.count)
                for c in stride(from: 0, to: n, by: 2) {
                    next[j * n + c] = dx
                    next[j * n + c + 1] = dy
                }
            }
            out.keys[k].v = next
        }
        return out
    }
}

nonisolated extension BezierPath {
    /// Every anchor's place, in the outline's order.
    var anchorPoints: [CGPoint] { subpaths.flatMap { $0.anchors.map(\.point) } }

    /// The same outline with every anchor and handle put elsewhere, as a film's map puts them
    /// (`Node.filmPointMap`); nil when one of them has nowhere to go, as past a horizon.
    func mapped(_ place: (CGPoint) -> CGPoint?) -> BezierPath? {
        var out = self
        for s in out.subpaths.indices {
            for i in out.subpaths[s].anchors.indices {
                let a = out.subpaths[s].anchors[i]
                guard let point = place(a.point) else { return nil }
                var handleIn: CGPoint?, handleOut: CGPoint?
                if let h = a.handleIn { guard let q = place(h) else { return nil }; handleIn = q }
                if let h = a.handleOut { guard let q = place(h) else { return nil }; handleOut = q }
                out.subpaths[s].anchors[i] = Anchor(point, in: handleIn, out: handleOut)
            }
        }
        return out
    }
}
