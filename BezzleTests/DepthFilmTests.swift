import Testing
import AppKit
@testable import Bezzle

/// Films of groups that keep their layers' depth (`Node.keepsDepth`): at rest the film is the
/// design's own picture, in the order the design draws it, also where layers lying in a turned
/// group are drawn as one piece; and a layer's keys are measured where its place is, in its
/// group, so a Move slides it along the group's plane and a Lift raises it off that plane, and
/// the film shows at every moment what the same change shows made in the design.
@MainActor
struct DepthFilmTests {
    /// A 400 by 300 artboard, seen from 800 points in front of its middle.
    private let size = CGSize(width: 400, height: 300)
    private let paper = RGBA(r: 0.96, g: 0.94, b: 0.9), ink = RGBA(r: 0.17, g: 0.15, b: 0.13)
    private let blue = RGBA(r: 0.18, g: 0.36, b: 0.83), red = RGBA(r: 0.85, g: 0.3, b: 0.22), green = RGBA(r: 0.2, g: 0.6, b: 0.4)
    private let sun = RGBA(r: 0.97, g: 0.72, b: 0.26)

    private func card(_ name: String, _ frame: CGRect, _ color: RGBA, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), radius: CGFloat = 0,
                      kind: Node.Kind = .rectangle) -> Node {
        var n = Node(kind: kind, name: name, frame: frame)
        n.fill.color = color
        n.cornerRadius = radius
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    private func group(_ name: String, _ frame: CGRect, _ children: [Node], z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), keeps: Bool = true) -> Node {
        var g = Node(kind: .group, name: name, frame: frame)
        g.children = children
        if z != 0 || turn.x != 0 || turn.y != 0 { g.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        if keeps { g.keepsDepth = true }
        return g
    }

    private func board(_ children: [Node]) -> Node {
        var b = Node(kind: .artboard, name: "Stage", frame: CGRect(origin: .zero, size: size))
        b.fill.color = ink
        b.children = children
        return b
    }

    /// A group turned and lifted that keeps depth, holding a plate lying in it, a card lying on
    /// that, one standing off it tipped, a disc held over it, and a group tipped again with a
    /// card of its own off its plane: what Windows' truth test found the fault with
    /// (`Windows/VM/DepthTruthTests.swift`, "Resting").
    private func scene(turn: (x: Double, y: Double) = (0, 40), z: CGFloat = 30, keeps: Bool = true, beside: [Node] = []) -> Node {
        var standing = card("Standing", CGRect(x: 20, y: 10, width: 60, height: 40), blue, z: 50, turn: (20, 0), radius: 8)
        standing.border = Border(on: true, color: .white, width: 3, position: .center)
        let inner = group("Inner", CGRect(x: 10, y: 20, width: 100, height: 60),
                          [card("Deep", CGRect(x: 5, y: 5, width: 30, height: 20), sun, z: 15, radius: 4)], z: 10, turn: (25, 0), keeps: keeps)
        return board(beside + [group("Group", CGRect(x: 100, y: 50, width: 200, height: 100), [
            card("Plate", CGRect(x: 0, y: 0, width: 200, height: 100), paper, radius: 12),
            card("Lying", CGRect(x: 100, y: 30, width: 80, height: 50), red, radius: 6),
            standing,
            card("Disc", CGRect(x: 130, y: 6, width: 36, height: 36), green, z: 24, kind: .ellipse),
            inner,
        ], z: z, turn: turn, keeps: keeps)])
    }

    private func layer(_ board: Node, _ name: String) -> Node {
        func find(_ n: Node) -> Node? { n.name == name ? n : n.children.lazy.compactMap(find).first }
        return find(board)!
    }

    // MARK: Worked out by hand

    /// Where a place in the artboard's scene shows, seen from its eye.
    private func seen(_ p: ScenePoint) -> CGPoint {
        let k = 800 / (800 - p.z)
        return CGPoint(x: 200 + (p.x - 200) * k, y: 150 + (p.y - 150) * k)
    }

    /// Where a point of a layer's parent stands in the scene of what holds that parent, the
    /// layer turned about its middle and lifted: one step for each layer.
    private func stood(_ p: ScenePoint, in layer: Node) -> ScenePoint {
        let t = layer.transform3D ?? Transform3D()
        let middle = ScenePoint(x: Double(layer.frame.midX), y: Double(layer.frame.midY))
        return Spin(t)(p - middle) + middle + ScenePoint(z: Double(t.z))
    }

    /// The same for a point given inside a group: in what holds the group.
    private func out(_ p: ScenePoint, of group: Node) -> ScenePoint {
        stood(p + ScenePoint(x: Double(group.frame.minX), y: Double(group.frame.minY)), in: group)
    }

    private func corners(_ n: Node) -> [CGPoint] { Geometry.corners(of: n.frame, rotation: n.rotation) }
    private func flat(_ p: CGPoint) -> ScenePoint { ScenePoint(x: Double(p.x), y: Double(p.y)) }
    private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-5) -> Bool { hypot(a.x - b.x, a.y - b.y) < tolerance }

    /// A layer with the change its keys make at a moment made in the design instead, by hand:
    /// moved in what holds it, and its own turn and height added to.
    private func changed(_ n: Node, at t: Double) -> Node {
        var out = n
        let pose = n.isArtboard ? MotionPose.rest : n.pose(at: t)
        out.motion = nil
        out.children = n.children.map { changed($0, at: t) }
        out.frame = out.frame.offsetBy(dx: pose.move.x, dy: pose.move.y)
        if pose.lift != 0 || pose.tilt != 0 || pose.swing != 0 {
            var turn = out.transform3D ?? Transform3D()
            turn.x += pose.tilt
            turn.y += pose.swing
            turn.z += CGFloat(pose.lift)
            out.transform3D = turn
        }
        return out
    }

    // MARK: Pictures

    /// A picture's pixels, four bytes each with red first, in rows from the top.
    private struct Pixels {
        let width: Int, height: Int
        private let bytes: [UInt8]
        private let row: Int

        init(_ image: CGImage) throws {
            let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(ctx.data)
            width = image.width
            height = image.height
            row = ctx.bytesPerRow
            bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: row * height))
        }

        subscript(x: Int, y: Int) -> [Int] {
            let at = y * row + x * 4
            return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
        }

        func shows(_ color: RGBA, at p: CGPoint, scale: CGFloat = 2, within tolerance: Int = 8) -> Bool {
            let want = [color.r, color.g, color.b].map { Int(($0 * 255).rounded()) }
            return zip(self[Int(p.x * scale), Int(p.y * scale)], want).allSatisfy { abs($0 - $1) <= tolerance }
        }

        /// How far apart two pictures are, of 255: on average, and in the block of eight by
        /// eight pixels where they differ most, on average there. A film lays each piece down
        /// through the camera, which leaves an edge a little softer or a part of a pixel aside
        /// than the design draws it: single pixels far apart along edges, and every block nearly
        /// alike. A layer missing, under another or lying elsewhere is whole blocks far apart.
        func distance(to other: Pixels) -> (mean: Double, block: Double) {
            var sum = 0, worst = 0
            for by in stride(from: 0, to: min(height, other.height), by: 8) {
                for bx in stride(from: 0, to: min(width, other.width), by: 8) {
                    var block = 0
                    for y in by..<min(by + 8, height, other.height) {
                        for x in bx..<min(bx + 8, width, other.width) {
                            for (a, b) in zip(self[x, y], other[x, y]) { block += abs(a - b) }
                        }
                    }
                    sum += block
                    worst = max(worst, block)
                }
            }
            return (Double(sum) / Double(max(1, width * height * 3)), Double(worst) / 192)
        }
    }

    private func film(_ board: Node, at t: Double) throws -> Pixels {
        try Pixels(#require(FilmExport.frame(of: board, at: t, size: CGSize(width: size.width * 2, height: size.height * 2), assets: nil)))
    }

    private func design(_ board: Node) throws -> Pixels {
        try Pixels(#require(Renderer.image(of: board, scale: 2)))
    }

    /// The layers in the order a film draws them at a moment, a run's as they lie in it.
    private func filmed(_ board: Node, at t: Double = 0) -> [String] {
        let pieces = board.filmPieces()
        let placements = pieces.map { board.placement(of: $0, at: t, camera: board.camera(at: t)) }
        return board.filmOrder(pieces, placements).flatMap { i in pieces[i].layers.compactMap { board.descendant($0)?.name } }
    }

    /// The layers in the order the design draws them.
    private func drawn(_ board: Node) -> [String] {
        DepthOrder.scene(board.children, eye: Eye.stage(board.frame.size)).map(\.node.name)
    }

    // MARK: At rest

    @Test func aFilmAtRestOrdersWhatLiesInATurnedGroupAsTheDesignDoes() throws {
        let stage = scene()
        // The plate and the card on it are one piece of the film, lying in the group's plane.
        let pieces = stage.filmPieces()
        #expect(pieces.map { $0.layers.compactMap { stage.descendant($0)?.name } } == [[], ["Plate", "Lying"], ["Standing"], ["Disc"], ["Deep"]])
        #expect(pieces[1].kind == .run && pieces[1].stand?.lying.count == 2)
        // The design draws the card of the group inside, facing another way, over the plate it
        // stands in front of, though the plate's near corner stands higher than that card's middle.
        #expect(drawn(stage) == ["Plate", "Lying", "Disc", "Deep", "Standing"])
        #expect(filmed(stage) == drawn(stage))
        // As near as the design has them: the plate's middle 30 up, its near corner 94.
        let placements = pieces.map { stage.placement(of: $0, at: 0, camera: .rest) }
        #expect(abs(placements[1].height - 30) < 1e-9, "\(placements[1].height)")
        #expect(abs((pieces[1].stand?.height ?? 0) - (30 + 100 * sin(40 * Double.pi / 180))) < 1e-9)
        // However the group is turned and wherever it is held, and with layers beside it: one
        // lying in the page under it, one held up in front, one leaning.
        let beside = [card("Under", CGRect(x: 60, y: 40, width: 120, height: 90), blue),
                      card("Front", CGRect(x: 230, y: 90, width: 90, height: 80), green, z: 70),
                      card("Leaning", CGRect(x: 150, y: 120, width: 120, height: 60), sun, z: 20, turn: (35, -15))]
        let turns: [(x: Double, y: Double, z: CGFloat)] = [(0, 40, 30), (0, -40, 30), (30, 0, 0), (-25, 35, -20), (20, 20, 60), (0, 140, 30), (0, 0, 30), (0, 0, 0), (60, -50, 10)]
        for turn in turns {
            for others in [[], beside] {
                let stage = scene(turn: (turn.x, turn.y), z: turn.z, beside: others)
                #expect(filmed(stage) == drawn(stage), "\(turn), \(others.count) beside: \(filmed(stage)) for \(drawn(stage))")
            }
        }
        // A group as one card is one piece, as it was, with nothing asked about what lies in it.
        let asCard = scene(keeps: false)
        #expect(asCard.filmPieces().count == 2 && asCard.filmPieces()[1].stand == nil)
        // A run is one piece, as near as the nearest of its layers, and they in it as they lie:
        // a title in the middle of a plate, its middle exactly as high as the plate's, stays on
        // the plate where a badge is held over the plate's higher end.
        let badged = board([group("Group", CGRect(x: 100, y: 50, width: 200, height: 100), [
            card("Plate", CGRect(x: 0, y: 0, width: 200, height: 100), paper),
            card("Title", CGRect(x: 80, y: 44, width: 40, height: 12), ink),
            card("Badge", CGRect(x: 170, y: 4, width: 26, height: 26), red, z: 12),
        ], z: 30, turn: (0, -40))])
        #expect(filmed(badged) == ["Plate", "Title", "Badge"])
    }

    @Test func aFilmAtRestIsTheDesignsPictureOfATurnedGroupThatKeepsDepth() throws {
        let stage = scene()
        let g = layer(stage, "Group"), inner = layer(stage, "Inner"), deep = layer(stage, "Deep")
        let frame = try film(stage, at: 0), picture = try design(stage)
        #expect(frame.width == picture.width && frame.height == picture.height)
        // The card of the group inside shows, over the plate, where the design shows it.
        let middle = seen(out(out(stood(flat(deep.frame.center), in: deep), of: inner), of: g))
        #expect(picture.shows(sun, at: middle) && frame.shows(sun, at: middle), "\(frame[Int(middle.x * 2), Int(middle.y * 2)])")
        let apart = frame.distance(to: picture)
        #expect(apart.mean < 0.25 && apart.block < 24, "\(apart)")
        // So it is with layers beside the group, and turned another way.
        let beside = [card("Under", CGRect(x: 60, y: 40, width: 120, height: 90), blue),
                      card("Front", CGRect(x: 230, y: 90, width: 90, height: 80), green, z: 70)]
        for turn in [(x: -25.0, y: 35.0), (x: 30.0, y: -20.0)] {
            let other = scene(turn: turn, z: 20, beside: beside)
            let apart = try film(other, at: 0).distance(to: design(other))
            #expect(apart.mean < 0.25 && apart.block < 24, "\(turn): \(apart)")
        }
    }

    // MARK: Keys

    /// The scene filmed: the card lying on the plate slides, the standing one rises, the disc is
    /// tipped and swung, and the card in the group inside slides and rises there, all in a second.
    private func keyed(keeps: Bool = true) -> Node {
        var stage = scene(keeps: keeps)
        func key(_ name: String, _ property: MotionProperty, _ value: [Double]) {
            func set(_ n: inout Node) {
                if n.name == name {
                    n.setKey(property, property.rest, at: 0, ease: .linear)
                    n.setKey(property, value, at: 1, ease: .linear)
                }
                for i in n.children.indices { set(&n.children[i]) }
            }
            set(&stage)
        }
        key("Lying", .move, [-30, 10])
        key("Standing", .lift, [45])
        key("Standing", .move, [12, 6])
        key("Disc", .tilt, [-20])
        key("Disc", .swing, [30])
        key("Deep", .move, [10, -4])
        key("Deep", .lift, [12])
        stage.film = Film(length: 2, once: true, backdrop: nil)
        return stage
    }

    @Test func aKeyedMoveSlidesInTheGroupsPlaneAndALiftRisesFromIt() throws {
        let stage = keyed()
        let pieces = stage.filmPieces()
        func piece(_ name: String) throws -> Int { try #require(pieces.firstIndex { $0.layers == [layer(stage, name).id] }) }
        // Seen straight on, and by a camera that has gone aside: two looks tell where a thing stands.
        var aside = FilmCamera()
        aside.x = 15
        aside.zoom = 1.2
        aside.swing = 22
        aside.tilt = 18
        for t in [0, 0.5, 1, 1.6] {
            let now = changed(stage, at: t)
            let g = layer(now, "Group"), inner = layer(now, "Inner")
            for camera in [FilmCamera.rest, aside] {
                let placements = pieces.map { stage.placement(of: $0, at: t, camera: camera) }
                /// Where the film shows a point of a layer's drawing, which is made as the design has the layer at rest.
                func shown(_ name: String, _ p: CGPoint) throws -> CGPoint { try placements[piece(name)].map(p + pieces[piece(name)].origin) }
                /// Where the camera shows a place in the scene: where a sheet lying level that high shows it.
                func sight(_ p: ScenePoint) -> CGPoint {
                    let there = FilmLens.ground(camera, size: size, height: p.z)(CGPoint(x: p.x, y: p.y))
                    if camera.isRest { #expect(near(there, seen(p))) }
                    return there
                }
                // Each where the same change stands it in the design: worked out by hand, a step for each layer.
                for name in ["Lying", "Standing", "Disc"] {
                    let rest = layer(stage, name), posed = layer(now, name)
                    for (p, q) in zip(corners(rest), corners(posed)) {
                        #expect(try near(shown(name, p), sight(out(stood(flat(q), in: posed), of: g))), "\(name) at \(t)")
                    }
                }
                let rest = layer(stage, "Deep"), posed = layer(now, "Deep")
                for (p, q) in zip(corners(rest), corners(posed)) {
                    #expect(try near(shown("Deep", p), sight(out(out(stood(flat(q), in: posed), of: inner), of: g))), "Deep at \(t)")
                }
            }
        }
        // Moved, the card that lay on the plate still lies on it: in the group's plane, 30 and 10
        // along it from where it lay, and not 30 and 10 across the page, through the plate.
        let g = layer(stage, "Group"), lying = layer(stage, "Lying")
        let placements = pieces.map { stage.placement(of: $0, at: 1, camera: .rest) }
        let at = try piece("Lying")
        for p in corners(lying) {
            let slid = out(flat(p) + ScenePoint(x: -30, y: 10), of: g)
            #expect(near(placements[at].map(p + pieces[at].origin), seen(slid)))
            let across = out(flat(p), of: g) + ScenePoint(x: -30, y: 10)
            #expect(!near(seen(slid), seen(across), 1))
        }
        // As high as the plate's own plane is there, so it is ordered as lying on it: over it, as listed.
        let plane = Spin(g.transform3D!).facing
        let middle = out(flat(lying.frame.center) + ScenePoint(x: -30, y: 10), of: g), plate = out(flat(layer(stage, "Plate").frame.center), of: g)
        #expect(abs(placements[at].height - middle.z) < 1e-9)
        #expect(abs((middle.x - plate.x) * plane.x + (middle.y - plate.y) * plane.y + (middle.z - plate.z) * plane.z) < 1e-9)
        let order = filmed(stage, at: 1)
        #expect(try #require(order.firstIndex(of: "Lying")) > #require(order.firstIndex(of: "Plate")), "\(order)")
        // A lift goes along the way the group faces, 45 from where it stood, and the move with it along the plane.
        let standing = layer(stage, "Standing"), up = try piece("Standing")
        let raised = out(flat(standing.frame.center) + ScenePoint(x: 12, y: 6, z: 50 + 45), of: g)
        let before = out(flat(standing.frame.center) + ScenePoint(z: 50), of: g)
        #expect(near(placements[up].map(standing.frame.center + pieces[up].origin), seen(raised)))
        let along = Spin(g.transform3D!)(ScenePoint(x: 12, y: 6, z: 45))
        #expect(abs(raised.x - before.x - along.x) < 1e-9 && abs(raised.y - before.y - along.y) < 1e-9 && abs(raised.z - before.z - along.z) < 1e-9)
        #expect(abs(placements[up].height - raised.z) < 1e-9)
    }

    @Test func atEveryMomentTheFilmShowsWhatTheSameChangeShowsInTheDesign() throws {
        let stage = keyed()
        for t in [0.5, 1] {
            // The order the design draws the changed layers in, and its picture.
            let now = changed(stage, at: t)
            #expect(filmed(stage, at: t) == drawn(now), "\(t): \(filmed(stage, at: t)) for \(drawn(now))")
            let apart = try film(stage, at: t).distance(to: design(now))
            #expect(apart.mean < 0.25 && apart.block < 24, "\(t): \(apart)")
            // Under a camera that has moved, each piece is where the changed design's film has it.
            var camera = FilmCamera()
            camera.swing = 22
            camera.tilt = 18
            camera.zoom = 1.2
            let pieces = stage.filmPieces(), there = now.filmPieces(loose: Set(pieces.filter { $0.kind == .layer }.flatMap(\.layers)))
            #expect(pieces.map(\.layers) == there.map(\.layers))
            for (piece, other) in zip(pieces, there) where piece.kind == .layer {
                let rest = try #require(stage.descendant(piece.layers[0])), posed = try #require(now.descendant(piece.layers[0]))
                let a = stage.placement(of: piece, at: t, camera: camera).map, b = now.placement(of: other, at: 0, camera: camera).map
                for (p, q) in zip(corners(rest), corners(posed)) {
                    #expect(near(a(p + piece.origin), b(q + other.origin), 1e-4), "\(rest.name) at \(t)")
                }
            }
        }
        // With the group as one card the card lying on it slides on the card: the same place.
        let asCard = keyed(keeps: false), lying = layer(stage, "Lying").id
        let kept = try #require(stage.filmCorners(of: lying, at: 1, pieces: stage.filmPieces()))
        let onCard = try #require(asCard.filmCorners(of: layer(asCard, "Lying").id, at: 1, pieces: asCard.filmPieces()))
        for (a, b) in zip(kept, onCard) { #expect(near(a, b, 1e-4)) }
    }
}
