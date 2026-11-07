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

// MARK: - Reading pixels

/// Reading a picture small with Core Graphics, as the Mac does (`Pixels` itself is shared, in
/// Model/PictureLook.swift).
nonisolated extension Pixels {
    init?(_ picture: CGImage, longest: Int) {
        let s = min(1, Double(longest) / Double(max(picture.width, picture.height)))
        let w = max(1, Int((Double(picture.width) * s).rounded())), h = max(1, Int((Double(picture.height) * s).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, bytes: bytes)
    }
}
