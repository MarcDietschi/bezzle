import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The photo the tour brings with it, for lessons that need one to try things on: a lake under
/// mountains at sundown, pines on the near shore. It is painted afresh each time a tour is made,
/// not kept in the app, and painted as a camera would leave it before anyone develops it: a
/// little flat, a little cool, the shadows grey, so there is something to bring out.
nonisolated enum WelcomePhoto {
    static let size = CGSize(width: 1500, height: 1000)

    /// The photo as a JPEG, as it is put in a design's images.
    static func jpeg() -> Data? {
        guard let image = paint() else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// Paints the photo. The same every time: its randomness is seeded.
    static func paint() -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Painted top down, as the picture is seen.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        var random = Seeded(7)
        let W = CGFloat(w), H = CGFloat(h)
        let horizon = H * 0.6

        // The sky, deep at the top and warm toward the sun going down.
        linear(ctx, [(0, "4C6E98"), (0.45, "9AA9C0"), (0.8, "E9B98E"), (1, "F4CDA0")], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: horizon))
        let sun = CGPoint(x: W * 0.64, y: H * 0.3)
        radial(ctx, at: sun, [(0, "FFFBEF", 1), (0.035, "FFF1D2", 1), (0.05, "FFDFA8", 0.8), (0.22, "F8B878", 0.4), (1, "F2A86B", 0)], radius: W * 0.6)

        // Clouds, lit from below where the sun is.
        if let clouds = noise(&random, width: w, height: Int(horizon), octaves: [(5, 18, 1), (10, 40, 0.5), (24, 90, 0.25), (60, 200, 0.12)]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: horizon), mask: clouds)
            linear(ctx, [(0, "B8C2D4", 0.0), (0.3, "D9D2D6", 0.55), (0.7, "FAD2A6", 0.7), (1, "FBDDB6", 0.2)], from: .zero, to: CGPoint(x: 0, y: horizon))
            ctx.restoreGState()
        }
        radial(ctx, at: sun, [(0, "FFFDF4", 1), (0.03, "FFF6DE", 0.95), (0.045, "FFE2AE", 0.5), (0.18, "F9C182", 0.18), (0.6, "F2A86B", 0)], radius: W * 0.5)

        // Mountains, the far ones pale with haze, the near ones dark and green.
        let ridges: [(top: CGFloat, rough: CGFloat, colour: String, haze: String)] = [
            (0.34, 0.16, "8E9AB4", "B7B9C8"),
            (0.42, 0.12, "65748F", "8C93A8"),
            (0.5, 0.09, "3E5260", "5E6E7C"),
            (0.55, 0.05, "28383A", "39494A"),
        ]
        var outlines: [CGPath] = []
        for r in ridges {
            let line = ridge(&random, width: W, base: H * r.top, rough: H * r.rough)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: horizon))
            for q in line { p.addLine(to: q) }
            p.addLine(to: CGPoint(x: W, y: horizon))
            p.closeSubpath()
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            linear(ctx, [(0, r.haze), (1, r.colour)], from: CGPoint(x: 0, y: H * (r.top - r.rough)), to: CGPoint(x: 0, y: horizon))
            ctx.restoreGState()
            outlines.append(p)
        }
        // Haze lying on the water's far edge.
        linear(ctx, [(0, "F0C9A0", 0), (0.7, "E8C3A0", 0.35), (1, "E2C2A8", 0.55)], from: CGPoint(x: 0, y: horizon - H * 0.08), to: CGPoint(x: 0, y: horizon))

        // The lake: the sky and mountains turned over, darker and stirred.
        if let above = ctx.makeImage(), let still = above.cropping(to: CGRect(x: 0, y: 0, width: w, height: Int(horizon))) {
            let lake = CGRect(x: 0, y: horizon, width: W, height: H - horizon)
            ctx.saveGState()
            ctx.clip(to: lake)
            // Drawn into the flipped context, an image comes out upside down: as a reflection is.
            ctx.draw(still, in: CGRect(x: 0, y: horizon, width: W, height: horizon * 0.9))
            ctx.restoreGState()
            linear(ctx, [(0, "1E2C38", 0.25), (1, "0F1820", 0.75)], from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: H))
            // Ripples catching the sun.
            for _ in 0..<110 {
                let y = horizon + pow(random.next(), 1.6) * (H - horizon)
                let near = (y - horizon) / (H - horizon)
                let x = sun.x + (random.next() - 0.5) * W * (0.08 + near * 0.5)
                let length = W * (0.006 + random.next() * 0.03) * (0.6 + near)
                ctx.setFillColor(colour("FFE2B8", alpha: 0.08 + 0.3 * (1 - near) * random.next()))
                ctx.fill(CGRect(x: x - length / 2, y: y, width: length, height: 1 + near * 3))
            }
        }

        // The near shore and its pines, dark against the water.
        ctx.setFillColor(colour("1D2A1E"))
        let shore = CGMutablePath()
        shore.move(to: CGPoint(x: 0, y: H * 0.8))
        shore.addCurve(to: CGPoint(x: W * 0.36, y: H * 0.9), control1: CGPoint(x: W * 0.12, y: H * 0.78), control2: CGPoint(x: W * 0.24, y: H * 0.86))
        shore.addCurve(to: CGPoint(x: W * 0.62, y: H), control1: CGPoint(x: W * 0.46, y: H * 0.93), control2: CGPoint(x: W * 0.55, y: H * 0.97))
        shore.addLine(to: CGPoint(x: 0, y: H))
        shore.closeSubpath()
        ctx.addPath(shore)
        ctx.fillPath()
        for i in 0..<9 {
            let x = W * (0.015 + CGFloat(i) * 0.034 + (random.next() - 0.5) * 0.02)
            let foot = H * (0.82 + CGFloat(i) * 0.008)
            pine(ctx, at: CGPoint(x: x, y: foot), height: H * (0.32 - CGFloat(i) * 0.02 + random.next() * 0.06), random: &random)
        }

        guard var image = ctx.makeImage() else { return nil }
        image = finish(image) ?? image
        return image
    }

    // MARK: Painting

    /// A seeded random, so the photo comes out the same each time.
    private struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> CGFloat {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return CGFloat(state % 1_000_000) / 1_000_000
        }
    }

    private static func colour(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let v = UInt32(hex, radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    private static func gradient(_ stops: [(CGFloat, String, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { colour($0.1, alpha: $0.2) } as CFArray,
                   locations: stops.map(\.0))!
    }

    private static func linear(_ ctx: CGContext, _ stops: [(CGFloat, String)], from a: CGPoint, to b: CGPoint) {
        linear(ctx, stops.map { ($0.0, $0.1, 1) }, from: a, to: b)
    }

    private static func linear(_ ctx: CGContext, _ stops: [(CGFloat, String, CGFloat)], from a: CGPoint, to b: CGPoint) {
        ctx.drawLinearGradient(gradient(stops), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, at c: CGPoint, _ stops: [(CGFloat, String, CGFloat)], radius: CGFloat) {
        ctx.drawRadialGradient(gradient(stops), startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    /// A mountain ridge across the picture, by halving and nudging, rougher the larger the step.
    private static func ridge(_ random: inout Seeded, width: CGFloat, base: CGFloat, rough: CGFloat) -> [CGPoint] {
        var heights: [CGFloat] = [random.next(), random.next()]
        var spread: CGFloat = 1
        for _ in 0..<8 {
            var next: [CGFloat] = []
            for (a, b) in zip(heights, heights.dropFirst()) {
                next += [a, (a + b) / 2 + (random.next() - 0.5) * spread]
            }
            next.append(heights.last!)
            heights = next
            spread *= 0.55
        }
        let low = heights.min()!, high = heights.max()!
        return heights.enumerated().map { i, v in
            CGPoint(x: width * CGFloat(i) / CGFloat(heights.count - 1), y: base + rough * (1 - (v - low) / max(high - low, 0.001)))
        }
    }

    /// Soft noise, as a grey mask: coarse random grids drawn large and smooth, laid over one another.
    private static func noise(_ random: inout Seeded, width: Int, height: Int, octaves: [(Int, Int, CGFloat)]) -> CGImage? {
        let grey = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: grey,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (cols, rows, weight) in octaves {
            var pixels = [UInt8](repeating: 0, count: cols * rows)
            for i in pixels.indices { pixels[i] = UInt8(max(0, min(255, (random.next() - 0.5) * 2.4 * 255))) }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let small = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: cols, space: grey,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                      decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            ctx.setAlpha(weight)
            ctx.setBlendMode(.plusLighter)
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ctx.makeImage()
    }

    /// A pine: tiers of boughs narrowing to the top, a little ragged.
    private static func pine(_ ctx: CGContext, at foot: CGPoint, height: CGFloat, random: inout Seeded) {
        let tiers = 9
        let p = CGMutablePath()
        for t in 0..<tiers {
            let k = CGFloat(t) / CGFloat(tiers)
            let y = foot.y - height * (0.12 + k * 0.88)
            let half = height * 0.17 * (1 - k) * (0.8 + random.next() * 0.4)
            p.move(to: CGPoint(x: foot.x, y: y - height * 0.16))
            p.addLine(to: CGPoint(x: foot.x + half, y: y + height * 0.02))
            p.addLine(to: CGPoint(x: foot.x - half, y: y + height * 0.02))
            p.closeSubpath()
        }
        p.addRect(CGRect(x: foot.x - height * 0.012, y: foot.y - height * 0.14, width: height * 0.024, height: height * 0.14))
        ctx.setFillColor(colour("101716"))
        ctx.addPath(p)
        ctx.fillPath()
    }

    /// As the camera leaves it: soft, a little flat and cool, darker in the corners, with grain.
    private static func finish(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let out = input
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.1]).cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.86, kCIInputSaturationKey: 0.8, kCIInputBrightnessKey: 0.01])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.91, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.92, w: 0),
                "inputBiasVector": CIVector(x: 0.045, y: 0.06, z: 0.08, w: 0),
            ])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.35, kCIInputRadiusKey: 1.8])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        guard let soft = context.createCGImage(out, from: extent, format: .RGBA8, colorSpace: space) else { return nil }
        return grained(soft)
    }

    /// Fine grain laid over the photo: a tile of random greys, repeated, mixed in softly.
    private static func grained(_ image: CGImage) -> CGImage? {
        let side = 256
        var random = Seeded(11)
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices { pixels[i] = UInt8(96 + random.next() * 64) }
        let grey = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let tile = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side, space: grey,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                 decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: all)
        ctx.setBlendMode(.overlay)
        ctx.setAlpha(0.35)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
        return ctx.makeImage()
    }
}
