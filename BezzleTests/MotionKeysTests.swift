import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// What posing, keying, moving and shifting keys leave behind on a layer, what a layer says of its
/// own motion and an artboard of its film, and the moves made in one go: past what `MotionTests` shows.
@MainActor
struct MotionKeysTests {
    private func card(_ name: String = "Card", _ frame: CGRect = CGRect(x: 100, y: 80, width: 120, height: 60)) -> Node {
        Node(kind: .rectangle, name: name, frame: frame)
    }

    private func board(_ children: [Node] = [], size: CGSize = CGSize(width: 400, height: 300)) -> Node {
        var b = Node(kind: .artboard, name: "A", frame: CGRect(origin: .zero, size: size))
        b.children = children
        return b
    }

    // MARK: Posing

    @Test func theFirstPoseAtTheStartFliesHomeAndALaterOneLeavesTheDesign() {
        // At the start, and within a quarter of a frame of it.
        for t in [0.0, 0.004, -3] {
            var n = card()
            n.pose(.turn, [45], at: t)
            let keys = n[track: .turn]!.keys
            #expect(keys.map(\.t) == [0, MotionTiming.beat], "posed at \(t)")
            #expect(keys.map(\.v) == [[45], [0]] && keys.map(\.given) == [nil, true], "posed at \(t)")
        }
        // Just after it, and later: the design at the start, the pose then.
        for t in [0.005, 0.3, 2.75] {
            var n = card()
            n.pose(.turn, [45], at: t)
            let keys = n[track: .turn]!.keys
            #expect(keys.map(\.t) == [0, t], "posed at \(t)")
            #expect(keys.map(\.v) == [[0], [45]] && keys.map(\.given) == [true, nil], "posed at \(t)")
        }
        // How long home takes can be said, and is never no time at all.
        var slow = card()
        slow.pose(.scale, [2, 2], at: 0, home: 3)
        #expect(slow[track: .scale]!.keys.map(\.t) == [0, 3])
        for home in [0.0, -1, 0.01] {
            var quick = card()
            quick.pose(.scale, [2, 2], at: 0, home: home)
            #expect(quick[track: .scale]!.keys.map(\.t) == [0, 0.05], "home in \(home)")
        }
        // A time to fly home in that is no number is the usual beat.
        for home in [Double.nan, .infinity] {
            var odd = card()
            odd.pose(.scale, [2, 2], at: 0, home: home)
            #expect(odd[track: .scale]!.keys.map(\.t) == [0, MotionTiming.beat], "home in \(home)")
        }
        // Each property has its own first pose.
        var n = card()
        n.pose(.move, [10, 0], at: 1)
        n.pose(.fade, [0], at: 0)
        #expect(n[track: .move]!.keys.map(\.t) == [0, 1] && n[track: .fade]!.keys.map(\.t) == [0, 0.5])
        #expect(n.motionProperties == [.move, .fade])
    }

    @Test func theDesignGivenForCompanyIsAnyonesOnceItIsTouched() {
        // Posed on, the key that was given is a key like any other: a later pose leaves it.
        var n = card()
        n.pose(.move, [0, 50], at: 0)
        n.pose(.move, [0, 10], at: MotionTiming.beat)
        #expect(n[track: .move]!.keys.map(\.given) == [nil, nil])
        n.pose(.move, [30, 0], at: 2)
        #expect(n[track: .move]!.keys.map(\.t) == [0, 0.5, 2])
        // So is one whose pace was chosen, or that was moved, or set as a key.
        var paced = card()
        paced.pose(.move, [0, 50], at: 0)
        paced.setEase(.linear, at: 0.5, of: [.move])
        paced.pose(.move, [30, 0], at: 2)
        #expect(paced[track: .move]!.keys.map(\.t) == [0, 0.5, 2])
        var moved = card()
        moved.pose(.move, [0, 50], at: 0)
        moved.moveKeys(from: 0.5, to: 1, of: [.move])
        moved.pose(.move, [30, 0], at: 2)
        #expect(moved[track: .move]!.keys.map(\.t) == [0, 1, 2])
        var set = card()
        set.pose(.move, [0, 50], at: 0)
        set.setKey(.move, [0, 0], at: 0.5)
        set.pose(.move, [30, 0], at: 2)
        #expect(set[track: .move]!.keys.map(\.t) == [0, 0.5, 2])
        // The design given at the start, for a layer posed later, never gives way: nothing is posed before it.
        var later = card()
        later.pose(.move, [40, 0], at: 1)
        later.pose(.move, [80, 0], at: 2)
        #expect(later[track: .move]!.keys.map(\.t) == [0, 1, 2] && later[track: .move]!.keys[0].given == true)
        // Posed on at the start, it is the pose's.
        later.pose(.move, [-20, 0], at: 0)
        #expect(later[track: .move]!.keys[0].v == [-20, 0] && later[track: .move]!.keys[0].given == nil)
        // With a key posed between, the way home is a motion of three keys, and a pose past it adds a fourth.
        var between = card()
        between.pose(.move, [0, 50], at: 0)
        between.pose(.move, [0, 20], at: 0.25)
        between.pose(.move, [30, 0], at: 2)
        #expect(between[track: .move]!.keys.map(\.t) == [0, 0.25, 0.5, 2])
    }

    @Test func posingAPropertyThatHasKeysAsDesignedIsAKeyLikeAnyOther() {
        var n = card()
        n.pose(.fade, [0.2], at: 1)
        n.pose(.fade, [1], at: 2)
        #expect(n[track: .fade]!.keys.map(\.t) == [0, 1, 2])
        #expect(n.value(of: .fade, at: 2) == [1])
        // Nothing else of the layer is touched by a pose.
        var plain = card()
        plain.pose(.fade, [0.2], at: 1)
        var bare = plain
        bare.motion = nil
        #expect(bare == card().with(id: plain.id))
    }

    // MARK: Keys

    @Test func settingAKeySetsThatKeyAndNothingElse() {
        var n = card()
        // On a property with none, one key, even one that says the design.
        n.setKey(.turn, [0], at: 1)
        #expect(n[track: .turn]!.keys == [MotionKey(t: 1, v: [0])])
        #expect(n.isAnimated)
        // "Auto" is what no pace says.
        n.setKey(.turn, [30], at: 2, ease: .auto)
        #expect(n[track: .turn]!.keys[1].ease == nil)
        n.setKey(.turn, [60], at: 3, ease: .spring(0.4))
        #expect(n[track: .turn]!.keys[2].ease == .spring(0.4))
        // On a key that is there, give or take a quarter of a frame, the value changes and the key stays when it was.
        n.setKey(.turn, [61], at: 3.003)
        #expect(n[track: .turn]!.keys.map(\.t) == [1, 2, 3] && n[track: .turn]!.keys[2].v == [61])
        // Its pace is kept unless one is said, and "auto" said takes it away.
        #expect(n[track: .turn]!.keys[2].ease == .spring(0.4))
        n.setKey(.turn, [62], at: 3, ease: .hold)
        #expect(n[track: .turn]!.keys[2].ease == .hold)
        n.setKey(.turn, [63], at: 3, ease: .auto)
        #expect(n[track: .turn]!.keys[2].ease == nil)
        // Before the others, it goes first; values are kept within what shows.
        n.setKey(.turn, [-10], at: 0.2)
        #expect(n[track: .turn]!.keys.map(\.t) == [0.2, 1, 2, 3])
        n.setKey(.fade, [4], at: 0)
        n.setKey(.scale, [5], at: 0)
        #expect(n[track: .fade]!.keys[0].v == [1] && n[track: .scale]!.keys[0].v == [5, 1])
        // A key set on one that was given is no longer given.
        var given = card()
        given.pose(.move, [0, 50], at: 0)
        given.setKey(.move, [5, 5], at: 0.5)
        #expect(given[track: .move]!.keys[1].given == nil)
    }

    @Test func takingKeysAwayLeavesTheRestAndALoneKeyThatSaysTheDesignGoesToo() {
        var n = card()
        n.setKey(.move, [0, 0], at: 0)
        n.setKey(.move, [40, 0], at: 1)
        n.setKey(.move, [40, 40], at: 2)
        n.setKey(.fade, [0.5], at: 1)
        n.setKey(.fade, [0.2], at: 2)
        // Only of the properties named, give or take a quarter of a frame.
        n.removeKeys(at: 1.003, of: [.move])
        #expect(n[track: .move]!.keys.map(\.t) == [0, 2] && n[track: .fade]!.keys.map(\.t) == [1, 2])
        // Where there is none, nothing happens; nor for a property with no keys.
        let before = n
        n.removeKeys(at: 1.5, of: MotionProperty.allCases)
        n.removeKeys(at: 0, of: [.turn, .cameraZoom])
        #expect(n == before)
        // Not even to a lone key elsewhere that says the design, set there to hold it: nothing of
        // that property was taken away.
        var held = card()
        held.setKey(.turn, [0], at: 0)
        held.setKey(.move, [10, 0], at: 2)
        held.removeKeys(at: 2, of: MotionProperty.layer)
        #expect(held[track: .turn]?.keys.map(\.t) == [0] && held[track: .move] == nil)
        // One key left that is not the design stays: the layer is like that all through.
        n.removeKeys(at: 2, of: [.fade])
        #expect(n[track: .fade]!.keys == [MotionKey(t: 1, v: [0.5])])
        #expect(n.value(of: .fade, at: 0) == [0.5])
        // One left that says the design has nothing to say.
        n.removeKeys(at: 2, of: [.move])
        #expect(n[track: .move] == nil)
        // The last one taken away, the layer is simply as designed.
        n.removeKeys(at: 1, of: [.fade])
        #expect(n.motion == nil && !n.isAnimated)
        // Two keys that both say the design are still two keys: only a lone one goes.
        var two = card()
        two.setKey(.turn, [0], at: 0)
        two.setKey(.turn, [90], at: 1)
        two.setKey(.turn, [0], at: 2)
        two.removeKeys(at: 1, of: [.turn])
        #expect(two[track: .turn]!.keys.map(\.t) == [0, 2])
    }

    @Test func movingKeysTakesThemToAnotherMomentWhereAKeyGivesWay() {
        func made() -> Node {
            var n = card()
            n.pose(.move, [40, 0], at: 1)
            n.setKey(.move, [40, 40], at: 2, ease: .spring(0.5))
            n.setKey(.fade, [0.5], at: 1)
            return n
        }
        // To a free moment: its value and its pace go with it, and it is no longer given.
        var n = made()
        n.moveKeys(from: 2, to: 0.5, of: [.move])
        #expect(n[track: .move]!.keys.map(\.t) == [0, 0.5, 1])
        #expect(n[track: .move]!.keys[1] == MotionKey(t: 0.5, v: [40, 40], ease: .spring(0.5)))
        #expect(n[track: .fade]!.keys.map(\.t) == [1])
        // Onto another key: that one gives way.
        n = made()
        n.moveKeys(from: 1, to: 2.003, of: [.move])
        #expect(n[track: .move]!.keys.map(\.t) == [0, 2.003] && n[track: .move]!.keys[1].v == [40, 0])
        // To before the start: to the start, where the key there gives way.
        n = made()
        n.moveKeys(from: 1, to: -4, of: [.move, .fade])
        #expect(n[track: .move]!.keys.map(\.t) == [0, 2] && n[track: .move]!.keys[0].v == [40, 0])
        #expect(n[track: .fade]!.keys.map(\.t) == [0])
        // By nothing, or by less than can be told apart: nothing changes, not even what was given.
        n = made()
        n.moveKeys(from: 0, to: 0, of: [.move])
        n.moveKeys(from: 1, to: 1.004, of: [.move, .fade])
        #expect(n == made().with(id: n.id))
        #expect(n[track: .move]!.keys[0].given == true)
        // From where there is no key: nothing.
        n.moveKeys(from: 1.5, to: 3, of: MotionProperty.allCases)
        #expect(n == made().with(id: n.id))
        // A given key that is moved is anyone's.
        n.moveKeys(from: 0, to: 0.25, of: [.move])
        #expect(n[track: .move]!.keys.map(\.t) == [0.25, 1, 2] && n[track: .move]!.keys[0].given == nil)
        // Where it is moved to is kept to the thousandth of a second.
        n.moveKeys(from: 0.25, to: 0.33333, of: [.move])
        #expect(n[track: .move]!.keys[0].t == 0.333)
    }

    @Test func aPaceIsSetOnTheKeysAtAMomentOnly() {
        var n = card()
        n.pose(.move, [40, 0], at: 0)
        n.setKey(.fade, [0.5], at: 0.5)
        n.setEase(.spring(0.2), at: 0.502, of: [.move, .fade, .turn])
        #expect(n[track: .move]!.keys[1].ease == .spring(0.2) && n[track: .move]!.keys[1].given == nil)
        #expect(n[track: .fade]!.keys[0].ease == .spring(0.2))
        #expect(n[track: .move]!.keys[0].ease == nil && n[track: .turn] == nil)
        n.setEase(.auto, at: 0.5, of: [.move])
        #expect(n[track: .move]!.keys[1].ease == nil && n[track: .fade]!.keys[0].ease == .spring(0.2))
        let before = n
        n.setEase(.hold, at: 3, of: MotionProperty.allCases)
        #expect(n == before)
    }

    @Test func shiftingKeysMovesAWholeMotionAndNeverBeforeTheStart() {
        func made() -> Node {
            var n = card()
            n.setKey(.move, [0, 0], at: 0.5)
            n.setKey(.move, [40, 0], at: 1.5)
            n.setKey(.fade, [0], at: 2)
            n.setKey(.fade, [1], at: 2.4, ease: .easeOut)
            return n
        }
        var n = made()
        n.shiftKeys(by: 1.25)
        #expect(n[track: .move]!.keys.map(\.t) == [1.75, 2.75] && n[track: .fade]!.keys.map(\.t) == [3.25, 3.65])
        #expect(n[track: .fade]!.keys[1].ease == .easeOut && n[track: .move]!.keys.map(\.v) == [[0, 0], [40, 0]])
        // Only of the properties named.
        n = made()
        n.shiftKeys(by: 1, of: [.fade])
        #expect(n[track: .move]!.keys.map(\.t) == [0.5, 1.5] && n[track: .fade]!.keys.map(\.t) == [3, 3.4])
        // Earlier than the start allows: as early as it goes, the whole motion together, so that
        // what faded after the move was done still does.
        n = made()
        n.shiftKeys(by: -3)
        #expect(n[track: .move]!.keys.map(\.t) == [0, 1])
        #expect(n[track: .fade]!.keys.map(\.t) == [1.5, 1.9])
        // By nothing, and by what is no number, nothing changes.
        n = made()
        n.shiftKeys(by: 0)
        n.shiftKeys(by: .nan)
        n.shiftKeys(by: .infinity)
        #expect(n == made().with(id: n.id))
    }

    @Test func aLayersKeyTimesAndItsLastKey() {
        var n = card()
        #expect(n.keyTimes().isEmpty && n.lastKey == 0)
        n.setKey(.move, [1, 1], at: 2)
        n.setKey(.move, [2, 2], at: 0.5)
        n.setKey(.fade, [0.5], at: 2.003)
        n.setKey(.fade, [0.7], at: 3)
        n.setKey(.cameraZoom, [2], at: 9)
        // Each moment once, though two properties have a key there, in order; the camera's apart.
        #expect(n.keyTimes() == [0.5, 2, 3])
        #expect(n.keyTimes([.fade]) == [2.003, 3])
        #expect(n.keyTimes(MotionProperty.camera) == [9])
        #expect(n.keyTimes([.turn]).isEmpty)
        #expect(n.lastKey == 9)
        // The last key of anything a layer holds counts for it, however deep.
        var inner = card("Inner")
        inner.setKey(.turn, [5], at: 12.5)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        group.children = [inner]
        var outer = Node(kind: .group, name: "Outer", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        outer.children = [group, n]
        #expect(outer.lastKey == 12.5 && group.lastKey == 12.5)
        #expect(outer.keyTimes().isEmpty)
    }

    // MARK: What a layer says of itself

    @Test func whatMovesIsKnownByLayerGroupAndArtboard() {
        var moving = card("Moving")
        moving.setKey(.fade, [0.5], at: 0)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        group.children = [card("Still"), moving]
        var outer = Node(kind: .group, name: "Outer", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        outer.children = [group]
        var b = board([outer, card("Other")])
        #expect(moving.isAnimated && !moving.holdsMotion && !moving.hasCamera)
        #expect(!group.isAnimated && group.holdsMotion)
        #expect(!outer.isAnimated && outer.holdsMotion)
        #expect(!b.isAnimated && b.holdsMotion && b.hasFilm && !b.hasCamera)
        // A camera's keys make a film, but do not make the artboard a moving layer.
        var filmed = board([card()])
        #expect(!filmed.hasFilm && !filmed.hasCamera && filmed.motionProperties.isEmpty)
        filmed.setKey(.cameraZoom, [2], at: 1)
        #expect(filmed.hasCamera && filmed.hasFilm && !filmed.isAnimated && !filmed.holdsMotion)
        #expect(filmed.camera(at: 1).zoom == 2 && filmed.pose(at: 1) == .rest)
        // The properties with keys are listed layers' first, then the camera's, each in its own order.
        b.setKey(.cameraRoll, [5], at: 0)
        b.setKey(.cameraMove, [5, 5], at: 0)
        b.setKey(.blur, [5], at: 0)
        b.setKey(.move, [5, 5], at: 0)
        #expect(b.motionProperties == [.move, .blur, .cameraMove, .cameraRoll])
        // A film's settings alone are no film: nothing moves.
        var set = board([card()])
        set.film = Film(length: 5, once: true)
        #expect(!set.hasFilm)
        // An empty list of keys is no motion, and taking the last track away leaves none at all.
        var n = card()
        n[track: .move] = MotionTrack()
        #expect(n.motion == nil)
        n[track: .move] = MotionTrack([MotionKey(t: 0, v: [1, 1])])
        n[track: .move] = nil
        #expect(n.motion == nil)
        // A property this Bezzle does not know, as a later one might write, is kept and moves nothing.
        var later = card()
        later.motion = ["wobble": MotionTrack([MotionKey(t: 0, v: [3]), MotionKey(t: 7, v: [4])])]
        #expect(later.motionProperties.isEmpty && !later.isAnimated && later.pose(at: 1) == .rest)
        later.setKey(.fade, [0.5], at: 1)
        later.removeKeys(at: 1, of: [.fade])
        #expect(later.motion?["wobble"]?.keys.count == 2)
    }

    @Test func aFilmRunsToTheNextHalfSecondPastItsLastKeyOrAsLongAsItIsSet() {
        func film(lastKey t: Double) -> Node {
            var n = card()
            n.setKey(.turn, [10], at: t)
            return board([n])
        }
        #expect(board().filmLength == 2)
        for (t, length) in [(0.0, 2.0), (1.9, 2), (2, 2), (2.001, 2.5), (2.5, 2.5), (2.501, 3), (7.2, 7.5), (59.75, 60)] {
            #expect(film(lastKey: t).filmLength == length, "last key at \(t)")
        }
        // The camera's keys count, and those of layers deep in groups.
        var b = board([card()])
        b.setKey(.cameraZoom, [2], at: 4.2)
        #expect(b.filmLength == 4.5)
        // Set, it runs that long, though keys lie past its end; set to nothing or less, or to no
        // number, it is as long as its keys again.
        var set = film(lastKey: 3.2)
        set.film = Film(length: 1.25)
        #expect(set.filmLength == 1.25)
        set.film = Film(length: 10)
        #expect(set.filmLength == 10)
        for length in [0, -3, .nan, .infinity, -.infinity] as [Double] {
            set.film = Film(length: length)
            #expect(set.filmLength == 3.5, "set to \(length)")
        }
        set.film = Film(once: true)
        #expect(set.filmLength == 3.5)
        // However absurd, working out how sharp its pictures must be never stops Bezzle.
        var absurd = film(lastKey: 1e300)
        #expect(absurd.filmStretch(of: absurd.filmPieces()[1], around: CGRect(x: 0, y: 0, width: 10, height: 10)) >= 1)
        absurd.film = Film(length: 1e300)
        #expect(absurd.filmStretch(of: absurd.filmPieces()[1], around: CGRect(x: 0, y: 0, width: 10, height: 10)) >= 1)
    }

    @Test func whatShowsPastTheArtboardsEdgesGoesWithTheArtboardUnlessItIsChosen() {
        let light = RGBA(r: 0.898, g: 0.882, b: 0.851), dark = RGBA(r: 0.059, g: 0.055, b: 0.051)
        var b = board()
        #expect(b.filmBackdrop == light)
        b.fill.color = RGBA(r: 0.1, g: 0.1, b: 0.12)
        #expect(b.filmBackdrop == dark)
        // An artboard with no fill is seen as white.
        b.fill.on = false
        #expect(b.filmBackdrop == light)
        b.fill = Fill(color: RGBA(r: 0.5, g: 0.5, b: 0.5))
        #expect(b.filmBackdrop == light)
        b.fill.color = RGBA(r: 0.4, g: 0.4, b: 0.4)
        #expect(b.filmBackdrop == dark)
        // A green as bright as that counts as light, and a blue as dark.
        b.fill.color = RGBA(r: 0, g: 1, b: 0)
        #expect(b.filmBackdrop == light)
        b.fill.color = RGBA(r: 0, g: 0, b: 1)
        #expect(b.filmBackdrop == dark)
        let chosen = RGBA(r: 1, g: 0, b: 0.5)
        b.film = Film(backdrop: chosen)
        #expect(b.filmBackdrop == chosen)
    }

    // MARK: Moves made in one go

    @Test func everyMoveComesFromAwayToTheDesignAndGoesTheOtherWay() {
        let size = CGSize(width: 400, height: 300)
        for move in MotionMove.allCases {
            let frame = CGRect(x: 100, y: 80, width: 120, height: 60)
            let away = move.away(frame, on: size)
            #expect(!away.isEmpty && away.keys.allSatisfy { !$0.isCamera }, "\(move)")
            #expect(move.time >= 0.4 && move.time <= 0.6 && !move.title.isEmpty, "\(move)")

            var coming = card()
            coming.apply(move, at: 1, frame: frame, board: size)
            #expect(Set(coming.motionProperties) == Set(away.keys), "\(move)")
            for (p, value) in away {
                let keys = coming[track: p]!.keys
                #expect(keys.map(\.t) == [1, MotionTiming.time(1 + move.time)], "\(move) \(p)")
                #expect(keys.map(\.v) == [p.clamped(value), p.rest], "\(move) \(p)")
                // What fades or sharpens only does that, however the move arrives.
                #expect(keys[1].ease == (p == .fade || p == .blur ? .easeOut : move.arriving), "\(move) \(p)")
                #expect(keys.allSatisfy { $0.given == nil }, "\(move) \(p)")
                // Away until it comes, as designed once it has.
                #expect(coming.value(of: p, at: 0) == p.clamped(value) && coming.value(of: p, at: 5) == p.rest, "\(move) \(p)")
            }
            #expect(coming.pose(at: 5) == .rest, "\(move)")
            #expect(coming.pose(at: 0) != .rest, "\(move)")

            var going = card()
            going.apply(move, at: 1, going: true, frame: frame, board: size)
            for (p, value) in away {
                let keys = going[track: p]!.keys
                #expect(keys.map(\.t) == [1, MotionTiming.time(1 + move.time)], "\(move) \(p) going")
                #expect(keys.map(\.v) == [p.rest, p.clamped(value)], "\(move) \(p) going")
                #expect(keys[1].ease == .easeIn, "\(move) \(p) going")
            }
            #expect(going.pose(at: 0) == .rest && going.pose(at: 5) != .rest, "\(move)")
        }
        // What is away is out of sight or off its place, each in its own way.
        #expect(MotionMove.fade.away(.zero, on: size) == [.fade: [0]])
        #expect(MotionMove.rise.away(.zero, on: size)[.move] == [0, 28])
        #expect(MotionMove.drop.away(.zero, on: size)[.move] == [0, -36])
        #expect(MotionMove.pop.away(.zero, on: size)[.scale] == [0.6, 0.6])
        #expect(MotionMove.zoom.away(.zero, on: size)[.scale] == [1.35, 1.35])
        #expect(MotionMove.flip.away(.zero, on: size)[.tilt] == [-80])
        #expect(MotionMove.focus.away(.zero, on: size)[.blur] == [18])
    }

    @Test func aMoveThatBouncesPassesTheDesignAndEndsOnItWhileItsFadeOnlyFades() {
        for move in [MotionMove.pop, .drop, .flip] {
            var n = card()
            n.apply(move, at: 0, frame: n.frame, board: CGSize(width: 400, height: 300))
            let p: MotionProperty = move == .pop ? .scale : move == .drop ? .move : .tilt
            let i = p == .move ? 1 : 0
            let from = n.value(of: p, at: 0)[i], home = p.rest[i]
            var passed = false, fadedPast = false
            for s in 0...600 {
                let t = move.time * Double(s) / 600
                // Past the design is the far side of it from where it came.
                if (n.value(of: p, at: t)[i] - home) * (from - home) < -1e-6 { passed = true }
                // As its keys say it, before it is kept within what shows.
                if n[track: .fade]!.value(at: t, rest: [1])[0] > 1 + 1e-9 { fadedPast = true }
            }
            #expect(passed, "\(move) never passes")
            #expect(!fadedPast, "\(move) flickers")
            #expect(n.value(of: p, at: move.time) == p.rest, "\(move)")
            #expect(n.pose(at: move.time) == .rest, "\(move)")
        }
    }

    @Test func aSlideStartsAndEndsOutOfSightOnTheNearerSide() {
        let size = CGSize(width: 400, height: 300)
        let frames = [CGRect(x: 20, y: 0, width: 100, height: 40), CGRect(x: 150, y: 0, width: 100, height: 40), CGRect(x: 151, y: 0, width: 100, height: 40),
                      CGRect(x: 280, y: 0, width: 100, height: 40), CGRect(x: -30, y: 0, width: 500, height: 40), CGRect(x: 390, y: 0, width: 300, height: 40)]
        for frame in frames {
            let left = frame.midX <= 200
            for going in [false, true] {
                var n = card("Slide", frame)
                n.apply(.slide, at: 0, going: going, frame: frame, board: size)
                #expect(n.motionProperties == [.move])
                let away = n.value(of: .move, at: going ? 1 : 0)
                let shown = frame.offsetBy(dx: away[0], dy: away[1])
                // Wholly off the artboard, on the side it lies nearer, and level.
                #expect(left ? shown.maxX <= 0 : shown.minX >= 400, "\(frame) going \(going): \(shown)")
                #expect(away[1] == 0)
                #expect(n.value(of: .move, at: going ? 0 : 1) == [0, 0])
            }
        }
    }

    @Test func aMoveTakesTheKeysInItsTimeAndLeavesThoseOutsideIt() {
        var n = card()
        for t in [0.0, 0.8, 0.997, 1.2, 1.404, 2] { n.setKey(.fade, [0.5], at: t) }
        for t in [0.0, 1.2, 2] { n.setKey(.turn, [20], at: t) }
        n.apply(.fade, at: 1, frame: n.frame, board: CGSize(width: 400, height: 300))
        // Those from its start to its end are gone, the one a hair before its start and the one a
        // hair past its end among them; before and after they stay.
        #expect(n[track: .fade]!.keys.map(\.t) == [0, 0.8, 1, 1.4, 2])
        #expect(n[track: .fade]!.keys.map(\.v) == [[0.5], [0.5], [0], [1], [0.5]])
        // Of the properties the move has: the others keep every key.
        #expect(n[track: .turn]!.keys.map(\.t) == [0, 1.2, 2])
        // A move over a move replaces it.
        var twice = card()
        twice.apply(.rise, at: 0.5, frame: twice.frame, board: CGSize(width: 400, height: 300))
        twice.apply(.rise, at: 0.5, going: true, frame: twice.frame, board: CGSize(width: 400, height: 300))
        #expect(twice[track: .move]!.keys.map(\.v) == [[0, 0], [0, 28]] && twice[track: .fade]!.keys.map(\.v) == [[1], [0]])
        // Coming on and later going, a layer has both.
        var both = card()
        both.apply(.fade, at: 0, frame: both.frame, board: CGSize(width: 400, height: 300))
        both.apply(.fade, at: 2, going: true, frame: both.frame, board: CGSize(width: 400, height: 300))
        #expect(both[track: .fade]!.keys.map(\.t) == [0, 0.4, 2, 2.4])
        #expect(both.value(of: .fade, at: 1) == [1] && both.value(of: .fade, at: 3) == [0])
        // At a moment before the start it begins at the start; at one that is no number, too.
        for t in [-2, .nan, .infinity] as [Double] {
            var early = card()
            early.apply(.fade, at: t, frame: early.frame, board: CGSize(width: 400, height: 300))
            #expect(early[track: .fade]!.keys.map(\.t) == [0, 0.4], "at \(t)")
        }
    }

    @Test func severalLayersAreGivenAMoveInTheOrderTheyAreRead() {
        // Two rows; the lower row a hair off level, which still reads as one line; one layer in a group.
        var inGroup = card("Second", CGRect(x: 10, y: 0, width: 40, height: 20))
        inGroup.rotation = 0
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 22, width: 60, height: 20))
        group.children = [inGroup]
        var a = board([card("Fourth", CGRect(x: 200, y: 103, width: 40, height: 20)), card("Third", CGRect(x: 20, y: 100, width: 40, height: 20)),
                       group, card("First", CGRect(x: 20, y: 20, width: 40, height: 20))])
        a.frame.origin = CGPoint(x: 500, y: 300)
        var doc = BezzleDocument()
        doc.nodes = [a, card("Loose", CGRect(x: 0, y: 0, width: 40, height: 20))]
        func id(_ name: String) -> UUID { doc.allNodes.first { $0.name == name }!.id }
        let names = ["Fourth", "Second", "Loose", "Third", "First"]
        doc.apply(.fade, to: names.map(id) + [a.id, UUID()], at: 1, apart: 0.25)
        #expect(["First", "Second", "Third", "Fourth"].map { doc.node(id($0))![track: .fade]!.start } == [1, 1.25, 1.5, 1.75])
        // A layer not on an artboard has nowhere to come on to, and an artboard is no layer: neither gets the move.
        #expect(doc.node(id("Loose"))!.motion == nil && doc.nodes[0].motion == nil)
        #expect(doc.node(id("Group"))!.motion == nil)
        // All at once when no time apart is given, or one that makes no sense.
        for apart in [0.0, -1] {
            var together = doc
            together.clearMotion([a.id])
            together.apply(.pop, to: names.map(id), at: 0.5, going: true, apart: apart)
            #expect(["First", "Second", "Third", "Fourth"].allSatisfy { together.node(id($0))![track: .scale]!.keys.map(\.t) == [0.5, 1.1] })
        }
        // A slide is from the side of the artboard the layer lies nearer, wherever the artboard is
        // on the canvas and however deep the layer lies in groups.
        var slid = doc
        slid.clearMotion([a.id])
        slid.apply(.slide, to: [id("Second"), id("Fourth")], at: 0)
        #expect(slid.node(id("Second"))![track: .move]!.keys[0].v == [-158, 0])
        #expect(slid.node(id("Fourth"))![track: .move]!.keys[0].v == [208, 0])
    }

    @Test func clearingMotionLeavesLayersAsDesigned() {
        var inner = card("Inner")
        inner.pose(.move, [10, 0], at: 1)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        group.children = [inner]
        group.pose(.fade, [0], at: 0)
        var other = card("Other")
        other.pose(.turn, [90], at: 1)
        var a = board([group, other])
        a.setKey(.cameraZoom, [2], at: 1)
        a.film = Film(length: 4, once: true, backdrop: .black)
        var b = a
        b.id = UUID()
        b.name = "B"
        b.children = [card("Second").with { $0.pose(.blur, [4], at: 1) }]
        var doc = BezzleDocument()
        doc.nodes = [a, b]
        func named(_ name: String) -> Node { doc.allNodes.first { $0.name == name }! }

        // A layer: only it.
        doc.clearMotion([other.id])
        #expect(named("Other").motion == nil && named("Group").motion != nil && named("Inner").motion != nil && doc.nodes[0].hasCamera)
        // A group: it and what it holds.
        doc.clearMotion([group.id])
        #expect(named("Group").motion == nil && named("Inner").motion == nil)
        #expect(doc.nodes[0].hasCamera && doc.nodes[0].film != nil)
        // An artboard: everything on it, its camera and what its film was set to. The other artboard keeps its film.
        doc.nodes[0].children[1].pose(.turn, [90], at: 1)
        doc.clearMotion([a.id, UUID()])
        #expect(doc.nodes[0].motion == nil && doc.nodes[0].film == nil && !doc.nodes[0].hasFilm)
        #expect(doc.nodes[0].children.allSatisfy { $0.motion == nil })
        #expect(doc.nodes[1].hasFilm && doc.nodes[1].hasCamera && doc.nodes[1].film?.length == 4)
        // Nothing else of the design has changed.
        var plain = a
        plain.motion = nil
        plain.film = nil
        plain.children = [group, other].map(\.withoutMotion)
        #expect(doc.nodes[0] == plain)
    }
}
