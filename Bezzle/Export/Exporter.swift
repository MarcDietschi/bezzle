import AppKit
import UniformTypeIdentifiers
import ImageIO

/// The kinds of file a design can be exported as.
enum ExportFormat: String, CaseIterable {
    case png, jpeg, svg, pdf

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .svg: "svg"
        case .pdf: "pdf"
        }
    }

    /// Drawn in pixels, at a scale; the others stay sharp at any size.
    var isPicture: Bool { self == .png || self == .jpeg }
}

/// One thing to export: an artboard, one slide of a carousel, or one layer on its own, from
/// wherever it lies.
struct ExportItem {
    /// Which slide of how many, and where it lies in the carousel, in the carousel's own coordinates.
    struct Slide {
        let number: Int
        let count: Int
        let rect: CGRect
    }

    let node: Node
    /// The artboard a layer lies on, for what shows through its background blurs.
    let board: Node?
    /// Where the top left of what holds the layer is, on the canvas.
    let origin: CGPoint
    /// Set when the artboard is a carousel and this is one of its slides.
    let slide: Slide?
    /// Set when the artboard is one post of a deck: which, of how many, and what it says first,
    /// so that the files are told apart by more than their numbers.
    var post: (number: Int, count: Int, words: String?)?

    init(artboard: Node) {
        node = artboard
        board = nil
        origin = .zero
        slide = nil
    }

    /// The slide `number` of a carousel, counted from 1.
    init(slide number: Int, of carousel: Node) {
        let rects = carousel.slideRects
        node = carousel
        board = nil
        origin = .zero
        slide = Slide(number: number, count: rects.count, rect: rects[min(max(number, 1), rects.count) - 1])
    }

    init?(layer id: UUID, in doc: BezzleDocument) {
        guard let n = doc.node(id), !n.isArtboard, !n.hidden else { return nil }
        node = n
        board = doc.artboard(of: id)
        origin = doc.parentOrigin(of: id)
        slide = nil
    }

    /// What an artboard goes out as: a deck a post at a time, a carousel a slide at a time, and
    /// anything else whole.
    static func items(for artboard: Node) -> [ExportItem] {
        if artboard.isDeck {
            let posts = artboard.posts
            return posts.enumerated().flatMap { i, p in
                let shown = artboard.showing(p)
                return items(for: shown).map { item in
                    var each = item
                    each.post = (i + 1, posts.count, headline(of: shown))
                    return each
                }
            }
        }
        guard artboard.isCarousel else { return [ExportItem(artboard: artboard)] }
        return (1...artboard.slideCount).map { ExportItem(slide: $0, of: artboard) }
    }

    /// What one post of a deck goes out as: the post, as it is numbered among the others.
    static func items(for deck: Node, post: Int?) -> [ExportItem] {
        let posts = deck.posts
        guard deck.isDeck, let post, let i = posts.firstIndex(of: post) else { return items(for: deck) }
        let shown = deck.showing(post)
        return items(for: shown).map { item in
            var each = item
            each.post = (i + 1, posts.count, headline(of: shown))
            return each
        }
    }

    /// What a post says first: the words set largest on it, a line of them, short enough for a name.
    private static func headline(of board: Node) -> String? {
        var best: (size: CGFloat, text: String)?
        func visit(_ n: Node) {
            if n.kind == .text, !n.hidden, let text = n.text, let size = n.style?.size, size > (best?.size ?? 0) {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !line.isEmpty { best = (size, line) }
            }
            if !n.hidden { n.children.forEach(visit) }
        }
        board.children.forEach(visit)
        guard var words = best?.text else { return nil }
        words = String(words.map { "/:\\".contains($0) ? "-" : $0 })
        return words.count > 40 ? String(words.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : words
    }

    /// A number with as many digits as the last one has and at least two, so files sort in order.
    private static func padded(_ number: Int, of count: Int) -> String {
        let digits = max(2, String(count).count), n = String(number)
        return String(repeating: "0", count: max(0, digits - n.count)) + n
    }

    /// A slide's carries its number, so that the files sort in order: "Launch 01", "Launch 02"…;
    /// a post's its number and what it says first: "Sale 03 Hats".
    var name: String {
        var name = node.name
        if let post {
            name += " \(Self.padded(post.number, of: post.count))"
            if let words = post.words { name += " \(words)" }
        }
        guard let slide else { return name }
        return "\(name) \(Self.padded(slide.number, of: slide.count))"
    }

    /// The part of the canvas a slide covers.
    var slideFrame: CGRect? { slide.map { $0.rect.offsetBy(dx: node.frame.minX, dy: node.frame.minY) } }

    /// What it is drawn with: for a layer, where it sits on its artboard, so that a blur of what
    /// lies behind it finds that.
    func options(scale: CGFloat, assets: Assets?) -> Renderer.Options {
        var o = Renderer.Options(deviceScale: scale, assets: assets)
        if let board {
            o.board = board
            o.offset = CGPoint(x: origin.x - board.frame.minX, y: origin.y - board.frame.minY)
        }
        return o
    }

    /// Draws a layer as it is on the canvas, the context in canvas coordinates.
    func drawLayer(in ctx: CGContext, scale: CGFloat, assets: Assets?) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        Renderer.drawNode(node, in: ctx, options: options(scale: scale, assets: assets))
        ctx.restoreGState()
    }

    /// The part of the canvas it covers: an artboard's frame, or for a layer just what it paints,
    /// its shadow and blur included, found by drawing it.
    func bounds(assets: Assets?) -> CGRect {
        if node.isArtboard { return slideFrame ?? node.frame }
        return picture(scale: 1, opaque: false, assets: assets)?.rect ?? node.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Drawn at `scale` pixels to the point: an artboard whole, or a layer trimmed to what it
    /// paints, on nothing; `opaque` puts it on white, as a JPEG has to be.
    func picture(scale: CGFloat, opaque: Bool, assets: Assets?) -> (image: CGImage, rect: CGRect)? {
        if node.isArtboard {
            let rect = slideFrame ?? node.frame
            return Renderer.image(of: node, part: slideFrame, scale: scale, opaque: opaque, assets: assets).map { ($0, rect) }
        }
        // The layer's own top left falls on a whole pixel, so its edges come out sharp.
        let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let reach = Renderer.reach(of: node).offsetBy(dx: origin.x, dy: origin.y)
        let minX = frame.minX + ((reach.minX - frame.minX) * scale).rounded(.down) / scale
        let minY = frame.minY + ((reach.minY - frame.minY) * scale).rounded(.down) / scale
        let w = Int(((reach.maxX - minX) * scale).rounded(.up)), h = Int(((reach.maxY - minY) * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 400_000_000, let ctx = Renderer.bitmap(CGSize(width: w, height: h)) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -minX, y: -minY)
        Renderer.withFlippedContext(ctx) { drawLayer(in: ctx, scale: scale, assets: assets) }
        guard let drawn = ctx.makeImage(), let used = Exporter.painted(in: ctx) else { return nil }
        let rect = CGRect(x: minX + CGFloat(used.minX) / scale, y: minY + CGFloat(used.minY) / scale,
                          width: CGFloat(used.width) / scale, height: CGFloat(used.height) / scale)
        guard let trimmed = drawn.cropping(to: used) else { return nil }
        guard opaque, let white = Renderer.bitmap(CGSize(width: trimmed.width, height: trimmed.height)) else { return (trimmed, rect) }
        let all = CGRect(x: 0, y: 0, width: trimmed.width, height: trimmed.height)
        white.setFillColor(CGColor.white)
        white.fill(all)
        white.draw(trimmed, in: all)
        return white.makeImage().map { ($0, rect) }
    }
}

enum Exporter {
    /// Writes each item into `folder` and returns the files made: a picture or an SVG each, or
    /// one PDF with a page each. Nothing is overwritten: a name already taken gets a number.
    @discardableResult
    static func export(_ items: [ExportItem], format: ExportFormat, scale: CGFloat, name: String, to folder: URL, assets: Assets? = nil) -> [URL] {
        var written: [URL] = []
        switch format {
        case .pdf:
            // Named after what it is when there is one of it, such as a carousel, a page a slide.
            let one = Set(items.map(\.node.id)).count == 1
            let url = free(folder.appendingPathComponent(one ? items[0].node.name : name).appendingPathExtension("pdf"))
            guard let ctx = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Bezzle"] as CFDictionary) else { return [] }
            for item in items { page(item, in: ctx, assets: assets) }
            ctx.closePDF()
            written.append(url)
        case .svg:
            for item in items {
                let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: assets), assets: assets)
                let url = free(folder.appendingPathComponent(item.name).appendingPathExtension("svg"))
                if (try? svg.write(to: url, atomically: true, encoding: .utf8)) != nil { written.append(url) }
            }
        case .png, .jpeg:
            let type = format == .png ? UTType.png : UTType.jpeg
            for item in items {
                guard let (image, _) = item.picture(scale: scale, opaque: format == .jpeg, assets: assets) else { continue }
                let suffix = scale == 1 ? "" : "@\(Int(scale))x"
                let url = free(folder.appendingPathComponent(item.name + suffix).appendingPathExtension(format.fileExtension))
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
                var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
                if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
                if CGImageDestinationFinalize(dest) { written.append(url) }
            }
        }
        return written
    }

    /// One page of a PDF, in points, as big as the item: shapes and text stay shapes and text.
    private static func page(_ item: ExportItem, in ctx: CGContext, assets: Assets?) {
        if item.node.isArtboard {
            Renderer.drawPDFPage(item.node, part: item.slideFrame, in: ctx, assets: assets)
            return
        }
        let bounds = item.bounds(assets: assets)
        var box = CGRect(origin: .zero, size: bounds.size)
        ctx.beginPage(mediaBox: &box)
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        Renderer.withFlippedContext(ctx) { item.drawLayer(in: ctx, scale: 2, assets: assets) }
        ctx.endPage()
    }

    /// The pixels of a bitmap that are not wholly clear, counted from its top left; nil when none are.
    static func painted(in ctx: CGContext) -> CGRect? {
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let w = ctx.width, h = ctx.height, row = ctx.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let line = bytes + y * row
            var x = 0
            while x < w {
                if line[x * 4 + 3] != 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = y
                }
                x += 1
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func free(_ url: URL) -> URL {
        var candidate = url
        var i = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }
}
