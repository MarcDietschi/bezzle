import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// The camera's arithmetic and the pieces a film is made of, past what `MotionTests` shows: each
/// thing the camera and a pose can do, done to points whose place is worked out by hand; the way
/// back from the picture to the page; and which layers are drawn together, which apart, and in
/// what order.
@MainActor
struct MotionLensTests {
    private let size = CGSize(width: 400, height: 400)
    /// How far the camera rests above an artboard of `size`.
    private let far = 800.0

    private func card(_ name: String = "Card", _ frame: CGRect = CGRect(x: 100, y: 80, width: 120, height: 60)) -> Node {
        Node(kind: .rectangle, name: name, frame: frame)
    }

    private func group(_ name: String, at origin: CGPoint = .zero, _ children: [Node]) -> Node {
        var g = Node(kind: .group, name: name, frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)))
        g.children = children
        return g
    }

    private func board(_ children: [Node] = [], size: CGSize = CGSize(width: 400, height: 400)) -> Node {
        var b = Node(kind: .artboard, name: "A", frame: CGRect(origin: CGPoint(x: 700, y: 50), size: size))
        b.children = children
        return b
    }

    private func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }
    private func near(_ a: CGPoint, _ b: CGPoint, _ e: Double = 1e-6) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }
    private func sine(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
    private func cosine(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }

    private func camera(_ change: (inout FilmCamera) -> Void) -> FilmCamera {
        var c = FilmCamera()
        change(&c)
        return c
    }

    private func pose(_ change: (inout MotionPose) -> Void) -> MotionPose {
        var p = MotionPose()
        change(&p)
        return p
    }

    private let points = [CGPoint.zero, CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 400), CGPoint(x: 0, y: 400), CGPoint(x: 200, y: 200),
                          CGPoint(x: 123, y: 45), CGPoint(x: 310, y: 377)]

    // MARK: A plane into the picture

    @Test func mapsMoveGrowAndFollowOneAnother() {
        let p = CGPoint(x: 30, y: -40)
        #expect(FilmMap.identity(p) == p)
        #expect(FilmMap.translation(10, 20)(p) == CGPoint(x: 40, y: -20))
        #expect(FilmMap.scale(3)(p) == CGPoint(x: 90, y: -120))
        // One after another is the second done to what the first gives.
        #expect(FilmMap.scale(3).after(.translation(10, 20))(p) == CGPoint(x: 120, y: -60))
        #expect(FilmMap.translation(10, 20).after(.scale(3))(p) == CGPoint(x: 100, y: -100))
        let tipped = FilmLens.ground(camera { $0.tilt = 40; $0.swing = -25; $0.roll = 10; $0.zoom = 1.5; $0.x = 30 }, size: size)
        let other = FilmLens.ground(camera { $0.tilt = -15; $0.zoom = 0.7; $0.y = -60 }, size: size)
        for q in points { #expect(near(tipped.after(other)(q), tipped(other(q)), 1e-6), "\(q)") }
        // Nothing done, nothing changes; and how big things show is how much a map grows them.
        #expect(FilmMap.identity.after(tipped) == tipped)
        #expect(FilmMap.identity.isFlat && FilmMap.scale(3).isFlat && FilmMap.translation(4, 4).isFlat)
        #expect(near(FilmMap.identity.stretch(at: p), 1) && near(FilmMap.scale(3).stretch(at: p), 3))
        #expect(FilmMap.identity.depth(at: p) == 1)
    }

    @Test func theWayBackLeadsToWhereItCameFrom() {
        let cameras = [FilmCamera.rest, camera { $0.zoom = 2.5; $0.x = 80; $0.y = -30 }, camera { $0.roll = 137 },
                       camera { $0.tilt = 55 }, camera { $0.swing = -70 }, camera { $0.tilt = -30; $0.swing = 40; $0.roll = -20; $0.zoom = 0.4; $0.x = -100; $0.y = 60 }]
        for (i, c) in cameras.enumerated() {
            let map = FilmLens.ground(c, size: size)
            let inverse = map.inverse
            #expect(inverse != nil, "camera \(i)")
            for p in points {
                let shown = map(p)
                #expect(map.back(shown).map { near($0, p, 1e-5) } == true, "camera \(i) at \(p)")
                #expect(inverse.map { near($0(shown), p, 1e-5) } == true, "camera \(i) at \(p)")
                #expect(map.depth(at: p) > 0, "camera \(i) at \(p)")
            }
        }
        // A posed layer's map leads back as well.
        let map = FilmLens.layer(center: CGPoint(x: 150, y: 120), rotation: 30,
                                 pose: pose { $0.move = CGPoint(x: 20, y: -10); $0.scale = CGPoint(x: 1.5, y: 0.5); $0.turn = 40; $0.tilt = 35; $0.swing = -20; $0.lift = 50 },
                                 camera: camera { $0.tilt = 20; $0.zoom = 1.3 }, size: size)
        for p in points { #expect(map.back(map(p)).map { near($0, p, 1e-5) } == true, "\(p)") }
        // A plane that shows nothing has no way back: shrunk to nothing, or seen edge on.
        #expect(FilmMap.scale(0).inverse == nil && FilmMap.scale(0).back(.zero) == nil)
        let edgeOn = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose { $0.tilt = 90 }, camera: .rest, size: size)
        #expect(edgeOn.back(CGPoint(x: 200, y: 180)) == nil)
    }

    // MARK: The camera

    @Test func theCameraComesCloserAboutWhereItLooks() {
        for zoom in [0.1, 0.5, 2, 16] {
            let c = camera { $0.zoom = zoom; $0.x = 60; $0.y = -40 }
            let map = FilmLens.ground(c, size: size)
            // What it looks at is in the middle of the frame, and everything else that many times further from it.
            #expect(near(map(CGPoint(x: 260, y: 160)), CGPoint(x: 200, y: 200)), "zoom \(zoom)")
            for p in points {
                #expect(near(map(p), CGPoint(x: 200 + (p.x - 260) * zoom, y: 200 + (p.y - 160) * zoom), 1e-6), "zoom \(zoom) at \(p)")
                #expect(near(map.stretch(at: p), zoom), "zoom \(zoom) at \(p)")
            }
            #expect(map.isFlat)
        }
    }

    @Test func theCameraRollsThePictureClockwiseAboutItsMiddle() {
        let quarter = FilmLens.ground(camera { $0.roll = 90 }, size: size)
        // What was above the middle is right of it, and what was right of it is below.
        #expect(near(quarter(CGPoint(x: 200, y: 100)), CGPoint(x: 300, y: 200)))
        #expect(near(quarter(CGPoint(x: 300, y: 200)), CGPoint(x: 200, y: 300)))
        #expect(near(quarter(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200)))
        let half = FilmLens.ground(camera { $0.roll = 180 }, size: size)
        for p in points { #expect(near(half(p), CGPoint(x: 400 - p.x, y: 400 - p.y)), "\(p)") }
        // Rolled, nothing grows and nothing leaves the page.
        let some = FilmLens.ground(camera { $0.roll = 33 }, size: size)
        #expect(some.isFlat)
        for p in points {
            #expect(near(some.stretch(at: p), 1), "\(p)")
            #expect(near(hypot(some(p).x - 200, some(p).y - 200), hypot(p.x - 200, p.y - 200)), "\(p)")
        }
        // It rolls about where it looks, wherever that is.
        let off = FilmLens.ground(camera { $0.roll = 90; $0.x = 50; $0.y = 50 }, size: size)
        #expect(near(off(CGPoint(x: 250, y: 250)), CGPoint(x: 200, y: 200)))
        #expect(near(off(CGPoint(x: 250, y: 150)), CGPoint(x: 300, y: 200)))
    }

    @Test func tippedBackTheTopOfTheSceneGoesAway() {
        let map = FilmLens.ground(camera { $0.tilt = 60 }, size: size)
        // The top edge's middle, 200 above the middle of the scene, lies back by 200 sin 60 and up by 200 cos 60.
        let away = far + 200 * sine(60)
        #expect(near(map(CGPoint(x: 200, y: 0)), CGPoint(x: 200, y: 200 - 200 * cosine(60) * far / away)))
        #expect(near(map.depth(at: CGPoint(x: 200, y: 0)), away))
        // The bottom edge comes nearer by as much, and so shows bigger.
        let near = far - 200 * sine(60)
        #expect(self.near(map(CGPoint(x: 200, y: 400)), CGPoint(x: 200, y: 200 + 200 * cosine(60) * far / near)))
        #expect(self.near(map(CGPoint(x: 400, y: 400)).x - map(CGPoint(x: 0, y: 400)).x, 400 * far / near))
        #expect(self.near(map(CGPoint(x: 400, y: 0)).x - map(CGPoint(x: 0, y: 0)).x, 400 * far / away))
        #expect(map.depth(at: CGPoint(x: 0, y: 0)) > map.depth(at: CGPoint(x: 0, y: 200)) && map.depth(at: CGPoint(x: 0, y: 200)) > map.depth(at: CGPoint(x: 0, y: 400)))
        // The level line through the middle stays as it is.
        #expect(self.near(map(CGPoint(x: 0, y: 200)), CGPoint(x: 0, y: 200)) && self.near(map(CGPoint(x: 400, y: 200)), CGPoint(x: 400, y: 200)))
        #expect(!map.isFlat)
        // Tipped the other way, the bottom goes away.
        let forward = FilmLens.ground(camera { $0.tilt = -60 }, size: size)
        #expect(forward.depth(at: CGPoint(x: 200, y: 400)) > forward.depth(at: CGPoint(x: 200, y: 0)))
        #expect(self.near(forward(CGPoint(x: 200, y: 400)), CGPoint(x: 200, y: 200 + 200 * cosine(60) * far / away)))
    }

    @Test func swungRoundTheRightOfTheSceneGoesAway() {
        let map = FilmLens.ground(camera { $0.swing = 60 }, size: size)
        let away = far + 200 * sine(60), near = far - 200 * sine(60)
        #expect(self.near(map(CGPoint(x: 400, y: 200)), CGPoint(x: 200 + 200 * cosine(60) * far / away, y: 200)))
        #expect(self.near(map(CGPoint(x: 0, y: 200)), CGPoint(x: 200 - 200 * cosine(60) * far / near, y: 200)))
        #expect(self.near(map.depth(at: CGPoint(x: 400, y: 200)), away) && self.near(map.depth(at: CGPoint(x: 0, y: 200)), near))
        // The right edge shows shorter than the left, and the upright line through the middle stays.
        #expect(map(CGPoint(x: 400, y: 400)).y - map(CGPoint(x: 400, y: 0)).y < map(CGPoint(x: 0, y: 400)).y - map(CGPoint(x: 0, y: 0)).y)
        #expect(self.near(map(CGPoint(x: 200, y: 0)), CGPoint(x: 200, y: 0)) && self.near(map(CGPoint(x: 200, y: 400)), CGPoint(x: 200, y: 400)))
        #expect(!map.isFlat)
    }

    @Test func theCameraRestsTwiceAsFarAsTheArtboardIsBigAndNeverTooNear() {
        #expect(FilmLens.distance(for: CGSize(width: 400, height: 400)) == 800)
        #expect(FilmLens.distance(for: CGSize(width: 1920, height: 1080)) == 3840)
        #expect(FilmLens.distance(for: CGSize(width: 300, height: 1000)) == 2000)
        #expect(FilmLens.distance(for: CGSize(width: 100, height: 80)) == 600)
        #expect(FilmLens.distance(for: .zero) == 600)
    }

    @Test func pastTheHorizonOfATippedSceneThereIsNoWayBack() {
        let map = FilmLens.ground(camera { $0.tilt = 80 }, size: size)
        // The scene runs away to a line 800 / tan 80 above the frame's middle; above it is sky.
        let horizon = 200 - far * cosine(80) / sine(80)
        #expect(map.back(CGPoint(x: 200, y: horizon - 5)) == nil)
        #expect(map.back(CGPoint(x: 30, y: 0)) == nil)
        let ground = map.back(CGPoint(x: 200, y: horizon + 5))
        #expect(ground != nil && ground!.y < 0)
        #expect(map.back(CGPoint(x: 200, y: 200)).map { near($0, CGPoint(x: 200, y: 200), 1e-5) } == true)
    }

    // MARK: A posed layer

    @Test func aLayerTippedBackHasItsTopGoAwayAndSwungItsRight() {
        let center = CGPoint(x: 200, y: 200)
        let tipped = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.tilt = 60 }, camera: .rest, size: size)
        let away = far + 50 * sine(60), near = far - 50 * sine(60)
        #expect(self.near(tipped(CGPoint(x: 200, y: 150)), CGPoint(x: 200, y: 200 - 50 * cosine(60) * far / away)))
        #expect(self.near(tipped(CGPoint(x: 200, y: 250)), CGPoint(x: 200, y: 200 + 50 * cosine(60) * far / near)))
        #expect(tipped.depth(at: CGPoint(x: 200, y: 150)) > tipped.depth(at: CGPoint(x: 200, y: 250)))
        #expect(!tipped.isFlat)
        let swung = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.swing = 60 }, camera: .rest, size: size)
        #expect(self.near(swung(CGPoint(x: 250, y: 200)), CGPoint(x: 200 + 50 * cosine(60) * far / away, y: 200)))
        #expect(swung.depth(at: CGPoint(x: 250, y: 200)) > swung.depth(at: CGPoint(x: 150, y: 200)))
        // It tips about its own middle, wherever it lies and wherever it was moved to.
        let elsewhere = FilmLens.layer(center: CGPoint(x: 100, y: 300), rotation: 0, pose: pose { $0.tilt = 60; $0.move = CGPoint(x: 100, y: -100) }, camera: .rest, size: size)
        #expect(self.near(elsewhere(CGPoint(x: 100, y: 300)), center))
        #expect(self.near(elsewhere(CGPoint(x: 100, y: 250)), tipped(CGPoint(x: 200, y: 150))))
        // The drawing it starts from is already turned as the design has it: its keys turn it on from there.
        let both = FilmLens.layer(center: center, rotation: 30, pose: pose { $0.turn = 60 }, camera: .rest, size: size)
        #expect(self.near(both(CGPoint(x: 250, y: 200)), CGPoint(x: 200 + 50 * cosine(60), y: 200 + 50 * sine(60))))
        // And it grows along its own sides, however the design has it turned: here its width runs down the artboard.
        let grown = FilmLens.layer(center: center, rotation: 90, pose: pose { $0.scale = CGPoint(x: 2, y: 1) }, camera: .rest, size: size)
        #expect(self.near(grown(CGPoint(x: 200, y: 250)), CGPoint(x: 200, y: 300)))
        #expect(self.near(grown(CGPoint(x: 250, y: 200)), CGPoint(x: 250, y: 200)))
        // The design's own turn in depth is added to for a layer drawn lying flat.
        var depth = Transform3D()
        depth.x = 20
        depth.z = 15
        let onTop = FilmLens.layer(center: center, rotation: 0, depth: depth, pose: pose { $0.tilt = 40; $0.lift = 25 }, camera: .rest, size: size)
        let whole = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.tilt = 60; $0.lift = 40 }, camera: .rest, size: size)
        for p in points { #expect(self.near(onTop(p), whole(p)), "\(p)") }
    }

    @Test func aLiftedLayerComesNearerAndShowsItsHeightOnlyToACameraAtAnAngle() {
        let center = CGPoint(x: 300, y: 100)
        // Seen straight on it is only nearer: bigger, and further from the middle of the frame by as much.
        let lifted = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.lift = 200 }, camera: .rest, size: size)
        let closer = far / (far - 200)
        #expect(near(lifted(center), CGPoint(x: 200 + 100 * closer, y: 200 - 100 * closer)))
        #expect(near(lifted.stretch(at: center), closer) && lifted.isFlat)
        #expect(near(lifted.depth(at: center), far - 200))
        // Sunk under the page it is further off and smaller.
        let sunk = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.lift = -200 }, camera: .rest, size: size)
        #expect(near(sunk.stretch(at: center), far / (far + 200)))
        // A layer lifted over the middle of the frame stays over it.
        let middle = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose { $0.lift = 200 }, camera: .rest, size: size)
        #expect(near(middle(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200)))
        // Under a camera tipped back it stands up off the page, toward the top of the frame;
        // under one swung round, off to the side the scene's right went away from.
        let tipped = camera { $0.tilt = 50 }
        let high = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose { $0.lift = 200 }, camera: tipped, size: size)
        let rise = 200 * sine(50) * far / (far - 200 * cosine(50))
        #expect(near(high(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200 - rise)))
        #expect(near(FilmLens.ground(tipped, size: size)(CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 200)))
        let swung = FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: pose { $0.lift = 200 }, camera: camera { $0.swing = 50 }, size: size)
        #expect(near(swung(CGPoint(x: 200, y: 200)), CGPoint(x: 200 + rise, y: 200)))
        // A sheet lying level above the artboard is where a layer lifted that high lies.
        let sheet = FilmLens.ground(tipped, size: size, height: 200)
        for p in points { #expect(near(sheet(p), FilmLens.layer(center: p, rotation: 0, pose: pose { $0.lift = 200 }, camera: tipped, size: size)(p)), "\(p)") }
    }

    @Test func whatIsLiftedPastTheEyeIsBehindItAndStillANumber() {
        let center = CGPoint(x: 150, y: 150)
        // Level with the eye, and past it.
        for lift in [far, far + 100, 4000] {
            let map = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.lift = lift }, camera: .rest, size: size)
            #expect(map.depth(at: center) <= 0, "lifted \(lift)")
            let shown = map(center)
            #expect(shown.x.isFinite && shown.y.isFinite, "lifted \(lift)")
            #expect(map.back(CGPoint(x: 200, y: 200)) == nil, "lifted \(lift)")
            #expect(map.stretch(at: center).isFinite, "lifted \(lift)")
        }
        // Just short of the eye it still shows, very big.
        let close = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.lift = far - 1 }, camera: .rest, size: size)
        #expect(close.depth(at: center) > 0 && near(close.stretch(at: center), far))
        // A film with such a layer in it still says how sharp its pictures must be.
        var flying = card("Flying", CGRect(x: 100, y: 100, width: 100, height: 100))
        flying.setKey(.lift, [0], at: 0)
        flying.setKey(.lift, [4000], at: 2)
        let b = board([flying])
        let stretch = b.filmStretch(of: b.filmPieces()[1], around: flying.frame)
        #expect(stretch.isFinite && stretch >= 1)
    }

    @Test func aPosedLayerShowsAsManyTimesBiggerAsItsLongerSideGrew() {
        let center = CGPoint(x: 200, y: 200)
        let wide = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.scale = CGPoint(x: 2, y: 0.5) }, camera: .rest, size: size)
        #expect(near(wide.stretch(at: center), 2) && wide.isFlat)
        let zoomed = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.scale = CGPoint(x: 2, y: 0.5) }, camera: camera { $0.zoom = 3 }, size: size)
        #expect(near(zoomed.stretch(at: center), 6))
        // Moved, turned and faded only, it is as big as drawn.
        let moved = FilmLens.layer(center: center, rotation: 0, pose: pose { $0.move = CGPoint(x: 50, y: 5); $0.turn = 70; $0.fade = 0.3 }, camera: .rest, size: size)
        #expect(near(moved.stretch(at: center), 1) && moved.isFlat)
    }

    // MARK: Pieces

    @Test func aGroupComesApartOnlyWhenNothingIsDoneToItAsAWhole() {
        let plain = group("Plain", [card()])
        #expect(plain.comesApart)
        #expect(!card().comesApart && !board().comesApart)
        let changes: [(String, (inout Node) -> Void)] = [
            ("masked", { $0.mask = [Node(kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 50, height: 50))] }),
            ("a mask that shows", { $0.clipsToFirst = true }),
            ("see-through", { $0.opacity = 0.5 }),
            ("blurred", { $0.blur = Blur(radius: 4) }),
            ("mixed in", { $0.blend = .multiply }),
            ("turned in depth", { $0.transform3D = Transform3D() }),
            ("shadowed", { $0.shadow.on = true }),
            ("shadowed again", { var s = Shadow(); s.on = true; $0.moreShadows = [s] }),
            ("a repeat grid", { $0.grid = RepeatGrid() }),
        ]
        for (name, change) in changes {
            var g = plain
            change(&g)
            #expect(!g.comesApart, "\(name)")
        }
        // What does nothing to it as a whole leaves it loose: a shadow that is off, a name, being locked.
        var g = plain
        g.moreShadows = [Shadow()]
        g.name = "Other"
        g.locked = true
        g.opacity = 0.9995
        #expect(g.comesApart)
    }

    @Test func hiddenLayersAreInNoPiece() {
        var hidden = card("Hidden")
        hidden.pose(.move, [10, 0], at: 1)
        hidden.hidden = true
        var inner = card("Inner")
        inner.pose(.fade, [0], at: 1)
        var hiddenGroup = group("Hidden group", [inner])
        hiddenGroup.hidden = true
        let one = card("One"), two = card("Two")
        let b = board([one, hidden, hiddenGroup, two])
        let pieces = b.filmPieces(loose: [hidden.id])
        // The two that show lie together, though hidden ones lie between them.
        #expect(pieces == [FilmPiece(kind: .ground), FilmPiece(kind: .run, layers: [one.id, two.id])])
        // It is a film all the same: what is hidden still has its keys.
        #expect(b.hasFilm)
    }

    @Test func groupsInGroupsComeApartDownToWhatMoves() {
        var moving = card("Moving", CGRect(x: 5, y: 5, width: 20, height: 20))
        moving.pose(.turn, [90], at: 1)
        let deep = card("Deep still", CGRect(x: 40, y: 5, width: 20, height: 20)), shallow = card("Shallow still", CGRect(x: 0, y: 100, width: 20, height: 20))
        let inner = group("Inner", at: CGPoint(x: 10, y: 20), [deep, moving, card("Deep above", CGRect(x: 80, y: 5, width: 20, height: 20))])
        let outer = group("Outer", at: CGPoint(x: 100, y: 50), [inner, shallow])
        let under = card("Under"), over = card("Over")
        let b = board([under, outer, over])
        let pieces = b.filmPieces()
        #expect(pieces.map(\.kind) == [.ground, .run, .run, .layer, .run, .run, .run])
        #expect(pieces[1].layers == [under.id] && pieces[1].holders.isEmpty && pieces[1].origin == .zero)
        #expect(pieces[2].layers == [deep.id] && pieces[2].holders == [outer.id, inner.id] && pieces[2].origin == CGPoint(x: 110, y: 70))
        #expect(pieces[3].layers == [moving.id] && pieces[3].holders == [outer.id, inner.id] && pieces[3].origin == CGPoint(x: 110, y: 70))
        #expect(!pieces[3].changes && !pieces[3].flat)
        #expect(pieces[4].layers == [inner.children[2].id] && pieces[4].holders == [outer.id, inner.id])
        #expect(pieces[5].layers == [shallow.id] && pieces[5].holders == [outer.id] && pieces[5].origin == CGPoint(x: 100, y: 50))
        #expect(pieces[6].layers == [over.id] && pieces[6].holders.isEmpty)
        // Every piece has a name of its own to be kept by, and every layer that shows is in exactly one.
        #expect(Set(pieces.map(\.key)).count == pieces.count)
        let drawn = pieces.flatMap(\.layers)
        #expect(Set(drawn).count == drawn.count && drawn.count == 6)
        // The moving layer shows where its groups put it.
        let placed = b.placement(of: pieces[3], at: 0, camera: .rest)
        #expect(near(placed.map(CGPoint(x: 125, y: 85)), CGPoint(x: 125, y: 85)))
        let turned = b.placement(of: pieces[3], at: 1, camera: .rest)
        #expect(near(turned.map(CGPoint(x: 135, y: 85)), CGPoint(x: 125, y: 95)))
    }

    /// The layers the pieces place, found in one walk for a stage that places them frame after
    /// frame, are the ones each would find on its own, and place each piece as that does.
    @Test func thePiecesLayersFoundTogetherPlaceThemAsEachFoundAlone() {
        var moving = card("Moving", CGRect(x: 5, y: 5, width: 20, height: 20))
        moving.pose(.turn, [90], at: 1)
        var lifted = card("Lifted", CGRect(x: 0, y: 100, width: 20, height: 20))
        lifted.pose(.lift, [60], at: 1)
        var fading = card("Fading", CGRect(x: 30, y: 30, width: 30, height: 30))
        fading.pose(.fade, [0.2], at: 1)
        let inner = group("Inner", at: CGPoint(x: 10, y: 20), [card("Deep still", CGRect(x: 40, y: 5, width: 20, height: 20)), moving])
        let outer = group("Outer", at: CGPoint(x: 100, y: 50), [inner, lifted])
        var b = board([card("Under"), outer, fading, card("Over")])
        b.pose(.cameraTilt, [20], at: 1)
        // The one the selection keeps apart, though nothing moves it.
        let picked = b.children[3].id
        let pieces = b.filmPieces(loose: [picked])
        let layers = b.filmLayers(of: pieces)
        #expect(layers.count == pieces.count)
        for (piece, layer) in zip(pieces, layers) {
            let alone = piece.kind == .layer ? piece.layers.first.flatMap { b.descendant($0) } : nil
            #expect(layer?.id == alone?.id && layer == alone, "\(piece.key)")
            for t in [0, 0.4, 1.0] {
                let camera = b.camera(at: t)
                #expect(b.placement(of: piece, layer: layer, at: t, camera: camera) == b.placement(of: piece, at: t, camera: camera))
            }
        }
        #expect(layers.compactMap { $0?.name } == ["Moving", "Lifted", "Fading", "Over"])
        // A piece whose layer is no longer there is placed as the ground is, as on its own.
        let gone = FilmPiece(kind: .layer, layers: [UUID()])
        #expect(b.filmLayers(of: [gone]) == [nil])
        #expect(b.placement(of: gone, layer: nil, at: 1, camera: b.camera(at: 1)) == b.placement(of: gone, at: 1, camera: b.camera(at: 1)))
    }

    /// A layer deep in a piece drawn again as what it holds moves shows where its groups pose,
    /// grow and turn it, whatever else they hold: posed along the way down alone, its corners are
    /// those of the layer in the whole group posed.
    @Test func aLayerInAPieceDrawnAgainShowsWhereItsWholeGroupPosesIt() throws {
        var target = card("Target", CGRect(x: 10, y: 15, width: 40, height: 30))
        target.pose(.move, [30, 10], at: 1)
        target.pose(.turn, [20], at: 1)
        var beside = card("Beside", CGRect(x: 80, y: 5, width: 20, height: 20))
        beside.pose(.move, [0, 60], at: 1)
        var inner = group("Inner", at: CGPoint(x: 20, y: 30), [target, beside])
        inner.frame.size = CGSize(width: 120, height: 80)
        inner.pose(.scale, [1.5, 0.8], at: 1)
        inner.pose(.turn, [-35], at: 1)
        var sibling = card("Sibling", CGRect(x: 150, y: 120, width: 30, height: 30))
        sibling.pose(.fade, [0.2], at: 1)
        // Faded as a whole, so drawn again as what it holds moves.
        var outer = group("Outer", at: CGPoint(x: 60, y: 40), [sibling, inner, card("Still", CGRect(x: 0, y: 150, width: 50, height: 20))])
        outer.opacity = 0.8
        var b = board([outer])
        b.pose(.cameraSwing, [25], at: 1)
        let pieces = b.filmPieces()
        let piece = try #require(pieces.first { $0.layers == [outer.id] })
        #expect(piece.changes)
        for t in [0, 0.35, 0.8, 1.0] {
            // The whole group posed, and the layer found in it.
            let whole = outer.posed(at: t, own: false)
            let posedInner = try #require(whole.children.first { $0.id == inner.id })
            let posedTarget = try #require(posedInner.children.first { $0.id == target.id })
            let origin = CGPoint(x: outer.frame.minX + posedInner.frame.minX, y: outer.frame.minY + posedInner.frame.minY)
            let map = b.placement(of: piece, at: t, camera: b.camera(at: t)).map
            let want = Geometry.corners(of: posedTarget.frame.offsetBy(dx: origin.x, dy: origin.y), rotation: posedTarget.rotation).map { map($0) }
            let got = try #require(b.filmCorners(of: target.id, at: t, pieces: pieces))
            for (a, w) in zip(got, want) { #expect(near(a, w, 1e-6), "at \(t): \(a) for \(w)") }
        }
    }

    @Test func aMovingGroupIsOnePieceWithWhatMovesInsideIt() {
        var inner = card("Inner", CGRect(x: 0, y: 0, width: 40, height: 40))
        inner.pose(.fade, [0], at: 1)
        var moving = group("Moving group", at: CGPoint(x: 50, y: 60), [inner, card("Beside", CGRect(x: 60, y: 0, width: 40, height: 40))])
        moving.frame.size = CGSize(width: 100, height: 40)
        moving.pose(.move, [30, 0], at: 1)
        let b = board([moving])
        let pieces = b.filmPieces()
        #expect(pieces.count == 2 && pieces[1].kind == .layer && pieces[1].layers == [moving.id])
        // Its drawing changes as time passes, for what moves inside it.
        #expect(pieces[1].changes)
        // It is placed by its own pose, about its own middle, and fades only by its own keys.
        let placed = b.placement(of: pieces[1], at: 1, camera: .rest)
        #expect(near(placed.map(CGPoint(x: 50, y: 60)), CGPoint(x: 80, y: 60)) && placed.opacity == 1)
        // Drawn for the piece, the group stays where it is and what it holds is posed.
        let drawn = moving.posed(at: 1, own: false)
        #expect(drawn.frame == moving.frame && drawn.children[0].opacity == 0 && drawn.children[1].opacity == 1)
        // Drawn whole, as for a still, it is moved too.
        #expect(moving.posed(at: 1).frame == moving.frame.offsetBy(dx: 30, dy: 0))
        // With nothing moving inside it, its drawing is made once.
        var simple = moving
        simple.children[0].motion = nil
        #expect(board([simple]).filmPieces()[1].changes == false)
    }

    @Test func aGroupThatIsMoreThanItsLayersStaysWholeAndIsDrawnAgainAsTheyMove() {
        var inner = card("Inner", CGRect(x: 10, y: 10, width: 40, height: 40))
        inner.pose(.move, [0, 20], at: 1)
        // A mask that shows, holding a layer that moves.
        var mask = group("Mask", at: CGPoint(x: 100, y: 100), [card("Shape", CGRect(x: 0, y: 0, width: 80, height: 80)), inner])
        mask.clipsToFirst = true
        // A group cut off by a shape, and a see-through one, each holding a layer that moves.
        var cut = group("Cut", at: CGPoint(x: 200, y: 100), [inner.with(id: UUID())])
        cut.mask = [Node(kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 50, height: 50))]
        var faint = group("Faint", at: CGPoint(x: 300, y: 100), [inner.with(id: UUID())])
        faint.opacity = 0.5
        let still = card("Still")
        let b = board([mask, still, cut, faint])
        let pieces = b.filmPieces()
        #expect(pieces.map(\.kind) == [.ground, .layer, .run, .layer, .layer])
        #expect(pieces[1].layers == [mask.id] && pieces[3].layers == [cut.id] && pieces[4].layers == [faint.id])
        #expect(pieces[1].changes && pieces[3].changes && pieces[4].changes)
        // With no keys of its own it is placed as the page is.
        let placed = b.placement(of: pieces[1], at: 1, camera: .rest)
        #expect(placed.map == FilmLens.layer(center: CGPoint(x: 200, y: 200), rotation: 0, pose: .rest, camera: .rest, size: size))
        for p in points { #expect(near(placed.map(p), p), "\(p)") }
        #expect(placed.opacity == 1 && placed.blur == 0 && placed.height == 0)
        // The same groups with nothing moving in them lie in a run with their neighbours.
        var quiet = b
        for i in quiet.children.indices { quiet.children[i] = quiet.children[i].withoutMotion }
        #expect(quiet.filmPieces().map(\.kind) == [.ground, .run])
        // A layer that blurs what lies behind it moves with its neighbours like any other.
        var glass = card("Glass")
        glass.blur = Blur(radius: 12, background: true)
        let behind = card("Behind").with { $0.pose(.move, [40, 0], at: 1) }
        let panes = board([card("Low"), glass, behind, card("High")]).filmPieces()
        #expect(panes.map(\.kind) == [.ground, .run, .layer, .run] && panes[1].layers.count == 2)
    }

    @Test func layersPickedAreKeptApartThoughNothingMovesThemYet() {
        let one = card("One"), two = card("Two"), three = card("Three")
        let inner = card("Inner")
        let holder = group("Holder", at: CGPoint(x: 20, y: 20), [inner, card("Other")])
        let b = board([one, two, three, holder])
        #expect(b.filmPieces().map(\.kind) == [.ground, .run])
        let picked = b.filmPieces(loose: [two.id])
        #expect(picked.map(\.kind) == [.ground, .run, .layer, .run] && picked[2].layers == [two.id] && !picked[2].changes)
        // One picked inside a group takes the group apart round it.
        let deep = b.filmPieces(loose: [inner.id])
        #expect(deep.map(\.kind) == [.ground, .run, .layer, .run])
        #expect(deep[2].layers == [inner.id] && deep[2].holders == [holder.id] && deep[2].origin == CGPoint(x: 20, y: 20))
        // A group picked is one piece, whole.
        let whole = b.filmPieces(loose: [holder.id])
        #expect(whole.map(\.kind) == [.ground, .run, .layer] && whole[2].layers == [holder.id])
        // A layer not on the artboard keeps nothing apart.
        #expect(b.filmPieces(loose: [UUID()]) == b.filmPieces())
    }

    @Test func aLayerTurnedInDepthByTheDesignStandsInTheSceneWhereTheDesignHasIt() {
        var depth = Transform3D()
        depth.x = 30
        depth.z = 12
        var tipping = card("Tipping")
        tipping.transform3D = depth
        tipping.setKey(.tilt, [20], at: 0)
        tipping.setKey(.lift, [8], at: 0)
        var sliding = card("Sliding")
        sliding.transform3D = depth
        sliding.setKey(.move, [20, 0], at: 0)
        var pinned = card("Pinned")
        pinned.transform3D = Transform3D(corners: [CGPoint(x: 0.1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        pinned.setKey(.tilt, [20], at: 0)
        var level = card("Level")
        level.setKey(.swing, [20], at: 0)
        var still = card("Still")
        still.transform3D = depth
        let b = board([tipping, sliding, pinned, level, still])
        let pieces = b.filmPieces()
        // Turned or lifted by the design, keys or none, a layer is drawn flat for the film to turn
        // and lift in the scene, as the design sees it (`Eye.stage`). A screen pinned into a photo
        // keeps the look it has; with nothing of the design to turn, there is nothing to leave out.
        #expect(pieces.dropFirst().map(\.flat) == [true, true, false, false, true])
        #expect(pieces[1].key.hasSuffix("/flat") && pieces[2].key.hasSuffix("/flat") && !pieces[3].key.hasSuffix("/flat"))
        // Drawn flat, the film turns it by the design's turn and its keys' together, and it lies as
        // high as both lift it.
        let placed = b.placement(of: pieces[1], at: 0, camera: .rest)
        #expect(placed.height == 20)
        #expect(placed.map == FilmLens.layer(center: tipping.center, rotation: 0, depth: depth, pose: tipping.pose(at: 0), camera: .rest, size: size))
        // Its keys only move it: it stands as high as the design holds it, turned as the design turns it.
        let slid = b.placement(of: pieces[2], at: 0, camera: .rest)
        #expect(slid.height == 12)
        #expect(slid.map == FilmLens.layer(center: sliding.center, rotation: 0, depth: depth, pose: sliding.pose(at: 0), camera: .rest, size: size))
        // No keys at all: a piece of its own all the same, where the design has it.
        let stood = b.placement(of: pieces[5], at: 0, camera: .rest)
        #expect(stood.height == 12 && !stood.map.isFlat)
    }

    @Test func aPieceIsPlacedFadedBlurredAndLiftedAsItsLayerIsPosed() {
        var n = card("Posed", CGRect(x: 100, y: 100, width: 100, height: 50))
        n.rotation = 90
        for (p, from, to) in [(MotionProperty.fade, [1.0], [0.2]), (.blur, [0], [10]), (.lift, [0], [100]), (.scale, [1, 1], [3, 1])] {
            n.setKey(p, from, at: 0)
            n.setKey(p, to, at: 2, ease: .linear)
        }
        let still = card("Still")
        let b = board([still, n])
        let pieces = b.filmPieces()
        let start = b.placement(of: pieces[2], at: 0, camera: .rest), half = b.placement(of: pieces[2], at: 1, camera: .rest)
        #expect(start.opacity == 1 && start.blur == 0 && start.height == 0)
        #expect(near(half.opacity, 0.6) && near(half.blur, 5) && near(half.height, 50))
        // Turned a quarter by the design, its own width runs down the page: twice as wide there, it
        // is twice as tall here, and nearer by its lift.
        let closer = far / (far - 50)
        #expect(near(half.map(CGPoint(x: 150, y: 125)), CGPoint(x: 200 + (150 - 200) * closer, y: 200 + (125 - 200) * closer)))
        #expect(near(half.map(CGPoint(x: 150, y: 135)).y - half.map(CGPoint(x: 150, y: 125)).y, 20 * closer))
        #expect(near(half.map(CGPoint(x: 160, y: 125)).x - half.map(CGPoint(x: 150, y: 125)).x, 10 * closer))
        // The ground and a run of still layers are placed as the camera sees the page, whole.
        let seen = camera { $0.zoom = 2; $0.tilt = 30 }
        for piece in pieces.prefix(2) {
            let placed = b.placement(of: piece, at: 1, camera: seen)
            #expect(placed.map == FilmLens.ground(seen, size: size) && placed.opacity == 1 && placed.blur == 0 && placed.height == 0)
        }
        // A piece whose layer has gone is placed as the page, and stops nothing.
        #expect(b.placement(of: FilmPiece(kind: .layer, layers: [UUID()]), at: 1, camera: seen).map == FilmLens.ground(seen, size: size))
    }

    @Test func piecesAreDrawnAsTheyLieUntilSomethingIsLiftedThenTheHigherCovers() {
        func lifting(_ name: String, to height: Double) -> Node {
            var n = card(name)
            n.setKey(.lift, [0], at: 0)
            n.setKey(.lift, [height], at: 1, ease: .linear)
            return n
        }
        let high = lifting("High", to: 80), low = lifting("Low", to: 30), sunk = lifting("Sunk", to: -30), level = lifting("Level", to: 0)
        let b = board([card("Under"), high, card("Between"), low, sunk, level, card("Over")])
        let pieces = b.filmPieces()
        #expect(pieces.map(\.kind) == [.ground, .run, .layer, .run, .layer, .layer, .layer, .run])
        func order(at t: Double) -> [Int] { b.filmOrder(pieces, pieces.map { b.placement(of: $0, at: t, camera: .rest) }) }
        // With nothing lifted, as they lie.
        #expect(order(at: 0) == Array(0..<8))
        // Lifted, the lowest first: the page itself is the backdrop, under all, what is sunk under
        // the page next, what lies on it stays in its order, and the highest is drawn last.
        #expect(order(at: 1) == [0, 5, 1, 3, 6, 7, 4, 2])
        // Half way they are already in that order.
        #expect(order(at: 0.5) == [0, 5, 1, 3, 6, 7, 4, 2])
        // Two as high as each other keep the order they lie in.
        let twins = board([lifting("First", to: 40), lifting("Second", to: 40)])
        let twinPieces = twins.filmPieces()
        #expect(twins.filmOrder(twinPieces, twinPieces.map { twins.placement(of: $0, at: 1, camera: .rest) }) == [0, 1, 2])
    }

    @Test func howSharpAPiecesPictureMustBeFollowsTheWholeFilm() {
        var growing = card("Growing", CGRect(x: 150, y: 150, width: 100, height: 100))
        growing.setKey(.scale, [1, 1], at: 0)
        growing.setKey(.scale, [1, 2.5], at: 1, ease: .linear)
        growing.setKey(.scale, [1, 1], at: 2, ease: .linear)
        var b = board([card("Still"), growing])
        let pieces = b.filmPieces()
        // The most it grows at any moment, though it ends as it began.
        #expect(near(b.filmStretch(of: pieces[2], around: growing.frame), 2.5, 0.01))
        #expect(near(b.filmStretch(of: pieces[1], around: CGRect(x: 0, y: 0, width: 400, height: 400)), 1))
        // The camera coming closer makes everything bigger, the still layers too.
        b.setKey(.cameraZoom, [1], at: 0)
        b.setKey(.cameraZoom, [4], at: 2, ease: .linear)
        #expect(near(b.filmStretch(of: pieces[1], around: CGRect(x: 0, y: 0, width: 400, height: 400)), 4, 0.01))
        #expect(b.filmStretch(of: pieces[2], around: growing.frame) > 4)
        // Never less than as drawn, however small it shows.
        var shrinking = board([card()])
        shrinking.setKey(.cameraZoom, [0.2], at: 0)
        #expect(shrinking.filmStretch(of: shrinking.filmPieces()[1], around: CGRect(x: 0, y: 0, width: 400, height: 400)) == 1)
    }

    // MARK: Found and outlined in the film

    @Test func aPressFindsWhatShowsThereAndWhatHoldsIt() {
        var inner = card("Inner", CGRect(x: 0, y: 0, width: 50, height: 50))
        inner.setKey(.move, [20, 0], at: 0)
        let holder = group("Holder", at: CGPoint(x: 100, y: 100), [inner, card("Beside", CGRect(x: 0, y: 100, width: 50, height: 50))])
        var faded = card("Faded", CGRect(x: 300, y: 300, width: 50, height: 50))
        faded.setKey(.fade, [0], at: 0)
        var lifted = card("Lifted", CGRect(x: 10, y: 10, width: 60, height: 60))
        lifted.setKey(.lift, [100], at: 0)
        let b = board([lifted, card("Cover", CGRect(x: 0, y: 0, width: 90, height: 90)), holder, faded])
        let pieces = b.filmPieces()
        // The layer in the group, where it shows, then the group that holds it.
        #expect(b.filmChain(at: CGPoint(x: 165, y: 125), time: 0, pieces: pieces, tolerance: 2).map(\.name) == ["Inner", "Holder"])
        #expect(b.filmChain(at: CGPoint(x: 110, y: 125), time: 0, pieces: pieces, tolerance: 2).isEmpty)
        #expect(b.filmChain(at: CGPoint(x: 125, y: 225), time: 0, pieces: pieces, tolerance: 2).map(\.name) == ["Beside", "Holder"])
        // What has faded away is not there to press.
        #expect(b.filmChain(at: CGPoint(x: 325, y: 325), time: 0, pieces: pieces, tolerance: 2).isEmpty)
        // What is lifted is on top, though it lies under the other in the design.
        #expect(b.filmChain(at: CGPoint(x: 40, y: 40), time: 0, pieces: pieces, tolerance: 2).first?.name == "Lifted")
        // Its outline follows it: the layer in the group, moved by its own keys.
        let corners = b.filmCorners(of: inner.id, at: 0, pieces: pieces)
        #expect(corners.map { near($0[0], CGPoint(x: 120, y: 100)) && near($0[2], CGPoint(x: 170, y: 150)) } == true)
        #expect(b.filmCorners(of: UUID(), at: 0, pieces: pieces) == nil)
    }

    @Test func aLayerPosedForDrawingTakesEveryPropertyOntoWhatItIs() {
        var n = card("Posed", CGRect(x: 100, y: 100, width: 100, height: 50))
        n.rotation = 30
        n.opacity = 0.5
        n.blur = Blur(radius: 3)
        var depth = Transform3D()
        depth.x = 10
        depth.y = 5
        depth.z = 2
        n.transform3D = depth
        n.setKey(.turn, [15], at: 0)
        n.setKey(.fade, [0.5], at: 0)
        n.setKey(.blur, [4], at: 0)
        n.setKey(.tilt, [20], at: 0)
        n.setKey(.swing, [-5], at: 0)
        n.setKey(.lift, [8], at: 0)
        let posed = n.posed(at: 0)
        #expect(posed.rotation == 45 && near(posed.opacity, 0.25) && posed.blur?.radius == 7)
        #expect(posed.transform3D?.x == 30 && posed.transform3D?.y == 0 && posed.transform3D?.z == 10)
        #expect(posed.frame == n.frame)
        // A group grown takes what it holds with it, about its middle.
        var g = group("Group", at: CGPoint(x: 100, y: 100), [card("In", CGRect(x: 0, y: 0, width: 50, height: 100)), card("Also", CGRect(x: 50, y: 0, width: 50, height: 100))])
        g.frame.size = CGSize(width: 100, height: 100)
        g.setKey(.scale, [2, 1], at: 0)
        let grown = g.posed(at: 0)
        #expect(grown.frame == CGRect(x: 50, y: 100, width: 200, height: 100))
        #expect(grown.children.map(\.frame) == [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)])
        // Faded past nothing or blurred by next to nothing, it stays a layer that can be drawn.
        var faint = card()
        faint.opacity = 0.3
        faint.setKey(.blur, [0.01], at: 0)
        #expect(faint.posed(at: 0).blur == nil && faint.posed(at: 0).opacity == 0.3)
        // A layer with no keys, and one before any of its properties leave the design, is itself.
        #expect(card().with(id: n.id).posed(at: 3) == card().with(id: n.id))
        var later = card()
        later.pose(.move, [40, 0], at: 1)
        #expect(later.posed(at: 0) == later)
    }
}
