import Testing
import AppKit
@testable import Bezzle

/// How the canvas is looked at while Animate is tried: as it opens, close up and panned, and from
/// far off. Everything the tool does maps between the view, the artboard and the film's frame, so
/// each hand is tried in all three.
nonisolated enum FilmView: CaseIterable, Sendable {
    case plain, close, far

    var viewport: Viewport {
        switch self {
        case .plain: Viewport(origin: .zero, zoom: 1)
        case .close: Viewport(origin: CGPoint(x: 60, y: 40), zoom: 2)
        case .far: Viewport(origin: CGPoint(x: -100, y: -50), zoom: 0.5)
        }
    }
}

/// Two fingers on the trackpad, pinching or turning, as the canvas is told of them.
nonisolated final class TwoFingers: NSEvent, @unchecked Sendable {
    private let place: CGPoint
    private let pinch: CGFloat
    private let turn: Float
    private let moment: NSEvent.Phase

    init(at place: CGPoint, pinch: CGFloat = 0, turn: Float = 0, _ moment: NSEvent.Phase) {
        self.place = place
        self.pinch = pinch
        self.turn = turn
        self.moment = moment
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var locationInWindow: NSPoint { place }
    override var magnification: CGFloat { pinch }
    override var rotation: Float { turn }
    override var phase: NSEvent.Phase { moment }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

/// Animate's bench: a design on the real canvas, animated, and a hand that presses, pulls and lets
/// go an event at a time. Each event is a step of its own, as each is in the app, so a gesture that
/// left more than one step to undo would show. Points are the canvas view's, as the tool has them.
@MainActor
final class FilmBench {
    let bench: Bench
    var store: DocumentStore { bench.store }
    var canvas: CanvasView { bench.canvas }
    var tool: MotionTool { bench.canvas.motionTool }
    var undo: UndoManager { bench.undo }

    /// On artboard A (at 100,100, 400 by 300): a card top left and a badge lower right.
    static var cardAndBadge: [Node] {
        [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
         CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40))]
    }

    /// A group on the artboard's right: a dot top left in it and a bar lower right.
    static var row: Node {
        var row = Node(kind: .group, name: "Row", frame: CGRect(x: 200, y: 20, width: 160, height: 100))
        row.children = [CanvasTests.rect("Dot", CGRect(x: 0, y: 0, width: 40, height: 40)),
                        CanvasTests.rect("Bar", CGRect(x: 60, y: 50, width: 100, height: 50))]
        return row
    }

    init(_ layers: [Node] = FilmBench.cardAndBadge, view: FilmView = .plain, animated: Bool = true) {
        bench = Bench(extra: layers)
        if animated { animate(view) }
    }

    func animate(_ view: FilmView = .plain) {
        store.show(.animate)
        // The view's glide to the film's artboard is no part of what is tested here.
        store.glide.stop()
        store.viewport = view.viewport
    }

    // MARK: The design and its film

    func id(_ name: String) -> UUID { bench.node(name)!.id }
    func node(_ name: String) -> Node { bench.node(name)! }
    var board: Node { store.filmBoard! }
    var scene: MotionTool.Scene { tool.scene! }
    var zoom: CGFloat { store.viewport.zoom }

    func keys(_ name: String, _ property: MotionProperty) -> [MotionKey] { node(name)[track: property]?.keys ?? [] }
    /// A layer's value at the playhead.
    func value(_ name: String, _ property: MotionProperty) -> [Double] { node(name).value(of: property, at: store.filmTime) }
    func cameraKeys(_ property: MotionProperty) -> [MotionKey] { board[track: property]?.keys ?? [] }
    /// The camera at the playhead.
    var camera: FilmCamera { board.camera(at: store.filmTime) }

    /// The design with everything Animate keeps in it taken out: what no pose may ever change.
    var design: [Node] {
        func bare(_ n: Node) -> Node {
            var n = n
            n.motion = nil
            n.film = nil
            n.children = n.children.map(bare)
            return n
        }
        return store.doc.nodes.map(bare)
    }

    /// One event, or one thing done from a menu: what a pass of the run loop is in the app. There a
    /// step that changes nothing leaves nothing to undo, since the history only opens a group when
    /// something is put in it. Here every step opens one, so one left empty is taken off again. An
    /// empty one still forgets what could be redone, which the app's would not: no test may count
    /// on redoing after a step in between.
    func step(_ body: () -> Void) {
        bench.step(body)
        guard undo.canUndo, undo.undoActionName.isEmpty else { return }
        let was = store.doc
        undo.undo()
        #expect(store.doc == was, "a step with no name changed the design")
    }

    /// A change to the design made behind the scenes, as its own step.
    func edit(_ change: (inout BezzleDocument) -> Void) {
        step { store.edit("Add Key", change) }
    }

    /// Forgets the steps so far, and stops a motion being shown: what comes next is all there is to undo.
    func fresh() {
        store.pauseFilm()
        undo.removeAllActions()
    }

    // MARK: Where things are, in the view

    /// A point of the film's frame, in the artboard's own points.
    func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint { scene.toView(CGPoint(x: x, y: y)) }
    /// A point of the canvas.
    func table(_ x: CGFloat, _ y: CGFloat) -> CGPoint { store.viewport.toView(CGPoint(x: x, y: y)) }
    /// Where a layer's corners show at the playhead: top left, top right, bottom right, bottom left.
    func corners(_ name: String) -> [CGPoint] { scene.corners(of: id(name)) ?? [] }
    func middle(_ name: String) -> CGPoint { Self.middle(corners(name)) }
    /// The middle of a layer's side, the top first, then round.
    func side(_ name: String, _ i: Int) -> CGPoint { Self.side(corners(name), i) }
    /// The small camera over the film's top right corner.
    var chip: CGPoint { CGPoint(x: scene.rect.maxX - 11, y: scene.rect.minY - 12) }
    /// The middle of the film's frame: where the camera looks.
    var eye: CGPoint { scene.rect.center }
    /// The artboard's own corners as the camera shows them.
    var sheet: [CGPoint] { scene.sheet }
    /// The point of the artboard's sheet, or of one lying level above it, that shows at a view point.
    func under(_ v: CGPoint, height: Double = 0) -> CGPoint? { scene.ground(height: height).back(scene.toFrame(v)) }

    static func middle(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.map(\.x).reduce(0, +) / CGFloat(max(q.count, 1)), y: q.map(\.y).reduce(0, +) / CGFloat(max(q.count, 1)))
    }

    static func side(_ q: [CGPoint], _ i: Int) -> CGPoint {
        CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2)
    }

    /// A point `by` further out from `c` than `p` is.
    static func out(_ p: CGPoint, from c: CGPoint, by: CGFloat) -> CGPoint {
        let d = hypot(p.x - c.x, p.y - c.y)
        return CGPoint(x: p.x + (p.x - c.x) / d * by, y: p.y + (p.y - c.y) / d * by)
    }

    /// A point `times` as far from `c` as `p` is, the same way.
    static func scaled(_ p: CGPoint, from c: CGPoint, _ times: CGFloat) -> CGPoint {
        CGPoint(x: c.x + (p.x - c.x) * times, y: c.y + (p.y - c.y) * times)
    }

    // MARK: The hand

    private func mouse(_ type: NSEvent.EventType, _ v: CGPoint, _ flags: NSEvent.ModifierFlags, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(v, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func press(_ v: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        step { canvas.mouseDown(with: mouse(.leftMouseDown, v, flags, clicks: clicks)) }
    }

    func pull(to v: CGPoint, flags: NSEvent.ModifierFlags = []) {
        step { canvas.mouseDragged(with: mouse(.leftMouseDragged, v, flags)) }
    }

    func letGo(at v: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        step { canvas.mouseUp(with: mouse(.leftMouseUp, v, flags, clicks: clicks)) }
    }

    /// Presses at `a`, pulls to `b` in four moves and lets go. `pulling` are the keys held while it
    /// is pulled, where they are not the ones held as it is pressed.
    func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = [], pulling: NSEvent.ModifierFlags? = nil) {
        press(a, flags: flags)
        for i in 1...4 {
            let t = CGFloat(i) / 4
            pull(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: pulling ?? flags)
        }
        letGo(at: b, flags: pulling ?? flags)
    }

    /// A click, or with `clicks` two, a click and then the second of a double click.
    func click(_ v: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        for n in 1...clicks {
            press(v, flags: flags, clicks: n)
            letGo(at: v, flags: flags, clicks: n)
        }
    }

    func hover(_ v: CGPoint) {
        canvas.mouseMoved(with: mouse(.mouseMoved, v, [], clicks: 0))
    }

    /// A right click, and what the canvas then offers; nil when it offers nothing.
    func rightClick(_ v: CGPoint) -> [MenuEntry]? {
        var offered: [MenuEntry]?
        canvas.onContextMenu = { _, entries in offered = entries }
        step { canvas.rightMouseDown(with: mouse(.rightMouseDown, v, [])) }
        canvas.onContextMenu = nil
        return offered
    }

    /// Chooses an entry of a menu by its title, as one step. False when it is not there, or cannot be chosen.
    @discardableResult
    func choose(_ title: String, in entries: [MenuEntry]?) -> Bool {
        guard let entry = entries?.first(where: { $0.kind == .item && $0.title == title }), entry.enabled else { return false }
        step { entry.action() }
        return true
    }

    private func keyEvent(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = [], at time: TimeInterval = 0) {
        step { canvas.keyDown(with: keyEvent(.keyDown, code, chars, flags, at: time)) }
    }

    func keyUp(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = [], at time: TimeInterval = 0) {
        step { canvas.keyUp(with: keyEvent(.keyUp, code, chars, flags, at: time)) }
    }

    /// An arrow key, with the flags a keyboard gives it: 123 left, 124 right, 125 down, 126 up.
    func arrow(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
        key(code, flags: flags.union([.numericPad, .function]))
    }

    /// The space bar pressed at one moment and let go at another, with something done while it is held.
    func space(from down: TimeInterval, to up: TimeInterval, _ held: () -> Void = {}) {
        key(49, " ", at: down)
        held()
        keyUp(49, " ", at: up)
    }

    /// A pinch at a view point: each amount an event, the first as it begins and the last as it ends.
    func pinch(at v: CGPoint, _ amounts: [CGFloat]) {
        for (i, amount) in amounts.enumerated() {
            let stage: NSEvent.Phase = i == 0 ? .began : i == amounts.count - 1 ? .ended : .changed
            step { canvas.magnify(with: TwoFingers(at: canvas.convert(v, to: nil), pinch: amount, stage)) }
        }
    }

    /// Two fingers turned at a view point, counterclockwise as the trackpad counts.
    func twist(at v: CGPoint, _ degrees: [Float]) {
        for (i, turn) in degrees.enumerated() {
            let stage: NSEvent.Phase = i == 0 ? .began : i == degrees.count - 1 ? .ended : .changed
            step { canvas.rotate(with: TwoFingers(at: canvas.convert(v, to: nil), turn: turn, stage)) }
        }
    }

    /// Draws the tool's marks as they are now, into a picture nobody sees: only that it can.
    func draw() {
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 0.5, y: 0.5)
        tool.draw(ctx, scale: 1, in: canvas.bounds)
    }
}

/// Whether two points are the same, give or take a little.
@MainActor func closeBy(_ a: CGPoint?, _ b: CGPoint?, within e: CGFloat = 0.01) -> Bool {
    guard let a, let b else { return false }
    return abs(a.x - b.x) <= e && abs(a.y - b.y) <= e
}

/// Whether two values are the same, give or take a little.
@MainActor func closeBy(_ a: [Double], _ b: [Double], within e: Double = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= e }
}

/// Animate on the canvas, as a person uses it there. Here: picking layers and posing them by a
/// drag. Their grips and beads are in `AnimateCanvasGripTests.swift`, the camera in
/// `AnimateCanvasCameraTests.swift`, the keyboard in `AnimateCanvasKeyTests.swift`, other
/// artboards, the right click and the edges in `AnimateCanvasEdgeTests.swift`, several as one
/// body in `AnimateCanvasBodyTests.swift`, and dragging in groups turned in depth in
/// `AnimateCanvasDepthTests.swift`.
@MainActor
struct AnimateCanvasTests {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Picking

    @Test func aClickPicksALayerShiftAddsAndTakesAwayAndNothingIsLeftToUndo() {
        let f = FilmBench()
        let before = f.store.doc
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")])
        f.click(f.middle("Badge"), flags: .shift)
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        f.click(f.middle("Card"), flags: .shift)
        #expect(f.store.selection == [f.id("Badge")])
        // A plain click on another picks that one alone.
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")])
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo)
        #expect(!f.store.inGesture && !f.tool.dragging)
    }

    @Test(arguments: FilmView.allCases) func aClickOnTheBareArtboardOrTheTableLetsGo(_ view: FilmView) {
        let f = FilmBench(view: view)
        f.click(f.middle("Card"))
        #expect(f.store.selection == [f.id("Card")])
        // The artboard's own sheet, where nothing lies.
        f.click(f.view(350, 40))
        #expect(f.store.selection.isEmpty)
        f.click(f.middle("Badge"))
        #expect(f.store.selection == [f.id("Badge")])
        // The table, off every artboard.
        f.click(f.table(300, 600))
        #expect(f.store.selection.isEmpty)
        #expect(f.store.film.board == f.bench.a.id)
        #expect(!f.undo.canUndo)
    }

    @Test func aSecondClickGoesALayerDeeperAndCommandPicksDeep() {
        var outer = Node(kind: .group, name: "Outer", frame: CGRect(x: 20, y: 150, width: 160, height: 100))
        var inner = Node(kind: .group, name: "Inner", frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        inner.children = [CanvasTests.rect("Leaf", CGRect(x: 0, y: 0, width: 40, height: 30)),
                          CanvasTests.rect("Twig", CGRect(x: 50, y: 30, width: 30, height: 30))]
        outer.children = [inner, CanvasTests.rect("Stone", CGRect(x: 100, y: 60, width: 60, height: 40))]
        let f = FilmBench([FilmBench.row, outer])
        let dot = f.middle("Dot")
        f.click(dot)
        #expect(f.store.selection == [f.id("Row")])
        f.click(dot, clicks: 2)
        #expect(f.store.selection == [f.id("Dot")])
        // Once inside the group, a click on its neighbour picks that, not the group again.
        f.click(f.middle("Bar"))
        #expect(f.store.selection == [f.id("Bar")])
        // Let go of, and Command reaches through at once.
        f.click(f.view(380, 280))
        #expect(f.store.selection.isEmpty)
        f.click(dot, flags: .command)
        #expect(f.store.selection == [f.id("Dot")])
        // A group in a group: a layer deeper each time.
        let leaf = f.middle("Leaf")
        f.click(leaf)
        #expect(f.store.selection == [f.id("Outer")])
        f.click(leaf, clicks: 2)
        #expect(f.store.selection == [f.id("Inner")])
        f.click(leaf, clicks: 2)
        #expect(f.store.selection == [f.id("Leaf")])
        // With Shift, its neighbour in the group is added.
        f.click(f.middle("Twig"), flags: .shift)
        #expect(f.store.selection == [f.id("Leaf"), f.id("Twig")])
        #expect(!f.undo.canUndo)
    }

    @Test(arguments: FilmView.allCases) func aLoopPulledOverLayersPicksThemAndShiftAddsToWhatIsPicked(_ view: FilmView) {
        var locked = CanvasTests.rect("Locked", CGRect(x: 40, y: 200, width: 60, height: 60))
        locked.locked = true
        var hidden = CanvasTests.rect("Hidden", CGRect(x: 300, y: 40, width: 60, height: 60))
        hidden.hidden = true
        let f = FilmBench(FilmBench.cardAndBadge + [locked, hidden], view: view)
        let before = f.store.doc
        // From the bare sheet above the card, down into it.
        f.drag(f.view(20, 20), f.view(100, 100))
        #expect(f.store.selection == [f.id("Card")])
        // With Shift, from the bare sheet beside the badge: added to what is picked.
        f.drag(f.view(220, 150), f.view(270, 200), flags: .shift)
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        // A loop round nothing lets go.
        f.drag(f.view(180, 130), f.view(220, 160))
        #expect(f.store.selection.isEmpty)
        // Begun on the table and pulled over the whole artboard: all that can be posed, never what is locked or hidden.
        f.drag(f.table(80, 80), f.table(520, 420))
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo)
        #expect(!f.store.film.playing)
    }

    // MARK: Posing by a drag

    @Test(arguments: FilmView.allCases) func aLayerDraggedLaterInTheFilmLeavesTheDesignAtTheStart(_ view: FilmView) {
        let f = FilmBench(view: view)
        let design = f.design
        f.store.seek(1)
        let from = f.middle("Card"), to = from + point(50, 30) * f.zoom
        f.drag(from, to)
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [50, 30])])
        #expect(f.design == design)
        #expect(f.store.selection == [f.id("Card")])
        // Its first key is shown once: from the start to there, and the playhead back where it was.
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == 1 && f.store.film.pass?.back == 1)
        f.store.pauseFilm()
        #expect(f.store.filmTime == 1)
        #expect(f.value("Card", .move) == [50, 30])
        // It shows where it was let go, its middle under the pointer.
        #expect(closeBy(f.middle("Card"), to))
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
    }

    @Test(arguments: FilmView.allCases) func aLayerDraggedAtTheStartFliesHome(_ view: FilmView) {
        let f = FilmBench(view: view)
        let design = f.design
        let from = f.middle("Card"), to = from + point(50, 30) * f.zoom
        f.drag(from, to)
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [50, 30]), MotionKey(t: 0.5, v: [0, 0], given: true)])
        #expect(f.design == design)
        // Shown from there home, over the beat it takes, and the playhead back at the start.
        #expect(f.store.film.playing)
        #expect(f.store.film.pass?.from == 0 && f.store.film.pass?.to == 0.5 && f.store.film.pass?.back == 0)
        f.store.pauseFilm()
        #expect(f.store.filmTime == 0)
        #expect(closeBy(f.middle("Card"), to))
        f.undo.undo()
        #expect(f.node("Card").motion == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func laterPosesAreEachOneMoreKeyAndAPoseAtAKeyChangesIt() {
        let f = FilmBench()
        f.store.seek(1)
        var at = f.middle("Card")
        f.drag(at, at + point(50, 30))
        f.fresh()
        // Half a second on, the layer rests where its last key left it. Dragged by its middle, where
        // that key's bead lies too, it is posed at the playhead: one more key.
        f.store.seek(1.5)
        at = f.middle("Card")
        #expect(closeBy(at, f.view(150, 110)))
        f.drag(at, at + point(20, 0))
        #expect(f.store.filmTime == 1.5)
        #expect(f.keys("Card", .move).map(\.t) == [0, 1, 1.5])
        #expect(f.value("Card", .move) == [70, 30])
        // Only a first key is shown.
        #expect(!f.store.film.playing)
        f.undo.undo()
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        #expect(!f.undo.canUndo)
        f.undo.redo()
        #expect(f.keys("Card", .move).map(\.t) == [0, 1, 1.5])
        // A third, at the film's end.
        f.store.seek(2)
        at = f.middle("Card")
        f.drag(at, at + point(0, 40))
        #expect(f.store.filmTime == 2)
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [50, 30], [70, 30], [70, 70]])
        // At a moment that has a key already, that key is changed and none is added.
        f.store.seek(1)
        at = f.middle("Card")
        f.drag(at, at + point(-10, 0))
        #expect(f.store.filmTime == 1)
        #expect(f.keys("Card", .move).map(\.t) == [0, 1, 1.5, 2])
        #expect(f.keys("Card", .move).map(\.v) == [[0, 0], [40, 30], [70, 30], [70, 70]])
        // The start it was given is still the design's own.
        #expect(f.keys("Card", .move)[0].given == true)
        #expect(!f.store.film.playing)
        #expect(f.node("Card").frame == CGRect(x: 40, y: 40, width: 120, height: 80))
    }

    @Test func aPoseBetweenTwoKeysIsAKeyOfItsOwn() {
        let f = FilmBench()
        f.store.seek(1)
        var at = f.middle("Card")
        f.drag(at, at + point(50, 30))
        f.fresh()
        f.store.seek(0.5)
        // On its way there, somewhere between.
        let was = f.value("Card", .move)
        #expect(was[0] > 0 && was[0] < 50 && was[1] > 0 && was[1] < 30)
        at = f.middle("Card")
        #expect(closeBy(at, f.view(100 + was[0], 80 + was[1])))
        f.drag(at, at + point(10, -10))
        let keys = f.keys("Card", .move)
        #expect(keys.map(\.t) == [0, 0.5, 1])
        // To the half point.
        #expect(abs(keys[1].v[0] - (was[0] + 10)) <= 0.25 && abs(keys[1].v[1] - (was[1] - 10)) <= 0.25)
        #expect(keys[1].v.allSatisfy { ($0 * 2).rounded() == $0 * 2 })
        #expect(keys[0] == MotionKey(t: 0, v: [0, 0], given: true) && keys[2] == MotionKey(t: 1, v: [50, 30]))
        #expect(!f.store.film.playing)
        f.undo.undo()
        #expect(f.keys("Card", .move).map(\.t) == [0, 1])
        #expect(!f.undo.canUndo)
    }

    @Test func aPosePastTheHomeALayerWasGivenTakesItsPlace() {
        let f = FilmBench()
        var at = f.middle("Card")
        f.drag(at, at + point(50, 30))
        f.fresh()
        #expect(f.keys("Card", .move).map(\.t) == [0, 0.5])
        // A second later it is home again. Posed there, the home it was given gives way.
        f.store.seek(1)
        at = f.middle("Card")
        #expect(closeBy(at, f.view(100, 80)))
        f.drag(at, at + point(0, 40))
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [50, 30]), MotionKey(t: 1, v: [0, 40])])
        #expect(!f.store.film.playing)
        f.undo.undo()
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [50, 30]), MotionKey(t: 0.5, v: [0, 0], given: true)])
        #expect(!f.undo.canUndo)
    }

    @Test func aLayerDraggedOutAndHomeAgainInOneGoIsLeftAsDesigned() {
        let f = FilmBench()
        let before = f.store.doc
        f.store.seek(1)
        let home = f.middle("Card")
        f.press(home)
        f.pull(to: home + point(40, 20))
        #expect(f.value("Card", .move) == [40, 20])
        // Back to where home catches it, and let go there.
        f.pull(to: home + point(2, -3))
        f.letGo(at: home + point(2, -3))
        // Posed as designed, a layer with no keys has none to show for it: no motion, nothing
        // played, nothing to undo.
        #expect(f.node("Card").motion == nil)
        #expect(f.store.doc == before)
        #expect(!f.store.film.playing)
        #expect(!f.undo.canUndo)
        #expect(!f.store.inGesture)
    }

    @Test func severalLayersDraggedTogetherArePosedAsOneStep() {
        let f = FilmBench()
        f.click(f.middle("Card"))
        f.click(f.middle("Badge"), flags: .shift)
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let at = f.middle("Badge")
        f.drag(at, at + point(-30, 20))
        #expect(f.keys("Card", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [-30, 20])])
        #expect(f.keys("Badge", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [-30, 20])])
        #expect(f.store.selection == [f.id("Card"), f.id("Badge")])
        #expect(f.design == design)
        #expect(f.store.film.playing)
        f.store.pauseFilm()
        f.undo.undo()
        #expect(f.node("Card").motion == nil && f.node("Badge").motion == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func withOptionADragIsStillAPoseAndNeverACopy() {
        let f = FilmBench()
        let design = f.design
        f.store.seek(1)
        let at = f.middle("Card")
        f.drag(at, at + point(30, 0), flags: .option)
        #expect(f.design == design)
        #expect(f.value("Card", .move) == [30, 0])
        #expect(f.store.doc.allNodes.filter { $0.name == "Card" }.count == 1)
    }

    // MARK: In groups, turned, locked, hidden

    @Test(arguments: FilmView.allCases) func aLayerInAGroupIsPosedAndTheGroupStaysAsDesigned(_ view: FilmView) {
        let f = FilmBench([FilmBench.row], view: view)
        f.click(f.middle("Dot"), flags: .command)
        #expect(f.store.selection == [f.id("Dot")])
        f.store.seek(1)
        f.fresh()
        let design = f.design
        let from = f.middle("Dot"), to = from + point(30, 50) * f.zoom
        #expect(closeBy(from, f.view(220, 40)))
        f.drag(from, to)
        #expect(f.keys("Dot", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [30, 50])])
        // The group has no motion of its own, and neither it nor the dot has moved in the design.
        #expect(f.node("Row").motion == nil)
        #expect(f.design == design)
        f.store.pauseFilm()
        #expect(closeBy(f.middle("Dot"), to))
        // Where it shows now is where it is picked.
        f.click(f.view(380, 280))
        f.click(to, flags: .command)
        #expect(f.store.selection == [f.id("Dot")])
        f.undo.undo()
        #expect(f.node("Dot").motion == nil)
        #expect(!f.undo.canUndo)
    }

    @Test func aLayerInAGroupThatMovesIsPosedOnTopOfTheGroupsOwnMotion() {
        let f = FilmBench([FilmBench.row])
        f.store.seek(1)
        var at = f.middle("Dot")
        // A first press on the dot is the group's: the whole row goes.
        f.drag(at, at + point(40, 0))
        #expect(f.store.selection == [f.id("Row")])
        #expect(f.value("Row", .move) == [40, 0])
        f.fresh()
        let design = f.design
        // The dot shows where the row has taken it.
        at = at + point(40, 0)
        #expect(closeBy(f.middle("Dot"), at))
        f.click(at, flags: .command)
        #expect(f.store.selection == [f.id("Dot")])
        f.drag(at, at + point(0, 30))
        #expect(f.keys("Dot", .move) == [MotionKey(t: 0, v: [0, 0], given: true), MotionKey(t: 1, v: [0, 30])])
        #expect(f.value("Row", .move) == [40, 0])
        #expect(f.design == design)
        f.store.pauseFilm()
        f.undo.undo()
        #expect(f.node("Dot").motion == nil)
        #expect(f.value("Row", .move) == [40, 0])
        #expect(!f.undo.canUndo)
    }

    @Test func aLayerPosedInAGroupThatMovesShowsAndIsPickedWhereItIs() {
        let f = FilmBench([FilmBench.row])
        f.store.seek(1)
        var at = f.middle("Dot")
        f.drag(at, at + point(40, 0))
        f.store.pauseFilm()
        at = at + point(40, 0)
        f.click(at, flags: .command)
        f.drag(at, at + point(0, 30))
        f.store.pauseFilm()
        // Its outline and handles are where it is drawn: the row's place and its own on top.
        #expect(closeBy(f.middle("Dot"), at + point(0, 30)))
        // And a press there, below where the design has it, finds it.
        f.click(f.view(380, 280))
        f.click(at + point(0, 45), flags: .command)
        #expect(f.store.selection == [f.id("Dot")])
    }

    @Test func aLayerTheDesignHasTurnedKeepsItsTurnAndGrowsAlongItsOwnSides() {
        var tilted = CanvasTests.rect("Tilted", CGRect(x: 60, y: 170, width: 100, height: 60))
        tilted.rotation = 30
        let f = FilmBench([tilted])
        let design = f.design
        f.store.seek(1)
        var at = f.middle("Tilted")
        #expect(closeBy(at, f.view(110, 200)))
        f.drag(at, at + point(40, -20))
        // Moved by what the pointer covered, across and down the artboard, however it is turned.
        #expect(f.value("Tilted", .move) == [40, -20])
        f.store.pauseFilm()
        // Its right side, pulled half as far out again along the way it is turned.
        at = f.middle("Tilted")
        let side = f.side("Tilted", 1)
        f.drag(side, FilmBench.scaled(side, from: at, 1.5))
        #expect(f.value("Tilted", .scale) == [1.5, 1])
        f.store.pauseFilm()
        let q = f.corners("Tilted")
        #expect(abs(hypot(q[1].x - q[0].x, q[1].y - q[0].y) - 150) < 0.01)
        #expect(abs(hypot(q[2].x - q[1].x, q[2].y - q[1].y) - 60) < 0.01)
        #expect(abs(atan2(q[1].y - q[0].y, q[1].x - q[0].x) * 180 / .pi - 30) < 0.01)
        #expect(closeBy(FilmBench.middle(q), at))
        // Turned from outside a corner, on top of the turn it has.
        let grip = FilmBench.out(q[2], from: at, by: 12)
        f.drag(grip, Geometry.rotated(grip, about: at, by: 20))
        #expect(f.value("Tilted", .turn) == [20])
        f.store.pauseFilm()
        let turned = f.corners("Tilted")
        #expect(abs(atan2(turned[1].y - turned[0].y, turned[1].x - turned[0].x) * 180 / .pi - 50) < 0.01)
        // The design has it as it was: where, how big and how far turned.
        #expect(f.design == design)
        #expect(f.node("Tilted").rotation == 30 && f.node("Tilted").frame == CGRect(x: 60, y: 170, width: 100, height: 60))
    }

    @Test func aLockedLayerIsNeverPosed() {
        var locked = CanvasTests.rect("Locked", CGRect(x: 240, y: 60, width: 80, height: 60))
        locked.locked = true
        let f = FilmBench([FilmBench.cardAndBadge[0], locked])
        let before = f.store.doc
        f.store.seek(1)
        let at = f.middle("Locked")
        f.drag(at, at + point(40, 40))
        #expect(f.node("Locked").motion == nil)
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo && !f.store.film.playing && !f.store.inGesture)
        // Nor by the arrows, nor held, nor with others it is picked among.
        f.store.selection = [f.id("Locked")]
        f.arrow(124)
        f.arrow(125, flags: .shift)
        f.key(40, "k")
        #expect(f.store.doc == before)
        f.store.seek(1)
        f.store.selection = [f.id("Card"), f.id("Locked")]
        let card = f.middle("Card")
        f.drag(card, card + point(20, 20))
        #expect(f.value("Card", .move) == [20, 20])
        #expect(f.node("Locked").motion == nil)
        #expect(f.node("Locked").frame == CGRect(x: 240, y: 60, width: 80, height: 60))
    }

    @Test func aHiddenLayerIsNeitherPickedNorInTheWay() {
        var hidden = CanvasTests.rect("Hidden", CGRect(x: 40, y: 40, width: 120, height: 80))
        hidden.hidden = true
        var alone = CanvasTests.rect("Alone", CGRect(x: 240, y: 60, width: 80, height: 60))
        alone.hidden = true
        let f = FilmBench([FilmBench.cardAndBadge[0], hidden, alone])
        let before = f.store.doc
        // It lies over the card, which is what a click there finds.
        f.click(f.view(100, 80))
        #expect(f.store.selection == [f.id("Card")])
        // Where only a hidden layer lies, there is nothing.
        f.click(f.view(280, 90))
        #expect(f.store.selection.isEmpty)
        f.drag(f.view(230, 50), f.view(330, 130))
        #expect(f.store.selection.isEmpty)
        // Picked in the layers list all the same, it has no handles to take hold of, and nothing trips.
        f.store.selection = [f.id("Alone")]
        f.hover(f.view(280, 90))
        f.draw()
        f.drag(f.view(320, 120), f.view(350, 150))
        #expect(f.store.doc == before)
        #expect(!f.undo.canUndo)
    }
}
