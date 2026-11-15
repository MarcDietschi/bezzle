import Testing
import Foundation
import CoreGraphics
@testable import Bezzle

/// The plane a Move slides a layer along, as the film shows it (`Node.filmMovePlane`): for every
/// Move the plane says, the layer posed with that Move shows its middle there, however the group
/// it lies in is turned and whether it keeps its layers' depth or is drawn as one card, under a
/// camera that is tilted itself. So a drag cast onto the plane keeps the layer under the pointer.
@MainActor
struct FilmMovePlaneTests {
    private let at = 1.0

    private func card(_ name: String, _ frame: CGRect, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0)) -> Node {
        var n = Node(kind: .rectangle, name: name, frame: frame)
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    /// A 400 by 300 artboard at a place of its own on the canvas.
    private func board(_ children: [Node], camera: FilmCamera = .rest) -> Node {
        var b = Node(kind: .artboard, name: "A", frame: CGRect(x: 700, y: 50, width: 400, height: 300))
        b.children = children
        for p in MotionProperty.view where camera[p] != p.rest { b.setKey(p, camera[p], at: 0) }
        return b
    }

    /// A group across the artboard's middle swung `swing` degrees, keeping its layers' depth or
    /// one card, holding a card lying in it, one lifted off it and one tipped in it.
    private func group(swing: Double, keeps: Bool, z: CGFloat = 0) -> Node {
        var g = Node(kind: .group, name: "Group", frame: CGRect(x: 100, y: 60, width: 200, height: 160))
        g.children = [card("Card", CGRect(x: 20, y: 30, width: 60, height: 40)),
                      card("Chip", CGRect(x: 120, y: 20, width: 40, height: 30), z: 25),
                      card("Leaf", CGRect(x: 110, y: 100, width: 50, height: 40), turn: (30, 0))]
        g.transform3D = Transform3D(x: 0, y: swing, z: z)
        if keeps { g.keepsDepth = true }
        return g
    }

    /// Tilted back, swung and rolled a little, and nearer.
    private var tilted: FilmCamera {
        var c = FilmCamera()
        c.tilt = 25
        c.swing = -12
        c.roll = 4
        c.zoom = 1.3
        c.x = 10
        c.y = -6
        return c
    }

    private func id(_ board: Node, _ name: String) -> UUID {
        func find(_ n: Node) -> Node? { n.name == name ? n : n.children.lazy.compactMap(find).first }
        return find(board)!.id
    }

    /// Where a layer's middle shows with a Move keyed at the moment, worked out apart from the
    /// plane: the film made again with the key, and where its corners' diagonals cross.
    private func middle(_ board: Node, _ id: UUID, moved move: CGPoint) -> CGPoint? {
        var b = board
        func key(_ n: inout Node) {
            if n.id == id { n.setKey(.move, [Double(move.x), Double(move.y)], at: at); return }
            for i in n.children.indices { key(&n.children[i]) }
        }
        key(&b)
        let pieces = b.filmPieces(loose: [id])
        return b.filmCorners(of: id, at: at, pieces: pieces).map(Geometry.crossing)
    }

    private func near(_ a: CGPoint?, _ b: CGPoint?, _ e: CGFloat = 1e-5) -> Bool {
        guard let a, let b else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= e
    }

    @Test(arguments: [40.0, 70.0, -55.0], [false, true])
    func everyMoveOfALayerInATurnedGroupShowsWhereThePlaneSays(_ swing: Double, _ keeps: Bool) throws {
        for camera in [FilmCamera.rest, tilted] {
            let b = board([group(swing: swing, keeps: keeps, z: 20)], camera: camera)
            for name in ["Card", "Chip", "Leaf"] {
                let layer = id(b, name)
                let plane = try #require(b.filmMovePlane(of: layer, at: at, pieces: b.filmPieces(loose: [layer])))
                for move in [CGPoint.zero, CGPoint(x: 30, y: 0), CGPoint(x: -45, y: 25), CGPoint(x: 120, y: -80), CGPoint(x: 7.5, y: 210)] {
                    #expect(near(plane(move), middle(b, layer, moved: move)), "\(name) swung \(swing), keeping \(keeps), moved \(move)")
                }
            }
        }
    }

    @Test(arguments: [40.0, 70.0], [false, true])
    func aDragCastOntoThePlaneEndsWithTheMiddleUnderThePointer(_ swing: Double, _ keeps: Bool) throws {
        var b = board([group(swing: swing, keeps: keeps)], camera: tilted)
        let layer = id(b, "Card")
        // Moved once already, at this moment.
        func key(_ n: inout Node) {
            if n.id == layer { n.setKey(.move, [10, -5], at: at); return }
            for i in n.children.indices { key(&n.children[i]) }
        }
        key(&b)
        let pieces = b.filmPieces(loose: [layer])
        let plane = try #require(b.filmMovePlane(of: layer, at: at, pieces: pieces))
        let from = try #require(middle(b, layer, moved: CGPoint(x: 10, y: -5)))
        #expect(near(plane(CGPoint(x: 10, y: -5)), from))
        for to in [CGPoint(x: from.x + 60, y: from.y + 20), CGPoint(x: from.x - 35, y: from.y + 50), CGPoint(x: 40, y: 260)] {
            let d = try #require(plane.travel(from: from, to: to))
            #expect(near(middle(b, layer, moved: CGPoint(x: 10 + d.x, y: -5 + d.y)), to), "to \(to)")
        }
        // Further than the same drag across the sheet: the group's plane runs away from the eye.
        let sideways = CGPoint(x: from.x + 60, y: from.y)
        let across = try #require(plane.travel(from: from, to: sideways))
        let sheet = try #require(FilmLens.ground(tilted, size: b.frame.size).travel(from: from, to: sideways))
        #expect(hypot(across.x, across.y) > hypot(sheet.x, sheet.y) * 1.05)
    }

    @Test func aLayerLiftedByTheDesignMovesInItsOwnHeightAboveTheSheet() throws {
        let b = board([card("Card", CGRect(x: 60, y: 50, width: 80, height: 60), z: 120)], camera: tilted)
        let layer = id(b, "Card")
        let plane = try #require(b.filmMovePlane(of: layer, at: at, pieces: b.filmPieces(loose: [layer])))
        let from = try #require(middle(b, layer, moved: .zero))
        let to = CGPoint(x: from.x + 80, y: from.y + 40)
        let d = try #require(plane.travel(from: from, to: to))
        #expect(near(middle(b, layer, moved: d), to))
        // The sheet itself would have moved it further: what stands nearer shows larger.
        let ground = FilmLens.ground(tilted, size: b.frame.size)
        let flat = try #require(ground.travel(from: from, to: to))
        #expect(hypot(flat.x, flat.y) > hypot(d.x, d.y) * 1.05)
    }

    @Test func aLayerLyingInARunIsKeptApartToBeTried() throws {
        let b = board([card("Card", CGRect(x: 60, y: 50, width: 80, height: 60)), card("Other", CGRect(x: 200, y: 50, width: 80, height: 60))],
                      camera: tilted)
        let layer = id(b, "Card")
        // Nothing kept apart: the card is drawn in the run of layers that stand still.
        let pieces = b.filmPieces()
        #expect(pieces.contains { $0.kind == .run && $0.layers.contains(layer) })
        let plane = try #require(b.filmMovePlane(of: layer, at: at, pieces: pieces))
        #expect(near(plane(CGPoint(x: 50, y: 20)), middle(b, layer, moved: CGPoint(x: 50, y: 20))))
    }

    @Test func aPlaneSeenEdgeOnHasNone() {
        let b = board([group(swing: 90, keeps: true)])
        let layer = id(b, "Card")
        #expect(b.filmMovePlane(of: layer, at: at, pieces: b.filmPieces(loose: [layer])) == nil)
        #expect(b.filmMovePlane(of: UUID(), at: at, pieces: b.filmPieces()) == nil)
    }

    @Test func theSquareGoesToItsFourPointsAndThreeInALineHaveNone() throws {
        let q = [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 30), CGPoint(x: 90, y: 140), CGPoint(x: 0, y: 100)]
        let map = try #require(FilmMap.square(to: q))
        for (p, to) in zip([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], q) {
            #expect(near(map(p), to, 1e-9))
        }
        #expect(near(map(CGPoint(x: 0.5, y: 0.5)), Geometry.crossing(q), 1e-9))
        #expect(FilmMap.square(to: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 5)]) == nil)
        // A line's corners have no crossing: its middle stands in.
        #expect(Geometry.crossing([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 0)]) == CGPoint(x: 5, y: 0))
    }
}
