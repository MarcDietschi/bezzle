import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bezzle

/// The Mac's own frames of films, for the browser viewer's film to be compared with
/// (tools/film-compare.mjs). The designs are made here and written as the Mac writes a design;
/// each film is drawn at several moments exactly as a movie's frames are (`FilmExport.frame`),
/// and with each frame goes where the film's arithmetic puts every piece then.
///
/// Like WebTruthTests, this is copied into `BezzleTests/` to be run, with
/// `TEST_RUNNER_WEB_TRUTH_OUT=<dir>`, and `TEST_RUNNER_WEB_TRUTH_DESIGNS=<AppStore/screenshots-src/designs>`
/// for the film made of a sample design. Everything goes to `<dir>/films`.
@MainActor
struct FilmTruthTests {
    private static let ink = RGBA(r: 0.17, g: 0.15, b: 0.13), soft = RGBA(r: 0.45, g: 0.42, b: 0.38)
    private static let blue = RGBA(r: 0.18, g: 0.36, b: 0.83), red = RGBA(r: 0.85, g: 0.3, b: 0.22), green = RGBA(r: 0.2, g: 0.6, b: 0.4)

    /// Camera moves in depth, fades, a blur and springs: three cards, one of them lifted and
    /// tipped, a faded group whose insides move, a layer the design itself holds up off the page,
    /// and one that reaches past the artboard's edge. It plays once, on a backdrop of its own.
    static func depth() -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Depth", frame: CGRect(x: 120, y: 80, width: 480, height: 320))
        board.fill.color = RGBA(r: 0.96, g: 0.94, b: 0.9)
        let size = board.frame.size

        // Standing still: one picture of them all.
        let sun = Parts.oval("Sun", CGRect(x: 356, y: 26, width: 84, height: 84), RGBA(r: 0.97, g: 0.72, b: 0.26))
        let title = Parts.text("Northern lights", x: 32, y: 26, size: 26, weight: "Bold", color: ink)
        let caption = Parts.paragraph("Three cards, a camera and a little depth.", x: 32, y: 64, width: 220, size: 13, color: soft)

        // Pops in on a spring.
        var one = Parts.rect("One", CGRect(x: 32, y: 122, width: 120, height: 150), .white, radius: 14)
        one.shadow = Parts.shadow(y: 8, blur: 18, RGBA(r: 0.1, g: 0.08, b: 0.05, a: 0.28))
        one.apply(.pop, at: 0.2, frame: one.frame, board: size)

        // Lifted off the page, tipped and swung, and set down again.
        var two = Parts.rect("Two", CGRect(x: 180, y: 122, width: 120, height: 150), blue, radius: 14)
        two.shadow = Parts.shadow(y: 8, blur: 18, RGBA(r: 0.05, g: 0.1, b: 0.3, a: 0.35))
        two.setKey(.lift, [0], at: 0.4)
        two.setKey(.lift, [90], at: 1.4)
        two.setKey(.lift, [20], at: 3)
        two.setKey(.tilt, [0], at: 0.4)
        two.setKey(.tilt, [-28], at: 1.4, ease: .spring(0.4))
        two.setKey(.swing, [0], at: 1)
        two.setKey(.swing, [32], at: 2.2)

        // Comes into focus, and goes soft again without fading.
        var three = Parts.rect("Three", CGRect(x: 328, y: 122, width: 120, height: 150), green, radius: 14)
        three.apply(.focus, at: 0.5, frame: three.frame, board: size)
        three.setKey(.blur, [0], at: 1.6)
        three.setKey(.blur, [9], at: 2.4, ease: .linear)
        three.setKey(.fade, [1], at: 2.4)
        three.setKey(.fade, [0.55], at: 3, ease: .linear)

        // Faded as a whole, and what it holds moves: drawn again at every moment.
        var dot = Parts.oval("Dot", CGRect(x: 54, y: 10, width: 20, height: 20), red)
        dot.setKey(.move, [0, 0], at: 0.3)
        dot.setKey(.move, [-44, 0], at: 1.2, ease: .spring(0.5))
        dot.setKey(.move, [0, 0], at: 2.4)
        var mark = Parts.rect("Mark", CGRect(x: 6, y: 6, width: 28, height: 28), ink, radius: 6)
        mark.setKey(.turn, [0], at: 0)
        mark.setKey(.turn, [180], at: 3, ease: .linear)
        var badge = Parts.group("Badge", [Parts.pill("Plate", CGRect(x: 0, y: 0, width: 84, height: 40), RGBA(r: 1, g: 0.85, b: 0.6)), mark, dot])
        badge.frame.origin = CGPoint(x: 262, y: 56)
        badge.opacity = 0.8

        // Held up off the page by the design: a piece of its own, which the camera sees standing.
        var held = Parts.rect("Held", CGRect(x: 200, y: 20, width: 46, height: 30), red, radius: 8)
        held.transform3D = Transform3D(x: 0, y: 0, z: 60)

        // Reaches past the artboard's edge, with its shadow: shown once the camera draws back.
        var edge = Parts.rect("Edge", CGRect(x: 436, y: 262, width: 92, height: 84), RGBA(r: 0.55, g: 0.35, b: 0.75), radius: 12)
        edge.shadow = Parts.shadow(y: 6, blur: 14, RGBA(r: 0, g: 0, b: 0, a: 0.3))
        edge.rotation = 8

        board.children = [sun, title, caption, one, two, three, badge, held, edge]

        board.setKey(.cameraZoom, [1], at: 0)
        board.setKey(.cameraZoom, [1.7], at: 1.5)
        board.setKey(.cameraZoom, [0.72], at: 3)
        board.setKey(.cameraMove, [0, 0], at: 0)
        board.setKey(.cameraMove, [56, 34], at: 1.5)
        board.setKey(.cameraMove, [-10, 6], at: 3)
        board.setKey(.cameraTilt, [0], at: 0.5)
        board.setKey(.cameraTilt, [38], at: 1.5)
        board.setKey(.cameraTilt, [12], at: 3)
        board.setKey(.cameraSwing, [0], at: 0.5)
        board.setKey(.cameraSwing, [-24], at: 2)
        board.setKey(.cameraSwing, [6], at: 3)
        board.setKey(.cameraRoll, [0], at: 2)
        board.setKey(.cameraRoll, [5], at: 3)
        board.film = Film(length: nil, once: true, backdrop: RGBA(r: 0.13, g: 0.15, b: 0.2))
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    /// Moves with time, and by a key of one of its inputs: bands that drift, see-through between them.
    static let waves = "precision highp float; uniform vec2 u_resolution; uniform float u_time; uniform float u_strength;"
        + " void main() { vec2 p = gl_FragCoord.xy / u_resolution;"
        + " float w = 0.5 + 0.5 * sin(6.2831853 * (p.x * 1.5 + u_time * 0.4)) * cos(6.2831853 * (p.y - u_time * 0.25));"
        + " vec3 c = mix(vec3(0.07, 0.11, 0.32), vec3(0.98, 0.56, 0.25), w * u_strength);"
        + " float a = 0.35 + 0.65 * w; gl_FragColor = vec4(c * a, a); }"

    /// A line drawn on, shapes whose points move, and a shader that moves by itself and by a key,
    /// under a camera that only draws near and turns. It goes round, on the backdrop Bezzle picks.
    static func lines() throws -> BezzleDocument {
        var board = Node(kind: .artboard, name: "Lines", frame: CGRect(x: -40, y: 300, width: 420, height: 300))
        board.fill.color = RGBA(r: 0.05, g: 0.06, b: 0.12)
        let size = board.frame.size

        var glow = Parts.rect("Glow", CGRect(x: 20, y: 20, width: 380, height: 260), .white, radius: 28)
        glow.fill.shader = ShaderFill.surface(fragment: waves, size: CGSize(width: 760, height: 520), uniforms: ["u_strength": [1]])
        glow.poseInput("u_strength", [0.25], at: 2)

        // Drawn on as a pen draws it.
        var signature = Node.path(BezierPath("M 40 210 C 80 120 120 260 160 190 C 190 140 230 150 250 200 C 270 250 330 240 380 150"), name: "Signature")
        signature.border = Border(on: true, color: .white, width: 5, position: .center)
        signature.apply(.draw, at: 0.2, frame: signature.frame, board: size)

        // A dash that runs along its line: both ends of what is drawn move.
        var runner = Node.path(BezierPath("M 50 60 L 150 40 L 250 70 L 370 50"), name: "Runner")
        runner.border = Border(on: true, color: RGBA(r: 1, g: 0.8, b: 0.3), width: 4, position: .center)
        runner.setKey(.draw, [0, 0.2], at: 0, ease: .linear)
        runner.setKey(.draw, [0.8, 1], at: 2, ease: .linear)

        // A star whose points go out and come back, turning meanwhile.
        var star = Node.path(BezierPath("M 300 90 L 312 124 L 348 124 L 319 145 L 330 180 L 300 159 L 270 180 L 281 145 L 252 124 L 288 124 Z"), name: "Star")
        star.fill = Fill(color: RGBA(r: 0.95, g: 0.35, b: 0.45))
        star.border.on = false
        var pointed = try #require(star.ownOutline)
        for i in stride(from: 0, to: pointed.subpaths[0].anchors.count, by: 2) {
            let p = pointed.subpaths[0].anchors[i].point, middle = CGPoint(x: 48, y: 48)
            pointed.subpaths[0].anchors[i].point = CGPoint(x: middle.x + (p.x - middle.x) * 1.55, y: middle.y + (p.y - middle.y) * 1.55)
        }
        let pointedNow = star.poseShape(pointed, at: 1.2)
        #expect(pointedNow)
        star.setKey(.shape, star.shapeRest, at: 2.4)
        star.setKey(.turn, [0], at: 0, ease: .linear)
        star.setKey(.turn, [72], at: 2.4, ease: .linear)

        // An ellipse pulled into a drop: its top point rises and loses its roundness.
        var drop = Parts.oval("Drop", CGRect(x: 60, y: 96, width: 56, height: 56), RGBA(r: 0.35, g: 0.75, b: 0.95))
        var pulled = try #require(drop.ownOutline)
        let anchors = pulled.subpaths[0].anchors
        let highest = anchors.indices.min { anchors[$0].point.y < anchors[$1].point.y }
        let top = try #require(highest)
        pulled.subpaths[0].anchors[top].point.y -= 34
        pulled.subpaths[0].anchors[top].handleIn = nil
        pulled.subpaths[0].anchors[top].handleOut = nil
        let pulledNow = drop.poseShape(pulled, at: 1.5)
        #expect(pulledNow)

        // A box whose border is drawn on.
        var box = Parts.rect("Box", CGRect(x: 150, y: 96, width: 70, height: 56), RGBA(r: 1, g: 1, b: 1, a: 0.08), radius: 10)
        box.border = Border(on: true, color: RGBA(r: 0.6, g: 0.9, b: 0.7), width: 3, position: .center)
        box.setKey(.draw, [0, 0], at: 0.4)
        box.setKey(.draw, [0, 1], at: 1.8, ease: .smooth)

        board.children = [glow, signature, runner, star, drop, box]
        board.setKey(.cameraZoom, [1], at: 0)
        board.setKey(.cameraZoom, [1.3], at: 2.5)
        board.setKey(.cameraRoll, [0], at: 0)
        board.setKey(.cameraRoll, [-5], at: 2.5)
        var doc = BezzleDocument()
        doc.nodes = [board]
        return doc
    }

    /// A film on a real design: the sample's first artboard, its layers rising one after another
    /// under a camera that flies in close over it, tipped and swung.
    static func flight(over sample: URL) throws -> BezzleDocument {
        var doc = try DesignFile.read(sample)
        let found = doc.nodes.firstIndex { $0.isArtboard }
        let at = try #require(found)
        doc.nodes = [doc.nodes[at]]
        let ids = doc.nodes[0].children.suffix(6).map(\.id)
        doc.apply(.rise, to: ids, at: 0.2, apart: 0.12)
        doc.nodes[0].setKey(.cameraZoom, [1], at: 0)
        doc.nodes[0].setKey(.cameraZoom, [2.4], at: 2)
        doc.nodes[0].setKey(.cameraZoom, [1], at: 4)
        doc.nodes[0].setKey(.cameraMove, [0, 0], at: 0)
        doc.nodes[0].setKey(.cameraMove, [-60, -220], at: 2)
        doc.nodes[0].setKey(.cameraMove, [0, 0], at: 4)
        doc.nodes[0].setKey(.cameraTilt, [0], at: 0)
        doc.nodes[0].setKey(.cameraTilt, [32], at: 2)
        doc.nodes[0].setKey(.cameraTilt, [0], at: 4)
        doc.nodes[0].setKey(.cameraSwing, [0], at: 1)
        doc.nodes[0].setKey(.cameraSwing, [-18], at: 2.5)
        doc.nodes[0].setKey(.cameraSwing, [0], at: 4)
        return doc
    }

    @Test func dumpFilms() throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["WEB_TRUTH_OUT"] ?? "/tmp/web-truth").appendingPathComponent("films", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var films: [(name: String, doc: BezzleDocument, moments: [Double], from: URL?)] = [
            ("Depth", Self.depth(), [0, 0.3, 0.55, 0.8, 1.2, 1.5, 2.1, 2.7, 3], nil),
            ("Lines", try Self.lines(), [0, 0.35, 0.7, 1.1, 1.5, 2, 2.5], nil),
        ]
        if let designs = environment["WEB_TRUTH_DESIGNS"], !designs.isEmpty {
            let sample = URL(fileURLWithPath: designs).appendingPathComponent("Wander.bezzle")
            films.append(("Flight", try Self.flight(over: sample), [0, 0.5, 1, 1.5, 2, 2.5, 3.2, 4], sample))
        }
        var all: [[String: Any]] = []
        for film in films {
            let package = out.appendingPathComponent("\(film.name).bezzle", isDirectory: true)
            try? FileManager.default.removeItem(at: package)
            if let from = film.from {
                try FileManager.default.copyItem(at: from, to: package)
            } else {
                try FileManager.default.createDirectory(at: package.appendingPathComponent(DesignFile.imagesFolder), withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(film.doc).write(to: package.appendingPathComponent(DesignFile.documentName))
            let assets = Assets(design: package)
            var boards: [[String: Any]] = []
            for (i, board) in film.doc.nodes.enumerated() where board.isArtboard && board.hasFilm {
                let size = CGSize(width: (board.frame.width * 2).rounded(), height: (board.frame.height * 2).rounded())
                let pieces = board.filmPieces(), layers = board.filmLayers(of: pieces)
                var frames: [[String: Any]] = []
                for t in film.moments where t <= board.filmLength + 1e-9 {
                    let file = "\(film.name)-\(i)-\(String(format: "%04d", Int((t * 1000).rounded()))).png"
                    let image = try #require(FilmExport.frame(of: board, at: t, size: size, assets: assets))
                    try write(image, to: out.appendingPathComponent(file))
                    let camera = board.camera(at: t)
                    let placements = pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera) }
                    frames.append([
                        "t": t, "file": file, "order": board.filmOrder(pieces, placements),
                        "pieces": zip(pieces, placements).map { piece, p in
                            ["key": piece.key, "changes": piece.changes, "opacity": p.opacity, "blur": p.blur, "height": p.height,
                             "map": [p.map.a, p.map.b, p.map.c, p.map.d, p.map.e, p.map.f, p.map.g, p.map.h, p.map.i]] as [String: Any]
                        },
                    ])
                }
                let backdrop = board.filmBackdrop
                boards.append([
                    "index": i, "name": board.name, "size": [board.frame.width, board.frame.height], "pixels": [size.width, size.height],
                    "length": board.filmLength, "once": board.film?.once == true,
                    "backdrop": [backdrop.r, backdrop.g, backdrop.b, backdrop.a], "frames": frames,
                ])
            }
            all.append(["name": film.name, "package": package.lastPathComponent, "boards": boards])
        }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("films.json"))
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
