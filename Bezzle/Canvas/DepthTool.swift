import AppKit

/// Turning layers in depth on the Mac's canvas: the shared `DepthTurning` (Model/DepthTurning.swift,
/// which says what it does), handed the canvas's events, its cursor, and what it shows drawn.
final class DepthTool {
    private let store: DocumentStore
    let turning: DepthTurning
    var redraw: () -> Void {
        get { turning.redraw }
        set { turning.redraw = newValue }
    }
    /// What a click at a canvas point picks, as the canvas would pick it.
    var pick: (CGPoint) -> UUID? {
        get { turning.pick }
        set { turning.pick = newValue }
    }
    private var deviceScale: CGFloat = 2
    static let reach = DepthTurning.reach

    init(store: DocumentStore) {
        self.store = store
        turning = DepthTurning(host: store)
    }

    var dragging: Bool { turning.dragging }

    func down(at v: CGPoint, event: NSEvent) -> Bool { turning.down(at: v, clicks: event.clickCount) }
    func startTurn(at v: CGPoint) { turning.startTurn(at: v) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        // Option, or Control as when moving it (`DepthPushing`), brings it nearer.
        turning.drag(to: v, shift: flags.contains(.shift), option: flags.contains(.option) || flags.contains(.control))
    }
    func up(at v: CGPoint, adding: Bool) { turning.up(at: v, adding: adding) }
    func cancel() { turning.cancel() }
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) { turning.hover(v) }

    var cursor: NSCursor? {
        turning.turnsPointer ? Cursors.turn : nil
    }

    // MARK: - Which way a face points

    /// Where a turned face points, and the turn that points it there (shared: `DepthAim`).
    static func facing(_ t: Transform3D) -> CGPoint { DepthAim.facing(t) }
    static func turn(facing d: CGPoint) -> (x: Double, y: Double) { DepthAim.turn(facing: d) }
    static func settled(_ x: Double, _ y: Double, steps: Bool) -> (x: Double, y: Double) { DepthAim.settled(x, y, steps: steps) }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let o = turning.overlay()
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let (center, radius) = o.ball {
            // The ball being turned.
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 4])
            ctx.strokeEllipse(in: CGRect(center: center, size: CGSize(width: radius * 2, height: radius * 2)))
            return
        }
        guard let (center, knob) = o.stalk else { return }
        if let ring = o.ring {
            // Where the face would be seen edge on.
            ctx.saveGState()
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [2, 3])
            ctx.strokeEllipse(in: CGRect(center: ring, size: CGSize(width: Self.reach * 2, height: Self.reach * 2)))
            ctx.restoreGState()
        }
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1.25)
        ctx.move(to: center)
        ctx.addLine(to: knob)
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(center: center, size: CGSize(width: 4, height: 4)))
        let rect = CGRect(center: knob, size: CGSize(width: 12, height: 12))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.fillEllipse(in: CGRect(center: knob, size: CGSize(width: 4, height: 4)))
    }
}

extension DocumentStore: DepthHost {
    var turnsFreely: Bool {
        tool == .select && editingText == nil && editingPath == nil && editingPicture == nil && building == nil
    }
    func measure(_ what: DepthMeasure?, _ box: CGRect) {
        switch what {
        case nil: return
        case .turning(let n)?: measurement = (String(localized: "Turning \(n) layers"), box)
        case .angles(let x, let y)?: measurement = ("X \(CanvasView.number(x))°  Y \(CanvasView.number(y))°", box)
        case .nearness(let z)?: measurement = ("Z \(CanvasView.number(z))", box)
        }
    }
}
