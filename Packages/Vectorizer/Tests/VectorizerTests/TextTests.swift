import XCTest
@testable import Vectorizer
#if canImport(CoreText)
import CoreGraphics
import CoreText
#endif

/// Small text: its smallest pieces, a pixel of ink or less each, stay.
final class TextTests: XCTestCase {
    private let paper: Paint = (255, 255, 255), ink: Paint = (20, 33, 61)

    private func dark(_ traced: Tracing) -> [Shape] {
        traced.shapes.filter { Int($0.color.r) + Int($0.color.g) + Int($0.color.b) < 300 }
    }

    /// Dots as large as the dot of an i at 10 points, each lying its own way on the pixels, and
    /// rings with an eye as small: `size` times as large.
    private func marks(size: Double) -> Bitmap {
        drawn(Int(150 * size), Int(40 * size)) { x, y in
            let x = x / size, y = y / size
            // Twelve dots, 1.2 pixels across.
            if y < 20 {
                let k = ((x - 6) / 12).rounded()
                guard k >= 0, k < 12 else { return self.paper }
                let cx = 6 + 12 * k + 0.09 * k, cy = 10 + 0.13 * k
                return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= 0.36 ? self.ink : self.paper
            }
            // Six rings, 6 pixels across, their eyes 1.4.
            let k = ((x - 12) / 24).rounded()
            guard k >= 0, k < 6 else { return self.paper }
            let cx = 12 + 24 * k + 0.17 * k, cy = 30 + 0.11 * k
            let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
            return d <= 9 && d >= 0.49 ? self.ink : self.paper
        }
    }

    func testDotsOfAPixelAndEyesAsSmallStay() throws {
        for size in [1.0, 2] {
            let traced = try XCTUnwrap(Vectorizer.trace(marks(size: size)))
            let found = dark(traced)
            XCTAssertEqual(found.count, 18, "\(size) times")
            let dots = found.filter { $0.area < 5 * size * size }, rings = found.filter { $0.area > 12 * size * size }
            XCTAssertEqual(dots.count, 12, "\(size) times")
            XCTAssertEqual(rings.count, 6, "\(size) times")
            // A dot drawn 1.13 pixels large is no speck and no blot. (One that lies on the
            // corner of four pixels still comes out some three times too large.)
            for dot in dots {
                XCTAssertGreaterThan(dot.area, 0.6 * size * size, "\(size) times")
                XCTAssertLessThan(dot.area, 4 * size * size, "\(size) times")
            }
            // The eyes are thinner than the rings, so they lie on them: six small shapes of paper.
            let eyes = traced.shapes.filter { $0.color.r > 200 && $0.area < 5 * size * size }
            XCTAssertEqual(eyes.count, 6, "\(size) times")
            XCTAssertEqual(traced.shapes.count, 25, "\(size) times")
        }
    }

    func testWithLittleDetailWantedTheyGo() throws {
        let traced = try XCTUnwrap(Vectorizer.trace(marks(size: 1), settings: Settings(detail: 0)))
        XCTAssertEqual(traced.shapes.count, 7)
    }

    #if canImport(CoreText)
    /// A line of text in Helvetica at 10 points, `size` pixels to the point.
    private func written(_ text: String, size: Int) -> Bitmap? {
        let w = 160 * size, h = 24 * size
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let done: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: CGFloat(size), y: CGFloat(size))
            let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            let color = CGColor(srgbRed: 20 / 255, green: 33 / 255, blue: 61 / 255, alpha: 1)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
            guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return false }
            ctx.textPosition = CGPoint(x: 6.3, y: 8.4)
            CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
            return true
        }
        for i in 0..<(w * h) { pixels[i * 4 + 3] = 255 }
        return done ? Bitmap(width: w, height: h, pixels: pixels) : nil
    }

    func testThePointsAndCommasOf10PointTextStay() throws {
        // A point, a comma, a colon and a semicolon, twice: twelve pieces of ink.
        for size in [1, 2] {
            let traced = try XCTUnwrap(Vectorizer.trace(try XCTUnwrap(written(". , : ; . , : ;", size: size))))
            XCTAssertEqual(dark(traced).count, 12, "\(size) times")
        }
    }

    func testTheEyesOf10PointLettersStayAtTwiceTheSize() throws {
        // b d o p q: one eye each.
        let traced = try XCTUnwrap(Vectorizer.trace(try XCTUnwrap(written("b d o p q", size: 2))))
        let letters = dark(traced)
        XCTAssertEqual(letters.count, 5)
        XCTAssertTrue(letters.allSatisfy { $0.outlines.count == 2 }, "\(letters.map(\.outlines.count))")
    }
    #endif
}
