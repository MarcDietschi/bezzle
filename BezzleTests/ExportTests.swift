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
        for format in ExportFormat.offered {
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

    // MARK: WebP and AVIF

    /// The picture a file holds, as ImageIO reads it, drawn into a bitmap of the same size.
    private func pixels(of url: URL) throws -> (CGContext, Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (ctx, image.width, image.height)
    }

    private func rgba(_ ctx: CGContext, _ x: Int, _ y: Int) -> [Int] {
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
        return (0..<4).map { Int(p[$0]) }
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func losslessWebPKeepsEveryPixel() throws {
        let doc = design()
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = ExportItem(artboard: doc.nodes[0])
        let url = try #require(Exporter.export([board], format: .webp, scale: 1, quality: 1, name: "Design", to: folder).first)
        #expect(url.lastPathComponent == "Board.webp")
        let (theirs, w, h) = try pixels(of: url)
        #expect(w == 300 && h == 200)
        let image = try #require(Renderer.image(of: doc.nodes[0], scale: 1))
        let ours = try #require(Renderer.bitmap(CGSize(width: w, height: h)))
        ours.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var differ = 0
        for y in 0..<h { for x in 0..<w where rgba(ours, x, y) != rgba(theirs, x, y) { differ += 1 } }
        #expect(differ == 0, "\(differ) pixels differ")
    }

    @Test func lossyWebPAndAVIFKeepTheLookAndWhatIsSeeThrough() throws {
        let doc = design()
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A layer alone on nothing: its shadow fades into what is clear.
        let lifted = try #require(ExportItem(layer: id("Lifted", in: doc), in: doc))
        let (drawn, _) = try #require(lifted.picture(scale: 2, opaque: false, assets: nil))
        let ours = try #require(Renderer.bitmap(CGSize(width: drawn.width, height: drawn.height)))
        ours.draw(drawn, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        for format in [ExportFormat.webp, .avif] where format.isAvailable {
            let url = try #require(Exporter.export([lifted], format: format, scale: 2, quality: 0.8, name: "Design", to: folder).first)
            #expect(url.lastPathComponent == "Lifted@2x.\(format.fileExtension)")
            let (theirs, w, h) = try pixels(of: url)
            #expect(w == drawn.width && h == drawn.height)
            // Clear in the corner, and solid red in the middle, near enough.
            #expect(rgba(theirs, 0, 0)[3] < 8, "\(format): \(rgba(theirs, 0, 0))")
            let middle = rgba(theirs, w / 2, h / 2), was = rgba(ours, w / 2, h / 2)
            #expect(zip(middle, was).allSatisfy { abs($0 - $1) <= 8 }, "\(format): \(middle) for \(was)")
            var total = 0
            for y in 0..<h { for x in 0..<w { total += zip(rgba(theirs, x, y), rgba(ours, x, y)).map { abs($0 - $1) }.max()! } }
            #expect(Double(total) / Double(w * h) < 3, "\(format): mean difference \(Double(total) / Double(w * h))")
        }
    }

    // MARK: Marked for export

    @Test func sizesReadAsTheyAreTyped() throws {
        #expect(ExportSize("2") == .scale(2) && ExportSize("2x") == .scale(2) && ExportSize("@3x") == .scale(3) && ExportSize("2×") == .scale(2))
        #expect(ExportSize("1,5x") == .scale(1.5) && ExportSize(" 0.5 x") == .scale(0.5))
        #expect(ExportSize("512w") == .width(512) && ExportSize("64 h") == .height(64))
        #expect(ExportSize("") == nil && ExportSize("x") == nil && ExportSize("0") == nil && ExportSize("99999w") == nil && ExportSize("2q") == nil)
        #expect(ExportSize.scale(2).suffix == "@2x" && ExportSize.scale(1).suffix == "" && ExportSize.scale(1.5).suffix == "@1.5x")
        #expect(ExportSize.width(512).suffix == "-512w" && ExportSize.height(64).shown == "64h" && ExportSize.scale(0.5).shown == "0.5×")
        // Stored as typed.
        let presets = [ExportPreset(size: .scale(2), format: .webp), ExportPreset(size: .width(512), suffix: "-large")]
        let json = String(decoding: try JSONEncoder().encode(presets), as: UTF8.self)
        #expect(json.contains("\"2x\"") && json.contains("\"512w\""))
        #expect(try JSONDecoder().decode([ExportPreset].self, from: Data(json.utf8)) == presets)
    }

    @Test func theNextPresetIsTheNextSizeUp() {
        #expect(ExportPreset.next(after: []) == ExportPreset())
        let one = [ExportPreset()]
        #expect(ExportPreset.next(after: one) == ExportPreset(size: .scale(2)))
        #expect(ExportPreset.next(after: one + [ExportPreset(size: .scale(2))]) == ExportPreset(size: .scale(3)))
        #expect(ExportPreset.next(after: [ExportPreset(size: .scale(2), format: .webp)]) == ExportPreset(size: .scale(3), format: .webp))
        #expect(ExportPreset.next(after: [ExportPreset(format: .svg)]).format == .svg)
    }

    @Test func aMarkedLayerGoesOutAsItsPresetsSay() throws {
        var doc = design()
        doc.update(id("Card", in: doc)) {
            $0.name = "icons/Card"
            $0.exports = [ExportPreset(), ExportPreset(size: .scale(2)), ExportPreset(size: .scale(3)),
                          ExportPreset(size: .width(100), format: .webp, suffix: "-wide"), ExportPreset(format: .svg)]
        }
        doc.update(id("Board", in: doc)) { $0.exports = [ExportPreset(format: .pdf)] }
        doc.update(id("Shape", in: doc)) { $0.exports = [ExportPreset(format: .jpeg)]; $0.hidden = true }
        let items = ExportItem.marked(in: doc, seen: doc)
        // The artboard, then the card; not the shape, which is hidden.
        #expect(items.map(\.node.name) == ["Board", "icons/Card"])
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = Exporter.export(presetsOf: items, quality: 0.9, to: folder)
        let names = written.map { $0.path.replacingOccurrences(of: folder.path + "/", with: "") }
        #expect(names == ["Board.pdf", "icons/Card.png", "icons/Card@2x.png", "icons/Card@3x.png", "icons/Card-wide.webp", "icons/Card.svg"])
        let (_, w1, h1) = try pixels(of: folder.appendingPathComponent("icons/Card@3x.png"))
        #expect(w1 == 120 && h1 == 90)
        let (_, w2, h2) = try pixels(of: folder.appendingPathComponent("icons/Card-wide.webp"))
        #expect(w2 == 100 && h2 == 75)
        // Again, keeping both: the new files are numbered, and what was there is found first.
        let files = Exporter.files(presetsOf: items)
        #expect(Exporter.clashes(files, in: folder).count == 6)
        let again = Exporter.export(presetsOf: items, quality: 0.9, to: folder)
        #expect(again.map(\.lastPathComponent).contains("Card@2x 2.png"))
        // And replacing: the same names, the files drawn anew.
        let card = folder.appendingPathComponent("icons/Card@3x.png")
        try Data().write(to: card)
        let replaced = Exporter.export(presetsOf: items, quality: 0.9, to: folder, replacing: true)
        #expect(replaced.map(\.lastPathComponent) == written.map(\.lastPathComponent))
        #expect(try pixels(of: card).1 == 120)
        // Two files of one export never land on one name, replacing or not.
        let twice = ExportFile(items: [items[1]], format: .png, size: .scale(1), name: "Twice")
        let places = Exporter.destinations(of: [twice, twice], in: folder, replacing: true).compactMap { $0?.lastPathComponent }
        #expect(places == ["Twice.png", "Twice 2.png"])
        // Nothing reaches outside the folder chosen.
        let file = ExportFile(items: [items[1]], format: .png, size: .scale(1), name: "../../up/../Card")
        #expect(Exporter.place(of: file, in: folder).path.hasPrefix(folder.path + "/up/"))
    }
}

