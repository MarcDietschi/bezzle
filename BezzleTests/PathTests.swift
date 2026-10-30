import Testing
import AppKit
@testable import Bezzle

/// Within a hundredth of a point: a curve's box is seldom whole, and the frame fitted round it carries that.
private func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
}

struct BezierPathTests {
    @Test func readsAndWritesTheSameOutline() {
        let path = BezierPath("M 0 0 L 10 0 C 20 0 20 10 10 10 Z")
        #expect(path.subpaths.count == 1)
        #expect(path.subpaths[0].closed)
        #expect(path.subpaths[0].anchors.map(\.point) == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        #expect(path.subpaths[0].anchors[1].handleOut == CGPoint(x: 20, y: 0))
        #expect(path.subpaths[0].anchors[2].handleIn == CGPoint(x: 20, y: 10))
        #expect(BezierPath(path.data) == path)
    }

    @Test func aRunThatEndsWhereItBeganHasThatPointOnce() {
        let path = BezierPath("M 0 0 C 5 -5 15 -5 20 0 C 15 5 5 5 0 0 Z")
        #expect(path.subpaths[0].anchors.count == 2)
        #expect(path.subpaths[0].anchors[0].handleIn == CGPoint(x: 5, y: 5))
        #expect(path.subpaths[0].anchors[0].handleOut == CGPoint(x: 5, y: -5))
        #expect(BezierPath(path.data) == path)
    }

    @Test func quadraticCurvesBecomeCubicOnes() {
        let path = BezierPath("M 0 0 Q 30 30 60 0")
        let a = path.subpaths[0].anchors
        #expect(a.count == 2)
        #expect(abs(a[0].handleOut!.x - 20) < 0.001 && abs(a[0].handleOut!.y - 20) < 0.001)
        #expect(abs(a[1].handleIn!.x - 40) < 0.001 && abs(a[1].handleIn!.y - 20) < 0.001)
    }

    @Test func aPointAddedOnACurveLeavesItsShape() {
        var path = BezierPath("M 0 0 C 0 50 100 50 100 0")
        let before = BezierPath.point(on: path.segment(0, 0), at: 0.25)
        let added = path.insert(0, segment: 0, t: 0.5)
        #expect(added == PathPoint(subpath: 0, index: 1))
        #expect(path.subpaths[0].anchors.count == 3)
        #expect(abs(path[added].point.x - 50) < 0.001 && abs(path[added].point.y - 37.5) < 0.001)
        // A quarter of the way along the whole is halfway along the first half.
        let after = BezierPath.point(on: path.segment(0, 0), at: 0.5)
        #expect(hypot(after.x - before.x, after.y - before.y) < 0.001)
        #expect(path.isSmooth(added))
    }

    @Test func takingAPointAwayJoinsItsNeighbours() {
        var path = BezierPath("M 0 0 L 10 0 L 20 0 L 30 0")
        path.remove([PathPoint(subpath: 0, index: 1), PathPoint(subpath: 0, index: 2)])
        #expect(path.subpaths[0].anchors.map(\.point) == [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0)])
        path.remove([PathPoint(subpath: 0, index: 0)])
        #expect(path.subpaths.isEmpty)
    }

    @Test func cornersAndSmoothPoints() {
        var path = BezierPath("M 0 0 L 50 50 L 100 0")
        let middle = PathPoint(subpath: 0, index: 1)
        #expect(!path.isSmooth(middle))
        path.makeSmooth(middle)
        #expect(path.isSmooth(middle))
        // Level, along the way from one neighbour to the other, a third of the way to each.
        #expect(abs(path[middle].handleIn!.y - 50) < 0.001 && abs(path[middle].handleOut!.y - 50) < 0.001)
        #expect(abs(path[middle].handleOut!.x - (50 + hypot(50, 50) / 3)) < 0.001)
        // A smooth point's handles turn together, each keeping its length…
        var turned = path
        turned.moveHandle(middle, out: true, to: CGPoint(x: 50, y: 80), alone: false)
        #expect(turned.isSmooth(middle))
        #expect(abs(turned[middle].handleIn!.x - 50) < 0.001 && abs(turned[middle].handleIn!.y - (50 - hypot(50, 50) / 3)) < 0.001)
        // …unless one moves alone, which leaves a bend.
        turned.moveHandle(middle, out: true, to: CGPoint(x: 90, y: 50), alone: true)
        #expect(!turned.isSmooth(middle))
        path.makeCorner(middle)
        #expect(path[middle].handleIn == nil && path[middle].handleOut == nil)
    }

    @Test func theNearestPlaceOnTheOutline() {
        let path = BezierPath("M 0 0 L 100 0 L 100 100")
        let spot = try! #require(path.nearest(to: CGPoint(x: 40, y: 6)))
        #expect(spot.segment == 0)
        #expect(abs(spot.t - 0.4) < 0.001)
        #expect(abs(spot.distance - 6) < 0.001)
        #expect(path.nearest(to: CGPoint(x: 40, y: 60), within: 5) == nil)
    }
}

@MainActor
struct PathLayerTests {
    @Test func pointsAreOnTheCanvasWhereverThePathIs() {
        var path = Node.path(BezierPath("M 0 0 L 40 0 L 40 20"), name: "P")
        path.frame = CGRect(x: 10, y: 10, width: 80, height: 40)
        let bench = Bench(extra: [path])
        let id = bench.node("P")!.id
        // Drawn twice as big as its own box, and on an artboard at 100,100.
        let points = try! #require(bench.store.doc.points(of: id))
        #expect(points.subpaths[0].anchors.map(\.point) == [CGPoint(x: 110, y: 110), CGPoint(x: 190, y: 110), CGPoint(x: 190, y: 150)])
    }

    @Test func aTurnedPathKeepsItsTurnAsItsPointsMove() {
        var path = Node.path(BezierPath("M 0 0 L 100 0 L 100 50"), name: "P")
        path.rotation = 30
        let bench = Bench(extra: [path])
        let id = bench.node("P")!.id
        var points = try! #require(bench.store.doc.points(of: id))
        let moved = points[PathPoint(subpath: 0, index: 2)].point + CGPoint(x: 0, y: 40)
        points[PathPoint(subpath: 0, index: 2)].point = moved
        bench.step { bench.store.setPoints(points, of: id, "Move Points") }
        let after = try! #require(bench.store.doc.points(of: id))
        #expect(bench.node("P")?.rotation == 30)
        for (a, b) in zip(after.subpaths[0].anchors, points.subpaths[0].anchors) {
            #expect(hypot(a.point.x - b.point.x, a.point.y - b.point.y) < 0.01)
        }
    }

    @Test func shapesConvertToPathsThatLookTheSame() {
        var rect = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 30))
        rect.rotation = 15
        let bench = Bench(extra: [rect])
        bench.store.selection = [bench.node("R")!.id]
        #expect(bench.store.canConvertToPath)
        bench.step { bench.store.convertToPath() }
        let n = try! #require(bench.node("R"))
        #expect(n.kind == .path)
        #expect(n.frame == CGRect(x: 10, y: 10, width: 50, height: 30))
        #expect(n.rotation == 15)
        let points = try! #require(bench.store.doc.points(of: n.id))
        #expect(points.subpaths.count == 1 && points.subpaths[0].closed && points.subpaths[0].anchors.count == 4)
    }
}

@MainActor
struct PenTests {
    private func path(_ bench: Bench) -> Node? { bench.store.doc.allNodes.first { $0.kind == .path } }

    private func points(_ bench: Bench) -> [CGPoint] {
        guard let p = path(bench), let points = bench.store.doc.points(of: p.id) else { return [] }
        return points.subpaths.flatMap(\.anchors).map(\.point)
    }

    @Test func clicksPutDownCornersAndReturnEndsThePath() {
        let bench = Bench()
        bench.store.tool = .pen
        bench.click(CGPoint(x: 150, y: 150), flags: .command)
        // One point is not yet a layer.
        #expect(bench.a.children.isEmpty)
        bench.click(CGPoint(x: 250, y: 150), flags: .command)
        bench.click(CGPoint(x: 250, y: 250), flags: .command)
        #expect(points(bench) == [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 150), CGPoint(x: 250, y: 250)])
        let p = try! #require(bench.a.children.first)
        #expect(p.kind == .path)
        #expect(p.frame == CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(p.border.on && !p.fill.on)
        #expect(bench.store.selection == [p.id])
        // Each point undoes on its own, and the pen carries on from the one before.
        bench.undoLast()
        #expect(points(bench).count == 2)
        bench.click(CGPoint(x: 150, y: 250), flags: .command)
        #expect(points(bench) == [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 150), CGPoint(x: 150, y: 250)])
        bench.key(36)
        #expect(bench.store.tool == .select)
        #expect(bench.store.doc.points(of: p.id)?.subpaths[0].closed == false)
        bench.undoLast()
        bench.undoLast()
        bench.undoLast()
        #expect(bench.a.children.isEmpty)
    }

    @Test func aDragPullsACurveOutOfThePoint() {
        let bench = Bench()
        bench.store.tool = .pen
        bench.click(CGPoint(x: 150, y: 150), flags: .command)
        bench.drag(CGPoint(x: 250, y: 150), CGPoint(x: 290, y: 190), flags: .command)
        let p = try! #require(path(bench))
        let a = try! #require(bench.store.doc.points(of: p.id)).subpaths[0].anchors
        #expect(near(a[1].point, CGPoint(x: 250, y: 150)))
        #expect(near(a[1].handleIn, CGPoint(x: 210, y: 110)))
        // The next part leaves along the handle pulled out…
        bench.click(CGPoint(x: 350, y: 150), flags: .command)
        let b = try! #require(bench.store.doc.points(of: p.id)).subpaths[0].anchors
        #expect(near(b[1].handleOut, CGPoint(x: 290, y: 190)))
        // Dragging from the newest point pulls a handle out of it alone…
        bench.drag(CGPoint(x: 350, y: 150), CGPoint(x: 350, y: 200), flags: .command)
        bench.click(CGPoint(x: 450, y: 150), flags: .command)
        let c = try! #require(bench.store.doc.points(of: p.id)).subpaths[0].anchors
        #expect(c.count == 4)
        #expect(c[2].handleIn == nil)
        #expect(near(c[2].handleOut, CGPoint(x: 350, y: 200)))
        // …and a click on it takes that away again, for a corner.
        bench.drag(CGPoint(x: 450, y: 150), CGPoint(x: 480, y: 120), flags: .command)
        bench.click(CGPoint(x: 450, y: 150))
        bench.click(CGPoint(x: 450, y: 250), flags: .command)
        let d = try! #require(bench.store.doc.points(of: p.id)).subpaths[0].anchors
        #expect(d.count == 5)
        #expect(d[3].handleOut == nil)
    }

    @Test func aClickOnTheNewestPointTakesAwayTheHandleItsOwnDragPulledOut() {
        let bench = Bench()
        bench.store.tool = .pen
        bench.click(CGPoint(x: 150, y: 150), flags: .command)
        bench.drag(CGPoint(x: 250, y: 150), CGPoint(x: 290, y: 190), flags: .command)
        bench.click(CGPoint(x: 250, y: 150))
        bench.click(CGPoint(x: 350, y: 150), flags: .command)
        let p = try! #require(path(bench))
        let a = try! #require(bench.store.points(of: p.id)).subpaths[0].anchors
        #expect(a.count == 3)
        #expect(near(a[1].handleIn, CGPoint(x: 210, y: 110)))
        #expect(a[1].handleOut == nil)
        #expect(a[2].handleIn == nil)
    }

    @Test func backOnTheFirstPointThePathCloses() {
        let bench = Bench()
        bench.store.tool = .pen
        for p in [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 150), CGPoint(x: 250, y: 250)] { bench.click(p, flags: .command) }
        bench.click(CGPoint(x: 151, y: 151))
        let p = try! #require(path(bench))
        let points = try! #require(bench.store.doc.points(of: p.id))
        #expect(points.subpaths[0].closed)
        #expect(points.subpaths[0].anchors.count == 3)
        #expect(bench.store.tool == .select)
        bench.undoLast()
        #expect(bench.store.doc.points(of: p.id)?.subpaths[0].closed == false)
    }

    @Test func deleteTakesBackTheNewestPoint() {
        let bench = Bench()
        bench.store.tool = .pen
        for p in [CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 150), CGPoint(x: 250, y: 250)] { bench.click(p, flags: .command) }
        bench.key(51)
        #expect(points(bench).count == 2)
        // Down to one point, the layer goes and the pen carries on from that point.
        bench.key(51)
        #expect(bench.a.children.isEmpty)
        bench.click(CGPoint(x: 200, y: 300), flags: .command)
        #expect(points(bench) == [CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 300)])
    }

    @Test func thePenCarriesOnFromAnOpenEndAndAddsAndTakesAwayPoints() {
        let bench = Bench(extra: [Node.path(BezierPath("M 10 10 L 110 10 L 110 110"), name: "P")])
        let id = bench.node("P")!.id
        bench.store.selection = [id]
        bench.store.tool = .pen
        // On the outline: a point there.
        bench.click(CGPoint(x: 160, y: 110))
        #expect(points(bench).contains(CGPoint(x: 160, y: 110)))
        #expect(points(bench).count == 4)
        // On a point that is not an end: it goes.
        bench.click(CGPoint(x: 210, y: 110))
        #expect(points(bench) == [CGPoint(x: 110, y: 110), CGPoint(x: 160, y: 110), CGPoint(x: 210, y: 210)])
        // On the first point, an open end: the next click carries on from it.
        bench.click(CGPoint(x: 110, y: 110))
        bench.click(CGPoint(x: 110, y: 250), flags: .command)
        let after = points(bench)
        #expect(after.count == 4)
        #expect(after.first == CGPoint(x: 210, y: 210) || after.last == CGPoint(x: 110, y: 250))
        #expect(Set(after) == [CGPoint(x: 110, y: 110), CGPoint(x: 160, y: 110), CGPoint(x: 210, y: 210), CGPoint(x: 110, y: 250)])
        #expect(bench.store.doc.allNodes.filter { $0.kind == .path }.count == 1)
    }
}

@MainActor
struct PointEditingTests {
    private func points(_ bench: Bench) -> [CGPoint] {
        guard let p = bench.node("P"), let points = bench.store.doc.points(of: p.id) else { return [] }
        return points.subpaths.flatMap(\.anchors).map(\.point)
    }

    /// An open path on artboard A, from 110,110 across to 210,110 and down to 210,210.
    private func bench() -> Bench {
        Bench(extra: [Node.path(BezierPath("M 10 10 L 110 10 L 110 110"), name: "P")])
    }

    @Test func aDoubleClickOpensThePointsAndEscapeShutsThem() {
        let bench = bench()
        // A quarter of the way along the top, clear of the frame's handles.
        bench.click(CGPoint(x: 135, y: 110))
        bench.click(CGPoint(x: 135, y: 110), clicks: 2)
        let id = bench.node("P")!.id
        #expect(bench.store.editingPath == id)
        bench.key(53)
        #expect(bench.store.editingPath == nil)
        #expect(bench.store.selection == [id])
        bench.key(36)
        #expect(bench.store.editingPath == id)
    }

    @Test func draggingAPointMovesIt() {
        let bench = bench()
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        bench.drag(CGPoint(x: 210, y: 210), CGPoint(x: 240, y: 230), flags: .command)
        #expect(points(bench) == [CGPoint(x: 110, y: 110), CGPoint(x: 210, y: 110), CGPoint(x: 240, y: 230)])
        #expect(bench.store.selectedPoints == [PathPoint(subpath: 0, index: 2)])
        #expect(bench.node("P")?.frame == CGRect(x: 10, y: 10, width: 130, height: 120))
        bench.undoLast()
        #expect(points(bench).last == CGPoint(x: 210, y: 210))
    }

    @Test func pickedPointsMoveTogetherAndGoWithDelete() {
        let bench = bench()
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        // Dragging round the first two picks them.
        bench.drag(CGPoint(x: 100, y: 100), CGPoint(x: 220, y: 120))
        #expect(bench.store.selectedPoints == [PathPoint(subpath: 0, index: 0), PathPoint(subpath: 0, index: 1)])
        bench.key(125, flags: .shift)
        #expect(points(bench) == [CGPoint(x: 110, y: 120), CGPoint(x: 210, y: 120), CGPoint(x: 210, y: 210)])
        bench.store.selectedPoints = [PathPoint(subpath: 0, index: 1)]
        bench.key(51)
        #expect(points(bench) == [CGPoint(x: 110, y: 120), CGPoint(x: 210, y: 210)])
    }

    @Test func aClickOnTheOutlineAddsAPointAndADoubleClickOnAPointRoundsIt() {
        let bench = bench()
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        bench.click(CGPoint(x: 210, y: 160))
        #expect(points(bench) == [CGPoint(x: 110, y: 110), CGPoint(x: 210, y: 110), CGPoint(x: 210, y: 160), CGPoint(x: 210, y: 210)])
        let corner = PathPoint(subpath: 0, index: 1)
        bench.click(CGPoint(x: 210, y: 110))
        bench.click(CGPoint(x: 210, y: 110), clicks: 2)
        let path = try! #require(bench.store.doc.points(of: bench.node("P")!.id))
        #expect(path.isSmooth(corner))
        #expect(bench.store.pickedSmooth == true)
        bench.step { bench.store.setSmooth(false) }
        #expect(bench.store.pickedSmooth == false)
    }

    @Test func aPointAddedOnTheOutlineGoesWithTheDragThatAddedIt() {
        let bench = bench()
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        bench.move(CGPoint(x: 210, y: 160))
        #expect(near(bench.canvas.pathTool.spot, CGPoint(x: 210, y: 160)))
        // Held down partway: the new point is under the pointer, and its ghost is gone from where it was.
        bench.drag(CGPoint(x: 210, y: 160), CGPoint(x: 250, y: 170), flags: .command, release: false)
        #expect(points(bench) == [CGPoint(x: 110, y: 110), CGPoint(x: 210, y: 110), CGPoint(x: 250, y: 170), CGPoint(x: 210, y: 210)])
        #expect(bench.store.selectedPoints == [PathPoint(subpath: 0, index: 2)])
        #expect(bench.canvas.pathTool.spot == nil)
    }

    @Test func draggingAHandleTurnsTheOtherWithIt() {
        let bench = Bench(extra: [Node.path(BezierPath("M 10 10 C 10 40 60 60 110 60 C 160 60 210 40 210 10"), name: "P")])
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        bench.click(CGPoint(x: 210, y: 160))
        #expect(bench.store.selectedPoints == [PathPoint(subpath: 0, index: 1)])
        // The handle out of the middle point, at 260,160 on the canvas, pulled up.
        bench.drag(CGPoint(x: 260, y: 160), CGPoint(x: 260, y: 110))
        let path = try! #require(bench.store.doc.points(of: bench.node("P")!.id))
        let middle = path[PathPoint(subpath: 0, index: 1)]
        #expect(near(middle.handleOut, CGPoint(x: 260, y: 110)))
        #expect(path.isSmooth(PathPoint(subpath: 0, index: 1)))
        #expect(abs(middle.handleIn!.x - (210 - 50 / sqrt(2))) < 0.01)
    }

    @Test func clickingAnotherLayerLeavesThePoints() {
        let bench = Bench(extra: [Node.path(BezierPath("M 10 10 L 110 10"), name: "P"), CanvasTests.rect("R", CGRect(x: 200, y: 150, width: 50, height: 50))])
        bench.store.selection = [bench.node("P")!.id]
        bench.store.editPoints()
        bench.click(CGPoint(x: 320, y: 270))
        #expect(bench.store.editingPath == nil)
        #expect(bench.store.selection == [bench.node("R")!.id])
    }

    /// A square on artboard A, from 110,110 to 210,210, opened by a double click in its middle.
    private func openedSquare() -> Bench {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.click(CGPoint(x: 160, y: 160))
        bench.click(CGPoint(x: 160, y: 160), clicks: 2)
        return bench
    }

    @Test func aDoubleClickedShapeLeftAsItWasIsTheShapeAgain() {
        let bench = openedSquare()
        let id = bench.node("R")!.id
        #expect(bench.store.editingPath == id)
        #expect(bench.node("R")?.kind == .path)
        // Not a change to its outline: it is still the shape afterwards, with the new opacity.
        bench.step { bench.store.updateSelection("Opacity") { $0.opacity = 0.5 } }
        bench.key(53)
        #expect(bench.store.editingPath == nil)
        #expect(bench.store.selection == [id])
        #expect(bench.node("R")?.kind == .rectangle)
        #expect(bench.node("R")?.opacity == 0.5)
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    @Test func aDoubleClickedShapeWhosePointsMovedStaysAPath() {
        let bench = openedSquare()
        bench.drag(CGPoint(x: 210, y: 210), CGPoint(x: 240, y: 230), flags: .command)
        bench.click(CGPoint(x: 450, y: 350))
        #expect(bench.store.editingPath == nil)
        #expect(bench.node("R")?.kind == .path)
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 130, height: 120))
    }

    @Test func undoingTheFirstChangeToAnOpenedShapeBringsTheShapeBack() {
        let bench = openedSquare()
        bench.drag(CGPoint(x: 210, y: 210), CGPoint(x: 240, y: 230), flags: .command)
        bench.undoLast()
        #expect(bench.store.editingPath == nil)
        #expect(bench.node("R")?.kind == .rectangle)
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 100, height: 100))
        bench.undo.redo()
        #expect(bench.node("R")?.kind == .path)
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 130, height: 120))
    }
}

@MainActor
struct CombineTests {
    private func near(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// "R", red, at 10,10 on artboard A, 100 square; "F" over it, from 60,60 the same size; "T"
    /// above both, away from them. F and R are selected, front first.
    private func bench(front: Node.Kind = .rectangle, frontFrame: CGRect = CGRect(x: 60, y: 60, width: 100, height: 100)) -> Bench {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        r.fill.color = RGBA(r: 1, g: 0, b: 0)
        let bench = Bench(extra: [r, Node(kind: front, name: "F", frame: frontFrame), CanvasTests.rect("T", CGRect(x: 300, y: 200, width: 20, height: 20))])
        bench.store.selection = [bench.node("F")!.id, bench.node("R")!.id]
        return bench
    }

    private func made(_ bench: Bench) -> Node? {
        bench.store.selection.count == 1 ? bench.store.node(bench.store.selection[0]) : nil
    }

    @Test func aUnionIsOnePathStyledAsTheBackShapeWhereTheFrontOneWas() throws {
        let bench = bench(front: .ellipse)
        #expect(bench.store.canCombine)
        bench.step { bench.store.combine(.union) }
        let n = try #require(made(bench))
        #expect(n.kind == .path && n.name == "R" && n.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(near(n.frame, CGRect(x: 10, y: 10, width: 150, height: 150)))
        #expect(bench.a.children.map(\.name) == ["R", "T"])
        let outline = try #require(bench.store.doc.outline(of: n.id))
        // In the square, in the circle, and in the circle's box but outside it.
        #expect(outline.contains(CGPoint(x: 120, y: 120)) && outline.contains(CGPoint(x: 250, y: 210)))
        #expect(!outline.contains(CGPoint(x: 250, y: 250)))
    }

    @Test func subtractingCutsTheFrontShapesOutOfTheBackOne() throws {
        let bench = bench(frontFrame: CGRect(x: 60, y: 0, width: 100, height: 120))
        bench.step { bench.store.combine(.subtract) }
        #expect(near(made(bench)?.frame, CGRect(x: 10, y: 10, width: 50, height: 100)))
    }

    @Test func intersectingKeepsWhereTheyOverlap() throws {
        let bench = bench()
        bench.step { bench.store.combine(.intersect) }
        #expect(near(made(bench)?.frame, CGRect(x: 60, y: 60, width: 50, height: 50)))
    }

    @Test func excludingCutsOutWhereTheyOverlap() throws {
        let bench = bench()
        bench.step { bench.store.combine(.exclude) }
        let n = try #require(made(bench))
        #expect(near(n.frame, CGRect(x: 10, y: 10, width: 150, height: 150)))
        let outline = try #require(bench.store.doc.outline(of: n.id))
        #expect(outline.contains(CGPoint(x: 130, y: 130)) && outline.contains(CGPoint(x: 240, y: 240)))
        #expect(!outline.contains(CGPoint(x: 185, y: 185)))
        // Drawn the same whichever way overlaps fill.
        #expect(n.evenOdd == nil)
    }

    @Test func nothingLeftChangesNothing() {
        let bench = bench(frontFrame: CGRect(x: 200, y: 150, width: 50, height: 50))
        let before = bench.store.doc
        bench.step { bench.store.combine(.intersect) }
        #expect(bench.store.doc == before)
        #expect(bench.store.selection.count == 2)
    }

    @Test func undoBringsTheShapesBack() {
        let bench = bench()
        bench.step { bench.store.combine(.union) }
        bench.undoLast()
        #expect(bench.a.children.map(\.name) == ["R", "F", "T"])
        #expect(bench.node("R")?.kind == .rectangle && bench.node("F")?.kind == .rectangle)
    }

    @Test func theBackShapesTurnIsKept() throws {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        r.rotation = 30
        let bench = Bench(extra: [r, CanvasTests.rect("F", CGRect(x: 55, y: 55, width: 10, height: 10))])
        bench.store.selection = [bench.node("R")!.id, bench.node("F")!.id]
        bench.step { bench.store.combine(.union) }
        let n = try #require(made(bench))
        #expect(n.rotation == 30)
        #expect(near(n.frame, CGRect(x: 10, y: 10, width: 100, height: 100)))
    }

    @Test func onlyTwoOrMoreShapesCombine() {
        let bench = bench()
        bench.store.selection = [bench.node("R")!.id]
        #expect(!bench.store.canCombine)
        let text = Node(kind: .text, name: "Words", frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        bench.step { bench.store.add(text, onto: bench.a.id) }
        bench.store.selection = [bench.node("R")!.id, bench.node("F")!.id, text.id]
        #expect(!bench.store.canCombine)
        bench.step { bench.store.setLocked(true, [bench.node("F")!.id]) }
        bench.store.selection = [bench.node("R")!.id, bench.node("F")!.id]
        #expect(!bench.store.canCombine)
    }
}

