import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas, with the camera in hand: looking elsewhere, coming closer, rolling,
/// the scene tipped and swung under it, two fingers on the trackpad, and layers posed while the
/// camera is anything but at rest. The bench is in `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    // MARK: The camera

    @Test func theChipPicksAndUnpicksTheCameraAndALayerPickedLetsGoOfIt() {
        let f = FilmBench()
        let before = f.store.doc
        f.click(f.middle("Card"))
        f.click(f.chip)
        #expect(f.store.film.camera && f.store.selection.isEmpty)
        f.click(f.chip)
        #expect(!f.store.film.camera)
        f.click(f.chip)
        #expect(f.store.film.camera)
        // A click on a layer while the camera is in hand picks the layer, and lets go of the camera.
        f.click(f.middle("Badge"))
        #expect(f.store.selection == [f.id("Badge")] && !f.store.film.camera)
        // A click on the bare sheet keeps it: the sheet is what the camera is held by.
        f.click(f.chip)
        f.click(f.view(350, 40))
        #expect(f.store.film.camera && f.store.selection.isEmpty)
        // A click beside the film, on the table, lets go of it, as of anything picked.
        f.click(f.table(60, 60))
        #expect(!f.store.film.camera && f.store.selection.isEmpty)
        f.click(f.chip)
        // With Shift, which adds to what is picked, it stays.
        f.click(f.table(60, 60), flags: .shift)
        #expect(f.store.film.camera)
        // A loop pulled over layers from the table picks them, and so lets go of it.
        f.drag(f.table(80, 80), f.table(300, 250))
        #expect(f.store.selection == [f.id("Card")] && !f.store.film.camera)
        // Escape puts it down.
        f.click(f.chip)
        f.key(53)
        #expect(!f.store.film.camera)
        #expect(f.store.doc == before && !f.undo.canUndo)
    }

    @Test func theChipIsNotThereToPressWhileTheArtboardShowsTooSmallForIt() {
        let f = FilmBench()
        f.store.viewport = Viewport(origin: CGPoint(x: -2000, y: -2000), zoom: 0.1)
        // Forty points wide on screen: no chip is drawn there.
        #expect(f.scene.rect.width < 60)
        f.click(f.chip)
        #expect(!f.store.film.camera)
        // A little closer, it is.
        f.store.viewport = Viewport(origin: CGPoint(x: -1000, y: -1000), zoom: 0.2)
        f.click(f.chip)
        #expect(f.store.film.camera)
    }

    @Test(arguments: FilmView.allCases) func aDragWithTheCameraInHandKeepsWhatWasTakenHoldOfUnderThePointer(_ view: FilmView) throws {
        let f = FilmBench(view: view)
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let design = f.design
        // The bare sheet taken hold of and pulled left and down: the camera looks right and up.
        let from = f.view(200, 50), to = from + point(-60, 25) * f.zoom
        let held = try #require(f.under(from))
        f.drag(from, to)
        #expect(f.cameraKeys(.cameraMove) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [60, -25])])
        #expect(f.store.film.camera && f.store.selection.isEmpty)
        #expect(f.design == design)
        #expect(f.node("Card").motion == nil && f.node("Badge").motion == nil)
        // Its first key is shown, from the start to there.
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == 1 && f.store.film.pass?.back == 1)
        f.store.pauseFilm()
        #expect(closeBy(f.under(to), held, within: 0.6))
        f.undo.undo()
        #expect(!f.board.hasCamera)
        #expect(!f.undo.canUndo)
    }

    @Test func lookingElsewhereKeepsHoldWhenTheCameraIsCloseRolledAndTheSceneTilted() throws {
        let f = FilmBench()
        let a = f.bench.a.id
        f.edit { doc in
            doc.update(a) { n in
                n.setKey(.cameraZoom, [2], at: 0)
                n.setKey(.cameraRoll, [15], at: 0)
                n.setKey(.cameraTilt, [35], at: 0)
                n.setKey(.cameraSwing, [-20], at: 0)
            }
        }
        f.click(f.chip)
        f.store.seek(1)
        let from = f.eye + point(-30, 40), to = from + point(-45, 20)
        let held = try #require(f.under(from))
        f.drag(from, to)
        f.store.pauseFilm()
        let now = try #require(f.under(to))
        // To the whole point the camera is kept at.
        #expect(closeBy(now, held, within: 1))
        #expect(abs(f.camera.x) + abs(f.camera.y) > 10)
        // The rest of it is as it was.
        #expect(f.camera.zoom == 2 && f.camera.roll == 15 && f.camera.tilt == 35 && f.camera.swing == -20)
    }

    @Test func theCameraCatchesOnTheArtboardsMiddleAndShiftKeepsItToAnAxis() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        let at = f.view(200, 50)
        f.drag(at, at + point(-60, 25))
        f.store.pauseFilm()
        #expect(f.cameraKeys(.cameraMove).last?.v == [60, -25])
        // Pulled back to three points from the middle either way: it looks at the middle again.
        f.drag(at, at + point(57, -22))
        #expect(f.cameraKeys(.cameraMove).last?.v == [0, 0])
        // With Command it is not caught.
        f.drag(at, at + point(-3, 4), pulling: .command)
        #expect(f.cameraKeys(.cameraMove).last?.v == [3, -4])
        // Nor further off than five points of the screen.
        f.drag(at, at + point(-5, 5))
        #expect(f.cameraKeys(.cameraMove).last?.v == [8, -9])
        // With Shift, only the way it has mostly gone.
        f.drag(at, at + point(-40, 10), pulling: .shift)
        #expect(f.cameraKeys(.cameraMove).last?.v == [48, -9])
        #expect(f.cameraKeys(.cameraMove).map(\.t) == [0, 1])
    }

    @Test func theCameraPosedAtTheStartFliesOutOverTheWholeFilm() {
        let f = FilmBench()
        f.click(f.chip)
        let at = f.view(200, 50)
        f.drag(at, at + point(-60, 0))
        // Not in a layer's short beat: it comes back to the whole artboard by the film's end.
        #expect(f.cameraKeys(.cameraMove) == [MotionKey(t: 0, v: [60, 0]), MotionKey(t: 2, v: [0, 0], given: true)])
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == 2 && f.store.film.pass?.back == 0)
        f.store.pauseFilm()
        #expect(f.store.filmTime == 0)
        // A longer film, and the next thing posed at its start takes as long.
        f.step { f.store.setFilm("Film Length") { $0.length = 4 } }
        let corner = f.sheet[2]
        f.drag(corner, FilmBench.scaled(corner, from: f.eye, 1.5))
        #expect(f.cameraKeys(.cameraZoom) == [MotionKey(t: 0, v: [1.5]), MotionKey(t: 4, v: [1], given: true)])
        f.store.pauseFilm()
        // A key posed past the home it was given takes its place.
        f.store.seek(3)
        f.drag(at, at + point(0, -30))
        #expect(f.cameraKeys(.cameraMove).map(\.t) == [0, 3])
    }

    @Test(arguments: FilmView.allCases) func aCornerBringsTheCameraCloserAboutTheFilmsMiddle(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.eye, q = f.sheet
        let to = FilmBench.scaled(q[2], from: c, 1.5)
        f.drag(q[2], to)
        #expect(f.cameraKeys(.cameraZoom) == [MotionKey(t: 0, v: [1], given: true), MotionKey(t: 1, v: [1.5])])
        #expect(f.design == design)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // The artboard's corner is under the pointer, and the one across from it as far the other way.
        #expect(closeBy(f.sheet[2], to) && closeBy(f.sheet[0], FilmBench.scaled(q[0], from: c, 1.5)))
        f.undo.undo()
        #expect(!f.board.hasCamera)
        #expect(!f.undo.canUndo)
        // Any corner, and drawing back: the top left pushed in to half.
        f.drag(q[0], FilmBench.scaled(q[0], from: c, 0.5))
        #expect(f.cameraKeys(.cameraZoom).last?.v == [0.5])
    }

    @Test func theCamerasZoomCatchesAtTheWholeArtboardAndStaysWithinItsLimits() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        let c = f.eye, whole = f.sheet[2]
        f.drag(whole, FilmBench.scaled(whole, from: c, 1.5))
        f.store.pauseFilm()
        // Within three hundredths of the whole artboard, it is the whole artboard.
        f.drag(FilmBench.scaled(whole, from: c, 1.5), FilmBench.scaled(whole, from: c, 1.02))
        #expect(f.camera.zoom == 1)
        f.drag(whole, FilmBench.scaled(whole, from: c, 1.02), pulling: .command)
        #expect(abs(f.camera.zoom - 1.02) < 1e-9)
        // No closer than sixteen times, and no further off than a tenth.
        f.drag(FilmBench.scaled(whole, from: c, 1.02), FilmBench.scaled(whole, from: c, 40))
        #expect(f.camera.zoom == 16)
        #expect(f.cameraKeys(.cameraZoom).last?.v == [16])
        let corner = f.sheet[2]
        f.drag(corner, FilmBench.scaled(corner, from: c, 0.001))
        #expect(f.camera.zoom == 0.1)
        #expect(f.cameraKeys(.cameraZoom).last?.v == [0.1])
    }

    @Test(arguments: FilmView.allCases) func fromJustOutsideACornerTheCameraRolls(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.eye, q = f.sheet
        let grip = FilmBench.out(q[2], from: c, by: 12)
        f.drag(grip, Geometry.rotated(grip, about: c, by: 20))
        #expect(f.cameraKeys(.cameraRoll) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [20])])
        #expect(f.design == design)
        f.store.pauseFilm()
        // The picture turned with the pointer: the artboard's corner went round the film's middle.
        #expect(closeBy(f.sheet[2], Geometry.rotated(q[2], about: c, by: 20)))
        f.undo.undo()
        #expect(!f.board.hasCamera)
        #expect(!f.undo.canUndo)
    }

    @Test func theCamerasRollCatchesWhenLevelAndShiftGoesInSteps() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        let c = f.eye
        func grip() -> CGPoint { FilmBench.out(f.sheet[2], from: c, by: 12) }
        var from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: 40), pulling: .shift)
        #expect(f.camera.roll == 45)
        f.store.pauseFilm()
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: -12.4))
        #expect(f.camera.roll == 33)
        // Within two degrees of level, it is level.
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: -31.4))
        #expect(f.camera.roll == 0)
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: 1.4), pulling: .command)
        #expect(abs(f.camera.roll - 1.4) < 1e-6)
    }

    @Test func theCameraRolledPastHalfARoundGoesTheWayItWasDragged() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let c = f.eye
        let grip = FilmBench.out(f.sheet[2], from: c, by: 12)
        f.press(grip)
        for degrees in stride(from: -30.0, through: -240, by: -30) { f.pull(to: Geometry.rotated(grip, about: c, by: degrees)) }
        f.letGo(at: Geometry.rotated(grip, about: c, by: -240))
        #expect(f.cameraKeys(.cameraRoll) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [-240])])
        f.store.pauseFilm()
        f.undo.undo()
        #expect(!f.board.hasCamera && !f.undo.canUndo)
    }

    @Test(arguments: FilmView.allCases) func fromJustOutsideASidesMiddleTheSceneTipsAndSwingsUnderTheCamera(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.eye
        var grip = FilmBench.out(FilmBench.side(f.sheet, 0), from: c, by: 12)
        f.drag(grip, grip + point(0, 50))
        #expect(f.cameraKeys(.cameraTilt) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [30])])
        #expect(f.design == design)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // The artboard's top has gone away: it shows shorter than its bottom.
        let q = f.sheet
        #expect(hypot(q[1].x - q[0].x, q[1].y - q[0].y) < hypot(q[2].x - q[3].x, q[2].y - q[3].y))
        f.undo.undo()
        #expect(!f.board.hasCamera && !f.undo.canUndo)
        f.undo.redo()
        // The right side pushed left swings the scene's right away.
        grip = FilmBench.out(FilmBench.side(f.sheet, 1), from: c, by: 12)
        f.drag(grip, grip + point(-50, 0))
        #expect(f.cameraKeys(.cameraSwing) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [30])])
        #expect(f.camera.tilt == 30)
        #expect(f.design == design)
    }

    @Test func theSceneTipsNoFurtherThanEightyDegreesAndCatchesWhenItLiesFlat() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        func top() -> CGPoint { FilmBench.out(FilmBench.side(f.sheet, 0), from: f.eye, by: 12) }
        var from = top()
        f.drag(from, from + point(0, 50))
        f.store.pauseFilm()
        #expect(f.camera.tilt == 30)
        // Within three degrees of flat, it lies flat.
        from = top()
        f.drag(from, from + point(0, -46))
        #expect(f.camera.tilt == 0)
        // With Shift, by fifteen degrees at a time.
        from = top()
        f.drag(from, from + point(0, 40), pulling: .shift)
        #expect(f.camera.tilt == 30)
        // However far it is pulled, the scene never tips right over.
        from = top()
        f.drag(from, from + point(0, 300))
        #expect(f.camera.tilt == 80)
        #expect(f.cameraKeys(.cameraTilt).last?.v == [80])
        // Nor swings right round, the other way.
        let g = FilmBench()
        g.click(g.chip)
        g.store.seek(1)
        let right = FilmBench.out(FilmBench.side(g.sheet, 1), from: g.eye, by: 12)
        g.drag(right, right + point(300, 0))
        #expect(g.camera.swing == -80)
    }

    @Test func aPinchOnTheFilmWithTheCameraInHandBringsItCloserAsOneStep() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let view = f.store.viewport
        f.pinch(at: f.eye, [0.1, 0.1, 0])
        #expect(f.cameraKeys(.cameraZoom).map(\.t) == [0, 1])
        #expect(abs(f.camera.zoom - 1.21) < 1e-9)
        // The view itself stays as it is.
        #expect(f.store.viewport == view)
        #expect(!f.store.inGesture)
        #expect(f.store.film.playing && f.store.film.pass?.to == 1)
        f.store.pauseFilm()
        f.undo.undo()
        #expect(!f.board.hasCamera)
        #expect(!f.undo.canUndo)
    }

    @Test func aPinchWithoutTheCameraOrOffTheFilmZoomsTheView() {
        let f = FilmBench()
        let before = f.store.doc
        f.pinch(at: f.eye, [0.1, 0.1, 0])
        #expect(abs(f.store.viewport.zoom - 1.21) < 1e-9)
        f.store.viewport = FilmView.plain.viewport
        // With the camera in hand, but the fingers off its film.
        f.click(f.chip)
        f.pinch(at: f.table(300, 600), [0.1, 0.1, 0])
        #expect(abs(f.store.viewport.zoom - 1.21) < 1e-9)
        // And while the film plays.
        f.store.viewport = FilmView.plain.viewport
        f.store.playFilm()
        f.pinch(at: f.table(300, 250), [0.1, 0.1, 0])
        #expect(abs(f.store.viewport.zoom - 1.21) < 1e-9)
        f.twist(at: f.table(300, 250), [5, 5, 0])
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.store.inGesture)
    }

    @Test func twoFingersTurnedOnTheFilmRollTheCameraWithThem() {
        let f = FilmBench()
        let before = f.store.doc
        // Without the camera in hand, nothing turns.
        f.twist(at: f.eye, [5, 5, 5])
        #expect(f.store.doc == before)
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        // The trackpad counts counterclockwise: the picture goes that way too.
        f.twist(at: f.eye, [5, 5, 5])
        #expect(f.cameraKeys(.cameraRoll) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [-15])])
        #expect(!f.store.inGesture)
        f.store.pauseFilm()
        f.undo.undo()
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo)
    }

    @Test func aPinchCutShortByEscapeIsPutBackAndTheRestOfItDoesNothing() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        f.fresh()
        let before = f.store.doc, view = f.store.viewport
        let at = f.canvas.convert(f.eye, to: nil)
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0.2, .began)) }
        #expect(f.store.inGesture)
        #expect(abs(f.camera.zoom - 1.2) < 1e-9)
        f.key(53)
        #expect(f.store.doc == before)
        #expect(!f.store.inGesture)
        // The fingers are still on the trackpad and go on being told of: nothing comes of it.
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0.2, .changed)) }
        f.step { f.canvas.magnify(with: TwoFingers(at: at, pinch: 0, .ended)) }
        #expect(f.store.doc == before)
        #expect(f.store.viewport == view)
        #expect(!f.undo.canUndo && !f.store.inGesture && !f.store.film.playing)
    }

    @Test func aPinchBegunWhileAMotionIsShownNeverPosesTheCameraStepByStep() {
        let f = FilmBench()
        f.click(f.chip)
        f.store.seek(1)
        let at = f.view(200, 50)
        f.drag(at, at + point(-60, 0))
        #expect(f.store.film.playing)
        f.undo.removeAllActions()
        let before = f.store.doc
        // Begun while the look just made is shown, the pinch is the view's. The showing ends while
        // the fingers are still down: what is left of the pinch is not the camera's either.
        let place = f.canvas.convert(f.eye, to: nil)
        f.step { f.canvas.magnify(with: TwoFingers(at: place, pinch: 0.1, .began)) }
        f.store.pauseFilm()
        f.step { f.canvas.magnify(with: TwoFingers(at: place, pinch: 0.1, .changed)) }
        f.step { f.canvas.magnify(with: TwoFingers(at: place, pinch: 0.1, .changed)) }
        f.step { f.canvas.magnify(with: TwoFingers(at: place, pinch: 0, .ended)) }
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.store.inGesture)
    }

    @Test func withTheCameraCloseALayerIsStillFoundOnlyWhereItShows() {
        let f = FilmBench()
        let a = f.bench.a.id, card = f.id("Card")
        // Three times closer, looking at the card.
        f.edit { doc in doc.update(a) { $0.setKey(.cameraZoom, [3], at: 0); $0.setKey(.cameraMove, [-100, -70], at: 0) } }
        let q = f.corners("Card")
        #expect(abs(hypot(q[1].x - q[0].x, q[1].y - q[0].y) - 360) < 0.01)
        let foot = FilmBench.side(q, 2)
        // Six points of the screen under it is the bare sheet, as it is with the camera at rest.
        f.click(foot + point(0, 6))
        #expect(f.store.selection.isEmpty)
        f.click(foot + point(0, 2))
        #expect(f.store.selection == [card])
        // Drawn back to a third, a point or two beside it still finds it.
        f.key(53)
        f.edit { doc in doc.update(a) { $0.setKey(.cameraZoom, [0.34], at: 0) } }
        let small = FilmBench.side(f.corners("Card"), 2)
        f.click(small + point(0, 6))
        #expect(f.store.selection.isEmpty)
        f.click(small + point(0, 2))
        #expect(f.store.selection == [card])
    }

    @Test func underATiltedCameraALayerStillFollowsThePointer() throws {
        let f = FilmBench()
        let a = f.bench.a.id
        f.edit { doc in
            doc.update(a) { n in
                n.setKey(.cameraTilt, [40], at: 0)
                n.setKey(.cameraSwing, [-25], at: 0)
                n.setKey(.cameraZoom, [1.2], at: 0)
            }
        }
        f.store.seek(1)
        let design = f.design
        let from = f.middle("Card"), to = from + point(45, 25)
        let taken = try #require(f.under(from)), let_go = try #require(f.under(to))
        f.drag(from, to)
        f.store.pauseFilm()
        #expect(f.store.selection == [f.id("Card")])
        let move = f.value("Card", .move)
        // By what the pointer covered on the artboard's sheet, to the half point.
        #expect(abs(move[0] - Double(let_go.x - taken.x)) <= 0.2501 && abs(move[1] - Double(let_go.y - taken.y)) <= 0.2501)
        // Which is not what it covered on the screen, the sheet being seen at an angle.
        #expect(abs(move[0] - 45) > 1 || abs(move[1] - 25) > 1)
        // The point of the layer that was taken hold of is under the pointer still.
        let now = try #require(f.under(to))
        #expect(closeBy(CGPoint(x: now.x - move[0], y: now.y - move[1]), taken, within: 0.3))
        #expect(f.design == design)
    }

    @Test func aLiftedLayerFollowsThePointerAtItsOwnHeight() throws {
        let f = FilmBench()
        let card = f.id("Card"), a = f.bench.a.id
        f.edit { doc in doc.update(card) { $0.setKey(.lift, [160], at: 0) } }
        f.store.seek(1)
        // A fifth of the way up to the camera, it shows a quarter bigger than it is.
        let q = f.corners("Card")
        #expect(abs(hypot(q[1].x - q[0].x, q[1].y - q[0].y) - 150) < 0.01)
        var from = f.middle("Card"), to = from + point(50, 25)
        f.drag(from, to)
        f.store.pauseFilm()
        // So fifty points of the screen are forty of its own way.
        #expect(f.value("Card", .move) == [40, 20])
        #expect(closeBy(f.middle("Card"), to))
        // Under a tilted camera too, it goes by the level it is lifted to. Tipped this way the
        // lifted card shows lower, well inside the film's frame, where it can be taken hold of.
        f.edit { doc in doc.update(a) { $0.setKey(.cameraTilt, [-30], at: 0) } }
        from = f.middle("Card")
        to = from + point(30, 20)
        #expect(f.scene.rect.contains(from) && f.scene.rect.contains(to))
        let taken = try #require(f.under(from, height: 160)), let_go = try #require(f.under(to, height: 160))
        let was = f.value("Card", .move)
        f.drag(from, to)
        let move = f.value("Card", .move)
        #expect(move != was)
        #expect(abs(move[0] - was[0] - Double(let_go.x - taken.x)) <= 0.2501 && abs(move[1] - was[1] - Double(let_go.y - taken.y)) <= 0.2501)
        // Which is neither what the pointer covered on the screen nor what it covered on the sheet below.
        let below = try #require(f.under(to)) - (try #require(f.under(from)))
        #expect(abs(Double(below.x) - (move[0] - was[0])) > 1 || abs(Double(below.y) - (move[1] - was[1])) > 1)
        #expect(f.value("Card", .lift) == [160])
    }
}
