import AppKit
import CoreImage

/// Blurs, drawn the only way Core Graphics allows: into a picture first, blurred with Core
/// Image, then drawn back. A layer's own blur blurs the layer; a background blur blurs what lies
/// behind it on its artboard, drawn again just for this up to the layer, and shows it through the
/// layer's outline, darkened or lightened, under the layer's own fill. The pictures are kept until
/// what they show changes, so moving about the canvas does not make them again.
extension Renderer {
    /// Stops a drawing just before one layer, so that what lies behind it can be drawn on its own.
    final class Halt {
        let before: UUID
        var reached = false

        init(before: UUID) { self.before = before }
    }

    /// How many pixels a point is in the context right now, whatever it has been scaled and turned
    /// by. The device transform counts the screen's own scale, which the canvas's context keeps out of its CTM.
    static func pixelScale(_ ctx: CGContext) -> CGFloat {
        let t = ctx.userSpaceToDeviceSpaceTransform
        return max(sqrt(abs(t.a * t.d - t.b * t.c)), 1)
    }

    /// Where a layer's own coordinates are in its parent's: the frame's top left, turned with it.
    static func localTransform(_ node: Node) -> CGAffineTransform {
        CGAffineTransform(translationX: -node.frame.width / 2, y: -node.frame.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
            .concatenating(CGAffineTransform(translationX: node.frame.midX, y: node.frame.midY))
    }

    /// A layer with a blur of its own: drawn as it would be, then blurred where it lies.
    static func drawBlurred(_ node: Node, radius: CGFloat, in ctx: CGContext, options: Options) {
        var plain = node
        plain.blur = nil
        // Blurred on its own, and then mixed as a whole with what lies under it.
        plain.blend = nil
        let scale = pixelScale(ctx)
        // The blur spreads about three times its radius; a shadow reaches further still.
        var region = Geometry.bounds(of: node).insetBy(dx: -node.border.width, dy: -node.border.width)
        if node.shadow.on {
            region = region.union(region.offsetBy(dx: node.shadow.x, dy: node.shadow.y).insetBy(dx: -node.shadow.blur * 2, dy: -node.shadow.blur * 2))
        }
        region = region.insetBy(dx: -radius * 3, dy: -radius * 3).integral
        // A large layer seen up close is only made as big as what can be seen of it.
        if region.width * region.height * scale * scale > 12_000_000, let around = around(options) {
            let toCanvas = CGPoint(x: (options.board?.frame.minX ?? 0) + options.offset.x, y: (options.board?.frame.minY ?? 0) + options.offset.y)
            region = region.intersection(around.offsetBy(dx: -toCanvas.x, dy: -toCanvas.y).insetBy(dx: -radius * 3, dy: -radius * 3)).integral
            guard !region.isNull, region.width > 0, region.height > 0 else { return }
        }

        let image: CGImage?
        if let kept = BlurCache.shared.object(plain, scale: scale, region: region) {
            image = kept
        } else {
            image = offscreen(region, scale: scale) { drawNode(plain, in: $0, options: options) }
                .flatMap { blurred($0, sigma: radius * scale, clamp: false) }
            if let image { BlurCache.shared.keep(object: plain, scale: scale, region: region, image: image) }
        }
        guard let image else { return }
        ctx.saveGState()
        if let blend = node.blend { ctx.setBlendMode(blend.cg) }
        place(image, at: region.origin, scale: scale, in: ctx)
        ctx.restoreGState()
    }

    /// What lies behind a layer with a background blur, blurred, shown through the layer's
    /// outline. The context is in the layer's own coordinates, as it is when its fill is drawn.
    static func drawBackdrop(_ node: Node, blur: Blur, outline: CGPath, evenOdd: Bool, in ctx: CGContext, options: Options) {
        let scale = pixelScale(ctx)
        guard let (image, region) = backdrop(of: node, blur: blur, scale: scale, options: options) else { return }
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip(using: evenOdd ? .evenOdd : .winding)
        // Back to the parent's coordinates, where the picture was made.
        ctx.concatenate(localTransform(node).inverted())
        place(image, at: region.origin, scale: scale, in: ctx)
        lighten(region, by: blur.brightness, in: ctx)
        ctx.restoreGState()
    }

    /// The blurred picture of what lies behind a layer, at `scale`, and where it goes in the
    /// layer's parent's coordinates; lightened or darkened only as it is drawn.
    private static func backdrop(of node: Node, blur: Blur, scale: CGFloat, options: Options) -> (image: CGImage, region: CGRect)? {
        guard let board = options.board, blur.radius > 0 else { return nil }
        // In the parent's coordinates, and where that is on the canvas.
        var region = Geometry.bounds(of: node).insetBy(dx: -blur.radius * 3, dy: -blur.radius * 3).integral
        let toCanvas = CGPoint(x: board.frame.minX + options.offset.x, y: board.frame.minY + options.offset.y)
        // Nothing lies behind beyond the artboard's edge: there the last of what does carries on.
        if board.clips {
            region = region.intersection(CGRect(origin: CGPoint(x: -options.offset.x, y: -options.offset.y), size: board.frame.size))
        }
        // A huge layer seen up close is only made as big as what can be seen of it.
        if region.width * region.height * scale * scale > 12_000_000, let around = around(options) {
            region = region.intersection(around.offsetBy(dx: -toCanvas.x, dy: -toCanvas.y).insetBy(dx: -blur.radius * 3, dy: -blur.radius * 3)).integral
        }
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }

        if let kept = BlurCache.shared.backdrop(node, board: board, scale: scale, region: region, settling: options.settling) {
            return kept
        }
        let made = offscreen(region.offsetBy(dx: toCanvas.x, dy: toCanvas.y), scale: scale) { c in
            var behind = Options(deviceScale: scale, assets: options.assets)
            behind.halt = Halt(before: node.id)
            // Only what lies behind this part of it: the rest of the artboard is left out.
            behind.visible = region.offsetBy(dx: toCanvas.x, dy: toCanvas.y)
            behind.screen = options.screen
            drawArtboard(board, in: c, options: behind)
        }
        .flatMap { blurred($0, sigma: blur.radius * scale, clamp: true) }
        guard let made else { return nil }
        BlurCache.shared.keep(backdrop: node, board: board, scale: scale, region: region, image: made)
        return (made, region)
    }

    /// The same, finished, lightened or darkened as it shows: for writing it into a file that
    /// cannot blur what lies behind a layer itself. In the layer's parent's coordinates.
    static func backdropPicture(of node: Node, scale: CGFloat, options: Options) -> (image: CGImage, region: CGRect)? {
        guard let blur = node.blur, blur.on, blur.background,
              let (image, region) = backdrop(of: node, blur: blur, scale: scale, options: options) else { return nil }
        guard blur.brightness != 0, let ctx = bitmap(CGSize(width: image.width, height: image.height)) else { return (image, region) }
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: all)
        lighten(all, by: blur.brightness, in: ctx)
        return ctx.makeImage().map { ($0, region) }
    }

    /// Lighter or darker by the same amount in every colour, as it is drawn rather than in the
    /// picture, so changing it shows at once: adding grey adds, and adding its opposite under
    /// "plus darker" takes away.
    private static func lighten(_ rect: CGRect, by brightness: Double, in ctx: CGContext) {
        let b = CGFloat(min(max(brightness, -1), 1))
        guard b != 0 else { return }
        ctx.saveGState()
        ctx.setBlendMode(b > 0 ? .plusLighter : .plusDarker)
        let level = b > 0 ? b : 1 + b
        ctx.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// What part of a large blur is worth making, on the canvas: what is on screen and a little
    /// way around it, in steps of a quarter of the screen, so that moving about a little, or
    /// drawing it tile by tile, keeps using the same picture.
    private static func around(_ options: Options) -> CGRect? {
        guard let screen = options.screen ?? options.visible else { return nil }
        let step = max(screen.width, screen.height) / 4
        guard step > 0, step.isFinite else { return screen }
        let minX = (screen.minX / step - 1).rounded(.down) * step, minY = (screen.minY / step - 1).rounded(.down) * step
        let maxX = (screen.maxX / step + 1).rounded(.up) * step, maxY = (screen.maxY / step + 1).rounded(.up) * step
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Draws into a picture of `region`, given in the context's coordinates, at `scale` pixels to the point.
    private static func offscreen(_ region: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((region.width * scale).rounded(.up)), h = Int((region.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 40_000_000, let c = bitmap(CGSize(width: w, height: h)) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: scale, y: -scale)
        c.translateBy(x: -region.minX, y: -region.minY)
        withFlippedContext(c) { body(c) }
        return c.makeImage()
    }

    /// Blurring in plain sRGB values, as design tools do: in linear light, a blur of black into
    /// white comes out lighter than the eye expects, and does not match what the designs were made with.
    private static let imaging = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// A Gaussian blur, measured as a standard deviation in pixels, which is what XD's blur amount is. What lies behind a layer reaches
    /// past the picture's edges, so for a backdrop the edge pixels carry on outward rather than fade.
    private static func blurred(_ image: CGImage, sigma: CGFloat, clamp: Bool) -> CGImage? {
        let input = CIImage(cgImage: image)
        let source = clamp ? input.clampedToExtent() : input
        let output = source.applyingGaussianBlur(sigma: Double(sigma)).cropped(to: input.extent)
        return imaging.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Draws a picture made at `scale` back where it was made, in a context whose y runs down.
    private static func place(_ image: CGImage, at origin: CGPoint, scale: CGFloat, in ctx: CGContext) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: origin.x, y: origin.y + size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}

/// Blurred pictures kept between drawings, with what they were made from, so each is made again
/// only when that changes: the layer, what lies behind it, how close the canvas is, or how much is seen.
private final class BlurCache {
    static let shared = BlurCache()

    private struct Entry {
        let node: Node
        let board: Node?
        let scale: CGFloat
        let region: CGRect
        let image: CGImage
        var used: UInt64 = 0
        var bytes: Int { image.width * image.height * 4 }
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    /// A large design has many background blurs; the least lately drawn go first.
    private let budget = 192 << 20

    func object(_ node: Node, scale: CGFloat, region: CGRect) -> CGImage? {
        guard let e = entries["o\(node.id)"], e.scale == scale, e.region == region, e.node == node else { return nil }
        touch("o\(node.id)")
        return e.image
    }

    private func touch(_ key: String) {
        clock += 1
        entries[key]?.used = clock
    }

    /// While things settle, what lay behind may have moved on a little; the picture made before
    /// stands in until they are done, wherever it was made for, as long as it covers what is needed
    /// and is blurred as much: a blur being changed itself shows each change at once.
    func backdrop(_ node: Node, board: Node, scale: CGFloat, region: CGRect, settling: Bool = false) -> (image: CGImage, region: CGRect)? {
        guard let e = entries["b\(node.id)"], e.scale == scale else { return nil }
        let stands = e.region.contains(region) && e.node.blur?.radius == node.blur?.radius
        guard settling ? stands : e.region == region && e.board == board else { return nil }
        touch("b\(node.id)")
        return (e.image, e.region)
    }

    func keep(object node: Node, scale: CGFloat, region: CGRect, image: CGImage) {
        store("o\(node.id)", Entry(node: node, board: nil, scale: scale, region: region, image: image))
    }

    func keep(backdrop node: Node, board: Node, scale: CGFloat, region: CGRect, image: CGImage) {
        store("b\(node.id)", Entry(node: node, board: board, scale: scale, region: region, image: image))
    }

    private func store(_ key: String, _ entry: Entry) {
        clock += 1
        var entry = entry
        entry.used = clock
        if let old = entries[key] { bytes -= old.bytes }
        entries[key] = entry
        bytes += entry.bytes
        guard bytes > budget else { return }
        for (k, e) in entries.sorted(by: { $0.value.used < $1.value.used }) where k != key {
            entries[k] = nil
            bytes -= e.bytes
            if bytes <= budget { break }
        }
    }
}
