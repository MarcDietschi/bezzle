import Testing
import AppKit
@testable import Bezzle

/// Shader fills drawn by Bezzle: where they lie, the right way round, at the film's moment, and as
/// a website's canvas drew them.
@MainActor
@Suite(.serialized)
struct ShaderDrawingTests {
    /// Red growing left to right, green growing bottom to top, as WebGL lays gl_FragCoord out.
    static let gradient = "precision mediump float; uniform vec2 u_resolution; uniform float u_strength;"
        + " void main() { vec2 p = gl_FragCoord.xy / u_resolution; gl_FragColor = vec4(p.x * u_strength, p.y, 0.0, 1.0); }"

    static func board(_ fill: ShaderFill, flipped: Bool = false) -> Node {
        var layer = CanvasTests.rect("Glow", CGRect(x: 0, y: 0, width: 200, height: 100))
        layer.fill = Fill(color: .white)
        layer.fill.shader = flipped ? fill.flipped(horizontally: true) : fill
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        board.children = [layer]
        return board
    }

    /// A pixel's sRGB values, 0…1, from its bytes as they are, counted from the top left: no
    /// colour management on the way, which would change what is measured.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
    }

    @Test func drawsAShaderTheRightWayRound() throws {
        let fill = ShaderFill.surface(fragment: Self.gradient, size: CGSize(width: 400, height: 200), uniforms: ["u_strength": [1]], time: nil)
        let image = try #require(Renderer.image(of: Self.board(fill), scale: 1, assets: nil))
        #expect(image.width == 200 && image.height == 100)
        let topLeft = Self.pixel(image, 2, 2), bottomRight = Self.pixel(image, 197, 97)
        // Top left: no red, nearly all green; bottom right: nearly all red, no green.
        #expect(topLeft.r < 0.05 && topLeft.g > 0.9, "\(topLeft)")
        #expect(bottomRight.r > 0.9 && bottomRight.g < 0.1, "\(bottomRight)")
        // Turned over with its layer, the red is on the left.
        let flipped = try #require(Renderer.image(of: Self.board(fill, flipped: true), scale: 1, assets: nil))
        #expect(Self.pixel(flipped, 2, 50).r > 0.9 && Self.pixel(flipped, 197, 50).r < 0.05)
    }

    @Test func drawsSharpWhenLookedAtCloselyAndInAPDF() throws {
        let fill = ShaderFill.surface(fragment: Self.gradient, size: CGSize(width: 40, height: 20), uniforms: ["u_strength": [1]], time: nil)
        // Drawn from a 40 by 20 buffer at ten times its size, it is still a smooth ramp: across what
        // is one of its pixels, fifty here, it takes many values, rising, and not one.
        let image = try #require(Renderer.image(of: Self.board(fill), scale: 10, assets: nil))
        let reds = stride(from: 1000, to: 1050, by: 5).map { Self.pixel(image, $0, 500).r }
        #expect(zip(reds, reds.dropFirst()).allSatisfy { $0 <= $1 } && Set(reds).count >= 5, "\(reds)")
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = CGDataConsumer(data: pdf as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        Renderer.withFlippedContext(ctx) { Renderer.drawArtboard(Self.board(fill), in: ctx, options: Renderer.Options()) }
        ctx.endPDFPage()
        ctx.closePDF()
        #expect(pdf.length > 2000)
    }

    @Test func theFilmDrawsKeyedInputsAtTheirMoment() throws {
        var board = Self.board(ShaderFill.surface(fragment: Self.gradient, size: CGSize(width: 200, height: 100), uniforms: ["u_strength": [1]], time: nil))
        board.children[0].poseInput("u_strength", [0], at: 2)
        let size = CGSize(width: 200, height: 100)
        let start = try #require(FilmExport.frame(of: board, at: 0, size: size, assets: nil))
        let end = try #require(FilmExport.frame(of: board, at: 2, size: size, assets: nil))
        #expect(Self.pixel(start, 190, 50).r > 0.85)
        #expect(Self.pixel(end, 190, 50).r < 0.05)
    }

    @Test(.timeLimit(.minutes(5))) func aWebsitesCanvasIsDrawnAsItDrewIt() async throws {
        let (read, held) = try await WebTest.read(ShaderImportTests.gradient)
        #expect(read.assets.stills.isEmpty && read.assets.scenes.count == 1)
        let (doc, _) = WebConverter.document([read], source: "test")
        var board = try #require(doc.nodes.first)
        board.frame.origin = .zero
        func find(_ n: Node, _ x: CGFloat, _ y: CGFloat) -> (Node, CGPoint)? {
            if n.fill.shader != nil { return (n, CGPoint(x: x + n.frame.minX, y: y + n.frame.minY)) }
            for c in n.children { if let f = find(c, n.isArtboard ? 0 : x + n.frame.minX, n.isArtboard ? 0 : y + n.frame.minY) { return f } }
            return nil
        }
        let (layer, origin) = try #require(board.children.lazy.compactMap { find($0, 0, 0) }.first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shader-\(UUID().uuidString).bezzle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        for (name, data) in held { try data.write(to: folder.appendingPathComponent("images").appendingPathComponent(name)) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let drawn = try #require(Renderer.image(of: board, scale: 1, assets: Assets(design: folder)))
        // The canvas as the page drew it, at the moment it came in, which is where its shader's time starts.
        let asset = try #require(layer.fill.image?.asset)
        let data = try #require(held[asset])
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let canvas = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(canvas.width == 320 && canvas.height == 200)
        for (x, y) in [(20, 20), (160, 100), (300, 180)] {
            let s = Self.pixel(drawn, Int(origin.x) + x, Int(origin.y) + y), c = Self.pixel(canvas, x, y)
            #expect(abs(s.r - c.r) < 0.04 && abs(s.g - c.g) < 0.04 && abs(s.b - c.b) < 0.04, "at \(x), \(y): \(s) drawn, \(c) on the page")
        }
    }
}
