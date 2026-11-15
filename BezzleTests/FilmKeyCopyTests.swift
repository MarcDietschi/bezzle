import Testing
import AppKit
@testable import Bezzle

/// Keys copied in the timeline (`AnimateClipboard.swift`): Copy, Cut, Paste and Duplicate in the
/// Edit menu while Animate has keys picked, and Option held as a bead or a band is pressed. Pasted
/// keys go to the playhead, onto what they were copied from, or one layer's onto the layers picked;
/// they are picked then, in one step, and a design shared live keeps what others did meanwhile.
@MainActor
struct FilmKeyCopyTests {
    /// On artboard A: a card, a badge over it, a tag with no keys and a box (a group, which has no
    /// fill). The camera's line comes first, then the badge's, then the card's.
    let bench: Bench
    let hand: FilmHand
    /// How wide the sheet is taken to be.
    let width: CGFloat = 600

    init() {
        var box = Node(kind: .group, name: "Box", frame: CGRect(x: 300, y: 20, width: 60, height: 60))
        box.children = [CanvasTests.rect("Dot", CGRect(x: 0, y: 0, width: 20, height: 20))]
        bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
                              CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40)),
                              CanvasTests.rect("Tag", CGRect(x: 40, y: 200, width: 80, height: 30)),
                              box])
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
        // A bench begins with no keys copied (`Bench`).
        #expect(DocumentStore.filmClip == nil)
    }

    var store: DocumentStore { bench.store }
    private func id(_ name: String) -> UUID { bench.node(name)!.id }
    private var card: UUID { id("Card") }
    private var badge: UUID { id("Badge") }
    private var board: UUID { bench.a.id }
    private var scale: FilmScale { hand.scale(width: width) }
    private var rows: [FilmRow] { FilmRow.rows(of: store.filmBoard!, open: store.film.open) }
    private var length: Double { store.filmBoard!.filmLength }

    private func keys(_ name: String, _ property: MotionProperty) -> [Double] {
        (bench.node(name)?[track: property]?.keys ?? []).map(\.t)
    }

    private func key(_ name: String, _ property: MotionProperty, at t: Double) -> MotionKey? {
        bench.node(name)?[track: property]?.keys.first { MotionTiming.same($0.t, t) }
    }

    /// A point of the sheet: at a moment, so many lines down. 1.5 is the middle of the second line.
    private func at(_ t: Double, _ lines: CGFloat) -> CGPoint {
        CGPoint(x: scale.x(t), y: lines * FilmTimeline.rowHeight)
    }

    private func click(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        bench.step {
            hand.press(at: p, rows: rows, scale: scale, flags: flags)
            hand.ended(scale: scale, flags: flags)
        }
    }

    /// A press dragged to another point in four steps and let go, as one step. `pulling` are the
    /// keys held while it is pulled, where they are not the ones held as it is pressed.
    private func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = [], pulling: NSEvent.ModifierFlags? = nil) {
        bench.step {
            hand.press(at: a, rows: rows, scale: scale, flags: flags)
            for i in 1...4 {
                let k = CGFloat(i) / 4
                let p = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                hand.dragged(to: p, by: p.x - a.x, rows: rows, scale: scale, length: length, flags: pulling ?? flags)
            }
            hand.ended(scale: scale, flags: pulling ?? flags)
        }
    }

    /// The card's keys at 0.2 and 0.8 picked by their beads, the playhead left at 0.2.
    private func pickTheCardsEnds() {
        click(at(0.2, 2.5))
        click(at(0.8, 2.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.8)] && store.selection == [card])
    }

    // MARK: Copy and paste

    @Test func pastedKeysBeginAtThePlayheadKeepTheirDistancesAndArePicked() {
        pickTheCardsEnds()
        #expect(store.copyFilmKeys())
        store.seek(1.1)
        let copied = store.doc
        bench.step { store.pasteFilmKeys() }
        // The earliest on the playhead, the other as far from it: every key the beads stood for.
        #expect(keys("Card", .move) == [0.2, 0.8, 1.1, 1.7] && keys("Card", .fade) == [0.2, 0.6, 1.1])
        #expect(key("Card", .move, at: 1.1)?.v == [30, 0] && key("Card", .move, at: 1.7)?.v == [0, 0] && key("Card", .fade, at: 1.1)?.v == [0])
        #expect(store.film.keys == [FilmKeyRef(card, at: 1.1), FilmKeyRef(card, at: 1.7)] && store.selection == [card])
        #expect(keys("Badge", .scale) == [0, 0.8, 1.4] && store.filmTime == 1.1)
        // One step, to undo.
        #expect(bench.undo.undoActionName == String(localized: "Paste Keys"))
        bench.undo.undo()
        #expect(store.doc == copied)
        // What was copied stays copied: pasted again elsewhere, and once more, it comes down each time.
        store.seek(1.4)
        bench.step { store.pasteFilmKeys() }
        bench.step { store.seek(0); store.pasteFilmKeys() }
        #expect(keys("Card", .move) == [0, 0.2, 0.6, 0.8, 1.4, 2])
    }

    @Test func aKeyAlreadyWhereOneComesDownGivesWay() {
        click(at(0.2, 2.5))
        #expect(store.copyFilmKeys())
        store.seek(0.6)
        bench.step { store.pasteFilmKeys() }
        // The fade's key at 0.6 is the copied one now; the move has one more.
        #expect(keys("Card", .fade) == [0.2, 0.6] && key("Card", .fade, at: 0.6)?.v == [0])
        #expect(keys("Card", .move) == [0.2, 0.6, 0.8] && key("Card", .move, at: 0.6)?.v == [30, 0])
        // Pasted where they were copied from, keys are as they were, and nothing is left to undo.
        let now = store.doc
        click(at(0.2, 2.5))
        #expect(store.copyFilmKeys())
        store.seek(0.2)
        bench.step { store.pasteFilmKeys() }
        #expect(store.doc == now && bench.undo.undoActionName.isEmpty)
    }

    @Test func aPropertysOwnKeysArePastedAloneAndPickedSo() {
        store.film.open = [card]
        // Lines: camera, badge, card, its move, its fade.
        #expect(rows.map(\.name) == ["Camera", "Badge", "Card", MotionProperty.move.title, MotionProperty.fade.title])
        click(at(0.2, 4.5))
        click(at(0.6, 4.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, .fade, at: 0.2), FilmKeyRef(card, .fade, at: 0.6)])
        #expect(store.copyFilmKeys())
        store.seek(1)
        bench.step { store.pasteFilmKeys() }
        #expect(keys("Card", .fade) == [0.2, 0.6, 1, 1.4] && keys("Card", .move) == [0.2, 0.8])
        #expect(store.film.keys == [FilmKeyRef(card, .fade, at: 1), FilmKeyRef(card, .fade, at: 1.4)])
    }

    // MARK: Onto other layers, and the camera

    @Test func oneLayersKeysGoOntoTheLayersPicked() {
        pickTheCardsEnds()
        #expect(store.copyFilmKeys())
        let tag = id("Tag")
        store.selection = [tag, badge]
        store.seek(1)
        bench.step { store.pasteFilmKeys() }
        // Onto each layer picked, the card left as it was.
        #expect(keys("Tag", .move) == [1, 1.6] && keys("Tag", .fade) == [1])
        #expect(keys("Badge", .move) == [1, 1.6] && keys("Badge", .fade) == [1] && keys("Badge", .scale) == [0, 0.8, 1.4])
        #expect(keys("Card", .move) == [0.2, 0.8])
        // Picked as the timeline has their lines, the tag in front first.
        #expect(store.selection == [tag, badge])
        #expect(store.film.keys == [FilmKeyRef(tag, at: 1), FilmKeyRef(tag, at: 1.6), FilmKeyRef(badge, at: 1), FilmKeyRef(badge, at: 1.6)])
        bench.undo.undo()
        // With the card itself among those picked, onto it as well.
        store.selection = [card, tag]
        store.seek(1.2)
        bench.step { store.pasteFilmKeys() }
        #expect(keys("Card", .move) == [0.2, 0.8, 1.2, 1.8] && keys("Tag", .move) == [1.2, 1.8])
        bench.undo.undo()
        // Picked alone, or with nothing picked, onto the card.
        store.selection = []
        store.seek(1.2)
        bench.step { store.pasteFilmKeys() }
        #expect(keys("Card", .move) == [0.2, 0.8, 1.2, 1.8] && keys("Tag", .move).isEmpty)
        #expect(store.selection == [card])
    }

    @Test func theKeysOfTwoLayersGoBackOntoThemWhateverIsPicked() {
        // A marquee over the card's and the badge's keys at 0.8.
        let a = at(1, 3.5)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: at(0.7, 1.5), by: at(0.7, 1.5).x - a.x, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)])
        #expect(store.copyFilmKeys())
        store.selection = [id("Tag")]
        store.seek(1.6)
        bench.step { store.pasteFilmKeys() }
        #expect(keys("Card", .move) == [0.2, 0.8, 1.6] && keys("Badge", .scale) == [0, 0.8, 1.4, 1.6])
        #expect(bench.node("Tag")?.motion == nil)
        #expect(store.selection == [badge, card] && store.film.keys == [FilmKeyRef(card, at: 1.6), FilmKeyRef(badge, at: 1.6)])
    }

    @Test func theCamerasKeysGoOntoTheCamera() {
        click(at(1, 0.5))
        #expect(store.film.camera && store.film.keys == [FilmKeyRef(board, at: 1)])
        #expect(store.copyFilmKeys())
        // A layer picked is no place for them: they go to the camera, which is picked then.
        store.selection = [card]
        store.seek(1.5)
        bench.step { store.pasteFilmKeys() }
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0, 1, 1.5])
        #expect(store.filmBoard?[track: .cameraZoom]?.keys.last?.v == [2])
        #expect(keys("Card", .move) == [0.2, 0.8] && bench.node("Card")?.motion?.keys.contains { $0.hasPrefix("camera") } == false)
        #expect(store.film.camera && store.selection.isEmpty && store.film.keys == [FilmKeyRef(board, at: 1.5)])
        // On another artboard's film, onto its camera.
        bench.step { store.selection = [bench.b.id] }
        #expect(store.filmBoard?.id == bench.b.id)
        store.seek(0.5)
        bench.step { store.pasteFilmKeys() }
        #expect((store.filmBoard?[track: .cameraZoom]?.keys ?? []).map(\.t) == [0.5])
    }

    @Test func keysGoOnlyWhereTheyFit() {
        // The card's fill turns to a colour of its own at one second.
        bench.step {
            store.edit("Add Key") { doc in
                doc.update(card) { $0.setLookKey(.fill(0), change: [0, 0, 0, 0, 0], at: 1.2); $0.setLookKey(.fill(0), change: [0.2, 0, 0, 0, 1], at: 1.6) }
            }
        }
        store.film.open = [card]
        let fill = rows.firstIndex { $0.look == .fill(0) }!
        click(at(1.2, CGFloat(fill) + 0.5))
        click(at(1.6, CGFloat(fill) + 0.5), flags: .shift)
        #expect(store.film.keys == [FilmKeyRef(card, look: .fill(0), at: 1.2), FilmKeyRef(card, look: .fill(0), at: 1.6)])
        #expect(store.copyFilmKeys())
        // A group has no fill to take them: nothing comes down, and there is no step.
        store.selection = [id("Box")]
        let before = store.doc
        bench.step { store.pasteFilmKeys() }
        #expect(store.doc == before && bench.undo.undoActionName.isEmpty)
        // A rectangle has.
        store.selection = [id("Tag")]
        store.seek(0)
        bench.step { store.pasteFilmKeys() }
        #expect((bench.node("Tag")?[track: LookTrack.fill(0).name]?.keys ?? []).map(\.t) == [0, 0.4])
        #expect(bench.node("Tag")?.fits(.fill(0)) == true)
        #expect(store.film.keys == [FilmKeyRef(id("Tag"), look: .fill(0), at: 0), FilmKeyRef(id("Tag"), look: .fill(0), at: 0.4)])
    }

    // MARK: Cut

    @Test func cutTakesTheKeysAwayAsOneStepAndPasteBringsThemBack() {
        click(at(0.8, 2.5))
        let before = store.doc
        bench.step { store.cutFilmKeys() }
        #expect(keys("Card", .move) == [0.2] && keys("Card", .fade) == [0.2, 0.6] && store.film.keys.isEmpty)
        #expect(bench.undo.undoActionName == String(localized: "Cut Keys"))
        store.selection = [card]
        store.seek(1.5)
        bench.step { store.pasteFilmKeys() }
        #expect(keys("Card", .move) == [0.2, 1.5] && key("Card", .move, at: 1.5)?.v == [0, 0])
        bench.undo.undo()
        bench.undo.undo()
        #expect(store.doc == before)
    }

    // MARK: Duplicate

    @Test func duplicatePutsCopiesABeatAfterTheLastKeyPicked() {
        pickTheCardsEnds()
        let head = store.filmTime
        #expect(store.canDuplicate)
        bench.step { store.duplicate() }
        // Half a second after the last, as far apart as they are, and picked.
        #expect(keys("Card", .move) == [0.2, 0.8, 1.3, 1.9] && keys("Card", .fade) == [0.2, 0.6, 1.3])
        #expect(key("Card", .move, at: 1.3)?.v == [30, 0])
        #expect(store.film.keys == [FilmKeyRef(card, at: 1.3), FilmKeyRef(card, at: 1.9)] && store.selection == [card])
        #expect(store.filmTime == head && bench.undo.undoActionName == String(localized: "Duplicate Keys"))
        // Again: those copies, a beat after them.
        bench.step { store.duplicate() }
        #expect(keys("Card", .move) == [0.2, 0.8, 1.3, 1.9, 2.4, 3])
        // With no key picked, Duplicate is the layers' again.
        store.film.keys = []
        let layers = store.doc.allNodes.count
        bench.step { store.duplicate() }
        #expect(store.doc.allNodes.count == layers + 1 && store.selection != [card])
    }

    // MARK: Option, as the press comes

    @Test func optionAsABeadIsPressedLeavesItAndMovesACopy() {
        click(at(1.4, 1.5))
        let before = store.doc
        drag(at(0.8, 2.5), at(1.2, 2.5), flags: .option, pulling: [])
        #expect(keys("Card", .move) == [0.2, 0.8, 1.2] && key("Card", .move, at: 1.2)?.v == [0, 0])
        #expect(store.film.keys == [FilmKeyRef(card, at: 1.2)] && store.selection == [card])
        #expect(bench.undo.undoActionName == String(localized: "Duplicate Keys"))
        bench.undo.undo()
        #expect(store.doc == before)
        // Still held, Option steps finer, as it does any key in hand.
        drag(at(0.8, 2.5), at(1.234, 2.5), flags: .option)
        #expect(keys("Card", .move) == [0.2, 0.8, 1.23])
        bench.undo.undo()
        // Dragged back to where it was, it leaves nothing.
        bench.step {
            let a = at(0.8, 2.5)
            hand.press(at: a, rows: rows, scale: scale, flags: .option)
            hand.dragged(to: at(1.2, 2.5), by: 60, rows: rows, scale: scale, length: length)
            hand.dragged(to: a, by: 0, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(store.doc == before && bench.undo.undoActionName.isEmpty)
        // Given up with Escape, no copy is left, and what was picked before is again.
        click(at(1.4, 1.5))
        bench.step {
            let a = at(0.8, 2.5)
            hand.press(at: a, rows: rows, scale: scale, flags: .option)
            hand.dragged(to: at(1.2, 2.5), by: 60, rows: rows, scale: scale, length: length)
            #expect(keys("Card", .move) == [0.2, 0.8, 1.2])
            #expect(hand.cancel())
            hand.ended(scale: scale)
        }
        #expect(store.doc == before && store.film.keys == [FilmKeyRef(badge, at: 1.4)])
    }

    @Test func optionAsABandIsPressedCopiesTheWholeMotion() {
        // The card's band, between its keys, taken with Option and laid a second later.
        drag(at(0.4, 2.5), at(1.4, 2.5), flags: .option, pulling: [])
        #expect(keys("Card", .move) == [0.2, 0.8, 1.2, 1.8] && keys("Card", .fade) == [0.2, 0.6, 1.2, 1.6])
        #expect(bench.undo.undoActionName == String(localized: "Duplicate Keys"))
    }

    // MARK: The Edit menu

    @Test func theEditMenuCopiesCutsAndPastesKeysWhileSomeArePicked() {
        let canvas = bench.canvas
        func enabled(_ action: String) -> Bool {
            canvas.validateMenuItem(NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: ""))
        }
        // Nothing picked: no keys to copy, none copied to paste.
        store.selection = []
        #expect(!enabled("copy:") && !enabled("cut:") && !enabled("paste:") && !store.canDuplicate)
        // A key picked: Copy, Cut and Duplicate are of it.
        click(at(0.8, 2.5))
        #expect(enabled("copy:") && enabled("cut:") && !enabled("paste:") && store.canDuplicate)
        canvas.copy(nil)
        #expect(DocumentStore.filmClip?.refs == [FilmKeyRef(card, at: 0.8)] && enabled("paste:"))
        store.seek(1.5)
        bench.step { canvas.paste(nil) }
        #expect(keys("Card", .move) == [0.2, 0.8, 1.5])
        bench.step { canvas.cut(nil) }
        #expect(keys("Card", .move) == [0.2, 0.8] && store.film.keys.isEmpty)
        // Keys copied can be pasted with nothing picked.
        store.selection = []
        #expect(enabled("paste:"))
        // Copy with layers picked and no key copies the layers, and Paste has no keys to put down:
        // what was copied last is what is pasted.
        store.selection = [id("Tag")]
        #expect(store.pickedKeys.isEmpty && enabled("copy:") && !enabled("cut:"))
        canvas.copy(nil)
        #expect(DocumentStore.filmClip == nil && !enabled("paste:"))
        // Out of Animate, Cut and Paste are the layers' again.
        store.show(.design)
        #expect(enabled("cut:") && enabled("paste:"))
    }

    // MARK: Shared live

    @Test func keysPastedInASharedDesignLeaveWhatOthersDidMeanwhile() throws {
        let (bench, session, initial) = sharedBench()
        var other = initial
        let store = bench.store
        defer { try? FileManager.default.removeItem(at: store.url) }
        let r = bench.node("R")!.id
        store.show(.animate)
        store.glide.stop()
        bench.step { store.edit("Add Key") { doc in doc.update(r) { $0.setKey(.move, [10, 0], at: 0); $0.setKey(.move, [0, 0], at: 1) } } }
        store.save()
        other.receive(session.state)
        // There, meanwhile: one more key of the same move, and a fade.
        other.time = Collaboration.now + 10
        other.edit { doc in doc.update(r) { $0.setKey(.move, [5, 5], at: 1.5); $0.setKey(.fade, [0.5], at: 2) } }
        // Here: both keys of the move copied, and pasted at two seconds.
        store.selection = [r]
        store.film.keys = [FilmKeyRef(r, .move, at: 0), FilmKeyRef(r, .move, at: 1)]
        #expect(store.copyFilmKeys())
        store.seek(2)
        bench.step { store.pasteFilmKeys() }
        #expect(bench.node("R")?[track: .move]?.keys.map(\.t) == [0, 1, 2, 3])
        store.save()
        session.receive([other.state], from: .cloud)
        #expect(bench.node("R")?[track: .move]?.keys.map(\.t) == [0, 1, 1.5, 2, 3])
        #expect(bench.node("R")?[track: .fade]?.keys.map(\.t) == [2])
        store.save()
        other.receive(session.state)
        #expect(other.doc.nodes == store.doc.nodes)
        // Undone here, the paste alone goes: the key set there stays.
        bench.undo.undo()
        #expect(bench.node("R")?[track: .move]?.keys.map(\.t) == [0, 1, 1.5])
        #expect(bench.node("R")?[track: .fade]?.keys.map(\.t) == [2])
        session.close()
    }

    /// A bench whose design is shared by link, kept on disk as a shared design is, with another
    /// Mac that has fetched it. No relay is reached: tests have none. As in `MotionSharingTests`.
    private func sharedBench() -> (Bench, Collaboration, Mac) {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        bench.store.save()
        DocumentStore.finishSaving()
        try? SharingFiles.write(ShareLink(secret: ShareKeys.newSecret().base64URL, title: "Test"), to: bench.store.url)
        let session = Collaboration.open(bench.store.url)!
        _ = session.document()
        bench.store.sharing = session
        session.attach(to: bench.store)
        var other = Mac("other")
        other.time = Collaboration.now
        other.receive(session.state)
        return (bench, session, other)
    }
}

/// One Mac's copy of a shared design, kept as `Collaboration` keeps it but without a relay. As in
/// `MotionSharingTests`.
private struct Mac {
    let name: String
    var state = SharedDesign()
    var base = FlatDesign()
    var doc = BezzleDocument()
    var time: Int64 = 1_000

    init(_ name: String) {
        self.name = name
        commit()
    }

    /// Takes in what was changed here, as saving does.
    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    mutating func edit(_ change: (inout BezzleDocument) -> Void) {
        change(&doc)
        commit()
    }

    /// Takes in another Mac's copy and shows it, as `Collaboration.receive` does.
    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }
}
