import AppKit

/// Layout grids on the canvas: columns and rows washed in the red of a ruled margin, and baselines
/// in the pale blue of lined paper, over each artboard that has them. At rest they stay faint; they
/// come up while something on the artboard is moved, resized or drawn, and the columns it spans
/// light up, with how many when it spans them exactly. A new grid falls into place from the
/// artboard's top, its middle columns first; changed, its columns slide to where they go, one
/// splitting into two as more come and two closing into one as fewer do. While its card is open,
/// a grid's gutters, margins and baselines are dragged on the canvas itself (the shared
/// `LayoutHandles`, Model/LayoutHandles.swift).
final class LayoutTool {
    private let store: DocumentStore
    private let handles: LayoutHandles
    var redraw: () -> Void {
        get { handles.redraw }
        set { handles.redraw = newValue }
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
    private var last: CFTimeInterval?
    private var deviceScale: CGFloat = 2
    /// The canvas on screen, which nothing is drawn beyond.
    private var view = CGRect.infinite

    private static let fall = 0.46
    private static let fold = 0.26

    init(store: DocumentStore) {
        self.store = store
        handles = LayoutHandles(host: store)
    }

    var dragging: Bool { handles.dragging }

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
        if handles.heldBoard == board.id || (handles.hovered != nil && editable?.id == board.id) { return true }
        if store.inGesture, let first = store.selection.first, first != board.id, store.doc.artboard(of: first)?.id == board.id { return true }
        return false
    }

    /// The artboard whose grid the canvas can change: selected alone, with its card open.
    private var editable: Node? { handles.editable }

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
        guard store.inGesture, Helpers.shared.grids, let first = store.selection.first, first != board.id,
              store.doc.artboard(of: first)?.id == board.id, let bounds = store.selectionBounds, looks[board.id] != nil,
              let span = board.columnSpan(of: bounds) else { return nil }
        return (span.lit, span.exact, bounds)
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
        let vp = store.viewport
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let red = CanvasInk.column
        for band in handles.lit() {
            let v = vp.toView(band.rect)
            if band.line {
                ctx.setFillColor(CanvasInk.baseline.withAlphaComponent(band.held ? 0.95 : 0.6).cgColor)
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

    // MARK: - The pointer

    func down(at v: CGPoint, event: NSEvent) -> Bool { handles.down(at: v) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { handles.drag(to: v) }
    func up() { handles.up() }
    func cancel() { handles.cancel() }
    func hover(_ v: CGPoint?) { handles.hover(v) }

    func cursor(at v: CGPoint) -> NSCursor? {
        handles.pointer(at: v).map { $0 ? .resizeLeftRight : .resizeUpDown }
    }
}

extension DocumentStore: LayoutHost {
    var layoutCardOpen: Bool { openAspect == .layout }
    var gridsShown: Bool { Helpers.shared.grids }

    func measure(_ what: LayoutMeasure?, _ box: CGRect) {
        switch what {
        case nil: measurement = nil
        case .gutter(let v)?: measurement = (String(localized: "Gutter \(CanvasView.number(v))"), box)
        case .margin(let v)?: measurement = (String(localized: "Margin \(CanvasView.number(v))"), box)
        case .baseline(let v)?: measurement = (String(localized: "Baseline \(CanvasView.number(v))"), box)
        }
    }
}
