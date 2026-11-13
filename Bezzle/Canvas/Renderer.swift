import AppKit

/// Draws a design with Core Graphics: the same code paints the canvas, the thumbnails on the
/// home screen and every export, so all three agree to the point.
///
/// Drawing happens in canvas points with y pointing down, in a context whose current
/// `NSGraphicsContext` is flipped (text needs it).
///
/// Not tied to the main thread: the canvas draws its tiles on several threads at once, so all it
/// keeps between drawings is behind a lock, and what it needs from the window comes in `Options`.
nonisolated enum Renderer {
    struct Options {
        /// Layers drawn by someone else for now, such as a text being typed into.
        var skipping: Set<UUID> = []
        /// The soft shadow under each artboard, on the canvas only.
        var artboardShadows = false
        /// Its colour, light or dark as the canvas is; worked out on the main thread, which knows.
        var artboardShadowInk: RGBA?
        /// Canvas points to device pixels, for effects that are measured on screen.
        var deviceScale: CGFloat = 1
        /// What part of the canvas will be seen; everything else is left out.
        var visible: CGRect?
        /// What part of the canvas is on screen, when only a piece of it is being drawn, such as one tile.
        var screen: CGRect?
        /// Where the design's pictures come from.
        var assets: Assets?
        /// A picture wanted at a size not yet read may be drawn at another for now, on the canvas,
        /// which draws again once it is read. See `Assets.image(_:pixels:later:)`.
        var picturesLater = false
        /// The artboard being drawn, and where the layers being drawn sit in it, for background
        /// blurs, which draw what lies behind them again.
        var board: Node?
        var offset: CGPoint = .zero
        /// Ends the drawing just before this layer.
        var halt: Halt?
        /// A preview is easing into place: background blurs keep showing what lay behind them
        /// when it began, and are made again once it settles, rather than on every frame.
        var settling = false
        /// Drawing a layer only for the shadow it casts: what it holds casts its own shadows as
        /// Core Graphics makes them, rather than apart. See `drawShadowApart`.
        var castingShadow = false
        /// The moment of an Animate film being drawn, in seconds from its start: a shader is drawn
        /// as it is then. As the design shows it when nil.
        var time: Double?
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
        // A deck shows one post at a time: its first, unless the canvas narrowed it to another.
        let board = board.shownAlone
        let rect = board.frame
        if background {
            ctx.saveGState()
            // The shadow only shows past the artboard's edges, so well inside them there is none
            // to work out; it reaches about 24 pixels on screen, whatever the zoom.
            let s = options.deviceScale, reach = 24 * s / pixelScale(ctx)
            let shadowed = options.artboardShadows && options.visible.map { !rect.insetBy(dx: reach, dy: reach).contains($0) } != false
            if shadowed {
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 10 * s, color: artboardShadow(options))
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

    /// The colour of the shadow under artboards: as given, or as the canvas's ink has it in the
    /// appearance being drawn in, which only the main thread knows, or the light one.
    private static func artboardShadow(_ options: Options) -> CGColor {
        if let ink = options.artboardShadowInk { return ink.with(alpha: 0.13).cgColor }
        guard Thread.isMainThread else { return RGBA(r: 0x3A / 255, g: 0x32 / 255, b: 0x26 / 255, a: 0.13).cgColor }
        return MainActor.assumeIsolated { CanvasInk.shadow.withAlphaComponent(0.13).cgColor }
    }

    private static let parsedPaths = Shared([String: CGPath]())

    /// Path data read once and kept, as the same outlines are drawn over and over.
    private static func parsed(_ data: String) -> CGPath {
        if let path = parsedPaths.with({ $0[data] }) { return path }
        let path = PathData.cgPath(data)
        parsedPaths.with {
            if $0.count > 4000 { $0.removeAll() }
            $0[data] = path
        }
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

    /// The outline a mask's shape cuts off what it holds at, in the mask: where the shape shows,
    /// turned in the page and in depth.
    static func heldOutline(of holder: Node) -> CGPath {
        let flat = placedOutline(of: holder)
        return Perspective(holder)?.shown(flat) ?? flat
    }

    static func drawNode(_ node: Node, in ctx: CGContext, options: Options) {
        if let halt = options.halt {
            if node.id == halt.before { halt.reached = true }
            if halt.reached { return }
        }
        guard !options.skipping.contains(node.id), node.opacity > 0 else { return }
        if let perspective = Perspective(node) {
            drawInDepth(node, perspective, in: ctx, options: options)
            return
        }
        if let blur = node.blur, blur.on, !blur.background, blur.radius > 0 {
            drawBlurred(node, radius: blur.radius, in: ctx, options: options)
            return
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // The shadow falls the same way however the layer is turned: the light is above the page.
        // One shadow is cast by the layer as it is drawn. Several, or one spread, are each cast
        // on their own first, and the layer is drawn over them.
        let outer = node.outerShadows, inner = node.innerShadows
        if outer.count == 1, !spreads(node, outer[0]) || options.castingShadow {
            if !drawShadowApart(node, outer[0], in: ctx, options: options) { setShadow(outer[0], in: ctx) }
        } else {
            for shadow in outer { drawShadowAlone(node, shadow, in: ctx, options: options) }
        }
        ctx.translateBy(x: node.frame.midX, y: node.frame.midY)
        if node.rotation != 0 { ctx.rotate(by: Geometry.radians(node.rotation)) }
        ctx.translateBy(x: -node.frame.width / 2, y: -node.frame.height / 2)

        // One layer for the whole of it, so a fill and its border fade and cast a shadow together,
        // and a shadow inside falls on the layer alone.
        let grouped = node.opacity < 1 || !outer.isEmpty || !inner.isEmpty || node.blend != nil
        if node.opacity < 1 { ctx.setAlpha(node.opacity) }
        if let blend = node.blend { ctx.setBlendMode(blend.cg) }
        // Only as big as the layer: left to itself, the layer is as big as everything in sight,
        // and its shadow is blurred all over that. A shadow inside is cast from around the
        // layer, so that much room is kept round it.
        let around = inner.map(innerReach).max() ?? 0
        if grouped { ctx.beginTransparencyLayer(in: ink(of: node).insetBy(dx: -1 - around, dy: -1 - around), auxiliaryInfo: nil) }

        switch node.kind {
        case .text:
            drawText(node, in: ctx, options: options)
            for shadow in inner { drawInnerShadow(shadow, of: node, in: ctx, options: options) { drawText(node, in: ctx, options: options) } }
        case .line:
            for border in node.borders { stroke(outline(of: node), border: border, size: node.frame.size, in: ctx, closed: false, options: options) }
        case .group:
            drawChildren(of: node, in: ctx, options: options)
            for shadow in inner { drawInnerShadow(shadow, of: node, in: ctx, options: options) { drawChildren(of: node, in: ctx, options: options) } }
        default:
            let path = outline(of: node)
            let evenOdd = node.evenOdd == true
            if let blur = node.blur, blur.on, blur.background {
                // What lies behind, blurred and lightened or darkened, and the layer's own fills
                // over it, together only as much as they show over a blur.
                drawBackdrop(node, blur: blur, outline: path, evenOdd: evenOdd, in: ctx, options: options)
                ctx.saveGState()
                ctx.setAlpha(blur.fillOpacity)
                let several = node.fills.count > 1
                if several { ctx.beginTransparencyLayer(in: path.boundingBoxOfPath.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil) }
                paintFills(of: node, in: path, evenOdd: evenOdd, in: ctx, options: options)
                if several { ctx.endTransparencyLayer() }
                ctx.restoreGState()
            } else {
                paintFills(of: node, in: path, evenOdd: evenOdd, in: ctx, options: options)
            }
            // Over the fills and under the borders, as a hollow lies inside its rim.
            for shadow in inner { drawInnerShadow(shadow, of: node, outline: path, evenOdd: evenOdd, in: ctx) }
            // Round a cut-out picture's subject, as a sticker's edge, rather than its frame.
            let borders = node.borders
            if !borders.isEmpty {
                let silhouette = node.silhouette
                let closed = silhouette != nil || node.kind != .path || isClosed(path)
                for border in borders {
                    if let silhouette {
                        stroke(silhouette, border: border, size: node.frame.size, in: ctx, closed: true, rule: .evenOdd, options: options)
                    } else {
                        stroke(path, border: border, size: node.frame.size, in: ctx, closed: closed, options: options)
                    }
                }
            }
        }

        if grouped { ctx.endTransparencyLayer() }
    }

    /// A shape's fills one over another inside its outline. Over a cut-out picture, those above it
    /// colour its subject alone, as it is all that shows of the picture.
    private static func paintFills(of node: Node, in path: CGPath, evenOdd: Bool, in ctx: CGContext, options: Options) {
        let fills = node.fills
        guard let first = fills.first else { return }
        paint(first, in: path, size: node.frame.size, evenOdd: evenOdd, in: ctx, options: options)
        guard fills.count > 1 else { return }
        let subject = node.silhouette
        for fill in fills.dropFirst() {
            paint(fill, in: subject ?? path, size: node.frame.size, evenOdd: subject != nil || evenOdd, in: ctx, options: options)
        }
    }

    /// What a group holds, cut to its mask.
    private static func drawChildren(of group: Node, in ctx: CGContext, options: Options) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let mask = group.mask?.first {
            ctx.addPath(placedOutline(of: mask))
            ctx.clip()
        }
        var inner = options
        inner.offset = CGPoint(x: options.offset.x + group.frame.minX, y: options.offset.y + group.frame.minY)
        if let holder = group.holder, group.children.count > 1 {
            drawHeld(by: holder, group.children.dropFirst(), in: ctx, options: inner)
            return
        }
        for child in group.children where !child.hidden && inSight(child, inner) {
            drawNode(child, in: ctx, options: inner)
        }
    }

    /// A shape holding layers, as it holds a picture (see `Mask`): its fill and the shadow it casts
    /// under them, they cut off at its outline, and its border and any shadow pressed into it over
    /// them, as a frame and a hollow are.
    private static func drawHeld(by holder: Node, _ held: ArraySlice<Node>, in ctx: CGContext, options: Options) {
        let shows = !holder.hidden && inSight(holder, options)
        if shows {
            var under = holder
            under.borders = []
            under.shadows = holder.outerShadows
            drawNode(under, in: ctx, options: options)
        }
        ctx.saveGState()
        ctx.addPath(heldOutline(of: holder))
        ctx.clip(using: holder.evenOdd == true ? .evenOdd : .winding)
        for child in held where !child.hidden && inSight(child, options) {
            drawNode(child, in: ctx, options: options)
        }
        ctx.restoreGState()
        guard shows, !holder.borders.isEmpty || !holder.innerShadows.isEmpty else { return }
        var over = holder
        over.fills = []
        over.blur = nil
        over.shadows = holder.innerShadows
        drawNode(over, in: ctx, options: options)
    }

    /// A fill inside an outline: a colour, a gradient stretched to the layer, or a picture. The
    /// picture is placed in the layer's frame, a layer of `size` with its top left at zero, or in
    /// `pictureBox` where it is placed in another, as a border's is in all it may reach.
    static func paint(_ fill: Fill, in path: CGPath, size: CGSize, evenOdd: Bool, in ctx: CGContext, options: Options, pictureBox: CGRect? = nil) {
        guard fill.on else { return }
        let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
        // A shader draws itself, at the film's moment, where its picture would lie; the picture
        // stands in where it cannot.
        if let shader = fill.shader,
           ShaderPainting.paint(shader, picture: fill.image, in: path, size: size, rule: rule, in: ctx, film: options.time, assets: options.assets, box: pictureBox) {
            return
        }
        if let image = fill.image {
            // Read at about the size it is drawn, not the size it was shot at.
            let box = pictureBox ?? CGRect(origin: .zero, size: size)
            let drawn = imageRect(image, in: box.size).offsetBy(dx: box.minX, dy: box.minY)
            let pixels = max(drawn.width, drawn.height) * Renderer.pixelScale(ctx)
            // Cut out, it casts its shadow from its subject alone, as that is all that is drawn.
            // A cutout someone sharing the design made shows the picture as it was until it comes.
            guard let picture = options.assets.flatMap({ assets in
                assets.image(image.shown, pixels: pixels, later: options.picturesLater)
                    ?? (image.cutout != nil ? assets.image(image.asset, pixels: pixels, later: options.picturesLater) : nil)
            }).map({ Developer.developed($0, image.develop) }) else {
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
        // Into a PDF, Core Graphics writes a gradient's colours but not how see-through they are,
        // so see-through ones are drawn whole through a mask of that.
        let masked = ctx.width == 0 && fill.gradient?.stops.contains { $0.color.a < 0.999 } == true
        if let g = fill.gradient, !g.stops.isEmpty,
           let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: g.stops.map { (masked ? $0.color.with(alpha: 1) : $0.color).cgColor } as CFArray,
                                     locations: g.stops.map { CGFloat($0.offset) }) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule)
            if masked { clipToTransparency(of: g, size: size, covering: path.boundingBoxOfPath, in: ctx) }
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

    /// Clips to how see-through a gradient is across `box` of a layer of `size`: a picture of it,
    /// a strip along a linear gradient or a square over a radial one, fine enough not to show its
    /// steps, and as it is past either end.
    private static func clipToTransparency(of g: Gradient, size: CGSize, covering box: CGRect, in ctx: CGContext) {
        let stops = g.stops.sorted { $0.offset < $1.offset }
        func alpha(_ t: Double) -> Double {
            guard let first = stops.first, let last = stops.last else { return 1 }
            if t <= first.offset { return first.color.a }
            if t >= last.offset { return last.color.a }
            for (a, b) in zip(stops, stops.dropFirst()) where t <= b.offset {
                let span = b.offset - a.offset
                return a.color.a + (b.color.a - a.color.a) * (span > 0 ? (t - a.offset) / span : 0)
            }
            return last.color.a
        }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let place: CGAffineTransform
        let width: Int, height: Int
        var levels: [UInt8]
        switch g.kind {
        case .linear:
            let s = CGPoint(x: g.start.x * size.width, y: g.start.y * size.height)
            let dx = (g.end.x - g.start.x) * size.width, dy = (g.end.y - g.start.y) * size.height
            let length = hypot(dx, dy)
            guard length > 0.001 else { return }
            let u = CGVector(dx: dx / length, dy: dy / length), v = CGVector(dx: -u.dy, dy: u.dx)
            let along = corners.map { (($0.x - s.x) * u.dx + ($0.y - s.y) * u.dy) / length }
            let across = corners.map { ($0.x - s.x) * v.dx + ($0.y - s.y) * v.dy }
            let t0 = along.min()!, t1 = along.max()!, w0 = across.min()!, w1 = across.max()!
            width = 1024
            height = 1
            levels = (0..<width).map { k in UInt8((alpha(Double(t0 + (CGFloat(k) + 0.5) / CGFloat(width) * (t1 - t0))) * 255).rounded()) }
            let run = length * (t1 - t0), wide = max(w1 - w0, 1)
            place = CGAffineTransform(a: u.dx * run, b: u.dy * run, c: v.dx * wide, d: v.dy * wide,
                                      tx: s.x + u.dx * length * t0 + v.dx * w0, ty: s.y + u.dy * length * t0 + v.dy * w0)
        case .radial:
            let spread = g.spread(in: size)
            guard abs(spread.a * spread.d - spread.b * spread.c) > 1e-6 else { return }
            let back = spread.inverted()
            let reach = max(corners.map { $0.applying(back) }.map { max(abs($0.x), abs($0.y)) }.max() ?? 1, 1)
            width = 384
            height = 384
            levels = []
            levels.reserveCapacity(width * height)
            for j in 0..<height {
                for i in 0..<width {
                    let x = -reach + (CGFloat(i) + 0.5) / CGFloat(width) * reach * 2, y = -reach + (CGFloat(j) + 0.5) / CGFloat(height) * reach * 2
                    levels.append(UInt8((alpha(Double(min(hypot(x, y), 1))) * 255).rounded()))
                }
            }
            place = CGAffineTransform(a: reach * 2, b: 0, c: 0, d: reach * 2, tx: -reach, ty: -reach).concatenating(spread)
        }
        guard let provider = CGDataProvider(data: Data(levels) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.concatenate(place)
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1), mask: mask)
        ctx.concatenate(place.inverted())
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

    private static func drawText(_ node: Node, in ctx: CGContext, options: Options) {
        if let curved = CurvedText.laid(node) {
            CurvedText.draw(curved, in: ctx, painting: letterPaint(of: node, options: options))
            return
        }
        let laid = TextLayout.layout(node)
        let previous = NSGraphicsContext.current
        if previous?.cgContext !== ctx {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        }
        // A box of fixed size too small for its lines hides what is past its top and bottom.
        let hides = node.overflows
        if hides {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -node.frame.width, y: 0, width: node.frame.width * 3, height: node.frame.height))
        }
        laid.draw(at: CGPoint(x: 0, y: TextLayout.offset(node)), painting: letterPaint(of: node, options: options))
        if hides { ctx.restoreGState() }
        NSGraphicsContext.current = previous
    }

    /// What paints a text's letters when it is filled with a gradient or a picture rather than a
    /// colour: the fill laid over all that is being drawn, placed in the layer's own coordinates,
    /// its frame's top left `down` points above where the text is drawn. Letters of a colour of
    /// their own keep it. Nil for a text of one colour.
    static func letterPaint(of node: Node, options: Options, down: CGFloat = 0) -> ((CGContext) -> Void)? {
        let fill = node.fill, size = node.frame.size
        guard node.kind == .text, fill.on, fill.paints else { return nil }
        return { ctx in
            if down != 0 { ctx.translateBy(x: 0, y: -down) }
            paint(fill, in: CGPath(rect: ctx.boundingBoxOfClipPath, transform: nil), size: size, evenOdd: false, in: ctx, options: options)
        }
    }

    /// A border along an outline, in a layer of `size`: of one colour, or a gradient or picture
    /// painted where it lies.
    private static func stroke(_ path: CGPath, border: Border, size: CGSize, in ctx: CGContext, closed: Bool,
                               rule: CGPathFillRule = .winding, options: Options) {
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
                ctx.clip(using: rule)
            }
        }
        // A subject's outline turns sharply where hair does: rounded, it reads as one edge.
        let join: CGLineJoin = rule == .evenOdd ? .round : .miter
        let cap: CGLineCap = closed ? .butt : (border.dash > 0 ? .butt : .round)
        let dashes = [border.dash, max(border.gap, 0.5)]
        guard border.paints else {
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(border.color.cgColor)
            ctx.setLineJoin(join)
            ctx.setLineCap(cap)
            if border.dash > 0 { ctx.setLineDash(phase: 0, lengths: dashes) }
            ctx.strokePath()
            return
        }
        // What the line covers, filled with the gradient or the picture. The picture covers all
        // the border may reach, past the frame as far as it lies outside, and a line's ends.
        let line = border.dash > 0 ? path.copy(dashingWithPhase: 0, lengths: dashes) : path
        let band = line.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: 10)
        guard !band.isEmpty else { return }
        let reach = closed ? border.reach : border.width / 2
        paint(border.paint, in: band, size: size, evenOdd: false, in: ctx, options: options,
              pictureBox: CGRect(origin: .zero, size: size).insetBy(dx: -reach, dy: -reach))
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

    // MARK: Shadows inside

    /// How far around a layer a shadow inside it is cast from: as far as it falls and spreads.
    static func innerReach(_ shadow: Shadow) -> CGFloat {
        abs(shadow.x) + abs(shadow.y) + shadow.blur * 2 + abs(shadow.grown) + 1
    }

    /// A shadow inside a shape, as if it were pressed into the page: all around the outline is
    /// filled, cut to the inside, and only the shadow that casts in shows. Spread, the hollow it
    /// is cast round is narrower than the shape, and the shadow comes further in. The context is
    /// in the layer's own coordinates.
    private static func drawInnerShadow(_ shadow: Shadow, of node: Node, outline path: CGPath, evenOdd: Bool, in ctx: CGContext) {
        let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
        let reach = innerReach(shadow)
        let box = path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)
        let hollow = shadow.grown != 0 ? spreadOutline(of: node, by: -shadow.grown, subject: false) : nil
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addPath(path)
        ctx.clip(using: rule)
        castInside(shadow, of: node, in: ctx)
        ctx.setFillColor(shadow.color.cgColor)
        // A rectangle's or an ellipse's outline never crosses itself, and one filled even-odd
        // leaves the same hole either way; only a path filled all over is cut out properly.
        if node.kind == .path && !evenOdd {
            ctx.addPath(CGPath(rect: box, transform: nil).subtracting(hollow ?? path, using: rule))
            ctx.fillPath()
        } else {
            ctx.addRect(box)
            ctx.addPath(hollow ?? path)
            ctx.fillPath(using: .evenOdd)
        }
    }

    /// A shadow inside a layer with no outline of its own, text or a group, as if what it draws
    /// were pressed into the page: all around it is filled, what it draws is cut out of that by
    /// drawing it again, and the shadow cast falls on the layer alone. The context is in the
    /// layer's own coordinates, in a transparency layer of its own.
    private static func drawInnerShadow(_ shadow: Shadow, of node: Node, in ctx: CGContext, options: Options, drawing draw: () -> Void) {
        // Stopped partway through, there is not the whole of it to cut out.
        if options.halt?.reached == true { return }
        let reach = innerReach(shadow)
        let box = ink(of: node).insetBy(dx: -reach, dy: -reach)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(.sourceAtop)
        castInside(shadow, of: node, in: ctx)
        ctx.beginTransparencyLayer(in: box, auxiliaryInfo: nil)
        ctx.setFillColor(shadow.color.cgColor)
        ctx.fill(box)
        // Cut out as a whole, however its own parts mix and cast.
        ctx.setBlendMode(.destinationOut)
        ctx.beginTransparencyLayer(in: box, auxiliaryInfo: nil)
        draw()
        ctx.endTransparencyLayer()
        ctx.endTransparencyLayer()
    }

    /// Sets the shadow cast from around a layer into it. What casts it is filled in the shadow's
    /// own colour, so the little of it that shows along the layer's soft edge is shadow too, and
    /// the shadow it casts is no fainter than that colour. Turned back by the layer's own turn, it
    /// falls as the light above the page casts it.
    private static func castInside(_ shadow: Shadow, of node: Node, in ctx: CGContext) {
        var cast = shadow
        cast.color = cast.color.with(alpha: 1)
        let fall = Geometry.rotate(CGPoint(x: cast.x, y: cast.y), by: -node.rotation)
        cast.x = fall.x
        cast.y = fall.y
        setShadow(cast, in: ctx)
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
    static func thumbnail(of doc: BezzleDocument, size: CGSize, scale: CGFloat = 2, assets: Assets? = nil, cover: Bool = false) -> CGImage? {
        guard let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 else { return nil }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        guard let ctx = bitmap(px) else { return nil }
        let place = thumbnailPlacement(of: doc, bounds: bounds, in: size, cover: cover)
        ctx.translateBy(x: 0, y: px.height)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: place.origin.x, y: place.origin.y)
        ctx.scaleBy(x: place.scale, y: place.scale)
        withFlippedContext(ctx) {
            var options = Options(deviceScale: scale * place.scale, assets: assets)
            options.artboardShadows = true
            draw(doc, in: ctx, options: options)
        }
        return ctx.makeImage()
    }

    /// How a design's `bounds` lie in a thumbnail of `size`: at what scale, and where the point at
    /// the design's origin lands, from the top left. The whole design fits, with a margin round
    /// it. With `cover`, it comes in closer, as close as still shows its largest artboard whole,
    /// until it fills the picture; what is left over runs off the right and the bottom, so a long
    /// column of artboards shows its first ones large rather than all of them tiny.
    static func thumbnailPlacement(of doc: BezzleDocument, bounds: CGRect, in size: CGSize, cover: Bool) -> (scale: CGFloat, origin: CGPoint) {
        let margin: CGFloat = 0.86
        let fit = min(size.width / bounds.width, size.height / bounds.height) * margin
        var s = fit
        if cover {
            let fill = max(size.width / bounds.width, size.height / bounds.height) * margin
            let boards = doc.nodes.filter { $0.isArtboard && !$0.hidden }
            let w = boards.map(\.frame.width).max() ?? bounds.width, h = boards.map(\.frame.height).max() ?? bounds.height
            let board = min(size.width / max(w, 1), size.height / max(h, 1)) * margin
            s = max(fit, min(fill, board))
        }
        let inset = min(size.width, size.height) * (1 - margin) / 2
        let w = bounds.width * s, h = bounds.height * s
        let x = w <= size.width - inset * 2 + 0.5 ? (size.width - w) / 2 : inset
        let y = h <= size.height - inset * 2 + 0.5 ? (size.height - h) / 2 : inset
        return (s, CGPoint(x: x - bounds.minX * s, y: y - bounds.minY * s))
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
