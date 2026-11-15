import Foundation
import CoreGraphics

// The layers list as rows, and where a row dragged in it would go, shared by every Bezzle: the
// Mac's LayersPanel and the Windows one list and drop layers the same way.

/// A layer as the list shows it: how deep, and in what.
struct ListedLayer: Identifiable {
    let node: Node
    let depth: Int
    let parent: UUID?
    var id: UUID { node.id }
}

/// Where a dragged row would be let go: onto the row at an index (into what it shows), or into
/// the gap before an index.
nonisolated enum LayerDropSpot: Equatable {
    case gap(Int)
    case onto(Int)
}

extension Node {
    /// What a layer holds as the list shows it: a repeat grid only its first cell, which the
    /// others follow, and a deck only the post in front.
    func listed(fronts: [UUID: Int]) -> [Node] {
        if isDeck { return seenLayers(fronts: fronts) }
        guard isRepeatGrid, let layout = RepeatGrid.layout(of: self) else { return children }
        return [children[layout.first]]
    }
}

/// Dropping a row in the list: `rows` top first, `board` the artboard whose page is open (nil
/// for every layer), `isShut` whether a row's layer is folded, `rowHeight` the rows' height.
struct LayerDrop {
    let doc: BezzleDocument
    let rows: [ListedLayer]
    let board: Node?
    let isShut: (Node) -> Bool
    var rowHeight: CGFloat = 28

    /// The middle half of a row that can take the layer is onto it; anywhere else is the gap nearest.
    func spot(at y: CGFloat, for row: ListedLayer) -> LayerDropSpot {
        let at = y / rowHeight
        let i = Int(at.rounded(.down))
        if rows.indices.contains(i), abs(at - CGFloat(i) - 0.5) < 0.25, canHold(rows[i], row) { return .onto(i) }
        return .gap(min(max(Int(at.rounded()), 0), rows.count))
    }

    /// Whether `id` is the dragged layer or lies in it: nothing goes into itself, or into what it holds.
    func within(_ id: UUID, _ row: ListedLayer) -> Bool {
        id == row.id || doc.ancestors(of: id).contains { $0.id == row.id }
    }

    /// Whether the layer a row shows can take the dragged one: an artboard or a group, though no
    /// repeat grid, as its cells follow its first. Artboards themselves go into nothing.
    func canHold(_ target: ListedLayer, _ row: ListedLayer) -> Bool {
        !row.node.isArtboard && target.node.isContainer && !target.node.isRepeatGrid && !within(target.id, row)
    }

    /// Where a dropped layer goes: on top of what is in the row it was let go onto, or between
    /// the rows above and below the gap it was let go over; and how deep it would be listed.
    func destination(for row: ListedLayer, spot: LayerDropSpot) -> (parent: UUID?, index: Int, depth: Int)? {
        let slot: Int
        switch spot {
        case .onto(let i):
            guard rows.indices.contains(i), canHold(rows[i], row) else { return nil }
            return (rows[i].id, rows[i].node.children.count, rows[i].depth + 1)
        case .gap(let i):
            // A gap found while the list was longer (rows gone while the drag went on, by an
            // undo or another person's change) is the last there is now.
            slot = min(max(i, 0), rows.count)
        }
        var above = slot > 0 ? rows[slot - 1] : nil
        // Artboards only go between the layers on the canvas itself.
        if row.node.isArtboard {
            while let a = above, a.depth > 0 { above = rows.first { $0.id == a.parent } }
        }
        guard let above else { return board.map { ($0.id, $0.children.count, 0) } ?? (nil, doc.nodes.count, 0) }
        if above.id == row.id { return nil }
        if !row.node.isArtboard && above.node.isContainer && !isShut(above.node) {
            // Just under an open artboard's or group's name: on top of what is in it.
            return within(above.id, row) || above.node.isRepeatGrid ? nil : (above.id, above.node.children.count, above.depth + 1)
        }
        if let parent = above.parent, let container = doc.node(parent),
           let i = container.children.firstIndex(where: { $0.id == above.id }) {
            return row.node.isArtboard || within(parent, row) || container.isRepeatGrid ? nil : (parent, i, above.depth)
        }
        guard let i = doc.nodes.firstIndex(where: { $0.id == above.id }) else { return nil }
        return (nil, i, 0)
    }
}
