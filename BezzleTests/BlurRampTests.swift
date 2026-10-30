import Testing
import AppKit
@testable import Bezzle

/// Blurs that grow across a layer, from sharp to blurred.
struct BlurRampTests {
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return Int(c.redComponent * 255)
    }

    /// A black bar on white, blurred by `blur`.
    private func bar(_ blur: Blur, rotation: Double = 0) throws -> CGImage {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        board.fill.color = .white
        var bar = Node(kind: .rectangle, name: "Bar", frame: CGRect(x: 50, y: 75, width: 100, height: 50))
        bar.fill.color = RGBA(r: 0, g: 0, b: 0)
        bar.rotation = rotation
        bar.blur = blur
        board.children = [bar]
        return try #require(Renderer.image(of: board, scale: 1))
    }

    @Test func aGrowingBlurIsSharpAtItsStartAndBlurredAtItsEnd() throws {
        let across = BlurRamp(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        let image = try bar(Blur(radius: 6, ramp: across))
        // Just outside the sharp left edge it is white; just outside the blurred right one, grey.
        #expect(pixel(image, 47, 100) > 245, "left: \(pixel(image, 47, 100))")
        #expect(pixel(image, 152, 100) < 215, "right: \(pixel(image, 152, 100))")
        // Blurred evenly, both edges are alike.
        let even = try bar(Blur(radius: 6))
        #expect(abs(pixel(even, 47, 100) - pixel(even, 152, 100)) < 6)
    }

    @Test func theRampTurnsWithItsLayer() throws {
        // Turned half round, the ramp's start, on its left, is now on the right.
        let across = BlurRamp(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        let image = try bar(Blur(radius: 6, ramp: across), rotation: 180)
        #expect(pixel(image, 152, 100) > 245, "right: \(pixel(image, 152, 100))")
        #expect(pixel(image, 47, 100) < 215, "left: \(pixel(image, 47, 100))")
    }

    @Test func aGrowingBackgroundBlurBlursWhatLiesBehindMoreTowardItsEnd() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 40, y: 60, width: 200, height: 100))
        board.fill.color = .white
        var dark = Node(kind: .rectangle, name: "Dark", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        dark.fill.color = RGBA(r: 0, g: 0, b: 0)
        // Clear glass over the edge between black and white, sharp at its top and blurred at its foot.
        var glass = Node(kind: .rectangle, name: "Glass", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        glass.fill.color = .white
        glass.blur = Blur(radius: 10, background: true, ramp: BlurRamp(start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)))
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 50, y: 0, width: 100, height: 100))
        group.children = [glass]
        board.children = [dark, group]
        let image = try #require(Renderer.image(of: board, scale: 1))
        let top = pixel(image, 102, 3) - pixel(image, 97, 3), foot = pixel(image, 102, 96) - pixel(image, 97, 96)
        #expect(top > 200, "across the edge at the top: \(top)")
        #expect(foot < 140, "across the edge at the foot: \(foot)")
    }

    @Test func svgShowsTheBlurredLayerMoreTowardTheRampsEnd() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        var bar = Node(kind: .rectangle, name: "Bar", frame: CGRect(x: 50, y: 75, width: 100, height: 50))
        bar.blur = Blur(radius: 6, ramp: .down)
        board.children = [bar]
        let item = ExportItem(artboard: board)
        let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: nil), assets: nil)
        let parser = XMLParser(data: Data(svg.utf8))
        #expect(parser.parse(), "\(parser.parserError.map { "\($0)" } ?? "")")
        #expect(svg.contains("<mask") && svg.contains("<feGaussianBlur") && svg.contains("<linearGradient"))
        // The ramp runs down the bar: from 35% of the way to its foot.
        #expect(svg.contains("y1=\"92.5\"") && svg.contains("y2=\"125\""), "\(svg)")
    }

    @Test func aRampIsKeptAndOlderBlursHaveNone() throws {
        var node = Node(kind: .rectangle, name: "R", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        node.blur = Blur(radius: 4, ramp: BlurRamp.toward(2))
        let back = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node))
        #expect(back.blur?.ramp == BlurRamp.toward(2))
        let old = try JSONDecoder().decode(Blur.self, from: Data(#"{"on":true,"radius":8,"background":false,"brightness":0,"fillOpacity":0}"#.utf8))
        #expect(old.ramp == nil && old.radius == 8)
    }

    @Test func rampsTowardEachEdgeBlurThere() {
        #expect(BlurRamp.toward(0) == .down)
        #expect(BlurRamp.toward(1).end == CGPoint(x: 0, y: 0.5))
        #expect(BlurRamp.toward(2).end == CGPoint(x: 0.5, y: 0))
        #expect(BlurRamp.toward(3).end == CGPoint(x: 1, y: 0.5))
        for edge in 0..<4 {
            let r = BlurRamp.toward(edge)
            #expect(hypot(r.end.x - r.start.x, r.end.y - r.start.y) > 0.6)
        }
    }
}
