import AppKit
import QuartzCore

/// The canvas's side of laying a design out again for a new artboard size (`Adapt`).
///
/// Motion: when a design is arranged another way, or an artboard takes a size chosen for it, every
/// layer travels to its new place on a spring, nearer ones a moment before farther ones, the
/// artboard itself with them; nothing jumps. While an edge is dragged and the arrangement holds,
/// the layers follow the pointer directly.
///
/// The skeleton: while an artboard's edge is dragged, what was understood of its design shows on
/// it, faint: each block outlined, each loose gap as a spring that stretches and squeezes with
/// the room it gets, each tight gap as a staple holding two blocks together. It opens when the
/// drag starts, pulses when the design is arranged anew, and folds away when the drag ends.
@MainActor
final class AdaptTool {
    private struct Track {
        var from: Node
        var progress = DeckTool.Spring(0)
        /// How long before it sets off.
        var wait: Double
    }

    private struct Move {
        /// The artboard as it was drawn when the move began, when it moves too.
        var board: Track?
        var layers: [UUID: Track] = [:]
    }

    private var moves: [UUID: Move] = [:]
    /// Artboards to move to where they now are, at the next frame, and whether the artboard
    /// itself moves with its layers.
    private var asked: [UUID: Bool] = [:]
    /// The design as last drawn.
    private var drawn: BezzleDocument?
    private var last: CFTimeInterval?

    nonisolated(unsafe) private var watcher: NSObjectProtocol?

    init() {
        watcher = NotificationCenter.default.addObserver(forName: Adapting.laidOut, object: nil, queue: nil) { [weak self] note in
            guard let ids = note.userInfo?["ids"] as? [UUID] else { return }
            MainActor.assumeIsolated { self?.move(ids, withBoard: true) }
        }
    }

    deinit {
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
    }

    /// Moves the artboards' layers from where they are drawn to where they now are.
    func move(_ ids: [UUID], withBoard: Bool) {
        for id in ids { asked[id] = (asked[id] ?? false) || withBoard }
    }

    var isAnimating: Bool { !moves.isEmpty || !asked.isEmpty || open.isMoving || pulse.isMoving }
    var isMoving: Bool { !moves.isEmpty }

    /// The design to draw at `now`: `doc`, with layers on their way to where they now are part of
    /// the way there.
    func frame(of doc: BezzleDocument, at now: CFTimeInterval) -> BezzleDocument {
        let dt = last.map { min(max(now - $0, 0), 0.05) } ?? 1.0 / 120
        last = now
        if !asked.isEmpty {
            if let before = drawn {
                for (id, withBoard) in asked { start(id, from: before, to: doc, withBoard: withBoard) }
            }
            asked = [:]
        }
        guard !moves.isEmpty else {
            drawn = doc
            return doc
        }
        var out = doc
        for (id, var move) in moves {
            guard let target = doc.node(id), target.isArtboard else {
                moves[id] = nil
                continue
            }
            var board = target
            var done = true
            if var t = move.board {
                step(&t, dt)
                board.frame = Self.mix(t.from.frame, target.frame, t.progress.value)
                if t.progress.settled && t.wait <= 0 { move.board = nil } else { move.board = t; done = false }
            }
            for i in board.children.indices {
                let c = board.children[i]
                guard var t = move.layers[c.id] else { continue }
                step(&t, dt)
                if t.progress.settled && t.wait <= 0 {
                    move.layers[c.id] = nil
                } else {
                    board.children[i] = Self.blend(t.from, c, t.wait > 0 ? 0 : t.progress.value)
                    move.layers[c.id] = t
                    done = false
                }
            }
            moves[id] = done ? nil : move
            out.update(id) { $0 = board }
        }
        drawn = out
        return out
    }

    private func start(_ id: UUID, from before: BezzleDocument, to doc: BezzleDocument, withBoard: Bool) {
        guard let was = before.node(id), let now = doc.node(id), was.isArtboard, now.isArtboard else { return }
        // Shown as a deck shows itself: the post in front is what moves.
        var move = moves[id] ?? Move()
        if withBoard, was.frame != now.frame { move.board = Track(from: was, wait: 0) }
        var then: [UUID: Node] = [:]
        for c in was.children { then[c.id] = c }
        // Nearest the artboard's top left first, as a wave running across it.
        let reach = max(hypot(now.frame.width, now.frame.height), 1)
        for c in now.children {
            guard let w = then[c.id], w != c else { continue }
            let d = hypot(c.frame.midX, c.frame.midY) / reach
            move.layers[c.id] = Track(from: w, wait: Double(d) * 0.07)
        }
        if move.board != nil || !move.layers.isEmpty { moves[id] = move }
    }

    private func step(_ t: inout Track, _ dt: Double) {
        if t.wait > 0 {
            t.wait -= dt
            return
        }
        t.progress.target = 1
        // A little past and back, as something with weight comes to rest.
        t.progress.step(dt, stiffness: 230, damping: 23)
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t), width: max(0, mix(a.width, b.width, t)), height: max(0, mix(a.height, b.height, t)))
    }

    /// Part of the way from one layer to the same layer laid out anew: its box, and with it its
    /// type, corners and what it holds.
    private static func blend(_ a: Node, _ b: Node, _ t: Double) -> Node {
        guard t < 1 || t > 1.0001 else { return b }
        var n = b
        let f = mix(a.frame, b.frame, t)
        n.cornerRadius = max(0, mix(a.cornerRadius, b.cornerRadius, t))
        if let ca = a.corners, let cb = b.corners, ca.count == cb.count { n.corners = zip(ca, cb).map { max(0, mix($0, $1, t)) } }
        if let ia = a.fill.image, let ib = b.fill.image, ia.asset == ib.asset {
            n.fill.image?.offset = CGPoint(x: mix(ia.offset.x, ib.offset.x, t), y: mix(ia.offset.y, ib.offset.y, t))
        }
        switch b.kind {
        case .text:
            if let sa = a.style?.size, let sb = b.style?.size, sb > 0 {
                let size = max(1, mix(sa, sb, t))
                if abs(size - sb) > 0.01 { n.scaleType(by: size / sb) }
            }
            n.frame = f
        case .group:
            if b.frame.width > 0, b.frame.height > 0 {
                n.children = BezzleDocument.scaled(b.children, from: b.frame.size, to: f.size)
                n.mask = b.mask.map { BezzleDocument.scaled($0, from: b.frame.size, to: f.size) }
            }
            n.frame = f
        default:
            n.frame = f
        }
        return n
    }

    // MARK: - The skeleton

    private var skeleton: Adapt.Skeleton?
    /// Where the artboard it is on lies on the canvas.
    private var origin: CGPoint = .zero
    private var open = DeckTool.Spring(0)
    private var pulse = DeckTool.Spring(0)
    private var stepped: CFTimeInterval?

    /// Shows what was understood of the artboard at `origin` as it is laid out now.
    func show(_ s: Adapt.Skeleton, at origin: CGPoint, rearranged: Bool) {
        skeleton = s
        self.origin = origin
        open.target = 1
        if rearranged {
            pulse.value = 1
            pulse.target = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func hide() {
        open.target = 0
    }

    func draw(_ ctx: CGContext, viewport: Viewport, scale: CGFloat) {
        let now = CACurrentMediaTime()
        let dt = stepped.map { min(max(now - $0, 0), 0.05) } ?? 1.0 / 120
        stepped = now
        open.step(dt, stiffness: 300, damping: 30)
        pulse.step(dt, stiffness: 120, damping: 18)
        guard let s = skeleton, open.value > 0.01 else {
            if !open.isMoving, open.target == 0 { skeleton = nil }
            return
        }
        let a = CGFloat(min(max(open.value, 0), 1))
        let lift = CGFloat(max(pulse.value, 0))
        func view(_ r: CGRect) -> CGRect { viewport.toView(r.offsetBy(dx: origin.x, dy: origin.y)) }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Blocks: a hairline round each, brighter for a moment when they are arranged anew.
        let pencil = CanvasInk.pencil
        ctx.setStrokeColor(pencil.withAlphaComponent((0.26 + 0.4 * lift) * a).cgColor)
        ctx.setLineWidth(1)
        for b in s.blocks {
            let r = view(b).insetBy(dx: -2 * a, dy: -2 * a)
            guard r.width > 2, r.height > 2 else { continue }
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
        }
        ctx.strokePath()

        // Tight gaps: a staple across, holding the two together.
        ctx.setStrokeColor(pencil.withAlphaComponent(0.55 * a).cgColor)
        ctx.setLineWidth(1.5)
        for g in s.bonds {
            let r = view(g.rect)
            let length = g.axis == .y ? r.height : r.width
            guard length >= 3 else { continue }
            let c = CGPoint(x: r.midX, y: r.midY)
            let w: CGFloat = 5 * a
            if g.axis == .y {
                ctx.move(to: CGPoint(x: c.x, y: r.minY + 1)); ctx.addLine(to: CGPoint(x: c.x, y: r.maxY - 1))
                ctx.move(to: CGPoint(x: c.x - w, y: r.minY + 1)); ctx.addLine(to: CGPoint(x: c.x + w, y: r.minY + 1))
                ctx.move(to: CGPoint(x: c.x - w, y: r.maxY - 1)); ctx.addLine(to: CGPoint(x: c.x + w, y: r.maxY - 1))
            } else {
                ctx.move(to: CGPoint(x: r.minX + 1, y: c.y)); ctx.addLine(to: CGPoint(x: r.maxX - 1, y: c.y))
                ctx.move(to: CGPoint(x: r.minX + 1, y: c.y - w)); ctx.addLine(to: CGPoint(x: r.minX + 1, y: c.y + w))
                ctx.move(to: CGPoint(x: r.maxX - 1, y: c.y - w)); ctx.addLine(to: CGPoint(x: r.maxX - 1, y: c.y + w))
            }
        }
        ctx.strokePath()

        // Loose gaps: a spring of as many turns whatever its length, so that it shows how far it
        // is stretched or squeezed.
        let ink = CanvasInk.gap
        ctx.setStrokeColor(ink.withAlphaComponent(0.85 * a).cgColor)
        ctx.setLineWidth(1.25)
        for g in s.springs {
            let r = view(g.rect)
            let length = g.axis == .y ? r.height : r.width
            guard length >= 6 else { continue }
            let c = CGPoint(x: r.midX, y: r.midY)
            let turns = 6
            let amp: CGFloat = min(6, max(3, 36 / max(length, 1) * 4)) * a
            let ends: CGFloat = min(5, length * 0.12)
            let start = g.axis == .y ? r.minY + 1 : r.minX + 1, stop = g.axis == .y ? r.maxY - 1 : r.maxX - 1
            func pt(_ along: CGFloat, _ off: CGFloat) -> CGPoint {
                g.axis == .y ? CGPoint(x: c.x + off, y: along) : CGPoint(x: along, y: c.y + off)
            }
            // A cap at each end, where it presses on the blocks.
            ctx.move(to: pt(start, -amp * 1.4)); ctx.addLine(to: pt(start, amp * 1.4))
            ctx.move(to: pt(stop, -amp * 1.4)); ctx.addLine(to: pt(stop, amp * 1.4))
            ctx.move(to: pt(start, 0))
            ctx.addLine(to: pt(start + ends, 0))
            let coil = (stop - start - ends * 2) / CGFloat(turns * 2)
            for i in 0..<(turns * 2) {
                ctx.addLine(to: pt(start + ends + coil * (CGFloat(i) + 0.5), i % 2 == 0 ? amp : -amp))
            }
            ctx.addLine(to: pt(stop - ends, 0))
            ctx.addLine(to: pt(stop, 0))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
