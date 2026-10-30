import Testing
import CoreGraphics
@testable import Bezzle

struct GeometryTests {
    @Test func resizeFromCornerKeepsOppositeCorner() {
        let frame = CGRect(x: 10, y: 10, width: 100, height: 50)
        let r = Geometry.resize(frame, rotation: 0, handle: .bottomRight, to: CGPoint(x: 160, y: 90), keepAspect: false, fromCenter: false)
        #expect(r == CGRect(x: 10, y: 10, width: 150, height: 80))
    }
}
