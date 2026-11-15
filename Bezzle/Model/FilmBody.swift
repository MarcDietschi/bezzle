import Foundation
import CoreGraphics

// Several layers posed as one body on Animate's canvas, shared by every Bezzle. Picked together
// and lying together, they are the faces of one thing at the playhead (`DepthBody`), as the Pose
// card's Tilt and Swing have them (`poseInDepth`): the canvas shows one set of handles round the
// body, in the plane of its lead's face, and turns and grows it as one about its middle. Each
// layer is keyed where it then stands, as `poseInDepth` keys it; nothing of the body is kept.

/// Several layers lying together as they stand at a moment of their film: one body.
nonisolated struct FilmBody: Sendable {
    /// The layers as the design has them, the order `depthBodies` gives.
    var layers: [Node]
    /// Their poses at the moment.
    var poses: [MotionPose]
    /// Each as it stands then, for a body to be worked out from: moved, grown, turned, tipped,
    /// swung and lifted by its keys.
    var standing: [Node]
    /// Which of them leads: the largest face (`DepthBody.lead`).
    var lead: Int
    /// The way the lead's sides run, as it stands: its turn in depth after its turn in the page.
    /// What the body's box is measured along.
    var sides: Spin
    /// The box round all the body reaches to (`DepthBody.reach`), measured along the lead's
    /// sides: its least and most each way.
    var low: ScenePoint
    var high: ScenePoint

    var ids: [UUID] { layers.map(\.id) }

    /// The middle a body turns about, in what holds it, as `DepthBody.middle` has it.
    var pivot: ScenePoint {
        sides(ScenePoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2, z: (low.z + high.z) / 2))
    }

    /// Where the lead's middle stands, measured along its sides.
    private var leadMiddle: ScenePoint { sides.back(DepthBody.middle(of: standing[lead])) }

    /// The middle a body grows about: the box's middle, in the plane of its lead's face, so that
    /// what shows round it grows about its own middle.
    var growPivot: ScenePoint {
        sides(ScenePoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2, z: leadMiddle.z))
    }

    /// The box round the body in the plane of its lead's face, where the handles are: its four
    /// corners from the top left round, in the lead's own upright points, as the design has it
    /// (its frame's top left at zero, before it is grown), where the film's map of the lead
    /// (`Node.filmPointMap`) takes them.
    var outline: [CGPoint] {
        let lead = layers[self.lead], pose = poses[self.lead]
        let w = Double(lead.frame.width), h = Double(lead.frame.height)
        let sx = max(Double(pose.scale.x), 1e-9), sy = max(Double(pose.scale.y), 1e-9)
        let m = leadMiddle
        return [(low.x, low.y), (high.x, low.y), (high.x, high.y), (low.x, high.y)].map { x, y in
            CGPoint(x: (x - m.x) / sx + w / 2, y: (y - m.y) / sy + h / 2)
        }
    }

    /// A layer as it stands at a moment of its film, as `poseInDepth` stands it: where its keys
    /// have its middle, how big, and how far turned, tipped, swung and lifted. The same as the
    /// one `DepthBody.swift` keeps to itself for `poseInDepth`, which the two must agree with.
    static func standing(_ node: Node, _ pose: MotionPose) -> Node {
        var n = node
        n.children = []
        let c = node.frame.center
        n.frame = CGRect(center: CGPoint(x: c.x + pose.move.x, y: c.y + pose.move.y),
                         size: CGSize(width: node.frame.width * pose.scale.x, height: node.frame.height * pose.scale.y))
        if !node.isGroup { n.rotation = node.rotation + pose.turn }
        var turn = node.transform3D ?? Transform3D()
        turn.x += pose.tilt
        turn.y += pose.swing
        turn.z += CGFloat(pose.lift)
        n.transform3D = turn
        return n
    }

    /// How a layer's own sides run as it stands: its turn in depth after its turn in the page.
    static func sides(of standing: Node) -> Spin {
        Spin(standing.transform3D ?? Transform3D()).after(.turn(standing.isGroup ? 0 : standing.rotation))
    }

    /// The layers as a body at a moment. `layers` lie together; nil for fewer than two.
    init?(_ layers: [Node], at t: Double) {
        guard layers.count > 1, let lead = DepthBody.lead(of: layers), let at = layers.firstIndex(where: { $0.id == lead.id }) else { return nil }
        self.layers = layers
        poses = layers.map { $0.pose(at: t) }
        standing = zip(layers, poses).map { Self.standing($0, $1) }
        self.lead = at
        sides = Self.sides(of: standing[at])
        let along = sides.back
        var low = ScenePoint(x: .infinity, y: .infinity, z: .infinity)
        var high = ScenePoint(x: -.infinity, y: -.infinity, z: -.infinity)
        for n in standing {
            for p in DepthBody.reach(of: n) {
                let q = along(p)
                low = ScenePoint(x: min(low.x, q.x), y: min(low.y, q.y), z: min(low.z, q.z))
                high = ScenePoint(x: max(high.x, q.x), y: max(high.y, q.y), z: max(high.z, q.z))
            }
        }
        guard low.x.isFinite, high.x.isFinite else { return nil }
        self.low = low
        self.high = high
    }
}

extension BezzleDocument {
    /// The body these layers make at a moment of their film: nil unless they are several lying
    /// together (on one artboard, or in one group on it), which the Pose card's Tilt and Swing
    /// pose as one (`poseInDepth`).
    nonisolated func filmBody(of ids: [UUID], at t: Double) -> FilmBody? {
        let bodies = depthBodies(of: ids)
        guard bodies.count == 1 else { return nil }
        return FilmBody(bodies[0], at: t)
    }

    /// Turns a body in the plane of its lead's face, about its middle, by `degrees` clockwise as
    /// the lead's face shows, at a moment of its film. Each layer is keyed where a real body's
    /// face would go: its turn, and its tilt, swing, move and lift where those change. The lead
    /// is turned by exactly that much and keeps how it is tipped and swung. `start` is the design
    /// the turn is measured from: during a drag, the design as the drag began, so that the body
    /// is turned once from where it stood, however many steps the drag takes.
    mutating func poseBody(_ ids: [UUID], turnedBy degrees: Double, at t: Double, from start: BezzleDocument? = nil) {
        guard let body = (start ?? self).filmBody(of: ids, at: t) else { return }
        let spin = body.sides.after(.turn(degrees)).after(body.sides.back)
        let pivot = body.pivot
        for k in body.layers.indices {
            let member = body.layers[k], pose = body.poses[k]
            let stand = DepthBody.stand(of: body.standing[k], turned: spin, about: pivot)
            let design = member.transform3D ?? Transform3D()
            let leads = k == body.lead
            var next = pose
            next.turn = leads ? pose.turn + degrees : DepthBody.tidy(pose.turn + stand.twist)
            if !leads {
                next.tilt = DepthBody.tidy(stand.tip - design.x)
                next.swing = DepthBody.tidy(stand.swing - design.y)
            }
            next.lift = DepthBody.tidy(stand.middle.z - Double(design.z))
            next.move = CGPoint(x: DepthBody.tidy(stand.middle.x - Double(member.frame.midX)), y: DepthBody.tidy(stand.middle.y - Double(member.frame.midY)))
            key(member, from: pose, to: next, always: leads ? [.turn] : [], at: t)
        }
    }

    /// Grows a body about its middle in the plane of its lead's face (`FilmBody.growPivot`),
    /// `x` times along the lead's sides across and `y` times down, at a moment of its film. Each
    /// layer stands as far from that middle as the body has grown that way, and grows as much
    /// along its own sides as they run with the lead's; grown evenly, it stands that much further
    /// off the lead's plane too. Keyed where it changes: its scale, and its move and lift. The
    /// lead grows by exactly that much. `start` as for a turn.
    mutating func poseBody(_ ids: [UUID], grownBy x: Double, _ y: Double, at t: Double, from start: BezzleDocument? = nil) {
        guard let body = (start ?? self).filmBody(of: ids, at: t), x.isFinite, y.isFinite else { return }
        let z = abs(x - y) < 1e-9 ? x : 1
        let along = body.sides.back, pivot = along(body.growPivot)
        func grown(_ p: ScenePoint) -> ScenePoint { ScenePoint(x: p.x * x, y: p.y * y, z: p.z * z) }
        func length(_ p: ScenePoint) -> Double { (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot() }
        for k in body.layers.indices {
            let member = body.layers[k], pose = body.poses[k], standing = body.standing[k]
            let leads = k == body.lead
            let middle = body.sides(pivot + grown(along(DepthBody.middle(of: standing)) - pivot))
            // Its own sides, measured along the lead's, and how long each is once grown.
            let own = FilmBody.sides(of: standing)
            let across = length(grown(along(own(ScenePoint(x: 1))))), down = length(grown(along(own(ScenePoint(y: 1)))))
            let design = member.transform3D ?? Transform3D()
            var next = pose
            next.scale = leads ? CGPoint(x: Double(pose.scale.x) * x, y: Double(pose.scale.y) * y)
                : CGPoint(x: DepthBody.tidy(Double(pose.scale.x) * across), y: DepthBody.tidy(Double(pose.scale.y) * down))
            next.lift = DepthBody.tidy(middle.z - Double(design.z))
            next.move = CGPoint(x: DepthBody.tidy(middle.x - Double(member.frame.midX)), y: DepthBody.tidy(middle.y - Double(member.frame.midY)))
            key(member, from: pose, to: next, always: leads ? [.scale] : [], at: t)
        }
    }

    /// Keys a layer of a body at a moment where its pose changes from `was`, and the properties
    /// `always` whatever they say, starting again from the keys it had before the change was
    /// begun: so a drag that comes back leaves nothing behind it.
    private mutating func key(_ member: Node, from was: MotionPose, to next: MotionPose, always: Set<MotionProperty>, at t: Double) {
        update(member.id) { n in
            n.motion = member.motion
            for p in [MotionProperty.move, .scale, .turn, .lift, .tilt, .swing] {
                let a = was[p], b = next[p]
                guard always.contains(p) || zip(a, b).contains(where: { abs($0 - $1) > 1e-6 }) else { continue }
                n.pose(p, b, at: t)
            }
        }
    }
}
