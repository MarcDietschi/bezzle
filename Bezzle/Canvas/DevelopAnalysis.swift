import CoreGraphics
import Foundation
import simd

/// What a picture holds, as the Photo card shows it: how much of it lies at each tone, and at each
/// colour, read from the picture developed, small. And what developing would suit it best.
nonisolated struct PictureLook: Sendable, Equatable {
    /// How much of the picture is at each tone, dark to light, the fullest being 1.
    var tones: [Double]
    /// The same for red, green and blue alone.
    var reds: [Double]
    var greens: [Double]
    var blues: [Double]
    /// How much of the picture is of each colour: `hueSteps` hues round the wheel from red, each
    /// `strengthSteps` strengths from grey out to full, the most being 1.
    var colors: [Double]
    /// How much of the picture is lost to black, and to white, 0…1.
    var crushed: Double
    var blown: Double
    /// The picture developed, small, for what colour it is under the pointer.
    var pixels: Pixels

    static let toneSteps = 64
    static let hueSteps = 36
    static let strengthSteps = 4

    static func == (a: PictureLook, b: PictureLook) -> Bool {
        a.tones == b.tones && a.colors == b.colors && a.reds == b.reds && a.crushed == b.crushed && a.blown == b.blown
    }

    /// The look of `picture` as `develop` makes it. Read small: `picture` is best a few hundred pixels.
    init?(_ picture: CGImage, _ develop: Develop?) {
        guard let px = Pixels(Developer.developed(picture, develop), longest: 200) else { return nil }
        let n = Self.toneSteps, hues = Self.hueSteps, rings = Self.strengthSteps
        var tones = [Double](repeating: 0, count: n), reds = tones, greens = tones, blues = tones
        var colors = [Double](repeating: 0, count: hues * rings)
        var crushed = 0.0, blown = 0.0, total = 0.0
        func bin(_ v: Double) -> Int { min(max(Int(v * Double(n - 1) + 0.5), 0), n - 1) }
        for i in 0..<(px.width * px.height) {
            guard let c = px.color(at: i), c.w > 0.25 else { continue }
            let rgb = SIMD3(c.x, c.y, c.z)
            let w = c.w
            total += w
            let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            tones[bin(l)] += w
            reds[bin(c.x)] += w
            greens[bin(c.y)] += w
            blues[bin(c.z)] += w
            if rgb.max() <= 1.5 / 255 { crushed += w }
            if rgb.min() >= 253.5 / 255 { blown += w }
            let (h, s) = PointMap.hueAndSaturation(rgb)
            if s > 0.06 {
                let ring = min(Int(s * Double(rings)), rings - 1)
                colors[(Int(h / 360 * Double(hues) + 0.5) % hues) * rings + ring] += w * (0.4 + s)
            }
        }
        guard total > 0 else { return nil }
        // Pure black and pure white often fill their ends: they are left out of how full the rest is.
        func scaled(_ v: [Double]) -> [Double] {
            let top = v.dropFirst().dropLast().max() ?? 0
            return top > 0 ? v.map { min($0 / top, 1.15) } : v
        }
        self.tones = scaled(tones)
        self.reds = scaled(reds)
        self.greens = scaled(greens)
        self.blues = scaled(blues)
        let most = colors.max() ?? 0
        self.colors = most > 0 ? colors.map { sqrt($0 / most) } : colors
        self.crushed = crushed / total
        self.blown = blown / total
        pixels = px
    }

    /// The colour at a point across and down the picture, 0…1, as developed.
    func color(at unit: CGPoint) -> SIMD3<Double>? {
        guard let c = pixels.color(at: unit), c.w > 0.25 else { return nil }
        return SIMD3(c.x, c.y, c.z)
    }
}

// MARK: - Auto

nonisolated extension Develop {
    /// What would suit `picture` best, as a careful hand would set it: its middle tones brought to
    /// a middle grey, its ends to just short of black and white, light let into deep shadows and
    /// taken out of bright skies, a colour cast mostly taken away and a little more life in its
    /// colours. Read from the picture small; a picture of a few hundred pixels is enough.
    static func auto(for picture: CGImage) -> Develop {
        guard let px = Pixels(picture, longest: 160) else { return Develop() }
        var lights: [Double] = []
        var cast = SIMD3<Double>(), castWeight = 0.0
        var strength = 0.0, darks = 0.0
        lights.reserveCapacity(px.width * px.height)
        for i in 0..<(px.width * px.height) {
            guard let c = px.color(at: i), c.w > 0.5 else { continue }
            let rgb = SIMD3(c.x, c.y, c.z)
            let lin = PointMap.decode(rgb)
            let l = PointMap.encode(PointMap.norm(lin))
            lights.append(l)
            let (_, s) = PointMap.hueAndSaturation(rgb)
            strength += s
            darks += rgb.min()
            // What should be grey: the middle tones that have little colour.
            if l > 0.2, l < 0.88, s < 0.3 {
                let w = 1 - s / 0.3
                cast += lin / max(PointMap.luma(lin), 1e-4) * w
                castWeight += w
            }
        }
        guard lights.count > 16 else { return Develop() }
        lights.sort()
        func at(_ p: Double) -> Double { lights[min(Int(p * Double(lights.count - 1)), lights.count - 1)] }
        let count = Double(lights.count)
        var d = Develop()

        // Exposure: the middle of the picture towards middle grey, part way, as a dark picture
        // may be meant to be dark.
        let middle = max(at(0.5), 0.02)
        let ev = log2(PointMap.decode(0.47) / PointMap.decode(middle)) * 0.55
        d[.exposure] = min(max(ev, -1.2), 1.4)
        let k = exp2(d[.exposure])
        func lit(_ l: Double) -> Double { min(PointMap.encode(PointMap.decode(l) * k), 1.2) }

        // The ends: towards black and white when they fall short of them.
        let top = lit(at(0.995)), bottom = lit(at(0.005))
        if top < 0.94 { d[.whites] = min((0.94 - top) * 260, 45) }
        if bottom > 0.035 { d[.blacks] = -min((bottom - 0.035) * 280, 40) }

        // Bright skies held back, deep shadows opened up.
        let bright = Double(lights.filter { lit($0) > 0.86 }.count) / count
        let dark = Double(lights.filter { lit($0) < 0.16 }.count) / count
        if bright > 0.04 { d[.highlights] = -min(bright * 260, 65) }
        if dark > 0.06 { d[.shadows] = min(dark * 200, 55) }

        // A flat picture gets some contrast.
        let spread = lit(at(0.95)) - lit(at(0.05))
        if spread < 0.62 { d[.contrast] = min((0.62 - spread) * 70, 25) }

        // A colour cast, mostly taken away: found in what should be grey.
        if castWeight > count * 0.04 {
            let c = cast / castWeight
            d[.temperature] = solve(-100...100) { warm in
                let g = PointMap.whiteBalance(warm / 100)
                return log2((c.x * g.x) / (c.z * g.z))
            } * 0.6
            d[.tint] = min(max(log2((c.x + c.z) / 2 / max(c.y, 1e-4)) * -180, -25), 25) * 0.6
            d[.temperature] = min(max(d[.temperature], -35), 35)
        }

        // More life in colours that have little.
        let meanStrength = strength / count
        d[.vibrance] = meanStrength < 0.4 ? min((0.4 - meanStrength) * 70 + 8, 30) : 6

        // Haze: where even the darkest colours are far from black.
        let meanDark = darks / count
        if meanDark > 0.28, meanStrength < 0.35 { d[.dehaze] = min((meanDark - 0.28) * 120, 30) }

        d[.clarity] = 8
        return d
    }

    /// The setting in `range` at which `f` comes to nothing, from a rising `f`; the nearer end if
    /// it never does.
    private static func solve(_ range: ClosedRange<Double>, _ f: (Double) -> Double) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        let rising = f(hi) > f(lo)
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if (f(mid) < 0) == rising { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
