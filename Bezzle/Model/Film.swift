import Foundation
import CoreGraphics

// An artboard's film: its layers posed at a moment and seen by its camera. One piece of
// arithmetic says where everything shows, and the canvas, playing and the exported movie all ask
// it, so that what is posed is what plays and what is saved.
//
// The artboard is a sheet lying in space, x across and y down as it is drawn, with z rising off it
// toward the eye. A layer lies in the sheet until it is lifted, tipped or swung. The camera looks
// straight down at the sheet's middle from far enough to see all of it; moving it looks elsewhere,
// zooming brings it closer, and tilting it tips the whole scene back as a card is tipped in the
// hand, so what is lifted off the sheet shows its height.

// MARK: - A plane into the picture

/// Where each point of a flat thing shows in the film's frame: a 3 by 3 map of its plane, as any
/// flat thing seen in perspective has. `x' = (a x + b y + c) / w`, `y' = (d x + e y + f) / w`,
/// `w = g x + h y + i`.
nonisolated struct FilmMap: Equatable, Sendable {
    var a = 1.0, b = 0.0, c = 0.0
    var d = 0.0, e = 1.0, f = 0.0
    var g = 0.0, h = 0.0, i = 1.0

    static let identity = FilmMap()

    static func translation(_ x: Double, _ y: Double) -> FilmMap { FilmMap(c: x, f: y) }
    static func scale(_ k: Double) -> FilmMap { FilmMap(a: k, e: k) }

    /// How near the eye the point is, as the divisor: at or below nothing it is behind the eye.
    func depth(at p: CGPoint) -> Double { g * Double(p.x) + h * Double(p.y) + i }

    /// Where a point shows. One behind the eye is pressed against it, so nothing is ever at infinity.
    func callAsFunction(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = max(g * x + h * y + i, 1e-6)
        return CGPoint(x: (a * x + b * y + c) / w, y: (d * x + e * y + f) / w)
    }

    /// This map after another: what `first` puts somewhere, this takes on from there.
    func after(_ first: FilmMap) -> FilmMap {
        let m = self, n = first
        return FilmMap(a: m.a * n.a + m.b * n.d + m.c * n.g, b: m.a * n.b + m.b * n.e + m.c * n.h, c: m.a * n.c + m.b * n.f + m.c * n.i,
                       d: m.d * n.a + m.e * n.d + m.f * n.g, e: m.d * n.b + m.e * n.e + m.f * n.h, f: m.d * n.c + m.e * n.f + m.f * n.i,
                       g: m.g * n.a + m.h * n.d + m.i * n.g, h: m.g * n.b + m.h * n.e + m.i * n.h, i: m.g * n.c + m.h * n.f + m.i * n.i)
    }

    /// The way back: from where something shows to the point of the plane that shows there. Nil
    /// for a plane seen edge on, which shows nothing.
    var inverse: FilmMap? {
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12, det.isFinite else { return nil }
        let k = 1 / det
        return FilmMap(a: (e * i - f * h) * k, b: (c * h - b * i) * k, c: (b * f - c * e) * k,
                       d: (f * g - d * i) * k, e: (a * i - c * g) * k, f: (c * d - a * f) * k,
                       g: (d * h - e * g) * k, h: (b * g - a * h) * k, i: (a * e - b * d) * k)
    }

    /// The point of the plane that shows at a point of the picture; nil past its horizon.
    func back(_ p: CGPoint) -> CGPoint? {
        guard let inverse else { return nil }
        let x = Double(p.x), y = Double(p.y)
        let w = inverse.g * x + inverse.h * y + inverse.i
        guard abs(w) > 1e-9 else { return nil }
        let q = CGPoint(x: (inverse.a * x + inverse.b * y + inverse.c) / w, y: (inverse.d * x + inverse.e * y + inverse.f) / w)
        // Behind the eye, the plane does not show there.
        guard depth(at: q) > 1e-6 else { return nil }
        return q
    }

    /// How many times bigger than it is drawn a small thing at this point shows, the longer way.
    func stretch(at p: CGPoint) -> Double {
        let o = self(p), x = self(CGPoint(x: p.x + 1, y: p.y)), y = self(CGPoint(x: p.x, y: p.y + 1))
        return Double(max(hypot(x.x - o.x, x.y - o.y), hypot(y.x - o.x, y.y - o.y)))
    }

    /// Whether it keeps things flat in the page: no perspective in it.
    var isFlat: Bool { abs(g) < 1e-12 && abs(h) < 1e-12 }

    /// What of a polygon lies on the side of a line where `a x + b y + c` is not below nothing.
    static func cut(_ polygon: [CGPoint], along side: (a: Double, b: Double, c: Double)) -> [CGPoint] {
        func over(_ p: CGPoint) -> Double { side.a * Double(p.x) + side.b * Double(p.y) + side.c }
        var out: [CGPoint] = []
        for (k, p) in polygon.enumerated() {
            let q = polygon[(k + 1) % polygon.count]
            let dp = over(p), dq = over(q)
            if dp >= 0 { out.append(p) }
            if (dp >= 0) != (dq >= 0) {
                let t = dp / (dp - dq)
                out.append(CGPoint(x: Double(p.x) + Double(q.x - p.x) * t, y: Double(p.y) + Double(q.y - p.y) * t))
            }
        }
        return out
    }

    /// What of a rect of the plane shows through a window of the picture: the part of the rect
    /// that does, and how many times bigger than it is drawn the plane shows there at most. Nil
    /// when nothing of it shows. A film is drawn from this: only what is seen, as sharp as it is
    /// seen, however far the camera goes in.
    func seen(of rect: CGRect, through window: CGRect) -> (part: CGRect, stretch: Double)? {
        guard rect.width > 0, rect.height > 0, window.width > 0, window.height > 0 else { return nil }
        var outline = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let x0 = Double(window.minX), x1 = Double(window.maxX), y0 = Double(window.minY), y1 = Double(window.maxY)
        // In front of the eye, and within the window's four sides: each a line on the plane.
        let sides: [(a: Double, b: Double, c: Double)] = [
            (g, h, i - 1e-3),
            (a - x0 * g, b - x0 * h, c - x0 * i),
            (x1 * g - a, x1 * h - b, x1 * i - c),
            (d - y0 * g, e - y0 * h, f - y0 * i),
            (y1 * g - d, y1 * h - e, y1 * i - f),
        ]
        for side in sides {
            outline = Self.cut(outline, along: side)
            guard outline.count >= 3 else { return nil }
        }
        var box = CGRect.null
        var most = 0.0, cx = 0.0, cy = 0.0
        for p in outline {
            box = box.union(CGRect(origin: p, size: .zero))
            most = max(most, stretch(at: p))
            cx += Double(p.x); cy += Double(p.y)
        }
        most = max(most, stretch(at: CGPoint(x: cx / Double(outline.count), y: cy / Double(outline.count))))
        box = box.intersection(rect)
        guard !box.isNull, box.width > 0, box.height > 0, most.isFinite else { return nil }
        return (box, most)
    }
}

// MARK: - The lens

/// The camera's arithmetic.
nonisolated enum FilmLens {
    /// A direction or a place in the artboard's space.
    private struct V { var x = 0.0, y = 0.0, z = 0.0 }

    /// A flat thing placed in space: where its plane's x and y lead, and where its origin is.
    private struct Plane {
        var u = V(x: 1), v = V(y: 1), o = V()

        func turned(_ f: (V) -> V) -> Plane { Plane(u: f(u), v: f(v), o: f(o)) }
        func moved(_ d: V) -> Plane { Plane(u: u, v: v, o: V(x: o.x + d.x, y: o.y + d.y, z: o.z + d.z)) }
    }

    /// Turned clockwise in the page.
    private static func turn(_ p: V, _ degrees: Double) -> V {
        guard degrees != 0 else { return p }
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return V(x: p.x * c - p.y * s, y: p.x * s + p.y * c, z: p.z)
    }

    /// Swung round its upright axis, its right side going away.
    private static func swing(_ p: V, _ degrees: Double) -> V {
        guard degrees != 0 else { return p }
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return V(x: p.x * c + p.z * s, y: p.y, z: -p.x * s + p.z * c)
    }

    /// Tipped back about its level axis, its top going away.
    private static func tilt(_ p: V, _ degrees: Double) -> V {
        guard degrees != 0 else { return p }
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return V(x: p.x, y: p.y * c - p.z * s, z: p.y * s + p.z * c)
    }

    /// How far above the artboard's middle the camera rests: twice as far as the artboard is big,
    /// as a layer turned in depth is looked at (`Perspective.viewingDistance`), so the two agree.
    static func distance(for size: CGSize) -> Double {
        max(600, Double(max(size.width, size.height)) * 2)
    }

    /// A plane in the artboard's space as the camera shows it in a frame of `size`.
    private static func seen(_ plane: Plane, by camera: FilmCamera, size: CGSize) -> FilmMap {
        let d = distance(for: size), s = camera.zoom
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        // The scene, measured from where the camera looks, turned under it as a card in the hand.
        func view(_ p: V, place: Bool) -> V {
            var q = place ? V(x: p.x - cx - camera.x, y: p.y - cy - camera.y, z: p.z) : p
            q = turn(q, camera.roll)
            q = swing(q, camera.swing)
            q = tilt(q, camera.tilt)
            return V(x: q.x * s, y: q.y * s, z: q.z * s)
        }
        let u = view(plane.u, place: false), v = view(plane.v, place: false), o = view(plane.o, place: true)
        // Seen from `d` above the frame's middle: across and down grow as it comes nearer.
        let g = -u.z, h = -v.z, i = d - o.z
        return FilmMap(a: d * u.x + cx * g, b: d * v.x + cx * h, c: d * o.x + cx * i,
                       d: d * u.y + cy * g, e: d * v.y + cy * h, f: d * o.y + cy * i,
                       g: g, h: h, i: i)
    }

    /// The artboard's own sheet, or one lying level `height` above it, as the camera shows it:
    /// from the artboard's points to the frame's.
    static func ground(_ camera: FilmCamera, size: CGSize, height: Double = 0) -> FilmMap {
        seen(Plane(o: V(z: height)), by: camera, size: size)
    }

    /// A posed layer as the camera shows it: from its drawing at rest, in the artboard's points,
    /// to the frame's. `center` is its middle on the artboard and `rotation` how far the design
    /// has it turned, about which it grows. `depth` is how the design has it turned in depth, for
    /// one whose drawing was made lying flat, which the film then turns in its own space. One
    /// lying in a group that keeps its layers' depth stands where the group puts it (`FilmStand`):
    /// its middle at `stands`, and turned in its own plane by `twist` besides.
    static func layer(center: CGPoint, rotation: Double, depth: Transform3D? = nil, pose: MotionPose, camera: FilmCamera, size: CGSize,
                      twist: Double = 0, stands: CGPoint? = nil) -> FilmMap {
        let c = V(x: Double(center.x), y: Double(center.y))
        // A point of the drawing, measured from the layer's middle, grown along its own sides.
        func own(_ p: V) -> V {
            var q = turn(p, -rotation)
            q = V(x: q.x * Double(pose.scale.x), y: q.y * Double(pose.scale.y), z: q.z)
            q = turn(q, rotation + pose.turn + twist)
            q = swing(q, pose.swing + (depth?.y ?? 0))
            return tilt(q, pose.tilt + (depth?.x ?? 0))
        }
        let at = stands.map { V(x: Double($0.x), y: Double($0.y)) } ?? c
        let place = V(x: at.x + Double(pose.move.x), y: at.y + Double(pose.move.y), z: pose.lift + Double(depth?.z ?? 0))
        let u = own(V(x: 1)), v = own(V(y: 1))
        // The drawing's origin is the artboard's: its middle is `c` from there.
        let o = own(V(x: -c.x, y: -c.y))
        let plane = Plane(u: u, v: v, o: V(x: o.x + place.x, y: o.y + place.y, z: o.z + place.z))
        return seen(plane, by: camera, size: size)
    }
}

// MARK: - Pieces

/// A part of an artboard that moves as one in its film, and so is drawn once and then only
/// placed: its ground; a run of layers lying together that nothing moves; or one layer with
/// motion of its own.
nonisolated struct FilmPiece: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable { case ground, run, layer }

    var kind: Kind
    /// The layers drawn in it, bottom first; none for the ground.
    var layers: [UUID] = []
    /// Where what holds them begins on the artboard: the groups they were taken out of.
    var origin = CGPoint.zero
    /// Those groups, outermost first.
    var holders: [UUID] = []
    /// Something inside it moves too, so its drawing changes as time passes.
    var changes = false
    /// Drawn lying flat though the design has it turned in depth, for the film to turn.
    var flat = false
    /// Taken out of a group that keeps its layers' depth: where the group's turn and height put it.
    var stand: FilmStand?

    var key: String { ([kind.rawValue] + layers.map(\.uuidString)).joined(separator: "/") + (flat ? "/flat" : "") }
}

/// Where a piece taken out of a group that keeps its layers' depth (`Node.opensInDepth`) stands in
/// the artboard's scene, turned and lifted by the group and by every such group about that one:
/// what the film turns its flat drawing by, in place of the layer's own turn. For a layer, its
/// middle; for a run of layers lying in the group, where the group's own points begin.
nonisolated struct FilmStand: Equatable, Hashable, Sendable {
    var middle: CGPoint
    var tip = 0.0, swing = 0.0, twist = 0.0, height = 0.0
    /// How the group's own plane is turned in the scene: what its layers lie in or stand off,
    /// and so what their places, heights and turns are measured in, and their keys with them.
    var plane = Spin.none
    /// A run lying in a group that is turned: each of its layers as the design orders it
    /// (`DepthOrder.face`), bottom first, for the film to order the run as the design orders
    /// them (`filmOrder`). None in a group that only lifts what it holds, which is all as high.
    var lying: [DepthOrder.Face] = []

    var depth: Transform3D { Transform3D(x: tip, y: swing, z: CGFloat(height)) }

    /// A layer seen from `eye`, where what holds it is seen from, that beginning at `origin` on the
    /// artboard; nil for a run. Nil outside any group that keeps depth.
    init?(_ layer: Node?, eye: Eye, origin: CGPoint) {
        guard let space = eye.space else { return nil }
        let t = layer?.transform3D.flatMap { $0.pinned ? nil : $0 }
        let spin = t.map { space.spin.after(Spin($0)) } ?? space.spin
        let stood = space(ScenePoint(x: Double(layer?.frame.midX ?? 0), y: Double(layer?.frame.midY ?? 0), z: Double(t?.z ?? 0)))
        let angles = spin.angles()
        middle = CGPoint(x: origin.x + CGFloat(stood.x), y: origin.y + CGFloat(stood.y))
        tip = angles.tip
        swing = angles.swing
        twist = angles.twist
        height = stood.z
        plane = space.spin
    }

    /// Where its layer stands posed by its keys: as the same change made in the design would
    /// stand it (`Node.posed`). A Move slides it along the group's plane and a Lift raises it
    /// along that plane's normal, so it stays on what lies in the group however the group is
    /// turned; a Tilt or a Swing is added to the layer's own, inside the group.
    func posed(_ pose: MotionPose, of layer: Node) -> FilmStand {
        guard pose.move != .zero || pose.inDepth else { return self }
        var out = self
        let by = plane(ScenePoint(x: Double(pose.move.x), y: Double(pose.move.y), z: pose.lift))
        out.middle = CGPoint(x: middle.x + CGFloat(by.x), y: middle.y + CGFloat(by.y))
        out.height = height + by.z
        if pose.tilt != 0 || pose.swing != 0 {
            let t = layer.transform3D.flatMap { $0.pinned ? nil : $0 }
            let angles = plane.after(Spin.tip((t?.x ?? 0) + pose.tilt).after(.swing((t?.y ?? 0) + pose.swing))).angles()
            out.tip = angles.tip
            out.swing = angles.swing
            out.twist = angles.twist
        }
        return out
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(middle)
        hasher.combine(tip)
        hasher.combine(swing)
        hasher.combine(twist)
        hasher.combine(height)
        hasher.combine(plane)
    }
}

nonisolated extension Node {
    /// Whether a group can be drawn as its layers one by one and look the same: nothing is done
    /// to it as a whole.
    var comesApart: Bool {
        isGroup && mask == nil && clipsToFirst != true && opacity >= 0.999 && blur == nil && blend == nil
            && transform3D == nil && !shadow.on && moreShadows?.contains(where: \.on) != true && grid == nil
    }

    /// Artboards: the pieces its film is made of, bottom first. `loose` are layers to keep apart
    /// though they have no keys yet, such as the ones picked, so that posing them moves them at once.
    func filmPieces(loose: Set<UUID> = []) -> [FilmPiece] {
        var out = [FilmPiece(kind: .ground)]
        func holdsLoose(_ n: Node) -> Bool { n.children.contains { loose.contains($0.id) || holdsLoose($0) } }
        func walk(_ nodes: [Node], origin: CGPoint, holders: [UUID], eye: Eye) {
            var run: [UUID] = []
            // The run's layers as the design orders them, where the group they lie in is turned:
            // their middles then stand at different heights, and one piece is drawn of them all.
            var lying: [DepthOrder.Face] = []
            let turned = eye.space.map { $0.spin != Spin.none } ?? false
            func flush() {
                if !run.isEmpty {
                    var stand = FilmStand(nil, eye: eye, origin: origin)
                    stand?.lying = lying
                    out.append(FilmPiece(kind: .run, layers: run, origin: origin, holders: holders, stand: stand))
                }
                run = []
                lying = []
            }
            // In a group that keeps its layers' depth, every piece stands where the group puts it.
            let stood = eye.space != nil
            for n in nodes where !n.hidden {
                // A shader that moves is drawn again at every moment, as a layer whose insides move.
                let own = n.isAnimated || loose.contains(n.id) || n.shaderMoves
                let inside = n.holdsMotion || holdsLoose(n) || n.children.contains(where: \.holdsMovingShader)
                // Held up off the artboard by the design, it stands in the scene where the design
                // has it, so the camera sees how high it is: drawn flat, for the film to turn and
                // lift in its own space, which sees it from where the design does (`Eye.stage`).
                // A screen pinned into a photo keeps the look it has.
                let deep = Perspective.inDepth(n) && n.transform3D?.pinned != true
                if !own, n.opensInDepth, !n.children.isEmpty {
                    // A group that keeps its layers' depth, with no keys of its own, comes apart
                    // into the scene: each of its layers a piece where the group puts it, so the
                    // film orders them among everything else and the camera sees between them.
                    flush()
                    walk(n.children, origin: CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY), holders: holders + [n.id], eye: eye.within(n))
                } else if own || deep || (stood && inside) {
                    flush()
                    out.append(FilmPiece(kind: .layer, layers: [n.id], origin: origin, holders: holders,
                                         changes: n.holdsMotion || n.holdsMovingShader || n.reshapes || n.looksChange,
                                         flat: deep || (stood && n.transform3D?.pinned != true), stand: FilmStand(n, eye: eye, origin: origin)))
                } else if inside, n.comesApart {
                    flush()
                    walk(n.children, origin: CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY), holders: holders + [n.id], eye: eye.within(n))
                } else if inside {
                    // Masked, faded or the like as a whole: drawn again as what it holds moves.
                    flush()
                    out.append(FilmPiece(kind: .layer, layers: [n.id], origin: origin, holders: holders,
                                         changes: n.holdsMotion || n.holdsMovingShader || n.reshapes || n.looksChange))
                } else {
                    run.append(n.id)
                    if turned { lying.append(DepthOrder.face(of: n, eye: eye, origin: origin)) }
                }
            }
            flush()
        }
        walk(children, origin: .zero, holders: [], eye: Eye.stage(frame.size))
        return out
    }

    /// A layer somewhere in this one, by its id.
    func descendant(_ id: UUID) -> Node? {
        for child in children {
            if child.id == id { return child }
            if let found = child.descendant(id) { return found }
        }
        return nil
    }

    /// The layers from this one down to a layer in it, the outermost first, ending with the layer.
    func way(to id: UUID) -> [Node]? {
        for child in children {
            if child.id == id { return [child] }
            if let rest = child.way(to: id) { return [child] + rest }
        }
        return nil
    }
}

/// A piece at one moment: where it shows, and how.
nonisolated struct FilmPlacement: Equatable, Sendable {
    /// From its drawing, in the artboard's points, to the film's frame.
    var map = FilmMap.identity
    var opacity = 1.0
    var blur = 0.0
    /// How far above the artboard it is, which says what covers what once layers are lifted.
    var height = 0.0
    /// A layer's piece as it stands in the scene, turned and all: the faces of a body turned as
    /// one are ordered as the design orders them (`DepthOrder.nearness`).
    var face: DepthOrder.Face?
    /// How much it is blurred for standing off the camera's focus, across the frame; nil under
    /// a camera that blurs nothing.
    var soft: FilmSoft?
}

nonisolated extension Node {
    /// Artboards: where a piece shows at a moment, through this camera.
    func placement(of piece: FilmPiece, at t: Double, camera: FilmCamera) -> FilmPlacement {
        placement(of: piece, layer: piece.kind == .layer ? piece.layers.first.flatMap { descendant($0) } : nil, at: t, camera: camera)
    }

    /// The same, for a piece whose layer has been found already (`filmLayers`): what is placed
    /// frame after frame is not looked for through the whole artboard each time.
    func placement(of piece: FilmPiece, layer: Node?, at t: Double, camera: FilmCamera) -> FilmPlacement {
        var placed = stood(piece, layer: layer, at: t, camera: camera)
        // Where it stands says how far it is off the camera's focus (`FilmSoft`).
        if camera.blur > 0 { placed.soft = FilmLens.soft(of: placed.map, camera: camera, size: frame.size) }
        return placed
    }

    /// Where a piece stands and shows at a moment, before the camera's focus is asked.
    private func stood(_ piece: FilmPiece, layer: Node?, at t: Double, camera: FilmCamera) -> FilmPlacement {
        guard piece.kind == .layer, let layer else {
            // A run of layers lying in a group that keeps depth lies in the group's plane, where that stands.
            if piece.kind == .run, let stand = piece.stand {
                let map = FilmLens.layer(center: piece.origin, rotation: 0, depth: stand.depth, pose: .rest, camera: camera, size: frame.size,
                                         twist: stand.twist, stands: stand.middle)
                // In a group that is turned its layers' middles stand at different heights. Lying
                // in one plane, they are as near as the highest of them (`DepthOrder.nearness`),
                // and among what is turned beside them `filmOrder` asks about each (`lying`).
                return FilmPlacement(map: map, height: stand.lying.map(\.middle.z).max() ?? stand.height)
            }
            return FilmPlacement(map: FilmLens.ground(camera, size: frame.size))
        }
        var pose = layer.pose(at: t)
        let (fade, blur) = (pose.fade, pose.blur)
        let center = CGPoint(x: piece.origin.x + layer.frame.midX, y: piece.origin.y + layer.frame.midY)
        // In a group that keeps depth its keys are measured in the group, as its place is: it
        // stands where they put it there, and only grows and turns in its own plane besides.
        let stand = piece.stand?.posed(pose, of: layer)
        if stand != nil {
            pose.move = .zero
            pose.lift = 0
            pose.tilt = 0
            pose.swing = 0
        }
        let depth = stand?.depth ?? (piece.flat ? layer.transform3D : nil)
        let twist = stand?.twist ?? 0, stands = stand?.middle ?? center
        let map = FilmLens.layer(center: center, rotation: layer.isGroup ? 0 : layer.rotation, depth: depth, pose: pose, camera: camera, size: frame.size,
                                 twist: twist, stands: stand?.middle)
        let height = pose.lift + Double(depth?.z ?? 0)
        // Tipped or swung, by the design or its keys: where it stands, for the order.
        let tip = pose.tilt + (depth?.x ?? 0), swing = pose.swing + (depth?.y ?? 0)
        var face: DepthOrder.Face?
        if tip != 0 || swing != 0 {
            face = DepthOrder.Face(middle: ScenePoint(x: Double(stands.x + pose.move.x), y: Double(stands.y + pose.move.y), z: height),
                                   size: CGSize(width: layer.frame.width * pose.scale.x, height: layer.frame.height * pose.scale.y),
                                   rotation: (layer.isGroup ? 0 : layer.rotation) + pose.turn + twist, turn: Spin.tip(tip).after(.swing(swing)))
        }
        return FilmPlacement(map: map, opacity: fade, blur: blur, height: height, face: face)
    }

    /// Artboards: the layer each piece places, found in one walk through it: nil for the ground,
    /// and for a piece whose layer is not on it.
    func filmLayers(of pieces: [FilmPiece]) -> [Node?] {
        var wanted: [UUID: [Int]] = [:]
        for (i, piece) in pieces.enumerated() where piece.kind == .layer {
            if let id = piece.layers.first { wanted[id, default: []].append(i) }
        }
        var out = [Node?](repeating: nil, count: pieces.count)
        var left = wanted.count
        func walk(_ nodes: [Node]) {
            for n in nodes {
                guard left > 0 else { return }
                if let at = wanted.removeValue(forKey: n.id) {
                    for i in at { out[i] = n }
                    left -= 1
                }
                if !n.children.isEmpty { walk(n.children) }
            }
        }
        walk(children)
        return out
    }

    /// Artboards: the order its pieces are drawn in at a moment. As they lie, until something is
    /// lifted: then what is higher above the artboard covers what is lower. The artboard's own
    /// sheet is the scene's backdrop and lies under everything, what is sunk below it too, as the
    /// design draws it (`DepthOrder`): so the camera at rest sees what the design shows.
    func filmOrder(_ pieces: [FilmPiece], _ placements: [FilmPlacement]) -> [Int] {
        guard placements.contains(where: { $0.height != 0 }) else { return Array(pieces.indices) }
        // The faces of a body turned as one are as near as they would be laid flat. What is
        // turned is asked about as the design asks: a layer's piece by its face, and a run lying
        // in a turned group that keeps depth by each of its layers, as near as the nearest.
        var heights = placements.map(\.height)
        var faces: [DepthOrder.Face] = [], turned: [Int] = []
        for i in placements.indices {
            if let face = placements[i].face {
                faces.append(face)
                turned.append(i)
            } else if pieces[i].kind == .run, let lying = pieces[i].stand?.lying, !lying.isEmpty {
                faces += lying
                turned += Array(repeating: i, count: lying.count)
            }
        }
        if faces.count > 1 {
            let near = DepthOrder.nearness(faces)
            for (k, i) in turned.enumerated() where k < near.count {
                // A run's first layer says how near it is, and any nearer one after it.
                heights[i] = k > 0 && turned[k - 1] == i ? max(heights[i], near[k]) : near[k]
            }
        }
        return pieces.indices.sorted { a, b in
            let ga = pieces[a].kind == .ground, gb = pieces[b].kind == .ground
            if ga != gb { return ga }
            return heights[a] != heights[b] ? heights[a] < heights[b] : a < b
        }
    }

    /// Artboards: how many times bigger than drawn a piece shows at most in the whole film, so
    /// its drawing can be made sharp enough for all of it. Looked at a few times a second.
    func filmStretch(of piece: FilmPiece, around rect: CGRect) -> Double {
        let length = filmLength
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.midY)]
        var most = 1.0
        // Counted before it is made a whole number: a film of absurd length, as a file could say, has no more steps.
        let steps = Int(max(8, min(96, (length * 8).rounded(.down))))
        let layer = piece.kind == .layer ? piece.layers.first.flatMap { descendant($0) } : nil
        for k in 0...steps {
            let t = length * Double(k) / Double(steps)
            let map = placement(of: piece, layer: layer, at: t, camera: camera(at: t)).map
            for p in corners where map.depth(at: p) > 1e-3 { most = max(most, map.stretch(at: p)) }
        }
        return most
    }
}

// MARK: - A layer as it is at a moment

extension Node {
    /// The layer as it is at a moment, for drawing it: moved, grown, turned and faded as its keys
    /// say, and everything in it likewise. `own` leaves its own pose out, for a piece of the film,
    /// which is placed by it; what it holds is posed all the same.
    func posed(at t: Double, own: Bool = true) -> Node {
        // Its shader's inputs are inside it, and posed with what it holds, own or not; so is
        // its outline, where its points are and how much of it is drawn.
        var n = inputTracks.isEmpty ? self : withInputs(at: t)
        // So is how it looks: its colours, widths, corners and shadows (`looked(at:)`).
        if hasLooks { n = n.looked(at: t) }
        if reshapes { n = n.reshaped(at: t) }
        if !children.isEmpty, holdsMotion { n.children = children.map { $0.posed(at: t) } }
        guard own, isAnimated else { return n }
        let pose = pose(at: t)
        // What it grows and turns about: the design's middle, wherever its outline has gone.
        let pivot = frame.center
        if pose.scale != CGPoint(x: 1, y: 1) {
            let f = n.frame
            var grown = CGRect(x: f.midX - f.width * pose.scale.x / 2, y: f.midY - f.height * pose.scale.y / 2,
                               width: f.width * pose.scale.x, height: f.height * pose.scale.y)
            if reshapes, f.center != pivot {
                // Its middle away from the design's, grown along its own sides with the rest of it.
                let d = Geometry.rotated(f.center, about: pivot, by: -rotation) - pivot
                let middle = Geometry.rotated(CGPoint(x: pivot.x + d.x * pose.scale.x, y: pivot.y + d.y * pose.scale.y), about: pivot, by: rotation)
                grown = CGRect(center: middle, size: grown.size)
            }
            if n.isGroup {
                n.children = BezzleDocument.scaled(n.children, from: f.size, to: grown.size)
                n.mask = n.mask.map { BezzleDocument.scaled($0, from: f.size, to: grown.size) }
            }
            n.frame = grown
        }
        if pose.turn != 0 { n = BezzleDocument.turned(n, by: pose.turn, about: reshapes ? pivot : n.frame.center) }
        n.frame = n.frame.offsetBy(dx: pose.move.x, dy: pose.move.y)
        n.opacity = min(max(n.opacity * pose.fade, 0), 1)
        if pose.inDepth {
            var turn = n.transform3D ?? Transform3D()
            turn.x += pose.tilt
            turn.y += pose.swing
            turn.z += CGFloat(pose.lift)
            n.transform3D = turn
        }
        if pose.blur > 0.05 {
            var blur = n.blur.flatMap { $0.on && !$0.background ? $0 : nil } ?? Blur(radius: 0)
            blur.radius += CGFloat(pose.blur)
            n.blur = blur
        }
        return n
    }
}

// MARK: - What is under the pointer

extension Node {
    /// Artboards: the layers under a point of the film's frame at a moment, the one on top first
    /// and after it what holds it, up to the layer lying on the artboard itself. Empty where only
    /// the artboard shows, or nothing does. `tolerance` is how far off a layer is still found, in
    /// the frame's own points: grown many times, or with the camera close, it reaches no further.
    func filmChain(at point: CGPoint, time t: Double, pieces: [FilmPiece], tolerance: CGFloat) -> [Node] {
        let camera = camera(at: t)
        let placements = zip(pieces, filmLayers(of: pieces)).map { placement(of: $0, layer: $1, at: t, camera: camera) }
        for i in filmOrder(pieces, placements).reversed() where pieces[i].kind != .ground {
            let piece = pieces[i], map = placements[i].map
            guard placements[i].opacity > 0.01, let q = map.back(point) else { continue }
            let inner = CGPoint(x: q.x - piece.origin.x, y: q.y - piece.origin.y)
            // What holds the piece's layers, to look in.
            var holder = Node(kind: .artboard, name: "", frame: .zero)
            let from = piece.holders.last.flatMap { descendant($0) }?.children ?? children
            holder.children = from.filter { piece.layers.contains($0.id) }.map { n in
                // As the piece is drawn: what moves inside it is where its keys have it.
                var n = piece.changes ? n.posed(at: t, own: false) : n
                if piece.flat { n.transform3D = nil }
                return n
            }
            // The reach, in the points of the piece's drawing, which shows this many times bigger here.
            let reach = tolerance / CGFloat(max(map.stretch(at: q), 1e-6))
            let chain = Prototype.chain(at: inner, in: holder, tolerance: reach, eye: Eye.stage(frame.size).inside(piece.origin))
            guard !chain.isEmpty else { continue }
            let above = piece.holders.compactMap { descendant($0) }.reversed()
            // The layers as the design has them, not as they are posed.
            return chain.map { descendant($0.id) ?? $0 } + above
        }
        return []
    }

    /// Artboards: where the four corners of a layer's frame show in the film at a moment: top
    /// left, top right, bottom right, bottom left. Nil for a layer not on it.
    func filmCorners(of id: UUID, at t: Double, pieces: [FilmPiece]) -> [CGPoint]? {
        guard var way = way(to: id) else { return nil }
        let design = way
        let ids = Set(way.map(\.id))
        // The piece the layer is drawn in: its own, or the one of what holds it.
        guard let piece = pieces.last(where: { p in p.layers.contains { ids.contains($0) } }) else { return nil }
        // In a piece drawn again as what it holds moves, a layer it holds is where its own keys
        // have it, and those of what holds it there. The piece's own layer the piece places.
        if piece.changes, let top = way.firstIndex(where: { piece.layers.contains($0.id) }), top < way.count - 1 {
            // Posed along the way down alone: a group poses, grows and turns each thing it holds
            // on its own, so what else it holds does not move the layer, and posing all of that at
            // every step was most of what a picked layer's outline cost. A repeat grid lays out its
            // cells together, and is posed whole.
            var chain = way[way.count - 1]
            if way[top..<(way.count - 1)].contains(where: \.isRepeatGrid) {
                chain = way[top]
            } else {
                for i in stride(from: way.count - 2, through: top, by: -1) {
                    var holder = way[i]
                    holder.children = [chain]
                    chain = holder
                }
            }
            var posed = [chain.posed(at: t, own: false)]
            for next in way[(top + 1)...] {
                guard let child = posed[posed.count - 1].children.first(where: { $0.id == next.id }) else { break }
                posed.append(child)
            }
            if posed.count == way.count - top { way.replaceSubrange(top..., with: posed) }
        }
        guard var layer = way.last else { return nil }
        // Drawn in a piece of its own, its outline is where its keys have it, in a frame grown to hold it.
        if layer.reshapes, piece.layers.first == id { layer = layer.reshaped(at: t) }
        let holders = way.dropLast()
        let origin = holders.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
        // The layer the piece places is on the way down already, as the design has it: not looked
        // for again through the whole artboard.
        let placed = piece.kind == .layer ? design.first { $0.id == piece.layers.first } ?? piece.layers.first.flatMap { descendant($0) } : nil
        let map = placement(of: piece, layer: placed, at: t, camera: camera(at: t)).map
        let flat = piece.flat && piece.layers.first == id
        let frame = layer.frame.offsetBy(dx: origin.x, dy: origin.y)
        let turn = BezzleDocument.turnedBox(of: layer)
        let box = layer.isGroup ? turn.frame.offsetBy(dx: origin.x, dy: origin.y) : frame
        var corners = Geometry.corners(of: box, rotation: turn.rotation)
        // Turned in depth by the design and drawn so: its corners are where that puts them, seen
        // from the artboard's eye.
        if !flat, Perspective.inDepth(layer), let t = layer.transform3D {
            let placed = Perspective(t, frame: frame, eye: Eye.stage(self.frame.size))
            corners = corners.map(placed.shown)
        }
        return corners.map { map($0) }
    }

    /// Artboards: where a layer's own upright points show in the film's frame at a moment: its
    /// frame's top left at zero, before it is turned, as the design has it. Through its place
    /// and turn, its pose and the camera: what its outline's points are shown at and dragged by
    /// in Animate. A point is moved there by the way back (`FilmMap.back`). Nil for a layer not on it.
    func filmPointMap(of id: UUID, at t: Double, pieces: [FilmPiece]) -> FilmMap? {
        guard var way = way(to: id), let design = way.last else { return nil }
        let ids = Set(way.map(\.id))
        guard let piece = pieces.last(where: { p in p.layers.contains { ids.contains($0) } }) else { return nil }
        // Its own points as its parent has them: as the design places it, its pose then being the
        // piece's to place; or, drawn inside a piece that changes as what holds it moves, as it
        // and they are posed in the drawing, its outline left as designed.
        var own = design.placement
        if piece.changes, let top = way.firstIndex(where: { piece.layers.contains($0.id) }), top < way.count - 1 {
            func plain(_ n: Node) -> Node {
                var n = n
                if n.id == id {
                    n[track: .shape] = nil
                    n[track: .draw] = nil
                } else if n.children.contains(where: { ids.contains($0.id) }) {
                    n.children = n.children.map { ids.contains($0.id) ? plain($0) : $0 }
                }
                return n
            }
            var posed = [plain(way[top]).posed(at: t, own: false)]
            for next in way[(top + 1)...] {
                guard let child = posed[posed.count - 1].children.first(where: { $0.id == next.id }) else { break }
                posed.append(child)
            }
            guard posed.count == way.count - top, let layer = posed.last else { return nil }
            way.replaceSubrange(top..., with: posed)
            let grown = CGAffineTransform(scaleX: design.frame.width > 0 ? layer.frame.width / design.frame.width : 1,
                                          y: design.frame.height > 0 ? layer.frame.height / design.frame.height : 1)
            own = grown.concatenating(layer.placement)
        }
        let origin = way.dropLast().reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
        let placed = own.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        let map = placement(of: piece, at: t, camera: camera(at: t)).map
        return map.after(FilmMap(a: Double(placed.a), b: Double(placed.c), c: Double(placed.tx),
                                 d: Double(placed.b), e: Double(placed.d), f: Double(placed.ty)))
    }
}
