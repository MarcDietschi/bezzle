import AppKit

/// What the canvas shows of a picture being vectorized.
///
/// Tracing takes a moment at most; should it take longer, a pencil line goes across the picture
/// as it does while one is cut out. Once the shapes are made, the pencil passes over the picture
/// once: before it the picture is still the picture, behind it it is its shapes, their outlines
/// drawn in pencil just where the pencil was, and gone again a little further back.
final class VectorTool {
    private let store: DocumentStore

    init(store: DocumentStore) {
        self.store = store
    }

    /// How long the pencil's pass takes, how far behind it the outlines show, as a share of the
    /// picture's width, and how long tracing goes on before a pencil line says so.
    private static let pass: CFTimeInterval = 0.85
    private static let trail: CGFloat = 0.3
    private static let patience: CFTimeInterval = 0.3
    private static let sweep: CFTimeInterval = 1.15

    /// Whether the canvas has to draw again soon, for something moving here.
    var animating: Bool { !store.vectorizing.isEmpty || !store.vectorReveals.isEmpty }

    func draw(_ ctx: CGContext, scale: CGFloat) {
        let now = CACurrentMediaTime()
        for (id, work) in store.vectorizing where now - work.began > Self.patience {
            guard let node = store.node(id), let frame = store.doc.absoluteFrame(of: id) else { continue }
            inLayer(frame, node.rotation, ctx) { size, point in
                ctx.addPath(Renderer.outline(of: node))
                ctx.clip(using: node.evenOdd == true ? .evenOdd : .winding)
                let phase = (now - work.began - Self.patience) / Self.sweep
                let along = phase - floor(phase)
                let x = size.width * CGFloat(-0.15 + 1.3 * (0.5 - 0.5 * cos(along * .pi)))
                ctx.setAlpha(Self.ease(min((now - work.began - Self.patience) / 0.2, 1)))
                pencil(at: x, size, point, ctx)
            }
        }
        for (id, reveal) in store.vectorReveals {
            let t = (now - reveal.at) / Self.pass
            guard t < 1 else {
                store.vectorReveals[id] = nil
                continue
            }
            // Eased in and out, from just before the picture to where the last outlines have gone.
            let e = CGFloat(0.5 - 0.5 * cos(min(max(t, 0), 1) * .pi))
            inLayer(reveal.frame, reveal.rotation, ctx) { size, point in
                let x = size.width * (-0.04 + (1.08 + Self.trail) * e)
                // The picture still, where the pencil has not been.
                if x < size.width {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: max(x, 0), y: 0, width: size.width - max(x, 0), height: size.height))
                    ctx.interpolationQuality = .high
                    ctx.translateBy(x: 0, y: size.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(reveal.image, in: CGRect(origin: .zero, size: size))
                    ctx.restoreGState()
                }
                // The outlines where it has just been: clearest right behind it.
                let reach = size.width * Self.trail
                ctx.setLineWidth(point)
                ctx.setLineJoin(.round)
                for (from, alpha) in [(1.0, 0.16), (0.62, 0.22), (0.3, 0.3)] as [(CGFloat, CGFloat)] {
                    let band = CGRect(x: x - reach * from, y: 0, width: reach * from, height: size.height).intersection(CGRect(origin: .zero, size: size))
                    guard !band.isEmpty else { continue }
                    ctx.saveGState()
                    ctx.clip(to: band)
                    ctx.addPath(reveal.outlines)
                    ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(alpha).cgColor)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                if x > -point, x < size.width + point { pencil(at: x, size, point, ctx) }
            }
        }
    }

    /// The pencil's line down the layer at `x`.
    private func pencil(at x: CGFloat, _ size: CGSize, _ point: CGFloat, _ ctx: CGContext) {
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fill(CGRect(x: x - point * 0.75, y: 0, width: point * 1.5, height: size.height))
    }

    /// `body` drawn in a layer's own coordinates, its top left at zero, told the layer's size and
    /// how much of it a point on screen is.
    private func inLayer(_ frame: CGRect, _ rotation: Double, _ ctx: CGContext, _ body: (CGSize, CGFloat) -> Void) {
        let viewport = store.viewport
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: Geometry.radians(rotation))
            .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
            .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom).translatedBy(x: -viewport.origin.x, y: -viewport.origin.y)))
        body(frame.size, 1 / max(viewport.zoom, 0.0001))
    }

    private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - max(t, 0), 3)) }
}
