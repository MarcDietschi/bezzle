import XCTest
@testable import Vectorizer

/// Pictures drawn here, where every edge is known, traced and held against what was drawn.
final class VectorizerTests: XCTestCase {
    /// A picture of `w` by `h`, each pixel the mean of 8 by 8 samples of `color`, which answers
    /// red, green, blue and alpha for a place in it.
    private func picture(_ w: Int, _ h: Int, _ color: (Double, Double) -> (Double, Double, Double, Double)) -> Bitmap {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let n = 8
        for y in 0..<h {
            for x in 0..<w {
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for j in 0..<n {
                    for i in 0..<n {
                        let c = color(Double(x) + (Double(i) + 0.5) / Double(n), Double(y) + (Double(j) + 0.5) / Double(n))
                        r += c.0 * c.3; g += c.1 * c.3; b += c.2 * c.3; a += c.3
                    }
                }
                let i = (y * w + x) * 4
                if a > 0 {
                    pixels[i] = UInt8((r / a).rounded()); pixels[i + 1] = UInt8((g / a).rounded()); pixels[i + 2] = UInt8((b / a).rounded())
                }
                pixels[i + 3] = UInt8((a / Double(n * n) * 255).rounded())
            }
        }
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    private let paper = (244.0, 241.0, 234.0, 1.0), ink = (217.0, 72.0, 15.0, 1.0)

    /// Twice the area an outline goes round: more than nothing the one way, less the other.
    private func area2(_ outline: Outline) -> Double {
        var sum = 0.0, last = outline.start
        for stretch in outline.stretches {
            let p = stretch.end
            sum += last.x * p.y - p.x * last.y
            last = p
        }
        return sum
    }

    func testADiscIsAnEllipseWhereItWasDrawn() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(picture(160, 120) { x, y in
            hypot(x - 70.3, y - 55.6) <= 36.25 ? self.ink : self.paper
        }))
        XCTAssertEqual(traced.shapes.count, 2)
        XCTAssertEqual(traced.palette.count, 2)
        guard case .ellipse(let c, let rx, let ry, _)? = traced.shapes.last?.figure else { return XCTFail("no ellipse") }
        XCTAssertEqual(c.x, 70.3, accuracy: 0.1)
        XCTAssertEqual(c.y, 55.6, accuracy: 0.1)
        XCTAssertEqual(rx, 36.25, accuracy: 0.1)
        XCTAssertEqual(ry, 36.25, accuracy: 0.1)
    }

    func testARectangleKeepsItsSidesBetweenThePixels() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(picture(200, 140) { x, y in
            x >= 40.5 && x <= 150.5 && y >= 30.25 && y <= 100.75 ? self.ink : self.paper
        }))
        guard case .rectangle(let c, let w, let h, let radius, let angle)? = traced.shapes.last?.figure else { return XCTFail("no rectangle") }
        XCTAssertEqual(c.x, 95.5, accuracy: 0.08)
        XCTAssertEqual(c.y, 65.5, accuracy: 0.08)
        XCTAssertEqual(w, 110, accuracy: 0.15)
        XCTAssertEqual(h, 70.5, accuracy: 0.15)
        XCTAssertEqual(radius, 0, accuracy: 0.01)
        XCTAssertEqual(angle, 0, accuracy: 0.01)
    }

    func testAHoleRunsTheOtherWayRound() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(picture(160, 160) { x, y in
            let d = hypot(x - 80, y - 80)
            return d <= 60 && d >= 30 ? self.ink : self.paper
        }))
        let ring = try XCTUnwrap(traced.shapes.first { $0.outlines.count == 2 })
        XCTAssertGreaterThan(area2(ring.outlines[0]) * area2(ring.outlines[1]), -.infinity)
        XCTAssertLessThan(area2(ring.outlines[0]) * area2(ring.outlines[1]), 0)
        XCTAssertGreaterThan(abs(area2(ring.outlines[0])), abs(area2(ring.outlines[1])))
    }

    func testNothingIsMadeOfWhatIsClear() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(picture(120, 120) { x, y in
            hypot(x - 60, y - 60) <= 40 ? self.ink : (0, 0, 0, 0)
        }))
        XCTAssertEqual(traced.shapes.count, 1)
        XCTAssertEqual(traced.shapes[0].area, .pi * 1600, accuracy: 30)
    }

    func testPixelArtKeepsItsSquares() throws {
        // A chequered board of four colours, each square eight pixels.
        let colors: [(Double, Double, Double, Double)] = [(20, 20, 30, 1), (240, 200, 60, 1), (200, 60, 70, 1), (60, 140, 220, 1)]
        let traced = try XCTUnwrap(Vectorizer.trace(picture(64, 64) { x, y in
            colors[(Int(x) / 8 + 2 * (Int(y) / 8)) % 4]
        }))
        XCTAssertTrue(traced.pixelArt)
        for shape in traced.shapes {
            for outline in shape.outlines {
                for stretch in outline.stretches {
                    guard case .line(let p) = stretch else { return XCTFail("a curve in pixel art") }
                    // On a square's corner where it shows, and a pixel under the squares over it.
                    XCTAssertEqual(p.x, p.x.rounded(), accuracy: 1e-6)
                    XCTAssertEqual(p.y, p.y.rounded(), accuracy: 1e-6)
                    XCTAssertLessThanOrEqual(abs(p.x - (p.x / 8).rounded() * 8), 1)
                    XCTAssertLessThanOrEqual(abs(p.y - (p.y / 8).rounded() * 8), 1)
                }
            }
        }
    }

    func testItStopsWhenTold() {
        let bitmap = picture(160, 120) { x, y in hypot(x - 70, y - 55) <= 36 ? self.ink : self.paper }
        XCTAssertNil(Vectorizer.trace(bitmap, progress: { _ in false }))
    }

    func testFewerColoursWhenAsked() throws {
        let bitmap = picture(180, 60) { x, _ in
            [(230.0, 40.0, 40.0, 1.0), (40.0, 160.0, 70.0, 1.0), (40.0, 80.0, 220.0, 1.0)][min(Int(x) / 60, 2)]
        }
        XCTAssertEqual(try XCTUnwrap(Vectorizer.trace(bitmap)).palette.count, 3)
        XCTAssertEqual(try XCTUnwrap(Vectorizer.trace(bitmap, settings: Settings(colors: 2))).palette.count, 2)
    }

    func testManyShapesShareLayersAndStayInOrder() throws {
        // Dots of two colours in rows on paper, and a dot on each dot.
        let traced = try XCTUnwrap(Vectorizer.trace(picture(240, 240) { x, y in
            let cx = (x / 40).rounded(.down) * 40 + 20, cy = (y / 40).rounded(.down) * 40 + 20
            let d = hypot(x - cx, y - cy), odd = (Int(x / 40) + Int(y / 40)) % 2 == 1
            if d <= 6 { return odd ? self.ink : (30, 60, 160, 1) }
            if d <= 15 { return odd ? (30, 60, 160, 1) : self.ink }
            return self.paper
        }))
        XCTAssertEqual(traced.shapes.count, 73)
        XCTAssertEqual(traced.layers().count, 73)
        let packed = traced.layers(most: 10)
        XCTAssertEqual(packed.reduce(0) { $0 + $1.shapes }, 73)
        // Paper, and a few layers of dots: far fewer than there are dots.
        XCTAssertLessThanOrEqual(packed.count, 12)
        XCTAssertEqual(packed.first?.shapes, 1)
        XCTAssertNil(packed.first { $0.figure != nil })
    }

    // MARK: Pictures that waver, as kept coarsely or scaled

    /// `bitmap` with every pixel moved a little, each time the same way.
    private func worn(_ bitmap: Bitmap, by most: Int = 10) -> Bitmap {
        var pixels = bitmap.pixels
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(bitmap.width * bitmap.height) {
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let move = Int((seed >> 33) % UInt64(2 * most + 1)) - most
                pixels[i * 4 + c] = UInt8(min(max(Int(pixels[i * 4 + c]) + move, 0), 255))
            }
        }
        return Bitmap(width: bitmap.width, height: bitmap.height, pixels: pixels)
    }

    /// The ends of an outline's stretches and the middles of its curves.
    private func places(along outline: Outline) -> [Spot] {
        var out: [Spot] = [], last = outline.start
        for stretch in outline.stretches {
            if case .curve(let a, let b, let p) = stretch {
                out.append(Spot((last.x + 3 * a.x + 3 * b.x + p.x) / 8, (last.y + 3 * a.y + 3 * b.y + p.y) / 8))
            }
            out.append(stretch.end)
            last = stretch.end
        }
        return out
    }

    func testAWornDiscStaysRoundToThePicturesEdge() throws {
        // A long arc's handles lie outside the picture; the arc must not be bent for it.
        let traced = try XCTUnwrap(Vectorizer.trace(worn(picture(240, 240) { x, y in
            hypot(x - 120, y - 120) <= 117 ? self.ink : self.paper
        })))
        XCTAssertEqual(traced.shapes.count, 2)
        // The shape on top shows the disc's edge: the disc itself, or the paper round it.
        let top = try XCTUnwrap(traced.shapes.last)
        var seen = 0
        for outline in top.outlines {
            let round = places(along: outline).filter { min($0.x, $0.y, 240 - $0.x, 240 - $0.y) > 0.5 }
            guard !round.isEmpty else { continue }
            XCTAssertLessThanOrEqual(outline.stretches.count, 16)
            for p in round { XCTAssertEqual(hypot(p.x - 120, p.y - 120), 117, accuracy: 0.8) }
            seen += round.count
        }
        XCTAssertGreaterThanOrEqual(seen, 8)
    }

    func testAWornTriangleHasThreeStraightSides() throws {
        func inside(_ x: Double, _ y: Double) -> Bool {
            let a = (40.0, 170.0), b = (210.0, 150.0), c = (110.0, 30.0)
            func side(_ p: (Double, Double), _ q: (Double, Double)) -> Double { (q.0 - p.0) * (y - p.1) - (q.1 - p.1) * (x - p.0) }
            let s1 = side(a, b), s2 = side(b, c), s3 = side(c, a)
            return (s1 <= 0 && s2 <= 0 && s3 <= 0) || (s1 >= 0 && s2 >= 0 && s3 >= 0)
        }
        let traced = try XCTUnwrap(Vectorizer.trace(worn(picture(250, 200) { x, y in inside(x, y) ? self.ink : self.paper })))
        XCTAssertEqual(traced.shapes.count, 2)
        let outline = try XCTUnwrap(traced.shapes.last?.outlines.first)
        XCTAssertEqual(outline.stretches.count, 3)
        for stretch in outline.stretches {
            guard case .line = stretch else { return XCTFail("a side is no line") }
        }
    }

    func testAThinOutlineBetweenTwoColoursIsOneRing() throws {
        // A line a pixel and a half thick round a disc: neither the disc's colour nor the
        // paper's, and nowhere pure. It comes out one ring, not a row of pieces.
        let fill = (164.0, 227.0, 198.0, 1.0), line = (96.0, 122.0, 138.0, 1.0)
        let traced = try XCTUnwrap(Vectorizer.trace(worn(picture(220, 220) { x, y in
            let d = hypot(x - 110.3, y - 109.6)
            return d <= 70 ? fill : d <= 71.5 ? line : self.paper
        }, by: 6)))
        let dark = traced.shapes.filter { Int($0.color.r) + Int($0.color.g) + Int($0.color.b) < 480 }
        XCTAssertEqual(dark.count, 1)
        XCTAssertEqual(dark.first?.outlines.count, 2)
        XCTAssertEqual(traced.shapes.count, 3)
    }

    func testLessDetailKeepsFewerShapes() throws {
        // Dots from large to very small, and faint ones: fewer of them the less detail is wanted.
        let faint = (228.0, 222.0, 212.0, 1.0)
        let bitmap = worn(picture(300, 200) { x, y in
            for k in 0..<12 {
                let cx = 30 + Double(k % 6) * 46, cy = 50 + Double(k / 6) * 90, r = 2 + Double(k) * 1.6
                if hypot(x - cx, y - cy) <= r { return k % 3 == 2 ? faint : self.ink }
            }
            return self.paper
        }, by: 6)
        func shapes(_ detail: Double) -> Int { Vectorizer.trace(bitmap, settings: Settings(detail: detail))?.shapes.count ?? 0 }
        let little = shapes(0.05), middling = shapes(0.5), much = shapes(1)
        XCTAssertLessThan(little, middling)
        XCTAssertLessThanOrEqual(middling, much)
        XCTAssertGreaterThanOrEqual(much, 12)
    }
}
