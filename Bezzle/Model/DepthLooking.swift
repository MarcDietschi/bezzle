import Foundation
import CoreGraphics

// Looking at an artboard's scene from the side, shared by every Bezzle. The page is not turned:
// the eye is moved, as someone in front of a window moves their head. So the page and all that
// lies flat in it stay exactly where they are, and everything done there stays true, while what
// is held up off the page shows how high it stands by how far it goes aside, and what is turned
// shows more of one side. It is a way of looking only: kept beside the design for as long as it
// is open, never in it (`BezzleDocument.looks`), so never saved, sent or exported.

/// From where an artboard's scene is looked at: how far round from straight in front the eye
/// stands, as high above the page as ever.
nonisolated struct DepthLook: Equatable, Hashable, Sendable {
    /// Degrees to the right of straight in front; to the left below 0.
    var across = 0.0
    /// Degrees below it; above below 0.
    var down = 0.0

    static let front = DepthLook()
    /// No further round than this: beyond it what is held up runs away across the page.
    static let most = 60.0
    /// Degrees for a point the pointer is dragged on the canvas.
    static let rate = 0.35

    var isFront: Bool { across == 0 && down == 0 }
    /// How far round it is, whichever way.
    var angle: Double { (across * across + down * down).squareRoot() }

    /// The same way round, no further than `most`.
    var held: DepthLook {
        let a = angle
        guard a > Self.most else { return self }
        return DepthLook(across: across * Self.most / a, down: down * Self.most / a)
    }

    /// How far aside of straight in front an eye `distance` above the page then stands.
    func aside(distance: CGFloat) -> CGPoint {
        let look = held, a = look.angle
        guard a > 0 else { return .zero }
        let far = Double(distance) * tan(a * .pi / 180)
        return CGPoint(x: CGFloat(far * look.across / a), y: CGFloat(far * look.down / a))
    }

    /// The look after the pointer has been dragged by `d` canvas-view points from where this was
    /// the look. What is held up goes with the pointer, as if the scene were taken hold of and
    /// turned: the eye goes the other way. `steps` goes in fives, and near the front it catches
    /// there.
    func dragged(by d: CGPoint, steps: Bool) -> DepthLook {
        var next = DepthLook(across: across - Double(d.x) * Self.rate, down: down - Double(d.y) * Self.rate).held
        if steps {
            next.across = (next.across / 5).rounded() * 5
            next.down = (next.down / 5).rounded() * 5
        } else {
            next.across = next.across.rounded()
            next.down = next.down.rounded()
            if abs(next.across) < 2 { next.across = 0 }
            if abs(next.down) < 2 { next.down = 0 }
        }
        // Not -0.
        if next.across == 0 { next.across = 0 }
        if next.down == 0 { next.down = 0 }
        return next.held
    }
}

/// A post under a corner of a layer held up off the page: from where the corner would lie in the
/// page, straight under it, to where it shows.
nonisolated struct DepthPost: Equatable, Sendable {
    var foot: CGPoint
    var top: CGPoint
    /// Where the corner stands in the artboard's scene, in the artboard's own points: what tells
    /// which parts of the post nearer layers cover (`BezzleDocument.shownParts`).
    var corner = ScenePoint()
}

nonisolated extension Eye {
    /// The same eye looking from where `look` says: moved aside, as high above the page.
    func looking(_ look: DepthLook?) -> Eye {
        guard let look, !look.isFront else { return self }
        let aside = look.aside(distance: distance)
        return Eye(at: CGPoint(x: at.x + aside.x, y: at.y + aside.y), distance: distance)
    }
}

nonisolated extension BezzleDocument {
    /// Where an artboard's scene is seen from, in its own points: in front of its middle
    /// (`Eye.stage`), or from where it is looked at for now (`looks`).
    func stage(of board: Node) -> Eye {
        Eye.stage(board.frame.size).looking(looks?[board.id])
    }

    /// The design looked at from the front, whatever it is looked at from for now: what anything
    /// that leaves the canvas reads, so a way of looking never goes with it.
    var front: BezzleDocument {
        guard looks != nil else { return self }
        var doc = self
        doc.looks = nil
        return doc
    }

    /// The posts of an artboard looked at from the side, on the canvas: one under each corner of
    /// every layer on it that stands off the page, so that how high each stands can be read,
    /// straight down to the page, which is what every height is measured from. A group that
    /// keeps its layers' depth has no card of its own: the posts stand under each of its layers,
    /// where they stand in the scene. With some of those layers `picked`, or the groups they lie
    /// in, only theirs, so that what is being worked on reads alone. None looked at from the
    /// front, where a post is seen end on.
    func posts(of board: Node, picked: Set<UUID> = []) -> [DepthPost] {
        guard board.isArtboard, let look = looks?[board.id], !look.isFront else { return [] }
        let eye = stage(of: board), origin = board.frame.origin
        var all: [DepthPost] = [], chosen: [DepthPost] = []
        for upright in Upright.all(on: board, eye: eye) where upright.deep {
            let mine = picked.contains(upright.node.id) || upright.groups.contains(where: picked.contains)
            for corner in upright.corners where abs(corner.z) > 0.01 {
                let foot = CGPoint(x: origin.x + CGFloat(corner.x), y: origin.y + CGFloat(corner.y))
                let top = Self.seen(corner, from: eye) + origin
                guard hypot(top.x - foot.x, top.y - foot.y) > 0.01 else { continue }
                let post = DepthPost(foot: foot, top: top, corner: corner)
                all.append(post)
                if mine { chosen.append(post) }
            }
        }
        return chosen.isEmpty ? all : chosen
    }

    /// The parts of each of these posts of an artboard that show: where no layer on it stands
    /// between the moved eye and the post, its own layer among them, as the posts under the far
    /// side of a card stand behind it. Each as stretches of the post's line on the canvas, from
    /// its foot, 0, to its top, 1; the whole of each, looked at from the front. On the main
    /// thread, as `Geometry.contains` is.
    @MainActor func shownParts(of posts: [DepthPost], on board: Node) -> [[ClosedRange<Double>]] {
        guard !posts.isEmpty, let look = looks?[board.id], !look.isFront else { return posts.map { _ in [0...1] } }
        let eye = stage(of: board)
        let from = ScenePoint(x: Double(eye.at.x), y: Double(eye.at.y), z: Double(eye.distance))
        // Each layer the line of sight may meet: the plane it lies in, and how to tell whether a
        // place in that plane is on it.
        struct Cover {
            var node: Node
            var corners: [ScenePoint]
            var flat: [CGPoint]
            var normal: ScenePoint
            /// How high its highest corner stands: nothing lower stands between the eye and a post.
            var highest: Double
            /// Round where it shows, in the artboard's points.
            var box: CGRect
        }
        var covers: [Cover] = []
        for upright in Upright.all(on: board, eye: eye) {
            let c = upright.corners
            guard c.count == 4 else { continue }
            let normal = Self.cross(c[1] - c[0], c[3] - c[0])
            guard Self.dot(normal, normal) > 1e-12 else { continue }
            var plain = upright.node
            plain.transform3D = nil
            // As its corners are found (`DepthBody.corners`): a group is never turned in its own plane.
            let flat = Geometry.corners(of: plain.frame, rotation: plain.isGroup ? 0 : plain.rotation)
            let shown = c.map { Self.seen($0, from: eye) }
            let xs = shown.map(\.x), ys = shown.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            covers.append(Cover(node: plain, corners: c, flat: flat, normal: normal, highest: c.map(\.z).max()!, box: box))
        }
        /// Whether one of these stands between the eye and a place in the scene.
        func covered(_ p: ScenePoint, by covers: [Cover]) -> Bool {
            let sight = p - from
            for cover in covers {
                let across = Self.dot(cover.normal, sight)
                guard abs(across) > 1e-12 else { continue }
                let t = Self.dot(cover.normal, cover.corners[0] - from) / across
                guard t > 1e-9, t < 1 - 1e-9 else { continue }
                // Where the sight meets that plane, as a share of the layer's top and left sides.
                let met = from + ScenePoint(x: sight.x * t, y: sight.y * t, z: sight.z * t) - cover.corners[0]
                let a = cover.corners[1] - cover.corners[0], b = cover.corners[3] - cover.corners[0]
                let aa = Self.dot(a, a), bb = Self.dot(b, b), ab = Self.dot(a, b)
                let det = aa * bb - ab * ab
                guard det > 1e-12 else { continue }
                let ma = Self.dot(met, a), mb = Self.dot(met, b)
                let u = (ma * bb - mb * ab) / det, v = (mb * aa - ma * ab) / det
                guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
                let f = cover.flat
                let q = CGPoint(x: f[0].x + CGFloat(u) * (f[1].x - f[0].x) + CGFloat(v) * (f[3].x - f[0].x),
                                y: f[0].y + CGFloat(u) * (f[1].y - f[0].y) + CGFloat(v) * (f[3].y - f[0].y))
                if Geometry.contains(cover.node, q, tolerance: 0) { return true }
            }
            return false
        }
        let steps = 32
        return posts.map { post in
            let line = CGPoint(x: post.top.x - post.foot.x, y: post.top.y - post.foot.y)
            let long = Double(line.x * line.x + line.y * line.y)
            guard long > 0 else { return [] }
            // Only what stands higher than the post's lowest point, where both show, can hide it:
            // for a post over the page, nothing that lies in it.
            let lowest = min(post.corner.z, 0)
            let reach = CGRect(x: min(post.foot.x, post.top.x), y: min(post.foot.y, post.top.y), width: abs(line.x), height: abs(line.y))
                .offsetBy(dx: -board.frame.minX, dy: -board.frame.minY).insetBy(dx: -1, dy: -1)
            let near = covers.filter { $0.highest > lowest + 1e-9 && $0.box.insetBy(dx: -1, dy: -1).intersects(reach) }
            // Places up the post, each with how far along its line on the canvas it shows.
            let places: [(along: Double, shows: Bool)] = (0..<steps).map { i in
                let p = ScenePoint(x: post.corner.x, y: post.corner.y, z: post.corner.z * (Double(i) + 0.5) / Double(steps))
                let at = Self.seen(p, from: eye) + board.frame.origin
                let along = Double((at.x - post.foot.x) * line.x + (at.y - post.foot.y) * line.y) / long
                return (min(max(along, 0), 1), !covered(p, by: near))
            }
            var parts: [ClosedRange<Double>] = []
            var start: Double?
            for (i, place) in places.enumerated() {
                if place.shows, start == nil { start = i == 0 ? 0 : (places[i - 1].along + place.along) / 2 }
                if !place.shows, let s = start {
                    parts.append(s...max(s, (places[i - 1].along + place.along) / 2))
                    start = nil
                }
            }
            if let s = start { parts.append(s...1) }
            return parts
        }
    }

    /// Where a place in an artboard's scene, in its own points, shows from `eye`, as a layer held
    /// that high there shows.
    private static func seen(_ p: ScenePoint, from eye: Eye) -> CGPoint {
        let flat = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        guard p.z != 0 else { return flat }
        return Perspective(Transform3D(z: CGFloat(p.z)), center: flat, eye: eye).shown(flat)
    }

    private static func dot(_ a: ScenePoint, _ b: ScenePoint) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func cross(_ a: ScenePoint, _ b: ScenePoint) -> ScenePoint {
        ScenePoint(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }
}

/// A layer of an artboard as it stands in the scene, for the posts and for what covers them.
private nonisolated struct Upright {
    var node: Node
    /// Where what holds it is seen from (`DepthOrder.Standing.eye`).
    var eye: Eye?
    /// Where what holds it begins, in the artboard's own points.
    var at: CGPoint
    /// The groups it lies in, outermost first.
    var groups: [UUID]

    /// Whether it stands in depth: turned or held off what holds it, or in a group that keeps
    /// depth, whose own turn and height stand it in the scene.
    var deep: Bool { eye?.space != nil || Perspective.inDepth(node) }

    /// Its corners where they stand in the artboard's scene, in the artboard's own points.
    var corners: [ScenePoint] {
        DepthBody.corners(of: node).map { c in
            var p = eye?.space.map { $0(c) } ?? c
            p.x += Double(at.x)
            p.y += Double(at.y)
            return p
        }
    }

    /// The layers of an artboard as they stand in its scene: a group that keeps its layers'
    /// depth gives each of them (`DepthOrder.scene`), and a group lying flat in the page what it
    /// holds, which may stand off it; a group turned or held up as one card is one.
    static func all(on board: Node, eye: Eye) -> [Upright] {
        var out: [Upright] = []
        func walk(_ nodes: [Node], eye: Eye, at: CGPoint, groups: [UUID]) {
            for piece in DepthOrder.scene(nodes, eye: eye, ordered: false) where !piece.node.hidden {
                let node = piece.node
                let upright = Upright(node: node, eye: piece.eye, at: at + piece.origin, groups: groups + piece.groups)
                if !upright.deep, node.isGroup, !node.children.isEmpty {
                    walk(node.children, eye: (piece.eye ?? eye).within(node), at: upright.at + node.frame.origin, groups: upright.groups + [node.id])
                } else {
                    out.append(upright)
                }
            }
        }
        walk(board.children, eye: eye, at: .zero, groups: [])
        return out
    }
}
