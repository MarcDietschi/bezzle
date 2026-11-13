import Foundation
import CoreGraphics

/// An artboard as a stage: everything on it is seen from one eye in front of its middle (`Eye`),
/// so layers held at different heights over it are a scene, and what is nearer covers what is
/// further, whatever the layers list says. Layers lying together at the same height keep the
/// order the list gives them, so a design with nothing brought nearer or pushed away is drawn as
/// it always was. A group is one card in the scene: what it holds is stacked inside it.
nonisolated enum DepthOrder {
    /// How far above what holds it a layer is held, at its middle: nearer the eye for more than
    /// nothing, further below. Artboards are the page.
    static func height(of node: Node) -> CGFloat {
        node.isArtboard ? 0 : node.transform3D?.z ?? 0
    }

    /// Whether any of these is held nearer or further than another, so that they are drawn in
    /// another order than listed.
    static func leaves<C: Collection>(_ nodes: C) -> Bool where C.Element == Node {
        guard let first = nodes.first else { return false }
        let level = height(of: first)
        return nodes.contains { height(of: $0) != level }
    }

    /// The order layers lying together are drawn in, bottom first, as positions among them:
    /// further under nearer, and as listed where they are as near as each other.
    static func order<C: Collection>(_ nodes: C) -> [C.Index] where C.Element == Node {
        let indices = Array(nodes.indices)
        guard leaves(nodes) else { return indices }
        let heights: [CGFloat] = nodes.map { height(of: $0) }
        let sorted: [Int] = Array(0..<indices.count).sorted { a, b in
            if heights[a] != heights[b] { return heights[a] < heights[b] }
            return a < b
        }
        return sorted.map { indices[$0] }
    }

    /// These layers in the order they are drawn, bottom first.
    static func stacked<C: Collection>(_ nodes: C) -> [Node] where C.Element == Node {
        guard leaves(nodes) else { return Array(nodes) }
        return order(nodes).map { nodes[$0] }
    }
}
