import Foundation
import CoreGraphics

/// What a repeat grid's handles on a canvas need of it: the design and what is picked, where the
/// canvas is, the steps of the history, and somewhere to say what a drag measures.
@MainActor protocol GridHost: AnyObject {
    var doc: BezzleDocument { get }
    var selection: [UUID] { get }
    /// Whether the select tool is in hand with nothing else under way (no words being typed, no
    /// points edited, no picture placed, no shapes built), so it may work on a grid.
    var selectsFreely: Bool { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    func beginGesture()
    func endGesture(_ action: LocalizedStringResource)
    func cancelGesture()
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void)
    /// What a drag on a grid measures, said beside `box` (on the canvas); nil when it ends.
    func measure(_ what: GridMeasure?, _ box: CGRect)
}

/// What dragging a grid's handles says: how many cells, how wide a gap, or how far it is turned.
enum GridMeasure: Equatable {
    case cells(columns: Int, rows: Int)
    /// A gap, and whether the gaps across and down change together.
    case gap(CGFloat, both: Bool)
    /// Its turn, in degrees, −180…180.
    case angle(Double)
}

/// What the pointer shows over a grid's handles.
enum GridPointer: Equatable {
    /// Pulling or spacing the way an angle runs, in degrees clockwise.
    case resize(Double)
    /// Turning, at a corner whose way from the middle is an angle.
    case turn(Double)
}

/// A selected repeat grid on a canvas, shared by every Bezzle: the canvas hands it the pointer
/// and draws what `marks` says shows.
///
/// A handle on its right edge pulls out columns, one on its bottom edge rows, one at its corner
/// both at once: a cell comes when the pointer passes the middle of where it will be, its outline
/// showing more clearly the nearer the pointer gets. The gaps between the cells show under the
/// pointer and are dragged to space them, the cell held staying under it; with Shift, the gaps
/// across and down change together. Just outside a corner the pointer turns the grid as one, as
/// it turns any layer, by fifteen degrees with Shift. All of it goes the way the grid's rows run.
/// While a layer in a cell is selected, the same layer in every other cell is outlined: what is
/// done to it is done to them all.
final class GridHandles {
    private let host: GridHost
    var redraw: () -> Void = {}

    enum Part: Equatable {
        case columns, rows, both
        /// The gaps between columns, held by the one after column `after`; or between rows.
        case columnGap(after: Int)
        case rowGap(after: Int)
        /// Just outside a corner, given 0…1 along the grid's rows and down its columns.
        case turn(CGPoint)

        var isGap: Bool {
            switch self {
            case .columnGap, .rowGap: true
            default: false
            }
        }
    }

    /// A grid as it lies on the canvas, measured in its own upright space: from the first cell's
    /// top left corner, along its rows and down its columns.
    fileprivate struct Placed {
        let id: UUID
        let spec: RepeatGrid
        /// Where the first cell's top left corner is on the canvas.
        let origin: CGPoint
        /// Which way its rows run, in degrees clockwise.
        let angle: Double
        /// One cell's size, upright.
        let size: CGSize
        /// From one cell to the next, along a row and down a column.
        let step: CGSize

        func canvas(_ local: CGPoint) -> CGPoint { origin + Geometry.rotate(local, by: angle) }
        func local(_ p: CGPoint) -> CGPoint { Geometry.rotate(p - origin, by: -angle) }

        /// What all its cells cover.
        var cells: CGRect { room(columns: spec.columns, rows: spec.rows) }

        func room(columns: Int, rows: Int) -> CGRect {
            CGRect(x: 0, y: 0, width: CGFloat(columns - 1) * step.width + size.width, height: CGFloat(rows - 1) * step.height + size.height)
        }

        func slot(_ column: Int, _ row: Int) -> CGRect {
            CGRect(x: CGFloat(column) * step.width, y: CGFloat(row) * step.height, width: size.width, height: size.height)
        }

        /// A rectangle of its own space as the four corners it has on the canvas.
        func corners(_ r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(canvas)
        }

        /// The upright box on the canvas round a rectangle of its own space.
        func bounds(_ r: CGRect) -> CGRect {
            let points = corners(r)
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    private enum Drag {
        case count(Part, Placed)
        case gap(Part, Placed, start: CGPoint)
        /// Turning the grid as it was when the drag began, about its middle on the canvas, in its parent.
        case turn(Part, Placed, grid: Node, middle: CGPoint, pivot: CGPoint, start: CGFloat)
    }

    private var drag: Drag?
    private var hovered: Part?
    /// How near the pointer is to the next column and the next row, 0…1, while a handle is dragged.
    private var reach = CGPoint.zero

    init(host: GridHost) {
        self.host = host
    }

    var dragging: Bool { drag != nil }

    private var zoom: CGFloat { host.zoom }
    private func view(_ p: CGPoint) -> CGPoint { host.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { host.toCanvas(v) }

    /// The one grid selected, when the select tool is free to work on it.
    private var selected: Placed? {
        let selection = host.selection
        guard host.selectsFreely, selection.count == 1, let g = host.doc.node(selection[0]), g.isRepeatGrid, !g.locked else { return nil }
        return placed(g)
    }

    private func placed(_ g: Node) -> Placed? { Self.placed(g, in: host.doc) }

    fileprivate static func placed(_ g: Node, in doc: BezzleDocument) -> Placed? {
        guard let spec = g.grid, let layout = RepeatGrid.layout(of: g), let frame = doc.absoluteFrame(of: g.id) else { return nil }
        let first = g.children[layout.first]
        let upright = RepeatGrid.upright(first, angle: spec.turn)
        return Placed(id: g.id, spec: spec, origin: frame.origin + Geometry.rotate(upright.origin, by: spec.turn), angle: spec.turn,
                      size: upright.size, step: RepeatGrid.step(of: first, spec))
    }

    /// A grid's outline on screen, round its cells the way its rows run, in place of its frame's.
    func outline(of id: UUID) -> [CGPoint]? { host.doc.gridOutline(of: id)?.map(view) }

    // MARK: - Handles and gaps

    private func handles(_ g: Placed) -> [(Part, CGPoint)] {
        let r = g.cells
        let own: [(Part, CGPoint)] = [(.both, CGPoint(x: r.maxX, y: r.maxY)), (.columns, CGPoint(x: r.maxX, y: r.midY)), (.rows, CGPoint(x: r.midX, y: r.maxY))]
        return own.map { ($0.0, view(g.canvas($0.1))) }
    }

    /// How long the handle along an edge is on screen: shorter on a small grid, so it never
    /// reaches the corner's.
    private func length(_ part: Part, _ g: Placed) -> CGFloat {
        min(26, max(10, (part == .columns ? g.cells.height : g.cells.width) * zoom * 0.5 - 12))
    }

    private func handle(at v: CGPoint, _ g: Placed) -> Part? {
        for (part, p) in handles(g) {
            // Measured along the grid's rows and down its columns.
            let d = Geometry.rotate(v - p, by: -g.angle)
            switch part {
            case .both:
                if hypot(d.x, d.y) <= 9 { return part }
            case .columns:
                if abs(d.x) <= 7, abs(d.y) <= length(part, g) / 2 + 3 { return part }
            default:
                if abs(d.y) <= 7, abs(d.x) <= length(part, g) / 2 + 3 { return part }
            }
        }
        return nil
    }

    /// Just outside a corner, where the pointer turns the grid.
    private func turn(at v: CGPoint, _ g: Placed) -> Part? {
        let r = g.cells
        guard !r.contains(g.local(canvas(v))) else { return nil }
        for unit in [CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)] {
            let p = view(g.canvas(CGPoint(x: r.minX + r.width * unit.x, y: r.minY + r.height * unit.y)))
            let d = hypot(p.x - v.x, p.y - v.y)
            if d > 10 && d < 24 { return .turn(unit) }
        }
        return nil
    }

    /// The gap under the pointer, if it is in the grid between two cells. A gap too narrow to
    /// point at, or below nothing, is taken as a few points either side of where the cells meet.
    private func gap(at v: CGPoint, _ g: Placed) -> Part? {
        let p = g.local(canvas(v))
        guard g.cells.insetBy(dx: -1 / zoom, dy: -1 / zoom).contains(p) else { return nil }
        let slop = 4 / zoom
        func find(_ along: CGFloat, step: CGFloat, size: CGFloat, count: Int) -> (Int, CGFloat)? {
            guard count > 1, step > 0 else { return nil }
            let k = min(max(Int(((along - size) / step).rounded(.down)), 0), count - 2)
            let start = CGFloat(k) * step + size, end = CGFloat(k + 1) * step
            let middle = (start + end) / 2, half = max(abs(end - start) / 2, slop)
            let off = abs(along - middle)
            return off <= half ? (k, off / half) : nil
        }
        let across = find(p.x, step: g.step.width, size: g.size.width, count: g.spec.columns)
        let down = find(p.y, step: g.step.height, size: g.size.height, count: g.spec.rows)
        switch (across, down) {
        case let (a?, d?): return a.1 <= d.1 ? .columnGap(after: a.0) : .rowGap(after: d.0)
        case let (a?, nil): return .columnGap(after: a.0)
        case let (nil, d?): return .rowGap(after: d.0)
        default: return nil
        }
    }

    private func part(at v: CGPoint, _ g: Placed) -> Part? {
        handle(at: v, g) ?? gap(at: v, g) ?? turn(at: v, g)
    }

    /// Every gap one way, in the grid's own space.
    private func bands(_ part: Part, _ g: Placed) -> [CGRect] {
        let cells = g.cells, slop = 2 / zoom
        func band(_ start: CGFloat, _ end: CGFloat) -> (CGFloat, CGFloat) {
            let lo = min(start, end), hi = max(start, end)
            return hi - lo < slop * 2 ? ((lo + hi) / 2 - slop, slop * 2) : (lo, hi - lo)
        }
        switch part {
        case .columnGap:
            return (0..<max(g.spec.columns - 1, 0)).map { k in
                let (x, w) = band(CGFloat(k) * g.step.width + g.size.width, CGFloat(k + 1) * g.step.width)
                return CGRect(x: x, y: cells.minY, width: w, height: cells.height)
            }
        case .rowGap:
            return (0..<max(g.spec.rows - 1, 0)).map { k in
                let (y, h) = band(CGFloat(k) * g.step.height + g.size.height, CGFloat(k + 1) * g.step.height)
                return CGRect(x: cells.minX, y: y, width: cells.width, height: h)
            }
        default:
            return []
        }
    }

    // MARK: - The pointer

    /// A press with the select tool on a selected grid's handle, gap or corner, at a point on
    /// screen. False leaves it to the canvas.
    func down(at v: CGPoint) -> Bool {
        guard let g = selected, let part = part(at: v, g) else { return false }
        if case .turn = part {
            guard let grid = host.doc.node(g.id) else { return false }
            let middle = g.canvas(CGPoint(x: g.cells.midX, y: g.cells.midY)), p = canvas(v)
            host.beginGesture()
            drag = .turn(part, g, grid: grid, middle: middle, pivot: middle - host.doc.parentOrigin(of: g.id),
                         start: atan2(p.y - middle.y, p.x - middle.x))
        } else if part.isGap {
            host.beginGesture()
            drag = .gap(part, g, start: canvas(v))
        } else {
            host.beginGesture()
            drag = .count(part, g)
            reach = .zero
        }
        redraw()
        return true
    }

    func drag(to v: CGPoint, flags: PenFlags) {
        let p = canvas(v)
        switch drag {
        case .count(let part, let g):
            let own = g.local(p)
            var columns = g.spec.columns, rows = g.spec.rows
            // As many cells as the pointer has passed the middle of, and how near it is to the next.
            func count(_ along: CGFloat, step: CGFloat, size: CGFloat, gap: CGFloat) -> (Int, CGFloat) {
                guard step > 0 else { return (1, 0) }
                let n = RepeatGrid.clamped(Int(((along - size / 2) / step).rounded(.down)) + 1)
                let near = (along - (CGFloat(n) * step - gap)) / max(gap + size / 2, 1)
                return (n, n < RepeatGrid.counts.upperBound ? min(max(near, 0), 1) : 0)
            }
            reach = .zero
            if part != .rows { (columns, reach.x) = count(own.x, step: g.step.width, size: g.size.width, gap: g.spec.columnGap) }
            if part != .columns { (rows, reach.y) = count(own.y, step: g.step.height, size: g.size.height, gap: g.spec.rowGap) }
            if host.doc.node(g.id)?.grid.map({ $0.columns != columns || $0.rows != rows }) == true {
                host.edit("Repeat Grid") { doc in doc.update(g.id) { $0.grid?.columns = columns; $0.grid?.rows = rows } }
            }
            host.measure(.cells(columns: columns, rows: rows), g.bounds(g.room(columns: columns, rows: rows)))
        case .gap(let part, let g, let start):
            var spec = g.spec
            let both = flags.contains(.shift)
            let moved = g.local(p) - g.local(start)
            switch part {
            case .columnGap(let k):
                // The cell after the gap held stays under the pointer: every gap before it moves alike.
                let gap = max((g.spec.columnGap + moved.x / CGFloat(k + 1)).rounded(), 1 - g.size.width)
                spec.columnGap = gap
                if both { spec.rowGap = max(gap, 1 - g.size.height) }
            case .rowGap(let k):
                let gap = max((g.spec.rowGap + moved.y / CGFloat(k + 1)).rounded(), 1 - g.size.height)
                spec.rowGap = gap
                if both { spec.columnGap = max(gap, 1 - g.size.width) }
            default:
                return
            }
            if host.doc.node(g.id)?.grid != spec {
                host.edit("Change Gap") { doc in doc.update(g.id) { $0.grid = spec } }
            }
            let across: Bool = if case .columnGap = part { true } else { false }
            let shown = across ? spec.columnGap : spec.rowGap
            let now = Placed(id: g.id, spec: spec, origin: g.origin, angle: g.angle, size: g.size,
                             step: CGSize(width: g.size.width + spec.columnGap, height: g.size.height + spec.rowGap))
            host.measure(.gap(shown, both: both), now.bounds(now.cells))
        case .turn(_, let g, let grid, let middle, let pivot, let start):
            var delta = Double((atan2(p.y - middle.y, p.x - middle.x) - start) * 180 / .pi)
            if flags.contains(.shift) { delta = ((g.angle + delta) / 15).rounded() * 15 - g.angle }
            host.edit("Rotate") { doc in doc.update(g.id) { $0 = RepeatGrid.turned(grid, by: delta, about: pivot) } }
            host.measure(.angle(Geometry.normalized(g.angle + delta)), g.bounds(g.cells))
        case nil:
            return
        }
        redraw()
    }

    func up() {
        guard let d = drag else { return }
        drag = nil
        reach = .zero
        switch d {
        case .count: host.endGesture("Repeat Grid")
        case .gap: host.endGesture("Change Gap")
        case .turn: host.endGesture("Rotate")
        }
        host.measure(nil, .zero)
        redraw()
    }

    func cancel() {
        guard drag != nil else { return }
        drag = nil
        reach = .zero
        host.cancelGesture()
        host.measure(nil, .zero)
        redraw()
    }

    /// The pointer moving with nothing pressed, or leaving the canvas (nil); whether what it
    /// lights changed.
    @discardableResult func hover(_ v: CGPoint?) -> Bool {
        var part: Part?
        if let v, drag == nil, let g = selected { part = self.part(at: v, g) }
        guard part != hovered else { return false }
        hovered = part
        redraw()
        return true
    }

    /// What the pointer shows at a point on screen, if a grid's handle is under it or held.
    func pointer(at v: CGPoint) -> GridPointer? {
        let part: Part?, angle: Double
        switch drag {
        case .count(let p, let g): (part, angle) = (p, g.angle)
        case .gap(let p, let g, _): (part, angle) = (p, g.angle)
        case .turn(let p, let g, _, _, _, _): (part, angle) = (p, host.doc.node(g.id)?.grid?.turn ?? g.angle)
        case nil:
            guard let g = selected else { return nil }
            (part, angle) = (self.part(at: v, g), g.angle)
        }
        switch part {
        case .columns, .columnGap: return .resize(angle)
        case .rows, .rowGap: return .resize(angle + 90)
        case .both: return .resize(angle + 45)
        case .turn(let unit):
            // The corner's way from the middle: bottom right is 45°, as for any layer's corners.
            let corner: Double = unit.y == 1 ? (unit.x == 1 ? 45 : 135) : (unit.x == 0 ? 225 : 315)
            return .turn(corner + angle)
        case nil: return nil
        }
    }

    // MARK: - What shows

    /// What a canvas draws for grids now, on screen, in this order: the same layer in the other
    /// cells, the cells, the gaps lit, the cells to come, the handles.
    func marks() -> RepeatGridMarks {
        var marks = RepeatGridMarks()
        marks.copies = copies()
        guard let g = selected, g.cells.width * zoom >= 4, g.cells.height * zoom >= 4 else { return marks }
        // While it turns, only its outline shows: the rest would only spin round with it.
        if case .turn = drag { return marks }
        if g.spec.count > 1, g.spec.count <= 600, g.size.width * zoom >= 8, g.size.height * zoom >= 8 {
            for row in 0..<g.spec.rows {
                for column in 0..<g.spec.columns { marks.cells.append(screen(g.slot(column, row), g)) }
            }
        }
        if case .count = drag { marks.cellsActive = true }
        let lit: Part? = switch drag {
        case .gap(let p, _, _): p
        case .count, .turn: nil
        case nil: hovered.flatMap { $0.isGap ? $0 : nil }
        }
        if let lit {
            let across: Bool = if case .columnGap = lit { true } else { false }
            for band in bands(lit, g) {
                // Its two edges, along the cells either side.
                let edges = across ? [(CGPoint(x: band.minX, y: band.minY), CGPoint(x: band.minX, y: band.maxY)),
                                      (CGPoint(x: band.maxX, y: band.minY), CGPoint(x: band.maxX, y: band.maxY))]
                                   : [(CGPoint(x: band.minX, y: band.minY), CGPoint(x: band.maxX, y: band.minY)),
                                      (CGPoint(x: band.minX, y: band.maxY), CGPoint(x: band.maxX, y: band.maxY))]
                marks.gaps.append(RepeatGridMarks.Band(corners: screen(band, g), edges: edges.map { (view(g.canvas($0.0)), view(g.canvas($0.1))) }))
            }
        }
        if case .count = drag, reach != .zero {
            let columns = g.spec.columns, rows = g.spec.rows
            if reach.x > 0 { for row in 0..<rows { marks.ghosts.append(RepeatGridMarks.Ghost(corners: screen(g.slot(columns, row), g), near: reach.x)) } }
            if reach.y > 0 { for column in 0..<columns { marks.ghosts.append(RepeatGridMarks.Ghost(corners: screen(g.slot(column, rows), g), near: reach.y)) } }
            if reach.x > 0, reach.y > 0 { marks.ghosts.append(RepeatGridMarks.Ghost(corners: screen(g.slot(columns, rows), g), near: min(reach.x, reach.y))) }
        }
        for (part, p) in handles(g) {
            // A little bigger under the pointer and while held.
            let held: Bool = if case .count(let d, _) = drag { d == part } else { false }
            let grow: CGFloat = held || hovered == part ? 1.5 : 0
            let size: CGSize
            switch part {
            case .both:
                size = CGSize(width: 10 + grow * 2, height: 10 + grow * 2)
            case .columns, .rows:
                let long = length(part, g) + grow * 2, thick = 7 + grow
                size = part == .columns ? CGSize(width: thick, height: long) : CGSize(width: long, height: thick)
            default:
                continue
            }
            marks.handles.append(RepeatGridMarks.Handle(part: part, at: p, angle: g.angle, size: size))
        }
        return marks
    }

    /// A rectangle of the grid's own space, as its corners on screen.
    private func screen(_ r: CGRect, _ g: Placed) -> [CGPoint] { g.corners(r).map(view) }

    /// The same layer as the one selected, in every other cell of its grid, as corners on screen.
    private func copies() -> [[CGPoint]] {
        let doc = host.doc, selection = host.selection
        guard selection.count == 1, let id = selection.first, let grid = doc.grid(holding: id), grid.id != id,
              let spec = grid.grid, spec.count <= 600, let found = RepeatGrid.cell(of: id, in: grid, doc: doc) else { return [] }
        if case .count = drag { return [] }
        let first = id.mixed(RepeatGrid.key(found.cell))
        var out: [[CGPoint]] = []
        for cell in spec.cells where cell != found.cell {
            let other = first.mixed(RepeatGrid.key(cell))
            guard let n = doc.node(other), let frame = doc.absoluteFrame(of: other) else { continue }
            out.append(Geometry.corners(of: frame, rotation: n.rotation).map(view))
        }
        return out
    }
}

extension BezzleDocument {
    /// A repeat grid's outline on the canvas, round its cells the way its rows run, in place of its frame's.
    func gridOutline(of id: UUID) -> [CGPoint]? {
        guard let g = node(id), g.isRepeatGrid, let p = GridHandles.placed(g, in: self) else { return nil }
        return p.corners(p.cells)
    }
}

/// What a canvas draws for repeat grids, on screen (see `GridHandles.marks`).
struct RepeatGridMarks {
    /// A gap lit: its band, and its two edges along the cells either side.
    struct Band {
        let corners: [CGPoint]
        let edges: [(CGPoint, CGPoint)]
    }
    /// A cell to come, shown more clearly the nearer the pointer is to bringing it, 0…1.
    struct Ghost {
        let corners: [CGPoint]
        let near: CGFloat
    }
    /// A pull of pencil blue on the edge it pulls out, along it (with two grip lines across, as
    /// on a drawer), or a dot at the corner (`.both`): drawn upright about its middle `at`, then
    /// turned by `angle` degrees, the way the grid's rows run.
    struct Handle {
        let part: GridHandles.Part
        let at: CGPoint
        let angle: Double
        let size: CGSize
    }

    /// The same layer as the one selected, in every other cell of its grid: dashed.
    var copies: [[CGPoint]] = []
    /// Each cell's place, faintly dashed, so the grid reads as a grid; less faintly while cells are pulled out.
    var cells: [[CGPoint]] = []
    var cellsActive = false
    var gaps: [Band] = []
    var ghosts: [Ghost] = []
    var handles: [Handle] = []
}
