import AppKit

/// Gaps as wide as each other while something is moved, shown so the rhythm reads before any
/// number does: each gap filled with a fine hatch between the two sides facing across it, so
/// even gaps look like the same tile laid down again. The gap beside what moves carries its width
/// on a solid label; those it is as wide as carry it outlined. A gap springs open from its middle
/// as it catches, those further along the row a moment after the nearer ones, so the rhythm runs
/// out from what moves; it folds away when it lets go.
final class GapMarks {
    private struct Mark {
        var guide: Guide
        var open = DeckTool.Spring(0)
        /// How long before it starts to open.
        var wait: Double = 0
    }

    /// A gap by where it lies, to half a point.
    private struct Key: Hashable {
        let edges: [Int]

        init(_ guide: Guide) {
            let r = guide.field ?? .zero
            edges = [r.minX, r.minY, r.maxX, r.maxY].map { Int(($0 * 2).rounded()) }
        }
    }

    private var marks: [Key: Mark] = [:]
    private var last: CFTimeInterval?

    /// How long after the gap beside what moves each one further along opens.
    private static let ripple = 0.045

    var isAnimating: Bool { marks.values.contains { $0.open.isMoving || $0.wait > 0 } }

    /// Takes in the gaps there are to show now: new ones open, and those no longer there fold away.
    func show(_ guides: [Guide]) {
        let gaps = guides.filter(\.gap)
        let keys = Set(gaps.map(Key.init))
        for k in marks.keys where !keys.contains(k) {
            marks[k]?.open.target = 0
            marks[k]?.wait = 0
        }
        let opening = gaps.filter { marks[Key($0)].map { $0.open.target == 0 } ?? true }
        guard !opening.isEmpty || gaps.contains(where: { marks[Key($0)]?.guide != $0 }) else { return }
        // Nearer what moves first: its own gaps, then the others by how far they are from them.
        let middles = gaps.filter(\.mine).compactMap { $0.field.map { CGPoint(x: $0.midX, y: $0.midY) } }
        func distance(_ g: Guide) -> CGFloat {
            guard let f = g.field, !g.mine else { return 0 }
            return middles.map { hypot($0.x - f.midX, $0.y - f.midY) }.min() ?? 0
        }
        let order = opening.sorted { distance($0) < distance($1) }
        for (rank, g) in order.enumerated() {
            var m = marks[Key(g)] ?? Mark(guide: g)
            m.open.target = 1
            m.wait = g.mine ? 0 : Double(rank) * Self.ripple
            marks[Key(g)] = m
        }
        for g in gaps { marks[Key(g)]?.guide = g }
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(now - (last ?? now), 1.0 / 30)
        last = now
        for k in marks.keys {
            guard var m = marks[k] else { continue }
            if m.wait > 0 {
                m.wait -= dt
            } else if m.open.target > 0 {
                // A little past open and back, as a spring does.
                m.open.step(dt, stiffness: 380, damping: 20)
            } else {
                m.open.step(dt, stiffness: 700, damping: 55)
            }
            marks[k] = m
        }
        marks = marks.filter { !($0.value.open.target == 0 && $0.value.open.settled) }
        if marks.isEmpty { last = nil }
    }

    func draw(_ ctx: CGContext, viewport: Viewport, scale: CGFloat) {
        step()
        guard !marks.isEmpty else { return }
        let ink = CanvasInk.gap
        let shown = marks.values.filter { $0.open.value > 0.01 }
        for m in shown { drawField(m, ctx, viewport: viewport, scale: scale, ink: ink) }
        // Their own above the ones they match.
        for m in shown.sorted(by: { !$0.guide.mine && $1.guide.mine }) { drawLabel(m, ctx, viewport: viewport, ink: ink) }
    }

    private static func across(_ g: Guide) -> Bool { abs(g.to.x - g.from.x) >= abs(g.to.y - g.from.y) }

    /// The gap shaded in a fine hatch, opened from its middle as far as it has come, with a line
    /// against each of its two sides; all of it fading out towards its ends, as pencil shading
    /// does, so it sits as well against round corners as square ones.
    private func drawField(_ m: Mark, _ ctx: CGContext, viewport: Viewport, scale: CGFloat, ink: NSColor) {
        guard let field = m.guide.field else { return }
        let open = CGFloat(m.open.value), fade = min(open, 1)
        let across = Self.across(m.guide)
        var r = viewport.toView(field)
        if across {
            r = CGRect(x: r.minX, y: r.midY - r.height * open / 2, width: r.width, height: r.height * open)
        } else {
            r = CGRect(x: r.midX - r.width * open / 2, y: r.minY, width: r.width * open, height: r.height)
        }
        guard r.width > 0, r.height > 0 else { return }
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
        ctx.saveGState()
        ctx.setAlpha(fade)
        ctx.beginTransparencyLayer(in: r.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
        ctx.setFillColor(ink.withAlphaComponent(0.07).cgColor)
        ctx.fill(r)
        // Hatched at forty-five degrees from its own corner, so even gaps look alike line for line.
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1 / scale)
        var x = r.minX - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.maxY))
            ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 4
        }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(ink.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        if across {
            for side in [r.minX, r.maxX] {
                ctx.move(to: CGPoint(x: pixel(side), y: r.minY))
                ctx.addLine(to: CGPoint(x: pixel(side), y: r.maxY))
            }
        } else {
            for side in [r.minY, r.maxY] {
                ctx.move(to: CGPoint(x: r.minX, y: pixel(side)))
                ctx.addLine(to: CGPoint(x: r.maxX, y: pixel(side)))
            }
        }
        ctx.strokePath()
        // Faded towards both ends, over a sixth of its length, but never less than a few points.
        let length = across ? r.height : r.width
        let edge = min(max(length / 6, 6), length / 2) / length
        if let fadeOut = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                    colorComponents: [0, 0, 0, 1, 0, 1, 0, 0] as [CGFloat],
                                    locations: [0, edge, 1 - edge, 1] as [CGFloat], count: 4) {
            ctx.setBlendMode(.destinationIn)
            let start = across ? CGPoint(x: r.midX, y: r.minY) : CGPoint(x: r.minX, y: r.midY)
            let end = across ? CGPoint(x: r.midX, y: r.maxY) : CGPoint(x: r.maxX, y: r.midY)
            ctx.drawLinearGradient(fadeOut, start: start, end: end, options: [])
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The gap's width in its middle, growing in with it: solid beside what moves, outlined on
    /// the gaps it is as wide as.
    private func drawLabel(_ m: Mark, _ ctx: CGContext, viewport: Viewport, ink: NSColor) {
        let g = m.guide
        let text = CanvasView.number(hypot(g.to.x - g.from.x, g.to.y - g.from.y)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: g.mine ? NSColor.white : ink,
        ]
        let size = text.size(withAttributes: attrs)
        let a = viewport.toView(g.from), b = viewport.toView(g.to)
        let middle = CGPoint(x: ((a.x + b.x) / 2).rounded(), y: ((a.y + b.y) / 2).rounded())
        let pill = CGRect(x: middle.x - (size.width / 2 + 5).rounded(), y: middle.y - 8.5, width: (size.width + 10).rounded(), height: 17)
        let grow = CGFloat(max(m.open.value, 0))
        ctx.saveGState()
        ctx.setAlpha(min(grow, 1))
        ctx.translateBy(x: middle.x, y: middle.y)
        ctx.scaleBy(x: grow, y: grow)
        ctx.translateBy(x: -middle.x, y: -middle.y)
        let shape = CGPath(roundedRect: pill, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)
        if g.mine {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: ink.withAlphaComponent(0.35).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(ink.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        text.draw(at: CGPoint(x: pill.minX + (pill.width - size.width) / 2, y: pill.minY + (pill.height - size.height) / 2), withAttributes: attrs)
        ctx.restoreGState()
    }
}
