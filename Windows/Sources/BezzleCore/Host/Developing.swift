import Foundation
import CBezzleHost

// Pictures on their way in a shared design, as the Mac's LiveMarks.drawDeveloping shows them: a
// picture someone placed that this computer does not have yet develops where it is, as a
// photograph does, from its glimpse, milky and grainy, its colours coming slowly, breathing as a
// print rocked in a tray; with no glimpse, as paper not yet exposed. Once it is here it is drawn
// into focus, the glimpse fading off it as the grain goes, with a little light at the moment it
// comes. Drawn by the core with Skia's own blend modes over what the canvas shows there (the
// grain overlaid on the picture, the light screened), so it mixes with the picture as on the Mac,
// which a separate layer over the canvas could not do. The window draws it again where it is:
// every frame while it clears at first and while it comes into focus, a dozen times a second
// otherwise, as its grain moves.

extension WindowsCore {
    /// A layer showing a picture on its way, in sight (`LiveScene.developing`).
    public struct LiveDeveloping: Sendable {
        public let id: UUID
        /// The design's layer it is in, by its place among them: an artboard, or a layer on the canvas.
        public var place: Int
        /// As far as it reaches on the canvas, in canvas points.
        public var box: CGRect
    }

    /// Part `part` of the design's layer at `place` (an artboard, or a layer lying on the canvas),
    /// on the canvas, drawn as the canvas draws it at `scale` pixels a point, the layers `hiding`
    /// left out, with the pictures on their way in it developing over it as they are this moment
    /// for a view at `zoom`: premultiplied BGRA, rows top first, into what `fill` gives for its
    /// size. With others' motion shown, inside `drawingOthersMotion`, as the canvas's.
    public static func drawDeveloping(place: Int, part: CGRect, scale: Double, zoom: Double, hiding: Set<UUID> = [],
                                      into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let ways = live?.onTheirWay else { return false }
        return drawDeveloping(ways, place: place, part: part, scale: scale, zoom: zoom, now: now, hiding: hiding, bgra: true, into: fill)
    }

    static func drawDeveloping(_ ways: PicturesOnTheirWay, place: Int, part: CGRect, scale: Double, zoom: Double, now: Double, hiding: Set<UUID>,
                               bgra: Bool, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard var doc = design, doc.nodes.indices.contains(place) else { return false }
        let s = CGFloat(scale)
        let size = CGSize(width: max(1, (part.width * s).rounded()), height: max(1, (part.height * s).rounded()))
        // As `render(board:)` draws it: the text typed into, and letters on their way, left out.
        for id in hiding { doc.update(id) { $0.hidden = true } }
        if let id = typing?.id, doc.node(id)?.isCurved == true { doc.update(id) { $0 = LetterFlights.straight($0, frame: $0.frame).node } }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let ctx = Renderer.bitmap(size) else { return false }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -part.minX, y: -part.minY)
        let node = seen(doc.nodes[place])
        Renderer.withFlippedContext(ctx) {
            var options = Renderer.Options(deviceScale: s, assets: assets)
            if node.isArtboard {
                options.visible = part
                Renderer.drawArtboard(node, in: ctx, options: options)
            } else {
                Renderer.drawNode(node, in: ctx, options: options)
            }
        }
        ways.draw(ctx, place: place, in: doc, zoom: CGFloat(zoom), within: part, now: now)
        guard let image = ctx.makeImage() else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), bgra ? 1 : 0, pixels) == 0
    }

    /// For comparing with the Mac's LiveMarks (bezzle-render's BEZZLE_DEVELOPING): the open
    /// design's first artboard as a view of it at `zoom` shows it, its picture `name` on its way at
    /// each moment `frames` gives (when it started developing, now, and when it came if it has),
    /// its glimpse `glimpse` from the first frame that says it had one, the picture itself (the file
    /// `picture`) from the first that says it came; each written to `out` as developing-<n>.png.
    public static func developingCheck(name: String, glimpse: Data, picture: URL, zoom: Double,
                                       frames: [(since: Double, now: Double, glimpsed: Bool, arrived: Double?)], out: URL) throws -> [String] {
        guard let board = design?.nodes.firstIndex(where: \.isArtboard), let frame = design?.nodes[board].frame else { return ["no artboard"] }
        let ways = PicturesOnTheirWay()
        var said: [String] = []
        for (k, f) in frames.enumerated() {
            if f.glimpsed, glimpseImages[name] == nil, ways.all[name]?.arrived == nil {
                standIn(LiveGlimpse(name: name, jpeg: glimpse))
                assets = Assets(folder: assets.folder)
            }
            if f.arrived != nil, ways.all[name]?.arrived == nil, let data = try? Data(contentsOf: picture) {
                giveSkia(name, data)
                glimpseDone(name)
            }
            let kept = ways.all[name]
            ways.all[name] = .init(since: f.since, standIn: f.glimpsed ? (kept?.standIn ?? glimpseImages[name]) : nil, arrived: f.arrived)
            var pixels: [UInt8] = []
            var size = (0, 0)
            let started = Date()
            let drew = drawDeveloping(ways, place: board, part: frame, scale: zoom, zoom: zoom, now: f.now, hiding: [], bgra: false) { w, h in
                pixels = [UInt8](repeating: 0, count: w * h * 4)
                size = (w, h)
                return pixels.withUnsafeMutableBytes { $0.baseAddress }
            }
            guard drew else { said.append("frame \(k): not drawn"); continue }
            try writePNG(pixels, width: size.0, height: size.1, to: out.appendingPathComponent("developing-\(k).png"))
            said.append("frame \(k): waited \(String(format: "%.3f", f.now - f.since)) s\(f.arrived.map { String(format: ", came %.3f s ago", f.now - $0) } ?? ""), "
                        + "\(size.0)×\(size.1) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
        return said
    }
}

/// The pictures on their way in a shared design's live room, by name (the Mac's
/// LiveRoom.developing), and how they are drawn (the Mac's LiveMarks.drawDeveloping).
final class PicturesOnTheirWay {
    /// A picture on its way, shown by its glimpse when one came (`standIn`), developing until it
    /// comes, then drawn into focus (the Mac's LiveRoom.Developing).
    struct Developing {
        var since: Double
        var standIn: CGImage?
        var arrived: Double?
    }

    var all: [String: Developing] = [:]
    /// The layers showing them, worked out again only as the design or they change.
    private var found: (version: Int, names: Set<String>, layers: [(id: UUID, name: String, place: Int)]) = (-1, [], [])

    /// How long a picture takes to come into focus once it is here (the Mac's LiveMarks.focusing).
    static let focusing = 1.1
    /// How long a picture on its way clears quickly at first, drawn every frame; after that it
    /// only breathes and its grain moves, a dozen times a second, until it comes.
    static let clearing = 2.5

    /// Pictures that have finished coming into focus are let go (the Mac's LiveRoom.developed).
    func developed(before now: Double) {
        for (name, d) in all where d.arrived.map({ now - $0 > Self.focusing }) ?? false { all[name] = nil }
    }

    /// The layers showing pictures on their way, by the place among the design's layers each is
    /// in, as the Mac's LiveMarks finds them: shown, not texts, filled with the picture.
    func layers(_ doc: BezzleDocument) -> [(id: UUID, name: String, place: Int)] {
        let names = Set(all.keys)
        guard !names.isEmpty else { return [] }
        if found.version == WindowsCore.designVersion, found.names == names { return found.layers }
        var out: [(UUID, String, Int)] = []
        func visit(_ n: Node, _ place: Int) {
            if !n.hidden, n.kind != .text, n.fill.on, let image = n.fill.image, names.contains(image.shown) { out.append((n.id, image.shown, place)) }
            for c in n.children { visit(c, place) }
        }
        for (place, n) in doc.nodes.enumerated() { visit(n, place) }
        found = (WindowsCore.designVersion, names, out)
        return out
    }

    /// The layers showing pictures on their way that are in sight in a view `vp` of `size` view
    /// points, for the window to draw again.
    func shown(_ doc: BezzleDocument, _ vp: Viewport, _ size: CGSize) -> [WindowsCore.LiveDeveloping] {
        let seen = CGRect(x: vp.origin.x, y: vp.origin.y, width: size.width / vp.zoom, height: size.height / vp.zoom)
        var out: [WindowsCore.LiveDeveloping] = []
        for (id, name, place) in layers(doc) {
            guard all[name] != nil, let (outline, _, _) = Self.placed(id, in: doc) else { continue }
            let box = outline.boundingBoxOfPath
            guard box.intersects(seen) else { continue }
            out.append(.init(id: id, place: place, box: box))
        }
        return out
    }

    /// A layer's outline on the canvas, with how its picture is placed in it, from its middle
    /// turned as it is (the Mac's `place`, without the view's part).
    private static func placed(_ id: UUID, in doc: BezzleDocument) -> (CGPath, CGAffineTransform, Node)? {
        guard let node = doc.node(id) else { return nil }
        let o = doc.parentOrigin(of: id)
        let size = node.frame.size
        let place = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
            .concatenating(CGAffineTransform(translationX: o.x + node.frame.midX, y: o.y + node.frame.midY))
        var t = place
        guard let outline = Renderer.outline(of: node).copy(using: &t) else { return nil }
        return (outline, place, node)
    }

    /// The pictures on their way in the design's layer at `place`, drawn over what the canvas
    /// shows there, in canvas points, for a view at `zoom`, as far as `within`: the Mac's
    /// LiveMarks.drawDeveloping, which draws in view points (its sizes here divided by the zoom).
    func draw(_ ctx: CGContext, place: Int, in doc: BezzleDocument, zoom: CGFloat, within: CGRect, now: Double) {
        for (id, name, at) in layers(doc) where at == place {
            guard let d = all[name], let (outline, place, node) = Self.placed(id, in: doc), let image = node.fill.image else { continue }
            let box = outline.boundingBoxOfPath
            guard box.intersects(within) else { continue }
            let size = node.frame.size
            let waited = now - d.since
            // How far it has come into focus, once it is here.
            let focus = d.arrived.map { CGFloat(min(max((now - $0) / Self.focusing, 0), 1)) } ?? 0
            // Gently out of the blur, then surely into focus.
            let leaving = 1 - focus * focus * (3 - 2 * focus)
            let opacity = CGFloat(node.opacity)
            ctx.saveGState()
            ctx.clip(to: within)
            if let parent = doc.parent(of: id), let mask = Mask.outline(of: parent.id, in: doc) {
                ctx.addPath(mask)
                ctx.clip()
            }
            ctx.addPath(outline)
            ctx.clip(using: node.evenOdd == true ? .evenOdd : .winding)
            // Each drawn straight onto the picture, so the grain and the light mix with it.
            if let standIn = d.standIn {
                // Coming into focus: the glimpse, drawn where the picture is, fading off it.
                if d.arrived != nil, leaving > 0.001 {
                    ctx.saveGState()
                    ctx.setAlpha(leaving * opacity)
                    ctx.concatenate(place)
                    let rect = Renderer.imageRect(image, in: size)
                    ctx.interpolationQuality = .high
                    ctx.translateBy(x: rect.midX, y: rect.midY)
                    ctx.scaleBy(x: image.flippedX == true ? -1 : 1, y: image.flippedY == true ? 1 : -1)
                    ctx.draw(Developer.developed(standIn, image.develop), in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
                    ctx.restoreGState()
                }
                // Milky at first, clearing as it develops, never quite clear until it is here, and
                // breathing slowly while it waits, as a print does in a tray rocked gently.
                let breath = 0.035 * (1 - cos(2 * .pi * waited / 3.4)) / 2
                let milk = CGFloat(0.1 + 0.5 * exp(-waited / 1.5) + breath) * leaving * opacity
                ctx.setFillColor(Self.paper.copy(alpha: milk) ?? Self.paper)
                ctx.fill(box)
            } else {
                // Paper not yet exposed, which the picture develops out of once it comes.
                ctx.setFillColor(Self.paper.copy(alpha: pow(leaving, 1.4) * opacity) ?? Self.paper)
                ctx.fill(box)
            }
            // A little light at the moment it comes into focus.
            if d.arrived != nil {
                ctx.setBlendMode(.screen)
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.16 * sin(.pi * focus) * opacity))
                ctx.fill(box)
                ctx.setBlendMode(.normal)
            }
            Self.drawGrain(ctx, in: box, alpha: 0.2 * leaving * opacity, now: now, zoom: zoom)
            ctx.restoreGState()
        }
    }

    /// Photographic paper, a warm white.
    private static let paper = CGColor(srgbRed: 0.955, green: 0.94, blue: 0.91, alpha: 1)

    /// Film grain, moving a dozen times a second for as long as the picture is on its way: tiles
    /// half the grain's pixels across in view points, from a corner that moves with each frame.
    private static func drawGrain(_ ctx: CGContext, in box: CGRect, alpha: CGFloat, now: Double, zoom: CGFloat) {
        guard alpha > 0.005, let grain = grain else { return }
        let frame = Int(now * 12)
        var r = UInt64(truncatingIfNeeded: frame) &* 0x9E37_79B9_7F4A_7C15
        r ^= r >> 29
        let dx = CGFloat(r % 97) / zoom, dy = CGFloat((r >> 8) % 89) / zoom
        let side = CGFloat(grainSide) / 2 / zoom
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setBlendMode(.overlay)
        ctx.interpolationQuality = .none
        // Tiled, as Core Graphics tiles it, over as much as the box needs.
        var y = box.minY - dy
        while y < box.maxY {
            var x = box.minX - dx
            while x < box.maxX {
                ctx.draw(grain, in: CGRect(x: x, y: y, width: side, height: side))
                x += side
            }
            y += side
        }
        ctx.restoreGState()
    }

    private static let grainSide = 192

    /// Noise about a mid grey, which overlaid leaves the picture as it is but for its grain (the
    /// Mac's, number for number).
    private static let grain: CGImage? = {
        let side = grainSide
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        var r: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in 0..<(side * side) {
            r ^= r << 13; r ^= r >> 7; r ^= r << 17
            // Two draws averaged: softer than white noise, as grain is.
            let a = Int(r & 0xFF), b = Int((r >> 8) & 0xFF)
            let v = UInt8(clamping: 128 + ((a + b) / 2 - 128) * 3 / 2)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}
