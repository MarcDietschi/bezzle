import XCTest
@testable import Vectorizer

/// Colours that run into each other: found as one shape with those colours where a picture has
/// them, and not found where it has shapes of nearly one colour.
final class BlendTests: XCTestCase {
    private let paper: Paint = (246, 241, 231), dark: Paint = (30, 42, 58), white: Paint = (255, 255, 255)

    private func mixed(_ a: Paint, _ b: Paint, _ t: Double) -> Paint {
        let u = min(max(t, 0), 1)
        return (a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
    }

    /// Colours running straight across, from `a` at `from` to `b` at `to`.
    private func straight(_ a: Paint, _ b: Paint, from: Spot, to: Spot) -> (Double, Double) -> Paint {
        let dx = to.x - from.x, dy = to.y - from.y, l = dx * dx + dy * dy
        return { x, y in self.mixed(a, b, ((x - from.x) * dx + (y - from.y) * dy) / l) }
    }

    /// Colours running outward, from `a` at `middle` to `b` as far out as `reach`.
    private func round(_ a: Paint, _ b: Paint, middle: Spot, reach: Double) -> (Double, Double) -> Paint {
        { x, y in self.mixed(a, b, ((x - middle.x) * (x - middle.x) + (y - middle.y) * (y - middle.y)).squareRoot() / reach) }
    }

    /// How far a shape's colours lie from a picture's at some places, at the worst.
    private func off(_ shape: Shape, from color: (Double, Double) -> Paint, at spots: [Spot]) -> Double {
        var worst = 0.0
        for spot in spots {
            let found = shape.blend?.color(at: spot) ?? shape.color, drawn = color(spot.x, spot.y)
            worst = max(worst, abs(Double(found.r) - drawn.0), abs(Double(found.g) - drawn.1), abs(Double(found.b) - drawn.2))
        }
        return worst
    }

    private func grid(_ xs: StrideThrough<Double>, _ ys: StrideThrough<Double>, where holds: (Double, Double) -> Bool = { _, _ in true }) -> [Spot] {
        var out: [Spot] = []
        for y in ys {
            for x in xs where holds(x, y) { out.append(Spot(x, y)) }
        }
        return out
    }

    func testABlendTellsTheColourOfAPlace() {
        let red = Tint(r: 200, g: 0, b: 0), blue = Tint(r: 0, g: 0, b: 100)
        let across = Blend(kind: .linear, start: Spot(10, 10), end: Spot(110, 10), stops: [.init(offset: 0, color: red), .init(offset: 0.5, color: blue), .init(offset: 1, color: red)])
        XCTAssertEqual(across.color(at: Spot(0, 80)), red)
        XCTAssertEqual(across.color(at: Spot(60, -5)), blue)
        XCTAssertEqual(across.color(at: Spot(35, 40)), Tint(r: 100, g: 0, b: 50))
        XCTAssertEqual(across.color(at: Spot(300, 0)), red)
        let outward = Blend(kind: .radial, start: Spot(50, 50), end: Spot(50, 90), stops: [.init(offset: 0, color: red), .init(offset: 1, color: blue)])
        XCTAssertEqual(outward.color(at: Spot(50, 50)), red)
        XCTAssertEqual(outward.color(at: Spot(30, 50)), Tint(r: 100, g: 0, b: 50))
        XCTAssertEqual(outward.color(at: Spot(0, 0)), blue)
    }

    func testColoursRunningStraightAcrossAreOneShape() throws {
        let from = Spot(30, 20), to = Spot(210, 140)
        let color = straight((30, 60, 160), (240, 180, 90), from: from, to: to)
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(240, 160, color)))
        XCTAssertEqual(traced.shapes.count, 1)
        let blend = try XCTUnwrap(traced.shapes.first?.blend)
        XCTAssertEqual(blend.kind, .linear)
        // The same way as drawn, to four degrees.
        let dx = blend.end.x - blend.start.x, dy = blend.end.y - blend.start.y
        let turn = (dx * (to.x - from.x) + dy * (to.y - from.y)) / ((dx * dx + dy * dy).squareRoot() * 216.33)
        XCTAssertGreaterThan(turn, 0.9976)
        XCTAssertLessThanOrEqual(blend.stops.count, 4, "\(blend.stops)")
        XCTAssertLessThanOrEqual(off(traced.shapes[0], from: color, at: grid(stride(from: 6, through: 234, by: 19), stride(from: 6, through: 154, by: 17))), 5)
        XCTAssertTrue(traced.svg().contains("<linearGradient id=\"b0\" gradientUnits=\"userSpaceOnUse\""))
        XCTAssertTrue(traced.svg().contains("fill=\"url(#b0)\""))
    }

    func testColoursRunningOutwardAreOneShapeOnItsGround() throws {
        // A ball lit from the upper left, as a round run of colours whose middle is not the
        // ball's.
        let middle = Spot(74, 62)
        let lit = round((255, 232, 160), (176, 64, 20), middle: middle, reach: 86)
        func ball(_ x: Double, _ y: Double) -> Bool { (x - 92) * (x - 92) + (y - 82) * (y - 82) <= 62 * 62 }
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(190, 170) { x, y in ball(x, y) ? lit(x, y) : self.paper }))
        XCTAssertEqual(traced.shapes.count, 2)
        XCTAssertNil(traced.shapes[0].blend)
        let blend = try XCTUnwrap(traced.shapes.last?.blend)
        XCTAssertEqual(blend.kind, .radial)
        XCTAssertEqual(blend.start.x, middle.x, accuracy: 3)
        XCTAssertEqual(blend.start.y, middle.y, accuracy: 3)
        let inside = grid(stride(from: 34, through: 150, by: 9), stride(from: 24, through: 140, by: 9)) { x, y in
            (x - 92) * (x - 92) + (y - 82) * (y - 82) <= 57 * 57
        }
        XCTAssertLessThanOrEqual(off(traced.shapes[1], from: lit, at: inside), 6)
        XCTAssertTrue(traced.svg().contains("<radialGradient id=\"b1\""))
        // And as layers it is one of its own, with its colours.
        let layers = traced.layers()
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers.last?.blend, blend)
    }

    func testAGentleRunsMiddleAndTheEdgesBesideItAreFound() throws {
        // A sky that runs, on it a ball lit from off its middle, so gently that from one pixel
        // to the next its colour changes by half a level, and a white bar.
        let sky = straight((36, 61, 128), (242, 168, 128), from: Spot(0, 0), to: Spot(150, 300))
        let middle = Spot(120, 115)
        let lit = round((255, 230, 158), (178, 66, 20), middle: middle, reach: 170)
        func ball(_ x: Double, _ y: Double) -> Bool { (x - 150) * (x - 150) + (y - 150) * (y - 150) <= 110 * 110 }
        func bar(_ x: Double, _ y: Double) -> Bool { x >= 290 && x <= 380 && y >= 200.5 && y <= 230.5 }
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(400, 300) { x, y in ball(x, y) ? lit(x, y) : bar(x, y) ? self.white : sky(x, y) }))
        XCTAssertEqual(traced.shapes.count, 3)
        XCTAssertEqual(traced.shapes.first?.blend?.kind, .linear)
        // Which way the colours change at a pixel is half chance in such a run, and yet its
        // middle is where the light is.
        let round = try XCTUnwrap(traced.shapes.first { $0.blend?.kind == .radial })
        XCTAssertEqual(round.blend?.start.x ?? 0, middle.x, accuracy: 1)
        XCTAssertEqual(round.blend?.start.y ?? 0, middle.y, accuracy: 1)
        let inside = grid(stride(from: 46, through: 254, by: 13), stride(from: 46, through: 254, by: 13)) { x, y in
            (x - 150) * (x - 150) + (y - 150) * (y - 150) <= 104 * 104
        }
        XCTAssertLessThanOrEqual(off(round, from: lit, at: inside), 4)
        // The palette has a colour for each band of the ball and of the sky, and an edge read
        // by those lies up to half a pixel off, another way beside each band. Placed by the
        // runs' own colours it is the circle drawn, to a tenth of a pixel.
        guard case .ellipse(let center, let radiusX, let radiusY, _)? = round.figure else { return XCTFail("the ball is no ellipse: \(String(describing: round.figure))") }
        XCTAssertEqual(center.x, 150, accuracy: 0.1)
        XCTAssertEqual(center.y, 150, accuracy: 0.1)
        XCTAssertEqual(radiusX, 110, accuracy: 0.1)
        XCTAssertEqual(radiusY, 110, accuracy: 0.1)
        let flat = try XCTUnwrap(traced.shapes.first { $0.blend == nil })
        guard case .rectangle(let at, let width, let height, _, _)? = flat.figure else { return XCTFail("the bar is no rectangle") }
        XCTAssertEqual(at.x, 335, accuracy: 0.1)
        XCTAssertEqual(at.y, 215.5, accuracy: 0.1)
        XCTAssertEqual(width, 90, accuracy: 0.15)
        XCTAssertEqual(height, 30, accuracy: 0.15)
    }

    func testShapesOnColoursThatRunStayThemselves() throws {
        // A sky with a dark disc, a white bar and a bar of one of the sky's own colours on
        // it, lying where the sky is another colour: three shapes of one colour each on one of
        // colours running.
        let sky = straight((60, 90, 170), (120, 150, 210), from: Spot(0, 0), to: Spot(260, 0))
        let own = sky(208, 0)
        func disc(_ x: Double, _ y: Double) -> Bool { (x - 70) * (x - 70) + (y - 60) * (y - 60) <= 30 * 30 }
        func bar(_ x: Double, _ y: Double) -> Bool { x >= 130 && x <= 230 && y >= 40 && y <= 58 }
        func tinted(_ x: Double, _ y: Double) -> Bool { x >= 24 && x <= 84 && y >= 110 && y <= 140 }
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(260, 160) { x, y in
            disc(x, y) ? self.dark : bar(x, y) ? self.white : tinted(x, y) ? own : sky(x, y)
        }))
        XCTAssertEqual(traced.shapes.count, 4)
        XCTAssertEqual(traced.shapes.filter { $0.blend != nil }.count, 1)
        let ground = try XCTUnwrap(traced.shapes.first)
        XCTAssertEqual(ground.blend?.kind, .linear)
        let open = grid(stride(from: 8, through: 252, by: 12), stride(from: 8, through: 152, by: 12)) { x, y in
            !disc(x, y) && !bar(x, y) && !tinted(x, y)
        }
        XCTAssertLessThanOrEqual(off(ground, from: sky, at: open), 5)
        let flat = traced.shapes.dropFirst()
        XCTAssertTrue(flat.contains { $0.color.r < 60 && $0.figure != nil }, "the disc")
        XCTAssertTrue(flat.contains { $0.color.r > 240 }, "the white bar")
        let bars = flat.filter { abs(Double($0.color.r) - own.0) <= 6 && abs(Double($0.color.b) - own.2) <= 6 }
        XCTAssertEqual(bars.count, 1, "the bar of the sky's colour")
        XCTAssertEqual(bars.first?.area ?? 0, 60 * 30, accuracy: 40)
    }

    func testShapesOfNearlyOneColourAreNoRun() throws {
        // Stripes a step apart, each one colour: six shapes, whether their edges are sharp
        // or out of focus.
        func stripes(soft: Double) -> Bitmap {
            drawn(240, 120) { x, _ in
                let at = x / 40, k = min(max((at + 0.5).rounded(.down), 1), 5)
                let u = soft > 0 ? min(max((x - k * 40) / soft + 0.5, 0), 1) : (x >= k * 40 ? 1 : 0)
                let step = k - 1 + u
                return (40 + 22 * step, 80 + 22 * step, 150 + 14 * step)
            }
        }
        for soft in [0.0, 3, 4.5] {
            let traced = try XCTUnwrap(Vectorizer.trace(stripes(soft: soft)))
            XCTAssertEqual(traced.shapes.count, 6, "edges \(soft) pixels wide")
            XCTAssertTrue(traced.shapes.allSatisfy { $0.blend == nil }, "edges \(soft) pixels wide")
        }
    }

    func testTwoColoursWithASoftEdgeBetweenThemAreNoRun() throws {
        // Two fields of nearly one colour and a soft edge between them, ten pixels wide: the
        // change is all in one place, so it is two shapes.
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(240, 120) { x, _ in
            self.mixed((52, 96, 150), (84, 130, 176), (x - 115) / 10)
        }))
        XCTAssertTrue(traced.shapes.allSatisfy { $0.blend == nil })
        XCTAssertEqual(traced.shapes.count, 2)
    }

    func testARunOfColoursInAShakenPicture() throws {
        let sky = straight((40, 70, 150), (230, 170, 110), from: Spot(0, 150), to: Spot(40, 0))
        func disc(_ x: Double, _ y: Double) -> Bool { (x - 120) * (x - 120) + (y - 75) * (y - 75) <= 34 * 34 }
        let traced = try XCTUnwrap(Vectorizer.trace(shaken(drawn(240, 150) { x, y in disc(x, y) ? self.white : sky(x, y) }, by: 4)))
        XCTAssertEqual(traced.shapes.count, 2)
        XCTAssertEqual(traced.shapes.first?.blend?.kind, .linear)
        XCTAssertNil(traced.shapes.last?.blend)
        let open = grid(stride(from: 8, through: 232, by: 14), stride(from: 8, through: 142, by: 11)) { x, y in
            (x - 120) * (x - 120) + (y - 75) * (y - 75) > 40 * 40
        }
        XCTAssertLessThanOrEqual(off(traced.shapes[0], from: sky, at: open), 6)
    }

    #if canImport(ImageIO)
    func testRunsOfColoursInAJPEG() throws {
        // What a JPEG does to them: blocks of eight pixels with each its own slight tint,
        // and ripples beside the shapes on top.
        let sky = straight((36, 58, 120), (150, 96, 160), from: Spot(0, 0), to: Spot(280, 180))
        let middle = Spot(78, 70)
        let lit = round((255, 232, 160), (176, 64, 20), middle: middle, reach: 80)
        func ball(_ x: Double, _ y: Double) -> Bool { (x - 92) * (x - 92) + (y - 86) * (y - 86) <= 56 * 56 }
        func bar(_ x: Double, _ y: Double) -> Bool { x >= 170 && x <= 260 && y >= 60 && y <= 80 }
        let bitmap = drawn(280, 180) { x, y in ball(x, y) ? lit(x, y) : bar(x, y) ? self.white : sky(x, y) }
        let traced = try XCTUnwrap(Vectorizer.trace(try XCTUnwrap(kept(bitmap, quality: 0.7))))
        XCTAssertEqual(traced.shapes.count, 3)
        XCTAssertEqual(traced.shapes[0].blend?.kind, .linear)
        let round = try XCTUnwrap(traced.shapes.first { $0.blend?.kind == .radial })
        XCTAssertEqual(round.blend?.start.x ?? 0, middle.x, accuracy: 4)
        XCTAssertEqual(round.blend?.start.y ?? 0, middle.y, accuracy: 4)
        XCTAssertEqual(traced.shapes.filter { $0.blend == nil }.count, 1)
        let open = grid(stride(from: 8, through: 272, by: 12), stride(from: 8, through: 172, by: 12)) { x, y in
            (x - 92) * (x - 92) + (y - 86) * (y - 86) > 62 * 62 && !(x >= 164 && x <= 266 && y >= 54 && y <= 86)
        }
        XCTAssertLessThanOrEqual(off(traced.shapes[0], from: sky, at: open), 8)
        let inside = grid(stride(from: 40, through: 144, by: 9), stride(from: 34, through: 138, by: 9)) { x, y in
            (x - 92) * (x - 92) + (y - 86) * (y - 86) <= 50 * 50
        }
        XCTAssertLessThanOrEqual(off(round, from: lit, at: inside), 9)
        // And the ball's edge is the circle drawn, to a sixth of a pixel on the whole (read
        // by the palette's colours alone: a quarter, and nine tenths at the worst). A JPEG's
        // colour lags its light across an edge, so the edge is placed by the light.
        var worst = 0.0, sum = 0.0, count = 0.0
        for outline in round.outlines {
            for corner in corners(outline) {
                let far = abs(((corner.x - 92) * (corner.x - 92) + (corner.y - 86) * (corner.y - 86)).squareRoot() - 56)
                worst = max(worst, far)
                sum += far
                count += 1
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.7)
        XCTAssertLessThanOrEqual(sum / max(count, 1), 0.17)
    }
    #endif
}
