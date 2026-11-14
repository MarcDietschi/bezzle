import Foundation

// A line in a picture that wavers comes out whole, but each of its two edges is found where
// the picture's pixels put it, and a thin line's pixels put them a little nearer or further
// apart every few pixels along it. Here the thickness of something thin is measured all along
// it and both its edges are moved, by the same amount each, until it is as thick at every place
// as it is nearby on the whole. Its middle stays where it was found.

extension Fitter {
    /// The edge of the samples' lattice between a sample of a shape and the one outside it
    /// beside it, as one number: what a step of a walk runs along.
    @inline(__always) static func edge(_ ix: Int, _ iy: Int, _ ox: Int, _ oy: Int, _ W: Int) -> Int {
        iy == oy ? (iy * (W + 2) + max(ix, ox)) << 1 : (max(iy, oy) * (W + 2) + ix) << 1 | 1
    }

    /// How far each step of the walks round region `me` is to be moved (`shifts`) for the
    /// region to be evenly thick where it is thin: across from each step the other edge is
    /// looked for, straight through the region; where it runs the other way there, as the two
    /// edges of a line do, the two are as far apart as the line is thick. Each step is then
    /// moved by half of what its thickness differs from the mean of those like it six pixels
    /// either way along the edge. Thicknesses that differ by more are another part of the shape
    /// (where a line ends, widens or meets another), and are left as they are. `line` tells
    /// whether the region is thin like that nearly all the way round: a line, or several.
    func evened(_ walks: [Walk], of me: Int32) -> (shifts: [Int: V2], line: Bool) {
        guard let cover, near != nil, W > 0, H > 0 else { return ([:], false) }
        let id = cover.id.p
        // As in `walked`: the samples left and right of a step heading down, right, up and left.
        let leftX = [0, 0, -1, -1], leftY = [0, -1, -1, 0], rightX = [-1, 0, 0, -1], rightY = [0, 0, -1, -1]
        struct Step {
            var p: V2
            var cellX: Int
            var cellY: Int
            var key: Int
            var hidden: Bool
            /// From its sample to the one outside it.
            var axis: V2
            /// Out of the shape, across the edge as it runs here.
            var out = V2(0, 0)
            var width = -1.0
        }
        var steps: [Step] = []
        var ranges: [Range<Int>] = []
        for walk in walks {
            let c = walk.corners, n = c.count
            guard n >= 3 else { continue }
            let (points, _, firstStep) = walked(c, closed: true)
            let from = steps.count
            for k in 0..<n {
                let a = c[k], b = c[(k + 1) % n]
                let count = Int(max(abs(b.x - a.x), abs(b.y - a.y)))
                guard count > 0 else { continue }
                let ux = Int((b.x - a.x).signum()), uy = Int((b.y - a.y).signum())
                let heading = b.y > a.y ? 0 : b.x > a.x ? 1 : b.y < a.y ? 2 : 3
                for s in 0..<count {
                    let cx = Int(a.x) + ux * s, cy = Int(a.y) + uy * s
                    let ix = cx + leftX[heading], iy = cy + leftY[heading]
                    let ox = cx + rightX[heading], oy = cy + rightY[heading]
                    steps.append(Step(p: points[firstStep[k] + s], cellX: ix, cellY: iy, key: Fitter.edge(ix, iy, ox, oy, W), hidden: walk.hidden[k],
                                      axis: V2(Double(ox - ix), Double(oy - iy))))
                }
            }
            ranges.append(from..<steps.count)
        }
        guard !steps.isEmpty else { return ([:], false) }
        var at: [Int: Int] = [:]
        at.reserveCapacity(steps.count)
        for i in steps.indices { at[steps[i].key] = i }

        // Which way the edge runs at each step, from a pixel of it either way.
        let reach = max(2, Int(scale.rounded()))
        for r in ranges {
            let N = r.count, first = r.lowerBound
            guard N >= 8 * reach else { continue }
            for i in r {
                let a = steps[first + (i - first + N - reach) % N].p, b = steps[first + (i - first + reach) % N].p
                let t = b - a, l = length(t)
                if l > 1e-6 { steps[i].out = V2(-t.y, t.x) / l }
            }
        }

        // How thick the region is at each step: to the edge across from it.
        let far = 4.5 * scale
        for i in steps.indices where !steps[i].hidden {
            let s = steps[i]
            guard s.out != V2(0, 0) else { continue }
            var cx = s.cellX, cy = s.cellY
            guard cx >= 0, cy >= 0, cx < W, cy < H, id[cy * W + cx] == me else { continue }
            // From just inside the lattice edge the step runs along.
            let o = V2(Double(cx) + 0.5, Double(cy) + 0.5) + s.axis * 0.49
            let d = V2(0, 0) - s.out
            let stepX = d.x > 0 ? 1 : -1, stepY = d.y > 0 ? 1 : -1
            let dx = abs(d.x) > 1e-9 ? 1 / abs(d.x) : Double.infinity, dy = abs(d.y) > 1e-9 ? 1 / abs(d.y) : Double.infinity
            var tx = dx.isFinite ? (d.x > 0 ? Double(cx + 1) - o.x : o.x - Double(cx)) * dx : Double.infinity
            var ty = dy.isFinite ? (d.y > 0 ? Double(cy + 1) - o.y : o.y - Double(cy)) * dy : Double.infinity
            var across = -1
            while true {
                let px = cx, py = cy
                let t: Double
                if tx < ty {
                    t = tx
                    tx += dx
                    cx += stepX
                } else {
                    t = ty
                    ty += dy
                    cy += stepY
                }
                if t > far + 1 { break }
                if cx < 0 || cy < 0 || cx >= W || cy >= H || id[cy * W + cx] != me {
                    across = at[Fitter.edge(px, py, cx, cy, W)] ?? -1
                    break
                }
            }
            guard across >= 0, across != i, !steps[across].hidden else { continue }
            let q = steps[across]
            guard dot(q.out, s.out) < -0.8 else { continue }
            let w = dot(s.p - q.p, s.out)
            if w > 0.2 * scale, w <= far { steps[i].width = w }
        }

        var shifts: [Int: V2] = [:]
        let half = Int((6 * scale).rounded()), most = 0.5 * scale
        var found = 0, even = 0
        for r in ranges {
            let N = r.count, first = r.lowerBound
            guard N > 2 * half else { continue }
            for i in r where steps[i].width > 0 {
                let w = steps[i].width, give = 0.15 * w + 0.2 * scale
                var sum = 0.0, count = 0, thin = 0
                for k in -half...half {
                    let v = steps[first + (i - first + k + N) % N].width
                    guard v > 0 else { continue }
                    thin += 1
                    if abs(v - w) <= give {
                        sum += v
                        count += 1
                    }
                }
                found += 1
                if 10 * count >= 9 * thin { even += 1 }
                guard count >= half else { continue }
                let move = min(max((sum / Double(count) - w) / 2, -most), most)
                if abs(move) > 0.01 { shifts[steps[i].key] = steps[i].out * move }
            }
        }
        // A line, or lines: six pixels round at least, thin nearly all the way, and with that
        // nearly as thick everywhere as it is nearby.
        return (shifts, steps.count >= Int(24 * scale) && Double(found) >= 0.7 * Double(steps.count) && Double(even) >= 0.9 * Double(found))
    }
}
