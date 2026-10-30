import AppKit

/// A design written as SVG, as close to how it looks as SVG allows, and as SVG has it, so that it
/// stays sharp and can be changed elsewhere: rectangles, ellipses and paths, text that is still
/// text, gradients, borders inside and outside, shadows and blurs as filters, pictures carried
/// in the file. A blur of what lies behind a layer, which SVG cannot do, comes as a picture of
/// what shows through, and a layer turned in depth as a picture of it. Layers keep their names as ids.
struct SVGWriter {
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
        if let filter = filter(for: node) { attrs.append("filter=\"url(#\(filter))\"") }
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
        return "<g \(attrs.joined(separator: " "))>\(inner)</g>"
    }

    /// A layer turned in depth, which SVG cannot do: a picture of it as it shows, still mixed with
    /// what lies under it as it is.
    private mutating func inDepth(_ node: Node, _ options: Renderer.Options) -> String {
        guard let (image, region) = Renderer.depthPicture(of: node, scale: pictureScale, options: options), let href = Self.dataURI(image) else { return "" }
        let blend = node.blend.map { " style=\"mix-blend-mode:\(Self.css($0))\"" } ?? ""
        return "<image id=\"\(id(for: node.name))\" x=\"\(n(region.minX))\" y=\"\(n(region.minY))\" width=\"\(n(CGFloat(image.width) / pictureScale))\" height=\"\(n(CGFloat(image.height) / pictureScale))\" preserveAspectRatio=\"none\"\(blend) xlink:href=\"\(href)\"/>"
    }

    private mutating func content(_ node: Node, _ options: Renderer.Options) -> String {
        switch node.kind {
        case .text:
            return text(node)
        case .group:
            var inner = options
            inner.offset = CGPoint(x: options.offset.x + node.frame.minX, y: options.offset.y + node.frame.minY)
            var out = node.children.map { layer($0, inner) }.joined()
            if let mask = node.mask?.first {
                let clip = newID("clip")
                defs.append("<clipPath id=\"\(clip)\"><path d=\"\(PathData.string(Renderer.placedOutline(of: mask)))\"/></clipPath>")
                out = "<g clip-path=\"url(#\(clip))\">\(out)</g>"
            }
            return out
        case .line:
            return stroke(node, geometry: "<path d=\"\(PathData.string(Renderer.outline(of: node)))\"", closed: false)
        case .artboard:
            return ""
        case .rectangle, .ellipse, .path:
            let geometry = shape(node)
            let rule = node.evenOdd == true ? " fill-rule=\"evenodd\"" : ""
            // Over a blur of what lies behind, the fill shows only as much as it is set to.
            let alpha = node.blur.map { $0.on && $0.background ? $0.fillOpacity : 1 } ?? 1
            var out = ""
            if node.fill.on && alpha > 0 {
                out += node.fill.image != nil ? picture(node.fill, size: node.frame.size, geometry: geometry, rule: rule, alpha: alpha)
                    : geometry + " \(paint(node.fill, size: node.frame.size, alpha: alpha))\(rule)/>"
            }
            if node.shadow.inside { out += innerShadow(node, geometry: geometry, rule: rule) }
            let closed = node.kind != .path || Self.isClosed(Renderer.outline(of: node))
            // A cut-out picture's border goes round its subject.
            if node.border.on, let silhouette = node.silhouette {
                return out + stroke(node, geometry: "<path d=\"\(PathData.string(silhouette))\" fill-rule=\"evenodd\" clip-rule=\"evenodd\"", closed: true)
            }
            return out + stroke(node, geometry: geometry, closed: closed)
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
            let stops = g.stops.sorted { $0.offset < $1.offset }.map { s in
                "<stop offset=\"\(n(s.offset))\" stop-color=\"#\(s.color.hex)\"\(s.color.a < 1 ? " stop-opacity=\"\(n(s.color.a))\"" : "")/>"
            }.joined()
            let gradient = newID("gradient")
            switch g.kind {
            case .linear:
                defs.append("<linearGradient id=\"\(gradient)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(g.start.x * size.width))\" y1=\"\(n(g.start.y * size.height))\" x2=\"\(n(g.end.x * size.width))\" y2=\"\(n(g.end.y * size.height))\">\(stops)</linearGradient>")
            case .radial:
                let t = g.spread(in: size)
                guard abs(t.a * t.d - t.b * t.c) > 1e-6 else {
                    let last = g.stops.max { $0.offset < $1.offset }!.color
                    return color(last, alpha: alpha)
                }
                defs.append("<radialGradient id=\"\(gradient)\" gradientUnits=\"userSpaceOnUse\" cx=\"0\" cy=\"0\" r=\"1\" gradientTransform=\"matrix(\(n(t.a)) \(n(t.b)) \(n(t.c)) \(n(t.d)) \(n(t.tx)) \(n(t.ty)))\">\(stops)</radialGradient>")
            }
            return "fill=\"url(#\(gradient))\"" + (alpha < 1 ? " fill-opacity=\"\(n(alpha))\"" : "")
        }
        return color(fill.color, alpha: alpha)
    }

    private func color(_ c: RGBA, alpha: Double) -> String {
        let a = c.a * alpha
        return "fill=\"#\(c.hex)\"" + (a < 1 ? " fill-opacity=\"\(n(a))\"" : "")
    }

    /// A picture filling a shape: the picture itself, carried in the file, cut to the outline.
    private mutating func picture(_ fill: Fill, size: CGSize, geometry: String, rule: String, alpha: Double) -> String {
        guard let image = fill.image else { return "" }
        guard let href = dataURI(asset: image.shown) ?? (image.cutout != nil ? dataURI(asset: image.asset) : nil) else { return geometry + " fill=\"#D9D9D9\"\(rule)/>" }
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
    private mutating func stroke(_ node: Node, geometry: String, closed: Bool) -> String {
        let b = node.border
        guard b.on, b.width > 0 else { return "" }
        let sides = closed && b.position != .center
        var attrs = "fill=\"none\" stroke=\"#\(b.color.hex)\"\(b.color.a < 1 ? " stroke-opacity=\"\(n(b.color.a))\"" : "") stroke-width=\"\(n(sides ? b.width * 2 : b.width))\""
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
        soft.shadow.on = soft.shadow.inside
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

    /// A layer's shadow and blur of its own as one filter, in its parent's coordinates: the
    /// shadow falls first, and the blur softens the layer with its shadow, as on the canvas. A
    /// shape's shadow inside lies over its fill and under its border, and is drawn there; text's
    /// and a group's falls on all of it, here.
    private mutating func filter(for node: Node) -> String? {
        let shadow = node.shadow.outside ? node.shadow : nil
        let inner = node.shadow.inside && [.text, .group].contains(node.kind) ? node.shadow : nil
        let blur = node.blur.flatMap { $0.on && !$0.background && $0.radius > 0 ? $0 : nil }
        guard shadow != nil || inner != nil || blur != nil else { return nil }
        let id = newID("effect")
        var steps = ""
        var source = "SourceGraphic"
        if let shadow {
            steps += "<feDropShadow in=\"\(source)\" dx=\"\(n(shadow.x))\" dy=\"\(n(shadow.y))\" stdDeviation=\"\(n(shadow.blur / 2))\" flood-color=\"#\(shadow.color.hex)\" flood-opacity=\"\(n(shadow.color.a))\" result=\"shadowed\"/>"
            source = "shadowed"
        }
        if let inner {
            steps += Self.cast(inner, dx: inner.x, dy: inner.y) + "<feMerge result=\"shadowed\"><feMergeNode in=\"\(source)\"/><feMergeNode in=\"inner\"/></feMerge>"
            source = "shadowed"
        }
        if let blur { steps += "<feGaussianBlur in=\"\(source)\" stdDeviation=\"\(n(blur.radius))\"/>" }
        var r = Renderer.reach(of: node).insetBy(dx: -4, dy: -4)
        // A shadow inside is cast from all around, which the filter has to reach out to.
        if let inner { r = r.insetBy(dx: -Renderer.innerReach(inner), dy: -Renderer.innerReach(inner)) }
        // Blurred as the canvas blurs, in sRGB, rather than in SVG's own linear light.
        defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" color-interpolation-filters=\"sRGB\">\(steps)</filter>")
        return id
    }

    /// A shape's shadow inside, in its own coordinates: its outline once more, filtered to nothing
    /// but the shadow cast into it, turned back by the layer's own turn as on the canvas.
    private mutating func innerShadow(_ node: Node, geometry: String, rule: String) -> String {
        let s = node.shadow
        let fall = Geometry.rotate(CGPoint(x: s.x, y: s.y), by: -node.rotation)
        let m = Renderer.innerReach(s) + 4
        let id = newID("effect")
        defs.append("<filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(n(-m))\" y=\"\(n(-m))\" width=\"\(n(node.frame.width + 2 * m))\" height=\"\(n(node.frame.height + 2 * m))\" color-interpolation-filters=\"sRGB\">\(Self.cast(s, dx: fall.x, dy: fall.y))</filter>")
        return geometry + " fill=\"#000000\"\(rule) filter=\"url(#\(id))\"/>"
    }

    /// Filter steps for a shadow cast into what is drawn from all around it: what lies outside,
    /// blurred and moved, in the shadow's colour, kept to the inside. The result is the shadow
    /// alone, named "inner".
    private static func cast(_ s: Shadow, dx: CGFloat, dy: CGFloat) -> String {
        "<feComponentTransfer in=\"SourceAlpha\" result=\"around\"><feFuncA type=\"table\" tableValues=\"1 0\"/></feComponentTransfer>"
            + "<feGaussianBlur in=\"around\" stdDeviation=\"\(n(s.blur / 2))\"/>"
            + "<feOffset dx=\"\(n(dx))\" dy=\"\(n(dy))\" result=\"cast\"/>"
            + "<feFlood flood-color=\"#\(s.color.hex)\" flood-opacity=\"\(n(s.color.a))\"/>"
            + "<feComposite in2=\"cast\" operator=\"in\"/>"
            + "<feComposite in2=\"SourceAlpha\" operator=\"in\" result=\"inner\"/>"
    }

    // MARK: Text

    /// Text that stays text: line by line where the canvas sets it, in its font, size and colour.
    private func text(_ node: Node) -> String {
        let style = node.style ?? TextStyle()
        let laid = TextLayout.layout(node)
        let font = Fonts.font(style)
        let string = laid.storage.string as NSString
        var lines: [String] = []
        laid.manager.enumerateLineFragments(forGlyphRange: laid.manager.glyphRange(for: laid.container)) { rect, _, _, glyphs, _ in
            let characters = laid.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let words = string.substring(with: characters).trimmingCharacters(in: .newlines)
            guard !words.isEmpty else { return }
            let at = laid.manager.location(forGlyphAt: glyphs.location)
            // A text of its own each, rather than spans of one: some programs place only the first span.
            lines.append("<text x=\"\(n(rect.minX + at.x))\" y=\"\(n(rect.minY + at.y))\">\(Self.escape(words))</text>")
        }
        guard !lines.isEmpty else { return "" }
        var attrs = ["font-family=\"\(Self.escape(Self.family(of: font, style: style)))\"", "font-size=\"\(n(style.size))\""]
        let weight = Self.weight(of: font)
        if weight != 400 { attrs.append("font-weight=\"\(weight)\"") }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { attrs.append("font-style=\"italic\"") }
        if style.tracking != 0 { attrs.append("letter-spacing=\"\(n(style.tracking / 1000 * style.size))\"") }
        if style.underline { attrs.append("text-decoration=\"underline\"") }
        attrs.append(node.fill.on ? color(node.fill.color, alpha: 1) : "fill=\"none\"")
        return "<g \(attrs.joined(separator: " ")) xml:space=\"preserve\">\(lines.joined())</g>"
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
    private func dataURI(asset: String) -> String? {
        guard let folder = assets?.folder else { return nil }
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

private func n(_ v: CGFloat) -> String { PathData.number(v) }
private func n(_ v: Double) -> String { PathData.number(CGFloat(v)) }
