import Foundation
import CoreGraphics

// What a click on the canvas picks, shared by every Bezzle: the Mac's CanvasView asks these, and
// so does the Windows canvas, so the same layer is picked under the same point everywhere.

extension Node {
    /// The post a deck shows in front, for a viewer who has put `fronts[deck]` in front: that
    /// one while it is there, else the first.
    func front(in fronts: [UUID: Int]) -> Int? {
        let posts = posts
        if let f = fronts[id], posts.contains(f) { return f }
        return posts.first
    }

    /// What lies on an artboard as it is seen: for a deck, the post in front.
    func seenLayers(fronts: [UUID: Int]) -> [Node] {
        isDeck ? layers(of: front(in: fronts)) : children
    }
}

extension BezzleDocument {
    /// The repeat grid a layer is or lies in.
    func grid(holding id: UUID) -> Node? {
        if let n = node(id), n.isRepeatGrid { return n }
        return ancestors(of: id).last { $0.isRepeatGrid }
    }
}

/// What a click at a canvas point picks, for a design as one viewer sees it: `selection` (the
/// group it is in is looked in first, as after a double click into it), `fronts` (each deck's
/// post in front), and `zoom` (how near the pointer must come: 4 points on the screen, and 12
/// for a mask's edge).
struct Picking {
    let doc: BezzleDocument
    var selection: [UUID] = []
    var fronts: [UUID: Int] = [:]
    var zoom: CGFloat = 1

    var tolerance: CGFloat { 4 / zoom }

    /// The topmost layer under a canvas point that a click would select: on an artboard, what
    /// lies on it (its empty space hides what lies under it); on the canvas, a layer or an artboard.
    func hit(_ p: CGPoint) -> UUID? {
        for node in doc.nodes.reversed() where !node.hidden {
            if node.isArtboard {
                let inside = node.frame.contains(p)
                guard inside || !node.clips else { continue }
                let local = p - node.frame.origin
                // Nearer before further, as they are drawn (`DepthOrder`), each seen from the artboard's eye.
                let eye = doc.stage(of: node)
                if let child = topmost(node.seenLayers(fronts: fronts), at: local, eye: eye) { return child.id }
                if inside { return nil }
            } else if !node.locked, Geometry.contains(node, p, tolerance: tolerance) {
                return node.id
            }
        }
        return nil
    }

    /// The topmost of layers lying together under a point of what holds them, as a click takes
    /// it: nearer before further, as they are drawn (`DepthOrder.scene`), so a layer of a group
    /// that keeps depth standing over a layer beside the group is met first, and takes the click
    /// for its group. Hidden and locked layers are passed through.
    func topmost<C: Collection>(_ nodes: C, at p: CGPoint, eye: Eye?) -> Node? where C.Element == Node {
        let listed = Array(nodes)
        let seen = eye?.lens?.shown(p) ?? p
        for piece in DepthOrder.scene(listed, eye: eye).reversed() {
            let top = listed[piece.top]
            guard !top.hidden, !top.locked, let q = piece.placed(seen) else { continue }
            if Geometry.contains(piece.node, q, tolerance: tolerance, eye: piece.eye) { return top }
        }
        return nil
    }

    /// The group the selection is in, where clicks look first, as they do after a double click into it.
    var enteredGroup: Node? {
        guard let first = selection.first, let parent = doc.parent(of: first), parent.isGroup else { return nil }
        return parent
    }

    /// What in a group lies under a canvas point, one level down. In a mask, only what shows
    /// inside its shape; along its edge, the shape itself, to take hold of it rather than of what
    /// it holds. A hidden shape still cuts off, but is not there to be taken hold of.
    /// The layer a picture or words let go at a point land on: the one under it, and inside a
    /// group, the one in it under the point, however deep.
    func dropTarget(_ p: CGPoint) -> UUID? {
        guard var id = hit(p) else { return nil }
        while let n = doc.node(id), n.isGroup, let inner = hit(p, in: n) { id = inner }
        return id
    }

    func hit(_ p: CGPoint, in group: Node) -> UUID? {
        guard let inner = doc.placed(p, inside: group.id) else { return nil }
        let eye = doc.eye(inside: group.id)
        if let holder = group.holder {
            guard Mask.inside(holder, inner, tolerance: tolerance) else { return nil }
            let takes = !holder.locked && !holder.hidden
            let edge = Renderer.heldOutline(of: holder).copy(strokingWithWidth: 12 / zoom, lineCap: .round, lineJoin: .round, miterLimit: 4)
            if takes, edge.contains(inner) { return holder.id }
            return topmost(group.children.dropFirst(), at: inner, eye: eye)?.id ?? (takes ? holder.id : nil)
        }
        return topmost(group.children, at: inner, eye: eye)?.id
    }

    /// Something picked inside a mask, where its ghost shows past the mask's shape.
    func pickedGhost(at p: CGPoint) -> UUID? {
        guard let mask = enteredGroup, let holder = mask.holder, let inner = doc.placed(p, inside: mask.id),
              !Mask.inside(holder, inner, tolerance: 0) else { return nil }
        let eye = doc.eye(inside: mask.id)
        return DepthOrder.stacked(mask.children.dropFirst()).reversed().first { child in
            selection.contains(child.id) && !child.hidden && !child.locked && Geometry.contains(child, inner, tolerance: tolerance, eye: eye)
        }?.id
    }

    /// What a click picks: something in the group the selection is in, or else what is under it as
    /// usual. Anything lying over that group is picked as usual, as it is what the click meets.
    func pick(_ p: CGPoint) -> UUID? {
        if let id = pickedGhost(at: p) { return id }
        if let group = enteredGroup, uncovered(group, at: p), let id = hit(p, in: group) { return id }
        if let id = pickInOtherCell(p) { return id }
        return hit(p)
    }

    /// Whether a click at a canvas point meets this group before anything else: at every level from
    /// the canvas down, what lies on top there is the group or what holds it.
    func uncovered(_ group: Node, at p: CGPoint) -> Bool {
        let chain = doc.ancestors(of: group.id).filter { !$0.isArtboard } + [group]
        guard hit(p) == chain[0].id else { return false }
        return zip(chain, chain.dropFirst()).allSatisfy { outer, inner in hit(p, in: outer) == inner.id }
    }

    /// Inside a cell of a repeat grid, a click on another cell picks what lies there as deep in it
    /// as the selection lies in its own, as if that cell had been entered the same way.
    func pickInOtherCell(_ p: CGPoint) -> UUID? {
        guard let group = enteredGroup, let grid = doc.grid(holding: group.id), grid.id != group.id, uncovered(grid, at: p),
              let here = RepeatGrid.cell(of: group.id, in: grid, doc: doc),
              let root = hit(p, in: grid), let there = RepeatGrid.cell(of: root, in: grid, doc: doc),
              let other = doc.node(group.id.mixed(RepeatGrid.key(here.cell)).mixed(RepeatGrid.key(there.cell))) else { return nil }
        return hit(p, in: other)
    }

    /// What Select All picks: beside the selection, everything lying with it; with nothing
    /// selected, what lies on the artboard in view (`focused`); else every layer and artboard on
    /// the canvas. Hidden and locked layers are left out.
    func all(focused: Node?) -> [UUID] {
        if let first = selection.first, let parent = doc.parent(of: first) {
            return (parent.isArtboard ? parent.seenLayers(fronts: fronts) : parent.children).filter { !$0.hidden && !$0.locked }.map(\.id)
        }
        if let board = focused, !board.children.isEmpty, selection.isEmpty {
            return board.seenLayers(fronts: fronts).filter { !$0.hidden && !$0.locked }.map(\.id)
        }
        return doc.nodes.filter { !$0.hidden && !$0.locked }.map(\.id)
    }

    /// What a box dragged on the canvas picks: on the artboard it began on (`inside`), what it
    /// touches there; on the canvas, the layers it touches and the artboards it holds whole.
    func marquee(_ rect: CGRect, inside: UUID?) -> [UUID] {
        if let inside, let board = doc.node(inside) {
            let local = rect.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
            let eye = doc.stage(of: board)
            return board.seenLayers(fronts: fronts).filter { !$0.hidden && !$0.locked && Geometry.bounds(of: $0, eye: eye).intersects(local) }.map(\.id)
        }
        return doc.nodes.filter { n in !n.hidden && !n.locked && (n.isArtboard ? rect.contains(n.frame) : Geometry.bounds(of: n).intersects(rect)) }.map(\.id)
    }
}
