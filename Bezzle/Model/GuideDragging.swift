import Foundation
import CoreGraphics

/// Which part of the rulers a point is on: the top one, the left one, or the corner where they meet.
enum RulerPart: Equatable { case top, left, corner }

/// What dragging guides needs of a canvas: the design, where the canvas is, its rulers, which
/// drawing aids show, and the steps of the history.
@MainActor protocol GuideHost: AnyObject {
    var doc: BezzleDocument { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    /// The part of the canvas in sight.
    var visibleCanvasRect: CGRect { get }
    /// Whether the select tool is in hand.
    var selectsGuides: Bool { get }
    var isReadOnly: Bool { get }
    /// What lies on an artboard as it is seen: for a deck, the post in front.
    func seenLayers(of board: Node) -> [Node]
    func beginGesture()
    func endGesture(_ action: LocalizedStringResource)
    func cancelGesture()
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void)
    var guidesShown: Bool { get set }
    var gridsShown: Bool { get }
    var rulersShown: Bool { get }
    var guidesLocked: Bool { get }
    /// The part of the rulers a point on screen is on, if it is on them.
    func rulerPart(at v: CGPoint) -> RulerPart?
    /// The artboard the rulers measure.
    var rulerBoard: Node? { get }
    /// How thick the rulers are, on screen: none while they are hidden.
    var rulerThickness: CGFloat { get }
}

/// Guides on a canvas, shared by every Bezzle: the canvas hands it the pointer, and draws them
/// from what it says shows (the Mac with its springs: unrolling, quivering, a dimension line).
///
/// Each guide runs across its artboard from edge to edge. One is pulled out of a ruler, or put
/// down by a click on one, and dragged by its tab on the ruler, or by its line wherever no layer
/// lies under it; resting on it where one does lights up its tab. While it moves, it catches on
/// the artboard's edges and middle, on what lies on the artboard and on the layout grid, Shift
/// holding it to tens, Command (Ctrl) letting go of anything. Dragged off its artboard, or back
/// onto the ruler, it goes when let go. A click on a guide without a drag is a click on what lies
/// under it; with Option (Alt) a drag leaves a copy behind. Out of the corner come two at once.
final class GuideDragging {
    private let host: GuideHost
    var redraw: () -> Void = {}
    /// A press on a guide that did not become a drag, which the canvas takes as a click.
    var click: (CGPoint, PenFlags) -> Void = { _, _ in }
    /// A click on the rulers' corner: the menu of the drawing aids, at a point on screen.
    var cornerMenu: (CGPoint) -> Void = { _ in }
    /// Where the layer a press at a point on screen would take lies on the canvas, if one does.
    var under: (CGPoint) -> CGRect? = { _ in nil }
    /// What can be felt: a guide taken out, one catching on something, one coming away.
    var feel: (Feel) -> Void = { _ in }
    /// The time now, in seconds, for what moves.
    var now: () -> Double = { Date().timeIntervalSinceReferenceDate }
    /// A guide begins to come out of a ruler (`fresh`), or a copy of one: what shows it grows.
    var began: (_ fresh: Bool) -> Void = { _ in }

    enum Feel { case generic, alignment, levelChange }

    struct Ref: Hashable {
        let board: UUID
        let key: String
    }

    private enum Drag {
        /// A press on a ruler, not yet a drag: a click puts a guide where it was.
        case press(RulerPart, start: CGPoint)
        /// A guide coming out of a ruler, or a copy of one, on no artboard until it is let go.
        case new(vertical: Bool, from: Ref?)
        /// A guide on an artboard, moved, by its line or its tab.
        case move(Ref, vertical: Bool, grip: CGFloat, started: Bool, start: CGPoint, copy: Bool, flags: PenFlags)
        /// Two guides at once, out of the corner.
        case cross
    }

    /// Where a guide being dragged is, and what it is doing.
    struct Held {
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
    private(set) var held: [Held] = []
    private(set) var hovered: Ref?
    /// The guide the pointer rests on where a layer lies over it: the press is the layer's, and
    /// the guide's tab on the ruler lights up, where it is taken instead.
    private(set) var beckoning: Ref?
    private var caught: [CGFloat?] = []

    /// When guides came, were plucked or went, for the drawing to move them.
    private(set) var appearing: [Ref: Double] = [:]
    private(set) var plucks: [Ref: Double] = [:]
    private(set) var heldPluck: Double?
    struct Vanishing {
        var from: CGPoint
        var to: CGPoint
        var born: Double
    }
    private(set) var vanishing: [Vanishing] = []

    /// How long a guide takes to unroll across its artboard.
    static let unroll = 0.32

    init(host: GuideHost) {
        self.host = host
    }

    var dragging: Bool {
        switch drag {
        case nil, .press: false
        case .move(_, _, _, let started, _, _, _): started
        default: true
        }
    }

    var pressed: Bool { drag != nil }

    /// The guide being moved by its line or tab, once the drag has begun.
    var moving: Ref? { if case .move(let r, _, _, true, _, _, _) = drag { r } else { nil } }
    /// Whether a guide (or two) is coming out of a ruler or the corner, rather than being moved.
    var adding: Bool { switch drag { case .new, .cross: true; default: false } }
    /// Whether two are coming out of the corner.
    var crossing: Bool { if case .cross = drag { true } else { false } }
    /// Which way the guide coming out runs, if one is.
    var newVertical: Bool? { if case .new(let vertical, _) = drag { vertical } else { nil } }
    /// Which way the guide being moved runs, once the drag has begun.
    var movingVertical: Bool? { if case .move(_, let vertical, _, true, _, _, _) = drag { vertical } else { nil } }

    /// Forgets what has finished moving.
    func settle(unrollFor unroll: Double, ringFor ring: Double, fadeFor fade: Double) {
        let t = now()
        appearing = appearing.filter { t - $0.value < unroll }
        plucks = plucks.filter { t - $0.value < ring }
        vanishing = vanishing.filter { t - $0.born < fade }
    }

    private var zoom: CGFloat { host.zoom }
    private var shown: Bool { host.guidesShown }

    // MARK: - Finding guides

    /// The artboards whose guides are in sight, big enough on screen to be worked with.
    func boards() -> [Node] {
        let visible = host.visibleCanvasRect
        return host.doc.artboards.filter { !$0.hidden && $0.guides?.isEmpty == false && $0.frame.intersects(visible.insetBy(dx: -20, dy: -20))
            && min($0.frame.width, $0.frame.height) * zoom >= 24 }
    }

    /// A guide's line on the canvas, from edge to edge of its artboard and no further.
    func line(of g: Guideline, on board: Node) -> (CGPoint, CGPoint) {
        let f = board.frame, at = g.position(in: f.size)
        return g.vertical ? (CGPoint(x: f.minX + at, y: f.minY), CGPoint(x: f.minX + at, y: f.maxY))
                          : (CGPoint(x: f.minX, y: f.minY + at), CGPoint(x: f.maxX, y: f.minY + at))
    }

    private func onScreen(_ r: CGRect) -> CGRect {
        let a = host.toView(CGPoint(x: r.minX, y: r.minY)), b = host.toView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The guide whose line a point on screen is within a few points of, and whether a layer lies
    /// under the point, where the press is the layer's.
    private func nearest(at v: CGPoint) -> (ref: Ref, covered: Bool)? {
        guard shown else { return nil }
        for board in boards().reversed() {
            var best: (String, CGFloat)?
            for (key, g) in board.guides ?? [:] {
                let (a, b) = line(of: g, on: board)
                let va = host.toView(a), vb = host.toView(b)
                let off = g.vertical ? abs(v.x - va.x) : abs(v.y - va.y)
                let within = g.vertical ? (v.y >= va.y - 3 && v.y <= vb.y + 3) : (v.x >= va.x - 3 && v.x <= vb.x + 3)
                guard within, off <= 4, best.map({ off < $0.1 }) ?? true else { continue }
                best = (key, off)
            }
            if let best, let g = board.guides?[best.0] {
                return (Ref(board: board.id, key: best.0), onScreen(board.frame).contains(v) && covered(v, by: g, on: board))
            }
        }
        return nil
    }

    /// Whether a layer under a point keeps a guide's line from the pointer there: one the guide
    /// crosses, as a card it centres. One it runs along nearly from edge to edge of the artboard,
    /// as a picture or colour laid under the whole page, is the ground it is drawn on.
    private func covered(_ v: CGPoint, by g: Guideline, on board: Node) -> Bool {
        guard let f = under(v) else { return false }
        let b = board.frame
        let (run, from, to) = g.vertical ? (b.height, max(f.minY, b.minY), min(f.maxY, b.maxY))
                                         : (b.width, max(f.minX, b.minX), min(f.maxX, b.maxX))
        return to - from < run * Self.ground
    }

    /// How much of a guide's length a layer has to lie along to be ground for it.
    static let ground: CGFloat = 0.85

    /// The guide under a point on screen that a press there takes: within a few points of it,
    /// where no layer lies under the pointer.
    func guide(at v: CGPoint) -> Ref? {
        guard let n = nearest(at: v), !n.covered else { return nil }
        return n.ref
    }

    /// The guide whose tab on a ruler is under a point on screen.
    private func tab(at v: CGPoint, on part: RulerPart) -> Ref? {
        guard shown, let board = host.rulerBoard, part != .corner else { return nil }
        let across = part == .top
        let f = board.frame
        var best: (String, CGFloat)?
        for (key, g) in board.guides ?? [:] where g.vertical == across {
            let p = host.toView(CGPoint(x: f.minX + g.position(in: f.size), y: f.minY + g.position(in: f.size)))
            let off = abs(across ? v.x - p.x : v.y - p.y)
            if off <= 6, best.map({ off < $0.1 }) ?? true { best = (key, off) }
        }
        return best.map { Ref(board: board.id, key: $0.0) }
    }

    /// Whether a point on screen is on a guide's tab on the rulers.
    func onTab(_ v: CGPoint) -> Bool {
        guard let part = host.rulerPart(at: v) else { return false }
        return tab(at: v, on: part) != nil
    }

    /// Which way the guide runs whose tab a point on screen is on, if it is on one.
    func tabVertical(at v: CGPoint) -> Bool? {
        guard let part = host.rulerPart(at: v), let ref = tab(at: v, on: part) else { return nil }
        return host.doc.node(ref.board)?.guides?[ref.key]?.vertical
    }

    // MARK: - Pressing

    /// A press on a ruler, whatever the tool, `clicks` the count. False leaves it to the canvas.
    func rulerDown(at v: CGPoint, clicks: Int, flags: PenFlags) -> Bool {
        guard let part = host.rulerPart(at: v) else { return false }
        if clicks >= 2 { return true }
        if let ref = tab(at: v, on: part), !host.guidesLocked, let g = host.doc.node(ref.board)?.guides?[ref.key] {
            let at = position(of: g, on: ref.board)
            let p = host.toCanvas(v)
            drag = .move(ref, vertical: g.vertical, grip: (g.vertical ? p.x : p.y) - at, started: false, start: v, copy: false, flags: flags)
            return true
        }
        drag = .press(part, start: v)
        return true
    }

    /// A press with the select tool on a guide's line. False leaves it to the canvas.
    func down(at v: CGPoint, flags: PenFlags) -> Bool {
        guard host.selectsGuides, !host.guidesLocked, !host.isReadOnly, let ref = guide(at: v),
              let g = host.doc.node(ref.board)?.guides?[ref.key] else { return false }
        let at = position(of: g, on: ref.board), p = host.toCanvas(v)
        drag = .move(ref, vertical: g.vertical, grip: (g.vertical ? p.x : p.y) - at, started: false, start: v,
                     copy: flags.contains(.option), flags: flags)
        return true
    }

    /// A guide's place across its artboard, or down it, as the artboard is now.
    private func position(of g: Guideline, on board: UUID) -> CGFloat {
        guard let b = host.doc.node(board) else { return 0 }
        return (g.vertical ? b.frame.minX : b.frame.minY) + g.position(in: b.frame.size)
    }

    func drag(to v: CGPoint, flags: PenFlags) {
        switch drag {
        case .press(let part, let start):
            guard hypot(v.x - start.x, v.y - start.y) > 3, !host.isReadOnly else { return }
            // Out of the top ruler comes a guide across, out of the left one a guide down.
            switch part {
            case .top: drag = .new(vertical: false, from: nil)
            case .left: drag = .new(vertical: true, from: nil)
            case .corner: drag = .cross
            }
            began(true)
            caught = []
            feel(.generic)
            drag(to: v, flags: flags)
            return
        case .move(let ref, let vertical, let grip, let started, let start, let copy, let first):
            if !started {
                guard hypot(v.x - start.x, v.y - start.y) > 3 else { return }
                if copy {
                    drag = .new(vertical: vertical, from: ref)
                    began(false)
                    drag(to: v, flags: flags)
                    return
                }
                host.beginGesture()
                drag = .move(ref, vertical: vertical, grip: grip, started: true, start: start, copy: false, flags: first)
            }
            let p = host.toCanvas(v)
            var h = place(vertical: vertical, at: (vertical ? p.x : p.y) - grip, pointer: p, view: v, board: ref.board, except: ref.key, flags: flags)
            h.board = ref.board
            if !h.leaving {
                let at = h.position
                host.edit("Move Guide") { $0.moveGuide(ref.key, on: ref.board, to: at) }
            }
            note(h, slot: 0)
            held = [h]
        case .new(let vertical, let from):
            let p = host.toCanvas(v)
            let board = from?.board ?? host.doc.artboard(at: p)?.id ?? host.rulerBoard?.id
            let h = place(vertical: vertical, at: vertical ? p.x : p.y, pointer: p, view: v, board: board, except: nil, flags: flags)
            note(h, slot: 0)
            held = [h]
        case .cross:
            let p = host.toCanvas(v)
            let board = host.doc.artboard(at: p)?.id ?? host.rulerBoard?.id
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
                feel(.alignment)
                heldPluck = now()
            }
            caught[slot] = h.caught
        }
    }

    /// Where a guide dragged to `value` on the canvas settles on an artboard: caught on what is near,
    /// held to tens with Shift, or let go of anything with Command; and whether it is leaving.
    private func place(vertical: Bool, at value: CGFloat, pointer p: CGPoint, view v: CGPoint, board id: UUID?, except: String?,
                       flags: PenFlags) -> Held {
        guard let id, let board = host.doc.node(id) else {
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
        let t = host.rulerThickness
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
        for child in host.seenLayers(of: board) where !child.hidden {
            let b = Geometry.bounds(of: child, eye: host.doc.stage(of: board))
            out += vertical ? [b.minX, b.midX, b.maxX] : [b.minY, b.midY, b.maxY]
        }
        if host.gridsShown, let grid = board.layout {
            let edges = grid.edges(of: board)
            out += vertical ? edges.xs : edges.ys + edges.baselines
        }
        return out
    }

    func up(at v: CGPoint, flags: PenFlags) {
        defer {
            drag = nil
            held = []
            caught = []
            redraw()
        }
        switch drag {
        case .press(let part, _):
            if part == .corner {
                cornerMenu(v)
                return
            }
            // A click on a ruler puts a guide down there, running across the ruler.
            guard !host.isReadOnly, let board = host.rulerBoard else { return }
            let vertical = part == .top
            let p = host.toCanvas(v)
            let f = board.frame
            let at = ((vertical ? p.x - f.minX : p.y - f.minY)).rounded()
            guard at >= 0, at <= (vertical ? f.width : f.height) else { return }
            var key: String?
            host.edit("Add Guide") { key = $0.addGuide(at: at, vertical: vertical, to: board.id) }
            host.guidesShown = true
            if let key, host.doc.node(board.id)?.guides?[key] != nil {
                let ref = Ref(board: board.id, key: key), t = now()
                appearing[ref] = t
                // It quivers as it comes taut at the far edge.
                plucks[ref] = t + Self.unroll * 0.8
                feel(.generic)
            }
        case .move(let ref, _, _, let started, _, _, let first):
            guard started else {
                // A click on a guide is a click on what lies under it; on a tab, nothing.
                if host.rulerPart(at: v) == nil { click(v, first) }
                return
            }
            if let h = held.first, h.leaving {
                host.cancelGesture()
                if let b = host.doc.node(ref.board), let g = b.guides?[ref.key] { vanish(g, on: b, at: h.pointer) }
                removeGuide(ref)
                feel(.levelChange)
            } else {
                host.endGesture("Move Guide")
                plucks[ref] = now()
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
        host.edit(action) { doc in
            for h in kept {
                guard let id = h.board, let b = doc.node(id) else { continue }
                let key = Guideline.key(besides: (b.guides ?? [:]).keys)
                let g = Guideline.at(h.position, vertical: h.vertical, in: b.frame.size)
                doc.update(id) { $0.guides = ($0.guides ?? [:]).merging([key: g]) { _, new in new } }
                added.append(Ref(board: id, key: key))
            }
        }
        let t = now()
        for r in added { plucks[r] = t }
        host.guidesShown = true
    }

    func cancel() {
        guard drag != nil else { return }
        if case .move(_, _, _, true, _, _, _) = drag { host.cancelGesture() }
        drag = nil
        held = []
        redraw()
    }

    /// A guide taken away, shrinking to where the pointer let it go as it fades.
    private func vanish(_ g: Guideline, on board: Node, at p: CGPoint) {
        let (a, b) = line(of: g, on: board)
        vanishing.append(Vanishing(from: g.vertical ? CGPoint(x: p.x, y: a.y) : CGPoint(x: a.x, y: p.y),
                                   to: g.vertical ? CGPoint(x: p.x, y: b.y) : CGPoint(x: b.x, y: p.y), born: now()))
    }

    private func vanish(_ h: Held) {
        guard let id = h.board, let board = host.doc.node(id) else { return }
        let g = Guideline(vertical: h.vertical, edge: .start, offset: h.position)
        vanish(g, on: board, at: h.pointer)
    }

    // MARK: - Taking guides away

    func removeGuide(_ ref: Ref) {
        guard host.doc.node(ref.board)?.guides?[ref.key] != nil else { return }
        host.edit("Remove Guide") { $0.removeGuide(ref.key, from: ref.board) }
    }

    func removeGuides(from board: UUID) {
        guard host.doc.node(board)?.guides?.isEmpty == false else { return }
        host.edit("Remove Guides") { $0.removeGuides(from: board) }
    }

    /// The guide a right click at a point on screen is on, and how many its artboard has.
    func guideForMenu(at v: CGPoint) -> (ref: Ref, count: Int)? {
        guard let ref = guide(at: v) else { return nil }
        return (ref, host.doc.node(ref.board)?.guides?.count ?? 0)
    }

    // MARK: - The pointer at rest

    /// The pointer at rest at a point on screen, or nil off the canvas: what it lights. Whether
    /// that changed.
    @discardableResult
    func hover(_ v: CGPoint?) -> Bool {
        var ref: Ref?, through: Ref?
        if let v, drag == nil {
            if let part = host.rulerPart(at: v) {
                ref = tab(at: v, on: part)
            } else if host.selectsGuides, !host.guidesLocked, !host.isReadOnly, let n = nearest(at: v) {
                if n.covered { through = n.ref } else { ref = n.ref }
            }
        }
        // Its tab lights up only where there is one: on the rulers, measuring its artboard.
        if let t = through, !(host.rulersShown && host.rulerBoard?.id == t.board) { through = nil }
        guard ref != hovered || through != beckoning else { return false }
        hovered = ref
        beckoning = through
        redraw()
        return true
    }

    /// Which way the guide under the pointer runs, for its cursor, if the pointer is on one.
    var hoveredVertical: Bool? {
        guard let ref = hovered else { return nil }
        return host.doc.node(ref.board)?.guides?[ref.key]?.vertical
    }

    // MARK: - On the rulers

    /// A guide's tab on a ruler, on screen: across the top for a guide running down.
    struct Tab {
        var at: CGFloat
        var vertical: Bool
        var lit: Bool
        /// Pointed at where a layer lies over it: this is where to take it.
        var beckoned = false
        var ref: Ref?
    }

    /// The tabs of the guides of the artboard the rulers measure, and of a guide being dragged.
    func tabs() -> [Tab] {
        guard shown, let board = host.rulerBoard else { return [] }
        let f = board.frame
        var out: [Tab] = []
        for (key, g) in board.guides ?? [:] {
            let ref = Ref(board: board.id, key: key)
            if ref == moving, held.first?.leaving == true { continue }
            let p = host.toView(CGPoint(x: f.minX + g.position(in: f.size), y: f.minY + g.position(in: f.size)))
            out.append(Tab(at: g.vertical ? p.x : p.y, vertical: g.vertical, lit: ref == hovered || ref == moving, ref: ref))
        }
        if case .move = drag {} else {
            for h in held where !h.leaving && h.board == board.id {
                let p = host.toView(CGPoint(x: f.minX + h.position, y: f.minY + h.position))
                out.append(Tab(at: h.vertical ? p.x : p.y, vertical: h.vertical, lit: true))
            }
        }
        return out
    }
}
