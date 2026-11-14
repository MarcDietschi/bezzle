import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture the tour brings for the lesson on Vectorize: a sailing club's badge as someone
/// would have it who has only ever been sent the picture. A few flat colours, a thin ring, two
/// thin waves and six letters, so that it comes out of the tracing as clean shapes. Painted
/// afresh each time a tour is made, as the tour's photo is (`WelcomePhoto`), and nothing but
/// pixels: no part of it is a layer until it has been traced.
nonisolated enum WelcomeLogo {
    static let size = CGSize(width: 900, height: 900)

    /// The picture as a PNG, as it is put in a design's images.
    static func png() -> Data? {
        guard let image = paint() else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// Paints the picture. The same every time.
    static func paint() -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Painted top down, as the picture is seen, and measured as a thousand across.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: size.width / 1000, y: -size.height / 1000)
        let paper = colour("F6EEDC"), navy = colour("1C3B5E"), water = colour("2B8088"), sun = colour("F6BE3B"), red = colour("EE6B4D")

        ctx.setFillColor(paper)
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))

        // The badge: a thin ring round a disc of evening sky.
        let middle = CGPoint(x: 500, y: 418)
        func circle(_ r: CGFloat, at c: CGPoint = middle) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }
        ctx.setStrokeColor(navy)
        ctx.setLineWidth(9)
        ctx.strokeEllipse(in: circle(352))
        ctx.saveGState()
        ctx.addEllipse(in: circle(318))
        ctx.clip()
        ctx.setFillColor(navy)
        ctx.fill(circle(318))
        // The sun, low over the water, which covers its foot; clear of the boat, so that each
        // comes out of the tracing as a shape of its own, whole.
        ctx.setFillColor(sun)
        ctx.fillEllipse(in: circle(92, at: CGPoint(x: 666, y: 438)))
        let shore: CGFloat = 486
        ctx.setFillColor(water)
        ctx.fill(CGRect(x: 0, y: shore, width: 1000, height: 1000 - shore))
        // Two thin waves.
        ctx.setStrokeColor(paper)
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        for (y, from, to) in [(CGFloat(566), CGFloat(300), CGFloat(700)), (636, 380, 620)] {
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: from, y: y))
            var x = from
            var up = true
            while x < to - 1 {
                let next = min(x + 80, to)
                wave.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? -22 : 22)))
                x = next
                up.toggle()
            }
            ctx.addPath(wave)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // The boat: two sails and a hull, on the water's edge.
        ctx.setFillColor(paper)
        for sail in [[CGPoint(x: 432, y: 236), CGPoint(x: 432, y: 452), CGPoint(x: 300, y: 452)],
                     [CGPoint(x: 452, y: 296), CGPoint(x: 452, y: 452), CGPoint(x: 546, y: 452)]] {
            ctx.addLines(between: sail)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setFillColor(red)
        ctx.addLines(between: [CGPoint(x: 286, y: 470), CGPoint(x: 566, y: 470), CGPoint(x: 522, y: 518), CGPoint(x: 330, y: 518)])
        ctx.closePath()
        ctx.fillPath()

        // Its name under it, set wide.
        let font = CTFontCreateWithName("Charter-Black" as CFString, 128, nil)
        let apart: CGFloat = 15
        let name = NSAttributedString(string: "BEZZLE", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): navy,
            NSAttributedString.Key(kCTKernAttributeName as String): apart,
        ])
        let line = CTLineCreateWithAttributedString(name)
        // As wide as its letters, without the room after the last.
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - apart
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: 500 - width / 2, y: 918)
        CTLineDraw(line, ctx)

        return ctx.makeImage()
    }

    private static func colour(_ hex: String) -> CGColor {
        let v = UInt32(hex, radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
