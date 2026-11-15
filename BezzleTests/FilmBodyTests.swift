import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// Several layers lying together posed as one body at a moment of their film (`FilmBody`,
/// `poseBody`): the box round them along their lead's sides, a turn in the plane of the lead's
/// face about the box's middle, and growing about it, each layer keyed where a real body's face
/// would go, worked out by hand; and a drag measured from where it began leaves nothing behind.
@MainActor
struct FilmBodyTests {
    private func card(_ name: String, _ frame: CGRect, turn: Transform3D? = nil, rotation: Double = 0) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        n.transform3D = turn
        n.rotation = rotation
        return n
    }

    /// An artboard holding a card (40, 40, 120 by 80), a badge (240, 180, 60 by 40) and a group
    /// with a dot and a bar in it.
    private func design(card c: Transform3D? = nil, badge b: Transform3D? = nil, badgeRotation: Double = 0) -> BezzleDocument {
        var row = Node(kind: .group, name: "Row", frame: CGRect(x: 200, y: 20, width: 160, height: 100))
        row.children = [card("Dot", CGRect(x: 0, y: 0, width: 40, height: 40)), card("Bar", CGRect(x: 60, y: 50, width: 100, height: 50))]
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        board.children = [card("Card", CGRect(x: 40, y: 40, width: 120, height: 80), turn: c),
                          card("Badge", CGRect(x: 240, y: 180, width: 60, height: 40), turn: b, rotation: badgeRotation), row]
        var doc = BezzleDocument()
        doc.nodes = [board, card("Loose", CGRect(x: 900, y: 0, width: 50, height: 50))]
        return doc
    }

    private func id(_ doc: BezzleDocument, _ name: String) -> UUID { doc.allNodes.first { $0.name == name }!.id }
    private func value(_ doc: BezzleDocument, _ name: String, _ p: MotionProperty, at t: Double = 1) -> [Double] {
        doc.node(id(doc, name))!.value(of: p, at: t)
    }
    private func near(_ a: [Double], _ b: [Double], _ e: Double = 1e-6) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= e } }
    private func near(_ a: ScenePoint, _ b: ScenePoint, _ e: Double = 1e-6) -> Bool {
        abs(a.x - b.x) <= e && abs(a.y - b.y) <= e && abs(a.z - b.z) <= e
    }

    @Test func severalLyingTogetherAreABodyAndTheBoxRoundThemIsAlongTheirLeadsSides() throws {
        let doc = design()
        let ids = [id(doc, "Card"), id(doc, "Badge")]
        let body = try #require(doc.filmBody(of: ids, at: 1))
        #expect(body.ids == ids && body.layers[body.lead].name == "Card")
        #expect(near(body.low, ScenePoint(x: 40, y: 40)) && near(body.high, ScenePoint(x: 300, y: 220)))
        #expect(near(body.pivot, ScenePoint(x: 170, y: 130)))
        // In the card's own points, its top left at nothing.
        #expect(body.outline == [CGPoint(x: 0, y: 0), CGPoint(x: 260, y: 0), CGPoint(x: 260, y: 180), CGPoint(x: 0, y: 180)])
        // One layer, layers lying apart, and one off any artboard are none.
        #expect(doc.filmBody(of: [ids[0]], at: 1) == nil)
        #expect(doc.filmBody(of: [ids[0], id(doc, "Dot")], at: 1) == nil)
        #expect(doc.filmBody(of: [id(doc, "Loose"), ids[0]], at: 1) == nil)
        // A group's two are one, measured in the group.
        let row = try #require(doc.filmBody(of: [id(doc, "Dot"), id(doc, "Bar")], at: 1))
        #expect(near(row.low, ScenePoint(x: 0, y: 0)) && near(row.high, ScenePoint(x: 160, y: 100)))
    }

    @Test func aBodyIsMeasuredAsItStandsAtTheMoment() throws {
        var doc = design()
        let card = id(doc, "Card")
        doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [-20, 10], at: 1); $0.setKey(.scale, [2, 2], at: 1) }
        let body = try #require(doc.filmBody(of: [card, id(doc, "Badge")], at: 1))
        // The card, moved and twice as big, from (-40, 10) to (200, 170); the badge as designed.
        #expect(near(body.low, ScenePoint(x: -40, y: 10)) && near(body.high, ScenePoint(x: 300, y: 220)))
        // Its outline in the card's own points, as designed: half as far, since it shows twice as big.
        #expect(body.outline[0] == CGPoint(x: 0, y: 0) && body.outline[2] == CGPoint(x: 170, y: 105))
    }

    @Test func aFlatBodyTurnsAboutTheMiddleOfTheBoxRoundIt() throws {
        var doc = design()
        let ids = [id(doc, "Card"), id(doc, "Badge")]
        doc.poseBody(ids, turnedBy: 30, at: 1)
        #expect(value(doc, "Card", .turn) == [30] && near(value(doc, "Badge", .turn), [30]))
        func round(_ p: CGPoint) -> [Double] {
            let to = Geometry.rotated(p, about: CGPoint(x: 170, y: 130), by: 30)
            return [Double(to.x - p.x), Double(to.y - p.y)]
        }
        #expect(near(value(doc, "Card", .move), round(CGPoint(x: 100, y: 80))))
        #expect(near(value(doc, "Badge", .move), round(CGPoint(x: 270, y: 200))))
        // Flat, it stays flat: no key says otherwise.
        for name in ["Card", "Badge"] {
            let n = doc.node(id(doc, name))!
            #expect(Set(n.motionProperties) == [.turn, .move], "\(name)")
            // The first key a property is given comes with the design for company.
            #expect(n[track: .turn]?.keys.first == MotionKey(t: 0, v: [0], given: true))
        }
    }

    @Test func aBodyTurnedInDepthTurnsInItsLeadsPlaneAndStaysWhole() throws {
        let tipped = Transform3D(x: 20, y: -35, z: 10)
        var doc = design(card: tipped, badge: tipped)
        let ids = [id(doc, "Card"), id(doc, "Badge")]
        // Already lifted and turned a little at the moment, by keys.
        doc.update(ids[1]) { $0.setKey(.lift, [15], at: 1); $0.setKey(.turn, [10], at: 1) }
        let before = try #require(doc.filmBody(of: ids, at: 1))
        doc.poseBody(ids, turnedBy: -25, at: 1)
        let after = try #require(doc.filmBody(of: ids, at: 1))
        // The lead turns in its own plane by exactly that, and faces the way it did.
        #expect(value(doc, "Card", .turn) == [-25])
        #expect(doc.node(ids[0])?[track: .tilt] == nil && doc.node(ids[0])?[track: .swing] == nil)
        #expect(DepthBody.facesOneWay(after.standing))
        // A turn about the same middle: the box round it as big, along the lead's turned sides.
        #expect(near(after.pivot, before.pivot))
        #expect(near(after.high - after.low, before.high - before.low))
        // The badge stands where the body carries it, a turn round the lead's face.
        let spin = before.sides.after(.turn(-25)).after(before.sides.back)
        let carried = before.pivot + spin(DepthBody.middle(of: before.standing[1]) - before.pivot)
        #expect(near(DepthBody.middle(of: after.standing[1]), carried))
    }

    @Test func aBodyGrowsAboutItsMiddleEvenlyOrOneWay() throws {
        var doc = design(badgeRotation: 90)
        let ids = [id(doc, "Card"), id(doc, "Badge")]
        // The badge, turned upright, stands thirty over the page.
        doc.update(ids[1]) { $0.setKey(.lift, [30], at: 1) }
        var even = doc
        even.poseBody(ids, grownBy: 1.5, 1.5, at: 1)
        #expect(value(even, "Card", .scale) == [1.5, 1.5] && near(value(even, "Badge", .scale), [1.5, 1.5]))
        // The box round them, turned badge and all, is (40, 40) to (290, 230): its middle (165, 135).
        // The card's middle (100, 80) to (67.5, 52.5); the badge's (270, 200) to (322.5, 232.5).
        #expect(near(value(even, "Card", .move), [-32.5, -27.5]))
        #expect(near(value(even, "Badge", .move), [52.5, 32.5]))
        // Grown evenly, it stands half as far again off the card's plane.
        #expect(near(value(even, "Badge", .lift), [45]))
        // One way, across: the card wider; the badge, which runs down the page, taller; and
        // as high as it was.
        var across = doc
        across.poseBody(ids, grownBy: 2, 1, at: 1)
        #expect(value(across, "Card", .scale) == [2, 1] && near(value(across, "Badge", .scale), [1, 2]))
        // Its middle twice as far across from 165, and as far down.
        #expect(near(value(across, "Badge", .move), [105, 0]))
        #expect(near(value(across, "Badge", .lift), [30]))
    }

    @Test func measuredFromWhereADragBeganNothingIsLeftBehind() {
        let doc = design()
        let ids = [id(doc, "Card"), id(doc, "Badge")]
        // Many steps of one drag, each from the design as it began, are the last step alone.
        var dragged = doc
        for degrees in [10.0, 40, 75, 12] { dragged.poseBody(ids, turnedBy: degrees, at: 1, from: doc) }
        var once = doc
        once.poseBody(ids, turnedBy: 12, at: 1)
        #expect(dragged == once)
        // Back to where it began: the lead's turn says so, and nothing else is keyed.
        dragged.poseBody(ids, turnedBy: 0, at: 1, from: doc)
        #expect(dragged == doc)
        for k in [1.8, 0.4, 1.0] { dragged.poseBody(ids, grownBy: k, k, at: 1, from: doc) }
        #expect(dragged.node(ids[1])?.motion == nil)
        #expect(dragged.node(ids[0])?[track: .move] == nil)
    }
}
