import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture of a design that the Finder shows for its file. Bezzle keeps it in the design's
/// package, and the Quick Look extension that comes with the app (BezzleThumbnails) lays it on a
/// sheet of Bezzle's paper with its corner folded over, as the design's icon is drawn. A design
/// without one, or kept as a single file, shows that icon.
///
/// It is what lies on the sheet: a design of one artboard is that artboard, edge to edge; one of
/// several is its canvas on the paper, come in close as the home screen does, so the first
/// artboards show large rather than all of them small.
nonisolated enum DesignPreview {
    /// Where in the package it is kept. BezzleThumbnails/ThumbnailProvider.swift reads it from there.
    static let folderName = "QuickLook"
    static let fileName = "Thumbnail.jpg"

    static func file(of design: URL) -> URL {
        design.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    static func exists(for design: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(of: design).path)
    }

    /// Whether it shows the design as last saved: made since, as Bezzle makes it after saving.
    /// A design changed where Bezzle could not make one, such as a shared design brought up to
    /// date while closed, or one saved by a Bezzle from before, has an older one or none.
    static func isCurrent(for design: URL) -> Bool {
        func date(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard let made = date(file(of: design)) else { return false }
        return date(design.appendingPathComponent(DesignFile.documentName)).map { made >= $0 } ?? true
    }

    /// How many pixels along its longer side: the Finder draws icons up to 512 points, at twice
    /// that on a Retina screen.
    static let longSide: CGFloat = 1024
    /// How tall or wide the sheet may be. A long page shows its top, and a strip its start.
    static let narrowest: CGFloat = 0.45, widest: CGFloat = 2.2
    /// How the canvas of a design of several artboards may be cut: nearer square, as a canvas
    /// spreads in every direction.
    static let canvasNarrowest: CGFloat = 0.7, canvasWidest: CGFloat = 1.6
    /// How long a design being worked on waits before its picture is made again, however many
    /// changes come meanwhile.
    static let every: Duration = .seconds(20)

    /// Pictures are made one after another, away from the main thread, as making one of a large
    /// design takes a moment.
    static let making = DispatchQueue(label: "com.erik.Bezzle.previews", qos: .utility)
    /// Pictures for designs in the library without a current one, on a queue of their own, as
    /// quitting waits for the pictures of designs just worked on but not for these.
    static let catchingUp = DispatchQueue(label: "com.erik.Bezzle.previews.library", qos: .background)

    /// The paper the sheet is cut from, as the icon's is: lighter at the top.
    private static let paperTop = CGColor(srgbRed: 0.976, green: 0.965, blue: 0.941, alpha: 1)
    private static let paperBottom = CGColor(srgbRed: 0.914, green: 0.894, blue: 0.855, alpha: 1)

    /// The picture, opaque, on the sheet's paper; nil for a design with nothing on it.
    static func picture(of doc: BezzleDocument, assets: Assets?) -> CGImage? {
        let shown = doc.nodes.filter { !$0.hidden }
        if shown.count == 1, let board = shown.first, board.isArtboard, board.frame.width > 0, board.frame.height > 0 {
            var part = board.frame
            if part.width / part.height < narrowest { part.size.height = part.width / narrowest }
            if part.width / part.height > widest { part.size.width = part.height * widest }
            let scale = longSide / max(part.width, part.height)
            guard let image = Renderer.image(of: board, part: part == board.frame ? nil : part, scale: scale, opaque: false,
                                             assets: assets) else { return nil }
            return onPaper(image)
        }
        guard let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 else { return nil }
        let aspect = min(max(bounds.width / bounds.height, canvasNarrowest), canvasWidest)
        // In points, drawn at twice that, as the home screen's thumbnails are, so artboards'
        // shadows and edges come out as there.
        let size = aspect >= 1 ? CGSize(width: longSide / 2, height: (longSide / 2 / aspect).rounded())
                               : CGSize(width: (longSide / 2 * aspect).rounded(), height: longSide / 2)
        let place = Renderer.thumbnailPlacement(of: doc, bounds: bounds, in: size, cover: true)
        let px = CGSize(width: size.width * 2, height: size.height * 2)
        guard let ctx = Renderer.bitmap(px) else { return nil }
        paint(ctx, px)
        ctx.translateBy(x: 0, y: px.height)
        ctx.scaleBy(x: 2, y: -2)
        ctx.translateBy(x: place.origin.x, y: place.origin.y)
        ctx.scaleBy(x: place.scale, y: place.scale)
        Renderer.withFlippedContext(ctx) {
            var options = Renderer.Options(deviceScale: 2 * place.scale, assets: assets)
            options.artboardShadows = true
            // Only what is in the picture: a design of hundreds of artboards shows a few.
            options.visible = CGRect(x: -place.origin.x / place.scale, y: -place.origin.y / place.scale,
                                     width: size.width / place.scale, height: size.height / place.scale)
            Renderer.draw(doc, in: ctx, options: options)
        }
        return ctx.makeImage()
    }

    private static func paint(_ ctx: CGContext, _ size: CGSize) {
        let paper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [paperTop, paperBottom] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    }

    /// An artboard's picture on the paper, which shows through where the artboard has no fill.
    private static func onPaper(_ image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let ctx = Renderer.bitmap(size) else { return nil }
        paint(ctx, size)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Makes the design's picture and keeps it in its package, or takes away one that no longer
    /// shows anything. Only for a design kept as a package; writing goes in turn with the design's
    /// own saves, so it never lands in one being turned into a package or moved.
    ///
    /// The Finder draws a design's thumbnail again only once the package's date moves, which
    /// writing inside it does not do; a design just worked on is dated now, as the picture is
    /// newer than its last save. With `keepingDate`, as for a design caught up on from the home
    /// screen, the date stays, and the design keeps its place among the others there.
    static func write(_ doc: BezzleDocument, assets: Assets?, to design: URL, keepingDate: Bool = false) {
        let image = picture(of: doc, assets: assets)
        let data = image.flatMap(jpeg)
        DocumentStore.saving.async {
            guard DesignFile.isPackage(design) else { return }
            let fm = FileManager.default
            let folder = design.appendingPathComponent(folderName, isDirectory: true), file = file(of: design)
            guard let data else {
                try? fm.removeItem(at: folder)
                return
            }
            let date = (try? design.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            do {
                try DesignFile.coordinated(writing: design) { _ in
                    if !fm.fileExists(atPath: folder.path) {
                        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    }
                    try data.write(to: file, options: .atomic)
                }
                if let when = keepingDate ? date : Date() {
                    var values = URLResourceValues()
                    values.contentModificationDate = when
                    var dated = design
                    try? dated.setResourceValues(values)
                }
            } catch {
                NSLog("Bezzle could not keep the Finder's picture of %@: %@", design.path, error.localizedDescription)
            }
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}
