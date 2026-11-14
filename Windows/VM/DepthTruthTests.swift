import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The Mac's own pictures of designs in depth, for Bezzle for Windows to be compared with
/// (Windows/VM/depth-agreement.sh): groups that keep their layers' depth beside the same groups
/// as one card, a body of several layers turned as one, artboards looked at from the side as
/// the Mac's canvas draws them (`Renderer.tile` with `Options.looks`) beside the same from the
/// front, and films of them (`FilmExport.frame`). The designs are made here, without text, and
/// written as the Mac writes a design; Windows draws the same files with `bezzle-render`.
///
/// Like the truth tests in Web/tools, this is copied into `BezzleTests/` to be run, with
/// `TEST_RUNNER_DEPTH_TRUTH_OUT=<dir>`; without it nothing is made.
@MainActor
struct DepthTruthTests {
    private static let size = CGSize(width: 400, height: 300)
    private static let paper = RGBA(r: 0.96, g: 0.94, b: 0.9), ink = RGBA(r: 0.17, g: 0.15, b: 0.13)
    private static let blue = RGBA(r: 0.18, g: 0.36, b: 0.83), red = RGBA(r: 0.85, g: 0.3, b: 0.22), green = RGBA(r: 0.2, g: 0.6, b: 0.4)
    private static let sun = RGBA(r: 0.97, g: 0.72, b: 0.26)

    /// From where the artboards are looked at, beside the front: as the folders are named.
    static let looks: [(name: String, look: DepthLook)] = [("side-45_0", DepthLook(across: -45)), ("side30_40", DepthLook(across: 30, down: 40))]
    /// The moments each film is drawn at.
    static let moments: [Double] = [0, 0.5, 1, 1.5, 2]

    private static func card(_ name: String, _ frame: CGRect, _ color: RGBA, z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), radius: CGFloat = 0,
                             kind: Node.Kind = .rectangle) -> Node {
        var n = Node(kind: kind, name: name, frame: frame)
        n.fill.color = color
        n.cornerRadius = radius
        if z != 0 || turn.x != 0 || turn.y != 0 { n.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        return n
    }

    private static func group(_ name: String, _ frame: CGRect, _ children: [Node], z: CGFloat = 0, turn: (x: Double, y: Double) = (0, 0), keeps: Bool) -> Node {
        var g = Node(kind: .group, name: name, frame: frame)
        g.children = children
        if z != 0 || turn.x != 0 || turn.y != 0 { g.transform3D = Transform3D(x: turn.x, y: turn.y, z: z) }
        if keeps { g.keepsDepth = true }
        return g
    }

    private static func board(_ name: String, _ place: Int, clips: Bool = true, _ children: [Node]) -> Node {
        var b = Node(kind: .artboard, name: name, frame: CGRect(origin: CGPoint(x: CGFloat(place % 4) * 520, y: CGFloat(place / 4) * 420), size: size))
        b.fill.color = ink
        b.clips = clips
        b.children = children
        return b
    }

    /// A group swung and lifted, holding a plate lying in it, a card lying on that, one standing
    /// off it tipped, a disc held over it, and a group tipped again with a card of its own off
    /// its plane.
    private static func turned(_ name: String, _ place: Int, keeps: Bool) -> Node {
        var standing = card("Standing", CGRect(x: 20, y: 10, width: 60, height: 40), blue, z: 50, turn: (20, 0), radius: 8)
        standing.border = Border(on: true, color: .white, width: 3, position: .center)
        let inner = group("Inner", CGRect(x: 10, y: 20, width: 100, height: 60),
                          [card("Deep", CGRect(x: 5, y: 5, width: 30, height: 20), sun, z: 15, radius: 4)], z: 10, turn: (25, 0), keeps: keeps)
        return board(name, place, [group("Group", CGRect(x: 100, y: 50, width: 200, height: 100), [
            card("Plate", CGRect(x: 0, y: 0, width: 200, height: 100), paper, radius: 12),
            card("Lying", CGRect(x: 100, y: 30, width: 80, height: 50), red, radius: 6),
            standing,
            card("Disc", CGRect(x: 130, y: 6, width: 36, height: 36), green, z: 24, kind: .ellipse),
            inner,
        ], z: 30, turn: (0, 40), keeps: keeps)])
    }

    /// A red card 40 off the page, listed under a group that lies in the page and holds a card
    /// in it and a blue one 80 off it, all over one another.
    private static func crossing(_ name: String, _ place: Int, keeps: Bool) -> Node {
        board(name, place, [
            card("Beside", CGRect(x: 150, y: 100, width: 100, height: 100), red, z: 40, radius: 10),
            group("Over", CGRect(x: 100, y: 50, width: 200, height: 200), [
                card("Low", CGRect(x: 60, y: 60, width: 80, height: 80), paper),
                card("High", CGRect(x: 70, y: 70, width: 40, height: 40), blue, z: 80, turn: (15, -20)),
            ], keeps: keeps),
        ])
    }

    /// A card on a backdrop with a label lying on it and a button raised off it, turned as one body.
    private static func body(_ name: String, _ place: Int, x: Double, y: Double) -> Node {
        var doc = BezzleDocument()
        doc.nodes = [board(name, place, [
            card("Back", CGRect(x: 20, y: 20, width: 360, height: 260), RGBA(r: 0.3, g: 0.32, b: 0.38), radius: 16),
            card("Card", CGRect(x: 100, y: 100, width: 200, height: 100), paper, radius: 12),
            card("Label", CGRect(x: 250, y: 110, width: 40, height: 16), green, radius: 4),
            card("Button", CGRect(x: 240, y: 140, width: 40, height: 20), red, z: 20, radius: 10),
        ])]
        let ids = doc.nodes[0].children.dropFirst().map(\.id)
        doc.turnInDepth(Array(ids)) { _, _ in Transform3D(x: x, y: y) }
        return doc.nodes[0]
    }

    /// What is looked at from the side: a card lying in the page, one held up over its middle,
    /// one leaning, and a group that keeps depth with a card standing off it.
    private static func scene(_ name: String, _ place: Int, clips: Bool) -> Node {
        board(name, place, clips: clips, [
            card("Lying", CGRect(x: 20, y: 20, width: 100, height: 60), paper, radius: 8),
            card("Lifted", CGRect(x: 180, y: 130, width: 40, height: 40), red, z: 40),
            card("Leaning", CGRect(x: 300, y: 200, width: 60, height: 40), sun, turn: (0, 40)),
            card("Edge", CGRect(x: 340, y: 40, width: 44, height: 44), blue, z: 60, kind: .ellipse),
            group("Shelf", CGRect(x: 16, y: 170, width: 150, height: 90), [
                card("Board", CGRect(x: 0, y: 0, width: 150, height: 90), RGBA(r: 0.3, g: 0.32, b: 0.38), radius: 10),
                card("Book", CGRect(x: 20, y: 20, width: 50, height: 50), green, z: 35, turn: (-25, 0)),
            ], z: 12, turn: (20, -30), keeps: true),
        ])
    }

    /// Everything drawn as a picture, an artboard each.
    static func design() -> BezzleDocument {
        var doc = BezzleDocument()
        doc.nodes = [
            turned("Keeps", 0, keeps: true), turned("AsCard", 1, keeps: false),
            crossing("Crossing", 2, keeps: true), crossing("CrossingCard", 3, keeps: false),
            body("Body", 4, x: 30, y: -55), body("BodyBack", 5, x: 0, y: 150),
            scene("Look", 6, clips: true), scene("Open", 7, clips: false),
        ]
        return doc
    }

    /// Films: a group that keeps depth, come apart into pieces that stand in the scene, under a
    /// camera that rests for a second (the design's own picture, `front/00.png`) and then swings;
    /// the same while one of its layers rises and another slides under a camera that swings and
    /// tilts; that as one card; that with a key of the group's own, which makes it one card too;
    /// and a body posed as one. A key is a change from the design: a lift of 45 is 45 higher.
    static func film() -> BezzleDocument {
        let backdrop = RGBA(r: 0.13, g: 0.15, b: 0.2)
        var resting = turned("Resting", 0, keeps: true)
        resting.setKey(.cameraSwing, [0], at: 1)
        resting.setKey(.cameraSwing, [22], at: 2)
        resting.film = Film(length: nil, once: true, backdrop: backdrop)
        func turning(_ name: String, _ place: Int, keeps: Bool, own: Bool = false) -> Node {
            var b = turned(name, place, keeps: keeps)
            // The group holds a plate, the lying card, the standing one, a disc and a group.
            b.children[0].children[2].setKey(.lift, [0], at: 0)
            b.children[0].children[2].setKey(.lift, [45], at: 1)
            b.children[0].children[2].setKey(.lift, [0], at: 2)
            b.children[0].children[1].setKey(.move, [0, 0], at: 0)
            b.children[0].children[1].setKey(.move, [-30, 10], at: 2)
            if own {
                b.children[0].setKey(.swing, [0], at: 0)
                b.children[0].setKey(.swing, [-60], at: 2)
            }
            b.setKey(.cameraSwing, [0], at: 0)
            b.setKey(.cameraSwing, [22], at: 2)
            b.setKey(.cameraTilt, [0], at: 0)
            b.setKey(.cameraTilt, [18], at: 2)
            b.film = Film(length: nil, once: true, backdrop: backdrop)
            return b
        }
        var posed = BezzleDocument()
        posed.nodes = [body("Posed", 4, x: 0, y: 0)]
        let ids = Array(posed.nodes[0].children.dropFirst().map(\.id))
        posed.poseInDepth(.swing, of: ids, at: 1) { _ in 40 }
        posed.poseInDepth(.tilt, of: ids, at: 2) { _ in 25 }
        posed.nodes[0].film = Film(length: nil, once: true, backdrop: backdrop)
        var doc = BezzleDocument()
        doc.nodes = [resting, turning("Turning", 1, keeps: true), turning("TurningCard", 2, keeps: false), turning("TurningKeyed", 3, keeps: true, own: true), posed.nodes[0]]
        return doc
    }

    /// The part of the canvas Windows' canvas draws an artboard over (`WindowsCore.drawn`): its
    /// frame, or, when it shows what runs past its edges, as far as that reaches seen from there.
    static func covers(_ board: Node, _ look: DepthLook?) -> CGRect {
        guard !board.clips else { return board.frame }
        var r = board.frame
        let eye = Eye.stage(board.frame.size).looking(look)
        for c in board.children where !c.hidden { r = r.union(Renderer.reach(of: c, eye: eye).offsetBy(dx: board.frame.minX, dy: board.frame.minY)) }
        return r.integral
    }

    @Test func dumpDepth() throws {
        guard let folder = ProcessInfo.processInfo.environment["DEPTH_TRUTH_OUT"], !folder.isEmpty else { return }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Pictures: from the front as anything is drawn, and from each side as the canvas draws.
        let doc = Self.design()
        let assets = try write(doc, named: "Depth", in: out)
        var covered: [String: [[Double]]] = [:]
        let front = out.appendingPathComponent("front", isDirectory: true)
        try FileManager.default.createDirectory(at: front, withIntermediateDirectories: true)
        for (k, board) in doc.nodes.enumerated() {
            let image = try #require(Renderer.image(of: board, scale: 2, assets: assets))
            try write(image, to: front.appendingPathComponent(String(format: "%02d.png", k)))
        }
        for (name, look) in Self.looks {
            let side = out.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
            var options = Renderer.Options(deviceScale: 2, assets: assets)
            options.looks = Dictionary(uniqueKeysWithValues: doc.nodes.map { ($0.id, look) })
            for (k, board) in doc.nodes.enumerated() {
                let rect = Self.covers(board, look)
                let image = try #require(Renderer.tile(of: board, rect: rect, scale: 2, options: options))
                try write(image, to: side.appendingPathComponent(String(format: "%02d.png", k)))
                covered[name, default: []].append([rect.minX, rect.minY, rect.width, rect.height])
            }
        }
        try JSONSerialization.data(withJSONObject: covered, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("covers.json"))

        // Films: each frame as a movie's frames are made.
        let film = Self.film()
        let filmAssets = try write(film, named: "DepthFilm", in: out)
        let films = out.appendingPathComponent("films", isDirectory: true)
        try FileManager.default.createDirectory(at: films, withIntermediateDirectories: true)
        for board in film.nodes where board.hasFilm {
            let size = CGSize(width: (board.frame.width * 2).rounded(), height: (board.frame.height * 2).rounded())
            for t in Self.moments {
                let image = try #require(FilmExport.frame(of: board, at: t, size: size, assets: filmAssets))
                try write(image, to: films.appendingPathComponent("\(board.name)-film-\(String(format: "%.2f", t)).png"))
            }
        }
    }

    private func write(_ doc: BezzleDocument, named name: String, in out: URL) throws -> Assets {
        let package = out.appendingPathComponent("\(name).bezzle", isDirectory: true)
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package.appendingPathComponent(DesignFile.imagesFolder), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(doc).write(to: package.appendingPathComponent(DesignFile.documentName))
        return Assets(design: package)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
