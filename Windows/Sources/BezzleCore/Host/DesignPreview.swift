import Foundation
import CBezzleHost

// The picture of a design that the Mac's Finder shows for its file, written on Windows exactly as
// the Mac writes it (from Bezzle/Store/DesignPreview.swift): QuickLook/Thumbnail.jpg in the
// design's package, which the Mac's Quick Look extension (BezzleThumbnails) lays on a sheet of
// Bezzle's paper. So a design worked on here shows as it now is in a Mac's Finder, as one worked on
// there does. What Explorer shows for a design is another matter, not decided yet; nothing else
// is written for it.
//
// It is what lies on the sheet: a design of one artboard is that artboard, edge to edge; one of
// several is its canvas on the paper, come in close as the home screen does, so the first
// artboards show large rather than all of them small. 1024 pixels along its longer side, JPEG at
// Image I/O's 0.82 (CBezzleHost/jpeg.cpp writes it with Image I/O's tables).

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
        return date(design.appendingPathComponent("document.json")).map { made >= $0 } ?? true
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
    public static let every: Double = 20
    /// Image I/O's lossy compression quality for it.
    static let quality = 0.82

    /// The paper the sheet is cut from, as the icon's is: lighter at the top.
    private static let paperTop = CGColor(srgbRed: 0.976, green: 0.965, blue: 0.941, alpha: 1)
    private static let paperBottom = CGColor(srgbRed: 0.914, green: 0.894, blue: 0.855, alpha: 1)

    /// The picture, opaque, on the sheet's paper; nil for a design with nothing on it.
    @MainActor static func picture(of doc: BezzleDocument, assets: Assets?) -> CGImage? {
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
    @MainActor private static func onPaper(_ image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let ctx = Renderer.bitmap(size) else { return nil }
        paint(ctx, size)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// The picture as a JPEG file's bytes, drawn by Skia; nil for a design with nothing on it.
    @MainActor static func jpeg(of doc: BezzleDocument, assets: Assets?) -> Data? {
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        defer { WindowsCore.forget(before: first) }
        guard let image = picture(of: doc, assets: assets) else { return nil }
        for p in Images.shared.list where p.id >= first { WindowsCore.send(p) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let read = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 0, $0.baseAddress) }
        guard read == 0 else { return nil }
        var capacity = image.width * image.height + 65_536
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = pixels.withUnsafeBytes { p in
                out.withUnsafeMutableBytes { bz_jpeg_encode(Int32(image.width), Int32(image.height), p.baseAddress, quality, $0.baseAddress, Int64(capacity)) }
            }
            if n == -1 { return nil }
            if n < 0 {
                capacity = Int(-n)
                continue
            }
            return Data(out.prefix(Int(n)))
        }
    }

    /// Makes the design's picture and keeps it in its package, or takes away one that no longer
    /// shows anything. Only for a design kept as a package. Written in turn with the design's own
    /// saves (both on the main thread here), so it never lands in one being moved.
    ///
    /// The Finder draws a design's thumbnail again only once the package's date moves, which
    /// writing inside it does not do; a design just worked on is dated now, as the picture is
    /// newer than its last save. With `keepingDate`, as for a design caught up on from the home
    /// screen, the date stays, and the design keeps its place among the others there.
    @MainActor static func write(_ doc: BezzleDocument, assets: Assets?, to design: URL, keepingDate: Bool = false) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: design.path, isDirectory: &isFolder), isFolder.boolValue else { return }
        let data = jpeg(of: doc, assets: assets)
        let fm = FileManager.default
        let folder = design.appendingPathComponent(folderName, isDirectory: true), file = file(of: design)
        let date = (try? fm.attributesOfItem(atPath: design.path))?[.modificationDate] as? Date
        guard let data else {
            try? fm.removeItem(at: folder)
            return
        }
        do {
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try data.write(to: file, options: .atomic)
            if let when = keepingDate ? date : Date() {
                try? fm.setAttributes([.modificationDate: when], ofItemAtPath: design.path)
            }
        } catch {
            NSLog("Bezzle could not keep the Finder's picture of %@: %@", design.path, "\(error)")
        }
    }
}

extension WindowsCore {
    /// Whether the open design has the Finder's picture already (see `DesignPreview`).
    public static var designHasPreview: Bool { designURL.map(DesignPreview.exists) ?? false }
    /// How many times the open design changed, as the Mac's store.version counts: its picture is
    /// made again only once it changed.
    public static var designChanges: Int { designVersion }
    /// Whether a drag or another gesture is going on.
    public static var inGesture: Bool { Editing.gestureStart != nil }
    /// How long a design being worked on waits, in seconds, before its picture is made again.
    public static var previewEvery: Double { DesignPreview.every }

    /// The Finder's picture of the open design made again from it as it is saved, and kept in its
    /// package (the Mac's DocumentStore.makePreview).
    public static func writePreview() {
        guard let url = designURL, let doc = previewBase ?? design else { return }
        DesignPreview.write(doc, assets: assets, to: url)
    }

    /// A design on the home screen without a current picture for the Finder, made before Bezzle
    /// kept them, brought in from elsewhere, changed while closed or last saved by a Bezzle for
    /// Windows from before, is given one, its date kept (the Mac's Library.seekPreview). Read on
    /// its own: the design that is open stays as it is. True when it had to be made.
    @discardableResult public static func catchUpPreview(of url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
              !DesignPreview.isCurrent(for: url), let doc = try? read(url) else { return false }
        DesignPreview.write(doc, assets: Assets(folder: url.appendingPathComponent("images")), to: url, keepingDate: true)
        return true
    }
}
