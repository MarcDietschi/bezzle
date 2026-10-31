import Testing
import AppKit
@testable import Bezzle

/// Groups on the canvas: a click meeting what lies over a group the selection is in, and a group
/// whose layers are turned seen turned with them, its box and handles along the turn.
@MainActor
struct TurnedGroupTests {
    /// Artboard A with group "G" of "Left" at 0,0 and "Right" at 150,0 (each 100 × 100), and
    /// "Over" lying above the group across Left's lower right.
    private func bench() -> Bench {
        let left = Node(kind: .rectangle, name: "Left", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = Node(kind: .rectangle, name: "Right", frame: CGRect(x: 150, y: 0, width: 100, height: 100))
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 40, y: 40, width: 250, height: 100))
        group.children = [left, right]
        let over = Node(kind: .rectangle, name: "Over", frame: CGRect(x: 90, y: 90, width: 100, height: 100))
        return Bench(extra: [group, over])
    }

    /// A group of two upright rectangles, 200 × 80 and 60 × 60 beside it, turned by `turn` about its middle.
    private func turnedGroup(_ turn: Double) -> Node {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 100, y: 100, width: 280, height: 80))
        group.children = [Node(kind: .rectangle, name: "Wide", frame: CGRect(x: 0, y: 0, width: 200, height: 80)),
                          Node(kind: .rectangle, name: "Small", frame: CGRect(x: 220, y: 10, width: 60, height: 60))]
        // Its frame fitted round them afterwards, as every change in the app does.
        var doc = BezzleDocument()
        doc.nodes = [BezzleDocument.turned(group, by: turn, about: group.frame.center)]
        doc.fitGroups()
        return doc.nodes[0]
    }

    @Test func aClickOnWhatLiesOverTheGroupPicksIt() {
        let bench = bench()
        bench.store.selection = [bench.node("Left")!.id]
        // On Left and Over both, Over lying on top: A is at 100,100, Left at 140,140 to 240,240.
        bench.click(CGPoint(x: 220, y: 220))
        #expect(bench.store.selection == [bench.node("Over")!.id])
    }

    @Test func aClickInTheGroupStillPicksInsideIt() {
        let bench = bench()
        bench.store.selection = [bench.node("Left")!.id]
        bench.click(CGPoint(x: 330, y: 180))
        #expect(bench.store.selection == [bench.node("Right")!.id])
        // Where nothing lies over it, Left too.
        bench.click(CGPoint(x: 160, y: 160))
        #expect(bench.store.selection == [bench.node("Left")!.id])
    }

    @Test func anUprightGroupIsItsFrame() {
        let group = turnedGroup(0)
        #expect(BezzleDocument.turn(of: group) == 0)
        let (box, turn) = BezzleDocument.turnedBox(of: group)
        #expect(box == group.frame && turn == 0)
        // A quarter turn lies the same way: its frame, upright.
        #expect(BezzleDocument.turnedBox(of: turnedGroup(90)).rotation == 0)
    }

    @Test func aTurnedGroupIsSeenTurned() {
        let group = turnedGroup(30)
        let (box, turn) = BezzleDocument.turnedBox(of: group)
        #expect(abs(turn - 30) < 0.001)
        #expect(abs(box.width - 280) < 0.01 && abs(box.height - 80) < 0.01)
        #expect(abs(box.midX - 240) < 0.01 && abs(box.midY - 140) < 0.01)
        // Its largest layer leads: a small layer turned its own way does not turn the box.
        var mixed = group
        mixed.children[1].rotation = 70
        #expect(abs(BezzleDocument.turn(of: mixed) - 30) < 0.001)
    }

    @Test func stretchingATurnedGroupStretchesItAlongItsTurn() {
        let group = turnedGroup(30)
        let (box, turn) = BezzleDocument.turnedBox(of: group)
        let wider = CGRect(x: box.minX, y: box.minY, width: box.width * 2, height: box.height)
        let stretched = BezzleDocument.scaled(group, turned: turn, from: box, to: wider)
        let (after, still) = BezzleDocument.turnedBox(of: stretched)
        #expect(abs(still - 30) < 0.001)
        #expect(abs(after.width - 560) < 0.01 && abs(after.height - 80) < 0.01)
        #expect(stretched.children.allSatisfy { abs($0.rotation - 30) < 0.001 })
        #expect(abs(stretched.children[0].frame.width - 400) < 0.01)
    }

    @Test func aTurnedGroupsCornerHandleStretchesItOnTheCanvas() throws {
        let bench = Bench(extra: [turnedGroup(30)])
        let id = try #require(bench.node("G")).id
        bench.store.selection = [id]
        let (box, turn) = BezzleDocument.turnedBox(of: bench.store.node(id)!)
        let a = bench.a.frame.origin
        // The bottom right handle, pulled 40 points further along the box's own across and down.
        let corner = Geometry.point(CGPoint(x: 1, y: 1), of: box, rotation: turn) + a
        let along = Geometry.rotate(CGPoint(x: 40, y: 40), by: turn)
        bench.drag(corner, CGPoint(x: corner.x + along.x, y: corner.y + along.y))
        let (after, still) = BezzleDocument.turnedBox(of: bench.store.node(id)!)
        #expect(abs(still - 30) < 0.001)
        #expect(abs(after.width - 320) < 1 && abs(after.height - 120) < 1)
        // The corner across stays where it was.
        let fixed = Geometry.point(.zero, of: box, rotation: turn), now = Geometry.point(.zero, of: after, rotation: still)
        #expect(hypot(fixed.x - now.x, fixed.y - now.y) < 1)
    }
}
