import Foundation

// Colours that run into each other, as the sky of a poster does or the light on a ball, have no
// edges, but a palette has only so many colours: read by them such a place is a row of bands,
// each one colour, with borders between them that the picture does not have. Here the bands are
// found again by just that: two regions of nearly the same colour whose border the picture
// passes without a step are one thing. The things so found are held against the two ways a
// design app has of running colours across a shape, straight across or outward from a middle,
// and where one of them fits, the bands become one region with those colours.

extension Vectorizer {
    /// The regions with every run of colours made one region, and for each region the colours
    /// that run across it (`start` and `end` in the raster's pixels) or nil for one colour.
    static func blended(_ regions: Regions, labels: Labels, raster: Raster, colors: [SIMD3<Int32>], scale: Int, noise: Double, mixing: Mixing)
        -> (regions: Regions, blends: [Blend?])? {
        let W = regions.W, H = regions.H, id = regions.id.p, count = regions.count
        let w = raster.w, h = raster.h, p = raster.rgb.p
        guard count >= 2, count < 60000, w >= 8, h >= 8 else { return nil }
        @inline(__always) func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 3
            return SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
        }

        // How alike two of the palette's colours are: bands beside each other are nearly the same.
        let n = colors.count
        var alike = [Bool](repeating: false, count: 256 * 256)
        var apart = [Double](repeating: 0, count: 256 * 256)
        for a in 0..<n {
            for b in 0..<n where a != b {
                let d = colors[a] &- colors[b]
                let gap = Double((d &* d).wrappedSum()).squareRoot()
                alike[a << 8 | b] = gap <= 72
                apart[a << 8 | b] = gap
            }
        }

        // Every border between two regions: how long it is, and along how much of it the
        // picture takes no step across it. A real edge between the two takes a step as big as
        // the two differ, or most of it, from the pixel before to the pixel after; and an edge
        // out of focus takes there a good part of all the change of the pixels around, where
        // colours that run on change as much before and after as they do across.
        struct Border {
            var long = 0
            var told = 0
            var soft = 0
        }
        var borders: [UInt64: Border] = [:]
        var lastKey: UInt64 = .max, last = Border()
        let half = scale / 2
        /// The region a pixel's middle lies in.
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int32 {
            id[min(min(max(y, 0), h - 1) * scale + half, H - 1) * W + min(min(max(x, 0), w - 1) * scale + half, W - 1)]
        }
        @inline(__always) func meet(_ a: Int32, _ b: Int32, _ x: Int, _ y: Int, _ dx: Int, _ dy: Int) {
            let la = Int(regions.label[Int(a)]), lb = Int(regions.label[Int(b)])
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if key != lastKey {
                if lastKey != .max { borders[lastKey] = last }
                lastKey = key
                last = borders[key] ?? Border()
            }
            last.long += 1
            guard alike[la << 8 | lb] else {
                last.told += 1
                return
            }
            // Only where the pixels either side are the two's own: where one is something
            // else's, the step tells of that and nothing of the two.
            @inline(__always) func theirs(_ far: Int) -> Bool {
                let before = at(x - far * dx, y - far * dy), after = at(x + far * dx, y + far * dy)
                return (before == a || before == b) && (after == a || after == b)
            }
            guard theirs(1) else { return }
            last.told += 1
            let gap = apart[la << 8 | lb]
            let near = color(x + dx, y + dy) - color(x - dx, y - dy)
            let step = (near * near).sum()
            guard step <= 0.25 * gap * gap else { return }
            if step > 0.0225 * gap * gap, theirs(4) {
                let wide = color(x + 4 * dx, y + 4 * dy) - color(x - 4 * dx, y - 4 * dy)
                guard (near * wide).sum() <= 0.4 * (wide * wide).sum() else { return }
            }
            last.soft += 1
        }
        for Y in 0..<H {
            let y = Y / scale
            for X in 0..<W {
                let i = Y * W + X, a = id[i]
                if X + 1 < W, id[i + 1] != a { meet(a, id[i + 1], (2 * X + 1) / (2 * scale), y, 1, 0) }
                if Y + 1 < H, id[i + W] != a { meet(a, id[i + W], X / scale, (2 * Y + 1) / (2 * scale), 0, 1) }
            }
        }
        if lastKey != .max { borders[lastKey] = last }
        guard borders.contains(where: { $0.value.soft > 0 }) else { return nil }

        // Regions that the picture passes between without a step are one run of colours. They
        // are put together two at a time, those first between which the least of a step is,
        // and what lies between two is then all that lies between any of the one's and any of
        // the other's: so two that an edge parts do not become one by a third they both run
        // into.
        var parent = [Int32](0..<Int32(count))
        func root(_ i: Int32) -> Int32 {
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
        var any = false
        var between = borders
        for _ in 0..<32 {
            // Three pixels of border without a step at least, and a third of it: the rest may
            // run along the edge of something else, where both are mixed with that.
            let sure = between.filter { $0.value.soft >= 3 * scale && 3 * $0.value.soft >= $0.value.told }
                .sorted {
                    let a = $0.value.soft * $1.value.told, b = $1.value.soft * $0.value.told
                    return a != b ? a > b : $0.key < $1.key
                }
            guard !sure.isEmpty else { break }
            var taken = Set<Int32>()
            for (key, _) in sure {
                let a = Int32(key >> 32), b = Int32(key & 0xFFFF_FFFF)
                guard !taken.contains(a), !taken.contains(b) else { continue }
                taken.insert(a)
                taken.insert(b)
                parent[Int(b)] = a
                any = true
            }
            var next: [UInt64: Border] = [:]
            for (key, border) in between {
                let a = root(Int32(key >> 32)), b = root(Int32(key & 0xFFFF_FFFF))
                guard a != b else { continue }
                let joined = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                var sum = next[joined] ?? Border()
                sum.long += border.long
                sum.told += border.told
                sum.soft += border.soft
                next[joined] = sum
            }
            between = next
        }
        guard any else { return nil }

        // The runs, and each one's pixels: those wholly inside it, away from its edges.
        var runOf = [Int32](repeating: -1, count: count)
        var members: [[Int]] = []
        var parts = [Int32](repeating: 0, count: count)
        for r in 0..<count { parts[Int(root(Int32(r)))] += 1 }
        for r in 0..<count {
            let top = Int(root(Int32(r)))
            guard parts[top] >= 2 else { continue }
            if runOf[top] < 0 {
                runOf[top] = Int32(members.count)
                members.append([])
            }
            runOf[r] = runOf[top]
            members[Int(runOf[top])].append(r)
        }
        let runs = members.count
        guard runs > 0 else { return nil }
        // Which run each pixel is of, by its middle.
        var runAt = [Int32](repeating: -1, count: w * h)
        for y in 0..<h {
            let row = min(y * scale + half, H - 1) * W
            for x in 0..<w { runAt[y * w + x] = runOf[Int(id[row + min(x * scale + half, W - 1)])] }
        }
        // Two pixels from anything else: an edge's own pixels are mixed with what lies beyond
        // it, and the pixels beside those are held against them here.
        var pixels = [[Int32]](repeating: [], count: runs)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let g = runAt[y * w + x]
                guard g >= 0 else { continue }
                var within = true
                for dy in -2...2 where within {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -2...2 {
                        let xx = x + dx
                        if xx >= 0, xx < w, runAt[yy * w + xx] != g { within = false; break }
                    }
                }
                if within { pixels[Int(g)].append(Int32(y * w + x)) }
            }
        }

        // Held against colours running straight across and colours running outward from a
        // middle: every pixel is then the colour of its place along the way, and how far the
        // pixels of one place differ among themselves tells how well the way fits.
        let fits = UnsafeMutablePointer<Blend?>.allocate(capacity: runs)
        fits.initialize(repeating: nil, count: runs)
        defer {
            fits.deinitialize(count: runs)
            fits.deallocate()
        }
        let found = Sent(fits)
        let all = pixels
        let most = 3 + 0.6 * min(noise, 10)
        parallel(runs, atLeast: 1) { range in
            for g in range { found.value[g] = fit(all[g], raster: raster, most: most) }
        }
        guard (0..<runs).contains(where: { fits[$0] != nil }) else { return nil }

        // What lies thin beside such a run is often the run's edge there and nothing of its
        // own. In one of the run's colours and between the run and something else, it is the
        // edge's pixels, mixed with the other's colour and read as the band of the run that
        // came nearest. In one of its colours, in the run and thinner than a pixel, it is a
        // band read a little too far. And in any colour, with pixels much nearer the run's
        // colours there than the colour it was read as, it is the light or dark line a picture
        // kept coarsely has along its edges. All three are the run's.
        var around = [Int](repeating: 0, count: count)
        for (key, border) in borders {
            around[Int(key >> 32)] += border.long
            around[Int(key & 0xFFFF_FFFF)] += border.long
        }
        var own = [Set<UInt8>](repeating: [], count: runs)
        for g in 0..<runs where fits[g] != nil {
            for r in members[g] { own[g].insert(regions.label[r]) }
        }
        // What was taken lies beside the next: a second round, and a third.
        for _ in 0..<3 {
            var beside: [UInt64: Int] = [:]
            for (key, border) in borders {
                let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
                for (r, other) in [(a, b), (b, a)] {
                    let g = Int(runOf[other])
                    guard g >= 0, fits[g] != nil, runOf[r] < 0 || fits[Int(runOf[r])] == nil else { continue }
                    beside[UInt64(r) << 32 | UInt64(g), default: 0] += border.long
                }
            }
            var edge: [Int: (run: Int32, long: Int)] = [:]
            var asked: [Int: (run: Int32, long: Int)] = [:]
            for (key, long) in beside {
                let r = Int(key >> 32), g = Int32(key & 0xFFFF_FFFF)
                // A quarter of what is round it the run, and two and a half pixels thick at most.
                let thick = 2 * Double(regions.area[r]) / Double(around[r] * scale)
                guard 4 * long >= around[r], thick <= 2.5 else { continue }
                if own[Int(g)].contains(regions.label[r]), 4 * (around[r] - long) >= around[r] || thick <= 0.8 {
                    if let have = edge[r], have.long > long || (have.long == long && have.run < g) { continue }
                    edge[r] = (g, long)
                } else if Int(regions.label[r]) < n {
                    if let have = asked[r], have.long > long || (have.long == long && have.run < g) { continue }
                    asked[r] = (g, long)
                }
            }
            var taken = !edge.isEmpty
            for (r, to) in edge {
                runOf[r] = to.run
                asked[r] = nil
            }
            if !asked.isEmpty {
                var run = [Int32](repeating: -1, count: count)
                for (r, to) in asked { run[r] = to.run }
                var mine = [Double](repeating: 0, count: count), theirs = [Double](repeating: 0, count: count)
                for y in 0..<h {
                    for x in 0..<w {
                        let r = Int(at(x, y))
                        guard run[r] >= 0, let blend = fits[Int(run[r])] else { continue }
                        let c = color(x, y), there = blend.color(at: Spot(Double(x) + 0.5, Double(y) + 0.5))
                        let a = c - SIMD3<Double>(colors[Int(regions.label[r])]), b = c - SIMD3(Double(there.r), Double(there.g), Double(there.b))
                        mine[r] += (a * a).sum()
                        theirs[r] += (b * b).sum()
                    }
                }
                // Twice as near the run's colours.
                for r in 0..<count where run[r] >= 0 && mine[r] > 0 && 4 * theirs[r] <= mine[r] {
                    runOf[r] = run[r]
                    taken = true
                }
            }
            if !taken { break }
        }

        // The regions again, each run that fits one region.
        var renamed = [Int32](repeating: -1, count: count)
        var label: [UInt8] = [], area: [Int32] = [], box: [SIMD4<Int32>] = [], blends: [Blend?] = []
        var regionOfRun = [Int32](repeating: -1, count: runs)
        for r in 0..<count {
            let g = Int(runOf[r])
            if g >= 0, let blend = fits[g] {
                if regionOfRun[g] < 0 {
                    regionOfRun[g] = Int32(label.count)
                    // Named after its biggest part.
                    let biggest = members[g].max { regions.area[$0] < regions.area[$1] } ?? r
                    label.append(regions.label[biggest])
                    area.append(0)
                    box.append(regions.box[r])
                    blends.append(blend)
                }
                let m = Int(regionOfRun[g])
                renamed[r] = Int32(m)
                area[m] += regions.area[r]
                let a = box[m], b = regions.box[r]
                box[m] = SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w))
            } else {
                renamed[r] = Int32(label.count)
                label.append(regions.label[r])
                area.append(regions.area[r])
                box.append(regions.box[r])
                blends.append(nil)
            }
        }
        let newId = Store<Int32>(W * H, 0)
        let to = Sent(newId.p)
        let names = renamed
        let old = regions.id
        parallel(H, atLeast: 64) { rows in
            for Y in rows {
                for i in (Y * W)..<((Y + 1) * W) { to.value[i] = names[Int(old.p[i])] }
            }
        }
        // And the edges of the runs, each where the run's own colours put it.
        var made = Regions(W: W, H: H, id: newId, label: label, area: area, box: box)
        placed(&made, near: labels.near, raster: raster, scale: scale, mixing: mixing,
               coloured: Coloured(blends: blends, flat: label.map { Int($0) < n ? SIMD3<Double>(colors[Int($0)]) : nil }))
        return (made, blends)
    }

    /// The colours that run across some pixels of a picture, if they run straight across or
    /// outward from a middle, with the pixels of one place along the way differing by `most`
    /// at most.
    private static func fit(_ pixels: [Int32], raster: Raster, most: Double) -> Blend? {
        let w = raster.w, p = raster.rgb.p
        guard pixels.count >= 48 else { return nil }
        @inline(__always) func color(_ i: Int) -> SIMD3<Double> { SIMD3(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2])) }

        // Which way the colours change at each pixel. Straight across, they all change one
        // way; outward from a middle, each along its line through the middle.
        var txx = 0.0, txy = 0.0, tyy = 0.0
        var bx = 0.0, by = 0.0
        var mean = SIMD3<Double>.zero, midX = 0.0, midY = 0.0
        for at in pixels {
            let i = Int(at), x = Double(i % w) + 0.5, y = Double(i / w) + 0.5
            let gx = (color(i + 1) - color(i - 1)) * 0.5, gy = (color(i + w) - color(i - w)) * 0.5
            let xx = (gx * gx).sum(), xy = (gx * gy).sum(), yy = (gy * gy).sum()
            txx += xx; txy += xy; tyy += yy
            // (|g|² − g gᵀ) p, summed over the three colours' changes.
            bx += yy * x - xy * y
            by += xx * y - xy * x
            mean += color(i)
            midX += x
            midY += y
        }
        let count = Double(pixels.count)
        mean /= count
        midX /= count
        midY /= count
        // Nothing runs where the pixels hardly change.
        guard (txx + tyy) / count >= 0.02 else { return nil }

        /// How far the pixels of one place differ among themselves when the place of each is
        /// `place`, how much of all the change along the way one short stretch of it holds, and
        /// the colours along the places, from `from` to `to`.
        func along(_ from: Double, _ to: Double, _ place: (Double, Double) -> Double) -> (off: Double, held: Double, colors: [SIMD3<Double>], filled: [Bool])? {
            let span = to - from
            guard span >= 4 else { return nil }
            let bins = min(max(Int(span / 1.5), 8), 96)
            var sum = [SIMD3<Double>](repeating: .zero, count: bins), n = [Double](repeating: 0, count: bins)
            for at in pixels {
                let i = Int(at)
                let t = (place(Double(i % w) + 0.5, Double(i / w) + 0.5) - from) / span * Double(bins)
                // Shared between the two places it lies between, so a place's colour is that
                // of its middle.
                let f = t - 0.5, k = Int(f.rounded(.down)), u = f - Double(k)
                let c = color(i)
                if k >= 0, k < bins { sum[k] += c * (1 - u); n[k] += 1 - u }
                if k + 1 >= 0, k + 1 < bins { sum[k + 1] += c * u; n[k + 1] += u }
            }
            var colors = [SIMD3<Double>](repeating: .zero, count: bins), filled = [Bool](repeating: false, count: bins)
            for k in 0..<bins where n[k] >= 0.5 {
                colors[k] = sum[k] / n[k]
                filled[k] = true
            }
            guard filled.contains(true) else { return nil }
            // Places none of its pixels lie at take the colour of the nearest that has some.
            var lastFilled = -1
            for k in 0..<bins {
                if filled[k] { lastFilled = k } else if lastFilled >= 0 { colors[k] = colors[lastFilled] }
            }
            if let first = filled.firstIndex(of: true), first > 0 {
                for k in 0..<first { colors[k] = colors[first] }
            }
            var off = 0.0
            for at in pixels {
                let i = Int(at)
                let t = (place(Double(i % w) + 0.5, Double(i / w) + 0.5) - from) / span * Double(bins)
                let f = min(max(t - 0.5, 0), Double(bins - 1)), k = min(Int(f), bins - 2), u = f - Double(k)
                let d = color(i) - (colors[k] * (1 - u) + colors[k + 1] * u)
                off += (d * d).sum()
            }
            // How much of all the change along the way its busiest eight pixels hold, or its
            // busiest seventh where it is short.
            let reach = max(1, min(Int(8 * Double(bins) / span), bins / 7))
            var steps = [Double](repeating: 0, count: bins - 1), all = 0.0
            for k in 0..<(bins - 1) where filled[k] && filled[k + 1] {
                let d = colors[k + 1] - colors[k]
                steps[k] = (d * d).sum().squareRoot()
                all += steps[k]
            }
            var held = 0.0, running = 0.0
            for k in 0..<(bins - 1) where all > 0 {
                running += steps[k]
                if k >= reach { running -= steps[k - reach] }
                held = max(held, running / all)
            }
            return ((off / count / 3).squareRoot(), held, colors, filled)
        }

        /// The colours along a way as stops: as few as keep every place's colour within two
        /// steps of what it was.
        func stops(_ colors: [SIMD3<Double>]) -> [Blend.Stop] {
            let bins = colors.count
            // The first and last places' colours are those of their middles: half a place
            // further out the colours have run on a little.
            var points: [(t: Double, c: SIMD3<Double>)] = [(0, colors[0] - (colors[1] - colors[0]) * 0.5)]
            for k in 0..<bins { points.append(((Double(k) + 0.5) / Double(bins), colors[k])) }
            points.append((1, colors[bins - 1] + (colors[bins - 1] - colors[bins - 2]) * 0.5))
            var keep = [Bool](repeating: false, count: points.count)
            keep[0] = true
            keep[points.count - 1] = true
            func split(_ a: Int, _ b: Int) {
                guard b > a + 1 else { return }
                var worst = 0.0, at = -1
                for k in (a + 1)..<b {
                    let u = (points[k].t - points[a].t) / (points[b].t - points[a].t)
                    let d = points[k].c - (points[a].c * (1 - u) + points[b].c * u)
                    let far = max(abs(d.x), abs(d.y), abs(d.z))
                    if far > worst { worst = far; at = k }
                }
                guard worst > 2.5, at >= 0 else { return }
                keep[at] = true
                split(a, at)
                split(at, b)
            }
            split(0, points.count - 1)
            return points.indices.filter { keep[$0] }.map { k in
                let c = points[k].c
                return Blend.Stop(offset: points[k].t, color: Tint(r: UInt8(min(max(c.x, 0), 255).rounded()), g: UInt8(min(max(c.y, 0), 255).rounded()),
                                                                  b: UInt8(min(max(c.z, 0), 255).rounded())))
            }
        }

        // Straight across: the way most of the change goes.
        var best: (off: Double, held: Double, blend: Blend)?
        let trace = txx + tyy, det = txx * tyy - txy * txy
        let root = max(trace * trace / 4 - det, 0).squareRoot()
        let big = trace / 2 + root, small = trace / 2 - root
        /// The way a matrix of squares and products stretches most.
        func stretch(_ xx: Double, _ xy: Double, _ yy: Double) -> (x: Double, y: Double) {
            let big = (xx + yy) / 2 + max((xx - yy) * (xx - yy) / 4 + xy * xy, 0).squareRoot()
            var x = xy, y = big - xx
            if abs(x) + abs(y) < 1e-9 { x = big - yy; y = xy }
            if abs(x) + abs(y) < 1e-9 { x = 1; y = 0 }
            let l = (x * x + y * y).squareRoot()
            return (x / l, y / l)
        }
        func straight(_ way: (x: Double, y: Double)) {
            let dx = way.x, dy = way.y
            var lo = Double.infinity, hi = -Double.infinity
            for at in pixels {
                let i = Int(at), t = (Double(i % w) + 0.5) * dx + (Double(i / w) + 0.5) * dy
                lo = min(lo, t)
                hi = max(hi, t)
            }
            guard let found = along(lo - 0.5, hi + 0.5, { $0 * dx + $1 * dy }), best == nil || found.off < best!.off else { return }
            let mid = midX * dx + midY * dy
            best = (found.off, found.held, Blend(kind: .linear, start: Spot(midX + dx * (lo - 0.5 - mid), midY + dy * (lo - 0.5 - mid)),
                                     end: Spot(midX + dx * (hi + 0.5 - mid), midY + dy * (hi + 0.5 - mid)), stops: stops(found.colors)))
        }
        // By how each pixel differs from those beside it, which finds the way however the
        // colours run along it; and by how the colours lie across the whole of it, which
        // finds it where they run so gently that pixel to pixel they change by a step or none.
        straight(stretch(txx, txy, tyy))
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sxc = SIMD3<Double>.zero, syc = SIMD3<Double>.zero, wide = 0.0
        for at in pixels {
            let i = Int(at), x = Double(i % w) + 0.5 - midX, y = Double(i / w) + 0.5 - midY
            let c = color(i) - mean
            sxx += x * x; sxy += x * y; syy += y * y
            sxc += c * x
            wide += (c * c).sum()
            syc += c * y
        }
        let flat = sxx * syy - sxy * sxy
        if flat > 1e-6 {
            let across = (sxc * syy - syc * sxy) / flat, down = (syc * sxx - sxc * sxy) / flat
            straight(stretch((across * across).sum(), (across * down).sum(), (down * down).sum()))
        }
        /// A middle moved to where the colours round it fit best. Where a picture changes from
        /// pixel to pixel by a level or less, which way it changes at a pixel is half chance,
        /// and the place where those ways meet lies too near the middle of the pixels. From
        /// there: the colours along the way out are taken as they are found, and the middle is
        /// moved by what the pixels' differences from them ask for, a few times over.
        func settled(_ x: Double, _ y: Double) -> (Double, Double) {
            var cx = x, cy = y
            let every = max(1, pixels.count / 12000)
            let some = stride(from: 0, to: pixels.count, by: every).map { Int(pixels[$0]) }
            /// How far the pixels are from the colours of their places, and where the middle
            /// would rather be.
            func asked(_ cx: Double, _ cy: Double) -> (off: Double, dx: Double, dy: Double)? {
                var reach = 0.0
                for i in some {
                    let px = Double(i % w) + 0.5 - cx, py = Double(i / w) + 0.5 - cy
                    reach = max(reach, px * px + py * py)
                }
                reach = reach.squareRoot() + 0.5
                guard reach >= 8 else { return nil }
                let bins = min(max(Int(reach / 2), 8), 128)
                var sum = [SIMD3<Double>](repeating: .zero, count: bins), n = [Double](repeating: 0, count: bins)
                for i in some {
                    let px = Double(i % w) + 0.5 - cx, py = Double(i / w) + 0.5 - cy
                    let f = (px * px + py * py).squareRoot() / reach * Double(bins) - 0.5, k = Int(f.rounded(.down)), u = f - Double(k)
                    let c = color(i)
                    if k >= 0, k < bins { sum[k] += c * (1 - u); n[k] += 1 - u }
                    if k + 1 >= 0, k + 1 < bins { sum[k + 1] += c * u; n[k + 1] += u }
                }
                var colors = [SIMD3<Double>](repeating: .zero, count: bins)
                var last = -1
                for k in 0..<bins {
                    if n[k] >= 0.5 { colors[k] = sum[k] / n[k]; last = k } else if last >= 0 { colors[k] = colors[last] }
                }
                guard last >= 0 else { return nil }
                if let first = (0..<bins).first(where: { n[$0] >= 0.5 }), first > 0 {
                    for k in 0..<first { colors[k] = colors[first] }
                }
                var off = 0.0, jxx = 0.0, jxy = 0.0, jyy = 0.0, ex = 0.0, ey = 0.0
                for i in some {
                    let px = Double(i % w) + 0.5 - cx, py = Double(i / w) + 0.5 - cy
                    let r = (px * px + py * py).squareRoot()
                    let f = min(max(r / reach * Double(bins) - 0.5, 0), Double(bins - 1)), k = min(Int(f), bins - 2), u = f - Double(k)
                    let e = color(i) - (colors[k] * (1 - u) + colors[k + 1] * u)
                    off += (e * e).sum()
                    guard r > 1 else { continue }
                    // Moving the middle by one moves this pixel's place by so much the other way.
                    let slope = (colors[k + 1] - colors[k]) * (Double(bins) / reach)
                    let ux = px / r, uy = py / r, s2 = (slope * slope).sum(), se = (slope * e).sum()
                    jxx += s2 * ux * ux; jxy += s2 * ux * uy; jyy += s2 * uy * uy
                    ex += se * ux; ey += se * uy
                }
                let det = jxx * jyy - jxy * jxy
                guard det > 1e-9 * max(jxx * jyy, 1e-9) else { return (off, 0, 0) }
                return (off, -(ex * jyy - ey * jxy) / det, -(jxx * ey - jxy * ex) / det)
            }
            guard var now = asked(cx, cy) else { return (x, y) }
            for _ in 0..<12 {
                var dx = now.dx, dy = now.dy
                let far = (dx * dx + dy * dy).squareRoot()
                guard far >= 0.02 else { break }
                // A step that makes it worse is taken shorter.
                var taken = false
                for _ in 0..<4 {
                    if let next = asked(cx + dx, cy + dy), next.off < now.off {
                        cx += dx
                        cy += dy
                        now = next
                        taken = true
                        break
                    }
                    dx /= 2
                    dy /= 2
                }
                guard taken else { break }
            }
            return (cx, cy)
        }

        // Outward from a middle: where the lines the colours change along all meet. Only
        // where they do not all run one way, which has no such place.
        if small >= 0.03 * big {
            // (Σ|g|² − Σ g gᵀ) c = b
            let axx = tyy, axy = -txy, ayy = txx
            let d = axx * ayy - axy * axy
            if abs(d) > 1e-9 {
                var cx = (bx * ayy - by * axy) / d, cy = (axx * by - axy * bx) / d
                (cx, cy) = settled(cx, cy)
                var reach = 0.0
                for at in pixels {
                    let i = Int(at)
                    reach = max(reach, ((Double(i % w) + 0.5 - cx) * (Double(i % w) + 0.5 - cx) + (Double(i / w) + 0.5 - cy) * (Double(i / w) + 0.5 - cy)).squareRoot())
                }
                reach += 0.5
                if reach < 4 * Double(max(raster.w, raster.h)),
                   let round = along(0, reach, { (($0 - cx) * ($0 - cx) + ($1 - cy) * ($1 - cy)).squareRoot() }) {
                    if best == nil || round.off < best!.off * 0.8 {
                        best = (round.off, round.held, Blend(kind: .radial, start: Spot(cx, cy), end: Spot(cx + reach, cy), stops: stops(round.colors)))
                    }
                }
            }
        }
        // The way must account for nearly all of how the pixels differ: what is left over is
        // then the picture's grain, and not shapes of its own inside the run. And the change
        // must be spread along it: all in one place, it is an edge out of focus between two
        // colours.
        guard let best, best.off <= most, best.off <= 0.2 * (wide / count / 3).squareRoot(), best.held <= 0.5, best.blend.stops.count >= 2 else { return nil }
        // And it must be colours running: one colour all through is no blend.
        let first = best.blend.stops[0].color
        guard best.blend.stops.contains(where: { abs(Int($0.color.r) - Int(first.r)) + abs(Int($0.color.g) - Int(first.g)) + abs(Int($0.color.b) - Int(first.b)) >= 12 }) else { return nil }
        return best.blend
    }
}
