import Foundation
import CoreGraphics

// Several layers turned in depth as one body, shared by every Bezzle. Layers picked together that
// lie together (on one artboard, or in one group) are the faces of one thing: turned, they go
// round the middle they share, each ending where a real body's face would, further along, higher
// or lower, and facing another way. Nothing is kept of the body: each layer stores where it
// stands and how it is turned, as it always did, so the file knows nothing new.

/// A place, or a way, in a scene: across and down as the page is drawn, and up off it toward
/// the eye.
nonisolated struct ScenePoint: Equatable, Hashable, Sendable {
    var x = 0.0, y = 0.0, z = 0.0

    static func + (a: ScenePoint, b: ScenePoint) -> ScenePoint { ScenePoint(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: ScenePoint, b: ScenePoint) -> ScenePoint { ScenePoint(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
}

/// A turn in space: three rows of three, as a layer's turn in depth is one (`Transform3D`, its
/// tip after its swing) and its turn in the page another.
nonisolated struct Spin: Equatable, Hashable, Sendable {
    var a = 1.0, b = 0.0, c = 0.0
    var d = 0.0, e = 1.0, f = 0.0
    var g = 0.0, h = 0.0, i = 1.0

    static let none = Spin()

    /// Clockwise in the page.
    static func turn(_ degrees: Double) -> Spin {
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return Spin(a: c, b: -s, d: s, e: c)
    }

    /// Round the upright axis, the right side going away.
    static func swing(_ degrees: Double) -> Spin {
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return Spin(a: c, c: s, g: -s, i: c)
    }

    /// Back about the level axis, the top going away.
    static func tip(_ degrees: Double) -> Spin {
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return Spin(e: c, f: -s, h: s, i: c)
    }

    func callAsFunction(_ p: ScenePoint) -> ScenePoint {
        ScenePoint(x: a * p.x + b * p.y + c * p.z, y: d * p.x + e * p.y + f * p.z, z: g * p.x + h * p.y + i * p.z)
    }

    /// This turn after another.
    func after(_ first: Spin) -> Spin {
        let m = self, n = first
        return Spin(a: m.a * n.a + m.b * n.d + m.c * n.g, b: m.a * n.b + m.b * n.e + m.c * n.h, c: m.a * n.c + m.b * n.f + m.c * n.i,
                    d: m.d * n.a + m.e * n.d + m.f * n.g, e: m.d * n.b + m.e * n.e + m.f * n.h, f: m.d * n.c + m.e * n.f + m.f * n.i,
                    g: m.g * n.a + m.h * n.d + m.i * n.g, h: m.g * n.b + m.h * n.e + m.i * n.h, i: m.g * n.c + m.h * n.f + m.i * n.i)
    }

    /// The turn that undoes it.
    var back: Spin { Spin(a: a, b: d, c: g, d: b, e: e, f: h, g: c, h: f, i: i) }

    /// Which way a face turned so points: out of the page, toward the eye, for none.
    var facing: ScenePoint { ScenePoint(x: c, y: f, z: i) }

    /// Degrees between -180 and 180.
    static func wrapped(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    /// The turn as a layer keeps it: tipped and swung in depth (`Transform3D`'s x and y), after a
    /// turn in the page, `twist`. Two sets of numbers say the same turn (a swing past edge on is
    /// one short of it tipped right over): the nearer to `near`, as the layer was turned, is
    /// given, so its numbers do not leap. Seen edge on, where tip and twist are one, the twist is
    /// none.
    func angles(near: (tip: Double, swing: Double) = (0, 0)) -> (tip: Double, swing: Double, twist: Double) {
        let degrees = 180 / Double.pi
        if abs(c) > 1 - 1e-12 {
            let s: Double = c > 0 ? 1 : -1
            return (atan2(d * s, e) * degrees, 90 * s, 0)
        }
        let one = (tip: atan2(-f, i) * degrees, swing: asin(c) * degrees, twist: atan2(-b, a) * degrees)
        let other = (tip: Self.wrapped(one.tip + 180), swing: Self.wrapped(180 - one.swing), twist: Self.wrapped(one.twist + 180))
        func far(_ t: (tip: Double, swing: Double, twist: Double)) -> Double {
            abs(Self.wrapped(t.tip - near.tip)) + abs(Self.wrapped(t.swing - near.swing)) + abs(t.twist)
        }
        return far(other) < far(one) - 1e-9 ? other : one
    }
}

nonisolated extension Spin {
    /// How a layer is turned in depth: swung, then tipped.
    init(_ t: Transform3D) {
        self = Spin.tip(t.x).after(.swing(t.y))
    }
}

/// Layers turned in depth as one body.
nonisolated enum DepthBody {
    /// The layer a body is read by and led by: its largest face, the first of those as large.
    /// The 3D card shows how it is turned, and what turns the body says how it shall be.
    static func lead(of body: [Node]) -> Node? {
        var lead: Node?
        var most: CGFloat = -1
        for n in body {
            let area = n.frame.width * n.frame.height
            if area > most { (lead, most) = (n, area) }
        }
        return lead
    }

    /// How far a layer is turned in the page itself: a group never is, what it holds is.
    private static func rotation(of node: Node) -> Double { node.isGroup ? 0 : node.rotation }

    /// Where a layer's middle stands in what holds it.
    static func middle(of node: Node) -> ScenePoint {
        ScenePoint(x: Double(node.frame.midX), y: Double(node.frame.midY), z: Double(node.transform3D?.z ?? 0))
    }

    /// Where the corners of a layer's frame stand in what holds it: top left, top right, bottom
    /// right, bottom left.
    static func corners(of node: Node) -> [ScenePoint] {
        let c = node.frame.center, m = middle(of: node)
        let spin = Spin(node.transform3D ?? Transform3D())
        return Geometry.corners(of: node.frame, rotation: rotation(of: node)).map { p in
            m + spin(ScenePoint(x: Double(p.x - c.x), y: Double(p.y - c.y)))
        }
    }

    /// The points a layer reaches to, where they stand in what holds it: the corners of its
    /// frame; of one pinned by its corners, where they are pinned; of a group, those of what it
    /// holds. They are the same points of it however it is turned in its own plane, which a
    /// group's frame, fitted round what it holds, and a pinned layer's are not.
    static func reach(of node: Node) -> [ScenePoint] {
        let c = node.frame.center, m = middle(of: node)
        let spin = Spin(node.transform3D ?? Transform3D())
        return lying(node).map { p in m + spin(ScenePoint(x: Double(p.x - c.x), y: Double(p.y - c.y))) }
    }

    /// The same, lying in the page of what holds it.
    private static func lying(_ node: Node) -> [CGPoint] {
        if node.isGroup, !node.isRepeatGrid, !node.children.isEmpty {
            return node.children.flatMap { child in
                lying(child).map { CGPoint(x: $0.x + node.frame.minX, y: $0.y + node.frame.minY) }
            }
        }
        if let t = node.transform3D, t.pinned, let pins = t.corners {
            return pins.map { CGPoint(x: node.frame.minX + $0.x * node.frame.width, y: node.frame.minY + $0.y * node.frame.height) }
        }
        return Geometry.corners(of: node.frame, rotation: rotation(of: node))
    }

    /// The middle a body turns about: of the box round all its layers reach to where they stand,
    /// measured along the lead's own sides. Flat and upright, that is the middle of the box round
    /// them on the page, half as high as they reach. Turned as one, the box turns with them, so
    /// the body goes round the same point every time, and laid flat again comes back to where it
    /// was.
    static func middle(of body: [Node], lead: Node) -> ScenePoint {
        let sides = Spin(lead.transform3D ?? Transform3D()).after(.turn(rotation(of: lead)))
        let along = sides.back
        var low = ScenePoint(x: .infinity, y: .infinity, z: .infinity)
        var high = ScenePoint(x: -.infinity, y: -.infinity, z: -.infinity)
        for n in body {
            for p in reach(of: n) {
                let q = along(p)
                low = ScenePoint(x: min(low.x, q.x), y: min(low.y, q.y), z: min(low.z, q.z))
                high = ScenePoint(x: max(high.x, q.x), y: max(high.y, q.y), z: max(high.z, q.z))
            }
        }
        guard low.x.isFinite else { return middle(of: lead) }
        return sides(ScenePoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2, z: (low.z + high.z) / 2))
    }

    /// Whether the layers of a body all face one way, as the faces of something flat do, or of
    /// something turned as one from flat.
    static func facesOneWay(_ body: [Node]) -> Bool {
        guard let first = body.first else { return true }
        let way = Spin(first.transform3D ?? Transform3D()).facing
        return body.allSatisfy { n in
            let f = Spin(n.transform3D ?? Transform3D()).facing
            return f.x * way.x + f.y * way.y + f.z * way.z > 1 - 1e-6
        }
    }

    /// A number as it is kept: what is a round number but for the arithmetic's last places is
    /// that number, so a body laid flat again is back to the point.
    static func tidy(_ v: Double) -> Double {
        let r = (v * 100).rounded() / 100
        // Not -0, which a file would keep.
        return abs(r - v) < 1e-7 ? (r == 0 ? 0 : r) : v
    }

    /// How a layer of a body stands once the body is turned: where its middle is, how it is
    /// tipped and swung, and what is left of the turn, a turn in its own plane.
    struct Stand: Equatable, Sendable {
        var middle: ScenePoint
        var tip: Double
        var swing: Double
        var twist: Double
    }

    /// A layer of a body turned by `spin` about `pivot`, in what holds it.
    static func stand(of node: Node, turned spin: Spin, about pivot: ScenePoint) -> Stand {
        let was = node.transform3D ?? Transform3D()
        let angles = spin.after(Spin(was)).angles(near: (was.x, was.y))
        return Stand(middle: pivot + spin(middle(of: node) - pivot), tip: tidy(angles.tip), swing: tidy(angles.swing), twist: tidy(angles.twist))
    }

    /// A layer of a body turned by `spin` about `pivot`, in what holds it: where its middle goes,
    /// how high, and how it is then tipped and swung. What is left of the turn, a turn in its own
    /// plane, it takes as any layer is turned in the page: by its rotation; a group by what it
    /// holds; one pinned by its corners by where they are pinned.
    @MainActor
    static func turned(_ node: Node, by spin: Spin, about pivot: ScenePoint) -> Node {
        var n = node
        let stand = stand(of: node, turned: spin, about: pivot)
        var place = stand.middle
        var turn = node.transform3D ?? Transform3D()
        turn.x = stand.tip
        turn.y = stand.swing
        if abs(stand.twist) > 1e-6 {
            let c = node.frame.center, w = node.frame.width, h = node.frame.height
            if turn.pinned, let corners = turn.corners, w > 0, h > 0 {
                turn.corners = corners.map { k in
                    let p = Geometry.rotate(CGPoint(x: (k.x - 0.5) * w, y: (k.y - 0.5) * h), by: stand.twist)
                    return CGPoint(x: p.x / w + 0.5, y: p.y / h + 0.5)
                }
            } else {
                n = BezzleDocument.turned(n, by: stand.twist, about: c)
                if n.isGroup {
                    // Its frame fits round what it holds, turned: its middle, which it is turned
                    // in depth about, has gone a little way in its own plane, and it stands that
                    // much further along, so that everything in it stays where the body has it.
                    n = BezzleDocument.fitted(n)
                    let gone = ScenePoint(x: Double(n.frame.midX - c.x), y: Double(n.frame.midY - c.y))
                    place = place + Spin(turn)(gone)
                }
            }
        }
        n.frame = CGRect(center: CGPoint(x: CGFloat(tidy(place.x)), y: CGFloat(tidy(place.y))), size: n.frame.size)
        turn.z = CGFloat(tidy(place.z))
        n.transform3D = turn
        return n
    }
}

extension BezzleDocument {
    /// The layers among these that can be turned in depth (not artboards, which are the page, nor
    /// locked ones), as the bodies they turn as: those lying together on an artboard, or in a
    /// group on one, are one body. Off any artboard there is no scene to stand in, each layer
    /// being seen from in front of its own middle, so each is a body of its own. In the order given.
    nonisolated func depthBodies(of ids: [UUID]) -> [[Node]] {
        var bodies: [[Node]] = [], known: [UUID: Int] = [:]
        for id in ids {
            guard let n = node(id), !n.isArtboard, !n.locked else { continue }
            guard let parent = parent(of: id), eye(inside: parent.id) != nil else {
                bodies.append([n])
                continue
            }
            if let at = known[parent.id] {
                bodies[at].append(n)
            } else {
                known[parent.id] = bodies.count
                bodies.append([n])
            }
        }
        return bodies
    }

    /// Turns layers in depth. `aim` is asked, for each body among them, how its lead shall be
    /// turned and how high it shall stand: it is given the lead as `start` has it, and how it is
    /// turned now. One layer is turned about its own middle, where it is. Several lying together
    /// go with their lead as one body about the middle they share (`DepthBody`), and as much
    /// nearer or further as it goes. `start` is the design the turn is measured from: during a
    /// drag, the design as the drag began, so that a body is turned once from where it stood,
    /// however many steps the drag takes. Gives back how each body's lead is then turned.
    @discardableResult
    mutating func turnInDepth(_ ids: [UUID], from start: BezzleDocument? = nil,
                              _ aim: (_ lead: Node, _ now: Transform3D) -> Transform3D) -> [Transform3D] {
        let start = start ?? self
        var turns: [Transform3D] = []
        for body in start.depthBodies(of: ids) {
            guard let lead = DepthBody.lead(of: body), let now = node(lead.id) else { continue }
            let current = now.transform3D ?? Transform3D()
            let target = aim(lead, current)
            turns.append(target)
            guard body.count > 1 else {
                update(lead.id) { $0.transform3D = target }
                continue
            }
            let was = lead.transform3D ?? Transform3D()
            let pivot = DepthBody.middle(of: body, lead: lead)
            func height(_ node: Node) -> Double { Double(node.transform3D?.z ?? 0) }
            // The turn takes the lead's middle round the body's, higher or lower. Beyond that the
            // body goes nearer or further only when it is aimed so: then its lead stands as high
            // as was said. Aimed no higher, it keeps what it was lifted by since `start`.
            let leading = DepthBody.turned(lead, by: Spin(target).after(Spin(was).back), about: pivot)
            var rise = 0.0
            if target.z != current.z {
                rise = Double(target.z) - height(leading)
            } else if current != was {
                rise = Double(current.z) - height(DepthBody.turned(lead, by: Spin(current).after(Spin(was).back), about: pivot))
            }
            if abs(rise) < 1e-7 { rise = 0 }
            let spin = Spin(target).after(Spin(was).back)
            for member in body {
                var turned = member.id == lead.id ? leading : DepthBody.turned(member, by: spin, about: pivot)
                if member.id == lead.id {
                    // To the number, as it was aimed.
                    turned.transform3D?.x = target.x
                    turned.transform3D?.y = target.y
                }
                if rise != 0 {
                    let raised = DepthBody.tidy(height(turned) + rise)
                    turned.transform3D?.z = CGFloat(raised)
                }
                if member.id == lead.id, target.z != current.z { turned.transform3D?.z = target.z }
                update(member.id) { $0 = turned }
            }
        }
        return turns
    }

    /// Lays layers flat in the page again, each as high as it stood. A body whose layers all face
    /// one way, as one turned together from flat does, is laid back as one, so its layers come to
    /// lie as they lay before it was turned; any others are each laid flat where they are.
    mutating func layFlat(_ ids: [UUID], from start: BezzleDocument? = nil) {
        let start = start ?? self
        for body in start.depthBodies(of: ids) {
            if body.count > 1, DepthBody.facesOneWay(body) {
                turnInDepth(body.map(\.id), from: start) { _, now in
                    var t = now
                    t.x = 0
                    t.y = 0
                    return t
                }
            } else {
                for n in body where n.transform3D != nil {
                    update(n.id) { $0.transform3D?.x = 0; $0.transform3D?.y = 0 }
                }
            }
        }
    }
}

// MARK: - In a film

extension BezzleDocument {
    /// A layer as it stands at a moment of its film, for a body to be worked out from: where its
    /// keys have its middle, how big, and how far turned, tipped, swung and lifted.
    nonisolated private static func standing(_ node: Node, _ pose: MotionPose) -> Node {
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

    /// Poses how far layers are tipped or swung at a moment of their film (`property` is `.tilt`
    /// or `.swing`), each body's lead to what `value` says for it. One layer is posed as it
    /// always was. Several lying together are posed as one body about the middle they share, as
    /// they stand at that moment (`DepthBody`): each gets the keys that put it where the body's
    /// face would be, tilt and swing, and move, lift and turn where those change. Between keys
    /// each property goes its own way, so a body is whole at its keys and nearly so between them;
    /// a group is what keeps layers one thing all the way.
    mutating func poseInDepth(_ property: MotionProperty, of ids: [UUID], at t: Double, _ value: (Node) -> Double) {
        guard property == .tilt || property == .swing else { return }
        for body in depthBodies(of: ids) {
            guard let lead = DepthBody.lead(of: body) else { continue }
            let v = value(lead)
            guard body.count > 1 else {
                update(lead.id) { $0.pose(property, [v], at: t) }
                continue
            }
            let poses = body.map { $0.pose(at: t) }
            let standing = zip(body, poses).map { Self.standing($0, $1) }
            guard let at = body.firstIndex(where: { $0.id == lead.id }) else { continue }
            let was = standing[at].transform3D ?? Transform3D()
            var target = was
            if property == .tilt { target.x = (lead.transform3D?.x ?? 0) + v } else { target.y = (lead.transform3D?.y ?? 0) + v }
            let spin = Spin(target).after(Spin(was).back)
            let pivot = DepthBody.middle(of: standing, lead: standing[at])
            for (k, member) in body.enumerated() {
                let pose = poses[k]
                let stand = DepthBody.stand(of: standing[k], turned: spin, about: pivot)
                let design = member.transform3D ?? Transform3D()
                let leads = member.id == lead.id
                let tilt = leads && property == .tilt ? v : DepthBody.tidy(stand.tip - design.x)
                let swing = leads && property == .swing ? v : DepthBody.tidy(stand.swing - design.y)
                let lift = DepthBody.tidy(stand.middle.z - Double(design.z))
                let move = [DepthBody.tidy(stand.middle.x - Double(member.frame.midX)), DepthBody.tidy(stand.middle.y - Double(member.frame.midY))]
                let turn = DepthBody.tidy(pose.turn + stand.twist)
                update(member.id) { n in
                    if (leads && property == .tilt) || abs(tilt - pose.tilt) > 1e-6 { n.pose(.tilt, [tilt], at: t) }
                    if (leads && property == .swing) || abs(swing - pose.swing) > 1e-6 { n.pose(.swing, [swing], at: t) }
                    if abs(lift - pose.lift) > 1e-6 { n.pose(.lift, [lift], at: t) }
                    if abs(move[0] - Double(pose.move.x)) > 1e-6 || abs(move[1] - Double(pose.move.y)) > 1e-6 { n.pose(.move, move, at: t) }
                    if abs(turn - pose.turn) > 1e-6 { n.pose(.turn, [turn], at: t) }
                }
            }
        }
    }
}
