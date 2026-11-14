import Foundation
import Testing
@testable import FilmRules

/// When Animate takes a shape's points in hand and puts them down (Host/FilmPointRules.swift), as
/// the Mac's AnimateCanvasPathTests have it: a double click on a shape picked alone takes them up;
/// a press off them pulls a loop round some; a double click there, or a press on another layer,
/// puts them down; picking anything else puts them down; the Pose card's chip says Done for them;
/// Delete takes the picked ones away while an outline is left.
struct FilmPointRulesTests {
    let shape = UUID(), card = UUID(), group = UUID()

    @Test func aDoubleClickOnAShapePickedAloneTakesItsPointsInHand() {
        #expect(FilmPointRules.takesInHand(clicks: 2, pressed: shape, selection: [shape], deepest: shape, reshapes: true, locked: false))
        // The first click only picks it.
        #expect(!FilmPointRules.takesInHand(clicks: 1, pressed: shape, selection: [shape], deepest: shape, reshapes: true, locked: false))
        // Nor a third.
        #expect(!FilmPointRules.takesInHand(clicks: 3, pressed: shape, selection: [shape], deepest: shape, reshapes: true, locked: false))
        // Pressed, but something else is picked, or more than it.
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: shape, selection: [card], deepest: shape, reshapes: true, locked: false))
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: shape, selection: [shape, card], deepest: shape, reshapes: true, locked: false))
        // Nothing pressed.
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: nil, selection: [shape], deepest: nil, reshapes: true, locked: false))
    }

    @Test func aDoubleClickOnAnythingElseGoesFurtherInAsBefore() {
        // A group picked with a shape of it under the pointer: the second click goes into it.
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: group, selection: [group], deepest: shape, reshapes: false, locked: false))
        // A layer whose outline is not points (a text, a picture, a group).
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: card, selection: [card], deepest: card, reshapes: false, locked: false))
        // A locked shape keeps its points.
        #expect(!FilmPointRules.takesInHand(clicks: 2, pressed: shape, selection: [shape], deepest: shape, reshapes: true, locked: true))
    }

    @Test func aPressOffThePointsPullsALoopOrPutsThemDown() {
        // On the shape itself, off its points: a loop that stays when clicked.
        #expect(FilmPointRules.press(on: shape, editing: shape, clicks: 1) == .loop(leaves: false))
        // On the bare film: a loop, and a click that does not drag puts them down.
        #expect(FilmPointRules.press(on: nil, editing: shape, clicks: 1) == .loop(leaves: true))
        // A double click on either puts them down.
        #expect(FilmPointRules.press(on: shape, editing: shape, clicks: 2) == .putDown)
        #expect(FilmPointRules.press(on: nil, editing: shape, clicks: 2) == .putDown)
        // Another layer: down, and that one picked, however many clicks.
        #expect(FilmPointRules.press(on: card, editing: shape, clicks: 1) == .passOn)
        #expect(FilmPointRules.press(on: card, editing: shape, clicks: 2) == .passOn)
    }

    @Test func pointsInHandStayOnlyWhileTheirShapeIsTheOnePicked() {
        #expect(FilmPointRules.keeps(shape, picked: [shape]))
        #expect(!FilmPointRules.keeps(shape, picked: []))
        #expect(!FilmPointRules.keeps(shape, picked: [card]))
        #expect(!FilmPointRules.keeps(shape, picked: [shape, card]))
    }

    @Test func thePoseCardsChipSaysDoneForThePointsInHand() {
        #expect(FilmPointRules.chip(editing: nil, picked: [shape]) == (false, true))
        #expect(FilmPointRules.chip(editing: shape, picked: [shape]) == (true, true))
        #expect(FilmPointRules.chip(editing: shape, picked: [card]) == (false, true))
        // Several picked: Edit Points, dimmed.
        #expect(FilmPointRules.chip(editing: nil, picked: [shape, card]) == (false, false))
        #expect(FilmPointRules.chip(editing: nil, picked: []) == (false, false))
    }

    @Test func drawAndShapeShowOnlyWhenEveryLayerPickedIsAShape() {
        #expect(FilmPointRules.showsShape([true]))
        #expect(FilmPointRules.showsShape([true, true]))
        #expect(!FilmPointRules.showsShape([true, false]))
        #expect(!FilmPointRules.showsShape([]))
    }

    /// Delete with points picked takes them away at the playhead, as the Mac's FilmPoints does,
    /// while what is left can be drawn: the last of a shape's points stay, and the canvas beeps.
    @Test func pointsAreTakenAwayWhileARunKeepsTwo() {
        // A triangle less one point is a line, which a key can hold.
        #expect(FilmPointRules.leavesAnOutline(runs: [2]))
        #expect(FilmPointRules.leavesAnOutline(runs: [5]))
        // Of two runs one is gone (the shared path drops a run left with fewer than two): the other is drawn.
        #expect(FilmPointRules.leavesAnOutline(runs: [3]))
        #expect(FilmPointRules.leavesAnOutline(runs: [1, 3]))
        // Nothing left, or a single point: no outline, so nothing is taken away.
        #expect(!FilmPointRules.leavesAnOutline(runs: []))
        #expect(!FilmPointRules.leavesAnOutline(runs: [1]))
        #expect(!FilmPointRules.leavesAnOutline(runs: [1, 1]))
    }
}
