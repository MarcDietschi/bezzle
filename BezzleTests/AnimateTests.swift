import Testing
import AppKit
@testable import Bezzle

/// Animate as it is used: the mode itself, layers posed by hand on the canvas, the camera, the
/// keys in the timeline taken by the pointer, and the moves made in one go. The film's own
/// arithmetic is in `MotionTests`.
@MainActor
struct AnimateTests {
    /// On artboard A (at 100,100, 400 by 300): a card top left and a badge lower right.
    let bench = Bench(extra: [
        CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
        CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40)),
    ])
    var store: DocumentStore { bench.store }

    /// The middle of a layer on the canvas, as designed.
    private func middle(_ name: String) -> CGPoint {
        let f = store.doc.absoluteFrame(of: bench.node(name)!.id)!
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func animate() {
        store.show(.animate)
        // The view's glide to the film's artboard is no part of what is tested here.
        store.glide.stop()
        store.viewport = Viewport(origin: .zero, zoom: 1)
    }

    /// A change to the design made behind the scenes, as its own step.
    private func edit(_ change: (inout BezzleDocument) -> Void) {
        bench.step { store.edit("Add Key", change) }
    }

    private func keys(_ name: String, _ property: MotionProperty) -> [MotionKey] {
        bench.node(name)?[track: property]?.keys ?? []
    }

    /// The timeline's lines and its scale, 600 points wide, as the card would lay them out.
    private var sheet: (rows: [FilmRow], scale: FilmScale, length: Double) {
        let board = store.filmBoard!
        return (FilmRow.rows(of: board, open: store.film.open), FilmScale(width: 600, span: FilmScale.span(for: board.filmLength)), board.filmLength)
    }

    /// A point of the sheet: a moment on a line.
    private func at(_ t: Double, line: Int, _ scale: FilmScale) -> CGPoint {
        CGPoint(x: scale.x(t), y: (CGFloat(line) + 0.5) * FilmTimeline.rowHeight)
    }

    // MARK: The mode

    @Test func animateIsAModeOfItsOwnOnThePrototypesTable() {
        animate()
        #expect(store.canvasMode == .animate)
        #expect(store.prototyping && !store.inspecting)
        #expect(store.film.board == bench.a.id)
        store.show(.inspect)
        #expect(store.canvasMode == .inspect && !store.animating)
        store.show(.animate)
        #expect(store.canvasMode == .animate && !store.inspecting)
        store.show(.design)
        #expect(store.canvasMode == .design && !store.animating && !store.prototyping)
    }

    @Test func theFilmFollowsWhatIsPicked() {
        animate()
        store.seek(1)
        #expect(store.filmTime == 1)
        // The other artboard picked: its film comes to the desk, from its start.
        store.selection = [bench.b.id]
        #expect(store.film.board == bench.b.id)
        #expect(store.filmTime == 0)
        store.selection = [bench.node("Card")!.id]
        #expect(store.film.board == bench.a.id)
        // Nothing picked leaves it there.
        store.selection = []
        #expect(store.film.board == bench.a.id)
    }

    // MARK: Posing by hand

    @Test func draggingALayerPosesItAndLeavesTheDesignAlone() {
        animate()
        let designed = bench.node("Card")!.frame
        store.seek(1)
        let from = middle("Card")
        bench.drag(from, CGPoint(x: from.x + 50, y: from.y + 30))
        #expect(bench.node("Card")!.frame == designed)
        let made = keys("Card", .move)
        #expect(made.map(\.t) == [0, 1])
        #expect(made[0].v == [0, 0] && made[0].given == true)
        #expect(abs(made[1].v[0] - 50) < 0.01 && abs(made[1].v[1] - 30) < 0.01)
        // Its first key is shown at once: the film plays to it, and the playhead comes back.
        #expect(store.film.playing)
        store.pauseFilm()
        #expect(store.filmTime == 1)
        // One step to undo, and the layer is as designed again.
        bench.undo.undo()
        #expect(bench.node("Card")!.motion == nil)
    }

    @Test func aSecondPoseIsOneMoreKeyAndTheFilmGrowsWithIt() {
        animate()
        store.selection = [bench.node("Card")!.id]
        store.seek(1)
        bench.step { store.pose(.move, of: store.posedLayers) { _ in [40, 0] } }
        store.seek(2)
        // Past the end there is nowhere to stand: the film is two seconds while nothing says.
        #expect(store.filmTime == 2)
        bench.step { store.pose(.move, of: store.posedLayers) { _ in [40, 60] } }
        #expect(keys("Card", .move).map(\.t) == [0, 1, 2])
        #expect(store.filmBoard?.filmLength == 2)
        bench.step { store.setFilm("Film Length") { $0.length = 3.5 } }
        #expect(store.filmBoard?.filmLength == 3.5)
        bench.step { store.setFilm("Film Length") { $0.length = nil } }
        #expect(store.filmBoard?.film == nil)
    }

    @Test func deleteTakesKeysAndNeverTheLayer() {
        animate()
        let card = bench.node("Card")!.id
        store.selection = [card]
        store.seek(1)
        bench.step { store.pose(.move, of: [card]) { _ in [30, 0] } }
        #expect(store.hasKeysToRemove)
        bench.key(51)
        #expect(bench.node("Card") != nil)
        // The key at the playhead went; what was left said only what the design does, and went too.
        #expect(bench.node("Card")!.motion == nil)
        // With nothing left to take, Delete still leaves the layer alone.
        bench.key(51)
        #expect(bench.node("Card") != nil)
        #expect(store.selection == [card])
    }

    @Test func holdingSetsAKeyOfEverythingThatMoves() {
        animate()
        let card = bench.node("Card")!.id
        store.selection = [card]
        #expect(store.holdState == .none)
        store.seek(1)
        bench.step { store.pose(.move, of: [card]) { _ in [30, 0] } }
        bench.step { store.pose(.fade, of: [card]) { _ in [0.5] } }
        #expect(store.holdState == .here)
        store.seek(0.5)
        #expect(store.holdState == .between)
        #expect(store.keyState(.move) == .between && store.keyState(.turn) == .none)
        bench.step { store.holdHere() }
        #expect(store.holdState == .here)
        #expect(keys("Card", .move).map(\.t) == [0, 0.5, 1])
        #expect(keys("Card", .fade).map(\.t) == [0, 0.5, 1])
        // One property's own bead takes its key away again, and only its own.
        bench.step { store.toggleKey(.fade) }
        #expect(keys("Card", .fade).map(\.t) == [0, 1])
        #expect(keys("Card", .move).map(\.t) == [0, 0.5, 1])
    }

    // MARK: The camera

    @Test func theCameraIsPickedInsteadOfLayersAndPosedLikeThem() {
        animate()
        store.selection = [bench.node("Card")!.id]
        store.pickCamera()
        #expect(store.film.camera && store.selection.isEmpty)
        store.seek(1)
        bench.step { store.poseCamera(.cameraZoom, [2]) }
        let board = store.filmBoard!
        #expect(board.camera(at: 0).zoom == 1)
        #expect(board.camera(at: 1).zoom == 2)
        #expect(board.hasCamera)
        // A layer picked lets go of the camera.
        store.selection = [bench.node("Badge")!.id]
        #expect(!store.film.camera)
        // Back to seeing everything from here on.
        store.pickCamera()
        store.seek(2)
        bench.step { store.restCamera() }
        #expect(store.filmBoard!.camera(at: 2).isRest)
        #expect(store.filmBoard!.camera(at: 1).zoom == 2)
    }

    @Test func theCameraFliesToWhatIsPicked() {
        animate()
        let badge = bench.node("Badge")!
        store.selection = [badge.id]
        store.seek(1)
        bench.step { store.flyCamera(to: store.posedLayers) }
        store.pauseFilm()
        let camera = store.filmBoard!.camera(at: 1)
        // It looks at the badge's middle, measured from the artboard's, and closer than the whole.
        #expect(abs(camera.x - (270 - 200)) < 0.01 && abs(camera.y - (200 - 150)) < 0.01)
        #expect(camera.zoom > 1.5)
        #expect(store.filmBoard!.camera(at: 0).isRest)
        // The layer stays picked, for the next thing to be done with it.
        #expect(store.selection == [badge.id])
        // The whole flight is one step.
        bench.undo.undo()
        #expect(!store.filmBoard!.hasCamera)
    }

    @Test func draggingWithTheCameraInHandLooksElsewhere() {
        animate()
        store.pickCamera()
        store.seek(1)
        // Bare artboard, away from both layers: taken hold of and pulled left, it shows what lay to the right.
        bench.drag(CGPoint(x: 300, y: 150), CGPoint(x: 240, y: 150))
        store.pauseFilm()
        let camera = store.filmBoard!.camera(at: 1)
        #expect(abs(camera.x - 60) < 0.5 && abs(camera.y) < 0.5)
        #expect(store.film.camera)
        #expect(bench.node("Card")!.motion == nil)
    }

    // MARK: Moves made in one go

    @Test func aMoveWithNothingPickedIsTheWholeArtboardsOneAfterAnother() {
        animate()
        store.film.apart = 0.1
        bench.step { store.applyMove(.rise) }
        store.pauseFilm()
        let card = keys("Card", .fade), badge = keys("Badge", .fade)
        // In the order they are read: the card first, the badge a tenth of a second after it.
        #expect(card.map(\.t) == [0, 0.5])
        #expect(badge.map(\.t) == [0.1, 0.6])
        #expect(card.first?.v == [0] && card.last?.v == [1])
        bench.undo.undo()
        #expect(!store.filmBoard!.hasFilm)
    }

    @Test func removingMotionIsOfWhatIsPicked() {
        animate()
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        store.selection = [bench.node("Card")!.id]
        bench.step { store.clearFilmMotion() }
        #expect(bench.node("Card")!.motion == nil)
        #expect(bench.node("Badge")!.motion != nil)
        store.selection = []
        bench.step { store.clearFilmMotion() }
        #expect(!store.filmBoard!.hasFilm)
    }

    // MARK: The timeline in hand

    @Test func theTimelineHasTheCameraThenWhatMovesFrontFirst() {
        animate()
        #expect(sheet.rows.map(\.name) == ["Camera"])
        bench.step { store.applyMove(.rise) }
        store.pauseFilm()
        // The badge lies over the card, so its line comes first, as in the layers list.
        #expect(sheet.rows.map(\.name) == ["Camera", "Badge", "Card"])
        store.film.open = [bench.node("Card")!.id]
        let rows = sheet.rows
        #expect(rows.map(\.name) == ["Camera", "Badge", "Card", MotionProperty.move.title, MotionProperty.fade.title])
        // Its beads: away at first, hollow where it is as designed again.
        #expect(rows[2].marks.map(\.home) == [false, true])
        #expect(rows[4].marks.last?.pace != nil)
    }

    @Test func aBeadDraggedMovesItsKeyAsOneStep() {
        animate()
        let card = bench.node("Card")!.id
        store.selection = [card]
        store.seek(1)
        bench.step { store.pose(.move, of: [card]) { _ in [30, 0] } }
        store.selection = []
        let hand = FilmHand(store: store)
        let (rows, scale, length) = sheet
        let from = at(1, line: 1, scale)
        bench.step {
            hand.press(at: from, rows: rows, scale: scale)
            // Pressed, it is picked, and its layer with it.
            #expect(store.film.keys == [FilmKeyRef(card, at: 1)])
            #expect(store.selection == [card])
            hand.dragged(to: CGPoint(x: scale.x(1.52), y: from.y), by: scale.x(1.52) - from.x, rows: rows, scale: scale, length: length)
            // While it is dragged the seconds hold still under it.
            #expect(hand.held == scale.span)
            hand.ended(scale: scale)
        }
        // To the nearest twentieth of a second.
        #expect(keys("Card", .move).map(\.t) == [0, 1.5])
        #expect(store.film.keys == [FilmKeyRef(card, at: 1.5)])
        #expect(hand.held == nil)
        bench.undo.undo()
        #expect(keys("Card", .move).map(\.t) == [0, 1])
    }

    @Test func aBeadCatchesOnAnotherLinesKeyAndCommandLetsItGo() {
        animate()
        let card = bench.node("Card")!.id, badge = bench.node("Badge")!.id
        edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) }
            doc.update(badge) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 1.33) }
        }
        let hand = FilmHand(store: store)
        let (rows, scale, length) = sheet
        // Lines: the camera, the badge, the card.
        let from = at(1, line: 2, scale)
        let near = scale.x(1.33) - 3
        bench.step {
            hand.press(at: from, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: near, y: from.y), by: near - from.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(keys("Card", .move).map(\.t) == [0, 1.33])
        let (rows2, scale2, length2) = sheet
        let again = at(1.33, line: 2, scale2)
        let free = scale2.x(1.412)
        bench.step {
            hand.press(at: again, rows: rows2, scale: scale2)
            hand.dragged(to: CGPoint(x: free, y: again.y), by: free - again.x, rows: rows2, scale: scale2, length: length2, flags: .command)
            hand.ended(scale: scale2)
        }
        #expect(keys("Card", .move).map(\.t) == [0, 1.412])
    }

    @Test func aLinesBandMovesItsWholeMotionAndAClickOnItOnlyThePlayhead() {
        animate()
        let card = bench.node("Card")!.id
        edit { doc in
            doc.update(card) { n in
                n.setKey(.move, [30, 0], at: 0.2)
                n.setKey(.move, [0, 0], at: 0.8)
                n.setKey(.fade, [0], at: 0.2)
                n.setKey(.fade, [1], at: 0.6)
            }
        }
        let hand = FilmHand(store: store)
        let (rows, scale, length) = sheet
        let from = at(0.5, line: 1, scale)
        #expect(hand.point(from, rows: rows, scale: scale).band == rows[1].id)
        bench.step {
            hand.press(at: from, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: from.x + scale.perSecond * 0.5, y: from.y), by: scale.perSecond * 0.5, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(keys("Card", .move).map(\.t) == [0.7, 1.3])
        #expect(keys("Card", .fade).map(\.t) == [0.7, 1.1])
        // Its keys are let go of again, so Delete after it does not take the whole motion.
        #expect(store.film.keys.isEmpty)
        // Only clicked, the band is a place for the playhead.
        let (rows2, scale2, _) = sheet
        hand.press(at: at(1, line: 1, scale2), rows: rows2, scale: scale2)
        hand.ended(scale: scale2)
        #expect(store.filmTime == 1)
        #expect(keys("Card", .move).map(\.t) == [0.7, 1.3])
    }

    @Test func thePlayheadCatchesOnKeysAsItIsDragged() {
        animate()
        let card = bench.node("Card")!.id
        edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 0.73) }
        }
        let hand = FilmHand(store: store)
        let (rows, scale, length) = sheet
        let before = store.doc
        // On the ruler, well away from any bead's moment.
        let from = CGPoint(x: scale.x(1.6), y: 10)
        hand.pressRuler(at: from, scale: scale, length: length)
        hand.dragged(to: from, by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == 1.6)
        hand.dragged(to: CGPoint(x: scale.x(0.73) + 4, y: from.y), by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == 0.73)
        hand.dragged(to: CGPoint(x: scale.x(0.73) + 4, y: from.y), by: 0, rows: rows, scale: scale, length: length, flags: .command)
        #expect(abs(store.filmTime - (0.73 + 4 / Double(scale.perSecond))) < 0.002)
        hand.dragged(to: CGPoint(x: scale.x(40), y: from.y), by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == length)
        hand.ended(scale: scale)
        // Scrubbing picks nothing and changes nothing.
        #expect(store.selection.isEmpty && store.doc == before)
    }

    @Test func theFlagSetsTheFilmsLengthAndTwiceOnItLetsItFollowTheKeys() {
        animate()
        let hand = FilmHand(store: store)
        let (rows, scale, length) = sheet
        #expect(length == 2)
        let flag = CGPoint(x: scale.x(length), y: 10)
        #expect(hand.pointRuler(flag, scale: scale, length: length).end)
        bench.step {
            hand.pressRuler(at: flag, scale: scale, length: length)
            let to = scale.x(1.27)
            hand.dragged(to: CGPoint(x: to, y: 10), by: to - flag.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        // By quarters of a second.
        #expect(store.filmBoard?.film?.length == 1.25)
        let (_, scale2, length2) = sheet
        bench.step {
            hand.pressRuler(at: CGPoint(x: scale2.x(length2), y: 10), scale: scale2, length: length2, clicks: 2)
            hand.ended(scale: scale2)
        }
        #expect(store.filmBoard?.film == nil)
        // Anywhere else on the ruler is the playhead's.
        let (rows3, scale3, length3) = sheet
        hand.pressRuler(at: CGPoint(x: scale3.x(0.5), y: 10), scale: scale3, length: length3)
        hand.dragged(to: CGPoint(x: scale3.x(0.5), y: 10), by: 0, rows: rows3, scale: scale3, length: length3)
        hand.ended(scale: scale3)
        #expect(store.filmTime == 0.5)
    }

    @Test func paceIsSetOnTheKeysInHand() {
        animate()
        let card = bench.node("Card")!.id
        store.selection = [card]
        store.seek(1)
        bench.step { store.pose(.move, of: [card]) { _ in [30, 0] } }
        // None picked in the timeline: those at the playhead.
        #expect(store.sharedEase == .auto)
        bench.step { store.setEase(.spring()) }
        #expect(keys("Card", .move).last?.ease == .spring())
        #expect(store.sharedEase?.kind == .spring)
        // Picked in the timeline, the key at the start instead.
        store.film.keys = [FilmKeyRef(card, at: 0)]
        bench.step { store.setEase(.linear) }
        #expect(keys("Card", .move).first?.ease == .linear)
        #expect(keys("Card", .move).last?.ease == .spring())
        bench.step { store.removeFilmKeys() }
        #expect(keys("Card", .move).map(\.t) == [1])
        #expect(store.film.keys.isEmpty)
    }
}
