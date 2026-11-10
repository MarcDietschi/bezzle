import Foundation

/// One cubic curve, from where the last ended.
struct Cubic {
    var c1: V2
    var c2: V2
    var to: V2
}

/// Points along a smooth run, each with the way the run is heading there, fitted with as few
/// cubic curves as stay within a tolerance of them (Philip Schneider's method, Graphics Gems).
enum CurveFit {
    static func fit(_ pts: [V2], _ tangents: [V2], tolerance: Double) -> [Cubic] {
        var out: [Cubic] = []
        guard pts.count >= 2 else { return out }
        fit(pts, tangents, 0, pts.count - 1, tangents[0], -tangents[pts.count - 1], tolerance * tolerance, &out, 0)
        return out
    }

    private static func point(_ p0: V2, _ c: Cubic, _ t: Double) -> V2 {
        let s = 1 - t
        return p0 * (s * s * s) + c.c1 * (3 * s * s * t) + c.c2 * (3 * s * t * t) + c.to * (t * t * t)
    }

    private static func fit(_ pts: [V2], _ tan: [V2], _ first: Int, _ last: Int, _ t0: V2, _ t1: V2, _ tol2: Double,
                            _ out: inout [Cubic], _ depth: Int) {
        let p0 = pts[first], p3 = pts[last]
        if last - first == 1 {
            let d = length(p3 - p0) / 3
            out.append(Cubic(c1: p0 + t0 * d, c2: p3 + t1 * d, to: p3))
            return
        }
        // Each point's place along the curve, by how far along the points it is.
        var u = [Double](repeating: 0, count: last - first + 1)
        for i in 1..<u.count { u[i] = u[i - 1] + length(pts[first + i] - pts[first + i - 1]) }
        let total = u[u.count - 1]
        guard total > 1e-9 else {
            out.append(Cubic(c1: p0, c2: p3, to: p3))
            return
        }
        for i in 0..<u.count { u[i] /= total }

        var curve = generate(pts, first, last, u, t0, t1)
        var (worst, split) = error(pts, first, last, p0, curve, u)
        if worst < tol2 {
            out.append(curve)
            return
        }
        // Near enough for moving each point's place along the curve to bring it within reach.
        if worst < tol2 * 16 || depth > 24 {
            for _ in 0..<4 {
                for i in 1..<(u.count - 1) { u[i] = nearer(p0, curve, pts[first + i], u[i]) }
                curve = generate(pts, first, last, u, t0, t1)
                (worst, split) = error(pts, first, last, p0, curve, u)
                if worst < tol2 || depth > 24 {
                    out.append(curve)
                    return
                }
            }
        }
        split = min(max(split, first + 1), last - 1)
        let through = tan[split]
        fit(pts, tan, first, split, t0, -through, tol2, &out, depth + 1)
        fit(pts, tan, split, last, through, t1, tol2, &out, depth + 1)
    }

    /// The curve from the first point to the last, leaving along `t0` and arriving against `t1`,
    /// that comes nearest the points between.
    private static func generate(_ pts: [V2], _ first: Int, _ last: Int, _ u: [Double], _ t0: V2, _ t1: V2) -> Cubic {
        let p0 = pts[first], p3 = pts[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for i in 0..<u.count {
            let t = u[i], s = 1 - t
            let b0 = s * s * s, b1 = 3 * s * s * t, b2 = 3 * s * t * t, b3 = t * t * t
            let a0 = t0 * b1, a1 = t1 * b2
            c00 += dot(a0, a0); c01 += dot(a0, a1); c11 += dot(a1, a1)
            let rest = pts[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += dot(a0, rest); x1 += dot(a1, rest)
        }
        let det = c00 * c11 - c01 * c01
        let chord = length(p3 - p0)
        var left = 0.0, right = 0.0
        if abs(det) > 1e-12 {
            left = (x0 * c11 - x1 * c01) / det
            right = (c00 * x1 - c01 * x0) / det
        }
        // The pulls must lead on from each end, and no further than the run is long; where the
        // sums say otherwise, a third of the way.
        let least = 1e-6 * max(chord, 1e-6)
        var run = 0.0
        for i in first..<last { run += length(pts[i + 1] - pts[i]) }
        if left < least || right < least || !left.isFinite || !right.isFinite || left > run || right > run {
            left = run / 3
            right = run / 3
        }
        return Cubic(c1: p0 + t0 * left, c2: p3 + t1 * right, to: p3)
    }

    private static func error(_ pts: [V2], _ first: Int, _ last: Int, _ p0: V2, _ c: Cubic, _ u: [Double]) -> (Double, Int) {
        var worst = 0.0, at = (first + last) / 2
        for i in 1..<(u.count - 1) {
            let d = point(p0, c, u[i]) - pts[first + i]
            let e = dot(d, d)
            if e >= worst { worst = e; at = first + i }
        }
        return (worst, at)
    }

    /// Where along the curve it is nearest `p`, one step of Newton's on from `t`.
    private static func nearer(_ p0: V2, _ c: Cubic, _ p: V2, _ t: Double) -> Double {
        let s = 1 - t
        let q = point(p0, c, t)
        let d1 = (c.c1 - p0) * (3 * s * s) + (c.c2 - c.c1) * (6 * s * t) + (c.to - c.c2) * (3 * t * t)
        let d2 = (c.c2 - c.c1 * 2 + p0) * (6 * s) + (c.to - c.c2 * 2 + c.c1) * (6 * t)
        let num = dot(q - p, d1), den = dot(d1, d1) + dot(q - p, d2)
        guard abs(den) > 1e-12 else { return t }
        return min(max(t - num / den, 0), 1)
    }
}

/// An outline in samples, as it comes out of fitting: a start, and lines and curves from there.
struct Fitted {
    enum Part {
        case line(V2)
        case curve(Cubic)

        var end: V2 {
            switch self {
            case .line(let p): p
            case .curve(let c): c.to
            }
        }
    }

    var start: V2
    var parts: [Part] = []
    var figure: Figure?
}

/// Turns the walks round a shape into outlines: sharp corners kept sharp, straight sides straight
/// and level ones level, everything between as few smooth curves as follow it.
///
/// The polygon of fewest sides (`Polygon`) says where the corners and the straight sides are;
/// between those, curves are fitted to the walk itself, the middle of each of its steps, which
/// lie evenly to both sides of the edge the walk follows.
struct Fitter {
    /// Samples across a pixel.
    let scale: Double
    /// How far a curve may run from the outline it follows, in samples.
    var tolerance: Double
    /// How far a corner must stand out to stay sharp.
    var sharpness: Double
    /// How far a straight side may stray from the walk it follows, in samples: 1 for a walk
    /// along a picture's own pixels, more the finer the picture is read.
    var slack: Double
    /// The tightest bend between two straight sides that is kept round, as its radius in
    /// samples; a tighter one is a sharp corner the pixels blunted.
    var pointed: Double
    /// Pixel art: every corner of every square kept.
    let exact: Bool
    /// How far each sample lies from the edge beside it (`Labels.near`), and the samples' rows
    /// and columns.
    var near: Store<UInt8>?
    var W = 0
    var H = 0
    /// Which region each sample is of, where each region lies in the stack, and which lower
    /// region reaches under each sample: what a shape may lie under without showing.
    var cover: Cover?
    /// How much more an outline is let stray from an edge that wavers than from a clean one.
    var loose = 1.0
    /// How many more times a walk is smoothed before curves are fitted to it: for the outline
    /// of something thin in a picture that wavers, whose two edges else waver each its own way.
    var calmer = 0

    struct Cover: @unchecked Sendable {
        let id: Store<Int32>
        let rank: [Int32]
        let under: Store<Int32>
        /// How far each region reaches under those over it, in samples.
        let lap: Int
    }

    /// The outline along a walk round region `me`.
    func outline(_ walk: Walk, of me: Int32 = -1) -> Fitted? {
        let n = walk.corners.count
        guard n >= 3 else { return nil }
        if exact {
            var out = Fitted(start: point(walk.corners[0]))
            for k in 1..<n { out.parts.append(.line(point(walk.corners[k]))) }
            out.parts.append(.line(out.start))
            return out
        }
        let anyHidden = walk.hidden.contains(true), anyShown = walk.hidden.contains(false)
        if !anyHidden || !anyShown {
            // All of it shows; or none of it, and it runs under other shapes as calmly as it can.
            let fitter = anyShown ? self : sunk
            let polygon = Polygon.fit(walk.corners, closed: true, sharpness: fitter.sharpness, slack: fitter.slack)
            guard polygon.v.count >= 3 else { return nil }
            let made = fitter.parts(of: polygon, along: walk.corners)
            var out = Fitted(start: made.start, parts: made.parts)
            if walk.area2 > 0, anyShown { out.figure = made.figure }
            return straightened(out)
        }
        // In turn the stretches that show, and those hidden under other shapes.
        // Begun where a stretch that shows begins.
        var from = 0
        for k in 0..<n where !walk.hidden[k] && walk.hidden[(k + n - 1) % n] { from = k; break }
        struct Run {
            var hidden: Bool
            var points: [SIMD2<Int32>]
            var parts: [Fitted.Part] = []
            /// Whether its outline runs straight on under the shapes it meets, at each end.
            var onAtStart = false, onAtEnd = false
        }
        var runs: [Run] = []
        var k = from
        repeat {
            let hidden = walk.hidden[k % n]
            var points = [walk.corners[k % n]]
            repeat {
                k += 1
                points.append(walk.corners[k % n])
            } while k < from + n && walk.hidden[k % n] == hidden
            runs.append(Run(hidden: hidden, points: points))
        } while k < from + n
        // What shows is followed with care.
        for i in runs.indices where !runs[i].hidden {
            let points = runs[i].points
            if points.count == 2 {
                runs[i].parts = [.line(point(points[1]))]
            } else {
                let polygon = Polygon.fit(points, closed: false, sharpness: sharpness, slack: slack)
                runs[i].parts = parts(of: polygon, along: points).parts
            }
        }
        /// Which way a path heads as it begins, and whether straight.
        func heading(_ start: V2, _ parts: [Fitted.Part]) -> (d: V2, straight: Bool)? {
            guard let first = parts.first else { return nil }
            switch first {
            case .line(let p): return length(p - start) > 1e-6 ? (unit(p - start), true) : nil
            case .curve(let c):
                let d = length(c.c1 - start) > 1e-6 ? c.c1 - start : c.c2 - start
                return length(d) > 1e-6 ? (unit(d), false) : nil
            }
        }
        // Where an edge meets a shape lying over it, the pixels are of three colours and say
        // little: the edge is taken to run straight on under that shape from a little before.
        let near = max(1, loose) * scale, on = 1.5 * scale
        // What is hidden runs on as the shape was heading where it went under, when all of
        // that lies under other shapes; else straight across; else along under their edges.
        for i in runs.indices where runs[i].hidden {
            let points = runs[i].points
            let b = (i + runs.count - 1) % runs.count, f = (i + 1) % runs.count
            let before = runs[b], after = runs[f]
            let j0 = point(points[0]), j1 = point(points[points.count - 1])
            let beforeStart = point(before.points[0])
            // Both edges carried on under, then as they were fitted.
            let tail = Fitter.carriedOn(beforeStart, before.parts, near: near, on: on)
            let back = Fitter.reversed(point(after.points[0]), after.parts)
            let head = Fitter.carriedOn(back.start, back.parts, near: near, on: on)
            var made: [Fitted.Part]?
            if let tail, let head, let leaving = heading(tail.end, [.line(tail.end + tail.heading)]),
               let way = under(points, of: me, from: tail.end, to: head.end, leaving: (leaving.d, tail.straight), arriving: (-head.heading, head.straight)) {
                made = way
                runs[b].onAtEnd = true
                runs[f].onAtStart = true
            } else {
                let ahead = Fitter.reversed(beforeStart, before.parts)
                if let leaving = heading(ahead.start, ahead.parts), let arriving = heading(point(after.points[0]), after.parts),
                   let way = under(points, of: me, from: j0, to: j1, leaving: (-leaving.d, leaving.straight), arriving: arriving) {
                    made = way
                }
            }
            if let made {
                runs[i].parts = made
            } else if points.count == 2 {
                runs[i].parts = [.line(j1)]
            } else {
                let fitter = sunk
                let polygon = Polygon.fit(points, closed: false, sharpness: fitter.sharpness, slack: fitter.slack)
                runs[i].parts = fitter.parts(of: polygon, along: points).parts
            }
        }
        var out = Fitted(start: point(walk.corners[from]))
        for (i, run) in runs.enumerated() {
            guard !run.hidden else {
                out.parts += run.parts
                continue
            }
            var start = point(run.points[0]), parts = run.parts
            if run.onAtEnd, let carried = Fitter.carriedOn(start, parts, near: near, on: on) { parts = carried.parts }
            if run.onAtStart {
                let back = Fitter.reversed(start, parts)
                if let carried = Fitter.carriedOn(back.start, back.parts, near: near, on: on) {
                    let again = Fitter.reversed(back.start, carried.parts)
                    start = again.start
                    parts = again.parts
                }
            }
            if i == 0 { out.start = start } else if run.onAtStart { out.parts.append(.line(start)) }
            out.parts += parts
        }
        // Back to where it began, when that was carried on.
        if let last = out.parts.last, length(last.end - out.start) > 1e-6 { out.parts.append(.line(out.start)) }
        // No stretch of no length.
        var kept: [Fitted.Part] = []
        var at = out.start
        for part in out.parts {
            if case .line(let p) = part, length(p - at) < 1e-6 { continue }
            kept.append(part)
            at = part.end
        }
        out.parts = kept
        return straightened(out)
    }

    /// Straight stretches one after another that lie along one line are one line: a long side
    /// comes out of the fitting in pieces where a bump in its edge, or the end of a stretch
    /// that shows, parted it.
    private func straightened(_ fitted: Fitted) -> Fitted {
        let parts = fitted.parts
        guard parts.count >= 3 else { return fitted }
        let give = 0.2 * scale * max(1, loose)
        func straight(_ from: V2, _ part: Fitted.Part) -> Bool {
            guard case .curve(let c) = part else { return true }
            let chord = c.to - from, l = length(chord)
            guard l > 1e-9 else { return false }
            return abs(cross(c.c1 - from, chord)) / l <= 0.5 * give && abs(cross(c.c2 - from, chord)) / l <= 0.5 * give
                && dot(c.c1 - from, chord) >= 0 && dot(c.to - c.c2, chord) >= 0
        }
        /// Whether `between` all lie along the way from `a` to `b`, in their order.
        func along(_ a: V2, _ b: V2, _ between: [V2]) -> Bool {
            let chord = b - a, l = length(chord)
            guard l > 1e-9 else { return false }
            var last = 0.0
            for m in between {
                let far = dot(m - a, chord) / l
                guard abs(cross(m - a, chord)) / l <= give, far >= last, far <= l else { return false }
                last = far
            }
            return true
        }
        var out: [Fitted.Part] = []
        var from = fitted.start, i = 0
        while i < parts.count {
            guard straight(from, parts[i]) else {
                out.append(parts[i])
                from = parts[i].end
                i += 1
                continue
            }
            var j = i, between: [V2] = []
            while j + 1 < parts.count, straight(parts[j].end, parts[j + 1]), along(from, parts[j + 1].end, between + [parts[j].end]) {
                between.append(parts[j].end)
                j += 1
            }
            out.append(j > i ? .line(parts[j].end) : parts[i])
            from = parts[j].end
            i = j + 1
        }
        var start = fitted.start
        // And over where the outline begins.
        if out.count >= 4, case .line(let next) = out[0], case .line = out[out.count - 1] {
            let before = out[out.count - 2].end
            if along(before, next, [start]) {
                start = before
                out.removeLast()
            }
        }
        guard out.count >= 2, out.count < parts.count else { return fitted }
        var made = fitted
        made.start = start
        made.parts = out
        return made
    }

    /// A path the other way round.
    private static func reversed(_ start: V2, _ parts: [Fitted.Part]) -> (start: V2, parts: [Fitted.Part]) {
        guard let last = parts.last else { return (start, parts) }
        var out: [Fitted.Part] = []
        for i in stride(from: parts.count - 1, through: 0, by: -1) {
            let to = i > 0 ? parts[i - 1].end : start
            switch parts[i] {
            case .line: out.append(.line(to))
            case .curve(let c): out.append(.curve(Cubic(c1: c.c2, c2: c.c1, to: to)))
            }
        }
        return (last.end, out)
    }

    /// A path cut where it comes within `near` of its end, and carried straight on from there,
    /// `on` past where it ended: where it ends then, and which way it was heading. Nil for a
    /// path too short to say which way it heads.
    private static func carriedOn(_ start: V2, _ parts: [Fitted.Part], near: Double, on: Double)
        -> (parts: [Fitted.Part], end: V2, heading: V2, straight: Bool)? {
        guard let last = parts.last else { return nil }
        let end = last.end
        guard length(start - end) > 4 * near else { return nil }
        // The last stretch that begins further off than `near`.
        var k = parts.count - 1
        while k > 0, length(parts[k - 1].end - end) <= near { k -= 1 }
        let from = k > 0 ? parts[k - 1].end : start
        guard length(from - end) > near else { return nil }
        var out = Array(parts[0..<k])
        switch parts[k] {
        case .line(let p):
            let d = p - from, l = length(d)
            guard l > 1e-6 else { return nil }
            // Where the line comes within `near` of the end.
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if length(from + d * mid - end) > near { lo = mid } else { hi = mid }
            }
            guard lo * l > 2 * near else { return nil }
            let cut = from + d * lo, heading = d / l
            let to = cut + heading * (length(cut - end) + on)
            out.append(.line(to))
            return (out, to, heading, true)
        case .curve(let c):
            func at(_ t: Double) -> V2 {
                let r = 1 - t
                return from * (r * r * r) + c.c1 * (3 * r * r * t) + c.c2 * (3 * r * t * t) + c.to * (t * t * t)
            }
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if length(at(mid) - end) > near { lo = mid } else { hi = mid }
            }
            guard lo > 0.3 else { return nil }
            // The curve up to there, and straight on.
            let t = lo
            let p01 = from + (c.c1 - from) * t, p12 = c.c1 + (c.c2 - c.c1) * t, p23 = c.c2 + (c.to - c.c2) * t
            let p012 = p01 + (p12 - p01) * t, p123 = p12 + (p23 - p12) * t
            let cut = p012 + (p123 - p012) * t
            let d = cut - p012
            guard length(d) > 1e-6 else { return nil }
            let heading = unit(d)
            let to = cut + heading * (length(cut - end) + on)
            // One curve when what is added is little beside it; else the curve and a line on.
            let added = length(to - cut), had = length(cut - from)
            if added <= 0.35 * had {
                let stretch = 1 + added / max(had, 1e-6)
                out.append(.curve(Cubic(c1: from + (p01 - from) * stretch, c2: to - heading * (length(cut - p012) * stretch), to: to)))
            } else {
                out.append(.curve(Cubic(c1: p01, c2: p012, to: cut)))
                out.append(.line(to))
            }
            return (out, to, heading, false)
        }
    }

    /// As this, for an outline no one sees: it need only stay under the shapes over it.
    private var sunk: Fitter {
        var f = self
        let lap = Double(cover?.lap ?? Int(scale))
        f.tolerance = max(tolerance, 0.35 * lap)
        f.slack = max(slack, 0.6 * lap)
        return f
    }

    // MARK: Under other shapes

    /// A hidden stretch of a shape's outline, drawn as the shape would run on were nothing over
    /// it: on from the way it was heading where it went under, to the way it heads where it
    /// comes out again, as one corner, one curve or one line. Nil when no such way stays hidden.
    private func under(_ points: [SIMD2<Int32>], of me: Int32, from a: V2, to b: V2, leaving: (d: V2, straight: Bool)?,
                       arriving: (d: V2, straight: Bool)?) -> [Fitted.Part]? {
        guard cover != nil, me >= 0, points.count >= 2 else { return nil }
        let chord = b - a, far = length(chord)
        guard far > 1e-6 else { return nil }
        var ways: [[Fitted.Part]] = []
        if let leaving, let arriving {
            let d0 = leaving.d, d1 = arriving.d
            let turn = abs(atan2(cross(d0, d1), dot(d0, d1)))
            let det = cross(d0, d1)
            // Where the two headings meet, ahead of where it went under and behind where it comes out.
            var meet: V2?
            var s = 0.0, u = 0.0
            if abs(det) > 1e-6 {
                s = cross(chord, d1) / det
                u = cross(chord, d0) / det
                if s > 0.5, u > 0.5, s < 6 * far, u < 6 * far { meet = a + d0 * s }
            }
            let onward = abs(cross(d0, unit(chord))) < 0.06 && abs(cross(d1, unit(chord))) < 0.06 && dot(d0, chord) > 0 && dot(d1, chord) > 0
            if onward {
                ways.append([.line(b)])
            } else {
                var corner: [Fitted.Part]?, bend: [Fitted.Part]?
                if let meet, turn > 0.3 { corner = [.line(meet), .line(b)] }
                if let meet {
                    // As a circle would round it, when both ends are as far from where they meet.
                    let k = turn < 3 ? 4.0 / 3 * tan(turn / 4) / max(tan(turn / 2), 1e-6) : 0.66
                    bend = [.curve(Cubic(c1: a + d0 * (s * k), c2: b - d1 * (u * k), to: b))]
                } else if dot(d0, chord) > 0, dot(d1, chord) > 0 {
                    bend = [.curve(Cubic(c1: a + d0 * (far / 3), c2: b - d1 * (far / 3), to: b))]
                }
                // Two straight edges meet in a corner, others in a bend.
                let first = leaving.straight && arriving.straight ? [corner, bend] : [bend, corner]
                for way in first { if let way { ways.append(way) } }
            }
        }
        ways.append([.line(b)])
        for way in ways where hides(way, from: a, insteadOf: points, of: me) { return way }
        return nil
    }

    /// Whether a shape whose outline ran along `way` instead of along the hidden stretch
    /// `points` would show nowhere it does not now, and still lie under the edges it lies
    /// under: everything between the two is of shapes over it.
    private func hides(_ way: [Fitted.Part], from start: V2, insteadOf points: [SIMD2<Int32>], of me: Int32) -> Bool {
        guard let cover else { return false }
        let mine = cover.rank[Int(me)]
        let a = point(points[0]), b = point(points[points.count - 1])
        // Round between the two: along the hidden stretch, and back along the way.
        var round: [V2] = points.map { point($0) }
        var back: [V2] = [start]
        var at = start
        for part in way {
            switch part {
            case .line(let p): back.append(p)
            case .curve(let c):
                let steps = max(8, Int((length(c.c1 - at) + length(c.c2 - c.c1) + length(c.to - c.c2)) / 2))
                for i in 1...steps {
                    let t = Double(i) / Double(steps), r = 1 - t
                    back.append(at * (r * r * r) + c.c1 * (3 * r * r * t) + c.c2 * (3 * r * t * t) + c.to * (t * t * t))
                }
            }
            at = part.end
        }
        for p in back where p.x < 0 || p.y < 0 || p.x > Double(W) || p.y > Double(H) { return false }
        round += back.reversed()
        var minX = Double.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for p in round { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        let top = max(Int(minY.rounded(.down)), 0), bottom = min(Int(maxY.rounded(.up)), H)
        guard bottom > top, (maxX - minX) * (maxY - minY) <= 6_000_000 else { return false }
        // Where each row of samples is crossed, and which way.
        var crossings = [[(x: Double, way: Int)]](repeating: [], count: bottom - top)
        let count = round.count
        for i in 0..<count {
            let p = round[i], q = round[(i + 1) % count]
            guard p.y != q.y else { continue }
            let low = min(p.y, q.y), high = max(p.y, q.y)
            var row = max(Int((low - 0.5).rounded(.up)), top)
            while row < bottom, Double(row) + 0.5 < high {
                let y = Double(row) + 0.5
                if y >= low { crossings[row - top].append((p.x + (q.x - p.x) * (y - p.y) / (q.y - p.y), q.y > p.y ? 1 : -1)) }
                row += 1
            }
        }
        let id = cover.id.p, lower = cover.under.p
        // Near its two ends the way may cut across what lies under an edge: there the shape's
        // own edge runs out from under it.
        let reach = max(3 * scale, 2 * Double(cover.lap))
        for row in 0..<(bottom - top) where crossings[row].count >= 2 {
            let sorted = crossings[row].sorted { $0.x < $1.x }
            var winding = 0
            for k in 0..<(sorted.count - 1) {
                winding += sorted[k].way
                guard winding != 0 else { continue }
                var X = max(Int((sorted[k].x - 0.5).rounded(.up)), 0)
                let Y = row + top
                while X < W, Double(X) + 0.5 < sorted[k + 1].x {
                    let i = Y * W + X
                    let other = id[i]
                    if other == me || cover.rank[Int(other)] <= mine { return false }
                    if lower[i] == me {
                        let c = V2(Double(X) + 0.5, Double(Y) + 0.5)
                        if length(c - a) > reach, length(c - b) > reach { return false }
                    }
                    X += 1
                }
            }
        }
        return true
    }

    private func point(_ p: SIMD2<Int32>) -> V2 { V2(Double(p.x), Double(p.y)) }

    /// A walk step by step: the middle of each step, moved to where the edge was found between
    /// the shape's sample and the one outside it; whether it was found there, or only that the
    /// edge lies between the two; and where each corner's steps begin.
    func walked(_ corners: [SIMD2<Int32>], closed: Bool) -> (steps: [V2], found: [Bool], firstStep: [Int]) {
        let n = corners.count
        var steps: [V2] = []
        var found: [Bool] = []
        var firstStep = [Int](repeating: 0, count: n + 1)
        // The samples on the left and the right hand of a step, from the corner it begins at,
        // heading down, right, up and left (as in `Stack.walks`).
        let leftX = [0, 0, -1, -1], leftY = [0, -1, -1, 0], rightX = [-1, 0, 0, -1], rightY = [0, 0, -1, -1]
        for c in 0..<(closed ? n : n - 1) {
            firstStep[c] = steps.count
            let a = corners[c], b = corners[(c + 1) % n]
            let count = Int(max(abs(b.x - a.x), abs(b.y - a.y)))
            guard count > 0 else { continue }
            let p = point(a), u = (point(b) - p) / Double(count)
            let heading = b.y > a.y ? 0 : b.x > a.x ? 1 : b.y < a.y ? 2 : 3
            let outward = V2(Double(rightX[heading] - leftX[heading]), Double(rightY[heading] - leftY[heading]))
            for s in 0..<count {
                var q = p + u * (Double(s) + 0.5)
                var exact = near == nil
                if let near {
                    // Where between the shape's sample and the one outside it the edge was found.
                    let cx = Int(a.x) + Int(u.x) * s, cy = Int(a.y) + Int(u.y) * s
                    let ix = cx + leftX[heading], iy = cy + leftY[heading]
                    let ox = cx + rightX[heading], oy = cy + rightY[heading]
                    let inside = ix >= 0 && iy >= 0 && ix < W && iy < H ? Double(near.p[iy * W + ix]) : 255
                    let outside = ox >= 0 && oy >= 0 && ox < W && oy < H ? Double(near.p[oy * W + ox]) : 255
                    var f = 0.5
                    exact = inside < 254 || outside < 254
                    if inside < 254, outside < 254 {
                        if inside + outside > 0 { f = inside / (inside + outside) }
                    } else if inside < 254 {
                        f = min(inside / 32, 1)
                    } else if outside < 254 {
                        f = 1 - min(outside / 32, 1)
                    }
                    q += outward * (min(max(f, 0.02), 0.98) - 0.5)
                }
                steps.append(q)
                found.append(exact)
            }
        }
        firstStep[closed ? n : n - 1] = steps.count
        firstStep[n] = steps.count
        return (steps, found, firstStep)
    }

    /// How unsteady the edge a walk follows is, for each stretch of it that shows: how far its
    /// steps stray from running on as they do, in samples. A drawn edge strays hardly at all; one
    /// from a blurred or a coarsely kept picture wanders by a good part of a pixel.
    func wobbles(_ walk: Walk) -> [Float] {
        let n = walk.corners.count
        guard n >= 3 else { return [] }
        let (steps, _, firstStep) = walked(walk.corners, closed: true)
        let N = steps.count
        let lag = max(2, Int(scale.rounded()))
        guard N >= 6 * lag else { return [] }
        var hidden = [Bool](repeating: false, count: N)
        for c in 0..<n where walk.hidden[c] { for i in firstStep[c]..<firstStep[c + 1] { hidden[i] = true } }
        var out: [Float] = []
        out.reserveCapacity(N / 2)
        var i = 0
        while i < N {
            let a = (i + N - lag) % N, c = (i + lag) % N, e = (i + 2 * lag) % N
            if !hidden[a], !hidden[i], !hidden[c], !hidden[e] {
                let chord = steps[e] - steps[a], l = length(chord)
                if l > 1e-6 {
                    // Nothing for a straight run or an even bend; only for what comes and goes.
                    let third = (steps[e] - steps[a]) * 0.5 + (steps[i] - steps[c]) * 1.5
                    out.append(Float(abs(cross(chord, third)) / l / 2.236))
                }
            }
            i += 2
        }
        return out
    }

    // MARK: From a polygon to lines and curves

    private struct Made {
        var start: V2
        var parts: [Fitted.Part]
        var figure: Figure?
    }

    /// Which sides of a polygon are straight lines of the outline itself, not the chords of a
    /// bend, and how much of each end of such a side the bend at that end takes (`reach`, for
    /// each corner). The walk bows out from a chord as far as a side is let stray from it, and
    /// from a straight side hardly at all.
    private func straightSides(_ polygon: Polygon, _ reach: [Double]) -> (isLine: [Bool], cutA: [Double], cutB: [Double]) {
        let v = polygon.v, sharp = polygon.sharp, closed = polygon.closed
        let m = v.count, sides = closed ? m : m - 1
        // An edge that wavers bows as far as it wavers, and is still straight.
        let flat = (0.25 + 0.07 * scale) * loose, lean = 0.035 * loose.squareRoot()
        var isLine = [Bool](repeating: false, count: sides)
        var cutA = [Double](repeating: 0, count: sides), cutB = [Double](repeating: 0, count: sides)
        for k in 0..<sides {
            let j = (k + 1) % m
            let L = length(v[j] - v[k])
            if sharp[k] && sharp[j] {
                isLine[k] = true
                continue
            }
            // Straight: hardly bowed, and so long that its ends lean no way one could see.
            guard L >= max(3 * scale, 8), abs(polygon.bow[k]) <= flat, 4 * abs(polygon.bow[k]) / L <= lean else { continue }
            if !sharp[k] { cutA[k] = reach[k] + 0.25 * scale }
            if !sharp[j] { cutB[k] = reach[j] + 0.25 * scale }
            // Enough of it must be left between its bends.
            if cutA[k] + cutB[k] > 0.75 * L || L - cutA[k] - cutB[k] < 1.5 * scale {
                cutA[k] = 0; cutB[k] = 0
                continue
            }
            isLine[k] = true
        }
        return (isLine, cutA, cutB)
    }

    /// Corners a picture's pixels have blunted, made sharp again: where two straight sides are
    /// joined by a bend so tight that no round corner could be told from a sharp one at the
    /// picture's size, the sides are carried on to where they meet.
    /// A long straight edge that wavers has a bump here and there, which the polygon goes
    /// round with a few short sides: where two straight sides lie along one line with only a
    /// short, low way round between them, they are one side.
    private func bridging(_ polygon: Polygon, _ isLine: [Bool]) -> Polygon? {
        let v = polygon.v, m = v.count, closed = polygon.closed
        let sides = closed ? m : m - 1
        guard m >= 5 else { return nil }
        let low = 0.5 * loose * scale, short = 3.5 * loose * scale
        var gone = [Bool](repeating: false, count: m)
        var any = false
        var k = 0
        while k < sides {
            guard isLine[k], !gone[k] else { k += 1; continue }
            let a = v[k], b = v[(k + 1) % m]
            let d = unit(b - a), la = length(b - a)
            // The next straight side along the same line, at most four corners on.
            var found = -1
            var way = 0.0
            for step in 1...4 {
                let j = k + step
                guard closed ? j < k + m - 1 : j < sides else { break }
                let c = v[j % m], e = v[(j + 1) % m]
                // Every corner between keeps near the line.
                guard abs(cross(c - a, d)) <= low else { break }
                if step > 1 { way += length(c - v[(j - 1) % m]) }
                guard way <= short else { break }
                if isLine[j % m], !gone[j % m] {
                    let lb = length(e - c)
                    let along = unit(e - c)
                    if dot(along, d) > 0.9990, abs(cross(e - a, d)) <= low, min(la, lb) >= max(2 * way, 3 * scale) {
                        found = j
                        break
                    }
                }
            }
            guard found > k else { k += 1; continue }
            for j in (k + 1)...found { gone[j % m] = true }
            any = true
            k = found
        }
        guard any else { return nil }
        var out = Polygon(v: [], sharp: [], bend: [], bow: [], at: [], closed: closed)
        for j in 0..<m where !gone[j] {
            out.v.append(v[j]); out.sharp.append(polygon.sharp[j]); out.bend.append(polygon.bend[j])
            out.bow.append(0); out.at.append(polygon.at[j])
        }
        return out.v.count >= 3 ? out : nil
    }

    private func pointing(_ polygon: Polygon, _ isLine: [Bool], worn: Double = 0) -> Polygon? {
        let v = polygon.v, m = v.count, closed = polygon.closed
        let sides = closed ? m : m - 1
        var corner = [V2?](repeating: nil, count: m), gone = [Bool](repeating: false, count: m)
        var any = false
        for k in 0..<sides where isLine[k] {
            // The bend after this line: corners that are not sharp, up to the next line.
            var chain: [Int] = []
            var j = (k + 1) % m
            var after = -1
            while chain.count < 5, !polygon.sharp[j], !gone[j], corner[j] == nil, closed || j < m - 1 {
                chain.append(j)
                if j < sides, isLine[j] { after = j; break }
                j = (j + 1) % m
                if j == (k + 1) % m { break }
            }
            guard after >= 0, after != k, !chain.isEmpty else { continue }
            let a0 = v[k], a1 = v[(k + 1) % m], b0 = v[after], b1 = v[(after + 1) % m]
            let da = unit(a1 - a0), db = unit(b1 - b0)
            let turn = abs(atan2(cross(da, db), dot(da, db)))
            guard turn >= 0.35, turn <= 2.97 else { continue }
            let det = cross(da, db)
            let meet = a0 + da * (cross(b0 - a0, db) / det)
            // It lies ahead of the first line and behind the second, and not far.
            let ahead = dot(meet - a1, da), behind = dot(b0 - meet, db)
            guard ahead >= -0.5 * scale, behind >= -0.5 * scale else { continue }
            guard ahead <= 0.75 * length(a1 - a0) + scale, behind <= 0.75 * length(b1 - b0) + scale else { continue }
            // How far the bend cuts the corner off, and the radius of the round corner that would.
            var depth = Double.greatestFiniteMagnitude
            let path = [a1] + chain.map { v[$0] } + [b0]
            for i in 0..<(path.count - 1) {
                let p = path[i], q = path[i + 1], d = q - p
                let l2 = dot(d, d)
                let t = l2 > 1e-12 ? min(max(dot(meet - p, d) / l2, 0), 1) : 0
                depth = min(depth, length(meet - (p + d * t)))
            }
            let half = (.pi - turn) / 2
            let radius = depth / max(1 / sin(half) - 1, 1e-6)
            guard radius <= pointed || depth <= worn else { continue }
            corner[chain[0]] = meet
            for j in chain.dropFirst() { gone[j] = true }
            any = true
        }
        guard any else { return nil }
        var out = Polygon(v: [], sharp: [], bend: [], bow: [], at: [], closed: closed)
        for j in 0..<m where !gone[j] {
            out.v.append(corner[j] ?? v[j])
            out.sharp.append(corner[j] != nil || polygon.sharp[j])
            out.bend.append(polygon.bend[j])
            // The side on from a corner made sharp is the line that came after its bend.
            out.bow.append(corner[j] != nil ? 0 : polygon.bow[j])
            out.at.append(polygon.at[j])
        }
        return out.v.count >= 3 ? out : nil
    }

    private func parts(of first: Polygon, along corners: [SIMD2<Int32>]) -> Made {
        let closed = first.closed
        let n = corners.count
        var (steps, found, firstStep) = walked(corners, closed: closed)
        let N = steps.count
        guard N > 0 else { return Made(start: first.v[0], parts: first.v.dropFirst().map { .line($0) }) }
        /// The first step after corner `k` of a polygon, which may be counted on past the last.
        func stepAt(_ polygon: Polygon, _ k: Int) -> Int {
            let m = polygon.v.count
            let c = polygon.at[k % m] + (k / m) * n
            return closed ? firstStep[c % n] + (c / n) * N : firstStep[min(c, n - 1)]
        }
        /// How round each corner of a polygon is, as the radius of the round corner that would
        /// stay as far from where its sides meet as the walk does; and how far along its two
        /// sides such a bend reaches.
        func bends(_ polygon: Polygon) -> (radius: [Double], reach: [Double], depth: [Double]) {
            let v = polygon.v, m = v.count
            var radii = [Double](repeating: 0, count: m), out = [Double](repeating: 0, count: m), depths = [Double](repeating: 0, count: m)
            for k in 0..<m where closed || (k > 0 && k < m - 1) {
                let before = v[k] - v[(k + m - 1) % m], after = v[(k + 1) % m] - v[k]
                let turn = abs(atan2(cross(before, after), dot(before, after)))
                guard turn > 1e-3 else { continue }
                let at = stepAt(polygon, k)
                let span = min(60, N / 2)
                var depth = Double.greatestFiniteMagnitude
                for i in (at - span)...(at + span) {
                    guard closed || (i >= 0 && i < N) else { continue }
                    depth = min(depth, length(steps[((i % N) + N) % N] - v[k]))
                }
                let half = (.pi - turn) / 2
                radii[k] = depth / max(1 / sin(half) - 1, 1e-6)
                depths[k] = depth
                if !polygon.sharp[k] { out[k] = min(radii[k] / max(tan(half), 1e-6), length(before) / 2, length(after) / 2) }
            }
            return (radii, out, depths)
        }

        /// How far the walk bows out from each side of a polygon in its middle, measured where
        /// the edge was found between the samples.
        func bows(_ polygon: Polygon) -> [Double] {
            let v = polygon.v, m = v.count
            var out = [Double](repeating: 0, count: m)
            for k in 0..<(closed ? m : m - 1) {
                let a = stepAt(polygon, k), b = stepAt(polygon, k + 1)
                guard b - a >= 8 else { continue }
                let d = unit(v[(k + 1) % m] - v[k]), normal = V2(-d.y, d.x)
                let q1 = a + (b - a) / 4, q3 = a + (b - a) * 3 / 4
                var ends = 0.0, middle = 0.0
                for i in a..<b {
                    let off = dot(steps[i % N] - v[k], normal)
                    if i < q1 || i >= q3 { ends += off } else { middle += off }
                }
                out[k] = 2 * (middle / Double(q3 - q1) - ends / Double(b - a - (q3 - q1)))
            }
            return out
        }

        var polygon = first
        polygon.bow = bows(polygon)
        // A corner the walk stays well clear of is no sharp one, but where a line runs into a
        // bend. Along an edge that wavers, a corner is worn down by as much as the edge wavers,
        // and still one.
        let worn = loose > 1 ? 0.45 * loose * scale : 0
        let round = bends(polygon)
        for k in 0..<polygon.v.count where polygon.sharp[k] && (closed || (k > 0 && k < polygon.v.count - 1)) {
            if round.radius[k] > 1.5 * max(pointed, scale), round.depth[k] > worn { polygon.sharp[k] = false }
        }
        var reach = bends(polygon).reach
        var (isLine, cutA, cutB) = straightSides(polygon, reach)
        if loose > 1, let bridged = bridging(polygon, isLine) {
            polygon = bridged
            polygon.bow = bows(polygon)
            reach = bends(polygon).reach
            (isLine, cutA, cutB) = straightSides(polygon, reach)
        }
        if pointed > 0, let sharper = pointing(polygon, isLine, worn: worn) {
            polygon = sharper
            polygon.bow = bows(polygon)
            reach = bends(polygon).reach
            (isLine, cutA, cutB) = straightSides(polygon, reach)
        }
        var v = polygon.v
        let m = v.count
        let sharp = polygon.sharp
        let sides = closed ? m : m - 1

        func stepAt(_ k: Int) -> Int { stepAt(polygon, k) }

        // Each line laid again, through where the edge was found between its bends: the
        // polygon's side was laid through the walk round the samples, and through the
        // beginnings of the bends at its ends. Lines all but level are level, and all but
        // upright, upright. The corners then lie where the lines meet.
        var laid = [(c: V2, d: V2)?](repeating: nil, count: m)
        for k in 0..<sides where isLine[k] {
            let j = (k + 1) % m
            let d0 = unit(v[j] - v[k]), L = length(v[j] - v[k])
            let a = v[k] + d0 * (cutA[k] + (sharp[k] ? scale : 0)), b = v[j] - d0 * (cutB[k] + (sharp[j] ? scale : 0))
            var n = 0.0, sum = V2(0, 0), xx = 0.0, xy = 0.0, yy = 0.0
            for i in stepAt(k)..<stepAt(k + 1) {
                let p = steps[i % N]
                guard dot(p - a, d0) >= 0, dot(b - p, d0) >= 0 else { continue }
                let q = p - v[k]
                n += 1
                sum += q
                xx += q.x * q.x; xy += q.x * q.y; yy += q.y * q.y
            }
            var line = (c: (v[k] + v[j]) / 2, d: d0)
            if n >= 6 {
                let c = sum / n
                let sxx = xx / n - c.x * c.x, sxy = xy / n - c.x * c.y, syy = yy / n - c.y * c.y
                let lambda = (sxx + syy + ((sxx - syy) * (sxx - syy) + 4 * sxy * sxy).squareRoot()) / 2
                var d = abs(lambda - sxx) > abs(lambda - syy) ? V2(sxy, lambda - sxx) : V2(lambda - syy, sxy)
                if length(d) > 1e-9 {
                    d = unit(d)
                    if dot(d, d0) < 0 { d = -d }
                    // Only where it says what the side said, more exactly.
                    if abs(cross(d, d0)) < 0.08, abs(cross(c + v[k] - line.c, d0)) < 2 { line = (c + v[k], d) }
                }
            }
            if L >= 3 * scale {
                if abs(line.d.y) * L <= max(0.3, 0.004 * L) {
                    line.d = V2(line.d.x < 0 ? -1 : 1, 0)
                } else if abs(line.d.x) * L <= max(0.3, 0.004 * L) {
                    line.d = V2(0, line.d.y < 0 ? -1 : 1)
                }
            }
            laid[k] = line
        }
        var moved = v
        for k in 0..<m {
            let before = closed || k > 0 ? laid[(k + m - 1) % m] : nil
            let after = k < sides ? laid[k] : nil
            if let before, let after, abs(cross(before.d, after.d)) > 0.05 {
                moved[k] = before.c + before.d * (cross(after.c - before.c, after.d) / cross(before.d, after.d))
            } else if let line = after ?? before {
                moved[k] = line.c + line.d * dot(v[k] - line.c, line.d)
            }
            // Never far from where it was.
            if length(moved[k] - v[k]) > 2.5 { moved[k] = v[k] }
        }
        v = moved

        // Which way the outline heads along each side: as the side does, but for where a bend
        // reaches into it; there it turns, at a corner that is not sharp to halfway between
        // its two sides, at a sharp one to how the side's bow leaves it.
        var along = [V2](repeating: V2(1, 0), count: m), far = [Double](repeating: 1, count: m)
        for k in 0..<sides {
            let d = v[(k + 1) % m] - v[k]
            far[k] = max(length(d), 1e-9)
            along[k] = unit(d)
        }
        func lean(_ k: Int) -> V2 {
            let slope = min(max(4 * polygon.bow[k] / max(far[k], 1), -0.35), 0.35)
            return V2(-along[k].y, along[k].x) * slope
        }
        func leaving(_ k: Int) -> V2 {
            if sharp[k] || (!closed && k == 0) { return unit(along[k] + lean(k)) }
            return unit(along[(k + m - 1) % m] + along[k])
        }
        func arriving(_ k: Int) -> V2 {
            let j = (k + 1) % m
            if sharp[j] || (!closed && j == m - 1) { return unit(along[k] - lean(k)) }
            return unit(along[k] + along[j])
        }
        /// How far into a side the turning at one of its ends is felt.
        func turning(_ corner: Int, _ side: Int) -> Double {
            if sharp[corner] || (!closed && (corner == 0 || corner == m - 1)) { return far[side] / 2 }
            return min(max(2 * reach[corner], scale), far[side] / 2)
        }
        func heading(_ side: Int, _ i: Int) -> V2 {
            let k = side % m
            let a = stepAt(side), b = stepAt(side + 1)
            let f = b > a ? (Double(i - a) + 0.5) / Double(b - a) : 0.5
            let done = f * far[k], left = (1 - f) * far[k]
            let first = turning(k, k), last = turning((k + 1) % m, k)
            if done < first {
                let from = leaving(k)
                return unit(from + (along[k] - from) * (done / first))
            }
            if left < last {
                let to = arriving(k)
                return unit(to + (along[k] - to) * (left / last))
            }
            return along[k]
        }

        // Where the outline breaks: at each sharp corner, and where each line begins and ends.
        enum Kind { case corner, lineStart, lineEnd }
        struct Break {
            var kind: Kind
            var k: Int
            var p: V2
            /// The last step before it and the first after it that curves may be fitted to.
            var before: Int
            var after: Int
        }
        var breaks: [Break] = []
        for k in 0..<m {
            if sharp[k] {
                let i = stepAt(k)
                breaks.append(Break(kind: .corner, k: k, p: v[k], before: i - 2, after: i + 1))
            }
            guard k < sides, isLine[k] else { continue }
            let from = stepAt(k), to = stepAt(k + 1)
            let a = v[k] + along[k] * cutA[k], b = v[(k + 1) % m] - along[k] * cutB[k]
            var i = from
            while i < to - 1, dot(steps[i % N] - a, along[k]) < 0 { i += 1 }
            var j = to - 1
            while j > i, dot(steps[j % N] - b, along[k]) > 0 { j -= 1 }
            breaks.append(Break(kind: .lineStart, k: k, p: a, before: i - 1, after: i))
            breaks.append(Break(kind: .lineEnd, k: k, p: b, before: j, after: j + 1))
        }

        var parts: [Fitted.Part] = []
        var runs: [[V2]] = []
        /// Curves through `pts`, heading as `tangents` say, added to the outline. `rough` is how
        /// much of the run was only followed round the samples, 0…1: such a run is followed
        /// less closely, as it still has their stairs in it.
        func fit(_ pts: [V2], _ tangents: [V2], rough: Double) {
            runs.append(pts)
            var from = pts[0]
            for c in CurveFit.fit(pts, tangents, tolerance: tolerance * (1 + rough)) {
                // A curve that is a line is one.
                let chord = c.to - from, l = length(chord)
                if l > 1e-9, abs(cross(c.c1 - from, chord)) / l < 0.03, abs(cross(c.c2 - from, chord)) / l < 0.03,
                   dot(c.c1 - from, chord) >= 0, dot(c.to - c.c2, chord) >= 0 {
                    parts.append(.line(c.to))
                } else {
                    parts.append(.curve(c))
                }
                from = c.to
            }
        }
        /// The walk's steps smoothed a little, so what is left of its stairs pulls no curve about;
        /// and more along an edge that wavers.
        let calm = min(Int((3 * (loose - 1)).rounded()), 6) + calmer
        func smoothed(_ pts: [V2], round: Bool, rough: Double) -> [V2] {
            var a = pts
            let count = a.count
            guard count >= (round ? 5 : 4) else { return a }
            for _ in 0..<(1 + Int((4 * rough).rounded()) + calm) {
                var b = a
                if round {
                    for i in 0..<count { b[i] = (a[(i + count - 1) % count] + a[i] * 2 + a[(i + 1) % count]) / 4 }
                } else {
                    for i in 1..<(count - 1) { b[i] = (a[i - 1] + a[i] * 2 + a[i + 1]) / 4 }
                }
                a = b
            }
            return a
        }

        var start = v[0]
        if breaks.isEmpty {
            // Smooth all round: one run from a step back to itself.
            var pts: [V2] = [], tangents: [V2] = []
            pts.reserveCapacity(N + 1)
            let from = stepAt(0)
            var side = 0
            for i in from..<(from + N) {
                while side < 2 * m, i >= stepAt(side + 1) { side += 1 }
                pts.append(steps[i % N])
                tangents.append(heading(side, i))
            }
            let rough = Double(found.reduce(0) { $0 + ($1 ? 0 : 1) }) / Double(N)
            pts = smoothed(pts, round: true, rough: rough)
            pts.append(pts[0])
            tangents.append(tangents[0])
            start = pts[0]
            fit(pts, tangents, rough: rough)
        } else {
            start = breaks[0].p
            let count = closed ? breaks.count : breaks.count - 1
            for at in 0..<max(count, 0) {
                let x = breaks[at]
                var y = breaks[(at + 1) % breaks.count]
                if at + 1 == breaks.count {
                    // Round over the walk's start, back to the first.
                    y.k += m
                    y.before += N
                }
                if x.kind == .lineStart, y.kind == .lineEnd {
                    parts.append(.line(y.p))
                    continue
                }
                // Nothing between a corner and the line from it; but an outline with one
                // corner alone runs all the way round to it.
                guard length(y.p - x.p) > 1e-6 || y.before - x.after >= 4 else { continue }
                var pts = [x.p], tangents = [x.kind == .lineEnd ? along[x.k % m] : leaving(x.k % m)]
                var side = x.k
                var loose = 0
                if x.after <= y.before {
                    for i in x.after...y.before {
                        while side < 2 * m, i >= stepAt(side + 1) { side += 1 }
                        let p = steps[i % N]
                        if !found[i % N] { loose += 1 }
                        if length(p - pts[pts.count - 1]) < 1e-6 { continue }
                        pts.append(p)
                        tangents.append(heading(side, i))
                    }
                }
                if pts.count > 1, length(y.p - pts[pts.count - 1]) < 1e-6 {
                    pts.removeLast()
                    tangents.removeLast()
                }
                pts.append(y.p)
                tangents.append(y.kind == .lineStart ? along[y.k % m] : arriving((y.k + m - 1) % m))
                if pts.count == 2, x.kind == .corner, y.kind == .corner {
                    parts.append(.line(y.p))
                    continue
                }
                let rough = Double(loose) / Double(max(y.before - x.after + 1, 1))
                fit(smoothed(pts, round: false, rough: rough), tangents, rough: rough)
            }
        }

        var made = Made(start: start, parts: parts)
        if closed { made.figure = figure(v, sharp: sharp, isLine: isLine, runs: runs) }
        return made
    }

    // MARK: Rectangles and ellipses

    /// The shape as a rectangle, with or without round corners, or an ellipse, when it is one to
    /// within what the eye could tell.
    private func figure(_ v: [V2], sharp: [Bool], isLine: [Bool], runs: [[V2]]) -> Figure? {
        let m = v.count
        let near = max(0.7, 0.35 * scale)
        func degrees(_ d: V2) -> Double { atan2(d.y, d.x) * 180 / .pi }
        func rectangle(_ corners: [V2], radius: Double) -> Figure? {
            let a = corners[1] - corners[0], b = corners[2] - corners[1]
            let c = corners[3] - corners[2], d = corners[0] - corners[3]
            let w = (length(a) + length(c)) / 2, h = (length(b) + length(d)) / 2
            guard w > 2 * scale, h > 2 * scale else { return nil }
            guard abs(length(a) - length(c)) <= max(1.2, 0.02 * w), abs(length(b) - length(d)) <= max(1.2, 0.02 * h) else { return nil }
            for (p, q) in [(a, b), (b, c), (c, d), (d, a)] {
                let cosine = dot(unit(p), unit(q))
                guard abs(cosine) < 0.035 else { return nil }
            }
            let center = (corners[0] + corners[1] + corners[2] + corners[3]) / 4
            // Turned as little as says the same: the side nearest level is its width.
            var angle = degrees(a), width = w, height = h
            while angle > 45 { angle -= 90; swap(&width, &height) }
            while angle <= -45 { angle += 90; swap(&width, &height) }
            if abs(angle) < 0.4 { angle = 0 }
            return .rectangle(center: Spot(center.x / scale, center.y / scale), width: width / scale, height: height / scale,
                              radius: min(radius, width / 2, height / 2) / scale, angle: angle)
        }

        if m == 4, sharp.allSatisfy({ $0 }) { return rectangle(v, radius: 0) }
        guard !sharp.contains(true) else { return nil }
        let lines = (0..<m).filter { isLine[$0] }

        if lines.count == 4 {
            // Round corners: the lines carried on meet at the rectangle's own, and how far the
            // outline stays from each says how round it is.
            var corners: [V2] = []
            var radii: [Double] = []
            for i in 0..<4 {
                let k = lines[i], l = lines[(i + 1) % 4]
                let p = v[k], d = unit(v[(k + 1) % m] - v[k]), q = v[l], e = unit(v[(l + 1) % m] - v[l])
                let det = cross(d, e)
                guard abs(det) > 0.5 else { return nil }
                let corner = p + d * (cross(q - p, e) / det)
                corners.append(corner)
                var depth = Double.greatestFiniteMagnitude
                for run in runs { for p in run { depth = min(depth, length(p - corner)) } }
                radii.append(depth / (2.0.squareRoot() - 1))
            }
            let radius = radii.reduce(0, +) / 4
            guard radii.allSatisfy({ abs($0 - radius) <= max(1.5, 0.15 * radius) }) else { return nil }
            // `corners[i]` lies after line i: the rectangle's corners in the lines' order.
            let ordered = [corners[3], corners[0], corners[1], corners[2]]
            guard let made = rectangle(ordered, radius: radius) else { return nil }
            // Every bend a quarter circle of that radius about its corner's centre.
            for i in 0..<4 {
                let k = lines[i], l = lines[(i + 1) % 4]
                let d = unit(v[(k + 1) % m] - v[k]), e = unit(v[(l + 1) % m] - v[l])
                let center = corners[i] - d * radius + e * radius
                for run in runs {
                    for p in run where dot(p - center, d) >= 0 && dot(p - center, e) <= 0 {
                        if abs(length(p - center) - radius) > near { return nil }
                    }
                }
            }
            return made
        }

        if lines.count == 2 {
            // A pill: two sides and half circles between.
            let k = lines[0], l = lines[1]
            let d = unit(v[(k + 1) % m] - v[k]), e = unit(v[(l + 1) % m] - v[l])
            guard dot(d, e) < -0.999 else { return nil }
            let across = abs(cross(v[l] - v[k], d))
            let radius = across / 2
            let middle = (v[k] + v[l]) / 2
            var least = Double.greatestFiniteMagnitude, most = -Double.greatestFiniteMagnitude
            for run in runs {
                for p in run {
                    let s = dot(p - middle, d)
                    least = min(least, s); most = max(most, s)
                }
            }
            guard most - least >= across else { return nil }
            let c1 = middle + d * (most - radius), c2 = middle + d * (least + radius)
            for run in runs {
                for p in run {
                    let s = dot(p - middle, d)
                    let off: Double
                    if s > most - radius {
                        off = abs(length(p - c1) - radius)
                    } else if s < least + radius {
                        off = abs(length(p - c2) - radius)
                    } else {
                        off = min(abs(cross(p - v[k], d)), abs(cross(p - v[l], e)))
                    }
                    if off > near { return nil }
                }
            }
            let center = (c1 + c2) / 2
            var angle = degrees(d)
            if angle > 90 { angle -= 180 }
            if angle <= -90 { angle += 180 }
            var w = most - least, h = across
            if angle > 45 { angle -= 90; swap(&w, &h) }
            if angle <= -45 { angle += 90; swap(&w, &h) }
            if abs(angle) < 0.4 { angle = 0 }
            return .rectangle(center: Spot(center.x / scale, center.y / scale), width: w / scale, height: h / scale,
                              radius: radius / scale, angle: angle)
        }

        guard lines.isEmpty, let run = runs.first, runs.count == 1, run.count >= 8 else { return nil }
        // An ellipse has the area, the middle and the spread of its outline's: from those its
        // axes, and then every point of the outline must lie on it.
        var area = 0.0, cx = 0.0, cy = 0.0, ixx = 0.0, iyy = 0.0, ixy = 0.0
        let o = run[0]
        for i in 0..<(run.count - 1) {
            let p = run[i] - o, q = run[i + 1] - o
            let a = cross(p, q)
            area += a
            cx += (p.x + q.x) * a
            cy += (p.y + q.y) * a
            ixx += (p.x * p.x + p.x * q.x + q.x * q.x) * a
            iyy += (p.y * p.y + p.y * q.y + q.y * q.y) * a
            ixy += (p.x * q.y + 2 * p.x * p.y + 2 * q.x * q.y + q.x * p.y) * a
        }
        area /= 2
        guard abs(area) > 4 * scale * scale else { return nil }
        cx /= 6 * area; cy /= 6 * area
        let sxx = ixx / (12 * area) - cx * cx, syy = iyy / (12 * area) - cy * cy, sxy = ixy / (24 * area) - cx * cy
        let spread = ((sxx - syy) * (sxx - syy) + 4 * sxy * sxy).squareRoot()
        let l1 = (sxx + syy + spread) / 2, l2 = (sxx + syy - spread) / 2
        guard l1 > 0, l2 > 0 else { return nil }
        var a = 2 * l1.squareRoot(), b = 2 * l2.squareRoot()
        guard b >= 1.5 * scale else { return nil }
        var angle = spread > 1e-9 * (sxx + syy) ? atan2(l1 - sxx, sxy) : 0
        if abs(sxy) < 1e-12 { angle = sxx >= syy ? 0 : .pi / 2 }
        let center = V2(cx, cy) + o
        let allowed = max(near, 0.012 * b)
        let ux = V2(cos(angle), sin(angle)), uy = V2(-sin(angle), cos(angle))
        for p in run {
            let d = p - center
            let x = dot(d, ux) / a, y = dot(d, uy) / b
            let f = (x * x + y * y).squareRoot()
            guard f > 1e-9 else { return nil }
            // How far from the ellipse, about: along the line from its middle.
            if abs(1 - 1 / f) * length(d) > allowed { return nil }
        }
        if abs(a - b) <= max(near, 0.015 * a) {
            a = (a + b) / 2; b = a; angle = 0
        }
        var turned = angle * 180 / .pi
        if turned > 90 { turned -= 180 }
        if turned <= -90 { turned += 180 }
        if turned > 45 { turned -= 90; swap(&a, &b) }
        if turned <= -45 { turned += 90; swap(&a, &b) }
        if abs(turned) < 0.4 { turned = 0 }
        return .ellipse(center: Spot(center.x / scale, center.y / scale), radiusX: a / scale, radiusY: b / scale, angle: turned)
    }
}
