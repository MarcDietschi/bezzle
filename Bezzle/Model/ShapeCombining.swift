import Foundation

/// The ways overlapping shapes become one path.
enum ShapeCombine: CaseIterable {
    /// All of them, as one outline.
    case union
    /// The shape at the back, less what lies in front of it.
    case subtract
    /// Only where they all overlap.
    case intersect
    /// Only where an odd number of them lie, so where two overlap is cut out.
    case exclude

    var title: LocalizedStringResource {
        switch self {
        case .union: "Union"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .exclude: "Exclude Overlap"
        }
    }
}

extension BezzleDocument {
    /// The shapes among `selection` that can be combined, back first: rectangles, ellipses and
    /// paths, not locked.
    func combinable(_ selection: [UUID]) -> [UUID] {
        selection.filter { id in node(id).map { [.rectangle, .ellipse, .path].contains($0.kind) && !$0.locked } == true }
            .compactMap { id in path(of: id).map { (id, $0.indices) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map(\.0)
    }

    /// Whether `selection` is two or more shapes and nothing else.
    func canCombine(_ selection: [UUID]) -> Bool {
        selection.count >= 2 && combinable(selection).count == selection.count
    }

    /// The selected shapes made one path, styled as the one at the back, its frame on the canvas
    /// (as `place(combined:replacing:)` takes it); nil when nothing would be left of them.
    func combined(_ selection: [UUID], _ how: ShapeCombine) -> Node? {
        guard canCombine(selection) else { return nil }
        let ids = combinable(selection)
        let outlines = ids.compactMap { outline(of: $0) }
        guard outlines.count == ids.count, let back = node(ids[0]) else { return nil }
        let rest = outlines.dropFirst()
        let combined = switch how {
        case .union: rest.reduce(outlines[0]) { $0.union($1) }
        case .subtract: rest.reduce(outlines[0]) { $0.subtracting($1) }
        case .intersect: rest.reduce(outlines[0]) { $0.intersection($1) }
        case .exclude: rest.reduce(outlines[0]) { $0.symmetricDifference($1) }
        }
        let shape = Outlines.cleaned(combined)
        let o = parentOrigin(of: back.id)
        guard !shape.isEmpty, var made = back.reshaped(to: shape, origin: o) else { return nil }
        made.id = UUID()
        made.frame = made.frame.offsetBy(dx: o.x, dy: o.y)
        return made
    }

    /// Puts a combined shape just above the frontmost of the shapes it was made from, which then
    /// go with the rest: what lay over it still does.
    mutating func place(combined made: Node, replacing selection: [UUID]) {
        let ids = combinable(selection)
        guard let last = ids.last, let front = path(of: last) else { return }
        attach(made, to: front.parent.map { self[$0].id }, at: front.indices[front.indices.count - 1] + 1)
        for id in ids { _ = detach(id) }
    }
}
