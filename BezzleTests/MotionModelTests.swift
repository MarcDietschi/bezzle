import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// The same numbers every run, so a sequence that goes wrong can be gone through again.
struct MotionDice: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    mutating func chance(_ of: Double) -> Bool { Double.random(in: 0..<1, using: &self) < of }
    mutating func number(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
}

/// Animate's arithmetic past what `MotionTests` shows: every property's limits, every pace between
/// keys, flights through several of them, and thousands of random changes after each of which a
/// layer's motion must still be in order. What posing and keying leave behind is in `MotionKeysTests`.
@MainActor
struct MotionModelTests {
    private func card(_ name: String = "Card", _ frame: CGRect = CGRect(x: 100, y: 80, width: 120, height: 60)) -> Node {
        Node(kind: .rectangle, name: name, frame: frame)
    }

    private func board(_ children: [Node] = [], size: CGSize = CGSize(width: 400, height: 300)) -> Node {
        var b = Node(kind: .artboard, name: "A", frame: CGRect(origin: .zero, size: size))
        b.children = children
        return b
    }

    private func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) < e }

    // MARK: What moves

    @Test func everyPropertyRestsOnAsManyNumbersAsItHasAndChangesNothingThere() {
        let pairs: Set<MotionProperty> = [.move, .scale, .cameraMove, .draw]
        let times: Set<MotionProperty> = [.scale, .fade, .cameraZoom]
        // A shape has as many numbers as its outline has points, none of them anything but nothing.
        #expect(MotionProperty.shape.rest.isEmpty)
        // All of a line is drawn, from its start to its end.
        #expect(MotionProperty.draw.rest == [0, 1])
        for p in MotionProperty.allCases {
            if p != .shape { #expect(p.rest.count == (pairs.contains(p) ? 2 : 1), "\(p)") }
            // What a layer is multiplied by rests at one, what is added to it at nothing.
            if p != .draw { #expect(p.rest.allSatisfy { $0 == (times.contains(p) ? 1 : 0) }, "\(p)") }
            #expect(p.clamped(p.rest) == p.rest, "\(p)")
            #expect(p.isCamera == p.rawValue.hasPrefix("camera"), "\(p)")
            #expect(MotionProperty(rawValue: p.rawValue) == p, "\(p)")
            #expect(!p.title.isEmpty, "\(p)")
        }
        #expect(MotionProperty.layer + MotionProperty.camera == MotionProperty.allCases)
        #expect(Set(MotionProperty.layer).isDisjoint(with: MotionProperty.camera))
        // At rest a pose and a camera say what the properties' rests say.
        for p in MotionProperty.layer { #expect(MotionPose.rest[p] == p.rest, "\(p)") }
        for p in MotionProperty.camera { #expect(FilmCamera.rest[p] == p.rest, "\(p)") }
        #expect(MotionPose.rest.isRest && !MotionPose.rest.inDepth)
        #expect(FilmCamera.rest.isRest && !FilmCamera.rest.inDepth)
    }

    @Test func everyLimitHoldsAtItAndPastIt() {
        let limits: [(MotionProperty, Double, Double)] = [
            (.scale, 0.001, 100), (.fade, 0, 1), (.blur, 0, 200), (.lift, -4000, 4000), (.tilt, -360, 360), (.swing, -360, 360),
            (.cameraZoom, 0.1, 16), (.cameraTilt, -80, 80), (.cameraSwing, -80, 80),
        ]
        for (p, low, high) in limits {
            func all(_ x: Double) -> [Double] { Array(repeating: x, count: p.rest.count) }
            #expect(p.clamped(all(low)) == all(low), "\(p) at its least")
            #expect(p.clamped(all(high)) == all(high), "\(p) at its most")
            #expect(p.clamped(all(low - 0.5)) == all(low), "\(p) under its least")
            #expect(p.clamped(all(high + 0.5)) == all(high), "\(p) over its most")
            #expect(p.clamped(all(-1e12)) == all(low), "\(p) far under")
            #expect(p.clamped(all(1e12)) == all(high), "\(p) far over")
            let middle = (low + high) / 2
            #expect(p.clamped(all(middle)) == all(middle), "\(p) in between")
        }
        // Where a layer is, how far it is turned, where the camera looks and how it is rolled have no limits.
        for p in [MotionProperty.move, .turn, .cameraMove, .cameraRoll] {
            let far = Array(repeating: -1e9, count: p.rest.count), further = Array(repeating: 12345.678, count: p.rest.count)
            #expect(p.clamped(far) == far, "\(p)")
            #expect(p.clamped(further) == further, "\(p)")
        }
        // Each of a size's two numbers on its own.
        #expect(MotionProperty.scale.clamped([0, 250]) == [0.001, 100])
        #expect(MotionProperty.scale.clamped([3, -1]) == [3, 0.001])
        // A pose and a camera keep to the same limits.
        var pose = MotionPose()
        pose[.fade] = [7]
        pose[.blur] = [-3]
        pose[.scale] = [0, 500]
        #expect(pose.fade == 1 && pose.blur == 0 && pose.scale == CGPoint(x: 0.001, y: 100))
        var camera = FilmCamera()
        camera[.cameraZoom] = [99]
        camera[.cameraTilt] = [-200]
        #expect(camera.zoom == 16 && camera.tilt == -80)
    }

    @Test func tooFewNumbersAreMadeUpFromRestAndTooManyAreDropped() {
        #expect(MotionProperty.move.clamped([5]) == [5, 0])
        #expect(MotionProperty.scale.clamped([2]) == [2, 1])
        #expect(MotionProperty.cameraMove.clamped([]) == [0, 0])
        #expect(MotionProperty.move.clamped([1, 2, 3]) == [1, 2])
        #expect(MotionProperty.fade.clamped([0.5, 9, 9]) == [0.5])
        #expect(MotionProperty.cameraZoom.clamped([2, 3]) == [2])
        for p in MotionProperty.allCases { #expect(p.clamped([]) == p.rest, "\(p)") }
        // A pose asked for a camera's property, and a camera for a layer's, say its rest and take nothing.
        var pose = MotionPose()
        pose[.cameraZoom] = [3]
        #expect(pose.isRest && pose[.cameraZoom] == [1])
        var camera = FilmCamera()
        camera[.move] = [30, 30]
        #expect(camera.isRest && camera[.move] == [0, 0])
    }

    @Test func whatIsNotANumberIsAsDesigned() {
        for p in MotionProperty.allCases {
            for bad in [Double.nan, .infinity, -.infinity, .signalingNaN] {
                // A shape's every number is a point's, kept where it is.
                #expect(p.clamped(Array(repeating: bad, count: 3)) == (p == .shape ? [0, 0, 0] : p.rest), "\(p) given \(bad)")
            }
        }
        #expect(MotionProperty.move.clamped([.nan, 3]) == [0, 3])
        #expect(MotionProperty.scale.clamped([.infinity, 2]) == [1, 2])
        #expect(MotionProperty.cameraMove.clamped([4, -.infinity]) == [4, 0])
        // Posed so, a layer gets no key at all, and one it has says the design.
        var n = card()
        n.pose(.move, [.nan, .nan], at: 1)
        n.pose(.fade, [.infinity], at: 1)
        #expect(n.motion == nil)
        n.setKey(.lift, [.nan], at: 1)
        #expect(n[track: .lift]?.keys.map(\.v) == [[0]])
    }

    // MARK: Paces

    @Test func everyPaceButASpringOnlyEverGoesForwardFromNothingToAll() {
        for kind in MotionEase.Kind.allCases where kind != .spring {
            var last = 0.0, forward = true, within = true
            for i in 0...2000 {
                let p = MotionEase.progress(kind, Double(i) / 2000)
                if !p.isFinite || p < last - 1e-5 { forward = false }
                if p < -1e-9 || p > 1 + 1e-9 { within = false }
                last = p
            }
            #expect(forward, "\(kind) goes back")
            #expect(within, "\(kind) leaves 0 to 1")
            #expect(MotionEase.progress(kind, 0) == 0, "\(kind)")
            #expect(near(MotionEase.progress(kind, 1), 1, 1e-9), "\(kind)")
            // Before the stretch begins nothing of it is done, and after it ends all of it.
            #expect(MotionEase.progress(kind, -3) == MotionEase.progress(kind, 0), "\(kind)")
            #expect(MotionEase.progress(kind, 7) == MotionEase.progress(kind, 1), "\(kind)")
        }
        // Left to Bezzle, a single stretch is paced as a smooth one.
        for u in [0.1, 0.37, 0.5, 0.9] { #expect(MotionEase.progress(.auto, u) == MotionEase.progress(.smooth, u)) }
        // Held, nothing happens until the very end.
        #expect(MotionEase.progress(.hold, 0.999999) == 0 && MotionEase.progress(.hold, 1) == 1)
        // Each says so by a name.
        #expect(Set(MotionEase.Kind.allCases.map { MotionEase(kind: $0).title }).count == MotionEase.Kind.allCases.count)
        #expect(MotionEase(kind: .linear).progress(0.25) == 0.25)
    }

    @Test func aSpringEndsExactlyThereHoweverMuchItBounces() {
        for bounce in [-2.0, 0, 0.18, 0.3, 0.42, 0.5, 0.75, 1, 5] {
            #expect(MotionEase.spring(0, bounce: bounce) == 0, "bounce \(bounce)")
            #expect(MotionEase.spring(1, bounce: bounce) == 1, "bounce \(bounce)")
            var finite = true, most = 0.0, least = 0.0
            for i in 0...1000 {
                let p = MotionEase.spring(Double(i) / 1000, bounce: bounce)
                if !p.isFinite { finite = false }
                most = max(most, p)
                least = min(least, p)
            }
            #expect(finite, "bounce \(bounce)")
            // Past where it is going by less than half the way again, and never back behind where it began.
            #expect(most < 1.6 && least > -1e-9, "bounce \(bounce): \(least) to \(most)")
        }
        // Bounce is kept to what a spring can have.
        for u in [0.1, 0.4, 0.8] {
            #expect(MotionEase.spring(u, bounce: 5) == MotionEase.spring(u, bounce: 1))
            #expect(MotionEase.spring(u, bounce: -2) == MotionEase.spring(u, bounce: 0))
        }
        // With none it never passes; with more it passes further.
        func most(_ bounce: Double) -> Double { (0...1000).map { MotionEase.spring(Double($0) / 1000, bounce: bounce) }.max()! }
        #expect(most(0) <= 1 + 1e-12)
        #expect(most(0.3) > 1.001 && most(0.6) > most(0.3) && most(1) > most(0.6))
        // The pace made for a spring remembers its bounce, and one made without takes the usual.
        #expect(MotionEase.spring(0.5).bounce == 0.5 && MotionEase.spring().bounce == 0.3)
        #expect(MotionEase(kind: .spring).progress(0.2) == MotionEase.spring(0.2, bounce: 0.3))
    }

    // MARK: Between keys

    @Test func noKeysSayTheDesignAndOneKeySaysItsValueAlways() {
        #expect(MotionTrack().value(at: 3, rest: [1, 1]) == [1, 1])
        #expect(MotionTrack().start == nil && MotionTrack().end == nil)
        let track = MotionTrack([MotionKey(t: 1, v: [7, 8])])
        for t in [-5.0, 0, 0.5, 1, 1.5, 100] { #expect(track.value(at: t, rest: [0, 0]) == [7, 8], "at \(t)") }
        #expect(track.start == 1 && track.end == 1)
        // On a layer, a property with no keys is as designed at any moment.
        let n = card()
        for p in MotionProperty.allCases { #expect(n.value(of: p, at: 2) == n.rest(of: p.rawValue), "\(p)") }
        #expect(n.value(of: .shape, at: 2) == Array(repeating: 0, count: 4 * BezierPath.numbersPerAnchor))
        #expect(n.pose(at: 2) == .rest && n.camera(at: 2) == .rest)
    }

    @Test func keysAreKeptInTheOrderOfTheirTimes() {
        let track = MotionTrack([MotionKey(t: 2, v: [2]), MotionKey(t: 0.5, v: [0.5]), MotionKey(t: 1, v: [1])])
        #expect(track.keys.map(\.t) == [0.5, 1, 2])
        #expect(track.start == 0.5 && track.end == 2)
        // A key's time is kept to the thousandth of a second, and never before the start.
        #expect(MotionKey(t: 1.23456, v: [0]).t == 1.235)
        #expect(MotionKey(t: -4, v: [0]).t == 0)
        #expect(MotionTiming.time(0.0004) == 0 && MotionTiming.time(0.0006) == 0.001)
        // The key at a time is found a quarter of a frame either side of it, and no further.
        #expect(track.index(at: 1.004) == 1 && track.index(at: 0.996) == 1)
        #expect(track.index(at: 1.005) == nil && track.index(at: 0.995) == nil)
        #expect(MotionTiming.same(1, 1.0041) && !MotionTiming.same(1, 1.0043))
        #expect(MotionTiming.alike([1, 2], [1, 2 + 1e-7]) && !MotionTiming.alike([1, 2], [1, 2.001]) && !MotionTiming.alike([1], [1, 1]))
    }

    @Test func everyPaceIsOnItsKeysExactlyAndBetweenThemBetweenTheirValues() {
        for kind in MotionEase.Kind.allCases {
            // A spring with no bounce, which never passes.
            let ease = kind == .spring ? MotionEase.spring(0) : MotionEase(kind: kind)
            let track = MotionTrack([MotionKey(t: 0.5, v: [10]), MotionKey(t: 1.5, v: [30], ease: ease), MotionKey(t: 2, v: [-5], ease: ease)])
            #expect(track.value(at: 0, rest: [0]) == [10], "\(kind) before the first key")
            #expect(track.value(at: 0.5, rest: [0]) == [10], "\(kind) at the first key")
            #expect(track.value(at: 1.5, rest: [0]) == [30], "\(kind) at the middle key")
            #expect(track.value(at: 2, rest: [0]) == [-5], "\(kind) at the last key")
            #expect(track.value(at: 9, rest: [0]) == [-5], "\(kind) after the last key")
            var inside = true
            for i in 1..<200 {
                let up = track.value(at: 0.5 + Double(i) / 200, rest: [0])[0], down = track.value(at: 1.5 + Double(i) / 400, rest: [0])[0]
                if !(up >= 10 - 1e-9 && up <= 30 + 1e-9) || !(down >= -5 - 1e-9 && down <= 30 + 1e-9) { inside = false }
            }
            #expect(inside, "\(kind) leaves what its keys say")
        }
        // Held, a value stays until its key and is there at once.
        let held = MotionTrack([MotionKey(t: 0, v: [1, 2]), MotionKey(t: 1, v: [5, 6], ease: .hold)])
        #expect(held.value(at: 0.999, rest: [0, 0]) == [1, 2])
        #expect(held.value(at: 1, rest: [0, 0]) == [5, 6])
        // Even, it is as far along as the time is.
        let even = MotionTrack([MotionKey(t: 1, v: [0, 100]), MotionKey(t: 3, v: [10, 0], ease: .linear)])
        let quarter = even.value(at: 1.5, rest: [0, 0])
        #expect(near(quarter[0], 2.5) && near(quarter[1], 75))
        // A spring passes where it is going and comes back to exactly there.
        let sprung = MotionTrack([MotionKey(t: 0, v: [0]), MotionKey(t: 1, v: [100], ease: .spring(0.6))])
        let furthest = (0...1000).map { sprung.value(at: Double($0) / 1000, rest: [0])[0] }.max()!
        #expect(furthest > 105)
        #expect(sprung.value(at: 1, rest: [0]) == [100])
        #expect(abs(sprung.value(at: 0.999999, rest: [0])[0] - 100) < 0.01)
    }

    @Test func twoKeysAlmostTogetherAndAStretchOfNoLengthStillGiveNumbers() {
        var n = card()
        n.setKey(.move, [0, 0], at: 1)
        n.setKey(.move, [100, 50], at: 1.005)
        #expect(n[track: .move]?.keys.count == 2)
        var fine = true
        for i in 0...50 {
            let v = n.value(of: .move, at: 1 + Double(i) * 0.0001)
            if v.count != 2 || !v.allSatisfy(\.isFinite) || v[0] < -1e-9 || v[0] > 100 + 1e-9 || v[1] < -1e-9 || v[1] > 50 + 1e-9 { fine = false }
        }
        #expect(fine)
        // Two keys at one moment, as a file written by hand could have them: before it the earlier
        // says, from it on the later, and nothing is ever divided by no time at all.
        var track = MotionTrack()
        track.keys = [MotionKey(t: 0, v: [0]), MotionKey(t: 1, v: [10]), MotionKey(t: 1, v: [20]), MotionKey(t: 2, v: [30])]
        #expect(track.value(at: 1, rest: [0]) == [20])
        #expect(abs(track.value(at: 0.999999, rest: [0])[0] - 10) < 0.01)
        var finite = true
        for i in 0...400 where !track.value(at: Double(i) / 200, rest: [0]).allSatisfy(\.isFinite) { finite = false }
        #expect(finite)
        // Three at one moment, all going the same way, which a flight would take its speed from.
        track.keys = [MotionKey(t: 0, v: [0]), MotionKey(t: 1, v: [10]), MotionKey(t: 1, v: [20]), MotionKey(t: 1, v: [30]), MotionKey(t: 2, v: [40])]
        for i in 0...400 where !track.value(at: Double(i) / 200, rest: [0]).allSatisfy(\.isFinite) { finite = false }
        #expect(finite)
        #expect(track.value(at: 1, rest: [0]) == [30])
        // Only two keys, both at one moment.
        track.keys = [MotionKey(t: 1, v: [1]), MotionKey(t: 1, v: [2])]
        #expect(track.value(at: 1, rest: [0]) == [1])
        #expect(track.value(at: 1.001, rest: [0]) == [2])
    }

    @Test func askedForAMomentThatIsNoNumberALayerStillSaysNumbers() {
        var n = card()
        n.setKey(.move, [0, 0], at: 0)
        n.setKey(.move, [100, 0], at: 1, ease: .spring(0.4))
        n.setKey(.move, [200, 0], at: 2)
        n.setKey(.fade, [0.2], at: 0)
        n.setKey(.fade, [0.8], at: 1, ease: .linear)
        for t in [Double.nan, .infinity, -.infinity] {
            #expect(n.value(of: .move, at: t).count == 2 && n.value(of: .move, at: t).allSatisfy(\.isFinite), "at \(t)")
            #expect(n.value(of: .fade, at: t).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "at \(t)")
        }
        #expect(n.value(of: .move, at: .infinity) == [200, 0])
        #expect(n.value(of: .move, at: -.infinity) == [0, 0])
        // A layer with one lone key says that key, whatever it is asked: this once stopped Bezzle.
        var lone = card()
        lone.setKey(.turn, [30], at: 1)
        for t in [Double.nan, .infinity, -.infinity, 0, 1, 2] { #expect(lone.value(of: .turn, at: t) == [30], "at \(t)") }
        #expect(lone.pose(at: .nan).turn == 30)
    }

    // MARK: Flights

    @Test func aFlightThroughSeveralKeysSetsOffGoesOnAndSetsDown() {
        var n = card()
        for i in 0...4 { n.setKey(.move, [Double(i) * 100, Double(i) * 10], at: Double(i)) }
        let track = n[track: .move]!
        #expect((0...4).map { track.flows(through: $0) } == [false, true, true, true, false])
        #expect((0..<4).map { track.pace(of: $0, rest: [0, 0]) } == [.setOff, .onward, .onward, .setDown])
        // Never before the first key or past the last, never back, and never a jump.
        var last = -1.0, forward = true, most = 0.0
        for i in 0...4000 {
            let v = n.value(of: .move, at: Double(i) / 1000)
            if !v.allSatisfy(\.isFinite) || v[0] < last - 1e-9 { forward = false }
            if last >= 0 { most = max(most, v[0] - last) }
            last = v[0]
        }
        #expect(forward)
        #expect(most < 0.2)
        // On its way it keeps the speed the keys ask for: a hundred points a second.
        #expect(near(n.value(of: .move, at: 2.5)[0], 250, 1e-6))
        // The other number flies with it.
        #expect(near(n.value(of: .move, at: 2.5)[1], 25, 1e-6))
    }

    @Test func aMotionFlowsOnlyWhereItKeepsGoingAndBothStretchesAreLeftToBezzle() {
        func track(_ values: [[Double]], eases: [Int: MotionEase] = [:]) -> MotionTrack {
            MotionTrack(values.enumerated().map { MotionKey(t: Double($0.offset), v: $0.element, ease: eases[$0.offset]) })
        }
        // It goes on.
        #expect(track([[0], [10], [30]]).flows(through: 1))
        // It turns back.
        #expect(!track([[0], [10], [5]]).flows(through: 1))
        // It stops: it does not move before the key, or after it.
        #expect(!track([[0], [10], [10]]).flows(through: 1))
        #expect(!track([[10], [10], [20]]).flows(through: 1))
        // Round a corner it rests; bearing off to one side it flows.
        #expect(!track([[0, 0], [100, 0], [100, 100]]).flows(through: 1))
        #expect(track([[0, 0], [100, 0], [150, 100]]).flows(through: 1))
        #expect(!track([[0, 0], [100, 0], [50, 100]]).flows(through: 1))
        // Never through the first key or the last, nor through one that is not there.
        let long = track([[0], [10], [20], [30]])
        #expect(!long.flows(through: 0) && !long.flows(through: 3) && !long.flows(through: -1) && !long.flows(through: 9))
        #expect(long.flows(through: 1) && long.flows(through: 2))
        #expect(!track([[0], [10]]).flows(through: 0) && !track([[0], [10]]).flows(through: 1))
        // A pace chosen for the stretch into the key, or out of it, is kept: no flight there.
        #expect(!track([[0], [10], [30]], eases: [1: .linear]).flows(through: 1))
        #expect(!track([[0], [10], [30]], eases: [2: .smooth]).flows(through: 1))
        // "Auto" said aloud is still left to Bezzle.
        #expect(track([[0], [10], [30]], eases: [1: .auto, 2: .auto]).flows(through: 1))
        // The first key's own pace is of no stretch, and stops nothing.
        #expect(track([[0], [10], [30]], eases: [0: .hold]).flows(through: 1))
    }

    @Test func leftToBezzleAStretchComesHomeGentlyAndElsewhereGentlyBothWays() {
        let home = MotionTrack([MotionKey(t: 0, v: [40, 0]), MotionKey(t: 0.5, v: [0, 0])])
        #expect(home.pace(of: 0, rest: [0, 0]) == .curve(.easeOut, bounce: 0.3))
        let away = MotionTrack([MotionKey(t: 0, v: [0, 0]), MotionKey(t: 0.5, v: [40, 0])])
        #expect(away.pace(of: 0, rest: [0, 0]) == .curve(.smooth, bounce: 0.3))
        let elsewhere = MotionTrack([MotionKey(t: 0, v: [10, 0]), MotionKey(t: 0.5, v: [40, 0])])
        #expect(elsewhere.pace(of: 0, rest: [0, 0]) == .curve(.smooth, bounce: 0.3))
        let still = MotionTrack([MotionKey(t: 0, v: [0, 0]), MotionKey(t: 0.5, v: [0, 0])])
        #expect(still.pace(of: 0, rest: [0, 0]) == .curve(.smooth, bounce: 0.3))
        // A pace that was chosen is the stretch's, with its bounce or the usual one.
        for kind in MotionEase.Kind.allCases where kind != .auto {
            let chosen = MotionTrack([MotionKey(t: 0, v: [40, 0]), MotionKey(t: 0.5, v: [0, 0], ease: MotionEase(kind: kind))])
            #expect(chosen.pace(of: 0, rest: [0, 0]) == .curve(kind, bounce: 0.3), "\(kind)")
        }
        let sprung = MotionTrack([MotionKey(t: 0, v: [40, 0]), MotionKey(t: 0.5, v: [0, 0], ease: .spring(0.7))])
        #expect(sprung.pace(of: 0, rest: [0, 0]) == .curve(.spring, bounce: 0.7))
    }

    @Test func aChosenPaceAmongOnesLeftToBezzleKeepsItsOwnStretchOnly() {
        var n = card()
        for i in 0...5 { n.setKey(.turn, [Double(i) * 30], at: Double(i), ease: i == 2 ? .linear : nil) }
        let track = n[track: .turn]!
        // The flight is broken at the stretch that was chosen, and begins again after it.
        #expect((0...5).map { track.flows(through: $0) } == [false, false, false, true, true, false])
        #expect((0..<5).map { track.pace(of: $0, rest: [0]) } == [.curve(.smooth, bounce: 0.3), .curve(.linear, bounce: 0.3), .setOff, .onward, .setDown])
        #expect(near(n.value(of: .turn, at: 1.5)[0], 45))
        // Where the flight goes on again it still does not jump.
        for t in [2.0, 3, 4] {
            #expect(abs(n.value(of: .turn, at: t - 1e-6)[0] - n.value(of: .turn, at: t)[0]) < 1e-3, "before \(t)")
            #expect(abs(n.value(of: .turn, at: t + 1e-6)[0] - n.value(of: .turn, at: t)[0]) < 1e-3, "after \(t)")
        }
    }

    @Test func noValueIsEverNotANumberAndNoneJumpsWhereStretchesMeet() {
        var dice = MotionDice(seed: 11)
        let kinds: [MotionEase.Kind?] = [nil, nil, nil, nil, .auto, .smooth, .easeIn, .easeOut, .linear, .spring, .hold]
        var trouble: String?
        for round in 0..<600 where trouble == nil {
            let p = dice.pick(MotionProperty.allCases), rest = p == .shape ? Array(repeating: 0, count: 12) : p.rest
            var keys: [MotionKey] = []
            var t = dice.chance(0.5) ? 0 : dice.number(0...2)
            var v = rest.map { $0 + dice.number(-200...200) }
            for _ in 0..<Int.random(in: 2...8, using: &dice) {
                let kind = dice.pick(kinds)
                let ease = kind.map { MotionEase(kind: $0, bounce: $0 == .spring ? dice.number(0...1) : nil) }
                keys.append(MotionKey(t: t, v: v, ease: ease))
                t += dice.pick([0.05, 0.1, 0.25, 0.5, 1, 1.5, 0.005])
                // Mostly onward, so that flights happen; sometimes back, sometimes not at all.
                let turn = dice.pick([1.0, 1, 1, 1, -1, 0])
                v = v.map { $0 + turn * dice.number(5...150) }
                if dice.chance(0.15) { v = rest }
            }
            let track = MotionTrack(keys)
            let size = 1 + (track.keys.flatMap(\.v).map(abs).max() ?? 0)
            func value(_ at: Double) -> [Double] { track.value(at: at, rest: rest) }
            func bad(_ x: [Double]) -> Bool { x.count != rest.count || !x.allSatisfy(\.isFinite) }
            for (i, key) in track.keys.enumerated() where trouble == nil {
                if value(key.t) != key.v { trouble = "round \(round) \(p): not on key \(i)" }
                // Into a held key the value jumps, as it is meant to; into any other it arrives.
                let holds = key.ease?.kind == .hold
                let before = value(key.t - 1e-8), after = value(key.t + 1e-8)
                if bad(before) || bad(after) { trouble = "round \(round) \(p): no number beside key \(i)"; break }
                let arriving = holds ? 0 : zip(before, key.v).map { abs($0 - $1) }.max()!
                let leaving = zip(after, key.v).map { abs($0 - $1) }.max()!
                if arriving > 2e-3 * size || leaving > 2e-3 * size { trouble = "round \(round) \(p): jumps by \(max(arriving, leaving)) at key \(i) of \(track.keys.map(\.t))" }
            }
            // And within each stretch, sampled closely, nothing leaps either.
            for i in track.keys.indices.dropLast() where trouble == nil && track.keys[i + 1].ease?.kind != .hold {
                let a = track.keys[i].t, b = track.keys[i + 1].t
                var last = value(a)
                for s in 1...400 {
                    let now = value(a + (b - a) * Double(s) / 400)
                    if bad(now) { trouble = "round \(round) \(p): no number in stretch \(i)"; break }
                    if zip(now, last).map({ abs($0 - $1) }).max()! > 0.25 * size { trouble = "round \(round) \(p): leaps in stretch \(i)"; break }
                    last = now
                }
            }
        }
        #expect(trouble == nil, "\(trouble ?? "")")
    }

    @Test func throughAKeyOfAFlightTheSpeedIsTheSameBeforeAndAfter() {
        // Stretches of unequal length and distance, all going on.
        var n = card()
        let times = [0.0, 0.4, 1.3, 1.6, 3], values = [0.0, 30, 200, 230, 600]
        for (t, v) in zip(times, values) { n.setKey(.move, [v, -v / 2], at: t) }
        let dt = 1e-5
        for (i, t) in times.enumerated() where i > 0 && i < times.count - 1 {
            #expect(n[track: .move]!.flows(through: i))
            let at = n.value(of: .move, at: t)[0]
            let before = (at - n.value(of: .move, at: t - dt)[0]) / dt, after = (n.value(of: .move, at: t + dt)[0] - at) / dt
            // The speed there is the one from the key before to the key after.
            let through = (values[i + 1] - values[i - 1]) / (times[i + 1] - times[i - 1])
            #expect(abs(before - through) < 0.01 * through && abs(after - through) < 0.01 * through, "key \(i): \(before) then \(after), meant \(through)")
        }
        // It leaves the first key from rest and comes to rest on the last.
        #expect(n.value(of: .move, at: dt)[0] / dt < 1)
        #expect((600 - n.value(of: .move, at: 3 - dt)[0]) / dt < 1)
    }

    // MARK: Whatever is done, in whatever order

    /// What must hold of a layer's motion after anything at all was done to it.
    private func trouble(in node: Node) -> String? {
        guard let motion = node.motion else { return nil }
        if motion.isEmpty { return "\(node.name): motion is empty rather than none" }
        for (name, track) in motion {
            guard let p = MotionProperty(rawValue: name) else { return "\(node.name): a property called \(name)" }
            if track.keys.isEmpty { return "\(node.name) \(name): a track with no keys" }
            for (i, key) in track.keys.enumerated() {
                if !key.t.isFinite || key.t < 0 { return "\(node.name) \(name): a key at \(key.t)" }
                if key.t != MotionTiming.time(key.t) { return "\(node.name) \(name): a key at \(key.t), kept finer than a thousandth" }
                if i > 0, !(track.keys[i - 1].t < key.t) || MotionTiming.same(track.keys[i - 1].t, key.t) {
                    return "\(node.name) \(name): keys at \(track.keys[i - 1].t) and \(key.t)"
                }
                if key.v.count != p.rest.count { return "\(node.name) \(name): \(key.v.count) numbers" }
                if !key.v.allSatisfy(\.isFinite) || p.clamped(key.v) != key.v { return "\(node.name) \(name): a value of \(key.v)" }
                if let ease = key.ease, ease.kind == .auto { return "\(node.name) \(name): a pace kept that says nothing" }
                if let bounce = key.ease?.bounce, !bounce.isFinite { return "\(node.name) \(name): a bounce of \(bounce)" }
            }
        }
        return nil
    }

    @Test(arguments: [1, 2, 3, 2026] as [UInt64])
    func whateverIsDoneInWhateverOrderALayersMotionStaysInOrder(seed: UInt64) {
        var dice = MotionDice(seed: seed)
        var text = Node(kind: .text, name: "Words", frame: CGRect(x: 10, y: 10, width: 80, height: 20))
        text.text = "Hello"
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 200, y: 40, width: 100, height: 60))
        group.children = [card("In group", CGRect(x: 0, y: 0, width: 60, height: 40)), text]
        var loose = card("Loose", CGRect(x: 900, y: 0, width: 50, height: 50))
        loose.id = UUID()
        var start = BezzleDocument()
        start.nodes = [board([card("One"), group, card("Two", CGRect(x: 300, y: 200, width: 60, height: 60))]), loose]
        let ids = start.allNodes.map(\.id), boardID = start.nodes[0].id

        let times: [Double] = [0, 0, 0.004, 0.005, 0.25, 0.5, 0.504, 1, 1.0004, 1.5, 2, 3.25, -1, 1e-9, .nan, .infinity]
        func time() -> Double { dice.chance(0.3) ? dice.number(0...4) : dice.pick(times) }
        func value(_ p: MotionProperty) -> [Double] {
            switch Int.random(in: 0..<12, using: &dice) {
            case 0: return p.rest
            case 1: return []
            case 2: return [.nan, .infinity]
            case 3: return [1e9, -1e9, 3]
            case 4: return [dice.number(-2...2)]
            default: return p.rest.map { $0 + dice.number(-300...300) }
            }
        }
        func ease() -> MotionEase {
            let kind = dice.pick(MotionEase.Kind.allCases)
            return MotionEase(kind: kind, bounce: kind == .spring && dice.chance(0.7) ? dice.number(0...1) : nil)
        }
        func some(_ all: [MotionProperty]) -> [MotionProperty] { dice.chance(0.3) ? all : [dice.pick(all)] }

        var said: String?
        for sequence in 0..<600 where said == nil {
            var doc = start
            for step in 0..<12 where said == nil {
                let id = dice.pick(ids)
                // Mostly a layer's own properties for a layer and the camera's for the artboard.
                let own = id == boardID ? MotionProperty.camera : MotionProperty.layer
                let p = dice.chance(0.9) ? dice.pick(own) : dice.pick(MotionProperty.allCases)
                var did = ""
                switch Int.random(in: 0..<16, using: &dice) {
                case 0...4:
                    let v = value(p), t = time()
                    did = "pose \(p) \(v) at \(t)"
                    doc.update(id) { $0.pose(p, v, at: t) }
                case 5...7:
                    let v = value(p), t = time(), e: MotionEase? = dice.chance(0.5) ? ease() : nil
                    did = "setKey \(p) \(v) at \(t) \(String(describing: e))"
                    doc.update(id) { $0.setKey(p, v, at: t, ease: e) }
                case 8:
                    let t = time(), of = some(own)
                    did = "removeKeys at \(t) of \(of)"
                    doc.update(id) { n in n.removeKeys(at: dice.chance(0.6) ? n.keyTimes(MotionProperty.allCases).first ?? t : t, of: of) }
                case 9, 10:
                    let to = time(), of = some(own)
                    did = "moveKeys to \(to) of \(of)"
                    doc.update(id) { n in
                        let held = n.keyTimes(MotionProperty.allCases)
                        n.moveKeys(from: held.isEmpty ? 1 : dice.pick(held), to: to, of: of)
                    }
                case 11:
                    let e = ease(), of = some(own)
                    did = "setEase \(e) of \(of)"
                    doc.update(id) { n in
                        let held = n.keyTimes(MotionProperty.allCases)
                        n.setEase(e, at: held.isEmpty ? 1 : dice.pick(held), of: of)
                    }
                case 12:
                    let by = dice.pick([0.5, -0.5, -0.004, 0.0004, 2.3333, -10, .nan, .infinity] as [Double]), of = some(MotionProperty.allCases)
                    did = "shiftKeys by \(by) of \(of)"
                    doc.update(id) { $0.shiftKeys(by: by, of: of) }
                case 13, 14:
                    let move = dice.pick(MotionMove.allCases), t = time(), going = dice.chance(0.4), apart = dice.pick([0, 0.1, -1] as [Double])
                    let several = dice.chance(0.5) ? ids : [id]
                    did = "apply \(move) at \(t) going \(going) apart \(apart) to \(several.count)"
                    doc.apply(move, to: several, at: t, going: going, apart: apart)
                default:
                    did = "clearMotion"
                    doc.clearMotion([id])
                }
                for node in doc.allNodes {
                    if let found = trouble(in: node) { said = "seed \(seed), sequence \(sequence), step \(step), after \(did): \(found)" }
                    // Whatever it holds, a layer still says numbers within what shows at any moment.
                    for q in node.motionProperties {
                        let now = node.value(of: q, at: dice.number(-1...6))
                        if now != q.clamped(now) || !now.allSatisfy(\.isFinite) { said = "seed \(seed), sequence \(sequence), step \(step), after \(did): \(node.name) \(q) is \(now)" }
                    }
                }
                // Only what was done to its motion has changed a layer.
                if doc.nodes.map(\.atRest) != start.nodes { said = "seed \(seed), sequence \(sequence), step \(step), after \(did): more than motion changed" }
            }
            guard said == nil else { break }
            // As a file keeps it and gives it back.
            guard let data = try? JSONEncoder().encode(doc) else { said = "seed \(seed), sequence \(sequence): the design cannot be written"; break }
            let back = try? JSONDecoder().decode(BezzleDocument.self, from: data)
            if back != doc { said = "seed \(seed), sequence \(sequence): the design does not come back from its file as it went" }
            if doc.nodes[0].filmLength < MotionTiming.shortest || !doc.nodes[0].filmLength.isFinite { said = "seed \(seed), sequence \(sequence): a film \(doc.nodes[0].filmLength) long" }
        }
        #expect(said == nil, "\(said ?? "")")
    }

    @Test func aKeyAtNoMomentAtAllCannotBeMadeForItWouldStopTheDesignBeingSaved() throws {
        // A number that is none cannot be written to a design's file: the whole save fails.
        var broken = MotionKey(t: 1, v: [0])
        broken.t = .nan
        #expect(throws: (any Error).self) { try JSONEncoder().encode(broken) }
        // So no way of making a key lets one in.
        #expect(MotionKey(t: .nan, v: [0]).t == 0 && MotionKey(t: .infinity, v: [0]).t == 0 && MotionKey(t: -.infinity, v: [0]).t == 0)
        #expect(MotionTiming.time(.nan) == 0)
        var n = card()
        n.setKey(.move, [1, 1], at: .nan)
        n.pose(.turn, [10], at: .infinity)
        n.setKey(.fade, [0.5], at: 1)
        n.moveKeys(from: 1, to: .nan, of: [.fade])
        #expect(n.keyTimes() == [0, MotionTiming.beat])
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(n)) == n)
    }
}

extension Node {
    /// The layer and all it holds with no motion and no film: the design alone.
    var atRest: Node {
        var n = self
        n.motion = nil
        n.film = nil
        n.children = children.map(\.atRest)
        return n
    }

    /// The same layer under another identity, to compare two made the same way.
    func with(id: UUID) -> Node {
        var n = self
        n.id = id
        return n
    }

    /// The layer changed, in one expression.
    func with(_ change: (inout Node) -> Void) -> Node {
        var n = self
        change(&n)
        return n
    }
}
