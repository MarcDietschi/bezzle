import AppKit

/// Two things done to a selected shape's outline straight on the Mac's canvas: its corners'
/// dots, and its edge pulled out or in with Option. The shared `OutlineDragging`
/// (Model/OutlineDragging.swift, which says what it does), handed the canvas's events, its
/// cursor, and what it shows drawn.
final class OutlineTool {
    private let outlines: OutlineDragging
    var redraw: () -> Void {
        get { outlines.redraw }
        set { outlines.redraw = newValue }
    }
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        outlines = OutlineDragging(host: store)
    }

    var dragging: Bool { outlines.dragging }

    private static func flags(_ f: NSEvent.ModifierFlags) -> PenFlags {
        var out: PenFlags = []
        if f.contains(.shift) { out.insert(.shift) }
        if f.contains(.option) { out.insert(.option) }
        if f.contains(.command) { out.insert(.command) }
        return out
    }

    /// A press with the select tool: on a corner dot, or on the edge with Option. False leaves
    /// it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool { outlines.down(at: v, flags: Self.flags(event.modifierFlags)) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { outlines.drag(to: v, flags: Self.flags(flags)) }
    func up() { outlines.up() }
    func cancel() { outlines.cancel() }
    /// The pointer moving with nothing pressed, or leaving the canvas (nil).
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) { outlines.hover(v, flags: Self.flags(flags)) }

    func cursor(at v: CGPoint) -> NSCursor? {
        switch outlines.pointer(at: v) {
        case .cross?: .crosshair
        case .across(let angle)?: Cursors.resize(angle)
        case nil: nil
        }
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let marks = outlines.marks()
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let edge = marks.edge {
            ctx.addPath(edge)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
        for p in marks.dots {
            let rect = CGRect(center: p, size: CGSize(width: 7, height: 7))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

extension DocumentStore: OutlineHost {
    func measure(_ what: OutlineMeasure?, _ box: CGRect) {
        switch what {
        case nil: measurement = nil
        case .radius(let r)?: measurement = (String(localized: "Radius \(CanvasView.number(r))"), box)
        case .outset(let d)?: measurement = (String(localized: "Outset \(CanvasView.number(d))"), box)
        case .inset(let d)?: measurement = (String(localized: "Inset \(CanvasView.number(d))"), box)
        }
    }
}
