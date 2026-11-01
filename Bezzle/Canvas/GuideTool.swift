import AppKit

/// Guides on the canvas. Each runs across its artboard from edge to edge, as a thread stretched
/// across a sheet, and quivers for a moment when it catches on something or is let go. One is
/// pulled out of a ruler, or put down by a click on one, and dragged by its tab on the ruler, or
/// by its line wherever no layer lies under it; resting on it where one does lights up its tab. While it moves, it catches on the
/// artboard's edges and middle, on what lies on the artboard and on the layout grid, Shift holding
/// it to tens; its distance to either edge shows in a pill, solid toward the edge it keeps to.
/// Dragged off its artboard, or back onto the ruler, it goes when let go. A click on a guide
/// without a drag is a click on what lies under it; with Option a drag leaves a copy behind.
final class GuideTool {
    private let store: DocumentStore
    private let rulers: Rulers
    var redraw: () -> Void = {}
    /// A press on a guide that did not become a drag, which the canvas takes as a click.
    var click: (CGPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// Opens a menu at a point on screen.
    var menu: (CGPoint, [MenuEntry]) -> Void = { _, _ in }
    /// Whether a layer lies under a point on screen. Where one does, a guide's line leaves the
    /// pointer to it, and the guide is taken by its tab on the ruler, which lights up to say so.
    var covered: (CGPoint) -> Bool = { _ in false }

    struct Ref: Hashable {
        let board: UUID
        let key: String
    }

    private enum Drag {
        /// A press on a ruler, not yet a drag: a click puts a guide where it was.
        case press(Rulers.Part, start: CGPoint)
        /// A guide coming out of a ruler, or a copy of one, on no artboard until it is let go.
        case new(vertical: Bool, from: Ref?)
        /// A guide on an artboard, moved, by its line or its tab.
        case move(Ref, vertical: Bool, grip: CGFloat, started: Bool, start: CGPoint, copy: Bool, flags: NSEvent.ModifierFlags)
        /// Two guides at once, out of the corner.
        case cross
    }

    /// Where a guide being dragged is, and what it is doing.
    private struct Held {
        var board: UUID?
        var vertical: Bool
        /// Across or down its artboard.
        var position: CGFloat
        var leaving: Bool
        var caught: CGFloat?
        /// Where along it the pointer is, on the canvas, for the pills.
        var pointer: CGPoint
    }

    private var drag: Drag?
    private var held: [Held] = []
    private var hovered: Ref?
    /// The guide the pointer rests on where a layer lies over it: the press is the layer's, and
    /// the guide's tab on the ruler lights up, where it is taken instead. `beckoned` keeps the
    /// glow on it while it fades.
    private var beckoning: Ref?
    private var beckoned: Ref?
    private var beckon = DeckTool.Spring(0)
    private var caught: [CGFloat?] = []

    // Motion.
    private var grow = DeckTool.Spring(1)
    private var appearing: [Ref: CFTimeInterval] = [:]
    private var plucks: [Ref: CFTimeInterval] = [:]
    private var heldPluck: CFTimeInterval?
    private struct Vanishing {
        var from: CGPoint
        var to: CGPoint
        var born: CFTimeInterval
    }
    private var vanishing: [Vanishing] = []
    private var last: CFTimeInterval?
    private var deviceScale: CGFloat = 2

    /// How long a guide takes to unroll across its artboard, and how long a pluck rings.
    private static let unroll = 0.32
    private static let ring = 1.05

    init(store: DocumentStore, rulers: Rulers) {
        self.store = store
        self.rulers = rulers
    }

    var dragging: Bool {
        switch drag {
        case nil, .press: false
        case .move(_, _, _, let started, _, _, _): started
        default: true
        }
    }

    var pressed: Bool { drag != nil }

    var isAnimating: Bool {
        let now = CACurrentMediaTime()
        return grow.isMoving || beckon.isMoving || !vanishing.isEmpty || appearing.values.contains { now - $0 < Self.unroll }
            || plucks.values.contains { now - $0 < Self.ring } || heldPluck.map { now - $0 < Self.ring } ?? false
    }

    private var zoom: CGFloat { store.viewport.zoom }
    private var shown: Bool { Helpers.shared.guides }

    // MARK: - Finding guides

    /// The artboards whose guides are in sight, big enough on screen to be worked with.
    private func boards() -> [Node] {
        let visible = store.visibleCanvasRect
        return store.doc.artboards.filter { !$0.hidden && $0.guides?.isEmpty == false && $0.frame.intersects(visible.insetBy(dx: -20, dy: -20))
            && min($0.frame.width, $0.frame.height) * zoom >= 24 }
    }

    /// A guide's line on the canvas, from edge to edge of its artboard and no further.
    private func line(of g: Guideline, on board: Node) -> (CGPoint, CGPoint) {
        let f = board.frame, at = g.position(in: f.size)
        return g.vertical ? (CGPoint(x: f.minX + at, y: f.minY), CGPoint(x: f.minX + at, y: f.maxY))
                          : (CGPoint(x: f.minX, y: f.minY + at), CGPoint(x: f.maxX, y: f.minY + at))
    }

    /// The guide whose line a point on screen is within a few points of, and whether a layer lies
    /// under the point, where the press is the layer's.
    private func nearest(at v: CGPoint) -> (ref: Ref, covered: Bool)? {
        guard shown else { return nil }
        for board in boards().reversed() {
            var best: (String, CGFloat)?
            for (key, g) in board.guides ?? [:] {
                let (a, b) = line(of: g, on: board)
                let va = store.viewport.toView(a), vb = store.viewport.toView(b)
                let off = g.vertical ? abs(v.x - va.x) : abs(v.y - va.y)
                let within = g.vertical ? (v.y >= va.y - 3 && v.y <= vb.y + 3) : (v.x >= va.x - 3 && v.x <= vb.x + 3)
                guard within, off <= 4, best.map({ off < $0.1 }) ?? true else { continue }
                best = (key, off)
            }
            if let best {
                return (Ref(board: board.id, key: best.0), store.viewport.toView(board.frame).contains(v) && covered(v))
            }
        }
        return nil
    }

    /// The guide under a point on screen that a press there takes: within a few points of it,
    /// where no layer lies under the pointer.
    func guide(at v: CGPoint) -> Ref? {
        guard let n = nearest(at: v), !n.covered else { return nil }
        return n.ref
    }

    /// The guide whose tab on a ruler is under a point on screen.
    private func tab(at v: CGPoint, on part: Rulers.Part) -> Ref? {
        guard shown, let board = rulers.board, part != .corner else { return nil }
        let across = part == .top
        let f = board.frame
        var best: (String, CGFloat)?
        for (key, g) in board.guides ?? [:] where g.vertical == across {
            let p = store.viewport.toView(CGPoint(x: f.minX + g.position(in: f.size), y: f.minY + g.position(in: f.size)))
            let off = abs(across ? v.x - p.x : v.y - p.y)
            if off <= 6, best.map({ off < $0.1 }) ?? true { best = (key, off) }
        }
        return best.map { Ref(board: board.id, key: $0.0) }
    }

    // MARK: - Pressing

    /// A press on a ruler, whatever the tool. False leaves it to the canvas.
    func rulerDown(at v: CGPoint, event: NSEvent) -> Bool {
        guard let part = rulers.part(at: v) else { return false }
        if event.clickCount >= 2 { return true }
        if let ref = tab(at: v, on: part), !Helpers.shared.guidesLocked, let g = store.node(ref.board)?.guides?[ref.key] {
            let at = position(of: g, on: ref.board)
            let p = canvas(v)
            drag = .move(ref, vertical: g.vertical, grip: (g.vertical ? p.x : p.y) - at, started: false, start: v, copy: false, flags: event.modifierFlags)
            return true
        }
        drag = .press(part, start: v)
        return true
    }

    /// A press with the select tool on a guide's line. False leaves it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard store.tool == .select, !Helpers.shared.guidesLocked, !store.isReadOnly, let ref = guide(at: v),
              let g = store.node(ref.board)?.guides?[ref.key] else { return false }
        let at = position(of: g, on: ref.board), p = canvas(v)
        drag = .move(ref, vertical: g.vertical, grip: (g.vertical ? p.x : p.y) - at, started: false, start: v,
                     copy: event.modifierFlags.contains(.option), flags: event.modifierFlags)
        return true
    }

    /// A guide's place across its artboard, or down it, as the artboard is now.
    private func position(of g: Guideline, on board: UUID) -> CGFloat {
        guard let b = store.node(board) else { return 0 }
        return (g.vertical ? b.frame.minX : b.frame.minY) + g.position(in: b.frame.size)
    }

    private func canvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        switch drag {
        case .press(let part, let start):
            guard hypot(v.x - start.x, v.y - start.y) > 3, !store.isReadOnly else { return }
            // Out of the top ruler comes a guide across, out of the left one a guide down.
            switch part {
            case .top: drag = .new(vertical: false, from: nil)
            case .left: drag = .new(vertical: true, from: nil)
            case .corner: drag = .cross
            }
            grow = DeckTool.Spring(0)
            grow.target = 1
            caught = []
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            drag(to: v, flags: flags)
            return
        case .move(let ref, let vertical, let grip, let started, let start, let copy, let first):
            if !started {
                guard hypot(v.x - start.x, v.y - start.y) > 3 else { return }
                if copy {
                    drag = .new(vertical: vertical, from: ref)
                    grow = DeckTool.Spring(1)
                    drag(to: v, flags: flags)
                    return
                }
                store.beginGesture()
                drag = .move(ref, vertical: vertical, grip: grip, started: true, start: start, copy: false, flags: first)
            }
            let p = canvas(v)
            var h = place(vertical: vertical, at: (vertical ? p.x : p.y) - grip, pointer: p, view: v, board: ref.board, except: ref.key, flags: flags)
            h.board = ref.board
            if !h.leaving { store.moveGuide(ref.key, on: ref.board, to: h.position) }
            note(h, slot: 0)
            held = [h]
        case .new(let vertical, let from):
            let p = canvas(v)
            let board = from?.board ?? store.doc.artboard(at: p)?.id ?? rulers.board?.id
            let h = place(vertical: vertical, at: vertical ? p.x : p.y, pointer: p, view: v, board: board, except: nil, flags: flags)
            note(h, slot: 0)
            held = [h]
        case .cross:
            let p = canvas(v)
            let board = store.doc.artboard(at: p)?.id ?? rulers.board?.id
            let a = place(vertical: true, at: p.x, pointer: p, view: v, board: board, except: nil, flags: flags)
            let b = place(vertical: false, at: p.y, pointer: p, view: v, board: board, except: nil, flags: flags)
            note(a, slot: 0)
            note(b, slot: 1)
            held = [a, b]
        case nil:
            return
        }
        redraw()
    }

    /// A guide's catch felt, and seen as a quiver, each time it catches on something new.
    private func note(_ h: Held, slot: Int) {
        while caught.count <= slot { caught.append(nil) }
        if h.caught != caught[slot] {
            if h.caught != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                heldPluck = CACurrentMediaTime()
            }
            caught[slot] = h.caught
        }
    }

    /// Where a guide dragged to `value` on the canvas settles on an artboard: caught on what is near,
    /// held to tens with Shift, or let go of anything with Command; and whether it is leaving.
    private func place(vertical: Bool, at value: CGFloat, pointer p: CGPoint, view v: CGPoint, board id: UUID?, except: String?,
                       flags: NSEvent.ModifierFlags) -> Held {
        guard let id, let board = store.node(id) else {
            return Held(board: nil, vertical: vertical, position: value, leaving: true, caught: nil, pointer: p)
        }
        let f = board.frame
        let length = vertical ? f.width : f.height
        var at = value - (vertical ? f.minX : f.minY)
        var caughtOn: CGFloat?
        if flags.contains(.shift) {
            // In tens from the edge it is nearer.
            at = at <= length / 2 ? (at / 10).rounded() * 10 : length - ((length - at) / 10).rounded() * 10
        } else if !flags.contains(.command) {
            let reach = 6 / zoom
            if let near = targets(on: board, vertical: vertical, except: except).min(by: { abs($0 - at) < abs($1 - at) }), abs(near - at) <= reach {
                at = near
                caughtOn = near
            } else {
                at = at.rounded()
            }
        } else {
            at = at.rounded()
        }
        // Back on the ruler it came from, or well off the artboard, it goes when let go.
        let t = rulers.thickness
        let onRuler = vertical ? v.x < t : v.y < t
        let slack = 14 / zoom
        let leaving = onRuler || at < -slack || at > length + slack
        return Held(board: id, vertical: vertical, position: min(max(at, 0), length), leaving: leaving, caught: leaving ? nil : caughtOn, pointer: p)
    }

    /// What a guide catches on along an artboard, in its own coordinates: its edges and middle,
    /// each slide's of a carousel, the edges and middles of what lies on it, and its grid's columns,
    /// rows and baselines.
    private func targets(on board: Node, vertical: Bool, except: String?) -> [CGFloat] {
        let f = board.frame, length = vertical ? f.width : f.height
        var out: [CGFloat] = [0, length / 2, length]
        if board.isCarousel { for s in board.slideRects { out += vertical ? [s.minX, s.midX, s.maxX] : [s.minY, s.midY, s.maxY] } }
        for child in store.seenLayers(of: board) where !child.hidden {
            let b = Geometry.bounds(of: child)
            out += vertical ? [b.minX, b.midX, b.maxX] : [b.minY, b.midY, b.maxY]
        }
        if Helpers.shared.grids, let grid = board.layout {
            let edges = grid.edges(of: board)
            out += vertical ? edges.xs : edges.ys + edges.baselines
        }
        return out
    }

    func up(at v: CGPoint, flags: NSEvent.ModifierFlags) {
        defer {
            drag = nil
            held = []
            caught = []
            redraw()
        }
        switch drag {
        case .press(let part, _):
            if part == .corner {
                menu(v, Helpers.shared.entries(for: store))
                return
            }
            // A click on a ruler puts a guide down there, running across the ruler.
            guard !store.isReadOnly, let board = rulers.board else { return }
            let vertical = part == .top
            let p = canvas(v)
            let f = board.frame
            let at = ((vertical ? p.x - f.minX : p.y - f.minY)).rounded()
            guard at >= 0, at <= (vertical ? f.width : f.height) else { return }
            if let key = store.addGuide(at: at, vertical: vertical, to: board.id) {
                let ref = Ref(board: board.id, key: key), now = CACurrentMediaTime()
                appearing[ref] = now
                // It quivers as it comes taut at the far edge.
                plucks[ref] = now + Self.unroll * 0.8
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        case .move(let ref, _, _, let started, _, _, let first):
            guard started else {
                // A click on a guide is a click on what lies under it; on a tab, nothing.
                if rulers.part(at: v) == nil { click(v, first) }
                return
            }
            if let h = held.first, h.leaving {
                store.cancelGesture()
                if let b = store.node(ref.board), let g = b.guides?[ref.key] { vanish(g, on: b, at: h.pointer) }
                store.removeGuide(ref.key, from: ref.board)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } else {
                store.endGesture("Move Guide")
                plucks[ref] = CACurrentMediaTime()
            }
        case .new:
            commit(held, action: "Add Guide")
        case .cross:
            commit(held, action: "Add Guides")
        case nil:
            break
        }
    }

    private func commit(_ guides: [Held], action: LocalizedStringResource) {
        let kept = guides.filter { !$0.leaving && $0.board != nil }
        guard !kept.isEmpty else {
            for h in guides { vanish(h) }
            return
        }
        var added: [Ref] = []
        store.edit(action) { doc in
            for h in kept {
                guard let id = h.board, let b = doc.node(id) else { continue }
                let key = Guideline.key(besides: (b.guides ?? [:]).keys)
                let g = Guideline.at(h.position, vertical: h.vertical, in: b.frame.size)
                doc.update(id) { $0.guides = ($0.guides ?? [:]).merging([key: g]) { _, new in new } }
                added.append(Ref(board: id, key: key))
            }
        }
        let now = CACurrentMediaTime()
        for r in added { plucks[r] = now }
        Helpers.shared.guides = true
    }

    func cancel() {
        guard drag != nil else { return }
        if case .move(_, _, _, true, _, _, _) = drag { store.cancelGesture() }
        drag = nil
        held = []
        redraw()
    }

    /// A guide taken away, shrinking to where the pointer let it go as it fades.
    private func vanish(_ g: Guideline, on board: Node, at p: CGPoint) {
        let (a, b) = line(of: g, on: board)
        vanishing.append(Vanishing(from: g.vertical ? CGPoint(x: p.x, y: a.y) : CGPoint(x: a.x, y: p.y),
                                   to: g.vertical ? CGPoint(x: p.x, y: b.y) : CGPoint(x: b.x, y: p.y), born: CACurrentMediaTime()))
    }

    private func vanish(_ h: Held) {
        guard let id = h.board, let board = store.node(id) else { return }
        let g = Guideline(vertical: h.vertical, edge: .start, offset: h.position)
        vanish(g, on: board, at: h.pointer)
    }

    // MARK: - The pointer at rest

    func hover(_ v: CGPoint?) {
        var ref: Ref?, through: Ref?
        if let v, drag == nil {
            if let part = rulers.part(at: v) {
                ref = tab(at: v, on: part)
            } else if store.tool == .select, !Helpers.shared.guidesLocked, !store.isReadOnly, let n = nearest(at: v) {
                if n.covered { through = n.ref } else { ref = n.ref }
            }
        }
        // Its tab lights up only where there is one: on the rulers, measuring its artboard.
        if let t = through, !(Helpers.shared.rulers && rulers.board?.id == t.board) { through = nil }
        if ref != hovered || through != beckoning {
            hovered = ref
            beckoning = through
            if let through { beckoned = through }
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if let h = held.first, case .move = drag, dragging { return h.vertical ? .resizeLeftRight : .resizeUpDown }
        if case .new(let vertical, _) = drag { return held.first?.leaving == true ? .disappearingItem : vertical ? .resizeLeftRight : .resizeUpDown }
        if case .cross = drag { return .crosshair }
        if let part = rulers.part(at: v) {
            if part == .corner { return .pointingHand }
            if let ref = tab(at: v, on: part), let g = store.node(ref.board)?.guides?[ref.key] { return g.vertical ? .resizeLeftRight : .resizeUpDown }
            return .arrow
        }
        guard drag == nil, store.tool == .select, let ref = hovered, rulers.part(at: v) == nil,
              let g = store.node(ref.board)?.guides?[ref.key] else { return nil }
        return g.vertical ? .resizeLeftRight : .resizeUpDown
    }

    /// What a right click on a guide offers, if it is on one.
    func menuEntries(at v: CGPoint) -> [MenuEntry]? {
        guard let ref = guide(at: v) else { return nil }
        let count = store.node(ref.board)?.guides?.count ?? 0
        return [
            .item("Remove Guide", enabled: !store.isReadOnly) { self.store.removeGuide(ref.key, from: ref.board) },
            .item("Remove Guides", enabled: count > 1 && !store.isReadOnly) { self.store.removeGuides(from: ref.board) },
            .separator,
            .item("Lock Guides", checked: Helpers.shared.guidesLocked) { Helpers.shared.guidesLocked.toggle() },
        ]
    }

    // MARK: - On the rulers

    /// The tabs of the guides of the artboard the rulers measure, and of a guide being dragged.
    func tabs() -> [Rulers.Tab] {
        guard shown, let board = rulers.board else { return [] }
        let f = board.frame, vp = store.viewport
        var out: [Rulers.Tab] = []
        let moving: Ref? = if case .move(let r, _, _, true, _, _, _) = drag { r } else { nil }
        for (key, g) in board.guides ?? [:] {
            let ref = Ref(board: board.id, key: key)
            if ref == moving, held.first?.leaving == true { continue }
            let p = vp.toView(CGPoint(x: f.minX + g.position(in: f.size), y: f.minY + g.position(in: f.size)))
            let glow = ref == beckoned ? CGFloat(min(max(beckon.value, 0), 1)) : 0
            out.append(Rulers.Tab(at: g.vertical ? p.x : p.y, vertical: g.vertical, lit: ref == hovered || ref == moving || glow > 0.5, glow: glow))
        }
        if case .move = drag {} else {
            for h in held where !h.leaving && h.board == board.id {
                let p = vp.toView(CGPoint(x: f.minX + h.position, y: f.minY + h.position))
                out.append(Rulers.Tab(at: h.vertical ? p.x : p.y, vertical: h.vertical, lit: true))
            }
        }
        return out
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let now = CACurrentMediaTime()
        let dt = min(now - (last ?? now), 1.0 / 30)
        last = now
        grow.step(dt, stiffness: 260, damping: 26)
        beckon.target = beckoning == nil ? 0 : 1
        beckon.step(dt, stiffness: 320, damping: 26)
        if beckoning == nil, beckon.value < 0.01, !beckon.isMoving { beckoned = nil }
        appearing = appearing.filter { now - $0.value < Self.unroll }
        plucks = plucks.filter { now - $0.value < Self.ring }
        vanishing = vanishing.filter { now - $0.born < 0.24 }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        if shown {
            let moving: Ref? = if case .move(let r, _, _, true, _, _, _) = drag { r } else { nil }
            for board in boards() {
                for (key, g) in board.guides ?? [:] {
                    let ref = Ref(board: board.id, key: key)
                    if ref == moving, held.first?.leaving == true { continue }
                    let lit = ref == hovered || ref == moving
                    // Pointed at through a layer: brighter, as its tab lights up, but not lifted.
                    let glow = ref == beckoned ? CGFloat(min(max(beckon.value, 0), 1)) : 0
                    let (a, b) = line(of: g, on: board)
                    var reach: CGFloat = 1
                    if let born = appearing[ref] { reach = Self.unrolled(min((now - born) / Self.unroll, 1)) }
                    let pluck = ref == moving ? heldPluck : plucks[ref]
                    drawThread(ctx, from: a, to: b, alpha: lit ? 1 : 0.62 + 0.26 * glow, width: lit ? 1.25 : 1, reach: reach, from0: true,
                               pluck: pluck.map { now - $0 }, strength: ref == moving ? Self.caughtStrength : 1, vertical: g.vertical)
                }
            }
        }
        for v in vanishing {
            let k = CGFloat((now - v.born) / 0.24)
            let mid = CGPoint(x: (v.from.x + v.to.x) / 2, y: (v.from.y + v.to.y) / 2)
            let a = CGPoint(x: v.from.x + (mid.x - v.from.x) * k, y: v.from.y + (mid.y - v.from.y) * k)
            let b = CGPoint(x: v.to.x + (mid.x - v.to.x) * k, y: v.to.y + (mid.y - v.to.y) * k)
            drawThread(ctx, from: a, to: b, alpha: 0.7 * (1 - k), width: 1, reach: 1, from0: true, pluck: nil, vertical: v.from.x == v.to.x)
        }
        for h in held { drawHeld(h, ctx, now: now) }
    }

    /// How far a guide has unrolled: quickly at first, slowing to a stop at the far edge, never past it.
    private static func unrolled(_ t: Double) -> CGFloat {
        CGFloat(1 - pow(1 - min(max(t, 0), 1), 3))
    }

    /// How hard a guide quivers when it catches on something while still being dragged, against
    /// coming to rest: enough to feel the catch, not so much it shakes under the pointer.
    private static let caughtStrength: CGFloat = 0.45

    /// A guide's line from edge to edge. `reach` unrolls it from its start; a pluck makes it quiver
    /// as a string fixed at the edges does, most in its middle, dying away.
    private func drawThread(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, alpha: CGFloat, width: CGFloat, reach: CGFloat,
                            from0: Bool, pluck: Double?, strength: CGFloat = 1, vertical: Bool, dashed: Bool = false) {
        let vp = store.viewport
        let va = vp.toView(a), vb0 = vp.toView(b)
        let vb = CGPoint(x: va.x + (vb0.x - va.x) * reach, y: va.y + (vb0.y - va.y) * reach)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(width)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        let s = deviceScale
        func crisp(_ x: CGFloat) -> CGFloat { (x * s).rounded() / s + 0.5 / s }
        if let t = pluck, t >= 0, t < Self.ring {
            // A string fixed at both ends: ringing mostly at its first mode, swinging the middle
            // furthest, with a little of its second, which dies sooner, so it moves as a string
            // does rather than as a seesaw. A long one swings further than a short one.
            let reachOnScreen = hypot(vb0.x - va.x, vb0.y - va.y)
            let swing = Double(strength * min(max(reachOnScreen * 0.009, 4), 9.5))
            let first = swing * exp(-t / 0.24) * sin(2 * .pi * 8 * t)
            let second = swing * 0.28 * exp(-t / 0.12) * sin(2 * .pi * 17 * t + 0.6)
            let n = 48
            for i in 0...n {
                let u = CGFloat(i) / CGFloat(n)
                let off = CGFloat(first) * sin(.pi * u) + CGFloat(second) * sin(2 * .pi * u)
                let p = CGPoint(x: va.x + (vb.x - va.x) * u + (vertical ? off : 0), y: va.y + (vb.y - va.y) * u + (vertical ? 0 : off))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
        } else if vertical {
            ctx.move(to: CGPoint(x: crisp(va.x), y: va.y))
            ctx.addLine(to: CGPoint(x: crisp(vb.x), y: vb.y))
        } else {
            ctx.move(to: CGPoint(x: va.x, y: crisp(va.y)))
            ctx.addLine(to: CGPoint(x: vb.x, y: crisp(vb.y)))
        }
        ctx.strokePath()
    }

    /// A guide being dragged: on its artboard, with its distances to either edge as a draftsman
    /// dimensions a drawing, or, leaving, dashed and fading, offering to go.
    private func drawHeld(_ h: Held, _ ctx: CGContext, now: CFTimeInterval) {
        let vp = store.viewport
        guard let id = h.board, let board = store.node(id) else {
            // Over no artboard at all: just a line under the pointer, dashed.
            let p = h.pointer, o = 40 / zoom
            let a = h.vertical ? CGPoint(x: h.position, y: p.y - o) : CGPoint(x: p.x - o, y: h.position)
            let b = h.vertical ? CGPoint(x: h.position, y: p.y + o) : CGPoint(x: p.x + o, y: h.position)
            drawThread(ctx, from: a, to: b, alpha: 0.4, width: 1, reach: 1, from0: true, pluck: nil, vertical: h.vertical, dashed: true)
            return
        }
        let f = board.frame
        let g = Guideline(vertical: h.vertical, edge: .start, offset: h.position)
        var (a, b) = line(of: g, on: board)
        if h.leaving {
            // Off the artboard, it follows the pointer out, dashed.
            if h.vertical { a.x = h.pointer.x; b.x = h.pointer.x } else { a.y = h.pointer.y; b.y = h.pointer.y }
            drawThread(ctx, from: a, to: b, alpha: 0.38, width: 1, reach: 1, from0: true, pluck: nil, vertical: h.vertical, dashed: true)
            drawPill(String(localized: "Release to remove"), at: vp.toView(h.pointer) + CGPoint(x: 14, y: 14), ctx: ctx, solid: true, warning: true)
            return
        }
        // Unrolled from where the pointer brought it in, to the edges and not past them.
        let k = CGFloat(min(max(grow.value, 0), 1))
        let p = h.pointer
        let ca = h.vertical ? CGPoint(x: a.x, y: p.y + (a.y - p.y) * k) : CGPoint(x: p.x + (a.x - p.x) * k, y: a.y)
        let cb = h.vertical ? CGPoint(x: b.x, y: p.y + (b.y - p.y) * k) : CGPoint(x: p.x + (b.x - p.x) * k, y: b.y)
        if case .move = drag {} else {
            drawThread(ctx, from: ca, to: cb, alpha: 1, width: 1.25, reach: 1, from0: true, pluck: heldPluck.map { now - $0 }, strength: Self.caughtStrength, vertical: h.vertical)
        }
        // Its distances to both edges: solid toward the edge it keeps to, outlined toward the other.
        let length = h.vertical ? f.width : f.height
        let kept = Guideline.at(h.position, vertical: h.vertical, in: f.size).edge
        let start = h.vertical ? f.minX : f.minY
        let spans: [(lo: CGFloat, hi: CGFloat, solid: Bool)] = [(start, start + h.position, kept != .end), (start + h.position, start + length, kept != .start)]
            .filter { $0.1 - $0.0 > 0.5 }
        let numbers = spans.map { CanvasView.number($0.hi - $0.lo) }
        // On screen, along the dimension line, and across it.
        func along(_ v: CGFloat) -> CGFloat { h.vertical ? vp.toView(CGPoint(x: v, y: 0)).x : vp.toView(CGPoint(x: 0, y: v)).y }
        let sheet = vp.toView(f), pv = vp.toView(p)
        // The line runs beside the pointer, never under it: below a guide running down, right of
        // one running across, clear of the cursor and of the numbers on it; on the other side
        // near the artboard's far end.
        let clear = h.vertical ? 28 : (numbers.map(Self.pillWidth).max() ?? 30) / 2 + 16
        let here = h.vertical ? pv.y : pv.x
        let near = (h.vertical ? sheet.minY : sheet.minX) + 12, far = (h.vertical ? sheet.maxY : sheet.maxX) - 12
        var line = here + clear > far ? here - clear : here + clear
        line = min(max(line, near), max(far, near))
        // Never under the rulers, which are drawn over the canvas.
        let rulers = Helpers.shared.rulers ? Rulers.thickness : 0
        line = max(line, rulers + (h.vertical ? Self.pillHeight : numbers.map(Self.pillWidth).max() ?? 30) / 2 + 3)
        for (span, number) in zip(spans, numbers) {
            let a = along(span.lo), b = along(span.hi)
            let va = h.vertical ? CGPoint(x: a, y: line) : CGPoint(x: line, y: a)
            let vb = h.vertical ? CGPoint(x: b, y: line) : CGPoint(x: line, y: b)
            drawDimension(from: va, to: vb, vertical: h.vertical, ctx: ctx)
            // Too short to hold its number, the number goes outside, past the artboard's edge, as
            // a draftsman writes a small dimension.
            let size = h.vertical ? Self.pillWidth(number) : Self.pillHeight
            var c = (a + b) / 2
            if b - a < size + 8 { c = span.lo == start ? a - size / 2 - 6 : b + size / 2 + 6 }
            c = max(c, rulers + size / 2 + 3)
            drawPill(number, at: h.vertical ? CGPoint(x: c, y: line) : CGPoint(x: line, y: c), ctx: ctx, solid: span.solid, warning: false, centered: true)
        }
    }

    /// A dimension line between two points on screen, with a short slash across each end.
    private func drawDimension(from a: CGPoint, to b: CGPoint, vertical: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: a)
        ctx.addLine(to: b)
        for e in [a, b] {
            ctx.move(to: CGPoint(x: e.x - 3, y: e.y + 3))
            ctx.addLine(to: CGPoint(x: e.x + 3, y: e.y - 3))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let pillHeight: CGFloat = 18

    /// How wide a pill with these words is on screen.
    private static func pillWidth(_ text: String) -> CGFloat {
        ((text as NSString).size(withAttributes: [.font: pillFont]).width + 12).rounded()
    }

    private func drawPill(_ text: String, at p: CGPoint, ctx: CGContext, solid: Bool, warning: Bool, centered: Bool = false) {
        let ink = warning ? Theme.dynamicNS(0xB3402F, 0xE4705C) : CanvasInk.pencil
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.pillFont, .foregroundColor: solid ? NSColor.white : ink]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = Self.pillWidth(text), h = Self.pillHeight
        let pill = centered ? CGRect(x: (p.x - w / 2).rounded(), y: (p.y - h / 2).rounded(), width: w, height: h)
                            : CGRect(x: p.x.rounded(), y: p.y.rounded(), width: w, height: h)
        ctx.saveGState()
        let shape = CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        if solid {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: ink.withAlphaComponent(0.35).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(ink.cgColor)
            ctx.fillPath()
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil))
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: pill.minX + (w - size.width) / 2, y: pill.minY + (h - size.height) / 2), withAttributes: attrs)
    }
}
