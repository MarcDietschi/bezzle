import XCTest
@testable import Vectorizer

/// Thin lines: what colour they are found to be, and how evenly thick they come out.
final class ThinTests: XCTestCase {
    private let paper: Paint = (246, 241, 231), dark: Paint = (30, 42, 58), red: Paint = (200, 52, 31), blue: Paint = (12, 84, 148)

    private func near(_ tint: Tint, _ paint: Paint, within: Double) -> Bool {
        abs(Double(tint.r) - paint.0) <= within && abs(Double(tint.g) - paint.1) <= within && abs(Double(tint.b) - paint.2) <= within
    }

    /// Hand drawn lines of one colour, from thin to thinner, on paper.
    private func lines(_ thicks: [Double], _ ink: Paint, wide: Int = 300) -> (Bitmap, [Sway]) {
        let sways = thicks.indices.map { Sway(y: 22 + 30 * Double($0), slope: 0.04 + 0.02 * Double($0), sway: 3, seed: 0.4 + 1.5 * Double($0)) }
        let bitmap = drawn(wide, 20 + 30 * thicks.count + 20) { x, y in
            for (k, sway) in sways.enumerated() where sway.holds(x, y, thick: thicks[k], from: 16, to: Double(wide) - 16) { return ink }
            return self.paper
        }
        return (bitmap, sways)
    }

    /// The line's shape in a tracing, and how thick it is along the line.
    private func measured(_ traced: Tracing, _ sways: [Sway], ink: Paint, wide: Int = 300) -> [(mean: Double, wavers: Double, missing: Int)] {
        let inked = traced.shapes.filter { near($0.color, ink, within: 40) }
        return sways.map { sway in
            // The shape that holds the line's middle.
            var best: [Double?] = []
            for shape in inked {
                let all = thicknesses(of: shape, along: sway, from: 24, to: Double(wide) - 24)
                if all.compactMap({ $0 }).count > best.compactMap({ $0 }).count { best = all }
            }
            let found = best.compactMap { $0 }
            let s = spread(found)
            return (s.mean, s.wavers, best.count - found.count)
        }
    }

    func testAThinLineKeepsItsOwnColourBesideADarkOne() throws {
        // Thin blue lines on white with something dark in the picture: the blue that is
        // furthest from both white and dark is a paler one than the lines', which only shows
        // where a line lies between two pixels. The lines are their own blue, once.
        let white: Paint = (255, 255, 255)
        let sways = (0..<4).map { Sway(y: 70 + 12 * Double($0), slope: 0.07 * Double($0 + 1), sway: 2, seed: Double($0)) }
        let traced = try XCTUnwrap(Vectorizer.trace(drawn(220, 150) { x, y in
            if x >= 12, x <= 80, y >= 10, y <= 50 { return self.dark }
            for sway in sways where sway.holds(x, y, thick: 1, from: 14, to: 206) { return self.blue }
            return white
        }))
        XCTAssertEqual(traced.palette.count, 3, "\(traced.palette)")
        let blues = traced.palette.filter { $0.b > $0.r &+ 40 && $0.r < 200 }
        XCTAssertEqual(blues.count, 1, "\(traced.palette)")
        XCTAssertTrue(blues.allSatisfy { near($0, blue, within: 10) }, "\(blues)")
    }

    func testThinLinesInAShakenPictureAreEvenlyThick() throws {
        let thicks = [1.5, 2, 3]
        let (bitmap, sways) = lines(thicks, dark)
        let traced = try XCTUnwrap(Vectorizer.trace(shaken(bitmap, by: 6)))
        XCTAssertEqual(traced.shapes.count, 1 + thicks.count)
        for (k, line) in measured(traced, sways, ink: dark).enumerated() {
            XCTAssertEqual(line.missing, 0, "the line \(thicks[k]) thick")
            XCTAssertEqual(line.mean, thicks[k], accuracy: 0.15, "the line \(thicks[k]) thick")
            XCTAssertLessThanOrEqual(line.wavers, 0.09, "the line \(thicks[k]) thick")
        }
    }

    #if canImport(ImageIO)
    func testThinColouredLinesInAJPEGAreOneShapeEachAndEvenlyThick() throws {
        // A JPEG keeps its colour coarser than its light: a thin red line's pixels come back
        // every shade between red, pink and brown. Each line is still one shape of one red.
        let thicks = [1.0, 1.5, 2]
        let (bitmap, sways) = lines(thicks, red)
        let traced = try XCTUnwrap(Vectorizer.trace(try XCTUnwrap(kept(bitmap, quality: 0.6))))
        XCTAssertEqual(traced.shapes.count, 1 + thicks.count)
        XCTAssertEqual(traced.palette.count, 2, "\(traced.palette)")
        for (k, line) in measured(traced, sways, ink: red).enumerated() {
            XCTAssertEqual(line.missing, 0, "the line \(thicks[k]) thick")
            XCTAssertEqual(line.mean, thicks[k], accuracy: 0.25, "the line \(thicks[k]) thick")
            XCTAssertLessThanOrEqual(line.wavers, 0.09, "the line \(thicks[k]) thick")
        }
    }
    #endif
}
