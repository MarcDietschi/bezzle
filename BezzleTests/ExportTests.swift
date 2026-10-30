import Testing
import AppKit
@testable import Bezzle

/// Exporting a layer on its own, and writing a design as SVG.
@MainActor
struct ExportTests {
    /// A design of one artboard with something of most kinds on it.
    private func design() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 100, y: 50, width: 300, height: 200))
        board.fill.color = RGBA(r: 0.95, g: 0.95, b: 0.9, a: 1)
        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 10.5, y: 20.25, width: 40, height: 30))
        card.fill.color = RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1)
        var lifted = Node(kind: .rectangle, name: "Lifted", frame: CGRect(x: 120, y: 30, width: 60, height: 40))
        lifted.cornerRadius = 8
        lifted.fill.color = RGBA(r: 0.9, g: 0.3, b: 0.3, a: 1)
        lifted.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.4), x: 0, y: 6, blur: 10)
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        dot.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 0.8, b: 0, a: 1)),
                                                             GradientStop(offset: 1, color: RGBA(r: 0.8, g: 0, b: 0.6, a: 1))],
                                     start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        var bar = Node(kind: .rectangle, name: "Bar", frame: CGRect(x: 40, y: 10, width: 50, height: 12))
        bar.fill.color = RGBA(r: 0.1, g: 0.6, b: 0.4, a: 1)
        bar.border = Border(on: true, color: .black, width: 2, position: .inside)
        var group = Node(kind: .group, name: "Badge", frame: CGRect(x: 200, y: 120, width: 90, height: 30))
        group.children = [dot, bar]
        var shape = Node(kind: .path, name: "Shape", frame: .zero)
        shape.path = "M 0 0 L 60 0 L 70 40 C 50 60 20 60 0 40 Z"
        shape.pathBox = PathData.bounds(shape.path!)
        shape.frame = shape.pathBox!.offsetBy(dx: 30, dy: 110)
        shape.rotation = 15
        shape.fill.color = RGBA(r: 0.5, g: 0.2, b: 0.7, a: 0.8)
        board.children = [card, lifted, group, shape]
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    private func id(_ name: String, in doc: BezzleDocument) -> UUID { doc.allNodes.first { $0.name == name }!.id }

    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let ctx = Renderer.bitmap(CGSize(width: image.width, height: image.height))!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.data!.assumingMemoryBound(to: UInt8.self)[y * ctx.bytesPerRow + x * 4 + 3]
    }

    @Test func aLayerGoesOutAsBigAsItIs() throws {
        let doc = design()
        let card = try #require(ExportItem(layer: id("Card", in: doc), in: doc))
        let (image, rect) = try #require(card.picture(scale: 2, opaque: false, assets: nil))
        // Just the card, though it lies at half a point: its edges fall on whole pixels, sharp.
        #expect(image.width == 80 && image.height == 60)
        #expect(rect == CGRect(x: 110.5, y: 70.25, width: 40, height: 30))
        #expect(alpha(image, 0, 0) == 255 && alpha(image, 79, 59) == 255)
    }

    @Test func aShadowWidensWhatGoesOut() throws {
        let doc = design()
        let lifted = try #require(ExportItem(layer: id("Lifted", in: doc), in: doc))
        let (image, rect) = try #require(lifted.picture(scale: 1, opaque: false, assets: nil))
        #expect(rect.minY < 80 && rect.maxY > 80 + 40 + 6, "the shadow falls below: \(rect)")
        #expect(image.width > 60 && image.height > 40)
        // On white for a JPEG, the clear around it is white.
        let (white, _) = try #require(lifted.picture(scale: 1, opaque: true, assets: nil))
        #expect(alpha(white, 0, 0) == 255)
    }

    @Test func aShadowInsideStaysInside() throws {
        var doc = design()
        doc.update(id("Lifted", in: doc)) { $0.shadow.inset = true }
        doc.update(id("Badge", in: doc)) { $0.shadow = Shadow(on: true, color: .shadow, x: 0, y: 2, blur: 4, inset: true) }
        // Going out, it widens nothing.
        let lifted = try #require(ExportItem(layer: id("Lifted", in: doc), in: doc))
        let rect = lifted.bounds(assets: nil)
        #expect(abs(rect.width - 60) < 1 && abs(rect.height - 40) < 1, "\(rect)")
        // In SVG, cast from all around and kept to the inside, with nothing dropped under.
        let board = ExportItem(artboard: doc.nodes[0])
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: nil), assets: nil)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(!svg.contains("<feDropShadow"))
        #expect(svg.components(separatedBy: "tableValues=\"1 0\"").count == 3, "one for the shape, one for the group")
        #expect(svg.contains("<feMergeNode in=\"inner\"/>"))
    }

    @Test func aGroupGoesOutWhole() throws {
        let doc = design()
        let badge = try #require(ExportItem(layer: id("Badge", in: doc), in: doc))
        let rect = badge.bounds(assets: nil)
        // The dot and the bar beside it, and the bar's border inside its edges.
        #expect(abs(rect.minX - 300) < 1 && abs(rect.minY - 170) < 1)
        #expect(abs(rect.width - 90) < 1 && abs(rect.height - 30) < 1)
    }

    @Test func svgIsWellFormedAndNamesItsLayers() throws {
        let doc = design()
        let board = ExportItem(artboard: doc.nodes[0])
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: nil), assets: nil)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(svg.contains("viewBox=\"0 0 300 200\""))
        for name in ["Card", "Lifted", "Badge", "Shape"] { #expect(svg.contains("id=\"\(name)\"")) }
        #expect(svg.contains("<linearGradient") && svg.contains("<feDropShadow") && svg.contains("<ellipse"))
        // A layer alone: as big as what it paints.
        let card = try #require(ExportItem(layer: id("Card", in: doc), in: doc))
        let alone = SVGWriter.document(for: card, bounds: card.bounds(assets: nil), assets: nil)
        #expect(alone.contains("width=\"40\" height=\"30\""))
    }

    @Test func svgLooksLikeTheArtboard() throws {
        // Shapes, a path, a gradient and a turn: what the Mac's own SVG drawing does well enough to compare with.
        var doc = design()
        doc.nodes[0].children.removeAll { $0.name == "Lifted" }
        let board = ExportItem(artboard: doc.nodes[0])
        let svg = SVGWriter.document(for: board, bounds: board.bounds(assets: nil), assets: nil)
        let drawn = try #require(NSImage(data: Data(svg.utf8)))
        let w = 300, h = 200
        func pixels(_ draw: (CGContext) -> Void) -> [UInt8] {
            let ctx = Renderer.bitmap(CGSize(width: w, height: h))!
            draw(ctx)
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * h))
        }
        let theirs = pixels { ctx in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            drawn.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.current = nil
        }
        let image = try #require(Renderer.image(of: doc.nodes[0], scale: 1))
        let ours = pixels { $0.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        var total = 0, far = 0
        for i in stride(from: 0, to: ours.count, by: 4) {
            let d = (0..<3).map { abs(Int(ours[i + $0]) - Int(theirs[i + $0])) }.max()!
            total += d
            if d > 40 { far += 1 }
        }
        let mean = Double(total) / Double(w * h)
        #expect(mean < 3, "mean difference \(mean)")
        // Only edges may differ much, where the two antialias a little differently.
        #expect(far < w * h / 50, "\(far) pixels far apart")
    }

    @Test func everyFormatWritesItsFiles() throws {
        let doc = design()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = ["Card", "Badge"].compactMap { ExportItem(layer: id($0, in: doc), in: doc) }
        for format in ExportFormat.allCases {
            let written = Exporter.export(items, format: format, scale: 2, name: "Design", to: folder)
            #expect(written.count == (format == .pdf ? 1 : 2), "\(format): \(written.map(\.lastPathComponent))")
            for url in written { #expect((try? Data(contentsOf: url))?.isEmpty == false) }
        }
        // A PDF of layers has a page each, as big as each.
        let pdf = try #require(CGPDFDocument(folder.appendingPathComponent("Design.pdf") as CFURL))
        #expect(pdf.numberOfPages == 2)
        let page = try #require(pdf.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(page.width - 40) < 0.5 && abs(page.height - 30) < 0.5)
    }
}
