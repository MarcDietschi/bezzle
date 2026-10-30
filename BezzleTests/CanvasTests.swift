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

    /// "Good morning" at 24 points, 36 between lines, on artboard A at 40,40.
    private static func autoSizeText() -> Node {
        var t = Node(kind: .text, name: "T", frame: CGRect(x: 40, y: 40, width: 0, height: 0))
        t.text = "Good morning"
        t.style?.size = 24
        t.style?.lineSpacing = 36
        t.refit()
        return t
    }

    @Test func aSideOfTheTextWrapsItsWords() {
        let bench = Bench(extra: [Self.autoSizeText()])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // The right side's handle, in to three fifths: the words go onto more lines, as big as they were.
        let width = (start.width * 0.6).rounded()
        bench.drag(CGPoint(x: start.maxX, y: start.midY), CGPoint(x: start.minX + width, y: start.midY), flags: .command)
        let t = try! #require(bench.node("T"))
        #expect(t.style?.sizing == .autoHeight)
        #expect(t.style?.size == 24)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f.origin == start.origin)
        #expect(f.width == width)
        #expect(f.height > start.height * 1.5)
        bench.undoLast()
        #expect(bench.node("T")?.style?.sizing == .autoWidth)
    }

    @Test func theTopOrACornerOfTheTextGrowsItsLettersAndLines() {
        let bench = Bench(extra: [Self.autoSizeText()])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // The top's handle, pulled up by half its height: its bottom stays, and the side it is aligned to.
        let d = (start.height / 2).rounded(), k = (start.height + d) / start.height
        bench.drag(CGPoint(x: start.midX, y: start.minY), CGPoint(x: start.midX, y: start.minY - d), flags: .command)
        let grown = try! #require(bench.node("T")?.style)
        #expect(grown.sizing == .autoWidth)
        #expect(grown.size == (24 * k * 10).rounded() / 10)
        #expect(grown.lineSpacing == (36 * k * 10).rounded() / 10)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f.maxY == start.maxY)
        #expect(f.minX == start.minX)
        // The bottom right corner, in to three quarters: smaller again, the top left where it was.
        bench.drag(CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX + (f.width * 0.75).rounded(), y: f.minY + (f.height * 0.75).rounded()), flags: .command)
        let shrunk = try! #require(bench.node("T")?.style)
        #expect(shrunk.size < grown.size)
        #expect(abs(shrunk.lineSpacing! / shrunk.size - 1.5) < 0.01)
        let g = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(g.origin == f.origin)
        bench.undoLast()
        bench.undoLast()
        #expect(bench.node("T")?.style?.size == 24)
        #expect(bench.node("T")?.style?.lineSpacing == 36)
    }

    @Test func aFixedWidthGrowsWithItsLettersSoTheWordsWrapWhereTheyDid() {
        var t = Self.autoSizeText()
        t.style?.sizing = .autoHeight
        t.frame.size.width = 100
        t.refit()
        let bench = Bench(extra: [t])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // The bottom right corner, out to twice the size with Shift.
        bench.drag(CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX + start.width * 2, y: start.minY + start.height * 2), flags: [.command, .shift])
        let n = try! #require(bench.node("T"))
        #expect(n.style?.sizing == .autoHeight)
        #expect(n.style?.size == 48)
        #expect(n.style?.lineSpacing == 72)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f.origin == start.origin)
        #expect(f.width == 200)
        #expect(abs(f.height - start.height * 2) <= 1)
    }

    @Test func aCornerOfTheTextGoesWhereItIsDraggedWithItsLettersAsBigAsFit() {
        let bench = Bench(extra: [Self.autoSizeText()])
        let id = bench.node("T")!.id
        let start = try! #require(bench.store.doc.absoluteFrame(of: id))
        bench.click(CGPoint(x: start.midX, y: start.midY))
        // Twice as wide and half as tall again: the height decides how big, on the one line.
        let box = CGSize(width: start.width * 2, height: (start.height * 1.5).rounded())
        bench.drag(CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX + box.width, y: start.minY + box.height), flags: .command)
        let t = try! #require(bench.node("T"))
        let style = try! #require(t.style)
        #expect(style.sizing == .fixed)
        #expect(abs(style.size - 36) < 0.5)
        let f = try! #require(bench.store.doc.absoluteFrame(of: id))
        #expect(f == CGRect(origin: start.origin, size: box))
        // A tenth of a point more would not fit.
        var base = try! #require(Self.autoSizeText().style)
        base.sizing = .fixed
        var bigger = t
        bigger.style = base.scaled(by: (style.size * 10 + 1) / 240)
        #expect(TextLayout.height(bigger, width: f.width) > box.height + 0.5)
    }

    @Test func aCornerOfTheTextKeepsTheCornerAcrossFromIt() {
        for (dx, dy) in [(1.0, 1.0), (0.0, 0.0), (1.0, 0.0), (0.0, 1.0)] as [(CGFloat, CGFloat)] {
            // Held partway, and let go.
            for release in [false, true] {
                let bench = Bench(extra: [Self.autoSizeText()])
                let id = bench.node("T")!.id
                let start = try! #require(bench.store.doc.absoluteFrame(of: id))
                bench.click(CGPoint(x: start.midX, y: start.midY))
                let corner = CGPoint(x: start.minX + start.width * dx, y: start.minY + start.height * dy)
                let across = CGPoint(x: start.minX + start.width * (1 - dx), y: start.minY + start.height * (1 - dy))
                // Out by a third of its width and half its height.
                let to = CGPoint(x: corner.x + (dx == 1 ? 1 : -1) * (start.width / 3).rounded(), y: corner.y + (dy == 1 ? 1 : -1) * (start.height / 2).rounded())
                bench.drag(corner, to, flags: .command, release: release)
                // The box runs from the corner across to the pointer.
                let f = try! #require(bench.store.doc.absoluteFrame(of: id))
                #expect(f == Geometry.rect(from: across, to: to), "corner \(dx),\(dy), let go \(release): \(f) from \(start)")
            }
        }
    }

    @Test func aBoxOfFixedSizeKeepsItsHeightAsItsWordsWrap() {
        var t = Self.autoSizeText()
        t.style?.sizing = .fixed
        t.frame.size = CGSize(width: 200, height: 120)
        t.refit()
        #expect(t.frame.size == CGSize(width: 200, height: 120))
        t.resizeText(to: CGSize(width: 80, height: 120), byHeight: false)
        #expect(t.style?.sizing == .fixed)
        #expect(t.style?.size == 24)
        #expect(t.frame.size == CGSize(width: 80, height: 120))
        t.resizeText(to: CGSize(width: 80, height: 240), byHeight: true)
        #expect(t.style?.size == 48)
        #expect(t.frame.size == CGSize(width: 160, height: 240))
    }

    @Test func aWidthTypedInWrapsTheWordsAndAHeightGrowsTheLetters() {
        var t = Self.autoSizeText()
        let start = t.frame
        t.resizeText(to: CGSize(width: 80, height: start.height), byHeight: false)
        #expect(t.style?.sizing == .autoHeight)
        #expect(t.style?.size == 24)
        #expect(t.frame.width == 80)
        #expect(t.frame.height > start.height)
        t.resizeText(to: CGSize(width: 80, height: t.frame.height * 2), byHeight: true)
        #expect(t.style?.size == 48)
        #expect(t.style?.lineSpacing == 72)
        #expect(t.frame.width == 160)
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
