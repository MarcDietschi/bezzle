import AppKit

/// The path tools that make new shapes out of those there are: building with the pieces
/// overlapping shapes cut each other into, cutting with the knife, pulling an outline out or in,
/// and turning a border into a shape. Each leaves paths that look as the shapes they came from.
extension DocumentStore {
    /// Rectangles, ellipses and paths: the shapes these tools work on.
    static let cuttable = BezzleDocument.cuttable

    /// Shapes in the order they are drawn, back first (the shared `BezzleDocument.backFirst`).
    func backFirst(_ ids: [UUID]) -> [UUID] { doc.backFirst(ids) }

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
        let pieces = doc.buildPieces(of: ids)
        piecesWorkedOut = (version, ids, pieces)
        return pieces
    }

    /// Joins the pieces into one shape, or wipes them away. The joined shape looks as the
    /// frontmost shape over the first piece, and lies over all the shapes it took from; those
    /// keep the rest of themselves, and go when nothing is left.
    func build(_ picked: [Int], erase: Bool) {
        let ids = buildShapes
        guard let plan = doc.buildPlan(picked, erase: erase, shapes: ids, pieces: buildPieces) else { return }
        var now: [UUID] = []
        edit(erase ? "Erase Pieces" : "Join Pieces") { doc in now = doc.build(plan, shapes: ids) }
        selection = now
        building = now.count > 0 ? now : nil
    }

    // MARK: Cutting

    /// Cuts the shapes `line` (on the canvas) runs right across into pieces (the shared
    /// `BezzleDocument.cuts` and `cut`). Returns whether anything was cut.
    @discardableResult
    func cut(along line: CGPath) -> Bool {
        let cuts = doc.cuts(along: line, selection: selection)
        guard !cuts.isEmpty else { return false }
        var made: [UUID] = []
        edit(LocalizedStringResource("knife.cut", defaultValue: "Cut", comment: "Undo name: shapes cut apart with the knife.")) { doc in
            made = doc.cut(cuts)
        }
        selection = made
        return true
    }

    // MARK: Pulling an outline out or in

    /// Whether the layer's outline can be pulled out or in: a shape whose fill closes it in.
    func canOffset(_ id: UUID) -> Bool { doc.canOffset(id) }

    /// A copy of the layer with its outline `distance` further out all round, behind it, or
    /// further in, in front of it. Within a gesture, `copy` is the one made already, which this
    /// replaces. Returns the copy, or nil when shrinking leaves nothing (the shared
    /// `BezzleDocument.offsetCopy` and `place(offset:)`).
    @discardableResult
    func offsetCopy(of id: UUID, by distance: CGFloat, round: Bool, replacing copy: UUID?) -> UUID? {
        guard node(id) != nil, doc.outline(of: id) != nil else { return nil }
        let made = doc.offsetCopy(of: id, by: distance, round: round, as: copy ?? UUID())
        edit(distance >= 0 ? "Outset" : "Inset") { $0.place(offset: made, of: id, by: distance, replacing: copy) }
        return made?.id
    }

    // MARK: Borders as shapes

    /// The selected layers with a border that could be a shape of its own.
    private var outlinable: [UUID] {
        selection.filter { id in
            guard let n = node(id), !n.locked else { return false }
            return (Self.cuttable.contains(n.kind) || n.kind == .line) && n.borders.contains { $0.width > 0 }
        }
    }

    var canOutlineBorders: Bool { !outlinable.isEmpty }

    /// Turns each selected layer's border into a shape filled with its paint, which scales as
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
        if !made.isEmpty { selection = made }
    }
}
