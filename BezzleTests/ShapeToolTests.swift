import Testing
import AppKit
@testable import Bezzle

private func near(_ a: CGFloat?, _ b: CGFloat, within d: CGFloat = 0.05) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= d
}

private func near(_ a: CGRect?, _ b: CGRect, within d: CGFloat = 0.05) -> Bool {
    guard let a else { return false }
    return near(a.minX, b.minX, within: d) && near(a.minY, b.minY, within: d) && near(a.width, b.width, within: d) && near(a.height, b.height, within: d)
}

struct CornerTests {
    private let square = BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z")

    @Test func aSquareHasFourSharpCorners() {
        let corners = square.corners
        #expect(corners.count == 4)
        #expect(corners.allSatisfy { !$0.rounded && $0.radius == 0 && near($0.angle, .pi / 2, within: 0.001) })
        #expect(corners[0].tip == .zero)
        #expect(near(corners[0].inward.x, sqrt(0.5), within: 0.001) && near(corners[0].inward.y, sqrt(0.5), within: 0.001))
    }

    @Test func roundedCornersAreFoundAgainWithTheirRadius() {
        let radii = Dictionary(uniqueKeysWithValues: square.corners.map { ($0.at, CGFloat(10)) })
        let (rounded, applied) = square.rounding(radii)
        #expect(applied.values.allSatisfy { near($0, 10) })
        #expect(rounded.subpaths[0].anchors.count == 8)
        let again = rounded.corners
        #expect(again.count == 4)
        #expect(again.allSatisfy { $0.rounded && near($0.radius, 10, within: 0.01) })
        #expect(Set(again.map { "\(Int($0.tip.x.rounded())),\(Int($0.tip.y.rounded()))" }) == ["0,0", "100,0", "100,100", "0,100"])
        // And back to sharp.
        let sharp = rounded.rounding(Dictionary(uniqueKeysWithValues: again.map { ($0.at, CGFloat(0)) })).path
        #expect(Set(sharp.subpaths[0].anchors.map { "\(Int($0.point.x.rounded())),\(Int($0.point.y.rounded()))" }) == ["0,0", "100,0", "100,100", "0,100"])
        #expect(sharp.subpaths[0].anchors.allSatisfy { $0.handleIn == nil && $0.handleOut == nil })
    }

    @Test func aRoundTakesNoMoreThanHalfASideBetweenTwoRounds() {
        let radii = Dictionary(uniqueKeysWithValues: square.corners.map { ($0.at, CGFloat(80)) })
        let (rounded, applied) = square.rounding(radii)
        #expect(applied.values.allSatisfy { near($0, 50) })
        // Rounds meeting halfway along each side make a circle of four points.
        #expect(rounded.subpaths[0].anchors.count == 4)
        let box = rounded.bounds
        #expect(near(box, CGRect(x: 0, y: 0, width: 100, height: 100), within: 0.1))
    }

    @Test func oneCornerAlone() {
        let triangle = BezierPath("M 0 100 L 50 0 L 100 100 Z")
        let top = try! #require(triangle.corners.first { $0.tip == CGPoint(x: 50, y: 0) })
        let (rounded, applied) = triangle.rounding([top.at: 8])
        #expect(near(applied[top.at], 8))
        #expect(rounded.subpaths[0].anchors.count == 4)
        #expect(rounded.corners.filter(\.rounded).count == 1)
    }

    @Test func aRectangleTurnedIntoAPathKeepsItsRoundsAsCorners() throws {
        var rect = Node(kind: .rectangle, name: "R", frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        rect.cornerRadius = 12
        let path = try #require(rect.asPath()?.path)
        let corners = BezierPath(path).corners
        #expect(corners.count == 4)
        #expect(corners.allSatisfy { $0.rounded && near($0.radius, 12, within: 0.05) })
    }

    @Test func aCornerWhereALineMeetsACurveRoundsToo() {
        // A square with a quarter circle bitten out of its bottom right.
        let bitten = BezierPath(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
            .subtracting(CGPath(ellipseIn: CGRect(x: 60, y: 60, width: 80, height: 80), transform: nil)))
        let mixed = bitten.corners.filter { !$0.straight }
        #expect(mixed.count == 2)
        let (rounded, _) = bitten.rounding(Dictionary(uniqueKeysWithValues: mixed.map { ($0.at, CGFloat(6)) }))
        #expect(rounded.anchorCount == bitten.anchorCount + 2)
        #expect(rounded.subpaths.allSatisfy { $0.closed })
        #expect(near(rounded.bounds, bitten.bounds, within: 0.1))
    }
}

struct OutlineGeometryTests {
    private let square = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)

    private func line(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        return p
    }

    @Test func aCutRightAcrossPartsTheShape() throws {
        let pieces = try #require(Outlines.cut(square, along: line([CGPoint(x: -10, y: 40), CGPoint(x: 110, y: 60)])))
        #expect(pieces.count == 2)
        #expect(near(pieces.map(Outlines.area).reduce(0, +), 10_000, within: 1))
    }

    @Test func aCutThatStopsShortPartsNothing() {
        #expect(Outlines.cut(square, along: line([CGPoint(x: -10, y: 50), CGPoint(x: 50, y: 50)])) == nil)
    }

    @Test func aSlitIntoAPieceIsClosedAgain() throws {
        // Right across, then back into the top piece and stopping there.
        let pieces = try #require(Outlines.cut(square, along: line([CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50), CGPoint(x: 110, y: 20), CGPoint(x: 60, y: 20)])))
        #expect(pieces.count == 2)
        // Where the slit went, the top piece is whole.
        #expect(pieces.contains { $0.contains(CGPoint(x: 80, y: 20)) })
    }

    @Test func overlappingSquaresMakeThreePieces() {
        let other = CGPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100), transform: nil)
        let pieces = Outlines.pieces(of: [square, other])
        #expect(pieces.count == 3)
        #expect(pieces.contains { $0.covers == [0, 1] && near(Outlines.area($0.outline), 2500, within: 1) })
        #expect(pieces.contains { $0.covers == [0] && near(Outlines.area($0.outline), 7500, within: 1) })
    }

    @Test func outlinesGrowAndShrink() throws {
        let out = try #require(Outlines.offset(square, by: 10, round: false))
        #expect(near(out.boundingBoxOfPath, CGRect(x: -10, y: -10, width: 120, height: 120), within: 0.01))
        let inner = try #require(Outlines.offset(square, by: -10, round: false))
        #expect(near(inner.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 80, height: 80), within: 0.01))
        #expect(Outlines.offset(square, by: -60, round: false) == nil)
    }
}

@MainActor
struct ShapeToolTests {
    /// "R" red at 10,10 on artboard A, 100 square; "F" blue from 60,60, the same size, over it.
    private func overlapping() -> Bench {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        r.fill.color = RGBA(r: 1, g: 0, b: 0)
        var f = CanvasTests.rect("F", CGRect(x: 60, y: 60, width: 100, height: 100))
        f.fill.color = RGBA(r: 0, g: 0, b: 1)
        let bench = Bench(extra: [r, f])
        bench.store.selection = [bench.node("R")!.id, bench.node("F")!.id]
        return bench
    }

    private func area(_ bench: Bench, _ id: UUID) -> CGFloat {
        bench.store.doc.outline(of: id).map(Outlines.area) ?? 0
    }

    // MARK: Building

    @Test func joiningTheOverlapMakesItAShapeOfItsOwn() throws {
        let bench = overlapping()
        bench.step { bench.store.startBuilding() }
        let pieces = bench.store.buildPieces
        #expect(pieces.count == 3)
        let overlap = try #require(pieces.firstIndex { $0.covers.count == 2 })
        bench.step { bench.store.build([overlap], erase: false) }
        let children = bench.a.children
        #expect(children.count == 3)
        // Looking as the shape in front, and over both.
        #expect(children.last?.fill.color == RGBA(r: 0, g: 0, b: 1))
        #expect(near(area(bench, children.last!.id), 2500, within: 1))
        #expect(near(area(bench, bench.node("R")!.id), 7500, within: 1))
        #expect(near(area(bench, bench.node("F")!.id), 7500, within: 1))
        // Still building, with what there is now.
        #expect(bench.store.building?.count == 3)
        #expect(bench.store.buildPieces.count == 3)
    }

    @Test func wipingTheOverlapAway() throws {
        let bench = overlapping()
        bench.step { bench.store.startBuilding() }
        let overlap = try #require(bench.store.buildPieces.firstIndex { $0.covers.count == 2 })
        bench.step { bench.store.build([overlap], erase: true) }
        #expect(bench.a.children.count == 2)
        #expect(near(area(bench, bench.node("R")!.id), 7500, within: 1))
        bench.undoLast()
        #expect(bench.node("R")?.kind == .rectangle && bench.a.children.count == 2)
    }

    @Test func aDragAcrossEveryPieceJoinsThemAll() {
        let bench = overlapping()
        bench.step { bench.store.startBuilding() }
        // From inside R alone, through the overlap, into F alone.
        bench.drag(CGPoint(x: 130, y: 130), CGPoint(x: 240, y: 240))
        let children = bench.a.children
        #expect(children.count == 1)
        #expect(children.first?.fill.color == RGBA(r: 1, g: 0, b: 0))
        #expect(near(children.first.map { area(bench, $0.id) }, 17_500, within: 2))
        bench.key(36)
        #expect(bench.store.building == nil)
    }

    // MARK: Cutting

    @Test func theKnifeDraggedAcrossCutsAShapeInTwo() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.store.tool = .knife
        bench.drag(CGPoint(x: 100, y: 160), CGPoint(x: 220, y: 160))
        let children = bench.a.children
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.name == "R" && $0.kind == .path && $0.fill.color == RGBA.shape })
        #expect(bench.store.selection.count == 2)
        #expect(Set(children.map { Int($0.frame.height.rounded()) }) == [50])
    }

    @Test func theKnifeStartedJustInsideStillCuts() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.store.tool = .knife
        bench.drag(CGPoint(x: 114, y: 160), CGPoint(x: 206, y: 160))
        #expect(bench.a.children.count == 2)
    }

    @Test func theKnifeCutsAlongPointsClickedOneAtATime() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.store.tool = .knife
        bench.click(CGPoint(x: 100, y: 120))
        bench.click(CGPoint(x: 160, y: 200))
        bench.click(CGPoint(x: 220, y: 120))
        #expect(bench.a.children.count == 1)
        bench.key(36)
        // The V parts the square into what lies above it and what lies below.
        #expect(bench.a.children.count == 2)
    }

    @Test func theKnifeCutsOnlyTheSelectedShapesItCrosses() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100)),
                                  CanvasTests.rect("S", CGRect(x: 10, y: 150, width: 100, height: 100))])
        bench.store.selection = [bench.node("S")!.id]
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 160, y: 90))
        line.addLine(to: CGPoint(x: 160, y: 390))
        bench.step { bench.store.cut(along: line) }
        #expect(bench.a.children.filter { $0.name == "R" }.count == 1)
        #expect(bench.a.children.filter { $0.name == "S" }.count == 2)
    }

    // MARK: Corners

    @Test func draggingACornerDotRoundsEveryCorner() throws {
        var square = Node.path(BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z"), name: "P")
        square.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        let bench = Bench(extra: [square])
        bench.store.selection = [bench.node("P")!.id]
        // The top left dot sits ten points in each way from the corner, at 110,110 on the canvas.
        bench.drag(CGPoint(x: 120, y: 120), CGPoint(x: 130, y: 130))
        let points = try #require(bench.store.points(of: bench.node("P")!.id))
        let corners = points.corners
        #expect(corners.count == 4)
        #expect(corners.allSatisfy { $0.rounded && near($0.radius, 20, within: 0.05) })
        bench.undoLast()
        #expect(bench.store.points(of: bench.node("P")!.id)?.corners.allSatisfy { !$0.rounded } == true)
    }

    @Test func optionDraggingACornerDotRoundsOnlyThatOne() throws {
        var square = Node.path(BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z"), name: "P")
        square.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        let bench = Bench(extra: [square])
        bench.store.selection = [bench.node("P")!.id]
        bench.drag(CGPoint(x: 120, y: 120), CGPoint(x: 130, y: 130), flags: .option)
        let corners = try #require(bench.store.points(of: bench.node("P")!.id)).corners
        #expect(corners.filter(\.rounded).count == 1)
    }

    // MARK: Outlines

    @Test func optionDraggingTheEdgeOutPullsACopyOutBehind() throws {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.store.selection = [bench.node("R")!.id]
        // From the left edge, away from its handle, ten points out.
        bench.drag(CGPoint(x: 110, y: 140), CGPoint(x: 100, y: 140), flags: .option)
        let children = bench.a.children
        #expect(children.count == 2)
        #expect(children.first?.name == "R Outset")
        #expect(near(children.first?.frame, CGRect(x: 0, y: 0, width: 120, height: 120), within: 0.01))
        #expect(bench.store.selection == [children[0].id])
    }

    @Test func pullingTheEdgeInMakesACopyInFront() throws {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        let id = bench.node("R")!.id
        bench.step { bench.store.offsetCopy(of: id, by: -10, round: false, replacing: nil) }
        let children = bench.a.children
        #expect(children.map(\.name) == ["R", "R Inset"])
        #expect(near(children.last?.frame, CGRect(x: 20, y: 20, width: 80, height: 80), within: 0.01))
    }

    @Test func aBorderBecomesAShapeOverTheFill() throws {
        var rect = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        rect.border = Border(on: true, color: RGBA(r: 0, g: 0.5, b: 0), width: 4, position: .inside)
        let bench = Bench(extra: [rect])
        bench.store.selection = [bench.node("R")!.id]
        #expect(bench.store.canOutlineBorders)
        bench.step { bench.store.outlineBorders() }
        let children = bench.a.children
        #expect(children.map(\.name) == ["R", "R Border"])
        #expect(children[0].border.on == false && children[0].fill.on)
        let border = children[1]
        #expect(border.fill.color == RGBA(r: 0, g: 0.5, b: 0) && !border.border.on)
        #expect(near(border.frame, CGRect(x: 10, y: 10, width: 100, height: 100), within: 0.01))
        #expect(near(area(bench, border.id), 10_000 - 92 * 92, within: 1))
    }

    @Test func aLineBecomesAFilledShape() throws {
        var line = Node(kind: .line, name: "L", frame: CGRect(x: 10, y: 10, width: 100, height: 0))
        line.border.width = 2
        let bench = Bench(extra: [line])
        bench.store.selection = [bench.node("L")!.id]
        bench.step { bench.store.outlineBorders() }
        let n = try #require(bench.node("L"))
        #expect(n.kind == .path && n.fill.on && !n.border.on)
        #expect(near(n.frame.height, 2, within: 0.01))
    }
}
