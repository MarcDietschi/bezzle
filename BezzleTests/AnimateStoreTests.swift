import Testing
import AppKit
@testable import Bezzle

/// What Animate does to a film, asked of the store the way the panel, the timeline and the menus
/// ask it: every pose, key, pace, move and setting, with one layer, several, locked and nested
/// ones, the camera, and nothing at all. `AnimateTests` has the mode as it is used by hand.
@MainActor
struct AnimateStoreTests {
    /// On artboard A (400 by 300): a card top left, a badge lower right, and a row holding an
    /// icon and a label. On B: one layer.
    let bench: Bench

    init() {
        var row = Node(kind: .group, name: "Row", frame: CGRect(x: 40, y: 240, width: 200, height: 40))
        row.children = [
            CanvasTests.rect("Icon", CGRect(x: 0, y: 0, width: 40, height: 40)),
            CanvasTests.rect("Label", CGRect(x: 60, y: 10, width: 140, height: 20)),
        ]
        bench = Bench(extra: [
            CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
            CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40)),
            row,
        ])
        // Layers are added through `nodes`, which has the design find them again by their ids.
        bench.step { bench.store.edit("Add") { $0.nodes[1].children = [CanvasTests.rect("Far", CGRect(x: 20, y: 20, width: 50, height: 50))] } }
        bench.undo.removeAllActions()
    }

    var store: DocumentStore { bench.store }

    private func id(_ name: String) -> UUID { bench.node(name)!.id }

    private func animate() {
        store.show(.animate)
        store.glide.stop()
        store.viewport = Viewport(origin: .zero, zoom: 1)
    }

    private func edit(_ change: (inout BezzleDocument) -> Void) {
        bench.step { store.edit("Add Key", change) }
    }

    private func keys(_ name: String, _ property: MotionProperty) -> [MotionKey] {
        bench.node(name)?[track: property]?.keys ?? []
    }

    private func times(_ name: String, _ property: MotionProperty) -> [Double] { keys(name, property).map(\.t) }

    private func camera(_ property: MotionProperty) -> [MotionKey] { store.filmBoard?[track: property]?.keys ?? [] }

    /// What the Edit menu would undo next.
    private var undoing: String { bench.undo.undoActionName }

    // MARK: The desk

    @Test func withNoArtboardThereIsNoFilmAndNothingBreaks() {
        bench.step { store.edit("Delete") { $0.nodes = [] } }
        animate()
        #expect(store.filmBoard == nil && store.film.board == nil)
        #expect(store.filmTime == 0 && store.posedLayers.isEmpty && store.filmStops.isEmpty)
        let before = store.doc
        bench.step {
            store.seek(1); store.playFilm(); store.toggleFilm(); store.stepToKey(forward: true); store.stepToKey(forward: false)
            store.pickCamera(); store.poseCamera(.cameraZoom, [2]); store.poseCamera(.cameraZoom, number: 0, to: 2)
            store.restCamera(); store.flyCamera(to: [UUID()])
            store.pose(.move, of: [UUID()]) { _ in [10, 10] }; store.pose(.move, number: 0, to: 10, of: [UUID()])
            store.toggleKey(.move); store.toggleKey(.cameraRoll); store.holdHere(); store.removeFilmKeys(); store.setEase(.linear)
            store.applyMove(.rise); store.clearFilmMotion(); store.setFilm("Film Length") { $0.length = 3 }
        }
        #expect(store.doc == before && !store.film.playing && !store.film.camera)
        #expect(store.keyState(.move) == .none && store.holdState == .none && store.sharedEase == nil && !store.hasKeysToRemove)
        #expect(store.sharedValue(.move, 0, of: [UUID()]) == nil && store.pickedKeys.isEmpty)
        // An artboard drawn now has its film on the desk at once.
        bench.step { store.edit("Artboard") { $0.nodes = [Node(kind: .artboard, name: "New", frame: CGRect(x: 0, y: 0, width: 200, height: 200))] } }
        #expect(store.filmBoard?.name == "New")
    }

    @Test func theDeskTurnsToAnotherArtboardWhenItsOwnGoesAway() {
        animate()
        let a = bench.a.id, b = bench.b.id
        #expect(store.film.board == a)
        store.seek(1.5)
        store.pickCamera()
        bench.step { store.edit("Delete") { $0.nodes.removeAll { $0.id == a } } }
        #expect(store.film.board == b && store.filmBoard?.id == b)
        #expect(store.filmTime == 0 && !store.film.camera)
        // Hidden, an artboard has no film to work on either.
        bench.step { store.edit("Hide") { $0.update(b) { $0.hidden = true } } }
        #expect(store.filmBoard == nil && store.film.board == nil)
        bench.undo.undo()
        #expect(store.film.board == b)
        // The first one back again, the desk stays where it is until that one is picked.
        bench.undo.undo()
        #expect(store.film.board == b)
        store.selection = [id("Card")]
        #expect(store.film.board == a)
    }

    @Test func aHiddenArtboardPickedDoesNotTakeTheDesk() {
        animate()
        let a = bench.a.id, b = bench.b.id
        bench.step { store.edit("Hide") { $0.update(b) { $0.hidden = true } } }
        store.selection = [b]
        #expect(store.film.board == a)
        store.selection = [id("Far")]
        #expect(store.film.board == a)
    }

    /// Turned to, a film's artboard comes to lie whole above the timeline, however many of its
    /// lines the card shows, and moves only the way it has to: what lies beside it stays in sight.
    @Test func theFilmsArtboardComesToLieClearOfTheTimelineMovingOnlyAsItMust() {
        let canvas = CGSize(width: 1000, height: 700)
        // A film of so many layers that move, 600 points right of another artboard. Without a
        // canvas, the view is at once where its glide ends.
        func turned(layers: Int, from origin: CGPoint) -> (store: DocumentStore, film: Node, foot: CGFloat) {
            var film = Node(kind: .artboard, name: "Film", frame: CGRect(x: 600, y: 0, width: 300, height: 400))
            film.children = (0..<layers).map { i in
                var layer = CanvasTests.rect("Layer \(i)", CGRect(x: 10, y: 10 + CGFloat(i) * 20, width: 40, height: 10))
                layer.setKey(.move, [10, 0], at: 0)
                layer.setKey(.move, [0, 0], at: 1)
                return layer
            }
            var doc = BezzleDocument()
            doc.nodes = [film, Node(kind: .artboard, name: "Beside", frame: CGRect(x: 0, y: 0, width: 500, height: 400))]
            let store = DocumentStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle"), document: doc)
            store.canvasSize = canvas
            store.viewport = Viewport(origin: origin, zoom: 1)
            store.selection = [film.id]
            store.show(.animate)
            return (store, film, FilmTimeline.foot(lines: FilmRow.rows(of: film, open: []).count))
        }
        // With few lines the card is low, and the artboard is clear of it where it lies.
        let start = CGPoint(x: -50, y: -100)
        var (store, film, foot) = turned(layers: 2, from: start)
        #expect(foot == FilmTimeline.foot(lines: 4) && store.viewport == Viewport(origin: start, zoom: 1))
        // With many, the card reaches higher and would cover the artboard's foot: the view moves
        // up, drawing back as far as it must, and stays where it is from side to side.
        (store, film, foot) = turned(layers: 7, from: start)
        #expect(foot == FilmTimeline.foot(lines: 4) + 3 * FilmTimeline.rowHeight)
        var seen = store.viewport.toView(film.frame)
        #expect(seen.minY >= 12 && seen.maxY <= canvas.height - foot - 12, "\(seen)")
        #expect(abs(seen.midY - (canvas.height - foot) / 2) < 0.5 && store.viewport.zoom < 1 && store.viewport.zoom > 0.85)
        // What was in the middle from side to side still is, and the artboard beside it shows.
        #expect(abs(store.viewport.toCanvas(CGPoint(x: canvas.width / 2, y: 0)).x - (start.x + canvas.width / 2)) < 0.01)
        #expect(store.viewport.toView(store.doc.nodes[1].frame).minX > 0)
        // Out of sight at the side, it comes to the middle both ways.
        (store, film, foot) = turned(layers: 7, from: CGPoint(x: -600, y: -100))
        seen = store.viewport.toView(film.frame)
        #expect(abs(seen.midX - canvas.width / 2) < 0.5 && abs(seen.midY - (canvas.height - foot) / 2) < 0.5, "\(seen)")
    }

    @Test func leavingAnimateLetsGoOfEverythingInHand() {
        animate()
        bench.step { store.applyMove(.fade) }
        #expect(store.film.playing)
        store.pickCamera()
        store.film.keys = [FilmKeyRef(id("Card"), at: 0)]
        store.show(.design)
        #expect(!store.film.playing && !store.film.camera && store.film.keys.isEmpty)
        #expect(!store.animating && !store.prototyping)
        // The film itself is the design's, and is still there.
        #expect(bench.a.hasFilm)
        store.show(.animate)
        #expect(store.film.board == bench.a.id)
        store.playFilm()
        store.show(.prototype)
        #expect(!store.animating && store.prototyping && !store.film.playing)
        store.show(.animate)
        store.show(.inspect)
        #expect(!store.animating && store.inspecting)
    }

    @Test func aFilmMadeShorterByAnUndoBringsThePlayheadBack() {
        animate()
        bench.step { store.setFilm("Film Length") { $0.length = 3.5 } }
        store.seek(3)
        #expect(store.filmTime == 3)
        bench.undo.undo()
        #expect(store.filmBoard?.filmLength == 2)
        #expect(store.filmTime == 2 && store.film.live == 2 && store.film.time == 2)
        // And one that follows its keys, when its last key goes.
        store.selection = [id("Card")]
        edit { $0.update(id("Card")) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 2.8) } }
        #expect(store.filmBoard?.filmLength == 3)
        store.seek(2.8)
        bench.step { store.removeFilmKeys() }
        #expect(store.filmBoard?.filmLength == 2 && store.filmTime == 2 && store.film.live == 2)
    }

    @Test func thePlayheadStepsThroughTheKeysOfWhatIsPicked() {
        animate()
        edit { doc in
            doc.update(id("Card")) { $0.setKey(.move, [0, 0], at: 0.2); $0.setKey(.move, [30, 0], at: 0.8) }
            doc.update(id("Label")) { $0.setKey(.fade, [0], at: 0.5); $0.setKey(.fade, [1], at: 1.5) }
            doc.update(bench.a.id) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) }
        }
        // Nothing picked: every key in the film, the camera's and those of layers inside others.
        #expect(store.filmStops == [0, 0.2, 0.5, 0.8, 1, 1.5])
        store.stepToKey(forward: true)
        #expect(store.filmTime == 0.2)
        store.stepToKey(forward: true)
        #expect(store.filmTime == 0.5)
        store.selection = [id("Card")]
        #expect(store.filmStops == [0.2, 0.8])
        store.stepToKey(forward: true)
        #expect(store.filmTime == 0.8)
        // Past the last, to the film's end; before the first, to its start.
        store.stepToKey(forward: true)
        #expect(store.filmTime == 2)
        store.stepToKey(forward: false)
        store.stepToKey(forward: false)
        store.stepToKey(forward: false)
        #expect(store.filmTime == 0)
        store.pickCamera()
        #expect(store.filmStops == [0, 1])
    }

    // MARK: Posing

    @Test func aPoseGoesToWhatIsPickedOnTheFilmsArtboardAndNeverToWhatIsLocked() {
        animate()
        edit { $0.update(id("Badge")) { $0.locked = true } }
        store.selection = [id("Card"), id("Badge"), bench.a.id, id("Far"), id("Label")]
        #expect(store.film.board == bench.a.id)
        #expect(store.posedLayers == [id("Card"), id("Label")])
        store.seek(1)
        bench.step { store.pose(.move, of: store.posedLayers) { n in [Double(n.frame.width), 0] } }
        #expect(keys("Card", .move).last?.v == [120, 0] && keys("Label", .move).last?.v == [140, 0])
        #expect(bench.node("Badge")?.motion == nil && bench.node("Far")?.motion == nil && !bench.a.hasCamera)
        // Handed a locked layer all the same, it leaves it alone.
        bench.step { store.pose(.fade, of: [id("Card"), id("Badge")]) { _ in [0.5] } }
        #expect(keys("Badge", .fade).isEmpty && keys("Card", .fade).count == 2)
        // Each is one step.
        bench.undo.undo()
        #expect(keys("Card", .fade).isEmpty && keys("Card", .move).count == 2)
    }

    @Test func aPoseThatChangesNothingMakesNothing() {
        animate()
        let card = id("Card")
        store.selection = [card]
        store.seek(1)
        let before = store.doc
        bench.step {
            store.pose(.move, of: [card]) { _ in [0, 0] }
            store.pose(.scale, number: 0, to: 1, of: [card])
            // More than wholly there is wholly there: as designed.
            store.pose(.fade, number: 0, to: 4, of: [card])
            // No number of that place, and no number at all.
            store.pose(.move, number: 2, to: 30, of: [card])
            store.pose(.move, number: 0, to: .nan, of: [card])
            store.pose(.turn, number: 0, to: .infinity, of: [card])
            // The camera's are not a layer's, nor a layer's the camera's.
            store.pose(.cameraZoom, of: [card]) { _ in [3] }
            store.poseCamera(.move, [10, 10])
            store.poseCamera(.cameraZoom, number: 0, to: .infinity)
            store.poseCamera(.cameraMove, number: 2, to: 3)
        }
        #expect(store.doc == before)
    }

    @Test func aFirstPoseAtTheStartFliesHomeAndALaterPoseTakesItsPlace() {
        animate()
        let card = id("Card")
        store.selection = [card]
        bench.step { store.pose(.fade, number: 0, to: 0, of: [card]) }
        #expect(times("Card", .fade) == [0, 0.5])
        #expect(keys("Card", .fade).map(\.given) == [nil, true] && keys("Card", .fade).last?.v == [1])
        store.seek(1)
        bench.step { store.pose(.fade, number: 0, to: 0.5, of: [card]) }
        #expect(times("Card", .fade) == [0, 1] && keys("Card", .fade).map(\.v) == [[0], [0.5]])
        store.seek(0.4)
        bench.step { store.pose(.fade, number: 0, to: 0.2, of: [card]) }
        #expect(times("Card", .fade) == [0, 0.4, 1])
        // On a key that is there, only what it holds changes.
        bench.step { store.pose(.fade, number: 0, to: 0.3, of: [card]) }
        #expect(keys("Card", .fade).map(\.v) == [[0], [0.3], [0.5]])
    }

    @Test func aGivenKeyPosedByHandIsNoLongerGivenWay() {
        animate()
        let card = id("Card")
        store.selection = [card]
        bench.step { store.pose(.turn, number: 0, to: 45, of: [card]) }
        store.seek(0.5)
        // Its flight home is taken in hand: it ends turned a little, and stays so.
        bench.step { store.pose(.turn, number: 0, to: 10, of: [card]) }
        #expect(keys("Card", .turn).map(\.given) == [nil, nil])
        store.seek(1)
        bench.step { store.pose(.turn, number: 0, to: 0, of: [card]) }
        #expect(times("Card", .turn) == [0, 0.5, 1])
    }

    @Test func whatIsPosedKeepsWithinWhatShows() {
        animate()
        let card = id("Card")
        store.selection = [card]
        store.seek(1)
        bench.step {
            store.pose(.fade, number: 0, to: -2, of: [card])
            store.pose(.scale, number: 0, to: 0, of: [card])
            store.pose(.blur, number: 0, to: 999, of: [card])
            store.pose(.tilt, number: 0, to: 720, of: [card])
            store.pose(.lift, number: 0, to: -1e9, of: [card])
        }
        #expect(keys("Card", .fade).last?.v == [0])
        #expect(keys("Card", .scale).last?.v == [0.001, 0.001])
        #expect(keys("Card", .blur).last?.v == [200])
        #expect(keys("Card", .tilt).last?.v == [360])
        #expect(keys("Card", .lift).last?.v == [-4000])
        store.pickCamera()
        bench.step {
            store.poseCamera(.cameraZoom, number: 0, to: 100)
            store.poseCamera(.cameraTilt, number: 0, to: -200)
            store.poseCamera(.cameraSwing, number: 0, to: 200)
        }
        let seen = store.filmBoard!.camera(at: 1)
        #expect(seen.zoom == 16 && seen.tilt == -80 && seen.swing == 80)
        // Shrunk to nothing and grown again, a layer has not lost its shape.
        store.selection = [card]
        bench.step { store.pose(.scale, number: 0, to: 2, of: [card]) }
        let grown = keys("Card", .scale).last!.v
        #expect(grown[0] == 2 && abs(grown[1] - 2) < 1e-9)
    }

    @Test func aScalesWidthTakesItsHeightAlongAndItsHeightGoesAlone() {
        animate()
        let card = id("Card")
        store.selection = [card]
        store.seek(1)
        bench.step { store.pose(.scale, number: 0, to: 2, of: [card]) }
        #expect(keys("Card", .scale).last?.v == [2, 2])
        bench.step { store.pose(.scale, number: 1, to: 3, of: [card]) }
        #expect(keys("Card", .scale).last?.v == [2, 3])
        bench.step { store.pose(.scale, number: 0, to: 1, of: [card]) }
        #expect(keys("Card", .scale).last?.v == [1, 1.5])
        #expect(store.sharedValue(.scale, 1, of: [card]) == 1.5)
    }

    @Test func thePanelShowsANumberOnlyWhereTheLayersShareIt() {
        animate()
        let card = id("Card"), badge = id("Badge")
        store.selection = [card, badge]
        #expect(store.sharedValue(.move, 0, of: [card, badge]) == 0 && store.sharedValue(.fade, 0, of: [card, badge]) == 1)
        store.seek(1)
        bench.step { store.pose(.move, of: [card, badge]) { _ in [20, 5] } }
        #expect(store.sharedValue(.move, 0, of: [card, badge]) == 20)
        // One number set leaves the other as each layer has it.
        bench.step { store.pose(.move, number: 1, to: 9, of: [badge]) }
        #expect(keys("Badge", .move).last?.v == [20, 9])
        #expect(store.sharedValue(.move, 1, of: [card, badge]) == nil)
        #expect(store.sharedValue(.move, 0, of: [card, badge]) == 20)
        #expect(store.sharedValue(.move, 2, of: [card]) == nil && store.sharedValue(.fade, 0, of: []) == nil)
        #expect(store.sharedValue(.move, 0, of: [id("Far")]) == nil)
        // Between two keys it is what the layer is on its way through, and set there it is a key.
        store.seek(0.5)
        let onTheWay = store.sharedValue(.move, 0, of: [card])!
        #expect(onTheWay > 0 && onTheWay < 20)
        bench.step { store.pose(.move, number: 1, to: 50, of: [card]) }
        let made = keys("Card", .move)
        #expect(made.map(\.t) == [0, 0.5, 1])
        #expect(abs(made[1].v[0] - onTheWay) < 1e-9 && made[1].v[1] == 50)
    }

    // MARK: The camera

    @Test func theCamerasFirstKeyAtTheStartFliesOutOverTheWholeFilm() {
        animate()
        store.pickCamera()
        bench.step { store.poseCamera(.cameraZoom, [2]) }
        #expect(camera(.cameraZoom).map(\.t) == [0, 2])
        #expect(camera(.cameraZoom).map(\.v) == [[2], [1]] && camera(.cameraZoom).last?.given == true)
        bench.undo.undo()
        // In a film set longer, over that.
        bench.step { store.setFilm("Film Length") { $0.length = 3.5 } }
        bench.step { store.poseCamera(.cameraRoll, [20]) }
        #expect(camera(.cameraRoll).map(\.t) == [0, 3.5])
    }

    @Test func oneNumberOfTheCameraSetLeavesTheOther() {
        animate()
        store.pickCamera()
        store.seek(1)
        bench.step { store.poseCamera(.cameraMove, number: 0, to: 40) }
        bench.step { store.poseCamera(.cameraMove, number: 1, to: -10) }
        let seen = store.filmBoard!.camera(at: 1)
        #expect(seen.x == 40 && seen.y == -10)
        #expect(camera(.cameraMove).map(\.t) == [0, 1])
        // The camera's keys are the artboard's, and no layer's.
        #expect(bench.a.children.allSatisfy { $0.motion == nil })
        #expect(store.keyState(.cameraMove) == .here && store.keyState(.cameraZoom) == .none)
    }

    @Test func theCamerasPadTurnsTheSceneFromWhereTheDragBeganAndCatchesStraightOn() {
        animate()
        store.pickCamera()
        store.seek(1)
        let from = store.filmBoard!.camera(at: 1)
        bench.step {
            store.beginGesture()
            // Down tips it back, left swings it round: six tenths of a degree to the point.
            store.turnScene(from: from, by: CGSize(width: -50, height: 40), stepped: false)
            #expect(store.filmBoard!.camera(at: 1).tilt == 24 && store.filmBoard!.camera(at: 1).swing == 30)
            // Measured from where the drag began, not from the step before.
            store.turnScene(from: from, by: CGSize(width: -3, height: 60), stepped: false)
            #expect(store.filmBoard!.camera(at: 1).tilt == 36 && store.filmBoard!.camera(at: 1).swing == 0)
            // With Shift, by fifteen degrees.
            store.turnScene(from: from, by: CGSize(width: -40, height: 60), stepped: true)
            #expect(store.filmBoard!.camera(at: 1).tilt == 30 && store.filmBoard!.camera(at: 1).swing == 30)
            // No further than the scene still shows.
            store.turnScene(from: from, by: CGSize(width: 900, height: 900), stepped: false)
            #expect(store.filmBoard!.camera(at: 1).tilt == 80 && store.filmBoard!.camera(at: 1).swing == -80)
            store.endGesture("Turn the Scene")
        }
        #expect(undoing == "Turn the Scene")
        // Two clicks on the pad look straight down again, the zoom left as it is.
        bench.step { store.poseCamera(.cameraZoom, [2]) }
        bench.step { store.straightenScene() }
        let seen = store.filmBoard!.camera(at: 1)
        #expect(seen.tilt == 0 && seen.swing == 0 && seen.zoom == 2 && undoing == "Look Straight Down")
        bench.undo.undo(); bench.undo.undo(); bench.undo.undo()
        #expect(!store.filmBoard!.hasCamera)
        // Straight already, two clicks are nothing.
        let before = store.doc
        bench.step { store.straightenScene() }
        #expect(store.doc == before)
    }

    @Test func seeingTheWholeArtboardWithoutACameraIsNothing() {
        animate()
        store.pickCamera()
        let before = store.doc
        bench.step { store.restCamera() }
        #expect(store.doc == before)
        // With one, it is one step that sets every number it has to rest.
        store.seek(1)
        bench.step { store.poseCamera(.cameraZoom, [3]); store.poseCamera(.cameraTilt, [40]) }
        store.seek(2)
        bench.step { store.restCamera() }
        #expect(store.filmBoard!.camera(at: 2).isRest && !store.filmBoard!.camera(at: 1).isRest)
        #expect(undoing == "See the Whole Artboard")
        bench.undo.undo()
        #expect(camera(.cameraZoom).map(\.t) == [0, 1])
    }

    @Test func theCameraAtTheStartLooksThereFromTheFirstFrameAndNothingPlays() {
        animate()
        store.selection = [id("Badge")]
        bench.step { store.flyCamera(to: store.posedLayers) }
        #expect(!store.film.playing)
        #expect(store.filmBoard!.camera(at: 0).x == 70 && store.filmBoard!.camera(at: 0).zoom > 1.5)
        #expect(camera(.cameraMove).map(\.t) == [0, 2])
        #expect(undoing == "Fly the Camera Here")
    }

    @Test func theCameraFliesToSeveralLayersAsOneAndFromItsLastKey() {
        animate()
        store.selection = [id("Card"), id("Badge")]
        store.seek(1)
        bench.step { store.flyCamera(to: store.posedLayers) }
        #expect(store.film.playing)
        store.pauseFilm()
        #expect(store.filmTime == 1)
        var seen = store.filmBoard!.camera(at: 1)
        // Card and badge together reach from 40,40 to 300,220.
        #expect(abs(seen.x - (170 - 200)) < 1e-9 && abs(seen.y - (130 - 150)) < 1e-9)
        #expect(abs(seen.zoom - 400 / (260 * 1.35)) < 1e-9)
        // On from there, to the badge alone.
        store.selection = [id("Badge")]
        store.seek(1.8)
        bench.step { store.flyCamera(to: store.posedLayers) }
        #expect(store.film.live == 1)
        store.pauseFilm()
        seen = store.filmBoard!.camera(at: 1.8)
        #expect(abs(seen.x - 70) < 1e-9 && camera(.cameraMove).map(\.t) == [0, 1, 1.8])
    }

    @Test func theCameraComesNoCloserThanEightTimesAndNoFurtherThanTheWhole() {
        animate()
        edit { doc in
            doc.nodes[0].children.append(CanvasTests.rect("Dot", CGRect(x: 100, y: 100, width: 4, height: 4)))
            doc.nodes[0].children.append(CanvasTests.rect("Wall", CGRect(x: 0, y: 0, width: 400, height: 300)))
            doc.nodes[0].children.append(CanvasTests.rect("Rule", CGRect(x: 100, y: 200, width: 200, height: 0)))
        }
        store.seek(1)
        store.selection = [id("Dot")]
        #expect(store.posedLayers == [id("Dot")])
        bench.step { store.flyCamera(to: store.posedLayers) }
        store.pauseFilm()
        #expect(camera(.cameraZoom).map(\.v) == [[1], [8]])
        #expect(camera(.cameraMove).map(\.v) == [[0, 0], [-98, -48]])
        #expect(store.filmBoard!.camera(at: 1).zoom == 8)
        bench.undo.undo()
        // What fills the artboard is seen whole as it is: there is nowhere to fly.
        let before = store.doc
        bench.step { store.flyCamera(to: [id("Wall")]) }
        #expect(store.doc == before && !store.film.playing)
        // A rule has no height, and is looked at along its length.
        bench.step { store.flyCamera(to: [id("Rule")]) }
        store.pauseFilm()
        let seen = store.filmBoard!.camera(at: 1)
        #expect(abs(seen.zoom - 400 / (200 * 1.35)) < 1e-9 && seen.y == 50 && seen.x == 0)
        bench.undo.undo()
        // Layers of another artboard, or none at all, are nowhere to fly to.
        bench.step { store.flyCamera(to: [id("Far"), UUID()]); store.flyCamera(to: []) }
        #expect(store.doc == before)
    }

    @Test func theCameraFliesToWhereALayerIsAtThatMoment() {
        animate()
        edit { doc in
            doc.update(id("Card")) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [100, 50], at: 1); $0.setKey(.scale, [1, 1], at: 0); $0.setKey(.scale, [2, 2], at: 1) }
            // The row is moved up as a whole, and its label with it.
            doc.update(id("Row")) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [0, -100], at: 1) }
        }
        store.seek(1)
        bench.step { store.flyCamera(to: [id("Card")]) }
        store.pauseFilm()
        var seen = store.filmBoard!.camera(at: 1)
        // The card's middle is at 100,80 as designed, and at 200,130 by then, twice the size.
        #expect(abs(seen.x) < 1e-9 && abs(seen.y - (130 - 150)) < 1e-9)
        #expect(abs(seen.zoom - min(400 / (240 * 1.35), 300 / (160 * 1.35))) < 1e-9)
        bench.undo.undo()
        bench.step { store.flyCamera(to: [id("Label")]) }
        store.pauseFilm()
        seen = store.filmBoard!.camera(at: 1)
        // The label's middle is at 170,260 as designed; its row has taken it up to 160.
        #expect(abs(seen.x - (170 - 200)) < 1e-9 && abs(seen.y - (160 - 150)) < 1e-9)
    }

    // MARK: Keys

    @Test func aPropertysBeadSetsAKeyForEveryLayerOrTakesThemAllAway() {
        animate()
        let card = id("Card"), badge = id("Badge")
        edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [40, 0], at: 1) }
            doc.update(badge) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [10, 0], at: 0.5) }
        }
        store.selection = [card, badge]
        store.seek(0.5)
        // One of them has a key here.
        #expect(store.keyState(.move) == .here)
        bench.step { store.toggleKey(.move) }
        #expect(undoing == "Add Key")
        #expect(times("Card", .move) == [0, 0.5, 1] && times("Badge", .move) == [0, 0.5])
        // The key made holds what the card was on its way through, so nothing jumps.
        let held = keys("Card", .move)[1].v[0]
        #expect(held > 0 && held < 40)
        // Now both have: taken away from both. The badge is left as designed, with nothing to say.
        bench.step { store.toggleKey(.move) }
        #expect(undoing == "Remove Key")
        #expect(times("Card", .move) == [0, 1] && bench.node("Badge")?.motion == nil)
        #expect(store.keyState(.move) == .between)
        // Of a property that does not move yet, a key as designed: held there, to move from.
        store.seek(1)
        #expect(store.keyState(.turn) == .none)
        bench.step { store.toggleKey(.turn) }
        #expect(keys("Card", .turn).map(\.v) == [[0]] && keys("Badge", .turn).map(\.t) == [1])
        #expect(store.keyState(.turn) == .here)
        // With no layer picked there is nothing to key; the camera's bead is the camera's all the same.
        store.selection = []
        let before = store.doc
        bench.step { store.toggleKey(.move) }
        #expect(store.doc == before)
        bench.step { store.toggleKey(.cameraRoll) }
        #expect(camera(.cameraRoll).map(\.t) == [1])
    }

    @Test func holdingTheCameraHoldsOnlyTheCamera() {
        animate()
        edit { doc in
            doc.update(bench.a.id) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) }
            doc.update(id("Card")) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [40, 0], at: 1) }
        }
        store.pickCamera()
        store.seek(0.5)
        #expect(store.holdState == .between)
        bench.step { store.holdHere() }
        #expect(camera(.cameraZoom).map(\.t) == [0, 0.5, 1] && times("Card", .move) == [0, 1])
        #expect(store.holdState == .here)
        // Held twice, nothing more.
        let before = store.doc
        bench.step { store.holdHere() }
        #expect(store.doc == before)
        // With nothing picked there is nothing to hold.
        store.film.camera = false
        #expect(store.holdState == .none)
        bench.step { store.holdHere() }
        #expect(store.doc == before)
        // A layer that does not move has nothing to hold either.
        store.selection = [id("Badge")]
        bench.step { store.holdHere() }
        #expect(store.doc == before && store.holdState == .none)
    }

    @Test func deleteWithNothingAtThePlayheadTakesNothing() {
        animate()
        let card = id("Card")
        edit { $0.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [40, 0], at: 1) } }
        store.selection = [card]
        store.seek(0.5)
        #expect(!store.hasKeysToRemove)
        let before = store.doc
        bench.step { store.removeFilmKeys() }
        #expect(store.doc == before)
        // The camera's keys are taken with the camera picked, and no layer's.
        edit { $0.update(bench.a.id) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 1) } }
        store.pickCamera()
        store.seek(1)
        #expect(store.hasKeysToRemove)
        bench.step { store.removeFilmKeys() }
        #expect(!store.filmBoard!.hasCamera && times("Card", .move) == [0, 1])
    }

    @Test(arguments: MotionEase.Kind.allCases)
    func everyPaceIsKeptOnTheKeyAndAutoIsNoPaceOfItsOwn(_ kind: MotionEase.Kind) {
        animate()
        let card = id("Card")
        edit { $0.update(card) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [40, 0], at: 1, ease: .hold) } }
        store.selection = [card]
        store.seek(1)
        bench.step { store.setEase(kind == .hold ? .linear : .hold) }
        bench.step { store.setEase(kind == .spring ? .spring() : MotionEase(kind: kind)) }
        #expect(store.sharedEase?.kind == kind)
        let kept = keys("Card", .move).last?.ease
        #expect(kind == .auto ? kept == nil : kept?.kind == kind)
        #expect(undoing == "Change Pace")
        // The pace is how the key is come to: the layer is where it was at the key itself.
        #expect(bench.node("Card")!.pose(at: 1).move == CGPoint(x: 40, y: 0))
        #expect(bench.node("Card")!.pose(at: 0).move == .zero)
    }

    @Test func keysThatDifferInPaceShareNone() {
        animate()
        let card = id("Card")
        edit { doc in
            doc.update(card) { n in
                n.setKey(.move, [0, 0], at: 0); n.setKey(.move, [40, 0], at: 1, ease: .linear)
                n.setKey(.fade, [0], at: 0); n.setKey(.fade, [1], at: 1, ease: .hold)
            }
        }
        store.selection = [card]
        store.seek(1)
        #expect(store.sharedEase == nil)
        // One property's key picked in the timeline has its own.
        store.film.keys = [FilmKeyRef(card, .fade, at: 1)]
        #expect(store.sharedEase == .hold)
        bench.step { store.setEase(.smooth) }
        #expect(keys("Card", .fade).last?.ease == .smooth && keys("Card", .move).last?.ease == .linear)
        // Away from every key there is none to have a pace.
        store.film.keys = []
        store.seek(0.5)
        #expect(store.sharedEase == nil)
        let before = store.doc
        bench.step { store.setEase(.hold) }
        #expect(store.doc == before)
    }

    @Test func keysMoveInTimeOnlyWithinADrag() {
        animate()
        let card = id("Card"), a = bench.a.id
        edit { doc in
            doc.update(card) { $0.setKey(.move, [0, 0], at: 0.5); $0.setKey(.move, [40, 0], at: 1) }
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0.5); $0.setKey(.cameraZoom, [2], at: 1) }
        }
        let before = store.doc
        let refs = [FilmKeyRef(a, at: 1)]
        #expect(store.retime(refs, by: 0.5) == refs && store.doc == before)
        bench.step {
            store.beginGesture()
            #expect(store.retime(refs, by: 0.25) == [FilmKeyRef(a, at: 1.25)])
            // Each step is measured from where the drag began, not from the step before.
            #expect(store.retime(refs, by: 0.4) == [FilmKeyRef(a, at: 1.4)])
            #expect(store.retime([], by: 1).isEmpty)
            store.endGesture("Move Key")
        }
        // The camera's key moved; the card's at the same moment is another line's.
        #expect(camera(.cameraZoom).map(\.t) == [0.5, 1.4] && times("Card", .move) == [0.5, 1])
        #expect(undoing == "Move Key")
        bench.step {
            store.beginGesture()
            // Both of the card's keys, far to the left: the first stops at the start.
            #expect(store.retime([FilmKeyRef(card, at: 0.5), FilmKeyRef(card, at: 1)], by: -3) == [FilmKeyRef(card, at: 0), FilmKeyRef(card, at: 0.5)])
            store.endGesture("Move Key")
        }
        #expect(times("Card", .move) == [0, 0.5])
    }

    // MARK: Moves made in one go

    @Test(arguments: MotionMove.allCases)
    func everyMoveComesOnFromAwayAndGoesFromTheDesign(_ move: MotionMove) {
        animate()
        let card = id("Card")
        store.selection = [card]
        store.seek(0.5)
        let end = MotionTiming.time(0.5 + move.time)
        bench.step { store.applyMove(move) }
        #expect(store.film.playing && undoing == move.title)
        store.pauseFilm()
        // Shown, and the playhead rests where it has arrived.
        #expect(store.filmTime == end)
        let away = move.away(CGRect(x: 40, y: 40, width: 120, height: 80), on: CGSize(width: 400, height: 300))
        #expect(Set(bench.node("Card")!.motionProperties) == Set(away.keys))
        for (p, v) in away {
            #expect(times("Card", p) == [0.5, end])
            #expect(keys("Card", p).first?.v == p.clamped(v) && keys("Card", p).last?.v == p.rest)
        }
        #expect(!bench.node("Card")!.pose(at: 0.5).isRest && bench.node("Card")!.pose(at: end).isRest)
        // Before it has come it is already away, so it does not show and then jump.
        #expect(bench.node("Card")!.pose(at: 0) == bench.node("Card")!.pose(at: 0.5))
        bench.undo.undo()
        #expect(bench.node("Card")!.motion == nil)
        // Going: from the design to away, and the playhead rests where it set out.
        store.seek(0.5)
        store.film.going = true
        bench.step { store.applyMove(move) }
        store.pauseFilm()
        #expect(store.filmTime == 0.5)
        #expect(bench.node("Card")!.pose(at: 0.5).isRest && !bench.node("Card")!.pose(at: end).isRest)
        for (p, v) in away { #expect(keys("Card", p).last?.v == p.clamped(v)) }
    }

    @Test func aMoveTakesThePlaceOfTheKeysInItsTimeAndKeepsTheOthers() {
        animate()
        let card = id("Card")
        edit { doc in
            doc.update(card) { n in
                n.setKey(.fade, [0.2], at: 0.1); n.setKey(.fade, [0.7], at: 0.3); n.setKey(.fade, [0.5], at: 1.5)
                n.setKey(.move, [5, 5], at: 0.2)
            }
        }
        store.selection = [card]
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        #expect(times("Card", .fade) == [0, 0.4, 1.5])
        #expect(times("Card", .move) == [0.2])
    }

    @Test func aMoveOfTheWholeArtboardLeavesOutWhatIsLockedOrHidden() {
        animate()
        edit { doc in
            doc.update(id("Badge")) { $0.locked = true }
            doc.update(id("Row")) { $0.hidden = true }
        }
        store.film.apart = 0.3
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        #expect(times("Card", .fade) == [0, 0.4])
        #expect(bench.node("Badge")?.motion == nil && bench.node("Row")?.motion == nil && bench.node("Label")?.motion == nil)
        bench.undo.undo()
        // With nothing left that may move, nothing happens and nothing plays.
        edit { $0.update(id("Card")) { $0.locked = true } }
        let before = store.doc
        bench.step { store.applyMove(.fade) }
        #expect(store.doc == before && !store.film.playing)
    }

    @Test func severalComeOneAfterAnotherAsTheyAreReadAndOneComesAtOnce() {
        animate()
        store.film.apart = 0.2
        store.seek(0.3)
        // The row lies lowest, the badge above it, the card at the top.
        store.selection = [id("Row"), id("Badge"), id("Card")]
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        #expect(times("Card", .fade) == [0.3, 0.7] && times("Badge", .fade) == [0.5, 0.9] && times("Row", .fade) == [0.7, 1.1])
        // The playhead rests where the last has arrived.
        #expect(abs(store.filmTime - 1.1) < 1e-9)
        bench.undo.undo()
        store.selection = [id("Badge")]
        store.seek(0.3)
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        #expect(times("Badge", .fade) == [0.3, 0.7])
        // Side by side, give or take a few points, the left one first.
        bench.undo.undo()
        edit { $0.update(id("Badge")) { $0.frame.origin.y = 43 } }
        store.selection = [id("Badge"), id("Card")]
        store.seek(0)
        bench.step { store.applyMove(.fade) }
        store.pauseFilm()
        #expect(times("Card", .fade) == [0, 0.4] && times("Badge", .fade) == [0.2, 0.6])
    }

    @Test func aLayerInsideAnotherSlidesInFromItsOwnSideOfTheArtboard() {
        animate()
        store.selection = [id("Label")]
        bench.step { store.applyMove(.slide) }
        store.pauseFilm()
        // The label reaches from 100 to 240 on the artboard: left of its middle, so from the left, wholly off.
        #expect(keys("Label", .move).first?.v == [-248, 0])
        store.selection = [id("Badge")]
        store.seek(0)
        bench.step { store.applyMove(.slide) }
        store.pauseFilm()
        #expect(keys("Badge", .move).first?.v == [400 - 240 + 8, 0])
    }

    @Test func aMoveInAFilmCutShortShowsOnlyAsFarAsTheFilmGoes() {
        animate()
        bench.step { store.setFilm("Film Length") { $0.length = 1 } }
        store.selection = [id("Card")]
        store.seek(0.9)
        bench.step { store.applyMove(.drop) }
        #expect(store.film.playing)
        store.pauseFilm()
        #expect(store.filmTime == 1)
        // Its keys reach past the end all the same, and the film stays as long as it was set.
        #expect(times("Card", .fade) == [0.9, 1.5] && store.filmBoard?.filmLength == 1)
    }

    // MARK: Taking motion away, and the film's own settings

    @Test func removingMotionIsOfTheCameraOfWhatIsPickedOrOfEverything() {
        animate()
        edit { doc in
            doc.update(id("Card")) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 1) }
            doc.update(id("Label")) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 1) }
            doc.update(id("Row")) { $0.setKey(.move, [0, 20], at: 0); $0.setKey(.move, [0, 0], at: 1) }
            doc.update(bench.a.id) { $0.setKey(.cameraZoom, [2], at: 0); $0.setKey(.cameraZoom, [1], at: 1); $0.film = Film(length: 3, once: true) }
        }
        store.pickCamera()
        store.film.keys = [FilmKeyRef(bench.a.id, at: 1)]
        bench.step { store.clearFilmMotion() }
        #expect(undoing == "Remove Motion")
        // The camera's alone: the layers', and what the film was set to, are kept.
        #expect(!store.filmBoard!.hasCamera && store.filmBoard!.holdsMotion && store.filmBoard?.film == Film(length: 3, once: true))
        #expect(store.film.keys.isEmpty)
        // Of a layer that holds others, theirs too.
        store.selection = [id("Row")]
        bench.step { store.clearFilmMotion() }
        #expect(bench.node("Row")?.motion == nil && bench.node("Label")?.motion == nil && bench.node("Card")?.motion != nil)
        // With nothing picked, the whole film: every layer as designed, and the film as it is by itself.
        store.selection = []
        bench.step { store.clearFilmMotion() }
        #expect(!store.filmBoard!.hasFilm && store.filmBoard?.film == nil)
        // Each was a step of its own.
        bench.undo.undo(); bench.undo.undo(); bench.undo.undo()
        #expect(store.filmBoard!.hasCamera && store.filmBoard?.film?.once == true)
    }

    @Test func aFilmSetBackToWhatItIsByItselfKeepsNothing() {
        animate()
        bench.step { store.setFilm("Play Once") { $0.once = true } }
        #expect(store.filmBoard?.film?.once == true && undoing == "Play Once")
        bench.step { store.setFilm("Backdrop") { $0.backdrop = RGBA(r: 0.1, g: 0.2, b: 0.3) } }
        #expect(store.filmBoard?.filmBackdrop == RGBA(r: 0.1, g: 0.2, b: 0.3))
        bench.step { store.setFilm("Play Round and Round") { $0.once = nil } }
        bench.step { store.setFilm("Backdrop") { $0.backdrop = nil } }
        #expect(store.filmBoard?.film == nil)
        // Its backdrop is then told by the artboard's own colour: light paper round a light page, dark round a dark one.
        let light = store.filmBoard!.filmBackdrop
        edit { $0.update(bench.a.id) { $0.fill.on = true; $0.fill.color = RGBA(r: 0.05, g: 0.05, b: 0.08) } }
        let dark = store.filmBoard!.filmBackdrop
        #expect(light.r > 0.5 && dark.r < 0.2)
        // Set to what it already is, nothing is done.
        let before = store.doc
        bench.step { store.setFilm("Film Length") { $0.length = nil } }
        #expect(store.doc == before)
    }

    @Test func aFilmIsAsLongAsItsLastKeyToTheHalfSecondAndNeverUnderTwo() {
        animate()
        #expect(store.filmBoard?.filmLength == 2)
        edit { $0.update(id("Label")) { $0.setKey(.fade, [0], at: 0); $0.setKey(.fade, [1], at: 2.2) } }
        #expect(store.filmBoard?.filmLength == 2.5)
        edit { $0.update(bench.a.id) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [2], at: 3) } }
        #expect(store.filmBoard?.filmLength == 3)
        // Set by hand it is that, however far the keys reach, and they are kept.
        bench.step { store.setFilm("Film Length") { $0.length = 0.5 } }
        #expect(store.filmBoard?.filmLength == 0.5 && times("Label", .fade) == [0, 2.2])
        // Past the end there is nowhere for the playhead to stand, or to pose at.
        store.seek(9)
        #expect(store.filmTime == 0.5)
        store.seek(-3)
        #expect(store.filmTime == 0)
    }
}
