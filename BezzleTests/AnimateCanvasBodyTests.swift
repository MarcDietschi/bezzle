import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas, several layers picked that lie together: one body at the playhead
/// (`FilmBody`), with one set of handles round it that grow it, turn it and tip it in depth as
/// one, each a single step, keyed as the Pose card keys a body. The bench is in
/// `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    /// The card and the badge picked together, the playhead a second in, nothing to undo yet.
    private func both(_ f: FilmBench) {
        f.click(f.middle("Card"))
        f.click(f.middle("Badge"), flags: .shift)
        f.store.seek(1)
        f.fresh()
    }

    /// The box round the body, as its handles show it.
    private func outline(_ f: FilmBench) -> [CGPoint] { f.tool.body(f.scene)?.outline.map(f.scene.toView) ?? [] }

    /// Every key of every layer, as numbers to compare within a little.
    private func keys(_ f: FilmBench, _ doc: BezzleDocument, _ names: [String]) -> [String: [MotionKey]] {
        var out: [String: [MotionKey]] = [:]
        for name in names {
            let n = doc.node(f.id(name))
            for p in MotionProperty.layer { if let track = n?[track: p] { out["\(name).\(p)"] = track.keys } }
        }
        return out
    }

    private func alike(_ a: [String: [MotionKey]], _ b: [String: [MotionKey]], within e: Double = 1e-6) -> Bool {
        guard Set(a.keys) == Set(b.keys) else { return false }
        return a.allSatisfy { name, keys in
            guard let other = b[name], other.count == keys.count else { return false }
            return zip(keys, other).allSatisfy { $0.t == $1.t && $0.given == $1.given && closeBy($0.v, $1.v, within: e) }
        }
    }

    // MARK: Its handles

    @Test(arguments: FilmView.allCases) func severalLyingTogetherShowOneSetOfHandlesRoundTheirBody(_ view: FilmView) {
        let f = FilmBench(view: view)
        both(f)
        // The box round the card (40, 40, 120 by 80) and the badge (240, 180, 60 by 40).
        let q = outline(f)
        let box = [f.view(40, 40), f.view(300, 40), f.view(300, 220), f.view(40, 220)]
        #expect(q.count == 4 && zip(q, box).allSatisfy { closeBy($0, $1) }, "\(q)")
        let c = FilmBench.middle(q)
        // Each grip has its own pointer, as one layer's do.
        let corner = f.tool.cursor(at: q[2]), side = f.tool.cursor(at: FilmBench.side(q, 1))
        let turn = f.tool.cursor(at: FilmBench.out(q[2], from: c, by: 12))
        let depth = f.tool.cursor(at: FilmBench.out(FilmBench.side(q, 0), from: c, by: 17))
        #expect(corner != NSCursor.arrow && side != NSCursor.arrow && turn != NSCursor.arrow && turn != corner)
        #expect(depth == Cursors.turn)
        f.hover(q[2])
        f.draw()
        // One layer alone has its own handles, and none round a body.
        f.click(f.view(350, 260))
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")] && f.tool.body(f.scene) == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func layersLyingApartOrTheCameraHaveNoBody() {
        let f = FilmBench(FilmBench.cardAndBadge + [FilmBench.row])
        // The card on the artboard and the dot in the row lie in two places.
        f.store.selection = [f.id("Card"), f.id("Dot")]
        #expect(f.tool.body(f.scene) == nil)
        // The dot and the bar lie together in the row: a body.
        f.store.selection = [f.id("Dot"), f.id("Bar")]
        let q = outline(f)
        #expect(q.count == 4 && closeBy(q[0], f.view(200, 20)) && closeBy(q[2], f.view(360, 120)), "\(q)")
        f.click(f.chip)
        #expect(f.store.film.camera && f.tool.body(f.scene) == nil)
    }

    // MARK: Tipping in depth

    @Test(arguments: FilmView.allCases) func fromBesideItsSidesABodyTipsAndSwingsAsThePoseCardDoes(_ view: FilmView) {
        let f = FilmBench(view: view)
        both(f)
        let design = f.design
        let ids = [f.id("Card"), f.id("Badge")]
        var start = f.store.doc
        // The top pushed down fifty points of the screen tips the body thirty degrees back, as
        // Tilt in the Pose card does for both.
        var q = outline(f)
        var grip = FilmBench.out(FilmBench.side(q, 0), from: FilmBench.middle(q), by: 17)
        f.drag(grip, grip + point(0, 50))
        var card = start
        card.poseInDepth(.tilt, of: ids, at: 1) { _ in 30 }
        #expect(alike(keys(f, f.store.doc, ["Card", "Badge"]), keys(f, card, ["Card", "Badge"])))
        #expect(f.value("Card", .tilt) == [30])
        // The badge, below the middle the body turns about, is carried with it: up the page and
        // nearer, as the body's foot comes toward the eye.
        #expect(f.value("Badge", .tilt) == [30] && f.value("Badge", .lift)[0] > 1 && f.value("Badge", .move)[1] < -1)
        #expect(f.design == design)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // One step.
        f.undo.undo()
        #expect(f.node("Card").motion == nil && f.node("Badge").motion == nil)
        #expect(!f.undo.canUndo)
        f.undo.redo()
        // The right side pushed left swings it, its lead's swing as the card would make it.
        start = f.store.doc
        q = outline(f)
        grip = FilmBench.out(FilmBench.side(q, 1), from: FilmBench.middle(q), by: 17)
        f.drag(grip, grip + point(-40, 0))
        card = start
        card.poseInDepth(.swing, of: ids, at: 1) { _ in 24 }
        #expect(alike(keys(f, f.store.doc, ["Card", "Badge"]), keys(f, card, ["Card", "Badge"])))
        #expect(f.value("Card", .swing) == [24])
        #expect(f.design == design)
    }

    // MARK: Turning

    @Test(arguments: FilmView.allCases) func fromJustOutsideACornerABodyTurnsAboutItsMiddle(_ view: FilmView) {
        let f = FilmBench(view: view)
        both(f)
        let design = f.design
        let q = outline(f), c = FilmBench.middle(q)
        let grip = FilmBench.out(q[2], from: c, by: 12)
        f.drag(grip, Geometry.rotated(grip, about: c, by: 30))
        // Both turn thirty degrees, and go round the box's middle (170, 130) with it.
        #expect(f.value("Card", .turn) == [30] && closeBy(f.value("Badge", .turn), [30]))
        func round(_ p: CGPoint) -> [Double] {
            let to = Geometry.rotated(p, about: CGPoint(x: 170, y: 130), by: 30)
            return [Double(to.x - p.x), Double(to.y - p.y)]
        }
        #expect(closeBy(f.value("Card", .move), round(CGPoint(x: 100, y: 80))))
        #expect(closeBy(f.value("Badge", .move), round(CGPoint(x: 270, y: 200))))
        // Lying flat, it stays flat.
        #expect(f.node("Card")[track: .tilt] == nil && f.node("Badge")[track: .lift] == nil)
        #expect(f.design == design)
        f.store.pauseFilm()
        // The corner in hand went round with the pointer.
        #expect(closeBy(outline(f)[2], Geometry.rotated(q[2], about: c, by: 30)))
        f.undo.undo()
        #expect(f.node("Card").motion == nil && f.node("Badge").motion == nil)
        #expect(!f.undo.canUndo)
        // With Shift, by fifteen degrees at a time; past where it began, the other way.
        f.drag(grip, Geometry.rotated(grip, about: c, by: -40), pulling: .shift)
        #expect(f.value("Card", .turn) == [-45] && closeBy(f.value("Badge", .turn), [-45]))
    }

    @Test func aBodyTurnedInDepthTurnsInThePlaneOfItsLeadAndStaysWhole() throws {
        var tipped = FilmBench.cardAndBadge
        tipped[0].transform3D = Transform3D(x: 20, y: -35, z: 10)
        tipped[1].transform3D = Transform3D(x: 20, y: -35, z: 10)
        let f = FilmBench(tipped)
        both(f)
        let before = try #require(f.store.doc.filmBody(of: [f.id("Card"), f.id("Badge")], at: 1))
        let q = outline(f), c = FilmBench.middle(q)
        let grip = FilmBench.out(q[1], from: c, by: 12)
        f.drag(grip, Geometry.rotated(grip, about: c, by: 25))
        let after = try #require(f.store.doc.filmBody(of: [f.id("Card"), f.id("Badge")], at: 1))
        // The lead turns in its own plane and keeps facing the way it faced.
        #expect(f.value("Card", .tilt) == [0] || f.node("Card")[track: .tilt] == nil)
        #expect(f.node("Card")[track: .swing] == nil)
        let turn = try #require(f.value("Card", .turn).first)
        #expect(turn != 0)
        // About the same middle, and the same box round it: a turn, nothing stretched or moved.
        let a = before.pivot, b = after.pivot
        #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.z - b.z) < 1e-6)
        for (x, y) in [(before.high.x - before.low.x, after.high.x - after.low.x), (before.high.y - before.low.y, after.high.y - after.low.y),
                       (before.high.z - before.low.z, after.high.z - after.low.z)] {
            #expect(abs(x - y) < 1e-6)
        }
        // The badge faces as the card does still.
        let card = after.standing[after.lead], badge = after.standing[1 - after.lead]
        #expect(DepthBody.facesOneWay([card, badge]))
    }

    // MARK: Growing

    @Test(arguments: FilmView.allCases) func aBodyGrowsAboutItsMiddleByACornerAndOneWayByASide(_ view: FilmView) {
        let f = FilmBench(view: view)
        both(f)
        let design = f.design
        var q = outline(f)
        let c = FilmBench.middle(q)
        f.drag(q[2], FilmBench.scaled(q[2], from: c, 1.5))
        #expect(f.value("Card", .scale) == [1.5, 1.5] && closeBy(f.value("Badge", .scale), [1.5, 1.5]))
        // Each stands half as far again from the box's middle (170, 130).
        #expect(closeBy(f.value("Card", .move), [-35, -25]))
        #expect(closeBy(f.value("Badge", .move), [50, 35]))
        #expect(f.design == design)
        f.store.pauseFilm()
        #expect(closeBy(outline(f)[2], FilmBench.scaled(q[2], from: c, 1.5)))
        f.undo.undo()
        #expect(f.node("Card").motion == nil && f.node("Badge").motion == nil)
        #expect(!f.undo.canUndo)
        // The right side, half as far out again: wider, no taller, and apart only across.
        q = outline(f)
        let side = FilmBench.side(q, 1)
        f.drag(side, FilmBench.scaled(side, from: c, 1.5))
        #expect(f.value("Card", .scale) == [1.5, 1] && closeBy(f.value("Badge", .scale), [1.5, 1]))
        #expect(closeBy(f.value("Card", .move), [-35, 0]))
        #expect(closeBy(f.value("Badge", .move), [50, 0]))
        // Its own size catches, as one layer's does.
        f.store.pauseFilm()
        q = outline(f)
        f.drag(q[2], FilmBench.scaled(q[2], from: FilmBench.middle(q), 1.0 / 1.5 * 1.02))
        #expect(f.value("Card", .scale)[0] == 1)
        #expect(f.design == design)
    }

    // MARK: Escape, and one layer as it was

    @Test func escapeDuringABodysDragPutsEverythingBack() {
        let f = FilmBench()
        both(f)
        let before = f.store.doc
        let q = outline(f), c = FilmBench.middle(q)
        let hands: [(from: CGPoint, to: CGPoint)] = [
            (q[2], FilmBench.scaled(q[2], from: c, 1.4)),
            (FilmBench.side(q, 1), FilmBench.scaled(FilmBench.side(q, 1), from: c, 1.4)),
            (FilmBench.out(q[2], from: c, by: 12), Geometry.rotated(FilmBench.out(q[2], from: c, by: 12), about: c, by: 30)),
            (FilmBench.out(FilmBench.side(q, 0), from: c, by: 17), FilmBench.out(FilmBench.side(q, 0), from: c, by: 17) + point(0, 50)),
        ]
        for (i, hand) in hands.enumerated() {
            f.press(hand.from)
            f.pull(to: FilmBench.scaled(hand.to, from: hand.from, 0.5))
            f.pull(to: hand.to)
            #expect(f.node("Card").motion != nil && f.node("Badge").motion != nil, "hand \(i)")
            #expect(f.tool.dragging && f.store.inGesture)
            f.key(53)
            #expect(f.store.doc == before, "hand \(i)")
            f.letGo(at: hand.to)
            #expect(f.store.doc == before && !f.undo.canUndo && !f.store.film.playing, "hand \(i)")
            #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        }
    }

    @Test func aBodyDraggedBackToWhereItBeganLeavesNothing() {
        let f = FilmBench()
        both(f)
        let before = f.store.doc
        let q = outline(f), c = FilmBench.middle(q)
        let grip = FilmBench.out(q[2], from: c, by: 12)
        f.press(grip)
        f.pull(to: Geometry.rotated(grip, about: c, by: 40))
        f.pull(to: Geometry.rotated(grip, about: c, by: 0.4))
        f.letGo(at: Geometry.rotated(grip, about: c, by: 0.4))
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.store.film.playing)
    }
}
