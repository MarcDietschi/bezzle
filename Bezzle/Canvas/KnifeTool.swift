import AppKit

/// The knife on the Mac: the shared `Knife` (Model/Knife.swift, which says what it does), handed
/// the canvas's events and keys, and its blade drawn over the design.
final class KnifeTool {
    private let store: DocumentStore
    let knife: Knife
    var redraw: () -> Void {
        get { knife.redraw }
        set { knife.redraw = newValue }
    }

    /// How the blade looks on the canvas: a warm red that reads on white and on the dark table.
    private static let ink = NSColor(srgbRed: 0.88, green: 0.29, blue: 0.2, alpha: 1)

    init(store: DocumentStore) {
        self.store = store
        knife = Knife(host: store)
    }

    var dragging: Bool { knife.dragging }

    func down(at v: CGPoint, event: NSEvent) { knife.down(at: v, flags: PathTool.flags(event.modifierFlags), clicks: event.clickCount) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { knife.drag(to: v, flags: PathTool.flags(flags)) }
    func up(at v: CGPoint) { knife.up(at: v) }
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) { knife.hover(v, flags: PathTool.flags(flags)) }
    var cursor: NSCursor? { store.tool == .knife ? Cursors.knife : nil }

    func key(_ event: NSEvent) -> Bool {
        let key: PenKey = switch event.keyCode {
        case 53: .escape
        case 36, 76: .enter
        case 51, 117: .delete
        default: .other
        }
        return knife.key(key)
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        guard let (blade, points) = knife.blade() else { return }
        let vp = store.viewport
        var toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        let anchors = points.map(\.point)
        guard let placed = blade.copy(using: &toView) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // A pale rim, so the blade shows on anything.
        ctx.addPath(placed)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addPath(placed)
        ctx.setStrokeColor(Self.ink.cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for (i, a) in anchors.enumerated() {
            let r = CGRect(center: vp.toView(a), size: CGSize(width: 7, height: 7))
            ctx.setFillColor(i == anchors.count - 1 ? Self.ink.cgColor : NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(Self.ink.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

extension DocumentStore: KnifeHost {
    var knifeInHand: Bool { tool == .knife }
    func refuse() { NSSound.beep() }
}
