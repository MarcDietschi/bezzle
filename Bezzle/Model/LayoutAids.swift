import Foundation

// Layout grids and guides as every Bezzle changes them: the artboard's own, kept within what can
// be had. What shows and what catches (the Mac's Helpers) stays with each app.

nonisolated extension Node {
    /// The layout grid changed, kept within what can be had; a grid left with nothing in it goes.
    /// Only an artboard has one.
    mutating func changeLayout(_ change: (inout LayoutGrid) -> Void) {
        guard isArtboard else { return }
        var grid = layout ?? LayoutGrid()
        change(&grid)
        grid.columns = grid.columns?.tidied
        grid.rows = grid.rows?.tidied
        grid.baseline = grid.baseline?.tidied
        layout = grid.orNil
    }
}

extension BezzleDocument {
    mutating func changeLayout(of board: UUID, _ change: (inout LayoutGrid) -> Void) {
        update(board) { $0.changeLayout(change) }
    }

    /// The columns that suit an artboard's size (a carousel's slide's).
    mutating func addLayout(to board: UUID) {
        guard let node = node(board), node.isArtboard else { return }
        let size = LayoutGrid.areas(of: node).first?.size ?? node.frame.size
        changeLayout(of: board) { $0 = LayoutGrid.suggested(for: size) }
    }

    mutating func removeLayout(from board: UUID) {
        update(board) { $0.layout = nil }
    }

    /// A guide put on an artboard, at a place across it (`vertical`) or down it; its key.
    @discardableResult
    mutating func addGuide(at position: CGFloat, vertical: Bool, to board: UUID) -> String? {
        guard let node = node(board), node.isArtboard else { return nil }
        let key = Guideline.key(besides: (node.guides ?? [:]).keys)
        let guide = Guideline.at(position, vertical: vertical, in: node.frame.size)
        update(board) { n in n.guides = (n.guides ?? [:]).merging([key: guide]) { _, new in new } }
        return self.node(board)?.guides?[key] != nil ? key : nil
    }

    /// A guide put somewhere else on its artboard, kept to the edge it is nearer now; whether it moved.
    @discardableResult
    mutating func moveGuide(_ key: String, on board: UUID, to position: CGFloat) -> Bool {
        guard let node = node(board), let guide = node.guides?[key] else { return false }
        let moved = Guideline.at(position, vertical: guide.vertical, in: node.frame.size)
        guard moved != guide else { return false }
        update(board) { $0.guides?[key] = moved }
        return true
    }

    mutating func removeGuide(_ key: String, from board: UUID) {
        update(board) { n in
            n.guides?[key] = nil
            if n.guides?.isEmpty == true { n.guides = nil }
        }
    }

    mutating func removeGuides(from board: UUID) {
        update(board) { $0.guides = nil }
    }

    /// The guides an artboard's layout grid wants where its columns, or rows, start and end (the
    /// margins), less those it has already.
    func guidesAtMargins(of board: UUID) -> [Guideline] {
        guard let node = node(board), let grid = node.layout else { return [] }
        let size = node.frame.size
        var wanted: [Guideline] = []
        if let c = grid.columns {
            wanted += [Guideline(vertical: true, edge: .start, offset: c.margin), Guideline(vertical: true, edge: .end, offset: c.margin)]
        }
        if let r = grid.rows {
            wanted += [Guideline(vertical: false, edge: .start, offset: r.margin), Guideline(vertical: false, edge: .end, offset: r.margin)]
        }
        let have = Set((node.guides ?? [:]).values.map { "\($0.vertical) \($0.position(in: size))" })
        return wanted.filter { !have.contains("\($0.vertical) \($0.position(in: size))") }
    }

    /// Guides put where an artboard's layout grid's columns, or rows, start and end.
    mutating func addGuides(_ fresh: [Guideline], to board: UUID) {
        guard !fresh.isEmpty else { return }
        update(board) { n in
            var all = n.guides ?? [:]
            for g in fresh { all[Guideline.key(besides: all.keys)] = g }
            n.guides = all
        }
    }
}
