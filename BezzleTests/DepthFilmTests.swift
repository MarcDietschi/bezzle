import Testing
import AppKit
@testable import Bezzle

/// Films of groups that keep their layers' depth (`Node.keepsDepth`): at rest the film is the
/// design's own picture, in the order the design draws it, also where layers lying in a turned
/// group are drawn as one piece.
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
}
