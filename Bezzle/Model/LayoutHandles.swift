import Foundation
import CoreGraphics

/// What dragging a layout grid on a canvas needs of it: the design and what is picked, whether
/// the grid's card is open and grids show, where the canvas is, the steps of the history, and
/// somewhere to say what a drag measures.
@MainActor protocol LayoutHost: AnyObject {
    var doc: BezzleDocument { get }
    var selection: [UUID] { get }
    /// Whether the select tool is in hand with nothing else under way (no words being typed, no
    /// points edited, no shapes built).
    var selectsFreely: Bool { get }
    /// Whether the Layout Grid card is open.
    var layoutCardOpen: Bool { get }
    var gridsShown: Bool { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    func beginGesture()
    func endGesture(_ action: LocalizedStringResource)
    func cancelGesture()
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void)
    /// What a drag on a layout grid measures, said beside `box` (on the canvas); nil when it ends.
    func measure(_ what: LayoutMeasure?, _ box: CGRect)
}

/// What dragging a layout grid says: its gutter, its margin or its baselines' step.
enum LayoutMeasure: Equatable {
    case gutter(CGFloat)
    case margin(CGFloat)
    case baseline(CGFloat)
}

/// A layout grid's gutters, margins and baselines dragged on a canvas while its card is open,
/// shared by every Bezzle: the canvas hands it the pointer, and draws the part under the pointer
/// or held from what `lit` says (the Mac with its grids falling into place and sliding).
///
/// The gutters are held at any one of them: pulled away from its middle they all open, toward it
/// they close, as a gap pulled open from both sides at once. A margin follows the pointer. The
/// baselines are held by any one but the first, which stays: the step follows the one held.
final class LayoutHandles {
    private let host: LayoutHost
    var redraw: () -> Void = {}

    enum Part: Equatable {
        /// The gutters, held at one of them, whose middle is here on the artboard: pulled away from
        /// it they all open, toward it they close.
        case gutter(columns: Bool, middle: CGFloat)
        case margin(columns: Bool, end: Bool)
        /// The baselines, held by the one this many steps below the first.
        case baseline(Int)
    }

    private struct Drag {
        let part: Part
        let board: UUID
        let start: CGPoint
        let grid: LayoutGrid
    }

    private var drag: Drag?
    /// The part under the pointer, with nothing pressed.
    private(set) var hovered: Part?

    init(host: LayoutHost) {
        self.host = host
    }

    var dragging: Bool { drag != nil }
    /// The artboard whose grid is being dragged.
    var heldBoard: UUID? { drag?.board }

    private var zoom: CGFloat { host.zoom }

    /// The artboard whose grid the canvas can change: selected alone, with its card open.
    var editable: Node? {
        let selection = host.selection
        guard host.selectsFreely, selection.count == 1, host.layoutCardOpen, let b = host.doc.node(selection[0]), b.isArtboard,
              !b.hidden, let grid = b.layout, !grid.isEmpty, host.gridsShown else { return nil }
        return b
    }

    // MARK: - What shows

    /// A band of the part under the pointer or held, on the canvas: a gutter or a margin, hatched;
    /// or a baseline (no height), the one held firmly and the first, which stays, less so.
    struct Lit {
        let rect: CGRect
        let line: Bool
        let held: Bool
    }

    /// The part under the pointer, or being dragged, on the editable artboard, in its bands.
    func lit() -> [Lit] {
        guard let board = editable, let part = drag?.part ?? hovered, let grid = board.layout else { return [] }
        let o = board.frame.origin
        var out: [Lit] = []
        for (i, band) in bands(of: part, grid: grid, on: board).enumerated() {
            let r = band.offsetBy(dx: o.x, dy: o.y)
            if case .baseline(let k) = part {
                // The one held, firmly; its step marked off down to the first.
                let lines = grid.baselines(in: LayoutGrid.areas(of: board).first ?? .zero).count
                let held = i % max(lines, 1) == k
                guard held || i % max(lines, 1) == 0 else { continue }
                out.append(Lit(rect: r, line: true, held: held))
            } else {
                out.append(Lit(rect: r, line: false, held: false))
            }
        }
        return out
    }

    /// Every band a part is one of, on the artboard: all its gutters, both its margins, or all its baselines.
    private func bands(of part: Part, grid: LayoutGrid, on board: Node) -> [CGRect] {
        var out: [CGRect] = []
        for area in LayoutGrid.areas(of: board) {
            switch part {
            case .gutter(let columns, _):
                let rects = columns ? grid.columnRects(in: area) : grid.rowRects(in: area)
                for (a, b) in zip(rects, rects.dropFirst()) {
                    out.append(columns ? CGRect(x: a.maxX, y: area.minY, width: b.minX - a.maxX, height: area.height)
                                       : CGRect(x: area.minX, y: a.maxY, width: area.width, height: b.minY - a.maxY))
                }
            case .margin(let columns, _):
                let rects = columns ? grid.columnRects(in: area) : grid.rowRects(in: area)
                guard let first = rects.first, let last = rects.last else { continue }
                if columns {
                    out += [CGRect(x: area.minX, y: area.minY, width: first.minX - area.minX, height: area.height),
                            CGRect(x: last.maxX, y: area.minY, width: area.maxX - last.maxX, height: area.height)]
                } else {
                    out += [CGRect(x: area.minX, y: area.minY, width: area.width, height: first.minY - area.minY),
                            CGRect(x: area.minX, y: last.maxY, width: area.width, height: area.maxY - last.maxY)]
                }
            case .baseline:
                out += grid.baselines(in: area).map { CGRect(x: area.minX, y: $0, width: area.width, height: 0) }
            }
        }
        return out
    }

    // MARK: - The pointer

    /// The part of the editable grid under a point on screen.
    private func part(at v: CGPoint) -> Part? {
        guard let board = editable, let grid = board.layout else { return nil }
        let p = host.toCanvas(v) - board.frame.origin
        let slop = 4 / zoom
        for area in LayoutGrid.areas(of: board) where area.insetBy(dx: -slop, dy: -slop).contains(p) {
            for columns in [true, false] {
                let rects = columns ? grid.columnRects(in: area) : grid.rowRects(in: area)
                guard let first = rects.first, let last = rects.last else { continue }
                let along = columns ? p.x : p.y
                let lo = columns ? area.minX : area.minY, hi = columns ? area.maxX : area.maxY
                func inBand(_ a: CGFloat, _ b: CGFloat) -> Bool {
                    let half = max((b - a) / 2, 4 / zoom), mid = (a + b) / 2
                    return abs(along - mid) <= half
                }
                for (a, b) in zip(rects, rects.dropFirst()) {
                    let s = columns ? a.maxX : a.maxY, e = columns ? b.minX : b.minY
                    if inBand(s, e) { return .gutter(columns: columns, middle: (s + e) / 2) }
                }
                let fs = columns ? first.minX : first.minY, le = columns ? last.maxX : last.maxY
                if along >= lo, along <= fs + 2 / zoom, fs - lo >= 0 { return .margin(columns: columns, end: false) }
                if along <= hi, along >= le - 2 / zoom, hi - le >= 0 { return .margin(columns: columns, end: true) }
            }
            // Off the gutters and margins, right on a baseline, when they are far enough apart to point at one.
            if let base = grid.baseline, base.step * zoom >= 9 {
                for (k, y) in grid.baselines(in: area).enumerated() where k > 0 && abs(p.y - y) <= 2 / zoom {
                    return .baseline(k)
                }
            }
        }
        return nil
    }

    /// A press at a point on screen on the editable grid's gutters, margins or baselines; false
    /// leaves it to the canvas.
    func down(at v: CGPoint) -> Bool {
        guard let board = editable, let grid = board.layout, let part = part(at: v) else { return false }
        host.beginGesture()
        drag = Drag(part: part, board: board.id, start: host.toCanvas(v), grid: grid)
        redraw()
        return true
    }

    func drag(to v: CGPoint) {
        guard let d = drag, let board = host.doc.node(d.board) else { return }
        let p = host.toCanvas(v)
        let moved = p - d.start
        var grid = d.grid
        let said: LayoutMeasure
        switch d.part {
        case .gutter(let columns, let middle):
            // Opened by as much again as the pointer has gone further from its middle, as a gap
            // pulled open from both sides at once.
            let o = columns ? board.frame.minX : board.frame.minY
            let now = (columns ? p.x : p.y) - o, then = (columns ? d.start.x : d.start.y) - o
            let along = abs(now - middle) - abs(then - middle)
            if columns {
                grid.columns?.gutter = max(((d.grid.columns?.gutter ?? 0) + along * 2).rounded(), 0)
                said = .gutter(grid.columns?.gutter ?? 0)
            } else {
                grid.rows?.gutter = max(((d.grid.rows?.gutter ?? 0) + along * 2).rounded(), 0)
                said = .gutter(grid.rows?.gutter ?? 0)
            }
        case .margin(let columns, let end):
            let along = (columns ? moved.x : moved.y) * (end ? -1 : 1)
            if columns {
                grid.columns?.margin = max(((d.grid.columns?.margin ?? 0) + along).rounded(), 0)
                said = .margin(grid.columns?.margin ?? 0)
            } else {
                grid.rows?.margin = max(((d.grid.rows?.margin ?? 0) + along).rounded(), 0)
                said = .margin(grid.rows?.margin ?? 0)
            }
        case .baseline(let k):
            guard let base = d.grid.baseline else { return }
            let area = LayoutGrid.areas(of: board).first ?? .zero
            let y = p.y - board.frame.minY - area.minY
            let firstLine = base.offset.truncatingRemainder(dividingBy: base.step)
            let step = ((y - firstLine) / CGFloat(k) * 2).rounded() / 2
            grid.baseline?.step = min(max(step, LayoutGrid.Baseline.steps.lowerBound), LayoutGrid.Baseline.steps.upperBound)
            said = .baseline(grid.baseline?.step ?? 0)
        }
        if host.doc.node(d.board)?.layout != grid {
            let id = d.board, now = grid
            host.edit("Change Layout Grid") { $0.changeLayout(of: id) { $0 = now } }
        }
        host.measure(said, board.frame)
        redraw()
    }

    func up() {
        guard drag != nil else { return }
        drag = nil
        host.endGesture("Change Layout Grid")
        host.measure(nil, .zero)
        redraw()
    }

    func cancel() {
        guard drag != nil else { return }
        drag = nil
        host.cancelGesture()
        host.measure(nil, .zero)
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil); whether what it
    /// lights changed.
    @discardableResult func hover(_ v: CGPoint?) -> Bool {
        let now = v.flatMap { drag == nil ? part(at: $0) : nil }
        guard now != hovered else { return false }
        hovered = now
        redraw()
        return true
    }

    /// Whether the pointer, at a point on screen, shows it moves across (columns) or up and down:
    /// nil when no part of a grid is under it or held.
    func pointer(at v: CGPoint) -> Bool? {
        guard let part = drag?.part ?? part(at: v) else { return nil }
        switch part {
        case .gutter(let columns, _), .margin(let columns, _): return columns
        case .baseline: return false
        }
    }
}

extension Node {
    /// The columns of this artboard's layout grid a box (on the canvas) overlaps, by their place
    /// among all its columns, and how many it spans when its edges lie on theirs.
    func columnSpan(of box: CGRect) -> (lit: Set<Int>, exact: Int?)? {
        guard let grid = layout, grid.columns != nil else { return nil }
        let columns = LayoutGrid.areas(of: self).flatMap { grid.columnRects(in: $0) }
        let r = box.offsetBy(dx: -frame.minX, dy: -frame.minY)
        var lit = Set<Int>()
        var starts: Int?, ends: Int?
        for (i, c) in columns.enumerated() {
            if min(r.maxX, c.maxX) - max(r.minX, c.minX) > 0.5 { lit.insert(i) }
            if abs(r.minX - c.minX) < 0.5 { starts = i }
            if abs(r.maxX - c.maxX) < 0.5 { ends = i }
        }
        let exact = starts.flatMap { s in ends.flatMap { e in e >= s ? e - s + 1 : nil } }
        return (lit, exact)
    }
}
