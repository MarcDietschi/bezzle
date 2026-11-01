import AppKit

/// What the canvas does while looking back through a design's versions. Going from one version
/// to another, the layers glide together to how they were: those not made yet fade away, and
/// those taken away since come back. Then what differs from now is marked in pencil at its
/// corners, what has gone since in sepia, what was made since as a faint dotted outline where it
/// will be, and the pointer resting on a layer shows where it is now, by a thread to its place.
@MainActor
final class TimeTable {
    private let store: DocumentStore
    private var shelf: VersionShelf { store.versions }

    init(store: DocumentStore) {
        self.store = store
    }

    // MARK: Gliding

    private enum Key: Equatable { case now, version(UUID) }
    private var lastKey: Key?
    private var drawn: BezzleDocument?

    private struct Glide {
        var began: CFTimeInterval
        /// Those changing, as they were drawn as it began, outer ones first.
        var from: [(UUID, Node)]
        var appearing: [UUID]
        var vanishing: [(node: Node, parent: UUID?, index: Int)]
    }

    private var glide: Glide?
    /// How long the layers take to get there.
    static let duration = 0.42
    /// How long the marks then take to be drawn.
    static let marking = 0.3

    /// The design to draw at `now`: as shown, with what is changing on its way there.
    func frame(of shown: BezzleDocument, in bounds: CGRect, at now: CFTimeInterval) -> BezzleDocument {
        let key: Key = shelf.travel.map { .version($0.at) } ?? .now
        if key != lastKey {
            if let drawn, lastKey != nil { begin(from: drawn, to: shown, at: now) }
            lastKey = key
        }
        guard let g = glide else {
            isMoving = false
            drawn = shown
            return shown
        }
        let t = (now - g.began) / Self.duration
        isMoving = t < 1
        if t >= 1 {
            if now - g.began > Self.duration + Self.marking { glide = nil }
            drawn = shown
            return shown
        }
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        var out = shown
        for (id, from) in g.from where out.node(id) != nil {
            out.update(id) { $0 = from.blended(to: $0, e) }
        }
        for id in g.appearing {
            out.update(id) { $0.opacity *= e }
        }
        for v in g.vanishing where out.node(v.node.id) == nil {
            var node = v.node
            node.opacity *= 1 - e
            if let parent = v.parent {
                guard let path = out.path(of: parent) else { continue }
                out.insert(node, at: NodePath(indices: path.indices + [v.index]))
            } else {
                out.insert(node, at: NodePath(indices: [v.index]))
            }
        }
        drawn = out
        return out
    }

    private func begin(from: BezzleDocument, to: BezzleDocument, at now: CFTimeInterval) {
        let d = VersionShelf.differences(from, to)
        var changing: [(UUID, Node, Int)] = []
        for id in d.changed {
            guard let n = from.node(id) else { continue }
            changing.append((id, n, from.path(of: id)?.indices.count ?? 0))
        }
        let appearing = d.added.filter { id in !to.ancestors(of: id).contains { d.added.contains($0.id) } }
        var vanishing: [(node: Node, parent: UUID?, index: Int)] = []
        for id in d.gone where !from.ancestors(of: id).contains(where: { d.gone.contains($0.id) }) {
            guard let n = from.node(id), let path = from.path(of: id) else { continue }
            vanishing.append((n, from.parent(of: id)?.id, path.indices.last ?? 0))
        }
        vanishing.sort { $0.index < $1.index }
        glide = Glide(began: now, from: changing.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) },
                      appearing: Array(appearing), vanishing: vanishing)
    }

    // MARK: Marks

    private(set) var hovered: UUID?

    /// The pointer over the canvas while looking back, at a canvas point, or gone (nil).
    func hover(_ p: CGPoint?) {
        let id = p.flatMap { shelf.layer(at: $0) }
        if id != hovered {
            hovered = id
            store.canvas?.needsDisplay = true
        }
    }

    private static let sepia = CGColor(srgbRed: 0.66, green: 0.43, blue: 0.22, alpha: 1)

    /// How far the marks are drawn, 0 to 1, once the layers have got there.
    private func inked(at now: CFTimeInterval) -> CGFloat {
        guard let g = glide else { return 1 }
        return CGFloat(min(max((now - g.began - Self.duration * 0.7) / Self.marking, 0), 1))
    }

    func drawMarks(_ ctx: CGContext, in bounds: CGRect, scale: CGFloat, at now: CFTimeInterval) {
        drawBroughtBack(ctx, in: bounds)
        guard let t = shelf.travel else { return }
        let vp = store.viewport
        let p = inked(at: now)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // What has been made since, faintly, where it will be.
        if p > 0 {
            ctx.setLineDash(phase: 0, lengths: [1.5, 3])
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CanvasInk.rulerInk.withAlphaComponent(0.22 * p).cgColor)
            for id in t.added where !store.doc.ancestors(of: id).contains(where: { t.added.contains($0.id) }) {
                guard let f = store.doc.absoluteFrame(of: id), !(store.doc.node(id)?.isArtboard ?? false) else { continue }
                let r = vp.toView(f)
                guard r.intersects(bounds), r.width > 4 || r.height > 4 else { continue }
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        for id in t.changed.union(t.gone) {
            guard let frame = t.doc.absoluteFrame(of: id) else { continue }
            // Within something that also differs, the outer one says enough.
            if t.doc.ancestors(of: id).contains(where: { (t.changed.contains($0.id) || t.gone.contains($0.id)) && !$0.isArtboard }) { continue }
            if t.doc.node(id)?.isArtboard == true, t.changed.contains(id) { continue }
            let r = vp.toView(frame)
            guard r.insetBy(dx: -12, dy: -12).intersects(bounds), r.width > 2 || r.height > 2 else { continue }
            let gone = t.gone.contains(id)
            let ink = gone ? Self.sepia : CanvasInk.pencil.cgColor
            if t.picked.contains(id) {
                ctx.setFillColor(ink.copy(alpha: 0.12) ?? ink)
                ctx.fill(r)
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(1.5)
                ctx.stroke(r.insetBy(dx: -0.75, dy: -0.75))
                drawCheck(ctx, at: CGPoint(x: r.maxX, y: r.minY), ink: ink)
            } else if p > 0 {
                ctx.setStrokeColor(ink.copy(alpha: hovered == id ? 1 : 0.85) ?? ink)
                ctx.setLineWidth(hovered == id ? 1.6 : 1.25)
                ctx.addPath(Self.corners(r.insetBy(dx: -4, dy: -4), arm: 9 * p))
                ctx.strokePath()
            }
            if hovered == id, !gone, let present = store.doc.absoluteFrame(of: id) {
                drawWhereItIsNow(ctx, then: r, now: vp.toView(present))
            }
        }
    }

    /// Crop marks at a rectangle's corners, their arms `arm` long.
    private static func corners(_ r: CGRect, arm: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let a = min(arm, r.width / 2, r.height / 2)
        guard a > 0.2 else { return p }
        for (c, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] as [(CGPoint, CGFloat, CGFloat)] {
            p.move(to: CGPoint(x: c.x, y: c.y + a * sy))
            p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x + a * sx, y: c.y))
        }
        return p
    }

    /// A layer that has changed since, pointed at: where it is now, faintly, and a pencil thread
    /// from where it was to there.
    private func drawWhereItIsNow(_ ctx: CGContext, then: CGRect, now: CGRect) {
        guard then != now else { return }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.stroke(now.insetBy(dx: 0.5, dy: 0.5))
        ctx.setLineDash(phase: 0, lengths: [])
        let a = CGPoint(x: then.midX, y: then.midY), b = CGPoint(x: now.midX, y: now.midY)
        if hypot(b.x - a.x, b.y - a.y) > 12 {
            // A thread that bows a little, as one held loosely does.
            let mid = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * 0.18, y: (a.y + b.y) / 2 + (b.x - a.x) * 0.18)
            ctx.move(to: a)
            ctx.addQuadCurve(to: b, control: mid)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.25)
            ctx.strokePath()
            ctx.setFillColor(CanvasInk.pencil.cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6))
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: a.x - 2, y: a.y - 2, width: 4, height: 4))
        }
        ctx.restoreGState()
    }

    /// A small round tick at a picked layer's corner.
    private func drawCheck(_ ctx: CGContext, at c: CGPoint, ink: CGColor) {
        let r: CGFloat = 7.5
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.18))
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: c.x - 3.2, y: c.y + 0.2))
        ctx.addLine(to: CGPoint(x: c.x - 0.9, y: c.y + 2.6))
        ctx.addLine(to: CGPoint(x: c.x + 3.4, y: c.y - 2.4))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Layers just brought back: their corners mark them landing, and fade.
    private func drawBroughtBack(_ ctx: CGContext, in bounds: CGRect) {
        guard let b = shelf.broughtBack else { return }
        let t = Date().timeIntervalSince(b.at)
        guard t < 1.1 else { return }
        let vp = store.viewport
        let p = CGFloat(t / 1.1)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(1 - p).cgColor)
        ctx.setLineWidth(1.6)
        for id in b.ids {
            guard let f = store.doc.absoluteFrame(of: id) else { continue }
            ctx.addPath(Self.corners(vp.toView(f).insetBy(dx: -4 - 6 * p, dy: -4 - 6 * p), arm: 9 + 4 * p))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Moving

    /// Whether the last frame had layers on their way.
    private(set) var isMoving = false

    var isAnimating: Bool {
        if glide != nil { return true }
        if let b = shelf.broughtBack, Date().timeIntervalSince(b.at) < 1.1 { return true }
        return false
    }
}
