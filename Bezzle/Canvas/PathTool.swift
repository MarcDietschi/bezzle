import AppKit

/// The pen, and the points of a path: drawing a path a point at a time, and moving, adding and
/// taking away the points of one already drawn. The canvas hands it the pointer and the keys
/// while the pen is in hand or a path's points are being edited, and it draws the points, their
/// handles and the curve still to come over the design.
///
/// With the pen, a click puts down a corner and a drag pulls a curve out of the point. Back on
/// the first point the path closes; on the last, a click takes its handle away so the next part
/// leaves straight. Return or Escape ends an open path. Over a selected path the pen carries on
/// from an open end, adds a point on the outline and takes one away elsewhere.
///
/// Editing points (double-click a path, or Return): points are picked by clicking and by
/// dragging round them, and dragged; handles turn both sides of a smooth point together unless
/// Option is held; a double click on a point makes it a corner or smooth; a click on the outline
/// adds a point there; Delete takes the picked points away.
final class PathTool {
    private let store: DocumentStore
    /// Draws the canvas again, for what changes here and not in the store: the curve following the pointer.
    var redraw: () -> Void = {}

    /// A path being drawn with the pen.
    private struct Session {
        /// The layer, once it has two points. Before then the first point is only here.
        var id: UUID?
        var first: BezierPath.Anchor?
        /// The artboard the first point went down on, which the path goes on.
        var board: UUID?
        /// The run of the layer being drawn.
        var run = 0
        /// Carrying on from a run's first point: it is turned round with the next point, so the
        /// pen always adds at the end.
        var fromStart = false
        /// Handles path data cannot keep while the run is open: the one out of its last point,
        /// along which the next part leaves, and the one into its first, for closing. Each with
        /// the point it belongs to, so it is let go if an undo takes that point away.
        var tailOut: (at: CGPoint, handle: CGPoint)?
        var headIn: (at: CGPoint, handle: CGPoint)?
    }

    private var session: Session?

    /// One of a point's two handles.
    private struct HandleRef: Hashable {
        var point: PathPoint
        var out: Bool
    }

    private enum Drag {
        /// Pulling the handles out of the point just put down, or, when closing, out of the
        /// first. `base` is the path with that point in it, nil while it is the session's first.
        case pull(id: UUID?, base: BezierPath?, at: PathPoint, closing: Bool, lastIn: CGPoint?, moved: Bool, action: LocalizedStringResource?)
        /// The last point pressed again: a click takes its handle away, a drag pulls a new one out of it alone.
        case cusp(id: UUID, base: BezierPath, at: PathPoint, moved: Bool)
        case points(id: UUID, base: BezierPath, moving: Set<PathPoint>, grabbed: PathPoint, start: CGPoint, targets: SnapTargets,
                    moved: Bool, action: LocalizedStringResource)
        case handle(id: UUID, base: BezierPath, at: HandleRef, moved: Bool)
        /// Dragging round points; when it `leaves`, a click that does not drag ends editing them.
        case marquee(start: CGPoint, base: Set<PathPoint>, leaves: Bool)
    }

    private var drag: Drag?
    private var downView: CGPoint = .zero
    private var flags: NSEvent.ModifierFlags = []
    private var deviceScale: CGFloat = 2

    /// What a click where the pointer is would do, for the pointer's look.
    private enum Mark: Equatable { case none, point, add, remove, close, convert, carryOn }
    private var mark = Mark.none
    /// Where the next point would go, for the curve that follows the pointer.
    private var preview: CGPoint?
    /// A place on the outline where a click adds a point, shown as a ghost of one.
    private(set) var spot: CGPoint?
    private var marquee: CGRect?
    /// A point a click just added: a second click on it is still the first, not a double click on the point.
    private var justAdded: PathPoint?

    init(store: DocumentStore) {
        self.store = store
    }

    var dragging: Bool { drag != nil }

    /// The path whose points show on the canvas in place of its frame: the one being drawn or
    /// edited, or, with the pen in hand, the one selected.
    var shownPath: UUID? {
        if store.tool == .pen, let id = session?.id { return id }
        if let id = store.editingPath { return id }
        if store.tool == .pen, store.selection.count == 1, let n = store.node(store.selection[0]), n.kind == .path, !n.locked { return n.id }
        return nil
    }

    // MARK: - Where things are

    private var zoom: CGFloat { store.viewport.zoom }
    private func view(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }

    private static let reach: CGFloat = 6

    private func near(_ v: CGPoint, _ p: CGPoint) -> Bool {
        let q = view(p)
        return hypot(q.x - v.x, q.y - v.y) <= Self.reach
    }

    private func anchor(at v: CGPoint, in points: BezierPath) -> PathPoint? {
        var best: (PathPoint, CGFloat)?
        for q in points.allPoints {
            let p = view(points[q].point), d = hypot(p.x - v.x, p.y - v.y)
            if d <= Self.reach, best == nil || d < best!.1 { best = (q, d) }
        }
        return best?.0
    }

    private func handle(at v: CGPoint, in points: BezierPath) -> HandleRef? {
        handles(in: points).first { h in points[h.point].handle(out: h.out).map { near(v, $0) } ?? false }
    }

    private func segment(at v: CGPoint, in points: BezierPath) -> BezierPath.Spot? {
        let reach = 5 / zoom
        guard let s = points.nearest(to: canvas(v), within: reach), s.distance <= reach else { return nil }
        return s
    }

    /// The handles that show, and so can be dragged: those of the picked points and of their
    /// neighbours' curves towards them while editing; the newest point's while drawing.
    private func handles(in points: BezierPath) -> [HandleRef] {
        var refs: [HandleRef] = []
        func add(_ q: PathPoint, _ out: Bool) {
            let r = HandleRef(point: q, out: out)
            if points.contains(q), points[q].handle(out: out) != nil, !refs.contains(r) { refs.append(r) }
        }
        if store.tool == .pen, session?.id != nil, let (_, drawn, run) = drawnPath() {
            var at = PathPoint(subpath: run, index: drawn.subpaths[run].anchors.count - 1)
            if case .pull(_, _, let p, true, _, _, _) = drag { at = p }
            add(at, false); add(at, true)
            return refs
        }
        guard store.editingPath != nil else { return [] }
        for q in store.livePoints.sorted() {
            let run = points.subpaths[q.subpath]
            add(q, false); add(q, true)
            if let b = run.before(q.index) { add(PathPoint(subpath: q.subpath, index: b), true) }
            if let a = run.after(q.index) { add(PathPoint(subpath: q.subpath, index: a), false) }
        }
        return refs
    }

    // MARK: - Drawing with the pen

    /// Ends a path the rest of the app has moved on from: another tool, another selection, or an
    /// undo that took its path away.
    private func check() {
        guard let s = session else { return }
        var over = store.tool != .pen
        if let id = s.id {
            if !store.selection.contains(id) { over = true }
            else if let points = store.points(of: id) {
                if !points.subpaths.indices.contains(s.run) || points.subpaths[s.run].closed { over = true }
            } else {
                over = true
            }
        } else if !store.selection.isEmpty {
            over = true
        }
        if over { session = nil }
    }

    /// The path being drawn, turned round if need be so the pen adds at the end of its run.
    private func drawnPath() -> (id: UUID, points: BezierPath, run: Int)? {
        guard let s = session, let id = s.id, var points = store.points(of: id), points.subpaths.indices.contains(s.run) else { return nil }
        if s.fromStart { points.reverse(s.run) }
        let last = points.subpaths[s.run].anchors.count - 1
        if let t = s.tailOut, BezierPath.same(points.subpaths[s.run].anchors[last].point, t.at) {
            points.subpaths[s.run].anchors[last].handleOut = t.handle
        }
        if let h = s.headIn, BezierPath.same(points.subpaths[s.run].anchors[0].point, h.at) {
            points.subpaths[s.run].anchors[0].handleIn = h.handle
        }
        return (id, points, s.run)
    }

    /// What the next point snaps to: what lies around, as for anything drawn, and the path's own points.
    private func targets(at p: CGPoint, own: BezierPath?, except: Set<PathPoint> = []) -> SnapTargets {
        var targets = SnapTargets(doc: store.seenDoc, moving: session?.id.map { [$0] } ?? store.editingPath.map { [$0] } ?? [])
        func add(_ q: CGPoint) {
            let box = CGRect(origin: q, size: .zero)
            targets.xs.append(SnapTargets.Line(value: q.x, box: box))
            targets.ys.append(SnapTargets.Line(value: q.y, box: box))
        }
        // Before the path is a layer, what lies on the artboard counts too.
        if session?.id == nil, store.editingPath == nil, let board = store.doc.artboard(at: p) {
            targets.catchOnHelpers(of: board)
            for child in board.children where !child.hidden {
                let b = Geometry.bounds(of: child).offsetBy(dx: board.frame.minX, dy: board.frame.minY)
                for x in [b.minX, b.midX, b.maxX] { targets.xs.append(SnapTargets.Line(value: x, box: b)) }
                for y in [b.minY, b.midY, b.maxY] { targets.ys.append(SnapTargets.Line(value: y, box: b)) }
            }
        }
        if let own { for q in own.allPoints where !except.contains(q) { add(own[q].point) } }
        if let first = session?.first { add(first.point) }
        return targets
    }

    /// How many steps a point is cut into where a point lands that nothing caught: whole points,
    /// and zoomed in, halves, quarters, tenths and finer, so a step is never more than two points
    /// on the screen and a point never seems to jump. With Command, hundredths: anywhere at all.
    private func steps(free: Bool) -> CGFloat {
        free ? 100 : Self.steps.first { zoom / $0 <= 2 } ?? 100
    }
    private static let steps: [CGFloat] = [1, 2, 4, 10, 20, 100]

    private func landed(_ v: CGFloat, free: Bool) -> CGFloat {
        let per = steps(free: free)
        return (v * per).rounded() / per
    }

    /// Where a point goes for the pointer at `p`: in 45° steps from the last with Shift, or else
    /// caught by what lies around; with Command, nothing catches it.
    private func place(_ p: CGPoint, from last: CGPoint?, own: BezierPath?, showGuides: Bool) -> CGPoint {
        let free = flags.contains(.command)
        var guides: [Guide] = []
        defer { if showGuides, store.guides != guides { store.guides = guides } }
        if flags.contains(.shift), let last {
            // As far along the line as the steps go, so it stays at its angle.
            let q = Geometry.lineEnd(from: last, to: p, constrain: true)
            return CGPoint(x: last.x + landed(q.x - last.x, free: free), y: last.y + landed(q.y - last.y, free: free))
        }
        guard !free else { return CGPoint(x: landed(p.x, free: true), y: landed(p.y, free: true)) }
        let t = targets(at: p, own: own)
        let (q, x, y) = t.snap(point: p, threshold: 5 / zoom)
        guides = t.guides(for: CGRect(origin: q, size: .zero), x: x, y: y)
        // Right on what caught it; elsewhere on the steps.
        return CGPoint(x: x != nil ? q.x : landed(q.x, free: false), y: y != nil ? q.y : landed(q.y, free: false))
    }

    func penDown(at v: CGPoint, event: NSEvent) {
        check()
        downView = v
        flags = event.modifierFlags
        justAdded = nil
        spot = nil
        let p = canvas(v)

        if session != nil {
            if let (id, points, run) = drawnPath() {
                let anchors = points.subpaths[run].anchors
                let head = PathPoint(subpath: run, index: 0), last = PathPoint(subpath: run, index: anchors.count - 1)
                if anchors.count > 1, near(v, anchors[0].point) {
                    // Back on the first point: the path closes, and a drag shapes the curve coming in.
                    var next = points
                    next.subpaths[run].closed = true
                    store.beginGesture()
                    store.setPoints(next, of: id, "Close Path")
                    session?.fromStart = false
                    drag = .pull(id: id, base: next, at: head, closing: true, lastIn: next[head].handleIn, moved: false, action: "Close Path")
                    return
                }
                if near(v, anchors[anchors.count - 1].point) {
                    drag = .cusp(id: id, base: points, at: last, moved: false)
                    return
                }
                let q = place(p, from: anchors[anchors.count - 1].point, own: points, showGuides: false)
                var next = points
                next.subpaths[run].anchors.append(BezierPath.Anchor(q))
                store.beginGesture()
                store.setPoints(next, of: id, "Add Point")
                session?.fromStart = false
                session?.tailOut = nil
                drag = .pull(id: id, base: next, at: PathPoint(subpath: run, index: anchors.count), closing: false, lastIn: nil,
                             moved: false, action: "Add Point")
                return
            }
            if let s = session, let first = s.first {
                guard !near(v, first.point) else { return }
                // The second point makes the path a layer.
                let q = place(p, from: first.point, own: nil, showGuides: false)
                let points = BezierPath(subpaths: [BezierPath.Subpath(anchors: [first, BezierPath.Anchor(q)])])
                store.beginGesture()
                let node = Node.path(points, name: store.doc.nextName(for: .path))
                store.add(node, onto: s.board, action: "Add Path")
                session = Session(id: node.id, board: s.board)
                session?.headIn = first.handleIn.map { (first.point, $0) }
                drag = .pull(id: node.id, base: points, at: PathPoint(subpath: 0, index: 1), closing: false, lastIn: nil,
                             moved: false, action: "Add Path")
                return
            }
        }

        // Over the selected path: carry on from an open end, take a point away, or add one.
        if let id = shownPath, let points = store.points(of: id) {
            if let q = anchor(at: v, in: points) {
                if points.isEnd(q) {
                    session = Session(id: id, run: q.subpath, fromStart: q.index == 0)
                    store.selectedPoints = []
                    redraw()
                } else {
                    var next = points
                    next.remove([q])
                    store.setPoints(next, of: id, "Delete Point")
                    store.selectedPoints = []
                }
                return
            }
            if let s = segment(at: v, in: points) {
                var next = points
                let added = next.insert(s.subpath, segment: s.segment, t: s.t)
                store.setPoints(next, of: id, "Add Point")
                if store.editingPath == id { store.selectedPoints = [added] }
                return
            }
        }

        // A new path, its first point only here until there is a second.
        let q = place(p, from: nil, own: nil, showGuides: false)
        store.selection = []
        session = Session(first: BezierPath.Anchor(q), board: store.doc.artboard(at: q)?.id)
        drag = .pull(id: nil, base: nil, at: PathPoint(subpath: 0, index: 0), closing: false, lastIn: nil, moved: false, action: nil)
        redraw()
    }

    /// Ends the path being drawn: it stays as it is, selected, and the pen is put down.
    private func finish() {
        session = nil
        store.guides = []
        store.tool = .select
        redraw()
    }

    /// Takes away the newest point. With only two, the path goes and its first point is left for the pen.
    private func removeLast() {
        guard let s = session else { return }
        guard let (id, points, run) = drawnPath() else {
            session = nil
            redraw()
            return
        }
        let anchors = points.subpaths[run].anchors
        if anchors.count <= 2 && points.subpaths.count == 1 {
            let board = s.board ?? store.doc.artboard(of: id)?.id
            store.setPoints(BezierPath(), of: id, "Delete Point")
            session = Session(first: anchors[0], board: board)
        } else {
            var next = points
            next.remove([PathPoint(subpath: run, index: anchors.count - 1)])
            store.setPoints(next, of: id, "Delete Point")
            session?.fromStart = false
            session?.tailOut = nil
            if anchors.count <= 2 { session = nil }
        }
        redraw()
    }

    // MARK: - Editing points

    /// A press while a path's points are being edited: on a point, a handle or the outline.
    /// False when it is on none of them, for the canvas to deal with.
    func editDown(at v: CGPoint, event: NSEvent) -> Bool {
        guard let (id, points) = store.editedPoints else { return false }
        downView = v
        flags = event.modifierFlags
        let p = canvas(v)
        let added = justAdded
        justAdded = nil
        // The ghost of a point to add has done its job; left, it would stay behind while the
        // point it became is dragged away.
        spot = nil

        if let q = anchor(at: v, in: points) {
            if event.clickCount >= 2 {
                // A double click turns a corner smooth and a smooth point sharp, but not the point
                // the first click put there.
                if q != added { store.setSmooth(!points.isSmooth(q), [q]) }
                store.selectedPoints = [q]
                return true
            }
            if flags.contains(.shift) {
                if store.livePoints.contains(q) {
                    store.selectedPoints.remove(q)
                    return true
                }
                store.selectedPoints.insert(q)
            } else if !store.livePoints.contains(q) {
                store.selectedPoints = [q]
            }
            movePoints(id, points, grabbed: q, from: p, action: "Move Points")
            return true
        }
        if let h = handle(at: v, in: points) {
            drag = .handle(id: id, base: points, at: h, moved: false)
            return true
        }
        if let s = segment(at: v, in: points) {
            store.beginGesture()
            var next = points
            let q = next.insert(s.subpath, segment: s.segment, t: s.t)
            store.setPoints(next, of: id, "Add Point")
            store.selectedPoints = [q]
            justAdded = q
            movePoints(id, next, grabbed: q, from: p, action: "Add Point")
            return true
        }
        return false
    }

    private func movePoints(_ id: UUID, _ points: BezierPath, grabbed: PathPoint, from p: CGPoint, action: LocalizedStringResource) {
        let moving = store.livePoints
        drag = .points(id: id, base: points, moving: moving, grabbed: grabbed, start: p,
                       targets: targets(at: p, own: points, except: moving), moved: false, action: action)
    }

    /// Dragging round points, from somewhere that is not on the path: picks those inside.
    func startMarquee(at v: CGPoint, adding: Bool, offPath: Bool) {
        downView = v
        drag = .marquee(start: canvas(v), base: adding ? store.livePoints : [], leaves: offPath && !adding)
        if !adding { store.selectedPoints = [] }
    }

    // MARK: - Dragging

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        self.flags = flags
        let p = canvas(v)
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let far = hypot(v.x - downView.x, v.y - downView.y) > 3

        switch drag {
        case nil:
            break

        case .pull(let id, let base, let at, let closing, let lastIn, let moved, let action):
            guard moved || far else { return }
            guard let anchor = base?[at].point ?? session?.first?.point else { return }
            let out = shift ? Geometry.lineEnd(from: anchor, to: p, constrain: true) : p
            let mirror = CGPoint(x: 2 * anchor.x - out.x, y: 2 * anchor.y - out.y)
            // The handle out follows the pointer and the one in mirrors it; with Option it stays
            // where it was, for a point that bends.
            let handleIn = option ? lastIn : mirror
            guard let base, let id, let action else {
                session?.first?.handleOut = out
                session?.first?.handleIn = handleIn
                drag = .pull(id: nil, base: nil, at: at, closing: closing, lastIn: handleIn, moved: true, action: action)
                redraw()
                return
            }
            var next = base
            if closing {
                // The curve coming back in is shaped by the mirrored handle; Option leaves the
                // first curve as it was.
                next[at].handleIn = mirror
                if !option { next[at].handleOut = out }
            } else {
                next[at].handleOut = out
                next[at].handleIn = handleIn
                session?.tailOut = (anchor, out)
            }
            store.setPoints(next, of: id, action)
            drag = .pull(id: id, base: base, at: at, closing: closing, lastIn: handleIn, moved: true, action: action)

        case .cusp(let id, let base, let at, let moved):
            guard moved || far else { return }
            let anchor = base[at].point
            let out = shift ? Geometry.lineEnd(from: anchor, to: p, constrain: true) : p
            session?.tailOut = BezierPath.same(out, anchor) ? nil : (anchor, out)
            drag = .cusp(id: id, base: base, at: at, moved: true)
            redraw()

        case .points(let id, let base, let moving, let grabbed, let start, let targets, let moved, let action):
            guard moved || far else { return }
            if !moved { store.beginGesture() }
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            let from = base[grabbed].point
            let free = flags.contains(.command)
            var guides: [Guide] = []
            var caught: (x: CGFloat?, y: CGFloat?) = (nil, nil)
            if !free {
                let (q, x, y) = targets.snap(point: CGPoint(x: from.x + dx, y: from.y + dy), threshold: 5 / zoom)
                caught = (shift && dx == 0 ? nil : x, shift && dy == 0 ? nil : y)
                if caught.x != nil { dx = q.x - from.x }
                if caught.y != nil { dy = q.y - from.y }
            }
            // The point held lands right on what caught it, or on the steps for the zoom; the
            // others picked go as far as it does. Held by Shift, it stays where it was that way.
            if caught.x == nil, dx != 0 { dx = landed(from.x + dx, free: free) - from.x }
            if caught.y == nil, dy != 0 { dy = landed(from.y + dy, free: free) - from.y }
            if !free {
                guides = targets.guides(for: CGRect(origin: CGPoint(x: from.x + dx, y: from.y + dy), size: .zero), x: caught.x, y: caught.y)
            }
            let d = CGPoint(x: dx, y: dy)
            var next = base
            for q in moving.union([grabbed]) where next.contains(q) { next[q] = base[q].offset(by: d) }
            store.setPoints(next, of: id, action)
            store.guides = guides
            drag = .points(id: id, base: base, moving: moving, grabbed: grabbed, start: start, targets: targets, moved: true, action: action)

        case .handle(let id, let base, let at, let moved):
            guard moved || far else { return }
            if !moved { store.beginGesture() }
            let anchor = base[at.point].point
            let to = shift ? Geometry.lineEnd(from: anchor, to: p, constrain: true) : p
            var next = base
            next.moveHandle(at.point, out: at.out, to: to, alone: option)
            store.setPoints(next, of: id, "Move Handle")
            drag = .handle(id: id, base: base, at: at, moved: true)

        case .marquee(let start, let base, _):
            let rect = Geometry.rect(from: start, to: p)
            marquee = rect
            if let (_, points) = store.editedPoints {
                store.selectedPoints = base.union(points.allPoints.filter { rect.contains(points[$0].point) })
            }
            redraw()
        }
    }

    func up(at v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .pull(_, _, _, let closing, _, _, let action):
            if let action { store.endGesture(action) }
            if closing {
                session = nil
                store.tool = .select
            }
        case .cusp(_, _, _, let moved):
            // A click takes the handle away; what a drag pulled out stays.
            if !moved { session?.tailOut = nil }
        case .points(_, _, _, _, _, _, _, let action):
            store.endGesture(action)
        case .handle:
            store.endGesture("Move Handle")
        case .marquee(_, _, let leaves):
            marquee = nil
            if leaves, hypot(v.x - downView.x, v.y - downView.y) <= 3 { store.editingPath = nil }
        }
        hover(v, flags: flags)
        redraw()
    }

    /// Escape during a drag puts everything back as it was.
    private func cancelDrag() {
        if case .pull(nil, _, _, _, _, _, _) = drag { session = nil }
        drag = nil
        marquee = nil
        store.cancelGesture()
        redraw()
    }

    // MARK: - Keys

    /// Keys for the pen and for editing points; false for those left to the canvas.
    func key(_ event: NSEvent) -> Bool {
        check()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = event.keyCode
        let escape = code == 53, enter = code == 36 || code == 76, delete = code == 51 || code == 117
        if drag != nil {
            if escape { cancelDrag(); return true }
            return false
        }
        if session != nil {
            if escape || enter { finish(); return true }
            if delete { removeLast(); return true }
            return false
        }
        if store.editingPath != nil {
            if escape || enter { store.editingPath = nil; return true }
            if delete { store.deleteSelectedPoints(); return true }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            if !store.livePoints.isEmpty {
                switch code {
                case 123: store.nudgePoints(dx: -step, dy: 0); return true
                case 124: store.nudgePoints(dx: step, dy: 0); return true
                case 125: store.nudgePoints(dx: 0, dy: step); return true
                case 126: store.nudgePoints(dx: 0, dy: -step); return true
                default: break
                }
            }
            return false
        }
        // Return on a selected path starts editing its points.
        if enter, store.tool == .select || store.tool == .pen, store.selection.count == 1, store.node(store.selection[0])?.kind == .path {
            store.editPoints()
            return true
        }
        return false
    }

    // MARK: - The pointer

    /// The pointer moving over the canvas with nothing pressed, or leaving it (nil).
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        check()
        self.flags = flags
        let was = (mark, preview, spot)
        mark = .none
        preview = nil
        spot = nil
        defer { if was != (mark, preview, spot) { redraw() } }
        guard let v, drag == nil else { return }

        if store.tool == .pen {
            if session != nil {
                if let (_, points, run) = drawnPath() {
                    let anchors = points.subpaths[run].anchors
                    if anchors.count > 1, near(v, anchors[0].point) { mark = .close; clearGuides(); return }
                    if near(v, anchors[anchors.count - 1].point) { mark = .convert; clearGuides(); return }
                    preview = place(canvas(v), from: anchors[anchors.count - 1].point, own: points, showGuides: true)
                } else if let first = session?.first {
                    if near(v, first.point) { clearGuides(); return }
                    preview = place(canvas(v), from: first.point, own: nil, showGuides: true)
                }
                return
            }
            if let id = shownPath, let points = store.points(of: id) {
                if let q = anchor(at: v, in: points) { mark = points.isEnd(q) ? .carryOn : .remove; clearGuides(); return }
                if let s = segment(at: v, in: points) { mark = .add; spot = s.point; clearGuides(); return }
            }
            _ = place(canvas(v), from: nil, own: nil, showGuides: true)
            return
        }
        if store.tool == .select, let (_, points) = store.editedPoints {
            if anchor(at: v, in: points) != nil || handle(at: v, in: points) != nil { mark = .point; return }
            if let s = segment(at: v, in: points) { mark = .add; spot = s.point }
        }
    }

    private func clearGuides() {
        if !store.guides.isEmpty { store.guides = [] }
    }

    /// The pointer for where it is, or nil when this has no say.
    var cursor: NSCursor? {
        if store.tool == .pen {
            switch mark {
            case .add: return Cursors.pen(.add)
            case .remove: return Cursors.pen(.remove)
            case .close: return Cursors.pen(.close)
            case .convert: return Cursors.pen(.convert)
            case .carryOn: return Cursors.pen(.carryOn)
            case .none, .point: return Cursors.pen(.none)
            }
        }
        if store.tool == .select, store.editingPath != nil {
            return mark == .add ? Cursors.pen(.add) : .arrow
        }
        return nil
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        check()
        deviceScale = scale
        let vp = store.viewport
        let toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        var shown: BezierPath?, newest: PathPoint?
        if store.tool == .pen, let (_, points, run) = drawnPath() {
            shown = points
            newest = PathPoint(subpath: run, index: points.subpaths[run].anchors.count - 1)
        } else if let id = shownPath, let points = store.points(of: id) {
            shown = points
        }

        if let shown {
            ctx.addPath(Self.placed(shown.cgPath, toView))
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // The curve still to come: from the newest point to where the next would go, or back to the first.
        if store.tool == .pen, drag == nil, let tail = shown.flatMap({ s in newest.map { s[$0] } }) ?? session?.first {
            var to: (CGPoint, CGPoint)?
            if mark == .close, let shown, let run = newest?.subpath {
                let head = shown.subpaths[run].anchors[0]
                to = (head.handleIn ?? head.point, head.point)
            } else if let preview {
                to = (preview, preview)
            }
            if let (c2, end) = to {
                let band = CGMutablePath()
                band.move(to: tail.point)
                band.addCurve(to: end, control1: tail.handleOut ?? tail.point, control2: c2)
                ctx.addPath(Self.placed(band, toView))
                ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
        }

        if let shown {
            let picked = store.editingPath != nil && session == nil ? store.livePoints : []
            drawHandles(handles(in: shown).compactMap { h in shown[h.point].handle(out: h.out).map { (shown[h.point].point, $0) } }, in: ctx)
            for q in shown.allPoints {
                drawAnchor(view(shown[q].point), filled: picked.contains(q) || q == newest, in: ctx)
            }
            if mark == .close, let run = newest?.subpath {
                let c = crisp(view(shown[PathPoint(subpath: run, index: 0)].point))
                ctx.setStrokeColor(CanvasInk.pencil.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(center: c, size: CGSize(width: 15, height: 15)))
            }
        }
        if store.tool == .pen, let first = session?.first {
            drawHandles([first.handleIn, first.handleOut].compactMap { $0.map { (first.point, $0) } }, in: ctx)
            drawAnchor(view(first.point), filled: true, in: ctx)
        }
        if let spot {
            ctx.setAlpha(0.55)
            drawAnchor(view(spot), filled: false, in: ctx)
            ctx.setAlpha(1)
        }
        if let marquee {
            let r = vp.toView(marquee)
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private static func placed(_ path: CGPath, _ t: CGAffineTransform) -> CGPath {
        var t = t
        return path.copy(using: &t) ?? path
    }

    /// Lines of one pixel fall on whole pixels.
    private func crisp(_ p: CGPoint) -> CGPoint {
        let s = deviceScale
        return CGPoint(x: (p.x * s).rounded() / s + 0.5 / s, y: (p.y * s).rounded() / s + 0.5 / s)
    }

    private func drawAnchor(_ p: CGPoint, filled: Bool, in ctx: CGContext) {
        let rect = CGRect(center: crisp(p), size: CGSize(width: 7, height: 7)).offsetBy(dx: -0.5 / deviceScale, dy: -0.5 / deviceScale)
        ctx.setFillColor(filled ? CanvasInk.pencil.cgColor : .white)
        ctx.fill(rect)
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// Each handle as a line from its point to a small round knob, all in canvas points.
    private func drawHandles(_ handles: [(CGPoint, CGPoint)], in ctx: CGContext) {
        guard !handles.isEmpty else { return }
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        for (a, h) in handles {
            ctx.move(to: crisp(view(a)))
            ctx.addLine(to: crisp(view(h)))
        }
        ctx.strokePath()
        for (_, h) in handles {
            let rect = CGRect(center: crisp(view(h)), size: CGSize(width: 7, height: 7))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
