import Foundation
import CoreGraphics

/// What a canvas decides about masks (see `Mask`), shared by every Bezzle: what a drag is held
/// over, whether resting there would mask it, whether it has been dragged off the mask it lies in,
/// and when to offer to mask what is picked. The Mac's MaskTool shows them with its springs.
extension BezzleDocument {
    /// Where a layer lies on the canvas: the bounds of its box, turned.
    func canvasBounds(of id: UUID) -> CGRect? {
        guard let n = node(id) else { return nil }
        let o = parentOrigin(of: id)
        return Geometry.bounds(of: n, eye: eye(forParentOf: id)).offsetBy(dx: o.x, dy: o.y)
    }

    /// Masking `ids` in the shape `over`, when that would cut something of them off that shows.
    func cuttingDip(_ ids: [UUID], over: UUID) -> MaskPlan? {
        guard let plan = dipPlan(ids, over: over), let shape = canvasBounds(of: over) else { return nil }
        var reach = CGRect.null
        for id in plan.held { if let r = canvasBounds(of: id) { reach = reach.union(r) } }
        // What an artboard cuts off anyway is no reason to.
        if let board = artboard(of: over), board.clips { reach = reach.intersection(board.frame) }
        guard !reach.isNull, reach.intersects(shape), !shape.insetBy(dx: -0.5, dy: -0.5).contains(reach) else { return nil }
        return plan
    }

    /// The shape, or the mask, a layer dragged to `p` on the canvas is held over: whatever is under
    /// the pointer there, leaving out what is being dragged, down into groups as far as the shape
    /// itself. Something else on top, such as a text, is what is under the pointer, and no shape
    /// is. `seen` is what lies on an artboard as it is seen (a deck's post in front).
    func maskTarget(at p: CGPoint, moving: [UUID], seen: (Node) -> [Node]) -> UUID? {
        let skip = Set(moving)
        func find(_ nodes: [Node], _ q: CGPoint) -> (found: UUID?, stop: Bool) {
            for n in nodes.reversed() where !n.hidden && !n.locked && !skip.contains(n.id) {
                let inner = CGPoint(x: q.x - n.frame.minX, y: q.y - n.frame.minY)
                if let holder = n.holder {
                    guard Mask.inside(holder, inner, tolerance: 0) else { continue }
                    return (n.id, true)
                }
                if n.isGroup {
                    let r = find(n.children, inner)
                    if r.stop { return r }
                    continue
                }
                guard Geometry.contains(n, q, tolerance: 0) else { continue }
                return (Mask.canHold(n) ? n.id : nil, true)
            }
            return (nil, false)
        }
        for top in nodes.reversed() where !top.hidden {
            if top.isArtboard {
                guard top.frame.contains(p) else { continue }
                return find(seen(top), CGPoint(x: p.x - top.frame.minX, y: p.y - top.frame.minY)).found
            }
            let r = find([top], p)
            if r.stop { return r.found }
        }
        return nil
    }

    /// The mask the layers being moved lie in, when they have been dragged wholly off its shape.
    func leavingMask(_ ids: [UUID]) -> UUID? {
        guard let first = ids.first, let mask = parent(of: first), let holder = mask.holder,
              ids.allSatisfy({ parent(of: $0)?.id == mask.id && $0 != holder.id }),
              let outline = Mask.outline(of: mask.id, in: self) else { return nil }
        let off = ids.allSatisfy { id in
            guard let r = canvasBounds(of: id) else { return true }
            return !outline.intersects(CGPath(rect: r, transform: nil))
        }
        return off ? mask.id : nil
    }

    /// After a shape has been drawn, moved or resized, picked alone: the picture under it to offer
    /// to mask in it, when the shape lies mostly over one that reaches past it, as a shape drawn
    /// over a photo to frame it does.
    func maskInvitation(_ selection: [UUID]) -> MaskPlan? {
        guard selection.count == 1, let id = selection.first, let shape = node(id), Mask.canHold(shape),
              shape.fill.image == nil, !shape.locked, let at = path(of: id), let frame = canvasBounds(of: id) else { return nil }
        let siblings = at.parent.map { self[$0].children } ?? nodes
        let i = at.indices.last!
        for other in siblings[..<i].reversed() where !other.hidden && !other.locked && other.post == shape.post {
            guard other.fill.on, other.fill.image != nil, Mask.canHold(other), let r = canvasBounds(of: other.id) else { continue }
            let both = r.intersection(frame)
            guard !both.isNull, both.width * both.height >= frame.width * frame.height * 0.5 else { continue }
            if frame.insetBy(dx: -0.5, dy: -0.5).contains(r) { return nil }
            return MaskPlan(shape: id, held: [other.id])
        }
        return nil
    }

    /// Several layers picked, one of them a shape all the rest overlap, which would cut something
    /// of them off (or a mask they would go into): the mask to offer. Picking things to move
    /// together does not ask.
    func maskOffer(_ selection: [UUID]) -> MaskPlan? {
        guard selection.count > 1, selection.count <= 12, let plan = maskPlan(selection),
              let reach = canvasBounds(of: plan.shape),
              plan.held.allSatisfy({ canvasBounds(of: $0)?.intersects(reach) == true }),
              node(plan.shape)?.isMask == true || plan.held.contains(where: { id in canvasBounds(of: id).map { !reach.contains($0) } == true })
        else { return nil }
        return plan
    }

    /// A mask picked alone: what it holds that can be picked, for Return to pick.
    func maskHeld(_ selection: [UUID]) -> [UUID]? {
        guard selection.count == 1, let mask = node(selection[0]), mask.isMask, !mask.locked else { return nil }
        let held = mask.children.dropFirst().filter { !$0.hidden && !$0.locked }.map(\.id)
        return held.isEmpty ? nil : held
    }
}
