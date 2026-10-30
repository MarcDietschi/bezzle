import AppKit
import ImageIO

/// Files dragged onto the canvas from elsewhere, shown doing what they would do before they are
/// let go (see `DropPlan`). Over a shape, the picture shows inside it already, cropped as it will
/// be, and the shape glows round its outline, breathing, to say it will take it; over a shape
/// repeated in a grid, every cell shows the picture it would get. Anywhere else each picture
/// shows where it would lie, faintly, with the artboard that would hold it outlined. Words over a
/// grid light up the text layers they go to. A label under it says what will happen.
final class DropTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}

    /// What is being dragged in, read once as it comes.
    private(set) var dropped: Dropped?
    private var plan: DropPlan?
    private var target: UUID?
    /// Small pictures of what is dragged in, read away from the main thread as the drag comes in.
    private var thumbnails: [URL: CGImage] = [:]
    private var session = UUID()
    private var pulse: Timer?
    private var began: CFTimeInterval = 0
    private var deviceScale: CGFloat = 2

    /// How many pictures are read for showing; a folder of hundreds shows its first.
    private static let shown = 48

    init(store: DocumentStore) {
        self.store = store
    }

    // MARK: - The drag

    /// Something has been dragged onto the canvas.
    func begin(_ dropped: Dropped) {
        self.dropped = dropped
        thumbnails = [:]
        plan = nil
        target = nil
        began = CACurrentMediaTime()
        let session = UUID()
        self.session = session
        let urls = Array(dropped.pictures.prefix(Self.shown))
        Task.detached(priority: .userInitiated) { [weak self] in
            for url in urls {
                guard let image = Self.thumbnail(url) else { continue }
                let picture = Picture(image: image)
                await MainActor.run {
                    guard let self, self.session == session else { return }
                    self.thumbnails[url] = picture.image
                    self.redraw()
                }
            }
        }
        // The glow breathes while the drag is over the canvas.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.plan != nil { self?.redraw() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulse?.invalidate()
        pulse = timer
    }

    /// The drag has moved over a canvas point, on a layer or on nothing. Returns whether letting
    /// go there would do anything.
    func update(at p: CGPoint, on target: UUID?) -> Bool {
        guard let dropped else { return false }
        self.target = target
        plan = store.plan(for: dropped, at: p, on: target)
        redraw()
        return plan != nil
    }

    /// The drag has left the canvas, or been let go.
    func end() {
        dropped = nil
        plan = nil
        target = nil
        thumbnails = [:]
        session = UUID()
        pulse?.invalidate()
        pulse = nil
        redraw()
    }

    /// A picture read small, at most as big as a shape on screen is likely to show it.
    nonisolated private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 720]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A picture handed from where it was read to the main thread, which only ever draws it.
    private struct Picture: @unchecked Sendable {
        let image: CGImage
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        guard let plan, let dropped else { return }
        deviceScale = scale
        // Between half and all of its glow, round and round in under two seconds.
        let breath = 0.5 + 0.5 * sin((CACurrentMediaTime() - began) * 2 * .pi / 1.6)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        var covered: CGRect?
        func cover(_ r: CGRect) { covered = covered?.union(r) ?? r }
        /// Where the label goes inside, rather than under what is covered: in the shape that is pointed at.
        var within: CGRect?
        let label: String
        switch plan {
        case .fill(let ids):
            for (i, id) in ids.enumerated() {
                guard let node = store.node(id) else { continue }
                let k = i % max(dropped.pictures.count, 1)
                drawPicture(thumbnails[dropped.pictures[k]], size: dropped.sizes[k], in: node, ctx)
                let outline = viewOutline(of: node)
                drawGlow(outline, breath: breath, strong: id == target || ids.count == 1, in: ctx)
                cover(outline.boundingBoxOfPath)
                if id == target || within == nil { within = outline.boundingBoxOfPath }
            }
            label = fillLabel(ids, pictures: dropped.pictures.count)
        case .place(let frames, let board):
            if let board = board.flatMap({ store.node($0) }) {
                ctx.addPath(CGPath(rect: store.viewport.toView(board.frame).insetBy(dx: -1, dy: -1), transform: nil))
                ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.35 + 0.3 * breath).cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
            for (i, frame) in frames.enumerated().reversed() {
                let r = store.viewport.toView(frame)
                drawGhost(thumbnails[dropped.pictures[i]], in: r, ctx)
                cover(r)
            }
            if let name = board.flatMap({ store.node($0)?.name }) {
                label = frames.count == 1 ? String(localized: "Add to \(name)") : String(localized: "Add \(frames.count) pictures to \(name)")
            } else {
                label = frames.count == 1 ? String(localized: "Add to the canvas") : String(localized: "Add \(frames.count) pictures to the canvas")
            }
        case .words(let grid, let layers, let columns, let lines):
            for id in layers {
                guard let node = store.node(id) else { continue }
                let outline = viewOutline(of: node)
                drawGlow(outline, breath: breath, strong: false, in: ctx)
                cover(outline.boundingBoxOfPath)
            }
            let cells = store.node(grid)?.grid?.count ?? layers.count
            label = switch (columns > 1, lines == 1, cells == 1) {
            case (true, _, true): String(localized: "\(columns) columns into 1 cell")
            case (true, _, false): String(localized: "\(columns) columns into \(cells) cells")
            case (false, true, true): String(localized: "1 line into 1 cell")
            case (false, true, false): String(localized: "1 line into \(cells) cells")
            case (false, false, true): String(localized: "\(lines) lines into 1 cell")
            case (false, false, false): String(localized: "\(lines) lines into \(cells) cells")
            }
        case .posts(let id, let count), .postWords(let id, let count):
            if let node = store.node(id) {
                if case .posts = plan { drawPicture(thumbnails[dropped.pictures[0]], size: dropped.sizes[0], in: node, ctx) }
                let outline = viewOutline(of: node)
                drawGlow(outline, breath: breath, strong: true, in: ctx)
                cover(outline.boundingBoxOfPath)
                within = outline.boundingBoxOfPath
            }
            label = postsLabel(id, count: count, pictures: { if case .posts = plan { true } else { false } }())
        }
        if let covered { drawLabel(label, under: covered, inside: within, in: bounds, ctx) }
    }

    /// What letting go makes of a deck's posts, in words: which of them it fills, and how many it adds.
    private func postsLabel(_ id: UUID, count: Int, pictures: Bool) -> String {
        guard let (deck, post) = store.doc.post(of: id), let post else {
            return pictures ? String(localized: "\(count) pictures into \(count) posts") : String(localized: "\(count) lines into \(count) posts")
        }
        let posts = deck.posts
        let from = posts.firstIndex(of: post) ?? 0
        let added = max(0, from + count - posts.count)
        let first = from + 1, last = from + count
        // One post is always one already there, so only a run of them can add new ones.
        return switch (pictures, count == 1, added > 0) {
        case (true, true, _): String(localized: "\(count) pictures into post \(first)")
        case (true, false, false): String(localized: "\(count) pictures into posts \(first)–\(last)")
        case (true, false, true): String(localized: "\(count) pictures into posts \(first)–\(last), \(added) new")
        case (false, true, _): String(localized: "\(count) lines into post \(first)")
        case (false, false, false): String(localized: "\(count) lines into posts \(first)–\(last)")
        case (false, false, true): String(localized: "\(count) lines into posts \(first)–\(last), \(added) new")
        }
    }

    /// What letting go fills, in words.
    private func fillLabel(_ ids: [UUID], pictures: Int) -> String {
        guard ids.count > 1 else {
            guard let node = ids.first.flatMap({ store.node($0) }) else { return String(localized: "Fill Shape") }
            return node.fill.image != nil ? String(localized: "Replace the picture in \(node.name)") : String(localized: "Fill \(node.name)")
        }
        if pictures >= ids.count { return String(localized: "\(ids.count) pictures into \(ids.count) cells") }
        return String(localized: "\(pictures) pictures into \(ids.count) cells, round again")
    }

    /// From a layer's parent's coordinates to the screen.
    private func toView(_ id: UUID) -> CGAffineTransform {
        let vp = store.viewport, o = store.doc.parentOrigin(of: id)
        return CGAffineTransform(translationX: o.x, y: o.y)
            .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
    }

    private func viewOutline(of node: Node) -> CGPath {
        var t = toView(node.id)
        let outline = Renderer.placedOutline(of: node)
        return outline.copy(using: &t) ?? outline
    }

    /// The picture inside a shape, cropped to fill it as a dropped picture will.
    private func drawPicture(_ image: CGImage?, size: CGSize, in node: Node, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(toView(node.id))
        ctx.addPath(Renderer.placedOutline(of: node))
        ctx.clip(using: node.evenOdd == true ? .evenOdd : .winding)
        guard let image else {
            // Still being read: a wash of pencil where it will be.
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.12).cgColor)
            ctx.fill(Renderer.placedOutline(of: node).boundingBoxOfPath)
            return
        }
        ctx.translateBy(x: node.frame.midX, y: node.frame.midY)
        if node.rotation != 0 { ctx.rotate(by: Geometry.radians(node.rotation)) }
        ctx.translateBy(x: -node.frame.width / 2, y: -node.frame.height / 2)
        let rect = Renderer.imageRect(ImageFill(asset: "", mode: .cover, size: size), in: node.frame.size)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
    }

    /// A soft pencil-blue glow round an outline on screen, and a fine line along it.
    private func drawGlow(_ outline: CGPath, breath: Double, strong: Bool, in ctx: CGContext) {
        let s = deviceScale
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: CGFloat(6 + 8 * breath) * s, color: CanvasInk.pencil.withAlphaComponent(strong ? 0.95 : 0.7).cgColor)
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(strong ? 4 : 3)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(strong ? 2 : 1.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Where a picture will lie: itself, faintly, in a dashed frame.
    private func drawGhost(_ image: CGImage?, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * deviceScale), blur: 14 * deviceScale, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.08).cgColor)
        ctx.fill(r)
        ctx.restoreGState()
        if let image {
            ctx.saveGState()
            ctx.setAlpha(0.7)
            ctx.interpolationQuality = .high
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))
        ctx.restoreGState()
    }

    /// What will happen, in a small pencil-blue pill: at the foot of the shape it goes into when
    /// there is room in it, so nothing beside it is hidden, or else under where it happens; kept on screen.
    private func drawLabel(_ text: String, under r: CGRect, inside shape: CGRect?, in bounds: CGRect, _ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var pill = CGRect(x: (r.midX - size.width / 2 - 9).rounded(), y: (r.maxY + 12).rounded(), width: (size.width + 18).rounded(), height: 22)
        if let shape, shape.width >= pill.width + 16, shape.height >= 22 + 24 {
            pill.origin = CGPoint(x: (shape.midX - pill.width / 2).rounded(), y: (shape.maxY - 22 - 10).rounded())
        }
        pill.origin.x = min(max(pill.minX, bounds.minX + 8), bounds.maxX - pill.width - 8)
        if pill.maxY > bounds.maxY - 8 { pill.origin.y = max(bounds.minY + 8, (r.minY - 34).rounded()) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * deviceScale), blur: 4 * deviceScale, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 9, y: pill.minY + (22 - size.height) / 2), withAttributes: attrs)
    }
}
