import Testing
import AppKit
@testable import Bezzle

/// Convert to Path on texts: the letters become outlines that look as the text did, on the
/// canvas, whatever the text was dressed in.
@MainActor
struct TextToPathTests {
    private static let ink = RGBA(r: 0.1, g: 0.2, b: 0.6), red = RGBA(r: 0.9, g: 0.1, b: 0.1)

    private func text(_ words: String, size: CGFloat = 40, at p: CGPoint = CGPoint(x: 20, y: 20), width: CGFloat? = nil) -> Node {
        var t = Node(kind: .text, name: "T", frame: CGRect(origin: p, size: CGSize(width: width ?? 0, height: 0)))
        var style = TextStyle()
        style.family = "Helvetica"
        style.size = size
        if width != nil { style.sizing = .autoHeight }
        t.style = style
        t.text = words
        t.fill.color = Self.ink
        t.refit()
        return t
    }

    /// The part of the canvas round `area` as drawn, at four times its size, as sRGB bytes.
    private func drawn(_ bench: Bench, _ area: CGRect, assets: Assets? = nil) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let image = try #require(Renderer.image(of: bench.a, part: area, scale: 4, assets: assets))
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, bytes)
    }

    /// How two pictures of the same letters differ: the share of the inked pixels of either
    /// with no inked pixel of the other within two pixels (half a point at this size), and the
    /// share of the pixels deep inside the letters of both whose colours are not the same. Type
    /// is drawn a little bolder than the same outlines filled as a shape, its letters and lines
    /// snapped to pixels, by less than a pixel at this size, and only at its edges.
    private func apart(_ a: (width: Int, height: Int, bytes: [UInt8]), _ b: (width: Int, height: Int, bytes: [UInt8])) -> (outline: Double, colour: Double) {
        guard a.width == b.width, a.height == b.height else { return (1, 1) }
        let w = a.width, h = a.height
        /// How many pixels of each are inked in every box from the top left, to count those in any box at once.
        func sums(_ p: [UInt8]) -> [Int] {
            var table = [Int](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row = 0
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if min(p[i], p[i + 1], p[i + 2]) < 128 { row += 1 }
                    table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + row
                }
            }
            return table
        }
        let inA = sums(a.bytes), inB = sums(b.bytes)
        func inked(_ table: [Int], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            let x0 = max(x0, 0), y0 = max(y0, 0), x1 = min(x1, w), y1 = min(y1, h)
            return table[y1 * (w + 1) + x1] - table[y0 * (w + 1) + x1] - table[y1 * (w + 1) + x0] + table[y0 * (w + 1) + x0]
        }
        var ink = 0, astray = 0, inside = 0, unlike = 0
        for y in 0..<h {
            for x in 0..<w {
                let a1 = inked(inA, x, y, x + 1, y + 1) == 1, b1 = inked(inB, x, y, x + 1, y + 1) == 1
                if a1 || b1 { ink += 1 }
                if a1 && inked(inB, x - 2, y - 2, x + 3, y + 3) == 0 { astray += 1 }
                if b1 && inked(inA, x - 2, y - 2, x + 3, y + 3) == 0 { astray += 1 }
                if inked(inA, x - 2, y - 2, x + 3, y + 3) == 25 && inked(inB, x - 2, y - 2, x + 3, y + 3) == 25 {
                    inside += 1
                    let i = (y * w + x) * 4
                    if (0..<3).contains(where: { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) > 16 }) { unlike += 1 }
                }
            }
        }
        return (ink == 0 ? 1 : Double(astray) / Double(ink), inside == 0 ? 1 : Double(unlike) / Double(inside))
    }

    /// Converts the text "T" on the bench, and returns what it became.
    private func convert(_ bench: Bench) throws -> Node {
        let id = try #require(bench.node("T")?.id)
        bench.store.selection = [id]
        #expect(bench.store.canConvertToPath)
        bench.step { bench.store.convertToPath() }
        return try #require(bench.store.doc.node(id))
    }

    private func looksTheSame(_ t: Node, assets: Assets? = nil, _ check: (Node) -> Void = { _ in }) throws {
        let bench = Bench(extra: [t])
        // Round the text where it lies, its shadow and all, on the artboard at 100,100.
        let area = Geometry.bounds(of: t).offsetBy(dx: 100, dy: 100).insetBy(dx: -16, dy: -16)
        let before = try drawn(bench, area, assets: assets)
        let made = try convert(bench)
        check(made)
        let after = try drawn(bench, area, assets: assets)
        let (outline, colour) = apart(before, after)
        #expect(outline < 0.001, "\(Int(outline * 10_000)) in 10 000 inked pixels lie astray")
        #expect(colour < 0.001, "\(Int(colour * 10_000)) in 10 000 pixels inside the letters change colour")
    }

    @Test func aTextBecomesOnePathThatLooksTheSame() throws {
        var t = text("Hamburgefonstiv")
        t.rotation = 12
        t.shadow.on = true
        t.shadow.y = 4
        t.opacity = 0.8
        try looksTheSame(t) { made in
            #expect(made.kind == .path)
            #expect(made.name == "T")
            #expect(made.rotation == 12)
            #expect(made.fill.color == Self.ink)
            #expect(made.shadow.on && made.opacity == 0.8)
            #expect(made.text == nil && made.style == nil)
            // Fitted round the letters, not the lines they stood in.
            #expect(made.frame.height < t.frame.height)
        }
    }

    @Test func lettersOfTheirOwnColourBecomeAPathOfTheirOwnInAGroup() throws {
        var t = text("Hello world")
        t.restyleLetters(in: NSRange(location: 6, length: 5)) { $0.color = Self.red }
        t.opacity = 0.6
        try looksTheSame(t) { made in
            #expect(made.kind == .group)
            #expect(made.name == "T" && made.opacity == 0.6)
            #expect(made.children.map(\.kind) == [.path, .path])
            #expect(made.children.map(\.name) == ["Hello", "world"])
            #expect(made.children.map(\.fill.color) == [Self.ink, Self.red])
            #expect(made.children.allSatisfy { $0.opacity == 1 })
        }
    }

    @Test func turnedLettersOfTheirOwnColourStayWhereTheyWere() throws {
        var t = text("Hello world")
        t.restyleLetters(in: NSRange(location: 0, length: 5)) { $0.color = Self.red }
        t.rotation = -20
        try looksTheSame(t) { made in
            #expect(made.kind == .group && made.rotation == 0)
            #expect(made.children.allSatisfy { $0.rotation == -20 })
        }
    }

    @Test func linesUnderAndThroughLettersComeAlong() throws {
        var t = text("Underlined jumpy words that wrap onto more lines", size: 28, width: 260)
        t.style?.underline = true
        t.restyleLetters(in: NSRange(location: 11, length: 5)) { $0.strikethrough = true }
        try looksTheSame(t)
    }

    @Test func listsKeepTheirMarkers() throws {
        var t = text("Apples\nPears\nPlums", size: 24, width: 200)
        t.restyleLetters(in: NSRange(location: 0, length: 17)) { $0.list = .number }
        try looksTheSame(t)
    }

    @Test func aGradientStaysWhereItLay() throws {
        // Lines far apart, so that the letters fill much less of the text's frame than of the path's.
        var t = text("Gradient", size: 60)
        t.style?.lineSpacing = 160
        t.refit()
        t.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: Self.red), GradientStop(offset: 1, color: Self.ink)],
                                   start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        try looksTheSame(t) { made in
            #expect(made.fill.gradient != nil)
            #expect(made.fill.gradient != t.fill.gradient)
        }
    }

    @Test func aPictureStaysWhereItLay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Four bands of colour across, so that a picture moved or grown shows it.
        let ctx = try #require(Renderer.bitmap(CGSize(width: 4, height: 3)))
        for (i, c) in [Self.red, Self.ink, RGBA(r: 0, g: 0.7, b: 0), RGBA(r: 0.9, g: 0.7, b: 0)].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: i, y: 0, width: 1, height: 3))
        }
        let bands = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: bands).representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("bands.png"))
        var t = text("Picture", size: 70)
        t.fill.image = ImageFill(asset: "bands.png", mode: .cover, size: CGSize(width: 4, height: 3), offset: CGPoint(x: 0.1, y: 0), scale: 1.3)
        try looksTheSame(t, assets: Assets(folder: folder)) { made in
            #expect(made.fill.image?.asset == "bands.png")
        }
    }

    @Test func lettersOnACurveKeepTheirCurve() throws {
        var t = text("Round and round", size: 30, at: CGPoint(x: 60, y: 100))
        t.bend(to: 0.4)
        #expect(t.isCurved)
        try looksTheSame(t) { made in
            #expect(made.kind == .path && made.curve == nil && made.curvePath == nil)
        }
    }

    @Test func undoingBringsTheTextBack() throws {
        let bench = Bench(extra: [text("Words")])
        let made = try convert(bench)
        #expect(made.kind == .path)
        bench.undo.undo()
        let back = try #require(bench.node("T"))
        #expect(back.kind == .text && back.text == "Words" && back.id == made.id)
    }

    @Test func emojiHaveNoOutlinesSoTheirTextStaysText() throws {
        let bench = Bench(extra: [text("Hi \u{1F44B}")])
        let made = try convert(bench)
        #expect(made.kind == .text)
    }

    @Test func aTextWithNoLettersIsNotOffered() {
        let bench = Bench(extra: [text("   ")])
        bench.store.selection = [bench.node("T")!.id]
        #expect(!bench.store.canConvertToPath)
    }
}
