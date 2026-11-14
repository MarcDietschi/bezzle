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
                out += [point.x, point.y, handleIn.x, handleIn.y, handleOut.x, handleOut.y].map { Double($0) }
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

// MARK: - When the design's outline changes

// A Shape key is a change of each of the design's points, so it is made for one outline. When the
// design gives the layer another, without a point being edited (it is resized, a rectangle's
// corners are rounded, it is flipped, or shapes are combined into it), its keys go with it:
// stretched as the layer is, turned over as it is, and where the outline has other points, each
// new point going as the place it lies at on the old outline went.

nonisolated extension BezierPath {
    /// How the change of each anchor of an outline is made of the changes of another's, the one
    /// its Shape keys were made for.
    struct Following {
        /// A share of one of the old outline's changes: its anchors' numbered three to an anchor,
        /// its point, its handle in, its handle out.
        typealias Share = (from: Int, share: Double)
        /// For each of the new outline's anchors three lists, what its point, its handle in and
        /// its handle out go by.
        var shares: [[Share]] = []
        /// How many anchors the old outline has.
        var old = 0

        /// From `old`, lying in the new outline's own points, to `new`. An anchor where one was
        /// goes as that one did, its handles too, the other way round where the outline now runs
        /// the other way; `inOrder` takes them by their place in the outline when both have the
        /// same runs, as a shape drawn again by its kind has them. Any other anchor goes as the
        /// place nearest it on the old outline went, between the anchors either side of it there,
        /// and its handles as the places they pull towards.
        init(from old: BezierPath, to new: BezierPath, inOrder: Bool) {
            self.old = old.anchorCount
            // The anchors of each, one after another, and where each run begins among them.
            func starts(_ p: BezierPath) -> [Int] {
                var at = 0
                return p.subpaths.map { run in defer { at += run.anchors.count }; return at }
            }
            let oldStarts = starts(old), newStarts = starts(new)
            let was = old.subpaths.flatMap(\.anchors), now = new.subpaths.flatMap(\.anchors)
            let alike = old.subpaths.count == new.subpaths.count
                && zip(old.subpaths, new.subpaths).allSatisfy { $0.anchors.count == $1.anchors.count }
            var from = [Int?](repeating: nil, count: now.count)
            var used = Set<Int>()
            if alike, inOrder {
                for j in now.indices { from[j] = j }
            } else {
                // Where one was: the one with the same place in the outline first, so that two
                // lying on each other each stay themselves.
                for j in now.indices where j < was.count && BezierPath.same(was[j].point, now[j].point) {
                    from[j] = j
                    used.insert(j)
                }
                for j in now.indices where from[j] == nil {
                    if let i = was.indices.first(where: { !used.contains($0) && BezierPath.same(was[$0].point, now[j].point) }) {
                        from[j] = i
                        used.insert(i)
                    }
                }
                // Dragged, with the outline's runs as they were: by its place in the outline.
                if alike {
                    for j in now.indices where from[j] == nil && !used.contains(j) {
                        from[j] = j
                        used.insert(j)
                    }
                }
            }
            // An anchor's neighbours along its run, among all the anchors.
            func neighbours(_ k: Int, _ p: BezierPath, _ starts: [Int]) -> (before: Int?, after: Int?) {
                guard let s = starts.lastIndex(where: { $0 <= k }) else { return (nil, nil) }
                let run = p.subpaths[s], i = k - starts[s]
                return (run.before(i).map { $0 + starts[s] }, run.after(i).map { $0 + starts[s] })
            }
            // Whether the outline runs the other way through an anchor than it did: its handles
            // tell, and where they cannot, as at a corner, the anchors either side.
            func turnedRound(_ j: Int, _ i: Int) -> Bool {
                let a = was[i], b = now[j]
                let aIn = a.handleIn ?? a.point, aOut = a.handleOut ?? a.point
                let bIn = b.handleIn ?? b.point, bOut = b.handleOut ?? b.point
                let straight = BezierPath.same(bIn, aIn) && BezierPath.same(bOut, aOut)
                let crossed = BezierPath.same(bIn, aOut) && BezierPath.same(bOut, aIn)
                if straight != crossed { return crossed }
                let o = neighbours(i, old, oldStarts), n = neighbours(j, new, newStarts)
                if let next = n.after, let came = from[next] {
                    if came == o.before, came != o.after { return true }
                    if came == o.after { return false }
                }
                if let last = n.before, let came = from[last] {
                    if came == o.after, came != o.before { return true }
                }
                return false
            }
            // What a place on the old outline goes by: the four points of its curve, each by how
            // much it pulls there. A straight side is measured along itself, and its curve runs
            // along it by `3u² − 2u³`: the same place, at the `u` that comes to.
            func pull(at spot: Spot) -> [Share] {
                let run = old.subpaths[spot.subpath]
                let i = oldStarts[spot.subpath] + spot.segment, j = oldStarts[spot.subpath] + (spot.segment + 1) % run.anchors.count
                var t = Double(min(max(spot.t, 0), 1))
                if old.isStraight(spot.subpath, spot.segment) { t = 0.5 - sin(asin(1 - 2 * t) / 3) }
                let u = 1 - t
                return [(i * 3, u * u * u), (i * 3 + 2, 3 * u * u * t), (j * 3 + 1, 3 * u * t * t), (j * 3, t * t * t)]
            }
            // The place nearest a point on one curve of the old outline, or on those either side of it.
            func spot(near p: CGPoint, by found: Spot) -> Spot {
                let run = old.subpaths[found.subpath], count = run.segmentCount
                var best = found
                best.distance = .infinity
                var tried = Set<Int>()
                for d in [0, -1, 1] {
                    var k = found.segment + d
                    if run.closed { k = (k % count + count) % count }
                    guard k >= 0, k < count, tried.insert(k).inserted else { continue }
                    let a = run.anchors[k], b = run.anchors[(k + 1) % run.anchors.count]
                    let piece = BezierPath(subpaths: [Subpath(anchors: [Anchor(a.point, out: a.handleOut), Anchor(b.point, in: b.handleIn)])])
                    if let s = piece.nearest(to: p), s.distance < best.distance {
                        best = Spot(subpath: found.subpath, segment: k, t: s.t, point: s.point, distance: s.distance)
                    }
                }
                return best
            }
            for j in now.indices {
                if let i = from[j] {
                    let round = turnedRound(j, i)
                    shares += [[(i * 3, 1)], [(i * 3 + (round ? 2 : 1), 1)], [(i * 3 + (round ? 1 : 2), 1)]]
                    continue
                }
                guard let found = old.nearest(to: now[j].point) else {
                    // An outline of single points has no curve to lie on: as the nearest of them went.
                    let near = was.indices.min { Self.far(was[$0].point, now[j].point) < Self.far(was[$1].point, now[j].point) }
                    let all: [Share] = near.map { [($0 * 3, 1)] } ?? []
                    shares += [all, all, all]
                    continue
                }
                let point = pull(at: found)
                // A handle goes as the place it pulls towards; with none, it stays on its point.
                let handleIn = now[j].handleIn.map { pull(at: spot(near: $0, by: found)) } ?? point
                let handleOut = now[j].handleOut.map { pull(at: spot(near: $0, by: found)) } ?? point
                shares += [point, handleIn, handleOut]
            }
        }

        private static func far(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        /// A change of the old outline's anchors as the change of the new one's that it comes to.
        /// `place` is how the old outline's own points lie in the new one's: a change is turned
        /// and grown as they are.
        func carried(_ change: [Double], placed place: CGAffineTransform) -> [Double] {
            let n = BezierPath.numbersPerAnchor
            guard change.count == old * n else { return change }
            let a = Double(place.a), b = Double(place.b), c = Double(place.c), d = Double(place.d)
            var out: [Double] = []
            out.reserveCapacity(shares.count * 2)
            for list in shares {
                var x = 0.0, y = 0.0
                for (from, share) in list {
                    let dx = change[from * 2], dy = change[from * 2 + 1]
                    x += (dx * a + dy * c) * share
                    y += (dx * b + dy * d) * share
                }
                out += [x, y]
            }
            return out
        }
    }
}

nonisolated extension MotionTrack {
    /// The keys of a Shape made for the outline `before`, for the outline `after` that the design
    /// has now, each in the layer's own points as they were and as they are. `place` is where the
    /// old own points lie among the new: grown as the layer was resized, turned over as it was
    /// flipped. Keys made for neither are left alone.
    func following(_ before: BezierPath, to after: BezierPath, placed place: CGAffineTransform = .identity, inOrder: Bool = false) -> MotionTrack {
        let count = before.anchorCount * BezierPath.numbersPerAnchor
        guard count > 0, after.anchorCount > 0, keys.contains(where: { $0.v.count == count }),
              [place.a, place.b, place.c, place.d, place.tx, place.ty].allSatisfy(\.isFinite) else { return self }
        let follow = BezierPath.Following(from: before.applying(place), to: after, inOrder: inOrder)
        var out = self
        for k in out.keys.indices where out.keys[k].v.count == count {
            out.keys[k].v = MotionProperty.shape.clamped(follow.carried(out.keys[k].v, placed: place))
        }
        return out
    }
}

nonisolated extension Node {
    /// What its outline is made of, besides where it lies: while none of this changes, its Shape
    /// keys fit it as they did.
    private func outlineSame(as other: Node) -> Bool {
        kind == other.kind && frame.size == other.frame.size && path == other.path && pathBox == other.pathBox
            && cornerRadius == other.cornerRadius && corners == other.corners && cornerSmoothing == other.cornerSmoothing && rising == other.rising
    }

    /// Its Shape keys for the outline it has now, when `before`, the same layer as it was, had
    /// another: `before`'s keys, made for that one. Nil where the outline is the same, or there
    /// are no keys to go with it. A layer resized has them grown with it, as far as each side
    /// grew; a rectangle, ellipse or line drawn anew, with other corners, has each of its points
    /// go as the place it lies at went; a path given other points without their being edited one
    /// by one, as shapes combined are, likewise, where both lie in what holds them.
    func shapeKeys(following before: Node) -> MotionTrack? {
        guard let track = before[track: .shape], canReshape, before.canReshape, !outlineSame(as: before),
              let was = before.ownOutline, let now = ownOutline, was != now else { return nil }
        let old = before.frame.size
        let grown = CGAffineTransform(scaleX: old.width > 1e-6 ? frame.width / old.width : 1, y: old.height > 1e-6 ? frame.height / old.height : 1)
        let next: MotionTrack
        if kind != .path, before.kind != .path {
            next = track.following(was, to: now, placed: grown, inOrder: kind == before.kind)
        } else if kind == .path, before.kind == .path, path == before.path, pathBox == before.pathBox {
            next = track.following(was, to: now, placed: grown, inOrder: true)
        } else {
            next = track.following(was, to: now, placed: before.placement.concatenating(placement.inverted()))
        }
        return next == self[track: .shape] ? nil : next
    }

    /// Whether it, or anything it holds, has Shape keys.
    var holdsShapeKeys: Bool {
        motion?[MotionProperty.shape.rawValue] != nil || children.contains(where: \.holdsShapeKeys) || (mask?.contains(where: \.holdsShapeKeys) ?? false)
    }

    /// The layer, flipped from `before` (`BezzleDocument.flipped`), with its Shape keys turned
    /// over as its outline was, and those of what it holds: a point that went left now goes right.
    func shapeKeysFlipped(from before: Node, horizontally: Bool) -> Node {
        guard before.holdsShapeKeys else { return self }
        var n = self
        if let track = before[track: .shape], self[track: .shape] == track, let was = before.ownOutline, let now = ownOutline {
            let size = before.frame.size
            let over = horizontally ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
                                    : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            n[track: .shape] = track.following(was, to: now, placed: over)
        }
        func each(_ now: [Node], _ was: [Node]) -> [Node] {
            guard now.count == was.count else { return now }
            return zip(now, was).map { $0.id == $1.id ? $0.shapeKeysFlipped(from: $1, horizontally: horizontally) : $0 }
        }
        n.children = each(children, before.children)
        if let mask, let was = before.mask { n.mask = each(mask, was) }
        return n
    }
}

nonisolated extension BezzleDocument {
    /// Keeps every Shape key with the outline it was made for, after a change to the design:
    /// where a layer's outline is another than in `before`, and its keys were left as they were,
    /// they go with it (`Node.shapeKeys(following:)`). One step with the change, so both are
    /// undone together. `start` is the design as a drag began: a layer dragged flat on the way,
    /// which leaves nothing of its keys to grow again, has them from there.
    mutating func followOutlines(since before: BezzleDocument, start: BezzleDocument? = nil) {
        var found: [(at: [Int], track: MotionTrack)] = []
        func look(_ now: [Node], _ was: [Node]?, _ at: [Int], _ old: (UUID) -> Node?) {
            for (i, n) in now.enumerated() {
                let same = was.flatMap { i < $0.count && $0[i].id == n.id ? $0[i] : nil }
                if let same, same == n { continue }
                if n.motion?[MotionProperty.shape.rawValue] != nil, n.canReshape, var then = same ?? old(n.id), then[track: .shape] == n[track: .shape] {
                    // Flat when this step began: from where the drag did.
                    if let began = start?.node(n.id), began[track: .shape] != nil,
                       (then.frame.width <= 1e-6 && began.frame.width > 1e-6) || (then.frame.height <= 1e-6 && began.frame.height > 1e-6) {
                        then = began
                    }
                    if let track = n.shapeKeys(following: then) { found.append((at + [i], track)) }
                }
                if !n.children.isEmpty { look(n.children, same?.children, at + [i], old) }
            }
        }
        look(nodes, before.nodes, []) { before.node($0) }
        for (at, track) in found { update(self[NodePath(indices: at)].id) { $0[track: .shape] = track } }
        // The components' own layers, which lie apart from the canvas.
        guard var list = components, list != before.components else { return }
        found = []
        var kept: [UUID: Node] = [:]
        func note(_ nodes: [Node]) { for n in nodes { kept[n.id] = n; note(n.children) } }
        note(before.components ?? [])
        look(list, before.components, []) { kept[$0] }
        guard !found.isEmpty else { return }
        func set(_ nodes: inout [Node], _ at: ArraySlice<Int>, _ track: MotionTrack) {
            guard let i = at.first else { return }
            if at.count == 1 { nodes[i][track: .shape] = track } else { set(&nodes[i].children, at.dropFirst(), track) }
        }
        for (at, track) in found { set(&list, at[...], track) }
        components = list
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

// MARK: - One outline into another that has other points

// Two outlines with the same runs of as many points go into each other point by point. Any other
// two are first given the same points, neither changing its shape by it (`matched`). An anchor
// both have in one place is one anchor. The stretches between such anchors are laid along each
// other, each anchor by how far along its stretch it is: two that come to lie close are one, and
// where one outline has an anchor the other has none for, the other gets a point there, on its
// curve. Outlines with no anchor in one place are laid along each other whole, begun at the place
// and run the way that takes their points least far. A run with none to go with shrinks to its
// middle, or grows from it. Then the one goes into the other as any two with the same points do
// (`mixed`).

nonisolated extension BezierPath {
    /// Whether the two have the same runs of anchors: as many runs, each of as many anchors, and
    /// closed or open alike. Such outlines go into each other point by point.
    func hasRuns(of other: BezierPath) -> Bool {
        subpaths.count == other.subpaths.count
            && zip(subpaths, other.subpaths).allSatisfy { $0.anchors.count == $1.anchors.count && $0.closed == $1.closed }
    }

    /// The outline `p` of the way from this one to `other`, which has the same runs
    /// (`hasRuns(of:)`): every anchor and handle that far on its way. At 0 it is this one and at
    /// 1 the other, exactly; past either it goes on as it went, as a spring's pace asks. Where an
    /// anchor is smooth in both, its handles stay in one line on the way.
    func mixed(with other: BezierPath, _ p: Double) -> BezierPath {
        guard hasRuns(of: other), p.isFinite else { return p >= 0.5 ? other : self }
        if p == 0 { return self }
        if p == 1 { return other }
        let q = CGFloat(p)
        // Lined up wholly on the way, and less and less towards either end, where each outline
        // is as it was keyed, handles a hair out of line too.
        let lined = CGFloat(min(1, 10 * max(0, min(p, 1 - p))))
        var out = self
        for s in subpaths.indices {
            for i in subpaths[s].anchors.indices {
                let a = subpaths[s].anchors[i], b = other.subpaths[s].anchors[i]
                let point = a.point + (b.point - a.point) * q
                var handleIn = (a.handleIn ?? a.point) + ((b.handleIn ?? b.point) - (a.handleIn ?? a.point)) * q
                var handleOut = (a.handleOut ?? a.point) + ((b.handleOut ?? b.point) - (a.handleOut ?? a.point)) * q
                let at = PathPoint(subpath: s, index: i)
                if lined > 0, a.handleIn != nil, a.handleOut != nil, b.handleIn != nil, b.handleOut != nil, isSmooth(at), other.isSmooth(at) {
                    let across = Self.length(handleOut - handleIn)
                    if across > 0.0001 {
                        let way = (handleOut - handleIn) * (1 / across)
                        let straightIn = point - way * Self.length(handleIn - point), straightOut = point + way * Self.length(handleOut - point)
                        handleIn = handleIn + (straightIn - handleIn) * lined
                        handleOut = handleOut + (straightOut - handleOut) * lined
                    }
                }
                out.subpaths[s].anchors[i] = Anchor(point, in: Self.same(handleIn, point) ? nil : handleIn,
                                                    out: Self.same(handleOut, point) ? nil : handleOut)
            }
        }
        return out
    }

    /// The two outlines with the same runs of anchors, each the shape it was: what `mixed` takes
    /// one into the other by. Outlines that have the same runs already are returned as they are:
    /// their points are the same points, each numbered as the other's.
    static func matched(_ a: BezierPath, _ b: BezierPath) -> (BezierPath, BezierPath) {
        if a.hasRuns(of: b) { return (a, b) }
        let runs = OutlineMatching.matched(a, b, anew: false)
        return (BezierPath(subpaths: runs.map(\.first)), BezierPath(subpaths: runs.map(\.second)))
    }

    /// This outline, the shape it is, with its points as they best come from `other`'s: what
    /// an outline taken from another shape is given, whose points are numbered as that shape
    /// had them and not as the outline it is to come from. Its runs are in the order of the runs
    /// of `other` they go with, each begun where and drawn the way that takes the points least
    /// far. Where that falls between two of its anchors, it has the points more that `matched`
    /// would give it, so that what comes from `other` comes without turning on the way; where
    /// it falls on its anchors, it has its own and no more.
    func laid(along other: BezierPath) -> BezierPath {
        BezierPath(subpaths: OutlineMatching.matched(other, self, anew: true).filter(\.own).map(\.second))
    }
}

/// How two runs of anchors are given the same anchors (`BezierPath.matched`).
nonisolated private enum OutlineMatching {
    typealias Run = BezierPath.Subpath
    typealias Anchor = BezierPath.Anchor
    typealias Curve = (CGPoint, CGPoint, CGPoint, CGPoint)

    static func curve(_ run: Run, _ i: Int) -> Curve {
        let a = run.anchors[i], b = run.anchors[(i + 1) % run.anchors.count]
        return (a.point, a.handleOut ?? a.point, b.handleIn ?? b.point, b.point)
    }

    static func straight(_ run: Run, _ i: Int) -> Bool {
        run.anchors[i].handleOut == nil && run.anchors[(i + 1) % run.anchors.count].handleIn == nil
    }

    /// A run measured along itself.
    struct Measure {
        var run: Run
        /// Each curve's length at places along it, from none of it to all.
        var lengths: [[Double]] = []
        /// How much of the run lies before each anchor, and last, all of it.
        var before: [Double] = [0]
        static let steps = 16

        init(_ run: Run) {
            self.run = run
            for i in 0..<run.segmentCount {
                let c = OutlineMatching.curve(run, i)
                var table = [0.0]
                if OutlineMatching.straight(run, i) {
                    table.append(Double(hypot(c.3.x - c.0.x, c.3.y - c.0.y)))
                } else {
                    var last = c.0
                    for k in 1...Self.steps {
                        let p = BezierPath.point(on: c, at: CGFloat(k) / CGFloat(Self.steps))
                        table.append(table[table.count - 1] + Double(hypot(p.x - last.x, p.y - last.y)))
                        last = p
                    }
                }
                lengths.append(table)
                before.append(before[before.count - 1] + table[table.count - 1])
            }
        }

        var total: Double { before[before.count - 1] }

        /// How far along curve `i` a length of it reaches, 0 to 1.
        func time(_ i: Int, _ length: Double) -> CGFloat {
            let table = lengths[i], whole = table[table.count - 1]
            guard whole > 1e-12, length > 0 else { return 0 }
            guard length < whole else { return 1 }
            if table.count == 2 { return CGFloat(length / whole) }
            var k = 1
            while k < table.count - 1, table[k] < length { k += 1 }
            let a = table[k - 1], b = table[k]
            return CGFloat((Double(k - 1) + (b > a ? (length - a) / (b - a) : 0)) / Double(table.count - 1))
        }

        /// The curve a length along the run lies on.
        func curve(at length: Double) -> Int {
            var i = 0
            while i < run.segmentCount - 1, before[i + 1] <= length { i += 1 }
            return i
        }

        /// `count` places evenly along it: round a closed run from its first anchor to just short
        /// of there again, along an open one from end to end.
        func points(_ count: Int) -> [CGPoint] {
            guard run.segmentCount > 0, total > 1e-12 else { return Array(repeating: run.anchors.first?.point ?? .zero, count: count) }
            let step = total / Double(run.closed ? count : max(count - 1, 1))
            var out: [CGPoint] = []
            out.reserveCapacity(count)
            var i = 0
            for k in 0..<count {
                let at = min(Double(k) * step, total)
                while i < run.segmentCount - 1, before[i + 1] <= at { i += 1 }
                let c = OutlineMatching.curve(run, i), t = time(i, at - before[i])
                out.append(OutlineMatching.straight(run, i) ? c.0 + (c.3 - c.0) * t : BezierPath.point(on: c, at: t))
            }
            return out
        }

        /// How far an anchor is from the nearer of the anchors either side, as a part of the run.
        func room(of i: Int) -> Double {
            guard total > 1e-12 else { return 0 }
            let n = run.anchors.count
            var gaps: [Double] = []
            if run.closed {
                gaps = [lengths[(i - 1 + n) % n].last ?? 0, lengths[i % n].last ?? 0]
            } else {
                if i > 0 { gaps.append(lengths[i - 1].last ?? 0) }
                if i < n - 1 { gaps.append(lengths[i].last ?? 0) }
            }
            return (gaps.min() ?? 0) / total
        }
    }

    /// A run with new anchors on its curves, which leave its shape as it is: `cuts[i]` says how
    /// far along curve `i` each lies, 0 to 1 and in their order. And where each of the run's own
    /// anchors comes to be among them all.
    static func cut(_ run: Run, at cuts: [[CGFloat]]) -> (run: Run, own: [Int]) {
        var anchors = run.anchors
        var added = [[Anchor]](repeating: [], count: anchors.count)
        func handle(_ h: CGPoint, of p: CGPoint) -> CGPoint? { BezierPath.same(h, p) ? nil : h }
        for i in 0..<run.segmentCount where i < cuts.count && !cuts[i].isEmpty {
            let j = (i + 1) % anchors.count
            if straight(run, i) {
                let a = anchors[i].point, b = anchors[j].point
                added[i] = cuts[i].map { Anchor(a + (b - a) * min(max($0, 0), 1)) }
                continue
            }
            // Cut the way de Casteljau does, one place after another along what is left.
            var rest = curve(run, i)
            var done: CGFloat = 0
            for t in cuts[i] {
                let t = min(max(t, done), 1)
                let local = done < 1 ? (t - done) / (1 - done) : 0
                let (p0, c1, c2, p3) = rest
                let p01 = p0 + (c1 - p0) * local, p12 = c1 + (c2 - c1) * local, p23 = c2 + (p3 - c2) * local
                let p012 = p01 + (p12 - p01) * local, p123 = p12 + (p23 - p12) * local
                let p = p012 + (p123 - p012) * local
                if added[i].isEmpty { anchors[i].handleOut = handle(p01, of: p0) } else { added[i][added[i].count - 1].handleOut = handle(p01, of: p0) }
                added[i].append(Anchor(p, in: handle(p012, of: p)))
                rest = (p, p123, p23, p3)
                done = t
            }
            added[i][added[i].count - 1].handleOut = handle(rest.1, of: rest.0)
            anchors[j].handleIn = handle(rest.2, of: rest.3)
        }
        var out: [Anchor] = [], own: [Int] = []
        for i in anchors.indices {
            own.append(out.count)
            out.append(anchors[i])
            out += added[i]
        }
        return (Run(anchors: out, closed: run.closed), own)
    }

    /// A run with every anchor at one place: what a run grows from, or shrinks to.
    static func gathered(_ run: Run, at point: CGPoint) -> Run {
        Run(anchors: run.anchors.map { _ in Anchor(point) }, closed: run.closed)
    }

    /// The box round a run's anchors.
    static func box(_ run: Run) -> CGRect {
        var box = CGRect.null
        for a in run.anchors { box = box.union(CGRect(origin: a.point, size: .zero)) }
        return box
    }

    static func middle(_ run: Run) -> CGPoint {
        let box = box(run)
        return box.isNull ? .zero : CGPoint(x: box.midX, y: box.midY)
    }

    /// A closed run begun at another of its anchors, and run the other way round if `turned`.
    static func begun(_ run: Run, at k: Int, turned: Bool) -> Run {
        let n = run.anchors.count
        guard n > 0 else { return run }
        var anchors = (0..<n).map { run.anchors[(k + $0) % n] }
        if turned { anchors = ([anchors[0]] + anchors.dropFirst().reversed()).map { Anchor($0.point, in: $0.handleOut, out: $0.handleIn) } }
        return Run(anchors: anchors, closed: run.closed)
    }

    /// Where anchor `k` of a closed run of `count` comes to be in the run begun at `start`.
    static func place(of k: Int, begunAt start: Int, turned: Bool, count: Int) -> Int {
        turned ? (start - k + count) % count : (k - start + count) % count
    }

    /// An open run drawn the other way.
    static func turned(_ run: Run) -> Run {
        Run(anchors: run.anchors.reversed().map { Anchor($0.point, in: $0.handleOut, out: $0.handleIn) }, closed: run.closed)
    }

    /// A closed run as an open one that ends where it begins.
    static func opened(_ run: Run) -> Run {
        guard let first = run.anchors.first else { return run }
        var anchors = run.anchors
        anchors[0].handleIn = nil
        anchors.append(Anchor(first.point, in: first.handleIn))
        return Run(anchors: anchors, closed: false)
    }

    /// For each anchor of `x`, the anchor of `y` that lies where it does, if one does: each of
    /// `y`'s for one of `x`'s, the earlier first.
    static func twins(_ x: Run, _ y: Run) -> [Int?] {
        struct Place: Hashable {
            var x: Int
            var y: Int
        }
        func place(_ p: CGPoint) -> Place? {
            guard p.x.isFinite, p.y.isFinite, abs(p.x) < 1e9, abs(p.y) < 1e9 else { return nil }
            return Place(x: Int((p.x * 100).rounded()), y: Int((p.y * 100).rounded()))
        }
        var at: [Place: [Int]] = [:]
        for (k, a) in y.anchors.enumerated().reversed() {
            if let p = place(a.point) { at[p, default: []].append(k) }
        }
        return x.anchors.map { a in place(a.point).flatMap { at[$0]?.popLast() } }
    }

    /// The longest choice of `values`, in their order, in which each is more than the one before:
    /// which of them.
    static func rising(_ values: [Int]) -> [Int] {
        var tails: [Int] = [], before = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tails[mid]] < v { lo = mid + 1 } else { hi = mid }
            }
            before[i] = lo > 0 ? tails[lo - 1] : -1
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [Int] = []
        var i = tails.last ?? -1
        while i >= 0 {
            out.append(i)
            i = before[i]
        }
        return out.reversed()
    }

    /// Places about their own middle, so that where two outlines lie does not count in how well
    /// they lie along each other.
    static func centred(_ points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        let sum = points.reduce(CGPoint.zero) { $0 + $1 }
        let middle = sum * (1 / CGFloat(points.count))
        return points.map { $0 - middle }
    }

    /// Which way round a closed run goes: the area its anchors enclose, with its sign.
    static func area(_ run: Run) -> CGFloat {
        var sum: CGFloat = 0
        for i in run.anchors.indices {
            let a = run.anchors[i].point, b = run.anchors[(i + 1) % run.anchors.count].point
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Where along a closed run to begin it, and whether to run it the other way round, so that
    /// it lies along `other` with its points going least far: tried at places evenly along it,
    /// both ways round. Of ways as good as each other, the one that turns it least.
    static func lay(_ m: Measure, along other: Measure) -> (at: Double, turned: Bool) {
        let count = 64
        let mine = centred(m.points(count)), theirs = centred(other.points(other.run.closed ? count : count + 1))
        // The more, the nearer: how far apart they lie, less what no way of laying them changes.
        func fit(_ j: Int, _ turned: Bool) -> Double {
            var sum = 0.0
            for i in theirs.indices {
                let p = mine[((turned ? j - i : j + i) % count + count) % count], q = theirs[i]
                sum += Double(p.x * q.x + p.y * q.y)
            }
            return sum
        }
        let size = (mine + theirs).reduce(0.0) { $0 + Double($1.x * $1.x + $1.y * $1.y) }
        var best = (j: 0, turned: false, fit: fit(0, false))
        for turned in [false, true] {
            for d in 0...(count / 2) {
                for j in (d == 0 || d * 2 == count ? [d] : [d, count - d]) where turned || j != 0 {
                    let f = fit(j, turned)
                    if f > best.fit + size * 1e-9 { best = (j, turned, f) }
                }
            }
        }
        // Between the places tried: where the ones either side say the best is.
        let before = fit(best.j - 1, best.turned), after = fit(best.j + 1, best.turned)
        let bend = before - 2 * best.fit + after
        let off = bend < -size * 1e-12 ? min(max(0.5 * (before - after) / bend, -0.5), 0.5) : 0
        var at = (Double(best.j) + off) / Double(count)
        at -= at.rounded(.down)
        return (at, best.turned)
    }

    /// How far apart two open runs lie, laid along each other end to end, where they are.
    static func apart(_ a: Measure, _ b: Measure, turned: Bool = false) -> Double {
        let count = 33
        let p = a.points(count), q = b.points(count)
        var sum = 0.0
        for i in 0..<count {
            let d = p[i] - q[turned ? count - 1 - i : i]
            sum += Double(d.x * d.x + d.y * d.y)
        }
        return sum
    }

    /// A closed run begun at a place along it, 0 to 1: at the anchor there, when one is within
    /// `room` of it, and else at a new anchor put there.
    static func begun(_ m: Measure, atPlace at: Double, turned: Bool, room: Double) -> Run {
        let run = m.run, n = run.anchors.count
        guard m.total > 1e-12, n > 0 else { return run }
        var near = 0, least = Double.infinity
        for k in 0..<n {
            let d = abs(m.before[k] / m.total - at), round = min(d, 1 - d)
            if round < least {
                near = k
                least = round
            }
        }
        if least <= 0.3 * min(room, m.room(of: near)) { return begun(run, at: near, turned: turned) }
        let length = at * m.total, i = m.curve(at: length)
        let made = cut(run, at: (0..<run.segmentCount).map { $0 == i ? [m.time(i, length - m.before[i])] : [] })
        return begun(made.run, at: made.own[i] + 1, turned: turned)
    }

    /// For each of `values`, which of `others` is nearest it; both in rising order.
    static func nearest(_ values: [Double], in others: [Double]) -> [Int?] {
        guard !others.isEmpty else { return Array(repeating: nil, count: values.count) }
        var k = 0
        return values.map { v in
            while k < others.count - 1, abs(others[k + 1] - v) <= abs(others[k] - v) { k += 1 }
            return k
        }
    }

    /// Two runs, both closed or both open, given the same anchors, each staying the shape it is.
    /// `fixed` are anchors known to be the same in both, as (which of `x`'s, which of `y`'s),
    /// rising in both: the first of them the runs' first anchors, and of open runs the last
    /// their last. Between two of them, as many anchors in the one as in the other are the same
    /// anchors in their order; otherwise each lies as far along the stretch as it does, two that
    /// lie close are one, and any other is given a point on the other run there. Also where each
    /// of `x`'s own anchors comes to be.
    static func zipped(_ x: Run, _ y: Run, fixed: [(Int, Int)]) -> (x: Run, y: Run, own: [Int]) {
        let mx = Measure(x), my = Measure(y)
        var cutsX = [[CGFloat]](repeating: [], count: x.segmentCount), cutsY = [[CGFloat]](repeating: [], count: y.segmentCount)
        var stops = fixed
        if x.closed { stops.append((x.anchors.count, y.anchors.count)) }
        for (from, to) in zip(stops, stops.dropFirst()) {
            let xs = Array((from.0 + 1)..<max(to.0, from.0 + 1)), ys = Array((from.1 + 1)..<max(to.1, from.1 + 1))
            guard xs.count != ys.count else { continue }
            let lx = mx.before[to.0] - mx.before[from.0], ly = my.before[to.1] - my.before[from.1]
            // How far along the stretch each anchor is, 0 to 1; where the stretch is one place, by its number.
            let ax = xs.map { lx > 1e-12 ? (mx.before[$0] - mx.before[from.0]) / lx : Double($0 - from.0) / Double(to.0 - from.0) }
            let ay = ys.map { ly > 1e-12 ? (my.before[$0] - my.before[from.1]) / ly : Double($0 - from.1) / Double(to.1 - from.1) }
            func room(_ at: [Double], _ i: Int) -> Double {
                min(at[i] - (i > 0 ? at[i - 1] : 0), (i < at.count - 1 ? at[i + 1] : 1) - at[i])
            }
            // Two that are each the other's nearest, and close for how far their neighbours are: one anchor.
            let nearY = nearest(ax, in: ay), nearX = nearest(ay, in: ax)
            var pair = [Int?](repeating: nil, count: xs.count)
            var paired = [Bool](repeating: false, count: ys.count)
            var last = -1
            for a in xs.indices {
                guard let b = nearY[a], b > last, nearX[b] == a, abs(ax[a] - ay[b]) <= 0.3 * min(room(ax, a), room(ay, b)) else { continue }
                pair[a] = b
                paired[b] = true
                last = b
            }
            // Along both at once, each anchor in its turn; one with none to go with gets a point
            // on the other run, on the curve after the last anchor passed there.
            var a = 0, b = 0, lastX = from.0, lastY = from.1
            func cutX(_ at: Double) {
                let t = mx.time(lastX, mx.before[from.0] + at * lx - mx.before[lastX])
                cutsX[lastX].append(max(t, cutsX[lastX].last ?? 0))
            }
            func cutY(_ at: Double) {
                let t = my.time(lastY, my.before[from.1] + at * ly - my.before[lastY])
                cutsY[lastY].append(max(t, cutsY[lastY].last ?? 0))
            }
            while a < xs.count || b < ys.count {
                if a < xs.count, let with = pair[a] {
                    if b < with {
                        cutX(ay[b])
                        lastY = ys[b]
                        b += 1
                    } else {
                        lastX = xs[a]
                        lastY = ys[with]
                        a += 1
                        b = with + 1
                    }
                } else if a < xs.count, b >= ys.count || paired[b] || ax[a] <= ay[b] {
                    cutY(ax[a])
                    lastX = xs[a]
                    a += 1
                } else {
                    cutX(ay[b])
                    lastY = ys[b]
                    b += 1
                }
            }
        }
        let made = cut(x, at: cutsX)
        return (made.run, cut(y, at: cutsY).run, made.own)
    }

    /// Two closed runs given the same anchors.
    static func round(_ x: Run, _ y: Run, _ mx: Measure, _ my: Measure) -> (Run, Run) {
        let n = x.anchors.count, m = y.anchors.count
        let twin = twins(x, y)
        let both = twin.indices.filter { twin[$0] != nil }
        guard let start = both.first, let begin = twin[start] else {
            // No anchor of the one lies where one of the other does: laid along each other whole.
            let lay = lay(my, along: mx)
            let made = zipped(x, begun(my, atPlace: lay.at, turned: lay.turned, room: mx.room(of: 0)), fixed: [(0, 0)])
            return (made.x, made.y)
        }
        // Both begun at an anchor they share, the other run the way that keeps more of the
        // anchors they share in their order: the way both go round, where that does not tell.
        func kept(_ turned: Bool) -> [(Int, Int)] {
            let pairs = both.map { (($0 - start + n) % n, place(of: twin[$0] ?? 0, begunAt: begin, turned: turned, count: m)) }
            return rising(pairs.map(\.1)).map { pairs[$0] }
        }
        let same = kept(false), other = kept(true)
        let turned = other.count != same.count ? other.count > same.count : area(x) * area(y) < 0
        let made = zipped(begun(x, at: start, turned: false), begun(y, at: begin, turned: turned), fixed: turned ? other : same)
        // Back to where `x` begins.
        guard start > 0 else { return (made.x, made.y) }
        let first = made.own[(n - start) % n]
        return (begun(made.x, at: first, turned: false), begun(made.y, at: first, turned: false))
    }

    /// Two open runs given the same anchors. With `decided`, they run the same way already.
    static func along(_ x: Run, _ y: Run, _ mx: Measure, _ my: Measure, decided: Bool = false) -> (Run, Run) {
        let m = y.anchors.count
        let twin = twins(x, y)
        func kept(_ turned: Bool) -> [(Int, Int)] {
            let pairs = twin.indices.compactMap { i in twin[i].map { (i, turned ? m - 1 - $0 : $0) } }
            return rising(pairs.map(\.1)).map { pairs[$0] }
        }
        var fixed = kept(false)
        var back = false
        if !decided {
            // The way that keeps more of the anchors they share in their order, or else the way
            // they lie nearer each other.
            let other = kept(true)
            back = other.count != fixed.count ? other.count > fixed.count : apart(mx, my, turned: true) < apart(mx, my) * (1 - 1e-9)
            if back { fixed = other }
        }
        var x = x, y = back ? turned(y) : y
        // A run that goes on past the other's end, where the other has that anchor too: the
        // other's end waits there for each anchor more, so the line grows out of its end.
        func grown(_ run: inout Run, by count: Int, atStart: Bool) {
            if atStart {
                run.anchors[0].handleIn = nil
                run.anchors.insert(contentsOf: Array(repeating: Anchor(run.anchors[0].point), count: count), at: 0)
            } else {
                run.anchors[run.anchors.count - 1].handleOut = nil
                run.anchors.append(contentsOf: Array(repeating: Anchor(run.anchors[run.anchors.count - 1].point), count: count))
            }
        }
        if let first = fixed.first, first.0 == 0, first.1 > 0 {
            grown(&x, by: first.1, atStart: true)
            fixed = (0..<first.1).map { ($0, $0) } + fixed.map { ($0.0 + first.1, $0.1) }
        } else if let first = fixed.first, first.1 == 0, first.0 > 0 {
            grown(&y, by: first.0, atStart: true)
            fixed = (0..<first.0).map { ($0, $0) } + fixed.map { ($0.0, $0.1 + first.0) }
        } else if fixed.first.map({ $0 != (0, 0) }) ?? true {
            fixed = [(0, 0)] + fixed.filter { $0.0 > 0 && $0.1 > 0 }
        }
        let nx = x.anchors.count, ny = y.anchors.count
        if let last = fixed.last, last.0 == nx - 1, last.1 < ny - 1 {
            grown(&x, by: ny - 1 - last.1, atStart: false)
            fixed += (1...(ny - 1 - last.1)).map { (last.0 + $0, last.1 + $0) }
        } else if let last = fixed.last, last.1 == ny - 1, last.0 < nx - 1 {
            grown(&y, by: nx - 1 - last.0, atStart: false)
            fixed += (1...(nx - 1 - last.0)).map { (last.0 + $0, last.1 + $0) }
        } else if fixed.last.map({ $0 != (nx - 1, ny - 1) }) ?? true {
            fixed = fixed.filter { $0.0 < nx - 1 && $0.1 < ny - 1 } + [(nx - 1, ny - 1)]
        }
        let made = zipped(x, y, fixed: fixed)
        return (made.x, made.y)
    }

    /// A closed run opened so as to lie along an open one: at the anchor the open one begins at,
    /// if it has that one, or else where its points go least far.
    static func unrolled(_ c: Run, _ mc: Measure, along o: Run, _ mo: Measure) -> Run {
        let twin = twins(o, c), n = c.anchors.count
        guard let start = twin.first ?? nil else {
            let lay = lay(mc, along: mo)
            return opened(begun(mc, atPlace: lay.at, turned: lay.turned, room: mo.room(of: 0)))
        }
        func kept(_ turned: Bool) -> Int {
            rising(twin.compactMap { $0.map { place(of: $0, begunAt: start, turned: turned, count: n) } }).count
        }
        let same = kept(false), other = kept(true)
        let a = opened(begun(c, at: start, turned: false)), b = opened(begun(c, at: start, turned: true))
        if same != other { return other > same ? b : a }
        return apart(Measure(b), mo) < apart(Measure(a), mo) * (1 - 1e-9) ? b : a
    }

    /// The runs of two outlines, each with the one of the other it goes with, given the same
    /// anchors: `a`'s in their order, then those of `b` that none of `a` goes with. A run with
    /// none to go with has itself gathered in its middle for company, to shrink to or grow from;
    /// `own` says whether the second of a pair is a run `b` has. With `anew`, runs with as many
    /// anchors are looked at too, which else are taken point by point as they are numbered.
    static func matched(_ a: BezierPath, _ b: BezierPath, anew: Bool) -> [(first: Run, second: Run, own: Bool)] {
        let xs = a.subpaths.filter { !$0.anchors.isEmpty }, ys = b.subpaths.filter { !$0.anchors.isEmpty }
        let partner = partners(xs, ys)
        var out: [(first: Run, second: Run, own: Bool)] = []
        var taken = Set<Int>()
        for (i, x) in xs.enumerated() {
            if let j = partner[i] {
                let (p, q) = matched(x, ys[j], anew: anew)
                out.append((p, q, true))
                taken.insert(j)
            } else {
                out.append((x, gathered(x, at: middle(x)), false))
            }
        }
        for (j, y) in ys.enumerated() where !taken.contains(j) { out.append((gathered(y, at: middle(y)), y, true)) }
        return out
    }

    /// Two runs given the same anchors.
    static func matched(_ x: Run, _ y: Run, anew: Bool = false) -> (Run, Run) {
        if !anew, x.anchors.count == y.anchors.count, x.closed == y.closed { return (x, y) }
        let mx = Measure(x), my = Measure(y)
        // A run that is one place: the other grows from it, or shrinks to it.
        if x.anchors.count < 2 || mx.total < 1e-9 { return (gathered(y, at: x.anchors[0].point), y) }
        if y.anchors.count < 2 || my.total < 1e-9 { return (x, gathered(x, at: y.anchors[0].point)) }
        switch (x.closed, y.closed) {
        case (true, true):
            return round(x, y, mx, my)
        case (false, false):
            return along(x, y, mx, my)
        case (true, false):
            let open = unrolled(x, mx, along: y, my)
            return along(open, y, Measure(open), my, decided: true)
        case (false, true):
            let open = unrolled(y, my, along: x, mx)
            return along(x, open, mx, Measure(open), decided: true)
        }
    }

    /// Which run of `ys` each run of `xs` goes with, if any: those nearest each other in place
    /// and size, a closed one with a closed one before an open one. Few runs are tried every
    /// way; many take the nearest first.
    static func partners(_ xs: [Run], _ ys: [Run]) -> [Int?] {
        guard !xs.isEmpty, !ys.isEmpty else { return Array(repeating: nil, count: xs.count) }
        if xs.count == 1, ys.count == 1 { return [0] }
        // Each run's box, from the middle of its whole outline: where the outlines lie does not count.
        func boxes(_ runs: [Run]) -> [CGRect] {
            let all = runs.map(box)
            let whole = all.reduce(CGRect.null) { $0.union($1) }
            return all.map { $0.offsetBy(dx: -whole.midX, dy: -whole.midY) }
        }
        let bx = boxes(xs), by = boxes(ys)
        // How unlike two runs are: closed and open first, then how far apart and how other in size.
        func cost(_ i: Int, _ j: Int) -> (Int, Double) {
            let p = bx[i], q = by[j]
            let apart = hypot(p.midX - q.midX, p.midY - q.midY), sized = hypot(p.width - q.width, p.height - q.height)
            return (xs[i].closed != ys[j].closed ? 1 : 0, Double(apart * apart + sized * sized))
        }
        var out = [Int?](repeating: nil, count: xs.count)
        if max(xs.count, ys.count) <= 6 {
            // Every way of giving each of the fewer one of the more.
            let fewer = xs.count <= ys.count
            let small = fewer ? xs.count : ys.count, large = fewer ? ys.count : xs.count
            var best: [Int] = [], least = (Int.max, Double.infinity)
            var chosen: [Int] = [], used = [Bool](repeating: false, count: large)
            func choose(_ sum: (Int, Double)) {
                guard sum < least else { return }
                if chosen.count == small {
                    best = chosen
                    least = sum
                    return
                }
                let s = chosen.count
                for l in 0..<large where !used[l] {
                    used[l] = true
                    chosen.append(l)
                    let c = fewer ? cost(s, l) : cost(l, s)
                    choose((sum.0 + c.0, sum.1 + c.1))
                    chosen.removeLast()
                    used[l] = false
                }
            }
            choose((0, 0))
            for (s, l) in best.enumerated() {
                if fewer { out[s] = l } else { out[l] = s }
            }
            return out
        }
        var all: [(cost: (Int, Double), x: Int, y: Int)] = []
        for i in xs.indices {
            for j in ys.indices { all.append((cost(i, j), i, j)) }
        }
        all.sort { ($0.cost.0, $0.cost.1, $0.x, $0.y) < ($1.cost.0, $1.cost.1, $1.x, $1.y) }
        var taken = Set<Int>()
        for (_, i, j) in all where out[i] == nil && !taken.contains(j) {
            out[i] = j
            taken.insert(j)
        }
        return out
    }
}
