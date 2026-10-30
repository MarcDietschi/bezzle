import Testing
@testable import Bezzle

struct ScrubTests {
    private func scrub(from: Double = 50, range: ClosedRange<Double> = 0...100, rate: Double = 1, decimals: Int = 0) -> Scrub {
        Scrub(from: from, range: range, rate: rate, decimals: decimals, step: 1)
    }

    @Test func theValueFollowsThePointerAtItsRate() {
        var s = scrub(rate: 0.5)
        var moved = s.move(10, pace: .normal)
        #expect(moved && s.value == 55)
        moved = s.move(-30, pace: .normal)
        #expect(moved && s.value == 40)
        moved = s.move(0.4, pace: .normal)
        #expect(!moved)
    }

    @Test func optionIsFineAndShiftIsCoarseInWholeTens() {
        var s = scrub(decimals: 1)
        _ = s.move(10, pace: .fine)
        #expect(s.value == 51)
        // A new pace carries on from where the value is, without a jump.
        _ = s.move(1.3, pace: .coarse)
        #expect(s.value == 60)
        _ = s.move(1, pace: .coarse)
        #expect(s.value == 70)
        // Letting go of Shift carries on from the ten it showed.
        _ = s.move(1, pace: .normal)
        #expect(s.value == 71)
    }

    @Test func atALimitItStopsAndTurnsBackAtOnce() {
        var s = scrub(from: 90)
        _ = s.move(40, pace: .normal)
        #expect(s.value == 100 && s.strain == 30)
        _ = s.move(25, pace: .normal)
        #expect(s.value == 100 && s.strain == 55)
        // However far past it went, coming back moves the value straight away.
        let moved = s.move(-5, pace: .normal)
        #expect(moved && s.value == 95 && s.strain == 0)
    }

    @Test func itStartsWithinTheRange() {
        let s = scrub(from: 140)
        #expect(s.value == 100 && s.from == 100)
    }
}
