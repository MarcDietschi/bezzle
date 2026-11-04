import CoreGraphics

/// A design's file as its thumbnail draws it: the design on a sheet of Bezzle's paper, lying on
/// the desk, its top right corner folded over. It is the sheet of the design's icon
/// (Scripts/make-icon.swift, `Sheet` and `renderDocument`) cut to the design's own proportions,
/// with the same shadows and the same fold, so a design with a picture and one without still
/// look like the same kind of file.
struct Sheet {
    /// The picture's width over its height, which the sheet takes.
    let aspect: CGFloat

    /// Room round the sheet for its shadow, as a share of its longer side.
    private static let margin: CGFloat = 0.05
    /// Its corners, and how far the fold reaches along the top and down the side, as shares of its shorter side.
    private static let corner: CGFloat = 0.05
    private static let ear: CGFloat = 0.21

    /// The size to draw it at, in points, as large as fits in `bounds`: the sheet and the margin round it.
    func size(fitting bounds: CGSize) -> CGSize {
        let m = 2 * Self.margin
        let long = aspect >= 1 ? min(bounds.width / (1 + m), bounds.height / (1 / aspect + m))
                               : min(bounds.width / (aspect + m), bounds.height / (1 + m))
        let w = aspect >= 1 ? long : long * aspect, h = aspect >= 1 ? long / aspect : long
        return CGSize(width: (w + m * long).rounded(), height: (h + m * long).rounded())
    }

    /// Draws the sheet with `picture` on it, filling a context `size` points large.
    func draw(_ picture: CGImage, in ctx: CGContext, size: CGSize) {
        // Points, however many pixels the context holds, with y pointing down from the top left.
        let box = ctx.boundingBoxOfClipPath
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: box.width / size.width, y: -box.height / size.height)
        // Shadows are measured in pixels, with y pointing up.
        let px = abs(ctx.userSpaceToDeviceSpaceTransform.d)
        func shadow(dy: CGFloat, blur: CGFloat, _ c: CGColor) {
            ctx.setShadow(offset: CGSize(width: 0, height: -dy * px), blur: max(blur * px, 0.5), color: c)
        }

        let m = 2 * Self.margin
        let long = aspect >= 1 ? size.width / (1 + m) : size.height / (1 + m)
        let inset = Self.margin * long
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let short = min(rect.width, rect.height)
        let corner = max(Self.corner * short, 1.5), ear = (Self.ear * short).rounded()

        let whole = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let past = CGMutablePath()
        past.addLines(between: [CGPoint(x: rect.maxX - ear, y: rect.minY), CGPoint(x: rect.maxX - ear + 4 * ear, y: rect.minY - 4 * ear),
                                CGPoint(x: rect.maxX + 4 * ear, y: rect.minY + ear), CGPoint(x: rect.maxX, y: rect.minY + ear)])
        past.closeSubpath()
        let page = whole.subtracting(past)
        // The corner past the crease, mirrored across it: its rounded tip points in.
        let c = rect.maxX - ear - rect.minY
        var mirror = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: c, ty: -c)
        let flap = whole.intersection(past).copy(using: &mirror) ?? CGMutablePath()

        // On the desk: a soft shadow under the sheet, and a tight one along its edge.
        for (dy, blur, alpha) in [(0.012 * long, 0.03 * long, 0.22), (0.0015 * long, 0.003 * long, 0.25)] {
            ctx.saveGState()
            shadow(dy: dy, blur: blur, Self.ink(alpha))
            ctx.addPath(page); ctx.setFillColor(Self.paper(0xEDE8DF)); ctx.fillPath()
            ctx.restoreGState()
        }

        // The design, the right way up in a context whose y points down.
        ctx.saveGState()
        ctx.addPath(page); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(picture, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
        // A faint line round it, so a white design keeps its edge on a white window.
        ctx.saveGState()
        ctx.addPath(page); ctx.clip()
        ctx.addPath(page); ctx.setStrokeColor(Self.ink(0.07)); ctx.setLineWidth(2 / px); ctx.strokePath()
        ctx.restoreGState()

        // The fold casts a shadow down onto the design, and is lit along the crease.
        ctx.saveGState()
        ctx.addPath(page); ctx.clip()
        shadow(dy: 0.056 * ear, blur: 0.12 * ear, Self.paper(0x3A2A1C, 0.3))
        ctx.addPath(flap); ctx.setFillColor(Self.paper(0xE6E0D5)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(flap); ctx.clip()
        let fold = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [Self.paper(0xFFFEFB), Self.paper(0xF4F0E8), Self.paper(0xDDD6CA)] as CFArray, locations: [0, 0.35, 1])!
        ctx.drawLinearGradient(fold, start: CGPoint(x: rect.maxX - ear / 2, y: rect.minY + ear / 2),
                               end: CGPoint(x: rect.maxX - ear, y: rect.minY + ear), options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func paper(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    private static func ink(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }
}
