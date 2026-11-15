import Testing
import AppKit
@testable import Bezzle

/// Animate on the canvas in depth: a layer dragged in a group turned in depth stays under the
/// pointer. The bench is in `AnimateCanvasTests.swift`.
extension AnimateCanvasTests {
    /// A group on the artboard's right, swung in depth, keeping its layers' depth or drawn as
    /// one card, with a tile and a chip lifted off it; fitted round them, as the design keeps it.
    static func swung(_ degrees: Double, keeps: Bool) -> Node {
        var plate = Node(kind: .group, name: "Plate", frame: CGRect(x: 200, y: 80, width: 130, height: 90))
        var chip = CanvasTests.rect("Chip", CGRect(x: 90, y: 60, width: 40, height: 30))
        chip.transform3D = Transform3D(x: 0, y: 0, z: 20)
        plate.children = [CanvasTests.rect("Tile", CGRect(x: 0, y: 0, width: 70, height: 50)), chip]
        plate.transform3D = Transform3D(x: 0, y: degrees, z: 0)
        if keeps { plate.keepsDepth = true }
        return BezzleDocument.fitted(plate)
    }

    /// The camera tipped back and swung a little, for the whole film.
    func tiltCamera(_ f: FilmBench, tilt: Double = 20, swing: Double = -10) {
        let board = f.board.id
        f.edit { doc in doc.update(board) { $0.setKey(.cameraTilt, [tilt], at: 0); $0.setKey(.cameraSwing, [swing], at: 0) } }
        f.fresh()
    }

    /// Where a layer's middle shows: where the diagonals of its corners cross.
    func centre(_ f: FilmBench, _ name: String) -> CGPoint { Geometry.crossing(f.corners(name)) }

    // MARK: Dragging inside a turned group

    @Test(arguments: [40.0, 70.0], [false, true])
    func aLayerDraggedInATurnedGroupStaysUnderThePointer(_ degrees: Double, _ keeps: Bool) {
        let f = FilmBench([FilmBench.cardAndBadge[0], Self.swung(degrees, keeps: keeps)])
        tiltCamera(f)
        let design = f.design
        for name in ["Tile", "Chip"] {
            f.store.selection = [f.id(name)]
            f.store.seek(1)
            let from = centre(f, name)
            for to in [from + point(50, 30), from + point(-40, 25)] {
                let at = centre(f, name)
                // With Command, so that home does not catch it along a line it comes near.
                f.drag(at, to, pulling: .command)
                f.store.pauseFilm()
                // Its middle shows where the pointer was let go, within a point, though the group's
                // plane runs away from the eye.
                #expect(hypot(centre(f, name).x - to.x, centre(f, name).y - to.y) <= 1, "\(name), \(degrees)°, keeping \(keeps): \(centre(f, name)) for \(to)")
            }
            #expect(f.node(name).motionProperties == [.move])
        }
        #expect(f.node("Plate").motion == nil)
        #expect(f.design == design)
    }

    @Test(arguments: [false, true])
    func takenHoldOfOffItsMiddleThatPointStaysUnderThePointer(_ keeps: Bool) throws {
        let f = FilmBench([Self.swung(70, keeps: keeps)])
        tiltCamera(f)
        let tile = f.id("Tile")
        f.store.selection = [tile]
        f.store.seek(1)
        // Near its top left corner, on it: the point of the tile there, in its own points.
        let q = f.corners("Tile"), c = centre(f, "Tile")
        let at = FilmBench.scaled(q[0], from: c, 0.6)
        func own() throws -> FilmMap { try #require(f.board.filmPointMap(of: tile, at: 1, pieces: f.scene.pieces)) }
        let held = try #require(own().back(f.scene.toFrame(at)))
        let to = at + point(45, 35)
        f.drag(at, to, pulling: .command)
        f.store.pauseFilm()
        let now = f.scene.toView(try own()(held))
        #expect(hypot(now.x - to.x, now.y - to.y) <= 1, "\(now) for \(to)")
    }

    @Test(arguments: [40.0, 70.0], [false, true])
    func aBeadDraggedInATurnedGroupTakesItsKeyUnderThePointer(_ degrees: Double, _ keeps: Bool) {
        let f = FilmBench([Self.swung(degrees, keeps: keeps)])
        tiltCamera(f)
        let tile = f.id("Tile")
        f.edit { doc in doc.update(tile) { $0.setKey(.move, [0, 0], at: 0); $0.setKey(.move, [30, 10], at: 1) } }
        f.store.selection = [tile]
        f.store.seek(0)
        f.fresh()
        // The bead at the end of its way, where the tile's middle shows a second in.
        f.store.seek(1)
        let bead = f.middle("Tile"), there = centre(f, "Tile")
        f.store.seek(0)
        f.drag(bead, bead + point(35, -20))
        #expect(f.store.filmTime == 1)
        #expect(f.keys("Tile", .move).map(\.t) == [0, 1])
        let now = centre(f, "Tile")
        #expect(hypot(now.x - there.x - 35, now.y - there.y + 20) <= 1, "\(now) for \(there + point(35, -20))")
    }

    @Test func aLayerTheDesignLiftsIsDraggedAsHighAsItStands() {
        var lifted = CanvasTests.rect("Lifted", CGRect(x: 60, y: 150, width: 90, height: 60))
        lifted.transform3D = Transform3D(x: 0, y: 0, z: 150)
        let f = FilmBench([lifted])
        tiltCamera(f, tilt: 30, swing: 15)
        f.store.selection = [f.id("Lifted")]
        f.store.seek(1)
        let from = centre(f, "Lifted"), to = from + point(60, -35)
        f.drag(from, to)
        f.store.pauseFilm()
        #expect(hypot(centre(f, "Lifted").x - to.x, centre(f, "Lifted").y - to.y) <= 1, "\(centre(f, "Lifted")) for \(to)")
    }
}
