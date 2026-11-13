import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas, at its edges: other artboards, a desk with no film on it, layers and
/// artboards that go while they are in hand, the right click, and coming into the mode and
/// leaving it in the middle of things. The bench is in `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    /// A menu as its titles, a rule where it has one.
    private func titles(_ entries: [MenuEntry]?) -> [String] {
        (entries ?? []).map { $0.kind == .separator ? "-" : $0.title }
    }

    private func entry(_ title: String, in entries: [MenuEntry]?) -> MenuEntry? {
        entries?.first { $0.kind == .item && $0.title == title }
    }

    // MARK: Other artboards

    @Test func aClickOnAnotherArtboardsNameOrItsBareSheetBringsItsFilmToTheDeskAtItsStart() {
        let f = FilmBench()
        let a = f.bench.a.id, b = f.bench.b.id
        f.edit { $0.nodes[1].children = [CanvasTests.rect("Lamp", CGRect(x: 40, y: 40, width: 80, height: 80))] }
        f.fresh()
        let before = f.store.doc
        f.store.seek(1)
        // B's name, just above its top left corner.
        f.click(f.table(604, 90))
        f.store.glide.stop()
        #expect(f.store.film.board == b && f.store.filmTime == 0)
        #expect(f.store.selection == [b])
        f.store.seek(1.5)
        // Back by A's bare sheet.
        f.click(f.table(120, 380))
        f.store.glide.stop()
        #expect(f.store.film.board == a && f.store.filmTime == 0)
        // With Shift, a press there only begins a loop for what is picked on this artboard.
        f.store.seek(1)
        f.click(f.middle("Card"))
        f.click(f.table(900, 300), flags: .shift)
        #expect(f.store.film.board == a && f.store.selection == [f.id("Card")] && f.store.filmTime == 1)
        // A layer of the other artboard: its film comes first, and the next click is the layer's.
        f.click(f.table(680, 180))
        f.store.glide.stop()
        #expect(f.store.film.board == b && f.store.filmTime == 0)
        f.click(f.table(680, 180))
        #expect(f.store.selection == [f.id("Lamp")])
        // The camera in hand is this film's: it is let go of when another comes.
        f.click(f.chip)
        #expect(f.store.film.camera)
        f.click(f.table(120, 380))
        f.store.glide.stop()
        #expect(f.store.film.board == a && !f.store.film.camera)
        // Its own name picks the artboard and keeps its film and its playhead.
        f.store.seek(1)
        f.click(f.table(104, 90))
        #expect(f.store.film.board == a && f.store.filmTime == 1 && f.store.selection == [a])
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func anArtboardWithNothingOnItStillHasACameraAndAFilm() {
        let f = FilmBench()
        let b = f.bench.b.id
        f.click(f.table(800, 250))
        f.store.glide.stop()
        #expect(f.store.film.board == b)
        f.hover(f.table(800, 250))
        f.drag(f.table(650, 150), f.table(900, 350))
        #expect(f.store.selection.isEmpty || f.store.selection == [b])
        #expect(titles(f.rightClick(f.table(800, 250))).contains("Remove All Motion"))
        f.draw()
        // Its camera is taken and posed like any.
        f.click(f.chip)
        f.store.seek(1)
        let at = f.view(200, 150)
        f.drag(at, at + point(-50, 0))
        #expect(f.cameraKeys(.cameraMove).last?.v == [50, 0])
        #expect(f.store.doc.node(b)?.hasCamera == true)
        f.store.pauseFilm()
        f.key(36, "\r")
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        f.draw()
    }

    // MARK: Edges

    @Test func withNoArtboardAtAllNothingTripsAndTheDeskIsEmpty() {
        let f = FilmBench(animated: false)
        f.edit { $0.nodes = [CanvasTests.rect("Loose", CGRect(x: 200, y: 200, width: 80, height: 80))] }
        f.animate()
        f.undo.removeAllActions()
        let before = f.store.doc, view = f.store.viewport
        #expect(f.store.filmBoard == nil && f.tool.scene == nil)
        let at = f.table(240, 240)
        f.hover(at)
        f.click(at)
        f.click(at, clicks: 2)
        f.click(at, flags: .shift)
        f.drag(at, at + point(60, 40))
        f.drag(f.table(100, 100), f.table(400, 400))
        #expect(f.rightClick(at) == nil)
        f.key(36, "\r")
        f.space(from: 10, to: 10.1)
        for code in [UInt16(51), 117, 53, 115, 119] { f.key(code) }
        for code in [UInt16(123), 124, 125, 126] {
            f.arrow(code)
            f.arrow(code, flags: .option)
            f.arrow(code, flags: .shift)
        }
        f.key(43, ",")
        f.key(47, ".")
        f.key(40, "k")
        f.twist(at: at, [5, 5, 0])
        f.draw()
        #expect(f.store.selection.isEmpty)
        #expect(!f.store.film.playing && f.store.filmTime == 0 && !f.store.film.camera)
        #expect(f.store.doc == before && !f.undo.canUndo && !f.store.inGesture)
        #expect(f.store.viewport == view)
        // With no film to be the camera's, a pinch is the view's.
        f.pinch(at: at, [0.1, 0.1, 0])
        #expect(f.store.viewport.zoom > 1.2)
    }

    @Test func theFilmsArtboardTakenAwayByUndoLeavesAPressToBringAnotherToTheDesk() {
        let f = FilmBench(animated: false)
        f.edit { $0.nodes.append(Node(kind: .artboard, name: "C", frame: CGRect(x: 100, y: 450, width: 400, height: 300))) }
        f.animate()
        let c = f.id("C"), a = f.bench.a.id
        f.store.selection = [c]
        #expect(f.store.film.board == c)
        f.click(f.chip)
        f.store.seek(1)
        let at = f.view(200, 150)
        f.drag(at, at + point(-50, 0))
        f.store.pauseFilm()
        #expect(f.store.doc.node(c)?.hasCamera == true)
        // The look is undone, and then the artboard itself.
        f.undo.undo()
        f.undo.undo()
        #expect(f.bench.node("C") == nil)
        // No film shows, and nothing trips over the one that went.
        #expect(f.store.filmBoard == nil && f.tool.scene == nil)
        f.hover(f.table(300, 600))
        f.draw()
        f.key(36, "\r")
        f.key(51)
        f.key(40, "k")
        f.arrow(124)
        f.arrow(124, flags: .option)
        #expect(!f.store.film.playing)
        #expect(f.rightClick(f.table(300, 250)) == nil)
        // A press anywhere turns the desk to an artboard that is there, with nothing of the old in hand.
        f.click(f.table(300, 600))
        #expect(f.store.film.board == a)
        #expect(f.store.filmBoard?.id == a && !f.store.film.camera && f.store.film.keys.isEmpty && f.store.filmTime == 0)
        // And is an ordinary press from then on.
        f.click(f.table(200, 180))
        #expect(f.store.selection == [f.id("Card")])
        #expect(!f.store.inGesture)
    }

    @Test func theFilmsArtboardHiddenLeavesNoFilmAndAPressOnAnotherBringsItsOwn() {
        let f = FilmBench()
        let a = f.bench.a.id, b = f.bench.b.id
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.edit { doc in doc.update(a) { $0.hidden = true } }
        f.fresh()
        let before = f.store.doc
        #expect(f.store.filmBoard == nil && f.tool.scene == nil)
        f.hover(f.table(200, 180))
        f.draw()
        f.key(36, "\r")
        f.arrow(124)
        f.arrow(124, flags: .option)
        f.key(40, "k")
        f.key(51)
        #expect(f.store.doc == before && !f.store.film.playing)
        // Where the hidden artboard lay there is only the table now.
        f.click(f.table(200, 180))
        #expect(f.store.selection.isEmpty && f.store.filmBoard == nil)
        // The other artboard's sheet brings its film.
        f.click(f.table(800, 250))
        f.store.glide.stop()
        #expect(f.store.film.board == b && f.store.filmBoard?.id == b)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func aLayerTakenAwayByUndoWhileItsKeysArePickedLeavesNothingBehind() {
        let f = FilmBench(animated: false)
        let a = f.bench.a.id
        f.edit { $0.nodes[0].children.append(CanvasTests.rect("Late", CGRect(x: 240, y: 40, width: 80, height: 60))) }
        f.animate()
        let late = f.id("Late")
        f.store.seek(1)
        let at = f.middle("Late")
        f.drag(at, at + point(30, 30))
        f.store.pauseFilm()
        f.store.film.keys = [FilmKeyRef(late, .move, at: 1), FilmKeyRef(late, at: 0)]
        f.undo.undo()
        f.undo.undo()
        #expect(f.bench.node("Late") == nil)
        // Picked with its keys, it takes them with it.
        #expect(f.store.selection.isEmpty && f.store.film.keys.isEmpty)
        let before = f.store.doc
        f.hover(at)
        f.draw()
        f.key(51)
        f.key(40, "k")
        f.arrow(124, flags: .option)
        _ = f.rightClick(at)
        f.click(at)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func keysLeftPickedOfALayerThatIsGoneAreLetGoOfByDelete() {
        let f = FilmBench(animated: false)
        let a = f.bench.a.id
        f.edit { $0.nodes[0].children.append(CanvasTests.rect("Late", CGRect(x: 240, y: 40, width: 80, height: 60))) }
        f.animate()
        let late = f.id("Late")
        f.store.seek(1)
        let at = f.middle("Late")
        f.drag(at, at + point(30, 30))
        f.store.pauseFilm()
        // Its keys picked in the timeline, and the layer itself not.
        f.store.selection = []
        f.store.film.keys = [FilmKeyRef(late, .move, at: 1)]
        f.undo.undo()
        f.undo.undo()
        #expect(f.bench.node("Late") == nil)
        let before = f.store.doc
        _ = f.rightClick(at)
        f.draw()
        f.key(40, "k")
        // Delete finds nothing of them, and lets go.
        f.key(51)
        #expect(f.store.film.keys.isEmpty)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    // MARK: The right click

    @Test func aRightClickOnALayerPicksItAndOffersWhatCanBeDoneWithItsKeys() {
        let f = FilmBench()
        f.store.seek(1)
        let before = f.store.doc
        var menu = f.rightClick(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")])
        // No keys yet: none to remove, and no pace to give them.
        #expect(titles(menu) == ["Hold Here", "Remove Key", "-", "Remove Motion", "-", "Play"])
        #expect(entry("Remove Key", in: menu)?.enabled == false)
        #expect(f.store.doc == before && !f.undo.canUndo)
        // Posed, its key at the playhead can be removed or paced.
        f.arrow(124, flags: .shift)
        f.fresh()
        menu = f.rightClick(f.middle("Card"))
        #expect(titles(menu) == ["Hold Here", "Remove Key", "-", "Auto", "Smooth", "Gathers Speed", "Settles", "Even", "Spring", "Hold", "-", "Remove Motion", "-", "Play"])
        #expect(entry("Remove Key", in: menu)?.enabled == true)
        #expect((menu ?? []).filter(\.checked).map(\.title) == ["Auto"])
        // Each pace is set on the key at the playhead, as one step, and is the one ticked next time.
        #expect(f.choose("Spring", in: menu))
        #expect(f.keys("Card", .move).last?.ease?.kind == .spring)
        #expect(f.keys("Card", .move).first?.ease == nil)
        menu = f.rightClick(f.middle("Card"))
        #expect((menu ?? []).filter(\.checked).map(\.title) == ["Spring"])
        #expect(f.choose("Even", in: menu))
        #expect(f.keys("Card", .move).last?.ease == .linear)
        #expect(f.choose("Auto", in: f.rightClick(f.middle("Card"))))
        #expect(f.keys("Card", .move).last?.ease == nil)
        f.undo.undo()
        #expect(f.keys("Card", .move).last?.ease == .linear)
        f.undo.undo()
        f.undo.undo()
        #expect(f.keys("Card", .move).last?.ease == nil && !f.undo.canUndo)
        // Between its keys: held there.
        f.store.seek(0.5)
        menu = f.rightClick(f.middle("Card"))
        #expect(entry("Remove Key", in: menu)?.enabled == false)
        #expect(f.choose("Hold Here", in: menu))
        #expect(f.keys("Card", .move).map(\.t) == [0, 0.5, 1])
        // And the key there taken away again.
        #expect(f.choose("Remove Key", in: f.rightClick(f.middle("Card"))))
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        // Play plays, from the playhead.
        #expect(f.choose("Play", in: f.rightClick(f.middle("Card"))))
        #expect(f.store.film.playing && f.store.film.pass?.from == 0.5)
        f.store.pauseFilm()
        // Remove Motion: the layer as designed again, and still there.
        #expect(f.choose("Remove Motion", in: f.rightClick(f.middle("Card"))))
        #expect(f.node("Card").motion == nil)
        #expect(f.store.doc == before)
    }

    @Test func aRightClickOnAnotherLayerPicksThatOneAndOnTheBareSheetKeepsWhatIsPicked() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.click(f.middle("Badge"), flags: .shift)
        // On one of several picked: all of them stay in hand.
        _ = f.rightClick(f.middle("Badge"))
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        // On the bare sheet: still theirs.
        #expect(titles(f.rightClick(f.view(350, 40))).first == "Hold Here")
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        // A click on one of several keeps them all in hand, as it does in the design: it may be
        // the start of dragging them together.
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        f.click(f.view(350, 40))
        f.click(f.middle("Card"))
        _ = f.rightClick(f.middle("Badge"))
        #expect(f.store.selection == [f.id("Badge")])
        #expect(!f.undo.canUndo)
    }

    @Test func aRightClickOnNothingOffersTheWholeFilm() {
        let f = FilmBench()
        let card = f.id("Card"), a = f.bench.a.id
        var menu = f.rightClick(f.view(350, 40))
        #expect(titles(menu) == ["Remove All Motion", "-", "Play"])
        // With nothing moving there is nothing to remove.
        #expect(entry("Remove All Motion", in: menu)?.enabled == false)
        f.edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) }
        }
        f.fresh()
        menu = f.rightClick(f.view(350, 40))
        #expect(entry("Remove All Motion", in: menu)?.enabled == true)
        #expect(f.choose("Remove All Motion", in: menu))
        #expect(f.node("Card").motion == nil && !f.board.hasCamera && !f.board.hasFilm)
        f.undo.undo()
        #expect(f.node("Card").motion != nil && f.board.hasCamera && !f.undo.canUndo)
        // On the table, off the film: the same.
        #expect(titles(f.rightClick(f.table(300, 600))) == ["Remove All Motion", "-", "Play"])
        #expect(f.store.selection.isEmpty)
    }

    @Test func aRightClickWithTheCameraInHandIsTheCameras() {
        let f = FilmBench()
        let card = f.id("Card"), a = f.bench.a.id
        f.edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) }
        }
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        // On a layer too: the camera stays in hand, and the layer is not picked.
        var menu = f.rightClick(f.view(100, 80))
        #expect(f.store.film.camera && f.store.selection.isEmpty)
        #expect(titles(menu) == ["Hold Here", "Remove Key", "-", "Auto", "Smooth", "Gathers Speed", "Settles", "Even", "Spring", "Hold", "-", "Remove Motion", "-", "Play"])
        #expect(f.choose("Settles", in: menu))
        #expect(f.cameraKeys(.cameraZoom).last?.ease == .easeOut)
        #expect(f.keys("Card", .move).last?.ease == nil)
        f.store.seek(0.5)
        menu = f.rightClick(f.view(350, 40))
        #expect(f.choose("Hold Here", in: menu))
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 0.5, 1])
        #expect(f.choose("Remove Key", in: f.rightClick(f.view(350, 40))))
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 1])
        // Remove Motion takes the camera's alone.
        #expect(f.choose("Remove Motion", in: f.rightClick(f.view(350, 40))))
        #expect(!f.board.hasCamera)
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        #expect(f.store.film.camera)
    }

    @Test func aRightClickWhileTheFilmPlaysChangesNothing() {
        let f = FilmBench()
        f.click(f.middle("Badge"))
        let before = f.store.doc
        f.store.playFilm()
        _ = f.rightClick(f.middle("Card"))
        #expect(f.store.selection == [f.id("Badge")])
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    // MARK: Into the mode and out of it

    @Test func leavingWhileTheFilmPlaysStopsItAndLetsGoOfTheCameraAndTheKeys() {
        let f = FilmBench()
        let card = f.id("Card")
        f.edit { doc in doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) } }
        f.fresh()
        let before = f.store.doc
        f.store.seek(1)
        f.click(f.chip)
        f.store.film.keys = [FilmKeyRef(card, .move, at: 1)]
        f.store.playFilm()
        for mode in [CanvasMode.design, .prototype, .inspect] {
            f.store.show(.animate)
            f.store.glide.stop()
            f.store.film.camera = true
            f.store.film.keys = [FilmKeyRef(card, .move, at: 1)]
            f.store.playFilm()
            #expect(f.store.film.playing)
            f.store.show(mode)
            #expect(f.store.canvasMode == mode)
            #expect(!f.store.film.playing && f.store.film.pass == nil && !f.store.film.camera && f.store.film.keys.isEmpty)
        }
        // Back in, the film is where it was left, and nothing is in hand.
        f.store.show(.animate)
        f.store.glide.stop()
        #expect(f.store.film.board == f.bench.a.id && f.store.filmTime == 1)
        #expect(!f.store.film.playing && !f.tool.dragging)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func leavingWithADragInHandPutsItBackAndLeavesTheHistoryWhole() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let before = f.store.doc
        let c = f.middle("Card"), corner = f.corners("Card")[2]
        for (from, to) in [(c, c + point(50, 30)), (corner, FilmBench.scaled(corner, from: c, 1.5))] {
            f.store.show(.animate)
            f.store.glide.stop()
            f.store.viewport = FilmView.plain.viewport
            f.press(from)
            f.pull(to: to)
            #expect(f.tool.dragging && f.store.inGesture)
            #expect(f.store.doc != before)
            f.store.show(.design)
            // Nothing is left in hand, and nothing half made in the design.
            #expect(!f.tool.dragging && !f.store.inGesture)
            #expect(f.store.doc == before)
            f.pull(to: to + point(10, 10))
            f.letGo(at: to + point(10, 10))
            #expect(f.store.doc == before && !f.undo.canUndo && !f.store.inGesture)
        }
        // What is done next in the design is a step of its own.
        f.store.selection = []
        f.bench.drag(CGPoint(x: 200, y: 180), CGPoint(x: 240, y: 200), flags: .command)
        #expect(f.node("Card").frame.origin == CGPoint(x: 80, y: 60))
        f.undo.undo()
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func leavingWithAPinchInHandPutsTheCameraBack() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        let before = f.store.doc
        let at = f.canvas.convert(f.eye, to: nil)
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0.2, .began)) }
        #expect(f.store.inGesture)
        f.store.show(.prototype)
        #expect(!f.store.inGesture && f.store.doc == before)
        // The rest of the pinch is the view's, as anywhere in the prototype.
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0.2, .changed)) }
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0, .ended)) }
        #expect(f.store.doc == before && !f.undo.canUndo && !f.store.inGesture)
    }

    @Test func comingInWithADesignDragInHandLetsThatDragEndAsItsOwnStep() {
        let f = FilmBench(animated: false)
        let before = f.store.doc
        f.press(f.table(200, 180), flags: .command)
        f.pull(to: f.table(220, 190), flags: .command)
        f.pull(to: f.table(240, 200), flags: .command)
        #expect(f.store.inGesture)
        f.animate()
        #expect(f.store.animating && f.store.film.board == f.bench.a.id)
        f.letGo(at: f.table(240, 200), flags: .command)
        #expect(!f.store.inGesture && !f.tool.dragging)
        f.undo.undo()
        #expect(f.store.doc == before && !f.undo.canUndo)
        // And Animate is ready for a press of its own.
        f.click(f.middle("Badge"))
        #expect(f.store.selection == [f.id("Badge")])
    }

    @Test func comingInAnewEachTimeNothingIsInHand() {
        let f = FilmBench(animated: false)
        // With a layer of the other artboard picked in the design, its film is the one on the desk.
        let b = f.bench.b.id
        f.edit { $0.nodes[1].children = [CanvasTests.rect("Lamp", CGRect(x: 40, y: 40, width: 80, height: 80))] }
        f.store.selection = [f.id("Lamp")]
        f.animate()
        #expect(f.store.film.board == b && f.store.selection == [f.id("Lamp")])
        #expect(!f.store.film.camera && !f.store.film.playing && f.store.filmTime == 0)
        // A drawing tool in hand in the design is put down.
        f.store.show(.design)
        f.store.tool = .rectangle
        f.animate()
        #expect(f.store.tool == .select)
        let at = f.middle("Lamp")
        f.drag(at, at + point(20, 20))
        #expect(f.value("Lamp", .move) == [20, 20])
    }
}
