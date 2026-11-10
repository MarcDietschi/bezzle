import Foundation

/// The order the regions are drawn in, and how far each lies under those over it.
///
/// Shapes that only touch show a hairline of whatever is behind them wherever they are drawn
/// with soft edges. So the shapes are stacked: broad regions lie at the bottom and thin ones on
/// top, and each region reaches a little way under every region over it that it touches, never
/// as far as that region's other side. Every edge that shows is then the edge of the upper shape
/// alone, with the lower one's colour continuing under it.
struct Stack: @unchecked Sendable {
    /// Where each region is in the order, 0 at the bottom; -1 for see-through regions, which
    /// are not drawn.
    let rank: [Int32]
    /// The regions from the bottom up.
    let order: [Int32]
    /// For each sample, the lower region that reaches under it; -1 for none.
    let under: Store<Int32>
    /// How far under, in samples.
    let lap: Int

    static func make(_ regions: Regions, clear: UInt8, lap: Int) -> Stack {
        let W = regions.W, H = regions.H, id = regions.id.p, n = regions.count
        // How broad each region is: the furthest any of its samples is from its edge.
        let depth = Store<UInt16>(W * H, 60000)
        var edge: [Int32] = []
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X, v = id[i]
                if (X > 0 && id[i - 1] != v) || (X < W - 1 && id[i + 1] != v) || (Y > 0 && id[i - W] != v) || (Y < H - 1 && id[i + W] != v) {
                    depth.p[i] = 3
                    edge.append(Int32(i))
                }
            }
        }
        Labels.spread(depth.p, W, H, within: Optional<UnsafeMutablePointer<UInt8>>.none)
        var broad = [UInt16](repeating: 0, count: n)
        for i in 0..<(W * H) {
            let r = Int(id[i])
            if depth.p[i] > broad[r] { broad[r] = depth.p[i] }
        }
        // A region alone in the picture has no edge: it is as broad as can be.
        var drawn = (0..<n).filter { regions.label[$0] != clear && regions.area[$0] > 0 }
        drawn.sort {
            if broad[$0] != broad[$1] { return broad[$0] > broad[$1] }
            if regions.area[$0] != regions.area[$1] { return regions.area[$0] > regions.area[$1] }
            return $0 < $1
        }
        var rank = [Int32](repeating: -1, count: n)
        for (k, r) in drawn.enumerated() { rank[r] = Int32(k) }

        // Each region spreads under the samples of regions over it, a step at a time from its
        // edge; where two meet, the first there has it.
        let under = Store<Int32>(W * H, -1)
        var front = edge.sorted { rank[Int(id[Int($0)])] < rank[Int(id[Int($1)])] }
        var source = front.map { id[Int($0)] }
        for _ in 0..<lap {
            var next: [Int32] = [], nextSource: [Int32] = []
            next.reserveCapacity(front.count)
            nextSource.reserveCapacity(front.count)
            for (k, at) in front.enumerated() {
                let i = Int(at), from = source[k], low = rank[Int(from)]
                let X = i % W, Y = i / W
                @inline(__always) func reach(_ j: Int) {
                    let r = id[j]
                    guard r != from, under.p[j] < 0, rank[Int(r)] > low else { return }
                    under.p[j] = from
                    next.append(Int32(j))
                    nextSource.append(from)
                }
                if X > 0 { reach(i - 1) }
                if X < W - 1 { reach(i + 1) }
                if Y > 0 { reach(i - W) }
                if Y < H - 1 { reach(i + W) }
            }
            front = next
            source = nextSource
            if front.isEmpty { break }
        }
        return Stack(rank: rank, order: drawn.map { Int32($0) }, under: under, lap: lap)
    }
}

/// A closed walk round a shape along the edges of its samples, as its corners, with the shape
/// on the left hand.
struct Walk {
    /// The corners, where the walk turns or passes from an edge that shows to one that is hidden.
    var corners: [SIMD2<Int32>] = []
    /// For the way from each corner to the next: whether it lies hidden under a region over it.
    var hidden: [Bool] = []
    /// Twice the area walked round: above 0 for the outside of a shape, below for a hole.
    var area2: Int = 0
}

extension Stack {
    /// The outlines of region `r` as it is drawn: itself and where it lies under others. Holes
    /// that only regions over it fill are closed, so the shape runs on under them whole.
    func walks(of r: Int, in regions: Regions) -> [Walk] {
        let W = regions.W, H = regions.H, id = regions.id.p, under = under.p
        let me = Int32(r), mine = rank[r]
        let b = regions.box[r]
        let minX = max(Int(b.x) - lap, 0), minY = max(Int(b.y) - lap, 0)
        let maxX = min(Int(b.z) + lap, W - 1), maxY = min(Int(b.w) + lap, H - 1)
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        var visited = [Bool](repeating: false, count: bw * bh)

        @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < W, y < H else { return false }
            let i = y * W + x
            return id[i] == me || under[i] == me
        }
        @inline(__always) func own(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < W, y < H else { return false }
            return id[y * W + x] == me
        }
        // Heading down, right, up, left: with y going down, the left hand is then east, north,
        // west, south.
        let dx = [0, 1, 0, -1], dy = [1, 0, -1, 0]
        /// The samples ahead of a corner on the left and the right hand, for each heading.
        let leftX = [0, 0, -1, -1], leftY = [0, -1, -1, 0]
        let rightX = [-1, 0, 0, -1], rightY = [0, 0, -1, -1]

        var walks: [Walk] = []
        for y in minY...maxY {
            for x in minX...maxX {
                guard inside(x, y), !inside(x - 1, y), !visited[(y - minY) * bw + x - minX] else { continue }
                var walk = Walk()
                var vx = x, vy = y, heading = 0
                var lastHeading = -1, lastHidden = false
                var area2 = 0
                repeat {
                    if heading == 0 { visited[(vy - minY) * bw + vx - minX] = true }
                    // The sample on the left of this step is the shape's; hidden when it is only
                    // lying under another there.
                    let hidden = !own(vx + leftX[heading], vy + leftY[heading])
                    if heading != lastHeading || hidden != lastHidden {
                        walk.corners.append(SIMD2(Int32(vx), Int32(vy)))
                        walk.hidden.append(hidden)
                        lastHeading = heading
                        lastHidden = hidden
                    }
                    let nx = vx + dx[heading], ny = vy + dy[heading]
                    area2 += vx * ny - nx * vy
                    vx = nx; vy = ny
                    // Which way on: left when the sample ahead on the left is not the shape's,
                    // straight when only it is, right when both are.
                    if !inside(vx + leftX[heading], vy + leftY[heading]) {
                        heading = (heading + 1) & 3
                    } else if inside(vx + rightX[heading], vy + rightY[heading]) {
                        heading = (heading + 3) & 3
                    }
                } while !(vx == x && vy == y && heading == 0)
                // Where the walk ends as it began, the first corner is no corner.
                if walk.corners.count > 1, lastHeading == 0, lastHidden == walk.hidden[0] {
                    walk.corners.removeFirst()
                    let h = walk.hidden.removeFirst()
                    walk.hidden[walk.hidden.count - 1] = h
                }
                // With y down and the shape on the left, the outside comes out below 0.
                walk.area2 = -area2
                if walk.area2 < 0, !walk.hidden.contains(false), filled(walk, above: mine, regions) { continue }
                walks.append(walk)
            }
        }
        return walks
    }

    /// Whether everything inside a hole is of regions above `mine`, so the hole can be closed.
    private func filled(_ hole: Walk, above mine: Int32, _ regions: Regions) -> Bool {
        let W = regions.W, id = regions.id.p
        // The hole's upright edges by row: between each pair of them lies its inside.
        var crossings: [Int32: [Int32]] = [:]
        let n = hole.corners.count
        for k in 0..<n {
            let a = hole.corners[k], b = hole.corners[(k + 1) % n]
            guard a.x == b.x, a.y != b.y else { continue }
            for y in min(a.y, b.y)..<max(a.y, b.y) { crossings[y, default: []].append(a.x) }
        }
        for (y, xs) in crossings {
            let sorted = xs.sorted()
            var k = 0
            while k + 1 < sorted.count {
                for x in sorted[k]..<sorted[k + 1] {
                    let r = id[Int(y) * W + Int(x)]
                    if rank[Int(r)] <= mine { return false }
                }
                k += 2
            }
        }
        return true
    }
}
