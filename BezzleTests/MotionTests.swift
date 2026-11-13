import Testing
import AppKit
@testable import Bezzle

/// Animate's model: keys kept as changes from the design, how a value travels between them, the
/// camera's arithmetic, and the pieces a film is made of.
@MainActor
struct MotionTests {
    private func card(_ name: String = "Card", _ frame: CGRect = CGRect(x: 100, y: 80, width: 120, height: 60)) -> Node {
        Node(kind: .rectangle, name: name, frame: frame)
    }

    private func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: Double = 1e-6) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

    // MARK: Posing

    @Test func aLayerPosedLaterLeavesTheDesignAtTheStart() {
        var n = card()
        n.pose(.move, [40, 0], at: 1)
        let keys = n[track: .move]!.keys
        #expect(keys.map(\.t) == [0, 1])
        #expect(keys[0].v == [0, 0] && keys[0].given == true)
        #expect(keys[1].v == [40, 0] && keys[1].given == nil)
        #expect(n.value(of: .move, at: 0) == [0, 0])
        #expect(n.value(of: .move, at: 1) == [40, 0])
        #expect(n.value(of: .move, at: 5) == [40, 0])
        let mid = n.value(of: .move, at: 0.5)[0]
        #expect(mid > 0 && mid < 40)
    }

    @Test func aLayerPosedAtTheStartFliesHome() {
        var n = card()
        n.pose(.fade, [0], at: 0)
        let keys = n[track: .fade]!.keys
        #expect(keys.map(\.t) == [0, MotionTiming.beat])
        #expect(keys[0].v == [0] && keys[1].v == [1] && keys[1].given == true)
        // Coming home, it arrives gently: most of the way there well before the end.
        #expect(n.value(of: .fade, at: MotionTiming.beat / 2)[0] > 0.7)
    }

    @Test func theDesignGivenForCompanyGivesWayToAKeyPosedPastIt() {
        var n = card()
        n.pose(.move, [0, 50], at: 0)
        n.pose(.move, [30, 0], at: 1.5)
        #expect(n[track: .move]!.keys.map(\.t) == [0, 1.5])
        #expect(n[track: .move]!.keys.map(\.v) == [[0, 50], [30, 0]])
        // Between the two it stays for good.
        var m = card()
        m.pose(.move, [0, 50], at: 0)
        m.pose(.move, [0, 20], at: 0.25)
        #expect(m[track: .move]!.keys.map(\.t) == [0, 0.25, 0.5])
    }

    @Test func posingAsDesignedMakesNoKeyAndAKeyThereIsChanged() {
        var n = card()
        n.pose(.scale, [1, 1], at: 1)
        #expect(n.motion == nil)
        n.pose(.scale, [2, 2], at: 1)
        n.pose(.scale, [3, 3], at: 1.002)
        #expect(n[track: .scale]!.keys.count == 2)
        #expect(n.value(of: .scale, at: 1) == [3, 3])
    }

    @Test func keysAreTakenAwayMovedAndPaced() {
        var n = card()
        n.pose(.move, [40, 0], at: 1)
        n.pose(.move, [40, 40], at: 2)
        n.moveKeys(from: 1, to: 1.5, of: [.move])
        #expect(n[track: .move]!.keys.map(\.t) == [0, 1.5, 2])
        n.setEase(.hold, at: 2, of: [.move])
        #expect(n.value(of: .move, at: 1.9) == [40, 0])
        #expect(n.value(of: .move, at: 2) == [40, 40])
        n.removeKeys(at: 1.5, of: [.move])
        n.removeKeys(at: 2, of: [.move])
        // Only the design is left to say, which is nothing.
        #expect(n.motion == nil)
    }

    @Test func valuesAreKeptWithinWhatShows() {
        var n = card()
        n.pose(.fade, [3], at: 1)
        #expect(n.value(of: .fade, at: 1) == [1])
        #expect(n.motion == nil)
        n.pose(.fade, [-2], at: 1)
        #expect(n.value(of: .fade, at: 1) == [0])
        n.pose(.scale, [0, -4], at: 1)
        #expect(n.value(of: .scale, at: 1)[0] > 0)
    }

    // MARK: Pacing

    @Test func everyPaceStartsAndEndsWhereItShould() {
        for kind in MotionEase.Kind.allCases {
            #expect(near(MotionEase.progress(kind, 0), 0, 1e-4), "\(kind)")
            #expect(near(MotionEase.progress(kind, 1), 1, 1e-4), "\(kind)")
        }
        #expect(MotionEase.progress(.hold, 0.99) == 0)
        #expect(near(MotionEase.progress(.linear, 0.3), 0.3))
        #expect(MotionEase.progress(.easeOut, 0.3) > 0.6)
        #expect(MotionEase.progress(.easeIn, 0.7) < 0.4)
        // A spring goes past, and more the more bounce it has.
        let high = stride(from: 0.0, through: 1, by: 0.01).map { MotionEase.spring($0, bounce: 0.6) }.max()!
        let none = stride(from: 0.0, through: 1, by: 0.01).map { MotionEase.spring($0, bounce: 0) }.max()!
        #expect(high > 1.1)
        #expect(none <= 1.0001)
    }

    @Test func aMotionThatKeepsGoingFliesThroughItsKeys() {
        var n = card()
        n.setKey(.move, [0, 0], at: 0)
        n.setKey(.move, [100, 0], at: 1)
        n.setKey(.move, [200, 0], at: 2)
        let track = n[track: .move]!
        #expect(track.flows(through: 1))
        #expect(track.pace(of: 0, rest: [0, 0]) == .setOff)
        #expect(track.pace(of: 1, rest: [0, 0]) == .setDown)
        // No jerk at the middle key: the speed just before it is the speed just after.
        let dt = 0.001
        let before = (n.value(of: .move, at: 1)[0] - n.value(of: .move, at: 1 - dt)[0]) / dt
        let after = (n.value(of: .move, at: 1 + dt)[0] - n.value(of: .move, at: 1)[0]) / dt
        #expect(abs(before - after) < 2)
        #expect(before > 80)
        // And it rests at both ends.
        #expect((n.value(of: .move, at: dt)[0]) / dt < 5)
        #expect((200 - n.value(of: .move, at: 2 - dt)[0]) / dt < 5)
    }

    @Test func aMotionThatTurnsBackRestsWhereItTurns() {
        var n = card()
        n.setKey(.scale, [1, 1], at: 0)
        n.setKey(.scale, [1.4, 1.4], at: 0.5)
        n.setKey(.scale, [1, 1], at: 1)
        let track = n[track: .scale]!
        #expect(!track.flows(through: 1))
        let dt = 0.001
        #expect(abs(n.value(of: .scale, at: 0.5)[0] - n.value(of: .scale, at: 0.5 - dt)[0]) / dt < 0.2)
        // A pace that was chosen is kept, though the motion keeps going.
        var m = card()
        m.setKey(.move, [0, 0], at: 0)
        m.setKey(.move, [100, 0], at: 1, ease: .spring(0.5))
        m.setKey(.move, [200, 0], at: 2)
        #expect(!m[track: .move]!.flows(through: 1))
    }

    // MARK: Moves made in one go

    @Test func aMoveComesFromAwayToTheDesign() {
        var n = card()
        n.apply(.rise, at: 0.5, frame: n.frame, board: CGSize(width: 400, height: 300))
        #expect(n.value(of: .fade, at: 0) == [0])
        #expect(n.value(of: .move, at: 0.5) == [0, 28])
        #expect(n.value(of: .move, at: 0.5 + MotionMove.rise.time) == [0, 0])
        #expect(n.value(of: .fade, at: 2) == [1])
        // Going is the same backwards.
        var m = card()
        m.apply(.fade, at: 1, going: true, frame: m.frame, board: CGSize(width: 400, height: 300))
        #expect(m.value(of: .fade, at: 1) == [1])
        #expect(m.value(of: .fade, at: 1 + MotionMove.fade.time) == [0])
    }

    @Test func aSlideComesFromOffTheNearerSide() {
        let board = CGSize(width: 400, height: 300)
        let left = MotionMove.slide.away(CGRect(x: 20, y: 0, width: 100, height: 40), on: board)[.move]!
        let right = MotionMove.slide.away(CGRect(x: 280, y: 0, width: 100, height: 40), on: board)[.move]!
        #expect(left[0] == -128)
        #expect(right[0] == 128)
    }

    @Test func severalLayersComeOneAfterAnotherAsTheyAreRead() {
        let bench = Bench(extra: [card("Low", CGRect(x: 40, y: 200, width: 80, height: 30)), card("High", CGRect(x: 40, y: 40, width: 80, height: 30)),
                                  card("Middle", CGRect(x: 40, y: 120, width: 80, height: 30))])
        let ids = ["Low", "High", "Middle"].map { bench.node($0)!.id }
        bench.step { bench.store.edit("Move") { $0.apply(.fade, to: ids, at: 0, apart: 0.1) } }
        #expect(bench.node("High")![track: .fade]!.start == 0)
        #expect(bench.node("Middle")![track: .fade]!.start == 0.1)
        #expect(bench.node("Low")![track: .fade]!.start == 0.2)
        bench.step { bench.store.edit("Clear") { $0.clearMotion([bench.a.id]) } }
        #expect(bench.store.doc.allNodes.allSatisfy { $0.motion == nil })
    }

    // MARK: The camera

    @Test func atRestTheCameraShowsTheArtboardAsItIs() {
        let size = CGSize(width: 400, height: 300)
        let map = FilmLens.ground(.rest, size: size)
        for p in [CGPoint.zero, CGPoint(x: 400, y: 300), CGPoint(x: 123, y: 45)] { #expect(near(map(p), p)) }
        #expect(map.isFlat)
        // And a layer at rest lies in it.
        let layer = FilmLens.layer(center: CGPoint(x: 160, y: 110), rotation: 30, pose: .rest, camera: .rest, size: size)
        #expect(near(layer(CGPoint(x: 100, y: 80)), CGPoint(x: 100, y: 80)))
    }

    @Test func theCameraLooksElsewhereComesCloserAndRolls() {
        let size = CGSize(width: 400, height: 300)
        var camera = FilmCamera()
        camera.x = 50
        camera.y = -20
        // What it looks at is in the middle of the frame.
        #expect(near(FilmLens.ground(camera, size: size)(CGPoint(x: 250, y: 130)), CGPoint(x: 200, y: 150)))
        camera.zoom = 2
        let map = FilmLens.ground(camera, size: size)
        #expect(near(map(CGPoint(x: 250, y: 130)), CGPoint(x: 200, y: 150)))
        #expect(near(map(CGPoint(x: 260, y: 130)), CGPoint(x: 220, y: 150)))
        #expect(near(map.stretch(at: CGPoint(x: 250, y: 130)), 2))
        // The way back.
        #expect(near(map.back(CGPoint(x: 220, y: 150))!, CGPoint(x: 260, y: 130)))
        var rolled = FilmCamera()
        rolled.roll = 90
        // Turned a quarter clockwise, what was right of the middle is below it.
        #expect(near(FilmLens.ground(rolled, size: size)(CGPoint(x: 300, y: 150)), CGPoint(x: 200, y: 250)))
    }

    @Test func tippedBackTheTopGoesAwayAndWhatIsLiftedShowsItsHeight() {
        let size = CGSize(width: 400, height: 400)
        var camera = FilmCamera()
        camera.tilt = 50
        let ground = FilmLens.ground(camera, size: size)
        let top = ground(CGPoint(x: 0, y: 0)), topRight = ground(CGPoint(x: 400, y: 0))
        let bottom = ground(CGPoint(x: 0, y: 400)), bottomRight = ground(CGPoint(x: 400, y: 400))
        // The far edge shows shorter than the near one, and the middle stays put.
        #expect(topRight.x - top.x < bottomRight.x - bottom.x)
        #expect(near(ground(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200)))
        #expect(!ground.isFlat)
        // Lifted off the sheet, a layer shows above where it lies, toward the top of the frame.
        var pose = MotionPose()
        pose.lift = 60
        let lifted = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose, camera: camera, size: size)
        #expect(lifted(CGPoint(x: 200, y: 200)).y < 199)
        // Seen straight on, it only comes nearer: bigger about the frame's middle.
        let straight = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose, camera: .rest, size: size)
        #expect(near(straight(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200)))
        #expect(straight.stretch(at: CGPoint(x: 200, y: 200)) > 1.05)
    }

    @Test func aPosedLayerGrowsAndTurnsAboutItsMiddle() {
        let size = CGSize(width: 400, height: 300)
        var pose = MotionPose()
        pose.scale = CGPoint(x: 2, y: 1)
        pose.move = CGPoint(x: 10, y: 5)
        let map = FilmLens.layer(center: CGPoint(x: 160, y: 110), rotation: 0, pose: pose, camera: .rest, size: size)
        #expect(near(map(CGPoint(x: 160, y: 110)), CGPoint(x: 170, y: 115)))
        #expect(near(map(CGPoint(x: 220, y: 140)), CGPoint(x: 290, y: 145)))
        // Turned by the design, it grows along its own sides, not the page's.
        var wide = MotionPose()
        wide.scale = CGPoint(x: 2, y: 1)
        let turned = FilmLens.layer(center: CGPoint(x: 100, y: 100), rotation: 90, pose: wide, camera: .rest, size: size)
        // Its own width runs down the page.
        #expect(near(turned(CGPoint(x: 100, y: 130)), CGPoint(x: 100, y: 160)))
        #expect(near(turned(CGPoint(x: 130, y: 100)), CGPoint(x: 130, y: 100)))
        var spun = MotionPose()
        spun.turn = 90
        let quarter = FilmLens.layer(center: CGPoint(x: 100, y: 100), rotation: 0, pose: spun, camera: .rest, size: size)
        #expect(near(quarter(CGPoint(x: 150, y: 100)), CGPoint(x: 100, y: 150)))
    }

    // MARK: Pieces

    @Test func aFilmIsItsGroundRunsOfStillLayersAndEachMovingOne() {
        var moving = card("Moving")
        moving.pose(.move, [10, 0], at: 1)
        var inner = card("Inner", CGRect(x: 0, y: 0, width: 20, height: 20))
        inner.pose(.fade, [0], at: 1)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 30, y: 40, width: 60, height: 20))
        group.children = [card("Still in group", CGRect(x: 30, y: 0, width: 30, height: 20)), inner]
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [card("One"), card("Two"), moving, card("Three"), group]
        let pieces = board.filmPieces()
        #expect(pieces.map(\.kind) == [.ground, .run, .layer, .run, .run, .layer])
        #expect(pieces[1].layers.count == 2)
        #expect(pieces[2].layers == [moving.id])
        // The group came apart: its still layer and its moving one, each where the group begins.
        #expect(pieces[4].holders == [group.id] && pieces[4].origin == CGPoint(x: 30, y: 40))
        #expect(pieces[5].layers == [inner.id] && pieces[5].origin == CGPoint(x: 30, y: 40))
        // A layer picked is kept apart, ready to move.
        let loose = board.filmPieces(loose: [board.children[0].id])
        #expect(loose.map(\.kind) == [.ground, .layer, .run, .layer, .run, .run, .layer])
        // A group that is more than its layers stays whole, and is drawn again as they move.
        board.children[4].opacity = 0.5
        let whole = board.filmPieces()
        #expect(whole.last?.layers == [group.id] && whole.last?.changes == true)
    }

    @Test func aPieceIsPlacedByItsLayersPose() {
        var moving = card("Moving")
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [100, 0], at: 1, ease: .linear)
        moving.setKey(.fade, [0.5], at: 0)
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [moving]
        let piece = board.filmPieces()[1]
        let placed = board.placement(of: piece, at: 0.5, camera: .rest)
        #expect(near(placed.map(CGPoint(x: 100, y: 80)), CGPoint(x: 150, y: 80)))
        #expect(placed.opacity == 0.5)
        #expect(near(board.filmCorners(of: moving.id, at: 0.5, pieces: board.filmPieces())![0], CGPoint(x: 150, y: 80)))
    }

    @Test func whatIsLiftedCoversWhatIsNot() {
        var low = card("Low"), high = card("High")
        high.setKey(.lift, [40], at: 0)
        low.setKey(.fade, [1], at: 0)
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [high, low]
        let pieces = board.filmPieces()
        let placements = pieces.map { board.placement(of: $0, at: 0, camera: .rest) }
        let order = board.filmOrder(pieces, placements)
        #expect(pieces[order.last!].layers == [high.id])
    }

    @Test func aPressFindsTheLayerWhereItShowsNotWhereItWasDesigned() {
        var moving = card("Moving")
        moving.setKey(.move, [200, 100], at: 0)
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [card("Still", CGRect(x: 10, y: 10, width: 40, height: 40)), moving]
        let pieces = board.filmPieces()
        #expect(board.filmChain(at: CGPoint(x: 360, y: 210), time: 0, pieces: pieces, tolerance: 2).first?.name == "Moving")
        #expect(board.filmChain(at: CGPoint(x: 160, y: 110), time: 0, pieces: pieces, tolerance: 2).isEmpty)
        #expect(board.filmChain(at: CGPoint(x: 30, y: 30), time: 0, pieces: pieces, tolerance: 2).first?.name == "Still")
    }

    @Test func aLayerPosedForDrawingIsMovedGrownTurnedAndFaded() {
        var n = card()
        n.opacity = 0.8
        n.setKey(.move, [10, 20], at: 0)
        n.setKey(.scale, [2, 2], at: 0)
        n.setKey(.turn, [45], at: 0)
        n.setKey(.fade, [0.5], at: 0)
        n.setKey(.lift, [30], at: 0)
        let posed = n.posed(at: 0)
        #expect(posed.frame == CGRect(x: 50, y: 70, width: 240, height: 120))
        #expect(posed.rotation == 45)
        #expect(near(posed.opacity, 0.4))
        #expect(posed.transform3D?.z == 30)
        #expect(n.posed(at: 0, own: false).frame == n.frame)
    }

    // MARK: Kept and shared

    @Test func motionIsALayersOwnPropertyKeptInFilesAndSharedTrackByTrack() throws {
        #expect(LayerField.all.contains { $0.name == "motion" } && LayerField.all.contains { $0.name == "film" })
        var n = card()
        n.pose(.move, [40, 0], at: 1)
        n.setKey(.fade, [0], at: 0, ease: .spring(0.4))
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        board.children = [n]
        board.film = Film(length: 4, once: true)
        board.setKey(.cameraZoom, [2], at: 1)
        var doc = BezzleDocument()
        doc.nodes = [board]
        let back = try JSONDecoder().decode(BezzleDocument.self, from: JSONEncoder().encode(doc))
        #expect(back == doc)
        #expect(back.nodes[0].filmLength == 4)
        #expect(back.nodes[0].camera(at: 1).zoom == 2)
        // A design from before Animate reads as it always did.
        let old = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(card()))
        #expect(old.motion == nil && old.film == nil)

        // Two people keying different properties of one layer both keep theirs.
        var mine = doc, theirs = doc
        mine.update(n.id) { $0.setKey(.turn, [90], at: 2) }
        theirs.update(n.id) { $0.setKey(.scale, [2, 2], at: 2) }
        let merged = FlatDesign.apply(from: doc, to: mine, onto: theirs)
        #expect(merged.node(n.id)?[track: .turn] != nil)
        #expect(merged.node(n.id)?[track: .scale] != nil)
        #expect(merged.node(n.id)?[track: .move] == n[track: .move])
    }

    @Test func aFilmRunsAsLongAsItsLastKeyUnlessItIsSet() {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(board.filmLength == MotionTiming.shortest)
        #expect(!board.hasFilm)
        var n = card()
        n.pose(.move, [10, 0], at: 3.2)
        board.children = [n]
        #expect(board.filmLength == 3.5)
        #expect(board.hasFilm)
        board.film = Film(length: 6)
        #expect(board.filmLength == 6)
    }
}
