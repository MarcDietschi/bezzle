import Foundation
import Testing
@testable import FilmRules

/// The timeline's sheet looked at closer (Host/FilmSheet.swift), as the Mac's FilmZoomTests have
/// its ruler, with the Mac's own cases: the numbers thin out and fill in, only the strokes in
/// sight are drawn, the stroke under the lines says which part shows, the wheel does what it does
/// on the canvas, and the sheet creeps only under a hand past its ends.
struct FilmSheetTests {
    /// How close a sheet can be looked at, in points a second (the shared FilmWindow.closest),
    /// and the room either side of its moments (FilmScale.inset).
    let closest = 1200.0
    let inset = 14.0

    // MARK: The ruler

    @Test func theRulersNumbersThinOutAndFillIn() {
        var last = Double.infinity
        var steps: Set<Double> = []
        for i in 0...200 {
            // From a second one point wide to the closest there is.
            let perSecond = pow(closest, Double(i) / 200)
            let (major, parts) = FilmSheet.step(perSecond)
            steps.insert(major)
            // The numbers stand clear of each other, and the strokes between them can be told apart.
            #expect(major * perSecond >= 52, "\(perSecond) points a second")
            #expect(major * perSecond < 52 * 3.1, "\(perSecond) points a second")
            #expect(major / Double(parts) * perSecond >= 5, "\(perSecond) points a second")
            // Closer, never fewer numbers.
            #expect(major <= last, "\(perSecond) points a second")
            last = major
        }
        #expect(steps.count >= 10)
        // As close as it goes: a number every twentieth of a second, a stroke every hundredth.
        #expect(FilmSheet.step(closest) == (0.05, 5))
        // Tenths are halved, where a key steps, until hundredths can be told apart.
        #expect(FilmSheet.step(560) == (0.1, 2) && FilmSheet.step(700) == (0.1, 10))
        // A whole film's ruler is the one there always was.
        #expect(FilmSheet.step(257.4) == (0.5, 5) && FilmSheet.step(60) == (1, 10) && FilmSheet.step(1) == (60, 6))
    }

    @Test func aRulerDrawsOnlyTheStrokesInSight() {
        // A whole film of two and a half seconds on a sheet 600 wide: from its start.
        let whole = (perSecond: (600 - inset * 2) / 2.5, origin: inset)
        let all = FilmSheet.strokes(perSecond: whole.perSecond, origin: whole.origin, width: 600)
        #expect(all.first == 0 && all.major == 0.5 && all.parts == 5)
        func x(_ i: Int, _ scale: (perSecond: Double, origin: Double), _ minor: Double) -> Double { scale.origin + Double(i) * minor * scale.perSecond }
        #expect(x(all.end - 1, whole, 0.1) <= 598 && x(all.end, whole, 0.1) > 598)
        // Ten minutes in, as close as it goes: a few dozen strokes, not the sixty thousand before them.
        let close = (perSecond: closest, origin: inset - 600 * closest)
        let some = FilmSheet.strokes(perSecond: close.perSecond, origin: close.origin, width: 600)
        #expect(some.end - some.first < 80 && some.first > 59_000)
        // The first is a numbered one, at the left edge or the last before it, so its number shows.
        #expect(some.first % some.parts == 0)
        let left = x(some.first, close, some.major / Double(some.parts))
        #expect(left <= 0.001 && left > -some.major * close.perSecond - 0.001)
        // A sheet moved far out of the film, or one no number can be told of, draws none and does not fail.
        let none = FilmSheet.strokes(perSecond: 100, origin: 5000, width: 600)
        #expect(none.end == none.first)
        #expect(FilmSheet.strokes(perSecond: 100, origin: .nan, width: 600).end == 0)
    }

    @Test func numbersPastAMinuteKeepThePartsOfASecond() {
        #expect(FilmSheet.label(0.75) == "0.75" && FilmSheet.label(12, step: 0.5) == "12" && FilmSheet.label(0.5) == "0.5" && FilmSheet.label(0) == "0")
        #expect(FilmSheet.label(75, step: 5) == "1:15" && FilmSheet.label(600, step: 60) == "10:00")
        #expect(FilmSheet.label(61.5, step: 0.5) == "1:01.5" && FilmSheet.label(600.05, step: 0.05) == "10:00.05")
        #expect(FilmSheet.label(62, step: 0.5) == "1:02" && FilmSheet.label(119.99, step: 0.05) == "1:59.99")
    }

    // MARK: Which part shows

    @Test func theStrokeUnderTheLinesIsAsLongAndAsFarAlongAsThePartShown() {
        let room = 600 - inset * 2
        // A quarter of the film, at its start, in its middle and at its end.
        let first = FilmSheet.thumb(width: 600, inset: inset, start: 0, span: 2.5, whole: 10)
        #expect(first.x == inset && abs(first.long - room / 4) < 1e-9)
        let middle = FilmSheet.thumb(width: 600, inset: inset, start: 3.75, span: 2.5, whole: 10)
        #expect(abs(middle.x + middle.long / 2 - 300) < 1e-9)
        let end = FilmSheet.thumb(width: 600, inset: inset, start: 7.5, span: 2.5, whole: 10)
        #expect(abs(end.x + end.long - (600 - inset)) < 1e-9)
        // As close as it goes on a long film it is still there to see, and within the sheet.
        let close = FilmSheet.thumb(width: 600, inset: inset, start: 300, span: room / closest, whole: 600)
        #expect(close.long == 18 && close.x >= inset && close.x + close.long <= 600 - inset)
    }

    // MARK: The wheel

    @Test func theWheelLooksCloserAndMovesAlongAsItDoesOnTheCanvas() {
        // A notch of the wheel is 120: a fifth closer, and back out by as much.
        #expect(abs(FilmSheet.closer(byWheel: 120) - 1.197) < 0.001)
        #expect(abs(FilmSheet.closer(byWheel: 120) * FilmSheet.closer(byWheel: -120) - 1) < 1e-12)
        #expect(FilmSheet.closer(byWheel: 0) == 1)
        // Turned to the right, the moments go left: later ones come into sight.
        #expect(FilmSheet.along(byWheel: 120) == -120 && FilmSheet.along(byWheel: -30) == 30)
    }

    // MARK: Past the ends

    @Test func theSheetCreepsOnlyUnderAPointerPastItsEnds() {
        // Within the sheet, its first and last moments included, nothing.
        for x in [inset, 300, 600 - inset] { #expect(FilmSheet.creepRate(at: x, width: 600, inset: inset) == 0) }
        // Just past the end slowly, further out faster, and never faster than a sheet can be read.
        let near = FilmSheet.creepRate(at: 600 - inset + 1, width: 600, inset: inset)
        let far = FilmSheet.creepRate(at: 600 + 40, width: 600, inset: inset)
        #expect(near == 52 && far > near && FilmSheet.creepRate(at: 5000, width: 600, inset: inset) == 1600)
        // Before the start, the other way, alike.
        #expect(FilmSheet.creepRate(at: inset - 1, width: 600, inset: inset) == -52)
        #expect(FilmSheet.creepRate(at: -5000, width: 600, inset: inset) == -1600)
    }
}
