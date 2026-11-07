import Foundation

/// Words riding a shape's outline (see `TextCurve`): laid along it, in a group they share with
/// it, and taken off again. Shared by every Bezzle; the Mac's store calls these
/// (Store/CurveOperations.swift), as does Windows.
extension BezzleDocument {
    /// Whether a text could ride `shape`'s outline: it is a shape lying flat, not in a repeat grid
    /// or holding a mask, and neither is locked.
    func canRide(_ text: UUID, on shape: UUID) -> Bool {
        guard text != shape, let t = node(text), t.kind == .text, !t.locked, let s = node(shape), TextCurve.canCarry(s), !s.locked else { return false }
        let above = ancestors(of: shape)
        guard !above.contains(where: { $0.isRepeatGrid || $0.id == text || $0.locked }), !ancestors(of: text).contains(where: \.isRepeatGrid) else { return false }
        // A mask's shape holds what lies in it, and would cut words along it in half.
        if let parent = above.last, parent.isMask, parent.children.first?.id == shape { return false }
        return true
    }

    /// Lays a text along a shape's outline, placed as `curve` says, and returns the group they
    /// share: the one the shape already carries words in, or a new one in the shape's place,
    /// holding the shape and then the words, so what lay over the shape still does.
    @discardableResult
    mutating func ride(_ text: UUID, on shape: UUID, curve: TextCurve) -> UUID? {
        guard canRide(text, on: shape), var taken = detach(text) else { return nil }
        var placed = curve
        placed.bend = nil
        placed.rides = true
        taken.curve = placed
        taken.curvePath = nil
        taken.rotation = 0
        taken.post = nil
        taken.own = nil
        if let parent = parent(of: shape), parent.carrier?.id == shape {
            attach(taken, to: parent.id)
            return parent.id
        }
        guard let at = path(of: shape), let alone = detach(shape) else {
            attach(taken, to: nil)
            return nil
        }
        var group = Node(kind: .group, name: TextCurve.name(in: self), frame: .zero)
        // A shape lying straight on a deck's post keeps its words in that post.
        group.post = alone.post
        var inside = alone
        inside.post = nil
        group.children = [inside, taken]
        attach(group, to: at.parent.map { self[$0].id }, at: at.indices.last!)
        return group.id
    }

    /// Takes texts off the outlines they ride, straight again and reading upright, each just above
    /// the group it rode in; a group left with its shape alone is that shape again.
    mutating func takeOffPath(_ ids: [UUID]) {
        for id in ids {
            guard node(id)?.rides == true else { continue }
            update(id) { $0.straighten() }
            guard let group = parent(of: id), group.isGroup, let at = path(of: group.id) else { continue }
            let holder = at.parent.map { self[$0].id }
            guard var layer = detach(id) else { continue }
            layer.post = group.post
            attach(layer, to: holder, at: at.indices.last! + 1)
            unwrapIfAlone(group.id)
        }
    }

    /// A group made for words to ride its shape, left holding the shape alone, is the shape again.
    private mutating func unwrapIfAlone(_ group: UUID) {
        guard let g = node(group), g.isGroup, g.children.count == 1, let only = g.children.first, TextCurve.canCarry(only),
              g.clipsToFirst != true, !g.isRepeatGrid, let at = path(of: group) else { return }
        var shape = only
        shape.frame = shape.frame.offsetBy(dx: g.frame.minX, dy: g.frame.minY)
        shape.post = g.post
        replace(at: at, with: [shape])
    }
}
