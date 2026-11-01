import AppKit
import UniformTypeIdentifiers
import ImageIO

/// One thing to export: an artboard, one slide of a carousel, or one layer on its own, from
/// wherever it lies. Drawn on any thread, so that exporting can go on beside the canvas.
nonisolated struct ExportItem: Sendable {
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
        // On a deck, what lies behind it is its own post, not the deck's first.
        board = doc.post(of: id).map { $0.deck.showing($0.post) } ?? doc.artboard(of: id)
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

    /// What these artboards and layers go out as: an artboard as `items(for:)` says, and any
    /// other layer on its own. Hidden ones are left out.
    static func items(for ids: [UUID], in doc: BezzleDocument) -> [ExportItem] {
        ids.flatMap { id -> [ExportItem] in
            guard let n = doc.node(id) else { return [] }
            if n.isArtboard { return n.hidden ? [] : items(for: n) }
            return ExportItem(layer: id, in: doc).map { [$0] } ?? []
        }
    }

    /// Everything marked for export that shows, top to bottom of the layers list: each artboard
    /// whole, as `items(for:)` says, and each layer on its own, on a deck those of the post in
    /// front. `seen` is the design as it is seen (`DocumentStore.seenDoc`).
    static func marked(in doc: BezzleDocument, seen: BezzleDocument) -> [ExportItem] {
        var out: [ExportItem] = []
        func visit(_ n: Node) {
            guard !n.hidden else { return }
            if n.exports?.isEmpty == false {
                if n.isArtboard {
                    // The deck itself, with every post, not only the one in front.
                    if let board = doc.node(n.id) { out += items(for: board) }
                } else if let item = ExportItem(layer: n.id, in: seen) {
                    out.append(item)
                }
            }
            n.children.forEach(visit)
        }
        seen.nodes.forEach(visit)
        return out
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

/// One file an export writes: what goes in it, as what, how big, and what it is called.
nonisolated struct ExportFile: Sendable {
    /// What it shows: one item, or for a PDF, a page each.
    let items: [ExportItem]
    let format: ExportFormat
    let size: ExportSize
    /// Its name without the extension. A "/" in it puts it in a folder of the name before.
    let name: String

    /// The pixels to a point it is drawn at: the size's own, or what makes it as wide or as tall as asked.
    func scale(assets: Assets?) -> CGFloat {
        if let s = size.plainScale { return CGFloat(s) }
        return size.scale(for: items.first?.bounds(assets: assets).size ?? .zero)
    }
}

nonisolated enum Exporter {
    /// How much of a JPEG, WebP or AVIF picture is kept when nothing else is asked, 0…1.
    static let defaultQuality = 0.9

    /// What exporting items in one format makes: a picture or an SVG each, or one PDF with a page
    /// each, named after the design unless it shows only one thing.
    static func files(_ items: [ExportItem], format: ExportFormat, scale: CGFloat, name: String) -> [ExportFile] {
        guard !items.isEmpty else { return [] }
        switch format {
        case .pdf:
            // Named after what it is when there is one of it, such as a carousel, a page a slide.
            let one = Set(items.map(\.node.id)).count == 1
            return [ExportFile(items: items, format: .pdf, size: .scale(1), name: one ? items[0].node.name : name)]
        case .svg:
            return items.map { ExportFile(items: [$0], format: .svg, size: .scale(1), name: $0.name) }
        case .png, .jpeg, .webp, .avif:
            let size = ExportSize.scale(Double(scale))
            return items.map { ExportFile(items: [$0], format: format, size: size, name: $0.name + size.suffix) }
        }
    }

    /// What exporting items as they are marked makes: a file for each preset of each, a PDF of
    /// one page among them.
    static func files(presetsOf items: [ExportItem]) -> [ExportFile] {
        items.flatMap { item in
            (item.node.exports ?? []).map { preset in
                ExportFile(items: [item], format: preset.format, size: preset.size, name: item.name + preset.nameSuffix)
            }
        }
    }

    /// Writes each item into `folder` and returns the files made. A file already there of the
    /// same name is replaced when `replacing`, and otherwise kept, the new one getting a number.
    @discardableResult
    static func export(_ items: [ExportItem], format: ExportFormat, scale: CGFloat, quality: Double = defaultQuality,
                       name: String, to folder: URL, replacing: Bool = false, assets: Assets? = nil) -> [URL] {
        write(files(items, format: format, scale: scale, name: name), quality: quality, to: folder, replacing: replacing, assets: assets)
    }

    /// Writes each item as each of its presets says.
    @discardableResult
    static func export(presetsOf items: [ExportItem], quality: Double = defaultQuality, to folder: URL, replacing: Bool = false,
                       assets: Assets? = nil) -> [URL] {
        write(files(presetsOf: items), quality: quality, to: folder, replacing: replacing, assets: assets)
    }

    /// Writes the files into `folder`, making the folders their names ask for, and returns
    /// those made; one that cannot be drawn or written is left out.
    @discardableResult
    static func write(_ files: [ExportFile], quality: Double = defaultQuality, to folder: URL, replacing: Bool = false,
                      assets: Assets? = nil) -> [URL] {
        zip(files, destinations(of: files, in: folder, replacing: replacing)).compactMap { file, url in
            guard let url, write(file, to: url, quality: quality, assets: assets) else { return nil }
            return url
        }
    }

    /// Writes one file where it goes, replacing what is there.
    static func write(_ file: ExportFile, to url: URL, quality: Double, assets: Assets?) -> Bool {
        switch file.format {
        case .pdf:
            guard let ctx = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Bezzle"] as CFDictionary) else { return false }
            for item in file.items { page(item, in: ctx, assets: assets) }
            ctx.closePDF()
            return true
        case .svg:
            guard let item = file.items.first else { return false }
            let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: assets), assets: assets)
            return (try? svg.write(to: url, atomically: true, encoding: .utf8)) != nil
        case .png, .jpeg, .webp, .avif:
            let scale = file.scale(assets: assets)
            guard let item = file.items.first,
                  let (image, _) = item.picture(scale: scale, opaque: !file.format.keepsTransparency, assets: assets) else { return false }
            return write(image, as: file.format, scale: scale, quality: quality, to: url)
        }
    }

    /// Writes a picture as a file of the format, marked with how many pixels it has to a point
    /// where the format can say so.
    static func write(_ image: CGImage, as format: ExportFormat, scale: CGFloat, quality: Double, to url: URL) -> Bool {
        if format == .webp {
            guard let data = WebPWriter.data(image, quality: quality) else { return false }
            return (try? data.write(to: url)) != nil
        }
        let type = switch format {
        case .jpeg: "public.jpeg"
        case .avif: "public.avif"
        default: "public.png"
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [:]
        if format != .avif {
            props[kCGImagePropertyDPIWidth] = 72 * scale
            props[kCGImagePropertyDPIHeight] = 72 * scale
        }
        // ImageIO writes no AVIF at all at the very top.
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = format == .avif ? min(quality, 0.99) : quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Where a file goes by its name: in the folders its name asks for. Nothing in a name reaches
    /// outside the folder chosen.
    static func place(of file: ExportFile, in folder: URL) -> URL {
        let parts = file.name.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "-") }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var place = folder
        for part in parts.dropLast() { place.appendPathComponent(part, isDirectory: true) }
        return place.appendingPathComponent(parts.last ?? "Export").appendingPathExtension(file.format.fileExtension)
    }

    /// The files already in `folder` that writing these would replace, each once.
    static func clashes(_ files: [ExportFile], in folder: URL) -> [URL] {
        var seen = Set<String>()
        return files.map { place(of: $0, in: folder) }.filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where each file goes, its folders made: under its own name, replacing what is there when
    /// `replacing`, otherwise numbered past it. Two files of one export never go to one place.
    static func destinations(of files: [ExportFile], in folder: URL, replacing: Bool) -> [URL?] {
        var taken = Set<String>()
        return files.map { file in
            let url = place(of: file, in: folder)
            let inside = url.deletingLastPathComponent()
            if inside.standardizedFileURL != folder.standardizedFileURL {
                guard (try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)) != nil else { return nil }
            }
            let chosen = free(url, replacing: replacing, taken: taken)
            taken.insert(chosen.path)
            return chosen
        }
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

    /// The name itself, or with a number after it, "Card 2", when it is taken: by a file there,
    /// unless that is to be replaced, or by another file of the same export.
    private static func free(_ url: URL, replacing: Bool, taken: Set<String>) -> URL {
        var candidate = url
        var i = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        func used(_ u: URL) -> Bool { taken.contains(u.path) || !replacing && FileManager.default.fileExists(atPath: u.path) }
        while used(candidate) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }
}
