import Testing
import AppKit
@testable import Bezzle

/// Gradients and pictures where a layer has more than its fill to paint: its borders, a line's
/// stroke, and the letters of text; on the canvas, in a PDF and in SVG.
@MainActor
struct PaintTests {
    private static let red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1), green = RGBA(r: 0, g: 0.8, b: 0)

    /// Red at the left, blue at the right.
    private static let across = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)],
                                         start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }

    private func board(_ layers: [Node], width: CGFloat = 200, height: CGFloat = 100) -> Node {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: width, height: height))
        board.fill.color = .white
        board.children = layers
        return board
    }

    /// Big square letters, which leave no gaps in them to miss: a row of blocks.
    private func blocks(_ count: Int = 6, at p: CGPoint = CGPoint(x: 10, y: 10)) -> Node {
        var t = Node(kind: .text, name: "T", frame: CGRect(origin: p, size: .zero))
        var style = TextStyle()
        style.family = "Menlo"
        style.size = 40
        t.style = style
        t.text = String(repeating: "\u{2588}", count: count)
        t.fill.color = .black
        t.refit()
        return t
    }

    /// The design as a one-page PDF, drawn back as a picture.
    private func throughPDF(_ board: Node, assets: Assets? = nil) throws -> CGImage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: board.frame.size)
        let consumer = try #require(CGDataConsumer(data: data))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        Renderer.drawPDFPage(board, in: ctx, assets: assets)
        ctx.closePDF()
        let provider = try #require(CGDataProvider(data: data))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let bitmap = try #require(Renderer.bitmap(board.frame.size))
        bitmap.setFillColor(CGColor.white)
        bitmap.fill(box)
        bitmap.drawPDFPage(page)
        return try #require(bitmap.makeImage())
    }

    /// A folder holding a picture red on its left half and blue on its right.
    private func halves() throws -> (Assets, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ctx = try #require(Renderer.bitmap(CGSize(width: 2, height: 1)))
        ctx.setFillColor(Self.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(Self.blue.cgColor)
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let picture = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("halves.png"))
        return (Assets(folder: folder), folder)
    }

    private static let halvesFill = ImageFill(asset: "halves.png", mode: .stretch, size: CGSize(width: 2, height: 1))

    // MARK: Borders

    /// A square with no fill and a thick border of `border`.
    private func framed(_ border: Border) -> Node {
        var box = Node(kind: .rectangle, name: "R", frame: CGRect(x: 20, y: 20, width: 160, height: 60))
        box.fill.on = false
        box.border = border
        return box
    }

    @Test func aBorderRunsWithItsGradient() throws {
        for position in Border.Position.allCases {
            var border = Border(on: true, color: .black, width: 8, position: position)
            border.gradient = Self.across
            let image = try #require(Renderer.image(of: board([framed(border)]), scale: 1))
            // Along the top edge: red at the left, blue at the right, and the middle untouched.
            let y = position == .inside ? 23 : position == .center ? 20 : 16
            let left = pixel(image, 24, y), right = pixel(image, 176, y)
            #expect(left.r > 200 && left.b < 60, "\(position) left \(left)")
            #expect(right.b > 200 && right.r < 60, "\(position) right \(right)")
            #expect(pixel(image, 100, 50).r > 250 && pixel(image, 100, 50).b > 250, "\(position) middle")
        }
    }

    @Test func aDashedBorderKeepsItsGapsWithAGradient() throws {
        var border = Border(on: true, color: .black, width: 6, position: .center, dash: 10, gap: 10)
        border.gradient = Self.across
        let image = try #require(Renderer.image(of: board([framed(border)]), scale: 1))
        // Along the top edge some is painted and some is left white.
        let row = (24...176).map { pixel(image, $0, 20) }
        #expect(row.contains { $0.g > 250 } && row.contains { $0.g < 80 }, "\(row.map(\.g))")
    }

    @Test func aPictureFillsABorder() throws {
        let (assets, folder) = try halves()
        defer { try? FileManager.default.removeItem(at: folder) }
        var border = Border(on: true, color: .black, width: 10, position: .outside)
        border.image = Self.halvesFill
        let image = try #require(Renderer.image(of: board([framed(border)]), scale: 1, assets: assets))
        // The picture covers all the border reaches, out past the frame: red on the left, blue on the right.
        let left = pixel(image, 12, 50), right = pixel(image, 188, 50)
        #expect(left.r > 200 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60, "right \(right)")
        #expect(pixel(image, 100, 50).g > 250, "inside, where there is no border")
    }

    @Test func aLineIsStrokedWithAGradient() throws {
        var line = Node(kind: .line, name: "L", frame: CGRect(x: 20, y: 50, width: 160, height: 0))
        line.border = Border(on: true, color: .black, width: 6, position: .center)
        line.border.gradient = Self.across
        let image = try #require(Renderer.image(of: board([line]), scale: 1))
        let left = pixel(image, 26, 50), right = pixel(image, 174, 50)
        #expect(left.r > 200 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60, "right \(right)")
    }

    @Test func aGradientBorderGoesIntoAPDF() throws {
        var border = Border(on: true, color: .black, width: 8, position: .inside)
        border.gradient = Self.across
        let image = try throughPDF(board([framed(border)]))
        #expect(pixel(image, 24, 23).r > 200 && pixel(image, 24, 23).b < 60)
        #expect(pixel(image, 176, 23).b > 200 && pixel(image, 176, 23).r < 60)
        #expect(pixel(image, 100, 50).g > 250)
    }

    // MARK: Text

    @Test func lettersShowTheirGradient() throws {
        var t = blocks()
        t.fill.gradient = Self.across
        let r = t.frame
        let image = try #require(Renderer.image(of: board([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        let y = Int(r.midY)
        let left = pixel(image, Int(r.minX) + 3, y), right = pixel(image, Int(r.maxX) - 4, y)
        #expect(left.r > 200 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60, "right \(right)")
        // Nothing round the letters is painted.
        #expect(pixel(image, Int(r.midX), 3).g > 250)
    }

    @Test func aLetterOfItsOwnColourKeepsItInAGradient() throws {
        var t = blocks()
        t.fill.gradient = Self.across
        // The third block green of its own.
        t.restyleLetters(in: NSRange(location: 2, length: 1)) { $0.color = Self.green }
        let r = t.frame, w = r.width / 6
        let image = try #require(Renderer.image(of: board([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        let own = pixel(image, Int(r.minX + w * 2.5), Int(r.midY))
        #expect(own.g > 150 && own.r < 60 && own.b < 60, "\(own)")
        let painted = pixel(image, Int(r.minX + w * 0.5), Int(r.midY))
        #expect(painted.r > 200 && painted.g < 60, "\(painted)")
    }

    @Test func lettersShowTheirPicture() throws {
        let (assets, folder) = try halves()
        defer { try? FileManager.default.removeItem(at: folder) }
        var t = blocks()
        t.fill.image = Self.halvesFill
        let r = t.frame
        let image = try #require(Renderer.image(of: board([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1, assets: assets))
        let left = pixel(image, Int(r.minX) + 3, Int(r.midY)), right = pixel(image, Int(r.maxX) - 4, Int(r.midY))
        #expect(left.r > 200 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60, "right \(right)")
    }

    @Test func aSeeThroughGradientShowsWhatLiesUnderTheLetters() throws {
        var t = blocks()
        t.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.blue.with(alpha: 0)), GradientStop(offset: 1, color: Self.blue)],
                                   start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        let r = t.frame
        let image = try #require(Renderer.image(of: board([t], width: r.maxX + 10, height: r.maxY + 10), scale: 1))
        // Clear at the left, so the white page shows; solid blue at the right.
        #expect(pixel(image, Int(r.minX) + 1, Int(r.midY)).r > 230)
        #expect(pixel(image, Int(r.maxX) - 2, Int(r.midY)).r < 40)
    }

    @Test func lettersKeepTheirGradientInAPDF() throws {
        var t = blocks()
        t.fill.gradient = Self.across
        t.restyleLetters(in: NSRange(location: 2, length: 1)) { $0.color = Self.green }
        let r = t.frame, w = r.width / 6
        let image = try throughPDF(board([t], width: r.maxX + 10, height: r.maxY + 10))
        let left = pixel(image, Int(r.minX) + 3, Int(r.midY)), right = pixel(image, Int(r.maxX) - 4, Int(r.midY))
        #expect(left.r > 200 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60, "right \(right)")
        let own = pixel(image, Int(r.minX + w * 2.5), Int(r.midY))
        #expect(own.g > 150 && own.r < 60, "own colour \(own)")
        #expect(pixel(image, Int(r.midX), 3).g > 250, "nothing round the letters")
    }

    @Test func aShadowFallsFromLettersOfAGradient() throws {
        var t = blocks(1, at: CGPoint(x: 10, y: 10))
        t.fill.gradient = Self.across
        t.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.8), x: 0, y: 40, blur: 0)
        let r = t.frame
        let image = try #require(Renderer.image(of: board([t], width: r.maxX + 10, height: r.maxY + 60), scale: 1))
        let below = pixel(image, Int(r.midX), Int(r.midY) + 40)
        #expect(below.r < 120 && below.g < 120, "the shadow under it \(below)")
    }

    // MARK: Files

    @Test func oldBordersReadAsTheyWereAndNewOnesKeepTheirPaint() throws {
        let old = #"{"on":true,"color":{"r":0,"g":0,"b":0,"a":1},"width":2,"position":"inside","dash":0,"gap":0}"#
        let read = try JSONDecoder().decode(Border.self, from: Data(old.utf8))
        #expect(read == Border(on: true, color: .black, width: 2, position: .inside))
        var painted = read
        painted.gradient = Self.across
        painted.image = Self.halvesFill
        let back = try JSONDecoder().decode(Border.self, from: JSONEncoder().encode(painted))
        #expect(back == painted)
        #expect(back.paint.gradient == Self.across && back.paint.image == Self.halvesFill)
    }

    @Test func aBorderPictureIsOneTheDesignShows() {
        var n = framed(Border(on: true, color: .black, width: 4))
        n.moreBorders = [Border(on: true, color: .black, width: 2, image: Self.halvesFill)]
        #expect(n.paintedPictures.map(\.asset) == ["halves.png"])
        #expect(n.shows(picture: "halves.png"))
        var doc = BezzleDocument()
        doc.nodes = [board([n])]
        #expect(Collaboration.pictures(in: doc) == ["halves.png"])
    }

    @Test func flippingALayerTurnsItsBorderGradient() {
        var border = Border(on: true, color: .black, width: 4)
        border.gradient = Self.across
        let flipped = BezzleDocument.flipped(framed(border), horizontally: true, about: 100)
        #expect(flipped.border.gradient?.start == CGPoint(x: 1, y: 0.5))
        #expect(flipped.border.gradient?.end == CGPoint(x: 0, y: 0.5))
    }

    @Test func svgPaintsBordersAndLettersWithTheirGradients() throws {
        var border = Border(on: true, color: .black, width: 8, position: .inside)
        border.gradient = Self.across
        var t = blocks(at: CGPoint(x: 10, y: 120))
        t.fill.gradient = Self.across
        let b = board([framed(border), t], width: 300, height: 200)
        let svg = SVGWriter.document(for: ExportItem(artboard: b), bounds: b.frame, assets: nil)
        #expect(XMLParser(data: Data(svg.utf8)).parse())
        #expect(svg.contains("stroke=\"url(#"), "the border strokes with the gradient")
        #expect(svg.components(separatedBy: "<linearGradient").count == 3, "one gradient each")
        #expect(svg.range(of: #"<g font-family="[^"]*" font-size="40"[^>]* fill="url\(#"#, options: .regularExpression) != nil, "the letters fill with it")
    }

    @Test func svgBordersLookAsTheyDoOnTheCanvas() throws {
        let (assets, folder) = try halves()
        defer { try? FileManager.default.removeItem(at: folder) }
        var outside = Border(on: true, color: .black, width: 8, position: .outside)
        outside.gradient = Self.across
        var inside = Border(on: true, color: .black, width: 10, position: .inside)
        inside.image = Self.halvesFill
        var a = framed(outside)
        a.frame = CGRect(x: 20, y: 20, width: 160, height: 60)
        var b = framed(inside)
        b.frame = CGRect(x: 20, y: 110, width: 160, height: 60)
        let page = board([a, b], width: 200, height: 200)
        let svg = SVGWriter.document(for: ExportItem(artboard: page), bounds: page.frame, assets: assets)
        let drawn = try #require(NSImage(data: Data(svg.utf8)))
        func pixels(_ draw: (CGContext) -> Void) -> [UInt8] {
            let ctx = Renderer.bitmap(CGSize(width: 200, height: 200))!
            draw(ctx)
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * 200))
        }
        let theirs = pixels { ctx in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            drawn.draw(in: NSRect(x: 0, y: 0, width: 200, height: 200))
            NSGraphicsContext.current = nil
        }
        let image = try #require(Renderer.image(of: page, scale: 1, assets: assets))
        let ours = pixels { $0.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200)) }
        var total = 0, far = 0
        for i in stride(from: 0, to: ours.count, by: 4) {
            let d = (0..<3).map { abs(Int(ours[i + $0]) - Int(theirs[i + $0])) }.max()!
            total += d
            if d > 60 { far += 1 }
        }
        #expect(Double(total) / 40_000 < 4, "mean difference \(Double(total) / 40_000)")
        #expect(far < 40_000 / 50, "\(far) pixels far apart")
    }

    @Test func svgPaintsBordersAndLettersWithTheirPictures() throws {
        let (assets, folder) = try halves()
        defer { try? FileManager.default.removeItem(at: folder) }
        var border = Border(on: true, color: .black, width: 8, position: .outside)
        border.image = Self.halvesFill
        var t = blocks(at: CGPoint(x: 10, y: 120))
        t.fill.image = Self.halvesFill
        let b = board([framed(border), t], width: 300, height: 200)
        let svg = SVGWriter.document(for: ExportItem(artboard: b), bounds: b.frame, assets: assets)
        #expect(XMLParser(data: Data(svg.utf8)).parse())
        #expect(svg.components(separatedBy: "<pattern").count == 3)
        #expect(svg.contains("stroke=\"url(#pattern"))
        #expect(svg.contains("fill=\"url(#pattern"))
    }
}

/// Painting borders and letters with gradients and pictures from the inspector, by dropping a
/// picture, and through the tools.
@MainActor
struct PaintEditingTests {
    let bench = Bench()
    let tools = MCPTools()

    init() {
        MCPTools.opened(bench.store)
    }

    private func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call(name, arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
    }

    private static let across = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 0, b: 0)), GradientStop(offset: 1, color: RGBA(r: 0, g: 0, b: 1))],
                                         start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))

    @discardableResult
    private func add(_ node: Node) -> UUID {
        bench.step { bench.store.add(node, onto: bench.a.id) }
        let id = bench.node(node.name)!.id
        bench.store.selection = [id]
        return id
    }

    private func framed() -> Node {
        var r = CanvasTests.rect("R", CGRect(x: 40, y: 40, width: 100, height: 60))
        r.border = Border(on: true, color: .black, width: 4, position: .inside)
        return r
    }

    /// "Hello World", "World" red of its own.
    private func hello() -> Node {
        var t = Node(kind: .text, name: "T", frame: CGRect(x: 40, y: 150, width: 0, height: 0))
        t.text = "Hello World"
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.color = RGBA(r: 1, g: 0, b: 0) }
        t.refit()
        return t
    }

    /// A picture file, red, somewhere the design can copy it from.
    private func pictureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).png")
        let ctx = try #require(Renderer.bitmap(CGSize(width: 4, height: 4)))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(ctx.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func theFillMenuReachesABorderThroughItsPaint() {
        var n = framed()
        n.moreBorders = [Border(on: true, color: .white, width: 1)]
        n[keyPath: PaintTarget.border(1).path].gradient = Self.across
        #expect(n.moreBorders?.first?.gradient == Self.across && n.border.gradient == nil)
        n[keyPath: PaintTarget.border(0).path].image = ImageFill(asset: "a.png", size: CGSize(width: 1, height: 1))
        #expect(n.border.image?.asset == "a.png" && n.border.on)
        #expect(PaintTarget.border(3).takesPicture && PaintTarget.fill(0).takesPicture && !PaintTarget.fill(1).takesPicture)
    }

    @Test func paintingTextAnewTakesAwayItsLettersOwnColours() {
        let id = add(hello())
        bench.step { bench.store.updatePaint(.fill(0), "Fill with a Gradient") { $0.gradient = Self.across } }
        let t = bench.store.node(id)!
        #expect(t.fill.gradient == Self.across)
        #expect(t.spans?.contains { $0.look.color != nil } != true, "\(String(describing: t.spans))")
        #expect(t.text == "Hello World")
        // A shape's fill changes as it is, and one undo brings the colours back.
        bench.undo.undo()
        #expect(bench.store.node(id)!.spans?.contains { $0.look.color != nil } == true)
    }

    @Test func aPictureDroppedOnTextFillsItsLetters() throws {
        let id = add(hello())
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let dropped = Dropped(pictures: [file])
        let at = bench.store.doc.absoluteFrame(of: id)!.center
        guard case .fill(let targets) = bench.store.plan(for: dropped, at: at, on: id) else {
            Issue.record("a picture over text should fill it")
            return
        }
        #expect(targets == [id])
        bench.step { _ = bench.store.drop(dropped, at: at, on: id) }
        let t = bench.store.node(id)!
        #expect(t.fill.image != nil && t.fill.on)
        #expect(t.spans?.contains { $0.look.color != nil } != true)
        #expect(Collaboration.pictures(in: bench.store.doc).count == 1)
    }

    @Test func aGradientBorderOutlinedFillsItsShapeWithTheGradient() {
        var r = framed()
        r.fill.on = false
        r.border.width = 10
        r.border.position = .outside
        r.border.gradient = Self.across
        let id = add(r)
        bench.step { bench.store.outlineBorders() }
        let shape = bench.store.node(id)!
        #expect(shape.kind == .path)
        let g = shape.fill.gradient
        #expect(g != nil && shape.fill.on)
        // Grown by the border outside, the gradient lies where it lay: its ends inside the new box.
        if let g {
            #expect(g.start.x > 0.05 && g.end.x < 0.95, "\(g)")
        }
    }

    @Test func theToolsSetAndReadABorderGradient() async {
        add(framed())
        var answer = await call("update_layers", ["updates": [["layer": "R",
            "border": ["gradient": ["type": "linear", "stops": ["#FF0000", "#0000FF"], "angle": 90]]]]])
        #expect(!answer.failed, "\(answer.text)")
        var r = bench.node("R")!
        #expect(r.border.gradient?.stops.count == 2 && r.border.width == 4)
        let read = await call("get_layers", ["layers": ["R"]])
        let layer = ((try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any])?["layers"] as? [[String: Any]]
        #expect((layer?.first?["border"] as? [String: Any])?["gradient"] != nil, "\(read.text)")
        // A colour on its own makes it solid again.
        answer = await call("update_layers", ["updates": [["layer": "R", "border": "#00FF00"]]])
        r = bench.node("R")!
        #expect(r.border.gradient == nil && r.border.color.hex == "00FF00")
    }

    @Test func theToolsPutAPictureInABorderAndInLetters() async throws {
        add(framed())
        add(hello())
        let file = try pictureFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // A design that can hold pictures, as one made now is.
        _ = bench.store.importPicture(file)
        var answer = await call("place_image", ["file": file.path, "layer": "R", "into": "border"])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.node("R")!.border.image != nil && bench.node("R")!.fill.image == nil)
        answer = await call("place_image", ["file": file.path, "layer": "T"])
        #expect(!answer.failed, "\(answer.text)")
        #expect(bench.node("T")!.fill.image != nil)
        answer = await call("place_image", ["file": file.path, "layer": "T", "into": "border"])
        #expect(answer.failed)
    }
}
