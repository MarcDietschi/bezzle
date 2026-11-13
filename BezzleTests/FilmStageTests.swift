import Testing
import AppKit
import CoreImage
@testable import Bezzle

/// A holder laid out from the top, as the canvas's own stack is in the app.
private final class HolderFromTheTop: NSView {
    override var isFlipped: Bool { true }
}

/// The film's stage, which shows the artboard being animated under the canvas: what it builds of
/// the film's pieces, where it puts them, when it draws their pictures again, and when it runs.
/// The stage is driven without a window; its pictures are drawn away from the main thread and
/// waited for. Only what a view does in a window alone is tried in one, which is never shown.
@MainActor
struct FilmStageTests {
    private let red = RGBA(r: 0.9, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.3, b: 0.8), green = RGBA(r: 0.1, g: 0.6, b: 0.3)

    private func box(_ name: String, _ frame: CGRect, _ color: RGBA) -> Node {
        var box = Node(kind: .rectangle, name: name, frame: frame)
        box.fill.color = color
        return box
    }

    /// A bench with these layers on artboard A, in Animate, and its stage as large as the canvas.
    ///
    /// `unseen` keeps the mode's change from the canvas. A canvas begins to ease into the
    /// prototype's table when it hears of it, with no window that never ends, and it is kept for as
    /// long (`CanvasView.keepEasing`). That is not the stage's doing, and would hide what is.
    private func staged(_ layers: [Node], zoom: CGFloat = 1, origin: CGPoint = .zero, unseen: Bool = false) -> (bench: Bench, stage: FilmStageView) {
        let bench = Bench(extra: layers)
        if unseen { bench.store.canvas = nil }
        bench.store.show(.animate)
        bench.store.canvas = bench.canvas
        // The view's glide to the film's artboard is no part of what is tested here.
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: origin, zoom: zoom)
        let stage = bench.canvas.filmStage
        stage.frame = bench.canvas.frame
        stage.layout()
        return (bench, stage)
    }

    /// Brings the stage to the design as the canvas does when it draws, again and again until the
    /// pictures it asked for have been drawn. Gives back what the last of these told the canvas.
    @discardableResult
    private func settle(_ stage: FilmStageView, scale: CGFloat = 2, within limit: Duration = .seconds(60)) async throws -> CGRect? {
        let clock = ContinuousClock(), began = clock.now
        while true {
            let rect = stage.sync(scale: scale)
            guard stage.isDrawing else { return rect }
            while stage.isDrawing {
                guard clock.now - began < limit else {
                    Issue.record("The stage's pictures were not drawn within \(limit).")
                    return rect
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// The stage's own layers: the film's frame, the artboard's points in it, and the pictures as they are stacked.
    private func layers(_ stage: FilmStageView) throws -> (gate: CALayer, scene: CALayer, pictures: [CALayer]) {
        let content = try #require(stage.layer?.sublayers?.first)
        let gate = try #require(content.sublayers?.first)
        let scene = try #require(gate.sublayers?.first)
        return (gate, scene, scene.sublayers ?? [])
    }

    /// A piece as the film's own arithmetic has it at a moment.
    private struct Expected {
        var piece: FilmPiece
        var rect: CGRect
        var placement: FilmPlacement
    }

    /// The pieces the stage has to show at a moment, in the order they are stacked there.
    private func expected(_ store: DocumentStore, at t: Double) throws -> [Expected] {
        let board = try #require(store.filmBoard)
        var all: [Expected] = []
        for piece in board.filmPieces(loose: Set(store.posedLayers)) {
            let rect = FilmPictures.rect(of: FilmPictures.subject(of: piece, on: board, at: t))
            if rect.width > 0, rect.height > 0 { all.append(Expected(piece: piece, rect: rect, placement: FilmPlacement())) }
        }
        let camera = board.camera(at: t)
        for i in all.indices { all[i].placement = board.placement(of: all[i].piece, at: t, camera: camera) }
        return board.filmOrder(all.map(\.piece), all.map(\.placement)).map { all[$0] }
    }

    /// Where a point of a picture, in the artboard's points, shows in the scene: its layer's own
    /// transform applied as Core Animation applies it.
    private func shown(_ p: CGPoint, by layer: CALayer) -> CGPoint {
        let m = layer.transform
        let x = p.x - layer.bounds.minX - layer.anchorPoint.x * layer.bounds.width
        let y = p.y - layer.bounds.minY - layer.anchorPoint.y * layer.bounds.height
        let w = x * m.m14 + y * m.m24 + m.m44
        return CGPoint(x: (x * m.m11 + y * m.m21 + m.m41) / w + layer.position.x, y: (x * m.m12 + y * m.m22 + m.m42) / w + layer.position.y)
    }

    /// Checks everything the stage has built against the film's arithmetic at the moment it shows.
    private func check(_ stage: FilmStageView, _ store: DocumentStore, _ note: String = "") throws {
        let t = store.film.playing ? store.film.head : store.filmTime
        let want = try expected(store, at: t)
        let pictures = try layers(stage).pictures
        #expect(pictures.count == want.count, "\(note) at \(t): \(pictures.count) pictures for \(want.count) pieces")
        for (layer, item) in zip(pictures, want) {
            let what = "\(note) at \(t), \(item.piece.kind) \(item.piece.layers.count)"
            #expect(layer.bounds == item.rect, "\(what): \(layer.bounds) for \(item.rect)")
            #expect(layer.contents != nil, "\(what)")
            #expect(abs(Double(layer.opacity) - item.placement.opacity) < 1e-6, "\(what): opacity \(layer.opacity) for \(item.placement.opacity)")
            let r = item.rect
            let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                          CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX + r.width / 3, y: r.maxY - r.height / 5)]
            for p in points where item.placement.map.depth(at: p) > 1e-3 {
                let got = shown(p, by: layer), should = item.placement.map(p)
                let slack = 1e-6 * max(1, abs(should.x), abs(should.y))
                #expect(abs(got.x - should.x) <= slack && abs(got.y - should.y) <= slack, "\(what): \(p) shows at \(got), the film has it at \(should)")
            }
        }
    }

    /// The colour in the middle of a picture.
    private func middle(of layer: CALayer) throws -> [Int] {
        let image = try #require(layer.contents.map { $0 as! CGImage })
        let ctx = try #require(Renderer.bitmap(CGSize(width: image.width, height: image.height)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let at = (image.height / 2) * ctx.bytesPerRow + (image.width / 2) * 4
        return [Int(data[at]), Int(data[at + 1]), Int(data[at + 2])]
    }

    private func images(_ stage: FilmStageView) throws -> [ObjectIdentifier] {
        try layers(stage).pictures.compactMap { $0.contents.map { ObjectIdentifier($0 as AnyObject) } }
    }

    private func components(_ color: CGColor?) -> [Double] {
        guard let color = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) else { return [] }
        return (color.components ?? []).map { (Double($0) * 1000).rounded() / 1000 }
    }

    /// A window that is never shown, for what a view does only in one.
    private func window(holding view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    /// A still box, one that moves, grows, turns and fades over a second, and a turned one over them.
    private func cast() -> [Node] {
        var mover = box("Mover", CGRect(x: 150, y: 40, width: 80, height: 60), blue)
        mover.setKey(.move, [0, 0], at: 0, ease: .linear)
        mover.setKey(.move, [80, 40], at: 1, ease: .linear)
        mover.setKey(.scale, [1, 1], at: 0)
        mover.setKey(.scale, [1.5, 0.5], at: 1)
        mover.setKey(.turn, [0], at: 0)
        mover.setKey(.turn, [30], at: 1)
        mover.setKey(.fade, [1], at: 0, ease: .linear)
        mover.setKey(.fade, [0.4], at: 1, ease: .linear)
        var top = box("Top", CGRect(x: 60, y: 150, width: 120, height: 80), green)
        top.rotation = 15
        return [box("Still", CGRect(x: 20, y: 20, width: 100, height: 60), red), mover, top]
    }

    private func edit(_ bench: Bench, _ change: (inout BezzleDocument) -> Void) {
        bench.step { bench.store.edit("Change", change) }
    }

    // MARK: What it builds

    @Test func withNoFilmToShowTheCanvasIsToldNothing() async throws {
        let bench = Bench(extra: cast())
        let stage = bench.canvas.filmStage
        stage.frame = bench.canvas.frame
        stage.layout()
        // Not animated: nothing to cut a window for, and nothing drawn.
        #expect(stage.sync(scale: 2) == nil)
        #expect(!stage.isDrawing && stage.picturesMade == 0)
        #expect(try layers(stage).gate.isHidden)
        // Animated, but with no room yet.
        bench.store.show(.animate)
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: .zero, zoom: 1)
        stage.frame = .zero
        #expect(stage.sync(scale: 2) == nil && !stage.isDrawing)
        // With room: nothing until its first pictures are drawn, so the canvas shows its own drawing meanwhile.
        stage.frame = bench.canvas.frame
        #expect(stage.sync(scale: 2) == nil)
        #expect(stage.isDrawing)
        #expect(try layers(stage).gate.isHidden)
        let rect = try await settle(stage)
        #expect(rect == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(try !layers(stage).gate.isHidden)
        // Back in the design, it is put away again.
        bench.store.show(.design)
        #expect(stage.sync(scale: 2) == nil)
        #expect(try layers(stage).gate.isHidden && layers(stage).pictures.isEmpty)
    }

    @Test func thereIsOnePictureForEachPieceAsTheFilmHasThem() async throws {
        let (bench, stage) = staged(cast())
        try await settle(stage)
        let built = try layers(stage)
        // The ground, the still box, the one that moves, and what lies over it.
        let want = try expected(bench.store, at: 0)
        #expect(want.map(\.piece.kind) == [.ground, .run, .layer, .run])
        #expect(built.pictures.count == 4 && stage.picturesMade == 4)
        try check(stage, bench.store)
        // Each drawn two pixels to the point for a screen that has two, and placed from its corner.
        // The one that grows to one and a half times its size is drawn sharp enough for that, which
        // in the steps pictures are drawn in is four pixels to the point.
        let mover = bench.node("Mover")!.id
        for (layer, item) in zip(built.pictures, want) {
            let image = layer.contents.map { $0 as! CGImage }
            let sharp: CGFloat = item.piece.layers.first == mover ? 4 : 2
            #expect(image?.width == Int(item.rect.width * sharp) && image?.height == Int(item.rect.height * sharp),
                    "\(item.piece.kind): \(image?.width ?? 0) by \(image?.height ?? 0) for \(item.rect)")
            #expect(layer.anchorPoint == .zero && layer.position == .zero)
        }
        // A picture reaches two points past what it shows, for soft edges.
        #expect(built.pictures[1].bounds == CGRect(x: 18, y: 18, width: 104, height: 64))
        #expect(built.pictures[2].bounds == CGRect(x: 148, y: 38, width: 84, height: 64))
        #expect(built.pictures[0].bounds == CGRect(x: 0, y: 0, width: 400, height: 300))
        // The film's frame is the artboard's place on the canvas, what is past it is cut off, and
        // the artboard's points are scaled to it.
        #expect(built.gate.frame == CGRect(x: 100, y: 100, width: 400, height: 300) && built.gate.masksToBounds)
        #expect(built.scene.bounds == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(CATransform3DEqualToTransform(built.scene.transform, CATransform3DIdentity))
    }

    @Test func eachPictureLiesWhereTheFilmsArithmeticPutsIt() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        // At rest, and posed along the way: moved, grown, turned and faded.
        for t in [0, 0.25, 0.5, 0.731, 1, 1.6] {
            store.seek(t)
            #expect(stage.sync(scale: 2) != nil)
            try check(stage, store, "posed")
        }
        let mover = try layers(stage).pictures[2]
        #expect(abs(mover.opacity - 0.4) < 1e-6)

        // Under a camera that comes closer, looks elsewhere, rolls and tips the scene.
        let a = bench.a.id
        edit(bench) { doc in
            doc.update(a) { n in
                n.setKey(.cameraZoom, [1], at: 0); n.setKey(.cameraZoom, [2.2], at: 2)
                n.setKey(.cameraMove, [0, 0], at: 0); n.setKey(.cameraMove, [60, -30], at: 2)
                n.setKey(.cameraRoll, [0], at: 0); n.setKey(.cameraRoll, [25], at: 2)
                n.setKey(.cameraTilt, [0], at: 0); n.setKey(.cameraTilt, [40], at: 2)
                n.setKey(.cameraSwing, [0], at: 0); n.setKey(.cameraSwing, [-20], at: 2)
            }
        }
        let made = stage.picturesMade
        for t in [0, 0.4, 1, 1.5, 2] {
            store.seek(t)
            try await settle(stage)
            try check(stage, store, "filmed")
        }
        // In perspective now: the pictures' own transforms carry it.
        #expect(try layers(stage).pictures[0].transform.m14 != 0)
        // The camera only places pictures; sharper ones are drawn for what it comes closer to.
        #expect(stage.picturesMade >= made)
    }

    @Test func liftedTippedAndSwungLayersAreStackedByTheirHeight() async throws {
        var low = box("Low", CGRect(x: 60, y: 60, width: 120, height: 90), red)
        low.setKey(.lift, [0], at: 0, ease: .linear)
        low.setKey(.lift, [120], at: 1, ease: .linear)
        low.setKey(.tilt, [0], at: 0)
        low.setKey(.tilt, [35], at: 1)
        var high = box("High", CGRect(x: 120, y: 100, width: 120, height: 90), blue)
        high.setKey(.swing, [0], at: 0)
        high.setKey(.swing, [-40], at: 1)
        high.setKey(.lift, [40], at: 0)
        let (bench, stage) = staged([low, high])
        let store = bench.store
        try await settle(stage)
        // At the start the upper one is the higher: ground, low, high.
        var want = try expected(store, at: 0)
        #expect(want.map { $0.piece.layers.first } == [nil, low.id, high.id])
        try check(stage, store, "start")
        // Lifted past it, the lower one covers it.
        store.seek(1)
        try await settle(stage)
        want = try expected(store, at: 1)
        #expect(want.map { $0.piece.layers.first } == [nil, high.id, low.id])
        try check(stage, store, "lifted")
        store.seek(0.5)
        try await settle(stage)
        try check(stage, store, "between")
    }

    @Test func atRestTheFilmLiesExactlyWhereTheCanvasDrawsTheArtboard() async throws {
        let (bench, stage) = staged(cast(), zoom: 1.37, origin: CGPoint(x: 37.3, y: -12.7))
        let store = bench.store
        let rect = try #require(try await settle(stage))
        let built = try layers(stage)
        let board = try #require(store.filmBoard)
        // A point of the artboard, through the picture's transform, the scene's scale and the frame's place.
        for (layer, item) in zip(built.pictures, try expected(store, at: 0)) {
            for p in [CGPoint(x: item.rect.minX, y: item.rect.minY), CGPoint(x: item.rect.maxX, y: item.rect.maxY)] {
                let inScene = shown(p, by: layer)
                let onStage = CGPoint(x: rect.minX + inScene.x * built.scene.transform.m11, y: rect.minY + inScene.y * built.scene.transform.m22)
                let onCanvas = store.viewport.toView(CGPoint(x: board.frame.minX + p.x, y: board.frame.minY + p.y))
                // To the pixel the frame is rounded to.
                #expect(abs(onStage.x - onCanvas.x) <= 0.51 && abs(onStage.y - onCanvas.y) <= 0.51, "\(p): \(onStage) for \(onCanvas)")
            }
        }
    }

    @Test func aLayerMovingInsideAGroupIsAPieceOfItsOwnPlacedFromTheGroup() async throws {
        var inner = box("Inner", CGRect(x: 10, y: 10, width: 40, height: 40), green)
        inner.setKey(.move, [0, 0], at: 0, ease: .linear)
        inner.setKey(.move, [100, 20], at: 1, ease: .linear)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 40, y: 150, width: 200, height: 60))
        group.children = [box("Rail", CGRect(x: 0, y: 50, width: 200, height: 10), blue), inner, box("Cap", CGRect(x: 150, y: 0, width: 50, height: 50), red)]
        var hidden = box("Hidden", CGRect(x: 300, y: 20, width: 60, height: 60), blue)
        hidden.hidden = true
        hidden.setKey(.move, [0, 0], at: 0)
        hidden.setKey(.move, [0, 50], at: 1)
        let (bench, stage) = staged([box("Still", CGRect(x: 20, y: 20, width: 100, height: 60), red), group, hidden])
        let store = bench.store
        try await settle(stage)
        // The group comes apart: what lies under the moving layer, the layer, and what lies over
        // it. Nothing of the hidden layer, though it has keys.
        let want = try expected(store, at: 0)
        #expect(want.map(\.piece.kind) == [.ground, .run, .run, .layer, .run])
        #expect(want.map(\.piece.origin) == [.zero, .zero, CGPoint(x: 40, y: 150), CGPoint(x: 40, y: 150), CGPoint(x: 40, y: 150)])
        #expect(try layers(stage).pictures.count == 5)
        try check(stage, store)
        // Its own corner, ten in from the group's, is where the move has taken it.
        let layer = try layers(stage).pictures[3]
        #expect(shown(CGPoint(x: 50, y: 160), by: layer) == CGPoint(x: 50, y: 160))
        store.seek(1)
        _ = stage.sync(scale: 2)
        try check(stage, store)
        #expect(shown(CGPoint(x: 50, y: 160), by: layer) == CGPoint(x: 150, y: 180))
        // The rail under it is drawn in the artboard's points, at the group's place.
        #expect(try layers(stage).pictures[2].bounds == CGRect(x: 38, y: 198, width: 204, height: 14))
    }

    // MARK: The window cut in the canvas

    @Test func theWindowCutInTheCanvasIsOnWholePixelsAtAnyZoomAndPlace() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        let views: [(zoom: CGFloat, origin: CGPoint, scale: CGFloat)] = [
            (1, .zero, 2), (1, .zero, 1), (1.37, CGPoint(x: 37.3, y: -12.7), 2), (0.31, CGPoint(x: -250.4, y: 91.9), 2),
            (3.7, CGPoint(x: 180.25, y: 140.6), 2), (0.0731, CGPoint(x: -3000, y: -2000), 1), (2.5, CGPoint(x: 99.99, y: 99.99), 3),
        ]
        for view in views {
            store.viewport = Viewport(origin: view.origin, zoom: view.zoom)
            let rect = try #require(try await settle(stage, scale: view.scale), "\(view)")
            let raw = store.viewport.toView(bench.a.frame)
            for edge in [rect.minX, rect.minY, rect.width, rect.height] {
                let pixels = edge * view.scale
                #expect(abs(pixels - pixels.rounded()) < 1e-6, "\(view): \(rect)")
            }
            let half = 0.5 / view.scale + 1e-6
            #expect(abs(rect.minX - raw.minX) <= half && abs(rect.minY - raw.minY) <= half, "\(view): \(rect) for \(raw)")
            #expect(abs(rect.width - raw.width) <= half && abs(rect.height - raw.height) <= half, "\(view): \(rect) for \(raw)")
            #expect(rect.width > 0 && rect.height > 0)
            // The film's frame is that very rect, and the artboard's points fill it.
            let built = try layers(stage)
            #expect(built.gate.frame == rect, "\(view)")
            #expect(abs(built.scene.transform.m11 - rect.width / 400) < 1e-9 && abs(built.scene.transform.m22 - rect.height / 300) < 1e-9, "\(view)")
            try check(stage, store, "zoom \(view.zoom)")
        }
    }

    @Test func theBackdropFillsTheFramePastTheArtboard() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        let made = stage.picturesMade
        // Chosen to go with a light artboard.
        #expect(try components(layers(stage).gate.backgroundColor) == [0.898, 0.882, 0.851, 1])
        // Set, it is that; changing it draws no picture again.
        bench.step { store.setFilm("Backdrop") { $0.backdrop = RGBA(r: 0.2, g: 0.4, b: 0.6) } }
        try await settle(stage)
        #expect(try components(layers(stage).gate.backgroundColor) == [0.2, 0.4, 0.6, 1])
        #expect(stage.picturesMade == made)
        // One that is not solid lies on black, as in the movie.
        bench.step { store.setFilm("Backdrop") { $0.backdrop = RGBA(r: 1, g: 0.5, b: 0, a: 0.5) } }
        try await settle(stage)
        #expect(try components(layers(stage).gate.backgroundColor) == [0.5, 0.25, 0, 1])
        // And under a dark artboard, a dark one.
        bench.step { store.setFilm("Backdrop") { $0.backdrop = nil } }
        edit(bench) { doc in doc.update(a) { $0.fill.color = RGBA(r: 0.1, g: 0.1, b: 0.12) } }
        try await settle(stage)
        #expect(try components(layers(stage).gate.backgroundColor) == [0.059, 0.055, 0.051, 1])
    }

    // MARK: Blur

    @Test func aKeyedBlurIsAFilterOnThePictureAndComesOffAgain() async throws {
        var soft = box("Soft", CGRect(x: 150, y: 40, width: 80, height: 60), blue)
        soft.setKey(.blur, [12], at: 0, ease: .linear)
        soft.setKey(.blur, [0], at: 1, ease: .linear)
        let (bench, stage) = staged([box("Still", CGRect(x: 20, y: 20, width: 100, height: 60), red), soft], zoom: 1.5)
        let store = bench.store
        try await settle(stage)
        func radius() throws -> Double? {
            let layer = try layers(stage).pictures[2]
            guard let filters = layer.filters, !filters.isEmpty else { return nil }
            #expect(filters.count == 1 && (filters[0] as? CIFilter)?.name == "blur")
            return layer.value(forKeyPath: "filters.blur.inputRadius") as? Double
        }
        // In the screen's pixels: points of blur, times the zoom, times the two pixels to a point.
        #expect(try radius() == 12 * 1.5 * 2)
        #expect(try layers(stage).pictures[1].filters == nil)
        store.seek(0.5)
        _ = stage.sync(scale: 2)
        #expect(try radius() == 6 * 1.5 * 2)
        store.seek(1)
        _ = stage.sync(scale: 2)
        #expect(try radius() == nil)
        store.seek(0.25)
        _ = stage.sync(scale: 2)
        #expect(try radius() == 9 * 1.5 * 2)
        // Zoomed, the same blur is more pixels.
        store.viewport = Viewport(origin: .zero, zoom: 0.75)
        try await settle(stage)
        #expect(try radius() == 9 * 0.75 * 2)
    }

    @Test func aBlurredPictureIsSharpAgainAfterTheStageWasSetAnew() async throws {
        var soft = box("Soft", CGRect(x: 150, y: 40, width: 80, height: 60), blue)
        soft.setKey(.blur, [12], at: 0, ease: .linear)
        soft.setKey(.blur, [0], at: 1, ease: .linear)
        let (bench, stage) = staged([soft, box("Still", CGRect(x: 20, y: 20, width: 100, height: 60), red)])
        let store = bench.store
        try await settle(stage)
        let layer = try layers(stage).pictures[1]
        #expect(layer.filters?.isEmpty == false)
        // The pieces are worked out again while it is blurred: another layer is picked, and the design changes.
        store.selection = [bench.node("Still")!.id]
        try await settle(stage)
        let still = bench.node("Still")!.id
        edit(bench) { doc in doc.update(still) { $0.fill.color = self.green } }
        try await settle(stage)
        #expect(try layers(stage).pictures[1] === layer)
        #expect(layer.filters?.isEmpty == false)
        // Where its keys have it sharp, it is.
        store.seek(1)
        _ = stage.sync(scale: 2)
        #expect(layer.filters?.isEmpty != false, "\(String(describing: layer.filters))")
        store.seek(0.5)
        _ = stage.sync(scale: 2)
        #expect(layer.value(forKeyPath: "filters.blur.inputRadius") as? Double == 12)
    }

    // MARK: When pictures are drawn again

    @Test func posingAndFilmingOnlyPlacePictures() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, mover = bench.node("Mover")!.id, a = bench.a.id
        try await settle(stage)
        let made = stage.picturesMade, first = try images(stage)
        #expect(made == 4 && first.count == 4)
        // The playhead moved about.
        for k in 0...40 {
            store.seek(Double(k) * 0.05)
            #expect(stage.sync(scale: 2) != nil)
            #expect(!stage.isDrawing)
        }
        // A layer that moves posed anew, a key retimed, its pace changed.
        edit(bench) { doc in doc.update(mover) { $0.setKey(.move, [10, 90], at: 0.5); $0.setKey(.fade, [0.1], at: 1.5) } }
        try await settle(stage)
        edit(bench) { doc in doc.update(mover) { $0.moveKeys(from: 0.5, to: 0.7, of: [.move]); $0.setEase(.spring(), at: 1, of: [.turn]) } }
        try await settle(stage)
        // The film's length, and its backdrop.
        bench.step { store.setFilm("Film") { $0.length = 3; $0.once = true } }
        try await settle(stage)
        // The view moved, without coming closer.
        store.viewport = Viewport(origin: CGPoint(x: -40, y: 25), zoom: 1)
        try await settle(stage)
        // And the camera looking elsewhere at the same distance.
        edit(bench) { doc in doc.update(a) { $0.setKey(.cameraMove, [0, 0], at: 0); $0.setKey(.cameraMove, [50, 20], at: 1); $0.setKey(.cameraRoll, [10], at: 1) } }
        store.seek(0.8)
        try await settle(stage)
        try check(stage, store)
        #expect(stage.picturesMade == made)
        #expect(try images(stage) == first)
    }

    @Test func aFilmThatOnlyPlacesPicturesDrawsNothingAgainWhileItPlays() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        let made = stage.picturesMade, first = try images(stage)
        store.playFilm(fromStart: true)
        let began = try #require(store.film.pass?.began)
        for frame in 0..<240 {
            stage.advance(to: began + Double(frame) / 60)
            #expect(!stage.isDrawing)
            if frame % 40 == 7 { try check(stage, store, "frame \(frame)") }
        }
        #expect(store.film.playing)
        // The canvas drawing meanwhile changes nothing either.
        #expect(stage.sync(scale: 2) != nil && !stage.isDrawing)
        #expect(stage.picturesMade == made)
        #expect(try images(stage) == first)
        store.pauseFilm()
    }

    @Test func aChangeToTheDesignDrawsItsPicturesAgain() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, still = bench.node("Still")!.id
        try await settle(stage)
        let made = stage.picturesMade, first = try images(stage)
        #expect(try middle(of: layers(stage).pictures[1]) == [230, 26, 26])
        edit(bench) { doc in doc.update(still) { $0.fill.color = self.green } }
        // What shows stays until the new pictures have come, so nothing flickers.
        #expect(stage.sync(scale: 2) != nil && stage.isDrawing)
        #expect(try images(stage) == first)
        try await settle(stage)
        #expect(stage.picturesMade > made)
        let now = try images(stage)
        #expect(now.count == 4 && now[1] != first[1])
        #expect(try middle(of: layers(stage).pictures[1]) == [26, 153, 77])
        try check(stage, store)
        // Moved in the design, its picture covers its new place.
        edit(bench) { doc in doc.update(still) { $0.frame.origin = CGPoint(x: 250, y: 200) } }
        try await settle(stage)
        try check(stage, store)
        #expect(try layers(stage).pictures[1].bounds == CGRect(x: 248, y: 198, width: 104, height: 64))
        // Taken out of the design, its picture goes.
        store.selection = [still]
        bench.step { store.deleteSelection() }
        try await settle(stage)
        #expect(try layers(stage).pictures.count == 3)
        try check(stage, store)
        // Undone, it is back.
        bench.undo.undo()
        try await settle(stage)
        #expect(try layers(stage).pictures.count == 4)
        try check(stage, store)
    }

    @Test func aLayerPickedIsItsOwnPieceSoThatPosingItMovesItAtOnce() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, top = bench.node("Top")!.id
        try await settle(stage)
        #expect(try expected(store, at: 0).map(\.piece.kind) == [.ground, .run, .layer, .run])
        store.selection = [top]
        try await settle(stage)
        #expect(try expected(store, at: 0).map(\.piece.kind) == [.ground, .run, .layer, .layer])
        try check(stage, store)
        // Turned as it is in the design, it shows at its own size: two pixels to the point, no sharper.
        let own = try layers(stage).pictures[3]
        #expect((own.contents.map { $0 as! CGImage })?.width == Int(own.bounds.width * 2))
        // Posed, it is placed there with the picture it has.
        let made = stage.picturesMade
        #expect(made == 5)
        store.seek(1)
        bench.step { store.pose(.move, of: [top]) { _ in [40, -30] } }
        store.pauseFilm()
        try await settle(stage)
        try check(stage, store)
        #expect(stage.picturesMade == made)
    }

    @Test func comingCloserAsksForSharperPicturesAndGoingBackKeepsThem() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        let made = stage.picturesMade
        func widths() throws -> [Int] { try layers(stage).pictures.map { ($0.contents.map { $0 as! CGImage })?.width ?? 0 } }
        #expect(try widths()[0] == 800)
        // A little closer, within the step they were drawn for.
        store.viewport = Viewport(origin: .zero, zoom: 0.9)
        try await settle(stage)
        #expect(stage.picturesMade == made)
        // Much closer: drawn again, eight pixels to the point for a zoom of three on a screen with two.
        store.viewport = Viewport(origin: .zero, zoom: 3)
        #expect(stage.sync(scale: 2) != nil && stage.isDrawing)
        try await settle(stage)
        #expect(stage.picturesMade == made + 4)
        #expect(try widths()[0] == 3200)
        try check(stage, store)
        // Further away again, the sharp ones do.
        let sharp = try images(stage)
        store.viewport = Viewport(origin: .zero, zoom: 1)
        try await settle(stage)
        store.viewport = Viewport(origin: .zero, zoom: 0.4)
        try await settle(stage)
        #expect(stage.picturesMade == made + 4)
        #expect(try images(stage) == sharp)
        try check(stage, store)
    }

    @Test func aCameraThatComesCloserHasItsPicturesDrawnSharpEnoughForIt() async throws {
        var layers = cast()
        layers.removeLast()
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        board.setKey(.cameraZoom, [1], at: 0)
        board.setKey(.cameraZoom, [2], at: 1)
        let (bench, stage) = staged(layers)
        let a = bench.a.id
        edit(bench) { doc in doc.update(a) { $0.motion = board.motion } }
        try await settle(stage)
        // Twice as close at its closest: four pixels to the point rather than two.
        let ground = try self.layers(stage).pictures[0].contents.map { $0 as! CGImage }
        #expect(ground?.width == 1600)
        try check(stage, bench.store)
    }

    @Test func anotherArtboardThrowsThePicturesAway() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        let first = try images(stage), made = stage.picturesMade
        store.selection = [bench.b.id]
        // Until the other film's pictures are drawn, the canvas shows that artboard itself.
        #expect(stage.sync(scale: 2) == nil && stage.isDrawing)
        let rect = try await settle(stage)
        #expect(rect == CGRect(x: 600, y: 100, width: 400, height: 300))
        let built = try layers(stage)
        #expect(built.pictures.count == 1 && built.gate.frame == rect)
        #expect(try Set(images(stage)).isDisjoint(with: first))
        #expect(stage.picturesMade == made + 1)
        try check(stage, store)
        // Back on the first, its pieces again, each where it belongs.
        store.selection = [bench.a.id]
        #expect(try await settle(stage) == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(try layers(stage).pictures.count == 4)
        try check(stage, store)
    }

    @Test func aPieceWhoseInsidesMoveIsDrawnAgainAsTimePasses() async throws {
        var inner = box("Inner", CGRect(x: 0, y: 0, width: 40, height: 40), green)
        inner.setKey(.move, [0, 0], at: 0, ease: .linear)
        inner.setKey(.move, [100, 0], at: 1, ease: .linear)
        // Faded as a whole, so it cannot be taken apart: it is drawn again as what it holds moves.
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 40, y: 150, width: 200, height: 40))
        group.opacity = 0.8
        group.children = [inner, box("Rail", CGRect(x: 0, y: 30, width: 200, height: 10), blue)]
        let (bench, stage) = staged([box("Still", CGRect(x: 20, y: 20, width: 100, height: 60), red), group])
        let store = bench.store
        try await settle(stage)
        #expect(try expected(store, at: 0).map(\.piece.changes) == [false, false, true])
        var made = stage.picturesMade
        #expect(made == 3)
        let still = try images(stage)[1]
        // The playhead elsewhere: that piece alone is drawn again, and shows what it holds moved.
        store.seek(0.5)
        #expect(stage.sync(scale: 2) != nil && stage.isDrawing)
        var before = try images(stage)[2]
        try await settle(stage)
        #expect(stage.picturesMade == made + 1)
        #expect(try images(stage)[2] != before && images(stage)[1] == still)
        #expect(try layers(stage).pictures[2].bounds == FilmPictures.rect(of: FilmPictures.subject(of: store.filmBoard!.filmPieces()[2], on: store.filmBoard!, at: 0.5)))
        // At the same moment, nothing more.
        made = stage.picturesMade
        _ = stage.sync(scale: 2)
        _ = stage.sync(scale: 2)
        #expect(!stage.isDrawing && stage.picturesMade == made)

        // While it plays, frame after frame: drawn again as fast as it can be, one at a time.
        store.playFilm(fromStart: true)
        let began = try #require(store.film.pass?.began)
        before = try images(stage)[2]
        stage.advance(to: began + 0.2)
        #expect(stage.isDrawing)
        stage.advance(to: began + 0.21)
        stage.advance(to: began + 0.22)
        while stage.isDrawing { try await Task.sleep(for: .milliseconds(2)) }
        #expect(stage.picturesMade == made + 1)
        #expect(try images(stage)[2] != before && images(stage)[1] == still)
        stage.advance(to: began + 0.6)
        while stage.isDrawing { try await Task.sleep(for: .milliseconds(2)) }
        #expect(stage.picturesMade == made + 2)
        store.pauseFilm()
        try await settle(stage)
        try check(stage, store)
    }

    // MARK: Laid out from the top

    @Test func itsLayersRunFromTheTopInAnyParent() async throws {
        /// How many of the layers from the content up turn their own over: an odd number runs from the top.
        func flips(_ stage: FilmStageView) throws -> Int {
            var count = 0
            var layer: CALayer? = try #require(stage.layer?.sublayers?.first)
            while let l = layer {
                if l.isGeometryFlipped { count += 1 }
                layer = l.superlayer
            }
            return count
        }
        // On its own.
        let (bench, stage) = staged(cast())
        try await settle(stage)
        #expect(try flips(stage) % 2 == 1)
        #expect(try layers(stage).gate.frame == CGRect(x: 100, y: 100, width: 400, height: 300))

        // In a parent laid out from the top, as the canvas's stack is, and in one from the bottom,
        // each in a window so that the layers are really hung into one another.
        for fromTheTop in [true, false] {
            let parent = fromTheTop ? HolderFromTheTop(frame: bench.canvas.frame) : NSView(frame: bench.canvas.frame)
            parent.wantsLayer = true
            stage.removeFromSuperview()
            stage.frame = parent.bounds
            stage.autoresizingMask = [.width, .height]
            parent.addSubview(stage)
            let window = window(holding: parent)
            window.displayIfNeeded()
            stage.needsLayout = true
            parent.layoutSubtreeIfNeeded()
            #expect(stage.layer?.superlayer === parent.layer, "\(fromTheTop)")
            let turned = try flips(stage)
            #expect(turned % 2 == 1, "from the top \(fromTheTop): \(turned)")
            // The content fills the stage, and the film's frame is where the canvas has the artboard.
            let content = try #require(stage.layer?.sublayers?.first)
            #expect(content.frame == stage.bounds)
            #expect(try await settle(stage) == CGRect(x: 100, y: 100, width: 400, height: 300))
            #expect(try layers(stage).gate.frame == CGRect(x: 100, y: 100, width: 400, height: 300))
            try check(stage, bench.store)
            // Resized with its parent, it still fills it.
            window.setContentSize(NSSize(width: 900, height: 700))
            parent.layoutSubtreeIfNeeded()
            #expect(stage.bounds.size == CGSize(width: 900, height: 700) && content.frame == stage.bounds)
            #expect(try flips(stage) % 2 == 1)
            // The layers above are told which way up they lie when the window first shows them,
            // which is after the stage was laid out, and nothing lays it out again. Brought to the
            // design as each drawing of the canvas does, it lies from the top again; left as it
            // was, the film is upside down, moves against the scroll, and a layer picked jumps.
            let above = try #require(parent.layer)
            for _ in 0..<2 {
                above.isGeometryFlipped.toggle()
                #expect(try flips(stage) % 2 == 0)
                try await settle(stage)
                #expect(try flips(stage) % 2 == 1, "from the top \(fromTheTop)")
                try check(stage, bench.store)
            }
            // And while the film plays, when the canvas draws nothing: with its next frame.
            above.isGeometryFlipped.toggle()
            bench.store.playFilm(fromStart: true)
            stage.advance(to: CACurrentMediaTime() + 0.1)
            #expect(try flips(stage) % 2 == 1, "playing, from the top \(fromTheTop)")
            bench.store.pauseFilm()
            above.isGeometryFlipped.toggle()
            try await settle(stage)
            #expect(try flips(stage) % 2 == 1)
            window.contentView = nil
        }
    }

    // MARK: Running and stopping

    @Test func theFilmRunsInAWindowWhileItPlaysAndNoLonger() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        // With no window there is no screen to follow.
        store.playFilm(fromStart: true)
        #expect(store.film.playing && !stage.isRunning)
        store.pauseFilm()

        let holder = HolderFromTheTop(frame: bench.canvas.frame)
        holder.addSubview(stage)
        let window = window(holding: holder)
        #expect(stage.window === window && !stage.isRunning)
        store.playFilm(fromStart: true)
        #expect(stage.isRunning)
        var began = try #require(store.film.pass?.began)
        stage.advance(to: began + 0.5)
        #expect(stage.isRunning && abs(store.film.head - 0.5) < 1e-6)
        try check(stage, store, "playing")
        // Paused: the next frame finds it stopped, and is the last.
        store.pauseFilm()
        stage.advance(to: began + 0.6)
        #expect(!stage.isRunning && store.film.time == 0.5)

        // A film that plays once ends its own run.
        bench.step { store.setFilm("Film") { $0.once = true } }
        store.playFilm(fromStart: true)
        #expect(stage.isRunning)
        began = try #require(store.film.pass?.began)
        stage.advance(to: began + 1.9)
        #expect(stage.isRunning)
        stage.advance(to: began + 2.1)
        #expect(!stage.isRunning && !store.film.playing && store.film.time == 2)
        try check(stage, store, "ended")

        // And a look at something ends when it is back.
        store.showFilm(from: 0, to: 0.5, back: 0.25)
        #expect(stage.isRunning)
        began = try #require(store.film.pass?.began)
        stage.advance(to: began + 0.7)
        #expect(stage.isRunning)
        stage.advance(to: began + 1)
        #expect(!stage.isRunning && store.film.time == 0.25)

        // Sought while it plays, likewise.
        store.playFilm(fromStart: true)
        store.seek(1)
        stage.advance(to: CACurrentMediaTime())
        #expect(!stage.isRunning)
        window.contentView = nil
    }

    @Test func leavingItsWindowEndsTheRunAndComingBackTakesItUp() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store
        try await settle(stage)
        let holder = HolderFromTheTop(frame: bench.canvas.frame)
        holder.addSubview(stage)
        let window = window(holding: holder)
        store.playFilm(fromStart: true)
        #expect(stage.isRunning)
        // Its tab goes behind another: out of the window, nothing runs, though the film still plays.
        stage.removeFromSuperview()
        #expect(stage.window == nil && !stage.isRunning && store.film.playing)
        // In front again, it goes on.
        holder.addSubview(stage)
        #expect(stage.isRunning)
        // The whole window's content taken out.
        window.contentView = nil
        #expect(!stage.isRunning)
        // A film set playing while its stage was away runs once the stage shows.
        store.pauseFilm()
        store.playFilm(fromStart: true)
        #expect(!stage.isRunning)
        window.contentView = holder
        #expect(stage.isRunning)
        window.contentView = nil
    }

    @Test func withItsArtboardGoneOrTheModeLeftNothingRuns() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, a = bench.a.id, b = bench.b.id
        try await settle(stage)
        let holder = HolderFromTheTop(frame: bench.canvas.frame)
        holder.addSubview(stage)
        let window = window(holding: holder)
        store.seek(0.4)
        store.playFilm()
        #expect(stage.isRunning)
        // Every artboard taken out of the design, so that there is none for the desk to turn to:
        // the film has stopped, and when the canvas draws next, the stage is put away and the
        // run ends.
        edit(bench) { doc in doc.nodes.removeAll { $0.isArtboard } }
        #expect(store.filmBoard == nil && !store.film.playing && store.film.pass == nil)
        #expect(stage.sync(scale: 2) == nil)
        #expect(!stage.isRunning)
        #expect(store.film.live == store.film.time && store.film.head == store.film.time)
        #expect(try layers(stage).gate.isHidden && layers(stage).pictures.isEmpty)
        // Back, the first of them shows again, at rest at its start.
        bench.undo.undo()
        #expect(store.film.board == a)
        #expect(try await settle(stage) == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(!stage.isRunning && store.filmTime == 0)
        try check(stage, store)

        // When a frame comes first instead, it ends the run itself.
        store.playFilm()
        #expect(stage.isRunning)
        edit(bench) { doc in doc.nodes.removeAll { $0.isArtboard } }
        stage.advance(to: CACurrentMediaTime() + 0.1)
        #expect(!stage.isRunning && !store.film.playing && store.film.live == store.film.time)
        bench.undo.undo()

        // Its own artboard alone taken away: the film stops, and the stage shows the other's.
        try await settle(stage)
        store.playFilm()
        #expect(stage.isRunning)
        edit(bench) { doc in doc.nodes.removeAll { $0.id == a } }
        #expect(store.film.board == b && !store.film.playing)
        #expect(try await settle(stage) == CGRect(x: 600, y: 100, width: 400, height: 300))
        // The run ends with its next frame, which finds the film stopped.
        stage.advance(to: CACurrentMediaTime() + 0.1)
        #expect(!stage.isRunning && !store.film.playing)
        bench.undo.undo()
        store.selection = [a]
        #expect(store.film.board == a)

        // The mode left while it plays.
        try await settle(stage)
        store.playFilm()
        #expect(stage.isRunning)
        store.show(.design)
        #expect(!store.film.playing)
        #expect(stage.sync(scale: 2) == nil && !stage.isRunning)
        window.contentView = nil
    }

    @Test func aFilmPlayingBehindAHiddenStageGoesOnWhenItShows() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        let holder = HolderFromTheTop(frame: bench.canvas.frame)
        holder.addSubview(stage)
        let window = window(holding: holder)
        store.playFilm(fromStart: true)
        #expect(stage.isRunning)
        // An artboard with no size has nothing to show, but is still there: the film still plays.
        edit(bench) { doc in doc.update(a) { $0.frame.size = .zero } }
        #expect(stage.sync(scale: 2) == nil && !stage.isRunning)
        #expect(store.film.playing)
        bench.undo.undo()
        try await settle(stage)
        #expect(stage.isRunning)
        store.pauseFilm()
        window.contentView = nil
    }

    @Test func lettingGoOfTheDesignLetsGoOfItsStage() async throws {
        weak var store: DocumentStore?
        weak var stage: FilmStageView?
        weak var canvas: CanvasView?
        do {
            let (bench, made) = staged(cast(), unseen: true)
            try await settle(made)
            // Having run in a window, and left it while the film played.
            let holder = HolderFromTheTop(frame: bench.canvas.frame)
            holder.addSubview(made)
            let window = window(holding: holder)
            bench.store.playFilm(fromStart: true)
            #expect(made.isRunning)
            made.advance(to: CACurrentMediaTime() + 0.3)
            window.contentView = nil
            made.removeFromSuperview()
            #expect(!made.isRunning)
            store = bench.store
            stage = made
            canvas = bench.canvas
        }
        // What was still on its way back to the main thread has come.
        for _ in 0..<250 where store != nil || stage != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(stage == nil)
        #expect(canvas == nil)
        #expect(store == nil)
    }

    @Test func aDesignLetGoOfWhileItsPicturesAreDrawnIsLetGoOf() async throws {
        weak var store: DocumentStore?
        weak var stage: FilmStageView?
        do {
            let (bench, made) = staged(cast(), zoom: 3, unseen: true)
            #expect(made.sync(scale: 2) == nil && made.isDrawing)
            store = bench.store
            stage = made
        }
        for _ in 0..<250 where store != nil || stage != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(stage == nil)
        #expect(store == nil)
    }

    @Test
    func aCanvasThatHeardOfTheModeChangingIsLetGoOfWithItsDesign() async throws {
        weak var store: DocumentStore?
        weak var canvas: CanvasView?
        do {
            let bench = Bench(extra: cast())
            bench.store.show(.animate)
            bench.store.glide.stop()
            store = bench.store
            canvas = bench.canvas
        }
        for _ in 0..<100 where store != nil || canvas != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(canvas == nil)
        #expect(store == nil)
    }

    // MARK: Edges

    @Test func anArtboardWithNoLayersIsItsGroundAlone() async throws {
        let (bench, stage) = staged([])
        let rect = try await settle(stage)
        #expect(rect == CGRect(x: 100, y: 100, width: 400, height: 300))
        let built = try layers(stage)
        #expect(built.pictures.count == 1 && built.pictures[0].bounds == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(try middle(of: built.pictures[0]) == [255, 255, 255])
        try check(stage, bench.store)
        // Played, there is nothing to draw again.
        bench.store.playFilm(fromStart: true)
        stage.advance(to: CACurrentMediaTime() + 1)
        #expect(!stage.isDrawing && stage.picturesMade == 1)
    }

    @Test func anArtboardWithNoSizeShowsNothingAndComesBackWithOne() async throws {
        let (bench, stage) = staged(cast())
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        for size in [CGSize.zero, CGSize(width: 0, height: 300), CGSize(width: 400, height: 0)] {
            edit(bench) { doc in doc.update(a) { $0.frame.size = size } }
            #expect(stage.sync(scale: 2) == nil, "\(size)")
            #expect(!stage.isDrawing, "\(size)")
            #expect(try layers(stage).gate.isHidden, "\(size)")
            bench.undo.undo()
            #expect(try await settle(stage) == CGRect(x: 100, y: 100, width: 400, height: 300), "\(size)")
            try check(stage, store, "\(size)")
        }
        // Made on one with no size from the first.
        let (other, empty) = staged([])
        let id = other.a.id
        edit(other) { doc in doc.update(id) { $0.frame.size = .zero } }
        #expect(empty.sync(scale: 2) == nil && !empty.isDrawing && empty.picturesMade == 0)
    }

    @Test func aLayerWhollyOutsideTheArtboard() async throws {
        // One that lies there still is cut off with the artboard's edge, as the design shows it:
        // there is nothing of it to draw.
        var comes = box("Comes", CGRect(x: -200, y: 40, width: 80, height: 60), blue)
        comes.setKey(.move, [0, 0], at: 0, ease: .linear)
        comes.setKey(.move, [260, 0], at: 1, ease: .linear)
        let (bench, stage) = staged([box("Away", CGRect(x: 600, y: 500, width: 80, height: 60), red), comes])
        let store = bench.store
        try await settle(stage)
        let built = try layers(stage)
        #expect(try expected(store, at: 0).map(\.piece.kind) == [.ground, .layer])
        #expect(built.pictures.count == 2)
        // One that moves is drawn whole, to come on from out there; the frame cuts it off meanwhile.
        #expect(built.pictures[1].bounds == CGRect(x: -202, y: 38, width: 84, height: 64))
        #expect(built.gate.masksToBounds)
        try check(stage, store, "away")
        store.seek(1)
        _ = stage.sync(scale: 2)
        try check(stage, store, "come")
        #expect(shown(CGPoint(x: -200, y: 40), by: built.pictures[1]) == CGPoint(x: 60, y: 40))
    }

    @Test func aLayerBehindTheEyeIsNotShown() async throws {
        // The camera rests 800 points above a 400 by 300 artboard: lifted further, a layer is behind it.
        var near = box("Near", CGRect(x: 150, y: 100, width: 100, height: 100), blue)
        near.setKey(.lift, [0], at: 0, ease: .linear)
        near.setKey(.lift, [1600], at: 2, ease: .linear)
        let (bench, stage) = staged([near])
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        var layer = try layers(stage).pictures[1]
        #expect(!layer.isHidden)
        store.seek(0.5)
        _ = stage.sync(scale: 2)
        #expect(!layer.isHidden)
        try check(stage, store, "nearer")
        // At the eye and past it.
        for t in [1, 1.2, 2] {
            store.seek(t)
            _ = stage.sync(scale: 2)
            #expect(layer.isHidden, "\(t)")
            let m = layer.transform
            let finite = [m.m11, m.m12, m.m14, m.m21, m.m22, m.m24, m.m41, m.m42, m.m44].allSatisfy { $0.isFinite }
            #expect(finite, "\(t): \(m)")
        }
        // Come back in front of it, it shows again.
        store.seek(0.9)
        _ = stage.sync(scale: 2)
        #expect(!layer.isHidden)

        // Under a steep camera close to the page, the near part of the artboard itself passes
        // behind the eye. What is in front of it still shows, so the ground is not put away.
        edit(bench) { doc in
            doc.update(a) { $0.setKey(.cameraTilt, [78], at: 0); $0.setKey(.cameraZoom, [8], at: 0) }
        }
        store.seek(0)
        try await settle(stage)
        let ground = try layers(stage).pictures[0]
        let map = store.filmBoard!.placement(of: store.filmBoard!.filmPieces()[0], at: 0, camera: store.filmBoard!.camera(at: 0)).map
        #expect(map.depth(at: CGPoint(x: 200, y: 300)) < 0 && map.depth(at: CGPoint(x: 200, y: 150)) > 0)
        #expect(!ground.isHidden)
        layer = ground
        let finite = [layer.transform.m11, layer.transform.m22, layer.transform.m44].allSatisfy { $0.isFinite }
        #expect(finite)
        try check(stage, store, "steep")
    }

    @Test func aVeryLargeArtboardIsDrawnNoLargerThanAPictureMayBe() async throws {
        let (bench, stage) = staged([box("Still", CGRect(x: 4000, y: 3000, width: 900, height: 700), red)])
        let store = bench.store, a = bench.a.id
        edit(bench) { doc in doc.update(a) { $0.frame.size = CGSize(width: 9000, height: 7000) } }
        store.selection = []
        let rect = try await settle(stage)
        #expect(rect == CGRect(x: 100, y: 100, width: 9000, height: 7000))
        let built = try layers(stage)
        #expect(built.pictures.count == 2)
        let ground = try #require(built.pictures[0].contents.map { $0 as! CGImage })
        // Two pixels to the point would be 18000 across: the longest side is as long as a picture may be.
        #expect(ground.width == Int(FilmPictures.most) && ground.height == Int((7000 * FilmPictures.most / 9000).rounded(.up)))
        // It is stretched over the whole artboard all the same, and everything lies where it belongs.
        #expect(built.pictures[0].bounds == CGRect(x: 0, y: 0, width: 9000, height: 7000) && built.pictures[0].contentsGravity == .resize)
        let still = try #require(built.pictures[1].contents.map { $0 as! CGImage })
        #expect(still.width == 904 * 2)
        try check(stage, store)
        // Closer, the ground cannot be drawn sharper, and is not drawn again.
        let made = stage.picturesMade, before = try images(stage)[0]
        store.viewport = Viewport(origin: CGPoint(x: 4000, y: 3000), zoom: 2)
        try await settle(stage)
        #expect(try images(stage)[0] == before)
        #expect(stage.picturesMade == made + 1)
    }

    /// Three hundred layers, every other one moving on its own, so that nearly each is a piece of
    /// its own: how long the pictures take, and how long one pass of placing them. The times are
    /// written to `$TMPDIR/bezzle-stage-timing.txt`.
    @Test func hundredsOfLayersStayQuick() async throws {
        var all: [Node] = []
        for i in 0..<300 {
            var card = box("Card \(i)", CGRect(x: 10 + CGFloat(i % 20) * 19, y: 10 + CGFloat(i / 20) * 19, width: 16, height: 16), [red, blue, green][i % 3])
            card.cornerRadius = 4
            if i % 2 == 0 {
                card.setKey(.move, [0, 0], at: Double(i % 10) * 0.1, ease: .linear)
                card.setKey(.move, [0, -12], at: Double(i % 10) * 0.1 + 0.5, ease: .linear)
                card.setKey(.fade, [0], at: 0)
                card.setKey(.fade, [1], at: 0.5)
            }
            if i % 30 == 0 { card.setKey(.tilt, [50], at: 1) }
            all.append(card)
        }
        let (bench, stage) = staged(all)
        let store = bench.store, a = bench.a.id
        edit(bench) { doc in doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0); $0.setKey(.cameraZoom, [1.4], at: 2); $0.setKey(.cameraTilt, [20], at: 2) } }
        let clock = ContinuousClock()
        var lines: [String] = []

        // The first pass works the pieces out and sends their pictures to be drawn.
        var began = clock.now
        #expect(stage.sync(scale: 2) == nil)
        let asked = clock.now - began
        try await settle(stage)
        let drawn = clock.now - began
        let pieces = try layers(stage).pictures.count
        #expect(pieces == 301 && stage.picturesMade == 301)
        lines.append("\(pieces) pieces: asked for in \(asked), all drawn after \(drawn)")

        // Placing them at another moment, as each frame of the screen does while it plays.
        var passes: [Duration] = []
        for k in 1...60 {
            store.seek(Double(k) / 30)
            began = clock.now
            _ = stage.sync(scale: 2)
            passes.append(clock.now - began)
        }
        #expect(!stage.isDrawing && stage.picturesMade == 301)
        try check(stage, store)
        passes.sort()
        lines.append("a pass of placing them: median \(passes[30]), slowest \(passes[59])")

        store.playFilm(fromStart: true)
        let start = try #require(store.film.pass?.began)
        var frames: [Duration] = []
        for k in 0..<120 {
            began = clock.now
            stage.advance(to: start + Double(k) / 60)
            frames.append(clock.now - began)
        }
        store.pauseFilm()
        frames.sort()
        lines.append("a frame while it plays: median \(frames[60]), slowest \(frames[119])")

        // One layer posed anew: the pieces are worked out again, and no picture is drawn.
        let card = bench.node("Card 4")!.id
        edit(bench) { doc in doc.update(card) { $0.setKey(.move, [5, 5], at: 1.5) } }
        began = clock.now
        _ = stage.sync(scale: 2)
        let posed = clock.now - began
        #expect(!stage.isDrawing && stage.picturesMade == 301)
        lines.append("after posing one layer: \(posed)")

        // One piece among them whose insides move is drawn again as the film plays; the others
        // are not looked at for it.
        var inner = box("Inner", CGRect(x: 0, y: 0, width: 10, height: 10), green)
        inner.setKey(.move, [0, 0], at: 0, ease: .linear)
        inner.setKey(.move, [30, 0], at: 2, ease: .linear)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 10, y: 286, width: 40, height: 10))
        group.opacity = 0.8
        group.children = [inner]
        edit(bench) { doc in doc.update(a) { $0.children.append(group) } }
        try await settle(stage)
        #expect(try layers(stage).pictures.count == 302)
        let before = stage.picturesMade
        store.playFilm(fromStart: true)
        let restart = try #require(store.film.pass?.began)
        var redrawn: [Duration] = []
        for k in 0..<120 {
            began = clock.now
            stage.advance(to: restart + Double(k) / 60)
            redrawn.append(clock.now - began)
            // Its picture comes back by way of the main thread.
            if k % 4 == 3 { try await Task.sleep(for: .milliseconds(1)) }
        }
        store.pauseFilm()
        while stage.isDrawing { try await Task.sleep(for: .milliseconds(2)) }
        redrawn.sort()
        let again = stage.picturesMade - before
        lines.append("a frame while one piece is drawn again as it plays: median \(redrawn[60]), slowest \(redrawn[119]); \(again) pictures in 120 frames")
        #expect(again >= 10 && again <= 120, "\(lines)")
        #expect(redrawn[60] < .milliseconds(60), "\(lines)")

        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-stage-timing.txt"), atomically: true, encoding: .utf8)
        // Generous: the tests are built without the compiler's speeding up, which makes this
        // arithmetic some ten times slower than in the app, and other work goes on beside them.
        #expect(passes[30] < .milliseconds(60), "\(lines)")
        #expect(frames[60] < .milliseconds(60), "\(lines)")
        #expect(posed < .seconds(2), "\(lines)")
        #expect(drawn < .seconds(20), "\(lines)")
    }
}
