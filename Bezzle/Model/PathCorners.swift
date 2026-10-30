import CoreGraphics

/// The corners of an outline, and rounding them: what the dots inside a path's corners work on.
/// A corner is a point where the outline turns sharply, or a curve that rounds off two straight
/// sides the way rounding leaves it, so it can be rounded more, less or not at all again.
nonisolated extension BezierPath {
    struct Corner: Equatable {
        /// The point at the corner, or the first of the two that round it.
        var at: PathPoint
        var rounded: Bool
        /// Where the sides meet, or would without the round.
        var tip: CGPoint
        /// Unit lengths from the tip: back along the side coming in, and on along the side going out.
        var back: CGPoint
        var on: CGPoint
        var radius: CGFloat
        /// Whether both sides are straight, as only then a round can be found again afterwards.
        var straight: Bool

        /// Between the two sides: π for no turn at all, near 0 for a spike.
        var angle: CGFloat { acos(min(max(back.x * on.x + back.y * on.y, -1), 1)) }
        /// Halfway between the sides, the way the round's centre lies from the tip.
        var inward: CGPoint { BezierPath.unit(back + on) }
    }

    /// Every corner of the outline, each run's in order.
    var corners: [Corner] {
        var found: [Corner] = []
        for s in subpaths.indices {
            let run = subpaths[s], n = run.anchors.count
            guard n >= 3 || (run.closed && n >= 2) else { continue }
            var i = 0
            while i < n {
                if let round = roundCorner(s, i) {
                    // Its second point is part of it. (Across the end of a closed run, that is the
                    // first, which runs smoothly into the round, so was never taken for a corner.)
                    found.append(round)
                    i += 2
                    continue
                }
                if let sharp = sharpCorner(s, i) { found.append(sharp) }
                i += 1
            }
        }
        return found
    }

    /// The anchor as a sharp corner: the outline turns there by more than a few degrees.
    private func sharpCorner(_ s: Int, _ i: Int) -> Corner? {
        let run = subpaths[s]
        guard let b = run.before(i), let a = run.after(i) else { return nil }
        let p = run.anchors[i], prev = run.anchors[b], next = run.anchors[a]
        let back = Self.firstWay(from: p.point, [p.handleIn, prev.handleOut, prev.point])
        let on = Self.firstWay(from: p.point, [p.handleOut, next.handleIn, next.point])
        guard back != .zero, on != .zero else { return nil }
        let c = Corner(at: PathPoint(subpath: s, index: i), rounded: false, tip: p.point, back: back, on: on, radius: 0,
                       straight: p.handleIn == nil && prev.handleOut == nil && p.handleOut == nil && next.handleIn == nil)
        // Between a spike and a turn too slight to see.
        guard c.angle > 0.03, c.angle < .pi * 172 / 180 else { return nil }
        return c
    }

    /// The curve from anchor `i` to the next as a round between two straight sides: it leaves and
    /// arrives along them, as far from where they meet at each end, with handles as a circle's arc has.
    private func roundCorner(_ s: Int, _ i: Int) -> Corner? {
        let run = subpaths[s], n = run.anchors.count
        guard n >= 4 || (run.closed && n >= 3) else { return nil }
        guard let j = run.after(i), let b = run.before(i), let a = run.after(j), b != j, a != i else { return nil }
        let p = run.anchors[i], q = run.anchors[j], prev = run.anchors[b], next = run.anchors[a]
        guard let h1 = p.handleOut, let h2 = q.handleIn, p.handleIn == nil, prev.handleOut == nil,
              q.handleOut == nil, next.handleIn == nil else { return nil }
        let along1 = Self.unit(p.point - prev.point), along2 = Self.unit(q.point - next.point)
        let out1 = h1 - p.point, out2 = h2 - q.point
        let l1 = Self.length(out1), l2 = Self.length(out2)
        guard l1 > 0.001, l2 > 0.001, along1 != .zero, along2 != .zero else { return nil }
        // The handles carry the sides on.
        func lines(_ u: CGPoint, _ v: CGPoint) -> Bool { abs(u.x * v.y - u.y * v.x) < 0.01 && u.x * v.x + u.y * v.y > 0 }
        guard lines(along1, Self.unit(out1)), lines(along2, Self.unit(out2)) else { return nil }
        // Where the sides would meet: p + along1·d1 = q + along2·d2.
        let den = along1.x * along2.y - along1.y * along2.x
        guard abs(den) > 0.0001 else { return nil }
        let w = q.point - p.point
        let d1 = (w.x * along2.y - w.y * along2.x) / den, d2 = (w.x * along1.y - w.y * along1.x) / den
        guard d1 > 0.001, d2 > 0.001, abs(d1 - d2) <= max(d1, d2) * 0.03 + 0.01 else { return nil }
        let tip = p.point + along1 * d1
        let c = Corner(at: PathPoint(subpath: s, index: i), rounded: true, tip: tip, back: along1 * -1, on: along2 * -1, radius: 0, straight: true)
        let t = (d1 + d2) / 2, theta = c.angle
        guard theta > 0.03, theta < .pi * 172 / 180 else { return nil }
        // A circle's arc has handles this much of the way to the tip.
        let k = Self.handleShare(theta)
        guard abs(l1 / t - k) < 0.12, abs(l2 / t - k) < 0.12 else { return nil }
        var round = c
        round.radius = t * tan(theta / 2)
        return round
    }

    /// For a round between sides at `angle`, how far along from where it leaves a side to the tip its handle reaches.
    static func handleShare(_ angle: CGFloat) -> CGFloat {
        let turn = .pi - angle
        return 4 / 3 * tan(turn / 4) * tan(angle / 2)
    }

    private static func firstWay(from p: CGPoint, _ candidates: [CGPoint?]) -> CGPoint {
        for c in candidates {
            if let c, !same(c, p) { return unit(c - p) }
        }
        return .zero
    }

    // MARK: Rounding

    /// The outline with each corner in `radii` (by where it is) rounded to its radius, or made
    /// sharp again at 0. A round never takes more than is there of a side: half, where the corner
    /// at its other end is rounded too. Also gives the radius each corner could have.
    func rounding(_ radii: [PathPoint: CGFloat]) -> (path: BezierPath, radii: [PathPoint: CGFloat]) {
        var result = self, applied: [PathPoint: CGFloat] = [:]
        let found = corners
        for s in subpaths.indices {
            let mine = found.filter { $0.at.subpath == s && radii[$0.at] != nil }
            guard !mine.isEmpty else { continue }
            let (run, done) = Self.round(subpaths[s], mine.map { ($0, radii[$0.at]!) })
            result.subpaths[s] = run
            for (at, r) in done { applied[PathPoint(subpath: s, index: at)] = r }
        }
        return (result, applied)
    }

    /// One run with its corners rounded. Rounds are made sharp first, so each is worked out from its tip.
    private static func round(_ run: Subpath, _ wanted: [(Corner, CGFloat)]) -> (Subpath, [Int: CGFloat]) {
        // The run with the chosen rounds back to sharp points, and what each point is to become.
        var anchors: [Anchor] = [], target: [Int: (corner: Corner, radius: CGFloat)] = [:]
        let byIndex = Dictionary(wanted.map { ($0.0.at.index, $0) }, uniquingKeysWith: { a, _ in a })
        // The second point of each round, which its tip stands in for. Across the end of a closed
        // run that is the first; the run then starts a point later, which a closed run does not mind.
        let seconds = Set(wanted.filter(\.0.rounded).map { ($0.0.at.index + 1) % run.anchors.count })
        for (i, a) in run.anchors.enumerated() where !seconds.contains(i) {
            if let (c, r) = byIndex[i] {
                target[anchors.count] = (c, r)
                anchors.append(c.rounded ? Anchor(c.tip) : a)
            } else {
                anchors.append(a)
            }
        }
        var sharp = Subpath(anchors: anchors, closed: run.closed)
        let count = sharp.anchors.count
        guard count >= 3 else { return (run, [:]) }

        // Each segment as its four points, and how long it is.
        func segment(_ i: Int) -> [CGPoint] {
            let a = sharp.anchors[i], b = sharp.anchors[(i + 1) % count]
            return [a.point, a.handleOut ?? a.point, b.handleIn ?? b.point, b.point]
        }
        let segments = (0..<sharp.segmentCount).map(segment)
        let lengths = segments.map(Self.length(of:))

        // How far along each side every round reaches: as the radius asks, within what is there.
        var reach: [Int: CGFloat] = [:], applied: [Int: CGFloat] = [:]
        for (i, t) in target {
            guard let before = sharp.before(i), sharp.after(i) != nil else { continue }
            let theta = t.corner.angle
            let limitIn = lengths[before] * (target[before] != nil ? 0.5 : 0.98)
            let limitOut = lengths[i] * (target[(i + 1) % count] != nil ? 0.5 : 0.98)
            let most = min(limitIn, limitOut)
            let want = max(t.radius, 0) / tan(theta / 2)
            reach[i] = min(want, most)
            applied[i] = (min(want, most) * tan(theta / 2) * 100).rounded() / 100
        }
        // Where each segment now starts and ends, as a share of the way along it.
        var trimmed: [[CGPoint]] = []
        for (i, seg) in segments.enumerated() {
            let start = reach[i].map { Self.share(of: seg, at: $0, fromEnd: false) } ?? 0
            let end = reach[(i + 1) % count].map { Self.share(of: seg, at: $0, fromEnd: true) } ?? 1
            trimmed.append(Self.part(of: seg, from: start, to: max(end, start)))
        }
        // The points again: a rounded corner is two, joined by the round.
        var out: [Anchor] = []
        for i in 0..<count {
            let into = sharp.before(i).map { trimmed[$0] }, from = i < trimmed.count ? trimmed[i] : nil
            func handleIn(_ seg: [CGPoint]?) -> CGPoint? { seg.flatMap { same($0[2], $0[3]) ? nil : $0[2] } }
            func handleOut(_ seg: [CGPoint]?) -> CGPoint? { seg.flatMap { same($0[1], $0[0]) ? nil : $0[1] } }
            guard let r = reach[i], r > 0.001, let into, let from else {
                var a = sharp.anchors[i]
                a.handleIn = sharp.before(i) == nil ? a.handleIn : handleIn(into)
                a.handleOut = from == nil ? a.handleOut : handleOut(from)
                out.append(a)
                continue
            }
            let p1 = into[3], p2 = from[0]
            let t1 = unit(tangent(into, atEnd: true)), t2 = unit(tangent(from, atEnd: false))
            let turn = acos(min(max(t1.x * t2.x + t1.y * t2.y, -1), 1))
            let chord = length(p2 - p1)
            let radius = turn > 0.0001 ? chord / (2 * sin(turn / 2)) : 0
            let h = 4 / 3 * tan(turn / 4) * radius
            out.append(Anchor(p1, in: handleIn(into), out: p1 + t1 * h))
            out.append(Anchor(p2, in: p2 - t2 * h, out: handleOut(from)))
        }
        // Rounds that took all of a side between them meet in one point.
        var merged: [Anchor] = []
        for a in out {
            if let last = merged.last, same(last.point, a.point) {
                merged[merged.count - 1].handleOut = a.handleOut
            } else {
                merged.append(a)
            }
        }
        if run.closed, merged.count > 1, let last = merged.last, same(last.point, merged[0].point) {
            merged[0].handleIn = last.handleIn
            merged.removeLast()
        }
        sharp.anchors = merged

        // Which corner each radius went to, by where it was in the run handed in.
        var done: [Int: CGFloat] = [:]
        for (i, t) in target { done[t.corner.at.index] = applied[i] ?? 0 }
        return (sharp, done)
    }

    // MARK: Curves

    private static func tangent(_ c: [CGPoint], atEnd: Bool) -> CGPoint {
        if atEnd {
            for q in [c[2], c[1], c[0]] where !same(q, c[3]) { return c[3] - q }
        } else {
            for q in [c[1], c[2], c[3]] where !same(q, c[0]) { return q - c[0] }
        }
        return .zero
    }

    private static func at(_ c: [CGPoint], _ t: CGFloat) -> CGPoint {
        point(on: (c[0], c[1], c[2], c[3]), at: t)
    }

    /// How long a curve is, near enough.
    static func length(of c: [CGPoint]) -> CGFloat {
        if same(c[1], c[0]) && same(c[2], c[3]) { return length(c[3] - c[0]) }
        var total: CGFloat = 0, last = c[0]
        for k in 1...32 {
            let p = at(c, CGFloat(k) / 32)
            total += length(p - last)
            last = p
        }
        return total
    }

    /// How far along a curve, as a share of the way, lies the place `distance` from its start or end.
    private static func share(of c: [CGPoint], at distance: CGFloat, fromEnd: Bool) -> CGFloat {
        if same(c[1], c[0]) && same(c[2], c[3]) {
            let l = length(c[3] - c[0])
            guard l > 0 else { return fromEnd ? 1 : 0 }
            return fromEnd ? 1 - distance / l : distance / l
        }
        let steps = 64
        var walked: CGFloat = 0, last = at(c, fromEnd ? 1 : 0)
        for k in 1...steps {
            let t = fromEnd ? 1 - CGFloat(k) / CGFloat(steps) : CGFloat(k) / CGFloat(steps)
            let p = at(c, t)
            let step = length(p - last)
            if walked + step >= distance {
                let f = step > 0 ? (distance - walked) / step : 0
                let previous = fromEnd ? 1 - CGFloat(k - 1) / CGFloat(steps) : CGFloat(k - 1) / CGFloat(steps)
                return previous + (t - previous) * f
            }
            walked += step
            last = p
        }
        return fromEnd ? 0 : 1
    }

    /// The part of a curve between two shares of the way along it, as a curve of its own.
    private static func part(of c: [CGPoint], from t0: CGFloat, to t1: CGFloat) -> [CGPoint] {
        if same(c[1], c[0]) && same(c[2], c[3]) {
            let a = c[0] + (c[3] - c[0]) * t0, b = c[0] + (c[3] - c[0]) * t1
            return [a, a, b, b]
        }
        func split(_ c: [CGPoint], _ t: CGFloat) -> ([CGPoint], [CGPoint]) {
            func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { a + (b - a) * t }
            let ab = mix(c[0], c[1]), bc = mix(c[1], c[2]), cd = mix(c[2], c[3])
            let abc = mix(ab, bc), bcd = mix(bc, cd), m = mix(abc, bcd)
            return ([c[0], ab, abc, m], [m, bcd, cd, c[3]])
        }
        var rest = c
        if t0 > 0 { rest = split(c, t0).1 }
        guard t1 < 1 else { return rest }
        let local = t0 < 1 ? (t1 - t0) / (1 - t0) : 0
        return split(rest, local).0
    }
}
