import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle
import Vectorizer

/// Vectorize: a layer's picture made shapes lying where the picture did, looking as it did;
/// undone in one step, traced again another way, given back, and asked for by an assistant.
@MainActor
struct VectorTests {
    /// A red disc and a blue bar on white, 800 × 600.
    static func drawing() -> CGImage {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.12, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 40, width: 200, height: 60))
        return ctx.makeImage()!
    }

    /// Rows of dots in two colours on paper, a smaller dot of the other colour on each: more
    /// shapes than each get a layer of their own.
    static func dots() -> CGImage {
        let ctx = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        let ink = CGColor(srgbRed: 0.85, green: 0.28, blue: 0.06, alpha: 1), blue = CGColor(srgbRed: 0.12, green: 0.24, blue: 0.63, alpha: 1)
        for row in 0..<16 {
            for column in 0..<20 {
                let c = CGPoint(x: 25 + 50 * CGFloat(column), y: 25 + 50 * CGFloat(row)), odd = (row + column) % 2 == 1
                ctx.setFillColor(odd ? ink : blue)
                ctx.fillEllipse(in: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36))
                ctx.setFillColor(odd ? blue : ink)
                ctx.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
            }
        }
        return ctx.makeImage()!
    }

    /// A design kept as a package, with a layer "Photo" on artboard "A" filled with `picture`.
    private func design(_ picture: CGImage = VectorTests.drawing(), frame: CGRect = CGRect(x: 50, y: 50, width: 200, height: 150),
                        _ change: (inout Node) -> Void = { _ in }) throws -> (DocumentStore, UndoManager) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        var photo = CanvasTests.rect("Photo", frame)
        photo.fill = Fill(color: .shape, image: ImageFill(asset: "photo.png", size: CGSize(width: picture.width, height: picture.height)))
        change(&photo)
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        board.children = [photo]
        var doc = BezzleDocument()
        doc.nodes = [board]
        try DesignFile.write(doc, to: url)
        let out = try #require(CGImageDestinationCreateWithURL(url.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent("photo.png") as CFURL,
                                                               UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, picture, nil)
        #expect(CGImageDestinationFinalize(out))
        let store = try DocumentStore(opening: url)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    private func photo(_ store: DocumentStore) -> Node? { store.doc.allNodes.first { $0.name == "Photo" } }

    /// The artboard as pixels, red, green, blue and alpha, `scale` to the point.
    private func shown(_ store: DocumentStore, scale: CGFloat = 2) throws -> [UInt8] {
        let image = try #require(Renderer.image(of: store.doc.nodes[0], scale: scale, assets: store.assets))
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    /// How far two renderings are apart on the whole, in levels of 255, and the share of pixels
    /// that differ clearly.
    private func apart(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, clearly: Double) {
        var sum = 0, clearly = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            sum += d
            if d > 90 { clearly += 1 }
        }
        let pixels = Double(max(a.count / 4, 1))
        return (Double(sum) / 3 / pixels, Double(clearly) / pixels)
    }

    private func settled(_ store: DocumentStore, _ id: UUID) async throws {
        while store.retracing.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aPictureBecomesShapesWhereItLay() async throws {
        let (store, undo) = try design()
        let id = try #require(photo(store)).id
        let before = try shown(store)
        #expect(store.vectorizable(id))
        #expect(try await store.vectorize([id]) == [id])

        let group = try #require(store.node(id))
        #expect(group.kind == .group)
        #expect(group.name == "Photo")
        #expect(group.frame == CGRect(x: 50, y: 50, width: 200, height: 150))
        #expect(group.children.count == 3)
        // The paper, the bar and the disc, each as what it is.
        let disc = try #require(group.children.first { $0.kind == .ellipse })
        #expect(abs(disc.frame.midX - 100) < 0.05 && abs(disc.frame.midY - 75) < 0.05)
        #expect(abs(disc.frame.width - 75) < 0.1 && abs(disc.frame.height - 75) < 0.1)
        let bar = try #require(group.children.first { $0.kind == .rectangle && $0.frame.width < 100 })
        #expect(abs(bar.frame.minX - 15) < 0.05 && abs(bar.frame.minY - 125) < 0.05)
        #expect(abs(bar.frame.width - 50) < 0.05 && abs(bar.frame.height - 15) < 0.05)
        #expect(bar.fill.color.hex.lowercased().contains("1a4dcc"))
        let seen = apart(before, try shown(store))
        #expect(seen.mean < 0.4, "\(seen)")
        #expect(seen.clearly < 0.0005, "\(seen)")

        // One step back to the picture, and one forward again to the vector that remembers it.
        undo.undo()
        #expect(photo(store)?.fill.image?.asset == "photo.png")
        #expect(store.vector(of: id) == nil)
        undo.redo()
        #expect(store.node(id)?.kind == .group)
        #expect(store.vector(of: id)?.version.shapes == 3)
        #expect(store.vectorCounts(of: id)?.colors.count == 3)
    }

    @Test func aTurnedPictureInAnEllipseLooksTheSame() async throws {
        let (store, _) = try design { photo in
            photo.kind = .ellipse
            photo.rotation = 30
            photo.opacity = 0.8
        }
        let id = try #require(photo(store)).id
        let before = try shown(store)
        try await store.vectorize([id])
        let group = try #require(store.node(id))
        #expect(group.kind == .group && group.rotation == 0 && group.opacity == 0.8)
        #expect(group.children.allSatisfy { $0.rotation == 30 || $0.kind == .ellipse })
        let seen = apart(before, try shown(store))
        #expect(seen.mean < 0.8, "\(seen)")
        #expect(seen.clearly < 0.002, "\(seen)")
    }

    @Test func manyShapesShareLayers() async throws {
        let (store, _) = try design(Self.dots(), frame: CGRect(x: 25, y: 50, width: 250, height: 200))
        let id = try #require(photo(store)).id
        // Seen at the picture's own pixels, where it is what was traced.
        let before = try shown(store, scale: 4)
        try await store.vectorize([id])
        let group = try #require(store.node(id))
        #expect(store.vector(of: id)?.version.shapes == 641)
        #expect(group.children.count < 20)
        #expect(group.children.allSatisfy { $0.kind == .path })
        let seen = apart(before, try shown(store, scale: 4))
        // Dots of a few pixels, all edge: a little more of them differs than of large shapes.
        #expect(seen.mean < 0.6, "\(seen)")
        #expect(seen.clearly < 0.004, "\(seen)")
    }

    /// A sky running from blue to peach, a ball lit from its upper left and a white bar, 800 × 600.
    static func sunset() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func run(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)! }
        let both: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        ctx.drawLinearGradient(run([CGColor(srgbRed: 0.14, green: 0.24, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.95, green: 0.66, blue: 0.5, alpha: 1)]),
                               start: CGPoint(x: 0, y: 600), end: CGPoint(x: 300, y: 0), options: both)
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 120, y: 180, width: 280, height: 280))
        ctx.clip()
        ctx.drawRadialGradient(run([CGColor(srgbRed: 1, green: 0.9, blue: 0.62, alpha: 1), CGColor(srgbRed: 0.7, green: 0.26, blue: 0.08, alpha: 1)]),
                               startCenter: CGPoint(x: 220, y: 370), startRadius: 0, endCenter: CGPoint(x: 220, y: 370), endRadius: 200, options: both)
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 480, y: 120, width: 240, height: 48))
        return ctx.makeImage()!
    }

    @Test func coloursThatRunBecomeGradients() async throws {
        let (store, _) = try design(Self.sunset())
        let id = try #require(photo(store)).id
        let before = try shown(store, scale: 4)
        try await store.vectorize([id])
        let group = try #require(store.node(id))
        // The sky, the ball and the bar: three layers, two of them with colours running.
        #expect(group.children.count == 3)
        let sky = try #require(group.children.first { $0.fill.gradient?.kind == .linear })
        #expect(abs(sky.frame.width - 200) < 0.1 && abs(sky.frame.height - 150) < 0.1)
        let run = try #require(sky.fill.gradient)
        // Down the picture and half as far to the right, as drawn.
        let right = (run.end.x - run.start.x) * 200, down = (run.end.y - run.start.y) * 150
        #expect(right > 0 && down > 0 && abs(2 * right - down) < 0.05 * down, "\(run.start) \(run.end)")
        let ball = try #require(group.children.first { $0.fill.gradient?.kind == .radial })
        #expect(ball.kind == .ellipse)
        #expect(abs(ball.frame.midX - 65) < 0.1 && abs(ball.frame.midY - 70) < 0.1 && abs(ball.frame.width - 70) < 0.2, "\(ball.frame)")
        let lit = try #require(ball.fill.gradient)
        // The light's middle, in the ball's own frame: left of its middle and above it.
        #expect(abs(lit.start.x - (55.0 - 30) / 70) < 0.02 && abs(lit.start.y - (57.5 - 35) / 70) < 0.02, "\(lit.start)")
        let bar = try #require(group.children.first { $0.fill.gradient == nil })
        #expect(bar.kind == .rectangle && bar.fill.color.hex.lowercased().contains("ffffff"))
        // And it looks as the picture did.
        let seen = apart(before, try shown(store, scale: 4))
        #expect(seen.mean < 1.2, "\(seen)")
        #expect(seen.clearly < 0.002, "\(seen)")
    }

    @Test func aBlendLiesInItsLayersFrame() {
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(a.x - x) < 1e-6 && abs(a.y - y) < 1e-6 }
        let red = Tint(r: 255, g: 0, b: 0), blue = Tint(r: 0, g: 0, b: 255)
        let stops = [Blend.Stop(offset: 0, color: red), Blend.Stop(offset: 1, color: blue)]
        // Across a picture of 100 by 50 pixels, two points each, on the layer that fills it.
        let across = VectorMaker.gradient(Blend(kind: .linear, start: Spot(0, 0), end: Spot(100, 0), stops: stops),
                                          middle: CGPoint(x: 100, y: 50), size: CGSize(width: 200, height: 100), turned: 0, sx: 2, sy: 2)
        #expect(across.kind == .linear && near(across.start, 0, 0) && near(across.end, 1, 0))
        #expect(across.stops.map(\.color) == [RGBA(r: 1, g: 0, b: 0), RGBA(r: 0, g: 0, b: 1)])
        // On a layer turned a quarter, it runs down the layer's own frame.
        let turned = VectorMaker.gradient(Blend(kind: .linear, start: Spot(50, 0), end: Spot(50, 50), stops: stops),
                                          middle: CGPoint(x: 100, y: 50), size: CGSize(width: 100, height: 200), turned: 90, sx: 2, sy: 2)
        #expect(near(turned.start, 0, 0.5) && near(turned.end, 1, 0.5))
        // Pixels twice as wide as high: the lines of one colour stay the picture's.
        let slanted = VectorMaker.gradient(Blend(kind: .linear, start: Spot(0, 0), end: Spot(10, 10), stops: stops),
                                           middle: CGPoint(x: 20, y: 10), size: CGSize(width: 40, height: 20), turned: 0, sx: 2, sy: 1)
        #expect(near(slanted.start, 0, 0) && near(slanted.end, 8.0 / 40, 16.0 / 20))
        // A round one is a circle in the picture, whatever the layer's shape.
        let round = VectorMaker.gradient(Blend(kind: .radial, start: Spot(50, 25), end: Spot(60, 25), stops: stops),
                                         middle: CGPoint(x: 100, y: 25), size: CGSize(width: 200, height: 50), turned: 0, sx: 2, sy: 1)
        #expect(round.kind == .radial && near(round.start, 0.5, 0.5) && near(round.end, 0.6, 0.5))
        #expect(round.across.map { near($0, 0.5, 0.7) } == true)
    }

    @Test func tracedAgainAnotherWayInOneStep() async throws {
        let (store, undo) = try design()
        let id = try #require(photo(store)).id
        try await store.vectorize([id])
        let first = try #require(store.node(id))
        store.setVector(id) { $0.colors = 2 }
        #expect(store.vectorSettings(of: id)?.colors == 2)
        try await settled(store, id)
        let second = try #require(store.node(id))
        #expect(second != first)
        #expect(Set(second.children.map(\.fill.color)).count == 2)
        #expect(store.vectorCounts(of: id)?.colors.count == 2)
        #expect(store.vector(of: id)?.version.settings.colors == 2)
        #expect(store.vectorWanted[id] == nil)
        undo.undo()
        #expect(store.node(id) == first)
        #expect(store.vector(of: id)?.version.settings.colors == nil)
        undo.undo()
        #expect(photo(store)?.fill.image != nil)
    }

    @Test func aDragShowsQuickTracingsAndChangesTheDesignOnce() async throws {
        let (store, undo) = try design()
        let id = try #require(photo(store)).id
        try await store.vectorize([id])
        let first = store.doc
        store.beginGesture()
        store.setVector(id) { $0.colors = 2 }
        while store.vectorPreviewed[id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        // Shown on the canvas, the design itself as it was.
        #expect(store.doc == first)
        #expect(Set((store.shownDoc.node(id)?.children ?? []).map(\.fill.color)).count == 2)
        #expect(store.vectorCounts(of: id)?.colors.count == 2)
        store.endGesture("Change Vector")
        try await settled(store, id)
        #expect(store.preview == nil)
        #expect(Set((store.node(id)?.children ?? []).map(\.fill.color)).count == 2)
        undo.undo()
        #expect(store.doc == first)
    }

    @Test func thePictureComesBackWhereItsVectorLies() async throws {
        let (store, undo) = try design()
        let id = try #require(photo(store)).id
        try await store.vectorize([id])
        undo.beginUndoGrouping()
        store.update([id], "Move") { $0.frame.origin = CGPoint(x: 70, y: 90) }
        undo.endUndoGrouping()
        #expect(store.vector(of: id) != nil)
        undo.beginUndoGrouping()
        store.backToPicture(id)
        undo.endUndoGrouping()
        let back = try #require(photo(store))
        #expect(back.kind == .rectangle && back.fill.image?.asset == "photo.png")
        #expect(back.frame == CGRect(x: 70, y: 90, width: 200, height: 150))
        #expect(store.vector(of: id) == nil)
    }

    @Test func whatOthersCountOnStaysAPicture() throws {
        let (store, _) = try design { $0.locked = true }
        #expect(!store.vectorizable(try #require(photo(store)).id))
        #expect(!store.vectorizable(store.doc.nodes[0].id))
        store.selection = [try #require(photo(store)).id]
        #expect(!store.canVectorize)
    }

    @Test func anAssistantCanVectorize() async throws {
        let (store, _) = try design()
        let id = try #require(photo(store)).id
        MCPTools.opened(store)
        defer { MCPTools.closed(store) }
        let tools = MCPTools()
        func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = store.name
            let result = await tools.call("vectorize", arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let made = await call(["layers": ["Photo"]])
        #expect(!made.failed, "\(made.text)")
        #expect(store.node(id)?.children.count == 3)
        #expect(made.text.contains("Ellipse"))
        let fewer = await call(["layers": ["Photo"], "colors": 2])
        #expect(!fewer.failed, "\(fewer.text)")
        #expect(store.vectorCounts(of: id)?.colors.count == 2)
        #expect(await call(["layers": ["Photo"], "detail": 140]).failed)
        let back = await call(["layers": ["Photo"], "restore": true])
        #expect(!back.failed, "\(back.text)")
        #expect(photo(store)?.fill.image?.asset == "photo.png")
        #expect(await call(["layers": ["A"]]).failed)
    }
}
