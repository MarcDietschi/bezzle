#if !os(Windows)
import CoreGraphics
#endif
import Foundation
@testable import Shaders

let renderer = ShaderRenderer.shared!

/// A picture's pixels, top row first, RGBA premultiplied, 0 to 255.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(_ image: ShaderPicture) {
        #if os(Windows)
        self.init(width: image.width, height: image.height, bytes: image.pixels)
        #else
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
        #endif
    }

    /// x from the left, y from the top.
    subscript(x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3])]
    }

    /// The mean of a block of pixels.
    func mean(x: Int, y: Int, size: Int) -> [Double] {
        var sum = [0.0, 0.0, 0.0, 0.0]
        for j in y..<(y + size) {
            for i in x..<(x + size) {
                let p = self[i, j]
                for c in 0..<4 { sum[c] += Double(p[c]) }
            }
        }
        return sum.map { $0 / Double(size * size) }
    }

    /// How many pixels differ from the first, and how many are not transparent.
    var variety: (different: Int, visible: Int) {
        var different = 0, visible = 0
        let first = Array(bytes[0..<4])
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if Array(bytes[i..<(i + 4)]) != first { different += 1 }
            if bytes[i + 3] != 0 { visible += 1 }
        }
        return (different, visible)
    }
}

func near(_ pixel: [Int], _ expected: [Int], within tolerance: Int = 3) -> Bool {
    zip(pixel, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

func near(_ pixel: [Double], _ expected: [Int], within tolerance: Double = 3) -> Bool {
    zip(pixel, expected).allSatisfy { abs($0 - Double($1)) <= tolerance }
}

/// A picture of `width` by `height` from RGBA bytes, top row first, not premultiplied.
func picture(_ width: Int, _ height: Int, _ rgba: [UInt8]) -> ShaderPicture {
    #if os(Windows)
    // Premultiplied as Core Graphics keeps it on the Mac, rounded to the nearest.
    var premultiplied = rgba
    for i in stride(from: 0, to: rgba.count, by: 4) {
        let alpha = Int(rgba[i + 3])
        for c in 0..<3 { premultiplied[i + c] = UInt8((Int(rgba[i + c]) * alpha + 127) / 255) }
    }
    return ShaderPicture(width: width, height: height, pixels: premultiplied)
    #else
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    #endif
}

/// One fragment shader over all of a drawing buffer.
func frame(_ width: Int, _ height: Int, _ fragment: String, uniforms: [String: [Float]] = [:],
           textures: [String: ShaderPicture] = [:], antialias: Bool = false) -> ShaderFrame {
    var draw = ShaderDraw.fullSurface(fragment: fragment, uniforms: uniforms, textures: textures)
    draw.uniforms["u_resolution"] = draw.uniforms["u_resolution"] ?? [Float(width), Float(height)]
    return ShaderFrame(size: CGSize(width: width, height: height), draws: [draw], antialias: antialias)
}

func draw(_ frame: ShaderFrame, scale: Double = 1, region: CGRect? = nil) throws -> Pixels {
    let area = region ?? CGRect(origin: .zero, size: frame.size)
    let image = try renderer.image(of: frame, pixels: CGSize(width: area.width * scale, height: area.height * scale),
                                   region: region)
    return Pixels(image)
}
