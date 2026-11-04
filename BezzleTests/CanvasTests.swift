import Testing
import AppKit
@testable import Bezzle

/// Drives the real canvas with mouse and key events, as a person would with the pointer: drawing,
/// moving, resizing, turning, typing, and undoing all of it. The canvas is kept out of any window,
/// so nothing is drawn: the test host trips over AppKit drawing a main-actor view between tests.
@MainActor
final class Bench {
    let store: DocumentStore
    let canvas: CanvasView
    let undo = UndoManager()

    /// An artboard "A" at 100,100 sized 400×300, and "B" at 600,100 the same size.
    init(extra: [Node] = []) {
        var a = Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        a.children = extra
        let b = Node(kind: .artboard, name: "B", frame: CGRect(x: 600, y: 100, width: 400, height: 300))
        var doc = BezzleDocument()
        doc.nodes = [a, b]
        doc.viewport = Viewport(origin: .zero, zoom: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
        store = DocumentStore(url: url, document: doc)
        canvas = CanvasView(store: store)
        canvas.wantsLayer = false
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        store.canvas = canvas
        store.undoManager = undo
        undo.groupsByEvent = false
        store.viewport = Viewport(origin: .zero, zoom: 1)
    }

    var a: Node { store.doc.nodes[0] }
    var b: Node { store.doc.nodes[1] }

    func node(_ name: String) -> Node? { store.doc.allNodes.first { $0.name == name } }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        let view = store.viewport.toView(p)
        let inWindow = canvas.convert(view, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// One step a person takes, undone as one: what a pass of the run loop is in the app. With no
    /// event loop turning here, the undo manager is told where each step begins and ends.
    func step(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// Presses at `from`, moves through to `to` in a few steps, lets go unless told to hold on.
    /// Points are on the canvas.
    func drag(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = [], release: Bool = true) {
        step {
            canvas.mouseDown(with: event(.leftMouseDown, from, flags: flags))
            for i in 1...4 {
                let t = CGFloat(i) / 4
                canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), flags: flags))
            }
            if release { canvas.mouseUp(with: event(.leftMouseUp, to, flags: flags)) }
        }
    }

    /// Lets go of a drag held on with `release: false`.
    func release(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        step { canvas.mouseUp(with: event(.leftMouseUp, p, flags: flags)) }
    }

    /// The pointer moving over the canvas with nothing pressed.
    func move(_ p: CGPoint) {
        canvas.mouseMoved(with: event(.mouseMoved, p, clicks: 0))
    }

    func click(_ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        step {
            canvas.mouseDown(with: event(.leftMouseDown, p, flags: flags, clicks: clicks))
            canvas.mouseUp(with: event(.leftMouseUp, p, flags: flags, clicks: clicks))
        }
    }

    func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        step { canvas.keyDown(with: e) }
    }

    /// A turn of the wheel, in lines, or a trackpad's swipe in points when `precise`.
    func scroll(dx: Int32 = 0, dy: Int32 = 0, flags: CGEventFlags = [], precise: Bool = false) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        cg.flags = flags
        canvas.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }

    /// Holds the wheel down at `from` and drags to `to`. Points are on the canvas as it was when
    /// the drag began: the pointer moves over the screen, and the canvas moves under it.
    func middleDrag(_ from: CGPoint, _ to: CGPoint) {
        // The wheel is the third button, as a mouse reports it.
        func wheel(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            let cg = event(type, p).cgEvent!
            cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return NSEvent(cgEvent: cg)!
        }
        let down = wheel(.otherMouseDown, from)
        let halfway = wheel(.otherMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
        let there = wheel(.otherMouseDragged, to)
        let up = wheel(.otherMouseUp, to)
        canvas.otherMouseDown(with: down)
        canvas.otherMouseDragged(with: halfway)
        canvas.otherMouseDragged(with: there)
        canvas.otherMouseUp(with: up)
    }

    func undoLast() {
        undo.undo()
    }

    /// The text view laid over the canvas while typing.
    var editor: NSTextView? { canvas.subviews.first?.subviews.first as? NSTextView }
}

@MainActor
struct CanvasTests {
    static func rect(_ name: String, _ frame: CGRect) -> Node {
        Node(kind: .rectangle, name: name, frame: frame)
    }

    @Test func drawingARectangleOnAnArtboard() {
        let bench = Bench()
        bench.store.tool = .rectangle
        bench.drag(CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 220), flags: [.command])
        let r = try! #require(bench.a.children.first)
        #expect(r.kind == .rectangle)
        #expect(r.frame == CGRect(x: 50, y: 50, width: 100, height: 70))
        #expect(bench.store.selection == [r.id])
        #expect(bench.store.tool == .select)
        bench.undoLast()
        #expect(bench.a.children.isEmpty)
    }

    @Test func theArtboardToolLetsGoOfTheSelection() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.click(CGPoint(x: 130, y: 130))
        #expect(bench.store.selection == [bench.node("R")!.id])
        bench.store.tool = .rectangle
        #expect(!bench.store.selection.isEmpty)
        bench.store.tool = .artboard
        #expect(bench.store.selection.isEmpty)
    }

    @Test func shiftDrawsASquareAndAClickMakesOneOfAHundred() {
        let bench = Bench()
        bench.store.tool = .ellipse
        bench.drag(CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 190), flags: [.shift, .command])
        #expect(bench.a.children.last?.frame.size == CGSize(width: 100, height: 100))
        bench.store.tool = .rectangle
        bench.click(CGPoint(x: 700, y: 150))
        #expect(bench.b.children.last?.frame == CGRect(x: 100, y: 50, width: 100, height: 100))
    }

    @Test func draggingMovesAndUndoPutsItBack() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.drag(CGPoint(x: 130, y: 130), CGPoint(x: 161, y: 147), flags: [.command])
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 41, y: 27))
        bench.undoLast()
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 10, y: 10))
    }

    @Test func movingSnapsToTheArtboardsMiddle() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        // The artboard's middle is at x 200 inside it; the square's middle starts at 35.
        bench.drag(CGPoint(x: 130, y: 130), CGPoint(x: 293, y: 130))
        #expect(bench.node("R")?.frame.midX == 200)
        #expect(bench.store.guides.isEmpty)
    }

    @Test func draggingAcrossMovesALayerOntoTheOtherArtboard() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.drag(CGPoint(x: 130, y: 130), CGPoint(x: 680, y: 160), flags: [.command])
        #expect(bench.a.children.isEmpty)
        let moved = try! #require(bench.b.children.first)
        #expect(moved.frame.origin == CGPoint(x: 60, y: 40))
        // And off any artboard, onto the canvas.
        bench.drag(CGPoint(x: 690, y: 170), CGPoint(x: 690, y: 600), flags: [.command])
        #expect(bench.store.doc.nodes.contains { $0.name == "R" })
        bench.undoLast()
        #expect(bench.b.children.first?.name == "R")
    }

    @Test func optionDragLeavesTheOriginalAndMovesACopy() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.drag(CGPoint(x: 130, y: 130), CGPoint(x: 230, y: 130), flags: [.option, .command])
        let all = bench.a.children.filter { $0.name == "R" }
        #expect(all.count == 2)
        #expect(Set(all.map(\.frame.minX)) == [10, 110])
        bench.undoLast()
        #expect(bench.a.children.count == 1)
    }

    /// The gaps marked on the canvas, each as wide as it is.
    private static func marked(_ bench: Bench) -> [CGFloat] {
        bench.store.guides.filter(\.gap).map { hypot($0.to.x - $0.from.x, $0.to.y - $0.from.y) }
    }

    @Test func aLayerMovedBetweenTwoCatchesHalfwayAndShowsTheEvenGaps() {
        // On the canvas, Left from 120 to 160 across and Right from 320 to 360, both 200 to 240 down.
        let bench = Bench(extra: [CanvasTests.rect("Left", CGRect(x: 20, y: 100, width: 40, height: 40)),
                                  CanvasTests.rect("Right", CGRect(x: 220, y: 100, width: 40, height: 40)),
                                  CanvasTests.rect("M", CGRect(x: 150, y: 180, width: 40, height: 40))])
        // From 250,280 to two points short of halfway across, and three below the others' tops.
        bench.drag(CGPoint(x: 270, y: 300), CGPoint(x: 238, y: 223), release: false)
        #expect(bench.node("M")?.frame.origin == CGPoint(x: 120, y: 100))
        #expect(Self.marked(bench) == [60, 60])
        bench.release(CGPoint(x: 238, y: 223))
        #expect(bench.store.guides.isEmpty)
    }

    @Test func aLayerMovedBesideARowKeepsTheGapTheRowHas() {
        // A from 120 to 160 across, B from 180 to 220: twenty apart.
        let bench = Bench(extra: [CanvasTests.rect("A", CGRect(x: 20, y: 100, width: 40, height: 40)),
                                  CanvasTests.rect("B", CGRect(x: 80, y: 100, width: 40, height: 40)),
                                  CanvasTests.rect("M", CGRect(x: 200, y: 200, width: 40, height: 40))])
        // To two points past twenty after B.
        bench.drag(CGPoint(x: 320, y: 320), CGPoint(x: 262, y: 220), release: false)
        #expect(bench.node("M")?.frame.origin == CGPoint(x: 140, y: 100))
        #expect(Self.marked(bench).sorted() == [20, 20])
        bench.release(CGPoint(x: 262, y: 220))
        // With Command, nothing catches.
        bench.drag(CGPoint(x: 260, y: 220), CGPoint(x: 263, y: 221), flags: .command, release: false)
        #expect(bench.node("M")?.frame.origin == CGPoint(x: 143, y: 101))
        #expect(Self.marked(bench).isEmpty)
    }

    @Test func aLayerMovedUnderOneOfARowKeepsTheGapTheRowHasAcross() {
        // A from 120 to 160 across and B from 180 to 220, both 120 to 160 down: twenty apart.
        let bench = Bench(extra: [CanvasTests.rect("A", CGRect(x: 20, y: 20, width: 40, height: 40)),
                                  CanvasTests.rect("B", CGRect(x: 80, y: 20, width: 40, height: 40)),
                                  CanvasTests.rect("C", CGRect(x: 300, y: 200, width: 40, height: 40))])
        // Under A, a point to its right and two points further down than twenty.
        bench.drag(CGPoint(x: 420, y: 320), CGPoint(x: 141, y: 202), release: false)
        #expect(bench.node("C")?.frame.origin == CGPoint(x: 20, y: 80))
        let gaps = bench.store.guides.filter(\.gap)
        #expect(Self.marked(bench) == [20, 20])
        // Its own gap runs down from A, and the one it matches across from A to B.
        #expect(gaps.first { $0.mine }.map { $0.from.x == $0.to.x } == true)
        #expect(gaps.first { !$0.mine }.map { $0.from.y == $0.to.y } == true)
    }

    @Test func anArtboardMovedBesideOthersKeepsTheGapBetweenThem() {
        // A from 100 to 500 across and B from 600 to 1000: a hundred apart. C lies off below.
        let bench = Bench()
        bench.step { bench.store.edit("Add") { $0.nodes.append(Node(kind: .artboard, name: "C", frame: CGRect(x: 1200, y: 600, width: 400, height: 300))) } }
        // By its name, above its top left, to two past a hundred after B and three below the others.
        bench.drag(CGPoint(x: 1205, y: 589), CGPoint(x: 1107, y: 92), flags: [], release: false)
        #expect(bench.node("C")?.frame.origin == CGPoint(x: 1100, y: 100))
        #expect(Self.marked(bench) == [100, 100])
        #expect(bench.store.guides.filter(\.mine).count == 1)
    }

    @Test func aCopyDraggedOutWithOptionKeepsTheGapToTheOriginal() {
        // A from 120 to 160 across, B from 180 to 220: a copy of B catches twenty after it.
        let bench = Bench(extra: [CanvasTests.rect("A", CGRect(x: 20, y: 100, width: 40, height: 40)),
                                  CanvasTests.rect("B", CGRect(x: 80, y: 100, width: 40, height: 40))])
        bench.click(CGPoint(x: 200, y: 220))
        bench.drag(CGPoint(x: 200, y: 220), CGPoint(x: 263, y: 221), flags: .option, release: false)
        let copies = bench.a.children.filter { $0.name == "B" }
        #expect(copies.count == 2)
        #expect(copies.last?.frame.origin == CGPoint(x: 140, y: 100))
        #expect(Self.marked(bench).sorted() == [20, 20])
    }

    @Test func resizingFromTheCornerHandle() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.click(CGPoint(x: 130, y: 130))
        // The bottom right handle sits at 160,160 on the canvas.
        bench.drag(CGPoint(x: 160, y: 160), CGPoint(x: 200, y: 180), flags: [.command])
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 90, height: 70))
        bench.drag(CGPoint(x: 200, y: 180), CGPoint(x: 230, y: 190), flags: [.shift, .command])
        let f = try! #require(bench.node("R")?.frame)
        #expect(abs(f.width / f.height - 90.0 / 70.0) < 0.02)
    }

    @Test func withShiftACatchNeverBendsTheShape() {
        // "T"'s left edge is at 400 on the canvas; the artboard's middle across at 250.
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 50)),
                                  CanvasTests.rect("T", CGRect(x: 300, y: 10, width: 50, height: 50))])
        bench.click(CGPoint(x: 150, y: 130))
        // Pulled by its bottom right corner (210,160) to where its right edge is 3 short of T and its
        // bottom 3.5 past the middle: both would catch, and only the nearer one does.
        bench.drag(CGPoint(x: 210, y: 160), CGPoint(x: 397, y: 230), flags: .shift, release: false)
        let f = try! #require(bench.node("R")?.frame)
        #expect(f == CGRect(x: 10, y: 10, width: 290, height: 145))
        #expect(bench.store.guides.contains { $0.from.x == 400 && $0.to.x == 400 })
        #expect(!bench.store.guides.contains { $0.from.y == 250 && $0.to.y == 250 })
        bench.release(CGPoint(x: 397, y: 230), flags: .shift)
    }

    @Test func aProportionalCatchFromASideATurnOverAndTheMiddle() {
        var targets = SnapTargets(doc: BezzleDocument(), moving: [])
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        targets.xs = [.init(value: 300, box: box), .init(value: -100, box: box)]
        targets.ys = [.init(value: 260, box: box)]
        // From the right side: the width catches, the height follows round the middle.
        let (side, _) = targets.snap(CGRect(x: 100, y: 75, width: 197, height: 98.5), keeping: 2, anchor: CGPoint(x: 100, y: 124.25),
                                     along: (true, false), threshold: 5)
        #expect(side == CGRect(x: 100, y: 74.25, width: 200, height: 100))
        // Dragged past its still corner at 100,100, it catches by its left edge, on the other side.
        let (over, _) = targets.snap(CGRect(x: -97, y: 0, width: 197, height: 100), keeping: 1.97, anchor: CGPoint(x: 100, y: 100),
                                     along: (true, true), threshold: 5)
        #expect(over.maxX == 100 && over.minX == -100 && abs(over.width / over.height - 1.97) < 0.0001)
        // Grown from its middle at 200,200, a square catches by its bottom edge, and grows round it.
        let (middle, _) = targets.snap(CGRect(x: 142, y: 142, width: 116, height: 116), keeping: 1, anchor: CGPoint(x: 200, y: 200),
                                       along: (true, true), threshold: 5)
        #expect(middle == CGRect(x: 140, y: 140, width: 120, height: 120))
    }

    @Test func aSquareDrawnWithShiftShowsOnlyWhatItCatches() {
        let bench = Bench(extra: [CanvasTests.rect("T", CGRect(x: 300, y: 10, width: 50, height: 50))])
        bench.store.tool = .rectangle
        // The pointer comes 3 short of T's left edge (400), but the square, as tall as the pointer is
        // far down, reaches 410: it does not catch there, and no guide says it does.
        bench.drag(CGPoint(x: 150, y: 120), CGPoint(x: 397, y: 380), flags: .shift, release: false)
        let r = try! #require(bench.a.children.last)
        #expect(r.frame.width == r.frame.height && r.frame.width == 260)
        #expect(!bench.store.guides.contains { $0.from.x == 400 && $0.to.x == 400 })
        bench.release(CGPoint(x: 397, y: 380), flags: .shift)
    }

    @Test func aCornerDotRoundsEveryCornerOrWithOptionOnlyItsOwn() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 50, y: 50, width: 200, height: 200))])
        // On the canvas, from 150,150 to 350,350.
        bench.click(CGPoint(x: 250, y: 250))
        // Sharp, the top left dot sits ten points in: in to thirty rounds every corner.
        bench.drag(CGPoint(x: 160, y: 160), CGPoint(x: 180, y: 180))
        #expect(bench.node("R")?.radii == [30, 30, 30, 30])
        #expect(bench.node("R")?.corners == nil)
        // The top right dot, now thirty in, with Option: only that corner.
        bench.drag(CGPoint(x: 320, y: 180), CGPoint(x: 300, y: 200), flags: .option)
        #expect(bench.node("R")?.radii == [30, 50, 30, 30])
        #expect(bench.node("R")?.cornerRadius == 50)
        // Each dot sits as far in as its own corner is round: the bottom left one is still thirty in.
        bench.drag(CGPoint(x: 180, y: 320), CGPoint(x: 190, y: 310))
        #expect(bench.node("R")?.radii == [40, 40, 40, 40])
        #expect(bench.node("R")?.corners == nil)
        bench.undoLast()
        #expect(bench.node("R")?.radii == [30, 50, 30, 30])
    }

    /// "Good morning" at 24 points, 36 between lines, on artboard A at 40,40.
    private static func autoSizeText() -> Node {
        var t = Node(kind: .text, name: "T", frame: CGRect(x: 40, y: 40, width: 0, height: 0))
        t.text = "Good morning"
        t.style?.size = 24
        t.style?.lineSpacing = 36
        t.refit()
        return t
    }

    /// "Good morning" at 24 points, 36 between lines, wrapped at `width`, on artboard A at 40,40.
    private static func wrappedText(_ sizing: TextSizing, width: CGFloat, height: CGFloat? = nil) -> Node {
        var t = autoSizeText()
        t.style?.sizing = sizing
        t.frame.size = CGSize(width: width, height: height ?? 0)
        t.refit()
        return t
    }

    // As Adobe XD has it: text as wide as its words has one handle, at its bottom, which grows
    // its letters; a fixed width's sides wrap its words, and its top, bottom or corners make it a
    // box of fixed size; a box of fixed size is resized, its letters as they are.

    @Test func textAsWideAsItsWordsGrowsItsLettersByItsOneHandle() {
        let bench = Bench(extra: [Self.autoSizeText()])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // Its bottom's handle, pulled down by half its height: its top and the side it is set to stay.
        let d = (start.height / 2).rounded(), k = (start.height + d) / start.height
        bench.drag(CGPoint(x: start.midX, y: start.maxY), CGPoint(x: start.midX, y: start.maxY + d), flags: .command)
        let grown = try! #require(bench.node("T")?.style)
        #expect(grown.sizing == .autoWidth)
        #expect(grown.size == (24 * k * 10).rounded() / 10)
        #expect(grown.lineSpacing == (36 * k * 10).rounded() / 10)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f.origin == start.origin)
        #expect(f.width > start.width)
        bench.undoLast()
        #expect(bench.node("T")?.style?.size == 24)
        #expect(bench.node("T")?.style?.lineSpacing == 36)
    }

    @Test func textAsWideAsItsWordsHasNoOtherHandles() {
        let bench = Bench(extra: [Self.autoSizeText()])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // Where a side's handle and a corner's would be: neither wraps it nor grows it.
        for from in [CGPoint(x: start.maxX, y: start.midY), CGPoint(x: start.maxX, y: start.minY)] {
            bench.drag(from, CGPoint(x: from.x - 40, y: from.y), flags: .command)
            let t = try! #require(bench.node("T"))
            #expect(t.style?.sizing == .autoWidth)
            #expect(t.style?.size == 24)
            #expect(bench.store.doc.absoluteFrame(of: id)?.size == start.size)
            bench.undoLast()
        }
    }

    @Test func aFixedWidthsSideWrapsItsWordsAndItsBottomMakesItABoxOfFixedSize() {
        let bench = Bench(extra: [Self.wrappedText(.autoHeight, width: 200)])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // The right side in to 80: the words wrap, as big as they were, and it is as tall as its lines.
        bench.drag(CGPoint(x: start.maxX, y: start.midY), CGPoint(x: start.minX + 80, y: start.midY), flags: .command)
        let wrapped = try! #require(bench.node("T"))
        #expect(wrapped.style?.sizing == .autoHeight)
        #expect(wrapped.style?.size == 24)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f.origin == start.origin)
        #expect(f.width == 80)
        #expect(f.height > start.height * 1.5)
        // Its bottom pulled down: a box of fixed size, as tall as it is pulled, its letters as they were.
        bench.drag(CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY + 50), flags: .command)
        let boxed = try! #require(bench.node("T"))
        #expect(boxed.style?.sizing == .fixed)
        #expect(boxed.style?.size == 24)
        #expect(bench.store.doc.absoluteFrame(of: id) == CGRect(x: f.minX, y: f.minY, width: 80, height: f.height + 50))
        bench.undoLast()
        #expect(bench.node("T")?.style?.sizing == .autoHeight)
    }

    @Test func aCornerOfAFixedWidthMakesABoxFromTheCornerAcrossToThePointer() {
        for (dx, dy) in [(1.0, 1.0), (0.0, 0.0), (1.0, 0.0), (0.0, 1.0)] as [(CGFloat, CGFloat)] {
            // Held partway, and let go.
            for release in [false, true] {
                let bench = Bench(extra: [Self.wrappedText(.autoHeight, width: 200)])
                let id = bench.node("T")!.id
                let start = try! #require(bench.store.doc.absoluteFrame(of: id))
                bench.click(CGPoint(x: start.midX, y: start.midY))
                let corner = CGPoint(x: start.minX + start.width * dx, y: start.minY + start.height * dy)
                let across = CGPoint(x: start.minX + start.width * (1 - dx), y: start.minY + start.height * (1 - dy))
                // Out by a third of its width and half its height.
                let to = CGPoint(x: corner.x + (dx == 1 ? 1 : -1) * (start.width / 3).rounded(), y: corner.y + (dy == 1 ? 1 : -1) * (start.height / 2).rounded())
                bench.drag(corner, to, flags: .command, release: release)
                let f = try! #require(bench.store.doc.absoluteFrame(of: id))
                #expect(f == Geometry.rect(from: across, to: to), "corner \(dx),\(dy), let go \(release): \(f) from \(start)")
                #expect(bench.node("T")?.style?.sizing == .fixed)
                #expect(bench.node("T")?.style?.size == 24)
            }
        }
    }

    @Test func aBoxOfFixedSizeHidesWhatDoesNotFitAndItsBottomHandleFitsIt() throws {
        let bench = Bench(extra: [Self.wrappedText(.fixed, width: 200, height: 100)])
        let id = bench.node("T")!.id
        let start = try #require(bench.store.doc.absoluteFrame(of: id))
        #expect(start.size == CGSize(width: 200, height: 100))
        #expect(bench.node("T")?.overflows == false)
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // Its corner in to 80 by 30: the box is that, its letters as they were, and what does not fit hidden.
        bench.drag(CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX + 80, y: start.minY + 30), flags: .command)
        let f = try #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f == CGRect(origin: start.origin, size: CGSize(width: 80, height: 30)))
        #expect(bench.node("T")?.style?.size == 24)
        #expect(bench.node("T")?.overflows == true)
        // Seen as a picture, the lines it hides are cut off at its bottom.
        var board = Node(kind: .artboard, name: "B", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        board.children = [try #require(bench.node("T"))]
        let item = ExportItem(artboard: board)
        let svg = SVGWriter.document(for: item, bounds: item.bounds(assets: nil), assets: nil)
        #expect(svg.contains("<clipPath") && svg.contains("height=\"30\""))
        // A double click on its bottom handle fits it to its words, as tall as they are again.
        bench.click(CGPoint(x: f.midX, y: f.maxY))
        bench.click(CGPoint(x: f.midX, y: f.maxY), clicks: 2)
        let fitted = try #require(bench.node("T"))
        #expect(fitted.style?.sizing == .autoHeight)
        #expect(fitted.overflows == false)
        let g = try #require(bench.store.doc.absoluteFrame(of: id))
        #expect(g.origin == f.origin)
        #expect(g.width == 80)
        #expect(g.height > 60)
        bench.undoLast()
        #expect(bench.node("T")?.style?.sizing == .fixed)
        #expect(bench.store.doc.absoluteFrame(of: id) == f)
    }

    @Test func sizesTypedInResizeAsTheHandlesDo() {
        // As wide as its words: its letters and lines grow, by the height, or by the width alone.
        var t = Self.autoSizeText()
        t.resizeText(to: CGSize(width: t.frame.width, height: t.frame.height * 2), byHeight: true)
        #expect(t.style?.sizing == .autoWidth)
        #expect(t.style?.size == 48)
        #expect(t.style?.lineSpacing == 72)
        t.resizeText(to: CGSize(width: t.frame.width / 2, height: t.frame.height), byHeight: false)
        #expect(t.style?.size == 24)
        // A fixed width: a width wraps its words; a height makes it a box of fixed size.
        var w = Self.wrappedText(.autoHeight, width: 200)
        let start = w.frame
        w.resizeText(to: CGSize(width: 80, height: start.height), byHeight: false)
        #expect(w.style?.sizing == .autoHeight)
        #expect(w.style?.size == 24)
        #expect(w.frame.width == 80)
        #expect(w.frame.height > start.height)
        w.resizeText(to: CGSize(width: 80, height: 240), byHeight: true)
        #expect(w.style?.sizing == .fixed)
        #expect(w.style?.size == 24)
        #expect(w.frame.size == CGSize(width: 80, height: 240))
        // A box of fixed size takes the size, too small or not.
        w.resizeText(to: CGSize(width: 60, height: 20), byHeight: false)
        #expect(w.frame.size == CGSize(width: 60, height: 20))
        #expect(w.style?.size == 24)
        #expect(w.overflows)
    }

    @Test func madeAsWideAsItsWordsItsLinesBreakWhereTheyWrapped() {
        var t = Self.wrappedText(.autoHeight, width: 110)
        #expect(TextLayout.layout(t).usedSize.height > 60)
        t.setSizing(.autoWidth)
        #expect(t.text == "Good\nmorning")
        #expect(t.style?.sizing == .autoWidth)
        #expect(t.frame.width < 110)
        // A fixed width again keeps the break.
        t.setSizing(.autoHeight)
        #expect(t.text == "Good\nmorning")
        // Lines that do not wrap are left as they are.
        var one = Self.autoSizeText()
        one.style?.sizing = .fixed
        one.frame.size = CGSize(width: 300, height: 100)
        one.setSizing(.autoWidth)
        #expect(one.text == "Good morning")
    }

    @Test func textOfAutoSizeInAGroupGrowsItsLinesWithIt() {
        let t = Self.autoSizeText()
        let scaled = BezzleDocument.scaled([t], from: CGSize(width: 100, height: 100), to: CGSize(width: 100, height: 200))
        #expect(scaled[0].style?.size == 48)
        #expect(scaled[0].style?.lineSpacing == 72)
    }

    @Test func turningFromJustOutsideACorner() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.click(CGPoint(x: 130, y: 130))
        // Out past the bottom right corner, then round to the bottom left: a quarter turn.
        bench.drag(CGPoint(x: 170, y: 170), CGPoint(x: 100, y: 170), flags: [.shift])
        #expect(bench.node("R")?.rotation == 90)
        #expect(bench.node("R")?.frame.center == CGPoint(x: 35, y: 35))
    }

    @Test func marqueeSelectsWhatItTouches() {
        let bench = Bench(extra: [CanvasTests.rect("R1", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("R2", CGRect(x: 100, y: 10, width: 50, height: 50)),
                                  CanvasTests.rect("R3", CGRect(x: 300, y: 200, width: 50, height: 50))])
        bench.drag(CGPoint(x: 105, y: 105), CGPoint(x: 220, y: 140))
        let names = Set(bench.store.selectedNodes.map(\.name))
        #expect(names == ["R1", "R2"])
    }

    @Test func clickingAnArtboardsNameSelectsIt() {
        let bench = Bench()
        bench.click(CGPoint(x: 104, y: 92))
        #expect(bench.store.selection == [bench.a.id])
    }

    @Test func arrowKeysNudge() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.click(CGPoint(x: 130, y: 130))
        bench.key(124)
        bench.key(125, flags: .shift)
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 11, y: 20))
    }

    @Test func typingMakesATextLayer() {
        let bench = Bench()
        bench.store.tool = .text
        bench.click(CGPoint(x: 150, y: 150))
        let editor = try! #require(bench.editor)
        editor.insertText("Hello there", replacementRange: NSRange(location: 0, length: 0))
        bench.step { bench.canvas.endEditing() }
        let text = try! #require(bench.a.children.first)
        #expect(text.kind == .text)
        #expect(text.text == "Hello there")
        #expect(text.frame.width > 40)
        #expect(bench.store.editingText == nil)
        bench.undoLast()
        #expect(bench.a.children.isEmpty)
    }

    @Test func emptyTextIsNotKept() {
        let bench = Bench()
        bench.store.tool = .text
        bench.click(CGPoint(x: 150, y: 150))
        bench.step { bench.canvas.endEditing() }
        #expect(bench.a.children.isEmpty)
    }

    @Test func aClickWithTheTextToolIsWhereTheFirstBaselineBeginsAndTheToolStays() throws {
        let bench = Bench()
        bench.store.tool = .text
        bench.click(CGPoint(x: 150, y: 150))
        let editor = try #require(bench.editor)
        editor.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        let id = try #require(bench.store.editingText)
        let text = try #require(bench.store.node(id))
        let f = try #require(bench.store.doc.absoluteFrame(of: id))
        #expect(text.style?.sizing == .autoWidth)
        #expect(f.minX == 150)
        #expect(abs(f.minY + TextLayout.firstBaseline(text) - 150) <= 0.5)
        // Done typing, the Text tool is still in hand, as in XD; Esc puts it down.
        bench.step { bench.canvas.endEditing() }
        #expect(bench.store.tool == .text)
        #expect(bench.store.selection == [id])
        bench.key(53)
        #expect(bench.store.tool == .select)
    }

    @Test func aClickWithTheTextToolOnATextTypesIntoItAndADragDrawsANewOneLikeIt() throws {
        var t = Self.autoSizeText()
        t.style?.size = 40
        t.fill.color = RGBA(r: 0.8, g: 0.1, b: 0.1, a: 1)
        t.refit()
        let bench = Bench(extra: [t])
        let id = bench.node("T")!.id
        let start = try #require(bench.store.doc.absoluteFrame(of: id))
        bench.store.tool = .text
        bench.click(CGPoint(x: start.midX, y: start.midY))
        #expect(bench.store.editingText == id)
        #expect(bench.editor?.selectedRange() == NSRange(location: 0, length: 12))
        bench.step { bench.canvas.endEditing() }
        // A drag, though it begins on the text, draws a new one, looking as the text selected does.
        let from = CGPoint(x: start.minX + 10, y: start.midY)
        bench.drag(from, CGPoint(x: from.x + 190, y: from.y + 60), flags: .command)
        #expect(bench.a.children.count == 2)
        let newID = try #require(bench.store.editingText)
        #expect(newID != id)
        let drawn = try #require(bench.store.node(newID))
        #expect(drawn.style?.sizing == .autoHeight)
        #expect(drawn.style?.size == 40)
        #expect(drawn.style?.lineSpacing == 36)
        #expect(drawn.fill.color == t.fill.color)
        // Its box is as it was dragged out until words are typed, then as tall as they are.
        #expect(bench.store.doc.absoluteFrame(of: newID)?.size == CGSize(width: 190, height: 60))
        try #require(bench.editor).insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        let typed = try #require(bench.store.doc.absoluteFrame(of: newID))
        #expect(typed.width == 190)
        #expect(typed.height < 60)
        #expect(bench.store.tool == .text)
    }

    @Test func theHandlesOfATextBeingTypedIntoResizeItAndTypingGoesOn() throws {
        let bench = Bench(extra: [Self.wrappedText(.fixed, width: 200, height: 100)])
        let id = bench.node("T")!.id
        bench.step { bench.canvas.beginEditing(id, action: "Typing") }
        try #require(bench.editor).setSelectedRange(NSRange(location: 4, length: 0))
        let f = try #require(bench.store.doc.absoluteFrame(of: id))
        bench.drag(CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY + 40), flags: .command)
        #expect(bench.store.doc.absoluteFrame(of: id)?.size == CGSize(width: 200, height: 140))
        #expect(bench.store.editingText == id)
        #expect(bench.editor?.selectedRange() == NSRange(location: 4, length: 0))
        bench.undoLast()
        #expect(bench.store.doc.absoluteFrame(of: id)?.size == CGSize(width: 200, height: 100))
    }

    @Test func shiftTurnsTheWheelSideways() {
        let bench = Bench()
        bench.scroll(dy: -3)
        #expect(bench.store.viewport.origin.x == 0)
        #expect(bench.store.viewport.origin.y > 0)
        // Shift with a wheel the system has not turned, as from a trackpad or some mice…
        bench.store.viewport.origin = .zero
        bench.scroll(dy: -3, flags: .maskShift)
        #expect(bench.store.viewport.origin.x > 0)
        #expect(bench.store.viewport.origin.y == 0)
        // …and one it has.
        bench.store.viewport.origin = .zero
        bench.scroll(dx: -3, flags: .maskShift)
        #expect(bench.store.viewport.origin.x > 0)
        #expect(bench.store.viewport.origin.y == 0)
        bench.store.viewport.origin = .zero
        bench.scroll(dy: -40, flags: .maskShift, precise: true)
        #expect(bench.store.viewport.origin.x > 0)
        #expect(bench.store.viewport.origin.y == 0)
    }

    @Test func holdingTheWheelDownDragsTheCanvas() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        bench.store.tool = .rectangle
        // Starting over a layer, with a drawing tool in hand: it neither moves nor draws.
        bench.middleDrag(CGPoint(x: 130, y: 130), CGPoint(x: 230, y: 180))
        #expect(bench.store.viewport.origin == CGPoint(x: -100, y: -50))
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 10, y: 10))
        #expect(bench.a.children.count == 1)
        #expect(bench.store.tool == .rectangle)
        #expect(!bench.undo.canUndo)
    }

    @Test func quickClicksGoDeeperIntoGroupsOneLevelEach() {
        var dot = CanvasTests.rect("Dot", CGRect(x: 0, y: 0, width: 20, height: 20))
        dot.fill.on = true
        var inner = Node(kind: .group, name: "Inner", frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        inner.children = [dot]
        var outer = Node(kind: .group, name: "Outer", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        outer.children = [inner]
        let bench = Bench(extra: [outer])
        // Four clicks in a row, as fast as they come: the counts go up with each.
        for (count, expected) in [(1, "Outer"), (2, "Inner"), (3, "Dot"), (4, "Dot")] {
            bench.click(CGPoint(x: 120, y: 120), clicks: count)
            #expect(bench.store.selectedNodes.first?.name == expected, "click \(count)")
        }
    }

    @Test func theTextBeingTypedStaysOnItsLayerAtAnyZoom() {
        func text(_ name: String, y: CGFloat, rotation: Double) -> Node {
            var t = Node(kind: .text, name: name, frame: CGRect(x: 40, y: y, width: 0, height: 0))
            t.text = "Good morning"
            t.refit()
            t.rotation = rotation
            return t
        }
        let bench = Bench(extra: [text("Upright", y: 40, rotation: 0), text("Turned", y: 160, rotation: 30)])
        bench.store.viewport = Viewport(origin: .zero, zoom: 0.5)
        for name in ["Upright", "Turned"] {
            let id = bench.node(name)!.id
            bench.step { bench.canvas.beginEditing(id, action: "Typing") }
            let host = try! #require(bench.editor?.superview)
            let frame = bench.store.doc.absoluteFrame(of: id)!
            let middle = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: bench.canvas)
            let wanted = bench.store.viewport.toView(CGPoint(x: frame.minX + host.bounds.width / 2, y: frame.midY))
            #expect(hypot(middle.x - wanted.x, middle.y - wanted.y) < 0.01, "\(name)")
            if name == "Upright" {
                let corner = host.convert(CGPoint.zero, to: bench.canvas), origin = bench.store.viewport.toView(frame.origin)
                #expect(hypot(corner.x - origin.x, corner.y - origin.y) < 0.01)
            }
            bench.step { bench.canvas.endEditing() }
        }
    }

    @Test func drawingALineEndsWhereThePointerWas() {
        let bench = Bench()
        bench.store.tool = .line
        bench.drag(CGPoint(x: 150, y: 250), CGPoint(x: 250, y: 150), flags: [.command])
        let line = try! #require(bench.a.children.first)
        #expect(line.kind == .line)
        #expect(line.rising)
        let (p, q) = line.lineEnds
        #expect(p == CGPoint(x: 50, y: 150))
        #expect(q == CGPoint(x: 150, y: 50))
    }
}
