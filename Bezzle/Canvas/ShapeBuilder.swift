import AppKit

/// Building with the pieces overlapping shapes cut each other into, once the selected shapes
/// are being built with (`DocumentStore.startBuilding`). Every piece is outlined, and the one
/// under the pointer lights up. A click makes that piece a shape of its own; a drag across
/// pieces joins every piece it touches into one. With Option held, the pieces are wiped away
/// instead. Return, Escape, or a click away from the pieces is done.
final class ShapeBuilder {
    private let store: DocumentStore
    var redraw: () -> Void = {}

    /// The piece under the pointer, by its place in `store.buildPieces`.
    private var hovered: Int?
    /// The pieces a drag has touched so far, in the order it touched them, and the way it went.
    private var picked: [Int] = []
    private var trail: [CGPoint] = []
    private var erasing = false
    private(set) var dragging = false

    /// Wiping away is shown in red, joining in the canvas's blue.
    private static let eraseInk = NSColor(srgbRed: 0.88, green: 0.29, blue: 0.2, alpha: 1)

    init(store: DocumentStore) {
        self.store = store
    }

    var active: Bool { store.building != nil }

    private func canvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }

    private func piece(at p: CGPoint) -> Int? {
        store.buildPieces.indices.last { store.buildPieces[$0].outline.contains(p) }
    }

    // MARK: - The pointer

    /// A press while building: on a piece it starts joining or wiping; anywhere else building is
    /// done, and false leaves the press to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard active else { return false }
        let p = canvas(v)
        guard let i = piece(at: p) else {
            store.building = nil
            return false
        }
        dragging = true
        picked = [i]
        trail = [p]
        erasing = event.modifierFlags.contains(.option)
        redraw()
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard dragging else { return }
        let p = canvas(v)
        erasing = flags.contains(.option)
        // Every piece the way passes over, however fast the pointer goes.
        if let last = trail.last {
            let steps = max(1, Int((hypot(p.x - last.x, p.y - last.y) * store.viewport.zoom / 3).rounded(.up)))
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                let q = CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
                if let i = piece(at: q), !picked.contains(i) { picked.append(i) }
            }
        }
        trail.append(p)
        redraw()
    }

    func up(at v: CGPoint) {
        guard dragging else { return }
        dragging = false
        let chosen = picked
        picked = []
        trail = []
        store.build(chosen, erase: erasing)
        hovered = piece(at: canvas(v))
        redraw()
    }

    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        guard active else {
            if hovered != nil { hovered = nil }
            return
        }
        let was = (hovered, erasing)
        hovered = v.flatMap { piece(at: canvas($0)) }
        erasing = flags.contains(.option)
        if was != (hovered, erasing) { redraw() }
    }

    var cursor: NSCursor? {
        guard active else { return nil }
        return hovered != nil || dragging ? Cursors.build(erase: erasing) : .arrow
    }

    func key(_ event: NSEvent) -> Bool {
        guard active else { return false }
        switch event.keyCode {
        case 36, 76, 53:
            if dragging {
                dragging = false
                picked = []
                trail = []
            } else {
                store.building = nil
            }
            redraw()
            return true
        default:
            return false
        }
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        guard active else { return }
        let vp = store.viewport
        var toView = CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
        let pieces = store.buildPieces
        let ink = erasing ? Self.eraseInk : CanvasInk.pencil
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Where the pointer is, or what the drag has touched: tinted, so it shows what will happen.
        let lit = dragging ? picked : hovered.map { [$0] } ?? []
        for i in lit where pieces.indices.contains(i) {
            guard let placed = pieces[i].outline.copy(using: &toView) else { continue }
            ctx.addPath(placed)
            ctx.setFillColor(ink.withAlphaComponent(erasing ? 0.28 : 0.22).cgColor)
            ctx.fillPath()
        }
        // Every piece's edge, faint, so the pieces read as pieces.
        ctx.setLineWidth(1)
        for (i, piece) in pieces.enumerated() {
            guard let placed = piece.outline.copy(using: &toView) else { continue }
            ctx.addPath(placed)
            ctx.setStrokeColor((lit.contains(i) ? ink : CanvasInk.pencil.withAlphaComponent(0.55)).cgColor)
            if !lit.contains(i) { ctx.setLineDash(phase: 0, lengths: [3, 2]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if dragging, trail.count > 1 {
            let way = CGMutablePath()
            way.addLines(between: trail.map(vp.toView))
            ctx.addPath(way)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(ink.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
    }
}
