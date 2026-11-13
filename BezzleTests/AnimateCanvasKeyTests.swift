import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas, from the keyboard, and the commands that must leave the design alone
/// while it is animated. The bench is in `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    /// The key that types a character on the keyboard in use, and what it types with Shift held:
    /// another character, and a different one on each keyboard.
    private func key(typing wanted: String) -> (code: UInt16, shifted: String)? {
        for code in UInt16(0)..<128 {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                               characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { continue }
            if event.characters(byApplyingModifiers: []) == wanted {
                return (code, event.characters(byApplyingModifiers: .shift) ?? wanted)
            }
        }
        return nil
    }

    // MARK: The keyboard

    @Test func returnPlaysFromTheStartWhateverIsPicked() {
        var photo = CanvasTests.rect("Photo", CGRect(x: 240, y: 40, width: 100, height: 80))
        photo.fill.on = true
        photo.fill.image = ImageFill(asset: "x", mode: .cover, size: CGSize(width: 1600, height: 1000))
        var line = Node(kind: .path, name: "Line", frame: CGRect(x: 40, y: 160, width: 80, height: 60))
        line.path = "M0 0 L80 60 L0 60 Z"
        line.pathBox = CGRect(x: 0, y: 0, width: 80, height: 60)
        var mask = Node(kind: .group, name: "Mask", frame: CGRect(x: 240, y: 160, width: 100, height: 100))
        mask.clipsToFirst = true
        mask.children = [Node(kind: .ellipse, name: "Ring", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                         CanvasTests.rect("Held", CGRect(x: 10, y: 10, width: 60, height: 60))]
        let f = FilmBench([FilmBench.cardAndBadge[0], photo, line, mask])
        let before = f.store.doc
        f.store.seek(1)
        f.key(36, "\r")
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == nil)
        // Again while it plays: from the start once more.
        f.key(36, "\r")
        #expect(f.store.film.playing && f.store.film.pass?.from == 0)
        f.store.pauseFilm()
        // The keypad's Enter is the same key here.
        f.key(76, "\u{3}")
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // On a picture, a path or a mask, Return opens them in the design. Not here.
        for name in ["Card", "Photo", "Line", "Mask"] {
            f.store.selection = [f.id(name)]
            f.key(36, "\r")
            #expect(f.store.film.playing, "\(name)")
            #expect(f.store.selection == [f.id(name)], "\(name)")
            #expect(f.store.editingPath == nil && f.store.editingPicture == nil && f.store.editingText == nil, "\(name)")
            f.store.pauseFilm()
        }
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func theSpaceBarTappedPlaysAndStopsAndHeldLongerDoesNeither() {
        let f = FilmBench()
        let before = f.store.doc
        f.store.seek(1)
        f.space(from: 10, to: 10.1)
        #expect(f.store.film.playing && f.store.film.pass?.from == 1)
        f.space(from: 11, to: 11.2)
        #expect(!f.store.film.playing)
        #expect(f.store.filmTime == 1)
        // Held for longer than a tap, as when the view is about to be moved.
        f.space(from: 12, to: 12.6)
        #expect(!f.store.film.playing)
        // At the film's end, it begins again at the start.
        f.store.seek(2)
        f.space(from: 13, to: 13.1)
        #expect(f.store.film.playing && f.store.film.pass?.from == 0)
        f.space(from: 14, to: 14.1)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func theSpaceBarHeldWithADragMovesTheViewAndNothingElse() {
        let f = FilmBench()
        let before = f.store.doc
        let at = f.middle("Card")
        f.space(from: 10, to: 10.3) { f.drag(at, at + point(40, 30)) }
        #expect(f.store.viewport.origin == CGPoint(x: -40, y: -30))
        #expect(!f.store.film.playing)
        #expect(f.store.selection.isEmpty)
        #expect(f.store.doc == before && !f.undo.canUndo && !f.tool.dragging)
        // A film that plays goes on playing while the view is moved under it.
        f.store.playFilm()
        f.space(from: 11, to: 11.2) { f.drag(at, at + point(10, 10)) }
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // Let go, the next press is the tool's again.
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")])
    }

    @Test func deleteAndForwardDeleteTakeTheKeysPickedOrThoseAtThePlayheadAndNeverALayer() {
        let f = FilmBench()
        let card = f.id("Card")
        f.edit { doc in
            doc.update(card) { n in
                n.setKey(.move, [0, 0], at: 0)
                n.setKey(.move, [30, 0], at: 1)
                n.setKey(.move, [60, 0], at: 2)
                n.setKey(.fade, [1], at: 0)
                n.setKey(.fade, [0.5], at: 1)
            }
        }
        f.store.selection = [card]
        f.store.seek(2)
        f.fresh()
        // Picked in the timeline: that key alone, wherever the playhead is.
        f.store.film.keys = [FilmKeyRef(card, .move, at: 1)]
        f.key(117)
        #expect(f.keys("Card", .move).map(\.t) == [0, 2])
        #expect(f.keys("Card", .fade).map(\.t) == [0, 1])
        #expect(f.store.film.keys.isEmpty)
        // None picked: every key of the layer at the playhead.
        f.store.seek(1)
        f.key(51)
        #expect(f.keys("Card", .fade).isEmpty)
        #expect(f.keys("Card", .move).map(\.t) == [0, 2])
        // Where there is no key, nothing is taken, and the layer stays in any case.
        f.key(51)
        f.key(117)
        #expect(f.keys("Card", .move).map(\.t) == [0, 2])
        #expect(f.bench.node("Card") != nil && f.store.selection == [card])
        // Two steps, each undone by itself.
        f.undo.undo()
        #expect(f.keys("Card", .fade).map(\.t) == [0, 1])
        f.undo.undo()
        #expect(f.keys("Card", .move).map(\.t) == [0, 1, 2])
        #expect(!f.undo.canUndo)
        // With no keys at all, Delete leaves the layer where it is.
        f.store.selection = [f.id("Badge")]
        f.key(51)
        f.key(117)
        #expect(f.bench.node("Badge") != nil)
        #expect(!f.undo.canUndo)
    }

    @Test func deleteWithTheCameraInHandTakesTheCamerasKeysAtThePlayhead() {
        let f = FilmBench()
        let a = f.bench.a.id, card = f.id("Card")
        f.edit { doc in
            doc.update(a) { n in
                n.setKey(.cameraZoom, [1], at: 0)
                n.setKey(.cameraZoom, [2], at: 1)
                n.setKey(.cameraRoll, [0], at: 0)
                n.setKey(.cameraRoll, [10], at: 1)
            }
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) }
        }
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        f.key(51)
        // What was left said only what the whole artboard does, and went too.
        #expect(!f.board.hasCamera)
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        #expect(f.store.doc.node(a) != nil && f.store.film.camera)
        f.undo.undo()
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 1] && f.cameraKeys(.cameraRoll).map(\.t) == [0, 1])
        #expect(!f.undo.canUndo)
    }

    @Test func escapeLetsGoOfOneThingAtATime() {
        let f = FilmBench()
        let card = f.id("Card")
        f.edit { doc in doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 0], at: 1) } }
        f.fresh()
        let before = f.store.doc
        f.click(f.view(100, 80))
        f.store.film.keys = [FilmKeyRef(card, .move, at: 1)]
        f.store.playFilm()
        // First the film stops.
        f.key(53)
        #expect(!f.store.film.playing && f.store.film.keys.count == 1 && f.store.selection == [card])
        // Then the keys picked are let go of.
        f.key(53)
        #expect(f.store.film.keys.isEmpty && f.store.selection == [card])
        // Then the layer.
        f.key(53)
        #expect(f.store.selection.isEmpty)
        // The camera likewise, and with nothing in hand Escape is nothing.
        f.click(f.chip)
        f.key(53)
        #expect(!f.store.film.camera)
        f.key(53)
        #expect(f.store.doc == before && !f.undo.canUndo && f.store.animating)
    }

    @Test func homeAndEndPutThePlayheadAtTheFilmsEnds() {
        let f = FilmBench()
        let before = f.store.doc
        f.store.seek(0.7)
        f.key(119, "\u{F72B}", flags: .function)
        #expect(f.store.filmTime == 2)
        f.key(115, "\u{F729}", flags: .function)
        #expect(f.store.filmTime == 0)
        // A film set longer ends later.
        f.step { f.store.setFilm("Film Length") { $0.length = 3.5 } }
        f.key(119, "\u{F72B}", flags: .function)
        #expect(f.store.filmTime == 3.5)
        // And they stop a film that plays.
        f.store.playFilm()
        f.key(115, "\u{F729}", flags: .function)
        #expect(!f.store.film.playing && f.store.filmTime == 0)
        f.undo.undo()
        #expect(f.store.doc == before)
    }

    @Test func theArrowsNudgeWhatIsPickedAsAKeyAtThePlayhead() {
        let f = FilmBench()
        let design = f.design
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.arrow(124)
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [1, 0])])
        // A nudge is not shown, and the playhead stays.
        #expect(!f.store.film.playing && f.store.filmTime == 1)
        f.arrow(125, flags: .shift)
        #expect(f.value("Card", .move) == [1, 10])
        f.arrow(123)
        f.arrow(123)
        #expect(f.value("Card", .move) == [-1, 10])
        f.arrow(126)
        #expect(f.value("Card", .move) == [-1, 9])
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        #expect(f.design == design)
        // Several picked go together.
        f.click(f.middle("Badge"), flags: .shift)
        f.arrow(124, flags: .shift)
        #expect(f.value("Card", .move) == [9, 9] && f.value("Badge", .move) == [10, 0])
        // Each press its own step.
        f.undo.undo()
        #expect(f.value("Card", .move) == [-1, 9] && f.node("Badge").motion == nil)
        for _ in 0..<5 { f.undo.undo() }
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func theArrowsNudgeTheCameraWhenItIsInHand() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        f.arrow(124)
        f.arrow(126, flags: .shift)
        #expect(f.cameraKeys(.cameraMove) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [1, -10])])
        #expect(f.node("Card").motion == nil)
        f.undo.undo()
        f.undo.undo()
        #expect(!f.board.hasCamera && !f.undo.canUndo)
    }

    @Test func withNothingPickedTheArrowsStepThePlayheadAFrameAtATime() {
        let f = FilmBench()
        let before = f.store.doc
        for _ in 0..<6 { f.arrow(124) }
        // Six frames of the sixty in a second.
        #expect(f.store.filmTime == 0.1)
        f.arrow(124, flags: .shift)
        #expect(f.store.filmTime == 0.267)
        f.arrow(123)
        #expect(f.store.filmTime == 0.25)
        f.arrow(123, flags: .shift)
        #expect(f.store.filmTime == 0.083)
        // Up and down are not ways through time.
        f.arrow(126)
        f.arrow(125)
        #expect(f.store.filmTime == 0.083)
        // Never before the start, nor past the end.
        f.arrow(123, flags: .shift)
        #expect(f.store.filmTime == 0)
        f.store.seek(2)
        f.arrow(124)
        #expect(f.store.filmTime == 2)
        // With Command they are someone else's, and do nothing here.
        f.arrow(123, flags: .command)
        #expect(f.store.filmTime == 2)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func commaAndFullStopStepAFrameAndSixtyFramesAreASecond() {
        let f = FilmBench()
        let before = f.store.doc
        for _ in 0..<60 { f.key(47, ".") }
        #expect(f.store.filmTime == 1)
        f.key(43, ",")
        #expect(f.store.filmTime == 0.983)
        for _ in 0..<59 { f.key(43, ",") }
        #expect(f.store.filmTime == 0)
        f.key(43, ",")
        #expect(f.store.filmTime == 0)
        // From between two frames, to the frame next to it, not a frame's length on.
        f.store.seek(0.73)
        f.key(47, ".")
        #expect(f.store.filmTime == 0.733)
        f.store.seek(0.73)
        f.key(43, ",")
        #expect(f.store.filmTime == 0.717)
        f.store.seek(2)
        f.key(47, ".")
        #expect(f.store.filmTime == 2)
        // They step through time whatever is picked.
        f.store.seek(0)
        f.click(f.middle("Card"))
        f.key(47, ".")
        #expect(f.store.filmTime == 0.017)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func withShiftCommaAndFullStopStepTenFrames() throws {
        let f = FilmBench()
        // Shift makes another character of each of the two keys, a different one on each keyboard.
        let stop = try #require(key(typing: ".")), comma = try #require(key(typing: ","))
        f.key(stop.code, stop.shifted, flags: .shift)
        #expect(f.store.filmTime == 0.167)
        f.key(stop.code, stop.shifted, flags: .shift)
        f.key(stop.code, ".")
        #expect(f.store.filmTime == 0.35)
        f.key(comma.code, comma.shifted, flags: .shift)
        #expect(f.store.filmTime == 0.183)
        f.key(comma.code, comma.shifted, flags: .shift)
        f.key(comma.code, comma.shifted, flags: .shift)
        #expect(f.store.filmTime == 0)
    }

    @Test func optionWithLeftAndRightStepsFromKeyToKey() {
        let f = FilmBench()
        let card = f.id("Card"), badge = f.id("Badge"), a = f.bench.a.id
        f.edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0.4); $0.setKey(.move, [30, 0], at: 1.2) }
            doc.update(badge) { $0.setKey(.fade, [0], at: 0.8); $0.setKey(.fade, [1], at: 1.2) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0.6); $0.setKey(.cameraZoom, [2], at: 1.6) }
        }
        f.fresh()
        let before = f.store.doc
        func steps(_ code: UInt16, _ count: Int) -> [Double] {
            (0..<count).map { _ in
                f.arrow(code, flags: .option)
                return f.store.filmTime
            }
        }
        // Nothing picked: every key of the film, and past the last, its end.
        #expect(steps(124, 6) == [0.4, 0.6, 0.8, 1.2, 1.6, 2])
        #expect(steps(123, 6) == [1.6, 1.2, 0.8, 0.6, 0.4, 0])
        // A layer picked: its own.
        f.store.selection = [card]
        #expect(steps(124, 3) == [0.4, 1.2, 2])
        // The camera in hand: the camera's.
        f.click(f.chip)
        #expect(steps(123, 3) == [1.6, 0.6, 0])
        // With Option, up and down still nudge.
        f.store.selection = [badge]
        f.store.seek(1.2)
        f.arrow(125, flags: .option)
        #expect(f.value("Badge", .move) == [0, 1])
        f.undo.undo()
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func kHoldsWhatIsPickedAsItIsAtThePlayhead() {
        let f = FilmBench()
        let card = f.id("Card"), a = f.bench.a.id
        f.edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [40, 0], at: 1); $0.setKey(.fade, [1], at: 0); $0.setKey(.fade, [0], at: 1) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) }
        }
        f.fresh()
        let before = f.store.doc
        f.store.seek(0.5)
        // With nothing in hand, K holds nothing, and is no knife either.
        f.key(40, "k")
        #expect(f.store.doc == before && f.store.tool == .select)
        f.store.selection = [card]
        let was = f.value("Card", .move)
        f.key(40, "k")
        #expect(f.keys("Card", .move).map(\.t) == [0, 0.5, 1] && f.keys("Card", .fade).map(\.t) == [0, 0.5, 1])
        #expect(f.keys("Card", .move)[1].v == was)
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 1])
        f.undo.undo()
        #expect(f.store.doc == before && !f.undo.canUndo)
        // The camera in hand: its keys.
        f.click(f.chip)
        f.key(40, "K", flags: .shift)
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 0.5, 1])
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
    }

    // MARK: What must leave the design alone

    @Test func theDrawingToolsLettersAndTheToolsThemselvesDrawNothing() {
        let f = FilmBench()
        let before = f.store.doc
        for (code, letter) in [(UInt16(15), "r"), (14, "e"), (37, "l"), (35, "p"), (17, "t"), (45, "n"), (0, "a"), (9, "v"), (15, "R")] {
            f.key(code, letter, flags: letter == "R" ? .shift : [])
            #expect(f.store.tool == .select, "\(letter)")
        }
        f.drag(f.view(180, 130), f.view(230, 170))
        f.click(f.view(350, 40), clicks: 2)
        // Even with a drawing tool somehow in hand, a drag on the film is Animate's.
        for tool in [Tool.rectangle, .ellipse, .line, .pen, .text, .artboard, .knife, .note] {
            f.store.tool = tool
            f.drag(f.view(180, 130), f.view(230, 170))
            f.click(f.table(300, 600))
            #expect(f.store.doc == before, "\(tool)")
        }
        #expect(f.store.editingText == nil && f.store.editingPath == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func cutPasteAndDeleteFromTheEditMenuNeverTakeOrAddALayer() {
        let f = FilmBench()
        let card = f.id("Card")
        f.click(f.middle("Card"))
        let before = f.store.doc
        let cut = NSMenuItem(title: "Cut", action: #selector(CanvasView.cut(_:)), keyEquivalent: "x")
        let paste = NSMenuItem(title: "Paste", action: #selector(CanvasView.paste(_:)), keyEquivalent: "v")
        let delete = NSMenuItem(title: "Delete", action: #selector(CanvasView.delete(_:)), keyEquivalent: "")
        #expect(!f.canvas.validateMenuItem(cut))
        #expect(!f.canvas.validateMenuItem(paste))
        // With no key at the playhead there is nothing for Delete to take.
        #expect(!f.canvas.validateMenuItem(delete))
        f.step {
            f.canvas.cut(nil)
            f.canvas.paste(nil)
            f.canvas.delete(nil)
        }
        #expect(f.store.doc == before && !f.undo.canUndo)
        // With one, it is offered, and takes the key.
        f.store.seek(1)
        f.arrow(124)
        #expect(f.canvas.validateMenuItem(delete))
        f.step { f.canvas.delete(nil) }
        #expect(f.store.doc == before)
        #expect(f.bench.node("Card") != nil && f.store.selection == [card])
        #expect(!f.canvas.validateMenuItem(delete) && !f.canvas.validateMenuItem(cut))
    }

    @Test(.disabled("BezzleApp.swift: Duplicate (line 169) and the Object menu (from line 213: Group, Align, Flip, Lock and the rest) are not turned off while animating, and the store does what they ask: each still changes the design. Reported, not changed"))
    func theMenusCommandsThatChangeLayersDoNothingWhileAnimating() {
        let f = FilmBench()
        // What the menus call, with two layers picked: nothing stands between them and the design.
        let commands: [(name: String, run: (DocumentStore) -> Void)] = [
            ("Duplicate", { $0.duplicateSelection() }),
            ("Group", { $0.group() }),
            ("Align Left", { $0.align(.left) }),
            ("Flip Horizontally", { $0.flip(horizontally: true) }),
            ("Lock", { $0.setLocked(true, $0.selection) }),
        ]
        for command in commands {
            f.store.selection = [f.id("Card"), f.id("Badge")]
            let before = f.store.doc
            f.step { command.run(f.store) }
            #expect(f.store.doc == before, "\(command.name)")
            if f.undo.canUndo { f.undo.undo() }
        }
    }
}
