import Testing
import SwiftUI
import AppKit
import Foundation
@testable import Bezzle

/// One Mac's copy of a shared design, kept as `Collaboration` keeps it, without iCloud.
private struct Copy {
    let name: String
    var state = SharedDesign()
    var base = FlatDesign()
    var doc: BezzleDocument
    var time: Int64 = 1_000

    init(_ name: String, _ doc: BezzleDocument) {
        self.name = name
        self.doc = doc
        commit()
    }

    mutating func commit() {
        time += 1
        state.absorb(FlatDesign(doc), since: base, by: name, at: time)
        base = FlatDesign(doc)
    }

    mutating func edit(_ change: (inout BezzleDocument) -> Void) {
        change(&doc)
        commit()
    }

    mutating func receive(_ other: SharedDesign) {
        commit()
        state.merge(other)
        base = state.flatDesign()
        doc = base.document()
        commit()
    }
}

/// A board with a rectangle on it, and notes about them.
private func design() -> (BezzleDocument, UUID) {
    var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let r = Node(kind: .rectangle, name: "R", frame: CGRect(x: 40, y: 40, width: 100, height: 60))
    board.children = [r]
    var doc = BezzleDocument()
    doc.nodes = [board]
    return (doc, r.id)
}

private func note(_ text: String, by: String, on: UUID? = nil, thread: UUID? = nil, time: Double) -> MarginNote {
    MarginNote(thread: thread, on: on, at: CGPoint(x: 0.25, y: 0.75), text: text, by: by, replica: by, time: time)
}

private func pair() -> (Copy, Copy, UUID) {
    let (doc, r) = design()
    let a = Copy("anna", doc)
    var b = Copy("ben", BezzleDocument())
    b.receive(a.state)
    return (a, b, r)
}

// MARK: - The notes themselves

@MainActor
struct NotesTests {
    @Test func aNoteSitsOnItsSpotWhereverTheLayerGoes() throws {
        var (doc, r) = design()
        doc.notes = [note("Bigger?", by: "anna", on: r, time: 1)]
        #expect(doc.spot(of: doc.notes![0]) == CGPoint(x: 40 + 25, y: 40 + 45))
        doc.update(r) { $0.frame = CGRect(x: 100, y: 100, width: 200, height: 100) }
        #expect(doc.spot(of: doc.notes![0]) == CGPoint(x: 150, y: 175))
        let back = try JSONDecoder().decode(BezzleDocument.self, from: JSONEncoder().encode(doc))
        #expect(back.notes == doc.notes)
    }

    @Test func aNoteOnTheCanvasStaysWhereItWasPut() {
        var (doc, _) = design()
        var n = note("Here", by: "anna", time: 1)
        n.put(at: CGPoint(x: 900, y: -40), on: nil, in: doc)
        doc.notes = [n]
        #expect(doc.spot(of: n) == CGPoint(x: 900, y: -40))
        #expect(doc.sheet(of: n) == nil)
        #expect(doc.area(of: n) == nil)
    }

    @Test func aSpotPutOnALayerIsKeptInsideIt() {
        let (doc, r) = design()
        var n = note("Edge", by: "anna", time: 1)
        // Past the layer's edge, it is still about the layer, on its edge.
        n.put(at: CGPoint(x: 400, y: 70), on: r, in: doc)
        #expect(n.on == r)
        #expect(n.at == CGPoint(x: 1, y: 0.5))
        #expect(n.place == CGRect(x: 400, y: 70, width: 0, height: 0))
    }

    @Test func aCircledPartGoesWithItsLayer() throws {
        var (doc, r) = design()
        var n = note("These two", by: "anna", time: 1)
        // A loop a little bigger than the rectangle, round it.
        n.put(around: CGRect(x: 30, y: 30, width: 120, height: 80), in: doc)
        #expect(n.on == r)
        doc.notes = [n]
        #expect(doc.area(of: n) == CGRect(x: 30, y: 30, width: 120, height: 80))
        #expect(doc.spot(of: n) == CGPoint(x: 90, y: 70))
        doc.update(r) { $0.frame = CGRect(x: 140, y: 40, width: 200, height: 60) }
        let moved = try #require(doc.area(of: n))
        #expect(abs(moved.minX - 120) < 0.001)
        #expect(abs(moved.width - 240) < 0.001)
        #expect(abs(moved.height - 80) < 0.001)
    }

    @Test func aLoopIsAboutWhatItIsRound() {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let backdrop = Node(kind: .rectangle, name: "Backdrop", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let button = Node(kind: .rectangle, name: "Button", frame: CGRect(x: 100, y: 100, width: 120, height: 40))
        let label = Node(kind: .text, name: "Label", frame: CGRect(x: 120, y: 110, width: 80, height: 20))
        board.children = [backdrop, button, label]
        var doc = BezzleDocument()
        doc.nodes = [board]
        // Round the button: the button, not the words on it.
        #expect(doc.subject(ofArea: CGRect(x: 90, y: 92, width: 140, height: 56)) == button.id)
        // Far bigger than the button: not the button; the backdrop holds all of it.
        #expect(doc.subject(ofArea: CGRect(x: 50, y: 50, width: 500, height: 400)) == backdrop.id)
        // On nothing but the board.
        var bare = doc
        bare.nodes[0].children = []
        #expect(bare.subject(ofArea: CGRect(x: 300, y: 300, width: 100, height: 100)) == board.id)
        // On the table.
        #expect(doc.subject(ofArea: CGRect(x: 1000, y: 1000, width: 50, height: 50)) == nil)
    }

    @Test func notesOfDesignsWrittenBeforeLoopsStillOpen() throws {
        let id = UUID()
        let json = #"{"notes":[{"id":"\#(id.uuidString)","at":[0.5,0.5],"text":"Old","by":"anna","time":3}],"nodes":[],"version":1}"#
        let doc = try JSONDecoder().decode(BezzleDocument.self, from: Data(json.utf8))
        let n = try #require(doc.notes?.first)
        #expect(n.id == id)
        #expect(n.area == nil && n.place == nil)
        #expect(doc.spot(of: n) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func aNoteWhoseLayerIsTakenAwayStaysWhereItWas() {
        var (doc, r) = design()
        var spot = note("Bigger?", by: "anna", on: r, time: 1)
        spot.put(at: CGPoint(x: 90, y: 70), on: r, in: doc)
        var loop = note("These", by: "ben", time: 2)
        loop.put(around: CGRect(x: 30, y: 30, width: 120, height: 80), in: doc)
        doc.notes = [spot, loop]
        doc.update(r) { $0.frame.origin = CGPoint(x: 140, y: 140) }
        let was = doc
        doc.nodes[0].children = []
        doc.keepNotes(since: was)
        let kept = doc.notes ?? []
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.on == nil })
        #expect(doc.spot(of: kept[0]) == CGPoint(x: 190, y: 170))
        #expect(doc.area(of: kept[1]) == CGRect(x: 130, y: 130, width: 120, height: 80))
    }

    @Test func aNoteWhoseLayerWentWithoutBeingSeenGoingFallsBackToWhereItWasPut() {
        var (doc, r) = design()
        var n = note("Bigger?", by: "anna", time: 1)
        n.put(at: CGPoint(x: 90, y: 70), on: r, in: doc)
        doc.notes = [n]
        doc.nodes[0].children = []
        #expect(doc.spot(of: n) == CGPoint(x: 90, y: 70))
        // One with neither its layer nor a place is nowhere to be shown.
        var lost = n
        lost.place = nil
        #expect(doc.spot(of: lost) == nil)
    }

    @Test func threadsAreInTheOrderTheyWereWritten() {
        var (doc, r) = design()
        let first = note("One", by: "anna", on: r, time: 5)
        let second = note("Two", by: "ben", on: r, time: 5)
        let late = note("Three", by: "anna", on: r, time: 9)
        doc.notes = [late, second, first, note("Re", by: "ben", thread: late.id, time: 10), note("Re0", by: "anna", thread: late.id, time: 9.5)]
        let threads = doc.threads
        #expect(threads.map(\.start.text).last == "Three")
        #expect(Set(threads.prefix(2).map(\.start.text)) == ["One", "Two"])
        #expect(threads.last?.replies.map(\.text) == ["Re0", "Re"])
        // The same however they were kept.
        doc.notes?.reverse()
        #expect(doc.threads.map(\.start.id) == threads.map(\.start.id))
    }

    @Test func aReviewGoesSheetBySheetAndDownEach() {
        var left = Node(kind: .artboard, name: "Left", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let a = Node(kind: .rectangle, name: "a", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        left.children = [a]
        var right = Node(kind: .artboard, name: "Right", frame: CGRect(x: 600, y: 0, width: 400, height: 300))
        let b = Node(kind: .rectangle, name: "b", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        right.children = [b]
        var below = Node(kind: .artboard, name: "Below", frame: CGRect(x: 0, y: 500, width: 400, height: 300))
        let c = Node(kind: .rectangle, name: "c", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        below.children = [c]
        var doc = BezzleDocument()
        doc.nodes = [below, right, left]
        func n(_ t: String, _ on: UUID?, _ p: CGPoint, time: Double) -> MarginNote {
            var m = note(t, by: "anna", time: time)
            m.put(at: p, on: on, in: doc)
            return m
        }
        var done = n("done", a.id, CGPoint(x: 10, y: 10), time: 0)
        done.done = true
        doc.notes = [n("table", nil, CGPoint(x: -500, y: 0), time: 1), n("below", c.id, CGPoint(x: 10, y: 600), time: 2),
                     n("right", b.id, CGPoint(x: 700, y: 50), time: 3), n("left low", a.id, CGPoint(x: 50, y: 250), time: 4),
                     n("left high", a.id, CGPoint(x: 300, y: 20), time: 5), done]
        let order = doc.reviewOrder.compactMap { id in doc.notes?.first { $0.id == id }?.text }
        #expect(order == ["left high", "left low", "right", "below", "table"])
    }

    @Test func whatIsNewIsWhatOthersWroteSinceItWasLastRead() {
        var (doc, r) = design()
        let start = note("Bigger?", by: "anna", on: r, time: 10)
        doc.notes = [start]
        #expect(doc.unread(start.id, seen: nil, replica: "ben"))
        #expect(!doc.unread(start.id, seen: nil, replica: "anna"))
        #expect(!doc.unread(start.id, seen: 11, replica: "ben"))
        doc.notes?.append(note("Yes", by: "carl", thread: start.id, time: 20))
        #expect(doc.unread(start.id, seen: 11, replica: "ben"))
        doc.notes?.append(note("Mine", by: "ben", thread: start.id, time: 30))
        #expect(!doc.unread(start.id, seen: 25, replica: "ben"))
    }

    @Test func theLoopRunsRoundItsPartEachOnesOwn() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 60)
        let points = NoteLoop.points(seed: 42, around: r)
        #expect(points.count == NoteLoop.samples + 1)
        #expect(points == NoteLoop.points(seed: 42, around: r))
        #expect(points != NoteLoop.points(seed: 43, around: r))
        // Out past every side of what it circles.
        #expect(points.map(\.x).min()! < r.minX)
        #expect(points.map(\.x).max()! > r.maxX)
        #expect(points.map(\.y).min()! < r.minY)
        #expect(points.map(\.y).max()! > r.maxY)
        // Its end runs on past its start.
        let sweep = zip(points, points.dropFirst()).reduce(0.0) { sum, pair in
            let a = atan2(Double(pair.0.y - r.midY), Double(pair.0.x - r.midX)), b = atan2(Double(pair.1.y - r.midY), Double(pair.1.x - r.midX))
            var d = b - a
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            return sum + d
        }
        #expect(abs(sweep) > 2 * .pi)
        // The thread leaves it on the side of its card, from the point of the line furthest out
        // that way: nothing of the loop runs out past its pin.
        let right = NoteLoop.pin(seed: 42, around: r, right: true), left = NoteLoop.pin(seed: 42, around: r, right: false)
        #expect(points.contains(right) && points.contains(left))
        #expect(right.x > r.maxX && left.x < r.minX)
        #expect(points.allSatisfy { $0.x <= right.x && $0.x >= left.x })
    }

    // MARK: Shared

    @Test func aNoteComesOutOfItsSharedCopyAsItWent() {
        var (doc, r) = design()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        var loop = note("These", by: "anna", time: 2)
        loop.put(around: CGRect(x: 30, y: 30, width: 120, height: 80), in: doc)
        loop.done = true
        doc.notes = [start, loop, note("Yes", by: "ben", thread: start.id, time: 3)]
        let copy = Copy("anna", doc)
        #expect(copy.state.flatDesign().document().notes == doc.notes)
    }

    @Test func twoPeopleAnsweringAtOnceBothKeepTheirAnswer() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        a.edit { $0.notes = [start] }
        b.receive(a.state)
        a.edit { $0.notes?.append(note("Or bolder", by: "anna", thread: start.id, time: 2)) }
        b.edit { $0.notes?.append(note("Yes, 20 more", by: "ben", thread: start.id, time: 2)) }
        a.receive(b.state)
        b.receive(a.state)
        for copy in [a, b] {
            let thread = copy.doc.threads.first
            #expect(thread?.start.id == start.id)
            #expect(Set(thread?.replies.map(\.text) ?? []) == ["Or bolder", "Yes, 20 more"])
        }
        #expect(a.doc.notes == b.doc.notes)
    }

    @Test func changingTheWordsWhileSomeoneTicksTheThreadOffKeepsBoth() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        a.edit { $0.notes = [start] }
        b.receive(a.state)
        a.edit { $0.notes?[0].text = "Bigger, please" }
        b.edit { $0.notes?[0].done = true }
        a.receive(b.state)
        b.receive(a.state)
        for copy in [a, b] {
            #expect(copy.doc.notes?.first?.text == "Bigger, please")
            #expect(copy.doc.notes?.first?.isDone == true)
        }
    }

    @Test func movingTheSpotWhileSomeoneAnswersKeepsBoth() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        a.edit { $0.notes = [start] }
        b.receive(a.state)
        a.edit { doc in
            var n = doc.notes![0]
            n.put(around: CGRect(x: 0, y: 0, width: 50, height: 50), in: doc)
            doc.notes?[0] = n
        }
        b.edit { $0.notes?.append(note("Sure", by: "ben", thread: start.id, time: 4)) }
        a.receive(b.state)
        b.receive(a.state)
        for copy in [a, b] {
            #expect(copy.doc.area(of: copy.doc.notesByID[start.id]!) != nil)
            #expect(copy.doc.threads.first?.replies.map(\.text) == ["Sure"])
        }
        #expect(a.doc.notes == b.doc.notes)
    }

    @Test func anAnswerTakenAwayWhileSomeoneChangedItComesBack() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1), reply = note("Hm", by: "ben", thread: start.id, time: 2)
        a.edit { $0.notes = [start, reply] }
        b.receive(a.state)
        a.edit { $0.notes?.removeAll { $0.id == reply.id } }
        b.time = a.time + 5
        b.edit { doc in
            if let i = doc.notes?.firstIndex(where: { $0.id == reply.id }) { doc.notes?[i].text = "Hm, maybe 20" }
        }
        a.receive(b.state)
        b.receive(a.state)
        #expect(a.doc.notes?.contains { $0.text == "Hm, maybe 20" } == true)
        #expect(a.doc.notes == b.doc.notes)
    }

    @Test func aThreadTakenAwayWhileSomeoneAnsweredItComesBackWhole() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1), old = note("Hm", by: "ben", thread: start.id, time: 2)
        a.edit { $0.notes = [start, old] }
        b.receive(a.state)
        // Anna takes the thread away; Ben, not having seen that, answers it.
        a.edit { doc in doc.notes?.removeAll { $0.id == start.id || $0.thread == start.id } }
        b.edit { $0.notes?.append(note("Done it, 20 more", by: "ben", thread: start.id, time: 3)) }
        a.receive(b.state)
        b.receive(a.state)
        for copy in [a, b] {
            let thread = copy.doc.threads.first { $0.start.id == start.id }
            #expect(thread != nil)
            #expect(thread?.replies.map(\.text) == ["Hm", "Done it, 20 more"])
        }
        #expect(a.doc.notes == b.doc.notes)
    }

    @Test func aThreadTakenAwayWithNobodyAnsweringStaysAway() {
        var (a, b, r) = pair()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        a.edit { $0.notes = [start, note("Hm", by: "ben", thread: start.id, time: 2)] }
        b.receive(a.state)
        a.edit { doc in doc.notes?.removeAll { $0.id == start.id || $0.thread == start.id } }
        b.receive(a.state)
        a.receive(b.state)
        #expect(a.doc.notes == nil)
        #expect(b.doc.notes == nil)
    }

    @Test func aLayerTakenAwayElsewhereLeavesItsNoteWhereItWas() {
        var (a, b, r) = pair()
        var start = note("Bigger?", by: "anna", time: 1)
        start.put(at: CGPoint(x: 90, y: 70), on: r, in: a.doc)
        a.edit { $0.notes = [start] }
        b.receive(a.state)
        // Ben takes the layer away as the app does, which keeps the note.
        b.edit { doc in
            let was = doc
            doc.nodes[0].children = []
            doc.keepNotes(since: was)
        }
        a.receive(b.state)
        let kept = a.doc.notesByID[start.id]
        #expect(kept?.on == nil)
        #expect(kept.flatMap { a.doc.spot(of: $0) } == CGPoint(x: 90, y: 70))
    }

    @Test func aThreadTakenAwayTakesItsAnswersWithIt() {
        var (doc, r) = design()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        doc.notes = [note("Yes", by: "ben", thread: start.id, time: 2)]
        doc.repairNotes()
        #expect(doc.notes == nil)
        doc.notes = [start, note("Yes", by: "ben", thread: start.id, time: 2)]
        doc.repairNotes()
        #expect(doc.notes?.count == 2)
    }

    @Test func undoTakesBackOnlyTheNoteChangedHere() {
        var (doc, r) = design()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        doc.notes = [start]
        var mine = doc
        mine.notes?[0].done = true
        // Someone else answered meanwhile.
        var theirs = mine
        theirs.notes?.append(note("Done it", by: "ben", thread: start.id, time: 3))
        let undone = FlatDesign.apply(from: mine, to: doc, onto: theirs)
        #expect(undone.notes?.first { $0.id == start.id }?.isDone == false)
        #expect(undone.notes?.contains { $0.text == "Done it" } == true)
    }

    @Test func undoingAMoveLeavesTheWordsChangedElsewhere() {
        var (doc, r) = design()
        let start = note("Bigger?", by: "anna", on: r, time: 1)
        doc.notes = [start]
        var moved = doc
        var n0 = moved.notes![0]
        n0.put(around: CGRect(x: 0, y: 0, width: 60, height: 60), in: moved)
        moved.notes?[0] = n0
        var theirs = moved
        theirs.notes?[0].text = "Bigger, please"
        let undone = FlatDesign.apply(from: moved, to: doc, onto: theirs)
        let n = undone.notes?.first
        #expect(n?.area == nil)
        #expect(n?.on == r)
        #expect(n?.at == start.at)
        #expect(n?.text == "Bigger, please")
    }
}

// MARK: - Where the notes go

@MainActor
struct NotePlacementTests {
    typealias Want = NotePlacement.Want

    private func want(_ spot: CGPoint, home: CGRect?, sheet: UUID? = UUID(), height: CGFloat = 66, open: Bool = false,
                      done: Bool = false) -> Want {
        Want(id: UUID(), spot: spot, home: home, sheet: home == nil ? nil : sheet, height: height, open: open, flagOnly: done)
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { a.insetBy(dx: 0.5, dy: 0.5).intersects(b.insetBy(dx: 0.5, dy: 0.5)) }

    @Test func aCardSitsInTheMarginLevelWithItsSpot() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        let w = want(CGPoint(x: 450, y: 200), home: home)
        let place = try #require(NotePlacement.place([w], around: [home]).first)
        #expect(place.kind == .card)
        #expect(place.side == .right)
        #expect(place.frame == CGRect(x: home.maxX + NotePlacement.gap, y: 200 - NotePlacement.lineIn, width: NotePlacement.width, height: 66))
        #expect(place.anchor == CGPoint(x: place.frame.minX, y: 200))
    }

    @Test func aCardGoesOnTheSideNearerItsSpot() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        let place = try #require(NotePlacement.place([want(CGPoint(x: 150, y: 200), home: home)], around: [home]).first)
        #expect(place.kind == .card)
        #expect(place.side == .left)
        #expect(place.frame.maxX == home.minX - NotePlacement.gap)
        #expect(place.anchor == CGPoint(x: place.frame.maxX, y: 200))
    }

    @Test func aCardNeverLiesOverTheNextSheet() throws {
        // The next sheet a little way off on the right: the card goes to the left margin instead.
        let home = CGRect(x: 100, y: 100, width: 400, height: 300), next = CGRect(x: 560, y: 100, width: 400, height: 300)
        let place = try #require(NotePlacement.place([want(CGPoint(x: 450, y: 200), home: home)], around: [home, next]).first)
        #expect(place.kind == .card)
        #expect(place.side == .left)
        #expect(!overlaps(place.frame, next))
    }

    @Test func withNoRoomOnEitherSideItIsAFlagOnTheEdge() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        let right = CGRect(x: 560, y: 100, width: 400, height: 300), left = CGRect(x: -400, y: 100, width: 460, height: 300)
        let place = try #require(NotePlacement.place([want(CGPoint(x: 450, y: 200), home: home)], around: [home, right, left]).first)
        #expect(place.kind == .flag)
        #expect(place.side == .right)
        #expect(place.frame.minX == home.maxX)
        #expect(place.frame.midY == 200)
        #expect(place.frame.width == NotePlacement.flagReach)
        #expect(place.anchor == CGPoint(x: home.maxX, y: 200))
        #expect(!overlaps(place.frame, right))
    }

    @Test func aBlockedMarginStillTakesCardsWhereItIsFree() throws {
        // A sheet beside only the top half: the card goes below it, still beside its own sheet.
        let home = CGRect(x: 100, y: 100, width: 400, height: 400), next = CGRect(x: 560, y: 0, width: 300, height: 260)
        let place = try #require(NotePlacement.place([want(CGPoint(x: 450, y: 200), home: home)], around: [home, next]).first)
        #expect(place.kind == .card)
        #expect(place.side == .right)
        #expect(place.frame.minY >= next.maxY + NotePlacement.clearance - 0.01)
        #expect(!overlaps(place.frame, next))
    }

    @Test func cardsDownAMarginKeepTheOrderOfTheirSpotsAndMakeRoom() {
        let home = CGRect(x: 100, y: 100, width: 400, height: 600)
        let wants = [480, 470, 460, 490].enumerated().map { i, x in want(CGPoint(x: CGFloat(x), y: 150 + CGFloat(i) * 20), home: home, sheet: nil) }
        let places = NotePlacement.place(wants, around: [home])
        #expect(places.allSatisfy { $0.kind == .card && $0.side == .right })
        let byWant = wants.map { w in places.first { $0.id == w.id }! }
        for (a, b) in zip(byWant, byWant.dropFirst()) {
            #expect(a.frame.maxY + NotePlacement.spacing <= b.frame.minY + 0.01)
        }
        #expect(byWant[0].frame.minY == 150 - NotePlacement.lineIn)
    }

    @Test func theOpenCardKeepsItsSpotAndTheOthersMakeRoom() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 600)
        let sheet = UUID()
        let above = want(CGPoint(x: 450, y: 200), home: home, sheet: sheet)
        var open = want(CGPoint(x: 450, y: 230), home: home, sheet: sheet, height: 220, open: true)
        open.open = true
        let places = NotePlacement.place([above, open], around: [home])
        let o = try #require(places.first { $0.id == open.id }), a = try #require(places.first { $0.id == above.id })
        #expect(o.kind == .card)
        #expect(o.frame.minY == 230 - NotePlacement.lineIn)
        #expect(!overlaps(o.frame, a.frame))
    }

    @Test func theOpenCardIsACardWhateverTheRoomLiftedOverTheTable() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        let right = CGRect(x: 520, y: 0, width: 400, height: 600), left = CGRect(x: -400, y: 0, width: 480, height: 600)
        let open = want(CGPoint(x: 450, y: 200), home: home, open: true)
        let place = try #require(NotePlacement.place([open], around: [home, right, left]).first)
        #expect(place.kind == .lifted)
        #expect(place.side == .right)
        // Never over its own sheet.
        #expect(!overlaps(place.frame, home))
    }

    @Test func aSheetSmallOnScreenTakesFlagsButOpensACard() {
        let home = CGRect(x: 100, y: 100, width: 60, height: 100)
        let shut = want(CGPoint(x: 150, y: 150), home: home)
        #expect(NotePlacement.place([shut], around: [home]).first?.kind == .flag)
        let open = want(CGPoint(x: 150, y: 150), home: home, open: true)
        #expect(NotePlacement.place([open], around: [home]).first?.kind == .card)
    }

    @Test func threadsTickedOffAreFlagsUnlessOpened() {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(NotePlacement.place([want(CGPoint(x: 450, y: 200), home: home, done: true)], around: [home]).first?.kind == .flag)
        #expect(NotePlacement.place([want(CGPoint(x: 450, y: 200), home: home, open: true, done: true)], around: [home]).first?.kind == .card)
    }

    @Test func flagsStackDownTheEdgeEachClearOfTheLast() {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300), right = CGRect(x: 540, y: 100, width: 400, height: 300),
            left = CGRect(x: -400, y: 100, width: 480, height: 300)
        let sheet = UUID()
        let wants = (0..<5).map { _ in want(CGPoint(x: 450, y: 200), home: home, sheet: sheet) }
        let flags = NotePlacement.place(wants, around: [home, right, left]).filter { $0.kind == .flag }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(flags.count == 5)
        for (a, b) in zip(flags, flags.dropFirst()) { #expect(a.frame.maxY + NotePlacement.flagSpacing <= b.frame.minY + 0.01) }
        #expect(flags.allSatisfy { $0.frame.minX == home.maxX })
    }

    @Test func twoSheetsShareTheNarrowGapBetweenTheirFlags() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300), b = CGRect(x: 420, y: 0, width: 400, height: 300)
        // Hemmed in on the outer sides too, so that both are flags.
        let c = CGRect(x: -300, y: 0, width: 290, height: 300), d = CGRect(x: 830, y: 0, width: 300, height: 300)
        let wa = want(CGPoint(x: 390, y: 150), home: a), wb = want(CGPoint(x: 430, y: 150), home: b)
        let places = NotePlacement.place([wa, wb], around: [a, b, c, d])
        #expect(places.allSatisfy { $0.kind == .flag })
        #expect(places.count == 2)
        #expect(!overlaps(places[0].frame, places[1].frame))
        #expect(places.allSatisfy { $0.frame.width >= 4 && $0.frame.width <= 10 })
        // Sheets that touch: each flag a sliver on its own sheet.
        let e = CGRect(x: 400, y: 0, width: 400, height: 300)
        let touching = NotePlacement.place([want(CGPoint(x: 390, y: 150), home: a), want(CGPoint(x: 410, y: 150), home: e)], around: [a, e, c, d])
        #expect(touching.allSatisfy { $0.kind == .flag })
        #expect(!overlaps(touching[0].frame, touching[1].frame))
        #expect(touching.allSatisfy { $0.frame.width == 4 })
    }

    @Test func moreFlagsThanAnEdgeHoldsStayOnItSmaller() {
        let home = CGRect(x: 100, y: 100, width: 80, height: 100)
        let sheet = UUID()
        // Spots on the right half, clear of the edge: eight flags fit along it, smaller.
        let flags = NotePlacement.place((0..<8).map { _ in want(CGPoint(x: 145, y: 190), home: home, sheet: sheet) }, around: [home])
            .sorted { $0.frame.minY < $1.frame.minY }
        #expect(flags.count == 8)
        #expect(flags.allSatisfy { $0.kind == .flag && $0.frame.minY >= home.minY - 0.01 && $0.frame.maxY <= home.maxY + 0.01 })
        for (a, b) in zip(flags, flags.dropFirst()) { #expect(a.frame.maxY <= b.frame.minY + 0.01) }
        // Spots right on the edge: the flags go round the pins, past the sheet's foot if they must,
        // never over a pin.
        let edge = (0..<8).map { _ in want(CGPoint(x: 176, y: 190), home: home, sheet: sheet) }
        let round = NotePlacement.place(edge, around: [home])
        for flag in round { for w in edge { for pin in NotePlacement.pins(of: w) { #expect(!flag.frame.intersects(pin)) } } }
        let sorted = round.sorted { $0.frame.minY < $1.frame.minY }
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.frame.maxY <= b.frame.minY + 0.01) }
    }

    @Test func aNoteOnTheTableSitsBesideItsPinOrIsItsWritersToken() throws {
        let spot = CGPoint(x: 1000, y: 500)
        let free = try #require(NotePlacement.place([want(spot, home: nil)], around: []).first)
        #expect(free.kind == .card)
        #expect(free.frame.minX == spot.x + NotePlacement.tableGap)
        // Hemmed in by sheets: its pin shows its writer.
        let walls = [CGRect(x: 1010, y: 0, width: 600, height: 1000), CGRect(x: 0, y: 0, width: 990, height: 1000)]
        let hemmed = try #require(NotePlacement.place([want(spot, home: nil)], around: walls).first)
        #expect(hemmed.kind == .pin)
        #expect(hemmed.anchor == spot)
        let opened = try #require(NotePlacement.place([want(spot, home: nil, open: true)], around: walls).first)
        #expect(opened.kind == .lifted)
    }

    @Test func theNearestFreeHeightIsFound() {
        let blocked = [CGRect(x: 0, y: 100, width: 300, height: 100)]
        // Blocked for tops from 100 - 12 - 50 = 38 to 212: 38 is nearer 120 than 212 is.
        #expect(NotePlacement.freeY(x: 0, height: 50, near: 120, atLeast: -.infinity, within: -1000...1000, blocked: blocked) == 38)
        // Not above what came before.
        #expect(NotePlacement.freeY(x: 0, height: 50, near: 120, atLeast: 60, within: -1000...1000, blocked: blocked) == 212)
        // Nowhere in reach.
        #expect(NotePlacement.freeY(x: 0, height: 50, near: 120, atLeast: -.infinity, within: 50...200, blocked: blocked) == nil)
        // A column clear of it.
        #expect(NotePlacement.freeY(x: 400, height: 50, near: 120, atLeast: -.infinity, within: -1000...1000, blocked: blocked) == 120)
    }

    @Test func aThreadNearTheEdgeOfHavingRoomTurnsOnceNotToAndFro() throws {
        let sheet = UUID()
        // A sheet between the height a card keeps to and the height a new one needs.
        let home = CGRect(x: 100, y: 100, width: 300, height: NotePlacement.smallest - 10)
        let w = Want(id: UUID(), spot: CGPoint(x: 350, y: 150), home: home, sheet: sheet, height: 60)
        #expect(NotePlacement.place([w], around: [home]).first?.kind == .flag)
        #expect(NotePlacement.place([w], around: [home], was: [w.id: .card]).first?.kind == .card)
        #expect(NotePlacement.place([w], around: [home], was: [w.id: .flag]).first?.kind == .flag)
        // A flag wants a little more than a card needs before it is one again.
        let taller = CGRect(x: 100, y: 100, width: 300, height: NotePlacement.smallest + 10)
        let v = Want(id: w.id, spot: CGPoint(x: 350, y: 150), home: taller, sheet: sheet, height: 60)
        #expect(NotePlacement.place([v], around: [taller]).first?.kind == .card)
        #expect(NotePlacement.place([v], around: [taller], was: [v.id: .flag]).first?.kind == .flag)
    }

    @Test func aGapJustWideEnoughKeepsACardButTakesNoFlagBack() throws {
        let home = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Room on the right for a card and its clearance, and a little over, but not much.
        let next = CGRect(x: home.maxX + NotePlacement.gap + NotePlacement.width + NotePlacement.clearance + 4, y: 0, width: 400, height: 300)
        let left = CGRect(x: -500, y: 0, width: 480, height: 300)
        let w = Want(id: UUID(), spot: CGPoint(x: 380, y: 150), home: home, sheet: UUID(), height: 66)
        let fresh = try #require(NotePlacement.place([w], around: [home, next, left]).first)
        #expect(fresh.kind == .card)
        #expect(NotePlacement.place([w], around: [home, next, left], was: [w.id: .card]).first?.kind == .card)
        #expect(NotePlacement.place([w], around: [home, next, left], was: [w.id: .flag]).first?.kind == .flag)
    }

    @Test func zoomingThroughTheEdgeTurnsEachThreadOnceEachWay() {
        // Three sheets side by side, a note on each, zoomed slowly out and in again: each thread
        // turns from card to flag once on the way out and back once on the way in.
        let sheets = (0..<3).map { (UUID(), CGRect(x: CGFloat($0) * 800, y: 0, width: 390, height: 844)) }
        let notes = sheets.map { s in (s, UUID(), CGPoint(x: s.1.maxX - 40, y: 300)) }
        var was: [UUID: NotePlacement.Kind] = [:]
        var turns: [UUID: Int] = [:]
        let zooms = stride(from: 1.0, through: 0.05, by: -0.005).map { CGFloat($0) }
        for zoom in zooms + zooms.reversed() {
            let obstacles = sheets.map { CGRect(x: $0.1.minX * zoom, y: $0.1.minY * zoom, width: $0.1.width * zoom, height: $0.1.height * zoom) }
            let wants = notes.enumerated().map { i, n in
                Want(id: n.1, spot: CGPoint(x: n.2.x * zoom, y: n.2.y * zoom), home: obstacles[i], sheet: n.0.0, height: 66)
            }
            for place in NotePlacement.place(wants, around: obstacles, was: was) {
                if let before = was[place.id], (before == .flag) != (place.kind == .flag) { turns[place.id, default: 0] += 1 }
                was[place.id] = place.kind
            }
        }
        #expect(turns.values.allSatisfy { $0 <= 2 }, "\(turns)")
        #expect(was.values.allSatisfy { $0 == .card }, "\(was.values.map { "\($0)" })")
    }

    private func pinRect(_ p: CGPoint) -> CGRect {
        CGRect(x: p.x - NotePlacement.pinSize / 2, y: p.y - NotePlacement.pinSize / 2, width: NotePlacement.pinSize, height: NotePlacement.pinSize)
    }

    @Test func aLoopAtTheSheetsEdgeKeepsItsPinBesideTheCard() throws {
        let home = CGRect(x: 0, y: 0, width: 400, height: 600)
        // Round something wide at the right edge: the loop, and its pin, run out past the sheet.
        var w = want(CGPoint(x: 270, y: 230), home: home)
        // The same loop each run, out past the sheet's edge.
        w.id = UUID(uuidString: "7A0C3E51-2B9D-4F60-8E12-5D4C3B2A1F09")!
        w.area = CGRect(x: 120, y: 200, width: 300, height: 60)
        let place = try #require(NotePlacement.place([w], around: [home]).first)
        let pin = NotePlacement.pin(of: w, side: place.side)
        #expect(place.kind == .card && place.side == .right)
        #expect(pin.x > home.maxX + NotePlacement.gap)
        #expect(place.frame.minX >= pin.x + NotePlacement.pinRoom - 0.01)
        #expect(!place.frame.intersects(pinRect(pin)))
        // Open, with no room, it lifts; still beside its pin.
        let walls = [CGRect(x: 420, y: 0, width: 400, height: 600), CGRect(x: -420, y: 0, width: 400, height: 600)]
        var open = w
        open.open = true
        let lifted = try #require(NotePlacement.place([open], around: [home] + walls).first)
        #expect(lifted.kind == .lifted)
        #expect(!lifted.frame.intersects(pinRect(NotePlacement.pin(of: open, side: lifted.side))))
    }

    @Test func aLoopOnTheTableHasItsCardBesideTheLoopNotOverIt() throws {
        // Round something on the table itself: the card goes out past the loop's pin, and no part
        // of the loop lies under it.
        var w = want(CGPoint(x: 1150, y: 520), home: nil)
        w.area = CGRect(x: 1000, y: 490, width: 300, height: 60)
        for (open, walls) in [(false, [CGRect]()), (true, []), (true, [CGRect(x: 1400, y: 0, width: 400, height: 1000), CGRect(x: 400, y: 0, width: 560, height: 1000)])] {
            var v = w
            v.open = open
            let place = try #require(NotePlacement.place([v], around: walls).first)
            let pin = NotePlacement.pin(of: v, side: place.side)
            #expect(!place.frame.intersects(pinRect(pin)), "open: \(open)")
            let loop = NoteLoop.points(seed: NoteLoop.seed(v.id), around: v.area!)
            #expect(loop.allSatisfy { !place.frame.contains($0) }, "the loop under its card, open: \(open)")
            #expect(abs(place.anchor.y - pin.y) < 0.01 || place.kind != .card, "not level with its pin")
        }
        // Hemmed in, shut: its pin is its writer's token, on the loop's edge.
        let walls = [CGRect(x: 1320, y: 0, width: 400, height: 1000), CGRect(x: 400, y: 0, width: 580, height: 1000)]
        let token = try #require(NotePlacement.place([w], around: walls).first)
        #expect(token.kind == .pin)
        #expect(token.anchor == NotePlacement.pin(of: w, side: .right))
    }

    @Test func aPinPulledOutIntoTheMarginPushesItsCardFurtherOut() throws {
        let home = CGRect(x: 0, y: 0, width: 400, height: 600)
        for x: CGFloat in [380, 420, 470, 560] {
            let w = want(CGPoint(x: x, y: 200), home: home)
            let place = try #require(NotePlacement.place([w], around: [home]).first)
            #expect(place.side == .right)
            #expect(!place.frame.intersects(pinRect(w.spot)), "pin at \(x)")
            #expect(place.frame.minX >= max(home.maxX + NotePlacement.gap, x + NotePlacement.pinRoom) - 0.01)
        }
        // Pulled out on the left, the card goes out on the left of it.
        let w = want(CGPoint(x: -60, y: 200), home: home)
        let place = try #require(NotePlacement.place([w], around: [home]).first)
        #expect(place.side == .left)
        #expect(place.frame.maxX <= -60 - NotePlacement.pinRoom + 0.01)
    }

    @Test func noCardLiesOverAnotherNotesPin() throws {
        let home = CGRect(x: 0, y: 0, width: 400, height: 600)
        // A note on the table, its pin in the sheet's right margin, level with a note on the sheet.
        let table = want(CGPoint(x: 470, y: 205), home: nil)
        let mine = want(CGPoint(x: 380, y: 200), home: home)
        let places = NotePlacement.place([mine, table], around: [home])
        let card = try #require(places.first { $0.id == mine.id })
        #expect(card.kind == .card)
        #expect(!card.frame.intersects(pinRect(table.spot)))
        let theirs = try #require(places.first { $0.id == table.id })
        #expect(!theirs.frame.intersects(pinRect(mine.spot)))
    }

    @Test func aFlagGoesRoundAPinOnTheSheetsEdge() throws {
        let home = CGRect(x: 100, y: 100, width: 400, height: 300)
        let walls = [CGRect(x: 540, y: 100, width: 400, height: 300), CGRect(x: -400, y: 100, width: 480, height: 300)]
        // A spot right on the edge, and a flag that would sit on it.
        let edge = want(CGPoint(x: 500, y: 200), home: home)
        let near = want(CGPoint(x: 492, y: 300), home: home, sheet: edge.sheet)
        let places = NotePlacement.place([edge, near], around: [home] + walls)
        #expect(places.allSatisfy { $0.kind == .flag })
        for place in places {
            for pin in [edge.spot, near.spot] { #expect(!place.frame.intersects(pinRect(pin))) }
            #expect(place.frame.minY >= home.minY && place.frame.maxY <= home.maxY)
        }
        // At the foot of the sheet, it goes above the pin instead.
        let foot = want(CGPoint(x: 500, y: 392), home: home)
        let low = try #require(NotePlacement.place([foot], around: [home] + walls).first)
        #expect(!low.frame.intersects(pinRect(foot.spot)))
        #expect(low.frame.maxY <= foot.spot.y)
    }

    /// The bug the margin had: cards over the next sheet. However the sheets lie, however many
    /// notes, a card is never over a sheet or another card, and every thread shows once.
    @Test func noCardEverLiesOverASheetOrAnotherCard() {
        var rng = SeededRandom(seed: 0xB322_1E)
        for _ in 0..<160 {
            // A grid of sheets of every size, with gaps from none to wide.
            var sheets: [(UUID, CGRect)] = []
            var y: CGFloat = 0
            for _ in 0..<Int(rng.next(1...3)) {
                var x: CGFloat = 0
                var tallest: CGFloat = 0
                for _ in 0..<Int(rng.next(1...4)) {
                    let w = rng.next(80...600), h = rng.next(80...700)
                    sheets.append((UUID(), CGRect(x: x, y: y, width: w, height: h)))
                    x += w + rng.next(0...420)
                    tallest = max(tallest, h)
                }
                y += tallest + rng.next(0...300)
            }
            var wants: [Want] = []
            var opened = false
            for (id, r) in sheets {
                for _ in 0..<Int(rng.next(0...4)) {
                    let open = !opened && rng.next(0...1) > 0.85
                    opened = opened || open
                    var w = Want(id: UUID(), spot: CGPoint(x: rng.next(r.minX...r.maxX), y: rng.next(r.minY...r.maxY)), home: r, sheet: id,
                                 height: rng.next(50...200), open: open, flagOnly: rng.next(0...1) > 0.9)
                    if rng.next(0...1) > 0.7 {
                        // Round a part of the sheet, perhaps out to its edge.
                        let aw = rng.next(20...max(20, r.width)), ah = rng.next(16...max(16, r.height / 3))
                        let ax = min(max(w.spot.x - aw / 2, r.minX), r.maxX - aw), ay = min(max(w.spot.y - ah / 2, r.minY), r.maxY - ah)
                        w.area = CGRect(x: ax, y: ay, width: aw, height: ah)
                        w.spot = CGPoint(x: ax + aw / 2, y: ay + ah / 2)
                    }
                    wants.append(w)
                }
            }
            for _ in 0..<Int(rng.next(0...3)) {
                var w = want(CGPoint(x: rng.next(-600...2400), y: rng.next(-600...2400)), home: nil, open: !opened && rng.next(0...1) > 0.8)
                opened = opened || w.open
                if rng.next(0...1) > 0.4 {
                    // A loop on the table, round nothing.
                    w.area = CGRect(x: w.spot.x - 80, y: w.spot.y - 25, width: rng.next(20...400), height: rng.next(16...120))
                    w.spot = CGPoint(x: w.area!.midX, y: w.area!.midY)
                }
                wants.append(w)
            }
            let obstacles = sheets.map(\.1)
            let places = NotePlacement.place(wants, around: obstacles)
            #expect(places.count == wants.count)
            #expect(Set(places.map(\.id)) == Set(wants.map(\.id)))
            let cards = places.filter { $0.kind == .card }
            for card in cards {
                for sheet in obstacles { #expect(!overlaps(card.frame, sheet), "a card over a sheet") }
            }
            for (i, a) in cards.enumerated() {
                for b in cards[(i + 1)...] { #expect(!overlaps(a.frame, b.frame), "two cards over each other") }
            }
            for lifted in places where lifted.kind == .lifted {
                #expect(wants.first { $0.id == lifted.id }?.open == true)
                if let home = wants.first(where: { $0.id == lifted.id })?.home { #expect(!overlaps(lifted.frame, home)) }
            }
            // Every pin shows: no card lies over one, and a card is never over its own, lifted or not.
            for card in cards {
                for w in wants { for pin in NotePlacement.pins(of: w) { #expect(!card.frame.intersects(pin), "a card over a pin") } }
            }
            for place in places where place.kind == .card || place.kind == .lifted {
                let w = wants.first { $0.id == place.id }!
                #expect(!place.frame.intersects(pinRect(NotePlacement.pin(of: w, side: place.side))), "a card over its own pin")
            }
            let flags = places.filter { $0.kind == .flag }
            for flag in flags {
                let home = wants.first { $0.id == flag.id }!.home!
                let edges = [home.minX, home.maxX]
                #expect(edges.contains { abs(flag.frame.minX - $0) < 0.01 || abs(flag.frame.maxX - $0) < 0.01 }, "a flag off its sheet's edge")
                // Along its sheet, unless the edge is so crowded with pins and flags it cannot be.
                let along = places.filter { p in p.kind == .flag && p.side == flag.side && wants.first { $0.id == p.id }?.home == home }
                let crowded = along.count * 24 + 48 > Int(home.height)
                #expect(crowded || (flag.frame.minY >= home.minY - 0.01 && flag.frame.maxY <= home.maxY + 0.01), "a flag past its sheet")
                for w in wants { for pin in NotePlacement.pins(of: w) { #expect(!flag.frame.intersects(pin), "a flag over a pin") } }
                for card in cards { #expect(!overlaps(flag.frame, card.frame), "a flag under a card") }
                #expect(!flag.frame.intersects(pinRect(NotePlacement.pin(of: wants.first { $0.id == flag.id }!, side: flag.side))),
                        "a flag over its own pin")
            }
            for (i, a) in flags.enumerated() {
                for b in flags[(i + 1)...] { #expect(!overlaps(a.frame, b.frame), "two flags over each other") }
            }
        }
    }
}

/// Numbers that come out the same each run, for trying many layouts.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed | 1 }

    mutating func next(_ range: ClosedRange<CGFloat>) -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(Double(state % 1_000_000) / 999_999)
    }
}

// MARK: - How the margin moves

@MainActor
struct NoteMotionTests {
    let id = UUID()
    let vp = Viewport(origin: .zero, zoom: 1)

    private var item: NotesLayer.Item {
        NotesLayer.Item(start: MarginNote(id: id, text: "Hi", by: "anna", time: 1), replies: [], color: .blue)
    }

    private func place(_ y: CGFloat, kind: NotePlacement.Kind = .card) -> NotePlacement.Place {
        NotePlacement.Place(id: id, kind: kind, frame: CGRect(x: 500, y: y, width: 236, height: 66), side: .right,
                            anchor: CGPoint(x: 500, y: y + NotePlacement.lineIn))
    }

    private func settle(_ m: NoteMotion, _ places: [NotePlacement.Place], spot: CGPoint = CGPoint(x: 400, y: 119),
                        drag: NoteDrag? = nil, viewport: Viewport? = nil, done: Set<UUID> = [], at now: Double) -> NotesLayer.Scene {
        m.settle(places, places.isEmpty ? [:] : [id: (item, spot, nil)], drag: drag, pointed: nil, viewport: viewport ?? vp, circle: nil,
                 done: done, canvas: nil, now: now)
    }

    /// Runs the clock on at 120 frames a second, the scene the last frame shows.
    private func run(_ m: NoteMotion, _ places: [NotePlacement.Place], spot: CGPoint = CGPoint(x: 400, y: 119), drag: NoteDrag? = nil,
                     from t: inout Double, for seconds: Double, done: Set<UUID> = []) -> NotesLayer.Scene {
        var scene = NotesLayer.Scene()
        let end = t + seconds
        while t < end {
            t += 1.0 / 120
            scene = settle(m, places, spot: spot, drag: drag, done: done, at: t)
        }
        return scene
    }

    @Test func whatIsThereWhenTheMarginOpensIsSimplyThere() {
        let m = NoteMotion()
        let scene = settle(m, [place(100)], at: 0)
        #expect(scene.shown.first?.born == 1)
        #expect(scene.shown.first?.frame.minY == 100)
        #expect(!m.moving)
    }

    @Test func aCardThatHasToMoveGoesWithWeight() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        var t = 0.0
        // The first frame after: still where it was.
        let first = settle(m, [place(200)], at: t + 1.0 / 120)
        #expect(abs(first.shown[0].frame.minY - 100) < 0.5)
        #expect(m.moving)
        t += 1.0 / 120
        let halfway = run(m, [place(200)], from: &t, for: 0.08)
        let y = halfway.shown[0].frame.minY
        #expect(y > 100 && y < 200)
        let rest = run(m, [place(200)], from: &t, for: 1.5)
        #expect(abs(rest.shown[0].frame.minY - 200) < 0.5)
        #expect(!m.moving)
    }

    @Test func theViewMovingCarriesTheCardsAtOnce() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        let panned = settle(m, [place(300)], viewport: Viewport(origin: CGPoint(x: 0, y: -200), zoom: 1), at: 0.01)
        #expect(panned.shown[0].frame.minY == 300)
        #expect(!m.moving)
    }

    @Test func aThreadWrittenIsDrawnIn() {
        let m = NoteMotion()
        _ = settle(m, [], at: 0)
        var t = 0.0
        let first = settle(m, [place(100)], at: 0.001)
        #expect(first.shown[0].born < 0.01)
        #expect(m.moving)
        let mid = run(m, [place(100)], from: &t, for: NoteMotion.writeIn / 2)
        #expect(mid.shown[0].born > 0.3 && mid.shown[0].born < 0.7)
        let end = run(m, [place(100)], from: &t, for: NoteMotion.writeIn)
        #expect(end.shown[0].born == 1)
        #expect(!m.moving)
    }

    @Test func aThreadTickedOffIsTickedThenTuckedAway() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        var t = 0.0
        let gone = settle(m, [], done: [id], at: 0.001)
        #expect(gone.shown.isEmpty)
        #expect(gone.ghosts.count == 1)
        #expect(gone.ghosts[0].tickedOff)
        #expect(gone.ghosts[0].frame.minY == 100)
        let mid = run(m, [], from: &t, for: NoteMotion.tickOff / 2, done: [id])
        #expect(mid.ghosts.first?.leaving.map { $0 > 0.3 && $0 < 0.7 } == true)
        let end = run(m, [], from: &t, for: NoteMotion.tickOff, done: [id])
        #expect(end.ghosts.isEmpty)
        #expect(m.idle)
        #expect(!m.moving)
    }

    @Test func aThreadTakenAwayFadesWithoutATick() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        let gone = settle(m, [], at: 0.001)
        #expect(gone.ghosts.count == 1)
        #expect(!gone.ghosts[0].tickedOff)
        var t = 0.001
        let end = run(m, [], from: &t, for: NoteMotion.fade + 0.05)
        #expect(end.ghosts.isEmpty)
    }

    @Test func aThreadTickedOffWhereItStillShowsIsTickedAndWrittenInAgain() {
        let m = NoteMotion()
        var open = item
        _ = m.settle([place(100)], [id: (open, CGPoint(x: 400, y: 119), nil)], drag: nil, pointed: nil, viewport: vp, circle: nil,
                     done: [], canvas: nil, now: 0)
        open.done = true
        let flag = m.settle([place(100, kind: .flag)], [id: (open, CGPoint(x: 400, y: 119), nil)], drag: nil, pointed: nil, viewport: vp,
                            circle: nil, done: [id], canvas: nil, now: 0.01)
        #expect(flag.ghosts.count == 1)
        #expect(flag.ghosts[0].tickedOff)
        #expect(flag.shown[0].born < 0.05)
    }

    @Test func aPinPulledIsCarriedAfterThePointerAndItsThreadSags() {
        let m = NoteMotion()
        let spot = CGPoint(x: 400, y: 119)
        _ = settle(m, [place(100)], spot: spot, at: 0)
        var t = 0.0
        let drag = NoteDrag(id: id, by: CGSize(width: -120, height: 160))
        let pulled = CGPoint(x: spot.x - 120, y: spot.y + 160)
        let early = run(m, [place(100)], spot: pulled, drag: drag, from: &t, for: 0.03)
        let pin = early.shown[0].pin
        // Behind the pointer, on its way.
        #expect(pin.y > spot.y && pin.y < pulled.y)
        #expect(early.shown[0].dragged)
        #expect(early.shown[0].lit)
        let held = run(m, [place(100)], spot: pulled, drag: drag, from: &t, for: 0.6)
        #expect(hypot(held.shown[0].pin.x - pulled.x, held.shown[0].pin.y - pulled.y) < 1)
        #expect(held.shown[0].sag > 5)
        // Let go there: it hangs still again, taut.
        let rest = run(m, [place(100)], spot: pulled, from: &t, for: 2)
        #expect(abs(rest.shown[0].sag) < 0.5)
        #expect(rest.shown[0].pin == pulled)
        #expect(!m.moving)
    }

    @Test func aCardFoldingToAFlagTurnsInPlaceAndNeverFlies() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        let flag = NotePlacement.Place(id: id, kind: .flag, frame: CGRect(x: 480, y: 110, width: 24, height: 20), side: .right,
                                       anchor: CGPoint(x: 480, y: 120))
        let turned = settle(m, [flag], at: 0.01)
        // The flag is where it goes from the first frame; the card it was folds away where it was.
        #expect(turned.shown[0].frame == flag.frame)
        #expect(turned.shown[0].turned)
        #expect(turned.shown[0].born < 0.1)
        #expect(turned.ghosts.count == 1)
        #expect(turned.ghosts[0].turned)
        #expect(turned.ghosts[0].frame.minY == 100)
        var t = 0.01
        let done = run(m, [flag], from: &t, for: NoteMotion.turn + 0.05)
        #expect(done.ghosts.isEmpty)
        #expect(done.shown[0].born == 1)
        #expect(!done.shown[0].turned)
        #expect(!m.moving)
        #expect(m.kinds[id] == .flag)
    }

    @Test func aCardGoingToTheOtherSideTurnsThereNotAcrossTheWork() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        let left = NotePlacement.Place(id: id, kind: .card, frame: CGRect(x: -300, y: 100, width: 236, height: 66), side: .left,
                                       anchor: CGPoint(x: -64, y: 119))
        let turned = settle(m, [left], at: 0.01)
        #expect(turned.shown[0].frame == left.frame)
        #expect(turned.shown[0].turned)
        #expect(turned.ghosts.first?.frame.minX == 500)
    }

    @Test func aCardMovesStraightThereAndStopsNeverPast() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        var t = 0.0
        var ys: [CGFloat] = []
        _ = settle(m, [place(300)], at: 0.001)
        while t < 1.2 {
            t += 1.0 / 120
            ys.append(settle(m, [place(300)], at: t).shown[0].frame.minY)
        }
        #expect(ys.allSatisfy { $0 <= 300.01 }, "overshot to \(ys.max() ?? 0)")
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 + 0.001 })
        #expect(abs(ys.last! - 300) < 0.5)
        #expect(!m.moving)
    }

    @Test func aCardMakingRoomHardlyStirsItsThread() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        var t = 0.0
        var sag: CGFloat = 0
        _ = settle(m, [place(260)], at: 0.001)
        while t < 1 {
            t += 1.0 / 120
            sag = max(sag, abs(settle(m, [place(260)], at: t).shown[0].sag))
        }
        #expect(sag < 4)
    }

    @Test func aThreadCaughtShiversAndSettles() {
        let m = NoteMotion()
        _ = settle(m, [place(100)], at: 0)
        m.caught(id)
        var t = 0.0
        let shiver = run(m, [place(100)], from: &t, for: 0.05)
        #expect(abs(shiver.shown[0].sag) > 1)
        let rest = run(m, [place(100)], from: &t, for: 2.5)
        #expect(rest.shown[0].sag == 0)
        #expect(!m.moving)
    }
}

// MARK: - Notes on the real canvas

@MainActor
struct NoteCanvasTests {
    let bench: Bench
    let button: UUID

    init() {
        let bench = Bench()
        let go = CanvasTests.rect("Go", CGRect(x: 200, y: 200, width: 100, height: 50))
        bench.step { bench.store.add(go, onto: bench.a.id) }
        bench.store.selection = []
        self.bench = bench
        button = go.id
    }

    private var store: DocumentStore { bench.store }

    private func post(_ text: String, at p: CGPoint) -> UUID {
        store.tool = .note
        bench.click(p)
        let id = store.draftNote!.id
        bench.step { store.postNote(text) }
        return id
    }

    @Test func aClickWithTheNoteToolStartsANoteOnTheLayerThere() throws {
        store.tool = .note
        bench.click(CGPoint(x: 225, y: 240))
        let draft = try #require(store.draftNote)
        #expect(draft.on == button)
        #expect(abs(draft.at.x - 0.25) < 0.001 && abs(draft.at.y - 0.8) < 0.001)
        #expect(draft.area == nil)
        #expect(store.tool == .select)
        #expect(store.doc.notes == nil)
    }

    @Test func aClickOnTheTableStartsANoteOnTheCanvas() throws {
        store.tool = .note
        bench.click(CGPoint(x: 540, y: 600))
        let draft = try #require(store.draftNote)
        #expect(draft.on == nil)
        #expect(draft.at == CGPoint(x: 540, y: 600))
    }

    @Test func aLoopDrawnRoundAPartStartsANoteAboutThatPart() throws {
        store.tool = .note
        bench.drag(CGPoint(x: 190, y: 190), CGPoint(x: 310, y: 262))
        let draft = try #require(store.draftNote)
        #expect(draft.on == button)
        let area = try #require(store.doc.area(of: draft))
        #expect(abs(area.minX - 190) < 0.01 && abs(area.maxX - 310) < 0.01)
        #expect(abs(area.minY - 190) < 0.01 && abs(area.maxY - 262) < 0.01)
        #expect(store.noteCircle == nil)
    }

    @Test func theLoopShowsAsItIsDrawnAndEscapeLetsItGo() {
        store.tool = .note
        bench.drag(CGPoint(x: 190, y: 190), CGPoint(x: 310, y: 262), release: false)
        #expect(store.noteCircle != nil)
        bench.key(53)
        #expect(store.noteCircle == nil)
        bench.release(CGPoint(x: 310, y: 262))
        #expect(store.draftNote == nil)
    }

    @Test func postingWritesTheNoteAsOneStepAndOpensIt() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        #expect(store.draftNote == nil)
        #expect(store.doc.notes?.count == 1)
        #expect(store.doc.notes?.first?.text == "Bigger?")
        #expect(store.doc.notes?.first?.id == id)
        #expect(store.openThread == id)
        #expect(!store.isUnread(id))
        bench.undoLast()
        #expect(store.doc.notes == nil)
    }

    @Test func postingNoWordsLetsTheNoteGo() {
        store.tool = .note
        bench.click(CGPoint(x: 225, y: 240))
        bench.step { store.postNote("  \n ") }
        #expect(store.draftNote == nil)
        #expect(store.doc.notes == nil)
    }

    @Test func answeringAddsToTheThreadEachAStep() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.answer(id, " Yes, 20 more ") }
        #expect(store.doc.threads.first?.replies.map(\.text) == ["Yes, 20 more"])
        bench.undoLast()
        #expect(store.doc.threads.first?.replies.isEmpty == true)
        // No words, or no thread to answer: nothing.
        store.answer(id, "   ")
        store.answer(UUID(), "To nothing")
        #expect(store.doc.notes?.count == 1)
    }

    @Test func answersAnswerThreadsNotAnswers() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.answer(id, "Yes") }
        let reply = store.doc.threads[0].replies[0].id
        bench.step { store.answer(reply, "Nested") }
        #expect(store.doc.notes?.count == 2)
    }

    @Test func tickingOffClosesTheThreadAndUndoBringsItBack() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        #expect(store.openThread == id)
        bench.step { store.setDone(id, true) }
        #expect(store.doc.notesByID[id]?.isDone == true)
        #expect(store.openThread == nil)
        #expect(store.doc.reviewOrder.isEmpty)
        bench.undoLast()
        #expect(store.doc.notesByID[id]?.isDone == false)
        bench.step { store.setDone(id, true) }
        bench.step { store.setDone(id, false) }
        #expect(store.doc.notesByID[id]?.done == nil)
    }

    @Test func deletingAThreadTakesItsAnswersAndUndoBringsAllBack() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.answer(id, "Yes") }
        bench.step { store.deleteNote(id) }
        #expect(store.doc.notes == nil)
        #expect(store.openThread == nil)
        bench.undoLast()
        #expect(store.doc.notes?.count == 2)
    }

    @Test func deletingAnAnswerLeavesTheThread() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.answer(id, "Yes") }
        let reply = store.doc.threads[0].replies[0].id
        bench.step { store.deleteNote(reply) }
        #expect(store.doc.notes?.map(\.id) == [id])
    }

    @Test func changingTheWordsKeepsTheThreadAndNoWordsChangeNothing() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.changeNote(id, " Bigger, please ") }
        #expect(store.doc.notesByID[id]?.text == "Bigger, please")
        bench.step { store.changeNote(id, "") }
        #expect(store.doc.notesByID[id]?.text == "Bigger, please")
    }

    @Test func aPinPulledOntoAnotherLayerIsAboutThatLayerNow() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        let other = CanvasTests.rect("Other", CGRect(x: 650, y: 150, width: 200, height: 100))
        bench.step { store.add(other, onto: bench.b.id) }
        bench.step { store.moveNote(id, to: CGPoint(x: 700, y: 200), on: other.id) }
        let moved = store.doc.notesByID[id]!
        #expect(moved.on == other.id)
        #expect(moved.at == CGPoint(x: 0.25, y: 0.5))
        #expect(store.doc.spot(of: moved) == CGPoint(x: 700, y: 200))
        bench.undoLast()
        #expect(store.doc.notesByID[id]?.on == button)
    }

    @Test func aPinPulledIntoTheOpenIsOnTheCanvas() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.moveNote(id, to: CGPoint(x: 540, y: 700), on: nil) }
        let moved = store.doc.notesByID[id]!
        #expect(moved.on == nil)
        #expect(store.doc.spot(of: moved) == CGPoint(x: 540, y: 700))
    }

    @Test func aLoopPulledGoesRoundWhatIsThere() throws {
        store.tool = .note
        bench.drag(CGPoint(x: 190, y: 190), CGPoint(x: 310, y: 262))
        let id = store.draftNote!.id
        bench.step { store.postNote("These") }
        let other = CanvasTests.rect("Other", CGRect(x: 700, y: 200, width: 100, height: 50))
        bench.step { store.add(other, onto: bench.b.id) }
        // Its middle onto the other's middle.
        bench.step { store.moveNote(id, to: CGPoint(x: 750, y: 225), on: nil) }
        let moved = store.doc.notesByID[id]!
        #expect(moved.on == other.id)
        let area = try #require(store.doc.area(of: moved))
        #expect(abs(area.midX - 750) < 0.01 && abs(area.midY - 225) < 0.01)
        #expect(abs(area.width - 120) < 0.01)
    }

    @Test func takingALayerAwayKeepsItsNoteWhereItWasAndUndoPutsItBack() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        store.selection = [button]
        bench.step { store.deleteSelection() }
        let kept = store.doc.notesByID[id]!
        #expect(kept.on == nil)
        #expect(store.doc.spot(of: kept) == CGPoint(x: 225, y: 240))
        bench.undoLast()
        #expect(store.doc.notesByID[id]?.on == button)
    }

    @Test func movingTheLayerTakesItsNoteAlong() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        bench.step { store.edit("Move") { doc in doc.update(button) { $0.frame.origin.x += 50 } } }
        #expect(store.doc.spot(of: store.doc.notesByID[id]!) == CGPoint(x: 275, y: 240))
    }

    @Test func escapePutsAwayTheOpenNoteBeforeAnythingElse() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        store.selection = [button]
        #expect(store.openThread == id)
        bench.key(53)
        #expect(store.openThread == nil)
        #expect(store.selection == [button])
    }

    @Test func aClickBesideTheOpenNotePutsItAway() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        #expect(store.openThread == id)
        bench.click(CGPoint(x: 540, y: 650))
        #expect(store.openThread == nil)
    }

    @Test func togglingOpensAndClosesAndReads() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        store.openThread = nil
        store.toggleThread(id)
        #expect(store.openThread == id)
        store.toggleThread(id)
        #expect(store.openThread == nil)
    }

    @Test func whatOthersWroteIsNewUntilOpened() {
        var theirs = MarginNote(text: "Look at this", by: "Ben", replica: "ben-mac", time: Date().timeIntervalSince1970)
        theirs.put(at: CGPoint(x: 225, y: 240), on: button, in: store.doc)
        bench.step { store.edit("Write Note") { $0.notes = [theirs] } }
        #expect(store.isUnread(theirs.id))
        store.toggleThread(theirs.id)
        #expect(!store.isUnread(theirs.id))
        #expect(!store.wrote(theirs))
    }

    @Test func steppingGoesRoundTheOpenThreadsInReviewOrder() {
        let first = post("One", at: CGPoint(x: 225, y: 210))
        let second = post("Two", at: CGPoint(x: 225, y: 245))
        let third = post("Three", at: CGPoint(x: 800, y: 300))
        store.openThread = first
        store.stepThread(by: 1)
        #expect(store.openThread == second)
        store.stepThread(by: 1)
        #expect(store.openThread == third)
        store.stepThread(by: 1)
        #expect(store.openThread == first)
        store.stepThread(by: -1)
        #expect(store.openThread == third)
        bench.step { store.setDone(second, true) }
        store.openThread = first
        store.stepThread(by: 1)
        #expect(store.openThread == third)
    }

    /// What the margin draws, frame by frame, as the app works it out: no card ever over its own
    /// pin, open or shut, as the pin is pulled and as everything settles after.
    private func expectPinsShow(_ scene: NotesLayer.Scene, _ what: String) {
        for shown in scene.shown where shown.place.kind != .pin {
            let pin = CGRect(x: shown.pin.x - 11, y: shown.pin.y - 11, width: 22, height: 22)
            #expect(!shown.frame.intersects(pin), "\(what): its \(shown.place.kind) over its own pin")
        }
    }

    /// A loop drawn round the button with the note tool, then pulled by its pin off the artboard
    /// onto the table, in steps as a hand pulls it: below the sheets, past the right one, past the
    /// left one, into the narrow gap between them. Open and shut.
    @Test(arguments: [false, true])
    func aLoopPulledOffItsArtboardKeepsItsPinBesideItsCard(open: Bool) throws {
        let targets = [CGPoint(x: 560, y: 650), CGPoint(x: 1160, y: 250), CGPoint(x: -120, y: 250), CGPoint(x: 550, y: 250)]
        for target in targets {
            let bench = Bench()
            let store = bench.store
            let go = CanvasTests.rect("Go", CGRect(x: 200, y: 200, width: 100, height: 50))
            bench.step { store.add(go, onto: bench.a.id) }
            store.selection = []
            store.tool = .note
            bench.drag(CGPoint(x: 190, y: 190), CGPoint(x: 310, y: 262))
            let id = try #require(store.draftNote?.id)
            bench.step { store.postNote("These two") }
            store.openThread = open ? id : nil
            let motion = NoteMotion()
            var t = 0.0
            func frame(_ drag: NoteDrag?) -> NotesLayer.Scene {
                t += 1.0 / 120
                return NotesLayer.scene(store, drag: drag, pointed: nil, heights: [:], motion: motion, canvas: nil, now: t)
            }
            expectPinsShow(frame(nil), "before")
            let from = try #require(store.doc.spot(of: store.doc.notesByID[id]!))
            for i in 1...48 {
                let k = CGFloat(i) / 48
                let by = CGSize(width: (target.x - from.x) * k, height: (target.y - from.y) * k)
                expectPinsShow(frame(NoteDrag(id: id, by: by)), "pulling to \(target), step \(i)")
            }
            // Let go there, as the pin does: the loop goes round whatever is there, here nothing.
            bench.step { store.moveNote(id, to: target, on: nil) }
            motion.caught(id)
            #expect(store.doc.notesByID[id]?.on == nil, "\(target)")
            var last = NotesLayer.Scene()
            for i in 0..<180 {
                last = frame(nil)
                expectPinsShow(last, "settling at \(target), frame \(i)")
            }
            // At rest, nothing of the loop lies under its card either.
            let shown = try #require(last.shown.first { $0.id == id })
            if shown.place.kind != .pin, let area = shown.area {
                let loop = NoteLoop.points(seed: NoteLoop.seed(id), around: area)
                #expect(loop.allSatisfy { !shown.frame.contains($0) }, "the loop under its card at \(target)")
            }
            #expect(!motion.moving)
        }
    }

    /// A spot, not a loop, pulled the same ways.
    @Test func aSpotPulledOffItsArtboardKeepsItsPinBesideItsCard() throws {
        for target in [CGPoint(x: 560, y: 650), CGPoint(x: 1160, y: 250), CGPoint(x: -120, y: 250), CGPoint(x: 520, y: 250)] {
            let bench = Bench()
            let store = bench.store
            let id = UUID()
            var n = MarginNote(id: id, text: "Bigger?", by: "Me", replica: store.noteAuthor.replica, time: 1)
            n.put(at: CGPoint(x: 450, y: 250), on: bench.a.id, in: store.doc)
            bench.step { store.edit("Write Note") { $0.notes = [n] } }
            let motion = NoteMotion()
            var t = 0.0
            func frame(_ drag: NoteDrag?) -> NotesLayer.Scene {
                t += 1.0 / 120
                return NotesLayer.scene(store, drag: drag, pointed: nil, heights: [:], motion: motion, canvas: nil, now: t)
            }
            _ = frame(nil)
            for i in 1...48 {
                let k = CGFloat(i) / 48
                expectPinsShow(frame(NoteDrag(id: id, by: CGSize(width: (target.x - 450) * k, height: (target.y - 250) * k))), "pulling to \(target)")
            }
            bench.step { store.moveNote(id, to: target, on: nil) }
            for i in 0..<120 { expectPinsShow(frame(nil), "settling at \(target), frame \(i)") }
        }
    }

    @Test func showingAThreadOpensItAndPutsAwayAnyNoteBeingWritten() {
        let id = post("Bigger?", at: CGPoint(x: 225, y: 240))
        store.openThread = nil
        store.tool = .note
        bench.click(CGPoint(x: 800, y: 300))
        #expect(store.draftNote != nil)
        store.showThread(id)
        #expect(store.draftNote == nil)
        #expect(store.openThread == id)
    }
}

// MARK: - Cards as they are drawn

@MainActor
struct NoteCardTests {
    let bench = Bench()

    private func drawn(_ start: MarginNote, replies: [MarginNote] = [], open: Bool = false) -> CGFloat {
        let item = NotesLayer.Item(start: start, replies: replies, open: open, color: .blue)
        let height = open ? NoteCardSize.open(start, replies, answering: true) : NoteCardSize.shut(start, answered: !replies.isEmpty)
        let place = NotePlacement.Place(id: start.id, kind: .card, frame: CGRect(x: 0, y: 0, width: NotePlacement.width, height: height),
                                        side: .right, anchor: .zero)
        let shown = NotesLayer.Shown(id: start.id, key: "", item: item, place: place, frame: place.frame, anchor: .zero, pin: .zero)
        let view = NoteCard(store: bench.store, shown: shown, pointed: .constant(nil))
            .frame(width: NotePlacement.width)
            .environment(MenuHost())
        let host = NSHostingView(rootView: view)
        return host.fittingSize.height
    }

    private func note(_ text: String) -> MarginNote { MarginNote(text: text, by: "Anna", replica: "anna", time: 1) }

    /// A shut card is as tall as the margin works out before it is drawn, however long its words:
    /// otherwise it finds it has no room once drawn, folds to a flag, and turns to and fro.
    @Test func aShutCardIsAsTallAsTheMarginKnowsItIs() {
        let texts = ["Bigger?", "Can the headline be bigger? It gets lost on the photo.",
                     "Can the headline be bigger? It gets lost on the photo, and the subline under it is too close as well.",
                     String(repeating: "Much too long to show whole here, so it stops after three lines. ", count: 4)]
        for text in texts {
            let start = note(text)
            #expect(abs(drawn(start) - NoteCardSize.shut(start, answered: false)) <= 2, "\(text.prefix(30))")
            let answered = [MarginNote(thread: start.id, text: "Yes", by: "Ben", replica: "ben", time: 2)]
            #expect(abs(drawn(start, replies: answered) - NoteCardSize.shut(start, answered: true)) <= 2)
        }
    }

    @Test func shutCardsGrowWithTheirWordsUpToThreeLines() {
        let one = NoteCardSize.shut(note("Bigger?"), answered: false)
        let two = NoteCardSize.shut(note("Can the headline be bigger? It gets lost on the photo."), answered: false)
        let many = NoteCardSize.shut(note(String(repeating: "Far too many words for a card. ", count: 20)), answered: false)
        let more = NoteCardSize.shut(note(String(repeating: "Far too many words for a card. ", count: 40)), answered: false)
        #expect(one < two)
        #expect(two < many)
        #expect(many == more)
        #expect(NoteCardSize.shut(note("Bigger?"), answered: true) > one)
        #expect(NoteCardSize.lines(String(repeating: "word ", count: 200), limit: 3) == 3)
    }

    @Test func anOpenCardIsAboutAsTallAsItWillBe() {
        let start = note("Can the headline be bigger? It gets lost on the photo.")
        let replies = [MarginNote(thread: start.id, text: "Yes, 20 more, and a softer shadow behind it.", by: "Ben", replica: "ben", time: 2)]
        let estimate = NoteCardSize.open(start, replies, answering: true)
        #expect(abs(drawn(start, replies: replies, open: true) - estimate) <= 8)
    }

    @Test func aRightClickOffersBezzlesOwnMenuForTheNote() {
        let store = bench.store
        var mine = MarginNote(text: "Mine", by: "Me", replica: store.noteAuthor.replica, time: 1)
        mine.put(at: CGPoint(x: 150, y: 150), on: nil, in: store.doc)
        var theirs = MarginNote(text: "Theirs", by: "Ben", replica: "ben", time: 2)
        theirs.put(at: CGPoint(x: 160, y: 160), on: nil, in: store.doc)
        bench.step { store.edit("Write Note") { $0.notes = [mine, theirs] } }
        func titles(_ n: MarginNote, done: Bool = false) -> [String] {
            NoteMenu.thread(NotesLayer.Item(start: n, replies: [], done: done, color: .blue), store: store).filter { $0.kind == .item }.map(\.title)
        }
        #expect(titles(mine) == ["Answer", "Mark as Done", "Edit", "Copy", "Delete"])
        #expect(titles(theirs) == ["Answer", "Mark as Done", "Copy"])
        #expect(titles(theirs, done: true) == ["Open Again", "Copy"])
        // Answer from the menu: the thread opens with the typing in its answer.
        let answer = NoteMenu.thread(NotesLayer.Item(start: theirs, replies: [], color: .blue), store: store).first { $0.title == "Answer" }
        answer?.action()
        #expect(store.openThread == theirs.id)
        #expect(store.noteFocus == .answer(theirs.id))
        #expect(!store.isUnread(theirs.id))
        // Ticking off from the menu.
        let tick = NoteMenu.thread(NotesLayer.Item(start: theirs, replies: [], color: .blue), store: store).first { $0.title == "Mark as Done" }
        bench.step { tick?.action() }
        #expect(store.doc.notesByID[theirs.id]?.isDone == true)
    }

    @Test func changingAnAnswerFromItsThreadOpensTheThread() {
        let store = bench.store
        var start = MarginNote(text: "Bigger?", by: "Ben", replica: "ben", time: 1)
        start.put(at: CGPoint(x: 150, y: 150), on: nil, in: store.doc)
        let reply = MarginNote(thread: start.id, text: "Yes", by: "Me", replica: store.noteAuthor.replica, time: 2)
        bench.step { store.edit("Write Note") { $0.notes = [start, reply] } }
        store.focusNote(.change(reply.id))
        #expect(store.openThread == start.id)
        #expect(store.noteFocus == .change(reply.id))
        store.noteFocus = nil
        store.focusNote(.answer(UUID()))
        #expect(store.noteFocus == nil)
    }
}

// MARK: - Flying to a note

@MainActor
struct NotesViewTests {
    let size = CGSize(width: 1200, height: 800)

    @Test func aNoteInSightNeedsNoFlight() {
        let vp = Viewport(origin: .zero, zoom: 1)
        #expect(NotesView.target(showing: CGPoint(x: 300, y: 300), area: nil, home: CGRect(x: 100, y: 100, width: 400, height: 400),
                                 from: vp, in: size) == nil)
    }

    @Test func aNoteOutOfSightIsFlownToWithItsMargin() throws {
        let vp = Viewport(origin: .zero, zoom: 1)
        let home = CGRect(x: 3000, y: 2000, width: 400, height: 400)
        let spot = CGPoint(x: 3300, y: 2100)
        let target = try #require(NotesView.target(showing: spot, area: nil, home: home, from: vp, in: size))
        #expect(target.zoom == 1)
        let seen = CGRect(origin: target.origin, size: size)
        #expect(seen.contains(spot))
        #expect(seen.maxX >= home.maxX + NotePlacement.gap + NotePlacement.width)
    }

    @Test func tooFarOutToReadTheViewComesIn() throws {
        let vp = Viewport(origin: .zero, zoom: 0.1)
        let home = CGRect(x: 0, y: 0, width: 400, height: 800)
        let target = try #require(NotesView.target(showing: CGPoint(x: 200, y: 400), area: nil, home: home, from: vp, in: size))
        #expect(target.zoom > 0.1)
        #expect(target.zoom <= 1)
        #expect(home.height * target.zoom >= 260)
    }

    @Test func closeInTheViewIsNotPulledOut() throws {
        let vp = Viewport(origin: CGPoint(x: 5000, y: 5000), zoom: 4)
        let target = try #require(NotesView.target(showing: CGPoint(x: 200, y: 400), area: nil, home: nil, from: vp, in: size))
        #expect(target.zoom == 4)
    }
}

// MARK: - The assistant

@MainActor
struct NoteMCPTests {
    let bench: Bench
    let tools = MCPTools()
    let button: UUID

    init() {
        let bench = Bench()
        MCPTools.opened(bench.store)
        let go = CanvasTests.rect("Go", CGRect(x: 200, y: 200, width: 100, height: 50))
        bench.step { bench.store.add(go, onto: bench.a.id) }
        self.bench = bench
        button = go.id
    }

    private func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool, object: [String: Any]) {
        var arguments = arguments
        arguments["design"] = bench.store.name
        let result = await tools.call("notes", arguments)
        let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (text, object?["isError"] as? Bool == true, inner)
    }

    private func threads(_ object: [String: Any]) -> [[String: Any]] { object["threads"] as? [[String: Any]] ?? [] }

    @Test func theAssistantWritesAnswersTicksOffAndRemoves() async throws {
        let wrote = await call(["write": "Bigger?", "layer": "Go", "x": 0.25, "y": 0.8])
        #expect(!wrote.failed, "\(wrote.text)")
        let id = try #require((wrote.object["made"] as? [String])?.first)
        let note = try #require(bench.store.doc.notesByID[UUID(uuidString: id)!])
        #expect(note.by == "Claude")
        #expect(note.on == button)
        #expect(bench.store.doc.spot(of: note) == CGPoint(x: 225, y: 240))
        let at = threads(wrote.object).first?["at"] as? [String: Double]
        #expect(at?["x"] == 225 && at?["y"] == 240)

        let answered = await call(["answer": "Yes, 20 more", "thread": id])
        #expect(!answered.failed)
        #expect((threads(answered.object).first?["answers"] as? [[String: Any]])?.first?["text"] as? String == "Yes, 20 more")

        let closed = await call(["close": [id]])
        #expect(!closed.failed)
        #expect(threads(closed.object).first?["closed"] as? Bool == true)
        let reopened = await call(["reopen": id])
        #expect(threads(reopened.object).first?["closed"] == nil)

        let removed = await call(["remove": [id]])
        #expect(!removed.failed)
        #expect(threads(removed.object).isEmpty)
        #expect(bench.store.doc.notes == nil)
    }

    @Test func theAssistantCirclesAPart() async throws {
        let wrote = await call(["write": "These", "area": ["x": 190, "y": 190, "width": 120, "height": 72]])
        #expect(!wrote.failed, "\(wrote.text)")
        let thread = try #require(threads(wrote.object).first)
        #expect((thread["about"] as? String)?.contains("Go") == true)
        let area = thread["area"] as? [String: Double]
        #expect(area?["x"] == 190 && area?["width"] == 120)
    }

    @Test func theAssistantMovesAThread() async throws {
        let wrote = await call(["write": "Here", "x": 900, "y": 600])
        let id = try #require((wrote.object["made"] as? [String])?.first)
        #expect(threads(wrote.object).first?["about"] as? String == "the canvas")
        let moved = await call(["thread": id, "move": ["x": 225, "y": 240]])
        #expect(!moved.failed, "\(moved.text)")
        #expect((threads(moved.object).first?["about"] as? String)?.contains("Go") == true)
        let circled = await call(["thread": id, "area": ["x": 650, "y": 150, "width": 100, "height": 50]])
        #expect(!circled.failed, "\(circled.text)")
        #expect(threads(circled.object).first?["area"] != nil)
    }

    @Test func theAssistantShowsAThreadOnScreen() async throws {
        let wrote = await call(["write": "Look", "layer": "Go"])
        let id = try #require((wrote.object["made"] as? [String])?.first)
        let shown = await call(["show": id])
        #expect(!shown.failed, "\(shown.text)")
        #expect(bench.store.openThread?.uuidString == id)
        #expect(threads(shown.object).first?["open"] as? Bool == true)
        _ = await call(["close": [id]])
        let ticked = await call(["show": id])
        #expect(ticked.failed)
    }

    @Test func whatIsWrongIsSaid() async {
        #expect(await call(["write": "  "]).failed)
        #expect(await call(["write": "Where?"]).failed)
        #expect(await call(["answer": "To what?"]).failed)
        #expect(await call(["answer": "To what?", "thread": UUID().uuidString]).failed)
        #expect(await call(["close": [UUID().uuidString]]).failed)
        #expect(await call(["write": "Bad", "area": ["x": 0, "y": 0, "width": 0, "height": 10]]).failed)
        #expect(await call(["move": ["x": 1, "y": 1]]).failed)
        #expect(bench.store.doc.notes == nil)
    }

    @Test func theAssistantsNotesAreOneStepEach() async {
        _ = await call(["write": "One", "layer": "Go"])
        _ = await call(["write": "Two", "layer": "Go"])
        #expect(bench.store.doc.notes?.count == 2)
        bench.undoLast()
        #expect(bench.store.doc.notes?.map(\.text) == ["One"])
    }
}
