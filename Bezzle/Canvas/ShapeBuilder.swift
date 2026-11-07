import AppKit

/// Building with the pieces overlapping shapes cut each other into on the Mac's canvas, once the
/// selected shapes are being built with (`DocumentStore.startBuilding`): the shared
/// `PieceBuilding` (Model/ShapeBuilding.swift, which says what it does), handed the canvas's
/// events, its cursor, and what it shows drawn.
final class ShapeBuilder {
    private let store: DocumentStore
    private let building: PieceBuilding
    var redraw: () -> Void {
        get { building.redraw }
        set { building.redraw = newValue }
    }

    /// Wiping away is shown in red, joining in the canvas's blue.
    private static let eraseInk = NSColor(srgbRed: 0.88, green: 0.29, blue: 0.2, alpha: 1)

    init(store: DocumentStore) {
        self.store = store
        building = PieceBuilding(host: store)
    }

    var active: Bool { building.active }
    var dragging: Bool { building.dragging }

    // MARK: - The pointer

    /// A press while building: on a piece it starts joining or wiping; anywhere else building is
    /// done, and false leaves the press to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool { building.down(at: v, option: event.modifierFlags.contains(.option)) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { building.drag(to: v, option: flags.contains(.option)) }
    func up(at v: CGPoint) { building.up(at: v) }
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) { building.hover(v, option: flags.contains(.option)) }

    var cursor: NSCursor? {
        building.pointer.map { $0.onPiece ? Cursors.build(erase: $0.erase) : .arrow }
    }

    func key(_ event: NSEvent) -> Bool {
        let key: PenKey = switch event.keyCode {
        case 53: .escape
        case 36, 76: .enter
        default: .other
        }
        return building.key(key)
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        guard active else { return }
        let marks = building.marks()
        let vp = store.viewport
        var toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        let ink = marks.erasing ? Self.eraseInk : CanvasInk.pencil
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Where the pointer is, or what the drag has touched: tinted, so it shows what will happen.
        for piece in marks.pieces where piece.lit {
            guard let placed = piece.outline.copy(using: &toView) else { continue }
            ctx.addPath(placed)
            ctx.setFillColor(ink.withAlphaComponent(marks.erasing ? 0.28 : 0.22).cgColor)
            ctx.fillPath()
        }
        // Every piece's edge, faint, so the pieces read as pieces.
        ctx.setLineWidth(1)
        for piece in marks.pieces {
            guard let placed = piece.outline.copy(using: &toView) else { continue }
            ctx.addPath(placed)
            ctx.setStrokeColor((piece.lit ? ink : CanvasInk.pencil.withAlphaComponent(0.55)).cgColor)
            if !piece.lit { ctx.setLineDash(phase: 0, lengths: [3, 2]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if marks.trail.count > 1 {
            let way = CGMutablePath()
            way.addLines(between: marks.trail)
            ctx.addPath(way)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(ink.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
    }
}

extension DocumentStore: BuildHost {}
