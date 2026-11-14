import Foundation
import Testing
@testable import FilmRules

/// Where the view goes when the desk turns to a film (Host/FilmFraming.swift), as the Mac's
/// AnimateStoreTests have it: the film's artboard comes to lie whole above the timeline, however
/// many of its lines the card shows, and moves only the way it has to.
struct FilmFramingTests {
    /// A window 1000 by 700 points; a film's artboard 300 by 400 at 600, 0, beside another at 0, 0.
    let canvas = (w: 1000.0, h: 700.0)
    let film = (x: 600.0, y: 0.0, w: 300.0, h: 400.0)

    func turned(lines: Int, from view: FilmFraming.View) -> FilmFraming.View? {
        FilmFraming.framed(x: film.x, y: film.y, width: film.w, height: film.h, from: view,
                           roomWidth: canvas.w, roomHeight: canvas.h - FilmFraming.foot(lines: lines))
    }

    @Test func theCardGrowsWithTheFilmsLinesFromFourToSeven() {
        #expect(FilmFraming.shown(of: 0) == 4 && FilmFraming.shown(of: 5) == 5 && FilmFraming.shown(of: 12) == 7)
        #expect(FilmFraming.foot(lines: 2) == FilmFraming.foot(lines: 4))
        #expect(FilmFraming.foot(lines: 7) == FilmFraming.foot(lines: 4) + 3 * FilmFraming.rowHeight)
        #expect(FilmFraming.foot(lines: 30) == FilmFraming.foot(lines: 7))
    }

    @Test func anArtboardClearOfALowCardStaysWhereItLies() {
        // The view's top left at -50, -100 on the canvas, life size.
        #expect(turned(lines: 2, from: FilmFraming.View(zoom: 1, panX: 50, panY: 100)) == nil)
    }

    @Test func underATallerCardItMovesUpAndStaysFromSideToSide() throws {
        let start = FilmFraming.View(zoom: 1, panX: 50, panY: 100)
        let foot = FilmFraming.foot(lines: 7)
        let to = try #require(turned(lines: 7, from: start))
        // Whole above the card, twelve points clear, in the middle from top to bottom, drawn back
        // as far as it must.
        let top = film.y * to.zoom + to.panY, bottom = (film.y + film.h) * to.zoom + to.panY
        #expect(top >= 12 && bottom <= canvas.h - foot - 12)
        #expect(abs((top + bottom) / 2 - (canvas.h - foot) / 2) < 0.5)
        #expect(to.zoom < 1 && to.zoom > 0.85)
        // What was in the middle from side to side still is, and the artboard beside it shows.
        #expect(abs((canvas.w / 2 - to.panX) / to.zoom - (-50 + canvas.w / 2)) < 0.01)
        #expect(0 * to.zoom + to.panX > 0)
    }

    @Test func outOfSightAtTheSideItComesToTheMiddleBothWays() throws {
        let foot = FilmFraming.foot(lines: 7)
        let to = try #require(turned(lines: 7, from: FilmFraming.View(zoom: 1, panX: 600, panY: 100)))
        let midX = (film.x + film.w / 2) * to.zoom + to.panX, midY = (film.y + film.h / 2) * to.zoom + to.panY
        #expect(abs(midX - canvas.w / 2) < 0.5 && abs(midY - (canvas.h - foot) / 2) < 0.5)
    }

    @Test func aViewFromFurtherOffLooksNoCloserThanLifeSize() throws {
        // Seen at a quarter, out of sight: it comes as close as life size where there is room.
        let small = FilmFraming.framed(x: 0, y: 0, width: 200, height: 100, from: FilmFraming.View(zoom: 0.25, panX: -4000, panY: 0),
                                       roomWidth: 1000, roomHeight: 500)
        #expect(try #require(small).zoom == 1)
        // Looked at three times closer, it draws back to twice at most.
        let close = FilmFraming.framed(x: 0, y: 0, width: 200, height: 100, from: FilmFraming.View(zoom: 3, panX: -4000, panY: 0),
                                       roomWidth: 1000, roomHeight: 500)
        #expect(try #require(close).zoom == 2)
    }
}
