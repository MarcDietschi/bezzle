import Foundation
import CoreGraphics

/// A shape holding other layers, as a shape holds a picture: a mask. It is a group whose first
/// layer, the shape, holds the rest (`Node.clipsToFirst`). The shape is drawn as it is, its fill
/// and shadow under what it holds and its border over it as a frame; what it holds is cut off at
/// its outline. The group is as big as the shape, so its handles go round what shows.
///
/// The shape is a layer like any other, so everything that changes a layer changes it, and two
/// people sharing the design change it and what it holds apart. That it is the first layer is
/// all that makes it the mask, so `keepMasks` keeps it first, whatever is put below it, and takes
/// the group apart once it is gone or holds nothing more.
///
/// Masks brought in from other apps that do not show are kept apart from what they cut, in `Node.mask`.
nonisolated enum Mask {
    /// Whether a layer can hold others: a shape lying flat in the page.
    static func canHold(_ node: Node) -> Bool {
        [.rectangle, .ellipse, .path].contains(node.kind) && node.transform3D == nil
    }

    /// The name a new mask is given: "Mask 1", "Mask 2", the first not taken.
    static func name(in doc: BezzleDocument) -> String {
        let taken = Set(doc.allNodes.lazy.filter(\.isGroup).map(\.name))
        var i = 1
        while taken.contains(String(localized: "Mask \(i)")) { i += 1 }
        return String(localized: "Mask \(i)")
    }
}

nonisolated extension Node {
    /// The shape holding what else this group holds: its first layer, when it is a mask.
    var holder: Node? { kind == .group && clipsToFirst == true ? children.first : nil }

    /// Whether this is a mask: a group whose first layer holds the rest.
    var isMask: Bool { holder != nil }

    /// What cuts off what a group holds: a mask brought in from another app, or the shape that
    /// holds the rest. Nil for any other group.
    var cutBy: Node? { mask?.first ?? holder }
}

extension Mask {
    /// Whether a point of a mask's parent lies inside its shape's outline, whatever the shape is
    /// filled with or whether it is: that is all of it that holds.
    @MainActor
    static func inside(_ shape: Node, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        var solid = shape
        solid.fills = [Fill(color: .white)]
        solid.borders = []
        return Geometry.contains(solid, p, tolerance: tolerance)
    }

    /// The outline a mask's shape cuts off at, placed on the canvas.
    @MainActor
    static func outline(of mask: UUID, in doc: BezzleDocument) -> CGPath? {
        guard let group = doc.node(mask), let shape = group.cutBy else { return nil }
        let o = doc.parentOrigin(of: mask)
        var t = CGAffineTransform(translationX: o.x + group.frame.minX, y: o.y + group.frame.minY)
        let path = Renderer.heldOutline(of: shape)
        return path.copy(using: &t) ?? path
    }
}

extension BezzleDocument {
    /// Keeps every mask that changed since `before` a mask: its shape first, wherever something
    /// it holds was moved in the list; and once its shape has gone, or it holds nothing more, the
    /// group is taken apart, what is left of it where the group was.
    mutating func keepMasks(since before: BezzleDocument) {
        var broken: [UUID] = []
        // Only where something changed; inside out, so taking one apart leaves the others where they are.
        func look(_ now: [Node], _ was: [Node]?) {
            for (i, n) in now.enumerated() where !n.children.isEmpty || n.clipsToFirst == true {
                let w = was.flatMap { i < $0.count && $0[i].id == n.id ? $0[i] : nil }
                if let w, w == n { continue }
                look(n.children, w?.children)
                if n.clipsToFirst == true, Self.needsKeeping(n, was: w ?? before.node(n.id)) { broken.append(n.id) }
            }
        }
        look(nodes, before.nodes)
        for id in broken { keep(id, was: before.node(id)) }
    }

    private static func needsKeeping(_ group: Node, was: Node?) -> Bool {
        if group.children.count < 2 { return true }
        guard let was, was.clipsToFirst == true, let first = was.children.first?.id else { return false }
        return group.children.first?.id != first
    }

    private mutating func keep(_ id: UUID, was: Node?) {
        guard let path = path(of: id) else { return }
        var group = self[path]
        if let was, was.clipsToFirst == true, let first = was.children.first?.id, group.children.first?.id != first {
            if let i = group.children.firstIndex(where: { $0.id == first }) {
                group.children.insert(group.children.remove(at: i), at: 0)
            } else {
                // What held them is gone: they stay a group as any other.
                group.clipsToFirst = nil
            }
        }
        guard group.children.count < 2 else {
            self[path] = group
            return
        }
        // Holding nothing, or held by nothing: what is left is a layer of its own again, where the
        // group was, and stays where it is on the canvas.
        let left = group.children.map { child -> Node in
            var c = child
            c.frame = c.frame.offsetBy(dx: group.frame.minX, dy: group.frame.minY)
            return c
        }
        replace(at: path, with: left)
    }

    /// Puts `layers` where the layer at `path` was, in its place among the others.
    mutating func replace(at path: NodePath, with layers: [Node]) {
        let i = path.indices.last!
        if let parent = path.parent {
            var holder = self[parent]
            holder.children.replaceSubrange(i...i, with: layers)
            self[parent] = holder
        } else {
            nodes.replaceSubrange(i...i, with: layers)
        }
    }
}

nonisolated extension BezzleDocument {
    /// Makes every mask a mask again in a design that changes made apart by several people were
    /// put together into, which none of them made: the shape one deleted while another dropped
    /// something in, or each taking out one of the last two layers it held. A mask holding fewer
    /// than two layers is taken apart, what is left of it where it was; one whose first layer is
    /// no shape is a group as any other. Every Mac works out the same from the same changes.
    mutating func repairMasks() {
        guard Self.hasBrokenMask(nodes) else { return }
        nodes = Self.repairingMasks(nodes)
    }

    private static func hasBrokenMask(_ list: [Node]) -> Bool {
        list.contains { n in
            if n.clipsToFirst == true, n.kind != .group || n.children.count < 2 || !Self.isShape(n.children[0]) { return true }
            return !n.children.isEmpty && hasBrokenMask(n.children)
        }
    }

    private static func repairingMasks(_ list: [Node]) -> [Node] {
        list.flatMap { node -> [Node] in
            guard !node.children.isEmpty || node.clipsToFirst == true else { return [node] }
            var n = node
            n.children = repairingMasks(node.children)
            guard n.clipsToFirst == true else { return [n] }
            if n.kind != .group || n.children.first.map(isShape) != true { n.clipsToFirst = nil }
            guard n.kind == .group, n.children.count < 2 else { return [n] }
            return n.children.map { child in
                var c = child
                c.frame = c.frame.offsetBy(dx: n.frame.minX, dy: n.frame.minY)
                return c
            }
        }
    }

    /// Whether a layer is a kind of shape that holds what a mask holds, however it is turned.
    private static func isShape(_ node: Node) -> Bool {
        [.rectangle, .ellipse, .path].contains(node.kind)
    }
}
