import AppKit

/// Layout grids on the canvas: columns and rows washed in the red of a ruled margin, and baselines
/// in the pale blue of lined paper, over each artboard that has them. At rest they stay faint; they
/// come up while something on the artboard is moved, resized or drawn, and the columns it spans
/// light up, with how many when it spans them exactly. A new grid falls into place from the
/// artboard's top, its middle columns first; changed, its columns slide to where they go, one
/// splitting into two as more come and two closing into one as fewer do. While its card is open,
/// a grid's gutters, margins and baselines are dragged on the canvas itself.
final class LayoutTool {
    private let store: DocumentStore
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

    /// One band as it moves from where it was to where it goes, fading out if it goes nowhere.
    private struct Piece {
        var from: CGRect
        var to: CGRect
        var stays: Bool
    }

    /// What an artboard's grid looks like just now on the canvas, in the artboard's coordinates.
    private struct Look {
        var columns: [CGRect] = []
        var rows: [CGRect] = []
        var columnPieces: [Piece] = []
        var rowPieces: [Piece] = []
        var morph = DeckTool.Spring(1)
        var lines: [CGFloat] = []
        var size: CGSize = .zero
        /// When it came, and when it began to go.
        var came: CFTimeInterval?
        var went: CFTimeInterval?
        var attention = DeckTool.Spring(0)
        var everShown = false
    }

    private var looks: [UUID: Look] = [:]
    private var drag: Drag?
    private var hovered: Part?
    private var last: CFTimeInterval?
    private var deviceScale: CGFloat = 2
    /// The canvas on screen, which nothing is drawn beyond.
    private var view = CGRect.infinite

    private static let fall = 0.46
    private static let fold = 0.26

    init(store: DocumentStore) {
        self.store = store
    }

    var dragging: Bool { drag != nil }

    var isAnimating: Bool {
        let now = CACurrentMediaTime()
        return looks.values.contains { l in
            l.morph.isMoving || l.attention.isMoving || l.came.map { now - $0 < Self.fall + 0.4 } ?? false || l.went != nil
        }
    }

    private var zoom: CGFloat { store.viewport.zoom }

    // MARK: - What shows

    /// The artboards in sight with a grid to show, as the canvas shows them, preview and all.
    private func boards(_ doc: BezzleDocument) -> [Node] {
        let visible = store.visibleCanvasRect.insetBy(dx: -40, dy: -40)
        return doc.artboards.filter { !$0.hidden && $0.frame.intersects(visible) && min($0.frame.width, $0.frame.height) * zoom >= 16 }
    }

    /// Whether an artboard's grid is being worked with: its card open, something on it being changed,
    /// a grid offered for it, or one of its parts under the pointer.
    private func active(_ board: Node) -> Bool {
        if store.selection == [board.id], store.openAspect == .layout || store.pointedAspect == .layout { return true }
        if store.preview?.ids.contains(board.id) == true { return true }
        if drag?.board == board.id || (hovered != nil && editable?.id == board.id) { return true }
        if store.inGesture, let first = store.selection.first, first != board.id, store.doc.artboard(of: first)?.id == board.id { return true }
        return false
    }

    /// The artboard whose grid the canvas can change: selected alone, with its card open.
    private var editable: Node? {
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.building == nil,
              store.selection.count == 1, store.openAspect == .layout, let b = store.node(store.selection[0]), b.isArtboard,
              !b.hidden, let grid = b.layout, !grid.isEmpty, Helpers.shared.grids else { return nil }
        return b
    }

    // MARK: - Motion

    /// Brings each artboard's look up to date with its grid, starting what moves.
    private func update(_ doc: BezzleDocument, now: CFTimeInterval, dt: Double) {
        let showing = Helpers.shared.grids
        var seen = Set<UUID>()
        for board in boards(doc) {
            seen.insert(board.id)
            var look = looks[board.id] ?? Look()
            let grid = showing ? board.layout : nil
            let areas = LayoutGrid.areas(of: board)
            let columns = grid.map { g in areas.flatMap { g.columnRects(in: $0) } } ?? []
            let rows = grid.map { g in areas.flatMap { g.rowRects(in: $0) } } ?? []
            let lines = grid.map { g in areas.first.map { g.baselines(in: $0) } ?? [] } ?? []
            let empty = columns.isEmpty && rows.isEmpty && lines.isEmpty
            let wasEmpty = look.columns.isEmpty && look.rows.isEmpty && look.lines.isEmpty
            if empty {
                if !wasEmpty, look.went == nil { look.went = now }
            } else {
                look.went = nil
                if wasEmpty || !look.everShown {
                    // It falls into place, unless it was in sight before the canvas was.
                    look.came = looks[board.id] == nil && last == nil ? nil : now
                    look.columnPieces = columns.map { Piece(from: $0, to: $0, stays: true) }
                    look.rowPieces = rows.map { Piece(from: $0, to: $0, stays: true) }
                    look.morph = DeckTool.Spring(1)
                } else if columns != look.columns || rows != look.rows {
                    let t = CGFloat(look.morph.value)
                    look.columnPieces = Self.pieces(from: Self.shown(look.columnPieces, t), to: columns, columns: look.columns != columns)
                    look.rowPieces = Self.pieces(from: Self.shown(look.rowPieces, t), to: rows, columns: look.rows != rows)
                    look.morph = DeckTool.Spring(0)
                    look.morph.target = 1
                }
                look.columns = columns
                look.rows = rows
                look.lines = lines
                look.size = board.frame.size
                look.everShown = true
            }
            look.attention.target = active(board) ? 1 : 0
            look.attention.step(dt, stiffness: 260, damping: 28)
            look.morph.step(dt, stiffness: 340, damping: 24)
            if let went = look.went, now - went > Self.fold {
                look = Look()
                look.everShown = true
            }
            looks[board.id] = look
        }
        // Out of sight, they are forgotten, and come back without falling into place.
        for id in looks.keys where !seen.contains(id) { looks[id] = nil }
    }

    /// The bands as they show partway through a change.
    private static func shown(_ pieces: [Piece], _ t: CGFloat) -> [CGRect] {
        pieces.filter(\.stays).map { mix($0.from, $0.to, t) }
    }

    /// How bands go from one layout to the next: each new one out of the old one at the same place
    /// along, so one splits into two as more come; each old one that none comes out of closing into
    /// the new one at its place, fading as it does.
    private static func pieces(from old: [CGRect], to new: [CGRect], columns changed: Bool) -> [Piece] {
        guard !old.isEmpty else { return new.map { Piece(from: $0, to: $0, stays: true) } }
        guard !new.isEmpty else { return [] }
        let n = old.count, m = new.count
        var out: [Piece] = []
        var used = Set<Int>()
        for (i, r) in new.enumerated() {
            let j = min(n - 1, i * n / m)
            used.insert(j)
            out.append(Piece(from: old[j], to: r, stays: true))
        }
        for (j, r) in old.enumerated() where !used.contains(j) {
            out.append(Piece(from: r, to: new[min(m - 1, j * m / n)], stays: false))
        }
        return out
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: max(a.width + (b.width - a.width) * t, 0), height: max(a.height + (b.height - a.height) * t, 0))
    }

    private static func ease(_ t: Double) -> CGFloat {
        let t = min(max(t, 0), 1)
        let c1 = 1.25, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2))
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        deviceScale = scale
        view = bounds
        let now = CACurrentMediaTime()
        let dt = min(now - (last ?? now), 1.0 / 30)
        let doc = store.shownDoc
        update(doc, now: now, dt: dt)
        last = now
        for board in boards(doc) {
            guard let look = looks[board.id], look.everShown, !(look.columns.isEmpty && look.rows.isEmpty && look.lines.isEmpty) else { continue }
            draw(look, on: board, ctx, now: now)
        }
    }

    private func draw(_ look: Look, on board: Node, _ ctx: CGContext, now: CFTimeInterval) {
        let vp = store.viewport, o = board.frame.origin
        let attention = CGFloat(min(max(look.attention.value, 0), 1))
        let t = CGFloat(look.morph.value)
        // Falling in from the top, or folding back up as it goes.
        let leaving = look.went.map { 1 - Self.ease((now - $0) / Self.fold) } ?? 1
        let came = look.came.map { now - $0 }
        func fallen(_ i: Int, of count: Int) -> CGFloat {
            guard let came else { return leaving }
            let middle = CGFloat(count - 1) / 2
            let wait = Double(abs(CGFloat(i) - middle)) * 0.035
            return Self.ease((came - wait) / Self.fall) * leaving
        }
        let sheet = vp.toView(board.frame).intersection(view)
        guard !sheet.isNull else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: sheet)
        let s = deviceScale
        func px(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s + 0.5 / s }

        // What is being moved or resized on it, to light the columns it spans.
        let span = spanned(on: board)

        let wash = 0.04 + 0.035 * attention, edge = 0.12 + 0.2 * attention
        let red = CanvasInk.column
        let columnPieces = look.columnPieces
        for (i, piece) in columnPieces.enumerated() {
            var r = Self.mix(piece.from, piece.to, t).offsetBy(dx: o.x, dy: o.y)
            let k = fallen(i, of: columnPieces.count)
            r.size.height *= max(k, 0)
            guard r.width * zoom >= 0.5, r.height > 0 else { continue }
            let alpha: CGFloat = piece.stays ? 1 : max(1 - t, 0)
            let lit = span?.lit.contains(i) == true
            let v = vp.toView(r)
            ctx.setFillColor(red.withAlphaComponent((wash + (lit ? 0.07 : 0)) * alpha).cgColor)
            ctx.fill(v)
            ctx.setFillColor(red.withAlphaComponent((edge + (lit ? 0.2 : 0)) * alpha).cgColor)
            ctx.fill(CGRect(x: px(v.minX) - 0.5 / s, y: v.minY, width: 1 / s, height: v.height))
            ctx.fill(CGRect(x: px(v.maxX) - 0.5 / s, y: v.minY, width: 1 / s, height: v.height))
        }
        let rowPieces = look.rowPieces
        for (i, piece) in rowPieces.enumerated() {
            var r = Self.mix(piece.from, piece.to, t).offsetBy(dx: o.x, dy: o.y)
            let k = fallen(i, of: rowPieces.count)
            r.size.width *= max(k, 0)
            guard r.height * zoom >= 0.5, r.width > 0 else { continue }
            let alpha: CGFloat = piece.stays ? 1 : max(1 - t, 0)
            let v = vp.toView(r)
            ctx.setFillColor(red.withAlphaComponent(wash * 0.8 * alpha).cgColor)
            ctx.fill(v)
            ctx.setFillColor(red.withAlphaComponent(edge * alpha).cgColor)
            ctx.fill(CGRect(x: v.minX, y: px(v.minY) - 0.5 / s, width: v.width, height: 1 / s))
            ctx.fill(CGRect(x: v.minX, y: px(v.maxY) - 0.5 / s, width: v.width, height: 1 / s))
        }
        // The baselines, fading as they crowd together zooming out, and running down the artboard
        // one after another as they come.
        if let grid = board.layout, let base = grid.baseline, Helpers.shared.grids || look.went != nil {
            let onScreen = base.step * zoom
            let crowd = min(max((onScreen - 2.5) / 5, 0), 1)
            if crowd > 0.01 {
                let blue = CanvasInk.baseline
                for area in LayoutGrid.areas(of: board) {
                    let lines = grid.baselines(in: area)
                    for (k, y) in lines.enumerated() {
                        var a = (0.14 + 0.14 * attention) * crowd * leaving
                        if let came { a *= min(max(CGFloat((came - Double(k) * 0.006) / 0.18), 0), 1) }
                        guard a > 0.005 else { continue }
                        let vy = px(vp.toView(CGPoint(x: 0, y: o.y + y)).y)
                        let x0 = vp.toView(CGPoint(x: o.x + area.minX, y: 0)).x, x1 = vp.toView(CGPoint(x: o.x + area.maxX, y: 0)).x
                        ctx.setFillColor(blue.withAlphaComponent(a).cgColor)
                        ctx.fill(CGRect(x: x0, y: vy - 0.5 / s, width: x1 - x0, height: 1 / s))
                    }
                }
            }
        }
        // Each column's number along the top while the grid is worked on.
        if editable?.id == board.id, attention > 0.05 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                                                        .foregroundColor: red.withAlphaComponent(0.85 * attention)]
            let perArea = board.layout?.columns?.count ?? 0
            for (i, r) in look.columns.enumerated() {
                let v = vp.toView(r.offsetBy(dx: o.x, dy: o.y))
                guard v.width >= 14 else { continue }
                let text = "\(perArea > 0 ? i % perArea + 1 : i + 1)" as NSString
                let w = text.size(withAttributes: attrs).width
                text.draw(at: CGPoint(x: v.midX - w / 2, y: v.minY + 5), withAttributes: attrs)
            }
        }
        ctx.resetClip()
        ctx.clip(to: view)
        if let span, let count = span.exact, store.inGesture { drawSpan(count, over: span.box, ctx) }
        if let editable, editable.id == board.id { drawHover(board, ctx) }
    }

    /// The columns what is being changed on an artboard overlaps, by their place among all its
    /// columns, and how many it spans when its edges lie on theirs.
    private func spanned(on board: Node) -> (lit: Set<Int>, exact: Int?, box: CGRect)? {
        guard store.inGesture, Helpers.shared.grids, board.layout?.columns != nil, let first = store.selection.first, first != board.id,
              store.doc.artboard(of: first)?.id == board.id, let bounds = store.selectionBounds, let look = looks[board.id] else { return nil }
        let r = bounds.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
        var lit = Set<Int>()
        var starts: Int?, ends: Int?
        for (i, c) in look.columns.enumerated() {
            if min(r.maxX, c.maxX) - max(r.minX, c.minX) > 0.5 { lit.insert(i) }
            if abs(r.minX - c.minX) < 0.5 { starts = i }
            if abs(r.maxX - c.maxX) < 0.5 { ends = i }
        }
        let exact = starts.flatMap { s in ends.flatMap { e in e >= s ? e - s + 1 : nil } }
        return (lit, exact, bounds)
    }

    /// How many columns something spans exactly, in a red pill over it.
    private func drawSpan(_ count: Int, over box: CGRect, _ ctx: CGContext) {
        let r = store.viewport.toView(box)
        let text = (count == 1 ? String(localized: "1 column") : String(localized: "\(count) columns")) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let pill = CGRect(x: (r.midX - size.width / 2 - 7).rounded(), y: (r.minY - 26).rounded(), width: (size.width + 14).rounded(), height: 18)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CanvasInk.column.withAlphaComponent(0.4).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.setFillColor(CanvasInk.column.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        text.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (18 - size.height) / 2), withAttributes: attrs)
    }

    /// The part under the pointer, or being dragged, lit up in its band.
    private func drawHover(_ board: Node, _ ctx: CGContext) {
        guard let part = drag?.part ?? hovered, let grid = board.layout else { return }
        let vp = store.viewport, o = board.frame.origin
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let red = CanvasInk.column
        for (i, band) in bands(of: part, grid: grid, on: board).enumerated() {
            let v = vp.toView(band.offsetBy(dx: o.x, dy: o.y))
            if case .baseline(let k) = part {
                // The one held, firmly; its step marked off down to the first.
                let lines = grid.baselines(in: LayoutGrid.areas(of: board).first ?? .zero).count
                let held = i % max(lines, 1) == k
                guard held || i % max(lines, 1) == 0 else { continue }
                ctx.setFillColor(CanvasInk.baseline.withAlphaComponent(held ? 0.95 : 0.6).cgColor)
                ctx.fill(CGRect(x: v.minX, y: v.midY - 0.75, width: v.width, height: 1.5))
                continue
            }
            ctx.saveGState()
            ctx.clip(to: v)
            ctx.setStrokeColor(red.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1 / deviceScale)
            // Hatched, as the gaps between layers are when they line up.
            var x = v.minX - v.height
            while x < v.maxX {
                ctx.move(to: CGPoint(x: x, y: v.maxY))
                ctx.addLine(to: CGPoint(x: x + v.height, y: v.minY))
                x += 4
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setFillColor(red.withAlphaComponent(0.14).cgColor)
            ctx.fill(v)
        }
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
        let p = store.viewport.toCanvas(v) - board.frame.origin
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

    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard let board = editable, let grid = board.layout, let part = part(at: v) else { return false }
        store.beginGesture()
        drag = Drag(part: part, board: board.id, start: store.viewport.toCanvas(v), grid: grid)
        redraw()
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let d = drag, let board = store.node(d.board) else { return }
        let p = store.viewport.toCanvas(v)
        let moved = p - d.start
        var grid = d.grid
        let said: String
        switch d.part {
        case .gutter(let columns, let middle):
            // Opened by as much again as the pointer has gone further from its middle, as a gap
            // pulled open from both sides at once.
            let o = columns ? board.frame.minX : board.frame.minY
            let now = (columns ? p.x : p.y) - o, then = (columns ? d.start.x : d.start.y) - o
            let along = abs(now - middle) - abs(then - middle)
            _ = moved
            if columns {
                grid.columns?.gutter = max(((d.grid.columns?.gutter ?? 0) + along * 2).rounded(), 0)
                said = String(localized: "Gutter \(CanvasView.number(grid.columns?.gutter ?? 0))")
            } else {
                grid.rows?.gutter = max(((d.grid.rows?.gutter ?? 0) + along * 2).rounded(), 0)
                said = String(localized: "Gutter \(CanvasView.number(grid.rows?.gutter ?? 0))")
            }
        case .margin(let columns, let end):
            let along = (columns ? moved.x : moved.y) * (end ? -1 : 1)
            if columns {
                grid.columns?.margin = max(((d.grid.columns?.margin ?? 0) + along).rounded(), 0)
                said = String(localized: "Margin \(CanvasView.number(grid.columns?.margin ?? 0))")
            } else {
                grid.rows?.margin = max(((d.grid.rows?.margin ?? 0) + along).rounded(), 0)
                said = String(localized: "Margin \(CanvasView.number(grid.rows?.margin ?? 0))")
            }
        case .baseline(let k):
            guard let base = d.grid.baseline else { return }
            let area = LayoutGrid.areas(of: board).first ?? .zero
            let y = p.y - board.frame.minY - area.minY
            let firstLine = base.offset.truncatingRemainder(dividingBy: base.step)
            let step = ((y - firstLine) / CGFloat(k) * 2).rounded() / 2
            grid.baseline?.step = min(max(step, LayoutGrid.Baseline.steps.lowerBound), LayoutGrid.Baseline.steps.upperBound)
            said = String(localized: "Baseline \(CanvasView.number(grid.baseline?.step ?? 0))")
        }
        if store.node(d.board)?.layout != grid {
            store.changeLayout(of: d.board, "Change Layout Grid") { $0 = grid }
        }
        store.measurement = (said, board.frame)
        redraw()
    }

    func up() {
        guard drag != nil else { return }
        drag = nil
        store.endGesture("Change Layout Grid")
        store.measurement = nil
        redraw()
    }

    func cancel() {
        guard drag != nil else { return }
        drag = nil
        store.cancelGesture()
        store.measurement = nil
        redraw()
    }

    func hover(_ v: CGPoint?) {
        let now = v.flatMap { drag == nil ? part(at: $0) : nil }
        if now != hovered {
            hovered = now
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        guard let part = drag?.part ?? part(at: v) else { return nil }
        switch part {
        case .gutter(let columns, _), .margin(let columns, _): return columns ? .resizeLeftRight : .resizeUpDown
        case .baseline: return .resizeUpDown
        }
    }
}
