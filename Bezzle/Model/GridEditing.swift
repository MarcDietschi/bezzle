import Foundation

// Repeat grids as every Bezzle makes and changes them: made of the selection, how many cells and
// how far apart, taken apart, and what each cell holds of its own. See `RepeatGrid`.

extension BezzleDocument {
    /// What would be repeated: the layers selected, if they lie together, none is locked, an
    /// artboard, a grid or a grid's cell.
    func repeatable(_ selection: [UUID]) -> [UUID]? {
        let ids = selection.filter { node($0)?.locked == false }
        guard !ids.isEmpty, ids.count == selection.count else { return nil }
        let parents = Set(ids.map { parent(of: $0)?.id })
        guard parents.count == 1, let parent = parents.first else { return nil }
        if let parent, node(parent)?.isRepeatGrid == true { return nil }
        guard ids.allSatisfy({ node($0).map { !$0.isArtboard && !$0.isRepeatGrid } == true }) else { return nil }
        return ids
    }

    /// Puts layers that lie together into a new repeat grid, where the topmost of them was, and
    /// returns its id: one layer is the cell itself, several are grouped into one first.
    @discardableResult
    mutating func makeRepeatGrid(of ids: [UUID], columns: Int = 1, rows: Int = 1,
                                 columnGap: CGFloat? = nil, rowGap: CGFloat? = nil, name: String? = nil) -> UUID? {
        guard let firstID = ids.first else { return nil }
        let parentID = parent(of: firstID)?.id
        let at = parentID.flatMap { path(of: $0) }
        var siblings = at.map { self[$0].children } ?? nodes
        let chosen = Set(ids)
        guard let top = siblings.lastIndex(where: { chosen.contains($0.id) }) else { return nil }
        let picked = siblings.filter { chosen.contains($0.id) }
        // In a group of their own, they keep where they are: it starts at its parent's top left
        // and is fitted round them.
        var cell = picked[0]
        if picked.count > 1 {
            cell = Node(kind: .group, name: nextName(for: .group), frame: .zero)
            cell.children = picked
        }
        let size = RepeatGrid.box(of: cell).size
        let gap = RepeatGrid.gap(for: size)
        var grid = Node(kind: .group, name: name ?? gridName(), frame: .zero)
        grid.grid = RepeatGrid(columns: RepeatGrid.clamped(columns), rows: RepeatGrid.clamped(rows),
                               columnGap: columnGap ?? gap, rowGap: rowGap ?? gap)
        grid.children = [cell]
        siblings.removeAll { chosen.contains($0.id) }
        siblings.insert(grid, at: top + 1 - picked.count)
        if let at {
            var holder = self[at]
            holder.children = siblings
            self[at] = holder
        } else {
            nodes = siblings
        }
        return grid.id
    }

    private func gridName() -> String {
        let taken = Set(allNodes.map(\.name))
        var i = 1
        while taken.contains(String(localized: "Repeat Grid \(i)")) { i += 1 }
        return String(localized: "Repeat Grid \(i)")
    }

    /// How many cells a grid has, or how far apart they are, changed, kept within what can be had.
    mutating func changeGrid(_ id: UUID, _ change: (inout RepeatGrid) -> Void) {
        update(id) { node in
            guard var spec = node.grid else { return }
            change(&spec)
            spec.columns = RepeatGrid.clamped(spec.columns)
            spec.rows = RepeatGrid.clamped(spec.rows)
            spec.columnGap = spec.columnGap.rounded()
            spec.rowGap = spec.rowGap.rounded()
            node.grid = spec
            node.refit()
        }
    }

    /// A grid made a plain group of the cells it has, each a layer of its own from then on.
    mutating func ungroupGrid(_ id: UUID) {
        update(id) { n in
            n.grid = nil
            n.refit()
        }
    }

    /// Each cell's copy of a text layer given the next of `values`, from the first cell on, and
    /// round again when there are fewer of them than cells.
    mutating func fillCells(_ slot: UUID, in gridID: UUID, with values: [String]) {
        guard let grid = node(gridID), !values.isEmpty else { return }
        for (i, id) in copies(of: slot, in: grid).enumerated() {
            update(id) { n in
                guard n.kind == .text else { return }
                n.text = values[i % values.count]
                n.refit()
            }
        }
    }

    /// Each cell's copy of a shape given the next of these pictures, and round again.
    mutating func fillCells(_ slot: UUID, in gridID: UUID, withPictures pictures: [ImageFill]) {
        guard let grid = node(gridID), !pictures.isEmpty else { return }
        for (i, id) in copies(of: slot, in: grid).enumerated() {
            update(id) { n in
                guard [.rectangle, .ellipse, .path].contains(n.kind) else { return }
                n.fill.on = true
                n.fill.image = pictures[i % pictures.count]
            }
        }
    }

    /// What each cell holds in a slot: its words, or its picture.
    func cellContents(_ slot: UUID, in grid: Node) -> [(text: String?, image: ImageFill?)] {
        copies(of: slot, in: grid).compactMap { node($0) }.map { ($0.kind == .text ? $0.text : nil, $0.fill.image) }
    }

    /// Which cell holds which of the words or pictures in a slot mixed up, never as it was.
    mutating func shuffleCells(_ slot: UUID, in gridID: UUID) {
        guard let grid = node(gridID) else { return }
        var held = cellContents(slot, in: grid)
        guard held.count > 1 else { return }
        let was = held
        for _ in 0..<8 where held.map(\.text) == was.map(\.text) && held.map(\.image) == was.map(\.image) { held.shuffle() }
        for (id, h) in zip(copies(of: slot, in: grid), held) {
            update(id) { n in
                if n.kind == .text, let text = h.text {
                    n.text = text
                    n.refit()
                } else if n.kind != .text {
                    n.fill.image = h.image
                }
            }
        }
    }

    /// Every cell given what one cell holds (`id`, a layer of it) in its slot.
    mutating func sameInEveryCell(_ id: UUID) {
        guard let grid = grid(holding: id), let slot = slot(of: id), let source = node(id) else { return }
        if source.kind == .text {
            fillCells(slot, in: grid.id, with: [source.text ?? ""])
        } else if let image = source.fill.image {
            fillCells(slot, in: grid.id, withPictures: [image])
        } else {
            for id in copies(of: slot, in: grid) { update(id) { $0.fill.image = nil } }
        }
    }

    /// A grid's text layers filled from text (see `assignments`); how many were filled.
    @discardableResult
    mutating func fillCells(_ gridID: UUID, from text: String, startingWith preferred: UUID? = nil) -> Int {
        guard let grid = node(gridID) else { return 0 }
        let filled = assignments(from: text, in: grid, startingWith: preferred)
        for (slot, values) in filled { fillCells(slot, in: gridID, with: values) }
        return filled.count
    }
}

extension RepeatGrid {
    /// Changes the layer with this id somewhere in a grid, however deep.
    static func change(_ id: UUID, in node: inout Node, _ body: (inout Node) -> Void) {
        if node.id == id {
            body(&node)
            return
        }
        for i in node.children.indices { change(id, in: &node.children[i], body) }
    }
}
