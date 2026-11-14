import Testing
import AppKit
@testable import Bezzle

/// One outline into another that has other points (`BezierPath.matched`, `mixed`): both are given
/// the same points without either changing its shape, with the points going least far.
struct MotionMatchingTests {
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

    /// Whether everything `a` draws lies on what `b` draws.
    private func lies(_ a: BezierPath, on b: BezierPath, within e: CGFloat = 0.05) -> Bool {
        for s in a.subpaths.indices {
            for i in 0..<a.subpaths[s].segmentCount {
                let c = a.segment(s, i)
                for k in 0...8 {
                    let p = BezierPath.point(on: c, at: CGFloat(k) / 8)
                    guard let spot = b.nearest(to: p), spot.distance < e else { return false }
                }
            }
        }
        return true
    }

    /// Whether two outlines draw the same shape, whatever points each has.
    private func sameShape(_ a: BezierPath, _ b: BezierPath, within e: CGFloat = 0.05) -> Bool {
        lies(a, on: b, within: e) && lies(b, on: a, within: e)
    }

    /// How far each anchor of the one is from the same anchor of the other.
    private func travel(_ a: BezierPath, _ b: BezierPath) -> [CGFloat] {
        zip(a.anchorPoints, b.anchorPoints).map { hypot($0.x - $1.x, $0.y - $1.y) }
    }

    private var square: BezierPath { BezierPath(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)) }
    private var circle: BezierPath { BezierPath(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)) }

    // MARK: The same points

    @Test func outlinesWithTheSamePointsAreLeftAsTheyAre() {
        let a = BezierPath("M 0 0 L 100 0 L 50 80 Z"), b = BezierPath("M 10 0 L 90 20 C 80 60 60 90 40 100 Z")
        #expect(a.hasRuns(of: b))
        let (x, y) = BezierPath.matched(a, b)
        #expect(x == a && y == b)
        // Closed and open are not the same runs, though they have as many anchors.
        #expect(!a.hasRuns(of: BezierPath("M 0 0 L 100 0 L 50 80")))
        #expect(!a.hasRuns(of: BezierPath("M 0 0 L 100 0 L 50 80 L 20 20 Z")))
    }

    @Test func oneGoesIntoTheOtherExactlyAtEitherEnd() {
        let a = BezierPath("M 0 0 L 100 0 L 50 80 Z"), b = BezierPath("M 10 0 L 90 20 C 80 60 60 90 40 100 Z")
        #expect(a.mixed(with: b, 0) == a)
        #expect(a.mixed(with: b, 1) == b)
        let half = a.mixed(with: b, 0.5)
        #expect(near(half.subpaths[0].anchors[1].point, CGPoint(x: 95, y: 10)))
        // A handle one has and the other has not comes out of the point.
        #expect(near(half.subpaths[0].anchors[1].handleOut ?? .zero, CGPoint(x: 90, y: 30)))
        // Past the end, as a spring goes: on as it went.
        #expect(near(a.mixed(with: b, 1.5).subpaths[0].anchors[0].point, CGPoint(x: 15, y: 0)))
    }

    @Test func handlesInOneLineStayInOneLineOnTheWay() {
        // A smooth point whose handles lie across in the one and upright in the other, of other lengths.
        var a = BezierPath("M 0 0 L 100 0 L 100 100 Z"), b = a
        a.subpaths[0].anchors[1] = BezierPath.Anchor(CGPoint(x: 100, y: 0), in: CGPoint(x: 90, y: 0), out: CGPoint(x: 130, y: 0))
        b.subpaths[0].anchors[1] = BezierPath.Anchor(CGPoint(x: 100, y: 0), in: CGPoint(x: 100, y: -30), out: CGPoint(x: 100, y: 10))
        let at = PathPoint(subpath: 0, index: 1)
        #expect(a.isSmooth(at) && b.isSmooth(at))
        for p in [0.1, 0.25, 0.5, 0.75, 0.9] {
            #expect(a.mixed(with: b, p).isSmooth(at), "at \(p)")
        }
        #expect(a.mixed(with: b, 0) == a && a.mixed(with: b, 1) == b)
        // Close to a key, close to what was keyed.
        let soon = a.mixed(with: b, 0.001).subpaths[0].anchors[1]
        #expect(near(soon.handleIn ?? .zero, CGPoint(x: 90, y: 0), 0.1) && near(soon.handleOut ?? .zero, CGPoint(x: 130, y: 0), 0.1))
    }

    // MARK: Other points

    @Test func aSquareGoesIntoACircleEachCornerTheNearestWay() {
        // As many anchors, numbered as each shape has them: point by point, which turns it on the way.
        #expect(BezierPath.matched(square, circle).1 == circle)
        // Taken for the square to go into, the circle has a point where each corner goes.
        let taken = circle.laid(along: square)
        #expect(taken.anchorCount == 8 && sameShape(taken, circle))
        let (x, y) = BezierPath.matched(square, taken)
        #expect(x.hasRuns(of: y))
        #expect(x.anchorCount == 8 && y == taken)
        #expect(sameShape(x, square))
        // The square still begins at its own first corner.
        #expect(near(x.subpaths[0].anchors[0].point, .zero))
        // Every point goes straight out from the middle or in to it: none goes round.
        let middle = CGPoint(x: 50, y: 50)
        for (p, q) in zip(x.anchorPoints, y.anchorPoints) {
            let a = atan2(p.y - middle.y, p.x - middle.x), b = atan2(q.y - middle.y, q.x - middle.x)
            let turn = abs(atan2(sin(a - b), cos(a - b))) * 180 / .pi
            #expect(turn < 2, "\(p) goes to \(q)")
        }
        // Halfway it is neither, and still one closed outline of the same points.
        let half = x.mixed(with: y, 0.5)
        #expect(half.hasRuns(of: x) && half.subpaths[0].closed)
        #expect(!sameShape(half, square, within: 1) && !sameShape(half, circle, within: 1))
    }

    @Test func aPointAddedComesOutOfItsSide() throws {
        let a = BezierPath("M 100 60 L 200 60 L 150 140 Z")
        var b = a
        let added = b.insert(0, segment: 0, t: 0.5)
        b[added].point = CGPoint(x: 150, y: 20)
        let (x, y) = BezierPath.matched(a, b)
        #expect(y == b)
        #expect(x.anchorCount == 4 && sameShape(x, a))
        // Its three corners stay; the new point is on the side it was put on, and goes up from there.
        #expect(x.anchorPoints.map { [$0.x, $0.y] } == [[100, 60], [150, 60], [200, 60], [150, 140]])
        #expect(travel(x, y) == [0, 40, 0, 0])
    }

    @Test func aPointTakenAwayGoesOntoTheSideThatIsLeft() {
        let a = BezierPath("M 0 0 L 50 -40 L 100 0 L 100 100 L 0 100 Z")
        var b = a
        b.remove([PathPoint(subpath: 0, index: 1)])
        let (x, y) = BezierPath.matched(a, b)
        #expect(x == a)
        #expect(y.anchorCount == 5 && sameShape(y, b))
        #expect(near(y.subpaths[0].anchors[1].point, CGPoint(x: 50, y: 0)))
        #expect(travel(x, y) == [0, 40, 0, 0, 0])
    }

    @Test func pointsMovedBetweenOnesThatStayedAreTakenInTheirOrder() {
        // Two of five moved, and one more put between them: the moved ones are still themselves.
        let a = BezierPath("M 0 0 L 100 0 L 140 60 L 100 120 L 0 120 Z")
        let b = BezierPath("M 0 0 L 100 0 L 170 20 L 190 60 L 170 100 L 100 120 L 0 120 Z")
        let (x, y) = BezierPath.matched(a, b)
        #expect(x.hasRuns(of: y) && x.anchorCount == 7)
        #expect(sameShape(x, a) && sameShape(y, b))
        #expect(travel(x, y)[0] == 0 && travel(x, y)[1] == 0 && travel(x, y)[5] == 0 && travel(x, y)[6] == 0)
    }

    @Test func anOutlineBegunElsewhereAndRunTheOtherWayGoesNowhere() {
        let a = BezierPath("M 0 0 C 40 -30 80 -30 120 0 L 140 80 C 100 120 40 120 0 80 Z")
        // The same shape, with one point more, begun at another anchor and drawn the other way.
        var b = a
        b.insert(0, segment: 1, t: 0.4)
        let n = b.subpaths[0].anchors.count
        b.subpaths[0].anchors = (0..<n).map { b.subpaths[0].anchors[(2 + $0) % n] }
        b.reverse(0)
        let (x, y) = BezierPath.matched(a, b)
        #expect(x.hasRuns(of: y) && x.anchorCount == 5)
        #expect(sameShape(x, a) && sameShape(y, b))
        #expect(travel(x, y).allSatisfy { $0 < 0.01 }, "\(travel(x, y))")
        #expect(sameShape(x.mixed(with: y, 0.5), a))
    }

    @Test func outlinesThatShareNoPointAreLaidAlongEachOtherWhole() {
        // One circle with its points elsewhere on it, begun elsewhere, drawn the other way.
        let turn = CGAffineTransform(translationX: 50, y: 50).rotated(by: 0.6).translatedBy(x: -50, y: -50)
        var b = circle.applying(turn)
        b.reverse(0)
        let (x, y) = BezierPath.matched(circle, b)
        // As many anchors already: point by point, as they are.
        #expect(x == circle && y == b)
        // With one point more, they are matched: nothing goes far, and the circle stays one. An
        // anchor that comes to lie close to one of the other's is that one, and goes the little way.
        b.insert(0, segment: 0, t: 0.5)
        let (p, q) = BezierPath.matched(circle, b)
        #expect(p.hasRuns(of: q) && p.anchorCount < 10, "\(p.anchorCount)")
        #expect(sameShape(p, circle) && sameShape(q, b))
        #expect(travel(p, q).allSatisfy { $0 < 12 }, "\(travel(p, q))")
        #expect(travel(p, q).filter { $0 < 1 }.count >= p.anchorCount - 1, "\(travel(p, q))")
        #expect(sameShape(p.mixed(with: q, 0.5), circle, within: 0.5))
    }

    @Test func aStarGoesIntoACircleAndBackWithoutCrossingItself() {
        var points: [CGPoint] = []
        for i in 0..<10 {
            let r: CGFloat = i % 2 == 0 ? 50 : 22, a = CGFloat(i) * .pi / 5 - .pi / 2
            points.append(CGPoint(x: 50 + r * cos(a), y: 50 + r * sin(a)))
        }
        let star = BezierPath(subpaths: [BezierPath.Subpath(anchors: points.map { BezierPath.Anchor($0) }, closed: true)])
        for (from, to) in [(star, circle), (circle, star)] {
            let (x, y) = BezierPath.matched(from, to)
            #expect(x.hasRuns(of: y))
            #expect(sameShape(x, from) && sameShape(y, to))
            #expect(x.subpaths[0].anchors[0].point == from.subpaths[0].anchors[0].point)
            // Every point keeps its side of the middle: the angle it is seen at turns by little.
            let middle = CGPoint(x: 50, y: 50)
            for (p, q) in zip(x.anchorPoints, y.anchorPoints) {
                let a = atan2(p.y - middle.y, p.x - middle.x), b = atan2(q.y - middle.y, q.x - middle.x)
                #expect(abs(atan2(sin(a - b), cos(a - b))) * 180 / .pi < 12, "\(p) goes to \(q)")
            }
        }
    }

    // MARK: Open runs

    @Test func aLineDrawnFurtherGrowsOutOfItsEnd() {
        let a = BezierPath("M 0 0 L 100 0"), b = BezierPath("M 0 0 L 100 0 L 100 80 L 160 80")
        let (x, y) = BezierPath.matched(a, b)
        #expect(y == b)
        #expect(x.anchorPoints.map { [$0.x, $0.y] } == [[0, 0], [100, 0], [100, 0], [100, 0]])
        #expect(!x.subpaths[0].closed)
        // And out of its beginning, when it is drawn on before it.
        let c = BezierPath("M -50 -50 L 0 0 L 100 0")
        let (p, q) = BezierPath.matched(a, c)
        #expect(q == c)
        #expect(p.anchorPoints.map { [$0.x, $0.y] } == [[0, 0], [0, 0], [100, 0]])
    }

    @Test func anOpenRunDrawnTheOtherWayIsTakenTheWayItLies() {
        let a = BezierPath("M 0 0 L 100 0 L 100 80"), b = BezierPath("M 104 84 L 104 40 L 104 4 L 4 4")
        let (x, y) = BezierPath.matched(a, b)
        #expect(x.hasRuns(of: y) && x.anchorCount == 4)
        #expect(sameShape(x, a) && sameShape(y, b))
        #expect(travel(x, y).allSatisfy { $0 < 6 }, "\(travel(x, y))")
        // `a` still runs its own way.
        #expect(x.subpaths[0].anchors[0].point == .zero)
    }

    @Test func aClosedRunGoesIntoAnOpenOneOpenedWhereThatBegins() {
        // The square's three sides, drawn from its second corner.
        let open = BezierPath("M 100 0 L 100 100 L 0 100 L 0 0")
        let (x, y) = BezierPath.matched(square, open)
        #expect(x.hasRuns(of: y) && !x.subpaths[0].closed)
        #expect(sameShape(x, square) && sameShape(y, open))
        #expect(near(x.subpaths[0].anchors[0].point, CGPoint(x: 100, y: 0)))
        // Its fourth side closes on the way: its end comes back from the open run's last corner.
        #expect(travel(x, y).filter { $0 > 0.01 }.count == 1)
        let (p, q) = BezierPath.matched(open, square)
        #expect(p.hasRuns(of: q) && sameShape(p, open) && sameShape(q, square))
        // Where it shares no corner: opened where its points go least far.
        let line = BezierPath("M 20 -30 L 80 -30")
        let (s, t) = BezierPath.matched(square, line)
        #expect(s.hasRuns(of: t) && sameShape(s, square) && sameShape(t, line))
        // Opened in the middle of the side away from the line, so each half goes round to it.
        #expect(near(s.subpaths[0].anchors[0].point, CGPoint(x: 50, y: 100), 2), "\(s.subpaths[0].anchors[0].point)")
    }

    // MARK: Several runs

    @Test func aRunWithNoneToGoWithShrinksToItsMiddle() {
        let ring = BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z M 30 30 L 30 70 L 70 70 L 70 30 Z")
        let (x, y) = BezierPath.matched(ring, circle)
        #expect(x.hasRuns(of: y) && x.subpaths.count == 2)
        #expect(x.subpaths[1] == ring.subpaths[1])
        #expect(y.subpaths[1].anchors.allSatisfy { $0.point == CGPoint(x: 50, y: 50) && $0.handleIn == nil && $0.handleOut == nil })
        #expect(sameShape(BezierPath(subpaths: [y.subpaths[0]]), circle))
        // The other way, it grows from there.
        let (p, q) = BezierPath.matched(circle, ring)
        #expect(p.hasRuns(of: q) && q.subpaths[1] == ring.subpaths[1])
        #expect(p.subpaths[1].anchors.allSatisfy { $0.point == CGPoint(x: 50, y: 50) })
    }

    @Test func runsGoWithTheRunsNearestThem() {
        // A square on the left and a triangle on the right; then the triangle first, with a point more.
        let a = BezierPath("M 0 0 L 40 0 L 40 40 L 0 40 Z M 100 0 L 140 0 L 120 40 Z")
        let b = BezierPath("M 100 0 L 120 -10 L 140 0 L 120 40 Z M 0 0 L 40 0 L 40 40 L 0 40 Z")
        let (x, y) = BezierPath.matched(a, b)
        #expect(x.hasRuns(of: y) && x.subpaths.count == 2)
        #expect(x.subpaths[0] == a.subpaths[0] && y.subpaths[0] == b.subpaths[1])
        #expect(x.subpaths[1].anchors.count == 4 && y.subpaths[1] == b.subpaths[0])
        #expect(travel(x, y).filter { $0 > 0.01 } == [10])
        // A closed run goes with the closed one, though an open one lies nearer.
        let c = BezierPath("M 0 0 L 40 0 L 40 40 M 200 0 L 240 0 L 240 40 L 220 60 L 200 40 Z")
        let (p, q) = BezierPath.matched(BezierPath("M 0 0 L 40 0 L 40 40 L 0 40 Z"), c)
        #expect(p.hasRuns(of: q))
        #expect(sameShape(BezierPath(subpaths: [q.subpaths[0]]), BezierPath(subpaths: [c.subpaths[1]])))
        #expect(q.subpaths[1] == c.subpaths[0] && p.subpaths[1].anchors.allSatisfy { $0.point == CGPoint(x: 20, y: 20) })
    }

    // MARK: Taken from another shape

    @Test func anOutlineTakenFromAnotherShapeIsNumberedLikeTheOneItComesFrom() {
        // The same square, begun at its third corner and drawn the other way: itself again.
        var other = square
        other.subpaths[0].anchors = [2, 1, 0, 3].map { square.subpaths[0].anchors[$0] }
        #expect(other.laid(along: square) == square)
        // A square a little turned and grown: its own four corners, begun at the nearest.
        let turn = CGAffineTransform(translationX: 50, y: 50).rotated(by: 0.1).scaledBy(x: 1.2, y: 1.2).translatedBy(x: -50, y: -50)
        let close = other.applying(turn).laid(along: square)
        #expect(close.anchorCount == 4 && sameShape(close, square.applying(turn)))
        #expect(travel(close, square).allSatisfy { $0 < 20 }, "\(travel(close, square))")
        // A diamond, whose corners are where the square's sides are: points more, so that
        // nothing turns on the way.
        let diamond = BezierPath("M 50 110 L -10 50 L 50 -10 L 110 50 Z")
        let taken = diamond.laid(along: square)
        #expect(taken.anchorCount == 8 && sameShape(taken, diamond))
        let (x, y) = BezierPath.matched(square, taken)
        #expect(y == taken && sameShape(x, square))
        #expect(travel(x, y).allSatisfy { $0 < 30 }, "\(travel(x, y))")
        // An open run, drawn the other way.
        #expect(BezierPath("M 100 0 L 50 10 L 0 0").laid(along: BezierPath("M 0 5 L 50 5 L 100 5")) == BezierPath("M 0 0 L 50 10 L 100 0"))
        // Runs in the order of the runs they go with, and none for a run that has none.
        let two = BezierPath("M 200 0 L 240 0 L 220 40 Z M 0 0 L 40 0 L 40 40 L 0 40 Z")
        let laid = two.laid(along: BezierPath("M 2 2 L 42 2 L 42 42 L 2 42 Z M 100 100 L 110 100 L 110 110 Z M 202 2 L 242 2 L 222 42 Z"))
        #expect(laid.subpaths.count == 2)
        #expect(laid.subpaths[0] == two.subpaths[1] && laid.subpaths[1] == two.subpaths[0])
    }

    // MARK: Whatever the outlines

    private struct Dice {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func number(_ range: ClosedRange<Double>) -> CGFloat {
            CGFloat(range.lowerBound + (range.upperBound - range.lowerBound) * Double(next() % 1_000_000) / 1_000_000)
        }
        mutating func whole(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
    }

    /// Any outline: one to three runs, closed or open, corners and curves.
    private func anyOutline(_ dice: inout Dice) -> BezierPath {
        var runs: [BezierPath.Subpath] = []
        for _ in 0..<dice.whole(1...3) {
            let middle = CGPoint(x: dice.number(0...300), y: dice.number(0...200)), count = dice.whole(2...9)
            let closed = count > 2 && dice.chance(0.7)
            var anchors: [BezierPath.Anchor] = []
            for i in 0..<count {
                let angle = CGFloat(i) / CGFloat(count) * 2 * .pi + dice.number(-0.2...0.2), r = dice.number(15...70)
                let p = CGPoint(x: middle.x + r * cos(angle), y: middle.y + r * sin(angle))
                var a = BezierPath.Anchor(p)
                if dice.chance(0.5) {
                    let way = CGPoint(x: -sin(angle), y: cos(angle)), l = dice.number(4...25)
                    a.handleIn = p - way * l
                    if dice.chance(0.8) { a.handleOut = p + way * dice.number(4...25) }
                }
                anchors.append(a)
            }
            runs.append(BezierPath.Subpath(anchors: anchors, closed: closed))
        }
        return BezierPath(subpaths: runs).stored
    }

    @Test func anyTwoOutlinesAreGivenTheSamePointsAndStayTheShapesTheyAre() {
        var dice = Dice(state: 7)
        for round in 0..<300 {
            let a = anyOutline(&dice)
            var b = anyOutline(&dice)
            // Often the other is the first one, changed a little: points added, taken away, moved.
            if dice.chance(0.5) {
                b = a
                for _ in 0..<dice.whole(1...3) {
                    let s = dice.whole(0...(b.subpaths.count - 1))
                    let run = b.subpaths[s]
                    switch dice.whole(0...2) {
                    case 0 where run.segmentCount > 0:
                        b.insert(s, segment: dice.whole(0...(run.segmentCount - 1)), t: dice.number(0.1...0.9))
                    case 1 where run.anchors.count > 3:
                        b.remove([PathPoint(subpath: s, index: dice.whole(0...(run.anchors.count - 1)))])
                    default:
                        let i = dice.whole(0...(run.anchors.count - 1))
                        b.subpaths[s].anchors[i] = run.anchors[i].offset(by: CGPoint(x: dice.number(-20...20), y: dice.number(-20...20)))
                    }
                }
            }
            let (x, y) = BezierPath.matched(a, b)
            #expect(x.hasRuns(of: y), "round \(round)")
            let numbers = (x.subpaths + y.subpaths).flatMap { $0.anchors.flatMap { [$0.point, $0.handleIn ?? $0.point, $0.handleOut ?? $0.point] } }
            #expect(numbers.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "round \(round)")
            // Each is the shape it was, but for runs gathered in one place to grow from.
            func drawn(_ p: BezierPath) -> BezierPath {
                BezierPath(subpaths: p.subpaths.filter { run in !run.anchors.allSatisfy { $0.point == run.anchors[0].point && $0.handleIn == nil && $0.handleOut == nil } })
            }
            #expect(sameShape(drawn(x), a), "round \(round): the first is another shape\n\(a.data)\n\(b.data)\n\(x.data)")
            #expect(sameShape(drawn(y), b), "round \(round): the second is another shape\n\(a.data)\n\(b.data)\n\(y.data)")
            #expect(x.mixed(with: y, 0) == x && x.mixed(with: y, 1) == y, "round \(round)")
            // A run of the first is drawn its own way from its own beginning still, where it was closed and stays so.
            if a.subpaths.count == 1, b.subpaths.count == 1, a.subpaths[0].closed, b.subpaths[0].closed {
                #expect(x.subpaths[0].anchors[0].point == a.subpaths[0].anchors[0].point, "round \(round)")
            }
        }
    }

    @Test func matchingLongOutlinesTakesLittleTime() {
        var dice = Dice(state: 11)
        func long(_ count: Int) -> BezierPath {
            var anchors: [BezierPath.Anchor] = []
            for i in 0..<count {
                let angle = CGFloat(i) / CGFloat(count) * 2 * .pi, r = dice.number(80...120)
                let p = CGPoint(x: 150 + r * cos(angle), y: 150 + r * sin(angle)), way = CGPoint(x: -sin(angle), y: cos(angle))
                anchors.append(BezierPath.Anchor(p, in: p - way * 2, out: p + way * 2))
            }
            return BezierPath(subpaths: [BezierPath.Subpath(anchors: anchors, closed: true)])
        }
        let a = long(120), b = long(90)
        let began = Date()
        var made = (a, b)
        for _ in 0..<10 { made = BezierPath.matched(a, b) }
        let each = Date().timeIntervalSince(began) / 10
        #expect(made.0.hasRuns(of: made.1))
        #expect(sameShape(made.0, a) && sameShape(made.1, b))
        // Unoptimized, as tests are built, and on a busy Mac: some 3 ms (2026-11-14), many times
        // less in a release.
        #expect(each < 0.05, "\(each * 1000) ms each")
    }
}
