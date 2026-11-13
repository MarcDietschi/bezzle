import Foundation

// The Mac's VectorTool (Canvas/VectorTool.swift) ported: what the canvas shows of a picture being
// vectorized. Drawn over the stage in one picture a frame (`draw`), which the canvas shows above
// the artboards, as the Mac draws it over the canvas.
//
// Tracing takes a moment at most; should it take longer, a pencil line goes across the picture
// as it does while one is cut out. Once the shapes are made, the pencil passes over the picture
// once: before it the picture is still the picture, behind it it is its shapes, their outlines
// drawn in pencil just where the pencil was, and gone again a little further back.
//
// What differs from the Mac's, for how Windows draws: the Mac keeps the picture as it was drawn
// for tracing and draws that ahead of the pencil; here the layer as it was is drawn again each
// frame, as the cutout's drop is, into the frame's picture, which Skia plays.

extension WindowsCore {
    public final class VectorHand {
        public init() {}

        /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero

        /// How long the pencil's pass takes, how far behind it the outlines show, as a share of the
        /// picture's width, and how long tracing goes on before a pencil line says so.
        private static let pass = 0.85
        private static let trail: CGFloat = 0.3
        private static let patience = 0.3
        private static let sweep = 1.15
        private static let pencil = RGBA(hex: "3A63D8")!

        /// Whether the canvas has to draw again soon, for something moving here.
        public var animating: Bool { !vectorizing.isEmpty || !vectorReveals.isEmpty }

        /// From a layer's own coordinates, its top left at zero, to the stage.
        private func toView(_ frame: CGRect, _ rotation: Double) -> CGAffineTransform {
            CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: Geometry.radians(rotation))
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y))
        }

        /// What the canvas draws over the stage now, `stage` big, at `scale` pixels a point, into
        /// pixels as `render(board:)` makes them; where on the stage, or nil for nothing.
        public func draw(scale: Double, stage: CGSize, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            let now = WindowsCore.now
            var working: [(node: Node, frame: CGRect, began: Double)] = []
            for (id, work) in vectorizing where now - work.began > Self.patience {
                guard let doc = design, let node = doc.node(id), let frame = doc.absoluteFrame(of: id) else { continue }
                working.append((node, frame, work.began))
            }
            var revealing: [VectorReveal] = []
            for (id, reveal) in vectorReveals {
                guard (now - reveal.at) / Self.pass < 1 else {
                    vectorReveals[id] = nil
                    continue
                }
                revealing.append(reveal)
            }
            var box = CGRect.null
            for w in working { box = box.union(CGRect(origin: .zero, size: w.frame.size).applying(toView(w.frame, w.node.rotation))) }
            for r in revealing { box = box.union(CGRect(origin: .zero, size: r.frame.size).applying(toView(r.frame, r.rotation))) }
            // Room for the pencil's width beside the frame.
            box = box.insetBy(dx: -4, dy: -4).intersection(CGRect(origin: .zero, size: stage))
            guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
            return WindowsCore.overlay(box: box, scale: scale, into: fill) { ctx in
                for w in working { self.working(w.node, w.frame, w.began, now, ctx) }
                for r in revealing { self.reveal(r, now, scale: scale, ctx) }
            }
        }

        /// A pencil line going to and fro across a picture that takes a while to trace.
        private func working(_ node: Node, _ frame: CGRect, _ began: Double, _ now: Double, _ ctx: CGContext) {
            inLayer(frame, node.rotation, ctx) { size, point in
                ctx.beginPath()
                ctx.addPath(Renderer.outline(of: node))
                ctx.clip(using: node.evenOdd == true ? .evenOdd : .winding)
                let phase = (now - began - Self.patience) / Self.sweep
                let along = phase - floor(phase)
                let x = size.width * CGFloat(-0.15 + 1.3 * (0.5 - 0.5 * cos(along * .pi)))
                ctx.setAlpha(Self.ease(min((now - began - Self.patience) / 0.2, 1)))
                self.pencil(at: x, size, point, ctx)
            }
        }

        /// The pencil passing over a picture just made shapes: the picture still ahead of it, the
        /// shapes' outlines just behind it.
        private func reveal(_ reveal: VectorReveal, _ now: Double, scale: Double, _ ctx: CGContext) {
            let t = (now - reveal.at) / Self.pass
            // Eased in and out, from just before the picture to where the last outlines have gone.
            let e = CGFloat(0.5 - 0.5 * cos(min(max(t, 0), 1) * .pi))
            inLayer(reveal.frame, reveal.rotation, ctx) { size, point in
                let x = size.width * (-0.04 + (1.08 + Self.trail) * e)
                // The picture still, where the pencil has not been.
                if x < size.width {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: max(x, 0), y: 0, width: size.width - max(x, 0), height: size.height))
                    ctx.interpolationQuality = .high
                    let options = Renderer.Options(deviceScale: CGFloat(scale) * self.zoom, assets: assets)
                    Renderer.withFlippedContext(ctx) { Renderer.drawNode(reveal.picture, in: ctx, options: options) }
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
                    ctx.beginPath()
                    ctx.addPath(reveal.outlines)
                    ctx.setStrokeColor(Self.ink(alpha))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                if x > -point, x < size.width + point { self.pencil(at: x, size, point, ctx) }
            }
        }

        /// The pencil's line down the layer at `x`.
        private func pencil(at x: CGFloat, _ size: CGSize, _ point: CGFloat, _ ctx: CGContext) {
            ctx.setFillColor(Self.ink(1))
            ctx.fill(CGRect(x: x - point * 0.75, y: 0, width: point * 1.5, height: size.height))
        }

        /// `body` drawn in a layer's own coordinates, its top left at zero, told the layer's size
        /// and how much of it a point on screen is.
        private func inLayer(_ frame: CGRect, _ rotation: Double, _ ctx: CGContext, _ body: (CGSize, CGFloat) -> Void) {
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.concatenate(toView(frame, rotation))
            body(frame.size, 1 / max(zoom, 0.0001))
        }

        private static func ink(_ alpha: CGFloat) -> CGColor { CGColor(red: pencil.r, green: pencil.g, blue: pencil.b, alpha: alpha) }
        private static func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - max(t, 0), 3)) }
    }
}
