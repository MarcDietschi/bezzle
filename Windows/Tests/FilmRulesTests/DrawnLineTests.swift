import Foundation
import Testing
@testable import FilmRules

/// The Draw move's line in its chip (Host/DrawnLine.swift): the Mac's two curves over the home
/// box, cut at a part of their length as SwiftUI's trimmedPath cuts them.
struct DrawnLineTests {
    /// The chip's home box: 18 by 13 in the middle of 36 by 24.
    let curves = DrawnLine.moveLine(x: 9, y: 5.5, w: 18, h: 13)

    private func length(_ line: [CGPoint]) -> Double {
        guard line.count >= 2 else { return 0 }
        return (1..<line.count).reduce(0) { $0 + hypot(Double(line[$1].x - line[$1 - 1].x), Double(line[$1].y - line[$1 - 1].y)) }
    }

    private func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.x == $1.x && $0.y == $1.y }
    }

    private func near(_ a: CGPoint?, _ x: Double, _ y: Double, _ e: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(Double(a.x) - x) < e && abs(Double(a.y) - y) < e
    }

    @Test func theLineRunsFromLeftOfTheBoxOverItsMiddleToPastItsRight() {
        #expect(curves.count == 2)
        let whole = DrawnLine.trimmed(curves, to: 1)
        // From just left of the box and below its middle, through its middle, out past its right.
        #expect(near(whole.first, 9 - 3, 12 + 3))
        #expect(near(whole.last, 27 + 3, 12 - 3))
        #expect(whole.contains { near($0, 18, 12) })
        #expect(whole.count == 1 + 2 * 24)
    }

    @Test func nothingDrawnIsNoLineAndAllOfItIsTheWholeLine() {
        #expect(DrawnLine.trimmed(curves, to: 0).isEmpty)
        #expect(DrawnLine.trimmed(curves, to: 0.0005).isEmpty)
        #expect(DrawnLine.trimmed(curves, to: -1).isEmpty)
        let whole = DrawnLine.trimmed(curves, to: 1)
        #expect(same(DrawnLine.trimmed(curves, to: 1.4), whole))
        #expect(DrawnLine.trimmed([], to: 0.5).isEmpty)
    }

    @Test func partOfItIsThatPartOfItsLengthFromItsStart() {
        let whole = DrawnLine.trimmed(curves, to: 1)
        let all = length(whole)
        var last = 0.0
        for k in 1...9 {
            let part = DrawnLine.trimmed(curves, to: Double(k) / 10)
            #expect(abs(length(part) - all * Double(k) / 10) < 1e-6, "\(k)")
            // The same line as far as it goes: every point but its end is the whole line's.
            #expect(same(Array(part.dropLast()), Array(whole.prefix(part.count - 1))))
            #expect(length(part) > last)
            last = length(part)
        }
    }

    @Test func aStraightCurveIsCutWhereItsLengthSays() {
        let straight = [DrawnLine.Curve(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0))]
        let part = DrawnLine.trimmed(straight, to: 0.3)
        #expect(near(part.first, 0, 0))
        #expect(near(part.last, 9, 0, 1e-6))
    }
}
