import Testing
import AppKit
@testable import Bezzle

/// Animate's shapes: a path's points moved in time (its Shape) and its line drawn on (its Draw),
/// kept as changes from the design like every key, and drawn so in the film.
@MainActor
struct MotionPathTests {
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

    /// A path on the canvas through these points, its frame round them.
    private func path(_ data: String, name: String = "Path") -> Node {
        var n = Node.path(BezierPath(data), name: name)
        n.fill.on = true
        n.fill.color = .black
        return n
    }

    /// The outline a layer is drawn with, on its parent: what the renderer draws.
    private func drawn(_ n: Node) -> BezierPath {
        BezierPath(n.path ?? "").applying(n.pathPlacement)
    }

    // MARK: Changes of points

    @Test func anOutlineChangedAndBackIsTheSame() throws {
        let a = BezierPath("M 0 0 L 100 0 C 120 40 80 80 50 100 L 0 100 Z")
        var b = a
        b.subpaths[0].anchors[1].point = CGPoint(x: 140, y: -20)
        b.subpaths[0].anchors[2].handleIn = CGPoint(x: 70, y: 60)
        // A corner given a handle where it had none.
        b.subpaths[0].anchors[0].handleOut = CGPoint(x: 30, y: -30)
        let change = try #require(a.change(to: b))
        #expect(change.count == a.anchorCount * 6)
        #expect(a.changed(by: change) == b)
        #expect(a.changed(by: Array(repeating: 0, count: change.count)) == a)
        // Made for another outline: nothing.
        #expect(a.changed(by: [1, 2, 3]) == nil)
        #expect(a.change(to: BezierPath("M 0 0 L 10 0")) == nil)
    }

    @Test func aHandleBroughtBackOntoItsPointIsNone() throws {
        let a = BezierPath("M 0 0 C 0 40 100 40 100 0")
        var b = a
        b.subpaths[0].anchors[0].handleOut = CGPoint.zero
        let change = try #require(a.change(to: b))
        #expect(a.changed(by: change)?.subpaths[0].anchors[0].handleOut == nil)
    }

    // MARK: Posing a shape

    @Test func aShapePosedLaterLeavesTheDesignAtTheStart() throws {
        var n = path("M 100 100 L 200 100 L 150 180 Z")
        var outline = try #require(n.ownOutline)
        #expect(outline.anchorCount == 3)
        outline.subpaths[0].anchors[2].point.y += 60
        let posed = n.poseShape(outline, at: 1)
        #expect(posed)
        let keys = try #require(n[track: .shape]).keys
        #expect(keys.map(\.t) == [0, 1])
        #expect(keys[0].given == true && keys[0].v == Array(repeating: 0, count: 18))
        #expect(n.outline(at: 0) == n.ownOutline)
        #expect(n.outline(at: 1) == outline)
        // Halfway, on its way.
        let mid = try #require(n.outline(at: 0.5)).subpaths[0].anchors[2].point.y
        #expect(mid > 80 && mid < 140)
        // The bead at the start is hollow: as designed there.
        let marks = FilmRow.marks(of: n, [.shape])
        #expect(marks.map(\.home) == [true, false])
        // Posing it as designed makes nothing.
        var m = path("M 0 0 L 10 0 L 5 8 Z")
        let same = try #require(m.ownOutline)
        let still = m.poseShape(same, at: 1)
        #expect(still && m.motion == nil)
    }

    @Test func anOutlineWithOtherPointsIsAPoseTheKeyHoldsItself() throws {
        // More of it in `MotionOutlineKeyTests`.
        var n = path("M 0 0 L 100 0 L 50 80 Z")
        let square = BezierPath("M 0 0 L 100 0 L 100 100 L 0 100 Z")
        let posed = n.poseShape(square, at: 1)
        #expect(posed && n[track: .shape]?.keys.map(\.t) == [0, 1])
        #expect(n.outline(at: 1) == square && n.outline(at: 0) == n.ownOutline)
        #expect(n.ownOutline?.anchorCount == 3)
        var text = Node(kind: .text, name: "T", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        text.text = "Hi"
        let words = text.poseShape(BezierPath("M 0 0 L 1 1"), at: 1)
        #expect(!text.canReshape && !words)
    }

    @Test func atRestTheLayerIsDrawnAsDesigned() {
        var n = path("M 100 100 L 200 100 L 150 180 Z")
        n.setKey(.shape, n.shapeRest, at: 0)
        n.setKey(.draw, [0, 1], at: 0)
        #expect(n.reshapes)
        #expect(n.reshaped(at: 0) == n)
        #expect(n.posed(at: 0, own: false) == n)
    }

    @Test func movedPointsAreDrawnWhereTheyAreAndTheFrameHoldsThem() throws {
        var n = path("M 100 100 L 200 100 L 150 180 Z")
        n.rotation = 30
        var outline = try #require(n.ownOutline)
        // The top right corner pulled far out past the frame.
        outline.subpaths[0].anchors[1].point = CGPoint(x: 160, y: -40)
        n.poseShape(outline, at: 1)
        let posed = n.reshaped(at: 1)
        // Where the design's own points land, moved: through the design's frame and turn.
        let expected = outline.applying(n.placement)
        let got = drawn(posed)
        for (a, b) in zip(expected.anchorPoints, got.anchorPoints) { #expect(near(a, b), "\(a) \(b)") }
        // Its frame holds them all, so its picture does; the points that stay are where they were.
        #expect(near(got.anchorPoints[0], n.ownOutline!.applying(n.placement).anchorPoints[0]))
        let box = Geometry.corners(of: posed.frame, rotation: posed.rotation)
        let path = CGMutablePath()
        path.addLines(between: box)
        path.closeSubpath()
        for p in got.anchorPoints { #expect(path.contains(p) || box.contains { near($0, p, 0.05) } || Self.onEdge(p, box)) }
        #expect(posed.rotation == n.rotation)
    }

    /// Whether a point lies on the outline of a four cornered box, within a twentieth of a point.
    private static func onEdge(_ p: CGPoint, _ q: [CGPoint]) -> Bool {
        (0..<4).contains { Geometry.distance(from: p, toSegment: q[$0], q[($0 + 1) % 4]) < 0.05 }
    }

    @Test func aRectangleAndAnEllipseAreShapesToo() throws {
        var round = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(round.canReshape)
        var outline = try #require(round.ownOutline)
        #expect(outline.anchorCount == 4)
        outline.subpaths[0].anchors[0].point.x += 30
        round.poseShape(outline, at: 0.5)
        let posed = round.posed(at: 0.5, own: false)
        #expect(posed.kind == .path)
        #expect(round.kind == .ellipse)
        // Before its keys change anything it is the ellipse itself.
        #expect(round.posed(at: 0, own: false).kind == .ellipse)
        let square = Node(kind: .rectangle, name: "Box", frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(square.ownOutline?.anchorCount == 4)
    }

    @Test func keysForAnotherOutlineChangeNothing() {
        var n = path("M 0 0 L 100 0 L 50 80 Z")
        n.setKey(.shape, Array(repeating: 5, count: 6 * 4), at: 1)
        #expect(n.reshaped(at: 1) == n)
        #expect(n.outline(at: 1) == n.ownOutline)
    }

    @Test func aShapeThatGrowsAndTurnsDoesSoAboutTheDesignsMiddle() throws {
        var n = path("M 0 0 L 100 0 L 100 100 L 0 100 Z")
        var outline = try #require(n.ownOutline)
        // Only the bottom right corner moves, far out.
        outline.subpaths[0].anchors[2].point = CGPoint(x: 300, y: 300)
        n.poseShape(outline, at: 1)
        n.setKey(.turn, [90], at: 1)
        n.setKey(.scale, [2, 2], at: 1)
        let posed = n.posed(at: 1)
        let points = drawn(posed).anchorPoints
        // The top left corner, 50 left and up of the middle at 50,50: grown twice and turned a
        // quarter clockwise about that middle, it lies at 150,-50.
        #expect(near(points[0], CGPoint(x: 150, y: -50)), "\(points[0])")
        // The corner that moved, 250 right and down of it: at -450,550.
        #expect(near(points[2], CGPoint(x: -450, y: 550)), "\(points[2])")
    }

    // MARK: Drawing a line on

    @Test func partOfALineIsDrawnAsAPenDrawsIt() {
        let line = BezierPath("M 0 0 L 100 0 L 100 100")
        let half = line.trimmed(from: 0, to: 0.5)
        #expect(half.subpaths.count == 1)
        #expect(half.anchorPoints.count == 2)
        #expect(near(half.anchorPoints[1], CGPoint(x: 100, y: 0)))
        let middle = line.trimmed(from: 0.25, to: 0.75)
        #expect(near(middle.anchorPoints[0], CGPoint(x: 50, y: 0)))
        #expect(near(middle.anchorPoints[middle.anchorPoints.count - 1], CGPoint(x: 100, y: 50)))
        #expect(line.trimmed(from: 0, to: 1) == line)
        #expect(line.trimmed(from: 0.6, to: 0.6).subpaths.isEmpty)
        #expect(line.trimmed(from: 0.8, to: 0.2).subpaths.isEmpty)
    }

    @Test func runsAreDrawnOneAfterAnother() {
        // Two strokes of 100 each: by the time half is drawn, the first is whole and closed as it was.
        let two = BezierPath("M 0 0 L 50 0 L 50 50 Z M 200 0 L 300 0")
        let first = two.subpaths[0]
        let firstLength = 50 + 50 + 50 * 2.squareRoot()
        let whole = firstLength + 100
        let drawn = two.trimmed(from: 0, to: (firstLength + 50) / whole)
        #expect(drawn.subpaths.count == 2)
        #expect(drawn.subpaths[0] == first)
        #expect(near(drawn.subpaths[1].anchors[1].point, CGPoint(x: 250, y: 0)))
        // Less than the first: only part of it, open.
        let some = two.trimmed(from: 0, to: 25 / whole)
        #expect(some.subpaths.count == 1 && !some.subpaths[0].closed)
        #expect(near(some.anchorPoints[1], CGPoint(x: 25, y: 0)))
    }

    @Test func aCurveIsCutAlongItsLength() throws {
        // A half circle as two quarter curves: halfway along it is its top.
        let arc = BezierPath("M 0 0 C 0 -55.23 44.77 -100 100 -100 C 155.23 -100 200 -55.23 200 0")
        let half = arc.trimmed(from: 0, to: 0.5)
        #expect(near(try #require(half.anchorPoints.last), CGPoint(x: 100, y: -100), 0.5))
        let third = arc.trimmed(from: 0, to: 1.0 / 3)
        let end = try #require(third.anchorPoints.last)
        // A third of the way round a half circle is 60 degrees up from the start.
        #expect(near(end, CGPoint(x: 100 - 100 * cos(Double.pi / 3), y: -100 * sin(Double.pi / 3)), 1.5), "\(end)")
    }

    @Test func aLayerWithNothingDrawnShowsNothingAndHalfShowsHalf() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        board.fill.color = .white
        var stroke = path("M 10 20 L 90 20")
        stroke.fill.on = false
        stroke.border = Border(on: true, color: .black, width: 6, position: .center)
        stroke.setKey(.draw, [0, 0], at: 0)
        stroke.setKey(.draw, [0, 0.5], at: 1)
        board.children = [stroke.posed(at: 0)]
        let none = try #require(Renderer.image(of: board, scale: 1))
        #expect(Self.dark(none, 30, 20) == false && Self.dark(none, 70, 20) == false)
        board.children = [stroke.posed(at: 1)]
        let half = try #require(Renderer.image(of: board, scale: 1))
        #expect(Self.dark(half, 30, 20) && !Self.dark(half, 70, 20))
    }

    /// Whether a pixel is dark, read from the bytes as drawn.
    private static func dark(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        guard let ctx = Renderer.bitmap(CGSize(width: image.width, height: image.height)) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return bytes[y * ctx.bytesPerRow + x * 4] < 100
    }

    @Test func theDrawMoveDrawsShapesAndFadesWhatHasNoLine() {
        var line = path("M 0 0 L 100 0")
        line.apply(.draw, at: 0.2, frame: line.frame, board: CGSize(width: 400, height: 300))
        let keys = line[track: .draw]?.keys ?? []
        #expect(keys.map(\.t) == [0.2, 1.1])
        #expect(keys.map(\.v) == [[0, 0], [0, 1]])
        #expect(line[track: .fade] == nil)
        var text = Node(kind: .text, name: "T", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        text.text = "Hi"
        text.apply(.draw, at: 0, frame: text.frame, board: CGSize(width: 400, height: 300))
        #expect(text[track: .draw] == nil)
        #expect(text[track: .fade]?.keys.map(\.v) == [[0], [1]])
        // Going, the line is taken back to where it began.
        var going = path("M 0 0 L 100 0")
        going.apply(.draw, at: 1, going: true, frame: going.frame, board: CGSize(width: 400, height: 300))
        #expect(going[track: .draw]?.keys.map(\.v) == [[0, 1], [0, 0]])
    }

    // MARK: The film

    @Test func aShapeThatChangesIsAPieceDrawnAgainAsTimePasses() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var n = path("M 100 100 L 200 100 L 150 180 Z")
        var outline = try #require(n.ownOutline)
        outline.subpaths[0].anchors[2].point.y += 40
        n.poseShape(outline, at: 1)
        let still = path("M 0 0 L 10 0 L 5 8 Z", name: "Still")
        board.children = [still, n]
        let pieces = board.filmPieces()
        let piece = try #require(pieces.first { $0.layers == [n.id] })
        #expect(piece.changes)
        // Its corners in the film are its frame as grown to hold the moved point.
        let corners = try #require(board.filmCorners(of: n.id, at: 1, pieces: pieces))
        #expect(corners.map(\.y).max()! > 180 + 39)
        let atStart = try #require(board.filmCorners(of: n.id, at: 0, pieces: pieces))
        #expect(abs(atStart.map(\.y).max()! - 180) < 0.01)
    }

    @Test func theDrawPropertyHasItsNumbersInRange() {
        #expect(MotionProperty.draw.clamped([-1, 3]) == [0, 1])
        #expect(MotionProperty.draw.clamped([0.4]) == [0.4, 1])
        #expect(MotionProperty.shape.clamped([1, .nan, 3]) == [1, 0, 3])
        var n = path("M 0 0 L 100 0")
        #expect(n.value(of: .draw, at: 3) == [0, 1])
        #expect(n.value(of: .shape, at: 3) == Array(repeating: 0, count: 12))
        n.pose(.draw, [0, 0.3], at: 0)
        #expect(n[track: .draw]?.keys.map(\.v) == [[0, 0.3], [0, 1]])
        #expect(n.pose(at: 0).drawTo == 0.3)
    }

    @Test func theFilmShowsAShapesPointsWhereItsPoseAndTheCameraPutThem() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var n = path("M 100 100 L 200 100 L 150 180 Z")
        n.pose(.move, [30, -10], at: 1)
        board.children = [n]
        var pieces = board.filmPieces()
        // At rest, its own top left is where its frame's is; posed, moved as its key says.
        let still = try #require(board.filmPointMap(of: n.id, at: 0, pieces: pieces))
        #expect(near(still(.zero), CGPoint(x: 100, y: 100)))
        let moved = try #require(board.filmPointMap(of: n.id, at: 1, pieces: pieces))
        #expect(near(moved(.zero), CGPoint(x: 130, y: 90)))
        // The camera closer, twice: about the artboard's middle.
        board.setKey(.cameraZoom, [2], at: 0)
        pieces = board.filmPieces()
        let close = try #require(board.filmPointMap(of: n.id, at: 0, pieces: pieces))
        #expect(near(close(.zero), CGPoint(x: 200 + (100 - 200) * 2, y: 150 + (100 - 150) * 2)))
        // And back from where it shows to its own points.
        let p = CGPoint(x: 37, y: 12)
        let back = try #require(close.back(close(p)))
        #expect(near(back, p))
    }

    @Test func insideAGroupThatIsDrawnWholeItsPointsAreWhereThePoseOfBothPutsThem() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var inner = path("M 20 20 L 60 20 L 40 60 Z", name: "Inner")
        inner.setKey(.move, [10, 0], at: 1)
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 100, y: 100, width: 100, height: 100))
        group.opacity = 0.5
        group.children = [inner]
        group.setKey(.move, [0, 50], at: 1)
        board.children = [group]
        let pieces = board.filmPieces()
        // Faded as a whole, the group is one piece, drawn again as what it holds moves.
        #expect(pieces.contains { $0.layers == [group.id] && $0.changes })
        let map = try #require(board.filmPointMap(of: inner.id, at: 1, pieces: pieces))
        #expect(near(map(.zero), CGPoint(x: 100 + 20 + 10, y: 100 + 20 + 50)))
    }

    // MARK: When the design's points change

    @Test func keysGoWithTheirPointsWhenTheDesignGainsOrLosesOne() throws {
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var n = path("M 100 100 L 200 100 L 200 200 L 100 200 Z")
        var outline = try #require(n.ownOutline)
        // The third point, the bottom right, goes 50 down at one second.
        outline.subpaths[0].anchors[2].point.y += 50
        n.poseShape(outline, at: 1)
        board.children = [n]
        var doc = BezzleDocument()
        doc.nodes = [board]
        // A point added on the top side, between the first and the second.
        var points = try #require(doc.points(of: n.id))
        points.insert(0, segment: 0, t: 0.5)
        doc.setPoints(points, of: n.id)
        var after = try #require(doc.node(n.id))
        #expect(after.ownOutline?.anchorCount == 5)
        var moved = try #require(after.outline(at: 1)).anchorPoints
        var design = try #require(after.ownOutline).anchorPoints
        // Still the bottom right that moves, now the fourth point.
        #expect(near(moved[3], CGPoint(x: design[3].x, y: design[3].y + 50)))
        #expect(near(moved[1], design[1]) && near(moved[2], design[2]))
        // The first point taken away: the bottom right, now the third, still moves.
        points = try #require(doc.points(of: n.id))
        points.remove([PathPoint(subpath: 0, index: 0)])
        doc.setPoints(points, of: n.id)
        after = try #require(doc.node(n.id))
        moved = try #require(after.outline(at: 1)).anchorPoints
        design = try #require(after.ownOutline).anchorPoints
        #expect(design.count == 4)
        #expect(near(moved[2], CGPoint(x: design[2].x, y: design[2].y + 50)))
        // A point dragged in the design keeps its own change.
        points = try #require(doc.points(of: n.id))
        points.subpaths[0].anchors[2].point.x += 20
        doc.setPoints(points, of: n.id)
        after = try #require(doc.node(n.id))
        moved = try #require(after.outline(at: 1)).anchorPoints
        design = try #require(after.ownOutline).anchorPoints
        #expect(near(moved[2], CGPoint(x: design[2].x, y: design[2].y + 50)))
    }

    @Test func shapeKeysAreSharedKeyByKeyAndSettledLikeAnyOther() throws {
        var n = path("M 0 0 L 100 0 L 50 80 Z")
        // Two people's keys a few thousandths apart, as changes put together can leave them.
        n[track: .shape] = MotionTrack([MotionKey(t: 1, v: Array(repeating: 1, count: 18)), MotionKey(t: 1.003, v: Array(repeating: 2, count: 18))])
        var doc = BezzleDocument()
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [n]
        doc.nodes = [board]
        doc.repairMotion()
        #expect(doc.node(n.id)?[track: .shape]?.keys.count == 1)
    }
}
