import Testing
import AppKit
@testable import Bezzle

/// Several fills, borders and shadows on one layer: kept as the first and those over it, drawn one
/// over another, shadows under the layer and inside it at once, and a shadow's spread.
struct LooksTests {
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }

    /// A white artboard 100 across with `layer` on it, drawn at `scale`.
    private func drawn(_ layer: Node, scale: CGFloat = 1) throws -> CGImage {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        board.children = [layer]
        return try #require(Renderer.image(of: board, scale: scale))
    }

    private func square(_ frame: CGRect = CGRect(x: 30, y: 30, width: 40, height: 40)) -> Node {
        var n = Node(kind: .rectangle, name: "R", frame: frame)
        n.fill.color = .white
        return n
    }

    private let dark = RGBA(r: 0, g: 0, b: 0, a: 0.8)

    // MARK: The stacks

    @Test func moreGoOnTopAndTheFirstIsKeptOff() {
        var n = Node(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let red = Fill(color: RGBA(r: 1, g: 0, b: 0)), blue = Fill(color: RGBA(r: 0, g: 0, b: 1))
        n.add(red)
        #expect(n.fills == [n.fill, red] && n.slots(.fill) == 2 && n[fill: 1] == red)
        n.add(blue)
        #expect(n.fills.last == blue && n.slots(.fill) == 3)
        // Restacked, and the first taken away: the next comes down to be the first.
        n.move(.fill, from: 2, to: 0)
        #expect(n.fill == blue && n[fill: 2] == red)
        n.remove(.fill, at: 0)
        #expect(n.slots(.fill) == 2 && n.fills.last == red && n.moreFills?.count == 1)
        n.remove(.fill, at: 1)
        #expect(n.moreFills == nil && n.fills.count == 1)
        // The last is only turned off, keeping its colour to bring back.
        let kept = n.fill.color
        n.remove(.fill, at: 0)
        #expect(n.fills.isEmpty && !n.fill.on && n.fill.color == kept && n.slots(.fill) == 1)
        n.add(red)
        #expect(n.fill == red && n.moreFills == nil)
        // A slot a layer has not got reads as off, and setting it changes nothing.
        #expect(!n[fill: 5].on)
        let before = n
        n[fill: 5] = blue
        #expect(n == before)
    }

    @Test func aPictureStaysAtTheBottom() {
        var n = Node(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        n.fill.image = ImageFill(asset: "a.png", size: CGSize(width: 4, height: 4))
        n.add(Presets.overlay)
        n.add(Fill(color: .black))
        #expect(!n.canMove(.fill, from: 0, to: 2) && !n.canMove(.fill, from: 1, to: 0))
        n.move(.fill, from: 2, to: 0)
        #expect(n.fill.image != nil)
        #expect(n.canMove(.fill, from: 2, to: 1))
        n.move(.fill, from: 2, to: 1)
        #expect(n[fill: 1].color == .black && n[fill: 2].gradient != nil)
    }

    @Test func aLayerWithOneOfEachIsStoredAsItAlwaysWas() throws {
        var n = square()
        n.shadow = Shadow(on: true, color: dark, x: 0, y: 4, blur: 8)
        let json = String(decoding: try JSONEncoder().encode(n), as: UTF8.self)
        #expect(!json.contains("moreFills") && !json.contains("moreShadows") && !json.contains("spread"))
        n.add(Shadow(on: true, color: dark, x: 0, y: 1, blur: 2, spread: 2))
        let back = try JSONDecoder().decode(Node.self, from: try JSONEncoder().encode(n))
        #expect(back == n && back.shadows.count == 2 && back.moreShadows?.first?.spread == 2)
    }

    @Test func eachIsAFieldOfItsOwnForSharing() {
        let names = Set(LayerField.all.map(\.name))
        #expect(names.isSuperset(of: ["fill", "border", "shadow", "moreFills", "moreBorders", "moreShadows"]))
        // Changing the first shadow and adding a second are two fields, so both are kept.
        var a = square()
        a.shadow = Shadow(on: true, color: dark, x: 0, y: 4, blur: 3)
        var b = a
        a.shadow.y = 9
        b.add(Shadow(on: true, color: dark, x: 0, y: 1, blur: 1, inset: true))
        let changed = LayerField.all.filter { !$0.same(a, b) }.map(\.name)
        #expect(Set(changed) == ["shadow", "moreShadows"], "\(changed)")
    }

    // MARK: Drawing

    @Test func fillsLieOneOverAnother() throws {
        var n = square()
        n.add(Fill(color: RGBA(r: 1, g: 0, b: 0, a: 0.5)))
        let image = try drawn(n)
        let mid = pixel(image, 50, 50)
        #expect(mid.r > 250 && (100...170).contains(mid.g) && (100...170).contains(mid.b), "red half over white: \(mid)")
        // A gradient over it, from nothing at the top to black at the bottom.
        n.add(Fill(color: .black, gradient: Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0, g: 0, b: 0, a: 0)),
                                                                           GradientStop(offset: 1, color: .black)],
                                                     start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))))
        let shaded = try drawn(n)
        #expect(pixel(shaded, 50, 31).r > 240 && pixel(shaded, 50, 68).r < 40, "\(pixel(shaded, 50, 31)) \(pixel(shaded, 50, 68))")
    }

    @Test func bordersAreDrawnOneOverAnother() throws {
        var n = square()
        n.border = Border(on: true, color: .black, width: 4, position: .inside)
        n.add(Border(on: true, color: RGBA(r: 1, g: 0, b: 0), width: 4, position: .outside))
        let image = try drawn(n)
        let inside = pixel(image, 32, 50), outside = pixel(image, 28, 50)
        #expect(inside.r < 20 && inside.g < 20, "the black one inside: \(inside)")
        #expect(outside.r > 240 && outside.g < 60 && outside.b < 60, "the red one outside: \(outside)")
        // Over the other, a narrower one in the middle of a wide one shows its own colour there.
        var line = Node(kind: .line, frame: .zero)
        line.setLineEnds(CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50))
        line.border = Border(on: true, color: .black, width: 10, position: .center)
        line.add(Border(on: true, color: RGBA(r: 1, g: 0, b: 0), width: 2, position: .center))
        let road = try drawn(line)
        #expect(pixel(road, 50, 50).r > 240 && pixel(road, 50, 47).r < 20, "\(pixel(road, 50, 50)) \(pixel(road, 50, 47))")
    }

    /// The square with a shadow straight down and one off to the right, sharp, at `scale`.
    private func twoShadows(scale: CGFloat, blur: CGFloat) throws -> CGImage {
        var n = square()
        n.shadow = Shadow(on: true, color: dark, x: 0, y: 20, blur: blur)
        n.add(Shadow(on: true, color: dark, x: 20, y: 0, blur: blur))
        return try drawn(n, scale: scale)
    }

    @Test func severalShadowsAreEachCast() throws {
        for (scale, blur) in [(1.0, 0.0), (4.0, 2.0), (4.0, 30.0)] as [(CGFloat, CGFloat)] {
            let image = try twoShadows(scale: scale, blur: blur)
            func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) { pixel(image, Int(CGFloat(x) * scale), Int(CGFloat(y) * scale)) }
            // Below and to the right, each falls; over the corner they leave, neither.
            #expect(at(50, 80).r < 200, "\(scale)× blur \(blur) below: \(at(50, 80))")
            #expect(at(80, 50).r < 200, "\(scale)× blur \(blur) right: \(at(80, 50))")
            // The layer itself drawn once, white, over both.
            #expect(at(50, 50).r > 250, "\(scale)× blur \(blur) the layer: \(at(50, 50))")
            if blur == 0 {
                #expect(at(85, 85).r > 250, "\(scale)× no shadow at the far corner: \(at(85, 85))")
                #expect(at(50, 20).r > 250 && at(20, 50).r > 250, "\(scale)× none above or to the left")
            }
        }
    }

    @Test func aShadowUnderAndOneInsideAtOnce() throws {
        var n = square()
        n.shadow = Shadow(on: true, color: dark, x: 0, y: 10, blur: 2)
        n.add(Shadow(on: true, color: dark, x: 0, y: 6, blur: 2, inset: true))
        let image = try drawn(n)
        #expect(pixel(image, 50, 76).r < 200, "under it: \(pixel(image, 50, 76))")
        #expect(pixel(image, 50, 32).r < 200, "inside along the top: \(pixel(image, 50, 32))")
        #expect(pixel(image, 50, 66).r > 245, "inside the foot, none: \(pixel(image, 50, 66))")
        #expect(pixel(image, 50, 25).r > 250, "above it, none: \(pixel(image, 50, 25))")
    }

    @Test func aSpreadShadowIsCastFromTheOutlineGrown() throws {
        var n = square()
        n.shadow = Shadow(on: true, color: .black, x: 0, y: 0, blur: 0)
        #expect(pixel(try drawn(n), 26, 50).r > 250, "without a spread, nothing beside it")
        n.shadow.spread = 6
        let grown = try drawn(n)
        #expect(pixel(grown, 26, 50).r < 10 && pixel(grown, 50, 26).r < 10, "\(pixel(grown, 26, 50))")
        #expect(pixel(grown, 22, 50).r > 250, "only as far as it spreads: \(pixel(grown, 22, 50))")
        // A square corner stays square, as CSS keeps it.
        #expect(pixel(grown, 25, 25).r < 10, "the corner: \(pixel(grown, 25, 25))")
        // Shrunk, it hides under the layer.
        n.shadow = Shadow(on: true, color: .black, x: 0, y: 4, blur: 0, spread: -4)
        #expect(pixel(try drawn(n), 50, 72).r > 250, "shrunk by as much as it falls")
        // An ellipse grows round, and the same at several pixels to the point, made apart or not.
        var round = Node(kind: .ellipse, frame: CGRect(x: 30, y: 30, width: 40, height: 40))
        round.fill.color = .white
        round.shadow = Shadow(on: true, color: .black, x: 0, y: 0, blur: 0, spread: 6)
        let ring = try drawn(round, scale: 3)
        #expect(pixel(ring, 26 * 3, 50 * 3).r < 10 && pixel(ring, 27 * 3, 27 * 3).r > 250, "\(pixel(ring, 27 * 3, 27 * 3))")
    }

    @Test func aSpreadShadowInsideComesFurtherIn() throws {
        var n = square()
        n.shadow = Shadow(on: true, color: .black, x: 0, y: 0, blur: 0, inset: true)
        #expect(pixel(try drawn(n), 34, 50).r > 250, "without a spread, a sharp shadow inside shows nothing")
        n.shadow.spread = 6
        let image = try drawn(n)
        #expect(pixel(image, 34, 50).r < 10 && pixel(image, 50, 34).r < 10, "\(pixel(image, 34, 50))")
        #expect(pixel(image, 50, 50).r > 250 && pixel(image, 27, 50).r > 250, "only inside, as far as it spreads")
    }

    @Test func aSpreadGrowsThePlaceTheLayerPaintsIn() {
        var n = square()
        n.shadow = Shadow(on: true, color: .black, x: 0, y: 0, blur: 0, spread: 10)
        n.add(Shadow(on: true, color: .black, x: 30, y: 0, blur: 4))
        let r = Renderer.reach(of: n)
        #expect(r.minX <= 20 && r.minY <= 20 && r.maxY >= 80, "the spread: \(r)")
        #expect(r.maxX >= 30 + 40 + 30 + 8, "the second shadow: \(r)")
    }

    // MARK: SVG

    @Test func svgHasEveryFillBorderAndShadow() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var n = square()
        n.name = "Card"
        n.add(Fill(color: RGBA(r: 1, g: 0, b: 0, a: 0.5)))
        n.border = Border(on: true, color: .black, width: 2, position: .inside)
        n.add(Border(on: true, color: RGBA(r: 0, g: 0, b: 1), width: 3, position: .outside))
        n.shadow = Shadow(on: true, color: dark, x: 0, y: 6, blur: 8, spread: 3)
        n.add(Shadow(on: true, color: dark, x: 0, y: 1, blur: 2))
        n.add(Shadow(on: true, color: dark, x: 0, y: 12, blur: 24))
        n.add(Shadow(on: true, color: dark, x: 0, y: 2, blur: 4, inset: true, spread: 2))
        board.children = [n]
        let item = ExportItem(artboard: board)
        let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: nil), assets: nil)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(svg.contains("fill=\"#FF0000\" fill-opacity=\"0.5\""))
        #expect(svg.contains("stroke=\"#000000\"") && svg.contains("stroke=\"#0000FF\""))
        // The two shadows under it that do not spread merged with the layer; the spread one its
        // outline grown, so a round corner stays round; the one inside cast round a narrower hollow.
        #expect(svg.contains("result=\"drop0\"") && svg.contains("result=\"drop1\"") && !svg.contains("<feDropShadow"))
        #expect(!svg.contains("feMorphology"))
        #expect(svg.contains("fill=\"#000000\" fill-opacity=\"0.8\" filter="), "the spread one, apart")
        #expect(svg.components(separatedBy: "tableValues=\"1 0\"").count == 2 && svg.contains("<g clip-path="))
    }

    @Test func aSeeThroughGradientStaysSeeThroughInAPDF() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        var n = square(CGRect(x: 0, y: 0, width: 100, height: 100))
        n.add(Fill(color: .black, gradient: Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0, g: 0, b: 1, a: 0)),
                                                                           GradientStop(offset: 1, color: RGBA(r: 0, g: 0, b: 1, a: 1))],
                                                     start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))))
        var round = square(CGRect(x: 0, y: 0, width: 100, height: 100))
        round.fill = Fill(color: .black, gradient: Gradient(kind: .radial, stops: [GradientStop(offset: 0, color: RGBA(r: 1, g: 0, b: 0, a: 1)),
                                                                                  GradientStop(offset: 1, color: RGBA(r: 1, g: 0, b: 0, a: 0))],
                                                            start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1, y: 0.5)))
        for (layer, check) in [(n, 0), (round, 1)] {
            board.children = [layer]
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            let consumer = try #require(CGDataConsumer(data: data))
            let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            Renderer.drawPDFPage(board, in: ctx)
            ctx.closePDF()
            let provider = try #require(CGDataProvider(data: data))
            let page = try #require(CGPDFDocument(provider)?.page(at: 1))
            let bitmap = try #require(Renderer.bitmap(CGSize(width: 100, height: 100)))
            bitmap.drawPDFPage(page)
            let image = try #require(bitmap.makeImage())
            if check == 0 {
                // White at the top, where it is clear; blue at the foot.
                #expect(pixel(image, 50, 3).r > 240 && pixel(image, 50, 96).r < 30, "\(pixel(image, 50, 3)) \(pixel(image, 50, 96))")
                #expect((90...170).contains(pixel(image, 50, 50).r), "half way: \(pixel(image, 50, 50))")
            } else {
                // Red in the middle, fading to white at the edge and beyond.
                #expect(pixel(image, 50, 50).g < 60 && pixel(image, 2, 2).g > 240, "\(pixel(image, 50, 50)) \(pixel(image, 2, 2))")
            }
        }
    }

    // MARK: Bringing them in

    @MainActor @Test func sketchBringsEveryFillBorderAndShadow() throws {
        let c = SketchImportTests.color
        let style = """
            {"fills":[\(SketchImportTests.fill(SketchImportTests.red)),\(SketchImportTests.fill(c(0, 0, 1, 0.5)))],
             "borders":[{"_class":"border","isEnabled":true,"fillType":0,"color":\(c(0, 0, 0, 1)),"position":1,"thickness":2},
                        {"_class":"border","isEnabled":true,"fillType":0,"color":\(c(1, 1, 1, 1)),"position":2,"thickness":1}],
             "shadows":[{"_class":"shadow","isEnabled":true,"offsetX":0,"offsetY":3,"blurRadius":6,"spread":4,"color":\(c(0, 0, 0, 0.2))},
                        {"_class":"shadow","isEnabled":true,"offsetX":0,"offsetY":1,"blurRadius":1,"spread":0,"color":\(c(0, 0, 0, 0.3))}],
             "innerShadows":[{"_class":"innerShadow","isEnabled":true,"offsetX":0,"offsetY":2,"blurRadius":2,"spread":0,"color":\(c(0, 0, 0, 0.5))}]}
            """
        let card = SketchImportTests.rectangle("Card", SketchImportTests.frame(10, 10, 100, 40), style: style)
        let board = #"{"_class":"artboard","name":"Board","frame":\#(SketchImportTests.frame(0, 0, 300, 300)),"layers":[\#(card)]}"#
        let page = #"{"_class":"page","name":"Page 1","layers":[\#(board)]}"#
        let document = #"{"_class":"document","pages":[{"_ref":"pages/P1"}]}"#
        let zip = TestZip.make([("document.json", Data(document.utf8)), ("meta.json", Data(#"{"appVersion":"70","version":136}"#.utf8)),
                                ("pages/P1.json", Data(page.utf8))], deflate: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).sketch")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try SketchImporter.read(url)
        let n = try #require(imported.document.allNodes.first { $0.name == "Card" })
        #expect(n.fills.map(\.color.hex) == ["FF0000", "0000FF"])
        #expect(n.borders.map(\.position) == [.inside, .outside])
        #expect(n.outerShadows.count == 2 && n.innerShadows.count == 1 && n.shadows[0].spread == 4)
        #expect(imported.report.notes.isEmpty, "\(imported.report.notes)")
    }
}

/// The inspector and the tools, offering and changing several of each.
@MainActor
struct LooksEditingTests {
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

    private func select(_ shadow: Shadow?, name: String = "R") -> SelectionInspector {
        var r = CanvasTests.rect(name, CGRect(x: 110, y: 110, width: 50, height: 50))
        if let shadow { r.shadow = shadow }
        bench.step { bench.store.add(r, onto: bench.a.id) }
        bench.store.selection = [bench.node(name)!.id]
        return SelectionInspector(store: bench.store)
    }

    @Test func theBarOffersAShadowInsideOnceThereIsOneUnder() {
        let none = select(nil, name: "Plain").addable(fill: true, border: true).map(\.id)
        #expect(none.contains("add-shadow") && !none.contains("add-inner-shadow"))
        let inspector = select(Shadow(on: true, color: .shadow, x: 0, y: 4, blur: 12))
        let under = inspector.addable(fill: true, border: true).map(\.id)
        #expect(!under.contains("add-shadow") && under.contains("add-inner-shadow"))
        // A line has no inside.
        #expect(!inspector.addable(fill: true, border: true, inset: false).contains { $0.id == "add-inner-shadow" })
        // Adding it puts it beside the one there is, and then neither is offered.
        let item = inspector.addable(fill: true, border: true).first { $0.id == "add-inner-shadow" }!
        #expect(item.aspect == .shadow(1))
        bench.step { bench.store.updateSelection(item.action, item.change) }
        let r = bench.node("R")!
        #expect(r.outerShadows.count == 1 && r.innerShadows.count == 1)
        #expect(!inspector.addable(fill: true, border: true).contains { $0.id.contains("shadow") })
    }

    @Test func takingOneAwayKeepsTheOthersAndOneUndoBringsItBack() {
        let inspector = select(Shadow(on: true, color: .shadow, x: 0, y: 4, blur: 12))
        bench.step { bench.store.updateSelection("Add Shadow") { $0.add(Presets.shadow(besides: $0.shadow)) } }
        let two = bench.node("R")!
        #expect(two.shadows.count == 2 && two.moreShadows?.first?.y == Presets.shadows[0].y)
        bench.store.openAspect = .shadow(1)
        bench.step { inspector.removeLook(.shadow, 0, "Remove Shadow") }
        let one = bench.node("R")!
        #expect(one.shadows.count == 1 && one.shadow == two.moreShadows?.first && one.moreShadows == nil)
        // The open card is still on the shadow it showed, now the first.
        #expect(bench.store.openAspect == .shadow(0))
        bench.undo.undo()
        #expect(bench.node("R")! == two)
    }

    @Test func theToolsReadAndSetSeveral() async {
        _ = select(nil)
        var answer = await call("update_layers", ["updates": [["layer": "R",
            "fill": ["#FFFFFF", ["gradient": ["type": "linear", "stops": ["#00000000", "#000000"]]]],
            "border": [["color": "#000", "width": 2, "position": "inside"], ["color": "#F00", "width": 1, "position": "outside"]],
            "shadow": ["soft", ["x": 0, "y": 1, "blur": 2, "spread": 3], ["inset": true, "y": 2, "blur": 4]],
        ]]])
        #expect(!answer.failed, "\(answer.text)")
        var r = bench.node("R")!
        #expect(r.fills.count == 2 && r[fill: 1].gradient != nil)
        #expect(r.borders.map(\.position) == [.inside, .outside])
        #expect(r.shadows.count == 3 && r[shadow: 1].spread == 3 && r[shadow: 2].inside && Presets.isShadow(Presets.shadows[1], r.shadow))
        let read = await call("get_layers", ["layers": ["R"]])
        let layer = ((try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any])?["layers"] as? [[String: Any]]
        #expect((layer?.first?["shadow"] as? [Any])?.count == 3 && (layer?.first?["fill"] as? [Any])?.count == 2)
        // One on its own changes the first; "none" takes them all away.
        answer = await call("update_layers", ["updates": [["layer": "R", "shadow": ["y": 9]]]])
        r = bench.node("R")!
        #expect(r.shadow.y == 9 && r.shadows.count == 3)
        _ = await call("update_layers", ["updates": [["layer": "R", "shadow": "none", "border": "none"]]])
        r = bench.node("R")!
        #expect(r.shadows.isEmpty && r.moreShadows == nil && r.borders.isEmpty)
    }
}
