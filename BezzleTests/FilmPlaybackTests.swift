import Testing
import AppKit
@testable import Bezzle

/// The playhead of an artboard's film, in Animate: put somewhere, running as the film plays, and
/// stepping from key to key. The film is moved on with times made up here, as the screen's frames
/// would move it, so each test says exactly how much time has passed.
@MainActor
struct FilmPlaybackTests {
    /// On artboard A: a card that moves and fades, a badge that turns, and a label nothing moves.
    let bench = Bench(extra: [
        CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
        CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40)),
        CanvasTests.rect("Label", CGRect(x: 40, y: 200, width: 100, height: 20)),
    ])
    var store: DocumentStore { bench.store }

    private func id(_ name: String) -> UUID { bench.node(name)!.id }

    /// Animate, with the card moving over a second and a half: a film two seconds long that goes round.
    private func animate() {
        store.show(.animate)
        // The view's glide to the film's artboard is no part of what is tested here.
        store.glide.stop()
        store.viewport = Viewport(origin: .zero, zoom: 1)
        let card = id("Card")
        edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [60, 0], at: 1.5) }
        }
    }

    /// A change to the design made behind the scenes, as its own step.
    private func edit(_ change: (inout BezzleDocument) -> Void) {
        bench.step { store.edit("Add Key", change) }
    }

    private func film(_ change: @escaping (inout Film) -> Void) {
        bench.step { store.setFilm("Film", change) }
    }

    /// Moves the playing film on to `seconds` after it began playing, as a frame of the screen does.
    @discardableResult
    private func step(_ seconds: Double) -> Bool {
        store.filmStep((store.film.pass?.began ?? CACurrentMediaTime()) + seconds)
    }

    /// Whether the playhead shows where it rests, as it must whenever the film does not play.
    private var atRest: Bool {
        !store.film.playing && store.film.pass == nil && store.film.live == store.film.time && store.film.head == store.film.time
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    // MARK: Round and round

    @Test func aFilmThatGoesRoundRestsAtItsEndForABreathAndBeginsAgain() {
        animate()
        #expect(store.filmBoard?.filmLength == 2 && store.filmBoard?.film?.once != true)
        store.seek(0.25)
        store.playFilm(fromStart: true)
        #expect(store.film.playing && store.film.head == 0 && store.film.live == 0)
        let round = 2 + FilmDesk.breath
        // Three times round: on its way, at rest on its last moment for the breath, and on its way again.
        for turn in 0..<3 {
            let began = Double(turn) * round
            #expect(step(began + 0.5) && near(store.film.head, 0.5), "\(turn): \(store.film.head)")
            #expect(step(began + 1.95) && near(store.film.head, 1.95), "\(turn): \(store.film.head)")
            #expect(step(began + 2.05) && store.film.head == 2, "\(turn): \(store.film.head)")
            #expect(step(began + round - 0.05) && store.film.head == 2, "\(turn): \(store.film.head)")
            #expect(step(began + round + 0.05) && near(store.film.head, 0.05), "\(turn): \(store.film.head)")
            #expect(store.film.live == store.film.head && store.film.playing)
        }
        // All the while, what is posed is the moment the playhead rested at.
        #expect(store.film.time == 0.25 && store.filmTime == 0.25)
    }

    @Test func everyFrameOfARoundShowsAMomentOfTheFilm() {
        animate()
        store.playFilm(fromStart: true)
        var last = -1.0, rounds = 0
        for frame in 0..<600 {
            #expect(step(Double(frame) / 60))
            let head = store.film.head
            #expect(head >= 0 && head <= 2 && store.film.live == head, "frame \(frame): \(head)")
            // It only ever goes on, or begins again from the start.
            if head < last {
                rounds += 1
                #expect(head < 0.02 && last == 2, "frame \(frame): from \(last) to \(head)")
            }
            last = head
        }
        // Ten seconds of a film that takes 2.7 a round.
        #expect(rounds == 3)
    }

    @Test func playingFromTheMiddleGoesOnFromThere() {
        animate()
        store.seek(1.2)
        store.playFilm()
        #expect(store.film.playing && store.film.head == 1.2 && store.film.live == 1.2)
        #expect(step(0.3) && near(store.film.head, 1.5))
        // On to the end, the breath there, and round to the start.
        #expect(step(0.9) && store.film.head == 2)
        #expect(step(0.8 + FilmDesk.breath + 0.1) && near(store.film.head, 0.1))
        #expect(store.film.time == 1.2)
    }

    @Test func playingFromTheEndStartsOver() {
        animate()
        store.seek(2)
        #expect(store.filmTime == 2)
        store.playFilm()
        #expect(store.film.playing && store.film.pass?.from == 0 && store.film.head == 0 && store.film.live == 0)
        #expect(step(0.4) && near(store.film.head, 0.4))
        // And asked to play from the start, it does from anywhere.
        store.seek(1.1)
        store.playFilm(fromStart: true)
        #expect(store.film.pass?.from == 0 && store.film.head == 0)
    }

    @Test func aFrameSaidToBeBeforeTheFilmBeganShowsWhereItBegan() {
        animate()
        store.seek(0.5)
        store.playFilm()
        #expect(step(-0.2) && store.film.head == 0.5 && store.film.live == 0.5)
    }

    // MARK: Once

    @Test func aFilmThatPlaysOnceStopsOnItsLastMomentAndPlaysAgainFromTheStart() {
        animate()
        film { $0.once = true }
        store.playFilm(fromStart: true)
        #expect(step(1) && near(store.film.head, 1))
        #expect(step(1.99) && near(store.film.head, 1.99) && store.film.playing)
        // At its end it stops there, exactly, and the playhead rests there.
        #expect(!step(2.01))
        #expect(atRest && store.film.time == 2 && store.filmTime == 2)
        // More frames change nothing.
        #expect(!step(2.5) && !step(9))
        #expect(atRest && store.film.time == 2)
        // Played again, it starts over.
        store.playFilm()
        #expect(store.film.playing && store.film.pass?.from == 0 && store.film.head == 0)
        #expect(step(0.3) && near(store.film.head, 0.3))
        // From the middle it runs to the end and stops.
        store.seek(1.5)
        store.playFilm()
        #expect(step(0.4) && near(store.film.head, 1.9))
        #expect(!step(0.6))
        #expect(atRest && store.film.time == 2)
    }

    // MARK: A look at something just made

    @Test func aLookGoesThereRestsAMomentAndComesBack() {
        animate()
        store.seek(0.6)
        store.showFilm(from: 0.2, to: 1.2, back: 0.6)
        #expect(store.film.playing && store.film.head == 0.2 && store.film.live == 0.2 && store.film.time == 0.6)
        #expect(step(0.5) && near(store.film.head, 0.7))
        #expect(step(1) && near(store.film.head, 1.2))
        // There, for a moment's rest.
        #expect(step(1.2) && store.film.head == 1.2)
        #expect(step(1.39) && store.film.head == 1.2 && store.film.live == 1.2)
        // And back to where the playhead was.
        #expect(!step(1.41))
        #expect(atRest && store.film.time == 0.6)
        #expect(!step(2))
        #expect(atRest && store.film.time == 0.6)
    }

    @Test func aLookThatLeadsNowhereIsNotBegun() {
        animate()
        store.seek(0.6)
        store.showFilm(from: 1, to: 1, back: 0.3)
        #expect(atRest && store.film.time == 0.6)
        store.showFilm(from: 1.5, to: 0.5, back: 0.3)
        #expect(atRest && store.film.time == 0.6)
        // Back to a moment past the end is back to the end.
        store.showFilm(from: 0, to: 0.5, back: 7)
        #expect(!step(1))
        #expect(atRest && store.film.time == 2)
    }

    // MARK: Pausing

    @Test func pausingRestsThePlayheadWhereItShows() {
        animate()
        // On its way round.
        store.playFilm(fromStart: true)
        step(0.8)
        store.pauseFilm()
        #expect(atRest && store.film.time == 0.8)
        // Paused already, nothing moves.
        store.pauseFilm()
        #expect(atRest && store.film.time == 0.8)
        // In the breath at the end: on the last moment, from where playing starts over.
        store.playFilm()
        step(1.5)
        #expect(store.film.head == 2)
        store.pauseFilm()
        #expect(atRest && store.film.time == 2)
        store.playFilm()
        #expect(store.film.pass?.from == 0)
        // From the middle.
        store.seek(1.1)
        store.playFilm()
        step(0.25)
        store.pauseFilm()
        #expect(atRest && store.film.time == 1.35)
    }

    @Test func pausingAFilmThatPlaysOnceRestsItWhereItWas() {
        animate()
        film { $0.once = true }
        store.playFilm(fromStart: true)
        step(0.7)
        store.pauseFilm()
        #expect(atRest && store.film.time == 0.7)
        // And on from there.
        store.playFilm()
        #expect(store.film.pass?.from == 0.7)
        #expect(step(0.5) && near(store.film.head, 1.2))
    }

    @Test func pausingALookRestsThePlayheadWhereItWasToComeBackTo() {
        animate()
        store.seek(1)
        store.showFilm(from: 0, to: 1, back: 1)
        step(0.4)
        store.pauseFilm()
        #expect(atRest && store.film.time == 1)
        // And during its moment's rest likewise.
        store.showFilm(from: 0.5, to: 1.5, back: 0.25)
        step(1.2)
        store.pauseFilm()
        #expect(atRest && store.film.time == 0.25)
    }

    @Test func theSpaceBarsToggleStartsAndStops() {
        animate()
        store.seek(0.3)
        store.toggleFilm()
        #expect(store.film.playing && store.film.pass?.from == 0.3)
        step(0.5)
        store.toggleFilm()
        #expect(atRest && store.film.time == 0.8)
        store.toggleFilm()
        #expect(store.film.playing && store.film.pass?.from == 0.8)
    }

    @Test func playingChangesNothingInTheDesign() {
        animate()
        let before = store.doc
        let version = store.version
        store.playFilm(fromStart: true)
        step(0.5)
        store.pauseFilm()
        store.showFilm(from: 0, to: 1, back: 0.5)
        step(2)
        store.seek(1)
        store.stepToKey(forward: true)
        #expect(store.doc == before && store.version == version)
        // What Undo takes back is still the key set before it played.
        bench.undo.undo()
        #expect(bench.node("Card")!.motion == nil)
    }

    // MARK: Seeking

    @Test func seekingWhileItPlaysStopsTheFilmThere() {
        animate()
        store.playFilm(fromStart: true)
        step(0.5)
        store.seek(1.3)
        #expect(atRest && store.film.time == 1.3)
        // The frames that still come change nothing.
        #expect(!step(0.6) && !step(3))
        #expect(atRest && store.film.time == 1.3)
        // During a look too, which then does not come back.
        store.showFilm(from: 0, to: 1, back: 0.2)
        step(0.4)
        store.seek(0.9)
        #expect(!step(2))
        #expect(atRest && store.film.time == 0.9)
    }

    @Test func seekingPastEitherEndStaysWithinTheFilm() {
        animate()
        store.seek(-3)
        #expect(atRest && store.film.time == 0)
        store.seek(99)
        #expect(atRest && store.film.time == 2)
        store.seek(.infinity)
        #expect(atRest && store.film.time == 2)
        store.seek(-.infinity)
        #expect(atRest && store.film.time == 0)
        // What is no moment at all is the start.
        store.seek(1)
        store.seek(.nan)
        #expect(atRest && store.film.time == 0 && store.filmTime == 0)
        // Kept to the thousandth of a second.
        store.seek(0.33349)
        #expect(store.film.time == 0.333)
        store.seek(1.9996)
        #expect(store.film.time == 2)
    }

    @Test func withNoFilmOnTheDeskThereIsNothingToPlay() {
        animate()
        let a = bench.a.id
        store.seek(1)
        bench.step { store.setHidden(true, [a]) }
        #expect(store.filmBoard == nil && store.filmTime == 0)
        store.playFilm()
        #expect(!store.film.playing)
        store.toggleFilm()
        #expect(!store.film.playing)
        store.showFilm(from: 0, to: 1, back: 0)
        #expect(!store.film.playing)
        #expect(store.filmStops.isEmpty)
        store.stepToKey(forward: true)
        #expect(atRest && store.film.time == 0)
    }

    // MARK: A film that changes while it plays

    @Test func aKeyPastTheEndMakesTheFilmLongerWhileItPlays() {
        animate()
        store.playFilm(fromStart: true)
        #expect(step(1) && near(store.film.head, 1))
        let card = id("Card")
        edit { doc in doc.update(card) { $0.setKey(.move, [60, 40], at: 3.4) } }
        #expect(store.filmBoard?.filmLength == 3.5)
        // It goes on, now past where it used to end, and round at the new end.
        #expect(store.film.playing)
        #expect(step(2.5) && near(store.film.head, 2.5))
        #expect(step(3.6) && store.film.head == 3.5)
        #expect(step(3.5 + FilmDesk.breath + 0.1) && near(store.film.head, 0.1))
    }

    @Test func aFilmMadeShorterKeepsThePlayheadWithinIt() {
        animate()
        film { $0.length = 4 }
        // At rest past the new end: brought to the end.
        store.seek(3.5)
        film { $0.length = 2 }
        #expect(atRest && store.film.time == 2 && store.filmTime == 2)

        // Going round, shown past the new end: the next frame is within the film again.
        film { $0.length = 4 }
        store.seek(0)
        store.playFilm()
        #expect(step(3) && near(store.film.head, 3))
        film { $0.length = 2 }
        #expect(store.film.playing)
        #expect(step(3.02) && store.film.head <= 2 && store.film.live <= 2)
        store.pauseFilm()
        #expect(atRest && store.film.time <= 2)

        // Playing once, shown past the new end: it has ended, on the new last moment.
        film { $0.length = 4; $0.once = true }
        store.seek(0)
        store.playFilm()
        #expect(step(3) && near(store.film.head, 3))
        film { $0.length = 2 }
        #expect(!step(3.02))
        #expect(atRest && store.film.time == 2)
    }

    @Test(.disabled("Outside this area: the playhead is not brought back when the film gets shorter by losing its last key, by Undo, or by the AI server; only DocumentStore.setFilm seeks again. FilmTimeline.swift:457 and :497 draw film.live as it is, past the end flag, while the canvas poses the film's last moment."))
    func aFilmThatLosesItsLastKeyBringsThePlayheadBackWithinIt() {
        animate()
        let card = id("Card")
        edit { doc in doc.update(card) { $0.setKey(.move, [60, 40], at: 3.4) } }
        store.seek(3.4)
        edit { doc in doc.update(card) { $0.removeKeys(at: 3.4, of: [.move]) } }
        #expect(store.filmBoard?.filmLength == 2 && store.filmTime == 2)
        #expect(store.film.live <= 2 && store.film.time <= 2)
    }

    @Test func theArtboardGoingAwayWhileItPlaysStopsTheFilm() {
        animate()
        let a = bench.a.id
        store.seek(0.3)
        store.playFilm()
        #expect(step(0.6) && near(store.film.head, 0.9))
        // Taken out of the design behind the scenes, as someone sharing the design might.
        bench.step { store.edit("Delete") { doc in doc.nodes.removeAll { $0.id == a } } }
        #expect(store.filmBoard == nil)
        #expect(!step(0.7))
        // Stopped, and the playhead shows where it rests.
        #expect(atRest && store.film.time == 0.3)
        #expect(store.filmTime == 0)
        // Back again, it is posed where the playhead rested.
        bench.undo.undo()
        #expect(store.filmBoard?.id == a && atRest && store.filmTime == 0.3)

        // Hidden, likewise.
        store.playFilm()
        step(0.2)
        bench.step { store.setHidden(true, [a]) }
        #expect(!step(0.3))
        #expect(atRest && store.film.time == 0.3)
    }

    // MARK: Head, live and time

    @Test func whereverThePlayheadRestsItShowsThere() {
        animate()
        film { $0.length = 3 }
        let checks: [(String, () -> Void)] = [
            ("sought", { store.seek(1.25) }),
            ("played and paused", { store.playFilm(); step(0.4); store.pauseFilm() }),
            ("played and sought", { store.playFilm(); step(0.4); store.seek(2.2) }),
            ("played to the breath and paused", { store.playFilm(fromStart: true); step(3.3); store.pauseFilm() }),
            ("a look run to its end", { store.showFilm(from: 0, to: 1, back: 0.5); step(0.5); step(1.5) }),
            ("a look paused", { store.showFilm(from: 0, to: 1, back: 0.75); step(0.5); store.pauseFilm() }),
            ("toggled twice", { store.toggleFilm(); step(0.2); store.toggleFilm() }),
            ("stepped to a key while playing", { store.playFilm(fromStart: true); step(0.4); store.stepToKey(forward: true) }),
            ("the camera picked while playing, then paused", { store.playFilm(fromStart: true); step(0.4); store.pickCamera(); step(0.6); store.pauseFilm() }),
            ("the other artboard picked while playing", { store.playFilm(fromStart: true); step(0.4); store.selection = [bench.b.id] }),
            ("back on the first artboard", { store.selection = [bench.a.id] }),
            ("the mode left while playing", { store.playFilm(fromStart: true); step(0.4); store.show(.design) }),
            ("the mode come back to", { store.show(.animate); store.glide.stop() }),
            ("played once to its end", { film { $0.once = true }; store.playFilm(fromStart: true); step(1); step(3.5) }),
            ("made shorter than the playhead", { film { $0.length = 1 } }),
        ]
        for (what, change) in checks {
            change()
            #expect(atRest, "\(what): time \(store.film.time), live \(store.film.live), head \(store.film.head), playing \(store.film.playing)")
            #expect(store.film.time == store.filmTime, "\(what): \(store.film.time) for \(store.filmTime)")
        }
    }

    // MARK: Stops

    /// The card's move at 0 and 1.5 already; its fade at half a second, the badge's turn at a
    /// quarter and at one and three quarters, and the camera's zoom at the start and at two.
    private func keyed() {
        animate()
        let card = id("Card"), badge = id("Badge"), a = bench.a.id
        edit { doc in
            doc.update(card) { $0.setKey(.fade, [0.5], at: 0.5) }
            doc.update(badge) { $0.setKey(.turn, [0], at: 0.25); $0.setKey(.turn, [90], at: 1.75) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [1.5], at: 2) }
        }
    }

    @Test func thePlayheadStopsAtTheKeysOfWhatIsPicked() {
        keyed()
        // Nothing picked: every key in the film.
        #expect(store.filmStops == [0, 0.25, 0.5, 1.5, 1.75, 2])
        store.selection = [id("Card")]
        #expect(store.filmStops == [0, 0.5, 1.5])
        store.selection = [id("Card"), id("Badge")]
        #expect(store.filmStops == [0, 0.25, 0.5, 1.5, 1.75])
        store.selection = [id("Label")]
        #expect(store.filmStops.isEmpty)
        // The artboard itself picked is nothing picked.
        store.selection = [bench.a.id]
        #expect(store.filmStops == [0, 0.25, 0.5, 1.5, 1.75, 2])
        store.pickCamera()
        #expect(store.filmStops == [0, 2])
    }

    @Test func aLockedLayerPickedStandsForNothingPicked() {
        keyed()
        let badge = id("Badge")
        bench.step { store.setLocked(true, [badge]) }
        store.selection = [badge]
        // It cannot be posed, so the playhead steps through the whole film.
        #expect(store.posedLayers.isEmpty)
        #expect(store.filmStops == [0, 0.25, 0.5, 1.5, 1.75, 2])
    }

    @Test func aHiddenLayersKeysAreNoStopsAsTheTimelineHasNone() {
        keyed()
        let badge = id("Badge")
        bench.step { store.setHidden(true, [badge]) }
        store.selection = []
        let rows = FilmRow.rows(of: store.filmBoard!, open: [])
        #expect(!rows.contains { $0.layer == badge })
        #expect(store.filmStops == [0, 0.5, 1.5, 2])
        // Picked in the layers list, it is stepped through all the same.
        store.selection = [badge]
        #expect(store.filmStops == [0.25, 1.75])
    }

    @Test func keysOfLayersInGroupsAreStopsToo() {
        animate()
        var inner = CanvasTests.rect("Inner", CGRect(x: 0, y: 0, width: 30, height: 30))
        inner.setKey(.fade, [0], at: 0.4)
        inner.setKey(.fade, [1], at: 0.9)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 200, y: 20, width: 60, height: 60))
        group.children = [inner]
        bench.step { store.add(group, onto: bench.a.id) }
        store.selection = []
        #expect(store.filmStops == [0, 0.4, 0.9, 1.5])
        store.selection = [id("Inner")]
        #expect(store.filmStops == [0.4, 0.9])
    }

    @Test func steppingGoesFromKeyToKeyAndToTheEnds() {
        keyed()
        film { $0.length = 3 }
        store.seek(0.6)
        var seen: [Double] = []
        for _ in 0..<6 {
            store.stepToKey(forward: true)
            seen.append(store.filmTime)
            #expect(atRest)
        }
        // Past the last key is the film's end, where it stays.
        #expect(seen == [1.5, 1.75, 2, 3, 3, 3])
        seen = []
        for _ in 0..<8 {
            store.stepToKey(forward: false)
            seen.append(store.filmTime)
        }
        #expect(seen == [2, 1.75, 1.5, 0.5, 0.25, 0, 0, 0])
        // With something picked that has no keys, straight to the ends.
        store.selection = [id("Label")]
        store.seek(1)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 3)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 0)
        // And with the camera picked, through its keys alone.
        store.pickCamera()
        store.stepToKey(forward: true)
        #expect(store.filmTime == 2)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 3)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 2)
    }

    @Test func aKeyPastTheFilmsEndIsSteppedToAsTheEnd() {
        keyed()
        film { $0.length = 1.6 }
        store.seek(1.5)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 1.6)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 1.6)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 1.5)
    }

    @Test func keysAHairApartAreOneStopAndThoseAFrameApartAreTwo() {
        animate()
        let card = id("Card"), badge = id("Badge")
        edit { doc in
            doc.update(card) { $0.setKey(.fade, [0.5], at: 1) }
            // Three thousandths after the card's: the same moment. Eight after: another.
            doc.update(badge) { $0.setKey(.turn, [10], at: 1.003); $0.setKey(.turn, [20], at: 1.008) }
        }
        store.selection = []
        #expect(store.filmStops == [0, 1, 1.008, 1.5])
        store.seek(0.5)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 1)
        // Both keys of that moment are at the playhead.
        #expect(bench.node("Card")![track: .fade]!.index(at: store.filmTime) != nil)
        #expect(bench.node("Badge")![track: .turn]!.index(at: store.filmTime) == 0)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 1.008)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 1.5)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 1.008)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 1)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 0)
        // Each layer alone has its own.
        store.selection = [badge]
        #expect(store.filmStops == [1.003, 1.008])
    }

    @Test func steppingWhileItPlaysStopsAndStepsFromWhereItShows() {
        keyed()
        store.seek(0.1)
        store.playFilm()
        step(0.5)
        #expect(near(store.film.head, 0.6))
        store.stepToKey(forward: true)
        #expect(atRest && store.film.time == 1.5)
        store.seek(0.1)
        store.playFilm()
        step(0.5)
        store.stepToKey(forward: false)
        #expect(atRest && store.film.time == 0.5)
        // During a look, from where the playhead was to come back to.
        store.showFilm(from: 0, to: 1, back: 1.6)
        step(0.3)
        store.stepToKey(forward: true)
        #expect(atRest && store.film.time == 1.75)
    }

    // MARK: In the middle of playing

    @Test func pickingAnotherArtboardWhileItPlaysTurnsTheDeskToItsFilmAtRest() {
        animate()
        store.playFilm(fromStart: true)
        step(0.5)
        store.selection = [bench.b.id]
        #expect(store.film.board == bench.b.id)
        #expect(atRest && store.film.time == 0)
        #expect(!step(0.6))
        // And back: the first film from its start, not from where it was left playing.
        store.selection = [id("Card")]
        #expect(store.film.board == bench.a.id && atRest && store.film.time == 0)
    }

    @Test func pickingALayerOrTheCameraWhileItPlaysLeavesItPlaying() {
        keyed()
        store.seek(0.2)
        store.playFilm()
        step(0.3)
        store.selection = [id("Badge")]
        #expect(store.film.playing && store.film.board == bench.a.id && !store.film.camera)
        #expect(step(0.5) && near(store.film.head, 0.7))
        #expect(store.filmStops == [0.25, 1.75])
        store.pickCamera()
        #expect(store.film.playing && store.film.camera && store.selection.isEmpty)
        #expect(step(0.8) && near(store.film.head, 1))
        #expect(store.filmStops == [0, 2])
        // Nothing picked again, still playing; paused, it rests where it shows.
        store.film.camera = false
        store.selection = []
        #expect(step(1.1) && near(store.film.head, 1.3))
        store.pauseFilm()
        #expect(atRest && store.film.time == 1.3)
    }

    @Test func leavingTheModeWhileItPlaysStopsTheFilmWhereItShows() {
        keyed()
        for mode in [CanvasMode.design, .prototype, .inspect] {
            store.show(.animate)
            store.glide.stop()
            store.seek(0)
            store.pickCamera()
            store.playFilm()
            step(0.5)
            store.show(mode)
            #expect(store.canvasMode == mode, "\(mode)")
            #expect(atRest && store.film.time == 0.5, "\(mode): \(store.film.time)")
            #expect(!store.film.camera && store.film.keys.isEmpty, "\(mode)")
            #expect(!step(0.9))
            // Come back to, the film is on the desk as it was left.
            store.show(.animate)
            store.glide.stop()
            #expect(store.film.board == bench.a.id && atRest && store.filmTime == 0.5, "\(mode)")
        }
    }
}
