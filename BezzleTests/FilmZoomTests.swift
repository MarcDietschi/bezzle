import Testing
import AppKit
@testable import Bezzle

/// Two fingers on the trackpad or the wheel over the timeline, as `FilmFingers` is told of them.
nonisolated final class SheetFingers: NSEvent, @unchecked Sendable {
    private let kind: NSEvent.EventType
    private let place: CGPoint
    private let pane: NSWindow?
    private let pinch: CGFloat
    private let by: CGSize
    private let moment: NSEvent.Phase
    private let coasting: NSEvent.Phase
    private let keys: NSEvent.ModifierFlags
    private let fine: Bool

    init(_ kind: NSEvent.EventType, at place: CGPoint, in pane: NSWindow?, pinch: CGFloat = 0, by: CGSize = .zero, _ moment: NSEvent.Phase = [],
         coasting: NSEvent.Phase = [], keys: NSEvent.ModifierFlags = [], fine: Bool = true) {
        self.kind = kind
        self.place = place
        self.pane = pane
        self.pinch = pinch
        self.by = by
        self.moment = moment
        self.coasting = coasting
        self.keys = keys
        self.fine = fine
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { pane }
    override var locationInWindow: NSPoint { place }
    override var magnification: CGFloat { pinch }
    override var scrollingDeltaX: CGFloat { by.width }
    override var scrollingDeltaY: CGFloat { by.height }
    override var hasPreciseScrollingDeltas: Bool { fine }
    override var phase: NSEvent.Phase { moment }
    override var momentumPhase: NSEvent.Phase { coasting }
    override var modifierFlags: NSEvent.ModifierFlags { keys }
}

/// The timeline looked at closer: a pinch about the moment under the pointer, two fingers moving
/// it along, the way back to the whole film, and everything the pointer does on it at any
/// closeness. How close it is looked at is the viewer's own, and no part of the design.
@MainActor
struct FilmZoomTests {
    /// On artboard A: a card, and a badge beside it.
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
        // The card with a move from 0.2 to 0.8 and a fade from 0.2 to 0.6: a film of two seconds.
        let card = bench.node("Card")!.id
        bench.step {
            bench.store.edit("Add Key") { doc in
                doc.update(card) { n in
                    n.setKey(.move, [30, 0], at: 0.2)
                    n.setKey(.move, [0, 0], at: 0.8)
                    n.setKey(.fade, [0], at: 0.2)
                    n.setKey(.fade, [1], at: 0.6)
                }
            }
        }
    }

    var store: DocumentStore { bench.store }
    private var card: UUID { bench.node("Card")!.id }
    private var scale: FilmScale { hand.scale(width: width) }
    private var rows: [FilmRow] { FilmRow.rows(of: store.filmBoard!, open: store.film.open) }
    private var length: Double { store.filmBoard!.filmLength }
    private var whole: Double { store.filmWhole }

    private func keys(_ property: MotionProperty) -> [Double] {
        (bench.node("Card")?[track: property]?.keys ?? []).map(\.t)
    }

    private func at(_ t: Double, line: Int) -> CGPoint {
        CGPoint(x: scale.x(t), y: (CGFloat(line) + 0.5) * FilmTimeline.rowHeight)
    }

    /// Whether the timeline shows this part of the film, give or take what numbers lose.
    private func shows(_ start: Double, _ span: Double) -> Bool {
        guard let part = store.film.window else { return false }
        return abs(part.start - start) < 1e-9 && abs(part.span - span) < 1e-9
    }

    /// Looks at the film `factor` times closer about a moment.
    private func zoom(_ factor: Double, about t: Double) {
        hand.zoom(by: factor, at: scale.x(t), scale: scale)
    }

    /// A press on a line at one moment, dragged to another in steps, and let go: one step.
    private func drag(line: Int, from: Double, to: Double, flags: NSEvent.ModifierFlags = []) {
        let a = at(from, line: line), b = at(to, line: line)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale, flags: flags)
            for i in 1...4 {
                let x = a.x + (b.x - a.x) * CGFloat(i) / 4
                hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length, flags: flags)
            }
            hand.ended(scale: scale, flags: flags)
        }
    }

    // MARK: Where moments lie

    @Test func aSheetMovedAlongStillTellsMomentsAndPointsBothWays() {
        let scale = FilmScale(width: 600, span: 0.8, start: 1.3)
        for t in [1.3, 1.31, 1.7, 2.1, 0, 5] { #expect(abs(scale.t(scale.x(t)) - t) < 1e-9) }
        // Its first moment lies where a whole sheet's start does, and its last as far from the other edge.
        #expect(scale.x(1.3) == FilmScale.inset)
        #expect(abs(scale.x(2.1) - (600 - FilmScale.inset)) < 1e-9)
        // What comes before it lies off the sheet, to the left.
        #expect(scale.x(1) < 0)
        // A sheet that starts where the film does is the sheet there was before any could be moved.
        #expect(FilmScale(width: 600, span: 2) == FilmScale(width: 600, span: 2, start: 0))
    }

    @Test func aWindowIsNeverPastTheFilmNorAllOfIt() {
        #expect(FilmWindow(start: 0.5, span: 1).fitted(to: 4) == FilmWindow(start: 0.5, span: 1))
        #expect(FilmWindow(start: 3.5, span: 1).fitted(to: 4) == FilmWindow(start: 3, span: 1))
        #expect(FilmWindow(start: -2, span: 1).fitted(to: 4) == FilmWindow(start: 0, span: 1))
        // As wide as the film, or wider, it is the whole film: no window at all.
        #expect(FilmWindow(start: 0, span: 4).fitted(to: 4) == nil)
        #expect(FilmWindow(start: 1, span: 9).fitted(to: 4) == nil)
        // And one that is no number is none.
        #expect(FilmWindow(start: .nan, span: 1).fitted(to: 4) == nil)
        #expect(FilmWindow(start: 0, span: .infinity).fitted(to: 4) == nil)
        #expect(FilmWindow(start: 0, span: 0).fitted(to: 4) == nil)
        // The whole sheet of a film, and a part of it.
        #expect(FilmScale(width: 600, length: 1.8, window: nil) == FilmScale(width: 600, span: 2))
        #expect(FilmScale(width: 600, length: 1.8, window: FilmWindow(start: 0.4, span: 0.5)) == FilmScale(width: 600, span: 0.5, start: 0.4))
        #expect(FilmScale(width: 600, length: 1.8, window: FilmWindow(start: 0.4, span: 7)) == FilmScale(width: 600, span: 2))
    }

    // MARK: A pinch

    @Test func aPinchKeepsTheMomentUnderThePointerWhereItIs() {
        #expect(!hand.zoomed && store.film.window == nil)
        let x = scale.x(0.8)
        var last = scale.perSecond
        for factor in [1.2, 1.5, 1.07, 2] {
            hand.zoom(by: factor, at: x, scale: scale)
            #expect(abs(scale.x(0.8) - x) < 1e-6, "by \(factor)")
            #expect(abs(Double(scale.perSecond / last) - factor) < 1e-6, "by \(factor)")
            last = scale.perSecond
        }
        #expect(hand.zoomed)
        // And back out about the same moment, as far as leaves the film's start in sight.
        hand.zoom(by: 0.8, at: x, scale: scale)
        #expect(abs(scale.x(0.8) - x) < 1e-6)
        // Under any point of the sheet, whatever moment is there.
        for x in [FilmScale.inset, 100, 333.3, width - FilmScale.inset] as [CGFloat] {
            store.film.window = nil
            hand.zoom(by: 1.4, at: x, scale: scale)
            let moment = scale.t(x)
            hand.zoom(by: 1.4, at: x, scale: scale)
            #expect(abs(scale.t(x) - moment) < 1e-9, "at \(x)")
        }
        // Off the sheet's ends, as over the names beside it, it is the moment at that end.
        store.film.window = nil
        zoom(3, about: 1)
        let first = scale.start
        hand.zoom(by: 1.5, at: -80, scale: scale)
        #expect(abs(scale.start - first) < 1e-9)
    }

    @Test func itIsLookedAtNoCloserThanAKeySteps() {
        zoom(1000, about: 0.8)
        // A second is `closest` points wide, a hundredth of one a dozen.
        #expect(abs(scale.perSecond - FilmWindow.closest) < 1e-6)
        let closest = store.film.window!
        zoom(2, about: 0.8)
        #expect(shows(closest.start, closest.span))
        // A film too short to be looked at any closer stays whole: here on a wider sheet, where
        // its half second is closer already.
        bench.step { store.setFilm("Film Length") { $0.length = 0.25 } }
        store.film.window = nil
        let before = hand.scale(width: 1000)
        #expect(before.perSecond > FilmWindow.closest)
        hand.zoom(by: 3, at: before.x(0.1), scale: before)
        #expect(store.film.window == nil && hand.scale(width: 1000) == before)
        // A factor that is none changes nothing.
        bench.step { store.setFilm("Film Length") { $0.length = nil } }
        for factor in [0, -2, .nan, .infinity] {
            hand.zoom(by: factor, at: 200, scale: scale)
            #expect(store.film.window == nil, "by \(factor)")
        }
    }

    @Test func pinchedBackOutItCatchesAtTheWholeFilm() {
        let before = scale
        zoom(6, about: 1.2)
        #expect(hand.zoomed)
        // Out in steps, as fingers go: it ends as the whole film, exactly, and goes no further.
        for _ in 0..<12 { hand.zoom(by: 0.7, at: scale.x(1.2), scale: scale) }
        #expect(store.film.window == nil && !hand.zoomed)
        #expect(scale == before)
        hand.zoom(by: 0.5, at: 300, scale: scale)
        #expect(scale == before)
    }

    @Test func atEitherEndOfTheFilmTheSheetStopsAndTheMomentGivesWay() {
        // Closer about the very start: the start stays at the sheet's left end.
        zoom(4, about: 0)
        #expect(scale.start == 0)
        // Back out about a late moment, from a part at the film's end: never past the end.
        store.film.window = FilmWindow(start: whole - 0.4, span: 0.4)
        for _ in 0..<5 {
            hand.zoom(by: 0.8, at: FilmScale.inset + 20, scale: scale)
            #expect(scale.start >= 0 && scale.start + scale.span <= whole + 1e-9)
        }
    }

    @Test func aDoubleTapWithTwoFingersGoesCloserAndBackToTheWholeFilm() {
        let before = scale
        let x = scale.x(0.6)
        hand.smartZoom(at: x, scale: scale)
        #expect(hand.zoomed)
        #expect(abs(Double(scale.perSecond / before.perSecond) - 4) < 1e-6)
        #expect(abs(scale.x(0.6) - x) < 1e-6)
        // Moved along and looked at closer still, the next one shows the whole film again.
        hand.scroll(by: -60, scale: scale)
        zoom(1.3, about: 1)
        hand.smartZoom(at: 40, scale: scale)
        #expect(store.film.window == nil && scale == before)
    }

    // MARK: Two fingers sideways

    @Test func twoFingersMoveASheetLookedAtCloserAlongAndStopAtTheFilmsEnds() {
        // The whole film has nowhere to go.
        hand.scroll(by: -120, scale: scale)
        #expect(store.film.window == nil)
        zoom(4, about: 1)
        let x = scale.x(1), span = scale.span
        // With the fingers: what was under them stays under them.
        hand.scroll(by: -50, scale: scale)
        #expect(abs(scale.x(1) - (x - 50)) < 1e-6 && scale.span == span)
        hand.scroll(by: 80, scale: scale)
        #expect(abs(scale.x(1) - (x + 30)) < 1e-6)
        // To the film's end and no further, and back to its start.
        hand.scroll(by: -50_000, scale: scale)
        #expect(abs(scale.start + scale.span - whole) < 1e-9)
        hand.scroll(by: -10, scale: scale)
        #expect(abs(scale.start + scale.span - whole) < 1e-9)
        hand.scroll(by: 50_000, scale: scale)
        #expect(scale.start == 0 && scale.span == span && hand.zoomed)
    }

    // MARK: The pointer at any closeness

    @Test func keysAreHitWhereTheyAreDrawnHoweverCloseAndWhereverTheSheetIs() {
        let ref = { (t: Double) in FilmKeyRef(self.card, at: t) }
        let views: [() -> Void] = [
            {},
            { self.zoom(2, about: 0.5) },
            { self.zoom(3, about: 0.7); self.hand.scroll(by: 40, scale: self.scale) },
            { self.zoom(40, about: 0.6) },
            { self.hand.scroll(by: -25, scale: self.scale) },
            { self.hand.smartZoom(at: 0, scale: self.scale) },
        ]
        for (i, look) in views.enumerated() {
            look()
            let scale = scale, rows = rows
            for t in [0.2, 0.6, 0.8] {
                let x = scale.x(t)
                // Only what is in sight can be pointed at.
                guard x >= 0, x <= width else { continue }
                let y = at(0, line: 1).y
                #expect(hand.point(CGPoint(x: x, y: y), rows: rows, scale: scale).key == ref(t), "view \(i), key at \(t)")
                #expect(hand.point(CGPoint(x: x + FilmHand.reach, y: y), rows: rows, scale: scale).key == ref(t), "view \(i), key at \(t)")
                // Further off than its reach it is not that bead, though another may be there.
                #expect(hand.point(CGPoint(x: x + FilmHand.reach + 1, y: y), rows: rows, scale: scale).key != ref(t), "view \(i), key at \(t)")
            }
            // Between the first key and the last, clear of them, it is the band.
            let mid = scale.x(0.4)
            if mid >= 0, mid <= width, abs(scale.x(0.2) - mid) > FilmHand.reach, abs(scale.x(0.6) - mid) > FilmHand.reach {
                #expect(hand.point(CGPoint(x: mid, y: at(0, line: 1).y), rows: rows, scale: scale).band == rows[1].id, "view \(i)")
            }
        }
    }

    @Test func aKeyDraggedMovesByTheTimeItIsDraggedAcrossHoweverClose() {
        let far = scale.x(1.1) - scale.x(0.8)
        // On the whole film.
        drag(line: 1, from: 0.8, to: 1.1)
        #expect(keys(.move) == [0.2, 1.1])
        bench.undo.undo()
        #expect(keys(.move) == [0.2, 0.8])
        // Four times closer, to the same moment: four times as far for the hand.
        zoom(4, about: 0.8)
        #expect(abs((scale.x(1.1) - scale.x(0.8)) / far - 4) < 1e-6)
        drag(line: 1, from: 0.8, to: 1.1)
        #expect(keys(.move) == [0.2, 1.1])
        // The fade's key at 0.6 was not picked and stays.
        #expect(keys(.fade) == [0.2, 0.6])
        // The sheet did not move under the drag, nor is it held as a whole film's is.
        #expect(hand.zoomed && hand.held == nil)
        bench.undo.undo()
        // Most of that way across the sheet again is a quarter of the time: 0.06 seconds, and
        // by twentieths still.
        let a = at(0.8, line: 1), some = far * 0.8
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: a.x + some, y: a.y), by: some, rows: rows, scale: scale, length: length)
            hand.ended(scale: scale)
        }
        #expect(keys(.move) == [0.2, 0.85])
        bench.undo.undo()
        // Very close, Option steps by hundredths, each a dozen points apart.
        zoom(1000, about: 0.8)
        drag(line: 1, from: 0.8, to: 0.83, flags: .option)
        #expect(keys(.move) == [0.2, 0.83])
    }

    @Test func severalKeysPickedMoveTogetherOnASheetLookedAtCloser() {
        zoom(2.5, about: 0.3)
        let (rows, scale) = (rows, scale)
        #expect(scale.x(0.2) > 0 && scale.x(0.95) < width)
        bench.step {
            hand.press(at: at(0.2, line: 1), rows: rows, scale: scale)
            hand.ended(scale: scale)
            hand.press(at: at(0.8, line: 1), rows: rows, scale: scale, flags: .shift)
            hand.ended(scale: scale, flags: .shift)
        }
        #expect(store.film.keys == [FilmKeyRef(card, at: 0.2), FilmKeyRef(card, at: 0.8)])
        drag(line: 1, from: 0.8, to: 0.95)
        #expect(keys(.move) == [0.35, 0.95])
        #expect(keys(.fade) == [0.35, 0.6])
    }

    @Test func aBandDraggedMovesTheWholeMotionOnASheetLookedAtCloser() {
        zoom(2, about: 0.5)
        drag(line: 1, from: 0.4, to: 0.7)
        #expect(keys(.move) == [0.5, 1.1])
        #expect(keys(.fade) == [0.5, 0.9])
    }

    @Test func twiceOnALineSetsAKeyAtTheMomentUnderThePointer() {
        zoom(5, about: 1.2)
        let (rows, scale) = (rows, scale)
        bench.step {
            hand.press(at: at(1.25, line: 1), rows: rows, scale: scale, clicks: 2)
            hand.ended(scale: scale)
        }
        #expect(keys(.move) == [0.2, 0.8, 1.25])
        #expect(store.filmTime == 1.25)
    }

    @Test func thePlayheadGoesToTheMomentUnderThePointerAndWaitsAtTheEndOfWhatShows() {
        zoom(4, about: 1)
        let (rows, scale) = (rows, scale)
        let p = at(1.1, line: 2)
        hand.press(at: p, rows: rows, scale: scale)
        hand.dragged(to: p, by: 0, rows: rows, scale: scale, length: length)
        #expect(store.filmTime == 1.1)
        hand.dragged(to: CGPoint(x: scale.x(0.93), y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .option)
        #expect(store.filmTime == 0.93)
        // Past the last moment in sight it waits there, in sight; and past the first, there.
        hand.dragged(to: CGPoint(x: width + 300, y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .command)
        #expect(abs(store.filmTime - (scale.start + scale.span)) < 0.0006)
        hand.dragged(to: CGPoint(x: -300, y: p.y), by: 0, rows: rows, scale: scale, length: length, flags: .command)
        #expect(abs(store.filmTime - scale.start) < 0.0006)
        // The sheet stays where it is under a hand on the playhead: only that hand moves it.
        #expect(self.scale == scale)
        hand.ended(scale: scale)
        // The flag at the film's end is taken where it is drawn.
        store.film.window = FilmWindow(start: 1.5, span: 0.6)
        #expect(hand.pointRuler(CGPoint(x: self.scale.x(length), y: 10), scale: self.scale, length: length).end)
        #expect(!hand.pointRuler(CGPoint(x: self.scale.x(length) + 20, y: 10), scale: self.scale, length: length).end)
    }

    // MARK: Past the ends of what shows

    @Test func theSheetCreepsAlongUnderAPlayheadDraggedPastItsEnd() {
        zoom(4, about: 0.6)
        let began = scale
        let p = at(0.7, line: 2)
        hand.press(at: p, rows: rows, scale: scale)
        hand.dragged(to: p, by: 0, rows: rows, scale: scale, length: length, flags: .command)
        // Within the sheet nothing creeps.
        #expect(!hand.creep(0.1) && scale == began)
        // Forty points past the last moment in sight: along at 520 points a second.
        let out = CGPoint(x: width - FilmScale.inset + 40, y: p.y)
        hand.dragged(to: out, by: out.x - p.x, rows: rows, scale: scale, length: length, flags: .command)
        #expect(FilmHand.creepRate(at: out.x, width: width) == 520)
        #expect(hand.creep(0.1))
        #expect(abs(scale.start - (began.start + 52 / Double(began.perSecond))) < 1e-9)
        // The playhead waits at the end of what shows, as the film runs by under it.
        #expect(abs(store.filmTime - (scale.start + scale.span)) < 0.0006)
        // To the film's end, and no further: there is nothing more to bring in.
        var steps = 0
        while hand.creep(0.1), steps < 500 { steps += 1 }
        #expect(steps < 500 && abs(scale.start + scale.span - whole) < 1e-9)
        #expect(store.filmTime == length)
        // Back past the first moment in sight, it creeps the other way, faster the further out.
        let back = CGPoint(x: -100, y: p.y)
        hand.dragged(to: back, by: back.x - p.x, rows: rows, scale: scale, length: length, flags: .command)
        let from = scale.start
        #expect(FilmHand.creepRate(at: -100, width: width) < FilmHand.creepRate(at: -20, width: width))
        #expect(hand.creep(0.05) && scale.start < from)
        #expect(abs(store.filmTime - scale.start) < 0.0006)
        hand.ended(scale: scale)
        // Let go, it creeps no more.
        #expect(!hand.creep(0.1))
        // Nor does a whole film ever.
        store.film.window = nil
        hand.press(at: p, rows: rows, scale: scale)
        hand.dragged(to: out, by: out.x - p.x, rows: rows, scale: scale, length: length)
        #expect(!hand.creep(0.1) && store.film.window == nil)
        hand.ended(scale: scale)
    }

    @Test func aKeyDraggedPastTheEndOfWhatShowsGoesOnWithTheSheet() {
        zoom(4, about: 0.6)
        let a = at(0.8, line: 1)
        let out = CGPoint(x: width - FilmScale.inset + 60, y: a.y)
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: out, by: out.x - a.x, rows: rows, scale: scale, length: length, flags: .command)
            // It waits at the last moment in sight.
            #expect(abs((keys(.move).last ?? 0) - (scale.start + scale.span)) < 0.0011)
            let before = keys(.move).last ?? 0
            for _ in 0..<5 { hand.creep(0.1) }
            // And is taken along as the sheet moves on, still at its end.
            #expect((keys(.move).last ?? 0) > before + 0.1)
            #expect(abs((keys(.move).last ?? 0) - (scale.start + scale.span)) < 0.0011)
            hand.ended(scale: scale)
        }
        #expect(keys(.move).first == 0.2)
        // The whole drag, creeping and all, is one step.
        bench.undo.undo()
        #expect(keys(.move) == [0.2, 0.8])
    }

    // MARK: The playhead kept in sight

    @Test func aPlayheadPutOutOfSightBringsTheSheetAlong() {
        store.film.window = FilmWindow(start: 1.4, span: 0.5)
        // Within what shows, the sheet stays.
        store.seek(1.6)
        #expect(store.film.window == FilmWindow(start: 1.4, span: 0.5))
        // Out of it, the moment comes to the middle; near the film's start, as near as the start allows.
        store.seek(0.8)
        #expect(shows(0.55, 0.5))
        store.seek(0.1)
        #expect(store.film.window == FilmWindow(start: 0, span: 0.5))
        // Stepping from key to key does the same.
        store.selection = [card]
        store.stepToKey(forward: true)
        #expect(store.filmTime == 0.2 && store.film.window?.holds(0.2) == true)
        store.stepToKey(forward: true)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 0.8 && store.film.window?.holds(0.8) == true)
        // A whole film is left whole.
        store.film.window = nil
        store.seek(1.9)
        #expect(store.film.window == nil)
    }

    @Test func aFilmPlayingOutOfWhatShowsTurnsThePage() {
        store.film.window = FilmWindow(start: 0, span: 0.5)
        store.playFilm(fromStart: true)
        let began = store.film.pass?.began ?? CACurrentMediaTime()
        #expect(store.filmStep(began + 0.3))
        #expect(store.film.window == FilmWindow(start: 0, span: 0.5))
        // Past its end, the sheet goes on a page: the playhead an eighth in, the rest still to come.
        #expect(store.filmStep(began + 0.52))
        #expect(store.film.window?.span == 0.5)
        #expect(abs((store.film.window?.start ?? 0) - (0.52 - 0.0625)) < 1e-9)
        let page = store.film.window
        #expect(store.filmStep(began + 0.7))
        #expect(store.film.window == page)
        // Moved away by hand while it plays, the sheet is left where it was put.
        store.film.window = FilmWindow(start: 1.6, span: 0.5)
        #expect(store.filmStep(began + 0.9))
        #expect(store.film.window == FilmWindow(start: 1.6, span: 0.5))
        // The film comes into it by itself, and takes it along again as it leaves: round to the start.
        #expect(store.filmStep(began + 1.8))
        #expect(store.filmStep(began + 2 + FilmDesk.breath + 0.01))
        #expect(store.film.window == FilmWindow(start: 0, span: 0.5))
        // Stopped, the sheet stays as it is looked at.
        store.film.window = FilmWindow(start: 1.2, span: 0.5)
        store.pauseFilm()
        #expect(store.film.window == FilmWindow(start: 1.2, span: 0.5))
    }

    @Test func whatFollowsThePlayheadIsToldOnlyWhenThePageTurns() {
        store.film.window = FilmWindow(start: 0, span: 1)
        nonisolated final class Told: @unchecked Sendable { var times = 0 }
        let told = Told()
        func watch() {
            withObservationTracking { _ = store.film.window } onChange: { told.times += 1 }
        }
        watch()
        // A scrub through what shows, and a film playing through it: the timeline's lines are not drawn again.
        for i in 0...40 { store.seek(Double(i) * 0.02) }
        store.playFilm(fromStart: true)
        let began = store.film.pass?.began ?? CACurrentMediaTime()
        for i in 0...50 { _ = store.filmStep(began + Double(i) * 0.019) }
        #expect(told.times == 0)
        // Out of it: once.
        _ = store.filmStep(began + 1.1)
        #expect(told.times == 1)
        watch()
        for i in 0...20 { _ = store.filmStep(began + 1.1 + Double(i) * 0.02) }
        #expect(told.times == 1)
    }

    // MARK: The viewer's own

    @Test func howCloseItIsLookedAtIsNoPartOfTheDesign() {
        let design = store.doc, version = store.version, steps = bench.undo.canUndo
        let name = bench.undo.undoActionName
        zoom(3, about: 0.7)
        hand.scroll(by: -40, scale: scale)
        hand.smartZoom(at: 100, scale: scale)
        hand.smartZoom(at: 100, scale: scale)
        zoom(0.2, about: 1)
        zoom(3, about: 0.7)
        #expect(hand.zoomed)
        #expect(store.doc == design && store.version == version)
        #expect(bench.undo.canUndo == steps && bench.undo.undoActionName == name)
        // Each film is seen whole first: another artboard's is not looked at as this one was.
        store.selection = [bench.b.id]
        #expect(store.film.board == bench.b.id && store.film.window == nil && !hand.zoomed)
    }

    @Test func aFilmThatGetsShorterIsNotLookedAtPastItsEnd() {
        bench.step { store.setFilm("Film Length") { $0.length = 6 } }
        store.film.window = FilmWindow(start: 5, span: 1)
        bench.step { store.setFilm("Film Length") { $0.length = 3 } }
        let part = store.film.window
        #expect(part?.span == 1)
        #expect(abs((part?.end ?? 0) - store.filmWhole) < 1e-9)
        // Shorter than what was looked at, it is all there is to see.
        bench.step { store.setFilm("Film Length") { $0.length = 0.5 } }
        #expect(store.film.window == nil && !hand.zoomed)
        #expect(scale == FilmScale(width: width, span: FilmScale.span(for: 0.5)))
    }

    @Test func aWholeFilmIsStillHeldAsItWasWhileAKeyIsDraggedPastItsEnd() {
        let a = at(0.8, line: 1), x = scale.x(2.15), before = scale
        bench.step {
            hand.press(at: a, rows: rows, scale: scale)
            hand.dragged(to: CGPoint(x: x, y: a.y), by: x - a.x, rows: rows, scale: scale, length: length)
            // The film grew, and the seconds hold still under the hand.
            #expect(length == 2.5 && scale == before)
            hand.ended(scale: scale)
        }
        #expect(scale == FilmScale(width: width, span: FilmScale.span(for: 2.5)))
        #expect(store.film.window == nil)
    }

    // MARK: The ruler

    @Test func theRulersNumbersThinOutAndFillIn() {
        var last = Double.infinity
        var steps: Set<Double> = []
        for i in 0...200 {
            // From a second one point wide to the closest there is.
            let perSecond = CGFloat(pow(Double(FilmWindow.closest), Double(i) / 200))
            let (major, parts) = FilmRuler.step(perSecond)
            steps.insert(major)
            // The numbers stand clear of each other, and the strokes between them can be told apart.
            #expect(CGFloat(major) * perSecond >= 52, "\(perSecond) points a second")
            #expect(CGFloat(major) * perSecond < 52 * 3.1, "\(perSecond) points a second")
            #expect(CGFloat(major / Double(parts)) * perSecond >= 5, "\(perSecond) points a second")
            // Closer, never fewer numbers.
            #expect(major <= last, "\(perSecond) points a second")
            last = major
        }
        #expect(steps.count >= 10)
        // As close as it goes: a number every twentieth of a second, a stroke every hundredth.
        #expect(FilmRuler.step(FilmWindow.closest) == (0.05, 5))
        // Tenths are halved, where a key steps, until hundredths can be told apart.
        #expect(FilmRuler.step(560) == (0.1, 2) && FilmRuler.step(700) == (0.1, 10))
        // A whole film's ruler is the one there always was.
        #expect(FilmRuler.step(257.4) == (0.5, 5) && FilmRuler.step(60) == (1, 10) && FilmRuler.step(1) == (60, 6))
    }

    @Test func aRulerDrawsOnlyTheStrokesInSight() {
        // A whole film: from its start.
        let whole = FilmScale(width: 600, span: 2.5)
        let all = FilmRuler.strokes(perSecond: whole.perSecond, origin: whole.x(0), width: 600)
        #expect(all.first == 0 && all.major == 0.5 && all.parts == 5)
        #expect(whole.x(Double(all.end - 1) * 0.1) <= 598 && whole.x(Double(all.end) * 0.1) > 598)
        // Ten minutes in, as close as it goes: a few dozen strokes, not the sixty thousand before them.
        let close = FilmScale(width: 600, span: 572 / Double(FilmWindow.closest), start: 600)
        let some = FilmRuler.strokes(perSecond: close.perSecond, origin: close.x(0), width: 600)
        #expect(some.end - some.first < 80 && some.first > 59_000)
        // The first is a numbered one, at the left edge or the last before it, so its number shows.
        #expect(some.first % some.parts == 0)
        let x = close.x(Double(some.first) * some.major / Double(some.parts))
        #expect(x <= 0.001 && x > -CGFloat(some.major) * close.perSecond - 0.001)
        // Numbers past a minute keep the parts of a second where strokes are that close.
        #expect(FilmRuler.label(0.75) == "0.75" && FilmRuler.label(12, step: 0.5) == "12")
        #expect(FilmRuler.label(75, step: 5) == "1:15" && FilmRuler.label(600, step: 60) == "10:00")
        #expect(FilmRuler.label(61.5, step: 0.5) == "1:01.5" && FilmRuler.label(600.05, step: 0.05) == "10:00.05")
        #expect(FilmRuler.label(62, step: 0.5) == "1:02")
    }

    // MARK: Fingers and the wheel, as the window tells of them

    /// A window nobody sees with the sheet's ground in it, 800 wide: the names take 150 of it.
    private func ground() -> (fingers: FilmFingers, window: NSWindow, names: CGFloat, sheet: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 50, y: 100, width: 800, height: 126))
        window.contentView?.addSubview(view)
        let fingers = FilmFingers(hand: hand)
        fingers.ground = view
        return (fingers, window, FilmTimeline.names(in: 800), FilmTimeline.sheet(in: 800))
    }

    @Test func aPinchOverTheSheetIsTheTimelinesFromFirstToLast() {
        let g = ground()
        let sheet = hand.scale(width: g.sheet)
        // Over the moment at 0.8, on the third line.
        let x = sheet.x(0.8)
        let on = CGPoint(x: 50 + g.names + x, y: 160)
        #expect(g.fingers.take(SheetFingers(.magnify, at: on, in: g.window, pinch: 0.25, .began)))
        #expect(g.fingers.take(SheetFingers(.magnify, at: on, in: g.window, pinch: 0.25, .changed)))
        #expect(g.fingers.take(SheetFingers(.magnify, at: on, in: g.window, pinch: 0, .ended)))
        let now = hand.scale(width: g.sheet)
        #expect(abs(Double(now.perSecond / sheet.perSecond) - 1.25 * 1.25) < 1e-6)
        #expect(abs(now.x(0.8) - x) < 1e-6)
        // One begun off the sheet is not, though it goes on: it is the canvas's.
        let off = CGPoint(x: 400, y: 300)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            #expect(!g.fingers.take(SheetFingers(.magnify, at: off, in: g.window, pinch: 0.3, phase)))
        }
        #expect(hand.scale(width: g.sheet) == now)
        // Nor one in another window, or while a menu is open over the sheet.
        #expect(!g.fingers.take(SheetFingers(.magnify, at: on, in: NSWindow(), pinch: 0.3, .began)))
        let menus = MenuHost()
        g.fingers.menus = menus
        menus.open = MenuHost.Open(id: "a", place: .point(.zero), content: .entries([]), width: 100)
        #expect(!g.fingers.take(SheetFingers(.magnify, at: on, in: g.window, pinch: 0.3, .began)))
        menus.open = nil
        // A double tap with two fingers there: the whole film again.
        #expect(g.fingers.take(SheetFingers(.smartMagnify, at: on, in: g.window)))
        #expect(store.film.window == nil)
        #expect(!g.fingers.take(SheetFingers(.smartMagnify, at: off, in: g.window)))
    }

    @Test func theWheelAndTwoFingersMovingAreTheTimelinesOnlyWhereTheyMoveIt() {
        let g = ground()
        let sheet = hand.scale(width: g.sheet)
        let x = sheet.x(1)
        let on = CGPoint(x: 50 + g.names + x, y: 160)
        func wheel(_ dx: CGFloat, _ dy: CGFloat, _ phase: NSEvent.Phase = [], coasting: NSEvent.Phase = [], keys: NSEvent.ModifierFlags = [], fine: Bool = true, at p: CGPoint? = nil) -> Bool {
            g.fingers.take(SheetFingers(.scrollWheel, at: p ?? on, in: g.window, by: CGSize(width: dx, height: dy), phase, coasting: coasting, keys: keys, fine: fine))
        }
        // Up and down is the lines', and sideways over a whole film nobody's.
        #expect(!wheel(0, -12, fine: false))
        #expect(!wheel(30, 2, .began) && !wheel(30, 2, .changed) && !wheel(0, 0, .ended))
        #expect(store.film.window == nil)
        // With Command, Option or Control the wheel looks closer about the pointer, as on the canvas.
        for key in [NSEvent.ModifierFlags.command, .option, .control] {
            store.film.window = nil
            #expect(wheel(0, 3, keys: key, fine: false))
            let now = hand.scale(width: g.sheet)
            #expect(abs(Double(now.perSecond / sheet.perSecond) - exp(0.3)) < 1e-6 && abs(now.x(1) - x) < 1e-6)
            #expect(wheel(0, 20, keys: key))
            #expect(abs(Double(hand.scale(width: g.sheet).perSecond / now.perSecond) - exp(0.24)) < 1e-6)
        }
        // Not off the sheet, where it zooms the canvas.
        #expect(!wheel(0, 3, keys: .command, fine: false, at: CGPoint(x: 400, y: 300)))
        // Looked at closer, two fingers sideways move it along with them, their coasting too.
        store.film.window = nil
        hand.zoom(by: 4, at: x, scale: hand.scale(width: g.sheet))
        let from = hand.scale(width: g.sheet)
        #expect(wheel(-20, 3, .began) && wheel(-20, 9, .changed) && wheel(0, 0, .ended))
        #expect(wheel(-10, 0, coasting: .began) && wheel(-10, 0, coasting: .ended))
        #expect(abs(hand.scale(width: g.sheet).x(1) - (from.x(1) - 60)) < 1e-6)
        // Fingers that set out up and down are the lines' until they are lifted, whatever they do after.
        let rest = hand.scale(width: g.sheet)
        #expect(!wheel(1, -8, .began) && !wheel(-40, -2, .changed) && !wheel(-40, 0, coasting: .changed))
        #expect(hand.scale(width: g.sheet) == rest)
        // Shift turns a wheel sideways: up, towards the film's start.
        #expect(wheel(0, 2, keys: .shift, fine: false))
        #expect(abs(hand.scale(width: g.sheet).x(1) - (rest.x(1) + 16)) < 1e-6)
        // A wheel that scrolls sideways by itself does the same.
        #expect(wheel(-2, 0, fine: false))
        #expect(abs(hand.scale(width: g.sheet).x(1) - rest.x(1)) < 1e-6)
    }

    @Test func whatThePointerIsOnIsFoundAgainOnceTheSheetRests() {
        let (rows, scale) = (rows, scale)
        hand.hot = hand.point(at(0.8, line: 1), rows: rows, scale: scale)
        #expect(hand.hot.key == FilmKeyRef(card, at: 0.8))
        // Looked at closer about another moment, the bead leaves the pointer.
        hand.zoom(by: 3, at: self.scale.x(0.2), scale: self.scale)
        #expect(hand.hot.key == nil && hand.hot.row == rows[1].id)
        hand.pointAgain(width: width)
        #expect(hand.hot.key == nil)
        // Moved along until another bead lies under it, that one is found.
        let x = hand.hot.x
        hand.scroll(by: x - self.scale.x(0.6), scale: self.scale)
        hand.pointAgain(width: width)
        #expect(hand.hot.key == FilmKeyRef(card, at: 0.6))
        // So a right click there offers that key's paces.
        #expect(hand.menu(rows: self.rows, scale: self.scale).filter { $0.kind == .item }.count == MotionEase.Kind.allCases.count + 1)
    }
}
