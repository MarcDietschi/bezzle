import Foundation
import CoreGraphics

/// An artboard as a stage: everything on it is seen from one eye in front of its middle (`Eye`),
/// so layers held at different heights over it are a scene, and what is nearer covers what is
/// further, whatever the layers list says. Layers lying together at the same height keep the
/// order the list gives them, so a design with nothing brought nearer or pushed away is drawn as
/// it always was. A group is one card in the scene: what it holds is stacked inside it.
///
/// How near a layer is, is how high its middle is held. The faces of one body are the exception
/// (`DepthBody`): turned together, their middles stand at heights the turn gave them, the far
/// side's low and the near side's high, though a label still lies on its card and a button over
/// it. So layers turned to face the same way that lie in one plane or over one another, with
/// their middles at different heights, are ordered as a body's faces are: by how far each plane
/// is in front of the others, and those in one plane as listed. Among everything else such a
/// body is as near as its faces would be laid flat, none of them lower than its middle stands,
/// so turning a body sinks nothing of it under what lies beside it.
nonisolated enum DepthOrder {
    /// How far above what holds it a layer is held, at its middle: nearer the eye for more than
    /// nothing, further below. Artboards are the page.
    static func height(of node: Node) -> CGFloat {
        node.isArtboard ? 0 : node.transform3D?.z ?? 0
    }

    /// A flat thing standing in a scene, as the order needs to know it.
    struct Face: Equatable, Sendable {
        /// Where its middle stands.
        var middle: ScenePoint
        /// How it is tipped and swung; nil lying level with the page.
        var turn: Spin?
        /// The upright box round it as it lies seen from straight above.
        var box: CGRect

        init(middle: ScenePoint, turn: Spin?, box: CGRect) {
            self.middle = middle
            self.turn = turn
            self.box = box
        }

        /// A thing of `size` with its middle at `middle`, turned `rotation` in its own plane
        /// and then in depth by `turn`.
        init(middle: ScenePoint, size: CGSize, rotation: Double, turn: Spin) {
            self.middle = middle
            self.turn = turn
            let w = Double(size.width) / 2, h = Double(size.height) / 2
            let own = turn.after(.turn(rotation))
            let corners = [ScenePoint(x: -w, y: -h), ScenePoint(x: w, y: -h), ScenePoint(x: w, y: h), ScenePoint(x: -w, y: h)].map { own($0) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            box = CGRect(x: CGFloat(middle.x + (xs.min() ?? 0)), y: CGFloat(middle.y + (ys.min() ?? 0)),
                         width: CGFloat((xs.max() ?? 0) - (xs.min() ?? 0)), height: CGFloat((ys.max() ?? 0) - (ys.min() ?? 0)))
        }

        /// A layer where it stands in what holds it.
        init(_ node: Node) {
            let z = DepthOrder.height(of: node)
            middle = ScenePoint(x: Double(node.frame.midX), y: Double(node.frame.midY), z: Double(z))
            guard !node.isArtboard, let t = node.transform3D, t.x != 0 || t.y != 0 else {
                turn = nil
                box = node.frame
                return
            }
            turn = Spin(t)
            let corners = DepthBody.corners(of: node)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            box = CGRect(x: CGFloat(xs.min() ?? 0), y: CGFloat(ys.min() ?? 0), width: CGFloat((xs.max() ?? 0) - (xs.min() ?? 0)),
                         height: CGFloat((ys.max() ?? 0) - (ys.min() ?? 0)))
        }
    }

    /// Whether any of these is held nearer or further than another, so that they are drawn in
    /// another order than listed.
    static func leaves<C: Collection>(_ nodes: C) -> Bool where C.Element == Node {
        guard let first = nodes.first else { return false }
        let level = height(of: first)
        return nodes.contains { height(of: $0) != level }
    }

    /// How near each of these is for the order they are drawn in: how high its middle is held,
    /// but for the faces of a body, which are as near as they would be laid flat.
    static func nearness(_ faces: [Face]) -> [Double] {
        var keys = faces.map(\.middle.z)
        // Those turned to face the same way, by which way that is.
        var ways: [[Int]: [Int]] = [:]
        for (i, face) in faces.enumerated() {
            guard let n = face.turn?.facing else { continue }
            ways[[Int((n.x * 1e6).rounded()), Int((n.y * 1e6).rounded()), Int((n.z * 1e6).rounded())], default: []].append(i)
        }
        for members in ways.values where members.count > 1 {
            guard let n = faces[members[0]].turn?.facing else { continue }
            // Seen from behind, what stood over a face stands behind it.
            let side: Double = n.z >= 0 ? 1 : -1
            // How far along the way they face each plane lies.
            let along = members.map { i in side * (n.x * faces[i].middle.x + n.y * faces[i].middle.y + n.z * faces[i].middle.z) }
            // The bodies among them: joined where two with their middles at different heights
            // lie in one plane, or over one another.
            var body = Array(members.indices)
            func root(_ k: Int) -> Int {
                var k = k
                while body[k] != k { k = body[k] }
                return k
            }
            for a in members.indices {
                for b in members.indices where b > a {
                    let fa = faces[members[a]], fb = faces[members[b]]
                    guard abs(fa.middle.z - fb.middle.z) > 1e-9 else { continue }
                    guard abs(along[a] - along[b]) < 0.01 || fa.box.intersects(fb.box) else { continue }
                    let ra = root(a), rb = root(b)
                    if ra != rb { body[max(ra, rb)] = min(ra, rb) }
                }
            }
            var lift: [Int: Double] = [:], size: [Int: Int] = [:]
            for k in members.indices {
                let r = root(k)
                lift[r] = max(lift[r] ?? -.infinity, faces[members[k]].middle.z - along[k])
                size[r, default: 0] += 1
            }
            for k in members.indices {
                let r = root(k)
                guard size[r] ?? 0 > 1, let lift = lift[r] else { continue }
                // Those of a body in one plane are as near as each other to the last place, the
                // first of them saying how near, so that they stay in the order listed.
                let first = members.indices.first { root($0) == r && abs(along[$0] - along[k]) < 0.01 } ?? k
                keys[members[k]] = along[first] + lift
            }
        }
        return keys
    }

    /// The order layers lying together are drawn in, bottom first, as positions among them:
    /// further under nearer, and as listed where they are as near as each other.
    static func order<C: Collection>(_ nodes: C) -> [C.Index] where C.Element == Node {
        let indices = Array(nodes.indices)
        guard leaves(nodes) else { return indices }
        let turned = nodes.contains { !$0.isArtboard && ($0.transform3D?.x ?? 0 != 0 || $0.transform3D?.y ?? 0 != 0) }
        let heights: [Double] = turned ? nearness(nodes.map { Face($0) }) : nodes.map { Double(height(of: $0)) }
        return sorted(heights).map { indices[$0] }
    }

    /// Positions in the order they are drawn, bottom first, given how near each is.
    static func sorted(_ nearness: [Double]) -> [Int] {
        Array(nearness.indices).sorted { a, b in
            if nearness[a] != nearness[b] { return nearness[a] < nearness[b] }
            return a < b
        }
    }

    /// These layers in the order they are drawn, bottom first.
    static func stacked<C: Collection>(_ nodes: C) -> [Node] where C.Element == Node {
        guard leaves(nodes) else { return Array(nodes) }
        return order(nodes).map { nodes[$0] }
    }
}
