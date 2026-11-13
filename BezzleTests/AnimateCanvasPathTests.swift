import Testing
import AppKit
@testable import Bezzle

/// Animate's canvas with a shape's points in hand: taken up with a double click or Return,
/// dragged to pose its Shape at the playhead, only moved, never added or taken away, and put
/// down again; the design's outline untouched throughout.
@MainActor
struct AnimateCanvasPathTests {
    /// On artboard A: a triangle, its tip at the bottom, and a card well away from it.
    static var layers: [Node] {
        var triangle = Node.path(BezierPath("M 100 60 L 200 60 L 150 140 Z"), name: "Tri")
        triangle.fill.on = true
        return [triangle, CanvasTests.rect("Card", CGRect(x: 280, y: 200, width: 80, height: 60))]
    }

    private func near(_ a: CGPoint?, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < e && abs(a.y - b.y) < e
    }

    /// The film with the triangle's points in hand at one second.
    private func inHand() -> FilmBench {
        let film = FilmBench(Self.layers)
        film.store.seek(1)
        film.click(film.view(150, 80))
        film.click(film.view(150, 80), clicks: 2)
        return film
    }

    @Test func aDoubleClickOnAShapeTakesItsPointsInHandAndADragPosesItsShape() throws {
        let film = inHand()
        #expect(film.store.editingPath == film.id("Tri"))
        let design = film.design
        film.fresh()
        // Its tip pulled 60 points lower, Command held so that nothing catches.
        film.drag(film.view(150, 140), film.view(150, 200), flags: [.command])
        let keys = film.keys("Tri", .shape)
        #expect(keys.map(\.t) == [0, 1])
        #expect(keys.first?.given == true)
        let tri = film.node("Tri")
        let moved = try #require(tri.outline(at: 1)).anchorPoints
        let was = try #require(tri.ownOutline).anchorPoints
        #expect(near(moved[2], CGPoint(x: was[2].x, y: was[2].y + 60)), "\(moved[2])")
        #expect(near(moved[0], was[0]) && near(moved[1], was[1]))
        // The points show where the film has them now.
        let shown = try #require(film.tool.points.pen.overlay().anchors.map(\.point))
        #expect(near(shown[2], CGPoint(x: 100 + 150, y: 100 + 200)), "\(shown)")
        // The design is as it was, and one undo takes the pose back.
        #expect(film.design == design)
        #expect(film.undo.undoActionName == String(localized: "Move Points"))
        film.undo.undo()
        #expect(film.node("Tri").motion == nil)
    }

    @Test func pointsAreOnlyMovedHereNeverAddedOrTakenAway() throws {
        let film = inHand()
        film.fresh()
        // A click on the outline, halfway along the top, adds nothing.
        film.click(film.view(150, 60))
        #expect(film.node("Tri").motion == nil)
        #expect(film.node("Tri").ownOutline?.anchorCount == 3)
        // A point picked and Delete pressed takes nothing away.
        film.click(film.view(100, 60))
        #expect(film.store.selectedPoints.count == 1)
        film.key(51)
        #expect(film.node("Tri").ownOutline?.anchorCount == 3)
        #expect(film.node("Tri").motion == nil)
        // The arrows move the picked point, a key at the playhead.
        film.arrow(124, flags: [.shift])
        let moved = try #require(film.node("Tri").outline(at: 1)).anchorPoints[0]
        let was = try #require(film.node("Tri").ownOutline).anchorPoints[0]
        #expect(near(moved, CGPoint(x: was.x + 10, y: was.y)), "\(moved)")
    }

    @Test func returnAndEscapePutThePointsDownAndLeavingAnimateDoesToo() {
        let film = inHand()
        // In hand, Return puts them down rather than playing the film.
        film.key(36, "\r")
        #expect(film.store.editingPath == nil)
        #expect(!film.store.film.playing)
        // Picked and not in hand, Return plays the film, as on anything here.
        film.key(36, "\r")
        #expect(film.store.film.playing && film.store.editingPath == nil)
        film.store.pauseFilm()
        // Escape puts them down too.
        film.click(film.view(150, 80), clicks: 2)
        #expect(film.store.editingPath == film.id("Tri"))
        film.key(53)
        #expect(film.store.editingPath == nil)
        // A card's points are taken up the same way: its outline is points too.
        film.click(film.view(320, 230))
        film.click(film.view(320, 230), clicks: 2)
        #expect(film.store.editingPath == film.id("Card"))
        // Leaving Animate puts them down.
        film.store.show(.design)
        #expect(film.store.editingPath == nil)
    }

    @Test func aRectanglesPointsPoseItsShapeAndItStaysARectangle() throws {
        let film = FilmBench(Self.layers)
        film.store.seek(0.5)
        film.click(film.view(320, 230))
        film.click(film.view(320, 230), clicks: 2)
        #expect(film.store.editingPath == film.id("Card"))
        // Its top right corner pulled up and out.
        film.drag(film.view(360, 200), film.view(380, 180), flags: [.command])
        let card = film.node("Card")
        #expect(card.kind == .rectangle)
        #expect(card[track: .shape]?.keys.count == 2)
        let corner = try #require(card.outline(at: 0.5)).anchorPoints[1]
        #expect(near(corner, CGPoint(x: 100, y: -20)), "\(corner)")
        // A double click off its points puts them down.
        film.click(film.view(20, 280), clicks: 2)
        #expect(film.store.editingPath == nil)
    }

    @Test func pointsShowWhereTheCameraSeesThem() throws {
        let film = inHand()
        // The camera twice as close, on the triangle's tip.
        film.edit { doc in
            guard let board = doc.nodes.first?.id else { return }
            doc.update(board) { b in
                b.setKey(.cameraZoom, [2], at: 0)
                b.setKey(.cameraMove, [150 - 200, 140 - 150], at: 0)
            }
        }
        let shown = try #require(film.tool.points.pen.overlay().anchors.map(\.point))
        // The tip is in the film's middle, which on the canvas is the artboard's.
        #expect(near(shown[2], CGPoint(x: 100 + 200, y: 100 + 150)), "\(shown)")
        film.fresh()
        film.drag(film.view(200, 150), film.view(200, 170), flags: [.command])
        // Twenty points on screen at twice as close is ten on the artboard.
        let moved = try #require(film.node("Tri").outline(at: 1)).anchorPoints[2]
        #expect(near(moved, CGPoint(x: 50, y: 90), 0.05), "\(moved)")
    }
}
