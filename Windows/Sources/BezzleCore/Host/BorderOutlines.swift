import Foundation

// Borders as shapes, as the Mac's Object › Outline Border (Store/ShapeOperations.swift).

extension WindowsCore {
    /// The layers with a border that could be a shape of its own.
    private static func outlinable(_ ids: [UUID]) -> [UUID] {
        guard let doc = design else { return [] }
        return ids.filter { id in
            guard let n = doc.node(id), !n.locked else { return false }
            return (BezzleDocument.cuttable.contains(n.kind) || n.kind == .line) && n.borders.contains { $0.width > 0 }
        }
    }

    public static func canOutlineBorders(_ ids: [UUID]) -> Bool { !outlinable(ids).isEmpty }

    /// Turns each layer's border into a shape filled with its paint, which scales as a shape does
    /// rather than keeping its width. It goes just above the layer, which keeps its fill; a layer
    /// that was all border becomes the shape. Answers the shapes made, to select.
    public static func outlineBorders(_ selection: [UUID]) -> [UUID] {
        let ids = outlinable(selection)
        guard !ids.isEmpty else { return [] }
        var made: [UUID] = []
        edit { doc in
            for id in ids {
                guard let n = doc.node(id), let line = doc.line(of: id), let at = doc.path(of: id) else { continue }
                let closed = n.kind != .line && (n.kind != .path || (doc.points(of: id)?.subpaths.allSatisfy(\.closed) ?? false))
                let inside = doc.outline(of: id) ?? line
                let o = doc.parentOrigin(of: id)
                let keepsFill = n.fill.on && n.kind != .line
                // Each border a shape of its own, one over another as they were drawn.
                var above = at.indices[at.indices.count - 1] + 1
                for (i, border) in n.borders.enumerated() {
                    // Filled as the border was drawn: a gradient lying where it lay.
                    var painted = n
                    painted.fill = border.paint
                    painted.fill.on = true
                    guard let area = Outlines.covered(by: border, along: line, inside: inside, closed: closed),
                          var shape = painted.reshaped(to: area, origin: o) else { continue }
                    shape.moreFills = nil
                    shape.border = Border()
                    shape.moreBorders = nil
                    if keepsFill || i > 0 {
                        shape.id = UUID()
                        shape.name = String(localized: "\(n.name) Border")
                        // The layer's shadows fall from the layer, as they did.
                        shape.shadows = []
                        shape.frame = shape.frame.offsetBy(dx: o.x, dy: o.y)
                        doc.attach(shape, to: at.parent.map { doc[$0].id }, at: above)
                        above += 1
                    } else {
                        doc.update(id) { $0 = shape }
                    }
                    made.append(shape.id)
                }
                if keepsFill {
                    doc.update(id) { n in
                        n.border.on = false
                        n.moreBorders = nil
                    }
                }
            }
        }
        return made
    }
}
