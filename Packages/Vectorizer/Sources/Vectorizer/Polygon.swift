import Foundation

typealias V2 = SIMD2<Double>

@inline(__always) func cross(_ a: V2, _ b: V2) -> Double { a.x * b.y - a.y * b.x }
@inline(__always) func dot(_ a: V2, _ b: V2) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) func length(_ a: V2) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) func unit(_ a: V2) -> V2 {
    let l = length(a)
    return l > 1e-12 ? a / l : V2(1, 0)
}

/// The fewest straight sides that follow a walk along the edges of samples, each side within
/// one sample of the walk, with their corners then set to a part of a sample where the sides'
/// best lines meet. This is the method of Peter Selinger's Potrace, done on the walk's corners.
struct Polygon {
    /// The corners, in samples.
    var v: [V2]
    /// Whether the outline turns sharply at each, rather than bending round it.
    var sharp: [Bool]
    /// How tightly it bends round each that is not sharp, 0.55…1.
    var bend: [Double]
    /// For the side from each corner to the next: how far the walk bows out from it in its
    /// middle, in samples. The chord of a bend bows as far as a side is let stray; a side of
    /// the outline that is straight itself hardly at all.
    var bow: [Double]
    /// Which corner of the walk each corner was made from, rising; past the walk's count where
    /// a closed polygon runs on over the walk's start.
    var at: [Int]
    var closed: Bool

    /// The sums a line is fitted from, over the samples' corners along the walk.
    private struct Sums {
        var n = 0.0, x = 0.0, y = 0.0, xx = 0.0, xy = 0.0, yy = 0.0

        static func - (a: Sums, b: Sums) -> Sums {
            Sums(n: a.n - b.n, x: a.x - b.x, y: a.y - b.y, xx: a.xx - b.xx, xy: a.xy - b.xy, yy: a.yy - b.yy)
        }

        mutating func add(_ p: V2) {
            n += 1; x += p.x; y += p.y; xx += p.x * p.x; xy += p.x * p.y; yy += p.y * p.y
        }
    }

    /// `points` are the walk's corners; `sharpness` is how far a corner must stand out from its
    /// neighbours to stay sharp (Potrace's alphamax, 1 as it has it).
    static func fit(_ points: [SIMD2<Int32>], closed: Bool, sharpness: Double, slack: Double = 1) -> Polygon {
        let n = points.count
        let origin = points[0]
        let P: [V2] = points.map { V2(Double($0.x - origin.x), Double($0.y - origin.y)) }
        let back = V2(Double(origin.x), Double(origin.y))
        guard n >= (closed ? 4 : 3) else {
            return Polygon(v: P.map { $0 + back }, sharp: [Bool](repeating: true, count: n), bend: [Double](repeating: 1, count: n),
                           bow: [Double](repeating: 0, count: n), at: Array(0..<n), closed: closed)
        }
        // Along the walk twice round when it is closed, so a side may pass its start.
        let span = closed ? 2 * n : n
        @inline(__always) func at(_ k: Int) -> V2 { P[k % n] }
        @inline(__always) func whole(_ k: Int) -> SIMD2<Int64> {
            let p = points[k % n]
            return SIMD2(Int64(p.x), Int64(p.y))
        }

        // The sums up to each corner, over every sample corner the walk passes, not only where it turns.
        var sums = [Sums](repeating: Sums(), count: span + 1)
        var running = Sums()
        /// The sums over `L` steps of the walk on from corner `k`, the corner itself counted first.
        func along(_ k: Int, _ L: Double) -> Sums {
            let a = at(k), b = at(k + 1)
            let steps = max(abs(b.x - a.x), abs(b.y - a.y))
            let u = steps > 0 ? (b - a) / steps : V2(0, 0)
            let tri = L * (L - 1) / 2, sq = (L - 1) * L * (2 * L - 1) / 6
            var s = Sums()
            s.n = L
            s.x = L * a.x + u.x * tri
            s.y = L * a.y + u.y * tri
            s.xx = L * a.x * a.x + 2 * a.x * u.x * tri + u.x * u.x * sq
            s.yy = L * a.y * a.y + 2 * a.y * u.y * tri + u.y * u.y * sq
            s.xy = L * a.x * a.y + (a.x * u.y + a.y * u.x) * tri + u.x * u.y * sq
            return s
        }
        func stepsFrom(_ k: Int) -> Double {
            let a = at(k), b = at(k + 1)
            return max(abs(b.x - a.x), abs(b.y - a.y))
        }
        for k in 0..<span {
            sums[k] = running
            guard closed || k < n - 1 else { continue }
            let part = along(k, stepsFrom(k))
            running.n += part.n; running.x += part.x; running.y += part.y
            running.xx += part.xx; running.xy += part.xy; running.yy += part.yy
        }
        sums[span] = running
        /// Over the walk from corner `i` to corner `j`, both counted.
        func over(_ i: Int, _ j: Int) -> Sums {
            var s = sums[j] - sums[i]
            s.add(at(j))
            return s
        }

        // How far a straight side can run from each corner.
        let last = closed ? span - 1 : n - 1
        var reach = [Int](repeating: 0, count: span)
        let starts = closed ? n : n - 1
        for i in 0..<starts {
            var c0 = SIMD2<Int64>(0, 0), c1 = SIMD2<Int64>(0, 0)
            var headings = 0
            var k1 = i, k = i + 1
            var far = i + 1
            let limit = closed ? i + n - 1 : n - 1
            let a = whole(i)
            // In eighths of a sample, so the slack need not be whole.
            let give = Int64((slack * 8).rounded())
            while k <= limit {
                let step = whole(k) &- whole(k1)
                headings |= step.x > 0 ? 1 : step.x < 0 ? 2 : step.y > 0 ? 4 : 8
                if headings == 15 { break }
                let cur = (whole(k) &- a) &* 8
                if c0.x * cur.y - c0.y * cur.x < 0 || c1.x * cur.y - c1.y * cur.x > 0 { break }
                far = k
                if abs(cur.x) > give || abs(cur.y) > give {
                    var off = SIMD2<Int64>(cur.x + ((cur.y >= 0 && (cur.y > 0 || cur.x < 0)) ? give : -give),
                                           cur.y + ((cur.x <= 0 && (cur.x < 0 || cur.y < 0)) ? give : -give))
                    if c0.x * off.y - c0.y * off.x >= 0 { c0 = off }
                    off = SIMD2<Int64>(cur.x + ((cur.y <= 0 && (cur.y < 0 || cur.x < 0)) ? give : -give),
                                       cur.y + ((cur.x >= 0 && (cur.x > 0 || cur.y < 0)) ? give : -give))
                    if c1.x * off.y - c1.y * off.x <= 0 { c1 = off }
                }
                k1 = k
                k += 1
            }
            reach[i] = far
        }
        if closed {
            for i in n..<span { reach[i] = min(reach[i - n] + n, last + 1) }
            // No side may run further than the one begun after it.
            for i in stride(from: span - 2, through: 0, by: -1) { reach[i] = min(reach[i], reach[i + 1]) }
        } else {
            reach[n - 1] = n - 1
            for i in stride(from: n - 2, through: 0, by: -1) { reach[i] = min(reach[i], max(reach[i + 1], i + 1)) }
        }

        /// What a side from `i` to `j` costs: its length times how far the walk strays from it.
        func penalty(_ i: Int, _ j: Int) -> Double {
            let s = over(i, j)
            let a = at(i), b = at(j)
            let px = (a.x + b.x) / 2, py = (a.y + b.y) / 2
            let ex = b.y - a.y, ey = -(b.x - a.x)
            let qa = (s.xx - 2 * s.x * px) / s.n + px * px
            let qb = (s.xy - s.x * py - s.y * px) / s.n + px * py
            let qc = (s.yy - 2 * s.y * py) / s.n + py * py
            return max(ex * ex * qa + 2 * ex * ey * qb + ey * ey * qc, 0).squareRoot()
        }

        /// The fewest sides from `from` to `to`, and of those the ones straying least.
        func path(_ from: Int, _ to: Int) -> [Int] {
            let m = to - from
            var sides = [Int](repeating: .max, count: m + 1)
            var cost = [Double](repeating: .greatestFiniteMagnitude, count: m + 1)
            var prev = [Int](repeating: 0, count: m + 1)
            sides[0] = 0
            cost[0] = 0
            for k in 1...m {
                var i = k - 1
                while i >= 0, reach[from + i] >= from + k {
                    if sides[i] != .max {
                        let s = sides[i] + 1
                        if s <= sides[k] {
                            let c = cost[i] + penalty(from + i, from + k)
                            if s < sides[k] || c < cost[k] {
                                sides[k] = s; cost[k] = c; prev[k] = i
                            }
                        }
                    }
                    i -= 1
                }
                if sides[k] == .max {
                    // Never left without a way on: the corner before always reaches the next.
                    sides[k] = sides[k - 1] + 1
                    cost[k] = cost[k - 1]
                    prev[k] = k - 1
                }
            }
            var out: [Int] = []
            var k = m
            while k > 0 {
                out.append(from + k)
                k = prev[k]
            }
            out.append(from)
            return out.reversed()
        }

        var chosen: [Int]
        if closed {
            // Begun anywhere, then again from the corner found sharpest, which every good polygon has.
            let first = path(0, n)
            var best = 0, sharpest = -1.0
            for k in 0..<(first.count - 1) {
                let i = first[(k + first.count - 2) % (first.count - 1)], j = first[k], l = first[k + 1]
                let a = at(i), b = at(j), c = at(l)
                let base = abs(c.x - a.x) + abs(c.y - a.y)
                let out = base > 0 ? abs(cross(b - a, c - a)) / base : 0
                if out > sharpest { sharpest = out; best = j }
            }
            chosen = path(best % n, best % n + n)
            chosen.removeLast()
        } else {
            chosen = path(0, n - 1)
        }
        let m = chosen.count

        // The best line through the walk along each side.
        struct Line { var c: V2; var dir: V2 }
        let sideCount = closed ? m : m - 1
        var lines: [Line] = []
        for k in 0..<sideCount {
            let i = chosen[k], j = closed && k == m - 1 ? chosen[0] + n : chosen[k + 1]
            let s = over(i, j)
            let c = V2(s.x / s.n, s.y / s.n)
            let a = s.xx / s.n - c.x * c.x, b = s.xy / s.n - c.x * c.y, d = s.yy / s.n - c.y * c.y
            let lambda = (a + d + ((a - d) * (a - d) + 4 * b * b).squareRoot()) / 2
            var dir = abs(lambda - a) > abs(lambda - d) ? V2(b, lambda - a) : V2(lambda - d, b)
            let chord = at(j) - at(i)
            if length(dir) < 1e-9 { dir = chord }
            dir = unit(dir)
            if dot(dir, chord) < 0 { dir = -dir }
            lines.append(Line(c: c, dir: dir))
        }

        // How far the walk bows out from each side: its middle half against its two ends.
        var bow = [Double](repeating: 0, count: m)
        /// The sums up to `count` sample corners along the walk past corner `i`.
        func upTo(_ i: Int, _ j: Int, _ count: Double) -> Sums {
            let target = sums[i].n + count
            var k = i
            while k + 1 < j, sums[k + 1].n <= target { k += 1 }
            let part = along(k, target - sums[k].n)
            var s = sums[k]
            s.n += part.n; s.x += part.x; s.y += part.y
            return s
        }
        for k in 0..<sideCount {
            let i = chosen[k], j = closed && k == m - 1 ? chosen[0] + n : chosen[k + 1]
            let count = sums[j].n - sums[i].n
            guard j > i + 1, count >= 8 else { continue }
            let line = lines[k], normal = V2(-line.dir.y, line.dir.x)
            let q1 = upTo(i, j, (count / 4).rounded()), q3 = upTo(i, j, (count * 3 / 4).rounded())
            func off(_ a: Sums, _ b: Sums) -> Double {
                let n = b.n - a.n
                guard n > 0 else { return 0 }
                return dot(normal, V2((b.x - a.x) / n, (b.y - a.y) / n) - line.c)
            }
            let first = off(sums[i], q1), middle = off(q1, q3), last = off(q3, sums[j])
            // Of a bow's height, the middle half shows half more than the ends.
            bow[k] = 2 * (middle - (first + last) / 2)
        }

        // Each corner where the lines of its two sides come nearest, kept within half a sample.
        var v = chosen.map { at($0) }
        for k in 0..<m {
            guard closed || (k > 0 && k < m - 1) else { continue }
            let l1 = lines[(k + sideCount - 1) % sideCount], l2 = lines[k % sideCount]
            let n1 = V2(-l1.dir.y, l1.dir.x), n2 = V2(-l2.dir.y, l2.dir.x)
            let h1 = dot(n1, l1.c), h2 = dot(n2, l2.c)
            let lattice = at(chosen[k])
            let half = 0.5 * slack
            func q(_ p: V2) -> Double {
                let d1 = dot(n1, p) - h1, d2 = dot(n2, p) - h2
                return d1 * d1 + d2 * d2
            }
            let det = cross(n1, n2)
            var best: V2?
            if abs(det) > 1e-6 {
                let p = V2((h1 * n2.y - h2 * n1.y) / det, (n1.x * h2 - n2.x * h1) / det)
                if abs(p.x - lattice.x) <= half, abs(p.y - lattice.y) <= half { best = p }
            }
            if best == nil {
                // On the square's edges, where it is least.
                var least = Double.greatestFiniteMagnitude
                for side in 0..<4 {
                    let fixed = side < 2 ? lattice.x + (side == 0 ? -half : half) : lattice.y + (side == 2 ? -half : half)
                    // Along the edge, q is a parabola in t.
                    let a = side < 2 ? V2(fixed, lattice.y - half) : V2(lattice.x - half, fixed)
                    let u = side < 2 ? V2(0, 1) : V2(1, 0)
                    let k1 = dot(n1, u), k2 = dot(n2, u)
                    let e1 = dot(n1, a) - h1, e2 = dot(n2, a) - h2
                    let den = k1 * k1 + k2 * k2
                    var t = den > 1e-12 ? -(e1 * k1 + e2 * k2) / den : 0.5
                    t = min(max(t, 0), 2 * half)
                    let p = a + u * t
                    let value = q(p)
                    if value < least { least = value; best = p }
                }
            }
            if let best { v[k] = best }
        }

        // Sharp where a corner stands far enough out from the line between its neighbours.
        var sharp = [Bool](repeating: false, count: m), bend = [Double](repeating: 1, count: m)
        for k in 0..<m {
            guard closed || (k > 0 && k < m - 1) else {
                sharp[k] = true
                continue
            }
            let before = (k + m - 1) % m
            let a = v[before], b = v[k], c = v[(k + 1) % m]
            let base = abs(c.x - a.x) + abs(c.y - a.y)
            var alpha = 4.0 / 3
            if base > 0 {
                let out = abs(cross(b - a, c - a)) / base
                alpha = (out > 1 ? 1 - 1 / out : 0) / 0.75
            }
            // The sides of a bend are chords, bowed, and turn from one to the next by what
            // their bows make up; only what a corner turns beyond that is its own.
            let d1 = b - a, d2 = c - b
            let turn = abs(atan2(cross(d1, d2), dot(d1, d2)))
            let bowed = 4 * (abs(bow[before]) / max(length(d1), 1) + abs(bow[k]) / max(length(d2), 1))
            sharp[k] = alpha >= sharpness && turn - bowed >= 0.3
            bend[k] = min(max(alpha, 0.55), 1)
        }
        return Polygon(v: v.map { $0 + back }, sharp: sharp, bend: bend, bow: bow, at: chosen, closed: closed)
    }
}
