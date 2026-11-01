import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation
import simd

/// Develops pictures as their `Develop` says, on the graphics card, with Core Image. What every
/// pixel becomes by itself (white balance, exposure, the tones, the colours) is worked out once
/// per setting as a colour cube; what depends on the pixels around it (haze, clarity, texture,
/// sharpness) is drawn with kernels of Bezzle's own.
///
/// Safe from any thread, as the canvas's tiles are drawn: what it keeps is behind a lock, and a
/// picture another thread is developing is waited for rather than developed twice. Distances,
/// such as how far clarity reaches, are in parts of the picture's size, so it looks alike at
/// whatever size it is read.
nonisolated enum Developer {
    /// The picture as `develop` makes it; the picture itself when it changes nothing.
    static func developed(_ picture: CGImage, _ develop: Develop?) -> CGImage {
        guard let develop, !develop.isNeutral || develop.isolate != nil else { return picture }
        let key = Key(source: ObjectIdentifier(picture), develop: develop)
        kept.lock.lock()
        while kept.working.contains(key) { kept.lock.wait() }
        if let hit = kept.images[key] {
            kept.tick += 1
            kept.images[key]?.used = kept.tick
            kept.lock.unlock()
            return hit.image
        }
        kept.working.insert(key)
        kept.lock.unlock()

        let image = render(picture, develop) ?? picture

        kept.lock.lock()
        kept.working.remove(key)
        kept.tick += 1
        kept.images[key] = Entry(source: picture, image: image, used: kept.tick, bytes: image.bytesPerRow * image.height)
        kept.trim()
        kept.lock.broadcast()
        kept.lock.unlock()
        return image
    }

    // MARK: Kept

    private struct Key: Hashable {
        let source: ObjectIdentifier
        let develop: Develop
    }

    private struct Entry {
        /// Held, so that no other picture comes to have its identity while this is kept.
        let source: CGImage
        let image: CGImage
        var used: Int
        let bytes: Int
    }

    private final class Kept: @unchecked Sendable {
        let lock = NSCondition()
        var images: [Key: Entry] = [:]
        var working: Set<Key> = []
        var tick = 0
        /// Colour cubes by what they do, for the settings a drag goes through and back.
        var cubes: [Develop: Data] = [:]
        var cubeUse: [Develop: Int] = [:]
        /// The colour of each picture's haze, by the picture.
        var air: [ObjectIdentifier: (CGImage, SIMD3<Double>)] = [:]

        /// What has not been used for longest goes, until a few hundred megabytes are kept.
        func trim() {
            var bytes = images.values.reduce(0) { $0 + $1.bytes }
            while images.count > 24 || bytes > 640 << 20, let oldest = images.min(by: { $0.value.used < $1.value.used }) {
                bytes -= oldest.value.bytes
                images[oldest.key] = nil
            }
        }
    }

    private static let kept = Kept()

    /// Forgets every picture developed, as tests do between themselves.
    static func forget() {
        kept.lock.withLock {
            kept.images = [:]
            kept.cubes = [:]
            kept.cubeUse = [:]
            kept.air = [:]
        }
    }

    // MARK: Drawing

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .name: "Bezzle develop",
    ])

    /// The colour space a picture is developed in: its own when that is Display P3, so its
    /// brightest colours are kept, and sRGB otherwise.
    private static func space(of picture: CGImage) -> CGColorSpace {
        if let name = picture.colorSpace?.name as String?, name.contains("P3") { return CGColorSpace(name: CGColorSpace.displayP3)! }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func render(_ picture: CGImage, _ d: Develop) -> CGImage? {
        let space = space(of: picture)
        var image = CIImage(cgImage: picture)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let long = Double(max(extent.width, extent.height))

        if d[.dehaze] != 0, let kernel = kernels.dehaze {
            image = dehazed(image, by: d[.dehaze] / 100, air: air(of: picture), long: long, kernel: kernel)
        }
        let point = d.pointOnly
        if !point.isNeutral || point.isolate != nil {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(cubeSize)
            filter.cubeData = cube(point)
            filter.colorSpace = space
            if let out = filter.outputImage { image = out }
        }
        let clarity = d[.clarity] / 100, texture = d[.texture] / 100, sharpness = d[.sharpness] / 100
        if clarity != 0 || texture != 0 || sharpness != 0, let kernel = kernels.detail {
            let edge = image.clampedToExtent()
            func blurred(_ part: Double, least: Double) -> CIImage {
                edge.applyingGaussianBlur(sigma: max(long * part, least))
            }
            let wide = clarity != 0 ? blurred(0.014, least: 2) : image
            let mid = texture != 0 ? blurred(0.0045, least: 1.5) : image
            let fine = texture != 0 ? blurred(0.0011, least: 0.6) : image
            let tiny = sharpness != 0 ? blurred(0.00045, least: 0.7) : image
            if let out = kernel.apply(extent: extent, arguments: [image, wide, mid, fine, tiny,
                                                                   clarity * (clarity > 0 ? 0.9 : 0.75), texture * 0.85, sharpness * 1.6]) {
                image = out
            }
        }
        return context.createCGImage(image.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
    }

    /// The picture with its haze taken away, or more laid over it, after the dark channel prior:
    /// outdoors, nearly every small patch of a clear photo has something nearly black in some
    /// colour, so how far a patch's darkest colour is from black says how much haze lies over it.
    private static func dehazed(_ image: CIImage, by amount: Double, air: SIMD3<Double>, long: Double, kernel: CIColorKernel) -> CIImage {
        let extent = image.extent
        // Worked out on a quarter of the picture, then laid back over it, softly.
        let quarter = CGAffineTransform(scaleX: 0.25, y: 0.25)
        let small = image.clampedToExtent().transformed(by: quarter).cropped(to: extent.applying(quarter))
        let reach = max(1, (long * 0.25 * 0.01).rounded())
        let dark = small.applyingFilter("CIMinimumComponent", parameters: [:])
            .clampedToExtent()
            .applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": reach * 2 + 1, "inputHeight": reach * 2 + 1])
            .applyingGaussianBlur(sigma: reach * 1.6)
            .transformed(by: quarter.inverted())
        return kernel.apply(extent: extent, arguments: [image, dark, CIVector(x: air.x, y: air.y, z: air.z), amount]) ?? image
    }

    /// The colour of a picture's haze: that of its haziest part, where even its darkest colour is
    /// lightest, as a sky usually is.
    private static func air(of picture: CGImage) -> SIMD3<Double> {
        let id = ObjectIdentifier(picture)
        if let known = kept.lock.withLock({ kept.air[id]?.1 }) { return known }
        var air = SIMD3<Double>(repeating: 0.9)
        if let px = Pixels(picture, longest: 96) {
            var darks: [(Double, SIMD3<Double>)] = []
            darks.reserveCapacity(px.width * px.height)
            for i in 0..<(px.width * px.height) {
                guard let c = px.color(at: i), c.w > 0.5 else { continue }
                darks.append((min(c.x, c.y, c.z), SIMD3(c.x, c.y, c.z)))
            }
            darks.sort { $0.0 > $1.0 }
            let top = darks.prefix(max(1, darks.count / 100))
            if !top.isEmpty {
                air = top.reduce(SIMD3<Double>()) { $0 + $1.1 } / Double(top.count)
                air = simd_clamp(air, SIMD3(repeating: 0.45), SIMD3(repeating: 1))
            }
        }
        kept.lock.withLock {
            if kept.air.count > 64 { kept.air = [:] }
            kept.air[id] = (picture, air)
        }
        return air
    }

    // MARK: The colour cube

    /// How many steps the cube has along each of red, green and blue. Fewer while Bezzle is being
    /// worked on: unoptimised, working out each step is many times slower, and a drag would stutter.
    #if DEBUG
    static let cubeSize = 24
    #else
    static let cubeSize = 40
    #endif

    /// Makes the kernels and readies Core Image ahead of the first picture, which would otherwise
    /// wait a moment for them: done away from the main thread when the Photo card first shows.
    static func warmUp() {
        guard !warm.swap() else { return }
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let picture = ctx?.makeImage() else { return }
        var d = Develop()
        for s in Develop.Setting.allCases { d[s] = s.range.upperBound / 10 }
        _ = render(picture, d)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// Whether it was done already; it is from now on.
        func swap() -> Bool { lock.withLock { defer { done = true }; return done } }
    }
    private static let warm = Once()

    /// The colour cube for what each pixel becomes by itself: red changing fastest, then green,
    /// then blue, each entry a colour and an alpha of one, as Core Image takes it.
    static func cube(_ d: Develop) -> Data {
        if let known = kept.lock.withLock({ () -> Data? in
            kept.tick += 1
            if kept.cubes[d] != nil { kept.cubeUse[d] = kept.tick }
            return kept.cubes[d]
        }) { return known }
        let n = cubeSize
        let map = PointMap(d)
        var values = [Float](repeating: 1, count: n * n * n * 4)
        // The brightest any colour comes out, for the shoulder that brings it back.
        let brightest = Brightest()
        values.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendable(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: n) { b in
                var top = 0.0
                for g in 0..<n {
                    for r in 0..<n {
                        let c = map.apply(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                        top = max(top, c.max())
                        let i = ((b * n + g) * n + r) * 4
                        out.pointer[i] = Float(c.x)
                        out.pointer[i + 1] = Float(c.y)
                        out.pointer[i + 2] = Float(c.z)
                    }
                }
                brightest.note(top)
            }
            let shoulder = PointMap.Shoulder(top: PointMap.encode(brightest.value), knee: 0.86)
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for i in stride(from: b * n * n * 4, to: (b + 1) * n * n * 4, by: 4) {
                    let lin = SIMD3(Double(out.pointer[i]), Double(out.pointer[i + 1]), Double(out.pointer[i + 2]))
                    let c = map.finish(lin, shoulder: shoulder)
                    out.pointer[i] = Float(c.x)
                    out.pointer[i + 1] = Float(c.y)
                    out.pointer[i + 2] = Float(c.z)
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        kept.lock.withLock {
            kept.tick += 1
            kept.cubes[d] = data
            kept.cubeUse[d] = kept.tick
            while kept.cubes.count > 12, let oldest = kept.cubeUse.min(by: { $0.value < $1.value })?.key {
                kept.cubes[oldest] = nil
                kept.cubeUse[oldest] = nil
            }
        }
        return data
    }

    private struct UnsafeSendable<T>: @unchecked Sendable { let pointer: UnsafeMutablePointer<T>; init(_ p: UnsafeMutablePointer<T>) { pointer = p } }

    private final class Brightest: @unchecked Sendable {
        private let lock = NSLock()
        private var top = 0.0
        func note(_ v: Double) { lock.withLock { top = max(top, v) } }
        var value: Double { lock.withLock { top } }
    }

    // MARK: Kernels

    private struct Kernels: @unchecked Sendable {
        var detail: CIColorKernel?
        var dehaze: CIColorKernel?
    }

    /// Compiled once, the first time a picture needs them.
    private static let kernels: Kernels = {
        var k = Kernels()
        do {
            for kernel in try CIKernel.kernels(withMetalString: metal) {
                guard let color = kernel as? CIColorKernel else { continue }
                switch kernel.name {
                case "bezzleDetail": k.detail = color
                case "bezzleDehaze": k.dehaze = color
                default: break
                }
            }
        } catch {
            NSLog("Bezzle could not make its develop kernels: \(error)")
        }
        return k
    }()

    /// Each takes linear, premultiplied colour, as Core Image works, and works on its own colour
    /// as the eye sees it: unpremultiplied and through the sRGB curve.
    private static let metal = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    static inline float3 bzEncode(float3 c) {
        float3 a = abs(c);
        float3 lo = a * 12.92;
        float3 hi = 1.055 * pow(a, float3(1.0 / 2.4)) - 0.055;
        return sign(c) * select(hi, lo, a <= 0.0031308);
    }

    static inline float3 bzDecode(float3 c) {
        float3 a = abs(c);
        float3 lo = a / 12.92;
        float3 hi = pow((a + 0.055) / 1.055, float3(2.4));
        return sign(c) * select(hi, lo, a <= 0.04045);
    }

    static inline float3 bzSeen(float4 p) {
        return bzEncode(p.a > 0.0001 ? p.rgb / p.a : float3(0.0));
    }

    static inline float bzLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    // Clarity: the difference from a wide blur, mostly in the middle tones. Texture: the band
    // between a fine and a middling blur, the size of skin, bark and fabric. Sharpness: the
    // difference from the finest blur, in lightness only, so edges gain no coloured fringes.
    [[ stitchable ]] float4 bezzleDetail(coreimage::sample_t e, coreimage::sample_t wide, coreimage::sample_t mid,
                                         coreimage::sample_t fine, coreimage::sample_t tiny,
                                         float clarity, float texture, float sharpness) {
        if (e.a <= 0.0001) { return e; }
        float3 c = bzSeen(e);
        float3 o = c;
        if (clarity != 0.0) {
            float3 w = bzSeen(wide);
            float l = clamp(bzLuma(w), 0.0, 1.0);
            float m = 1.0 - pow(abs(2.0 * l - 1.0), 2.2);
            c += clarity * m * (o - w);
        }
        if (texture != 0.0) {
            // Not where it would push deep shadows to black or bright skies to white.
            float m = 1.0 - pow(abs(2.0 * clamp(bzLuma(o), 0.0, 1.0) - 1.0), 3.0);
            c += texture * m * (bzSeen(fine) - bzSeen(mid));
        }
        if (sharpness != 0.0) {
            float d = bzLuma(o) - bzLuma(bzSeen(tiny));
            c += sharpness * clamp(d, -0.25, 0.25);
        }
        return float4(bzDecode(c) * e.a, e.a);
    }

    // Haze: taken away where the darkest colour round about is far from black, back towards the
    // colours under it; or more laid over, most where there is most already, as in the distance.
    [[ stitchable ]] float4 bezzleDehaze(coreimage::sample_t e, coreimage::sample_t dark, float3 air, float amount) {
        if (e.a <= 0.0001) { return e; }
        float3 c = bzSeen(e);
        float a = max((air.r + air.g + air.b) / 3.0, 0.2);
        float d = clamp(bzEncode(float3(dark.a > 0.0001 ? dark.r / dark.a : 0.0)).r / a, 0.0, 1.0);
        if (amount > 0.0) {
            float t = max(1.0 - amount * 0.92 * d, 0.22);
            c = (c - air) / t + air;
            // What lay under the haze comes out a little darker than it is: lift it back part way.
            c += (1.0 - t) * 0.18 * amount;
        } else {
            c = mix(c, air, -amount * 0.62 * (0.3 + 0.7 * d));
        }
        return float4(bzDecode(c) * e.a, e.a);
    }
    """
}

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
        let p = simd_max(c, SIMD3(repeating: 0))
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
        let lit = simd_max(SIMD3(r, g, b), SIMD3(repeating: 0.05))
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
        let seen = Self.encode(simd_clamp(lin, SIMD3(repeating: 0), SIMD3(repeating: 1)))
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
            lin = simd_max(SIMD3(repeating: y) + (lin - SIMD3(repeating: y)) * max(strength, 0), SIMD3(repeating: 0))
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
        var lin = simd_max(lin, SIMD3(repeating: 0))
        let m = lin.max()
        if shoulder.on, m > 0 {
            let l = Self.encode(m)
            lin *= Self.decode(shoulder(l)) / m
        }
        return simd_clamp(Self.encode(lin), SIMD3(repeating: 0), SIMD3(repeating: 1))
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

// MARK: - Reading pixels

/// A picture read small, its pixels at hand: for looking at what it holds, and what colour it is
/// under the pointer. In sRGB, 8 bits, premultiplied.
nonisolated struct Pixels: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ picture: CGImage, longest: Int) {
        let s = min(1, Double(longest) / Double(max(picture.width, picture.height)))
        width = max(1, Int((Double(picture.width) * s).rounded()))
        height = max(1, Int((Double(picture.height) * s).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    /// The pixel `i` along, top row first: its colour unpremultiplied, 0…1, and its alpha.
    func color(at i: Int) -> SIMD4<Double>? {
        guard i >= 0, i < width * height else { return nil }
        let a = Double(bytes[i * 4 + 3]) / 255
        guard a > 0 else { return SIMD4(0, 0, 0, 0) }
        return SIMD4(Double(bytes[i * 4]) / 255 / a, Double(bytes[i * 4 + 1]) / 255 / a, Double(bytes[i * 4 + 2]) / 255 / a, a)
    }

    /// The colour at a point across and down the picture, 0…1.
    func color(at unit: CGPoint) -> SIMD4<Double>? {
        guard (0...1).contains(unit.x), (0...1).contains(unit.y) else { return nil }
        let x = min(Int(unit.x * CGFloat(width)), width - 1), y = min(Int(unit.y * CGFloat(height)), height - 1)
        return color(at: y * width + x)
    }
}
