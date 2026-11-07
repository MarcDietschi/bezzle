import Foundation

// Masks, shared by every Bezzle: which layer of several would hold the rest, held over a shape
// while dragged, made, and layers taken out of one. See `Mask`.

/// What a mask is made of, worked out once, so what the canvas shows before it is made is what
/// is made: the shape that will hold, and the layers it will hold, back to front.
struct MaskPlan: Equatable {
    /// A shape, or a mask already, which then holds them as well.
    let shape: UUID
    let held: [UUID]
}

extension BezzleDocument {
    /// Of several layers, the one that holds the rest: a mask among them, or else the frontmost
    /// shape that shows no picture, as a shape drawn over a photo or put under one is, or else
    /// the frontmost shape. What it holds has to overlap it, or would vanish.
    func maskPlan(_ ids: [UUID]) -> MaskPlan? {
        let doc = self
        guard let ids = doc.groupable(ids), ids.count > 1 else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard nodes.count == ids.count, !nodes.contains(where: \.locked) else { return nil }
        // Front to back.
        let order = ids.compactMap { id in doc.path(of: id).map { (id: id, at: $0.indices) } }
            .sorted { $1.at.lexicographicallyPrecedes($0.at) }.map(\.id)
        let shape = order.first { doc.node($0)?.isMask == true }
            ?? order.first { doc.node($0).map { Mask.canHold($0) && $0.fill.image == nil } == true }
            ?? order.first { doc.node($0).map(Mask.canHold) == true }
        guard let shape, let reach = doc.absoluteFrame(of: shape) else { return nil }
        let held = order.reversed().filter { $0 != shape }
        guard held.contains(where: { id in doc.absoluteFrame(of: id).map { $0.intersects(reach) } == true }) else { return nil }
        return MaskPlan(shape: shape, held: held)
    }

    /// Layers being moved, held over a layer, as a mask: the shape it is, or the mask it lies in,
    /// holding them. Nil when it cannot hold them, or is one of them or in one.
    func dipPlan(_ moving: [UUID], over target: UUID) -> MaskPlan? {
        let doc = self
        guard let node = doc.node(target), !node.locked, node.isMask || Mask.canHold(node), !moving.contains(target) else { return nil }
        let above = Set(doc.ancestors(of: target).map(\.id))
        guard !moving.contains(where: above.contains),
              !doc.ancestors(of: target).contains(where: \.isRepeatGrid), !node.isRepeatGrid,
              moving.allSatisfy({ doc.node($0).map { !$0.isArtboard && !$0.locked } == true }) else { return nil }
        // What a mask holds already is no more held by it for being dragged about inside it.
        let held = moving.filter { doc.parent(of: $0)?.id != target }
        guard !held.isEmpty else { return nil }
        let back = held.compactMap { id in doc.path(of: id).map { (id: id, at: $0.indices) } }
            .sorted { $0.at.lexicographicallyPrecedes($1.at) }.map(\.id)
        return MaskPlan(shape: target, held: back)
    }

    /// Puts layers inside a shape, or into a mask on top of what it holds already, each staying
    /// where it is on the canvas, and returns the mask. A new mask takes the shape's place, so
    /// what lay over the shape still does.
    @discardableResult
    mutating func mask(_ plan: MaskPlan) -> UUID? {
        guard let shape = node(plan.shape) else { return nil }
        let held = plan.held.filter { $0 != plan.shape && node($0) != nil }
        guard !held.isEmpty else { return nil }
        let taken = held.compactMap { detach($0) }
        if shape.isMask {
            for layer in taken { attach(layer, to: plan.shape) }
            return plan.shape
        }
        // Where the shape is once they are out.
        guard let at = path(of: plan.shape), let alone = detach(plan.shape) else { return nil }
        var group = Node(kind: .group, name: Mask.name(in: self), frame: .zero)
        group.clipsToFirst = true
        // A shape lying straight on a deck's post keeps its mask in that post.
        group.post = alone.post
        var inside = alone
        inside.post = nil
        // Taken out onto the canvas, and so into a group lying at the canvas's top left, they keep
        // where they are; it is fitted round its shape afterwards.
        group.children = [inside] + taken.map { var n = $0; n.post = nil; return n }
        attach(group, to: at.parent.map { self[$0].id }, at: at.indices.last!)
        return group.id
    }

    /// Takes layers out of the masks they lie in, each just above its mask, in the same order
    /// back to front; a mask left holding nothing is its shape again.
    mutating func takeOutOfMasks(_ ids: [UUID]) {
        let back = ids.compactMap { id in path(of: id).map { (id: id, at: $0.indices) } }
            .sorted { $0.at.lexicographicallyPrecedes($1.at) }.map(\.id)
        var placed: [UUID: Int] = [:]
        for id in back {
            guard let mask = parent(of: id), mask.isMask, mask.children.first?.id != id,
                  let at = path(of: mask.id) else { continue }
            let holder = at.parent.map { self[$0].id }
            let k = placed[mask.id, default: 0]
            guard let layer = detach(id) else { continue }
            attach(layer, to: holder, at: at.indices.last! + 1 + k)
            placed[mask.id] = k + 1
        }
    }
}
