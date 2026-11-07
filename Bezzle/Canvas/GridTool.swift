import AppKit

/// A selected repeat grid on the Mac's canvas: the shared `GridHandles` (Model/GridHandles.swift,
/// which says what it does), handed the canvas's events, its cursor, and what it shows drawn.
final class GridTool {
    private let handles: GridHandles
    var redraw: () -> Void {
        get { handles.redraw }
        set { handles.redraw = newValue }
    }
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        handles = GridHandles(host: store)
    }

    var dragging: Bool { handles.dragging }

    /// A grid's outline on screen, round its cells the way its rows run, in place of its frame's.
    func outline(of id: UUID) -> [CGPoint]? { handles.outline(of: id) }

    /// A press with the select tool on a selected grid's handle, gap or corner. False leaves it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool { handles.down(at: v) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { handles.drag(to: v, flags: flags.contains(.shift) ? .shift : []) }
    func up() { handles.up() }
    func cancel() { handles.cancel() }
    /// The pointer moving with nothing pressed, or leaving the canvas (nil).
    func hover(_ v: CGPoint?) { handles.hover(v) }

    func cursor(at v: CGPoint) -> NSCursor? {
        switch handles.pointer(at: v) {
        case .resize(let angle)?: Cursors.resize(angle)
        case .turn(let angle)?: Cursors.rotate(angle)
        case nil: nil
        }
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let marks = handles.marks()
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if !marks.copies.isEmpty {
            ctx.saveGState()
            for corners in marks.copies {
                ctx.addLines(between: corners.map(crisp))
                ctx.closePath()
            }
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.strokePath()
            ctx.restoreGState()
        }
        if !marks.cells.isEmpty {
            ctx.saveGState()
            for corners in marks.cells { ctx.addPath(polygon(corners)) }
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(marks.cellsActive ? 0.55 : 0.3).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.restoreGState()
        }
        for band in marks.gaps {
            ctx.saveGState()
            ctx.addPath(polygon(band.corners))
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()
            for (a, b) in band.edges {
                ctx.move(to: crisp(a))
                ctx.addLine(to: crisp(b))
            }
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }
        if !marks.ghosts.isEmpty {
            ctx.saveGState()
            for ghost in marks.ghosts {
                let shape = polygon(ghost.corners)
                ctx.addPath(shape)
                ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.07 * ghost.near).cgColor)
                ctx.fillPath()
                ctx.addPath(shape)
                ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.25 + 0.55 * ghost.near).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        for handle in marks.handles { draw(handle, in: ctx) }
    }

    /// Corners on screen as a closed shape on whole pixels.
    private func polygon(_ corners: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: corners.map(crisp))
        path.closeSubpath()
        return path
    }

    private func draw(_ handle: RepeatGridMarks.Handle, in ctx: CGContext) {
        let rect = CGRect(center: .zero, size: handle.size)
        let round = handle.part == .both
        let thick = min(handle.size.width, handle.size.height)
        let shape = round ? CGPath(ellipseIn: rect, transform: nil)
                          : CGPath(roundedRect: rect, cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Drawn upright about its own middle, then turned the way the grid's rows run.
        ctx.translateBy(x: handle.at.x, y: handle.at.y)
        ctx.rotate(by: Geometry.radians(handle.angle))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 2 * deviceScale, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        // Two grip lines across the pull, as on a drawer.
        guard !round else { return }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        for d in [-2.0, 2.0] as [CGFloat] {
            if handle.part == .columns {
                ctx.move(to: CGPoint(x: -1.5, y: d)); ctx.addLine(to: CGPoint(x: 1.5, y: d))
            } else {
                ctx.move(to: CGPoint(x: d, y: -1.5)); ctx.addLine(to: CGPoint(x: d, y: 1.5))
            }
        }
        ctx.strokePath()
    }

    /// Lines of one pixel fall on whole pixels.
    private func crisp(_ p: CGPoint) -> CGPoint {
        let s = deviceScale
        return CGPoint(x: (p.x * s).rounded() / s + 0.5 / s, y: (p.y * s).rounded() / s + 0.5 / s)
    }
}

extension DocumentStore: GridHost {
    var selectsFreely: Bool { turnsFreely }

    func measure(_ what: GridMeasure?, _ box: CGRect) {
        switch what {
        case nil:
            measurement = nil
        case .cells(let columns, let rows)?:
            let cells = columns * rows
            measurement = (cells > 1 ? String(localized: "\(columns) × \(rows)  ·  \(cells) cells") : "\(columns) × \(rows)", box)
        case .gap(let gap, let both)?:
            measurement = (both ? String(localized: "Gaps \(CanvasView.number(gap))") : String(localized: "Gap \(CanvasView.number(gap))"), box)
        case .angle(let angle)?:
            measurement = ("\(CanvasView.number(angle))°", box)
        }
    }
}
