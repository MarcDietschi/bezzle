import Foundation
@testable import Vectorizer
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

// Pictures drawn for the tests, and what is measured of their tracings.

typealias Paint = (Double, Double, Double)

/// A picture of `w` by `h`, each pixel the mean of 8 by 8 samples of `color`, which answers red,
/// green and blue for a place in it.
func drawn(_ w: Int, _ h: Int, _ color: (Double, Double) -> Paint) -> Bitmap {
    var pixels = [UInt8](repeating: 255, count: w * h * 4)
    let n = 8
    for y in 0..<h {
        for x in 0..<w {
            var r = 0.0, g = 0.0, b = 0.0
            for j in 0..<n {
                for i in 0..<n {
                    let c = color(Double(x) + (Double(i) + 0.5) / Double(n), Double(y) + (Double(j) + 0.5) / Double(n))
                    r += c.0; g += c.1; b += c.2
                }
            }
            let i = (y * w + x) * 4, all = Double(n * n)
            pixels[i] = UInt8((r / all).rounded()); pixels[i + 1] = UInt8((g / all).rounded()); pixels[i + 2] = UInt8((b / all).rounded())
        }
    }
    return Bitmap(width: w, height: h, pixels: pixels)
}

/// `bitmap` with every pixel moved a little, each time the same way.
func shaken(_ bitmap: Bitmap, by most: Int) -> Bitmap {
    var pixels = bitmap.pixels
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for i in 0..<(bitmap.width * bitmap.height) {
        for c in 0..<3 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let move = Int((seed >> 33) % UInt64(2 * most + 1)) - most
            pixels[i * 4 + c] = UInt8(min(max(Int(pixels[i * 4 + c]) + move, 0), 255))
        }
    }
    return Bitmap(width: bitmap.width, height: bitmap.height, pixels: pixels)
}

#if canImport(ImageIO)
/// `bitmap` as it comes back from a JPEG file of that quality.
func kept(_ bitmap: Bitmap, quality: Double) -> Bitmap? {
    let w = bitmap.width, h = bitmap.height
    var pixels = bitmap.pixels
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    guard let image, let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(out), let source = CGImageSourceCreateWithData(data, nil),
          let back = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var read = [UInt8](repeating: 255, count: w * h * 4)
    read.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.draw(back, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    for i in 0..<(w * h) { read[i * 4 + 3] = 255 }
    return Bitmap(width: w, height: h, pixels: read)
}
#endif

/// A line as a hand draws it: from the left of a picture to its right, rising or falling a
/// little and swaying about that way.
struct Sway {
    var y: Double
    var slope: Double
    var sway: Double
    var seed: Double

    func height(_ x: Double) -> Double {
        y + slope * x + sway * sin(x / 21 + seed) + 0.4 * sway * sin(x / 8.3 + 2.7 * seed)
    }

    func steepness(_ x: Double) -> Double {
        slope + sway / 21 * cos(x / 21 + seed) + 0.4 * sway / 8.3 * cos(x / 8.3 + 2.7 * seed)
    }

    /// Whether a place lies on the line drawn `thick`, from `from` to `to` across.
    func holds(_ x: Double, _ y: Double, thick: Double, from: Double, to: Double) -> Bool {
        guard x >= from, x <= to else { return false }
        let s = steepness(x)
        return abs(y - height(x)) <= thick / 2 * (1 + s * s).squareRoot()
    }
}

/// An outline as corners close together.
func corners(_ outline: Outline) -> [Spot] {
    var out = [outline.start], last = outline.start
    for stretch in outline.stretches {
        switch stretch {
        case .line(let p):
            out.append(p)
        case .curve(let a, let b, let p):
            for k in 1...12 {
                let t = Double(k) / 12, s = 1 - t
                out.append(Spot(s * s * s * last.x + 3 * s * s * t * a.x + 3 * s * t * t * b.x + t * t * t * p.x,
                                s * s * s * last.y + 3 * s * s * t * a.y + 3 * s * t * t * b.y + t * t * t * p.y))
            }
        }
        last = stretch.end
    }
    return out
}

/// How thick a shape is across a line drawn as `sway`, measured every pixel and a third from
/// `from` to `to`: at each place, between the shape's nearest edges either side of the line's
/// middle. Nil where the middle is not in the shape.
func thicknesses(of shape: Shape, along sway: Sway, from: Double, to: Double) -> [Double?] {
    let rounds = shape.outlines.map(corners)
    var out: [Double?] = []
    var x = from
    while x <= to {
        let s = sway.steepness(x), l = (1 + s * s).squareRoot()
        let c = Spot(x, sway.height(x)), n = Spot(-s / l, 1 / l)
        var above = Double.infinity, below = Double.infinity
        for round in rounds {
            for k in 0..<(round.count - 1) {
                let a = round[k], b = round[k + 1]
                // Where the edge from a to b meets the line through c along n.
                let ex = b.x - a.x, ey = b.y - a.y
                let det = ex * n.y - ey * n.x
                guard abs(det) > 1e-12 else { continue }
                let u = ((c.x - a.x) * n.y - (c.y - a.y) * n.x) / det
                guard u >= 0, u <= 1 else { continue }
                let t = (a.x + ex * u - c.x) * n.x + (a.y + ey * u - c.y) * n.y
                if t >= 0 { above = min(above, t) } else { below = min(below, -t) }
            }
        }
        out.append(above.isFinite && below.isFinite && above + below < 12 ? above + below : nil)
        x += 1.3
    }
    return out
}

/// The mean of some measures, and how far they lie from it on the whole.
func spread(_ values: [Double]) -> (mean: Double, wavers: Double) {
    guard !values.isEmpty else { return (0, 0) }
    let mean = values.reduce(0, +) / Double(values.count)
    let wavers = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    return (mean, wavers)
}
