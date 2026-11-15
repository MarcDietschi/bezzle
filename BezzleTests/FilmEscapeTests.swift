import Testing
import AppKit
@testable import Bezzle

/// Escape under every drag on the film's timeline (`FilmHand.cancel`, and `heed`, which asks the
/// keyboard for the key): a key, several keys, a line's band, the playhead and the film's end
/// dragged are given back to exactly where and what they were before the press came, with what
/// was picked, the playhead, the part of the film the sheet showed, and nothing to undo. The
/// marquee's own Escape is in `FilmMarqueeTests`.
@MainActor
struct FilmEscapeTests {
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

    /// A point of the ruler at a moment.
    private func ruler(_ t: Double) -> CGPoint { CGPoint(x: scale.x(t), y: 10) }

    private func press(_ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        hand.press(at: p, rows: rows, scale: scale, flags: flags, clicks: clicks)
    }

    private func pressRuler(_ p: CGPoint) {
        hand.pressRuler(at: p, scale: scale, length: length)
    }

    /// The press that was made at `a` moved on to `b`, on the sheet as it shows by now.
    private func pull(from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        hand.dragged(to: b, by: b.x - a.x, rows: rows, scale: scale, length: length, flags: flags)
    }

    private func letGo(flags: NSEvent.ModifierFlags = []) {
        hand.ended(scale: scale, flags: flags)
    }

    private func click(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        bench.step {
            press(p, flags: flags)
            letGo(flags: flags)
        }
    }

    /// Whether the last step left nothing to undo: here every step opens a group of the history,
    /// which stays there empty and nameless when nothing was put in it.
    private var nothingToUndo: Bool { bench.undo.undoActionName.isEmpty }

    // MARK: Keys

    @Test func aKeyDraggedIsGivenBackWithWhatWasPickedBeforeItsPress() {
        let before = store.doc
        click(at(1.4, 1.5))
        #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge] && store.filmTime == 1.4)
        let a = at(0.8, 2.5)
        bench.step {
            // The card's bead: its key and the card are picked as it is pressed.
            press(a)
            #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)] && store.selection == [card])
            pull(from: a, to: at(1.1, 2.5))
            #expect(keys("Card", .move) == [0.2, 1.1] && store.inGesture && hand.held != nil)
            #expect(hand.cancel())
            // Where it was, and what was picked before the press is picked again.
            #expect(keys("Card", .move) == [0.2, 0.8] && keys("Card", .fade) == [0.2, 0.6])
            #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge] && !store.film.camera)
            #expect(!store.inGesture && hand.held == nil && hand.drag?.kind == .nothing)
            // The rest of the drag does nothing, and letting go takes the playhead nowhere.
            pull(from: a, to: at(1.3, 2.5))
            #expect(keys("Card", .move) == [0.2, 0.8])
            letGo()
        }
        #expect(store.doc == before && store.filmTime == 1.4 && hand.drag == nil && nothingToUndo)
        // Given up, there is nothing more to give up.
        #expect(!hand.cancel())
    }

    @Test func severalKeysDraggedAreGivenBackTogether() {
        let before = store.doc
        click(at(0.2, 2.5))
        click(at(0.8, 2.5), flags: .shift)
        let picked: Set = [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.8)]
        #expect(store.film.keys == picked)
        let head = store.filmTime
        bench.step {
            let a = at(0.8, 2.5)
            press(a)
            pull(from: a, to: at(1.1, 2.5))
            #expect(keys("Card", .move) == [0.5, 1.1] && keys("Card", .fade) == [0.5, 0.6])
            #expect(hand.cancel())
            letGo()
        }
        #expect(store.doc == before && store.film.keys == picked && store.selection == [card] && store.filmTime == head && nothingToUndo)
    }

    @Test func aBandDraggedIsGivenBackWhole() {
        let before = store.doc
        click(at(1.4, 1.5))
        bench.step {
            // The card's band, between its keys.
            let a = at(0.4, 2.5)
            press(a)
            #expect(hand.drag?.kind == .band && store.selection == [card])
            pull(from: a, to: at(0.9, 2.5))
            #expect(keys("Card", .move) == [0.7, 1.3])
            #expect(hand.cancel())
            #expect(keys("Card", .move) == [0.2, 0.8] && keys("Card", .fade) == [0.2, 0.6])
            letGo()
        }
        // Not a click on the band either: the playhead stays.
        #expect(store.doc == before && store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
        #expect(store.filmTime == 1.4 && nothingToUndo)
    }

    @Test func aKeyDraggedPastTheEndGivesTheFilmBackItsLength() {
        let before = store.doc
        let span = scale.span
        bench.step {
            let a = at(1.4, 1.5)
            press(a)
            pull(from: a, to: at(2.3, 1.5))
            // A film that follows its keys grows, while the seconds are held still under the hand.
            #expect(keys("Badge", .scale) == [0, 0.8, 2.3] && length == 2.5 && hand.held == span)
            #expect(hand.cancel())
            #expect(length == 2 && hand.held == nil && scale.span == span)
            letGo()
        }
        #expect(store.doc == before && nothingToUndo)
    }

    @Test func aKeyPressedAndNotYetMovedGivesBackWhatItPicked() {
        click(at(1.4, 1.5))
        bench.step {
            press(at(0.8, 2.5))
            #expect(store.film.keys == [FilmKeyRef(card, at: 0.8)] && store.selection == [card])
            #expect(hand.cancel())
            #expect(store.film.keys == [FilmKeyRef(badge, at: 1.4)] && store.selection == [badge])
            letGo()
        }
        // A bead only clicked takes the playhead there; given up, it does not.
        #expect(store.filmTime == 1.4)
        // The camera picked before is picked again, and its keys.
        click(at(1, 0.5))
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(bench.a.id, at: 1)])
        bench.step {
            press(at(0.8, 2.5))
            #expect(!store.film.camera)
            #expect(hand.cancel())
            letGo()
        }
        #expect(store.film.camera && store.selection.isEmpty && store.film.keys == [FilmKeyRef(bench.a.id, at: 1)])
    }

    // MARK: The playhead and the film's end

    @Test func thePlayheadIsGivenBackWhereItWas() {
        store.seek(0.3)
        // Taken in the ruler.
        pressRuler(ruler(1.2))
        pull(from: ruler(1.2), to: ruler(1.65))
        #expect(store.filmTime == 1.65)
        #expect(hand.cancel())
        #expect(store.filmTime == 0.3 && store.film.live == 0.3)
        pull(from: ruler(1.2), to: ruler(1.8))
        letGo()
        #expect(store.filmTime == 0.3 && hand.drag == nil)
        // Taken by its line down the sheet.
        let p = CGPoint(x: scale.x(0.3), y: at(0, 3.5).y)
        press(p)
        #expect(hand.drag?.kind == .scrub)
        pull(from: p, to: at(1.5, 3.5))
        #expect(store.filmTime == 1.5)
        #expect(hand.cancel() && store.filmTime == 0.3)
        letGo()
        // A film that played as it was taken stops where it showed then: played on six tenths
        // of a second from where it rests, as its frames would have.
        store.playFilm()
        #expect(store.filmStep(CACurrentMediaTime() + 0.6) && store.film.playing)
        let showed = store.film.live
        #expect(showed > 0.85 && showed < 1)
        pressRuler(ruler(1.2))
        pull(from: ruler(1.2), to: ruler(1.6))
        #expect(!store.film.playing && store.filmTime == 1.6)
        #expect(hand.cancel())
        #expect(!store.film.playing && abs(store.filmTime - showed) < 0.001 && store.film.live == store.filmTime)
        letGo()
    }

    @Test func theFilmsEndIsGivenBackAndThePlayheadItTookAlong() {
        let before = store.doc
        store.seek(1.8)
        let flag = ruler(length)
        bench.step {
            pressRuler(flag)
            #expect(hand.drag?.kind == .length)
            pull(from: flag, to: ruler(0.5))
            // Cut short, the film took the playhead back inside it.
            #expect(store.filmBoard?.film?.length == 0.5 && store.filmTime == 0.5)
            #expect(hand.cancel())
            #expect(store.filmBoard?.film == nil && length == 2 && store.filmTime == 1.8 && hand.held == nil)
            letGo()
        }
        #expect(store.doc == before && nothingToUndo)
        // A length that was set is set again.
        bench.step { store.setFilm("Film Length") { $0.length = 1.5 } }
        let set = store.doc
        bench.step {
            let flag = ruler(1.5)
            pressRuler(flag)
            pull(from: flag, to: ruler(1))
            #expect(store.filmBoard?.film?.length == 1)
            #expect(hand.cancel())
            letGo()
        }
        #expect(store.doc == set && store.filmBoard?.film?.length == 1.5 && nothingToUndo)
        // Under the empty step, the length that was set, and under it the design as it was.
        bench.undo.undo()
        #expect(bench.undo.undoActionName == String(localized: "Film Length"))
        bench.undo.undo()
        #expect(store.doc == before)
    }

    @Test func aClickTwiceOnALineOrOnTheFlagIsNoDragToGiveBack() {
        bench.step {
            press(at(0.4, 2.5), clicks: 2)
            #expect(keys("Card", .move) == [0.2, 0.4, 0.8])
            #expect(!hand.cancel())
            letGo()
        }
        #expect(keys("Card", .move) == [0.2, 0.4, 0.8])
    }

    // MARK: The keyboard

    /// Of Escape the app is told nothing while SwiftUI follows a press, so the hand asks the
    /// keyboard (`heed`): at every step of whatever is dragged.
    @Test func escapeHeldGivesBackWhateverIsDragged() {
        nonisolated final class Key: @unchecked Sendable { var down = false }
        let key = Key()
        hand.escapeDown = { key.down }
        let before = store.doc
        store.seek(0.3)
        // Each taken, dragged, and given up at the step Escape is down at.
        func drag(_ press: () -> Void, from a: CGPoint, to b: CGPoint, check: () -> Void) {
            bench.step {
                press()
                pull(from: a, to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                key.down = true
                pull(from: a, to: b)
                #expect(hand.drag?.kind == .nothing)
                check()
                key.down = false
                letGo()
            }
        }
        drag({ pressRuler(ruler(1)) }, from: ruler(1), to: ruler(1.6)) { #expect(store.filmTime == 0.3) }
        drag({ pressRuler(ruler(length)) }, from: ruler(length), to: ruler(0.6)) { #expect(store.filmBoard?.film == nil && store.filmTime == 0.3) }
        drag({ press(at(0.8, 2.5)) }, from: at(0.8, 2.5), to: at(1.2, 2.5)) { #expect(keys("Card", .move) == [0.2, 0.8]) }
        drag({ press(at(0.4, 2.5)) }, from: at(0.4, 2.5), to: at(0.9, 2.5)) { #expect(keys("Card", .fade) == [0.2, 0.6]) }
        drag({ press(at(1.2, 3.5)) }, from: at(1.2, 3.5), to: at(0.1, 1.5)) { #expect(store.film.keys.isEmpty) }
        #expect(store.doc == before && store.filmTime == 0.3 && store.selection.isEmpty && store.film.keys.isEmpty)
    }

    // MARK: A sheet looked at closer

    @Test func aSheetThatCreptUnderWhatWasDraggedIsPutBackWhereItWas() {
        hand.zoom(by: 4, at: scale.x(0.6), scale: scale)
        let shown = store.film.window
        #expect(shown != nil)
        let before = store.doc
        let past = CGPoint(x: width - FilmScale.inset + 40, y: at(0, 2.5).y)
        // A key dragged past the last moment in sight: the sheet creeps along under it.
        bench.step {
            let a = at(0.8, 2.5)
            press(a)
            pull(from: a, to: past)
            #expect(hand.creep(0.1) && hand.creep(0.1))
            #expect(store.film.window != shown && keys("Card", .move).last! > 0.9)
            #expect(hand.cancel())
            #expect(store.film.window == shown && keys("Card", .move) == [0.2, 0.8])
            #expect(!hand.creep(0.1))
            letGo()
        }
        // The playhead the same.
        let head = store.filmTime
        pressRuler(ruler(0.7))
        pull(from: ruler(0.7), to: CGPoint(x: past.x, y: 10))
        #expect(hand.creep(0.1) && store.film.window != shown)
        #expect(hand.cancel() && store.film.window == shown && store.filmTime == head)
        letGo()
        // And a marquee: the part of the film it crept to is let go of with what it caught.
        let m = at(0.7, 3.5)
        press(m)
        pull(from: m, to: CGPoint(x: past.x, y: at(0, 0.4).y))
        #expect(hand.creep(0.1) && hand.creep(0.1) && store.film.window != shown && !store.film.keys.isEmpty)
        #expect(hand.cancel() && store.film.window == shown && store.film.keys.isEmpty)
        letGo()
        #expect(store.doc == before)
    }
}
