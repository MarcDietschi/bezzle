import AppKit
import UniformTypeIdentifiers
import ImageIO

// Drawing and writing what an export makes, on the Mac (what goes out is ExportPlan.swift).

nonisolated extension ExportItem {
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
        let reach = Renderer.reach(of: node, eye: options(scale: scale, assets: assets).eye).offsetBy(dx: origin.x, dy: origin.y)
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

nonisolated extension ExportFile {
    /// The pixels to a point it is drawn at (see `scale(drawn:)`).
    func scale(assets: Assets?) -> CGFloat { scale(drawn: items.first?.bounds(assets: assets).size ?? .zero) }
}

nonisolated extension Exporter {
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
}
