import Foundation
import CoreGraphics
import Accelerate
import WebP

/// Writes WebP files with libwebp, which Packages/WebP holds: ImageIO reads WebP but cannot write it.
nonisolated enum WebPWriter {
    /// The picture as a WebP file: lossless at a quality of 1, otherwise as lossy as `quality`
    /// (0…1) allows, its see-through parts kept. Nil when it is too large for WebP, which
    /// holds at most 16383 pixels a side, or cannot be encoded.
    static func data(_ image: CGImage, quality: Double) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_383, h <= 16_383,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // libwebp takes each colour as it is, not already darkened by how see-through it is.
        var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        guard vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        let lossless = quality >= 1
        let size = BezzleWebPEncodeRGBA(pixels.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h), Int32(w * 4),
                                        Float(min(max(quality, 0), 1) * 100), lossless ? 1 : 0, &out)
        guard size > 0, let out else { return nil }
        defer { BezzleWebPFree(out) }
        return Data(bytes: out, count: size)
    }
}
