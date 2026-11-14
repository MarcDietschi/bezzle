import Foundation

/// Memory several threads read and write at once, each its own part.
final class Store<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    let count: Int

    init(_ count: Int, _ value: T) {
        self.count = count
        p = .allocate(capacity: max(count, 1))
        p.initialize(repeating: value, count: max(count, 1))
    }

    deinit { p.deallocate() }
}

/// `body` for every part of `0..<n`, the parts side by side on the Mac's cores.
func parallel(_ n: Int, atLeast: Int = 16, _ body: @escaping @Sendable (Range<Int>) -> Void) {
    guard n > 0 else { return }
    let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let parts = min(cores * 2, max(1, n / max(atLeast, 1)))
    if parts <= 1 {
        body(0..<n)
        return
    }
    DispatchQueue.concurrentPerform(iterations: parts) { i in
        let from = n * i / parts, to = n * (i + 1) / parts
        if from < to { body(from..<to) }
    }
}

/// The picture as it is worked on: three bytes of sRGB for each pixel, and how solid each is.
struct Raster: @unchecked Sendable {
    let w: Int
    let h: Int
    let rgb: Store<UInt8>
    let alpha: Store<UInt8>
    /// Whether any of it is see-through.
    let clear: Bool

    /// The bitmap made ready: no larger than `cap` pixels, and its see-through pixels given the
    /// colours of the solid ones beside them, so nothing foreign is mixed in at its edges.
    static func prepare(_ bitmap: Bitmap, cap: Int) -> Raster {
        var w = bitmap.width, h = bitmap.height
        let rgb: Store<UInt8>, alpha: Store<UInt8>
        if w * h > cap {
            let f = (Double(cap) / Double(w * h)).squareRoot()
            let dw = max(1, Int((Double(w) * f).rounded())), dh = max(1, Int((Double(h) * f).rounded()))
            rgb = Store(dw * dh * 3, 0)
            alpha = Store(dw * dh, 0)
            let sw = w, sh = h
            bitmap.pixels.withUnsafeBufferPointer { src in
                let s = src.baseAddress!
                for y in 0..<dh {
                    let y0 = y * sh / dh, y1 = max(y0 + 1, (y + 1) * sh / dh)
                    for x in 0..<dw {
                        let x0 = x * sw / dw, x1 = max(x0 + 1, (x + 1) * sw / dw)
                        var r = 0, g = 0, b = 0, a = 0
                        for yy in y0..<y1 {
                            var q = s + (yy * sw + x0) * 4
                            for _ in x0..<x1 {
                                let qa = Int(q[3])
                                r += Int(q[0]) * qa; g += Int(q[1]) * qa; b += Int(q[2]) * qa; a += qa
                                q += 4
                            }
                        }
                        let n = (y1 - y0) * (x1 - x0), i = y * dw + x
                        if a > 0 {
                            rgb.p[i * 3] = UInt8((r + a / 2) / a)
                            rgb.p[i * 3 + 1] = UInt8((g + a / 2) / a)
                            rgb.p[i * 3 + 2] = UInt8((b + a / 2) / a)
                        }
                        alpha.p[i] = UInt8((a + n / 2) / n)
                    }
                }
            }
            w = dw; h = dh
        } else {
            rgb = Store(w * h * 3, 0)
            alpha = Store(w * h, 0)
            bitmap.pixels.withUnsafeBufferPointer { src in
                let s = src.baseAddress!
                for i in 0..<(w * h) {
                    rgb.p[i * 3] = s[i * 4]; rgb.p[i * 3 + 1] = s[i * 4 + 1]; rgb.p[i * 3 + 2] = s[i * 4 + 2]
                    alpha.p[i] = s[i * 4 + 3]
                }
            }
        }
        var clear = false
        for i in 0..<(w * h) where alpha.p[i] < 128 { clear = true; break }
        if clear { bleed(rgb, alpha, w, h) }
        return Raster(w: w, h: h, rgb: rgb, alpha: alpha, clear: clear)
    }

    /// See-through pixels take the colour of the solid ones next to them, a few pixels out.
    private static func bleed(_ rgb: Store<UInt8>, _ alpha: Store<UInt8>, _ w: Int, _ h: Int) {
        var known = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { known[i] = alpha.p[i] >= 128 }
        for _ in 0..<4 {
            var next = known
            var changed = false
            for y in 0..<h {
                for x in 0..<w where !known[y * w + x] {
                    var r = 0, g = 0, b = 0, n = 0
                    for dy in -1...1 {
                        let yy = y + dy
                        guard yy >= 0, yy < h else { continue }
                        for dx in -1...1 {
                            let xx = x + dx
                            guard xx >= 0, xx < w, known[yy * w + xx] else { continue }
                            let j = (yy * w + xx) * 3
                            r += Int(rgb.p[j]); g += Int(rgb.p[j + 1]); b += Int(rgb.p[j + 2]); n += 1
                        }
                    }
                    guard n > 0 else { continue }
                    let i = (y * w + x) * 3
                    rgb.p[i] = UInt8(r / n); rgb.p[i + 1] = UInt8(g / n); rgb.p[i + 2] = UInt8(b / n)
                    next[y * w + x] = true
                    changed = true
                }
            }
            known = next
            if !changed { break }
        }
    }

    /// How noisy the picture is, as the spread of its noise in levels of 255: from how much each
    /// pixel differs from what its neighbours say it should be, the middle of all of them, so
    /// that edges do not count.
    func noise() -> Double {
        guard w >= 3, h >= 3 else { return 0 }
        var bins = [Int](repeating: 0, count: 2048)
        let p = rgb.p
        @inline(__always) func luma(_ i: Int) -> Int { (Int(p[i * 3]) * 2 + Int(p[i * 3 + 1]) * 5 + Int(p[i * 3 + 2])) }
        let step = max(1, Int((Double(w * h) / 400_000).squareRoot()))
        var count = 0
        var y = 1
        while y < h - 1 {
            var x = 1
            while x < w - 1 {
                let i = y * w + x
                let v = luma(i - w - 1) - 2 * luma(i - w) + luma(i - w + 1)
                    - 2 * luma(i - 1) + 4 * luma(i) - 2 * luma(i + 1)
                    + luma(i + w - 1) - 2 * luma(i + w) + luma(i + w + 1)
                bins[min(abs(v) / 8, 2047)] += 1
                count += 1
                x += step
            }
            y += step
        }
        var seen = 0, middle = 0
        for (i, n) in bins.enumerated() {
            seen += n
            if seen * 2 >= count { middle = i; break }
        }
        // The mask's answer to noise of spread s has spread 6 s; half of them lie under 0.6745 of that.
        return Double(middle) / (6 * 0.6745)
    }

    /// How restless the picture is beside its edges, as the spread of its noise in levels of
    /// 255: measured three to six pixels off its strong edges, where nothing of an edge itself
    /// is left. A drawn picture is calm there, however thin its lines; one kept as a JPEG rings,
    /// also where most of it is flat paper and `noise` finds it calm. Nil when the picture has
    /// too few such places to say.
    func ringing(_ share: Double = 0.5) -> Double? {
        guard w >= 16, h >= 16 else { return nil }
        let p = rgb.p, w = w, h = h
        @inline(__always) func luma(_ i: Int) -> Int { (Int(p[i * 3]) * 2 + Int(p[i * 3 + 1]) * 5 + Int(p[i * 3 + 2])) }
        // How far each pixel is from the nearest strong step, in pixels, up to 7.
        var far = [UInt8](repeating: 7, count: w * h)
        var any = false
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, l = luma(i)
                if x < w - 1, abs(l - luma(i + 1)) >= 8 * 40 { far[i] = 0; far[i + 1] = 0; any = true }
                if y < h - 1, abs(l - luma(i + w)) >= 8 * 40 { far[i] = 0; far[i + w] = 0; any = true }
            }
        }
        guard any else { return nil }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var d = far[i]
                if x > 0 { d = min(d, far[i - 1] &+ 1) }
                if y > 0 {
                    d = min(d, far[i - w] &+ 1)
                    if x > 0 { d = min(d, far[i - w - 1] &+ 1) }
                    if x < w - 1 { d = min(d, far[i - w + 1] &+ 1) }
                }
                far[i] = d
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                var d = far[i]
                if x < w - 1 { d = min(d, far[i + 1] &+ 1) }
                if y < h - 1 {
                    d = min(d, far[i + w] &+ 1)
                    if x < w - 1 { d = min(d, far[i + w + 1] &+ 1) }
                    if x > 0 { d = min(d, far[i + w - 1] &+ 1) }
                }
                far[i] = d
            }
        }
        var bins = [Int](repeating: 0, count: 2048)
        var count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard far[i] >= 3, far[i] <= 6 else { continue }
                let v = luma(i - w - 1) - 2 * luma(i - w) + luma(i - w + 1)
                    - 2 * luma(i - 1) + 4 * luma(i) - 2 * luma(i + 1)
                    + luma(i + w - 1) - 2 * luma(i + w) + luma(i + w + 1)
                bins[min(abs(v) / 8, 2047)] += 1
                count += 1
            }
        }
        guard count >= 400 else { return nil }
        var seen = 0, middle = 0
        for (i, n) in bins.enumerated() {
            seen += n
            if Double(seen) >= share * Double(count) { middle = i; break }
        }
        return Double(middle) / 6
    }

    /// The picture smaller, each pixel the mean of what it covers of the picture's own, a part
    /// of a pixel counted as that part.
    func resized(_ nw: Int, _ nh: Int) -> Raster {
        guard nw > 0, nh > 0, nw < w || nh < h else { return self }
        /// For each new pixel along an axis, the old ones it covers and how much of each.
        func spans(_ old: Int, _ new: Int) -> (first: [Int32], weights: [[Float]]) {
            let r = Double(old) / Double(new)
            var first = [Int32](repeating: 0, count: new), weights = [[Float]](repeating: [], count: new)
            for i in 0..<new {
                let a = Double(i) * r, b = min(Double(i + 1) * r, Double(old))
                let from = Int(a.rounded(.down)), to = min(Int(b.rounded(.up)), old)
                first[i] = Int32(from)
                weights[i] = (from..<max(to, from + 1)).map { Float(max(min(Double($0 + 1), b) - max(Double($0), a), 0)) }
            }
            return (first, weights)
        }
        let (fx, wx) = spans(w, nw), (fy, wy) = spans(h, nh)
        // Across first: colour times how solid, and how solid.
        let mid = Store<Float>(nw * h * 4, 0)
        let src = rgb.p, sa = alpha.p, w = w, h = h
        parallel(h, atLeast: 16) { rows in
            for y in rows {
                for x in 0..<nw {
                    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                    var i = y * w + Int(fx[x])
                    for k in wx[x] {
                        let q = k * Float(sa[i])
                        r += Float(src[i * 3]) * q; g += Float(src[i * 3 + 1]) * q; b += Float(src[i * 3 + 2]) * q; a += q
                        i += 1
                    }
                    let o = (y * nw + x) * 4
                    mid.p[o] = r; mid.p[o + 1] = g; mid.p[o + 2] = b; mid.p[o + 3] = a
                }
            }
        }
        let out = Store<UInt8>(nw * nh * 3, 0), solid = Store<UInt8>(nw * nh, 0)
        let across = Float(Double(w) / Double(nw)), down = Float(Double(h) / Double(nh))
        parallel(nh, atLeast: 16) { rows in
            for y in rows {
                for x in 0..<nw {
                    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                    var row = Int(fy[y])
                    for k in wy[y] {
                        let o = (row * nw + x) * 4
                        r += mid.p[o] * k; g += mid.p[o + 1] * k; b += mid.p[o + 2] * k; a += mid.p[o + 3] * k
                        row += 1
                    }
                    let i = y * nw + x
                    if a > 0 {
                        out.p[i * 3] = UInt8(min(max((r / a).rounded(), 0), 255))
                        out.p[i * 3 + 1] = UInt8(min(max((g / a).rounded(), 0), 255))
                        out.p[i * 3 + 2] = UInt8(min(max((b / a).rounded(), 0), 255))
                    }
                    solid.p[i] = UInt8(min(max((a / (across * down)).rounded(), 0), 255))
                }
            }
        }
        if clear { Raster.bleed(out, solid, nw, nh) }
        return Raster(w: nw, h: nh, rgb: out, alpha: solid, clear: clear)
    }

    /// How soft the picture's edges are: how many pixels its strong edges take to pass from one
    /// colour to the other, the middle of them all. A drawn edge takes little more than one; a
    /// picture scaled up, blurred or kept coarsely takes two or three, and nothing finer than
    /// that is left in it to follow.
    func softness(_ share: Double = 0.5) -> Double {
        guard w >= 8, h >= 8 else { return 1 }
        let p = rgb.p
        @inline(__always) func light(_ i: Int) -> Int { Int(p[i * 3]) * 2 + Int(p[i * 3 + 1]) * 5 + Int(p[i * 3 + 2]) }
        var bins = [Int](repeating: 0, count: 96)
        var count = 0
        /// Along a line of `n` pixels from `first`, `by` apart.
        func along(_ first: Int, _ by: Int, _ n: Int) {
            var k = 1
            while k < n - 1 {
                let d = light(first + k * by) - light(first + (k - 1) * by)
                // The steepest step of an edge: steeper than those beside it.
                guard abs(d) >= 8 * 24 else { k += 1; continue }
                let sign = d > 0 ? 1 : -1
                var steepest = abs(d), total = abs(d)
                var a = k - 1
                while a > 0 {
                    let e = (light(first + a * by) - light(first + (a - 1) * by)) * sign
                    guard e > 8 * 2 else { break }
                    total += e; steepest = max(steepest, e); a -= 1
                }
                var b = k
                while b < n - 1 {
                    let e = (light(first + (b + 1) * by) - light(first + b * by)) * sign
                    guard e > 8 * 2 else { break }
                    total += e; steepest = max(steepest, e); b += 1
                }
                if total >= 8 * 48 {
                    bins[min(Int(Double(total) / Double(steepest) * 16), 95)] += 1
                    count += 1
                }
                k = b + 1
            }
        }
        let stepY = max(1, h / 400), stepX = max(1, w / 400)
        for y in stride(from: 0, to: h, by: stepY) { along(y * w, 1, w) }
        for x in stride(from: 0, to: w, by: stepX) { along(x, w, h) }
        guard count >= 30 else { return 1 }
        var seen = 0
        for (i, n) in bins.enumerated() {
            seen += n
            if Double(seen) >= share * Double(count) { return (Double(i) + 0.5) / 16 }
        }
        return 1
    }

    /// Whether the picture keeps its colour coarser than its light, as a JPEG does: along its
    /// edges the light then steps from one side to the other within a pixel while the colour
    /// takes two or three, so the pixels of an edge are no plain mix of its two sides. Nil when
    /// it has too few edges between colours to say, as a picture of thin lines has.
    func colorCoarse() -> Bool? {
        guard w >= 8, h >= 8 else { return nil }
        let p = rgb.p
        var gaps: [Double] = []
        let step = max(1, h / 300)
        @inline(__always) func color(_ i: Int) -> SIMD3<Double> { SIMD3(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2])) }
        for y in stride(from: 0, to: h, by: step) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = color(i - 1), v = color(i + 1) - l
                let light = Mixing.light(v)
                guard abs(light) >= 48 else { continue }
                let hue = v - SIMD3(repeating: light)
                let hh = (hue * hue).sum()
                guard hh >= 48 * 48 else { continue }
                let u = color(i) - l
                let stepped = Mixing.light(u) / light
                guard stepped > 0.15, stepped < 0.85 else { continue }
                let turned = ((u - SIMD3(repeating: Mixing.light(u))) * hue).sum() / hh
                gaps.append(abs(stepped - turned))
            }
        }
        guard gaps.count >= 40 else { return nil }
        gaps.sort()
        return gaps[gaps.count / 2] >= 0.1
    }

    /// The picture with its noise taken out and its edges left: each pixel the mean of those
    /// round it that are nearly its colour.
    func calmed(noise sigma: Double) -> Raster {
        let out = Store<UInt8>(w * h * 3, 0)
        let reach = 2
        let range = min(max(3 * sigma + 3, 6), 40)
        // By the squared difference of the colours, a quarter as fine.
        let limit = 3 * 255 * 255 / 4 + 1
        var falloff = [Float](repeating: 0, count: limit)
        for i in 0..<limit { falloff[i] = Float(exp(-Double(i * 4) / (2 * range * range * 3))) }
        var near = [Float](repeating: 0, count: (2 * reach + 1) * (2 * reach + 1))
        for dy in -reach...reach {
            for dx in -reach...reach {
                near[(dy + reach) * (2 * reach + 1) + dx + reach] = Float(exp(-Double(dx * dx + dy * dy) / (2 * 1.5 * 1.5)))
            }
        }
        let w = w, h = h, src = rgb
        let fall = falloff, nearby = near
        parallel(h, atLeast: 8) { rows in
            fall.withUnsafeBufferPointer { fall in
                nearby.withUnsafeBufferPointer { nearby in
                    let p = src.p
                    for y in rows {
                        for x in 0..<w {
                            let i = (y * w + x) * 3
                            let r0 = Int(p[i]), g0 = Int(p[i + 1]), b0 = Int(p[i + 2])
                            var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                            for dy in -reach...reach {
                                let yy = y + dy
                                guard yy >= 0, yy < h else { continue }
                                for dx in -reach...reach {
                                    let xx = x + dx
                                    guard xx >= 0, xx < w else { continue }
                                    let j = (yy * w + xx) * 3
                                    let dr = Int(p[j]) - r0, dg = Int(p[j + 1]) - g0, db = Int(p[j + 2]) - b0
                                    let k = nearby[(dy + reach) * (2 * reach + 1) + dx + reach] * fall[(dr * dr + dg * dg + db * db) / 4]
                                    r += k * Float(p[j]); g += k * Float(p[j + 1]); b += k * Float(p[j + 2]); n += k
                                }
                            }
                            out.p[i] = UInt8(min(max(r / n + 0.5, 0), 255))
                            out.p[i + 1] = UInt8(min(max(g / n + 0.5, 0), 255))
                            out.p[i + 2] = UInt8(min(max(b / n + 0.5, 0), 255))
                        }
                    }
                }
            }
        }
        return Raster(w: w, h: h, rgb: out, alpha: alpha, clear: clear)
    }

    /// Whether the picture's edges are hard: hardly a pixel between two colours is a mix of them,
    /// as the soft edges of drawn or scaled pictures are.
    func hardEdged() -> Bool {
        let p = rgb.p
        var edges = 0, mixes = 0
        @inline(__always) func far(_ i: Int, _ j: Int, _ by: Int) -> Bool {
            abs(Int(p[i * 3]) - Int(p[j * 3])) > by || abs(Int(p[i * 3 + 1]) - Int(p[j * 3 + 1])) > by || abs(Int(p[i * 3 + 2]) - Int(p[j * 3 + 2])) > by
        }
        /// Whether pixel `i` lies between `a` and `b` in colour, and is neither.
        @inline(__always) func between(_ i: Int, _ a: Int, _ b: Int) -> Bool {
            guard far(i, a, 8), far(i, b, 8) else { return false }
            var vv = 0, wv = 0, ww = 0
            for c in 0..<3 {
                let v = Int(p[b * 3 + c]) - Int(p[a * 3 + c]), u = Int(p[i * 3 + c]) - Int(p[a * 3 + c])
                vv += v * v; wv += u * v; ww += u * u
            }
            guard vv > 0, wv > 0, wv < vv else { return false }
            // How far off the line from one to the other, squared.
            let off = ww - wv * wv / vv
            return off <= 14 * 14
        }
        for y in 0..<h {
            for x in 1..<max(w - 1, 1) {
                let i = y * w + x
                if far(i - 1, i + 1, 24) {
                    edges += 1
                    if between(i, i - 1, i + 1) { mixes += 1 }
                }
            }
        }
        for y in 1..<max(h - 1, 1) {
            for x in 0..<w {
                let i = y * w + x
                if far(i - w, i + w, 24) {
                    edges += 1
                    if between(i, i - w, i + w) { mixes += 1 }
                }
            }
        }
        return edges > 0 && Double(mixes) < Double(edges) * 0.04
    }

    /// How many pixels each square of pixel art is across, when the picture is made of such
    /// squares: the largest size that every run of one colour, across and down, is a multiple of.
    func blockSize() -> Int {
        let p = rgb.p
        @inline(__always) func same(_ i: Int, _ j: Int) -> Bool {
            p[i * 3] == p[j * 3] && p[i * 3 + 1] == p[j * 3 + 1] && p[i * 3 + 2] == p[j * 3 + 2] && (alpha.p[i] >= 128) == (alpha.p[j] >= 128)
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var size = 0
        for y in 0..<h {
            var run = 1
            for x in 1..<w {
                if same(y * w + x, y * w + x - 1) { run += 1 } else {
                    size = gcd(size, run); run = 1
                    if size == 1 { return 1 }
                }
            }
            size = gcd(size, run)
        }
        for x in 0..<w {
            var run = 1
            for y in 1..<h {
                if same(y * w + x, (y - 1) * w + x) { run += 1 } else {
                    size = gcd(size, run); run = 1
                    if size == 1 { return 1 }
                }
            }
            size = gcd(size, run)
        }
        return max(size, 1)
    }
}

// MARK: - Colour

/// Colours as the eye tells them apart (Oklab): equal steps look equally far.
enum Oklab {
    private static let linear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    static func from(r: Double, g: Double, b: Double) -> SIMD3<Float> {
        // Between the levels of the table, for the means of many pixels.
        func lin(_ v: Double) -> Float {
            let x = min(max(v, 0), 255), i = Int(x), f = Float(x - Double(i))
            return linear[i] + (linear[min(i + 1, 255)] - linear[i]) * f
        }
        let lr = lin(r), lg = lin(g), lb = lin(b)
        let l = cbrtf(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrtf(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrtf(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum().squareRoot()
    }
}

/// How a colour lies between two others: a mix of them, as the pixels of a soft edge are.
struct Mixing: Sendable {
    /// The picture keeps its colour coarser than its light (`Raster.colorCoarse`): a pixel of an
    /// edge may then have the light of one mix and the colour of another, and how much of each
    /// side it holds is told by its light, which is exact.
    let coarse: Bool

    @inline(__always) static func light(_ v: SIMD3<Double>) -> Double { 0.299 * v.x + 0.587 * v.y + 0.114 * v.z }

    /// Where `c` lies on the way from `a` to `b`: by its light and by its colour, each 0 at `a`
    /// and 1 at `b` (the same unless coarse), and how far it is from any mix of the two, squared.
    @inline(__always) func callAsFunction(_ c: SIMD3<Int32>, from a: SIMD3<Int32>, to b: SIMD3<Int32>) -> (light: Double, hue: Double, off: Double) {
        let vi = b &- a, ui = c &- a
        let v = SIMD3<Double>(Double(vi.x), Double(vi.y), Double(vi.z)), u = SIMD3<Double>(Double(ui.x), Double(ui.y), Double(ui.z))
        let vv = (v * v).sum(), uv = (u * v).sum(), uu = (u * u).sum()
        guard vv > 0 else { return (0, 0, uu) }
        if coarse {
            let step = Mixing.light(v)
            let l = SIMD3<Double>(repeating: step), k = v - l
            let ll = (l * l).sum(), kk = (k * k).sum(), lk = (l * k).sum()
            let det = ll * kk - lk * lk
            if abs(step) >= 24, kk >= 24 * 24, det > 1e-6 * ll * kk {
                let ul = (u * l).sum(), uk = (u * k).sum()
                let t = (ul * kk - uk * lk) / det, s = (uk * ll - ul * lk) / det
                let rest = u - l * t - k * s
                // The colour may lag the light, never run away from both sides.
                let stray = max(0, -0.25 - s, s - 1.25)
                return (t, s, (rest * rest).sum() + stray * stray * kk)
            }
        }
        let t = uv / vv
        return (t, t, max(uu - uv * uv / vv, 0))
    }

    /// Whether what `callAsFunction` found is a mix of the two and neither of them.
    @inline(__always) static func isBetween(_ m: (light: Double, hue: Double, off: Double), within gap: Double) -> Bool {
        guard m.off <= gap * gap, m.light > -0.1, m.light < 1.1 else { return false }
        return (m.light > 0 && m.light < 1) || (m.hue > 0 && m.hue < 1)
    }
}
