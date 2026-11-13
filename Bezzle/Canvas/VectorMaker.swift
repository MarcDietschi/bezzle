import CoreGraphics
import Foundation
import Vectorizer

/// What of Vectorize is the Mac's own (the rest is shared with Windows, Model/Vectorizing.swift):
/// the layer drawn into pixels with Core Graphics, to be traced.
extension VectorMaker {
    /// The layer as it shows, without its border, shadows, opacity and turn, as pixels. Nil when
    /// it shows no picture, or nothing at all.
    nonisolated static func source(of node: Node, assets: Assets) -> Source? {
        guard let (size, scale) = reading(node), let ctx = Renderer.bitmap(size) else { return nil }
        let plain = plain(node)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / node.frame.width, y: -size.height / node.frame.height)
        ctx.interpolationQuality = .high
        Renderer.withFlippedContext(ctx) {
            Renderer.drawNode(plain, in: ctx, options: Renderer.Options(deviceScale: scale, assets: assets))
        }
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self), let made = ctx.makeImage(),
              let pixels = straightened(data, width: ctx.width, height: ctx.height, rowBytes: ctx.bytesPerRow) else { return nil }
        return Source(bitmap: Bitmap(width: ctx.width, height: ctx.height, pixels: pixels), image: made, scale: size.width / node.frame.width)
    }
}
