import Testing
import AppKit
@testable import Bezzle

/// The film's timeline taken by the pointer (`FilmHand`), and the lines it is made of
/// (`FilmRow`, `FilmScale`): what a press, a drag and a right click do on a bead, on a line's
/// band, on bare sheet and on the ruler, with and without the keys held down.
@MainActor
struct FilmTimelineTests {
    /// On artboard A: a group of two (an icon and a label) over a card, and a hidden layer.
    let bench: Bench
    let hand: FilmHand

    init() {
        var group = Node(kind: .group, name: "Row", frame: CGRect(x: 40, y: 160, width: 200, height: 40))
        group.children = [
            CanvasTests.rect("Icon", CGRect(x: 0, y: 0, width: 40, height: 40)),
            CanvasTests.rect("Label", CGRect(x: 60, y: 10, width: 140, height: 20)),
        ]
        var ghost = CanvasTests.rect("Ghost", CGRect(x: 300, y: 20, width: 40, height: 40))
        ghost.hidden = true
        bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)), group, ghost])
        hand = FilmHand(store: bench.store)
        bench.store.show(.animate)
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: .zero, zoom: 1)
    }

    var store: DocumentStore { bench.store }

    private func id(_ name: String) -> UUID { bench.node(name)!.id }

    private func edit(_ change: (inout BezzleDocument) -> Void) {
        bench.step { store.edit("Add Key", change) }
    }

    private func keys(_ name: String, _ property: MotionProperty) -> [Double] {
        (bench.node(name)?[track: property]?.keys ?? []).map(\.t)
    }

    private var sheet: (rows: [FilmRow], scale: FilmScale, length: Double) {
        let board = store.filmBoard!
        return (FilmRow.rows(of: board, open: store.film.open), FilmScale(width: 600, span: FilmScale.span(for: board.filmLength)), board.filmLength)
    }

    private func at(_ t: Double, line: Int, _ scale: FilmScale) -> CGPoint {
        CGPoint(x: scale.x(t), y: (CGFloat(line) + 0.5) * FilmTimeline.rowHeight)
    }

    /// A press at one moment of a line, dragged to another moment, and let go: one step.
    private func drag(line: Int, from: Double, to: Double, flags: NSEvent.ModifierFlags = []) {
        let (rows, scale, length) = sheet
        let a = at(from, line: line, scale), b = at(to, line: line, scale)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale, flags: flags)
            for i in 1...4 {
                let x = a.x + (b.x - a.x) * CGFloat(i) / 4
                hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length, flags: flags)
            }
            hand.ended(scale: scale, flags: flags)
        }
    }

    private func press(line: Int, at t: Double, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let (rows, scale, _) = sheet
        bench.step {
            hand.press(at: at(t, line: line, scale), rows: rows, scale: scale, flags: flags, clicks: clicks)
            hand.ended(scale: scale, flags: flags)
        }
    }

    /// The card with a move from 0.2 to 0.8 and a fade from 0.2 to 0.6.
    private func animateCard() {
        edit { doc in
            doc.update(id("Card")) { n in
                n.setKey(.move, [30, 0], at: 0.2)
                n.setKey(.move, [0, 0], at: 0.8)
                n.setKey(.fade, [0], at: 0.2)
                n.setKey(.fade, [1], at: 0.6)
            }
        }
    }

    // MARK: The lines

    @Test func momentsAndPointsGoBothWays() {
        let scale = FilmScale(width: 600, span: FilmScale.span(for: 2))
        for t in [0, 0.05, 0.73, 1, 2, 2.2] {
            #expect(abs(scale.t(scale.x(t)) - t) < 1e-9)
        }
        // The film ends short of the card's edge, with room for its flag and a bead past it.
        #expect(scale.x(2) < 600 - FilmScale.inset)
        #expect(scale.x(0) == FilmScale.inset)
        // However short the film is set, the sheet never shows less than half a second.
        #expect(FilmScale.span(for: 0.01) == 0.5)
    }

    @Test func aFilmWithNothingMovingHasOnlyTheCamerasLine() {
        let rows = sheet.rows
        #expect(rows.count == 1 && rows[0].camera && rows[0].marks.isEmpty)
        #expect(rows[0].layer == bench.a.id)
    }

    @Test func linesAreOfWhatMovesFrontFirstAndNeverOfWhatIsHidden() {
        edit { doc in
            for name in ["Card", "Row", "Label", "Ghost"] {
                doc.update(id(name)) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 0.5) }
            }
        }
        // The row lies over the card, and what it holds comes under it, front first.
        #expect(sheet.rows.map(\.name) == ["Camera", "Row", "Label", "Card"])
        // Every line has an id of its own, the camera's apart from any layer's.
        #expect(Set(sheet.rows.map(\.id)).count == 4)
    }

    @Test func aLineOpenedHasOneForEachPropertyWithItsOwnKeys() {
        animateCard()
        store.film.open = [id("Card")]
        let rows = sheet.rows
        #expect(rows.map(\.name) == ["Camera", "Card", MotionProperty.move.title, MotionProperty.fade.title])
        #expect(rows[1].marks.map(\.t) == [0.2, 0.6, 0.8])
        #expect(rows[2].marks.map(\.t) == [0.2, 0.8] && rows[2].property == .move)
        #expect(rows[3].marks.map(\.t) == [0.2, 0.6] && rows[3].property == .fade)
        // A bead is hollow only where everything keyed at that moment is as designed.
        #expect(rows[1].marks.map(\.home) == [false, true, true])
        // How a key is come to is told on a property's own line, from its second key on.
        #expect(rows[2].marks[0].pace == nil && rows[2].marks[1].pace != nil)
        #expect(rows[1].marks.allSatisfy { $0.pace == nil })
    }

    @Test func theCamerasLineOpensByItsArtboard() {
        bench.step { store.pickCamera(); store.seek(1); store.poseCamera(.cameraZoom, [2]); store.poseCamera(.cameraRoll, [10]) }
        store.film.open = [bench.a.id]
        let rows = sheet.rows
        #expect(rows.map(\.name) == ["Camera", MotionProperty.cameraZoom.title, MotionProperty.cameraRoll.title])
        #expect(rows.allSatisfy { $0.camera && $0.layer == bench.a.id })
        // The key Bezzle gave it at the start, to fly from, is told apart from one that was set.
        #expect(rows[0].marks.map(\.given) == [true, false])
    }

    // MARK: Pointing

    @Test func thePointerIsOnABeadWithinReachElseOnTheBandElseOnNothing() {
        animateCard()
        let (rows, scale, _) = sheet
        let y = at(0, line: 1, scale).y
        let onBead = hand.point(CGPoint(x: scale.x(0.2) + FilmHand.reach, y: y), rows: rows, scale: scale)
        #expect(onBead.key == FilmKeyRef(id("Card"), at: 0.2) && onBead.band == nil)
        let onBand = hand.point(CGPoint(x: scale.x(0.4), y: y), rows: rows, scale: scale)
        #expect(onBand.key == nil && onBand.band == rows[1].id)
        let past = hand.point(CGPoint(x: scale.x(1.4), y: y), rows: rows, scale: scale)
        #expect(past.key == nil && past.band == nil && past.row == rows[1].id)
        // Of two beads within reach, the nearer.
        let between = hand.point(CGPoint(x: scale.x(0.6) + 2, y: y), rows: rows, scale: scale)
        #expect(between.key == FilmKeyRef(id("Card"), at: 0.6))
        // Under the last line, and over the first, there is no line.
        #expect(hand.point(CGPoint(x: 100, y: 500), rows: rows, scale: scale).row == nil)
        #expect(hand.point(CGPoint(x: 100, y: -4), rows: rows, scale: scale).row == nil)
        // A line with one key has no band.
        let lone = hand.point(CGPoint(x: scale.x(1), y: at(0, line: 0, scale).y), rows: rows, scale: scale)
        #expect(lone.row == rows[0].id && lone.band == nil && lone.key == nil)
    }

    // MARK: Beads

    @Test func aBeadOnlyClickedPicksItsKeyAndLayerAndTakesThePlayheadThere() {
        animateCard()
        press(line: 1, at: 0.8)
        #expect(store.film.keys == [FilmKeyRef(id("Card"), at: 0.8)])
        #expect(store.selection == [id("Card")])
        #expect(store.filmTime == 0.8)
        #expect(keys("Card", .move) == [0.2, 0.8])
        #expect(!bench.undo.canUndo || store.doc.node(id("Card"))?[track: .move]?.keys.count == 2)
    }

    @Test func aDragShorterThanAClickIsAClick() {
        animateCard()
        let before = store.doc
        let (rows, scale, length) = sheet
        let a = at(0.8, line: 1, scale)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: a.x + 2, y: a.y), by: 2, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(store.doc == before)
        #expect(hand.held == nil && hand.drag == nil)
    }

    @Test func shiftPicksOneMoreKeyAndTheyMoveTogetherKeepingTheirDistance() {
        animateCard()
        press(line: 1, at: 0.2)
        press(line: 1, at: 0.8, flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(id("Card"), at: 0.2), FilmKeyRef(id("Card"), at: 0.8)])
        // Shift does not move the playhead: it stays where the first click put it.
        #expect(store.filmTime == 0.2)
        drag(line: 1, from: 0.8, to: 1.1)
        #expect(keys("Card", .move) == [0.5, 1.1])
        // The fade's first key was at the same moment as the move's, and goes with it; its second was not picked.
        #expect(keys("Card", .fade) == [0.5, 0.6])
        // Shift on a picked key lets go of it.
        press(line: 1, at: 1.1, flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(id("Card"), at: 0.5)])
    }

    @Test func keysDraggedTowardsTheStartStopThereTogether() {
        animateCard()
        press(line: 1, at: 0.2)
        press(line: 1, at: 0.8, flags: .shift)
        drag(line: 1, from: 0.8, to: 0.1)
        // The first reached the start; the second kept its distance from it.
        #expect(keys("Card", .move) == [0, 0.6])
    }

    @Test func aKeyDraggedOverAnotherLeavesItAloneUntilItIsLetGoOnIt() {
        animateCard()
        let (rows, scale, length) = sheet
        let a = at(0.2, line: 1, scale)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            // Over the key at 0.6, and on past it.
            for t in [0.4, 0.6, 0.7] {
                let x = scale.x(t)
                hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length)
            }
            hand.ended(scale: scale)
        }
        #expect(keys("Card", .move) == [0.7, 0.8])
        #expect(keys("Card", .fade) == [0.6, 0.7])
        bench.undo.undo()
        #expect(keys("Card", .move) == [0.2, 0.8] && keys("Card", .fade) == [0.2, 0.6])
        // Let go on another key of the same property, it takes that key's place.
        drag(line: 1, from: 0.2, to: 0.6)
        #expect(keys("Card", .fade) == [0.6])
        #expect(bench.node("Card")?[track: .fade]?.keys.first?.v == [0])
    }

    @Test func aKeyDraggedBackToWhereItWasLeavesNothingToUndo() {
        animateCard()
        let before = store.doc
        let (rows, scale, length) = sheet
        let a = at(0.8, line: 1, scale)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: a.x + 60, y: a.y), by: 60, rows: rows, scale: scale, length: length)
            hand.dragged(to: a, by: 0, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(store.doc == before)
        // A move that came to nothing is not a step to undo.
        #expect(bench.undo.undoActionName != String(localized: "Move Key"))
        #expect(hand.held == nil)
    }

    @Test func optionStepsFinerAndTheKeyCatchesOnThePlayhead() {
        animateCard()
        drag(line: 1, from: 0.8, to: 1.234, flags: .option)
        #expect(keys("Card", .move) == [0.2, 1.23])
        store.seek(1.57)
        // Within reach of the playhead it lands on it, though that is on no step.
        let (rows, scale, length) = sheet
        let a = at(1.23, line: 1, scale), x = scale.x(1.57) + 3
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(keys("Card", .move) == [0.2, 1.57])
        #expect(store.filmTime == 1.57)
    }

    @Test func aPropertysOwnBeadMovesThatPropertyAlone() {
        animateCard()
        store.film.open = [id("Card")]
        // Lines: camera, card, its move, its fade.
        drag(line: 3, from: 0.2, to: 0.4)
        #expect(keys("Card", .fade) == [0.4, 0.6])
        #expect(keys("Card", .move) == [0.2, 0.8])
        #expect(store.film.keys == [FilmKeyRef(id("Card"), .fade, at: 0.4)])
    }

    @Test func theCamerasBeadPicksTheCameraAndMovesItsKey() {
        bench.step { store.pickCamera(); store.seek(1); store.poseCamera(.cameraZoom, [2]) }
        store.selection = [id("Card")]
        #expect(!store.film.camera)
        drag(line: 0, from: 1, to: 1.5)
        #expect(store.film.camera && store.selection.isEmpty)
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1.5])
        #expect(store.film.keys == [FilmKeyRef(bench.a.id, at: 1.5)])
    }

    @Test func aKeyDraggedPastTheEndLengthensAFilmThatFollowsItsKeys() {
        animateCard()
        #expect(store.filmBoard?.filmLength == 2)
        let (rows, scale, length) = sheet
        let a = at(0.8, line: 1, scale), x = scale.x(2.15)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length)
            // The seconds hold still under the hand though the film has grown.
            #expect(hand.held == scale.span)
            hand.ended(scale: scale)
        }
        #expect(keys("Card", .move) == [0.2, 2.15])
        #expect(store.filmBoard?.filmLength == 2.5)
        #expect(hand.held == nil)
    }

    // MARK: Bands and bare sheet

    @Test func twiceOnALineSetsAKeyOfEverythingThatMovesThere() {
        animateCard()
        press(line: 1, at: 0.4, clicks: 2)
        #expect(keys("Card", .move) == [0.2, 0.4, 0.8])
        #expect(keys("Card", .fade) == [0.2, 0.4, 0.6])
        #expect(store.filmTime == 0.4 && store.selection == [id("Card")])
        // What it holds there is what the layer was on its way through.
        let held = bench.node("Card")!.value(of: .fade, at: 0.4)[0]
        #expect(held > 0 && held < 1)
        bench.undo.undo()
        #expect(keys("Card", .move) == [0.2, 0.8])
    }

    @Test func twiceOnAPropertysLineSetsItsKeyAlone() {
        animateCard()
        store.film.open = [id("Card")]
        press(line: 2, at: 0.5, clicks: 2)
        #expect(keys("Card", .move) == [0.2, 0.5, 0.8])
        #expect(keys("Card", .fade) == [0.2, 0.6])
    }

    @Test func aPressOnBareSheetLetsGoOfKeysAndKeepsWhatIsPicked() {
        animateCard()
        press(line: 1, at: 0.8)
        #expect(!store.film.keys.isEmpty)
        // The line under the card's is bare.
        press(line: 2, at: 1.2)
        #expect(store.film.keys.isEmpty)
        #expect(store.selection == [id("Card")])
        #expect(store.filmTime == 0.8)
        // Only a drag there, even of nothing, takes the playhead.
        let (rows, scale, length) = sheet
        let p = at(1.2, line: 2, scale)
        hand.press(at: p, rows: rows, scale: scale)
        hand.dragged(to: p, by: 0, rows: rows, scale: scale, length: length)
        hand.ended(scale: scale)
        #expect(store.filmTime == 1.2)
    }

    @Test func scrubbingStopsAFilmThatPlaysAndStaysWithinTheFilm() {
        animateCard()
        store.playFilm()
        #expect(store.film.playing)
        let (rows, scale, length) = sheet
        let p = at(1.2, line: 3, scale)
        hand.press(at: p, rows: rows, scale: scale)
        hand.dragged(to: p, by: 0, rows: rows, scale: scale, length: length)
        #expect(!store.film.playing && store.filmTime == 1.2)
        hand.dragged(to: CGPoint(x: -80, y: p.y), by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == 0)
        hand.dragged(to: CGPoint(x: 5000, y: p.y), by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == length)
        // Clear of every key, Option steps by hundredths; near one, the playhead still lands on it.
        hand.dragged(to: CGPoint(x: scale.x(1.377), y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .option)
        #expect(store.filmTime == 1.38)
        hand.dragged(to: CGPoint(x: scale.x(0.777), y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .option)
        #expect(store.filmTime == 0.8)
        hand.dragged(to: CGPoint(x: scale.x(0.777), y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .command)
        #expect(abs(store.filmTime - 0.777) < 0.0006)
        hand.ended(scale: scale)
        #expect(store.film.live == store.film.time && store.film.head == store.film.time)
    }

    @Test func aBandDraggedToTheStartStopsThereWhole() {
        animateCard()
        drag(line: 1, from: 0.4, to: -0.4)
        #expect(keys("Card", .move) == [0, 0.6])
        #expect(keys("Card", .fade) == [0, 0.4])
        #expect(store.film.keys.isEmpty)
    }

    // MARK: The ruler

    @Test func theFlagStopsAtAQuarterSecondAndCatchesOnTheLastKey() {
        animateCard()
        let (rows, scale, length) = sheet
        let flag = CGPoint(x: scale.x(length), y: 10)
        bench.step {
            hand.pressRuler(at: flag, scale: scale, length: length)
            hand.dragged(to: CGPoint(x: scale.x(0.8) + 5, y: 10), by: scale.x(0.8) + 5 - flag.x, rows: rows, scale: scale, length: length)
            #expect(store.filmBoard?.film?.length == 0.8)
            hand.dragged(to: CGPoint(x: -200, y: 10), by: -200 - flag.x, rows: rows, scale: scale, length: length)
            #expect(store.filmBoard?.film?.length == 0.25)
            hand.dragged(to: CGPoint(x: scale.x(1.13), y: 10), by: scale.x(1.13) - flag.x, rows: rows, scale: scale, length: length, flags: .option)
            hand.ended(scale: scale)
        }
        #expect(store.filmBoard?.film?.length == 1.15)
        // The whole drag is one step.
        bench.undo.undo()
        #expect(store.filmBoard?.film == nil)
    }

    @Test func aFilmCutShortBringsThePlayheadBackInsideIt() {
        animateCard()
        store.seek(1.8)
        bench.step { store.setFilm("Film Length") { $0.length = 1 } }
        #expect(store.filmTime == 1)
        #expect(store.film.live <= 1)
        // The keys past the end are kept, in the shade.
        bench.step { store.setFilm("Film Length") { $0.length = 0.5 } }
        #expect(keys("Card", .move) == [0.2, 0.8])
    }

    // MARK: The menu

    @Test func aRightClickOnABeadOffersEveryPaceAndItsRemoval() {
        animateCard()
        let (rows, scale, _) = sheet
        hand.hot = hand.point(at(0.8, line: 1, scale), rows: rows, scale: scale)
        let entries = hand.menu(rows: rows, scale: scale)
        let items = entries.filter { $0.kind == .item }
        #expect(items.count == MotionEase.Kind.allCases.count + 1)
        #expect(items.filter(\.checked).map(\.title) == [MotionEase.auto.title])
        // The click picked the key and its layer, so what is chosen goes to it.
        #expect(store.film.keys == [FilmKeyRef(id("Card"), at: 0.8)] && store.selection == [id("Card")])
        bench.step { items.first { $0.title == MotionEase.spring().title }?.action() }
        #expect(bench.node("Card")?[track: .move]?.keys.last?.ease?.kind == .spring)
        // The fade has no key at that moment and is left alone.
        #expect(bench.node("Card")?[track: .fade]?.keys.allSatisfy { $0.ease == nil } == true)
        bench.step { items.last?.action() }
        #expect(keys("Card", .move) == [0.2])
    }

    @Test func aRightClickOnALineOffersAKeyThereAndTheRemovalOfItsMotion() {
        animateCard()
        let (rows, scale, _) = sheet
        hand.hot = hand.point(at(0.4, line: 1, scale), rows: rows, scale: scale)
        let items = hand.menu(rows: rows, scale: scale).filter { $0.kind == .item }
        #expect(items.count == 2)
        bench.step { items[0].action() }
        #expect(keys("Card", .move) == [0.2, 0.4, 0.8] && store.filmTime == 0.4)
        bench.step { items[1].action() }
        #expect(bench.node("Card")?.motion == nil)
        // Nothing under the pointer, nothing offered.
        hand.hot = FilmHand.Hot()
        #expect(hand.menu(rows: sheet.rows, scale: scale).isEmpty)
    }

    @Test func aRightClickOnTheCamerasLineIsOfTheCameraAlone() {
        animateCard()
        bench.step { store.pickCamera(); store.seek(1); store.poseCamera(.cameraZoom, [2]) }
        store.selection = [id("Card")]
        let (rows, scale, _) = sheet
        hand.hot = hand.point(at(0.5, line: 0, scale), rows: rows, scale: scale)
        let items = hand.menu(rows: rows, scale: scale).filter { $0.kind == .item }
        #expect(store.film.camera)
        bench.step { items.last?.action() }
        #expect(store.filmBoard?.hasCamera == false)
        #expect(keys("Card", .move) == [0.2, 0.8])
    }

    // MARK: Things going away under the hand

    @Test func keysOfALayerThatIsGoneAreLetGoOfQuietly() {
        animateCard()
        store.selection = [id("Card")]
        let stale: Set = [FilmKeyRef(id("Card"), at: 0.8)]
        store.film.keys = stale
        #expect(store.pickedKeys.count == 1 && store.hasKeysToRemove)
        // The keys' making undone while one of them is picked.
        bench.undo.undo()
        store.selection = [id("Card")]
        store.film.keys = stale
        #expect(store.pickedKeys.isEmpty)
        #expect(store.sharedEase == nil && !store.hasKeysToRemove)
        bench.undo.redo()
        // With a picked key gone, Delete and the paces fall to the keys at the playhead again.
        store.selection = [id("Card")]
        store.film.keys = [FilmKeyRef(id("Card"), at: 1.4)]
        store.seek(0.6)
        #expect(store.hasKeysToRemove && store.sharedEase == .auto)
        bench.step { store.removeFilmKeys() }
        #expect(keys("Card", .fade) == [0.2] && keys("Card", .move) == [0.2, 0.8])
        #expect(store.film.keys.isEmpty)
        // And of a layer deleted outright: nothing is done, and they are let go of.
        store.film.keys = [FilmKeyRef(UUID(), at: 0.5)]
        let before = store.doc
        bench.step { store.setEase(.linear); store.removeFilmKeys() }
        #expect(store.film.keys.isEmpty && store.doc == before)
    }

    @Test func aDragGoesOnSanelyWhenItsLinesChangeUnderIt() {
        animateCard()
        let (rows, scale, length) = sheet
        let a = at(0.8, line: 1, scale)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: a.x + 40, y: a.y), by: 40, rows: rows, scale: scale, length: length)
            // The lines as they are after the first step: the key is elsewhere now.
            let (later, _, _) = sheet
            hand.dragged(to: CGPoint(x: a.x + 80, y: a.y), by: 80, rows: later, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        let moved = keys("Card", .move)
        #expect(moved.count == 2 && moved[0] == 0.2)
        #expect(abs(moved[1] - (0.8 + 80 / Double(scale.perSecond))) < 0.05)
    }
}
