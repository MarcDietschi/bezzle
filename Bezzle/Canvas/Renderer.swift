import AppKit

/// Draws a design with Core Graphics: the same code paints the canvas, the thumbnails on the
/// home screen and every export, so all three agree to the point.
///
/// Drawing happens in canvas points with y pointing down, in a context whose current
/// `NSGraphicsContext` is flipped (text needs it).
enum Renderer {
    struct Options {
        /// Layers drawn by someone else for now, such as a text being typed into.
        var skipping: Set<UUID> = []
        /// The soft shadow under each artboard, on the canvas only.
        var artboardShadows = false
        /// Canvas points to device pixels, for effects that are measured on screen.
        var deviceScale: CGFloat = 1
        /// What part of the canvas will be seen; everything else is left out.
        var visible: CGRect?
        /// What part of the canvas is on screen, when only a piece of it is being drawn, such as one tile.
        var screen: CGRect?
        /// Where the design's pictures come from.
        var assets: Assets?
        /// The artboard being drawn, and where the layers being drawn sit in it, for background
        /// blurs, which draw what lies behind them again.
        var board: Node?
        var offset: CGPoint = .zero
        /// Ends the drawing just before this layer.
        var halt: Halt?
        /// A preview is easing into place: background blurs keep showing what lay behind them
        /// when it began, and are made again once it settles, rather than on every frame.
        var settling = false
    }

    static func draw(_ doc: BezzleDocument, in ctx: CGContext, options: Options = Options()) {
        for node in doc.nodes where !node.hidden {
            if let visible = options.visible, !Geometry.bounds(of: node).insetBy(dx: -40, dy: -40).intersects(visible) { continue }
            if node.isArtboard {
                drawArtboard(node, in: ctx, options: options)
            } else {
                drawNode(node, in: ctx, options: options)
            }
        }
    }

    static func drawArtboard(_ board: Node, in ctx: CGContext, options: Options, background: Bool = true) {
        let rect = board.frame
        if background {
            ctx.saveGState()
            // The shadow only shows past the artboard's edges, so well inside them there is none
            // to work out; it reaches about 24 pixels on screen, whatever the zoom.
            let s = options.deviceScale, reach = 24 * s / pixelScale(ctx)
            let shadowed = options.artboardShadows && options.visible.map { !rect.insetBy(dx: reach, dy: reach).contains($0) } != false
            if shadowed {
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 10 * s,
                              color: CanvasInk.shadow.withAlphaComponent(0.13).cgColor)
                // In a layer of its own, the shadow is worked out from as much of the artboard as
                // reaches what is drawn, even when only part of it is being drawn.
                let near = options.visible.map { rect.intersection($0.insetBy(dx: -reach, dy: -reach)) } ?? rect
                ctx.beginTransparencyLayer(in: near.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
            }
            if board.fill.on, board.fill.gradient != nil || board.fill.image != nil {
                ctx.setFillColor(CGColor.white)
                ctx.fill(rect)
                ctx.translateBy(x: rect.minX, y: rect.minY)
                paint(board.fill, in: CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), size: rect.size,
                      evenOdd: false, in: ctx, options: options)
            } else {
                ctx.setFillColor(board.fill.on ? board.fill.color.cgColor : CGColor.white)
                ctx.fill(rect)
            }
            if shadowed { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
        ctx.saveGState()
        if board.clips { ctx.clip(to: rect) }
        ctx.translateBy(x: rect.minX, y: rect.minY)
        var inner = options
        inner.board = board
        inner.offset = .zero
        for child in board.children where !child.hidden && inSight(child, inner) {
            drawNode(child, in: ctx, options: inner)
        }
        ctx.restoreGState()
    }

    /// The outline of a shape in its own coordinates, its frame's top left at zero.
    static func outline(of node: Node) -> CGPath {
        let r = CGRect(origin: .zero, size: node.frame.size)
        switch node.kind {
        case .ellipse:
            return CGPath(ellipseIn: r, transform: nil)
        case .rectangle, .artboard, .text, .group:
            if node.kind == .rectangle, let smoothing = node.cornerSmoothing, smoothing > 0 {
                return Squircle.path(in: r, corners: node.corners.flatMap { $0.count == 4 ? $0 : nil } ?? Array(repeating: node.cornerRadius, count: 4),
                                     smoothing: smoothing)
            }
            if let corners = node.corners, corners.count == 4, node.kind == .rectangle { return roundedRect(r, corners: corners) }
            let radius = node.kind == .rectangle ? min(max(node.cornerRadius, 0), min(r.width, r.height) / 2) : 0
            return radius > 0 ? CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGPath(rect: r, transform: nil)
        case .path:
            guard let data = node.path else { return CGPath(rect: r, transform: nil) }
            let shape = parsed(data)
            let box = node.pathBox ?? shape.boundingBoxOfPath
            // The path's own box is drawn to fill the frame, so resizing the layer stretches it.
            var t = CGAffineTransform(scaleX: box.width > 0 ? r.width / box.width : 1, y: box.height > 0 ? r.height / box.height : 1)
                .translatedBy(x: -box.minX, y: -box.minY)
            return shape.copy(using: &t) ?? shape
        case .line:
            let p = CGMutablePath()
            if node.rising {
                p.move(to: CGPoint(x: 0, y: r.height)); p.addLine(to: CGPoint(x: r.width, y: 0))
            } else {
                p.move(to: .zero); p.addLine(to: CGPoint(x: r.width, y: r.height))
            }
            return p
        }
    }

    /// A rectangle whose corners are each rounded their own way: top left, top right, bottom right, bottom left.
    static func roundedRect(_ r: CGRect, corners: [CGFloat]) -> CGPath {
        let most = min(r.width, r.height) / 2
        let tl = min(max(corners[0], 0), most), tr = min(max(corners[1], 0), most)
        let br = min(max(corners[2], 0), most), bl = min(max(corners[3], 0), most)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
        p.closeSubpath()
        return p
    }

    private static var parsedPaths: [String: CGPath] = [:]

    /// Path data read once and kept, as the same outlines are drawn over and over.
    private static func parsed(_ data: String) -> CGPath {
        if let path = parsedPaths[data] { return path }
        let path = PathData.cgPath(data)
        if parsedPaths.count > 4000 { parsedPaths.removeAll() }
        parsedPaths[data] = path
        return path
    }

    /// A layer's outline placed in its parent's coordinates: moved to its frame and turned with it.
    static func placedOutline(of node: Node) -> CGPath {
        var t = CGAffineTransform(translationX: node.frame.midX, y: node.frame.midY)
            .rotated(by: Geometry.radians(node.rotation))
            .translatedBy(x: -node.frame.width / 2, y: -node.frame.height / 2)
        let path = outline(of: node)
        return path.copy(using: &t) ?? path
    }

    static func drawNode(_ node: Node, in ctx: CGContext, options: Options) {
        if let halt = options.halt {
            if node.id == halt.before { halt.reached = true }
            if halt.reached { return }
        }
        guard !options.skipping.contains(node.id), node.opacity > 0 else { return }
        if let blur = node.blur, blur.on, !blur.background, blur.radius > 0 {
            drawBlurred(node, radius: blur.radius, in: ctx, options: options)
            return
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // The shadow falls the same way however the layer is turned: the light is above the page.
        if node.shadow.on {
            setShadow(node.shadow, in: ctx)
        }
        ctx.translateBy(x: node.frame.midX, y: node.frame.midY)
        if node.rotation != 0 { ctx.rotate(by: Geometry.radians(node.rotation)) }
        ctx.translateBy(x: -node.frame.width / 2, y: -node.frame.height / 2)

        // One layer for the whole of it, so a fill and its border fade and cast a shadow together.
        let grouped = node.opacity < 1 || node.shadow.on || node.blend != nil
        if node.opacity < 1 { ctx.setAlpha(node.opacity) }
        if let blend = node.blend { ctx.setBlendMode(blend.cg) }
        // Only as big as the layer: left to itself, the layer is as big as everything in sight,
        // and its shadow is blurred all over that.
        if grouped { ctx.beginTransparencyLayer(in: ink(of: node).insetBy(dx: -1, dy: -1), auxiliaryInfo: nil) }

        switch node.kind {
        case .text:
            drawText(node, in: ctx)
        case .line:
            stroke(outline(of: node), border: node.border, in: ctx, closed: false)
        case .group:
            if let mask = node.mask?.first {
                ctx.addPath(placedOutline(of: mask))
                ctx.clip()
            }
            var inner = options
            inner.offset = CGPoint(x: options.offset.x + node.frame.minX, y: options.offset.y + node.frame.minY)
            for child in node.children where !child.hidden && inSight(child, inner) {
                drawNode(child, in: ctx, options: inner)
            }
        default:
            let path = outline(of: node)
            let evenOdd = node.evenOdd == true
            if let blur = node.blur, blur.on, blur.background {
                // What lies behind, blurred and lightened or darkened, and the layer's own fill
                // over it only as much as it shows over a blur.
                drawBackdrop(node, blur: blur, outline: path, evenOdd: evenOdd, in: ctx, options: options)
                ctx.saveGState()
                ctx.setAlpha(blur.fillOpacity)
                paint(node.fill, in: path, size: node.frame.size, evenOdd: evenOdd, in: ctx, options: options)
                ctx.restoreGState()
            } else {
                paint(node.fill, in: path, size: node.frame.size, evenOdd: evenOdd, in: ctx, options: options)
            }
            stroke(path, border: node.border, in: ctx, closed: node.kind != .path || isClosed(path))
        }

        if grouped { ctx.endTransparencyLayer() }
    }

    /// A fill inside an outline: a colour, a gradient stretched to the layer, or a picture.
    static func paint(_ fill: Fill, in path: CGPath, size: CGSize, evenOdd: Bool, in ctx: CGContext, options: Options) {
        guard fill.on else { return }
        let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
        if let image = fill.image {
            // Read at about the size it is drawn, not the size it was shot at.
            let drawn = imageRect(image, in: size)
            let pixels = max(drawn.width, drawn.height) * Renderer.pixelScale(ctx)
            guard let picture = options.assets?.image(image.asset, pixels: pixels) else {
                // A picture that is missing shows as a quiet grey, so its place stays visible.
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
                ctx.fillPath(using: rule)
                return
            }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule)
            let rect = drawn
            ctx.interpolationQuality = .high
            // Upright, or turned over where it lies when its layer was flipped.
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: image.flippedX == true ? -1 : 1, y: image.flippedY == true ? 1 : -1)
            ctx.draw(picture, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            ctx.restoreGState()
            return
        }
        if let g = fill.gradient, !g.stops.isEmpty,
           let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: g.stops.map(\.color.cgColor) as CFArray,
                                     locations: g.stops.map { CGFloat($0.offset) }) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule)
            switch g.kind {
            case .linear:
                ctx.drawLinearGradient(gradient, start: CGPoint(x: g.start.x * size.width, y: g.start.y * size.height),
                                       end: CGPoint(x: g.end.x * size.width, y: g.end.y * size.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial:
                let spread = g.spread(in: size)
                if abs(spread.a * spread.d - spread.b * spread.c) > 1e-6 {
                    ctx.concatenate(spread)
                    ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                                           options: [.drawsAfterEndLocation])
                } else if let last = g.stops.max(by: { $0.offset < $1.offset }) {
                    // Spread to nothing, it is all its last colour.
                    ctx.setFillColor(last.color.cgColor)
                    ctx.addPath(path)
                    ctx.fillPath(using: rule)
                }
            }
            ctx.restoreGState()
            return
        }
        ctx.addPath(path)
        ctx.setFillColor(fill.color.cgColor)
        ctx.fillPath(using: rule)
    }

    /// Where a picture is drawn in a layer of `size`: covering it, fitting in it, or squeezed to it.
    static func imageRect(_ image: ImageFill, in size: CGSize) -> CGRect {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let scale: CGFloat
        switch image.mode {
        case .stretch: return CGRect(origin: .zero, size: size)
        case .cover: scale = max(size.width / w, size.height / h) * max(image.scale, 0.01)
        case .fit: scale = min(size.width / w, size.height / h) * max(image.scale, 0.01)
        }
        let drawn = CGSize(width: w * scale, height: h * scale)
        return CGRect(x: (size.width - drawn.width) / 2 + image.offset.x * size.width,
                      y: (size.height - drawn.height) / 2 + image.offset.y * size.height,
                      width: drawn.width, height: drawn.height)
    }

    private static func isClosed(_ path: CGPath) -> Bool {
        var closed = false
        path.applyWithBlock { if $0.pointee.type == .closeSubpath { closed = true } }
        return closed
    }

    private static func drawText(_ node: Node, in ctx: CGContext) {
        let laid = TextLayout.layout(node)
        let previous = NSGraphicsContext.current
        if previous?.cgContext !== ctx {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        }
        laid.draw(at: .zero)
        NSGraphicsContext.current = previous
    }

    private static func stroke(_ path: CGPath, border: Border, in ctx: CGContext, closed: Bool) {
        guard border.on, border.width > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        var width = border.width
        if closed && border.position != .center {
            width *= 2
            ctx.addPath(path)
            if border.position == .outside {
                ctx.addRect(path.boundingBox.insetBy(dx: -width * 2 - 4, dy: -width * 2 - 4))
                ctx.clip(using: .evenOdd)
            } else {
                ctx.clip()
            }
        }
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(border.color.cgColor)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(closed ? .butt : (border.dash > 0 ? .butt : .round))
        if border.dash > 0 {
            ctx.setLineDash(phase: 0, lengths: [border.dash * (closed && border.position != .center ? 1 : 1), max(border.gap, 0.5)])
        }
        ctx.strokePath()
    }

    /// Core Graphics measures shadows in the context's base space (pixels, y up), whatever the
    /// drawing's scale; this turns a shadow measured in canvas points into those.
    static func setShadow(_ shadow: Shadow, in ctx: CGContext) {
        let t = ctx.ctm
        var offset = CGSize(width: shadow.x, height: shadow.y).applying(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
        // Drawing a picture, the turn from y up to Bezzle's y down is in the CTM, and the line
        // above undoes it. On screen the canvas's layer keeps that turn below the CTM, so the CTM
        // looks unflipped and a shadow meant to fall would rise; it is undone here instead.
        if t.a * t.d - t.b * t.c > 0 { offset.height = -offset.height }
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        ctx.setShadow(offset: offset, blur: shadow.blur * scale, color: shadow.color.cgColor)
    }

    // MARK: Pictures of a design

    /// One artboard as a picture, `scale` pixels to the point; or only `part` of it, on the
    /// canvas, such as one slide of a carousel.
    static func image(of board: Node, part: CGRect? = nil, scale: CGFloat, opaque: Bool = true, assets: Assets? = nil) -> CGImage? {
        let rect = part ?? board.frame
        let size = CGSize(width: max(1, (rect.width * scale).rounded()), height: max(1, (rect.height * scale).rounded()))
        guard let ctx = bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        withFlippedContext(ctx) {
            var b = board
            if !opaque && !board.fill.on { b.fill.color = b.fill.color.with(alpha: 0) }
            var options = Options(deviceScale: scale, assets: assets)
            // What lies wholly outside the part is left out.
            options.visible = part
            drawArtboard(b, in: ctx, options: options)
        }
        return ctx.makeImage()
    }

    /// The whole design fitted into `size` points, for the home screen.
    static func thumbnail(of doc: BezzleDocument, size: CGSize, scale: CGFloat = 2, assets: Assets? = nil) -> CGImage? {
        guard let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 else { return nil }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        guard let ctx = bitmap(px) else { return nil }
        let fit = min(size.width / bounds.width, size.height / bounds.height) * 0.86
        ctx.translateBy(x: 0, y: px.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: fit, y: fit)
        ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        withFlippedContext(ctx) {
            var options = Options(deviceScale: scale * fit, assets: assets)
            options.artboardShadows = true
            draw(doc, in: ctx, options: options)
        }
        return ctx.makeImage()
    }

    /// One artboard as a page of a PDF, in points; or only `part` of it, on the canvas, such as
    /// one slide of a carousel.
    static func drawPDFPage(_ board: Node, part: CGRect? = nil, in ctx: CGContext, assets: Assets? = nil) {
        let rect = part ?? board.frame
        var box = CGRect(origin: .zero, size: rect.size)
        ctx.beginPage(mediaBox: &box)
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        var options = Options(assets: assets)
        if let part {
            // The rest of the artboard stays off the page, and out of the file.
            ctx.clip(to: part)
            options.visible = part
        }
        withFlippedContext(ctx) { drawArtboard(board, in: ctx, options: options) }
        ctx.endPage()
    }

    static func bitmap(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func withFlippedContext(_ ctx: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }
}
