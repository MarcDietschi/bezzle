import Foundation

/// The picture read between its pixels: `scale` samples across each, so an edge is found to a
/// part of a pixel from how much of each colour the pixels along it are mixed of.
struct Sampler: @unchecked Sendable {
    let raster: Raster
    let scale: Int
    let W: Int
    let H: Int
    private let x0: [Int32], x1: [Int32], fx: [Int32]
    private let y0: [Int32], y1: [Int32], fy: [Int32]
    /// For each sample along an axis, the four pixels it is read from and how much of each, in
    /// 1024ths: a curve through the pixels rather than straight lines between them, so a stroke
    /// one pixel wide that lies across two rows still reads as more than half its colour.
    private let xi: [Int32], xw: [Int32], yi: [Int32], yw: [Int32]

    init(_ raster: Raster, scale: Int) {
        self.raster = raster
        self.scale = scale
        W = raster.w * scale
        H = raster.h * scale
        func table(_ n: Int, _ size: Int) -> ([Int32], [Int32], [Int32], [Int32], [Int32]) {
            var a = [Int32](repeating: 0, count: n), b = a, f = a
            var at4 = [Int32](repeating: 0, count: n * 4), w4 = at4
            for i in 0..<n {
                let at = (Double(i) + 0.5) / Double(scale) - 0.5
                let lo = floor(at)
                a[i] = Int32(min(max(Int(lo), 0), size - 1))
                b[i] = Int32(min(max(Int(lo) + 1, 0), size - 1))
                let t = at - lo
                f[i] = Int32((t * 256).rounded())
                let w = [(-t * t * t + 2 * t * t - t) / 2, (3 * t * t * t - 5 * t * t + 2) / 2,
                         (-3 * t * t * t + 4 * t * t + t) / 2, (t * t * t - t * t) / 2]
                var whole = w.map { Int32(($0 * 1024).rounded()) }
                whole[1] += 1024 - whole.reduce(0, +)
                for j in 0..<4 {
                    at4[i * 4 + j] = Int32(min(max(Int(lo) - 1 + j, 0), size - 1))
                    w4[i * 4 + j] = whole[j]
                }
            }
            return (a, b, f, at4, w4)
        }
        (x0, x1, fx, xi, xw) = table(W, raster.w)
        (y0, y1, fy, yi, yw) = table(H, raster.h)
    }

    @inline(__always) func color(_ X: Int, _ Y: Int) -> SIMD3<Int32> {
        let p = raster.rgb.p, w = raster.w
        if scale == 1 {
            let i = (Y * w + X) * 3
            return SIMD3(Int32(p[i]), Int32(p[i + 1]), Int32(p[i + 2]))
        }
        var sum = SIMD3<Int32>(0, 0, 0)
        for j in 0..<4 {
            let row = Int(yi[Y * 4 + j]) * w
            var line = SIMD3<Int32>(0, 0, 0)
            for i in 0..<4 {
                let a = (row + Int(xi[X * 4 + i])) * 3
                line &+= SIMD3<Int32>(Int32(p[a]), Int32(p[a + 1]), Int32(p[a + 2])) &* xw[X * 4 + i]
            }
            sum &+= (line &>> 2) &* yw[Y * 4 + j]
        }
        let c = (sum &+ (1 << 17)) &>> 18
        return c.clamped(lowerBound: SIMD3(0, 0, 0), upperBound: SIMD3(255, 255, 255))
    }

    /// How solid, 0…255.
    @inline(__always) func solid(_ X: Int, _ Y: Int) -> Int32 {
        let p = raster.alpha.p, w = raster.w
        if scale == 1 { return Int32(p[Y * w + X]) }
        let u = fx[X], v = fy[Y]
        let top = Int32(p[Int(y0[Y]) * w + Int(x0[X])]) * (256 - u) + Int32(p[Int(y0[Y]) * w + Int(x1[X])]) * u
        let low = Int32(p[Int(y1[Y]) * w + Int(x0[X])]) * (256 - u) + Int32(p[Int(y1[Y]) * w + Int(x1[X])]) * u
        return (top * (256 - v) + low * v + 32768) >> 16
    }
}

/// Which two colours a pixel or a sample is mixed of.
private struct Mixer: @unchecked Sendable {
    let colors: [SIMD3<Int32>]
    let weights: [Double]
    let clear: UInt8
    let pureGap: Int32
    let mixedGap: Int32
    let mixing: Mixing
    let small: Store<UInt8>
    let broad: Store<Bool>
    let broadNear: Store<UInt32>
    let anyNear: Store<UInt32>

    /// The two colours `c` is mixed of and how much of the second it is, for something in pixel
    /// `P` whose nearest colour is `own`; nil when it is simply that colour.
    ///
    /// With `sure`, what is all but purely its colour is left that colour; without, the least
    /// of another colour in it counts, as it does for finding an edge's exact place.
    @inline(__always) func pair(_ c: SIMD3<Int32>, own: UInt8, at P: Int, _ seen: UnsafeMutablePointer<UInt8>, sure: Bool)
        -> (a: UInt8, b: UInt8, along: Double)? {
        let d = c &- colors[Int(own)]
        let isPure = sure && (d &* d).wrappedSum() <= pureGap * pureGap
        if isPure, broad.p[P], small.p[P] == own { return nil }
        // The colours it may be a mix of: those lying broad, and any other than its own.
        var n = 0
        var ownBroad = false
        let b = broadNear.p[P], a = anyNear.p[P]
        for k in 0..<4 {
            let v = UInt8((b >> UInt32(k * 8)) & 0xFF)
            if v == 0xFF || v == clear { continue }
            if v == own { ownBroad = true }
            seen[n] = v; n += 1
        }
        for k in 0..<4 {
            let v = UInt8((a >> UInt32(k * 8)) & 0xFF)
            if v == 0xFF || v == clear || v == own { continue }
            var known = false
            for i in 0..<n where seen[i] == v { known = true }
            if !known { seen[n] = v; n += 1 }
        }
        if isPure, ownBroad { return nil }
        guard n >= 1 else { return nil }
        let gap = Double(mixedGap)
        var best = Double.greatestFiniteMagnitude, A = own, B = own, along = 0.5
        for i in 0..<n {
            for j in (i + 1)..<n {
                let ca = colors[Int(seen[i])], cb = colors[Int(seen[j])]
                let v = cb &- ca
                guard (v &* v).wrappedSum() >= 9 * mixedGap * mixedGap else { continue }
                let m = mixing(c, from: ca, to: cb)
                guard Mixing.isBetween(m, within: gap), m.off < best else { continue }
                best = m.off
                A = seen[i]; B = seen[j]
                along = min(max(m.light, 0), 1)
            }
        }
        if best > gap * gap {
            // Something thin, with none of its own colour pure beside it: a mix of a colour
            // that is, and whichever of the palette's lies on from there.
            var most = -1.0
            let far = (d &* d).wrappedSum() >= 6 * pureGap * pureGap
            for i in 0..<n {
                let ca = colors[Int(seen[i])]
                for k in 0..<colors.count where UInt8(k) != seen[i] {
                    guard far || UInt8(k) == own || seen[i] == own else { continue }
                    let v = colors[k] &- ca
                    guard (v &* v).wrappedSum() >= 9 * mixedGap * mixedGap else { continue }
                    let m = mixing(c, from: ca, to: colors[k])
                    // Of those it could be, the one the picture has most of.
                    guard Mixing.isBetween(m, within: gap), weights[k] > most else { continue }
                    most = weights[k]
                    best = m.off
                    A = seen[i]; B = UInt8(k)
                    along = min(max(m.light, 0), 1)
                }
            }
        }
        guard best <= gap * gap else { return nil }
        return (A, B, along)
    }

    /// How much of `b` and of `l` colour `c` holds when it is a mix of `a`, `b` and `l`, and
    /// how far it is from any such mix, squared. Nil when the three lie in a row.
    @inline(__always) static func unmixed(_ c: SIMD3<Int32>, _ a: SIMD3<Int32>, _ b: SIMD3<Int32>, _ l: SIMD3<Int32>)
        -> (u: Double, v: Double, off: Double)? {
        let e1 = SIMD3<Double>(b &- a), e2 = SIMD3<Double>(l &- a), w = SIMD3<Double>(c &- a)
        let a11 = (e1 * e1).sum(), a12 = (e1 * e2).sum(), a22 = (e2 * e2).sum()
        let det = a11 * a22 - a12 * a12
        guard a11 > 1, det > 1e-6 * a11 * a22 else { return nil }
        let b1 = (w * e1).sum(), b2 = (w * e2).sum()
        let u = (b1 * a22 - b2 * a12) / det, v = (a11 * b2 - a12 * b1) / det
        let left = w - e1 * u - e2 * v
        return (u, v, (left * left).sum())
    }

    /// Something thin running between two colours, as an outline does between what it goes
    /// round and what lies outside: the two colours lying broad beside pixel `P`, and the
    /// third that `c` holds besides, when it is no mix of the two alone. Of the colours it
    /// could be, the one that `c` is most of.
    @inline(__always) func triple(_ c: SIMD3<Int32>, at P: Int) -> (a: UInt8, b: UInt8, l: UInt8)? {
        let near = broadNear.p[P]
        let a = UInt8(near & 0xFF), b = UInt8((near >> 8) & 0xFF)
        guard a != 0xFF, b != 0xFF, a != clear, b != clear, (near >> 16) & 0xFF == 0xFF else { return nil }
        let ca = colors[Int(a)], cb = colors[Int(b)]
        let gap = Double(mixedGap)
        let between = ca &- cb
        guard (between &* between).wrappedSum() >= 9 * mixedGap * mixedGap else { return nil }
        if Mixing.isBetween(mixing(c, from: ca, to: cb), within: gap) { return nil }
        var most = 0.0, found: UInt8?
        let e1 = SIMD3<Double>(cb &- ca), l1 = (e1 * e1).sum()
        for k in 0..<colors.count where UInt8(k) != a && UInt8(k) != b {
            // Well off the way from one colour to the other.
            let e2 = SIMD3<Double>(colors[k] &- ca)
            let along = (e1 * e2).sum()
            guard (e2 * e2).sum() - along * along / l1 >= 9 * gap * gap else { continue }
            guard let m = Mixer.unmixed(c, ca, cb, colors[k]) else { continue }
            guard m.v >= 0.2, m.v <= 1.1, m.u >= -0.1, m.u + m.v <= 1.1, m.off <= 2.25 * gap * gap, m.v > most else { continue }
            most = m.v
            found = UInt8(k)
        }
        guard let found else { return nil }
        return (a, b, found)
    }
}

/// Which colour of the palette each sample of the picture is, and from them its regions: each a
/// patch of one colour, all in one piece.
struct Labels: @unchecked Sendable {
    let W: Int
    let H: Int
    /// The palette's colour of each sample; `clear` for see-through.
    let label: Store<UInt8>
    let clear: UInt8
    /// How far each sample lies from the edge found beside it, in 32nds of a sample, where one
    /// was found exactly; 254 for far from any, 255 for not known. With it an outline is
    /// followed between the samples, not only round them.
    let near: Store<UInt8>

    /// Every sample given its colour: the palette's nearest, but where the picture is mixed of
    /// two colours, as along every soft edge and in everything thin, the one of the two it is
    /// more of.
    ///
    /// Along an edge from one colour to another, the mixed pixels pass through whatever lies
    /// between the two; where the palette has such a colour, a thin line of it would run along
    /// the edge. So a sample that is not purely its colour is looked at again: when it is a mix
    /// of two colours that lie pure beside it, it goes to one of those two, the one it is more
    /// than half of.
    ///
    /// Where such an edge runs clean through a pixel, with each colour pure a pixel or two to
    /// its side, the edge itself is found (`edge`), and every sample of the pixel lies on one
    /// side of it or the other. Everywhere else the picture is read between its pixels.
    ///
    /// A stroke thinner than a pixel never shows its own colour, only a mix nearer to what is
    /// round it, and the gap between two letters never the paper's. Such a thing shows as a
    /// ridge, lower on both its sides, or as a furrow; there, half is counted from the ridge's
    /// top or the furrow's bottom, so hairlines stay whole and small letters stay apart. A soft
    /// edge has no ridge, however blurred, and is cut at half as ever.
    static func read(_ sampler: Sampler, _ nearest: Nearest, weights: [Double], noise: Double, mixes: Bool, mixing: Mixing, worn: Bool = false) -> Labels {
        let W = sampler.W, H = sampler.H, scale = sampler.scale
        let label = Store<UInt8>(W * H, 0)
        let near = Store<UInt8>(W * H, 255)
        let clear = UInt8(nearest.colors.count)
        let raster = sampler.raster
        let seeThrough = raster.clear
        let w = raster.w, h = raster.h, p = raster.rgb.p
        let colors = nearest.colors
        guard mixes else {
            parallel(H, atLeast: 8) { rows in
                for Y in rows {
                    let row = label.p + Y * W
                    for X in 0..<W {
                        if seeThrough, sampler.solid(X, Y) < 128 {
                            row[X] = clear
                        } else {
                            let c = sampler.color(X, Y)
                            row[X] = nearest(c.x, c.y, c.z)
                        }
                    }
                }
            }
            return Labels(W: W, H: H, label: label, clear: clear, near: Store<UInt8>(W * H, 255))
        }

        // The picture's own pixels first: which colour each is, and whether purely.
        let pureGap = Int32(18 + 2.5 * min(noise, 10)), mixedGap = Int32(14 + 2 * min(noise, 10))
        let small = Store<UInt8>(w * h, 0)
        let pure = Store<Bool>(w * h, false)
        parallel(h, atLeast: 16) { rows in
            for y in rows {
                for x in 0..<w {
                    let i = y * w + x
                    if seeThrough, raster.alpha.p[i] < 128 {
                        small.p[i] = clear
                        continue
                    }
                    let c = SIMD3<Int32>(Int32(p[i * 3]), Int32(p[i * 3 + 1]), Int32(p[i * 3 + 2]))
                    let l = nearest(c.x, c.y, c.z)
                    small.p[i] = l
                    let d = c &- colors[Int(l)]
                    pure.p[i] = (d &* d).wrappedSum() <= pureGap * pureGap
                }
            }
        }
        // Broad: in a part of its colour at least three pixels across.
        let core = Store<Bool>(w * h, false)
        for y in 1..<max(h - 1, 1) {
            for x in 1..<max(w - 1, 1) {
                let i = y * w + x, v = small.p[i]
                core.p[i] = small.p[i - 1] == v && small.p[i + 1] == v && small.p[i - w] == v && small.p[i + w] == v
                    && small.p[i - w - 1] == v && small.p[i - w + 1] == v && small.p[i + w - 1] == v && small.p[i + w + 1] == v
            }
        }
        let broad = Store<Bool>(w * h, false)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, v = small.p[i]
                var found = false
                for dy in -1...1 where !found && y + dy >= 0 && y + dy < h {
                    for dx in -1...1 where x + dx >= 0 && x + dx < w {
                        let j = i + dy * w + dx
                        if core.p[j], small.p[j] == v { found = true; break }
                    }
                }
                broad.p[i] = found
            }
        }
        // For each pixel, the colours lying pure within two pixels of it, the nearest first:
        // those that lie broad, and all of them.
        let none: UInt32 = 0xFFFF_FFFF
        let broadNear = Store<UInt32>(w * h, none), anyNear = Store<UInt32>(w * h, none)
        var ring: [(Int, Int)] = []
        // Where colour is coarse, a pixel purely one colour lies further from an edge.
        let reach = mixing.coarse ? 3 : 2
        for dy in -reach...reach { for dx in -reach...reach { ring.append((dx, dy)) } }
        ring.sort { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }
        let around = ring
        parallel(h, atLeast: 16) { rows in
            for y in rows {
                for x in 0..<w {
                    var broadSet = none, anySet = none
                    var nb = 0, na = 0
                    for (dx, dy) in around {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        guard pure.p[j] else { continue }
                        let v = UInt32(small.p[j])
                        @inline(__always) func has(_ set: UInt32) -> Bool {
                            set & 0xFF == v || (set >> 8) & 0xFF == v || (set >> 16) & 0xFF == v || (set >> 24) & 0xFF == v
                        }
                        if na < 4, !has(anySet) {
                            anySet = (anySet & ~(0xFF << UInt32(na * 8))) | (v << UInt32(na * 8))
                            na += 1
                        }
                        if broad.p[j], nb < 4, !has(broadSet) {
                            broadSet = (broadSet & ~(0xFF << UInt32(nb * 8))) | (v << UInt32(nb * 8))
                            nb += 1
                        }
                    }
                    broadNear.p[y * w + x] = broadSet
                    anyNear.p[y * w + x] = anySet
                }
            }
        }

        // Still: purely its colour with all round it the same, so every sample in it is too.
        let still = Store<Bool>(w * h, false)
        parallel(h, atLeast: 16) { rows in
            for y in rows {
                for x in 0..<w {
                    let i = y * w + x, v = small.p[i]
                    var same = v == clear || pure.p[i]
                    for dy in -1...1 where same {
                        for dx in -1...1 {
                            let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                            let j = yy * w + xx
                            if small.p[j] != v || !(v == clear || pure.p[j]) { same = false; break }
                        }
                    }
                    still.p[i] = same
                }
            }
        }

        let least = 0.2 + 0.02 * min(noise, 10)
        let full = (mixing.coarse ? 0.1 : 0.06) + 0.01 * min(noise, 10)
        let wide = 2.25 * Double(mixedGap * mixedGap)
        // How little of a stroke's colour a pixel beside it may hold, where pixels waver.
        let loose = max(full, 0.16)
        let mixer = Mixer(colors: colors, weights: weights, clear: clear, pureGap: pureGap, mixedGap: mixedGap, mixing: mixing,
                          small: small, broad: broad, broadNear: broadNear, anyNear: anyNear)
        parallel(h, atLeast: 4) { rows in
            let seen = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
            let ts = UnsafeMutablePointer<Double>.allocate(capacity: 49)
            let us = UnsafeMutablePointer<Double>.allocate(capacity: 49)
            defer {
                seen.deallocate()
                ts.deallocate()
                us.deallocate()
            }
            /// How much of `b` each pixel of a square round one is, -1 where it is neither colour
            /// nor between them.
            @inline(__always) func shares(_ a: UInt8, _ b: UInt8, fromX: Int, fromY: Int, side: Int) {
                let ca = colors[Int(a)], cb = colors[Int(b)]
                for dy in 0..<side {
                    let yy = min(max(fromY + dy, 0), h - 1)
                    for dx in 0..<side {
                        let xx = min(max(fromX + dx, 0), w - 1)
                        let j = (yy * w + xx) * 3
                        let m = mixing(SIMD3<Int32>(Int32(p[j]), Int32(p[j + 1]), Int32(p[j + 2])), from: ca, to: cb)
                        let t = min(max(m.light, 0), 1)
                        ts[dy * side + dx] = m.off <= wide || t == 0 || t == 1 ? t : -1
                    }
                }
            }
            for y in rows {
                for x in 0..<w {
                    let P = y * w + x
                    if still.p[P] {
                        let v = small.p[P]
                        for sy in 0..<scale {
                            let row = label.p + (y * scale + sy) * W + x * scale
                            let far = near.p + (y * scale + sy) * W + x * scale
                            for sx in 0..<scale {
                                row[sx] = v
                                far[sx] = 254
                            }
                        }
                        continue
                    }
                    // An edge between two colours through this pixel, or a thin stroke of one in
                    // the other, found exactly.
                    if scale > 1, small.p[P] != clear {
                        let c = SIMD3<Int32>(Int32(p[P * 3]), Int32(p[P * 3 + 1]), Int32(p[P * 3 + 2]))
                        if let pair = mixer.pair(c, own: small.p[P], at: P, seen, sure: false) {
                            shares(pair.a, pair.b, fromX: x - 3, fromY: y - 3, side: 7)
                            if let edge = Labels.edge(ts, full) {
                                for sy in 0..<scale {
                                    let row = label.p + (y * scale + sy) * W + x * scale
                                    let v = (Double(sy) + 0.5) / Double(scale) - 0.5
                                    for sx in 0..<scale {
                                        if seeThrough, sampler.solid(x * scale + sx, y * scale + sy) < 128 {
                                            row[sx] = clear
                                            continue
                                        }
                                        let u = (Double(sx) + 0.5) / Double(scale) - 0.5
                                        let along = edge.upright ? v : u, across = (edge.upright ? u : v) * edge.sign
                                        let from = across - (edge.a + edge.b * along + edge.c * along * along)
                                        row[sx] = from > 0 ? pair.b : pair.a
                                        near.p[(y * scale + sy) * W + x * scale + sx] = UInt8(min(abs(from) * Double(scale * 32), 253))
                                    }
                                }
                                continue
                            }
                            var inverted = false
                            var stroke = worn ? Labels.strokeAlong(ts, loose, inverted: false) : Labels.stroke(ts, full, inverted: false)
                            if stroke == nil {
                                stroke = worn ? Labels.strokeAlong(ts, loose, inverted: true) : Labels.stroke(ts, full, inverted: true)
                                inverted = true
                            }
                            if let stroke {
                                let inside = inverted ? pair.a : pair.b, outside = inverted ? pair.b : pair.a
                                for sy in 0..<scale {
                                    let row = label.p + (y * scale + sy) * W + x * scale
                                    let v = (Double(sy) + 0.5) / Double(scale) - 0.5
                                    for sx in 0..<scale {
                                        if seeThrough, sampler.solid(x * scale + sx, y * scale + sy) < 128 {
                                            row[sx] = clear
                                            continue
                                        }
                                        let u = (Double(sx) + 0.5) / Double(scale) - 0.5
                                        let along = stroke.upright ? v : u, across = stroke.upright ? u : v
                                        let middle = stroke.a + stroke.b * along + stroke.c * along * along
                                        let from = abs(across - middle) - (stroke.thick + stroke.widening * along) / 2
                                        row[sx] = from <= 0 ? inside : outside
                                        near.p[(y * scale + sy) * W + x * scale + sx] = UInt8(min(abs(from) * Double(scale * 32), 253))
                                    }
                                }
                                continue
                            }
                        } else if pure.p[P] {
                            // Wholly its colour: whatever passes by passes outside it.
                            let v = small.p[P]
                            for sy in 0..<scale {
                                let row = label.p + (y * scale + sy) * W + x * scale
                                for sx in 0..<scale {
                                    row[sx] = seeThrough && sampler.solid(x * scale + sx, y * scale + sy) < 128 ? clear : v
                                }
                            }
                            continue
                        }
                        // A thin stroke of a third colour running between two, found exactly.
                        if let three = mixer.triple(c, at: P) {
                            let ca = colors[Int(three.a)], cb = colors[Int(three.b)], cl = colors[Int(three.l)]
                            for dy in 0..<7 {
                                let yy = min(max(y - 3 + dy, 0), h - 1)
                                for dx in 0..<7 {
                                    let xx = min(max(x - 3 + dx, 0), w - 1)
                                    let j = (yy * w + xx) * 3
                                    let q = SIMD3<Int32>(Int32(p[j]), Int32(p[j + 1]), Int32(p[j + 2]))
                                    if let m = Mixer.unmixed(q, ca, cb, cl), m.off <= 2 * wide, m.v >= -0.15, m.u >= -0.15, m.u + m.v <= 1.15 {
                                        ts[dy * 7 + dx] = min(max(m.v, 0), 1)
                                        us[dy * 7 + dx] = min(max(m.u, 0), 1)
                                    } else {
                                        ts[dy * 7 + dx] = -1
                                        us[dy * 7 + dx] = -1
                                    }
                                }
                            }
                            if let stroke = worn ? Labels.strokeAlong(ts, loose, inverted: false) : Labels.stroke(ts, full, inverted: false), stroke.thick >= 0.3 {
                                // Which side of it the second colour lies on.
                                var lean = 0.0
                                for dy in 1..<6 {
                                    for dx in 1..<6 where ts[dy * 7 + dx] >= 0 && ts[dy * 7 + dx] < 0.7 {
                                        let along = Double(stroke.upright ? dy - 3 : dx - 3), across = Double(stroke.upright ? dx - 3 : dy - 3)
                                        let off = across - (stroke.a + stroke.b * along + stroke.c * along * along)
                                        guard abs(off) >= 0.75 else { continue }
                                        let share = us[dy * 7 + dx] / (1 - ts[dy * 7 + dx])
                                        lean += (min(share, 1) - 0.5) * (off > 0 ? 1 : -1)
                                    }
                                }
                                if abs(lean) >= 1.5 {
                                    for sy in 0..<scale {
                                        let row = label.p + (y * scale + sy) * W + x * scale
                                        let v = (Double(sy) + 0.5) / Double(scale) - 0.5
                                        for sx in 0..<scale {
                                            if seeThrough, sampler.solid(x * scale + sx, y * scale + sy) < 128 {
                                                row[sx] = clear
                                                continue
                                            }
                                            let u = (Double(sx) + 0.5) / Double(scale) - 0.5
                                            let along = stroke.upright ? v : u, across = stroke.upright ? u : v
                                            let off = across - (stroke.a + stroke.b * along + stroke.c * along * along)
                                            let from = abs(off) - (stroke.thick + stroke.widening * along) / 2
                                            row[sx] = from <= 0 ? three.l : (off * lean > 0 ? three.b : three.a)
                                            near.p[(y * scale + sy) * W + x * scale + sx] = UInt8(min(abs(from) * Double(scale * 32), 253))
                                        }
                                    }
                                    continue
                                }
                            }
                        }
                    }
                    // Otherwise sample by sample, read between the pixels.
                    for sy in 0..<scale {
                        let Y = y * scale + sy
                        let row = label.p + Y * W
                        for sx in 0..<scale {
                            let X = x * scale + sx
                            if seeThrough, sampler.solid(X, Y) < 128 {
                                row[X] = clear
                                continue
                            }
                            let c = sampler.color(X, Y)
                            let own = nearest(c.x, c.y, c.z)
                            row[X] = own
                            guard let pair = mixer.pair(c, own: own, at: P, seen, sure: true) else { continue }
                            // How much of B each of the pixels round the sample is, six by six
                            // of them, and where half lies, carried evenly between the four
                            // pixels round the sample.
                            let fx = (Double(X) + 0.5) / Double(scale) - 0.5, fy = (Double(Y) + 0.5) / Double(scale) - 0.5
                            let bx = Int(fx.rounded(.down)), by = Int(fy.rounded(.down))
                            shares(pair.a, pair.b, fromX: bx - 2, fromY: by - 2, side: 6)
                            let ux = fx - Double(bx), uy = fy - Double(by)
                            let top = Labels.half(ts, 0, 0, least) * (1 - ux) + Labels.half(ts, 1, 0, least) * ux
                            let low = Labels.half(ts, 0, 1, least) * (1 - ux) + Labels.half(ts, 1, 1, least) * ux
                            let middle = top * (1 - uy) + low * uy
                            row[X] = pair.along < middle ? pair.a : pair.b
                        }
                    }
                }
            }
        }
        return Labels(W: W, H: H, label: label, clear: clear, near: near)
    }

    /// An edge between two colours through a pixel, from how much of the second colour each of
    /// the seven by seven pixels round it is.
    ///
    /// A pixel holds as much of a colour as the colour covers of it. So across the edge, the
    /// shares of a row of pixels add up to how far the colour reaches into that row: the edge's
    /// place there, to a small part of a pixel, however the edge lies on the pixels. Three such
    /// rows side by side give the edge as a curve, `across = a + b·along + c·along²`, measured
    /// from the pixel's middle, with the second colour on the side `sign` points to; `upright`
    /// when the edge runs more up and down than level. Nil where the pixels do not show one
    /// clean edge: at corners, where a third colour is near, and in everything thin.
    @inline(__always) private static func edge(_ ts: UnsafePointer<Double>, _ full: Double)
        -> (upright: Bool, sign: Double, a: Double, b: Double, c: Double)? {
        @inline(__always) func t(_ c: Int, _ r: Int) -> Double { ts[(r + 3) * 7 + c + 3] }
        var gx = 0.0, gy = 0.0
        for k in -1...1 {
            let l = t(-1, k), r = t(1, k), u = t(k, -1), d = t(k, 1)
            guard l >= 0, r >= 0, u >= 0, d >= 0 else { return nil }
            gx += r - l
            gy += d - u
        }
        guard max(abs(gx), abs(gy)) >= 0.3 else { return nil }
        let upright = abs(gx) > abs(gy)
        let sign = (upright ? gx : gy) > 0 ? 1 : -1
        @inline(__always) func s(_ k: Int, _ i: Int) -> Double {
            let d = (i - 3) * sign
            return upright ? t(d, k) : t(k, d)
        }
        /// Where the edge crosses row `k` of pixels, from the last pixel wholly the first colour
        /// to the first wholly the second.
        @inline(__always) func crossing(_ k: Int) -> Double? {
            var lo = -1
            for i in stride(from: 4, through: 0, by: -1) {
                let v = s(k, i)
                if v >= 0, v <= full { lo = i; break }
            }
            guard lo >= 0 else { return nil }
            var hi = -1
            for i in (lo + 1)...min(lo + 3, 6) where s(k, i) >= 1 - full { hi = i; break }
            guard hi >= 2 else { return nil }
            var sum = 0.0, last = 0.0
            for i in lo...hi {
                let v = s(k, i)
                guard v >= 0, v >= last - 0.08 else { return nil }
                sum += v
                last = max(last, v)
            }
            return Double(hi - 3) + 0.5 - sum
        }
        guard let middle = crossing(0) else { return nil }
        let before = crossing(-1), after = crossing(1)
        var a = middle, b = 0.0, c = 0.0
        if let before, let after {
            c = (after + before - 2 * middle) / 2
            b = (after - before) / 2
            a = middle - c / 12
        } else if let side = after ?? before {
            // Beside a corner, or where a third colour comes in, the edge is known on one side
            // only: straight from there through here.
            b = after != nil ? side - middle : middle - side
        } else {
            return nil
        }
        guard abs(c) <= 0.3, abs(b) <= 1.3, abs(a) <= 1 else { return nil }
        return (upright, Double(sign), a, b, c)
    }

    /// A thin stroke of the second colour through a pixel (or with `inverted`, a thin gap of
    /// the first colour in the second), from the seven by seven pixels round it.
    ///
    /// Across the stroke, the shares of a row of pixels add up to how thick it is there, and
    /// lie about its middle as the stroke does: both exact, however little of the stroke any
    /// one pixel holds. Three such rows give its middle as a curve, `a + b·along + c·along²`
    /// from the pixel's middle, and its thickness, `thick + widening·along`. Nil where the
    /// pixels do not show one stroke with the other colour pure on both its sides.
    @inline(__always) private static func stroke(_ ts: UnsafePointer<Double>, _ full: Double, inverted: Bool)
        -> (upright: Bool, a: Double, b: Double, c: Double, thick: Double, widening: Double)? {
        @inline(__always) func t(_ c: Int, _ r: Int) -> Double {
            let v = ts[(r + 3) * 7 + c + 3]
            return v < 0 ? -1 : inverted ? 1 - v : v
        }
        /// The stroke where it crosses row `k` of pixels (a column of them when it runs level):
        /// how thick, and where its middle is; looked for within a pixel of `around`.
        @inline(__always) func crossing(_ k: Int, _ upright: Bool, _ around: Int) -> (thick: Double, middle: Double)? {
            @inline(__always) func s(_ i: Int) -> Double { upright ? t(i - 3, k) : t(k, i - 3) }
            var top = around
            if around > 0, s(around - 1) > s(top) { top = around - 1 }
            if around < 6, s(around + 1) > s(top) { top = around + 1 }
            let peak = s(top)
            guard peak > full else { return nil }
            var sum = peak, moment = peak * Double(top - 3)
            for way in [-1, 1] {
                var i = top + way, last = peak, closed = false
                while i >= 0, i <= 6, abs(i - top) <= 3 {
                    let v = s(i)
                    guard v >= 0, v <= last + 0.08 else { return nil }
                    sum += v
                    moment += v * Double(i - 3)
                    if v <= full { closed = true; break }
                    last = min(last, v)
                    i += way
                }
                guard closed else { return nil }
            }
            return (sum, moment / sum)
        }
        let level = crossing(0, false, 3), standing = crossing(0, true, 3)
        guard level != nil || standing != nil else { return nil }
        let upright = level == nil || (standing != nil && standing!.thick < level!.thick)
        guard let mid = upright ? standing : level, mid.thick <= 3.5 else { return nil }
        let near = min(max(Int(mid.middle.rounded()) + 3, 1), 5)
        guard let before = crossing(-1, upright, near), let after = crossing(1, upright, near) else { return nil }
        guard abs(before.middle - mid.middle) <= 1.3, abs(after.middle - mid.middle) <= 1.3 else { return nil }
        let give = 0.5 * mid.thick + 0.25
        guard abs(before.thick - mid.thick) <= give, abs(after.thick - mid.thick) <= give else { return nil }
        let c = (after.middle + before.middle - 2 * mid.middle) / 2
        guard abs(c) <= 0.3 else { return nil }
        return (upright, mid.middle - c / 12, (after.middle - before.middle) / 2, c,
                (before.thick + mid.thick + after.thick) / 3, (after.thick - before.thick) / 2)
    }

    /// As `stroke`, for a picture whose pixels waver: the stroke is followed across all seven
    /// rows of pixels, as far either way as it runs on evenly, and its middle and thickness
    /// are those that fit all of them best. So what one row's pixels say amiss moves the stroke
    /// little, and next door's pixel, which sees six of the same rows, finds the same stroke.
    private static func strokeAlong(_ ts: UnsafePointer<Double>, _ full: Double, inverted: Bool)
        -> (upright: Bool, a: Double, b: Double, c: Double, thick: Double, widening: Double)? {
        @inline(__always) func t(_ c: Int, _ r: Int) -> Double {
            let v = ts[(r + 3) * 7 + c + 3]
            return v < 0 ? -1 : inverted ? 1 - v : v
        }
        func crossing(_ k: Int, _ upright: Bool, _ around: Int) -> (thick: Double, middle: Double)? {
            @inline(__always) func s(_ i: Int) -> Double { upright ? t(i - 3, k) : t(k, i - 3) }
            var top = around
            if around > 0, s(around - 1) > s(top) { top = around - 1 }
            if around < 6, s(around + 1) > s(top) { top = around + 1 }
            let peak = s(top)
            guard peak > full else { return nil }
            var sum = peak, moment = peak * Double(top - 3)
            for way in [-1, 1] {
                var i = top + way, last = peak, closed = false
                while i >= 0, i <= 6, abs(i - top) <= 3 {
                    let v = s(i)
                    guard v >= 0, v <= last + 0.15 else { return nil }
                    if v <= full { closed = true; break }
                    sum += v
                    moment += v * Double(i - 3)
                    last = min(last, v)
                    i += way
                }
                guard closed else { return nil }
            }
            return (sum, moment / sum)
        }
        let level = crossing(0, false, 3), standing = crossing(0, true, 3)
        guard level != nil || standing != nil else { return nil }
        let upright = level == nil || (standing != nil && standing!.thick < level!.thick)
        guard let mid = upright ? standing : level, mid.thick <= 3.5 else { return nil }
        var ks: [Double] = [0], middles = [mid.middle], thicks = [mid.thick]
        let give = 0.6 * mid.thick + 0.3
        var sides = 0
        for way in [-1, 1] {
            var last = mid.middle
            var any = false
            for step in 1...3 {
                let k = way * step
                let near = min(max(Int(last.rounded()) + 3, 1), 5)
                guard let found = crossing(k, upright, near), abs(found.middle - last) <= 1.3, abs(found.thick - mid.thick) <= give else { break }
                ks.append(Double(k)); middles.append(found.middle); thicks.append(found.thick)
                last = found.middle
                any = true
            }
            if any { sides += 1 }
        }
        let n = Double(ks.count)
        guard ks.count >= 4 else { return nil }
        let thick = thicks.reduce(0, +) / n
        // The middle as a line, or with rows enough on both sides as a curve, by least squares.
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, y0 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<ks.count {
            let k = ks[i], m = middles[i]
            s1 += k; s2 += k * k; s3 += k * k * k; s4 += k * k * k * k
            y0 += m; y1 += m * k; y2 += m * k * k
        }
        var a = y0 / n, b = 0.0, c = 0.0
        let lineDet = n * s2 - s1 * s1
        if lineDet > 1e-9 {
            b = (n * y1 - s1 * y0) / lineDet
            a = (y0 - b * s1) / n
        }
        if sides == 2, ks.count >= 5 {
            // n·a + s1·b + s2·c = y0;  s1·a + s2·b + s3·c = y1;  s2·a + s3·b + s4·c = y2
            let det = n * (s2 * s4 - s3 * s3) - s1 * (s1 * s4 - s3 * s2) + s2 * (s1 * s3 - s2 * s2)
            if abs(det) > 1e-9 {
                let qa = (y0 * (s2 * s4 - s3 * s3) - s1 * (y1 * s4 - s3 * y2) + s2 * (y1 * s3 - s2 * y2)) / det
                let qb = (n * (y1 * s4 - y2 * s3) - y0 * (s1 * s4 - s3 * s2) + s2 * (s1 * y2 - s2 * y1)) / det
                let qc = (n * (s2 * y2 - s3 * y1) - s1 * (s1 * y2 - s2 * y1) + y0 * (s1 * s3 - s2 * s2)) / det
                if abs(qc) <= 0.2 { a = qa; b = qb; c = qc }
            }
        }
        guard abs(a) <= 2, abs(b) <= 1.5 else { return nil }
        return (upright, a, b, c, thick, 0)
    }

    /// How much of the second of two colours counts as half of it at one pixel, from the six by
    /// six round a sample (`ox`, `oy` pick which of the middle four): half, unless the pixel
    /// lies on a ridge or in a furrow at least `least` high, when it is counted from the most
    /// or the least there is of the colour round the pixel. So a corner, with the whole colour
    /// beside it, is no ridge.
    @inline(__always) private static func half(_ ts: UnsafePointer<Double>, _ ox: Int, _ oy: Int, _ least: Double) -> Double {
        var ridge = 0.0, furrow = 0.0
        let at = (2 + oy) * 6 + 2 + ox
        let c = ts[at]
        guard c >= 0 else { return 0.5 }
        var peak = c, bottom = c
        for step in [1, 6, 7, 5] {
            let a1 = ts[at - step], b1 = ts[at + step]
            if a1 >= 0 { peak = max(peak, a1); bottom = min(bottom, a1) }
            if b1 >= 0 { peak = max(peak, b1); bottom = min(bottom, b1) }
            guard a1 >= 0, b1 >= 0 else { continue }
            var a2 = ts[at - 2 * step], b2 = ts[at + 2 * step]
            if a2 < 0 { a2 = a1 }
            if b2 < 0 { b2 = b1 }
            ridge = max(ridge, max(a1, c, b1) - max(min(a1, a2), min(b1, b2)))
            furrow = max(furrow, min(max(a1, a2), max(b1, b2)) - min(a1, c, b1))
        }
        func eased(_ x: Double) -> Double {
            let t = min(max(x, 0), 1)
            return t * t * (3 - 2 * t)
        }
        let high = 1 - (1 - peak) * eased((ridge - least) / 0.1)
        let low = bottom * eased((furrow - least) / 0.1)
        return min(max((low + high) / 2, 0.12), 0.88)
    }

    /// How far each sample is from the nearest one of another colour, in thirds of a sample
    /// (3 for a sample beside one, 4 for one across a corner).
    func depths() -> Store<UInt16> {
        let W = W, H = H, l = label.p
        let d = Store<UInt16>(W * H, 60000)
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X, v = l[i]
                if (X > 0 && l[i - 1] != v) || (X < W - 1 && l[i + 1] != v) || (Y > 0 && l[i - W] != v) || (Y < H - 1 && l[i + W] != v) {
                    d.p[i] = 3
                }
            }
        }
        Labels.spread(d.p, W, H, within: Optional<UnsafeMutablePointer<UInt8>>.none)
        return d
    }

    /// Where three colours meet in a picture kept coarsely, or two along a worn edge, a thin
    /// tongue of one colour reaches in between the others: not a part of the picture, but what
    /// its pixels made of two colours at once. Such a spur, thinner than twice `reach` samples
    /// and smaller than `most` of them, on a part of its colour that is not thin, goes to the
    /// colours beside it. A line, however thin, is longer than that and stays.
    func withoutSpurs(reach: Int, most: Int) {
        let W = W, H = H, l = label.p
        guard reach >= 1, W * H > 0 else { return }
        // Far enough inside its colour to be left when the colour is worn down by `reach`…
        let depth = depths()
        let back = Store<UInt16>(W * H, 60000)
        for i in 0..<(W * H) where depth.p[i] > UInt16(3 * reach) { back.p[i] = 0 }
        // …and what comes back when it is grown again by as much: all but what was thin.
        Labels.spread(back.p, W, H, within: l)
        let thin = Store<Bool>(W * H, false)
        for i in 0..<(W * H) where back.p[i] > UInt16(3 * reach + 1) { thin.p[i] = true }
        // The thin parts piece by piece: those small, and joined to a part that is not thin.
        let seen = Store<Bool>(W * H, false)
        var piece: [Int32] = [], going: [Int32] = []
        for first in 0..<(W * H) where thin.p[first] && !seen.p[first] {
            piece.removeAll(keepingCapacity: true)
            piece.append(Int32(first))
            seen.p[first] = true
            let v = l[first]
            var joined = false
            var at = 0
            while at < piece.count {
                let i = Int(piece[at])
                at += 1
                let X = i % W, Y = i / W
                @inline(__always) func look(_ j: Int) {
                    guard l[j] == v else { return }
                    if !thin.p[j] { joined = true } else if !seen.p[j] {
                        seen.p[j] = true
                        piece.append(Int32(j))
                    }
                }
                if X > 0 { look(i - 1) }
                if X < W - 1 { look(i + 1) }
                if Y > 0 { look(i - W) }
                if Y < H - 1 { look(i + W) }
            }
            if joined, piece.count <= most { going += piece } else { for i in piece { thin.p[Int(i)] = false } }
        }
        guard !going.isEmpty else { return }
        // Each takes the colour beside it that is not its own, from the outside in.
        var left = going
        for _ in 0..<(4 * reach + 8) {
            var taken: [(Int32, UInt8)] = [], next: [Int32] = []
            for at in left {
                let i = Int(at), X = i % W, Y = i / W, own = l[i]
                var to: UInt8?
                @inline(__always) func look(_ j: Int) {
                    if to == nil, !thin.p[j], l[j] != own { to = l[j] }
                }
                if X > 0 { look(i - 1) }
                if X < W - 1 { look(i + 1) }
                if Y > 0 { look(i - W) }
                if Y < H - 1 { look(i + W) }
                if let to { taken.append((at, to)) } else { next.append(at) }
            }
            guard !taken.isEmpty else { break }
            for (at, to) in taken {
                l[Int(at)] = to
                thin.p[Int(at)] = false
                near.p[Int(at)] = 255
            }
            left = next
            if left.isEmpty { break }
        }
    }

    /// Distances carried on from where they are set, by 3 to the side and 4 across a corner;
    /// `within` keeps them inside samples of one value.
    static func spread<V: Equatable>(_ d: UnsafeMutablePointer<UInt16>, _ W: Int, _ H: Int, within: UnsafeMutablePointer<V>?) {
        @inline(__always) func take(_ i: Int, _ j: Int, _ step: UInt16) {
            if let within, within[i] != within[j] { return }
            let v = d[j] &+ step
            if v < d[i] { d[i] = v }
        }
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X
                if d[i] == 0 { continue }
                if X > 0 { take(i, i - 1, 3) }
                if Y > 0 {
                    take(i, i - W, 3)
                    if X > 0 { take(i, i - W - 1, 4) }
                    if X < W - 1 { take(i, i - W + 1, 4) }
                }
            }
        }
        for Y in stride(from: H - 1, through: 0, by: -1) {
            for X in stride(from: W - 1, through: 0, by: -1) {
                let i = Y * W + X
                if d[i] == 0 { continue }
                if X < W - 1 { take(i, i + 1, 3) }
                if Y < H - 1 {
                    take(i, i + W, 3)
                    if X < W - 1 { take(i, i + W + 1, 4) }
                    if X > 0 { take(i, i + W - 1, 4) }
                }
            }
        }
    }
}

/// The picture's regions: each sample's region, and of each region its colour, size and box.
struct Regions: @unchecked Sendable {
    let W: Int
    let H: Int
    let id: Store<Int32>
    var label: [UInt8]
    var area: [Int32]
    /// minX, minY, maxX, maxY of its samples.
    var box: [SIMD4<Int32>]

    var count: Int { label.count }

    /// The patches of samples of one colour that hang together by their sides.
    static func find(_ labels: Labels) -> Regions {
        let W = labels.W, H = labels.H, l = labels.label.p
        let id = Store<Int32>(W * H, 0)
        var parent: [Int32] = []
        parent.reserveCapacity(4096)
        func root(_ i: Int32, _ parent: inout [Int32]) -> Int32 {
            var r = i
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = i
            while parent[Int(c)] != r {
                let next = parent[Int(c)]
                parent[Int(c)] = r
                c = next
            }
            return r
        }
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X, v = l[i]
                let left = X > 0 && l[i - 1] == v, up = Y > 0 && l[i - W] == v
                if left && up {
                    let a = root(id.p[i - 1], &parent), b = root(id.p[i - W], &parent)
                    if a != b { parent[Int(max(a, b))] = min(a, b) }
                    id.p[i] = min(a, b)
                } else if left {
                    id.p[i] = id.p[i - 1]
                } else if up {
                    id.p[i] = id.p[i - W]
                } else {
                    id.p[i] = Int32(parent.count)
                    parent.append(Int32(parent.count))
                }
            }
        }
        var renamed = [Int32](repeating: -1, count: parent.count)
        var label: [UInt8] = [], area: [Int32] = [], box: [SIMD4<Int32>] = []
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X
                let r = Int(root(id.p[i], &parent))
                if renamed[r] < 0 {
                    renamed[r] = Int32(label.count)
                    label.append(l[i])
                    area.append(0)
                    box.append(SIMD4(Int32(X), Int32(Y), Int32(X), Int32(Y)))
                }
                let n = Int(renamed[r])
                id.p[i] = Int32(n)
                area[n] += 1
                let b = box[n]
                box[n] = SIMD4(min(b.x, Int32(X)), min(b.y, Int32(Y)), max(b.z, Int32(X)), max(b.w, Int32(Y)))
            }
        }
        return Regions(W: W, H: H, id: id, label: label, area: area, box: box)
    }

    /// A line too thin to show its own colour shows a mix of it and what it lies on, and a
    /// different mix every few pixels: read by its colours it is a row of short pieces. Thin
    /// regions, none deeper than `thin` samples, that touch and are more like each other than
    /// like what they lie on are one line, of the colour among them that stands out most.
    /// Changes `labels` to match, and says whether it did.
    ///
    /// In a picture kept coarsely (`worn`), a piece is of the line it touches too when its
    /// colour is a mix of the line's and of what it lies on, however much of each.
    func threaded(_ labels: Labels, colors: [SIMD3<Int32>], thin: Int, worn: Bool) -> Bool {
        let W = W, H = H, l = labels.label.p, id = id.p
        guard count > 2 else { return false }
        let depth = labels.depths()
        var deepest = [UInt16](repeating: 0, count: count)
        for i in 0..<(W * H) {
            let r = Int(id[i])
            if depth.p[i] > deepest[r] { deepest[r] = depth.p[i] }
        }
        let isThin = deepest.map { $0 <= UInt16(3 * thin) }
        guard isThin.contains(true) else { return false }
        // How long a border each region shares with each beside it.
        var borders: [UInt64: Int32] = [:]
        @inline(__always) func meet(_ a: Int32, _ b: Int32) {
            guard a != b, isThin[Int(a)] || isThin[Int(b)] else { return }
            borders[UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b))), default: 0] += 1
        }
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X
                if X < W - 1 { meet(id[i], id[i + 1]) }
                if Y < H - 1 { meet(id[i], id[i + W]) }
            }
        }
        func gap(_ a: UInt8, _ b: UInt8) -> Double {
            guard Int(a) < colors.count, Int(b) < colors.count else { return 120 }
            let d = colors[Int(a)] &- colors[Int(b)]
            return Double((d &* d).wrappedSum()).squareRoot()
        }
        /// Whether colour `c` could be a mix of `g` and `e`: on the way from one to the other,
        /// or not far beside it.
        func mixed(_ c: UInt8, of g: UInt8, and e: UInt8) -> Bool {
            guard Int(c) < colors.count, Int(g) < colors.count, Int(e) < colors.count else { return false }
            let v = SIMD3<Double>(colors[Int(e)] &- colors[Int(g)]), w = SIMD3<Double>(colors[Int(c)] &- colors[Int(g)])
            let l2 = (v * v).sum()
            guard l2 > 900 else { return false }
            let t = (w * v).sum() / l2
            guard t > 0.15, t < 1.05 else { return false }
            let off = w - v * t
            return (off * off).sum() < 0.35 * 0.35 * l2
        }
        // What each thin region lies on: the region beside it that is not thin, of the longest
        // border with it.
        var ground = [Int32](repeating: -1, count: count), most = [Int32](repeating: 0, count: count)
        for (key, n) in borders {
            let a = Int(key >> 32), b = Int(key & 0xffff_ffff)
            if isThin[a], !isThin[b], n > most[a] || (n == most[a] && Int32(b) < ground[a]) { most[a] = n; ground[a] = Int32(b) }
            if isThin[b], !isThin[a], n > most[b] || (n == most[b] && Int32(a) < ground[b]) { most[b] = n; ground[b] = Int32(a) }
        }
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        var any = false
        for key in borders.keys.sorted() {
            let a = Int(key >> 32), b = Int(key & 0xffff_ffff)
            guard isThin[a], isThin[b], ground[a] >= 0, ground[b] >= 0 else { continue }
            guard Int(label[a]) < colors.count, Int(label[b]) < colors.count else { continue }
            let onA = gap(label[a], label[Int(ground[a])]), onB = gap(label[b], label[Int(ground[b])])
            guard gap(label[a], label[b]) < 0.75 * min(onA, onB)
                || (worn && (mixed(label[b], of: label[Int(ground[b])], and: label[a]) || mixed(label[a], of: label[Int(ground[a])], and: label[b])))
            else { continue }
            let ra = root(a), rb = root(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb); any = true }
        }
        guard any else { return false }
        // Each line's colour: the one most of it is; where its pieces are mixes, counted more
        // the more it stands out. A picture that wavers was read stroke by stroke already.
        var weight: [Int: [UInt8: Double]] = [:]
        for r in 0..<count where isThin[r] && ground[r] >= 0 {
            let g = root(r)
            weight[g, default: [:]][label[r], default: 0] += Double(area[r]) * (worn ? 1 : gap(label[r], label[Int(ground[r])]))
        }
        var to = label
        var changed = false
        for r in 0..<count where isThin[r] {
            guard let found = weight[root(r)], found.count > 1 else { continue }
            let best = found.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
            if best != label[r] { to[r] = best; changed = true }
        }
        guard changed else { return false }
        for i in 0..<(W * H) {
            let r = Int(id[i])
            if to[r] != label[r] { l[i] = to[r] }
        }
        return true
    }

    /// Along the edges of a picture kept coarsely runs a fringe: a pixel's width of a colour
    /// that is neither side's, in pieces. A thin region, none of it deeper than `thin` samples,
    /// that hardly stands out from one of the regions it lies along, by less than `faint` when
    /// its width in pixels is counted in, is such a fringe and no line of the picture: its
    /// samples go to the regions beside it, from the outside in. Changes `labels` to match,
    /// and says whether it did.
    func withoutFringes(_ labels: Labels, colors: [SIMD3<Int32>], thin: Int, scale: Int, faint: Double) -> Bool {
        let W = W, H = H, l = labels.label.p, id = id.p
        guard count > 2, faint > 0 else { return false }
        let depth = labels.depths()
        var deepest = [UInt16](repeating: 0, count: count)
        for i in 0..<(W * H) {
            let r = Int(id[i])
            if depth.p[i] > deepest[r] { deepest[r] = depth.p[i] }
        }
        let isThin = deepest.map { $0 <= UInt16(3 * thin) }
        guard isThin.contains(true) else { return false }
        var borders: [UInt64: Int32] = [:]
        var around = [Int32](repeating: 0, count: count)
        @inline(__always) func meet(_ a: Int32, _ b: Int32) {
            guard a != b, isThin[Int(a)] || isThin[Int(b)] else { return }
            borders[UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b))), default: 0] += 1
            around[Int(a)] += 1
            around[Int(b)] += 1
        }
        for Y in 0..<H {
            for X in 0..<W {
                let i = Y * W + X
                if X < W - 1 { meet(id[i], id[i + 1]) }
                if Y < H - 1 { meet(id[i], id[i + W]) }
            }
        }
        func gap(_ a: UInt8, _ b: UInt8) -> Double {
            guard Int(a) < colors.count, Int(b) < colors.count else { return 120 }
            let d = colors[Int(a)] &- colors[Int(b)]
            return Double((d &* d).wrappedSum()).squareRoot()
        }
        // How little each thin region stands out from what it lies along: from the most like it
        // of the regions that have a real share of its border.
        var like = [Double](repeating: .greatestFiniteMagnitude, count: count)
        for (key, n) in borders {
            let a = Int(key >> 32), b = Int(key & 0xffff_ffff)
            let apart = gap(label[a], label[b])
            if isThin[a], Double(n) >= 0.15 * Double(around[a]) { like[a] = min(like[a], apart) }
            if isThin[b], Double(n) >= 0.15 * Double(around[b]) { like[b] = min(like[b], apart) }
        }
        var going = [Bool](repeating: false, count: count)
        var any = false
        for r in 0..<count where isThin[r] && Int(label[r]) < colors.count && like[r] < .greatestFiniteMagnitude {
            let width = max(2 * Double(deepest[r]) / 3, 1) / Double(scale)
            if width * like[r] < faint { going[r] = true; any = true }
        }
        guard any else { return false }
        var left: [Int32] = []
        for i in 0..<(W * H) where going[Int(id[i])] { left.append(Int32(i)) }
        let marked = Store<Bool>(W * H, false)
        for i in left { marked.p[Int(i)] = true }
        for _ in 0..<(4 * thin + 8) {
            var taken: [(Int32, UInt8)] = [], next: [Int32] = []
            for at in left {
                let i = Int(at), X = i % W, Y = i / W
                var to: UInt8?
                @inline(__always) func look(_ j: Int) {
                    if to == nil, !marked.p[j] { to = l[j] }
                }
                if X > 0 { look(i - 1) }
                if X < W - 1 { look(i + 1) }
                if Y > 0 { look(i - W) }
                if Y < H - 1 { look(i + W) }
                if let to { taken.append((at, to)) } else { next.append(at) }
            }
            guard !taken.isEmpty else { break }
            for (at, to) in taken {
                l[Int(at)] = to
                marked.p[Int(at)] = false
                labels.near.p[Int(at)] = 255
            }
            left = next
            if left.isEmpty { break }
        }
        return true
    }

    /// Regions smaller than `least` samples, the smallest first, go to the neighbour they share
    /// the longest border with, one of a like colour sooner. Changes `labels` to match.
    ///
    /// A region hardly apart from the neighbour it would go to, as a blotch in a picture kept
    /// coarsely is, goes at a larger size: one whose colour is `faint` or less from its
    /// neighbour's at up to thirty times `least`, by the square of how alike the two are.
    func withoutSpecks(_ labels: Labels, colors: [SIMD3<Int32>], least: Int, faint: Double = 0) -> Labels {
        let W = W, H = H, l = labels.label.p, id = id.p
        var area = area
        var first = [Int32](repeating: -1, count: count)
        for i in 0..<(W * H) where first[Int(id[i])] < 0 { first[Int(id[i])] = Int32(i) }
        var label = label
        let widest = faint > 0 ? 30 * least : least
        let small = (0..<count).filter { Int(area[$0]) < widest }.sorted { area[$0] < area[$1] }
        var pixels: [Int32] = []
        var borders: [Int32: Int] = [:]
        func gap(_ a: UInt8, _ b: UInt8) -> Double {
            guard Int(a) < colors.count, Int(b) < colors.count else { return 120 }
            let d = colors[Int(a)] &- colors[Int(b)]
            return Double((d &* d).wrappedSum()).squareRoot()
        }
        for _ in 0..<2 {
            for r in small where area[r] > 0 && Int(area[r]) < widest {
                pixels.removeAll(keepingCapacity: true)
                borders.removeAll(keepingCapacity: true)
                let me = Int32(r)
                // Its samples, marked as they are found.
                pixels.append(first[r])
                id[Int(first[r])] = -1
                var at = 0
                while at < pixels.count {
                    let i = Int(pixels[at])
                    at += 1
                    let X = i % W, Y = i / W
                    @inline(__always) func look(_ j: Int) {
                        let other = id[j]
                        if other == me {
                            id[j] = -1
                            pixels.append(Int32(j))
                        } else if other >= 0 {
                            borders[other, default: 0] += 1
                        }
                    }
                    if X > 0 { look(i - 1) }
                    if X < W - 1 { look(i + 1) }
                    if Y > 0 { look(i - W) }
                    if Y < H - 1 { look(i + W) }
                }
                var best = -1.0, target: Int32 = -1
                for (other, n) in borders {
                    let score = Double(n) / (20 + gap(label[r], label[Int(other)]))
                    if score > best || (score == best && other < target) { best = score; target = other }
                }
                if target >= 0, Int(area[r]) >= least {
                    // Too large to go for its size alone: only when it is faint enough.
                    let apart = max(gap(label[r], label[Int(target)]), 1)
                    let allowed = Double(least) * min(30, (faint / apart) * (faint / apart))
                    if Double(area[r]) >= allowed { target = -2 }
                }
                for i in pixels {
                    id[Int(i)] = target >= 0 ? target : me
                    if target >= 0 {
                        l[Int(i)] = label[Int(target)]
                        labels.near.p[Int(i)] = 255
                    }
                }
                if target >= 0 {
                    area[Int(target)] += area[r]
                    area[r] = 0
                    label[r] = label[Int(target)]
                }
            }
        }
        return labels
    }
}
