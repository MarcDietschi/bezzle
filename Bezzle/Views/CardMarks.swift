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
            case .component:
                // Every copy of the component, wherever it is used.
                if let copy = doc.copy(holding: id), let inst = copy.instance {
                    let linked = Color(nsColor: CanvasInk.linked)
                    for other in doc.copies(of: inst.of) {
                        guard let f = doc.absoluteFrame(of: other.id) else { continue }
                        let r = Path(roundedRect: vp.toView(f).insetBy(dx: -3, dy: -3), cornerRadius: 3)
                        ctx.fill(r, with: .color(linked.opacity(other.id == copy.id ? 0.1 : 0.06)))
                        ctx.stroke(r, with: .color(linked.opacity(other.id == copy.id ? 1 : 0.7)), lineWidth: other.id == copy.id ? 1.5 : 1)
                    }
                }
            case .mask:
                // The shape that holds, wherever what is picked lies in it.
                let mask = node.isMask ? node : doc.parent(of: id)
                if let mask, mask.isMask, let shape = Mask.outline(of: mask.id, in: doc) {
                    let seen = Path(shape).applying(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
                    ctx.stroke(seen, with: .color(pencil.opacity(0.18)), lineWidth: 6)
                    ctx.stroke(seen, with: .color(pencil), lineWidth: 1.5)
                }
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
            case .shadow(let slot):
                let shadow = node[shadow: slot]
                if shadow.inside {
                    ctx.stroke(outline, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    // Where it falls, as far round as it spreads.
                    let cast = Renderer.spreads(node, shadow) ? Renderer.spreadOutline(of: node, by: shadow.grown).map {
                        Path($0.copy(using: [Renderer.localTransform(node)]) ?? $0).applying(toView)
                    } : nil
                    let fallen = (cast ?? outline).applying(CGAffineTransform(translationX: shadow.x * vp.zoom, y: shadow.y * vp.zoom))
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
            case .curve:
                // The line the words run along, as far as it goes.
                if let laid = CurvedText.laid(node) {
                    let t = CurveTool.toCanvas(node, origin: o)
                        .concatenating(CGAffineTransform(translationX: -vp.origin.x, y: -vp.origin.y))
                        .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom))
                    let line = Path { p in p.addLines(laid.walk.points.map { $0.applying(t) }) }
                    ctx.stroke(line, with: .color(pencil), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    ctx.stroke(around, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            case .depth:
                ctx.stroke(around, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            case .export:
                // What goes into the file: the artboard, or all the layer paints, shadow and all.
                let reach = node.isArtboard ? box : Renderer.reach(of: node).offsetBy(dx: o.x, dy: o.y)
                let corner = vp.toView(reach.origin)
                let cut = Path(CGRect(x: corner.x, y: corner.y, width: reach.width * vp.zoom, height: reach.height * vp.zoom))
                ctx.fill(cut, with: .color(pencil.opacity(0.06)))
                ctx.stroke(cut, with: .color(pencil), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .layout, .guides, .appearance:
                // The grid and the guides light up on the canvas themselves; the sheet they lie on is outlined.
                ctx.stroke(Path(vp.toView(box)), with: .color(pencil.opacity(0.5)), lineWidth: 1)
            case .frame, .arrange, .artboard, .deck, .grid:
                ctx.stroke(around, with: .color(pencil), lineWidth: 1.5)
            case .photo:
                // Nothing over the picture, which has to be seen as it is: only a hairline round it.
                ctx.stroke(outline, with: .color(pencil.opacity(0.5)), lineWidth: 1)
            case .flow, .screen, .states:
                // The prototype's own marks are on the canvas already.
                break
            }
        }
    }
}
