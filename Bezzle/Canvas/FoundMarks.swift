import AppKit

extension CanvasView {
    /// Marks on the canvas what the find bar finds: each found word lit as a highlighter would,
    /// the one picked out brighter and ringed, or for misspelt words a wavy line under each.
    func drawFound(_ ctx: CGContext) {
        guard let finder = store.finder else { return }
        let matches = store.foundText
        guard !matches.isEmpty else { return }
        let current = store.currentFind
        let doc = store.seenDoc
        let view = store.visibleCanvasRect
        let zoom = store.viewport.zoom
        for m in matches {
            guard let node = doc.node(m.layer), node.kind == .text, store.editingText != m.layer || finder.spelling == false,
                  let frame = doc.absoluteFrame(of: m.layer), frame.insetBy(dx: -40, dy: -40).intersects(view) else { continue }
            let picked = m == current
            for quad in Self.quads(of: m.range, in: node, id: m.layer, doc: doc) {
                let points = quad.map { store.viewport.toView($0) }
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                ctx.saveGState()
                if finder.spelling {
                    Self.squiggle(under: points, in: ctx, picked: picked, zoom: zoom)
                } else {
                    ctx.addPath(path)
                    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: picked ? 0.55 : 0.28).cgColor)
                    ctx.fillPath()
                    if picked {
                        ctx.addPath(path)
                        ctx.setStrokeColor(NSColor(srgbRed: 0.93, green: 0.6, blue: 0, alpha: 0.95).cgColor)
                        ctx.setLineWidth(1.5)
                        ctx.strokePath()
                    }
                }
                ctx.restoreGState()
            }
        }
    }

    /// A wavy line along the bottom of a word, the way a misspelt word is marked as it is typed.
    private static func squiggle(under quad: [CGPoint], in ctx: CGContext, picked: Bool, zoom: CGFloat) {
        guard quad.count == 4 else { return }
        let a = quad[3], b = quad[2]
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return }
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let wave: CGFloat = 3, height: CGFloat = 1.6
        let path = CGMutablePath()
        var t: CGFloat = 0
        path.move(to: a)
        while t < length {
            let next = min(t + wave, length)
            let up = (Int(t / wave) % 2 == 0 ? 1 : -1) * height
            let mid = (t + next) / 2
            path.addQuadCurve(to: CGPoint(x: a.x + ux * next, y: a.y + uy * next),
                              control: CGPoint(x: a.x + ux * mid - uy * up * 2, y: a.y + uy * mid + ux * up * 2))
            t = next
        }
        if picked {
            let fill = CGMutablePath()
            fill.addLines(between: quad)
            fill.closeSubpath()
            ctx.addPath(fill)
            ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.14).cgColor)
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(srgbRed: 0.88, green: 0.16, blue: 0.16, alpha: picked ? 1 : 0.8).cgColor)
        ctx.setLineWidth(picked ? 1.6 : 1.2)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    /// The boxes some letters of a text take, each a line's worth, as four corners on the canvas.
    static func quads(of range: NSRange, in node: Node, id: UUID, doc: BezzleDocument) -> [[CGPoint]] {
        let laid = TextLayout.layout(node)
        guard NSMaxRange(range) <= laid.storage.length else { return [] }
        let glyphs = laid.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let down = TextLayout.offset(node)
        var rects: [CGRect] = []
        laid.manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: laid.container) { rect, _ in rects.append(rect) }
        let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
        return rects.map { r in
            let box = r.offsetBy(dx: node.frame.minX, dy: node.frame.minY + down).insetBy(dx: -1, dy: 0)
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                .map { doc.shown(Perspective.shown(Geometry.rotated($0, about: center, by: node.rotation), of: node), inParentOf: id) }
        }
    }
}
