import AppKit

/// The path tools that make new shapes out of those there are: building with the pieces
/// overlapping shapes cut each other into, cutting with the knife, pulling an outline out or in,
/// and turning a border into a shape. Each leaves paths that look as the shapes they came from.
extension DocumentStore {
    /// Rectangles, ellipses and paths: the shapes these tools work on.
    static let cuttable: Set<Node.Kind> = [.rectangle, .ellipse, .path]

    /// Shapes in the order they are drawn, back first.
    func backFirst(_ ids: [UUID]) -> [UUID] {
        ids.compactMap { id in doc.path(of: id).map { (id, $0.indices) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map(\.0)
    }

    // MARK: Building

    /// Starts building with the selected shapes: the canvas shows the pieces they cut each
    /// other into, to be joined or wiped away.
    func startBuilding() {
        guard canCombine else { return }
        editingPath = nil
        building = backFirst(selection)
    }

    /// The shapes being built with that are still there, back first.
    var buildShapes: [UUID] {
        backFirst((building ?? []).filter { node($0) != nil })
    }

    /// The pieces the shapes being built with cut each other into, worked out once for each
    /// version of the design. Each says which of `buildShapes` cover it.
    var buildPieces: [Outlines.Piece] {
        let ids = buildShapes
        if let worked = piecesWorkedOut, worked.version == version, worked.ids == ids { return worked.pieces }
        let pieces = Outlines.pieces(of: ids.compactMap { doc.outline(of: $0) })
        piecesWorkedOut = (version, ids, pieces)
        return pieces
    }

    /// Joins the pieces into one shape, or wipes them away. The joined shape looks as the
    /// frontmost shape over the first piece, and lies over all the shapes it took from; those
    /// keep the rest of themselves, and go when nothing is left.
    func build(_ picked: [Int], erase: Bool) {
        let ids = buildShapes, pieces = buildPieces
        let chosen = picked.filter { pieces.indices.contains($0) }
        guard let first = chosen.first, let touched = Outlines.union(chosen.map { pieces[$0].outline }) else { return }
        let from = Set(chosen.flatMap { pieces[$0].covers })
        // One whole shape picked on its own would only become itself.
        if !erase, from.count == 1, let only = from.first,
           pieces.indices.filter({ pieces[$0].covers.contains(only) }).allSatisfy(chosen.contains) { return }

        var made: Node?
        if !erase, let look = pieces[first].covers.last.flatMap({ node(ids[$0]) }) {
            let o = doc.parentOrigin(of: look.id)
            if var joined = look.reshaped(to: touched, origin: o) {
                joined.id = UUID()
                joined.frame = joined.frame.offsetBy(dx: o.x, dy: o.y)
                made = joined
            }
        }
        let frontmost = from.max().map { ids[$0] }
        var kept: [UUID] = []
        edit(erase ? "Erase Pieces" : "Join Pieces") { doc in
            if let made, let frontmost, let at = doc.path(of: frontmost) {
                doc.attach(made, to: at.parent.map { doc[$0].id }, at: at.indices[at.indices.count - 1] + 1)
            }
            for (i, id) in ids.enumerated() {
                guard from.contains(i) else { kept.append(id); continue }
                guard let outline = doc.outline(of: id), let n = doc.node(id) else { continue }
                let rest = Outlines.cleaned(outline.subtracting(touched))
                if rest.isEmpty {
                    _ = doc.detach(id)
                } else if let reshaped = n.reshaped(to: rest, origin: doc.parentOrigin(of: id)) {
                    doc.update(id) { $0 = reshaped }
                    kept.append(id)
                }
            }
        }
        let now = backFirst(kept + (made.map { [$0.id] } ?? []))
        selection = now
        building = now.count > 0 ? now : nil
    }

    // MARK: Cutting

    /// Cuts the shapes `line` (on the canvas) runs right across into pieces: the selected
    /// shapes it parts, or, when it parts none of them, every shape it does. Each piece looks as
    /// the shape did and lies where it lay. Returns whether anything was cut.
    @discardableResult
    func cut(along line: CGPath) -> Bool {
        let reach = line.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        func pieces(_ ids: [UUID]) -> [(UUID, [CGPath])] {
            ids.compactMap { id in
                guard let n = node(id), Self.cuttable.contains(n.kind), !n.locked, !n.hidden,
                      let frame = doc.absoluteFrame(of: id), Geometry.bounds(of: frame, rotation: n.rotation).intersects(reach),
                      let outline = doc.outline(of: id), let parts = Outlines.cut(outline, along: line) else { return nil }
                return (id, parts)
            }
        }
        var cuts = pieces(selection)
        if cuts.isEmpty {
            let shown = doc.allNodes.filter { n in !n.hidden && !doc.ancestors(of: n.id).contains { $0.hidden || $0.locked } }
            cuts = pieces(shown.map(\.id))
        }
        guard !cuts.isEmpty else { return false }
        var made: [UUID] = []
        edit("Cut") { doc in
            for (id, parts) in cuts {
                guard let n = doc.node(id), let at = doc.path(of: id) else { continue }
                let o = doc.parentOrigin(of: id), parent = at.parent.map { doc[$0].id }
                let index = at.indices[at.indices.count - 1]
                // In place of the shape, in the order the pieces came.
                for (k, part) in parts.enumerated() {
                    guard var piece = n.reshaped(to: part, origin: o) else { continue }
                    piece.id = UUID()
                    piece.frame = piece.frame.offsetBy(dx: o.x, dy: o.y)
                    doc.attach(piece, to: parent, at: index + 1 + k)
                    made.append(piece.id)
                }
                _ = doc.detach(id)
            }
        }
        selection = made
        return true
    }

    // MARK: Pulling an outline out or in

    /// Whether the layer's outline can be pulled out or in: a shape whose fill closes it in.
    func canOffset(_ id: UUID) -> Bool {
        guard let n = node(id), Self.cuttable.contains(n.kind), !n.locked else { return false }
        return n.kind != .path || n.fill.on || (points(of: id)?.subpaths.allSatisfy(\.closed) ?? false)
    }

    /// A copy of the layer with its outline `distance` further out all round, behind it, or
    /// further in, in front of it. Within a gesture, `copy` is the one made already, which this
    /// replaces. Returns the copy, or nil when shrinking leaves nothing.
    @discardableResult
    func offsetCopy(of id: UUID, by distance: CGFloat, round: Bool, replacing copy: UUID?) -> UUID? {
        guard let n = node(id), let outline = doc.outline(of: id) else { return nil }
        let shape = Outlines.offset(outline, by: distance, round: round)
        var made = shape.flatMap { n.reshaped(to: $0, origin: doc.parentOrigin(of: id)) }
        made?.id = copy ?? UUID()
        made?.name = "\(n.name) \(distance >= 0 ? "Outset" : "Inset")"
        edit(distance >= 0 ? "Outset" : "Inset") { doc in
            if let copy { _ = doc.detach(copy) }
            guard var made, let at = doc.path(of: id) else { return }
            let o = doc.parentOrigin(of: id)
            made.frame = made.frame.offsetBy(dx: o.x, dy: o.y)
            let index = at.indices[at.indices.count - 1]
            doc.attach(made, to: at.parent.map { doc[$0].id }, at: distance >= 0 ? index : index + 1)
        }
        return made?.id
    }

    // MARK: Borders as shapes

    /// The selected layers with a border that could be a shape of its own.
    private var outlinable: [UUID] {
        selection.filter { id in
            guard let n = node(id), !n.locked else { return false }
            return (Self.cuttable.contains(n.kind) || n.kind == .line) && n.border.on && n.border.width > 0
        }
    }

    var canOutlineBorders: Bool { !outlinable.isEmpty }

    /// Turns each selected layer's border into a shape filled with its colour, which scales as
    /// a shape does rather than keeping its width. It goes just above the layer, which keeps its
    /// fill; a layer that was all border becomes the shape.
    func outlineBorders() {
        let ids = outlinable
        guard !ids.isEmpty else { return }
        var made: [UUID] = []
        edit(ids.count == 1 ? "Outline Border" : "Outline Borders") { doc in
            for id in ids {
                guard let n = doc.node(id), let line = doc.line(of: id), let at = doc.path(of: id) else { continue }
                let closed = n.kind != .line && (n.kind != .path || (doc.points(of: id)?.subpaths.allSatisfy(\.closed) ?? false))
                let inside = doc.outline(of: id) ?? line
                guard let area = Outlines.covered(by: n.border, along: line, inside: inside, closed: closed) else { continue }
                let o = doc.parentOrigin(of: id)
                guard var shape = n.reshaped(to: area, origin: o) else { continue }
                shape.fill = Fill(color: n.border.color)
                shape.border = Border()
                let keepsFill = n.fill.on && n.kind != .line
                if keepsFill {
                    shape.id = UUID()
                    shape.name = "\(n.name) Border"
                    // The layer's shadow falls from the layer, as it did.
                    shape.shadow.on = false
                    shape.frame = shape.frame.offsetBy(dx: o.x, dy: o.y)
                    doc.update(id) { $0.border.on = false }
                    doc.attach(shape, to: at.parent.map { doc[$0].id }, at: at.indices[at.indices.count - 1] + 1)
                } else {
                    doc.update(id) { $0 = shape }
                }
                made.append(shape.id)
            }
        }
        if !made.isEmpty { selection = made }
    }
}
