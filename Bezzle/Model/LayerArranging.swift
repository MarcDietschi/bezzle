import Foundation
import CoreGraphics

// Duplicating, grouping, arranging and lining layers up, shared by every Bezzle: the Mac's
// DocumentStore wraps these in its undo steps and selection, and so does the Windows app.

extension BezzleDocument {
    // MARK: Duplicating

    /// Puts a copy of each layer right above it and returns the copies' ids. An artboard's copy
    /// goes beside it rather than over it; in a deck's post, the same layer of every post is
    /// copied too, each with its own words.
    mutating func duplicate(_ ids: [UUID], offset: CGPoint) -> [UUID] {
        var copies: [UUID] = []
        for id in ids {
            if let copy = Deck.duplicate(id, in: &self, offset: offset) {
                copies.append(copy)
                continue
            }
            guard let path = path(of: id) else { continue }
            var copy = self[path].freshCopy()
            if copy.isArtboard {
                copy.frame.origin.x += copy.frame.width + 80
            } else {
                copy.frame.origin.x += offset.x
                copy.frame.origin.y += offset.y
            }
            var above = path
            above.indices[above.indices.count - 1] += 1
            insert(copy, at: above)
            copies.append(copy.id)
        }
        return copies
    }

    // MARK: Where layers lie

    /// Moves each layer onto the artboard its centre is over, or off onto the canvas, as when it
    /// is dragged across, keeping where it is on screen. What is in a group stays in it.
    mutating func settle(_ ids: [UUID]) {
        for id in ids {
            guard let node = node(id), !node.isArtboard, let frame = absoluteFrame(of: id) else { continue }
            if parent(of: id)?.isGroup == true { continue }
            let target = artboard(at: frame.center)?.id
            guard target != parent(of: id)?.id else { continue }
            if let n = detach(id) { attach(n, to: target) }
        }
    }

    /// Moves a layer in the layers list: onto an artboard (or the canvas, when nil) at `index`,
    /// counted bottom first. An artboard stays on the canvas.
    mutating func move(_ id: UUID, to artboard: UUID?, at index: Int) {
        guard let node = node(id), artboard != id else { return }
        if node.isArtboard && artboard != nil { return }
        let oldPath = path(of: id)
        var target = index
        // Removing it first shifts what comes after it in the same list.
        if let oldPath {
            let sameList = oldPath.parent.map { self[$0].id } == artboard
            if sameList && oldPath.indices.last! < target { target -= 1 }
        }
        guard let detached = detach(id) else { return }
        attach(detached, to: artboard, at: target)
    }

    // MARK: Arranging

    nonisolated enum Arrange: Sendable { case front, forward, backward, back }

    /// Brings layers to the front or forward, or sends them backward or to the back, each list of
    /// siblings on its own, however deep.
    mutating func arrange(_ ids: [UUID], _ how: Arrange) {
        let chosen = Set(ids)
        func reorder(_ list: inout [Node]) {
            guard list.contains(where: { chosen.contains($0.id) }) else { return }
            switch how {
            case .front:
                let moving = list.filter { chosen.contains($0.id) }
                list.removeAll { chosen.contains($0.id) }
                list += moving
            case .back:
                let moving = list.filter { chosen.contains($0.id) }
                list.removeAll { chosen.contains($0.id) }
                list = moving + list
            case .forward:
                for i in list.indices.reversed() where chosen.contains(list[i].id) && i + 1 < list.count && !chosen.contains(list[i + 1].id) {
                    list.swapAt(i, i + 1)
                }
            case .backward:
                for i in list.indices where chosen.contains(list[i].id) && i > 0 && !chosen.contains(list[i - 1].id) {
                    list.swapAt(i, i - 1)
                }
            }
        }
        func everywhere(_ list: inout [Node]) {
            reorder(&list)
            for i in list.indices where !list[i].children.isEmpty { everywhere(&list[i].children) }
        }
        everywhere(&nodes)
    }

    // MARK: Grouping

    /// The layers among `ids` that would go into a group: all but those inside another of them.
    /// Nil when there are none, or one is an artboard or lies in a repeat grid, or they lie on
    /// more than one artboard, or some on one and some on the canvas.
    func groupable(_ ids: [UUID]) -> [UUID]? {
        let chosen = Set(ids)
        let ids = ids.filter { id in node(id) != nil && !ancestors(of: id).contains { chosen.contains($0.id) } }
        guard !ids.isEmpty, Set(ids.map { artboard(of: $0)?.id }).count == 1,
              ids.allSatisfy({ id in node(id)?.isArtboard == false && !ancestors(of: id).contains(where: \.isRepeatGrid) }) else { return nil }
        return ids
    }

    /// Puts layers into a new group, in the artboard or group that holds them all, where the
    /// frontmost of them was, and returns its id. Each stays where it is on the canvas, and in
    /// the same order back to front.
    @discardableResult
    mutating func group(_ ids: [UUID], name: String? = nil) -> UUID? {
        guard let ids = groupable(ids) else { return nil }
        // Back to front, as they are drawn.
        let paths = ids.compactMap { id in path(of: id).map { (id: id, at: $0.indices) } }
            .sorted { $0.at.lexicographicallyPrecedes($1.at) }
        guard let front = paths.last else { return nil }
        // Where the deepest artboard or group that holds them all is.
        var shared = Array(front.at.dropLast())
        for p in paths {
            let parent = p.at.dropLast()
            shared = Array(zip(shared, parent).prefix { $0 == $1 }.map(\.0))
        }
        let holder = shared.isEmpty ? nil : ancestors(of: front.id)[shared.count - 1].id
        // Just above what holds the frontmost there, once those lying there themselves are out.
        let place = front.at[shared.count]
        let leaving = paths.filter { $0.at.count == shared.count + 1 && $0.at[shared.count] <= place }.count
        var group = Node(kind: .group, name: name ?? nextName(for: .group), frame: .zero)
        // Taken out onto the canvas, and so into a group lying at the canvas's top left, they keep
        // where they are; it is fitted round them afterwards.
        group.children = paths.compactMap { detach($0.id) }
        attach(group, to: holder, at: place + 1 - leaving)
        return group.id
    }

    /// Takes the layers out of groups, each into its group's place, where they are, and returns them.
    @discardableResult
    mutating func ungroup(_ ids: [UUID]) -> [UUID] {
        var freed: [UUID] = []
        for id in ids {
            guard let path = path(of: id), let group = node(id), group.isGroup else { continue }
            // A group is never turned, so its layers only move by where it is.
            let layers = group.children.map { child -> Node in
                var c = child
                c.frame = c.frame.offsetBy(dx: group.frame.minX, dy: group.frame.minY)
                return c
            }
            let i = path.indices.last!
            if let parent = path.parent {
                var holder = self[parent]
                holder.children.replaceSubrange(i...i, with: layers)
                self[parent] = holder
            } else {
                nodes.replaceSubrange(i...i, with: layers)
            }
            freed += layers.map(\.id)
        }
        // A group taken apart after the one it was in.
        return freed.filter { node($0) != nil }
    }

    // MARK: Several at once

    /// The frame the Frame card shows for layers: one layer's own (a group seen turned, its box
    /// along the turn); for several, the box round them all, in the artboard or group they share,
    /// else on the canvas.
    func selectionFrame(_ ids: [UUID]) -> CGRect? {
        let nodes = ids.compactMap { node($0) }
        if nodes.count == 1 { return BezzleDocument.turnedBox(of: nodes[0]).frame }
        guard let bounds = bounds(of: ids) else { return nil }
        let parents = Set(nodes.map { parent(of: $0.id)?.id })
        if parents.count == 1, let p = parents.first ?? nil, let parent = absoluteFrame(of: p) {
            return bounds.offsetBy(dx: -parent.minX, dy: -parent.minY)
        }
        return bounds
    }

    /// Layers given a new box together, each keeping its place in it. The box is in their shared
    /// artboard's coordinates, or on the canvas. A group's layers stretch with it; an artboard is
    /// given its new size by `resizingArtboard` (the Mac lays its design out again).
    mutating func place(_ ids: [UUID], from f: CGRect, to target: CGRect,
                        resizingArtboard: (Node, CGSize) -> Node = { n, size in var n = n; n.frame.size = size; return n }) {
        let parentOrigins = Dictionary(ids.map { ($0, parentOrigin(of: $0)) }, uniquingKeysWith: { a, _ in a })
        let shared = Set(ids.map { parent(of: $0)?.id }).count == 1
        for id in ids {
            update(id) { n in
                let o = shared ? .zero : parentOrigins[id] ?? .zero
                let own = n.frame.offsetBy(dx: o.x, dy: o.y)
                let next = Geometry.snapToPixels(Geometry.map(own, from: f, to: target)).offsetBy(dx: -o.x, dy: -o.y)
                if n.isArtboard {
                    n = resizingArtboard(n, next.size)
                    n.frame.origin = next.origin
                } else if n.isGroup, n.frame.size != next.size, n.frame.width > 0, n.frame.height > 0 {
                    // A group's layers stretch with it, as they do when it is resized alone; set
                    // only its frame, it would be fitted back round them as it was.
                    let old = n.frame.size
                    n.children = BezzleDocument.scaled(n.children, from: old, to: next.size)
                    n.mask = n.mask.map { BezzleDocument.scaled($0, from: old, to: next.size) }
                    n.grid?.columnGap *= next.width / old.width
                    n.grid?.rowGap *= next.height / old.height
                    n.frame = next
                } else {
                    n.frame = next
                }
                n.refit()
            }
        }
    }

    // MARK: Aligning

    nonisolated enum Align: Sendable { case left, centerX, right, top, centerY, bottom }

    /// Lines layers up, each as far as it reaches turned; a single layer lines up with its artboard.
    /// Locked layers stay.
    mutating func align(_ ids: [UUID], _ how: Align) {
        let ids = ids.filter { node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        let frames = ids.compactMap { id in node(id).map { (id, Geometry.bounds(of: $0).offsetBy(dx: parentOrigin(of: id).x, dy: parentOrigin(of: id).y)) } }
        guard let first = frames.first else { return }
        let reference: CGRect
        if ids.count == 1 {
            guard let board = artboard(of: ids[0]) else { return }
            reference = board.frame
        } else {
            reference = frames.map(\.1).reduce(first.1) { $0.union($1) }
        }
        for (id, r) in frames {
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch how {
            case .left: dx = reference.minX - r.minX
            case .centerX: dx = reference.midX - r.midX
            case .right: dx = reference.maxX - r.maxX
            case .top: dy = reference.minY - r.minY
            case .centerY: dy = reference.midY - r.midY
            case .bottom: dy = reference.maxY - r.maxY
            }
            update(id) { $0.frame = $0.frame.offsetBy(dx: dx.rounded(), dy: dy.rounded()) }
        }
    }

    /// Spaces three or more layers evenly between the outermost two. Locked layers stay.
    mutating func distribute(_ ids: [UUID], horizontally: Bool) {
        let ids = ids.filter { node($0)?.locked == false }
        guard ids.count >= 3 else { return }
        var items = ids.compactMap { id in node(id).map { (id, Geometry.bounds(of: $0).offsetBy(dx: parentOrigin(of: id).x, dy: parentOrigin(of: id).y)) } }
        items.sort { horizontally ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let total = items.reduce(CGFloat(0)) { $0 + (horizontally ? $1.1.width : $1.1.height) }
        let start = horizontally ? items.first!.1.minX : items.first!.1.minY
        let end = horizontally ? items.map(\.1.maxX).max()! : items.map(\.1.maxY).max()!
        let gap = (end - start - total) / CGFloat(items.count - 1)
        var cursor = start
        for (id, r) in items {
            let delta = cursor - (horizontally ? r.minX : r.minY)
            update(id) { $0.frame = $0.frame.offsetBy(dx: horizontally ? delta : 0, dy: horizontally ? 0 : delta) }
            cursor += (horizontally ? r.width : r.height) + gap
        }
    }
}
