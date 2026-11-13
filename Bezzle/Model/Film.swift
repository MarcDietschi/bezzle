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
    /// one whose drawing was made lying flat, which the film then turns in its own space.
    static func layer(center: CGPoint, rotation: Double, depth: Transform3D? = nil, pose: MotionPose, camera: FilmCamera, size: CGSize) -> FilmMap {
        let c = V(x: Double(center.x), y: Double(center.y))
        // A point of the drawing, measured from the layer's middle, grown along its own sides.
        func own(_ p: V) -> V {
            var q = turn(p, -rotation)
            q = V(x: q.x * Double(pose.scale.x), y: q.y * Double(pose.scale.y), z: q.z)
            q = turn(q, rotation + pose.turn)
            q = swing(q, pose.swing + (depth?.y ?? 0))
            return tilt(q, pose.tilt + (depth?.x ?? 0))
        }
        let place = V(x: c.x + Double(pose.move.x), y: c.y + Double(pose.move.y), z: pose.lift + Double(depth?.z ?? 0))
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

    var key: String { ([kind.rawValue] + layers.map(\.uuidString)).joined(separator: "/") + (flat ? "/flat" : "") }
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
        func walk(_ nodes: [Node], origin: CGPoint, holders: [UUID]) {
            var run: [UUID] = []
            func flush() {
                if !run.isEmpty { out.append(FilmPiece(kind: .run, layers: run, origin: origin, holders: holders)) }
                run = []
            }
            for n in nodes where !n.hidden {
                // A shader that moves is drawn again at every moment, as a layer whose insides move.
                let own = n.isAnimated || loose.contains(n.id) || n.shaderMoves
                let inside = n.holdsMotion || holdsLoose(n) || n.children.contains(where: \.holdsMovingShader)
                // Held up off the artboard by the design, it stands in the scene where the design
                // has it, so the camera sees how high it is: drawn flat, for the film to turn and
                // lift in its own space, which sees it from where the design does (`Eye.stage`).
                // A screen pinned into a photo keeps the look it has.
                let deep = Perspective.inDepth(n) && n.transform3D?.pinned != true
                if own || deep {
                    flush()
                    out.append(FilmPiece(kind: .layer, layers: [n.id], origin: origin, holders: holders, changes: n.holdsMotion || n.holdsMovingShader, flat: deep))
                } else if inside, n.comesApart {
                    flush()
                    walk(n.children, origin: CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY), holders: holders + [n.id])
                } else if inside {
                    // Masked, faded or the like as a whole: drawn again as what it holds moves.
                    flush()
                    out.append(FilmPiece(kind: .layer, layers: [n.id], origin: origin, holders: holders, changes: n.holdsMotion || n.holdsMovingShader))
                } else {
                    run.append(n.id)
                }
            }
            flush()
        }
        walk(children, origin: .zero, holders: [])
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
}

nonisolated extension Node {
    /// Artboards: where a piece shows at a moment, through this camera.
    func placement(of piece: FilmPiece, at t: Double, camera: FilmCamera) -> FilmPlacement {
        guard piece.kind == .layer, let id = piece.layers.first, let layer = descendant(id) else {
            return FilmPlacement(map: FilmLens.ground(camera, size: frame.size))
        }
        let pose = layer.pose(at: t)
        let center = CGPoint(x: piece.origin.x + layer.frame.midX, y: piece.origin.y + layer.frame.midY)
        let depth = piece.flat ? layer.transform3D : nil
        let map = FilmLens.layer(center: center, rotation: layer.isGroup ? 0 : layer.rotation, depth: depth, pose: pose, camera: camera, size: frame.size)
        return FilmPlacement(map: map, opacity: pose.fade, blur: pose.blur, height: pose.lift + Double(depth?.z ?? 0))
    }

    /// Artboards: the order its pieces are drawn in at a moment. As they lie, until something is
    /// lifted: then what is higher above the artboard covers what is lower. The artboard's own
    /// sheet is the scene's backdrop and lies under everything, what is sunk below it too, as the
    /// design draws it (`DepthOrder`): so the camera at rest sees what the design shows.
    func filmOrder(_ pieces: [FilmPiece], _ placements: [FilmPlacement]) -> [Int] {
        guard placements.contains(where: { $0.height != 0 }) else { return Array(pieces.indices) }
        return pieces.indices.sorted { a, b in
            let ga = pieces[a].kind == .ground, gb = pieces[b].kind == .ground
            if ga != gb { return ga }
            return placements[a].height != placements[b].height ? placements[a].height < placements[b].height : a < b
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
        for k in 0...steps {
            let t = length * Double(k) / Double(steps)
            let map = placement(of: piece, at: t, camera: camera(at: t)).map
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
        // Its shader's inputs are inside it, and posed with what it holds, own or not.
        var n = inputTracks.isEmpty ? self : withInputs(at: t)
        if !children.isEmpty, holdsMotion { n.children = children.map { $0.posed(at: t) } }
        guard own, isAnimated else { return n }
        let pose = pose(at: t)
        if pose.scale != CGPoint(x: 1, y: 1) {
            let f = n.frame
            let grown = CGRect(x: f.midX - f.width * pose.scale.x / 2, y: f.midY - f.height * pose.scale.y / 2,
                               width: f.width * pose.scale.x, height: f.height * pose.scale.y)
            if n.isGroup {
                n.children = BezzleDocument.scaled(n.children, from: f.size, to: grown.size)
                n.mask = n.mask.map { BezzleDocument.scaled($0, from: f.size, to: grown.size) }
            }
            n.frame = grown
        }
        if pose.turn != 0 { n = BezzleDocument.turned(n, by: pose.turn, about: n.frame.center) }
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
        let placements = pieces.map { placement(of: $0, at: t, camera: camera) }
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
        let ids = Set(way.map(\.id))
        // The piece the layer is drawn in: its own, or the one of what holds it.
        guard let piece = pieces.last(where: { p in p.layers.contains { ids.contains($0) } }) else { return nil }
        // In a piece drawn again as what it holds moves, a layer it holds is where its own keys
        // have it, and those of what holds it there. The piece's own layer the piece places.
        if piece.changes, let top = way.firstIndex(where: { piece.layers.contains($0.id) }), top < way.count - 1 {
            var posed = [way[top].posed(at: t, own: false)]
            for next in way[(top + 1)...] {
                guard let child = posed[posed.count - 1].children.first(where: { $0.id == next.id }) else { break }
                posed.append(child)
            }
            if posed.count == way.count - top { way.replaceSubrange(top..., with: posed) }
        }
        guard let layer = way.last else { return nil }
        let holders = way.dropLast()
        let origin = holders.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
        let map = placement(of: piece, at: t, camera: camera(at: t)).map
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
}
