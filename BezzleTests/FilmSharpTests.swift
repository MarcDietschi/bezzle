import Testing
import AppKit
@testable import Bezzle

/// A film stays as sharp as the design it is made of, however near the camera or the view goes:
/// what shows larger than a piece's whole picture holds is drawn again, only the part that is
/// seen, as sharp as it is seen (`FilmMap.seen`, `FilmPictures.Part`, the stage's parts and the
/// movie's). And nothing of a layer is cut off at the artboard's edge once the camera sees past
/// it, its shadow least of all.
@MainActor
struct FilmSharpTests {
    private let red = RGBA(r: 0.9, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.3, b: 0.8)

    private func box(_ name: String, _ frame: CGRect, _ color: RGBA) -> Node {
        var box = Node(kind: .rectangle, name: name, frame: frame)
        box.fill.color = color
        return box
    }

    /// A white card with a wide soft shadow.
    private func card(_ frame: CGRect) -> Node {
        var card = box("Card", frame, RGBA(r: 1, g: 1, b: 1))
        card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.3), x: 0, y: 24, blur: 48)
        return card
    }

    private func board(_ size: CGSize, _ layers: [Node], fill: String = "E9E7E2") -> Node {
        var board = Node(kind: .artboard, name: "Board", frame: CGRect(origin: .zero, size: size))
        board.fill.color = RGBA(hex: fill)!
        board.children = layers
        return board
    }

    /// A picture's pixels, a row after another from the top, four bytes each.
    private struct Pixels {
        let width: Int, height: Int, row: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            let ctx = Renderer.bitmap(CGSize(width: image.width, height: image.height))!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            width = image.width
            height = image.height
            row = ctx.bytesPerRow
            bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * image.height))
        }

        subscript(x: Int, y: Int) -> [Int] {
            let at = min(max(y, 0), height - 1) * row + min(max(x, 0), width - 1) * 4
            return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3])]
        }
    }

    /// The pixel of a piece's picture at a point of the artboard.
    private func pixel(_ picture: FilmPictures.Picture, _ pixels: Pixels, at p: CGPoint) -> [Int] {
        let kx = CGFloat(pixels.width) / picture.rect.width, ky = CGFloat(pixels.height) / picture.rect.height
        return pixels[Int((p.x - picture.rect.minX) * kx), Int((p.y - picture.rect.minY) * ky)]
    }

    // MARK: What shows, and how large

    @Test func whatShowsOfAPieceThroughAWindowIsFoundWithHowLargeItShows() throws {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600), window = rect
        // As it lies: all of it, as large as drawn.
        var seen = try #require(FilmMap.identity.seen(of: rect, through: window))
        #expect(seen.part == rect && abs(seen.stretch - 1) < 1e-9)
        // Through a smaller window, that much of it.
        seen = try #require(FilmMap.identity.seen(of: rect, through: CGRect(x: 100, y: 50, width: 200, height: 120)))
        #expect(seen.part == CGRect(x: 100, y: 50, width: 200, height: 120))
        // Four times larger about its middle: the middle quarter each way, four times as large.
        let close = FilmMap(a: 4, c: -1200, e: 4, f: -900)
        seen = try #require(close.seen(of: rect, through: window))
        #expect(abs(seen.part.minX - 300) < 1e-9 && abs(seen.part.minY - 225) < 1e-9 && abs(seen.part.width - 200) < 1e-9 && abs(seen.part.height - 150) < 1e-9)
        #expect(abs(seen.stretch - 4) < 1e-9)
        // A piece that covers only some of what shows: no more than itself.
        seen = try #require(close.seen(of: CGRect(x: 380, y: 280, width: 500, height: 40), through: window))
        #expect(abs(seen.part.minX - 380) < 1e-9 && abs(seen.part.maxX - 500) < 1e-9 && abs(seen.part.minY - 280) < 1e-9 && abs(seen.part.height - 40) < 1e-9)
        // Out of sight, nothing; and nothing of nothing.
        #expect(close.seen(of: CGRect(x: 0, y: 0, width: 100, height: 100), through: window) == nil)
        #expect(FilmMap.identity.seen(of: CGRect(x: 900, y: 0, width: 50, height: 50), through: window) == nil)
        #expect(FilmMap.identity.seen(of: .zero, through: window) == nil && FilmMap.identity.seen(of: rect, through: .zero) == nil)
        // Smaller than drawn, it shows as small.
        seen = try #require(FilmMap(a: 0.5, c: 200, e: 0.5, f: 150).seen(of: rect, through: window))
        #expect(seen.part == rect && abs(seen.stretch - 0.5) < 1e-9)
    }

    @Test func inPerspectiveOnlyWhatLiesInFrontAndInTheFrameCounts() throws {
        let size = CGSize(width: 800, height: 600), rect = CGRect(origin: .zero, size: size)
        // A camera tipped steeply and close: the near edge of the sheet passes behind the eye.
        var board = self.board(size, [])
        board.setKey(.cameraTilt, [78], at: 0)
        board.setKey(.cameraZoom, [8], at: 0)
        let map = board.placement(of: board.filmPieces()[0], at: 0, camera: board.camera(at: 0)).map
        #expect(!map.isFlat)
        let seen = try #require(map.seen(of: rect, through: rect))
        #expect(rect.contains(seen.part) && seen.part.width > 0 && seen.part.height > 0 && seen.stretch.isFinite)
        // Every corner of the part that lies in front shows in the frame or on its edge, or
        // the part reaches no further than the cut along the frame's sides made it.
        let corners = [CGPoint(x: seen.part.minX, y: seen.part.minY), CGPoint(x: seen.part.maxX, y: seen.part.maxY)]
        #expect(corners.contains { map.depth(at: $0) > 1e-3 })
        // What shows in the frame's middle lies in the part.
        let middle = try #require(map.back(CGPoint(x: 400, y: 300)))
        #expect(seen.part.insetBy(dx: -0.01, dy: -0.01).contains(middle))
        // And is at least as large there as the part is said to show at most.
        #expect(map.stretch(at: middle) <= seen.stretch + 1e-6)
        // Swung gently, nothing behind the eye: the part is what the frame's corners reach back to.
        var gentle = self.board(size, [])
        gentle.setKey(.cameraSwing, [25], at: 0)
        gentle.setKey(.cameraZoom, [3], at: 0)
        let turned = gentle.placement(of: gentle.filmPieces()[0], at: 0, camera: gentle.camera(at: 0)).map
        let part = try #require(turned.seen(of: rect, through: rect)).part
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 0), CGPoint(x: 800, y: 600), CGPoint(x: 0, y: 600)] {
            if let back = turned.back(corner), rect.contains(back) { #expect(part.insetBy(dx: -0.01, dy: -0.01).contains(back)) }
        }
        #expect(part.width < 800 && part.height < 600)
    }

    // MARK: A part to draw

    @Test func aPartIsWhatIsSeenWithRoomRoundItOnItsOwnPixelsAndNoLargerThanItMayBe() throws {
        let whole = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let seen = CGRect(x: 600.3, y: 400.7, width: 180, height: 112.5)
        let part = try #require(FilmPictures.part(for: seen, of: whole, need: 16))
        // As sharp as needed, by no more than a step.
        #expect(part.scale >= 16 && part.scale <= 16 * 1.2)
        #expect(part.rect.contains(seen))
        // On whole pixels of its own.
        for v in [part.rect.minX, part.rect.minY, part.rect.width, part.rect.height] {
            #expect(abs(v * part.scale - (v * part.scale).rounded()) < 1e-6)
        }
        // With room round it, kept within the piece.
        let roomy = try #require(FilmPictures.part(for: seen, of: whole, need: 16, margin: 0.1, around: 2))
        #expect(roomy.rect.minX <= seen.minX - 19.9 && roomy.rect.maxX >= seen.maxX + 19.9 && roomy.rect.minY <= seen.minY - 13.2)
        let edge = try #require(FilmPictures.part(for: CGRect(x: 0, y: 0, width: 100, height: 100), of: whole, need: 4, margin: 0.5))
        #expect(edge.rect.minX == 0 && edge.rect.minY == 0 && edge.rect.maxX >= 150)
        // The steps: a need a little over one is drawn at the next, the same one for all needs up to it.
        let a = try #require(FilmPictures.part(for: seen, of: whole, need: 8.1)), b = try #require(FilmPictures.part(for: seen, of: whole, need: 9.4))
        #expect(a.scale == b.scale && a.scale >= 9.4)
        // Never more than a part may hold: its side and its pixels in all.
        let huge = try #require(FilmPictures.part(for: whole, of: whole, need: 200))
        #expect(huge.rect.width * huge.scale <= FilmPictures.mostInPart.side + 1 && huge.rect.width * huge.rect.height * huge.scale * huge.scale <= FilmPictures.mostInPart.pixels * 1.001)
        #expect(huge.scale < 200)
        // Nothing to draw of nothing.
        #expect(FilmPictures.part(for: CGRect(x: 2000, y: 0, width: 10, height: 10), of: whole, need: 2) == nil)
        #expect(FilmPictures.part(for: seen, of: whole, need: 0) == nil && FilmPictures.part(for: seen, of: whole, need: .infinity) == nil)
    }

    @Test func aPartDrawnIsTheSamePictureAsThatPartOfTheWholeDrawnAsSharp() throws {
        var label = Node(kind: .text, name: "Label", frame: CGRect(x: 300, y: 215, width: 0, height: 0))
        label.text = "Sharp as a pin"
        label.style = TextStyle(family: TextStyle.system, face: "Bold", size: 22)
        label.refit()
        let board = self.board(CGSize(width: 800, height: 600), [card(CGRect(x: 250, y: 200, width: 300, height: 100)), label])
        let piece = try #require(board.filmPieces().last)
        let subject = FilmPictures.subject(of: piece, on: board, at: 0)
        let whole = try #require(FilmPictures.picture(of: subject, scale: 4, assets: nil))
        #expect(abs(FilmPictures.sharpness(of: whole) - 4) < 0.05)
        // A part across the card's corner, its words and its shadow.
        let part = try #require(FilmPictures.part(for: CGRect(x: 240, y: 190, width: 140, height: 150), of: FilmPictures.rect(of: subject), need: 4))
        #expect(part.scale == 4)
        let drawn = try #require(FilmPictures.picture(of: subject, scale: part.scale, assets: nil, part: part))
        #expect(drawn.rect == part.rect && drawn.image.width == Int(part.rect.width * 4) && drawn.image.height == Int(part.rect.height * 4))
        let a = Pixels(whole.image), b = Pixels(drawn.image)
        var worst = 0, differing = 0
        for y in stride(from: 0, to: b.height, by: 3) {
            for x in stride(from: 0, to: b.width, by: 3) {
                let p = CGPoint(x: part.rect.minX + (CGFloat(x) + 0.5) / 4, y: part.rect.minY + (CGFloat(y) + 0.5) / 4)
                let one = pixel(whole, a, at: p), other = b[x, y]
                let d = zip(one, other).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, d)
                if d > 3 { differing += 1 }
            }
        }
        // But for a pixel here and there along a letter's edge, the same picture.
        #expect(differing <= 4 && worst <= 40, "\(differing) pixels differ, the worst by \(worst)")
        // The card and its shadow are in it.
        #expect(b[Int((300 - part.rect.minX) * 4), Int((250 - part.rect.minY) * 4)][3] == 255)
        #expect(b[Int((300 - part.rect.minX) * 4), Int((320 - part.rect.minY) * 4)][3] > 20)
    }

    // MARK: Past the artboard's edge

    @Test func aShadowThatFallsPastTheArtboardsEdgeIsInTheFilm() throws {
        // A sheet as large as the artboard, with a shadow: all of the shadow lies outside.
        let size = CGSize(width: 800, height: 600)
        var board = self.board(size, [card(CGRect(origin: .zero, size: size))])
        let piece = try #require(board.filmPieces().last)
        #expect(piece.kind == .run)
        let subject = FilmPictures.subject(of: piece, on: board, at: 0)
        let core = FilmPictures.core(of: subject)
        #expect(core.minX < -40 && core.maxX > 840 && core.maxY > 600 + 24 + 40 && core == FilmPictures.rect(of: subject))
        let picture = try #require(FilmPictures.picture(of: subject, scale: 1, assets: nil))
        #expect(picture.rect == core)
        let pixels = Pixels(picture.image)
        #expect(pixel(picture, pixels, at: CGPoint(x: 400, y: 300))[3] == 255)
        #expect(pixel(picture, pixels, at: CGPoint(x: 400, y: 620))[3] > 30)
        #expect(pixel(picture, pixels, at: CGPoint(x: 400, y: 660))[3] > 0)
        // The artboard's own sheet ends at its edge, as ever.
        let ground = FilmPictures.subject(of: board.filmPieces()[0], on: board, at: 0)
        #expect(FilmPictures.rect(of: ground) == CGRect(origin: .zero, size: size) && FilmPictures.core(of: ground) == FilmPictures.rect(of: ground))

        // In the movie, with the camera drawn back: the shadow shows under the sheet, on the backdrop.
        board.setKey(.cameraZoom, [0.5], at: 0)
        board.film = Film(backdrop: RGBA(hex: "E9E7E2")!)
        let frame = try #require(FilmExport.frame(of: board, at: 0, size: size, assets: nil))
        let shown = Pixels(frame)
        // The sheet shows from 200 to 600 across and 150 to 450 down.
        #expect(shown[400, 300] == [255, 255, 255, 255])
        let backdrop = shown[20, 20], under = shown[400, 462]
        #expect(backdrop[0] > 225 && under[0] < backdrop[0] - 10, "\(under) under the sheet, \(backdrop) far from it")
        // At rest the frame is the artboard, and shows none of it.
        board.setKey(.cameraZoom, [1], at: 0)
        let still = Pixels(try #require(FilmExport.frame(of: board, at: 0, size: size, assets: nil)))
        #expect(still[400, 590] == [255, 255, 255, 255] && still[5, 5] == [255, 255, 255, 255])
    }

    @Test func whatLiesFarOutsideTheArtboardIsNotInTheWholePictureButIsStillThePieces() throws {
        let size = CGSize(width: 400, height: 300)
        let near = box("Near", CGRect(x: 50, y: 50, width: 100, height: 60), red)
        let far = box("Far", CGRect(x: 1500, y: 100, width: 80, height: 80), blue)
        let board = self.board(size, [near, far])
        let run = try #require(board.filmPieces().last)
        let subject = FilmPictures.subject(of: run, on: board, at: 0)
        let reach = FilmPictures.rect(of: subject), core = FilmPictures.core(of: subject)
        #expect(reach.maxX > 1580 && core.maxX <= 400 + 100 + 1 && core.minX == reach.minX)
        // Its whole picture is of what is near, as sharp as asked, and not thinned out by the gap.
        let whole = try #require(FilmPictures.picture(of: subject, scale: 4, assets: nil))
        #expect(whole.rect == core && abs(FilmPictures.sharpness(of: whole) - 4) < 0.1)
        // The far layer is drawn as a part.
        let part = try #require(FilmPictures.part(for: CGRect(x: 1490, y: 90, width: 100, height: 100), of: reach, need: 2))
        let drawn = try #require(FilmPictures.picture(of: subject, scale: part.scale, assets: nil, part: part))
        let pixels = Pixels(drawn.image)
        let middle = pixel(drawn, pixels, at: CGPoint(x: 1540, y: 140))
        #expect(middle[3] == 255 && middle[2] > middle[0])
        // With nothing of it near the artboard, a run's whole picture is of where it is.
        let lone = self.board(size, [far])
        let alone = FilmPictures.subject(of: try #require(lone.filmPieces().last), on: lone, at: 0)
        #expect(FilmPictures.core(of: alone) == FilmPictures.rect(of: alone) && FilmPictures.core(of: alone).minX > 1400)
    }

    // MARK: On the stage

    /// A bench with these layers on artboard A (400 by 300 at 100, 100), in Animate, and its
    /// stage as large as the canvas.
    private func staged(_ layers: [Node], zoom: CGFloat = 1, origin: CGPoint = .zero) -> (bench: Bench, stage: FilmStageView) {
        let bench = Bench(extra: layers)
        bench.store.show(.animate)
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: origin, zoom: zoom)
        let stage = bench.canvas.filmStage
        stage.frame = bench.canvas.frame
        stage.layout()
        return (bench, stage)
    }

    /// Brings the stage to the design as the canvas does when it draws, until everything it
    /// asked for has been drawn: the pieces' pictures, and the parts drawn sharper.
    @discardableResult
    private func settle(_ stage: FilmStageView, scale: CGFloat = 2) async throws -> CGRect? {
        let clock = ContinuousClock(), began = clock.now
        while true {
            let rect = stage.sync(scale: scale)
            guard stage.isDrawing else { return rect }
            while stage.isDrawing {
                guard clock.now - began < .seconds(60) else {
                    Issue.record("The stage's pictures were not drawn within a minute.")
                    return rect
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// A piece on the stage: its whole picture's layer, and the part over it, if any.
    private struct Staged {
        var whole: CALayer
        var over: CALayer?
    }

    private func staged(on stage: FilmStageView) throws -> [Staged] {
        let content = try #require(stage.layer?.sublayers?.first)
        let scene = try #require(content.sublayers?.first?.sublayers?.first)
        var all: [Staged] = []
        for layer in scene.sublayers ?? [] {
            if layer.name == FilmStageView.partName {
                #expect(!all.isEmpty && all[all.count - 1].over == nil)
                if !all.isEmpty { all[all.count - 1].over = layer }
            } else {
                all.append(Staged(whole: layer, over: nil))
            }
        }
        return all
    }

    /// How many pixels to the point a layer's picture has.
    private func sharpness(_ layer: CALayer) throws -> CGFloat {
        let image = try #require(layer.contents.map { $0 as! CGImage })
        return CGFloat(image.width) / layer.bounds.width
    }

    /// Where a layer has a point of the artboard, in the scene: its transform as Core Animation applies it.
    private func shown(_ p: CGPoint, by layer: CALayer) -> CGPoint {
        let m = layer.transform
        let x = p.x - layer.bounds.minX, y = p.y - layer.bounds.minY
        let w = x * m.m14 + y * m.m24 + m.m44
        return CGPoint(x: (x * m.m11 + y * m.m21 + m.m41) / w, y: (x * m.m12 + y * m.m22 + m.m42) / w)
    }

    private func edit(_ bench: Bench, _ change: (inout BezzleDocument) -> Void) {
        bench.step { bench.store.edit("Change", change) }
    }

    /// What the film shows of each piece through the whole frame now, and how sharp that has to be on a screen of two pixels to the point.
    private func seen(_ store: DocumentStore, window: CGRect? = nil, pixels: CGFloat = 2) throws -> [(part: CGRect, need: CGFloat)?] {
        let board = try #require(store.filmBoard)
        let camera = board.camera(at: store.filmTime)
        return board.filmPieces(loose: Set(store.posedLayers)).map { piece in
            let subject = FilmPictures.subject(of: piece, on: board, at: store.filmTime)
            let map = board.placement(of: piece, at: store.filmTime, camera: camera).map
            return map.seen(of: FilmPictures.rect(of: subject), through: window ?? CGRect(origin: .zero, size: board.frame.size))
                .map { ($0.part, CGFloat($0.stretch) * pixels) }
        }
    }

    @Test func withTheCameraCloseWhatShowsIsDrawnAsSharpAsItShows() async throws {
        let (bench, stage) = staged([box("Fine", CGRect(x: 180, y: 130, width: 40, height: 40), red)])
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        // At rest the whole pictures do: nothing more is drawn.
        var pieces = try staged(on: stage)
        #expect(pieces.count == 2 && pieces.allSatisfy { $0.over == nil && $0.whole.mask == nil } && stage.partsMade == 0)

        // Eight times closer: sixteen pixels to the point on this screen, more than a whole picture holds.
        edit(bench) { doc in doc.update(a) { $0.setKey(.cameraZoom, [8], at: 0) } }
        try await settle(stage)
        pieces = try staged(on: stage)
        var want = try seen(store)
        #expect(pieces.count == 2 && stage.partsMade == 2)
        for (piece, wanted) in zip(pieces, want) {
            let wanted = try #require(wanted), over = try #require(piece.over)
            #expect(abs(wanted.need - 16) < 1e-6)
            // The whole picture is not that sharp, the part is, and covers all that shows, with room.
            #expect(try sharpness(piece.whole) < 16 && sharpness(over) >= 16 && sharpness(over) <= 16 * 1.2)
            #expect(over.bounds.contains(wanted.part) && over.bounds.width < 200)
            // It lies where its piece does: any point of it shows where the whole picture has it.
            for p in [CGPoint(x: wanted.part.minX, y: wanted.part.minY), CGPoint(x: wanted.part.midX, y: wanted.part.maxY)] {
                let one = shown(p, by: piece.whole), other = shown(p, by: over)
                #expect(abs(one.x - other.x) < 1e-6 && abs(one.y - other.y) < 1e-6)
            }
            #expect(over.opacity == piece.whole.opacity)
            // The whole picture gives way under it.
            let mask = try #require(piece.whole.mask as? CAShapeLayer)
            #expect(mask.fillRule == .evenOdd && mask.bounds == piece.whole.bounds && mask.position == piece.whole.bounds.origin)
            #expect(mask.path?.contains(CGPoint(x: wanted.part.midX, y: wanted.part.midY), using: .evenOdd) == false)
        }
        // Brought to the design again with nothing changed, nothing more is drawn.
        let made = stage.partsMade
        _ = stage.sync(scale: 2)
        _ = stage.sync(scale: 2)
        #expect(!stage.isDrawing && stage.partsMade == made)

        // Looking elsewhere, as close: the part that shows there.
        edit(bench) { doc in doc.update(a) { $0.setKey(.cameraMove, [120, -80], at: 0) } }
        try await settle(stage)
        pieces = try staged(on: stage)
        want = try seen(store)
        let ground = try #require(want[0]), over = try #require(pieces[0].over)
        #expect(over.bounds.contains(ground.part) && stage.partsMade > made)
        #expect(try sharpness(over) >= 16)
        // The little box is out of sight there, and has no part.
        #expect(want[1] == nil && pieces[1].over == nil && pieces[1].whole.mask == nil)

        // Back at rest, the parts are taken off again and let go.
        edit(bench) { doc in doc.update(a) { $0.motion = nil } }
        try await settle(stage)
        pieces = try staged(on: stage)
        #expect(pieces.count == 2 && pieces.allSatisfy { $0.over == nil && $0.whole.mask == nil })
    }

    @Test func aCameraPosedByADragLeavesItsFilmSharpWhileItIsDraggedAndAfter() async throws {
        let (bench, stage) = staged([box("Fine", CGRect(x: 180, y: 130, width: 40, height: 40), red)])
        let store = bench.store, a = bench.a.id
        try await settle(stage)
        var pieces = try staged(on: stage)
        #expect(try sharpness(pieces[0].whole) == 2 && pieces[0].over == nil)
        // A drag that brings the camera three times closer, step by step.
        bench.undo.beginUndoGrouping()
        store.beginGesture()
        for zoom in [1.5, 2, 2.5, 3] { store.edit("Camera") { doc in doc.update(a) { $0.setKey(.cameraZoom, [zoom], at: 0) } } }
        try await settle(stage)
        pieces = try staged(on: stage)
        // While it is dragged the whole pictures are left as they are, and what shows is drawn
        // sharper over them: six pixels to the point.
        #expect(try sharpness(pieces[0].whole) == 2)
        #expect(try sharpness(try #require(pieces[0].over)) >= 6)
        store.endGesture("Camera")
        bench.undo.endUndoGrouping()
        try await settle(stage)
        pieces = try staged(on: stage)
        // Let go, the whole pictures are drawn as sharp as the film shows them at its closest,
        // and no part is needed over them.
        #expect(try sharpness(pieces[0].whole) >= 6)
        #expect(pieces[0].over == nil && pieces[0].whole.mask == nil)
    }

    @Test func withTheViewCloseOnlyWhatIsInTheViewIsDrawnSharper() async throws {
        // Ten times closer in the view: twenty pixels to the point, and the artboard forty
        // times the view's breadth in pixels.
        let (bench, stage) = staged([box("Fine", CGRect(x: 60, y: 30, width: 40, height: 40), red)], zoom: 10, origin: CGPoint(x: 250, y: 200))
        let rect = try await settle(stage)
        #expect(rect == CGRect(x: -1500, y: -1000, width: 4000, height: 3000))
        let pieces = try staged(on: stage)
        #expect(pieces.count == 2)
        // The view shows the artboard from 150 to 270 across and 100 to 180 down.
        let window = CGRect(x: 150, y: 100, width: bench.canvas.frame.width / 10, height: bench.canvas.frame.height / 10)
        let over = try #require(pieces[0].over)
        #expect(try sharpness(pieces[0].whole) < 20 && sharpness(over) >= 20)
        #expect(over.bounds.contains(window) && over.bounds.width <= window.width * 1.25 && over.bounds.height <= window.height * 1.25)
        // The box lies outside the view: nothing of it is drawn again.
        #expect(pieces[1].over == nil && stage.partsMade == 1)
        // Scrolled a little, within the room round the part: nothing is drawn again.
        bench.store.viewport = Viewport(origin: CGPoint(x: 254, y: 203), zoom: 10)
        try await settle(stage)
        #expect(stage.partsMade == 1)
        // Scrolled far: the part there.
        bench.store.viewport = Viewport(origin: CGPoint(x: 120, y: 110), zoom: 10)
        try await settle(stage)
        let moved = try staged(on: stage)
        #expect(stage.partsMade > 1)
        #expect(try #require(moved[0].over).bounds.contains(CGRect(x: 20, y: 10, width: window.width, height: window.height)))
        // The box is in the view now. Small as it is, its whole picture is sharp enough, and no
        // part of it is drawn.
        #expect(try sharpness(moved[1].whole) >= 20 && moved[1].over == nil)
    }

    @Test func whatLiesFarOutsideTheArtboardShowsOnceTheCameraSeesIt() async throws {
        let near = box("Near", CGRect(x: 50, y: 50, width: 100, height: 60), red)
        let far = box("Far", CGRect(x: 1500, y: 100, width: 80, height: 80), blue)
        let (bench, stage) = staged([near, far])
        let a = bench.a.id
        try await settle(stage)
        var pieces = try staged(on: stage)
        // At rest the whole picture holds what is near, and that is all that shows.
        #expect(pieces.count == 2 && pieces[1].over == nil && pieces[1].whole.bounds.maxX <= 501 && stage.partsMade == 0)
        // Drawn back as far as it goes: the frame shows 4000 by 3000 about the middle.
        edit(bench) { doc in doc.update(a) { $0.setKey(.cameraZoom, [0.1], at: 0) } }
        try await settle(stage)
        pieces = try staged(on: stage)
        let over = try #require(pieces[1].over)
        #expect(over.bounds.contains(CGRect(x: 1500, y: 100, width: 80, height: 80)) && over.bounds.contains(CGRect(x: 50, y: 50, width: 100, height: 60)))
        // No sharper than it shows, which is small.
        #expect(try sharpness(over) >= 0.2 && sharpness(over) < 0.5)
        let image = try #require(over.contents.map { $0 as! CGImage })
        let pixels = Pixels(image)
        let k = CGFloat(image.width) / over.bounds.width
        let middle = pixels[Int((1540 - over.bounds.minX) * k), Int((140 - over.bounds.minY) * k)]
        #expect(middle[3] > 200 && middle[2] > middle[0])
    }

    @Test func aFilmThatPlaysIsDrawnSharperForWhereItIsGoing() async throws {
        let (bench, stage) = staged([box("Fine", CGRect(x: 180, y: 130, width: 40, height: 40), red)])
        let store = bench.store, a = bench.a.id
        edit(bench) { doc in
            doc.update(a) { $0.setKey(.cameraZoom, [1], at: 0, ease: .linear); $0.setKey(.cameraZoom, [12], at: 1, ease: .linear) }
            doc.update(a) { $0.film = Film(length: 1, once: true) }
        }
        store.seek(0)
        try await settle(stage)
        #expect(stage.partsMade == 0)
        store.playFilm(fromStart: true)
        let began = try #require(store.film.pass?.began)
        // Frame by frame to nine tenths of a second, letting each part be drawn as it would be meanwhile.
        for frame in 1...54 {
            stage.advance(to: began + Double(frame) / 60)
            while stage.isDrawing { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(store.film.playing && abs(store.film.head - 0.9) < 1e-6)
        stage.advance(to: began + 0.9)
        let pieces = try staged(on: stage)
        let board = try #require(store.filmBoard)
        let map = board.placement(of: board.filmPieces()[0], at: 0.9, camera: board.camera(at: 0.9)).map
        let now = try #require(map.seen(of: CGRect(x: 0, y: 0, width: 400, height: 300), through: CGRect(x: 0, y: 0, width: 400, height: 300)))
        let over = try #require(pieces[0].over)
        // What shows is covered, close to as sharp as it shows: drawn ahead, not behind.
        #expect(over.bounds.insetBy(dx: -0.01, dy: -0.01).contains(now.part))
        let sharp = try sharpness(over)
        #expect(sharp >= CGFloat(now.stretch) * 2 * 0.85, "\(sharp) for \(now.stretch * 2)")
        #expect(stage.partsMade >= 2)
        store.pauseFilm()
    }

    // MARK: In the movie

    @Test func aFrameOfTheMovieIsSharpHoweverCloseTheCamera() throws {
        // A black box whose edge runs down the middle of a white artboard, and the camera
        // twelve times closer: a whole picture of the artboard could hold a sixth of that.
        let size = CGSize(width: 1500, height: 1000)
        var board = self.board(size, [box("Edge", CGRect(x: 750.3, y: 0, width: 400, height: 1000), RGBA(r: 0, g: 0, b: 0))], fill: "FFFFFF")
        board.setKey(.cameraZoom, [12], at: 0)
        let frame = try #require(FilmExport.frame(of: board, at: 0, size: CGSize(width: 3000, height: 2000), assets: nil))
        let pixels = Pixels(frame)
        // The edge shows at 1500 + 0.3 × 24 pixels across. Left of it white, right of it black,
        // and between them no more than the one pixel the edge runs through.
        var soft = 0
        for x in 1480...1540 {
            let v = pixels[x, 1000][0]
            if v > 12 && v < 243 { soft += 1 }
        }
        #expect(pixels[1490, 1000][0] > 250 && pixels[1525, 1000][0] < 5)
        #expect(soft <= 2, "\(soft) pixels between white and black")
        // And where it shows is right to the pixel.
        #expect(pixels[1505, 1000][0] > 240 && pixels[1509, 1000][0] < 15)
    }

    @Test func aMovieOfACameraGoingInIsSharpInEveryFrame() async throws {
        let size = CGSize(width: 800, height: 600)
        var board = self.board(size, [box("Edge", CGRect(x: 400.25, y: 0, width: 300, height: 600), RGBA(r: 0, g: 0, b: 0))], fill: "FFFFFF")
        board.setKey(.cameraZoom, [1], at: 0, ease: .linear)
        board.setKey(.cameraZoom, [24], at: 1, ease: .linear)
        board.film = Film(length: 1, once: true)
        // Frame by frame as the movie makes them, at one pixel to the point.
        for t in [0, 0.25, 0.5, 0.75, 1.0] {
            let frame = try #require(FilmExport.frame(of: board, at: t, size: size, assets: nil))
            let pixels = Pixels(frame)
            let zoom = board.camera(at: t).zoom
            let edge = 400 + 0.25 * zoom
            var soft = 0
            for x in Int(edge) - 12...Int(edge) + 12 {
                let v = pixels[x, 300][0]
                if v > 12 && v < 243 { soft += 1 }
            }
            #expect(soft <= 2, "at \(t), \(zoom) times closer: \(soft) pixels between white and black")
            #expect(pixels[Int(edge) - 6, 300][0] > 250 && pixels[Int(edge) + 6, 300][0] < 5, "at \(t)")
        }
        // And written as a movie, with parts drawn ahead for several frames at once, it is whole.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("film-sharp-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await FilmExport.write(board, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 30)) { _ in }
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(bytes > 1000)
    }

    // MARK: A design's own film

    /// How a design's own film plays on the stage, in real time: how long a frame keeps the
    /// main thread, how many parts are drawn sharper, and how far what shows falls short of as
    /// sharp as it shows. Once at a pixel to the point and once at two. Run with
    /// `TEST_RUNNER_ANIMATE_FILM_DESIGN=<a design>` before `xcodebuild`; the answer is written
    /// to `$TMPDIR/bezzle-film-stage.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_FILM_DESIGN"] != nil))
    func timesADesignsFilmOnTheStage() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ANIMATE_FILM_DESIGN"]))
        let doc = try DesignFile.read(url)
        let first = try #require(doc.nodes.first { $0.isArtboard && !$0.hidden })
        var lines: [String] = []
        // The stage takes two pixels to the point with no window: half the zoom is a screen of one.
        for zoom in [0.5, 1.0] as [CGFloat] {
            let store = DocumentStore(url: url, document: doc)
            let canvas = CanvasView(store: store)
            canvas.wantsLayer = false
            canvas.frame = NSRect(x: 0, y: 0, width: 2240 * zoom, height: 1240 * zoom)
            store.canvas = canvas
            store.viewport = Viewport(origin: CGPoint(x: first.frame.midX - 1120, y: first.frame.midY - 620), zoom: zoom)
            store.selection = [first.id]
            store.show(.animate)
            store.glide.stop()
            let stage = canvas.filmStage
            stage.frame = canvas.frame
            stage.layout()
            store.seek(0)
            try await settle(stage)
            let board = try #require(store.filmBoard)
            let length = min(board.filmLength, 4)
            let atRest = stage.partsMade
            let lensBefore = (frames: stage.lensFrames, spent: stage.lensSpent)
            store.playFilm(fromStart: true)
            let began = try #require(store.film.pass?.began)
            let clock = ContinuousClock()
            var longest = Duration.zero, whole = Duration.zero, frames = 0
            var softest = 1.0, soft = 0, softAt = 0.0, most = 0.0
            let wholes = try staged(on: stage).map { try sharpness($0.whole) }
            for frame in 1...Int(length * 60) {
                while CACurrentMediaTime() < began + Double(frame) / 60 { try await Task.sleep(for: .milliseconds(1)) }
                let took = clock.measure { stage.advance(to: CACurrentMediaTime()) }
                longest = max(longest, took)
                whole += took
                frames += 1
                guard store.film.playing else { break }
                // How sharp each piece shows, against how sharp it shows at.
                let pieces = try staged(on: stage)
                let want = try seen(store, pixels: 2 * zoom)
                guard pieces.count == want.count else { continue }
                var least = 1.0
                for (piece, wanted) in zip(pieces, want) {
                    guard let wanted, wanted.need > 0, !piece.whole.isHidden, piece.whole.filters == nil else { continue }
                    var has = try sharpness(piece.whole)
                    if let over = piece.over, over.bounds.insetBy(dx: -0.01, dy: -0.01).contains(wanted.part) { has = max(has, try sharpness(over)) }
                    least = min(least, Double(has / wanted.need))
                    most = max(most, Double(wanted.need))
                }
                if least < 0.8 { soft += 1 }
                if least < softest { softest = least; softAt = store.film.head }
            }
            store.pauseFilm()
            while stage.isDrawing { try await Task.sleep(for: .milliseconds(2)) }
            // Where the camera blurs, what the stage's lens made of those frames, and how long one took.
            let lensFrames = stage.lensFrames - lensBefore.frames, lensSpent = stage.lensSpent - lensBefore.spent
            let lens = lensFrames > 0
                ? String(format: "; the lens made %d frames, %.1f ms each, %.1f ms the longest", lensFrames, lensSpent / Double(lensFrames) * 1000, stage.lensLongest * 1000)
                : ""
            lines.append("\(Int(2 * zoom)) to the point: \(frames) frames, the main thread kept \(whole / max(frames, 1)) a frame and \(longest) at most; "
                + "\(atRest) parts at rest, \(stage.partsMade - atRest) while playing; softest \(softest) of what shows at \(softAt) s, \(soft) frames under 0.8; "
                + "\(board.filmPieces().count) pieces, their whole pictures \(wholes) pixels to the point, shown at up to \(most)" + lens)
        }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-film-stage.txt"), atomically: true, encoding: .utf8)
    }
}
