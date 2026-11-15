import Testing
import AppKit
@testable import Bezzle

/// A marquee dragged over the keys of the film's timeline (`FilmHand`, `FilmMarquee`): from bare
/// sheet it picks the keys under it as it grows, with Shift it adds to those picked and lets go
/// of those among them it catches again. On a sheet looked at closer it creeps along at the
/// sheet's ends and keeps what it caught. Escape gives it up: what was picked before is picked
/// again (`cancel`, and `heed`, which asks the keyboard for the key).
@MainActor
struct FilmMarqueeTests {
    /// On artboard A: a card, and a badge over it. The camera's line comes first, then the
    /// badge's, then the card's; under those the sheet is bare.
    let bench: Bench
    let hand: FilmHand
    /// How wide the sheet is taken to be.
    let width: CGFloat = 600

    init() {
        bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
                              CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40))])
        hand = FilmHand(store: bench.store)
        bench.store.show(.animate)
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: .zero, zoom: 1)
        // The card moves from 0.2 to 0.8 and fades from 0.2 to 0.6; the badge grows at 0, 0.8 and
        // 1.4; the camera goes closer from 0 to 1. A film of two seconds.
        let card = bench.node("Card")!.id, badge = bench.node("Badge")!.id, board = bench.a.id
        bench.step {
            bench.store.edit("Add Key") { doc in
                doc.update(card) { n in
                    n.setKey(.move, [30, 0], at: 0.2)
                    n.setKey(.move, [0, 0], at: 0.8)
                    n.setKey(.fade, [0], at: 0.2)
                    n.setKey(.fade, [1], at: 0.6)
                }
                doc.update(badge) { n in
                    n.setKey(.scale, [0.5, 0.5], at: 0)
                    n.setKey(.scale, [1, 1], at: 0.8)
                    n.setKey(.scale, [1.2, 1.2], at: 1.4)
                }
                doc.update(board) { n in
                    n.setKey(.cameraZoom, [1.5], at: 0)
                    n.setKey(.cameraZoom, [2], at: 1)
                }
            }
        }
    }

    var store: DocumentStore { bench.store }
    private var card: UUID { bench.node("Card")!.id }
    private var badge: UUID { bench.node("Badge")!.id }
    private var board: UUID { bench.a.id }
    private var scale: FilmScale { hand.scale(width: width) }
    private var rows: [FilmRow] { FilmRow.rows(of: store.filmBoard!, open: store.film.open) }
    private var length: Double { store.filmBoard!.filmLength }

    private func keys(_ name: String, _ property: MotionProperty) -> [Double] {
        (bench.node(name)?[track: property]?.keys ?? []).map(\.t)
    }

    /// A point of the sheet: at a moment, so many lines down. 1.5 is the middle of the second line.
    private func at(_ t: Double, _ lines: CGFloat) -> CGPoint {
        CGPoint(x: scale.x(t), y: lines * FilmTimeline.rowHeight)
    }

    private func press(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        hand.press(at: p, rows: rows, scale: scale, flags: flags)
    }

    /// The press that was made at `a` moved on to `b`, on the sheet as it shows by now.
    private func pull(from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        hand.dragged(to: b, by: b.x - a.x, rows: rows, scale: scale, length: length, flags: flags)
    }

    private func letGo(flags: NSEvent.ModifierFlags = []) {
        hand.ended(scale: scale, flags: flags)
    }

    /// A press at one point dragged to another in steps and let go, as one step to undo.
    private func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        bench.step {
            press(a, flags: flags)
            for i in 1...4 {
                let k = CGFloat(i) / 4
                pull(from: a, to: CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), flags: flags)
            }
            letGo(flags: flags)
        }
    }

    private func click(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        bench.step {
            press(p, flags: flags)
            letGo(flags: flags)
        }
    }

    // MARK: The lines it is dragged over

    @Test func theLinesAreTheCamerasTheBadgesAndTheCards() {
        #expect(rows.map(\.name) == ["Camera", "Badge", "Card"])
        #expect(rows.map { $0.marks.map(\.t) } == [[0, 1], [0, 0.8, 1.4], [0.2, 0.6, 0.8]])
        #expect(length == 2)
    }

    // MARK: The whole gesture

    @Test func aDragFromBareSheetPicksTheKeysUnderItAsItGrows() {
        let before = store.doc
        // Pressed under the last line, at one second.
        let a = at(1, 3.5)
        press(a)
        #expect(hand.drag?.kind == .marquee && hand.marquee == nil)
        // Under three points it is no drag yet.
        pull(from: a, to: CGPoint(x: a.x + 2, y: a.y - 2))
        #expect(hand.marquee == nil && store.film.keys.isEmpty && hand.drag?.moved == false)
        // Up into the card's line, short of its last key: a marquee, with nothing in it.
        var b = at(0.9, 2.5)
        pull(from: a, to: b)
        #expect(hand.marquee == FilmMarquee(from: scale.t(a.x), to: scale.t(b.x), top: a.y, foot: b.y))
        #expect(store.film.keys.isEmpty && store.selection.isEmpty)
        // Over the card's key at 0.8: picked, and the card with it, as a press on the bead picks both.
        b = at(0.7, 2.5)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)])
        #expect(store.selection == [card])
        // Up over the badge's line: its key at that moment too, and the badge, in the lines' order.
        b = at(0.7, 1.5)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        #expect(store.selection == [badge, card])
        let r = hand.marquee!.rect(on: scale)
        #expect(closeBy(r.origin, CGPoint(x: scale.x(0.7), y: 36)) && abs(r.maxX - scale.x(1)) < 0.01 && abs(r.height - 48) < 0.01)
        // And over the camera's: its key at one second, beside the layers'. The layers stay picked.
        b = at(0.7, 0.4)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8), FilmKeyRef(board, at: 1)])
        #expect(store.selection == [badge, card] && !store.film.camera)
        // Back towards the start: every key from there to one second, and none before or after.
        b = at(0.1, 0.4)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8),
                                    FilmKeyRef(badge, at: 0.8), FilmKeyRef(board, at: 1)])
        // Made smaller again, it lets go of what it no longer covers.
        b = at(0.7, 2.5)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)] && store.selection == [card])
        // Over nothing, nothing is picked, and what was picked before it began is again.
        b = at(0.9, 2.5)
        pull(from: a, to: b)
        #expect(store.film.keys.isEmpty && store.selection.isEmpty)
        b = at(0.5, 2.5)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)])
        letGo()
        // Let go, they stay picked; nothing is drawn or held, and the playhead and the design are as they were.
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)] && store.selection == [card])
        #expect(hand.marquee == nil && hand.drag == nil && hand.held == nil)
        #expect(store.filmTime == 0 && store.doc == before && !store.inGesture)
    }

    @Test func whatItPickedMovesIsPacedAndIsTakenAwayTogether() {
        let a = at(1, 3.5)
        press(a)
        pull(from: a, to: at(0.5, 2.5))
        letGo()
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)])
        // One of them dragged takes the other along, as far.
        drag(at(0.8, 2.5), at(1.1, 2.5))
        #expect(keys("Card", .move) == [0.2, 1.1] && keys("Card", .fade) == [0.2, 0.9])
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.9), FilmKeyRef(card, at: 1.1)])
        #expect(bench.undo.undoActionName == String(localized: "Move Key"))
        // A pace goes to both, and Delete takes both away.
        bench.step { store.setEase(.linear) }
        #expect(bench.node("Card")?[track: .move]?.keys.last?.ease == .linear && bench.node("Card")?[track: .fade]?.keys.last?.ease == .linear)
        bench.step { store.removeFilmKeys() }
        #expect(keys("Card", .move) == [0.2] && keys("Card", .fade) == [0.2])
        #expect(store.film.keys.isEmpty)
    }

    @Test func keysOfLayersAndOfTheCameraCaughtTogetherMoveTogether() {
        let a = at(1.1, 3.5)
        press(a)
        pull(from: a, to: at(0.7, 0.4))
        letGo()
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8), FilmKeyRef(board, at: 1)])
        // Taken by a layer's bead, or by the camera's: all of them go, the camera's with the layers'.
        drag(at(0.8, 1.5), at(0.9, 1.5))
        #expect(keys("Card", .move) == [0.2, 0.9] && keys("Badge", .scale) == [0, 0.9, 1.4])
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1.1])
        drag(at(1.1, 0.5), at(1.2, 0.5))
        #expect(keys("Card", .move) == [0.2, 1] && keys("Badge", .scale) == [0, 1, 1.4])
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1.2])
        #expect(store.film.keys == [FilmKeyRef(card, at: 1), FilmKeyRef(badge, at: 1), FilmKeyRef(board, at: 1.2)])
        #expect(store.selection == [badge, card] && !store.film.camera)
        // The camera's bead pressed when it is not among the picked keys picks the camera alone, as ever.
        click(at(0, 0.5))
        #expect(store.film.keys == [FilmKeyRef(board, at: 0)] && store.film.camera && store.selection.isEmpty)
    }

    // MARK: Shift

    @Test func shiftAddsToWhatIsPickedAndLetsGoOfWhatItCatchesAgain() {
        click(at(0.2, 2.5))
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2)] && store.filmTime == 0.2)
        let a = at(1, 3.5)
        press(a, flags: .shift)
        // Pressed with Shift, what is picked stays.
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2)])
        pull(from: a, to: at(0.7, 1.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        #expect(store.selection == [card, badge])
        // Over the key that was picked before: that one is let go of, the others it catches are added.
        pull(from: a, to: at(0.1, 1.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        // Off it again, it is picked as before.
        pull(from: a, to: at(0.3, 1.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        letGo(flags: .shift)
        #expect(store.film.keys.count == 4 && store.selection == [card, badge])
        // Shift never moves the playhead.
        #expect(store.filmTime == 0.2)
        // A marquee with Shift over nothing, and Shift only clicked on bare sheet, change nothing.
        press(a, flags: .shift)
        pull(from: a, to: at(1.2, 3.2), flags: .shift)
        #expect(hand.marquee != nil && store.film.keys.count == 4)
        letGo(flags: .shift)
        click(a, flags: .shift)
        #expect(store.film.keys.count == 4 && store.selection == [card, badge] && store.filmTime == 0.2)
        // With Shift over the camera's key: picked beside the layers', which stay picked.
        let c = at(1.2, 0.2)
        press(c, flags: .shift)
        pull(from: c, to: at(0.95, 0.9), flags: .shift)
        letGo(flags: .shift)
        #expect(store.film.keys.count == 5 && store.film.keys.contains(FilmKeyRef(board, at: 1)))
        #expect(store.selection == [card, badge] && !store.film.camera)
        // And Shift on the camera's other bead adds that one, as it does a layer's.
        click(at(0, 0.5), flags: .shift)
        #expect(store.film.keys.count == 6 && store.film.keys.contains(FilmKeyRef(board, at: 0)) && store.selection == [card, badge])
        // Without Shift, a marquee picks what it catches alone.
        press(a)
        #expect(store.film.keys.isEmpty)
        pull(from: a, to: at(1.45, 1.5))
        letGo()
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
    }

    // MARK: Escape

    @Test func escapeGivesBackWhatWasPicked() {
        let before = store.doc
        click(at(1.4, 1.5))
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge] && store.filmTime == 1.4)
        let a = at(1, 3.5)
        press(a)
        pull(from: a, to: at(0.1, 2.5))
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)] && store.selection == [card])
        #expect(hand.cancel())
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
        #expect(hand.marquee == nil && hand.drag?.kind == .nothing)
        // The rest of the drag does nothing, and letting go leaves the playhead where it was.
        pull(from: a, to: at(0.1, 0.4))
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && hand.marquee == nil)
        letGo()
        #expect(hand.drag == nil && store.filmTime == 1.4 && store.selection == [badge])
        // With no marquee in hand there is nothing to give up.
        #expect(!hand.cancel())
        // Pressed and not yet dragged, the keys were let go of: those are given back too.
        press(a)
        #expect(store.film.keys.isEmpty)
        #expect(hand.cancel() && store.film.keys == [FilmKeyRef(badge, at: 1.4)])
        letGo()
        #expect(store.filmTime == 1.4)
        // With Shift: what was added is let go of, and what was let go of is picked again.
        press(a, flags: .shift)
        pull(from: a, to: at(0.7, 1.2), flags: .shift)
        #expect(store.film.keys.count == 3 && store.selection == [badge, card])
        pull(from: a, to: at(1.45, 1.2), flags: .shift)
        #expect(store.film.keys.isEmpty && store.selection == [badge])
        #expect(hand.cancel())
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
        letGo(flags: .shift)
        // The camera and its key, picked before a marquee caught layers' keys, are picked again.
        click(at(1, 0.5))
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1)])
        let c = at(1.2, 3.5)
        press(c)
        pull(from: c, to: at(0.1, 2.5))
        #expect(store.selection == [card] && !store.film.camera && store.film.keys.count == 3)
        #expect(hand.cancel())
        #expect(store.film.camera && store.selection.isEmpty && store.film.keys == [FilmKeyRef(board, at: 1)])
        letGo()
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1)] && store.filmTime == 1)
        // A key that is dragged is put back by it as well, and leaves nothing to undo
        // (`FilmEscapeTests` has every drag the timeline takes).
        bench.step {
            press(at(1, 0.5))
            pull(from: at(1, 0.5), to: at(1.2, 0.5))
            #expect(hand.drag?.kind == .keys && hand.cancel() && hand.drag?.kind == .nothing)
            letGo()
        }
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1])
        #expect(store.doc == before && bench.undo.undoActionName != String(localized: "Move Key"))
    }

    /// Of a key pressed while a drag is in SwiftUI's hand the app is told nothing, so the hand
    /// asks whether Escape is down: at every step of the drag, and between them while anything
    /// is in hand, as its timer does with `heed`.
    @Test func escapeIsAskedOfTheKeyboardOnlyWhileSomethingIsInHand() {
        nonisolated final class Key: @unchecked Sendable { var down = false, asked = 0 }
        let key = Key()
        hand.escapeDown = { key.asked += 1; return key.down }
        click(at(1, 0.5))
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1)])
        // Nothing in hand: the keyboard is not asked, and Escape held changes nothing.
        key.down = true
        #expect(!hand.heed() && key.asked == 0)
        // A key dragged with Escape held is given up at its first step, and stays where it was.
        drag(at(1, 0.5), at(1.2, 0.5))
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1] && key.asked == 1)
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1)])
        // Not held, it is asked at every step, and the key goes.
        key.down = false
        drag(at(1, 0.5), at(1.2, 0.5))
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1.2] && key.asked == 5)
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1.2)])
        let head = store.filmTime
        // A marquee: asked at each step.
        let a = at(0.9, 3.5)
        press(a)
        pull(from: a, to: at(0.1, 2.5))
        #expect(store.selection == [card] && !store.film.camera && store.film.keys.count == 3 && key.asked == 6)
        #expect(!hand.heed() && key.asked == 7)
        // Escape goes down while the pointer rests: the next look gives the marquee up.
        key.down = true
        #expect(hand.heed())
        #expect(store.film.camera && store.selection.isEmpty && store.film.keys == [FilmKeyRef(board, at: 1.2)])
        #expect(hand.marquee == nil && hand.drag?.kind == .nothing)
        // Still down, there is nothing more to give up, the keyboard is not asked again, and
        // the rest of the drag does nothing.
        let asked = key.asked
        #expect(!hand.heed())
        pull(from: a, to: at(0.1, 0.4))
        letGo()
        #expect(key.asked == asked && hand.drag == nil)
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1.2)] && store.filmTime == head)
        // Down as the pointer moves on: the step that would have grown the marquee gives it up.
        key.down = false
        press(a)
        pull(from: a, to: at(0.7, 2.5))
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)] && store.selection == [card])
        key.down = true
        pull(from: a, to: at(0.1, 2.5))
        #expect(hand.marquee == nil && store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1.2)])
        letGo()
        // Held as bare sheet is pressed, nothing comes of the press but that it is given up.
        press(a)
        #expect(hand.heed() && hand.drag?.kind == .nothing)
        letGo()
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1.2)] && store.filmTime == head)
        // What the card asks is the keyboard itself. Whether somebody holds Escape while the
        // tests run is not theirs to say, so only that it answers is asked here.
        _ = FilmHand.escapeOnKeyboard()
    }

    /// While the pointer rests no step of the drag comes, so the hand looks by itself while a
    /// marquee is in it: also while the app follows a press, when its run loop hears nothing
    /// but what belongs to the press.
    @Test func escapeIsHeardWhileThePointerRests() {
        nonisolated final class Key: @unchecked Sendable { var down = false, asked = 0 }
        let key = Key()
        hand.escapeDown = { key.asked += 1; return key.down }
        func wait(_ mode: RunLoop.Mode, upTo seconds: Double = 2, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01)) }
        }
        click(at(1.4, 1.5))
        let a = at(1, 3.5)
        for mode in [RunLoop.Mode.eventTracking, .default] {
            press(a)
            pull(from: a, to: at(0.1, 2.5))
            #expect(store.film.keys.count == 3 && store.selection == [card] && hand.marquee != nil)
            // Not down: it is asked again and again, and the marquee stays as it is.
            let asked = key.asked
            wait(mode) { key.asked >= asked + 3 }
            #expect(key.asked >= asked + 3 && hand.marquee != nil && store.film.keys.count == 3)
            // Down: given up without a step of the drag.
            key.down = true
            wait(mode) { hand.marquee == nil }
            #expect(hand.marquee == nil && hand.drag?.kind == .nothing)
            #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
            // Given up, nothing looks any more, whatever the key does.
            let after = key.asked
            wait(mode, upTo: 0.1) { false }
            #expect(key.asked == after)
            letGo()
            key.down = false
        }
        // Nor once it is let go of.
        drag(a, at(0.1, 2.5))
        #expect(store.film.keys.count == 3 && hand.drag == nil)
        let after = key.asked
        wait(.default, upTo: 0.1) { false }
        #expect(key.asked == after)
        // A key held still is looked out for as a marquee is, and given up without a step.
        press(at(0.8, 2.5))
        wait(.default) { key.asked >= after + 3 }
        #expect(key.asked >= after + 3 && hand.drag?.kind == .keys)
        key.down = true
        wait(.default) { hand.drag?.kind == .nothing }
        #expect(hand.drag?.kind == .nothing && store.film.keys.count == 3)
        letGo()
        key.down = false
    }

    // MARK: Lines as they show

    @Test func aLayersOpenedLinesAreCaughtEachAsItShows() {
        store.film.open = [card]
        #expect(rows.map(\.name) == ["Camera", "Badge", "Card", MotionProperty.move.title, MotionProperty.fade.title])
        let a = at(1, 5.5)
        press(a)
        // The fade's line alone: its keys, and no others at their moments.
        pull(from: a, to: at(0.1, 4.5))
        #expect(store.film.keys == [FilmKeyRef(card, .fade, at: 0.2), FilmKeyRef(card, .fade, at: 0.6)])
        #expect(store.selection == [card])
        // The move's line too: each property's own.
        pull(from: a, to: at(0.1, 3.5))
        #expect(store.film.keys == [FilmKeyRef(card, .fade, at: 0.2), FilmKeyRef(card, .fade, at: 0.6),
                                    FilmKeyRef(card, .move, at: 0.2), FilmKeyRef(card, .move, at: 0.8)])
        // The layer's own line with them: its beads stand for every key at their moments.
        pull(from: a, to: at(0.1, 2.5))
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)])
        letGo()
        // A property's keys picked by it move alone.
        press(a)
        pull(from: a, to: at(0.1, 4.5))
        letGo()
        drag(at(0.6, 4.5), at(0.7, 4.5))
        #expect(keys("Card", .fade) == [0.3, 0.7] && keys("Card", .move) == [0.2, 0.8])
        #expect(store.film.keys == [FilmKeyRef(card, .fade, at: 0.3), FilmKeyRef(card, .fade, at: 0.7)])
    }

    @Test func theCamerasLinesPickTheCameraAndGiveBackWhatWasPicked() {
        store.selection = [card]
        store.film.open = [board]
        #expect(rows.map(\.name) == ["Camera", MotionProperty.cameraZoom.title, "Badge", "Card"])
        // From bare sheet on the zoom's line, past its last key.
        let a = at(1.3, 1.5)
        press(a)
        pull(from: a, to: at(0.9, 1.6))
        #expect(store.film.keys == [FilmKeyRef(board, .cameraZoom, at: 1)])
        // Only the camera's keys are caught: the camera is picked, and no layer.
        #expect(store.film.camera && store.selection.isEmpty)
        pull(from: a, to: at(0.9, 0.5))
        #expect(store.film.keys == [FilmKeyRef(board, at: 1)] && store.film.camera)
        // Off them again, the card is picked as before.
        pull(from: a, to: at(1.2, 1.6))
        #expect(store.film.keys.isEmpty && !store.film.camera && store.selection == [card])
        pull(from: a, to: at(0.9, 1.6))
        letGo()
        #expect(store.film.keys == [FilmKeyRef(board, .cameraZoom, at: 1)] && store.film.camera && store.selection.isEmpty)
        // Its key moves, and is taken away, alone.
        drag(at(1, 1.5), at(1.3, 1.5))
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1.3])
        bench.step { store.removeFilmKeys() }
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0])
        #expect(keys("Card", .move) == [0.2, 0.8] && keys("Badge", .scale) == [0, 0.8, 1.4])
    }

    @Test func aShadersInputsAreCaughtOnTheirOwnLines() {
        let bench = Bench(extra: ShaderKeyTests.painted)
        let store = bench.store, hand = FilmHand(store: store)
        store.show(.animate)
        store.glide.stop()
        let card = bench.node("Card")!.id
        bench.step {
            store.edit("Add Key") { doc in
                doc.update(card) { n in
                    n.setInputKey("u_strength", change: [-0.5], at: 0)
                    n.setInputKey("u_strength", change: [0], at: 1)
                    n.setKey(.move, [10, 0], at: 0.5)
                    n.setKey(.move, [0, 0], at: 1)
                }
            }
        }
        store.film.open = [card]
        let rows = FilmRow.rows(of: store.filmBoard!, open: store.film.open)
        #expect(rows.map(\.name) == ["Camera", "Card", MotionProperty.move.title, "u_strength"])
        let scale = hand.scale(width: width), length = store.filmBoard!.filmLength
        func at(_ t: Double, _ lines: CGFloat) -> CGPoint { CGPoint(x: scale.x(t), y: lines * FilmTimeline.rowHeight) }
        // The input's line alone, round its key at one second.
        let a = at(1.3, 4.5), b = at(0.9, 3.5)
        hand.press(at: a, rows: rows, scale: scale)
        hand.dragged(to: b, by: b.x - a.x, rows: rows, scale: scale, length: length)
        hand.ended(scale: scale)
        #expect(store.film.keys == [FilmKeyRef(card, input: "u_strength", at: 1)] && store.selection == [card])
        bench.step { store.removeFilmKeys() }
        #expect((bench.node("Card")?[track: ShaderFill.inputTrack("u_strength")]?.keys ?? []).map(\.t) == [0])
        #expect((bench.node("Card")?[track: .move]?.keys ?? []).map(\.t) == [0.5, 1])
        // Folded, the layer's bead is the input's key and the move's at that moment alike.
        store.film.open = []
        let folded = FilmRow.rows(of: store.filmBoard!, open: [])
        #expect(folded.map { $0.marks.map(\.t) } == [[], [0, 0.5, 1]])
        let c = at(0.2, 2.5), d = at(-0.04, 1.5)
        hand.press(at: c, rows: folded, scale: scale)
        hand.dragged(to: d, by: d.x - c.x, rows: folded, scale: scale, length: length)
        hand.ended(scale: scale)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0)])
        bench.step { store.removeFilmKeys() }
        #expect(bench.node("Card")?[track: ShaderFill.inputTrack("u_strength")] == nil)
        #expect((bench.node("Card")?[track: .move]?.keys ?? []).map(\.t) == [0.5, 1])
    }

    // MARK: Looked at closer

    @Test func atACloserLookItCatchesWhatItTouchesThere() {
        hand.zoom(by: 4, at: scale.x(0.6), scale: scale)
        #expect(abs(scale.start - 0.45) < 1e-9 && abs(Double(scale.perSecond) - 1029.6) < 1e-6)
        let a = at(0.95, 3.5)
        press(a)
        // Six points short of the bead at 0.8, it does not touch it; three points short, it does.
        var b = CGPoint(x: scale.x(0.8) + 6, y: at(0, 2.5).y)
        pull(from: a, to: b)
        #expect(hand.marquee != nil && store.film.keys.isEmpty)
        b.x = scale.x(0.8) + 3
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)])
        // It lies where it was dragged, in the sheet's points as it shows now.
        let r = hand.marquee!.rect(on: scale)
        #expect(closeBy(r.origin, CGPoint(x: b.x, y: 60)) && abs(r.maxX - a.x) < 0.01 && abs(r.maxY - a.y) < 0.01)
        // The beads either side of it in time are far from it here, however near they are on the whole film.
        b = at(0.7, 1.5)
        pull(from: a, to: b)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        // Two fingers move the sheet along under the pointer: it reaches from where it was
        // pressed to the moment that is under the pointer now.
        hand.scroll(by: 206, scale: scale)
        #expect(abs(scale.start - (0.45 - 206 / 1029.6)) < 1e-9)
        #expect(abs((hand.marquee?.from ?? 0) - 0.95) < 1e-9 && abs((hand.marquee?.to ?? 0) - (0.7 - 206 / 1029.6)) < 1e-9)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        // And a pinch back out to the whole film leaves it over the same moments.
        hand.zoom(by: 0.1, at: b.x, scale: scale)
        #expect(store.film.window == nil)
        #expect(abs((hand.marquee?.from ?? 0) - 0.95) < 1e-9)
        letGo()
        #expect(hand.marquee == nil)
    }

    @Test func draggedPastTheEndOfWhatShowsItCreepsAndKeepsWhatItCaught() {
        hand.zoom(by: 4, at: scale.x(0.6), scale: scale)
        let began = scale
        // Pressed under the last line at half a second, and dragged up and out past the last moment in sight.
        let a = at(0.5, 3.5)
        press(a)
        // Within the sheet nothing creeps.
        pull(from: a, to: at(0.9, 0.4))
        #expect(!hand.creep(0.1) && scale == began)
        let out = CGPoint(x: width - FilmScale.inset + 40, y: 0.4 * FilmTimeline.rowHeight)
        pull(from: a, to: out)
        // It reaches to the sheet's own edge, and no further than shows.
        #expect(abs((hand.marquee?.to ?? 0) - scale.t(width)) < 1e-9)
        let first: Set = [FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8), FilmKeyRef(board, at: 1)]
        #expect(store.film.keys == first && store.selection == [badge, card])
        // Forty points past: along at 520 points a second, as under anything dragged there.
        #expect(hand.creep(0.1))
        #expect(abs(scale.start - (began.start + 52 / Double(began.perSecond))) < 1e-9)
        // It still begins at the moment it was pressed at, which is out of sight now, and ends at the sheet's edge.
        #expect(abs((hand.marquee?.from ?? 0) - 0.5) < 1e-9 && scale.start > 0.5)
        #expect(abs((hand.marquee?.to ?? 0) - scale.t(width)) < 1e-9)
        #expect(store.film.keys == first)
        // On to the film's end: the badge's last key comes under it, and all it caught on the
        // way is still picked, though none of it is in sight.
        var steps = 0
        while hand.creep(0.1), steps < 500 { steps += 1 }
        #expect(steps < 500 && abs(scale.start + scale.span - store.filmWhole) < 1e-9)
        #expect(store.film.keys == first.union([FilmKeyRef(badge, at: 1.4)]))
        #expect(store.film.keys.allSatisfy { $0.time < scale.start })
        #expect(hand.marquee!.rect(on: scale).minX < -1000)
        // Back within the sheet it creeps no more, and holds them still.
        pull(from: a, to: CGPoint(x: 300, y: out.y))
        #expect(!hand.creep(0.1))
        #expect(store.film.keys == first.union([FilmKeyRef(badge, at: 1.4)]))
        // Past the first moment in sight it creeps back, letting go of what it leaves behind.
        let back = CGPoint(x: -30, y: out.y)
        pull(from: a, to: back)
        while scale.start > 1.2, hand.creep(0.1) {}
        #expect(scale.start <= 1.2 && scale.start > 1.1)
        #expect(store.film.keys == first)
        steps = 0
        while hand.creep(0.1), steps < 500 { steps += 1 }
        #expect(steps < 500 && scale.start == 0)
        // Across the moment it was pressed at, to the film's start: what lies before that moment now.
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(badge, at: 0), FilmKeyRef(board, at: 0)])
        letGo()
        // Let go, it creeps no more, and what it caught stays picked.
        #expect(!hand.creep(0.1))
        #expect(store.film.keys.count == 3 && store.selection == [badge, card])
    }

    @Test func itCreepsOnlyOnceItIsUnderWayAndNeverOverAWholeFilm() {
        hand.zoom(by: 4, at: scale.x(0.6), scale: scale)
        // Pressed in the last points of the sheet, where a drag creeps: not before it is one.
        let a = CGPoint(x: width - 5, y: 3.5 * FilmTimeline.rowHeight)
        press(a)
        pull(from: a, to: a)
        #expect(hand.drag?.kind == .marquee && !hand.creep(0.1))
        pull(from: a, to: CGPoint(x: a.x, y: a.y - 12))
        #expect(hand.marquee != nil && hand.creep(0.1))
        // Given up at Escape, it creeps no more.
        #expect(hand.cancel() && !hand.creep(0.1))
        letGo()
        // The whole film has nowhere to creep to: the marquee ends at the sheet's edge.
        store.film.window = nil
        let b = at(1.8, 3.5), out = CGPoint(x: width + 200, y: 1.5 * FilmTimeline.rowHeight)
        press(b)
        pull(from: b, to: out)
        #expect(!hand.creep(0.1) && store.film.window == nil)
        #expect(abs((hand.marquee?.to ?? 0) - scale.t(width)) < 1e-9)
        #expect(store.film.keys.isEmpty)
        // And at its other side, where the film starts.
        pull(from: b, to: CGPoint(x: -200, y: out.y))
        #expect(abs((hand.marquee?.to ?? 0) - scale.t(0)) < 1e-9)
        #expect(store.film.keys == [FilmKeyRef(badge, at: 0), FilmKeyRef(badge, at: 0.8), FilmKeyRef(badge, at: 1.4),
                                    FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.6), FilmKeyRef(card, at: 0.8)])
        letGo()
    }

    // MARK: More lines than show

    /// A film of nine layers that fade in over a second, with the camera's line ten lines: the
    /// card shows seven of them, from `linesTop` down, and scrolls the rest.
    private struct Tall {
        let bench: Bench
        let hand: FilmHand
        /// Where the hand has had the card's lines scrolled to, in order.
        let scrolled: Scrolled
        final class Scrolled { var tops: [CGFloat] = [] }

        init() {
            let names = (1...9).map { "L\($0)" }
            let bench = Bench(extra: names.enumerated().map { i, name in CanvasTests.rect(name, CGRect(x: 10 + CGFloat(i) * 40, y: 20, width: 30, height: 30)) })
            let hand = FilmHand(store: bench.store), scrolled = Scrolled()
            self.bench = bench
            self.hand = hand
            self.scrolled = scrolled
            bench.store.show(.animate)
            bench.store.glide.stop()
            let ids = names.map { bench.node($0)!.id }
            bench.step {
                bench.store.edit("Add Key") { doc in
                    for id in ids { doc.update(id) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 1) } }
                }
            }
            hand.scrollsLines = { scrolled.tops.append($0) }
        }

        var store: DocumentStore { bench.store }
        var rows: [FilmRow] { FilmRow.rows(of: store.filmBoard!, open: []) }
        var scale: FilmScale { hand.scale(width: 600) }
        /// A point of the lines at a moment, so many lines down from the first, wherever they are scrolled.
        func at(_ t: Double, _ lines: CGFloat) -> CGPoint { CGPoint(x: scale.x(t), y: lines * FilmTimeline.rowHeight) }
        /// The keys at one second of these lines.
        func caught(_ lines: ClosedRange<Int>) -> Set<FilmKeyRef> { Set(rows[lines].map { FilmKeyRef($0.layer, at: 1) }) }
        func press(_ p: CGPoint) { hand.press(at: p, rows: rows, scale: scale) }
        func pull(from a: CGPoint, to b: CGPoint) {
            hand.dragged(to: b, by: b.x - a.x, rows: rows, scale: scale, length: store.filmBoard!.filmLength)
        }
    }

    @Test func inAFilmOfMoreLinesThanShowItScrollsThemAndPicksWhatComesIntoSight() {
        let tall = Tall()
        let hand = tall.hand, store = tall.store
        #expect(tall.rows.count == 10 && FilmHand.sight(of: 10) == 168)
        // Pressed on bare sheet past the keys of the fifth line, dragged back over its beads at
        // one second and down to the seventh.
        let a = tall.at(1.5, 4.5)
        tall.press(a)
        tall.pull(from: a, to: tall.at(0.9, 6.5))
        #expect(store.film.keys == tall.caught(4...6))
        #expect(!hand.creep(0.1) && hand.linesTop == 0)
        // Thirty points past the foot of the lines in sight: it reaches no further than they show,
        // and catches nothing of the lines out of sight.
        let down = CGPoint(x: tall.scale.x(0.9), y: 168 + 30)
        tall.pull(from: a, to: down)
        #expect(hand.marquee?.foot == 168 && store.film.keys == tall.caught(4...6))
        // The lines scroll up under it at 400 points a second, and it catches what comes into sight.
        #expect(hand.creep(0.1))
        #expect(abs(hand.linesTop - 40) < 1e-9 && tall.scrolled.tops == [hand.linesTop])
        #expect(abs((hand.marquee?.foot ?? 0) - 208) < 1e-9 && store.film.keys == tall.caught(4...8))
        // To the last line, and no further.
        var steps = 0
        while hand.creep(0.1), steps < 100 { steps += 1 }
        #expect(steps == 1 && hand.linesTop == 72 && hand.marquee?.foot == 240)
        #expect(store.film.keys == tall.caught(4...9) && store.selection == tall.rows[4...9].map(\.layer))
        // Back within the lines in sight it scrolls no more, and lets go of what it no longer covers.
        tall.pull(from: a, to: tall.at(0.9, 6))
        #expect(!hand.creep(0.1) && hand.linesTop == 72)
        #expect(store.film.keys == tall.caught(4...5))
        // Past their top, the lines scroll down under it, to the first.
        tall.pull(from: a, to: tall.at(0.9, 2))
        #expect(hand.marquee?.foot == 72 && store.film.keys == tall.caught(3...4))
        steps = 0
        while hand.creep(0.1), steps < 100 { steps += 1 }
        #expect(steps < 100 && hand.linesTop == 0 && hand.marquee?.foot == 0)
        #expect(store.film.keys == tall.caught(1...4))
        hand.ended(scale: tall.scale)
        // Let go, what it caught stays picked, and the lines stay where they are.
        #expect(store.film.keys == tall.caught(1...4) && hand.linesTop == 0 && !hand.creep(0.1))
        #expect(tall.scrolled.tops.last == 0)
    }

    @Test func escapeScrollsTheLinesBackWhereTheyWere() {
        let tall = Tall()
        let hand = tall.hand, store = tall.store
        // The lines scrolled by hand a line down, and a key picked.
        hand.linesTop = 24
        tall.bench.step {
            tall.press(tall.at(1, 2.5))
            hand.ended(scale: tall.scale)
        }
        let picked = tall.caught(2...2)
        #expect(store.film.keys == picked)
        let a = tall.at(1.5, 3.5)
        tall.press(a)
        tall.pull(from: a, to: CGPoint(x: tall.scale.x(0.9), y: 24 + 168 + 60))
        while hand.creep(0.1) {}
        #expect(hand.linesTop == 72 && store.film.keys == tall.caught(3...9))
        #expect(hand.cancel())
        #expect(hand.linesTop == 24 && tall.scrolled.tops.last == 24)
        #expect(store.film.keys == picked && store.selection == [tall.rows[2].layer] && hand.marquee == nil)
        hand.ended(scale: tall.scale)
        #expect(store.film.keys == picked && hand.linesTop == 24)
    }

    @Test func aFilmOfSevenLinesOrFewerNeverScrollsThem() {
        #expect(rows.count == 3)
        let a = at(1, 3.5)
        press(a)
        pull(from: a, to: CGPoint(x: scale.x(0.1), y: 400))
        #expect(!hand.creep(0.1) && hand.linesTop == 0)
        // Reaching as far as the four lines the card shows of it.
        #expect(hand.marquee?.foot == FilmHand.sight(of: 3) && FilmHand.sight(of: 3) == 96)
        pull(from: a, to: CGPoint(x: scale.x(0.1), y: -300))
        #expect(!hand.creep(0.1) && hand.marquee?.foot == 0)
        letGo()
        // Slowly just past the lines, faster further out, and not at all within them.
        #expect(FilmHand.climbRate(at: 100, sight: 168) == 0 && FilmHand.climbRate(at: 0, sight: 168) == 0)
        #expect(FilmHand.climbRate(at: 170, sight: 168) == 64 && FilmHand.climbRate(at: -2, sight: 168) == -64)
        #expect(FilmHand.climbRate(at: 1000, sight: 168) == 1600)
    }

    // MARK: What it tells

    /// As it grows the marquee is drawn again at every step, and nothing else: the keys and
    /// the layers are set only when it catches or lets go of one, or every line of the timeline
    /// would be drawn again with it.
    @Test func growingItTellsOfThePickedKeysOnlyWhenTheyChange() {
        let a = at(1, 3.5)
        press(a)
        pull(from: a, to: at(0.95, 3.2))
        nonisolated final class Told: @unchecked Sendable { var what: Set<String> = [] }
        let told = Told()
        func watch() {
            withObservationTracking {
                _ = (store.film.keys, store.selection, store.film.camera, hand.drag, hand.held, hand.hot)
            } onChange: { told.what.insert("picked") }
            withObservationTracking {
                _ = hand.marquee
            } onChange: { told.what.insert("marquee") }
        }
        watch()
        pull(from: a, to: at(0.9, 2.8))
        #expect(told.what == ["marquee"])
        told.what = []
        watch()
        pull(from: a, to: at(0.7, 2.5))
        #expect(told.what == ["marquee", "picked"])
        // The same keys under it still: only the marquee.
        told.what = []
        watch()
        pull(from: a, to: at(0.65, 2.4))
        #expect(told.what == ["marquee"])
        // And held still, nothing at all.
        told.what = []
        watch()
        pull(from: a, to: at(0.65, 2.4))
        #expect(told.what.isEmpty)
        letGo()
    }

    // MARK: The arithmetic

    @Test func aMarqueeCatchesTheBeadsItTouchesWhicheverWayItWasDragged() {
        let a = UUID(), b = UUID()
        func mark(_ t: Double) -> FilmRow.Mark { FilmRow.Mark(t: t, home: false, given: false) }
        var whole = FilmRow(id: "a", layer: a, name: "A")
        whole.marks = [mark(1), mark(2)]
        var move = FilmRow(id: "a:move", layer: a, property: .move, name: "Move")
        move.marks = [mark(1)]
        var input = FilmRow(id: "a:u", layer: a, input: "u", name: "u")
        input.marks = [mark(2)]
        var other = FilmRow(id: "b", layer: b, name: "B")
        other.marks = [mark(1.5)]
        let rows = [whole, move, input, other]
        // Fifty points to the second, lines twenty points tall: a bead is caught within four
        // points of its middle, which is 0.08 s here.
        let scale = FilmScale(width: 228, span: 4)
        #expect(scale.perSecond == 50)
        func caught(_ from: Double, _ to: Double, _ top: CGFloat, _ foot: CGFloat) -> Set<FilmKeyRef> {
            FilmMarquee(from: from, to: to, top: top, foot: foot).keys(of: rows, line: 20, scale: scale)
        }
        // Along the first line: from just within reach of the bead at one second, or just out of it.
        #expect(caught(1.07, 3, 0, 10) == [FilmKeyRef(a, at: 1), FilmKeyRef(a, at: 2)])
        #expect(caught(1.09, 3, 0, 10) == [FilmKeyRef(a, at: 2)])
        #expect(caught(0, 1.93, 0, 10) == [FilmKeyRef(a, at: 1), FilmKeyRef(a, at: 2)])
        #expect(caught(0, 1.91, 0, 10) == [FilmKeyRef(a, at: 1)])
        // Dragged the other way, or upwards, it is the same marquee.
        #expect(caught(3, 1.09, 10, 0) == [FilmKeyRef(a, at: 2)])
        // Down the lines: a line is caught within four points of its middle.
        #expect(caught(0, 4, 13.5, 14) == [FilmKeyRef(a, at: 1), FilmKeyRef(a, at: 2)])
        #expect(caught(0, 4, 14.5, 25.5).isEmpty)
        #expect(caught(0, 4, 14.5, 26.5) == [FilmKeyRef(a, .move, at: 1)])
        // A property's and an input's line give their own keys.
        #expect(caught(0, 4, 30, 50) == [FilmKeyRef(a, .move, at: 1), FilmKeyRef(a, input: "u", at: 2)])
        #expect(caught(0, 4, 30, 70) == [FilmKeyRef(a, .move, at: 1), FilmKeyRef(a, input: "u", at: 2), FilmKeyRef(b, at: 1.5)])
        // Under the layer's line with them, the layer's beads stand for them.
        #expect(caught(0, 4, 10, 70) == [FilmKeyRef(a, at: 1), FilmKeyRef(a, at: 2), FilmKeyRef(b, at: 1.5)])
        // A property's key at a moment the layer's line is not caught at is still its own.
        #expect(caught(0, 1.5, 10, 50) == [FilmKeyRef(a, at: 1)])
        #expect(caught(1.5, 4, 30, 50) == [FilmKeyRef(a, input: "u", at: 2)])
        // Over no line, or with none, nothing.
        #expect(caught(0, 4, 90, 200).isEmpty && caught(0, 4, -50, -10).isEmpty)
        #expect(FilmMarquee(from: 0, to: 4, top: 0, foot: 80).keys(of: [], line: 20, scale: scale).isEmpty)
        // Where it lies on a sheet, and on one moved along and looked at closer.
        #expect(FilmMarquee(from: 3, to: 1, top: 50, foot: 10).rect(on: scale) == CGRect(x: 64, y: 10, width: 100, height: 40))
        let closer = FilmScale(width: 228, span: 1, start: 0.5)
        #expect(FilmMarquee(from: 0, to: 1, top: 0, foot: 20).rect(on: closer) == CGRect(x: -86, y: 0, width: 200, height: 20))
    }
}
