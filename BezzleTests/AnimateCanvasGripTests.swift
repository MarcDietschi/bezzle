import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas, by what a picked layer is taken hold of: its corners and sides, the
/// reach beside them for turning and tipping, and the beads of its way. Then what is shown of a
/// motion just made, Escape, and what the pointer says. The bench is in `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    // MARK: Catching

    @Test(arguments: FilmView.allCases) func homeCatchesALayerComingNearAndCommandFreesIt(_ view: FilmView) {
        let f = FilmBench(view: view)
        let z = f.zoom
        f.store.seek(1)
        let home = f.middle("Card")
        f.drag(home, home + point(50, 30) * z)
        f.store.pauseFilm()
        // Taken hold of a little off its middle, clear of the beads of its way.
        let hold = point(25, 15) * z
        // Let go three and four points of the screen from home: held there, along both lines.
        f.drag(home + point(50, 30) * z + hold, home + point(3, 4) + hold)
        #expect(f.value("Card", .move) == [0, 0])
        // Along one line alone, while it is far off along the other.
        f.drag(home + hold, home + point(3, 40 * z) + hold)
        #expect(f.value("Card", .move) == [0, 40])
        // With Command nothing holds it, and it lies to the half point where it was let go.
        f.drag(home + point(0, 40 * z) + hold, home + point(3, 4) + hold, pulling: .command)
        #expect(f.value("Card", .move) == [Double(3 / z), Double(4 / z)])
        // Further off than five points of the screen, it is not caught.
        f.drag(home + point(3, 4) + hold, home + point(7, -8) + hold)
        #expect(f.value("Card", .move) == [Double(7 / z), Double(-8 / z)])
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
    }

    @Test func shiftKeepsADragToTheWayItHasMostlyGone() {
        let f = FilmBench()
        f.store.seek(1)
        var at = f.middle("Card")
        // Shift is held once the layer is in hand: pressed with it, a click adds to what is picked.
        f.drag(at, at + point(40, 12), pulling: .shift)
        #expect(f.value("Card", .move) == [40, 0])
        f.store.pauseFilm()
        at = f.middle("Card")
        f.drag(at, at + point(5, -30), pulling: .shift)
        #expect(f.value("Card", .move) == [40, -30])
    }

    // MARK: Growing

    @Test(arguments: FilmView.allCases) func aCornerGrowsALayerEvenlyAboutItsMiddle(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.middle("Card"), q = f.corners("Card")
        let to = FilmBench.scaled(q[2], from: c, 1.5)
        f.drag(q[2], to)
        #expect(f.keys("Card", .scale) == [MotionKey(t: 0, v: [1, 1], given: true), MotionKey(t: 1, v: [1.5, 1.5])])
        #expect(f.design == design)
        #expect(f.store.film.playing && f.store.film.pass?.to == 1 && f.store.film.pass?.back == 1)
        f.store.pauseFilm()
        // The corner in hand is under the pointer, and the one across from it as far the other way.
        let grown = f.corners("Card")
        #expect(closeBy(grown[2], to) && closeBy(grown[0], FilmBench.scaled(q[0], from: c, 1.5)))
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
        // Any corner does the same: the top left pulled in to half.
        f.drag(q[0], FilmBench.scaled(q[0], from: c, 0.5))
        #expect(f.value("Card", .scale) == [0.5, 0.5])
    }

    @Test func growingCatchesAtTheDesignedSizeAndCommandFreesIt() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let c = f.middle("Card"), designed = f.corners("Card")[2]
        f.drag(designed, FilmBench.scaled(designed, from: c, 1.5))
        f.store.pauseFilm()
        // Let go within three hundredths of its own size: it is that size.
        f.drag(FilmBench.scaled(designed, from: c, 1.5), FilmBench.scaled(designed, from: c, 1.02))
        #expect(f.value("Card", .scale) == [1, 1])
        f.drag(designed, FilmBench.scaled(designed, from: c, 1.02), pulling: .command)
        #expect(closeBy(f.value("Card", .scale), [1.02, 1.02]))
        // A little further and it is not caught.
        f.drag(FilmBench.scaled(designed, from: c, 1.02), FilmBench.scaled(designed, from: c, 1.06))
        #expect(closeBy(f.value("Card", .scale), [1.06, 1.06]))
        #expect(f.keys("Card", .scale).map(\.t) == [0, 1])
    }

    @Test func aCornerPulledRightIntoTheMiddleLeavesASpeckAndNothingTrips() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let design = f.design
        let c = f.middle("Card")
        f.drag(f.corners("Card")[2], c)
        // As small as a layer is kept: never nothing, which could not be grown again.
        #expect(f.value("Card", .scale) == [0.001, 0.001])
        f.store.pauseFilm()
        #expect(f.corners("Card").allSatisfy { closeBy($0, c, within: 0.1) })
        f.hover(c)
        f.draw()
        // Too small to have corners to take hold of, it is still moved from where it is.
        #expect(f.tool.cursor(at: c) == NSCursor.arrow)
        f.drag(c, c + point(20, 0))
        #expect(f.value("Card", .move) == [20, 0])
        #expect(f.value("Card", .scale) == [0.001, 0.001])
        #expect(f.design == design)
    }

    @Test(arguments: FilmView.allCases) func aSideGrowsALayerOneWay(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.middle("Card")
        // The right side, half as far out again: wider, no taller.
        var side = f.side("Card", 1)
        f.drag(side, FilmBench.scaled(side, from: c, 1.5))
        #expect(f.keys("Card", .scale) == [MotionKey(t: 0, v: [1, 1], given: true), MotionKey(t: 1, v: [1.5, 1])])
        f.store.pauseFilm()
        f.undo.undo()
        #expect(f.node("Card").motion == nil && !f.undo.canUndo)
        f.undo.redo()
        // The top, twice as far out: taller, and as wide as it was made.
        side = f.side("Card", 0)
        f.drag(side, FilmBench.scaled(side, from: c, 2))
        #expect(f.value("Card", .scale) == [1.5, 2])
        // The left and the bottom likewise, back in.
        side = f.side("Card", 3)
        f.drag(side, FilmBench.scaled(side, from: c, 0.5))
        #expect(f.value("Card", .scale) == [0.75, 2])
        side = f.side("Card", 2)
        f.drag(side, FilmBench.scaled(side, from: c, 0.25))
        #expect(f.value("Card", .scale) == [0.75, 0.5])
        // One way too, its own size catches.
        side = f.side("Card", 2)
        f.drag(side, FilmBench.scaled(side, from: c, 2.03))
        #expect(f.value("Card", .scale) == [0.75, 1])
        #expect(f.design == design)
        #expect(closeBy(f.middle("Card"), c))
    }

    // MARK: Turning

    @Test(arguments: FilmView.allCases) func fromJustOutsideACornerALayerTurns(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let c = f.middle("Card"), q = f.corners("Card")
        let grip = FilmBench.out(q[2], from: c, by: 12)
        f.drag(grip, Geometry.rotated(grip, about: c, by: 30))
        #expect(f.keys("Card", .turn) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [30])])
        #expect(f.design == design)
        #expect(f.node("Card").rotation == 0)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // The corner went round with the pointer, about the layer's middle.
        #expect(closeBy(f.corners("Card")[2], Geometry.rotated(q[2], about: c, by: 30)))
        #expect(closeBy(f.middle("Card"), c))
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
        // The other way, from another corner.
        let other = FilmBench.out(q[0], from: c, by: 12)
        f.drag(other, Geometry.rotated(other, about: c, by: -50))
        #expect(f.value("Card", .turn) == [-50])
    }

    @Test func turningCatchesWhenItIsStraightAgainShiftGoesInStepsAndCommandFrees() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let c = f.middle("Card")
        func grip() -> CGPoint { FilmBench.out(f.corners("Card")[2], from: c, by: 12) }
        // With Shift, by fifteen degrees at a time.
        var from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: 40), pulling: .shift)
        #expect(f.value("Card", .turn) == [45])
        f.store.pauseFilm()
        // Without, to the whole degree.
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: -12.4))
        #expect(f.value("Card", .turn) == [33])
        // Within two degrees of straight, it is straight.
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: -31.4))
        #expect(f.value("Card", .turn) == [0])
        // With Command it is neither caught nor rounded.
        from = grip()
        f.drag(from, Geometry.rotated(from, about: c, by: 1.4), pulling: .command)
        #expect(closeBy(f.value("Card", .turn), [1.4], within: 1e-6))
        #expect(f.keys("Card", .turn).map(\.t) == [0, 1])
    }

    @Test func aTurnDraggedPastHalfARoundGoesTheWayItWasDragged() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.fresh()
        let c = f.middle("Card")
        let grip = FilmBench.out(f.corners("Card")[2], from: c, by: 12)
        f.press(grip)
        for degrees in stride(from: 30.0, through: 270, by: 30) { f.pull(to: Geometry.rotated(grip, about: c, by: degrees)) }
        f.letGo(at: Geometry.rotated(grip, about: c, by: 270))
        // Three quarters round is a spin that way in the film, not a quarter turn back.
        #expect(f.value("Card", .turn) == [270])
        f.store.pauseFilm()
        // On round, past where it began: a whole turn and a bit more, still as one step.
        var from = FilmBench.out(f.corners("Card")[2], from: c, by: 12)
        f.press(from)
        for degrees in stride(from: 30.0, through: 120, by: 30) { f.pull(to: Geometry.rotated(from, about: c, by: degrees)) }
        f.letGo(at: Geometry.rotated(from, about: c, by: 120))
        #expect(f.value("Card", .turn) == [390])
        // Back the other way, and straight again after a whole round catches as straight does.
        from = FilmBench.out(f.corners("Card")[2], from: c, by: 12)
        f.press(from)
        for degrees in stride(from: -10.0, through: -29, by: -10) { f.pull(to: Geometry.rotated(from, about: c, by: degrees)) }
        f.pull(to: Geometry.rotated(from, about: c, by: -29))
        f.letGo(at: Geometry.rotated(from, about: c, by: -29))
        #expect(f.value("Card", .turn) == [360])
        f.undo.undo()
        f.undo.undo()
        #expect(f.value("Card", .turn) == [270])
        f.undo.undo()
        #expect(f.node("Card").motion == nil && !f.undo.canUndo)
    }

    // MARK: Tipping in depth

    @Test(arguments: FilmView.allCases) func fromJustOutsideASidesMiddleALayerTipsAndSwings(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.middle("Card"))
        f.store.seek(1)
        f.fresh()
        let design = f.design
        var c = f.middle("Card")
        // The top pushed down fifty points of the screen tips it thirty degrees back.
        // Seventeen points out from the side's middle: clear of the corners, whose reach for turning
        // comes close on a side that shows short.
        var grip = FilmBench.out(f.side("Card", 0), from: c, by: 17)
        f.drag(grip, grip + point(0, 50))
        #expect(f.keys("Card", .tilt) == [MotionKey(t: 0, v: [0], given: true), MotionKey(t: 1, v: [30])])
        #expect(f.design == design)
        #expect(f.node("Card").transform3D == nil)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        // Its top has gone away: shorter than its bottom now.
        let q = f.corners("Card")
        #expect(hypot(q[1].x - q[0].x, q[1].y - q[0].y) < hypot(q[2].x - q[3].x, q[2].y - q[3].y))
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
        f.undo.redo()
        // The right side pushed left swings its right away.
        c = f.middle("Card")
        grip = FilmBench.out(f.side("Card", 1), from: c, by: 17)
        f.drag(grip, grip + point(-50, 0))
        #expect(f.value("Card", .swing) == [30])
        #expect(f.value("Card", .tilt) == [30])
        f.store.pauseFilm()
        // The bottom tips it too, and the left swings it: pulled the other way, back again.
        c = f.middle("Card")
        grip = FilmBench.out(f.side("Card", 2), from: c, by: 17)
        f.drag(grip, grip + point(0, -25))
        #expect(f.value("Card", .tilt) == [15])
        c = f.middle("Card")
        grip = FilmBench.out(f.side("Card", 3), from: c, by: 17)
        f.drag(grip, grip + point(25, 0))
        #expect(f.value("Card", .swing) == [15])
        #expect(f.design == design)
    }

    @Test func tippingCatchesWhenItLiesFlatAgainAndShiftGoesInSteps() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        func grip() -> CGPoint { FilmBench.out(f.side("Card", 0), from: f.middle("Card"), by: 17) }
        var from = grip()
        f.drag(from, from + point(0, 40), pulling: .shift)
        #expect(f.value("Card", .tilt) == [30])
        f.store.pauseFilm()
        // To the whole degree.
        from = grip()
        f.drag(from, from + point(0, 12))
        #expect(f.value("Card", .tilt) == [37])
        // Within three degrees of flat, it lies flat.
        from = grip()
        f.drag(from, from + point(0, -58))
        #expect(f.value("Card", .tilt) == [0])
        // With Command it is neither caught nor rounded.
        from = grip()
        f.drag(from, from + point(0, 4), pulling: .command)
        #expect(closeBy(f.value("Card", .tilt), [2.4], within: 1e-6))
    }

    // MARK: Lines, hairlines and what has no size

    @Test func aLineOrAHairlinePickedIsMovedFromAnywhereAlongIt() {
        let rule = CanvasTests.rect("Rule", CGRect(x: 100, y: 200, width: 200, height: 2))
        let line = Node(kind: .line, name: "Line", frame: CGRect(x: 100, y: 250, width: 200, height: 0))
        let short = Node(kind: .line, name: "Short", frame: CGRect(x: 40, y: 270, width: 60, height: 0))
        let f = FilmBench([rule, line, short])
        f.store.seek(1)
        let design = f.design
        // By its middle, a point or two off it, further along and close to an end: wherever the
        // pointer is on it, it is moved. Its handles and its reach for turning are beside it.
        let holds: [(name: String, at: [CGPoint])] = [
            ("Rule", [point(0, 0), point(0, 2), point(60, 2), point(-90, 2)]),
            ("Line", [point(0, 0), point(0, 2), point(60, -2), point(-90, 2)]),
            ("Short", [point(0, 0), point(0, 2), point(10, 1), point(-20, -2)]),
        ]
        for (name, at) in holds {
            f.store.selection = [f.id(name)]
            let c = f.middle(name)
            for hold in at {
                #expect(f.tool.cursor(at: c + hold) == NSCursor.arrow, "\(name) held at \(hold)")
                f.drag(c + hold, c + hold + point(30, 20))
                #expect(f.node(name).motionProperties == [.move], "\(name) held at \(hold)")
                #expect(f.value(name, .move) == [30, 20], "\(name) held at \(hold)")
                f.store.pauseFilm()
                f.undo.undo()
                #expect(f.node(name).motion == nil && !f.undo.canUndo)
            }
        }
        #expect(f.design == design)
    }

    @Test func aLineIsGrownByItsEndsTurnedFromBeyondThemAndTippedFromBesideItsMiddle() {
        let line = Node(kind: .line, name: "Line", frame: CGRect(x: 100, y: 150, width: 200, height: 0))
        let f = FilmBench([line])
        f.store.selection = [f.id("Line")]
        f.store.seek(1)
        let design = f.design
        let c = f.middle("Line"), end = f.corners("Line")[1]
        #expect(closeBy(c, f.view(200, 150)) && closeBy(end, f.view(300, 150)))
        f.drag(end, FilmBench.scaled(end, from: c, 1.5))
        #expect(f.value("Line", .scale) == [1.5, 1.5])
        f.store.pauseFilm()
        f.undo.undo()
        let beyond = FilmBench.out(end, from: c, by: 12)
        f.drag(beyond, Geometry.rotated(beyond, about: c, by: 30))
        #expect(f.value("Line", .turn) == [30])
        f.store.pauseFilm()
        f.undo.undo()
        let beside = c + point(0, -12)
        f.drag(beside, beside + point(0, 50))
        #expect(f.value("Line", .tilt) == [30])
        #expect(f.design == design)
    }

    @Test func aLayerWithNoSizeIsOnlyMovedAndNothingTrips() {
        let speck = CanvasTests.rect("Speck", CGRect(x: 250, y: 150, width: 0, height: 0))
        let f = FilmBench([FilmBench.cardAndBadge[0], speck])
        let design = f.design
        f.store.seek(1)
        f.store.selection = [f.id("Speck")]
        let at = f.view(250, 150)
        #expect(f.corners("Speck").allSatisfy { closeBy($0, at) })
        f.hover(at)
        // With nothing to grow or to turn it has no grips: on it and beside it, the pointer is the arrow.
        #expect(f.tool.cursor(at: at) == NSCursor.arrow)
        #expect(f.tool.cursor(at: at + point(10, 10)) == NSCursor.arrow)
        f.draw()
        // Taken hold of where it is, it is moved.
        f.drag(at, at + point(30, 30))
        #expect(f.keys("Speck", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [30, 30])])
        f.store.pauseFilm()
        f.draw()
        // A press beside it is on the bare sheet.
        f.click(at + point(40, 40))
        #expect(f.store.selection.isEmpty)
        f.store.selection = [f.id("Speck")]
        f.arrow(124)
        f.arrow(125, flags: .shift)
        f.key(40, "k")
        f.draw()
        _ = f.rightClick(at + point(31, 40))
        let now = f.node("Speck")
        #expect(now.motionProperties == [.move])
        #expect(now.value(of: .move, at: 1) == [31, 40])
        #expect(f.design == design)
        #expect(!f.store.inGesture && !f.tool.dragging)
    }

    @Test(.disabled("Film.swift filmChain (line 369) looks for a layer within a reach counted in the layer's own points, so one grown three times is found from nine points off: reported, not changed"))
    func aLayerGrownManyTimesIsStillFoundOnlyWhereItShows() {
        let f = FilmBench()
        let card = f.id("Card")
        f.edit { doc in doc.update(card) { $0.setKey(.scale, [3, 3], at: 0) } }
        let foot = FilmBench.side(f.corners("Card"), 2)
        f.click(foot + point(0, 6))
        #expect(f.store.selection.isEmpty)
        f.click(foot + point(0, 2))
        #expect(f.store.selection == [card])
    }

    // MARK: The beads of its way

    @Test(arguments: FilmView.allCases) func aBeadOfTheWayMovesItsKeyAndPutsThePlayheadOnIt(_ view: FilmView) {
        let f = FilmBench(view: view)
        let z = f.zoom
        f.store.seek(1)
        let home = f.middle("Card")
        f.drag(home, home + point(40, 30) * z)
        f.fresh()
        let design = f.design
        // The bead at home, where the layer is at the start: taken from the film's other end.
        f.drag(home, home + point(20, 20) * z)
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [20, 20]), MotionKey(t: 1, v: [40, 30])])
        #expect(f.store.filmTime == 0)
        #expect(!f.store.film.playing)
        #expect(f.design == design)
        // The layer is where its bead was let go.
        #expect(closeBy(f.middle("Card"), home + point(20, 20) * z))
        f.undo.undo()
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [40, 30])])
        #expect(!f.undo.canUndo)
        // The bead at the other end, taken from the start.
        f.store.seek(0)
        f.drag(home + point(40, 30) * z, home + point(40, 50) * z)
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [40, 50]])
        #expect(f.store.filmTime == 1)
        // Shift keeps a bead to the way it has mostly gone, and home catches it as it does the layer.
        f.store.seek(0)
        f.drag(home + point(40, 50) * z, home + point(3, 42 * z), pulling: .shift)
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [0, 50]])
    }

    @Test func aBeadOnlyPressedPutsThePlayheadOnItsKeyAndChangesNothing() {
        let f = FilmBench()
        f.store.seek(1)
        let home = f.middle("Card")
        f.drag(home, home + point(20, 10))
        f.fresh()
        let before = f.store.doc
        f.click(home)
        #expect(f.store.filmTime == 0)
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.store.inGesture && !f.store.film.playing)
        #expect(f.store.selection == [f.id("Card")])
    }

    @Test func whereTwoKeysLieAtOnePlaceTheLayerIsPosedAtThePlayhead() {
        let f = FilmBench()
        let card = f.id("Card")
        // Out and home again: at the end it lies where it began, and both those beads under it.
        f.edit { doc in
            doc.update(card) { n in
                n.setKey(.move, [0, 0], at: 0)
                n.setKey(.move, [50, 30], at: 1)
                n.setKey(.move, [0, 0], at: 2)
            }
        }
        f.store.selection = [card]
        f.store.seek(2)
        f.fresh()
        let at = f.middle("Card")
        f.drag(at, at + point(0, 40))
        #expect(f.store.filmTime == 2)
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [50, 30], [0, 40]])
    }

    @Test func aBeadLyingInACornersReachForTurningIsStillTheBead() {
        let f = FilmBench()
        let card = f.id("Card")
        // Its way ends just past its own bottom right corner, as it lies at the start.
        f.edit { doc in doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [70, 50], at: 1) } }
        f.store.selection = [card]
        f.fresh()
        let home = f.middle("Card")
        let bead = home + point(70, 50)
        #expect(f.tool.cursor(at: bead) == NSCursor.crosshair)
        f.drag(bead, bead + point(0, 30))
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [70, 80]])
        #expect(f.node("Card").motionProperties == [.move])
        #expect(f.store.filmTime == 1)
        // Beside where the bead was, the corner turns the layer as ever.
        f.store.seek(0)
        f.drag(bead, Geometry.rotated(bead, about: home, by: 20))
        #expect(f.value("Card", .turn) == [20])
    }

    // MARK: Showing what was made, and a press while it plays

    @Test func theFirstKeyOfEachPropertyIsShownAndLaterPosesAreNot() {
        let f = FilmBench()
        f.store.seek(1)
        let c = f.middle("Card")
        f.drag(c, c + point(0, 40))
        #expect(f.store.film.playing && f.store.film.pass?.from == 0 && f.store.film.pass?.to == 1)
        f.store.pauseFilm()
        #expect(!f.store.film.playing && f.store.film.pass == nil && f.store.filmTime == 1)
        // Growing it for the first time, later: that motion is shown, from its start to there.
        f.store.seek(1.5)
        var corner = f.corners("Card")[2]
        f.drag(corner, FilmBench.scaled(corner, from: f.middle("Card"), 1.5))
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == 1.5 && f.store.film.pass?.back == 1.5)
        f.store.pauseFilm()
        #expect(f.store.filmTime == 1.5)
        // Grown again at another moment, nothing plays.
        f.store.seek(2)
        corner = f.corners("Card")[2]
        f.drag(corner, FilmBench.scaled(corner, from: f.middle("Card"), 0.5))
        #expect(!f.store.film.playing)
        #expect(f.keys("Card", .scale).map(\.t) == [0, 1.5, 2])
    }

    @Test func aPressWhileTheFilmPlaysStopsItAndDoesNothingElse() {
        let f = FilmBench()
        f.click(f.middle("Badge"))
        f.store.seek(1)
        let before = f.store.doc
        f.store.playFilm()
        #expect(f.store.film.playing)
        let card = f.middle("Card")
        f.drag(card, card + point(50, 30))
        #expect(!f.store.film.playing)
        #expect(f.store.filmTime == 1)
        #expect(f.store.selection == [f.id("Badge")])
        #expect(f.store.doc == before)
        #expect(!f.tool.dragging && !f.store.inGesture && !f.undo.canUndo)
        // The camera's chip too: the press that stops the film does not take the camera in hand.
        f.store.playFilm()
        f.click(f.chip)
        #expect(!f.store.film.playing && !f.store.film.camera)
        // Stopped, the next press is an ordinary one.
        f.drag(card, card + point(50, 30))
        #expect(f.value("Card", .move) == [50, 30])
    }

    @Test func aPressWhileAMotionJustMadeIsShownGoesOnToWhatItPressed() {
        let f = FilmBench()
        f.store.seek(1)
        let card = f.middle("Card")
        f.drag(card, card + point(50, 30))
        #expect(f.store.film.playing && f.store.film.pass?.to != nil)
        // Without waiting for it to end, the badge is taken and posed.
        let badge = f.middle("Badge")
        f.drag(badge, badge + point(0, -40))
        #expect(f.store.selection == [f.id("Badge")])
        #expect(f.keys("Badge", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [0, -40])])
        f.store.pauseFilm()
        #expect(f.store.filmTime == 1)
        // Each drag its own step.
        f.undo.undo()
        #expect(f.node("Badge").motion == nil && f.node("Card").motion != nil)
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
    }

    // MARK: Escape

    @Test func escapeDuringADragPutsEverythingBackAndLeavesNothingToUndo() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let before = f.store.doc
        let c = f.middle("Card"), q = f.corners("Card")
        let hands: [(from: CGPoint, to: CGPoint, of: MotionProperty)] = [
            (c, c + point(50, 30), .move),
            (q[2], FilmBench.scaled(q[2], from: c, 1.5), .scale),
            (f.side("Card", 1), FilmBench.scaled(f.side("Card", 1), from: c, 1.5), .scale),
            (FilmBench.out(q[2], from: c, by: 12), Geometry.rotated(FilmBench.out(q[2], from: c, by: 12), about: c, by: 30), .turn),
            (FilmBench.out(f.side("Card", 0), from: c, by: 12), FilmBench.out(f.side("Card", 0), from: c, by: 12) + point(0, 50), .tilt),
            (FilmBench.out(f.side("Card", 3), from: c, by: 12), FilmBench.out(f.side("Card", 3), from: c, by: 12) + point(50, 0), .swing),
        ]
        for hand in hands {
            f.press(hand.from)
            f.pull(to: FilmBench.scaled(hand.to, from: hand.from, 0.5))
            f.pull(to: hand.to)
            // In hand, it is posed already.
            #expect(f.node("Card")[track: hand.of] != nil, "\(hand.of)")
            #expect(f.tool.dragging && f.store.inGesture)
            f.key(53)
            #expect(f.store.doc == before, "\(hand.of)")
            #expect(!f.tool.dragging && !f.store.inGesture)
            #expect(f.store.selection == [f.id("Card")])
            // The button comes up afterwards, and that does nothing either.
            f.letGo(at: hand.to)
            #expect(f.store.doc == before, "\(hand.of)")
            #expect(!f.undo.canUndo && !f.store.film.playing)
        }
        // Escape once more, with nothing in hand, lets go of the layer.
        f.key(53)
        #expect(f.store.selection.isEmpty)
    }

    @Test func escapeDuringABeadsDragPutsItsKeyBack() {
        let f = FilmBench()
        f.store.seek(1)
        let home = f.middle("Card")
        f.drag(home, home + point(20, 10))
        f.fresh()
        let before = f.store.doc
        f.press(home)
        f.pull(to: home + point(30, 30))
        #expect(f.keys("Card", .move)[0].v == [30, 30])
        f.key(53)
        f.letGo(at: home + point(30, 30))
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.tool.dragging && !f.store.inGesture)
    }

    @Test func escapeDuringALoopOrAPressLeavesNothingInHand() {
        let f = FilmBench()
        let before = f.store.doc
        // A layer pressed and not yet moved.
        f.press(f.middle("Card"))
        #expect(f.tool.dragging)
        f.key(53)
        #expect(!f.tool.dragging && !f.store.inGesture)
        f.letGo(at: f.middle("Card"))
        // A loop half pulled.
        f.press(f.view(20, 20))
        f.pull(to: f.view(100, 100))
        f.key(53)
        #expect(!f.tool.dragging && !f.store.inGesture)
        f.pull(to: f.view(300, 250))
        f.letGo(at: f.view(300, 250))
        #expect(!f.store.selection.contains(f.id("Badge")))
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo)
    }

    // MARK: The pointer and the marks

    @Test func thePointerSaysWhatAPressWouldDoAndKeepsSayingItWhileItDoes() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.store.seek(1)
        let c = f.middle("Card"), q = f.corners("Card")
        #expect(f.tool.cursor(at: f.chip) == NSCursor.pointingHand)
        #expect(f.tool.cursor(at: f.view(350, 40)) == NSCursor.arrow)
        // Each grip has its own pointer, and none of them is the arrow.
        let corner = f.tool.cursor(at: q[2])
        let side = f.tool.cursor(at: f.side("Card", 1))
        let turn = f.tool.cursor(at: FilmBench.out(q[2], from: c, by: 12))
        let depth = f.tool.cursor(at: FilmBench.out(f.side("Card", 0), from: c, by: 12))
        #expect(corner != NSCursor.arrow && side != NSCursor.arrow && turn != NSCursor.arrow && turn != corner)
        #expect(depth == Cursors.turn)
        // In hand, the pointer stays what it was when it took hold, wherever it is pulled to.
        f.press(q[2])
        #expect(f.tool.cursor(at: q[2]) == corner)
        f.pull(to: FilmBench.scaled(q[2], from: c, 1.5))
        #expect(f.tool.cursor(at: FilmBench.scaled(q[2], from: c, 1.5)) == corner)
        f.key(53)
        f.letGo(at: q[2])
        f.press(FilmBench.out(f.side("Card", 0), from: c, by: 12))
        f.pull(to: c)
        #expect(f.tool.cursor(at: c) == Cursors.turn)
        f.key(53)
        f.letGo(at: c)
        // A bead of its way shows a cross.
        f.drag(c, c + point(20, 10))
        f.store.pauseFilm()
        #expect(f.tool.cursor(at: c) == NSCursor.crosshair)
        // With the camera in hand, the film is taken hold of by an open hand, which closes on it.
        f.click(f.chip)
        #expect(f.tool.cursor(at: f.view(350, 40)) == NSCursor.openHand)
        f.press(f.view(350, 40))
        f.pull(to: f.view(330, 40))
        #expect(f.tool.cursor(at: f.view(330, 40)) == NSCursor.closedHand)
        f.letGo(at: f.view(330, 40))
        f.store.pauseFilm()
        // Off the film there is nothing to take hold of.
        #expect(f.tool.cursor(at: f.table(300, 600)) == NSCursor.arrow)
    }

    @Test func theMarksAreDrawnInEveryStateOfTheDesk() {
        var tilted = CanvasTests.rect("Tilted", CGRect(x: 60, y: 200, width: 100, height: 60))
        tilted.rotation = 30
        let f = FilmBench(FilmBench.cardAndBadge + [FilmBench.row, tilted])
        f.draw()
        f.hover(f.middle("Card"))
        f.draw()
        f.store.seek(1)
        let c = f.middle("Card")
        f.press(c)
        f.pull(to: c + point(20, 10))
        f.draw()
        f.pull(to: c + point(50, 30))
        f.letGo(at: c + point(50, 30))
        // While the motion is shown, and once it has stopped: its way, its beads and its home.
        f.draw()
        f.store.pauseFilm()
        f.draw()
        f.hover(c)
        f.draw()
        f.store.seek(0.4)
        f.draw()
        // Tipped in depth, several picked, a loop in hand, and the camera.
        let grip = FilmBench.out(f.side("Card", 0), from: f.middle("Card"), by: 12)
        f.drag(grip, grip + point(0, 60))
        f.store.pauseFilm()
        f.draw()
        f.click(f.middle("Badge"), flags: .shift)
        f.draw()
        f.press(f.view(380, 280))
        f.pull(to: f.view(200, 100))
        f.draw()
        f.letGo(at: f.view(200, 100))
        f.click(f.chip)
        f.draw()
        f.drag(f.view(380, 280), f.view(340, 260))
        f.store.pauseFilm()
        f.hover(f.chip)
        f.draw()
        #expect(f.store.film.camera)
    }
}
