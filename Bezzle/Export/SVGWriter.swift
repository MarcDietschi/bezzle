import AppKit

/// A design written as SVG, as close to how it looks as SVG allows, and as SVG has it, so that it
/// stays sharp and can be changed elsewhere: rectangles, ellipses and paths, text that is still
/// text, gradients, borders inside and outside, shadows and blurs as filters, pictures carried
/// in the file. A blur of what lies behind a layer, which SVG cannot do, comes as a picture of
/// what shows through, and a layer turned in depth as a picture of it. Layers keep their names as ids.
nonisolated struct SVGWriter {
    private var defs: [String] = []
    private var ids: Set<String> = []
    private var count = 0
    private let assets: Assets?
    /// Pixels to the point for what has to come as a picture.
    private let pictureScale: CGFloat = 2

    private init(assets: Assets?) {
        self.assets = assets
    }

    /// The whole file for an artboard or a layer, showing `bounds` of the canvas.
    static func document(for item: ExportItem, bounds: CGRect, assets: Assets?) -> String {
        var w = SVGWriter(assets: assets)
        let body: String
        if item.node.isArtboard {
            body = w.artboard(item.node, part: item.slideFrame)
        } else {
            body = "<g transform=\"translate(\(n(item.origin.x)) \(n(item.origin.y)))\">\(w.layer(item.node, item.options(scale: w.pictureScale, assets: assets)))</g>"
        }
        let defs = w.defs.isEmpty ? "" : "<defs>\n\(w.defs.joined(separator: "\n"))\n</defs>\n"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(n(bounds.width))" height="\(n(bounds.height))" viewBox="0 0 \(n(bounds.width)) \(n(bounds.height))">
        \(defs)<g transform="translate(\(n(-bounds.minX)) \(n(-bounds.minY)))">
        \(body)
        </g>
        </svg>

        """
    }

    // MARK: Artboards and layers

    /// An artboard, or only what reaches `part` of it, on the canvas, such as one slide of a carousel.
    private mutating func artboard(_ board: Node, part: CGRect? = nil) -> String {
        // A deck goes out as one post: its first, unless it was narrowed to another.
        let board = board.shownAlone
        let size = board.frame.size
        var out = "<g id=\"\(id(for: board.name))\" transform=\"translate(\(n(board.frame.minX)) \(n(board.frame.minY)))\">\n"
        if board.fill.on {
            let rect = "<rect width=\"\(n(size.width))\" height=\"\(n(size.height))\""
            out += board.fill.image != nil ? picture(board.fill, size: size, geometry: rect, rule: "", alpha: 1) : rect + " \(paint(board.fill, size: size, alpha: 1))/>"
            out += "\n"
        }
        var options = Renderer.Options(deviceScale: pictureScale, assets: assets)
        options.board = board
        options.visible = part
        let inside = board.children.filter { Renderer.inSight($0, options) }.map { layer($0, options) }.joined(separator: "\n")
        if board.clips {
            let clip = newID("clip")
            defs.append("<clipPath id=\"\(clip)\"><rect width=\"\(n(size.width))\" height=\"\(n(size.height))\"/></clipPath>")
            out += "<g clip-path=\"url(#\(clip))\">\n\(inside)\n</g>"
        } else {
            out += inside
        }
        return out + "\n</g>"
    }

    /// A layer in its parent's coordinates. `options` says where it lies on its artboard.
    private mutating func layer(_ node: Node, _ options: Renderer.Options) -> String {
        guard !node.hidden, node.opacity > 0 else { return "" }
        if Perspective(node) != nil { return inDepth(node, options) }
        if let blur = node.blur, blur.on, !blur.background, blur.radius > 0, let ramp = blur.ramp { return growing(node, blur, ramp, options) }
        var attrs = ["id=\"\(id(for: node.name))\""]
        if node.opacity < 1 { attrs.append("opacity=\"\(n(node.opacity))\"") }
        if let blend = node.blend { attrs.append("style=\"mix-blend-mode:\(Self.css(blend))\"") }
        // Shadows spread from a shape's outline are cast apart, under the rest.
        let spread = node.outerShadows.filter { Renderer.spreads(node, $0) }
        let filter = filter(for: node)
        if let filter, spread.isEmpty { attrs.append("filter=\"url(#\(filter))\"") }
        var inner = ""
        // What lies behind, blurred, shows through the outline; the layer's own fill lies over it.
        if let blur = node.blur, blur.on, blur.background, [.rectangle, .ellipse, .path].contains(node.kind),
           let (image, region) = Renderer.backdropPicture(of: node, scale: pictureScale, options: options), let href = Self.dataURI(image) {
            let clip = newID("clip")
            defs.append("<clipPath id=\"\(clip)\"><path d=\"\(PathData.string(Renderer.placedOutline(of: node)))\"\(node.evenOdd == true ? " clip-rule=\"evenodd\"" : "")/></clipPath>")
            inner += "<image x=\"\(n(region.minX))\" y=\"\(n(region.minY))\" width=\"\(n(region.width))\" height=\"\(n(region.height))\" preserveAspectRatio=\"none\" xlink:href=\"\(href)\" clip-path=\"url(#\(clip))\"/>"
        }
        var place = "translate(\(n(node.frame.minX)) \(n(node.frame.minY)))"
        if node.rotation != 0 { place += " rotate(\(n(node.rotation)) \(n(node.frame.width / 2)) \(n(node.frame.height / 2)))" }
        inner += "<g transform=\"\(place)\">\(content(node, options))</g>"
        guard !spread.isEmpty else { return "<g \(attrs.joined(separator: " "))>\(inner)</g>" }
        let under = spread.map { spreadShadow($0, of: node) }.joined()
        return "<g \(attrs.joined(separator: " "))>\(under)\(filter.map { "<g filter=\"url(#\($0))\">\(inner)</g>" } ?? inner)</g>"
    }

    /// A layer turned in depth, which SVG cannot do: a picture of it as it shows, still mixed with
    /// what lies under it as it is.
    private mutating func inDepth(_ node: Node, _ options: Renderer.Options) -> String {
        guard let (image, region) = Renderer.depthPicture(of: node, scale: pictureScale, options: options), let href = Self.dataURI(image) else { return "" }
        let blend = node.blend.map { " style=\"mix-blend-mode:\(Self.css($0))\"" } ?? ""
        return "<image id=\"\(id(for: node.name))\" x=\"\(n(region.minX))\" y=\"\(n(region.minY))\" width=\"\(n(CGFloat(image.width) / pictureScale))\" height=\"\(n(CGFloat(image.height) / pictureScale))\" preserveAspectRatio=\"none\"\(blend) xlink:href=\"\(href)\"/>"
    }

    /// A shape holding layers (see `Mask`), as the canvas draws it: its fill and shadow, then
    /// what it holds cut off at its outline, then its border and any shadow pressed into it.
    private mutating func held(by holder: Node, _ held: ArraySlice<Node>, _ options: Renderer.Options) -> String {
        var under = holder
        under.borders = []
        under.shadows = holder.outerShadows
        var out = layer(under, options)
        let clip = newID("clip")
        let rule = holder.evenOdd == true ? " clip-rule=\"evenodd\"" : ""
        defs.append("<clipPath id=\"\(clip)\"><path d=\"\(PathData.string(Renderer.heldOutline(of: holder)))\"\(rule)/></clipPath>")
        out += "<g clip-path=\"url(#\(clip))\">\(held.map { layer($0, options) }.joined())</g>"
        guard !holder.borders.isEmpty || !holder.innerShadows.isEmpty else { return out }
        var over = holder
        over.fills = []
        over.blur = nil
        over.shadows = holder.innerShadows
        return out + layer(over, options)
    }

    private mutating func content(_ node: Node, _ options: Renderer.Options) -> String {
        switch node.kind {
        case .text:
            return text(node)
        case .group:
            var inner = options
            inner.offset = CGPoint(x: options.offset.x + node.frame.minX, y: options.offset.y + node.frame.minY)
            if let holder = node.holder, node.children.count > 1 { return held(by: holder, node.children.dropFirst(), inner) }
            var out = node.children.map { layer($0, inner) }.joined()
            if let mask = node.mask?.first {
                let clip = newID("clip")
                defs.append("<clipPath id=\"\(clip)\"><path d=\"\(PathData.string(Renderer.placedOutline(of: mask)))\"/></clipPath>")
                out = "<g clip-path=\"url(#\(clip))\">\(out)</g>"
            }
            return out
        case .line:
            let geometry = "<path d=\"\(PathData.string(Renderer.outline(of: node)))\""
            return node.borders.map { stroke($0, of: node, geometry: geometry, closed: false) }.joined()
        case .artboard:
            return ""
        case .rectangle, .ellipse, .path:
            let geometry = shape(node)
            let rule = node.evenOdd == true ? " fill-rule=\"evenodd\"" : ""
            // Over a blur of what lies behind, the fill shows only as much as it is set to.
            let alpha = node.blur.map { $0.on && $0.background ? $0.fillOpacity : 1 } ?? 1
            var out = ""
            let fills = node.fills, silhouette = node.silhouette
            if !fills.isEmpty && alpha > 0 {
                // Several fade together over a blur, as one.
                let each = fills.count > 1 ? 1 : alpha
                var painted = ""
                for (i, fill) in fills.enumerated() {
                    // Those over a cut-out picture colour its subject alone.
                    let (shape, shapeRule) = i > 0 && silhouette != nil
                        ? ("<path d=\"\(PathData.string(silhouette!))\"", " fill-rule=\"evenodd\"") : (geometry, rule)
                    painted += fill.image != nil ? picture(fill, size: node.frame.size, geometry: shape, rule: shapeRule, alpha: each)
                        : shape + " \(paint(fill, size: node.frame.size, alpha: each))\(shapeRule)/>"
                }
                out += fills.count > 1 && alpha < 1 ? "<g opacity=\"\(n(alpha))\">\(painted)</g>" : painted
            }
            for shadow in node.innerShadows { out += innerShadow(shadow, of: node, geometry: geometry, rule: rule) }
            let closed = node.kind != .path || Self.isClosed(Renderer.outline(of: node))
            // A cut-out picture's borders go round its subject.
            let rim = silhouette.map { "<path d=\"\(PathData.string($0))\" fill-rule=\"evenodd\" clip-rule=\"evenodd\"" }
            return out + node.borders.map { stroke($0, of: node, geometry: rim ?? geometry, closed: rim != nil || closed) }.joined()
        }
    }

    /// The start of the element that draws a shape's outline, in its own coordinates: a plain
    /// rectangle or ellipse where it is one, a path otherwise.
    private func shape(_ node: Node) -> String {
        let w = node.frame.width, h = node.frame.height
        if node.kind == .ellipse {
            return "<ellipse cx=\"\(n(w / 2))\" cy=\"\(n(h / 2))\" rx=\"\(n(w / 2))\" ry=\"\(n(h / 2))\""
        }
        let corners = node.corners.flatMap { $0.count == 4 ? $0 : nil }
        if node.kind == .rectangle, (node.cornerSmoothing ?? 0) == 0, corners.map({ Set($0).count == 1 }) ?? true {
            let r = min(max(corners?.first ?? node.cornerRadius, 0), min(w, h) / 2)
            return "<rect width=\"\(n(w))\" height=\"\(n(h))\"\(r > 0 ? " rx=\"\(n(r))\"" : "")"
        }
        return "<path d=\"\(PathData.string(Renderer.outline(of: node)))\""
    }

    // MARK: Fills and borders

    /// The fill as attributes: a colour, or a gradient written into the definitions.
    private mutating func paint(_ fill: Fill, size: CGSize, alpha: Double) -> String {
        if let g = fill.gradient, !g.stops.isEmpty {
            guard let gradient = gradient(g, size: size) else {
                let last = g.stops.max { $0.offset < $1.offset }!.color
                return color(last, alpha: alpha)
            }
            return "fill=\"url(#\(gradient))\"" + (alpha < 1 ? " fill-opacity=\"\(n(alpha))\"" : "")
        }
        return color(fill.color, alpha: alpha)
    }

    /// A gradient across a layer of `size`, written into the definitions: its id, or nil for a
    /// radial one spread to nothing, which is all its last colour.
    private mutating func gradient(_ g: Gradient, size: CGSize) -> String? {
        let stops = g.stops.sorted { $0.offset < $1.offset }.map { s in
            "<stop offset=\"\(n(s.offset))\" stop-color=\"#\(s.color.hex)\"\(s.color.a < 1 ? " stop-opacity=\"\(n(s.color.a))\"" : "")/>"
        }.joined()
        let gradient = newID("gradient")
        switch g.kind {
        case .linear:
            defs.append("<linearGradient id=\"\(gradient)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(g.start.x * size.width))\" y1=\"\(n(g.start.y * size.height))\" x2=\"\(n(g.end.x * size.width))\" y2=\"\(n(g.end.y * size.height))\">\(stops)</linearGradient>")
        case .radial:
            let t = g.spread(in: size)
            guard abs(t.a * t.d - t.b * t.c) > 1e-6 else { return nil }
            defs.append("<radialGradient id=\"\(gradient)\" gradientUnits=\"userSpaceOnUse\" cx=\"0\" cy=\"0\" r=\"1\" gradientTransform=\"matrix(\(n(t.a)) \(n(t.b)) \(n(t.c)) \(n(t.d)) \(n(t.tx)) \(n(t.ty)))\">\(stops)</radialGradient>")
        }
        return gradient
    }

    /// What paints a border or a text's letters, as an attribute's value: a colour, or a gradient
    /// or a picture written into the definitions. A gradient lies across a layer of `size`; a
    /// picture is placed in `place`, the layer's frame unless said otherwise, and shows once over
    /// all of `box`, as on the canvas.
    private mutating func ink(_ fill: Fill, size: CGSize, box: CGRect, place: CGRect? = nil) -> (value: String, opacity: Double?) {
        if let image = fill.image {
            guard let href = dataURI(asset: image.shown, developed: image.develop) ?? (image.cutout != nil ? dataURI(asset: image.asset, developed: image.develop) : nil)
            else { return ("#D9D9D9", nil) }
            let pattern = newID("pattern")
            // In the pattern's own space, whose top left is the box's.
            let placed = place ?? CGRect(origin: .zero, size: size)
            let r = Renderer.imageRect(image, in: placed.size).offsetBy(dx: placed.minX - box.minX, dy: placed.minY - box.minY)
            var element = "<image x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" preserveAspectRatio=\"none\" xlink:href=\"\(href)\""
            if image.flippedX == true || image.flippedY == true {
                let sx: CGFloat = image.flippedX == true ? -1 : 1, sy: CGFloat = image.flippedY == true ? -1 : 1
                element += " transform=\"matrix(\(n(sx)) 0 0 \(n(sy)) \(n((1 - sx) * r.midX)) \(n((1 - sy) * r.midY)))\""
            }
            // Its tile is as big as all it may paint, so it never shows twice.
            defs.append("<pattern id=\"\(pattern)\" patternUnits=\"userSpaceOnUse\" x=\"\(n(box.minX))\" y=\"\(n(box.minY))\" width=\"\(n(box.width))\" height=\"\(n(box.height))\">\(element)/></pattern>")
            return ("url(#\(pattern))", nil)
        }
        if let g = fill.gradient, !g.stops.isEmpty {
            if let gradient = gradient(g, size: size) { return ("url(#\(gradient))", nil) }
            let last = g.stops.max { $0.offset < $1.offset }!.color
            return ("#\(last.hex)", last.a < 1 ? last.a : nil)
        }
        return ("#\(fill.color.hex)", fill.color.a < 1 ? fill.color.a : nil)
    }

    private func color(_ c: RGBA, alpha: Double) -> String {
        let a = c.a * alpha
        return "fill=\"#\(c.hex)\"" + (a < 1 ? " fill-opacity=\"\(n(a))\"" : "")
    }

    /// A picture filling a shape: the picture itself, carried in the file, cut to the outline.
    private mutating func picture(_ fill: Fill, size: CGSize, geometry: String, rule: String, alpha: Double) -> String {
        guard let image = fill.image else { return "" }
        guard let href = dataURI(asset: image.shown, developed: image.develop) ?? (image.cutout != nil ? dataURI(asset: image.asset, developed: image.develop) : nil) else { return geometry + " fill=\"#D9D9D9\"\(rule)/>" }
        let clip = newID("clip")
        defs.append("<clipPath id=\"\(clip)\">\(geometry)\(rule.replacingOccurrences(of: "fill-rule", with: "clip-rule"))/></clipPath>")
        let r = Renderer.imageRect(image, in: size)
        let fade = alpha < 1 ? " opacity=\"\(n(alpha))\"" : ""
        let element = "<image x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" preserveAspectRatio=\"none\" xlink:href=\"\(href)\""
        guard image.flippedX == true || image.flippedY == true else { return element + " clip-path=\"url(#\(clip))\"\(fade)/>" }
        // Turned over where it lies. A cut on the picture itself would be turned over with it, so
        // the outline cuts a group around it instead.
        let sx: CGFloat = image.flippedX == true ? -1 : 1, sy: CGFloat = image.flippedY == true ? -1 : 1
        return "<g clip-path=\"url(#\(clip))\"\(fade)>" + element
            + " transform=\"matrix(\(n(sx)) 0 0 \(n(sy)) \(n((1 - sx) * r.midX)) \(n((1 - sy) * r.midY)))\"/></g>"
    }

    /// The border. SVG strokes along the middle of the edge; one inside or outside is drawn twice
    /// as wide and cut to the inside, or kept to the outside.
    private mutating func stroke(_ b: Border, of node: Node, geometry: String, closed: Bool) -> String {
        guard b.on, b.width > 0 else { return "" }
        let sides = closed && b.position != .center
        // A gradient or a picture, which covers all the border may reach.
        let reach = closed ? b.reach : b.width / 2
        let rim = CGRect(origin: .zero, size: node.frame.size).insetBy(dx: -reach, dy: -reach)
        let (stroke, opacity) = ink(b.paint, size: node.frame.size, box: rim, place: rim)
        var attrs = "fill=\"none\" stroke=\"\(stroke)\"\(opacity.map { " stroke-opacity=\"\(n($0))\"" } ?? "") stroke-width=\"\(n(sides ? b.width * 2 : b.width))\""
        attrs += " stroke-linejoin=\"miter\" stroke-linecap=\"\(closed || b.dash > 0 ? "butt" : "round")\""
        if b.dash > 0 { attrs += " stroke-dasharray=\"\(n(b.dash)) \(n(max(b.gap, 0.5)))\"" }
        let line = geometry + " \(attrs)/>"
        guard sides else { return line }
        if b.position == .inside {
            let clip = newID("clip")
            defs.append("<clipPath id=\"\(clip)\">\(geometry)/></clipPath>")
            return "<g clip-path=\"url(#\(clip))\">\(line)</g>"
        }
        let mask = newID("mask"), w = node.frame.width, h = node.frame.height, m = b.width * 2 + 4
        defs.append("<mask id=\"\(mask)\" maskUnits=\"userSpaceOnUse\" x=\"\(n(-m))\" y=\"\(n(-m))\" width=\"\(n(w + 2 * m))\" height=\"\(n(h + 2 * m))\"><rect x=\"\(n(-m))\" y=\"\(n(-m))\" width=\"\(n(w + 2 * m))\" height=\"\(n(h + 2 * m))\" fill=\"#FFFFFF\"/>\(geometry) fill=\"#000000\"/></mask>")
        return "<g mask=\"url(#\(mask))\">\(line)</g>"
    }

    // MARK: Shadows and blurs

    /// A layer whose blur grows across it, which SVG cannot blur by more in some places than in
    /// others: the layer sharp, and blurred all over above it, showing more of the blurred one
    /// the further along the ramp, until past its end there is only that.
    private mutating func growing(_ node: Node, _ blur: Blur, _ ramp: BlurRamp, _ options: Renderer.Options) -> String {
        var sharp = node
        sharp.blur = nil
        sharp.opacity = 1
        sharp.blend = nil
        var soft = sharp
        soft.blur = blur
        soft.blur?.ramp = nil
        soft.shadows = node.innerShadows
        let t = Renderer.localTransform(node)
        func at(_ u: CGPoint) -> CGPoint { CGPoint(x: u.x * node.frame.width, y: u.y * node.frame.height).applying(t) }
        let a = at(ramp.start), b = at(ramp.end)
        let r = Renderer.reach(of: node).insetBy(dx: -blur.radius * 3 - 4, dy: -blur.radius * 3 - 4)
        let gradient = newID("gradient"), mask = newID("mask")
        defs.append("<linearGradient id=\"\(gradient)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(a.x))\" y1=\"\(n(a.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\"><stop offset=\"0\" stop-color=\"#000000\"/><stop offset=\"1\" stop-color=\"#FFFFFF\"/></linearGradient>")
        defs.append("<mask id=\"\(mask)\" maskUnits=\"userSpaceOnUse\" x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\"><rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" fill=\"url(#\(gradient))\"/></mask>")
        var attrs = ["id=\"\(id(for: node.name))\""]
        if node.opacity < 1 { attrs.append("opacity=\"\(n(node.opacity))\"") }
        if let blend = node.blend { attrs.append("style=\"mix-blend-mode:\(Self.css(blend))\"") }
        return "<g \(attrs.joined(separator: " "))>\(layer(sharp, options))<g mask=\"url(#\(mask))\">\(layer(soft, options))</g></g>"
    }

    /// A layer's shadows and blur of its own as one filter, in its parent's coordinates: the
    /// shadows fall first, each on its own, and the blur softens the layer with its shadows, as on
    /// the canvas. A shape's shadows inside lie over its fills and under its borders, and are drawn
    /// there; text's and a group's fall on all of it, here.
    private mutating func filter(for node: Node) -> String? {
        let outer = node.outerShadows.filter { !Renderer.spreads(node, $0) }
        let inner = [.text, .group].contains(node.kind) ? node.innerShadows : []
        let blur = node.blur.flatMap { $0.on && !$0.background && $0.radius > 0 ? $0 : nil }
        guard !outer.isEmpty || !inner.isEmpty || blur != nil else { return nil }
        let id = newID("effect")
        var steps = ""
        var source = "SourceGraphic"
        if outer.count == 1, let shadow = outer.first {
            steps += "<feDropShadow in=\"\(source)\" dx=\"\(n(shadow.x))\" dy=\"\(n(shadow.y))\" stdDeviation=\"\(n(shadow.blur / 2))\" flood-color=\"#\(shadow.color.hex)\" flood-opacity=\"\(n(shadow.color.a))\" result=\"shadowed\"/>"
            source = "shadowed"
        } else if !outer.isEmpty {
            // The first cast lowest, and the layer over them all.
            for (i, shadow) in outer.enumerated() { steps += Self.drop(shadow, named: "drop\(i)") }
            steps += "<feMerge result=\"shadowed\">" + outer.indices.map { "<feMergeNode in=\"drop\($0)\"/>" }.joined()
                + "<feMergeNode in=\"\(source)\"/></feMerge>"
            source = "shadowed"
        }
        if !inner.isEmpty {
            let names = inner.indices.map { $0 == 0 ? "inner" : "inner\($0)" }
            for (shadow, name) in zip(inner, names) { steps += Self.cast(shadow, dx: shadow.x, dy: shadow.y, named: name) }
            steps += "<feMerge result=\"shadowed\"><feMergeNode in=\"\(source)\"/>" + names.map { "<feMergeNode in=\"\($0)\"/>" }.joined() + "</feMerge>"
            source = "shadowed"
        }
        if let blur { steps += "<feGaussianBlur in=\"\(source)\" stdDeviation=\"\(n(blur.radius))\"/>" }
        var r = Renderer.reach(of: node).insetBy(dx: -4, dy: -4)
        // A shadow inside is cast from all around, which the filter has to reach out to.
        if let most = inner.map(Renderer.innerReach).max() { r = r.insetBy(dx: -most, dy: -most) }
        // Blurred as the canvas blurs, in sRGB, rather than in SVG's own linear light.
        defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" color-interpolation-filters=\"sRGB\">\(steps)</filter>")
        return id
    }

    /// A shape's shadow inside, in its own coordinates: its outline once more, filtered to nothing
    /// but the shadow cast into it, turned back by the layer's own turn as on the canvas.
    /// Spread, it is cast round the hollow narrowed by as much, and kept to the shape.
    private mutating func innerShadow(_ s: Shadow, of node: Node, geometry: String, rule: String) -> String {
        let fall = Geometry.rotate(CGPoint(x: s.x, y: s.y), by: -node.rotation)
        let m = Renderer.innerReach(s) + 4
        let id = newID("effect")
        let hollow = s.grown != 0 ? Renderer.spreadOutline(of: node, by: -s.grown, subject: false) : nil
        defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(-m))\" y=\"\(n(-m))\" width=\"\(n(node.frame.width + 2 * m))\" height=\"\(n(node.frame.height + 2 * m))\" color-interpolation-filters=\"sRGB\">\(Self.cast(s, dx: fall.x, dy: fall.y, named: "inner", within: hollow == nil))</filter>")
        guard let hollow else { return geometry + " fill=\"#000000\"\(rule) filter=\"url(#\(id))\"/>" }
        let clip = newID("clip")
        defs.append("<clipPath id=\"\(clip)\">\(geometry)\(rule.replacingOccurrences(of: "fill-rule", with: "clip-rule"))/></clipPath>")
        return "<g clip-path=\"url(#\(clip))\"><path d=\"\(PathData.string(hollow))\" fill=\"#000000\"\(rule) filter=\"url(#\(id))\"/></g>"
    }

    /// A shadow cast from a shape's outline grown by its spread, in its parent's coordinates: that
    /// outline moved as far as the shadow falls and blurred, in its colour.
    private mutating func spreadShadow(_ s: Shadow, of node: Node) -> String {
        guard let grown = Renderer.spreadOutline(of: node, by: s.grown) else { return "" }
        var t = Renderer.localTransform(node).concatenating(CGAffineTransform(translationX: s.x, y: s.y))
        let placed = grown.copy(using: &t) ?? grown
        let rule = node.silhouette != nil || node.evenOdd == true ? " fill-rule=\"evenodd\"" : ""
        var blur = ""
        if s.blur > 0 {
            let id = newID("effect"), r = placed.boundingBoxOfPath.insetBy(dx: -s.blur * 2 - 4, dy: -s.blur * 2 - 4)
            defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" color-interpolation-filters=\"sRGB\"><feGaussianBlur stdDeviation=\"\(n(s.blur / 2))\"/></filter>")
            blur = " filter=\"url(#\(id))\""
        }
        return "<path d=\"\(PathData.string(placed))\"\(rule) \(color(s.color, alpha: 1))\(blur)/>"
    }

    /// Filter steps for a shadow cast under what is drawn: what is drawn as it would show,
    /// blurred, moved and in the shadow's colour. The result is the shadow alone, `named`.
    private static func drop(_ s: Shadow, named name: String) -> String {
        "<feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"\(n(s.blur / 2))\"/>"
            + "<feOffset dx=\"\(n(s.x))\" dy=\"\(n(s.y))\" result=\"\(name)-cast\"/>"
            + "<feFlood flood-color=\"#\(s.color.hex)\" flood-opacity=\"\(n(s.color.a))\"/>"
            + "<feComposite in2=\"\(name)-cast\" operator=\"in\" result=\"\(name)\"/>"
    }

    /// Filter steps for a shadow cast into what is drawn from all around it: what lies outside,
    /// blurred and moved, in the shadow's colour, kept to the inside unless it is kept to the
    /// shape some other way (`within` false). The result is the shadow alone, `named`.
    private static func cast(_ s: Shadow, dx: CGFloat, dy: CGFloat, named name: String, within: Bool = true) -> String {
        "<feComponentTransfer in=\"SourceAlpha\" result=\"\(name)-around\"><feFuncA type=\"table\" tableValues=\"1 0\"/></feComponentTransfer>"
            + "<feGaussianBlur in=\"\(name)-around\" stdDeviation=\"\(n(s.blur / 2))\"/>"
            + "<feOffset dx=\"\(n(dx))\" dy=\"\(n(dy))\" result=\"\(name)-cast\"/>"
            + "<feFlood flood-color=\"#\(s.color.hex)\" flood-opacity=\"\(n(s.color.a))\"/>"
            + (within ? "<feComposite in2=\"\(name)-cast\" operator=\"in\"/><feComposite in2=\"SourceAlpha\" operator=\"in\" result=\"\(name)\"/>"
                      : "<feComposite in2=\"\(name)-cast\" operator=\"in\" result=\"\(name)\"/>")
    }

    // MARK: Text

    /// Text that stays text: line by line where the canvas sets it, in its font, size and colour,
    /// and letters that look different from the rest in spans of their own; justified lines as
    /// wide as they are set, and the markers of a list's items before them.
    private mutating func text(_ node: Node) -> String {
        if let curved = CurvedText.laid(node) { return curvedText(node, curved) }
        let style = node.style ?? TextStyle()
        let laid = TextLayout.layout(node)
        let font = Fonts.font(style)
        let storage = laid.storage
        let string = storage.string as NSString
        let down = TextLayout.offset(node)
        // As the letters are laid out: painted ones are solid, to be painted through.
        let baseColor = node.letterColor
        var lines: [String] = []
        laid.manager.enumerateLineFragments(forGlyphRange: laid.manager.glyphRange(for: laid.container)) { rect, used, _, glyphs, _ in
            var characters = laid.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // Without the line's breaks, which draw nothing.
            while characters.length > 0, let last = Unicode.Scalar(string.character(at: NSMaxRange(characters) - 1)),
                  CharacterSet.newlines.contains(last) { characters.length -= 1 }
            guard characters.length > 0 else { return }
            let at = laid.manager.location(forGlyphAt: glyphs.location)
            var spans = ""
            storage.enumerateAttributes(in: characters) { attrs, range, _ in
                let words = Self.escape(string.substring(with: range))
                let own = Self.letterAttributes(attrs, against: font, style: style, color: baseColor)
                spans += own.isEmpty ? words : "<tspan \(own.joined(separator: " "))>\(words)</tspan>"
            }
            // A justified line but a paragraph's last is spread to the width it is set at.
            var stretch = ""
            if style.align == .justify, NSMaxRange(characters) < string.length,
               let next = Unicode.Scalar(string.character(at: NSMaxRange(characters))), !CharacterSet.newlines.contains(next) {
                stretch = " textLength=\"\(n(used.width - at.x + used.minX - rect.minX))\" lengthAdjust=\"spacing\""
            }
            // A text of its own each, rather than spans of one: some programs place only the first span.
            lines.append("<text x=\"\(n(rect.minX + at.x))\" y=\"\(n(rect.minY + at.y + down))\"\(stretch)>\(spans)</text>")
        }
        for marker in TextLayout.markers(laid.manager) {
            let own = Self.letterAttributes([.font: marker.font, .foregroundColor: marker.color], against: font, style: style, color: baseColor)
            lines.append("<text x=\"\(n(marker.at.x))\" y=\"\(n(marker.at.y + down))\" \(own.joined(separator: " "))>\(Self.escape(marker.text))</text>")
        }
        guard !lines.isEmpty else { return "" }
        var attrs = ["font-family=\"\(Self.escape(Self.family(of: font, style: style)))\"", "font-size=\"\(n(style.size))\""]
        let weight = Self.weight(of: font)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { attrs.append("font-style=\"italic\"") }
        if style.tracking != 0 { attrs.append("letter-spacing=\"\(n(style.tracking / 1000 * style.size))\"") }
        let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { attrs.append("text-decoration=\"\(decorations.joined(separator: " "))\"") }
        if node.fill.on, node.fill.paints {
            // Letters of the text's own colour painted with its gradient or picture.
            let (fill, opacity) = ink(node.fill, size: node.frame.size, box: Renderer.ink(of: node))
            attrs.append("fill=\"\(fill)\"" + (opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""))
        } else {
            attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        }
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(lines.joined())</g>"
    }

    /// What about some letters differs from the text they are in, as SVG says it.
    private static func letterAttributes(_ attrs: [NSAttributedString.Key: Any], against font: NSFont, style: TextStyle, color base: RGBA?) -> [String] {
        var out: [String] = []
        if let f = attrs[.font] as? NSFont, f != font {
            if f.familyName != font.familyName || f.fontName.hasPrefix(".") != font.fontName.hasPrefix(".") {
                var s = style
                s.family = f.familyName.map { $0.hasPrefix(".") ? TextStyle.system : $0 } ?? style.family
                out.append("font-family=\"\(escape(family(of: f, style: s)))\"")
            }
            if f.pointSize != font.pointSize { out.append("font-size=\"\(n(f.pointSize))\"") }
            let w = weight(of: f)
            if w != weight(of: font) { out.append("font-weight=\"\(w)\"") }
            let italic = f.fontDescriptor.symbolicTraits.contains(.italic)
            if italic != font.fontDescriptor.symbolicTraits.contains(.italic) { out.append("font-style=\"\(italic ? "italic" : "normal")\"") }
            if let kern = attrs[.kern] as? CGFloat, abs(kern - style.tracking / 1000 * f.pointSize) > 0.01 { out.append("letter-spacing=\"\(n(kern))\"") }
        } else if let kern = attrs[.kern] as? CGFloat, abs(kern - style.tracking / 1000 * style.size) > 0.01 {
            out.append("letter-spacing=\"\(n(kern))\"")
        }
        if let c = attrs[.foregroundColor] as? NSColor, let base {
            let rgba = RGBA(c)
            if rgba.hex != base.hex || abs(rgba.a - base.a) > 0.002 {
                let a = rgba.a
                out.append("fill=\"#\(rgba.hex)\"" + (a < 1 ? " fill-opacity=\"\(n(a))\"" : ""))
            }
        }
        let under = (attrs[.underlineStyle] as? Int ?? 0) != 0, through = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        if under != style.underline || through != (style.strikethrough == true) {
            let marks = [under ? "underline" : nil, through ? "line-through" : nil].compactMap { $0 }
            out.append("text-decoration=\"\(marks.isEmpty ? "none" : marks.joined(separator: " "))\"")
        }
        return out
    }

    /// The family the design asks for first, for whoever has it, then the face drawn here by its
    /// exact name and its family, then something like it everyone has.
    private static func family(of font: NSFont, style: TextStyle) -> String {
        var names: [String] = []
        if style.family != TextStyle.system { names.append(style.family) }
        // The Mac's own face goes by private names; elsewhere it is SF Pro, or the system's.
        if let family = font.familyName, !family.hasPrefix("."), !font.fontName.hasPrefix(".") {
            names += [font.fontName, family]
        } else {
            names.append("SF Pro")
        }
        var seen = Set<String>()
        let quoted = names.filter { seen.insert($0).inserted }.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }
        return (quoted + ["-apple-system", "'Helvetica Neue'", "sans-serif"]).joined(separator: ", ")
    }

    /// The font's weight as CSS counts it, from the Mac's own scale of 0 to 15, where 5 is regular and 9 bold.
    private static func weight(of font: NSFont) -> Int {
        switch NSFontManager.shared.weight(of: font) {
        case ...2: 100
        case 3: 200
        case 4: 300
        case 5: 400
        case 6: 500
        case 7, 8: 600
        case 9: 700
        case 10: 800
        default: 900
        }
    }

    // MARK: Pieces

    private static func css(_ blend: BlendMode) -> String {
        switch blend {
        case .multiply: "multiply"
        case .screen: "screen"
        case .overlay: "overlay"
        case .darken: "darken"
        case .lighten: "lighten"
        case .colorDodge: "color-dodge"
        case .colorBurn: "color-burn"
        case .hardLight: "hard-light"
        case .softLight: "soft-light"
        case .difference: "difference"
        case .exclusion: "exclusion"
        case .hue: "hue"
        case .saturation: "saturation"
        case .color: "color"
        case .luminosity: "luminosity"
        }
    }

    /// A picture of the design's own, as it is in the file when it is a PNG or a JPEG.
    private func dataURI(asset: String, developed develop: Develop? = nil) -> String? {
        guard let folder = assets?.folder else { return nil }
        // A developed picture is carried as it is shown: a JPEG when it is solid all over.
        if let develop, !develop.isNeutral {
            guard let picture = assets?.image(asset) else { return nil }
            let shown = Developer.developed(picture, develop)
            let solid = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(picture.alphaInfo)
            let rep = NSBitmapImageRep(cgImage: shown)
            if solid, let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            }
            return Self.dataURI(shown)
        }
        let url = folder.appendingPathComponent(asset)
        switch url.pathExtension.lowercased() {
        case "png": return (try? Data(contentsOf: url)).map { "data:image/png;base64,\($0.base64EncodedString())" }
        case "jpg", "jpeg": return (try? Data(contentsOf: url)).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
        default: return assets?.image(asset).flatMap(Self.dataURI)
        }
    }

    private static func dataURI(_ image: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64,\($0.base64EncodedString())" }
    }

    private static func isClosed(_ path: CGPath) -> Bool {
        var closed = false
        path.applyWithBlock { if $0.pointee.type == .closeSubpath { closed = true } }
        return closed
    }

    private mutating func newID(_ kind: String) -> String {
        count += 1
        return "\(kind)-\(count)"
    }

    /// A layer's name as an id, made of what an id may hold, and kept apart from the others'.
    private mutating func id(for name: String) -> String {
        var base = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        if base.isEmpty || base.first!.isNumber { base = "layer_" + base }
        var candidate = base, i = 2
        while ids.contains(candidate) {
            candidate = "\(base)_\(i)"
            i += 1
        }
        ids.insert(candidate)
        return candidate
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

nonisolated private func n(_ v: CGFloat) -> String { PathData.number(v) }
nonisolated private func n(_ v: Double) -> String { PathData.number(CGFloat(v)) }

nonisolated extension SVGWriter {
    /// Words along a curve that stay words: each letter a text of its own, placed and turned
    /// where it lies on the curve, in its font, size and colour.
    fileprivate mutating func curvedText(_ node: Node, _ laid: CurvedText.Laid) -> String {
        let style = node.style ?? TextStyle()
        let font = Fonts.font(style)
        let words = CurvedText.words(of: node)
        let string = words.string as NSString
        let baseColor = node.letterColor
        var letters: [String] = []
        for letter in laid.letters where NSMaxRange(letter.characters) <= string.length {
            let drawn = string.substring(with: letter.characters)
            guard !drawn.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let attrs = words.attributes(at: letter.characters.location, effectiveRange: nil)
            let own = Self.letterAttributes(attrs, against: font, style: style, color: baseColor)
            // SVG sets letters with y running down, as the layer has it.
            let m = CGAffineTransform(scaleX: 1, y: -1).concatenating(letter.place)
            let place = "transform=\"matrix(\(n(m.a)) \(n(m.b)) \(n(m.c)) \(n(m.d)) \(n(m.tx)) \(n(m.ty)))\""
            letters.append("<text \(([place] + own).joined(separator: " "))>\(Self.escape(drawn))</text>")
        }
        guard !letters.isEmpty else { return "" }
        var attrs = ["font-family=\"\(Self.escape(Self.family(of: font, style: style)))\"", "font-size=\"\(n(style.size))\""]
        let weight = Self.weight(of: font)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { attrs.append("font-style=\"italic\"") }
        let decorations = [style.underline ? "underline" : nil, style.strikethrough == true ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { attrs.append("text-decoration=\"\(decorations.joined(separator: " "))\"") }
        if node.fill.on, node.fill.paints {
            let (fill, opacity) = ink(node.fill, size: node.frame.size, box: Renderer.ink(of: node))
            attrs.append("fill=\"\(fill)\"" + (opacity.map { " fill-opacity=\"\(n($0))\"" } ?? ""))
        } else {
            attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        }
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(letters.joined())</g>"
    }
}
