import Foundation
import CoreGraphics

// Cutting shapes apart, shared by every Bezzle: the knife's line parts the shapes it runs right
// across into pieces that look as they did, and the outlines and reshaping it takes. The Mac's
// store and the Windows core both cut this way.

extension BezzleDocument {
    /// Rectangles, ellipses and paths: the shapes the path tools work on.
    nonisolated static let cuttable: Set<Node.Kind> = [.rectangle, .ellipse, .path]

    /// The shapes `line` (on the canvas) runs right across, and the pieces each parts into: the
    /// selected shapes it parts, or, when it parts none of them, every shape it does.
    func cuts(along line: CGPath, selection: [UUID]) -> [(UUID, [CGPath])] {
        let reach = line.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        func pieces(_ ids: [UUID]) -> [(UUID, [CGPath])] {
            ids.compactMap { id in
                guard let n = node(id), Self.cuttable.contains(n.kind), !n.locked, !n.hidden,
                      let frame = absoluteFrame(of: id), Geometry.bounds(of: frame, rotation: n.rotation).intersects(reach),
                      let outline = outline(of: id), let parts = Outlines.cut(outline, along: line) else { return nil }
                return (id, parts)
            }
        }
        var cuts = pieces(selection)
        if cuts.isEmpty {
            let shown = allNodes.filter { n in !n.hidden && !ancestors(of: n.id).contains { $0.hidden || $0.locked } }
            cuts = pieces(shown.map(\.id))
        }
        return cuts
    }

    /// Each shape cut into its pieces, which look as it did and lie where it lay, in its place in
    /// the order they came. Returns the pieces.
    mutating func cut(_ cuts: [(UUID, [CGPath])]) -> [UUID] {
        var made: [UUID] = []
        for (id, parts) in cuts {
            guard let n = node(id), let at = path(of: id) else { continue }
            let o = parentOrigin(of: id), parent = at.parent.map { self[$0].id }
            // A mask's shape cut apart is a mask for each piece, each showing what it showed there.
            if let mask = self.parent(of: id), mask.holder?.id == id {
                made += Self.cut(mask, into: parts, origin: o, in: &self)
                continue
            }
            let index = at.indices[at.indices.count - 1]
            for (k, part) in parts.enumerated() {
                guard var piece = n.reshaped(to: part, origin: o) else { continue }
                piece.id = UUID()
                piece.frame = piece.frame.offsetBy(dx: o.x, dy: o.y)
                attach(piece, to: parent, at: index + 1 + k)
                made.append(piece.id)
            }
            _ = detach(id)
        }
        return made
    }

    /// A mask whose shape is cut into pieces, as a framed picture is cut through, frame and all:
    /// the first piece is its shape now, holding what it held, and each other piece the shape of a
    /// mask of its own just above it, holding a copy of all that. What shows stays as it was, in
    /// pieces that come apart. `origin` is where the mask's own coordinates start on the canvas.
    /// Returns the pieces.
    private static func cut(_ mask: Node, into parts: [CGPath], origin o: CGPoint, in doc: inout BezzleDocument) -> [UUID] {
        guard let shape = mask.holder, var at = doc.path(of: mask.id) else { return [] }
        let pieces = parts.compactMap { shape.reshaped(to: $0, origin: o) }
        guard var first = pieces.first else { return [] }
        // The first keeps being the shape it was, so the mask still knows it.
        first.id = shape.id
        doc.update(shape.id) { $0 = first }
        guard let whole = doc.node(mask.id) else { return [shape.id] }
        var made = [shape.id]
        for var piece in pieces.dropFirst() {
            piece.id = UUID()
            var copy = whole.freshCopy()
            copy.children[0] = piece
            copy.name = Mask.name(in: doc)
            at.indices[at.indices.count - 1] += 1
            doc.insert(copy, at: at)
            made.append(piece.id)
        }
        return made
    }
}

nonisolated extension BezzleDocument {
    /// The area a shape's fill covers, on the canvas, with no part of the outline crossing another.
    func outline(of id: UUID) -> CGPath? {
        guard let n = node(id), let p = n.kind == .path ? n : n.asPath(), let data = p.path else { return nil }
        let o = parentOrigin(of: id)
        var t = p.pathPlacement.concatenating(CGAffineTransform(translationX: o.x, y: o.y))
        return PathData.cgPath(data).copy(using: &t)?.normalized(using: n.evenOdd == true ? .evenOdd : .winding)
    }
}

extension BezzleDocument {
    /// A layer's outline on the canvas as it is drawn, open runs and all: what its border follows.
    func line(of id: UUID) -> CGPath? {
        guard let n = node(id) else { return nil }
        let o = parentOrigin(of: id)
        var t = CGAffineTransform(translationX: o.x, y: o.y)
        let placed = Renderer.placedOutline(of: n)
        return placed.copy(using: &t)
    }
}

nonisolated extension Node {
    /// The same layer as a path whose outline is `outline` on the canvas, its parent starting at
    /// `origin` there; its frame is in the parent, as any layer's. It keeps its turn and its look,
    /// and a gradient stays where it lay.
    func reshaped(to outline: CGPath, origin o: CGPoint) -> Node? {
        guard var made = kind == .path ? self : asPath() else { return nil }
        // In the layer's own upright coordinates, so the path keeps its turn.
        var toFrame = placement.concatenating(CGAffineTransform(translationX: o.x, y: o.y)).inverted()
        guard let upright = outline.copy(using: &toFrame) else { return nil }
        let box = upright.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return nil }
        made.frame = CGRect(center: CGPoint(x: box.midX, y: box.midY).applying(placement), size: box.size)
        made.path = PathData.string(upright)
        made.pathBox = box
        // What comes out of Core Graphics never crosses itself, and its holes wind the other way.
        made.evenOdd = nil
        made.fill.gradient = fill.gradient?.moved(from: frame.size, to: box)
        return made
    }
}
