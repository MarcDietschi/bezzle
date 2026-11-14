import XCTest
@testable import Vectorizer

/// Pictures with a grain: as many shapes as were drawn, not one for every blotch.
final class TextureTests: XCTestCase {
    private let orange: Paint = (236, 140, 52), teal: Paint = (34, 120, 132), cream: Paint = (244, 236, 214), dark: Paint = (28, 30, 44)

    private func isDark(_ shape: Shape) -> Bool {
        Int(shape.color.r) + Int(shape.color.g) + Int(shape.color.b) < 240
    }

    /// Three fields side by side. Along the first edge lies a line that comes and goes, a pixel
    /// thick at most and in pieces some ten pixels long; along the second a whole one. A dot
    /// lies in the last field.
    private func fields() -> Bitmap {
        drawn(240, 160) { x, y in
            let first = 80 + 8 * sin(y / 23), second = 160 + 6 * sin(y / 31 + 1)
            let thick = 1.1 * sin(y / 4.5)
            if thick > 0, abs(x - first) <= thick / 2 { return self.dark }
            if abs(x - second) <= 0.75 { return self.dark }
            if (x - 205) * (x - 205) + (y - 80) * (y - 80) <= 6.25 { return self.dark }
            return x < first ? self.orange : x < second ? self.teal : self.cream
        }
    }

    func testPiecesOfALineAlongAnEdgeGoAndAWholeLineStays() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(shaken(fields(), by: 6)))
        // The fields, the whole line and the dot: none of the first edge's pieces.
        let inked = traced.shapes.filter(isDark)
        XCTAssertEqual(inked.count, 2, "\(inked.map(\.area))")
        XCTAssertEqual(traced.shapes.count, 5, "\(traced.shapes.map(\.area))")
        // The line: a pixel and a half thick, from top to bottom.
        let line = try XCTUnwrap(inked.max { $0.area < $1.area })
        XCTAssertEqual(line.area, 1.5 * 161, accuracy: 30)
        // The dot: five pixels across.
        let dot = try XCTUnwrap(inked.min { $0.area < $1.area })
        XCTAssertEqual(dot.area, 19.6, accuracy: 4)
    }

    func testThePiecesStayInAPictureKeptWhole() throws {
        // Nothing wore this picture: what is in it was drawn, pieces of a line too.
        let traced = try XCTUnwrap(Vectorizer.trace(fields()))
        XCTAssertEqual(traced.shapes.filter(isDark).count, 8)
    }

    func testAGrainMakesNoShapesOfItsOwn() throws {
        // A disc and a bar on a ground, every pixel up to 16 levels off: three shapes.
        let traced = try XCTUnwrap(Vectorizer.trace(shaken(drawn(200, 140) { x, y in
            if (x - 70) * (x - 70) + (y - 70) * (y - 70) <= 1600 { return self.teal }
            if x >= 130, x <= 180, y >= 40, y <= 100 { return self.orange }
            return self.cream
        }, by: 16)))
        XCTAssertEqual(traced.shapes.count, 3, "\(traced.shapes.map(\.area))")
        let disc = try XCTUnwrap(traced.shapes.first { $0.color.r < 100 })
        XCTAssertEqual(disc.area, 1600 * Double.pi, accuracy: 60)
    }
}
