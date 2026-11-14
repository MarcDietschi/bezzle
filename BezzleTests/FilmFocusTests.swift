import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// Depth of field as arithmetic: how far a thing stands off the camera's focus, and the blur
/// that gives it across the frame, for distances worked out by hand under a camera at rest,
/// tipped, swung and close.
@MainActor
struct FilmFocusTests {
    private let size = CGSize(width: 400, height: 300)
    /// How far the camera rests above an artboard of `size`: twice its larger side.
    private let far = 800.0

    private func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }
    private func sine(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
    private func cosine(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }

    private func camera(_ change: (inout FilmCamera) -> Void) -> FilmCamera {
        var c = FilmCamera()
        change(&c)
        return c
    }

    private func board(_ children: [Node] = []) -> Node {
        var b = Node(kind: .artboard, name: "A", frame: CGRect(origin: CGPoint(x: 700, y: 50), size: size))
        b.children = children
        return b
    }

    private func card(_ name: String, _ frame: CGRect, lifted: CGFloat = 0) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        if lifted != 0 { n.transform3D = Transform3D(x: 0, y: 0, z: lifted) }
        return n
    }

    // MARK: At rest

    @Test func aCameraThatBlursNothingLeavesEveryPieceWithoutABlur() {
        let b = board([card("Flat", CGRect(x: 20, y: 20, width: 60, height: 40)), card("High", CGRect(x: 200, y: 100, width: 60, height: 40), lifted: 100)])
        let pieces = b.filmPieces()
        #expect(pieces.count == 3)
        for seen in [FilmCamera.rest, camera { $0.tilt = 40; $0.zoom = 2 }, camera { $0.focus = 120 }] {
            for piece in pieces { #expect(b.placement(of: piece, at: 0, camera: seen).soft == nil) }
        }
        // Its other numbers are what they were: asking for the blur changes no place.
        let tipped = camera { $0.tilt = 40; $0.zoom = 2 }, soft = camera { $0.tilt = 40; $0.zoom = 2; $0.blur = 12; $0.focus = 30 }
        for piece in pieces {
            var with = b.placement(of: piece, at: 0, camera: soft)
            #expect(with.soft != nil)
            with.soft = nil
            #expect(with == b.placement(of: piece, at: 0, camera: tipped))
        }
    }

    @Test func atRestWithNothingLiftedNothingIsBlurredHoweverMuchItBlurs() throws {
        let b = board([card("Flat", CGRect(x: 20, y: 20, width: 60, height: 40))])
        let seen = camera { $0.blur = 100 }
        for piece in b.filmPieces() {
            let soft = try #require(b.placement(of: piece, at: 0, camera: seen).soft)
            #expect(soft.across == 0 && soft.down == 0 && near(soft.level, 0, 1e-9))
            #expect(soft.range(in: CGRect(origin: .zero, size: size)).most < 1e-9)
        }
    }

    @Test func aLiftedLayerIsBlurredByHowFarItStandsOffThePage() throws {
        let b = board([card("Flat", CGRect(x: 20, y: 20, width: 60, height: 40)), card("High", CGRect(x: 200, y: 100, width: 60, height: 40), lifted: 100),
                       card("Sunk", CGRect(x: 300, y: 200, width: 60, height: 40), lifted: -100)])
        let pieces = b.filmPieces()
        let seen = camera { $0.blur = 10 }
        // A tenth of a point of blur for each point off the focus: ten of its own points for a
        // hundred, and the layer shows 800 / 700 as large for being nearer.
        let high = try #require(b.placement(of: pieces[2], at: 0, camera: seen).soft)
        #expect(high.across == 0 && high.down == 0)
        #expect(near(high.blur(at: CGPoint(x: 230, y: 120)), 10 * far / (far - 100)))
        // As far behind the page, as blurred in its own points, and shown smaller.
        let sunk = try #require(b.placement(of: pieces[3], at: 0, camera: seen).soft)
        #expect(near(sunk.blur(at: .zero), 10 * far / (far + 100)))
        // Sharp on the lifted layer instead, the page is a hundred off, and shows at its own size.
        let lifted = camera { $0.blur = 10; $0.focus = 100 }
        #expect(near(try #require(b.placement(of: pieces[2], at: 0, camera: lifted).soft).blur(at: .zero), 0, 1e-9))
        #expect(near(try #require(b.placement(of: pieces[0], at: 0, camera: lifted).soft).blur(at: CGPoint(x: 10, y: 290)), 10))
        #expect(near(try #require(b.placement(of: pieces[3], at: 0, camera: lifted).soft).blur(at: .zero), 20 * far / (far + 100)))
        // Twice the blur, twice as blurred.
        #expect(near(try #require(b.placement(of: pieces[2], at: 0, camera: camera { $0.blur = 20 }).soft).blur(at: .zero), 20 * far / (far - 100)))
    }

    @Test func aLayerLiftedByItsKeysIsAsBlurredAsOneLiftedByTheDesign() throws {
        var keyed = card("Keyed", CGRect(x: 200, y: 100, width: 60, height: 40))
        keyed.setKey(.lift, [0], at: 0)
        keyed.setKey(.lift, [100], at: 1, ease: .linear)
        let b = board([keyed])
        let piece = b.filmPieces()[1]
        let seen = camera { $0.blur = 10 }
        #expect(near(try #require(b.placement(of: piece, at: 0, camera: seen).soft).blur(at: .zero), 0, 1e-9))
        #expect(near(try #require(b.placement(of: piece, at: 0.5, camera: seen).soft).blur(at: .zero), 5 * far / (far - 50)))
        #expect(near(try #require(b.placement(of: piece, at: 1, camera: seen).soft).blur(at: .zero), 10 * far / (far - 100)))
    }

    // MARK: Tipped and swung

    @Test func underACameraTippedBackTheSheetIsSharpAcrossItsMiddleAndSofterToTopAndFoot() throws {
        let seen = camera { $0.tilt = 30; $0.blur = 10 }
        let ground = FilmLens.ground(seen, size: size)
        let soft = try #require(FilmLens.soft(of: ground, camera: seen, size: size))
        // Level across: the same blur from side to side.
        #expect(near(soft.across, 0, 1e-12) && soft.down != 0)
        // The line across the sheet's middle is where the camera looks: sharp.
        #expect(near(soft.blur(at: ground(CGPoint(x: 0, y: 150))), 0, 1e-9) && near(soft.blur(at: ground(CGPoint(x: 400, y: 150))), 0, 1e-9))
        // The sheet's foot has come nearer by half of the 150 points it is from the middle: 75
        // off the focus is 7.5 points of its own, shown 800 / 725 as large.
        let foot = ground(CGPoint(x: 200, y: 300))
        #expect(near(Double(foot.y), 150 + far * 150 * cosine(30) / (far - 75)))
        #expect(near(soft.blur(at: foot), 7.5 * far / (far - 75)))
        // Its top has gone as far away: as blurred in its own points, and shown smaller.
        let top = ground(CGPoint(x: 200, y: 0))
        #expect(near(soft.blur(at: top), 7.5 * far / (far + 75)))
        // Between, in step with the distance: a third of the way down from the middle, 2.5 points.
        #expect(near(soft.blur(at: ground(CGPoint(x: 80, y: 200))), 2.5 * far / (far - 25)))
        #expect(near(FilmLens.nearness(of: CGPoint(x: 80, y: 200), in: ground, camera: seen, size: size), 25))
        // Within the frame it is sharp somewhere and at its softest in a corner.
        let range = soft.range(in: CGRect(origin: .zero, size: size))
        #expect(range.least == 0 && near(range.most, soft.blur(at: CGPoint(x: 0, y: 300))))
        // The line that is sharp, on the sheet: level, through its middle.
        let line = try #require(FilmLens.sharpLine(of: CGRect(origin: .zero, size: size), in: ground, camera: seen, size: size))
        #expect(near(Double(line.0.y), 150) && near(Double(line.1.y), 150) && abs(line.0.x - line.1.x) == 400)
        // Sharp on what is 50 nearer instead: the line lies where the sheet is 50 nearer, 100 down from its middle.
        let nearer = camera { $0.tilt = 30; $0.blur = 10; $0.focus = 50 }
        let moved = try #require(FilmLens.sharpLine(of: CGRect(origin: .zero, size: size), in: ground, camera: nearer, size: size))
        #expect(near(Double(moved.0.y), 250) && near(Double(moved.1.y), 250))
        #expect(near(try #require(FilmLens.soft(of: ground, camera: nearer, size: size)).blur(at: ground(CGPoint(x: 30, y: 250))), 0, 1e-9))
        // A camera that faces the sheet has no such line: all of it is as far.
        #expect(FilmLens.sharpLine(of: CGRect(origin: .zero, size: size), in: FilmLens.ground(.rest, size: size), camera: .rest, size: size) == nil)
    }

    @Test func underACameraSwungRoundTheSheetIsSofterToItsSides() throws {
        let seen = camera { $0.swing = 30; $0.blur = 10 }
        let ground = FilmLens.ground(seen, size: size)
        let soft = try #require(FilmLens.soft(of: ground, camera: seen, size: size))
        #expect(near(soft.down, 0, 1e-12) && soft.across != 0)
        // Its right side has gone away by half of the 200 points it is from the middle.
        #expect(near(FilmLens.nearness(of: CGPoint(x: 400, y: 40), in: ground, camera: seen, size: size), -100))
        #expect(near(soft.blur(at: ground(CGPoint(x: 400, y: 40))), 10 * far / (far + 100)))
        #expect(near(soft.blur(at: ground(CGPoint(x: 0, y: 280))), 10 * far / (far - 100)))
        #expect(near(soft.blur(at: ground(CGPoint(x: 200, y: 10))), 0, 1e-9))
    }

    @Test func aLayerStandingOffASheetThatIsTippedIsBlurredByItsOwnDistance() throws {
        // On the sheet 100 below its middle, and lifted 100: under a camera tipped back 30° it
        // stands 100 sin 30° nearer for where it lies and 100 cos 30° nearer for its lift.
        let b = board([card("High", CGRect(x: 170, y: 230, width: 60, height: 40), lifted: 100)])
        let seen = camera { $0.tilt = 30; $0.blur = 10 }
        let piece = b.filmPieces()[1]
        let placed = b.placement(of: piece, at: 0, camera: seen)
        let soft = try #require(placed.soft)
        let off = 100 * sine(30) + 100 * cosine(30)
        #expect(near(FilmLens.nearness(of: CGPoint(x: 200, y: 250), in: placed.map, camera: seen, size: size), off))
        #expect(near(soft.blur(at: placed.map(CGPoint(x: 200, y: 250))), off / 10 * far / (far - off)))
        // Sharp there, its middle is sharp and its foot, 20 further down the tipped sheet, 10 nearer still.
        let sharp = camera { $0.tilt = 30; $0.blur = 10; $0.focus = off }
        let there = b.placement(of: piece, at: 0, camera: sharp)
        #expect(near(try #require(there.soft).blur(at: there.map(CGPoint(x: 200, y: 250))), 0, 1e-9))
        #expect(near(try #require(there.soft).blur(at: there.map(CGPoint(x: 200, y: 270))), 1 * far / (far - off - 10)))
    }

    // MARK: Closer, and looking elsewhere

    @Test func aCameraThatComesCloserStaysSharpOnWhatItLooksAtAndBlursTheRestAsMuchInItsOwnPoints() throws {
        let b = board([card("High", CGRect(x: 200, y: 100, width: 60, height: 40), lifted: 100)])
        let pieces = b.filmPieces()
        let close = camera { $0.zoom = 2; $0.blur = 10 }
        // The page it looks at is still sharp.
        #expect(near(try #require(b.placement(of: pieces[0], at: 0, camera: close).soft).blur(at: CGPoint(x: 77, y: 12)), 0, 1e-9))
        // The lifted layer is a hundred points off, as before: ten points of its own, which the
        // camera now shows 2 * 800 / 600 as large.
        let placed = b.placement(of: pieces[1], at: 0, camera: close)
        #expect(near(FilmLens.nearness(of: CGPoint(x: 230, y: 120), in: placed.map, camera: close, size: size), 100))
        #expect(near(try #require(placed.soft).blur(at: .zero), 10 * 2 * far / (far - 200)))
        // Sharp on it at a hundred, close or not.
        #expect(near(try #require(b.placement(of: pieces[1], at: 0, camera: camera { $0.zoom = 2; $0.blur = 10; $0.focus = 100 }).soft).blur(at: .zero), 0, 1e-9))
        // Looking elsewhere, rolled: what lies in the page is as far as ever.
        let aside = camera { $0.x = 120; $0.y = -60; $0.roll = 35; $0.blur = 10 }
        #expect(near(try #require(b.placement(of: pieces[0], at: 0, camera: aside).soft).blur(at: CGPoint(x: 300, y: 20)), 0, 1e-9))
        #expect(near(try #require(b.placement(of: pieces[1], at: 0, camera: aside).soft).blur(at: .zero), 10 * far / (far - 100)))
    }

    @Test func theBlurIsHowFarAPointStandsOffTheFocusWhereverTheCameraIs() throws {
        // Any plane under any camera: at the point of the frame where a point of it shows, the
        // blur is a hundredth of the camera's for every point the point stands off the focus,
        // shown as many times larger as a thing at its distance is.
        var seed: UInt64 = 0x5EED
        func random(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + (range.upperBound - range.lowerBound) * Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<200 {
            let seen = camera {
                $0.x = random(-150...150); $0.y = random(-100...100); $0.zoom = random(0.3...6); $0.roll = random(-180...180)
                $0.tilt = random(-70...70); $0.swing = random(-70...70); $0.focus = random(-300...120); $0.blur = random(0.5...40)
            }
            var pose = MotionPose()
            pose.lift = random(-200...100)
            pose.tilt = random(-60...60)
            pose.swing = random(-60...60)
            pose.turn = random(-180...180)
            pose.move = CGPoint(x: random(-80...80), y: random(-80...80))
            let center = CGPoint(x: random(50...350), y: random(50...250))
            let map = FilmLens.layer(center: center, rotation: random(-90...90), pose: pose, camera: seen, size: size)
            let soft = try #require(FilmLens.soft(of: map, camera: seen, size: size))
            for _ in 0..<4 {
                let p = CGPoint(x: Double(center.x) + random(-40...40), y: Double(center.y) + random(-40...40))
                let depth = map.depth(at: p)
                // In front of the eye, where it shows at all, and not so nearly edge on that
                // where it shows is no longer told to the millionth of a point.
                guard depth > 20, let back = map.back(map(p)), hypot(back.x - p.x, back.y - p.y) < 1e-8 else { continue }
                let off = abs(FilmLens.nearness(of: p, in: map, camera: seen, size: size) - seen.focus)
                let shown = seen.blur / 100 * off * seen.zoom * far / depth
                guard shown < FilmSoft.most else { continue }
                let got = soft.blur(at: map(p))
                #expect(abs(got - shown) < 1e-6 * max(1, shown), "\(seen) \(pose): \(got) against \(shown)")
            }
        }
    }

    // MARK: Pieces in one plane, and the most

    @Test func piecesLyingInOnePlaneHaveOneBlurAndThoseStandingOffItAnother() throws {
        var sliding = card("Sliding", CGRect(x: 40, y: 40, width: 60, height: 40))
        sliding.setKey(.move, [0, 0], at: 0)
        sliding.setKey(.move, [200, 90], at: 1)
        sliding.setKey(.turn, [0], at: 0)
        sliding.setKey(.turn, [70], at: 1)
        sliding.setKey(.scale, [1, 1], at: 0)
        sliding.setKey(.scale, [2, 0.5], at: 1)
        let b = board([card("Flat", CGRect(x: 20, y: 200, width: 60, height: 40)), sliding, card("High", CGRect(x: 200, y: 100, width: 60, height: 40), lifted: 30)])
        let pieces = b.filmPieces()
        #expect(pieces.map(\.kind) == [.ground, .run, .layer, .layer])
        let seen = camera { $0.tilt = 35; $0.swing = -20; $0.roll = 10; $0.zoom = 1.4; $0.blur = 8; $0.focus = 20 }
        for t in [0.0, 0.4, 1] {
            let soft = try pieces.map { try #require(b.placement(of: $0, at: t, camera: seen).soft) }
            // The sheet, what lies still on it and what slides, turns and grows in it: one plane.
            #expect(soft[1] == soft[0] && soft[2].matches(soft[0], in: size), "\(t)")
            #expect(!soft[3].matches(soft[0], in: size))
        }
    }

    @Test func nothingIsBlurredByMoreThanALayersOwnBlurGoesTo() throws {
        let b = board([card("High", CGRect(x: 200, y: 100, width: 60, height: 40), lifted: 700)])
        let seen = camera { $0.blur = 100 }
        let soft = try #require(b.placement(of: b.filmPieces()[1], at: 0, camera: seen).soft)
        #expect(soft.level > FilmSoft.most && soft.blur(at: .zero) == FilmSoft.most)
        #expect(soft.range(in: CGRect(origin: .zero, size: size)).most == FilmSoft.most)
        // A thing seen edge on shows nothing, and has no blur to say.
        var edge = FilmMap()
        edge.a = 0; edge.d = 0
        #expect(edge.inverse == nil && FilmLens.soft(of: edge, camera: seen, size: size) == nil)
    }

    // MARK: What to be sharp at

    @Test func whatToBeSharpAtForALayerIsHowMuchNearerItsMiddleStands() throws {
        let flat = card("Flat", CGRect(x: 170, y: 230, width: 60, height: 40))
        let high = card("High", CGRect(x: 20, y: 130, width: 60, height: 40), lifted: 100)
        var held = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 0, width: 200, height: 100))
        held.children = [card("Inside", CGRect(x: 80, y: 20, width: 40, height: 40))]
        var b = board([flat, high, held])
        var pieces = b.filmPieces()
        // At rest: what lies in the page is where the camera looks, and what is lifted, that much nearer.
        #expect(b.focus(on: [flat.id], at: 0, pieces: pieces) == 0)
        #expect(b.focus(on: [high.id], at: 0, pieces: pieces) == 100)
        #expect(b.focus(on: [held.children[0].id], at: 0, pieces: pieces) == 0)
        // Two at different distances: half way between them.
        #expect(b.focus(on: [flat.id, high.id], at: 0, pieces: pieces) == 50)
        #expect(b.focus(on: [UUID()], at: 0, pieces: pieces) == nil && b.focus(on: [], at: 0, pieces: pieces) == nil)
        // Under a camera tipped back 30°: 100 below the sheet's middle is 50 nearer; the lifted one
        // lies level with the middle, and is nearer by its lift as the camera sees it; the one in
        // the group lies 110 above the middle, and is 55 further.
        b.setKey(.cameraTilt, [30], at: 0)
        pieces = b.filmPieces()
        #expect(b.focus(on: [flat.id], at: 0, pieces: pieces) == 50)
        #expect(b.focus(on: [high.id], at: 0, pieces: pieces) == (100 * cosine(30)).rounded())
        #expect(b.focus(on: [held.children[0].id], at: 0, pieces: pieces) == -55)
        // Closer, the same: the distances are the scene's own.
        b.setKey(.cameraZoom, [3], at: 0)
        #expect(b.focus(on: [flat.id], at: 0, pieces: pieces) == 50)
        // Looking at it, it is where the camera looks.
        b.setKey(.cameraMove, [0, 100], at: 0)
        #expect(b.focus(on: [flat.id], at: 0, pieces: pieces) == 0)
        // Where its keys have it at that moment: lifted 80 half way through.
        var rising = flat
        rising.setKey(.lift, [0], at: 0)
        rising.setKey(.lift, [160], at: 2, ease: .linear)
        var c = board([rising])
        c.setKey(.cameraSwing, [0], at: 0)
        #expect(c.focus(on: [rising.id], at: 1, pieces: c.filmPieces()) == 80)
    }

    /// A group that keeps its layers' depth is no card: each layer in it stands where the group
    /// and its own lift put it, and is blurred by that.
    @Test func inAGroupThatKeepsItsLayersDepthEachLayerIsBlurredByWhereItStands() throws {
        let low = card("Low", CGRect(x: 0, y: 0, width: 60, height: 40))
        let high = card("High", CGRect(x: 80, y: 0, width: 60, height: 40), lifted: 100)
        var held = Node(kind: .group, name: "Held", frame: CGRect(x: 130, y: 130, width: 140, height: 40))
        held.children = [low, high]
        held.transform3D = Transform3D(x: 0, y: 0, z: 50)
        held.keepsDepth = true
        let b = board([held])
        let pieces = b.filmPieces()
        // Sharp at 50, where the group holds its own page: the layer in that page is sharp, and
        // the one a hundred above it has ten of its own points of blur, shown 800 / 650 as large.
        let seen = camera { $0.blur = 10; $0.focus = 50 }
        func soft(_ id: UUID) throws -> FilmSoft {
            let piece = try #require(pieces.last { $0.layers.contains(id) })
            return try #require(b.placement(of: piece, at: 0, camera: seen).soft)
        }
        #expect(try soft(low.id).range(in: CGRect(origin: .zero, size: size)).most < 1e-6)
        #expect(try near(soft(high.id).blur(at: CGPoint(x: 200, y: 150)), 10 * far / (far - 150), 1e-6))
        #expect(b.focus(on: [low.id], at: 0, pieces: pieces) == 50 && b.focus(on: [high.id], at: 0, pieces: pieces) == 150)
        // As a card, the group is one flat picture where it is held: all of it at 50.
        var flat = b
        flat.children[0].keepsDepth = nil
        let whole = flat.filmPieces()
        let piece = try #require(whole.last { $0.layers.contains(held.id) })
        #expect(try #require(flat.placement(of: piece, at: 0, camera: seen).soft).range(in: CGRect(origin: .zero, size: size)).most < 1e-6)
    }
}
