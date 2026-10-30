import Testing
import AppKit
import QuartzCore
@testable import Bezzle

/// An artboard drawn from tiles looks as it does drawn layer by layer, at any zoom, and still
/// does after it changes and only some tiles are made again.
@MainActor
struct TilesTests {
    /// An artboard with something of everything, some of it across the edges between tiles.
    private func board() -> Node {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 36, y: 52, width: 600, height: 400))
        board.fill.color = .white
        var a = Node(kind: .rectangle, name: "A", frame: CGRect(x: 10, y: 10, width: 120, height: 80))
        a.fill.color = RGBA(r: 0.9, g: 0.2, b: 0.2, a: 1)
        a.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.5), x: 0, y: 8, blur: 12)
        // Across the tile edges at about 242 points, with its shadow falling over the one below.
        var across = Node(kind: .rectangle, name: "Across", frame: CGRect(x: 200, y: 200, width: 80, height: 30))
        across.fill.color = RGBA(r: 0.2, g: 0.6, b: 0.3, a: 1)
        across.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 20, blur: 10)
        var turned = Node(kind: .rectangle, name: "Turned", frame: CGRect(x: 380, y: 40, width: 100, height: 60))
        turned.rotation = 30
        turned.fill.color = RGBA(r: 0.2, g: 0.3, b: 0.9, a: 1)
        turned.border = Border(on: true, color: .black, width: 3)
        var text = Node(kind: .text, name: "T", frame: CGRect(x: 20, y: 120, width: 0, height: 0))
        text.text = "Tiles meet without a seam"
        text.refit()
        var square = Node(kind: .rectangle, name: "Square", frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        square.fill.color = RGBA(r: 0.1, g: 0.7, b: 0.7, a: 1)
        var round = Node(kind: .ellipse, name: "Round", frame: CGRect(x: 50, y: 40, width: 90, height: 90))
        round.fill.color = RGBA(r: 0.95, g: 0.8, b: 0.1, a: 1)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 420, y: 230, width: 140, height: 130))
        group.opacity = 0.7
        group.children = [square, round]
        var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 100, y: 60, width: 200, height: 120))
        glass.fill.color = .white
        glass.blur = Blur(radius: 8, background: true, brightness: 0, fillOpacity: 0.2)
        var shape = Node(kind: .path, name: "Shape", frame: .zero)
        shape.path = Self.shapeData(apex: CGPoint(x: 120, y: 80))
        shape.pathBox = PathData.bounds(shape.path!)
        shape.frame = shape.pathBox!.offsetBy(dx: 40, dy: 250)
        shape.fill.color = RGBA(r: 0.9, g: 0.5, b: 0.1, a: 1)
        shape.border = Border(on: true, color: .black, width: 2)
        board.children = [a, across, turned, text, group, glass, shape]
        return board
    }

    /// A shape of a few straight sides and a curve, one of its points at `apex`, in its own coordinates.
    static func shapeData(apex: CGPoint) -> String {
        "M 0 0 L 100 0 L \(apex.x) \(apex.y) C 110 120 60 130 30 120 L 10 60 Z"
    }

    private var options: Renderer.Options {
        var o = Renderer.Options()
        o.artboardShadows = true
        return o
    }

    /// The pixels of `rect` on the canvas at `scale`, drawn by `body` in canvas points.
    private func canvas(_ rect: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> [UInt8] {
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        let ctx = Renderer.bitmap(CGSize(width: w, height: h))!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        Renderer.withFlippedContext(ctx) { body(ctx) }
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: ctx.bytesPerRow * h))
    }

    private func direct(_ board: Node, _ rect: CGRect, scale: CGFloat) -> [UInt8] {
        canvas(rect, scale: scale) { ctx in
            var o = options
            o.deviceScale = scale
            o.visible = rect
            Renderer.drawArtboard(board, in: ctx, options: o)
        }
    }

    /// Drawn from `tiles`, `now` seconds in, and again once a moment has passed, as the canvas
    /// does while tiles are still to come; counts the tiles made, leaving out the pictures of the
    /// whole artboard, and the parts drawn directly.
    private func tiled(_ board: Node, _ rect: CGRect, scale: CGFloat, tiles: BoardTiles, now: CFTimeInterval,
                       made: inout Int, directly: inout Int) -> [UInt8] {
        var m = 0, d = 0
        let whole = BoardTiles.overviewStep(board.frame.size, shadowPixels: 28 * scale)
        var out: [UInt8] = []
        for t in [now, now + 0.5] {
            out = canvas(rect, scale: scale) { ctx in
                var o = options
                o.deviceScale = scale
                o.visible = rect
                tiles.begin(scale: scale, now: t, artboards: [board.id])
                _ = tiles.draw(board, in: ctx, visible: rect, shadowPixels: 28 * scale, now: t, deadline: .infinity, live: false) { part, step, changing in
                    if step != whole || BoardTiles.step(for: scale) <= whole { m += 1 }
                    var making = o
                    making.settling = changing
                    return Renderer.tile(of: board, rect: part, scale: step, options: making)
                }
            }
        }
        made += m
        directly += d
        return out
    }

    /// How many pixels are more than a little apart, and the most any channel is apart, and
    /// where they are. With BEZZLE_TILES_OUT set, both pictures are saved there to be looked at.
    private func difference(_ a: [UInt8], _ b: [UInt8], width: Int = 0, name: String = "") -> (pixels: Int, most: Int, mean: Double, at: CGRect) {
        var pixels = 0, most = 0, at = CGRect.null, sum = 0
        let row = width * 4
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(a[i + c]) - Int(b[i + c]))) }
            sum += d
            if d > 3 {
                pixels += 1
                if row > 0 { at = at.union(CGRect(x: (i % row) / 4, y: i / row, width: 1, height: 1)) }
            }
            most = max(most, d)
        }
        if pixels > 0, row > 0, let out = ProcessInfo.processInfo.environment["BEZZLE_TILES_OUT"] {
            var marks = a
            for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
                var d = 0
                for c in 0..<4 { d = max(d, abs(Int(a[i + c]) - Int(b[i + c]))) }
                if d > 3 { marks[i] = 255; marks[i + 1] = 0; marks[i + 2] = 0; marks[i + 3] = 255 } else { marks[i + 3] = 60; marks[i] = 60; marks[i + 1] = 60; marks[i + 2] = 60 }
            }
            for (bytes, kind) in [(a, "direct"), (b, "tiled"), (marks, "marks")] {
                var copy = bytes
                let ctx = CGContext(data: &copy, width: width, height: bytes.count / row, bitsPerComponent: 8, bytesPerRow: row,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name)-\(kind).png"))
            }
        }
        return (pixels, most, Double(sum) / Double(max(1, min(a.count, b.count) / 4)), at)
    }

    @Test(arguments: [0.5, 1, 1.4142135623730951, 2, 8] as [CGFloat])
    func tilesLookLikeTheArtboard(scale: CGFloat) {
        let b = board()
        // Up close, only part of it is in sight.
        let rect = scale > 4 ? CGRect(x: 36 + 180, y: 52 + 170, width: 120, height: 100) : b.frame.insetBy(dx: -20, dy: -20)
        var made = 0, directly = 0
        let t = tiled(b, rect, scale: scale, tiles: BoardTiles(), now: 100, made: &made, directly: &directly)
        let d = difference(direct(b, rect, scale: scale), t, width: Int(rect.width * scale), name: "scale-\(scale)")
        #expect(made > 0)
        #expect(directly == 0)
        // Drawn at the step tiles are made at, they match to the pixel; between steps, only the
        // stretching tells them apart.
        // Where the artboard's corner falls on a whole pixel, the tiles are copied as they were
        // made and match but for a few pixels of antialiasing; elsewhere they are a fraction of
        // a pixel over, or stretched, and match to a little on average.
        let drawnAt = max(BoardTiles.step(for: scale), BoardTiles.overviewStep(b.frame.size, shadowPixels: 28 * scale))
        if b.frame.minX * scale == (b.frame.minX * scale).rounded(), drawnAt == scale {
            #expect(d.pixels <= Int(rect.width * rect.height * scale * scale) / 10_000, "at \(scale): \(d)")
        } else {
            #expect(d.mean < 2, "at \(scale): \(d)")
        }
    }

    @Test func onlyTheTilesAChangeTouchesAreMadeAgain() {
        let tiles = BoardTiles()
        var b = board()
        let scale: CGFloat = 2
        let rect = CGRect(x: 0, y: 0, width: 720, height: 520)
        var made = 0, directly = 0, now: CFTimeInterval = 100
        _ = tiled(b, rect, scale: scale, tiles: tiles, now: now, made: &made, directly: &directly)
        let all = made
        /// Draws the change, and again once it has settled, and compares that with the artboard.
        func check(_ name: String) {
            made = 0
            now += 1
            _ = tiled(b, rect, scale: scale, tiles: tiles, now: now, made: &made, directly: &directly)
            now += 1
            let t = tiled(b, rect, scale: scale, tiles: tiles, now: now, made: &made, directly: &directly)
            let d = difference(direct(b, rect, scale: scale), t, width: Int(rect.width * scale), name: name)
            // A turned edge can come out a shade apart in a few pixels, where it falls in its tile.
            #expect(d.pixels <= 20 && d.most <= 8, "\(name): \(d)")
        }

        // The rectangle in the top left corner moves a little: only the tiles there.
        b.children[0].frame.origin.x += 6
        check("moved")
        #expect(made >= 1 && made < all, "made \(made) of \(all)")

        // Inside the group, which changes size around it.
        b.children[4].children[1].frame.origin.y += 30
        b.children[4].children[1].fill.color = RGBA(r: 0.5, g: 0.1, b: 0.6, a: 1)
        var doc = BezzleDocument()
        doc.nodes = [b]
        doc.fitGroups()
        b = doc.nodes[0]
        check("grouped")
        #expect(made >= 1 && made < all, "made \(made) of \(all)")

        // Hidden, and moved to the top.
        b.children[2].hidden = true
        check("hidden")
        b.children.append(b.children.remove(at: 1))
        check("reordered")

        // Under the glass, which shows it once things settle.
        b.children[0].fill.color = RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1)
        b.children[0].frame.origin = CGPoint(x: 150, y: 90)
        check("under glass")

        // One point of a path moves: only the curves either side of it.
        made = 0
        let before = b.children[6]
        var shape = before
        shape.path = Self.shapeData(apex: CGPoint(x: 150, y: 70))
        shape.pathBox = PathData.bounds(shape.path!)
        shape.frame = shape.pathBox!.offsetBy(dx: 40, dy: 250)
        b.children[6] = shape
        check("path point moved")
        #expect(made >= 1 && made < all, "made \(made) of \(all)")

        // A lock or a new name makes nothing again.
        b.children[0].locked = true
        b.children[3].name = "Words"
        check("locked")
        #expect(made == 0)

        // Moving the whole artboard keeps every tile.
        b.frame.origin.x += 40
        check("artboard moved")
        #expect(made == 0)
        #expect(directly == 0)
    }
}
