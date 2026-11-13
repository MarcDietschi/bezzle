import AppKit

/// The pen on the Mac: the shared `PenTool` (Model/PenTool.swift, which says what the pen and
/// point editing do), handed the canvas's events and keys, and what it says shows drawn over the
/// design, with the pen's own pointers.
final class PathTool {
    private let store: DocumentStore
    let pen: PenTool
    /// Draws the canvas again, for what changes here and not in the store: the curve following the pointer.
    var redraw: () -> Void {
        get { pen.redraw }
        set { pen.redraw = newValue }
    }
    private var deviceScale: CGFloat = 2

    /// `host` is what the pen works on: the design, or in Animate the film (`FilmPoints`).
    init(store: DocumentStore, host: PenHost? = nil) {
        self.store = store
        pen = PenTool(host: host ?? store)
    }

    var dragging: Bool { pen.dragging }
    var shownPath: UUID? { pen.shownPath }
    var spot: CGPoint? { pen.spot }

    static func flags(_ f: NSEvent.ModifierFlags) -> PenFlags {
        var out: PenFlags = []
        if f.contains(.shift) { out.insert(.shift) }
        if f.contains(.option) { out.insert(.option) }
        if f.contains(.command) { out.insert(.command) }
        return out
    }

    func penDown(at v: CGPoint, event: NSEvent) { pen.penDown(at: v, flags: Self.flags(event.modifierFlags)) }
    func editDown(at v: CGPoint, event: NSEvent) -> Bool { pen.editDown(at: v, flags: Self.flags(event.modifierFlags), clicks: event.clickCount) }
    func startMarquee(at v: CGPoint, adding: Bool, offPath: Bool) { pen.startMarquee(at: v, adding: adding, offPath: offPath) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { pen.drag(to: v, flags: Self.flags(flags)) }
    func up(at v: CGPoint, flags: NSEvent.ModifierFlags) { pen.up(at: v, flags: Self.flags(flags)) }
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) { pen.hover(v, flags: Self.flags(flags)) }

    /// Keys for the pen and for editing points; false for those left to the canvas.
    func key(_ event: NSEvent) -> Bool {
        let key: PenKey = switch event.keyCode {
        case 53: .escape
        case 36, 76: .enter
        case 51, 117: .delete
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: .other
        }
        return pen.key(key, flags: Self.flags(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    /// The pointer for where it is, or nil when this has no say.
    var cursor: NSCursor? {
        if store.tool == .pen {
            switch pen.mark {
            case .add: return Cursors.pen(.add)
            case .remove: return Cursors.pen(.remove)
            case .close: return Cursors.pen(.close)
            case .convert: return Cursors.pen(.convert)
            case .carryOn: return Cursors.pen(.carryOn)
            case .none, .point: return Cursors.pen(.none)
            }
        }
        if store.tool == .select, store.editingPath != nil {
            return pen.mark == .add ? Cursors.pen(.add) : .arrow
        }
        return nil
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let o = pen.overlay()
        let vp = store.viewport
        let toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        if let shown = o.outline {
            ctx.addPath(Self.placed(shown.cgPath, toView))
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        // The curve still to come: from the newest point to where the next would go, or back to the first.
        if let c = o.toCome {
            let band = CGMutablePath()
            band.move(to: c.from)
            band.addCurve(to: c.to, control1: c.c1, control2: c.c2)
            ctx.addPath(Self.placed(band, toView))
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        drawHandles(o.handles.map { ($0.point, $0.handle) }, in: ctx)
        for a in o.anchors { drawAnchor(vp.toView(a.point), filled: a.filled, in: ctx) }
        if let first = o.closing {
            let c = crisp(vp.toView(first))
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(center: c, size: CGSize(width: 15, height: 15)))
        }
        if let spot = o.spot {
            ctx.setAlpha(0.55)
            drawAnchor(vp.toView(spot), filled: false, in: ctx)
            ctx.setAlpha(1)
        }
        if let marquee = o.marquee {
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
            ctx.move(to: crisp(store.viewport.toView(a)))
            ctx.addLine(to: crisp(store.viewport.toView(h)))
        }
        ctx.strokePath()
        for (_, h) in handles {
            let rect = CGRect(center: crisp(store.viewport.toView(h)), size: CGSize(width: 7, height: 7))
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

extension DocumentStore: PenHost {
    var penInHand: Bool { tool == .pen }
    var selecting: Bool { tool == .select }
    func dropPen() { tool = .select }
    var zoom: CGFloat { viewport.zoom }
    func toView(_ p: CGPoint) -> CGPoint { viewport.toView(p) }
    func toCanvas(_ v: CGPoint) -> CGPoint { viewport.toCanvas(v) }
}
