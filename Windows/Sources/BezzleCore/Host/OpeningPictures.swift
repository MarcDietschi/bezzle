import Foundation

// The parts of Bezzle's mark the opening cover is made of (OpeningPlan.Part), drawn by the shared
// OpeningMark.paint as the Mac draws them, by Skia here, for the cover's pictures.

extension OpeningPlan {
    /// A part of a sheet, as big as the whole mark with its shadows, `scale` pixels to the point,
    /// into the pixels `fill` gives (premultiplied BGRA, rows top first). Its size in pixels, or
    /// nil if it could not be drawn.
    @MainActor public static func picture(_ part: Part, of sheet: Int, dark: Bool, scale: Double,
                                          into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> (width: Int, height: Int)? {
        let pixels = OpeningMark.side / 500 * CGFloat(scale)
        let size = CGSize(width: (OpeningMark.canvas.width * pixels).rounded(.up), height: (OpeningMark.canvas.height * pixels).rounded(.up))
        let drawn = WindowsCore.picture({
            guard let ctx = Renderer.bitmap(size) else { return nil }
            // The mark's units, y down.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: pixels, y: -pixels)
            ctx.translateBy(x: -OpeningMark.canvas.minX, y: -OpeningMark.canvas.minY)
            OpeningMark.paint(part.shared, of: sheet, dark: dark, pixels: pixels, in: ctx)
            return ctx.makeImage()
        }, into: fill)
        return drawn ? (Int(size.width), Int(size.height)) : nil
    }
}
