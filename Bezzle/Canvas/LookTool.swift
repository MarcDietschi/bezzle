import AppKit

/// Looking at an artboard's scene from the side on the Mac's canvas (`DepthLook`, which says what
/// that is: the eye moves, the page stays). Control held, a drag that begins on nothing, beside
/// the layers, takes the scene of the artboard under the pointer and turns the look with it: what
/// is held up off the page goes with the pointer. While an artboard is looked at from the side,
/// a post stands under each corner of what is off the page (of what is picked alone, when some
/// of it is), and a word by its top right corner
/// looks from the front again, as a click with Control on nothing does, and Escape with nothing
/// picked. The look is the store's (`DocumentStore.looks`): never an undo step, never saved.
final class LookTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}
    private var drag: (board: UUID, from: DepthLook?, start: CGPoint, moved: Bool)?
    private var wordHovered = false

    init(store: DocumentStore) {
        self.store = store
    }

    var dragging: Bool { drag != nil }

    /// Control pressed on nothing, at `v` in the view: takes the look of the artboard there, or
    /// of the one being worked on. False with no artboard to look at.
    func down(at v: CGPoint) -> Bool {
        let p = store.viewport.toCanvas(v)
        guard let board = store.doc.artboard(at: p) ?? store.focusedArtboard, !board.hidden else { return false }
        drag = (board.id, store.looks[board.id], v, false)
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard var d = drag else { return }
        let by = CGPoint(x: v.x - d.start.x, y: v.y - d.start.y)
        if !d.moved, hypot(by.x, by.y) < 3 { return }
        d.moved = true
        drag = d
        let look = (d.from ?? .front).dragged(by: by, steps: flags.contains(.shift))
        store.look(at: d.board, from: look)
        let at = store.viewport.toCanvas(CGPoint(x: v.x, y: v.y + 14))
        store.measurement = (Self.words(look), CGRect(origin: at, size: .zero))
        redraw()
    }

    func up() {
        guard let d = drag else { return }
        drag = nil
        store.measurement = nil
        // A click, nothing dragged: from the front again.
        if !d.moved { store.look(at: d.board, from: nil) }
        redraw()
    }

    /// Escape during the drag: looked at as before it.
    func cancel() {
        guard let d = drag else { return }
        drag = nil
        store.measurement = nil
        store.look(at: d.board, from: d.from)
        redraw()
    }

    /// From which side, and how far round: an arrow for the side the eye stands on.
    static func words(_ look: DepthLook) -> String {
        var parts: [String] = []
        if look.across != 0 { parts.append("\(look.across > 0 ? "→" : "←") \(Int(abs(look.across).rounded()))°") }
        if look.down != 0 { parts.append("\(look.down > 0 ? "↓" : "↑") \(Int(abs(look.down).rounded()))°") }
        return parts.isEmpty ? "0°" : parts.joined(separator: "  ")
    }

    // MARK: - The word that looks from the front again

    static let front = LocalizedStringResource("Look from the Front", comment: "A word on the canvas by an artboard looked at from the side: a click looks at it from straight in front again.")
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private var lastBounds: CGRect = .zero

    /// Where the word stands for an artboard: by its top right corner, in the line its name is
    /// in, and inside the view while any of the artboard is.
    private func wordRect(of board: Node, in bounds: CGRect) -> CGRect? {
        let r = store.viewport.toView(board.frame)
        guard r.intersects(bounds) else { return nil }
        let words = String(localized: Self.front)
        let w = ceil((words as NSString).size(withAttributes: [.font: Self.font]).width)
        let size = CGSize(width: w + 20, height: 20)
        var origin = CGPoint(x: (r.maxX - size.width).rounded(), y: (r.minY - size.height - 5).rounded())
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }

    /// The artboards looked at from the side, and where each one's word stands.
    private func words(in bounds: CGRect) -> [(board: UUID, rect: CGRect)] {
        guard !store.looks.isEmpty else { return [] }
        return store.doc.artboards.compactMap { board in
            guard !board.hidden, store.looks[board.id] != nil, let r = wordRect(of: board, in: bounds) else { return nil }
            return (board.id, r)
        }
    }

    /// A press on a word: that artboard is looked at from the front. False leaves it to the canvas.
    func wordDown(at v: CGPoint) -> Bool {
        guard let hit = words(in: lastBounds).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(v) }) else { return false }
        store.look(at: hit.board, from: nil)
        wordHovered = false
        redraw()
        return true
    }

    func hover(_ v: CGPoint?) {
        lastPointer = v
        let on = v.map { v in words(in: lastBounds).contains { $0.rect.insetBy(dx: -2, dy: -2).contains(v) } } ?? false
        guard on != wordHovered else { return }
        wordHovered = on
        redraw()
    }

    /// Whether the pointer is on a word, which takes the arrow.
    var onWord: Bool { wordHovered }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, in bounds: CGRect) {
        lastBounds = bounds
        guard !store.looks.isEmpty else { return }
        let doc = store.shownDoc
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // A post under each corner of what stands off the page.
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        for board in doc.artboards where !board.hidden && doc.looks?[board.id] != nil {
            guard store.viewport.toView(board.frame).insetBy(dx: -400, dy: -400).intersects(bounds) else { continue }
            for post in doc.posts(of: board, picked: Set(store.selection)) {
                let foot = store.viewport.toView(post.foot), top = store.viewport.toView(post.top)
                ctx.move(to: foot)
                ctx.addLine(to: top)
                ctx.strokePath()
                ctx.fillEllipse(in: CGRect(x: foot.x - 1.5, y: foot.y - 1.5, width: 3, height: 3))
            }
        }
        let words = String(localized: Self.front)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (words as NSString).size(withAttributes: attrs)
        for (_, r) in self.words(in: bounds) {
            let on = wordHovered && r.insetBy(dx: -2, dy: -2).contains(lastPointer ?? CGPoint(x: -.infinity, y: -.infinity))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
            ctx.setFillColor((on ? CanvasInk.pencil.blended(withFraction: 0.12, of: .black) ?? CanvasInk.pencil : CanvasInk.pencil).cgColor)
            ctx.fillPath()
            (words as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// Where the pointer is, to darken the word under it.
    var lastPointer: CGPoint?
}
