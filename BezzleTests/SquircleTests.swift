import Testing
import CoreGraphics
@testable import Bezzle

struct SquircleTests {
    private let square = CGRect(x: 0, y: 0, width: 200, height: 200)

    /// Points over the shape, set off from any round number so none falls right on an edge.
    private var grid: [CGPoint] {
        stride(from: 0.37, to: 200, by: 1.91).flatMap { x in stride(from: 0.29, to: 200, by: 1.73).map { CGPoint(x: x, y: $0) } }
    }

    @Test func withoutSmoothingItIsAPlainRoundedRectangle() {
        let smooth = Squircle.path(in: square, corners: [40, 40, 40, 40], smoothing: 0)
        let plain = CGPath(roundedRect: square, cornerWidth: 40, cornerHeight: 40, transform: nil)
        #expect(grid.filter { smooth.contains($0) != plain.contains($0) }.isEmpty)
    }

    @Test func aSquircleKeepsToItsBoxAndItsCornersAreAlike() {
        let p = Squircle.path(in: square, corners: [40, 40, 40, 40], smoothing: 0.6)
        let box = p.boundingBoxOfPath
        #expect(abs(box.minX) < 0.01 && abs(box.minY) < 0.01 && abs(box.maxX - 200) < 0.01 && abs(box.maxY - 200) < 0.01)
        // The same at every corner, and even either side of each corner's diagonal.
        let uneven = grid.filter { q in
            let inside = p.contains(q)
            return inside != p.contains(CGPoint(x: q.y, y: q.x)) || inside != p.contains(CGPoint(x: 200 - q.x, y: q.y))
                || inside != p.contains(CGPoint(x: q.x, y: 200 - q.y))
        }
        #expect(uneven.isEmpty)
    }

    @Test func itBendsFromFurtherAlongTheSidesAroundTheSameArc() {
        let p = Squircle.path(in: square, corners: [40, 40, 40, 40], smoothing: 0.6)
        // At 60%, a corner of 40 reaches 64 along each side, where a plain one reaches 40.
        var first: CGPoint?
        p.applyWithBlock { e in if first == nil { first = e.pointee.points[0] } }
        #expect(first.map { abs($0.x - 136) < 0.001 && abs($0.y) < 0.001 } == true)
        // Its middle is the plain corner's arc: as far in from the corner.
        let centre = CGPoint(x: 160, y: 40), out = CGVector(dx: cos(CGFloat.pi / 4), dy: -sin(CGFloat.pi / 4))
        #expect(p.contains(CGPoint(x: centre.x + out.dx * 39.5, y: centre.y + out.dy * 39.5)))
        #expect(!p.contains(CGPoint(x: centre.x + out.dx * 40.5, y: centre.y + out.dy * 40.5)))
    }

    @Test func aPillStaysWithinItsSides() {
        let pill = CGRect(x: 0, y: 0, width: 300, height: 80)
        let p = Squircle.path(in: pill, corners: [40, 40, 40, 40], smoothing: 1)
        let box = p.boundingBoxOfPath
        #expect(abs(box.minY) < 0.01 && abs(box.maxY - 80) < 0.01 && abs(box.minX) < 0.01 && abs(box.maxX - 300) < 0.01)
        #expect(p.contains(CGPoint(x: 150, y: 40)) && p.contains(CGPoint(x: 20, y: 40)))
    }
}
