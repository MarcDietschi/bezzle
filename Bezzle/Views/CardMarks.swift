import SwiftUI
import AppKit

/// Over the canvas, in pencil, the part of the selected layers that the inspector card under the
/// pointer changes: their corners, their fill, their edge, where their shadow falls, their blur,
/// their box. It shows what a preset or a dashed card would add while it is pointed at, too, and
/// never takes a click.
struct CardMarks: View {
    let store: DocumentStore

    var body: some View {
        ZStack {
            if let aspect = store.pointedAspect, !store.selection.isEmpty {
                // Read here rather than while drawing, so a change to any of them draws the marks again.
                let doc = store.shownDoc, viewport = store.viewport, ids = store.selection
                Canvas { ctx, _ in draw(aspect, of: ids, in: doc, viewport: viewport, into: &ctx) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: store.pointedAspect)
        .allowsHitTesting(false)
    }

    private func draw(_ aspect: Aspect, of ids: [UUID], in doc: BezzleDocument, viewport vp: Viewport, into ctx: inout GraphicsContext) {
        let pencil = Color(nsColor: CanvasInk.pencil)
        for id in ids {
            guard let node = doc.node(id), let box = doc.absoluteFrame(of: id) else { continue }
            let o = doc.parentOrigin(of: id)
            let toView = CGAffineTransform(translationX: o.x, y: o.y)
                .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
            let outline = Path(Renderer.placedOutline(of: node)).applying(toView)
            // The layer's box, a little way out from it, as handles would sit.
            let around = Path { p in
                p.addLines(Geometry.corners(of: box.insetBy(dx: -4 / vp.zoom, dy: -4 / vp.zoom), rotation: node.rotation).map(vp.toView))
                p.closeSubpath()
            }
            switch aspect {
            case .fill, .opacity, .background:
                ctx.fill(outline, with: .color(pencil.opacity(0.18)))
                ctx.stroke(outline, with: .color(pencil.opacity(0.6)), lineWidth: 1)
            case .border, .text, .path, .cell, .post:
                ctx.stroke(outline, with: .color(pencil.opacity(0.18)), lineWidth: 6)
                ctx.stroke(outline, with: .color(pencil), lineWidth: 1.5)
            case .corners:
                // The outline only where it turns, round each corner.
                let reach = max(min(node.cornerRadius, min(box.width, box.height) / 2) * vp.zoom * 1.4, 14)
                let spots = Path { p in
                    for c in Geometry.corners(of: box, rotation: node.rotation).map(vp.toView) {
                        p.addEllipse(in: CGRect(x: c.x - reach, y: c.y - reach, width: reach * 2, height: reach * 2))
                    }
                }
                ctx.drawLayer { layer in
                    layer.clip(to: spots)
                    layer.stroke(outline, with: .color(pencil), lineWidth: 2)
                }
            case .shadow:
                let shadow = node.shadow
                if shadow.inside {
                    ctx.stroke(outline, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    let fallen = outline.applying(CGAffineTransform(translationX: shadow.x * vp.zoom, y: shadow.y * vp.zoom))
                    ctx.fill(fallen, with: .color(pencil.opacity(0.08)))
                    ctx.stroke(fallen, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            case .blur:
                let bounds = outline.boundingRect
                let lines = Path { p in
                    var x = bounds.minX - bounds.height
                    while x < bounds.maxX {
                        p.move(to: CGPoint(x: x, y: bounds.maxY))
                        p.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                        x += 6
                    }
                }
                ctx.drawLayer { layer in
                    layer.clip(to: outline)
                    layer.stroke(lines, with: .color(pencil.opacity(0.35)), lineWidth: 1)
                }
                ctx.stroke(outline, with: .color(pencil), lineWidth: 1)
            case .depth:
                ctx.stroke(around, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            case .frame, .arrange, .artboard, .deck, .grid:
                ctx.stroke(around, with: .color(pencil), lineWidth: 1.5)
            }
        }
    }
}
