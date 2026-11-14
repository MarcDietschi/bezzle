import Foundation

/// The colours a picture is made of, found from where it is one colour: the mixed pixels along
/// soft edges are left out, so no colour is made of what lies between two others.
struct Palette {
    /// sRGB, 0…255.
    var colors: [SIMD3<Int32>]
    /// How many pixels are each, about.
    var weights: [Double]
    /// The colour each is drawn in: its own, but for what is thin in a picture that keeps its
    /// colour coarser than its light. There `colors` has it as its pixels show it, which is what
    /// the pixels are held against, and this as it was drawn (`thin`).
    var drawn: [SIMD3<Int32>]

    private struct Cluster {
        var lab: SIMD3<Float>
        var rgb: SIMD3<Double>
        var weight: Double
        var drawn: SIMD3<Double>?
    }

    /// The most a picture is traced in, by how much detail is wanted.
    static func most(detail: Double) -> Int {
        Int((6 + 58 * pow(min(max(detail, 0), 1), 1.3)).rounded())
    }

    static func find(_ raster: Raster, settings: Settings, noise: Double, exact: Bool, mixing: Mixing) -> Palette {
        let w = raster.w, h = raster.h, p = raster.rgb.p, alpha = raster.alpha.p
        let bits = 6, side = 1 << bits, cells = side * side * side
        var count = [Double](repeating: 0, count: cells)
        var sum = [SIMD3<Double>](repeating: .zero, count: cells)
        var all = [Double](repeating: 0, count: cells)
        var allSum = [SIMD3<Double>](repeating: .zero, count: cells)
        let calm = exact ? 0 : Int(min(6 + 2.5 * noise, 24))
        var flat = [Bool](repeating: false, count: w * h)
        var flats = 0.0, solid = 0.0

        @inline(__always) func differ(_ i: Int, _ j: Int) -> Int {
            max(abs(Int(p[i * 3]) - Int(p[j * 3])), abs(Int(p[i * 3 + 1]) - Int(p[j * 3 + 1])), abs(Int(p[i * 3 + 2]) - Int(p[j * 3 + 2])))
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard alpha[i] >= 128 else { continue }
                let c = SIMD3(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2]))
                let key = (Int(p[i * 3]) >> (8 - bits)) << (2 * bits) | (Int(p[i * 3 + 1]) >> (8 - bits)) << bits | Int(p[i * 3 + 2]) >> (8 - bits)
                all[key] += 1
                allSum[key] += c
                solid += 1
                var edge = 0
                if x > 0 { edge = max(edge, differ(i, i - 1)) }
                if x < w - 1 { edge = max(edge, differ(i, i + 1)) }
                if y > 0 { edge = max(edge, differ(i, i - w)) }
                if y < h - 1 { edge = max(edge, differ(i, i + w)) }
                if edge <= calm {
                    flat[i] = true
                    count[key] += 1
                    sum[key] += c
                    flats += 1
                }
            }
        }
        guard solid > 0 else { return Palette(colors: [], weights: [], drawn: []) }
        // A picture with hardly a calm place, such as a noisy or finely patterned one, is taken whole.
        if flats < solid * 0.05 {
            count = all
            sum = allSum
            flats = solid
        }

        var clusters: [Cluster] = []
        for key in 0..<cells where count[key] > 0 {
            let mean = sum[key] / count[key]
            clusters.append(Cluster(lab: Oklab.from(r: mean.x, g: mean.y, b: mean.z), rgb: mean, weight: count[key]))
        }
        let total = flats
        let wanted = settings.colors.map { min(max($0, 1), 64) }
        let most = wanted ?? most(detail: settings.detail)
        if exact, clusters.count <= max(most, 64), wanted == nil {
            // Pixel art keeps its colours as they are.
            return finished(clusters)
        }
        if clusters.count > 160 { clusters = reduced(clusters, to: 160) }

        // Merged from the most alike, small ones sooner, until those left are all their own colour.
        let detail = min(max(settings.detail, 0), 1)
        let alike = Float(0.07 * pow(1 - detail, 1.5) + 0.012 + (noise >= 4 ? 0.004 : 0.0015) * min(noise, 10))
        func cost(_ a: Cluster, _ b: Cluster) -> Float {
            let share = Float(min(a.weight, b.weight) / total)
            return Oklab.distance(a.lab, b.lab) * powf(max(share, 1e-7), 0.08)
        }
        while clusters.count > 1 {
            var best = Float.greatestFiniteMagnitude, bi = 0, bj = 1
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let c = cost(clusters[i], clusters[j])
                    if c < best { best = c; bi = i; bj = j }
                }
            }
            if clusters.count <= most, wanted != nil || best > alike { break }
            let a = clusters[bi], b = clusters[bj]
            let weight = a.weight + b.weight
            let rgb = (a.rgb * a.weight + b.rgb * b.weight) / weight
            clusters[bi] = Cluster(lab: Oklab.from(r: rgb.x, g: rgb.y, b: rgb.z), rgb: rgb, weight: weight)
            clusters.remove(at: bj)
        }

        // What is too little to be a colour of the picture goes to the one most like it.
        let least = max(4, total * 0.00003)
        if clusters.count > 1 {
            let kept = clusters.filter { $0.weight >= least }
            if !kept.isEmpty { clusters = kept }
        }
        if wanted == nil, !exact {
            clusters += thin(raster, flat: flat, beside: clusters, noise: noise, room: most - clusters.count, mixing: mixing)
        }
        return finished(clusters)
    }

    private static func finished(_ clusters: [Cluster]) -> Palette {
        let sorted = clusters.sorted { $0.weight > $1.weight }
        var colors: [SIMD3<Int32>] = [], weights: [Double] = [], drawn: [SIMD3<Int32>] = []
        func whole(_ c: SIMD3<Double>) -> SIMD3<Int32> {
            let v = SIMD3<Int32>(Int32(c.x.rounded()), Int32(c.y.rounded()), Int32(c.z.rounded()))
            // Nearly white is white and nearly black is black: what a file's compression moved.
            if v.x >= 251, v.y >= 251, v.z >= 251 { return SIMD3(255, 255, 255) }
            if v.x <= 4, v.y <= 4, v.z <= 4 { return SIMD3(0, 0, 0) }
            return v
        }
        for c in sorted {
            let v = whole(c.rgb)
            if colors.contains(v) { continue }
            colors.append(v)
            weights.append(c.weight)
            drawn.append(c.drawn.map(whole) ?? v)
        }
        return Palette(colors: colors, weights: weights, drawn: drawn)
    }

    /// Many colours brought down to `k` by the means of those nearest each other.
    private static func reduced(_ clusters: [Cluster], to k: Int) -> [Cluster] {
        // Begun from the heaviest, then each time the one furthest from those taken, by weight.
        var centers: [SIMD3<Float>] = []
        var far = [Float](repeating: .greatestFiniteMagnitude, count: clusters.count)
        var next = clusters.indices.max { clusters[$0].weight < clusters[$1].weight } ?? 0
        for _ in 0..<k {
            let c = clusters[next].lab
            centers.append(c)
            var best: Float = -1
            for i in clusters.indices {
                let d = Oklab.distance(clusters[i].lab, c)
                if d < far[i] { far[i] = d }
                let score = far[i] * Float(pow(clusters[i].weight, 0.25))
                if score > best { best = score; next = i }
            }
            if best <= 0 { break }
        }
        var owner = [Int](repeating: 0, count: clusters.count)
        var out: [Cluster] = []
        for round in 0..<6 {
            for i in clusters.indices {
                var best = Float.greatestFiniteMagnitude
                for (j, c) in centers.enumerated() {
                    let d = Oklab.distance(clusters[i].lab, c)
                    if d < best { best = d; owner[i] = j }
                }
            }
            var weight = [Double](repeating: 0, count: centers.count)
            var rgb = [SIMD3<Double>](repeating: .zero, count: centers.count)
            for i in clusters.indices {
                weight[owner[i]] += clusters[i].weight
                rgb[owner[i]] += clusters[i].rgb * clusters[i].weight
            }
            out = []
            for j in centers.indices where weight[j] > 0 {
                let mean = rgb[j] / weight[j]
                out.append(Cluster(lab: Oklab.from(r: mean.x, g: mean.y, b: mean.z), rgb: mean, weight: weight[j]))
            }
            if round < 5 { centers = out.map(\.lab) }
        }
        return out
    }

    /// The colours of what is too thin to have a calm place: hairlines and small letters. Their
    /// pixels are darker or lighter than both sides, not between them, which sets them apart from
    /// the mixed pixels of an edge; of these the furthest from the colours found are taken, and
    /// what lies between one taken and a colour found is its soft edge, and left out.
    private static func thin(_ raster: Raster, flat: [Bool], beside found: [Cluster], noise: Double, room: Int, mixing: Mixing) -> [Cluster] {
        guard room > 0, !found.isEmpty else { return [] }
        let w = raster.w, h = raster.h, p = raster.rgb.p, alpha = raster.alpha.p
        guard w >= 5, h >= 5 else { return [] }
        let known = found.map { SIMD3<Int32>(Int32($0.rgb.x), Int32($0.rgb.y), Int32($0.rgb.z)) }
        let apart = Int32(36 + 3 * min(noise, 10)), mixed = Int32(14 + 2 * min(noise, 10))
        @inline(__always) func color(_ i: Int) -> SIMD3<Int32> { SIMD3(Int32(p[i * 3]), Int32(p[i * 3 + 1]), Int32(p[i * 3 + 2])) }
        @inline(__always) func gap(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> Int32 {
            let d = a &- b
            return (d &* d).wrappedSum()
        }
        /// Whether `c` lies on the way from `a` to `b`, which are far apart.
        @inline(__always) func between(_ c: SIMD3<Int32>, _ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> Bool {
            let v = b &- a
            guard (v &* v).wrappedSum() > apart * apart / 2 else { return false }
            return Mixing.isBetween(mixing(c, from: a, to: b), within: Double(mixed))
        }
        /// What the seven by seven pixels round one hold more than the ground they lie on, added
        /// up; nothing where fewer than most of them show that ground. Where a picture keeps
        /// its colour coarser than its light, a thin line's colour is spread over the pixels
        /// beside it and its own are left dull, but none of it is lost: this sum has the hue
        /// the line was drawn in.
        func around(_ x: Int, _ y: Int, on ground: SIMD3<Int32>) -> SIMD3<Double> {
            var sum = SIMD3<Double>.zero
            var calm = 0
            for dy in -3...3 {
                let row = min(max(y + dy, 0), h - 1) * w
                for dx in -3...3 {
                    let d = color(row + min(max(x + dx, 0), w - 1)) &- ground
                    sum += SIMD3(Double(d.x), Double(d.y), Double(d.z))
                    if (d &* d).wrappedSum() <= apart * apart { calm += 1 }
                }
            }
            return calm >= 28 ? sum : .zero
        }
        var bins: [Int: (sum: SIMD3<Double>, n: Double, grounds: [Double], around: [SIMD3<Double>])] = [:]
        let steps = [(1, 0), (0, 1), (1, 1), (1, -1)]
        let none = [Double](repeating: 0, count: known.count)
        let hueless = [SIMD3<Double>](repeating: .zero, count: mixing.coarse ? known.count : 0)
        for y in 2..<(h - 2) {
            for x in 2..<(w - 2) {
                let i = y * w + x
                guard !flat[i], alpha[i] >= 128 else { continue }
                let c = color(i)
                var near = Int32.max
                for k in known { near = min(near, gap(c, k)) }
                guard near > apart * apart else { continue }
                var edge = false
                for (dx, dy) in steps {
                    for reach in 1...2 {
                        let a = color(i - (dy * w + dx) * reach), b = color(i + (dy * w + dx) * reach)
                        if between(c, a, b) { edge = true; break }
                    }
                    if edge { break }
                }
                guard !edge else { continue }
                // Between two of the colours found, it is a mix of them and no colour of its own.
                var mix = false
                for a in 0..<known.count where !mix {
                    for b in (a + 1)..<known.count where between(c, known[a], known[b]) { mix = true; break }
                }
                guard !mix else { continue }
                // What it lies on: the colours found that show two pixels from it.
                var grounds = none
                for (dx, dy) in steps {
                    for way in [-2, 2] {
                        let q = color(i + (dy * w + dx) * way)
                        if let k = known.firstIndex(where: { gap(q, $0) <= mixed * mixed }) { grounds[k] += 1 }
                    }
                }
                let key = (Int(c.x) >> 3) << 10 | (Int(c.y) >> 3) << 5 | Int(c.z) >> 3
                var bin = bins[key] ?? (.zero, 0, none, hueless)
                bin.sum += SIMD3(Double(c.x), Double(c.y), Double(c.z))
                bin.n += 1
                for k in grounds.indices { bin.grounds[k] += grounds[k] }
                if mixing.coarse, let ground = grounds.indices.max(by: { grounds[$0] < grounds[$1] }), grounds[ground] >= 3 {
                    bin.around[ground] += around(x, y, on: known[ground])
                }
                bins[key] = bin
            }
        }
        let least = max(10, Double(w * h) * 0.00012)
        struct Thin {
            var color: Cluster
            /// Which of the colours found it mostly lies on.
            var ground: Int?
            /// What the pixels round its own hold more than that ground (`around`).
            var around: SIMD3<Double>
        }
        var candidates = bins.values.map { bin -> Thin in
            let mean = bin.sum / bin.n
            let ground = bin.grounds.indices.max { bin.grounds[$0] < bin.grounds[$1] }.flatMap { bin.grounds[$0] > 0 ? $0 : nil }
            return Thin(color: Cluster(lab: Oklab.from(r: mean.x, g: mean.y, b: mean.z), rgb: mean, weight: bin.n), ground: ground,
                        around: ground.flatMap { $0 < bin.around.count ? bin.around[$0] : nil } ?? .zero)
        }
        // The furthest from the colours found first: what is thin is never more its own colour
        // than where it shows most, and all it shows less of lies between that and what is
        // round it.
        func farness(_ c: Cluster) -> Float { found.map { Oklab.distance($0.lab, c.lab) }.min() ?? 0 }
        func whole(_ c: Cluster) -> SIMD3<Int32> { SIMD3(Int32(c.rgb.x), Int32(c.rgb.y), Int32(c.rgb.z)) }
        candidates.sort { farness($0.color) > farness($1.color) }
        var taken: [Cluster] = []
        var left = candidates
        while taken.count < min(room, 6), var first = left.first(where: { $0.color.weight >= 2 && farness($0.color) > 0.08 }) {
            // And never one that another lies beyond, seen from what both lie on: that is the
            // other where less of it shows. With a second colour found near, such a one may be
            // the furthest from both and still nobody's colour.
            var v = whole(first.color)
            if let ground = first.ground {
                let from = known[ground]
                for _ in 0..<4 {
                    var beyond: Thin?
                    var furthest = gap(v, from)
                    for other in left where other.color.weight >= 2 && other.ground == ground {
                        let o = whole(other.color)
                        if gap(o, from) > furthest, between(v, from, o) {
                            beyond = other
                            furthest = gap(o, from)
                        }
                    }
                    guard let beyond else { break }
                    first = beyond
                    v = whole(first.color)
                }
            }
            func explained(_ c: Thin) -> Bool {
                let cv = whole(c.color)
                return gap(cv, v) < apart * apart || known.contains { between(cv, $0, v) }
            }
            let support = left.filter(explained).reduce(0) { $0 + $1.color.weight }
            let rest = left.filter { !explained($0) }
            if support >= least {
                var cluster = Cluster(lab: first.color.lab, rgb: first.color.rgb, weight: support)
                // Drawn in the hue all its pixels have together, as light or dark as where it
                // shows most.
                if mixing.coarse, let ground = first.ground {
                    let from = SIMD3(Double(known[ground].x), Double(known[ground].y), Double(known[ground].z))
                    let all = left.filter { explained($0) && $0.ground == ground }.reduce(SIMD3<Double>.zero) { $0 + $1.around }
                    let light = Mixing.light(first.color.rgb - from), lit = Mixing.light(all)
                    if abs(light) >= 24, abs(lit) >= 24, (light > 0) == (lit > 0) {
                        let hue = from + all * (light / lit)
                        cluster.drawn = SIMD3(min(max(hue.x, 0), 255), min(max(hue.y, 0), 255), min(max(hue.z, 0), 255))
                    }
                }
                taken.append(cluster)
            }
            if rest.count == left.count { break }
            left = rest
        }
        return taken
    }
}

/// Which of the palette's colours a pixel is nearest to, found fast: for each small cube of
/// colours, the few that any colour in it could be nearest to are worked out once.
struct Nearest: @unchecked Sendable {
    let colors: [SIMD3<Int32>]
    private let starts: [Int32]
    private let lists: [UInt8]

    init(_ colors: [SIMD3<Int32>]) {
        self.colors = colors
        var starts = [Int32](repeating: 0, count: 32 * 32 * 32 + 1)
        var lists: [UInt8] = []
        lists.reserveCapacity(32 * 32 * 32 * 2)
        var least = [Int32](repeating: 0, count: colors.count)
        for cell in 0..<(32 * 32 * 32) {
            let lo = SIMD3<Int32>(Int32(cell >> 10) << 3, Int32((cell >> 5) & 31) << 3, Int32(cell & 31) << 3)
            let hi = lo &+ 7
            var nearestFar = Int32.max
            for (k, c) in colors.enumerated() {
                // To the nearest and the furthest point of the cube.
                let below = lo &- c, above = c &- hi
                let out = pointwiseMax(pointwiseMax(below, above), .zero)
                let fromLo = c &- lo, fromHi = c &- hi
                let far = pointwiseMax(fromLo &* fromLo, fromHi &* fromHi)
                least[k] = (out &* out).wrappedSum()
                nearestFar = min(nearestFar, far.wrappedSum())
            }
            starts[cell] = Int32(lists.count)
            for k in colors.indices where least[k] <= nearestFar { lists.append(UInt8(k)) }
        }
        starts[32 * 32 * 32] = Int32(lists.count)
        self.starts = starts
        self.lists = lists
    }

    @inline(__always) func callAsFunction(_ r: Int32, _ g: Int32, _ b: Int32) -> UInt8 {
        let cell = Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)
        return starts.withUnsafeBufferPointer { starts in
            lists.withUnsafeBufferPointer { lists in
                colors.withUnsafeBufferPointer { colors in
                    let from = Int(starts[cell]), to = Int(starts[cell + 1])
                    if to - from == 1 { return lists[from] }
                    var best = Int32.max, at: UInt8 = 0
                    for i in from..<to {
                        let c = colors[Int(lists[i])]
                        let dr = c.x - r, dg = c.y - g, db = c.z - b
                        let d = dr * dr + dg * dg + db * db
                        if d < best { best = d; at = lists[i] }
                    }
                    return at
                }
            }
        }
    }
}
