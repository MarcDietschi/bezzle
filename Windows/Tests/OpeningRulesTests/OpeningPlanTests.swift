import Foundation
import Testing
@testable import OpeningRules

/// The cover over a design while it opens, as Windows' compositor moves it (Host/OpeningPlan.swift),
/// against the shared numbers the Mac moves its own by (Model/OpeningCover.swift): the same moments,
/// the same rests, nothing still moving when the paper may lift, and the lift within its time.
struct OpeningPlanTests {
    /// When it begins moving, and when it rests (a breath never does).
    private func span(_ m: OpeningPlan.Move) -> ClosedRange<Double> { m.at...(m.at + m.duration) }

    @Test func eachSheetIsStruckWhenTheMacStrikesIt() {
        let moves = OpeningPlan.pressing(calm: false)
        for (i, strike) in OpeningMark.strikes.enumerated() {
            let sheet = moves.filter { $0.target == .sheet(i) }
            #expect(sheet.count == 2)
            #expect(sheet.allSatisfy { $0.at == strike })
            let scale = sheet.first { $0.property == .scale }
            #expect(scale?.from == Double(OpeningMark.strikeFrom) && scale?.to == 1)
            // A hair past and back, as a spring lands.
            #expect((scale?.keys.map(\.value).min() ?? 1) < 1)
            #expect(sheet.first { $0.property == .opacity }?.to == 1)
        }
    }

    @Test func theNameIsSetLetterByLetterFromAbove() {
        let moves = OpeningPlan.pressing(calm: false)
        for i in 0..<OpeningMark.word.count {
            let letter = moves.filter { $0.target == .letter(i) }
            #expect(letter.count == 3)
            #expect(letter.allSatisfy { $0.at == OpeningMark.sets(i) })
            let drop = letter.first { $0.property == .drop }
            #expect((drop?.from ?? 0) < 0 && drop?.to == 0)
        }
        #expect(OpeningPlan.word == "Bezzle")
    }

    /// Everything but the breath is at rest before the mark may lift, and the breath begins only
    /// after: a short wait never sees it begin to.
    @Test func theGestureIsDoneBeforeTheMarkMayLift() {
        for move in OpeningPlan.pressing(calm: false) {
            if move.breathing {
                #expect(move.at > OpeningCover.least)
                #expect(move.from == 1 && move.to == Double(OpeningMark.shallowest))
            } else {
                // The springs settle a little later, a hair from their rest.
                let rest = move.keys.first { abs($0.value - move.to) < 0.01 * max(abs(move.from - move.to), 0.01) }
                #expect(move.at + (rest?.progress ?? 1) * move.duration <= OpeningCover.least + 0.1, "\(move.target) \(move.property)")
                #expect(move.keys.first?.progress == 0 && move.keys.last?.progress == 1)
            }
        }
        // Only the walls, floors and the paper round them breathe; the ink stays as it ran in.
        #expect(!OpeningPlan.pressing(calm: false).contains { $0.breathing && $0.target == .ink })
        #expect(OpeningPlan.pressing(calm: false).contains { $0.target == .ink && $0.property == .inked && $0.to == 1 })
    }

    @Test func theLiftTakesItsTime() {
        for marked in [true, false] {
            for calm in [true, false] {
                let moves = OpeningPlan.lifting(marked: marked, calm: calm)
                let end = moves.map { $0.at + $0.duration }.max() ?? 0
                #expect(abs(end - (marked ? OpeningCover.lifting : OpeningCover.quick)) < 1e-9, "marked \(marked), calm \(calm)")
                // The paper clears in the end.
                #expect(moves.contains { $0.target == .paper && $0.to == 0 })
            }
        }
        // The mark goes before the paper is through.
        let lift = OpeningPlan.lifting(marked: true, calm: false)
        let mark = lift.first { $0.target == .mark && $0.property == .opacity }
        let paper = lift.first { $0.target == .paper }
        #expect(mark.map { $0.at + $0.duration } ?? 1 < paper.map { $0.at + $0.duration } ?? 0)
    }

    /// Calm, the mark only fades in, all at once.
    @Test func calmTheMarkOnlyFades() {
        let moves = OpeningPlan.pressing(calm: true)
        #expect(moves.allSatisfy { $0.property == .opacity && $0.at == 0 && !$0.breathing })
        #expect(Set(moves.map(\.target)) == [.mark, .word])
    }

    /// The cover's timing is the shared one.
    @Test func theCoverWaitsAsTheMacsDoes() {
        let quick = OpeningPlan.Cover(began: 5, growing: false)
        #expect(quick.marks == 5 + OpeningCover.grace)
        #expect(!quick.lift(readyAt: 5.1).marked)
        let growing = OpeningPlan.Cover(began: 5, growing: true)
        #expect(growing.lift(readyAt: 5.1) == (5 + OpeningCover.least, true))
        #expect(growing.gone(readyAt: 9) == 9 + OpeningCover.lifting)
    }

    /// Laid out in a room: the mark over its name, together a little above the middle; the parts
    /// each sheet has; where it is struck about.
    @Test func itSitsALittleAboveTheMiddle() {
        let at = OpeningPlan.place(width: 1000, height: 800, capHeight: 20)
        let middle = at.markTop + (OpeningPlan.side + OpeningPlan.wordGap + 20) / 2
        #expect(middle < 400 && middle > 400 - 800 * OpeningPlan.lift - 1)
        #expect(at.markLeft == 500 - OpeningPlan.side / 2)
        #expect(at.wordTop == at.markTop + OpeningPlan.side + OpeningPlan.wordGap)
        #expect(OpeningPlan.parts(of: 0) == [.rim, .floor, .walls])
        #expect(OpeningPlan.parts(of: OpeningPlan.sheets - 1) == OpeningPlan.Part.allCases)
        let outer = OpeningPlan.middle(of: 0)
        #expect(abs(outer.x - OpeningPlan.markSize / 2) < 1e-9 && abs(outer.y - OpeningPlan.markSize / 2) < 1e-9)
        #expect(OpeningPlan.middle(of: 2).x > outer.x)
    }
}
