import Foundation

// What a picture's light and colour settings do to each colour (see `Develop`), for every Bezzle:
// the Mac bakes it into a colour cube for Core Image (Canvas/Developer.swift), the web core and
// Windows into one their hosts lay over the picture's pixels.

// MARK: - What each pixel becomes

/// What a picture's light and colour settings do to one colour, worked out ahead for every pixel
/// at once. Colours come in through the sRGB curve, 0…1, are worked on in light, and leave
/// through the curve again.
nonisolated struct PointMap {
    /// Gains on red, green and blue that warm or cool the light, and tint it.
    let gains: SIMD3<Double>
    /// How much more light, from the exposure, in light itself.
    let exposure: Double
    /// Brings what exposure takes past white back under it, softly.
    let lift: Shoulder
    let contrast: Double
    /// The tones moved by blacks, shadows, highlights and whites; none while they are all nothing.
    let tones: ToneCurve?
    let vibrance, saturation: Double
    let hue, sat, lum: [Double]
    let colorsChanged: Bool
    let isolate: Develop.Isolation?

    init(_ d: Develop) {
        let warm = d[.temperature] / 100, pink = d[.tint] / 100
        var g = PointMap.whiteBalance(warm)
        g.y *= exp2(-0.42 * pink)
        g /= PointMap.luma(g)
        gains = g
        exposure = exp2(d[.exposure])
        lift = Shoulder(top: PointMap.encode(PointMap.norm(g * exposure)), knee: 0.8)
        contrast = d[.contrast] / 100
        tones = ToneCurve(blacks: d[.blacks] / 100, shadows: d[.shadows] / 100, highlights: d[.highlights] / 100, whites: d[.whites] / 100)
        vibrance = d[.vibrance] / 100
        saturation = d[.saturation] / 100
        hue = Develop.Band.allCases.map { d[$0].hue / 100 }
        sat = Develop.Band.allCases.map { d[$0].saturation / 100 }
        lum = Develop.Band.allCases.map { d[$0].luminance / 100 }
        colorsChanged = !d.bands.isEmpty
        isolate = d.isolate
    }

    /// The tones as blacks, shadows, highlights and whites move them: a smooth curve through
    /// points across the tones, each setting lifting or lowering those of its own, that never
    /// turns back on itself however they are set together, as Fritsch and Carlson's curves do not.
    struct ToneCurve {
        private static let xs: [Double] = [0, 0.05, 0.12, 0.27, 0.5, 0.73, 0.88, 0.95, 1]
        /// How far each setting, all the way, moves each point.
        private static let moves: [[Double]] = [
            [0.04, 0.06, 0.07, 0.03, 0.005, 0, 0, 0, 0],
            [0, 0.03, 0.08, 0.13, 0.05, 0.01, 0, 0, 0],
            [0, 0, 0, 0.01, 0.05, 0.12, 0.07, 0.03, 0],
            [0, 0, 0, 0.005, 0.025, 0.07, 0.1, 0.07, 0.04],
        ]
        private let ys: [Double]
        private let ms: [Double]

        init?(blacks: Double, shadows: Double, highlights: Double, whites: Double) {
            let amounts = [blacks, shadows, highlights, whites]
            guard amounts.contains(where: { $0 != 0 }) else { return nil }
            let xs = Self.xs, n = xs.count
            var ys = xs
            for (a, move) in zip(amounts, Self.moves) { for i in 0..<n { ys[i] += a * move[i] } }
            // Always rising, a little at least, then held between black and white.
            for i in 1..<n { ys[i] = max(ys[i], ys[i - 1] + (xs[i] - xs[i - 1]) * 0.12) }
            ys = ys.map { min(max($0, 0), 1) }
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
            var m = [Double](repeating: 0, count: n)
            m[0] = d[0]
            m[n - 1] = d[n - 2]
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
            for i in 0..<(n - 1) {
                if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
                let a = m[i] / d[i], b = m[i + 1] / d[i]
                let h = a * a + b * b
                if h > 9 {
                    let t = 3 / sqrt(h)
                    m[i] = t * a * d[i]
                    m[i + 1] = t * b * d[i]
                }
            }
            self.ys = ys
            ms = m
        }

        func callAsFunction(_ l: Double) -> Double {
            let xs = Self.xs
            let x = min(max(l, 0), 1)
            var i = 0
            while i < xs.count - 2, x > xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
        }
    }

    /// A curve that leaves what is under its knee be and brings everything from there to `top`
    /// down under one, smoothly; nothing at all once nothing reaches past one.
    struct Shoulder {
        let knee: Double
        let a: Double
        let on: Bool

        init(top: Double, knee: Double) {
            self.knee = knee
            on = top > 1.0005
            a = on ? ((top - knee) / (1 - knee) - 1) / (top - knee) : 0
        }

        func callAsFunction(_ x: Double) -> Double {
            guard on, x > knee else { return x }
            return knee + (x - knee) / (1 + a * (x - knee))
        }
    }

    // MARK: Light

    /// The sRGB curve, from light to how bright it looks, carried on past one and below zero.
    static func encode(_ x: Double) -> Double {
        let a = abs(x)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -v : v
    }

    static func decode(_ x: Double) -> Double {
        let a = abs(x)
        let v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -v : v
    }

    static func encode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(encode(c.x), encode(c.y), encode(c.z)) }
    static func decode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(decode(c.x), decode(c.y), decode(c.z)) }

    static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// How bright a colour is for its tones: between its lightness and its strongest part, so a
    /// deep blue counts as darker than white but brighter than its lightness alone says.
    static func norm(_ c: SIMD3<Double>) -> Double {
        let p = pointwiseMax(c, SIMD3(repeating: 0))
        let sq = (p * p).sum()
        return sq > 1e-12 ? (p * p * p).sum() / sq : 0
    }

    /// Gains that warm (above 0) or cool the light: as if the picture had been lit by daylight of
    /// another colour, from about 4000 K to 17,000 K, set back to white.
    static func whiteBalance(_ warm: Double) -> SIMD3<Double> {
        guard warm != 0 else { return SIMD3(repeating: 1) }
        let mired = 1e6 / 6504 - warm * 95
        let t = 1e6 / mired
        // The daylight locus, and from there to sRGB's red, green and blue.
        let x = t <= 7000
            ? -4.6070e9 / pow(t, 3) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
            : -2.0064e9 / pow(t, 3) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        let y = -3 * x * x + 2.870 * x - 0.275
        let X = x / y, Z = (1 - x - y) / y
        let r = 3.2406 * X - 1.5372 - 0.4986 * Z
        let g = -0.9689 * X + 1.8758 + 0.0415 * Z
        let b = 0.0557 * X - 0.2040 + 1.0570 * Z
        let lit = pointwiseMax(SIMD3(r, g, b), SIMD3(repeating: 0.05))
        // D65 itself comes out a touch off white this way; that is taken out too.
        let d65 = SIMD3(0.9505 * 3.2406 - 1.5372 - 0.4986 * 1.089, -0.9689 * 0.9505 + 1.8758 + 0.0415 * 1.089, 0.0557 * 0.9505 - 0.2040 + 1.0570 * 1.089)
        return d65 / lit
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func bump(_ x: Double, _ center: Double, _ radius: Double) -> Double {
        let d = abs(x - center)
        return d >= radius ? 0 : 0.5 * (1 + cos(.pi * d / radius))
    }

    /// How much of each tone a setting works on, by how bright it looks, 0…1.
    static func mask(_ setting: Develop.Setting, _ l: Double) -> Double {
        switch setting {
        case .blacks: 1 - smoothstep(0, 0.32, l)
        case .shadows: bump(l, 0.27, 0.27)
        case .highlights: bump(l, 0.73, 0.27)
        case .whites: smoothstep(0.62, 1, l)
        default: 1
        }
    }

    /// The tone curve: contrast turning about middle grey, from how bright a tone looks to how bright it comes out.
    private func contrasted(_ l: Double) -> Double {
        guard contrast != 0 else { return l }
        let p = 0.46
        func s(_ l: Double, _ g: Double) -> Double {
            l <= p ? p * pow(max(l, 0) / p, g) : 1 - (1 - p) * pow(max(1 - l, 0) / (1 - p), g)
        }
        return contrast > 0 ? l + contrast * 0.85 * (s(l, 2.4) - l) : l - contrast * 0.6 * (s(l, 0.55) - l)
    }

    // MARK: Each pixel

    /// A colour as it comes out, in light, before what reaches past white is brought back.
    func apply(_ c: SIMD3<Double>) -> SIMD3<Double> {
        var lin = Self.decode(c) * gains * exposure
        let n = Self.norm(lin)
        var tone = 0.0
        if n > 1e-7 {
            var l = contrasted(lift(Self.encode(n)))
            tone = l
            if let tones { l = tones(l) }
            lin *= Self.decode(l) / n
        }
        if colorsChanged || vibrance != 0 || saturation != 0 || isolate != nil {
            lin = colored(lin, tone: tone)
        }
        return lin
    }

    /// The colours: each band's hue, strength and lightness, then vibrance and saturation.
    private func colored(_ lin: SIMD3<Double>, tone: Double) -> SIMD3<Double> {
        var lin = lin
        let seen = Self.encode((lin).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)))
        let (h, s) = Self.hueAndSaturation(seen)
        // Greys have no colour to change.
        let colored = Self.smoothstep(0.03, 0.2, s)
        var strength = 1 + saturation
        if colorsChanged, colored > 0 {
            let (i, share) = Develop.Band.split(hue: h)
            let j = (i + 1) % hue.count
            let dh = (hue[i] * share + hue[j] * (1 - share)) * colored
            let ds = (sat[i] * share + sat[j] * (1 - share)) * colored
            let dl = (lum[i] * share + lum[j] * (1 - share)) * colored
            if dh != 0 { lin = Self.decode(Self.turned(Self.encode(lin), by: dh * 30)) }
            strength *= 1 + ds
            if dl != 0 { lin *= exp2(dl * 1.4) }
        }
        if vibrance > 0 {
            // Most for what has least colour, and less for skin.
            let skin = 1 - 0.55 * Self.bump(h, 30, 28)
            strength *= 1 + vibrance * 1.15 * (1 - s) * (1 - s) * skin
        } else if vibrance < 0 {
            strength *= 1 + vibrance * (1 - 0.6 * s)
        }
        if strength != 1 {
            let y = Self.luma(lin)
            lin = pointwiseMax(SIMD3(repeating: y) + (lin - SIMD3(repeating: y)) * max(strength, 0), SIMD3(repeating: 0))
        }
        switch isolate {
        case .band(let band)?:
            let w = band.weight(hue: h) * Self.smoothstep(0.05, 0.22, s)
            let y = Self.luma(lin)
            lin = SIMD3(repeating: y) + (lin - SIMD3(repeating: y)) * w
        case .tone(let setting)?:
            let w = Self.smoothstep(0.15, 0.55, Self.mask(setting, tone))
            // The rest of the picture stays readable, in grey and dimmed.
            let rest = SIMD3<Double>(repeating: Self.decode(0.06 + 0.5 * Self.encode(Self.luma(lin))))
            lin = rest + (lin - rest) * w
        case nil:
            break
        }
        return lin
    }

    /// The end of every colour: brought back under white along `shoulder`, keeping its hue, and
    /// through the sRGB curve.
    func finish(_ lin: SIMD3<Double>, shoulder: Shoulder) -> SIMD3<Double> {
        var lin = pointwiseMax(lin, SIMD3(repeating: 0))
        let m = lin.max()
        if shoulder.on, m > 0 {
            let l = Self.encode(m)
            lin *= Self.decode(shoulder(l)) / m
        }
        return (Self.encode(lin)).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    }

    /// A colour's hue on the wheel in degrees from red, and how strong it is, 0…1, as HSV has them.
    static func hueAndSaturation(_ c: SIMD3<Double>) -> (Double, Double) {
        let mx = c.max(), mn = c.min(), d = mx - mn
        guard d > 1e-9 else { return (0, 0) }
        var h: Double
        if mx == c.x { h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0) } else if mx == c.y { h = (c.z - c.x) / d + 2 } else { h = (c.x - c.y) / d + 4 }
        h *= 60
        return (h, mx > 0 ? d / mx : 0)
    }

    /// A colour as it looks, its hue turned `degrees` round the wheel towards yellow, keeping how
    /// light it is: turned across its colour, as YIQ has it.
    static func turned(_ c: SIMD3<Double>, by degrees: Double) -> SIMD3<Double> {
        let y = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        let i = 0.596 * c.x - 0.274 * c.y - 0.322 * c.z
        let q = 0.211 * c.x - 0.523 * c.y + 0.312 * c.z
        // Red to yellow runs clockwise in YIQ.
        let a = -degrees * .pi / 180
        let i2 = i * cos(a) - q * sin(a), q2 = i * sin(a) + q * cos(a)
        return SIMD3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2)
    }
}
