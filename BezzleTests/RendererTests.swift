import Testing
import AppKit
@testable import Bezzle

struct RendererTests {
    /// The alpha of one pixel of an artboard drawn at 1×, x and y from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255), UInt8(c.alphaComponent * 255))
    }

    @Test func shadowFallsBelowAShape() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        var box = Node(kind: .rectangle, name: "R", frame: CGRect(x: 30, y: 20, width: 40, height: 30))
        box.fill.color = .white
        box.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.5), x: 0, y: 10, blur: 4)
        board.children = [box]
        let image = try #require(Renderer.image(of: board, scale: 1))
        let below = pixel(image, 50, 55)
        let above = pixel(image, 50, 15)
        #expect(below.r < 230, "under the shape: \(below)")
        #expect(above.r > 250, "over the shape: \(above)")
    }

    /// A white square on white with a shadow inside it, falling down, turned as far as `rotation`.
    private func pressed(_ kind: Node.Kind = .rectangle, rotation: Double = 0, fill: Bool = true) throws -> CGImage {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        var box = Node(kind: kind, name: "R", frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        box.fill.color = .white
        box.fill.on = fill
        box.rotation = rotation
        box.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 6, blur: 4, inset: true)
        board.children = [box]
        return try #require(Renderer.image(of: board, scale: 1))
    }

    @Test func aShadowInsideFallsInsideTheShapeAlone() throws {
        for kind in [Node.Kind.rectangle, .ellipse] {
            let image = try pressed(kind)
            // Just inside the top edge, where the light above casts it; not at the foot, nor outside.
            #expect(pixel(image, 50, 23).r < 200, "\(kind) inside the top: \(pixel(image, 50, 23))")
            #expect(pixel(image, 50, 76).r > 250, "\(kind) inside the foot: \(pixel(image, 50, 76))")
            #expect(pixel(image, 50, 15).r > 250 && pixel(image, 50, 85).r > 250, "\(kind) outside")
        }
        // A shape with no fill shows its hollow all the same.
        #expect(pixel(try pressed(fill: false), 50, 23).r < 200)
    }

    @Test func aShadowInsideFallsFromAboveHoweverTheLayerIsTurned() throws {
        for rotation in [90.0, 180, 270] {
            let image = try pressed(rotation: rotation)
            #expect(pixel(image, 50, 23).r < 200, "turned \(rotation): \(pixel(image, 50, 23))")
            #expect(pixel(image, 50, 76).r > 250, "turned \(rotation): \(pixel(image, 50, 76))")
            #expect(abs(Int(pixel(image, 23, 50).r) - Int(pixel(image, 76, 50).r)) < 4, "turned \(rotation): the sides alike")
        }
    }

    @Test func aGroupsShadowInsideFallsOnWhatItHolds() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        var a = Node(kind: .rectangle, name: "A", frame: CGRect(x: 0, y: 0, width: 25, height: 60))
        a.fill.color = .white
        var b = a
        b.id = UUID()
        b.frame.origin.x = 35
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        group.children = [a, b]
        group.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 6, blur: 4, inset: true)
        board.children = [group]
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(pixel(image, 30, 23).r < 200, "inside the top of one: \(pixel(image, 30, 23))")
        #expect(pixel(image, 70, 23).r < 200, "inside the top of the other: \(pixel(image, 70, 23))")
        // Not in the gap between them, and no dark rim along their feet.
        #expect(pixel(image, 50, 23).r > 250 && pixel(image, 50, 50).r > 250)
        #expect(pixel(image, 30, 79).r > 240, "along the foot: \(pixel(image, 30, 79))")
    }

    @Test func aShadowInsideTextFallsOnTheLetters() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        board.fill.color = .white
        var text = Node(kind: .text, name: "T", frame: CGRect(x: 20, y: 10, width: 10, height: 10))
        text.text = "HI"
        text.style?.size = 80
        text.style?.face = "Black"
        text.fill.color = .white
        text.refit()
        text.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.8), x: 0, y: 4, blur: 2, inset: true)
        board.children = [text]
        let image = try #require(Renderer.image(of: board, scale: 1))
        let rep = NSBitmapImageRep(cgImage: image)
        var dark = 0, outside = 0
        for y in 0..<image.height { for x in 0..<image.width where rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent < 0.8 {
            dark += 1
            if !text.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) { outside += 1 }
        } }
        // White letters on white show only by their shadow, and it lies within them.
        #expect(dark > 40, "\(dark)")
        #expect(outside == 0, "\(outside)")
    }

    @Test func whatIsBehindABlurDoesNotTakeAShadowInside() throws {
        // A group's shadow inside, around glass in the group: what shows through the glass is
        // the group drawn only up to the glass, which has no whole to cast a shadow into.
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        board.fill.color = .black
        var paper = Node(kind: .rectangle, name: "Paper", frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        paper.fill.color = .white
        var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 40, y: 40, width: 80, height: 80))
        glass.fill.color = .white
        glass.blur = Blur(radius: 4, background: true, brightness: 0, fillOpacity: 0)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 20, y: 20, width: 160, height: 160))
        group.children = [paper, glass]
        group.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.6), x: 0, y: 6, blur: 4, inset: true)
        board.children = [group]
        let image = try #require(Renderer.image(of: board, scale: 1))
        #expect(pixel(image, 100, 100).r > 240, "through the glass: \(pixel(image, 100, 100))")
        #expect(pixel(image, 100, 23).r < 200, "inside the top of the group: \(pixel(image, 100, 23))")
    }

    @Test func aBackgroundBlurBlursWhatLiesBehindIt() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 40, y: 60, width: 200, height: 100))
        board.fill.color = .white
        var dark = Node(kind: .rectangle, name: "Dark", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        dark.fill.color = .black
        // Clear glass over the edge between black and white, inside a group so it is not at the top.
        var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        glass.fill.color = .white
        glass.blur = Blur(radius: 10, background: true, brightness: 0, fillOpacity: 0)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 50, y: 0, width: 100, height: 100))
        group.children = [glass]
        board.children = [dark, group]
        let image = try #require(Renderer.image(of: board, scale: 1))
        // On the edge, under the glass: grey.
        let edge = pixel(image, 100, 50)
        #expect(edge.r > 60 && edge.r < 200, "on the edge: \(edge)")
        // Under the glass, a little way into the black: lifted by the white beside it.
        #expect(pixel(image, 92, 50).r > 20)
        // Outside the glass nothing is blurred.
        #expect(pixel(image, 45, 50).r < 5)
        #expect(pixel(image, 195, 50).r > 250)
    }

    @Test func aBackgroundBlursLightMovesEveryColourAlike() throws {
        for (light, expected) in [(-0.3, 0.2), (0.3, 0.8), (0, 0.5)] {
            var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            board.fill.color = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)
            var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 20, y: 20, width: 60, height: 60))
            glass.fill.color = .white
            glass.blur = Blur(radius: 6, background: true, brightness: light, fillOpacity: 0)
            board.children = [glass]
            let image = try #require(Renderer.image(of: board, scale: 1))
            // The bytes as drawn, in the sRGB they were drawn in, with nothing converted on the way.
            let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            func at(_ x: Int, _ y: Int) -> [Double] { (0..<3).map { Double(bytes[y * ctx.bytesPerRow + x * 4 + $0]) } }
            let under = at(50, 50)
            #expect(under.allSatisfy { abs($0 - expected * 255) <= 3 }, "light \(light): \(under)")
            // Outside the glass, the paper as it is.
            #expect(at(5, 5).allSatisfy { abs($0 - 127.5) <= 2 }, "\(at(5, 5))")
        }
    }

    @Test func anObjectBlurSpreadsTheLayer() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = .white
        var dot = Node(kind: .rectangle, name: "Dot", frame: CGRect(x: 30, y: 30, width: 40, height: 40))
        dot.fill.color = .black
        dot.blur = Blur(radius: 4)
        board.children = [dot]
        let image = try #require(Renderer.image(of: board, scale: 2))
        #expect(pixel(image, 100, 100).r < 20, "the middle stays dark")
        let past = pixel(image, 56, 100)
        #expect(past.r > 20 && past.r < 240, "just past the edge it spreads: \(past)")
        #expect(pixel(image, 20, 100).r > 250, "far off it is untouched")
    }

    @Test func fillIsDrawnWhereTheFrameIs() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 200, y: 300, width: 100, height: 100))
        board.fill.color = .white
        var box = Node(kind: .rectangle, name: "R", frame: CGRect(x: 10, y: 60, width: 20, height: 20))
        box.fill.color = .black
        board.children = [box]
        let image = try #require(Renderer.image(of: board, scale: 2))
        #expect(pixel(image, 40, 140).r < 10)
        #expect(pixel(image, 40, 100).r > 250)
    }

    @MainActor
    @Test func aFlippedPictureFacesTheOtherWay() throws {
        // A picture of four squares: red at the top left, blue at the top right, green below the red.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ctx = try #require(Renderer.bitmap(CGSize(width: 2, height: 2)))
        for (x, y, color) in [(0, 1, RGBA(r: 1, g: 0, b: 0)), (1, 1, RGBA(r: 0, g: 0, b: 1)), (0, 0, RGBA(r: 0, g: 1, b: 0)), (1, 0, RGBA.black)] {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        let squares = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: squares).representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("squares.png"))
        let assets = Assets(folder: folder)

        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var card = Node(kind: .rectangle, name: "R", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        card.fill.image = ImageFill(asset: "squares.png", mode: .stretch, size: CGSize(width: 2, height: 2))
        board.children = [card]
        func topLeft(_ node: Node) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            board.children = [node]
            return pixel(try #require(Renderer.image(of: board, scale: 1, assets: assets)), 10, 10)
        }
        #expect(try topLeft(card).r > 200)
        let across = BezzleDocument.flipped(card, horizontally: true, about: 50)
        #expect(try topLeft(across).b > 200)
        #expect(try topLeft(BezzleDocument.flipped(card, horizontally: false, about: 50)).g > 200)
        // Flipped back, it is as it was.
        #expect(BezzleDocument.flipped(across, horizontally: true, about: 50) == card)

        // As SVG: the picture is turned over, and the outline that cuts it is not.
        board.children = [across]
        let svg = SVGWriter.document(for: ExportItem(artboard: board), bounds: board.frame, assets: assets)
        #expect(XMLParser(data: Data(svg.utf8)).parse())
        #expect(svg.contains("transform=\"matrix(-1 0 0 1 100 0)\""))
        #expect(svg.contains("<g clip-path="))
    }

    @Test func aBlendModeMixesALayerWithWhatLiesUnderIt() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.fill.color = RGBA(r: 1, g: 0.5, b: 0)
        var tint = Node(kind: .rectangle, name: "Tint", frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        tint.fill.color = RGBA(r: 0.5, g: 0.5, b: 1)
        func middle(_ node: Node) throws -> [Int] {
            board.children = [node]
            let image = try #require(Renderer.image(of: board, scale: 1))
            // The bytes as drawn, in the sRGB they were drawn in, with nothing converted on the way.
            let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            return (0..<3).map { Int(bytes[50 * ctx.bytesPerRow + 50 * 4 + $0]) }
        }
        func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 4 } }
        let normal = try middle(tint)
        #expect(near(normal, [127, 127, 255]), "\(normal)")
        tint.blend = .multiply
        let multiplied = try middle(tint)
        #expect(near(multiplied, [127, 63, 0]), "\(multiplied)")
        // Blurred, it is still mixed with what is under it, not laid over it.
        tint.blur = Blur(radius: 2)
        let blurred = try middle(tint)
        #expect(near(blurred, [127, 63, 0]), "blurred: \(blurred)")
    }
}
