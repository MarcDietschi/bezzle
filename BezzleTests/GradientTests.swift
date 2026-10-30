import Testing
import CoreGraphics
@testable import Bezzle

struct GradientTests {
    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.0001 && abs(a.y - b.y) < 0.0001 }

    @Test func anglesRunAsCSSCountsThem() {
        var g = Gradient.fading(from: RGBA(hex: "3559C7")!)
        g.aim(180, in: CGSize(width: 200, height: 100))
        #expect(near(g.start, CGPoint(x: 0.5, y: 0)) && near(g.end, CGPoint(x: 0.5, y: 1)))
        g.aim(90, in: CGSize(width: 200, height: 100))
        #expect(near(g.start, CGPoint(x: 0, y: 0.5)) && near(g.end, CGPoint(x: 1, y: 0.5)))
        // Corner to corner on a square: bottom left to top right.
        g.aim(45, in: CGSize(width: 100, height: 100))
        #expect(near(g.start, CGPoint(x: 0, y: 1)) && near(g.end, CGPoint(x: 1, y: 0)))
    }

    @Test func theAngleShownIsTheOneSetOnAnyShape() {
        var g = Gradient.fading(from: .white)
        for size in [CGSize(width: 345, height: 180), CGSize(width: 40, height: 300)] {
            for degrees in [0.0, 30, 135, 200, 315] {
                g.aim(degrees, in: size)
                #expect(abs(g.angle(in: size) - degrees) < 0.001)
            }
        }
    }

    @Test func coloursBetweenStopsAreMixed() {
        let g = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: RGBA(r: 0, g: 0, b: 0)), GradientStop(offset: 1, color: RGBA(r: 1, g: 1, b: 1))],
                         start: .zero, end: CGPoint(x: 1, y: 0))
        #expect(abs(g.color(at: 0.25).r - 0.25) < 0.0001)
        #expect(g.color(at: -1).r == 0 && g.color(at: 2).r == 1)
    }

    @Test func aStopDraggedPastAnotherKeepsBeingTheOneMoved() {
        let stops = [GradientStop(offset: 0, color: .white), GradientStop(offset: 0.5, color: RGBA(r: 1, g: 0, b: 0)),
                     GradientStop(offset: 1, color: RGBA(r: 0, g: 0, b: 0))]
        let (moved, at) = stops.placing(0, at: 0.8)
        #expect(moved.map(\.offset) == [0.5, 0.8, 1])
        #expect(at == 1 && moved[at].color == .white)
        #expect(stops.placing(2, at: 5).stops.last?.offset == 1)
    }

    @Test func aRadialGradientSpreadsAcrossTheLayerUntilItIsShaped() {
        let g = Gradient(kind: .radial, stops: [], start: CGPoint(x: 0.4, y: 0.5), end: .zero, radius: 0.5)
        let (a, b) = g.radii
        #expect(near(a, CGPoint(x: 0.9, y: 0.5)) && near(b, CGPoint(x: 0.4, y: 1)))
        // The unit circle lands on the ellipse the old drawing made: radii of half the width and height.
        let spread = g.spread(in: CGSize(width: 200, height: 100))
        #expect(near(CGPoint(x: 1, y: 0).applying(spread), CGPoint(x: 180, y: 50)))
        #expect(near(CGPoint(x: 0, y: 1).applying(spread), CGPoint(x: 80, y: 100)))
    }

    @Test func turningARadialGradientKeepsItsSecondRadiusSquareAndAsLong() {
        let size = CGSize(width: 200, height: 100)
        var g = Gradient(kind: .radial, stops: [], start: CGPoint(x: 0.5, y: 0.5), end: .zero, radius: 0.5)
        // Its first radius, 100 wide, turned to point up and shortened to 50.
        g.turn(to: CGPoint(x: 0.5, y: 0), in: size)
        #expect(near(g.end, CGPoint(x: 0.5, y: 0)))
        // The second, 50 long and pointing down, turns with it to point right.
        #expect(g.across.map { near($0, CGPoint(x: 0.75, y: 0.5)) } == true)
        g.stretch(to: CGPoint(x: 0.9, y: 0.3), in: size)
        #expect(g.across.map { near($0, CGPoint(x: 0.9, y: 0.5)) } == true)
        #expect(near(g.end, CGPoint(x: 0.5, y: 0)))
        g.centre(at: CGPoint(x: 0.4, y: 0.6))
        #expect(near(g.end, CGPoint(x: 0.4, y: 0.1)) && g.across.map { near($0, CGPoint(x: 0.8, y: 0.6)) } == true)
    }

    @Test func fillsKnowTheirKind() {
        var fill = Fill(color: .white)
        #expect(FillKind(fill) == .solid)
        fill.gradient = .fading(from: .white)
        #expect(FillKind(fill) == .linear)
        fill.gradient?.kind = .radial
        #expect(FillKind(fill) == .radial)
        #expect(FillKind.choices(with: .radial).count == 3 && FillKind.choices(with: .picture).count == 4)
    }
}
