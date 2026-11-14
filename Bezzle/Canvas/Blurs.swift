import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Blurs, drawn the only way Core Graphics allows: into a picture first, blurred with Core
/// Image, then drawn back. A layer's own blur blurs the layer; a background blur blurs what lies
/// behind it on its artboard, drawn again just for this up to the layer, and shows it through the
/// layer's outline, darkened or lightened, under the layer's own fill. The pictures are kept until
/// what they show changes, so moving about the canvas does not make them again.
nonisolated extension Renderer {
    /// Stops a drawing just before one layer, so that what lies behind it can be drawn on its own.
    /// Each drawing has its own, on the one thread it is drawn on.
    final class Halt: @unchecked Sendable {
        let before: UUID
        var reached = false

        init(before: UUID) { self.before = before }
    }

    /// How many pixels a point is in the context right now, whatever it has been scaled and turned
    /// by. The device transform counts the screen's own scale, which the canvas's context keeps out of its CTM.
    static func pixelScale(_ ctx: CGContext) -> CGFloat {
        max(exactPixelScale(ctx), 1)
    }

    private static func exactPixelScale(_ ctx: CGContext) -> CGFloat {
        let t = ctx.userSpaceToDeviceSpaceTransform
        return sqrt(abs(t.a * t.d - t.b * t.c))
    }

    /// Whether a blur this wide is less than half a pixel where it is drawn, as in a thumbnail or
    /// far out on the canvas, and so changes nothing that can be seen. Made anyway, it is made a
    /// point to the pixel all the same, and takes a long time to show nothing.
    private static func tooSmallToSee(_ radius: CGFloat, in ctx: CGContext) -> Bool {
        radius * exactPixelScale(ctx) < 0.5
    }

    /// How many pixels a blur is spread over, at most, when it is made: by Core Image, which
    /// measures it as a standard deviation, and a shadow by Core Graphics, which measures twice
    /// that. Blurred that much, a picture holds nothing finer than these pixels do, so making it at
    /// the screen's own only takes longer: close up on a Retina screen a 30 point shadow is spread
    /// over a thousand pixels, and Core Graphics takes seconds over it. Made at fewer and
    /// stretched, it differs by a few 255ths at most, about as much as the same shadow differs
    /// between two zooms anyway.
    static let blurPixels: CGFloat = 16
    static let shadowPixels: CGFloat = 24

    /// A layer's shadow, wide on screen, made apart from the layer at fewer pixels and drawn where
    /// it falls, faded and mixed as the layer is; the layer is then drawn without one. Core
    /// Graphics still makes it, from the layer drawn well to the side of the picture with its
    /// shadow cast back into it, so it is the shadow the layer casts. Returns whether it did.
    static func drawShadowApart(_ node: Node, _ shadow: Shadow, in ctx: CGContext, options: Options) -> Bool {
        let scale = pixelScale(ctx), made = min(scale, shadowPixels / max(shadow.blur, 0.001))
        // Only into pixels: a PDF's shadows are left to Core Graphics.
        guard !options.castingShadow, made < scale * 0.75, ctx.width > 0 else { return false }
        let drawn = casting(node, shadow, eye: options.eye)
        let falls = drawn.offsetBy(dx: shadow.x, dy: shadow.y).insetBy(dx: -shadow.blur * 2, dy: -shadow.blur * 2).integral
        // Only what is drawn of it, and a few pixels round that for the stretching, in whole pixels
        // counted from its corner: every tile makes the same pixels of it, and they meet without a seam.
        let seen = falls.intersection(ctx.boundingBoxOfClipPath.insetBy(dx: -3 / made, dy: -3 / made))
        guard !seen.isNull, seen.width > 0, seen.height > 0 else { return true }
        func pixel(_ v: CGFloat, from origin: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat {
            origin + ((v - origin) * made).rounded(rule) / made
        }
        let x = pixel(seen.minX, from: falls.minX, .down), y = pixel(seen.minY, from: falls.minY, .down)
        let region = CGRect(x: x, y: y, width: pixel(seen.maxX, from: falls.minX, .up) - x, height: pixel(seen.maxY, from: falls.minY, .up) - y)
        // Far enough to the right that none of the layer reaches the picture, by whole pixels.
        let away = ((falls.maxX - drawn.minX + shadow.blur * 2 + 8) * made).rounded(.up) / made
        var cast = shadow
        cast.x -= away
        var alone = options
        alone.castingShadow = true
        // Cast by as much of it as is drawn, without stopping the drawing it is part of.
        alone.halt = options.halt.map { Halt(before: $0.before) }
        guard let picture = offscreen(region, scale: made, deep: options.deep, { c in
            c.translateBy(x: away, y: 0)
            drawCaster(of: node, casting: cast, in: c, options: alone)
        }) else { return false }
        ctx.saveGState()
        if node.opacity < 1 { ctx.setAlpha(node.opacity) }
        if let blend = node.blend { ctx.setBlendMode(blend.cg) }
        place(picture, at: region.origin, scale: made, in: ctx)
        ctx.restoreGState()
        return true
    }

    /// One of a layer's shadows under it, on its own, so that the layer can cast several, or one
    /// from its outline grown: made apart when it is wide on screen, as `drawShadowApart` makes
    /// it, and otherwise cast where it falls by the layer drawn well to the side, out of sight,
    /// faded and mixed as the layer is. The layer is then drawn over it without it.
    static func drawShadowAlone(_ node: Node, _ shadow: Shadow, in ctx: CGContext, options: Options) {
        if drawShadowApart(node, shadow, in: ctx, options: options) { return }
        let drawn = casting(node, shadow, eye: options.eye)
        let falls = drawn.offsetBy(dx: shadow.x, dy: shadow.y).insetBy(dx: -shadow.blur * 2 - 1, dy: -shadow.blur * 2 - 1)
        guard !falls.isNull, falls.width > 0, falls.height > 0 else { return }
        let away = (falls.maxX - drawn.minX + shadow.blur * 2 + 8).rounded(.up)
        var cast = shadow
        cast.x -= away
        var alone = options
        alone.castingShadow = true
        alone.halt = options.halt.map { Halt(before: $0.before) }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: falls)
        let mixed = node.opacity < 1 || node.blend != nil
        if mixed {
            if node.opacity < 1 { ctx.setAlpha(node.opacity) }
            if let blend = node.blend { ctx.setBlendMode(blend.cg) }
            ctx.beginTransparencyLayer(in: falls, auxiliaryInfo: nil)
        }
        ctx.translateBy(x: away, y: 0)
        drawCaster(of: node, casting: cast, in: ctx, options: alone)
        if mixed { ctx.endTransparencyLayer() }
    }

    /// Where what casts a shadow lies, in the layer's parent's coordinates: the layer as it is
    /// drawn, turned in depth with it, or its outline as the spread grows it.
    static func casting(_ node: Node, _ shadow: Shadow, eye: Eye?) -> CGRect {
        let perspective = Perspective.onCanvas(node, eye: eye)
        let drawn = perspective.map { $0.bounds(of: reach(of: flattened(node), eye: eye?.level)) } ?? ink(of: node, eye: eye).applying(localTransform(node))
        return spreads(node, shadow) && perspective == nil ? drawn.insetBy(dx: -max(shadow.grown, 0), dy: -max(shadow.grown, 0)) : drawn
    }

    /// Draws what casts one of a layer's shadows, the shadow set: the layer as it is drawn, at full
    /// strength and holding no other shadow under it, or the outline its spread grows, filled.
    /// `options` cast as Core Graphics casts, not apart.
    static func drawCaster(of node: Node, casting shadow: Shadow, in ctx: CGContext, options: Options) {
        if spreads(node, shadow), !Perspective.inDepth(node), let grown = spreadOutline(of: node, by: shadow.grown) {
            ctx.saveGState()
            setShadow(shadow, in: ctx)
            ctx.concatenate(localTransform(node))
            ctx.addPath(grown)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath(using: node.silhouette != nil || node.evenOdd == true ? .evenOdd : .winding)
            ctx.restoreGState()
            return
        }
        var cast = node
        cast.shadows = [shadow] + node.innerShadows
        cast.opacity = 1
        cast.blend = nil
        drawNode(cast, in: ctx, options: options)
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
        if tooSmallToSee(radius, in: ctx) {
            drawNode(plain, in: ctx, options: options)
            return
        }
        // Blurred on its own, and then mixed as a whole with what lies under it.
        plain.blend = nil
        let ramp = node.blur?.ramp
        // A blur that grows is sharp at one end, which needs the screen's own pixels.
        var scale = ramp == nil ? min(pixelScale(ctx), blurPixels / radius) : pixelScale(ctx)
        // The blur spreads about three times its radius; a shadow reaches further still.
        var region = Geometry.bounds(of: node).insetBy(dx: -node.borderWidth, dy: -node.borderWidth)
        region = shadowed(region, by: node).insetBy(dx: -radius * 3, dy: -radius * 3).integral
        // A large layer seen up close is only made as big as what can be seen of it.
        if region.width * region.height * scale * scale > 12_000_000, let around = around(options) {
            let toCanvas = CGPoint(x: (options.board?.frame.minX ?? 0) + options.offset.x, y: (options.board?.frame.minY ?? 0) + options.offset.y)
            region = region.intersection(around.offsetBy(dx: -toCanvas.x, dy: -toCanvas.y).insetBy(dx: -radius * 3, dy: -radius * 3)).integral
            guard !region.isNull, region.width > 0, region.height > 0 else { return }
        }
        if ramp != nil { scale = rampScale(scale, radius: radius, region: region) }

        // Kept with its blur, which the picture shows.
        var keyed = plain
        keyed.blur = node.blur
        let image: CGImage?
        let deep = options.deep
        if let kept = BlurCache.shared.object(keyed, scale: scale, region: region, deep: deep) {
            image = kept
        } else {
            image = offscreen(region, scale: scale, deep: deep) { drawNode(plain, in: $0, options: options) }
                .flatMap { picture in
                    guard let ramp else { return blurred(picture, sigma: radius * scale, clamp: false, deep: deep) }
                    let (from, to) = pixels(of: ramp, on: node, in: region, sx: scale, sy: scale, height: CGFloat(picture.height))
                    return blurred(picture, sigma: radius * scale, from: from, to: to, clamp: false, deep: deep)
                }
            if let image { BlurCache.shared.keep(object: keyed, scale: scale, region: region, deep: deep, image: image) }
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
        // Too small to see, the blur leaves what lies behind as it is, and that is drawn already.
        if tooSmallToSee(blur.radius, in: ctx) {
            ctx.saveGState()
            ctx.addPath(outline)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            lighten(outline.boundingBoxOfPath, by: blur.brightness, in: ctx)
            ctx.restoreGState()
            return
        }
        let scale = pixelScale(ctx)
        guard let (image, region) = backdrop(of: node, blur: blur, scale: scale, options: options) else { return }
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip(using: evenOdd ? .evenOdd : .winding)
        // Back to the parent's coordinates, where the picture was made.
        ctx.concatenate(localTransform(node).inverted())
        place(image, in: region, ctx)
        lighten(region, by: blur.brightness, in: ctx)
        ctx.restoreGState()
    }

    /// The blurred picture of what lies behind a layer, at `scale` or as few pixels as its blur
    /// leaves room for, and where it goes in the layer's parent's coordinates, which it covers
    /// exactly; lightened or darkened only as it is drawn.
    private static func backdrop(of node: Node, blur: Blur, scale: CGFloat, options: Options) -> (image: CGImage, region: CGRect)? {
        guard let board = options.board, blur.radius > 0 else { return nil }
        // In the parent's coordinates, and where that is on the canvas.
        var region = Geometry.bounds(of: node).insetBy(dx: -blur.radius * 3, dy: -blur.radius * 3).integral
        // A blur that grows is sharp at one end, which needs the screen's own pixels.
        var scale = blur.ramp == nil ? min(scale, blurPixels / blur.radius) : scale
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
        if blur.ramp != nil { scale = rampScale(scale, radius: blur.radius, region: region) }

        let deep = options.deep
        if let kept = BlurCache.shared.backdrop(node, board: board, scale: scale, region: region, deep: deep, settling: options.settling) {
            return kept
        }
        let made = offscreen(region.offsetBy(dx: toCanvas.x, dy: toCanvas.y), scale: scale, exactly: true, deep: deep) { c in
            var behind = Options(deviceScale: scale, assets: options.assets)
            behind.deep = deep
            behind.picturesLater = options.picturesLater
            behind.halt = Halt(before: node.id)
            // Only what lies behind this part of it: the rest of the artboard is left out.
            behind.visible = region.offsetBy(dx: toCanvas.x, dy: toCanvas.y)
            behind.screen = options.screen
            drawArtboard(board, in: c, options: behind)
        }
        .flatMap { picture in
            guard let ramp = blur.ramp else { return blurred(picture, sigma: blur.radius * scale, clamp: true, deep: deep) }
            let height = CGFloat(picture.height)
            let (from, to) = pixels(of: ramp, on: node, in: region, sx: CGFloat(picture.width) / region.width, sy: height / region.height, height: height)
            return blurred(picture, sigma: blur.radius * scale, from: from, to: to, clamp: true, deep: deep)
        }
        guard let made else { return nil }
        BlurCache.shared.keep(backdrop: node, board: board, scale: scale, region: region, deep: deep, image: made)
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
    static func around(_ options: Options) -> CGRect? {
        guard let screen = options.screen ?? options.visible else { return nil }
        let step = max(screen.width, screen.height) / 4
        guard step > 0, step.isFinite else { return screen }
        let minX = (screen.minX / step - 1).rounded(.down) * step, minY = (screen.minY / step - 1).rounded(.down) * step
        let maxX = (screen.maxX / step + 1).rounded(.up) * step, maxY = (screen.maxY / step + 1).rounded(.up) * step
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Draws into a picture of `region`, given in the context's coordinates, at `scale` pixels to the point.
    /// `exactly` makes it a whole number of pixels that covers just `region`, stretched a hair to
    /// fit, for a picture whose edges are carried on outward: a pixel only partly covered at its
    /// edge would carry on fainter. `deep` as the bitmap it is drawn back into is (`Options.deep`).
    static func offscreen(_ region: CGRect, scale: CGFloat, exactly: Bool = false, deep: Bool = false, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((region.width * scale).rounded(exactly ? .toNearestOrAwayFromZero : .up))
        let h = Int((region.height * scale).rounded(exactly ? .toNearestOrAwayFromZero : .up))
        guard w > 0, h > 0, w * h <= 40_000_000, let c = bitmap(CGSize(width: w, height: h), deep: deep) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: exactly ? CGFloat(w) / region.width : scale, y: exactly ? -CGFloat(h) / region.height : -scale)
        c.translateBy(x: -region.minX, y: -region.minY)
        withFlippedContext(c) { body(c) }
        return c.makeImage()
    }

    /// Blurring in plain sRGB values, as design tools do: in linear light, a blur of black into
    /// white comes out lighter than the eye expects, and does not match what the designs were made with.
    static let imaging = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// A Gaussian blur, measured as a standard deviation in pixels, which is what XD's blur amount is. What lies behind a layer reaches
    /// past the picture's edges, so for a backdrop the edge pixels carry on outward rather than fade.
    private static func blurred(_ image: CGImage, sigma: CGFloat, clamp: Bool, deep: Bool) -> CGImage? {
        let input = CIImage(cgImage: image)
        let source = clamp ? input.clampedToExtent() : input
        let output = source.applyingGaussianBlur(sigma: Double(sigma)).cropped(to: input.extent)
        return picture(of: output, from: input.extent, deep: deep)
    }

    /// What Core Image made, as a picture to draw: with eight bits to a colour, or sixteen where
    /// it is drawn into a deep bitmap (`Options.deep`), which only the Mac's are: this file is
    /// built for Windows and the browser too, whose pictures have eight.
    static func picture(of output: CIImage, from extent: CGRect, deep: Bool) -> CGImage? {
        #if canImport(Metal)
        let format: CIFormat = deep ? .RGBAh : .RGBA8
        #else
        let format = CIFormat.RGBA8
        #endif
        return imaging.createCGImage(output, from: extent, format: format, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The same, growing from none at `from` to `sigma` at `to`, in the picture's pixels counted
    /// from its bottom left as Core Image counts them, and staying as it is past either.
    private static func blurred(_ image: CGImage, sigma: CGFloat, from: CGPoint, to: CGPoint, clamp: Bool, deep: Bool) -> CGImage? {
        guard hypot(to.x - from.x, to.y - from.y) >= 0.5 else { return blurred(image, sigma: sigma, clamp: clamp, deep: deep) }
        let input = CIImage(cgImage: image)
        let source = clamp ? input.clampedToExtent() : input
        let mask = CIFilter.linearGradient()
        mask.point0 = from
        mask.color0 = CIColor(red: 0, green: 0, blue: 0)
        mask.point1 = to
        mask.color1 = CIColor(red: 1, green: 1, blue: 1)
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = source
        blur.mask = mask.outputImage
        blur.radius = Float(sigma)
        guard let output = blur.outputImage?.cropped(to: input.extent) else { return nil }
        return picture(of: output, from: input.extent, deep: deep)
    }

    /// Where a blur's ramp runs in a picture of `region` of the layer's parent, at `sx` and `sy`
    /// pixels to the point, counted from the picture's bottom left.
    private static func pixels(of ramp: BlurRamp, on node: Node, in region: CGRect, sx: CGFloat, sy: CGFloat, height: CGFloat) -> (CGPoint, CGPoint) {
        let t = localTransform(node)
        func at(_ u: CGPoint) -> CGPoint {
            let p = CGPoint(x: u.x * node.frame.width, y: u.y * node.frame.height).applying(t)
            return CGPoint(x: (p.x - region.minX) * sx, y: height - (p.y - region.minY) * sy)
        }
        return (at(ramp.start), at(ramp.end))
    }

    /// How many pixels to the point a blur that grows is made at: as the screen has them, which
    /// its sharp end needs, but no more than keeps the picture to ten million, as many as a
    /// layer seen up close is already cut down to.
    private static func rampScale(_ screen: CGFloat, radius: CGFloat, region: CGRect) -> CGFloat {
        let most = sqrt(10_000_000 / max(region.width * region.height, 1))
        return max(min(screen, most), min(screen, blurPixels / max(radius, 0.001)))
    }

    /// Draws a picture made at `scale` back where it was made, in a context whose y runs down.
    static func place(_ image: CGImage, at origin: CGPoint, scale: CGFloat, in ctx: CGContext) {
        place(image, in: CGRect(origin: origin, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)), ctx)
    }

    /// Draws a picture over `rect`, in a context whose y runs down.
    static func place(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

/// Blurred pictures kept between drawings, with what they were made from, so each is made again
/// only when that changes: the layer, what lies behind it, how close the canvas is, or how much is
/// seen. Layers turned in depth are kept here too, bent into place. Tiles drawn side by side on
/// several threads share them, so all of it is kept behind a lock.
nonisolated final class BlurCache: @unchecked Sendable {
    static let shared = BlurCache()
    private let lock = NSLock()

    private struct Entry {
        let node: Node
        let board: Node?
        /// Where a layer turned in depth was seen from when its picture was made.
        var eye: Eye? = nil
        let scale: CGFloat
        let region: CGRect
        let image: CGImage
        /// Where a picture of a layer turned in depth goes, which is not where it was made.
        var at: CGPoint = .zero
        var used: UInt64 = 0
        var bytes: Int { image.width * image.height * image.bitsPerPixel / 8 }
    }

    /// A picture with sixteen bits to a colour, made for a movie (`Renderer.Options.deep`), is
    /// kept apart from the one the canvas draws with.
    private static func mark(_ deep: Bool) -> String { deep ? "h" : "" }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    /// A large design has many background blurs; the least lately drawn go first.
    private let budget = 192 << 20

    /// A layer may be drawn at two scales by turns, once for its shadow, made apart at fewer
    /// pixels: a picture at each is kept.
    func object(_ node: Node, scale: CGFloat, region: CGRect, deep: Bool = false) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let key = "o\(node.id)@\(scale)" + Self.mark(deep)
        guard let e = entries[key], e.region == region, e.node == node else { return nil }
        touch(key)
        return e.image
    }

    private func touch(_ key: String) {
        clock += 1
        entries[key]?.used = clock
    }

    /// While things settle, what lay behind may have moved on a little; the picture made before
    /// stands in until they are done, wherever it was made for, as long as it covers what is needed
    /// and is blurred as much: a blur being changed itself shows each change at once.
    func backdrop(_ node: Node, board: Node, scale: CGFloat, region: CGRect, deep: Bool = false, settling: Bool = false) -> (image: CGImage, region: CGRect)? {
        lock.lock()
        defer { lock.unlock() }
        let key = "b\(node.id)@\(scale)" + Self.mark(deep)
        guard let e = entries[key] else { return nil }
        let stands = e.region.contains(region) && e.node.blur?.radius == node.blur?.radius && e.node.blur?.ramp == node.blur?.ramp
        guard settling ? stands : e.region == region && e.board == board else { return nil }
        touch(key)
        return (e.image, e.region)
    }

    /// A layer turned in depth: as it shows, or, `casting`, as it is drawn to cast its shadow at fewer pixels.
    func depth(_ node: Node, scale: CGFloat, region: CGRect, casting: Bool, eye: Eye?, deep: Bool = false) -> (image: CGImage, at: CGPoint)? {
        lock.lock()
        defer { lock.unlock() }
        let key = (casting ? "c" : "d") + "\(node.id)" + Self.mark(deep)
        guard let e = entries[key], e.scale == scale, e.region == region, e.node == node, e.eye == eye else { return nil }
        touch(key)
        return (e.image, e.at)
    }

    func keep(depth node: Node, scale: CGFloat, region: CGRect, casting: Bool, eye: Eye?, deep: Bool = false, image: CGImage, at: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        store((casting ? "c" : "d") + "\(node.id)" + Self.mark(deep), Entry(node: node, board: nil, eye: eye, scale: scale, region: region, image: image, at: at))
    }

    func keep(object node: Node, scale: CGFloat, region: CGRect, deep: Bool = false, image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        store("o\(node.id)@\(scale)" + Self.mark(deep), Entry(node: node, board: nil, scale: scale, region: region, image: image))
    }

    func keep(backdrop node: Node, board: Node, scale: CGFloat, region: CGRect, deep: Bool = false, image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        store("b\(node.id)@\(scale)" + Self.mark(deep), Entry(node: node, board: board, scale: scale, region: region, image: image))
    }

    /// Lets go of the pictures that show a picture, which may have been drawn at another size for
    /// the time being: those of a layer that holds it, and of what lies behind on an artboard that does.
    func forget(showing picture: String) {
        lock.lock()
        defer { lock.unlock() }
        for (key, e) in entries where e.node.shows(picture: picture) || e.board?.shows(picture: picture) == true {
            entries[key] = nil
            bytes -= e.bytes
        }
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
