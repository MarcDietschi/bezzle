import Testing
import AppKit
import AVFoundation
@testable import Bezzle

/// Depth of field as it is drawn: a frame of a film whose camera is sharp at one distance, and
/// blurs what stands nearer or further by how far off it stands (`FilmSoft`, `FilmExport.composed`).
/// How wide a blur is, is measured: an edge between black and white, blurred, runs from the one
/// to the other as steeply as the blur is narrow.
@MainActor
struct FilmFocusFrameTests {
    /// A picture's tones: red, green and blue, from 0 to 1, in rows from the top, as fine as the
    /// picture has them. Asked for a pixel, it gives the red.
    struct Tones {
        let width: Int, height: Int
        private let values: [Float]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGBitmapInfo.floatComponents.rawValue
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let floats = try #require(ctx.data).assumingMemoryBound(to: Float.self), row = ctx.bytesPerRow / 4
            var all = [Float](repeating: 0, count: width * height * 3)
            for y in 0..<height {
                for x in 0..<width {
                    for c in 0..<3 { all[(y * width + x) * 3 + c] = floats[y * row + x * 4 + c] }
                }
            }
            values = all
        }

        subscript(x: Int, y: Int) -> Double { Double(values[(y * width + x) * 3]) }

        /// How wide the blur of an edge is that crosses a row at a column: the spread of the
        /// row's slope there, which for an edge blurred by a gaussian is the gaussian's. Within
        /// `reach` pixels of the column, four times the blur looked for: further out a blurred
        /// edge has nothing left, and the last bit of a half float, in a row that is flat to
        /// the eye, would count for much so far from the edge.
        func spread(inRow y: Int, at column: Int, within reach: Double) -> Double {
            spread(inRow: y, from: column - Int(reach.rounded(.up)), to: column + Int(reach.rounded(.up)))
        }

        func spread(inRow y: Int, from: Int, to: Int) -> Double {
            let from = max(from, 1), to = min(to, width - 1)
            var sum = 0.0, mean = 0.0
            for x in from...to {
                let d = abs(self[x, y] - self[x - 1, y])
                sum += d
                mean += d * (Double(x) - 0.5)
            }
            guard sum > 1e-6 else { return 0 }
            mean /= sum
            var spread = 0.0
            for x in from...to {
                let d = abs(self[x, y] - self[x - 1, y]), off = Double(x) - 0.5 - mean
                spread += d * off * off
            }
            return (spread / sum).squareRoot()
        }

        /// How far apart two pictures are: at the pixel and colour where they differ most, and
        /// on average, in 255ths.
        func distance(to other: Tones) -> (most: Double, mean: Double) {
            guard width == other.width, height == other.height else { return (255, 255) }
            var most = 0.0, sum = 0.0
            for i in values.indices {
                let d = Double(abs(values[i] - other.values[i])) * 255
                most = max(most, d)
                sum += d
            }
            return (most, sum / Double(max(1, values.count)))
        }

        /// How many of its pixels are further than so many 255ths from another's, in any colour.
        func pixels(furtherThan limit: Double, from other: Tones) -> Int {
            guard width == other.width, height == other.height else { return width * height }
            var count = 0
            for i in 0..<width * height where (0..<3).contains(where: { Double(abs(values[i * 3 + $0] - other.values[i * 3 + $0])) * 255 > limit }) { count += 1 }
            return count
        }
    }

    static func board(_ size: CGSize = CGSize(width: 400, height: 300)) -> Node {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(origin: .zero, size: size))
        board.fill.color = .white
        board.film = Film(length: 1)
        return board
    }

    static func box(_ name: String, _ frame: CGRect, lift: Double? = nil) -> Node {
        var box = Node(kind: .rectangle, name: name, frame: frame)
        box.fill.color = .black
        if let lift { box.setKey(.lift, [lift], at: 0) }
        return box
    }

    /// A frame of the film, `scale` pixels to the point, before anything has cut its tones.
    private func frame(of board: Node, at t: Double = 0, scale: CGFloat = 2, deep: Bool = true) throws -> Tones {
        let size = CGSize(width: board.frame.width * scale, height: board.frame.height * scale)
        return try Tones(#require(FilmExport.frame(of: board, at: t, size: size, assets: nil, deep: deep)))
    }

    /// How much each piece of a film is blurred at a point of the frame, by the film's arithmetic.
    private func blur(on board: Node, at p: CGPoint, time t: Double = 0) -> [Double] {
        let pieces = board.filmPieces(), layers = board.filmLayers(of: pieces), camera = board.camera(at: t)
        return pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera).soft?.blur(at: p) ?? 0 }
    }

    // MARK: How much

    @Test func aLiftedCardIsBlurredByHowFarItStandsOffTheFocus() throws {
        // The left half of the frame, a hundred points above the page. The eye is 800 away.
        var b = Self.board()
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 200, height: 300), lift: 100)]
        let sharp = try frame(of: b).spread(inRow: 300, at: 400, within: 8)
        #expect(sharp < 0.8, "\(sharp)")
        // Six points of blur for every hundred off the focus: six of its own points, shown
        // 800/700 times as large as it is, with two pixels to the point.
        b.setKey(.cameraBlur, [6], at: 0)
        let film = try frame(of: b)
        let want = 6 * 800.0 / 700 * 2
        for row in [100, 300, 500] {
            let spread = film.spread(inRow: row, at: 400, within: want * 4)
            #expect(abs(spread - want) < want * 0.06, "row \(row): \(spread), not \(want)")
        }
        // The edge is where it was, and half way between black and white there.
        #expect(abs(film[400, 300] + film[399, 300] - 1) < 0.04, "\(film[400, 300])")
        // Twice the blur, and it is twice as wide.
        b.setKey(.cameraBlur, [12], at: 0)
        let wider = try frame(of: b).spread(inRow: 300, at: 400, within: want * 8)
        #expect(abs(wider - want * 2) < want * 2 * 0.06, "\(wider)")
    }

    @Test func aCardOffTheFocusIsBlurredAsItsOwnBlurWouldBlurIt() throws {
        // A hundred points off the focus under a blur of 6 is a blur of 6 of its own.
        var b = Self.board()
        b.children = [Self.box("Card", CGRect(x: 100, y: 60, width: 200, height: 180), lift: 100)]
        var own = b
        own.children[0].setKey(.blur, [6], at: 0)
        b.setKey(.cameraBlur, [6], at: 0)
        let film = try frame(of: b), other = try frame(of: own)
        // As wide, and the same picture but for the shape of the two blurs: a few 255ths apart
        // where they differ most, along the card's edges.
        let apart = film.distance(to: other)
        #expect(apart.mean < 1 && apart.most < 14, "\(apart)")
        let want = 6 * 800.0 / 700 * 2
        let mine = film.spread(inRow: 300, at: 171, within: want * 4), its = other.spread(inRow: 300, at: 171, within: want * 4)
        #expect(abs(mine - want) < want * 0.06 && abs(its - want) < want * 0.06, "\(mine) \(its)")
    }

    @Test func sharpOnTheCardThePageIsSoftInstead() throws {
        var b = Self.board()
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 200, height: 300), lift: 100),
                      Self.box("Mark", CGRect(x: 300, y: 0, width: 100, height: 300))]
        b.setKey(.cameraBlur, [6], at: 0)
        b.setKey(.cameraFocus, [100], at: 0)
        let film = try frame(of: b)
        // The card's edge, in the middle of the frame, is sharp; the mark's, on the page a
        // hundred points further, is blurred by six points: twelve pixels.
        let card = film.spread(inRow: 300, at: 400, within: 8), mark = film.spread(inRow: 300, at: 600, within: 48)
        #expect(card < 0.8, "\(card)")
        #expect(abs(mark - 12) < 12 * 0.06, "\(mark)")
        // Half way between the two, and each is half as soft.
        b.setKey(.cameraFocus, [50], at: 0)
        let between = try frame(of: b)
        let nearer = between.spread(inRow: 300, at: 400, within: 28), further = between.spread(inRow: 300, at: 600, within: 24)
        #expect(abs(nearer - 6 * 800.0 / 700) < 0.6 && abs(further - 6) < 0.6, "\(nearer) \(further)")
    }

    @Test func withNothingOffTheFocusAFrameIsWhatItIsWithoutTheBlur() throws {
        var b = Self.board()
        var faint = Self.box("Faint", CGRect(x: 40, y: 40, width: 120, height: 90))
        faint.opacity = 0.5
        var turned = Self.box("Turned", CGRect(x: 220, y: 120, width: 120, height: 90))
        turned.rotation = 20
        turned.setKey(.move, [0, 0], at: 0, ease: .linear)
        turned.setKey(.move, [30, 10], at: 1, ease: .linear)
        b.children = [faint, turned]
        b.setKey(.cameraZoom, [1.6], at: 0)
        b.setKey(.cameraMove, [30, -20], at: 0)
        b.setKey(.cameraRoll, [10], at: 0)
        let plain = try frame(of: b, at: 0.5)
        // Everything lies in the page, which the camera faces and is sharp on, however much it
        // blurs what stands off it.
        b.setKey(.cameraBlur, [40], at: 0)
        let film = try frame(of: b, at: 0.5)
        let apart = film.distance(to: plain)
        #expect(apart.most < 0.6, "\(apart)")
    }

    // MARK: Across a thing the camera does not face

    @Test func underACameraTippedBackThePageIsSharpAcrossItsMiddleAndSofterToItsTopAndFoot() throws {
        // The left half of the page is black: an edge down the middle of the frame, which stays
        // there however the page is tipped back.
        var b = Self.board()
        b.children = [Self.box("Half", CGRect(x: 0, y: 0, width: 200, height: 300))]
        b.setKey(.cameraTilt, [50], at: 0)
        b.setKey(.cameraBlur, [12], at: 0)
        let film = try frame(of: b)
        var spreads: [Double] = []
        // Down the page, which shows from about 66 to 262 points down the frame.
        for y in stride(from: 86.0, through: 214, by: 16) {
            // What the film's arithmetic says of the page at this height of the frame, in pixels.
            let want = try #require(blur(on: b, at: CGPoint(x: 200, y: y)).first) * 2
            let spread = film.spread(inRow: Int(y * 2), at: 400, within: want * 4 + 4)
            spreads.append(spread)
            #expect(abs(spread - want) < max(0.9, want * 0.12), "at \(y): \(spread), not \(want)")
        }
        // Sharp across the middle, where the camera looks, and softer each way from there.
        #expect(spreads[4] < 0.8, "\(spreads)")
        #expect(spreads[0] > spreads[1] && spreads[1] > spreads[2] && spreads[2] > spreads[3] && spreads[3] > spreads[4], "\(spreads)")
        #expect(spreads[8] > spreads[7] && spreads[7] > spreads[6] && spreads[6] > spreads[5] && spreads[5] > spreads[4], "\(spreads)")
        #expect(spreads[0] > 4 && spreads[8] > 4, "\(spreads)")
        // Focused nearer, the line that is sharp lies lower in the frame, where the page is nearer.
        b.setKey(.cameraFocus, [60], at: 0)
        let nearer = try frame(of: b)
        var sharpest = (row: 0, blur: Double.infinity)
        for row in stride(from: 300, through: 480, by: 12) {
            let want = try #require(blur(on: b, at: CGPoint(x: 200, y: Double(row) / 2)).first) * 2
            let spread = nearer.spread(inRow: row, at: 400, within: want * 4 + 4)
            #expect(abs(spread - want) < max(0.9, want * 0.12), "row \(row): \(spread), not \(want)")
            if spread < sharpest.blur { sharpest = (row, spread) }
        }
        #expect(sharpest.row > 380 && sharpest.row < 430 && sharpest.blur < 1, "\(sharpest)")
    }

    // MARK: Much of it

    @Test func aBlurOfHundredsOfPixelsIsAsWideAsAsked() throws {
        // A wide artboard, the eye 3200 away, and a card 400 above the page: under a blur of 25
        // it is blurred by a hundred of its own points, shown 3200/2800 times as large.
        var b = Self.board(CGSize(width: 1600, height: 400))
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 800, height: 400), lift: 400)]
        b.setKey(.cameraBlur, [25], at: 0)
        let film = try frame(of: b, scale: 1)
        let want = 100 * 3200.0 / 2800
        for row in [60, 200, 340] {
            let spread = film.spread(inRow: row, at: 800, within: want * 4)
            #expect(abs(spread - want) < want * 0.08, "row \(row): \(spread), not \(want)")
        }
        // As smooth as it is wide: no step from one pixel to the next larger than a bell that wide has.
        var steepest = 0.0
        for x in 1..<film.width { steepest = max(steepest, abs(film[x, 200] - film[x - 1, 200])) }
        #expect(steepest < 1.6 * 0.3989 / want, "\(steepest)")
    }

    @Test func tippedFarBackTheBlurGrowsEvenlyFromNothingToHundredsOfPixels() throws {
        var b = Self.board()
        b.children = [Self.box("Half", CGRect(x: 0, y: 0, width: 200, height: 300))]
        b.setKey(.cameraTilt, [60], at: 0)
        b.setKey(.cameraBlur, [40], at: 0)
        let film = try frame(of: b)
        var last = 0.0
        // From the line that is sharp to the frame's foot: wider at every step, and as wide as
        // the film's arithmetic says, also where the blur is made of a smaller picture.
        for y in stride(from: 150.0, through: 290, by: 10) {
            let want = min(try #require(blur(on: b, at: CGPoint(x: 200, y: y)).first) * 2, 400)
            let reach = min(Int(want * 3.2) + 8, 398)
            let spread = film.spread(inRow: Int(y * 2), from: 400 - reach, to: 400 + reach)
            // Measured between two columns, a wide bell is cut off: a tenth less of it shows.
            #expect(spread > want * 0.84 - 0.8 && spread < want * 1.1 + 0.8, "at \(y): \(spread), not \(want)")
            #expect(spread >= last - 0.3, "at \(y): \(spread) after \(last)")
            last = spread
        }
        #expect(last > 80, "\(last)")
    }

    @Test func nothingIsBlurredByMoreThanALayersOwnBlurGoesTo() throws {
        // All but at the eye, and blurred a hundred for a hundred: thousands of points, were
        // there no end to it. It is made at all, and soon.
        var b = Self.board()
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 200, height: 300), lift: 700)]
        b.setKey(.cameraBlur, [100], at: 0)
        #expect((blur(on: b, at: CGPoint(x: 200, y: 150)).max() ?? 0) == FilmSoft.most)
        let began = ContinuousClock.now
        let film = try frame(of: b, scale: 1)
        #expect(ContinuousClock.now - began < .seconds(5))
        // Black to the left and white to the right, spread all over the frame.
        #expect(film[20, 150] < film[200, 150] && film[200, 150] < film[380, 150])
        #expect(abs(film[200, 150] - 0.5) < 0.1, "\(film[200, 150])")
    }

    // MARK: One plane, one picture

    @Test func twoCardsInOnePlaneAreBlurredAsTheOnePictureTheyAre() throws {
        // Side by side with no gap, both a hundred above the page. Each blurred by itself would
        // be half gone at the edge they share, and the page would show through there.
        var b = Self.board()
        b.children = [Self.box("Left", CGRect(x: 100, y: 100, width: 100, height: 100), lift: 100),
                      Self.box("Right", CGRect(x: 200, y: 100, width: 100, height: 100), lift: 100)]
        b.setKey(.cameraBlur, [8], at: 0)
        #expect(b.filmPieces().filter { $0.kind == .layer }.count == 2)
        let film = try frame(of: b)
        #expect(film[400, 300] < 0.02 && film[399, 300] < 0.02, "\(film[400, 300])")
        // Their outer edges are soft.
        #expect(film.spread(inRow: 300, at: 171, within: 80) > 10)
    }

    // MARK: Gentle tones

    @Test func aBlurredEdgeKeepsItsTonesUntilTheFramesOwnStepsCutThemOnce() throws {
        var b = Self.board(CGSize(width: 1600, height: 400))
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 800, height: 400), lift: 400)]
        b.setKey(.cameraBlur, [25], at: 0)
        let deep = try frame(of: b, scale: 1), cut = try frame(of: b, scale: 1, deep: false)
        // Flat black on flat white, neither with a gentle tone of its own, so both drawn with
        // eight bits. The blur between them is worked out finer: far more tones along the edge
        // than eight bits have between black and white.
        #expect(!b.children[0].hasGentleTones)
        var tones = Set<Double>(), steps = Set<Double>()
        for x in 0..<deep.width {
            tones.insert(deep[x, 200])
            steps.insert(cut[x, 200])
        }
        #expect(steps.count <= 256 && tones.count > 420, "\(tones.count) tones, \(steps.count) steps")
        // And eight bits are those tones rounded, once: half a step off at most, and what a
        // half float's last bit is near white, an eighth of a step.
        var furthest = 0.0
        for x in 0..<deep.width { furthest = max(furthest, abs(deep[x, 200] - cut[x, 200]) * 255) }
        #expect(furthest <= 0.64, "\(furthest)")
    }

    // MARK: The stage

    /// A bench with these layers on artboard A (400 by 300 at 100, 100, the eye 800 away), in
    /// Animate, its camera keyed so at the film's start, and its stage as large as the canvas.
    private func staged(_ layers: [Node], camera: [(MotionProperty, [Double])], zoom: CGFloat = 1, origin: CGPoint = .zero) -> (bench: Bench, stage: FilmStageView) {
        let bench = Bench(extra: layers)
        let id = bench.a.id
        bench.step {
            bench.store.edit("Camera") { doc in
                doc.update(id) { n in
                    n.film = Film(length: 1)
                    for (property, value) in camera { n.setKey(property, value, at: 0) }
                }
            }
        }
        bench.store.show(.animate)
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: origin, zoom: zoom)
        let stage = bench.canvas.filmStage
        stage.frame = bench.canvas.frame
        stage.layout()
        return (bench, stage)
    }

    /// Brings the stage to the design as the canvas does when it draws, until everything it
    /// asked for has been made: the pieces' pictures, the parts drawn sharper, and the lens's frame.
    @discardableResult
    private func settle(_ stage: FilmStageView, scale: CGFloat = 2) async throws -> CGRect? {
        let clock = ContinuousClock(), began = clock.now
        while true {
            let rect = stage.sync(scale: scale)
            guard stage.isDrawing else { return rect }
            while stage.isDrawing {
                guard clock.now - began < .seconds(60) else {
                    Issue.record("The stage's pictures were not made within a minute.")
                    return rect
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// The stage's two ways of showing a film: the pieces' own layers, and the lens over them.
    private func layers(of stage: FilmStageView) throws -> (scene: CALayer, lens: CALayer) {
        let gate = try #require(stage.layer?.sublayers?.first?.sublayers?.first)
        let lens = try #require(gate.sublayers?.first { $0.name == FilmStageView.lensName })
        return (try #require(gate.sublayers?.first { $0.name != FilmStageView.lensName }), lens)
    }

    /// Cards at three heights, one of them in colour and one half faded, and bars on the page.
    private func scene() -> [Node] {
        var red = Self.box("Red", CGRect(x: 40, y: 40, width: 120, height: 90), lift: 120)
        red.fill.color = RGBA(r: 0.9, g: 0.2, b: 0.1)
        var faint = Self.box("Faint", CGRect(x: 230, y: 150, width: 130, height: 110), lift: 40)
        faint.opacity = 0.5
        var blue = Self.box("Blue", CGRect(x: 150, y: 90, width: 100, height: 100), lift: -60)
        blue.fill.color = RGBA(r: 0.1, g: 0.3, b: 0.8)
        var bars: [Node] = []
        for x in stride(from: 10.0, to: 400, by: 30) { bars.append(Self.box("Bar", CGRect(x: x, y: 0, width: 4, height: 300))) }
        return bars + [blue, faint, red]
    }

    @Test func theStageShowsTheFrameAMovieHasOfTheSameMoment() async throws {
        for camera: [(MotionProperty, [Double])] in [
            [(.cameraBlur, [8])],
            [(.cameraBlur, [8]), (.cameraFocus, [120])],
            [(.cameraBlur, [10]), (.cameraTilt, [40]), (.cameraSwing, [-20]), (.cameraZoom, [1.3]), (.cameraFocus, [30])],
        ] {
            let (bench, stage) = staged(scene(), camera: camera)
            #expect(try await settle(stage) == CGRect(x: 100, y: 100, width: 400, height: 300))
            let lens = try #require(stage.lensPicture, "\(camera)")
            // All of the film's frame shows in the view: 800 by 600 pixels, two to the point.
            #expect(lens.covers == CGRect(x: 0, y: 0, width: 400, height: 300))
            let shown = try Tones(lens.image)
            let board = try #require(bench.store.filmBoard)
            let frame = try Tones(#require(FilmExport.frame(of: board, at: 0, size: CGSize(width: 800, height: 600), assets: nil)))
            // The same picture. Along a sharp edge the two differ by what a pixel is when it
            // is drawn at another size first; nowhere else.
            let apart = shown.distance(to: frame), off = shown.pixels(furtherThan: 8, from: frame)
            #expect(apart.mean < 0.4, "\(camera): \(apart)")
            #expect(off < 800 * 600 / 400, "\(camera): \(off) pixels apart, \(apart)")
            // And it is blurred: the red card's edge, or the page's bars.
            let plain = try Tones(#require(Renderer.image(of: board, scale: 2)))
            #expect(shown.distance(to: plain).mean > 2)
            // The pieces' own layers are put away while the lens shows.
            let both = try layers(of: stage)
            #expect(both.scene.isHidden && !both.lens.isHidden)
        }
    }

    @Test func aFilmWithNothingBlurredIsShownByItsLayersAsItAlwaysWas() async throws {
        // No blur at all; and a camera that blurs, with everything in the page it is sharp on.
        for (layers, camera): ([Node], [(MotionProperty, [Double])]) in [
            (scene(), [(.cameraZoom, [1.5]), (.cameraTilt, [30])]),
            ([Self.box("Flat", CGRect(x: 40, y: 40, width: 120, height: 90))], [(.cameraBlur, [40]), (.cameraZoom, [1.5]), (.cameraRoll, [20])]),
        ] {
            let (_, stage) = staged(layers, camera: camera)
            try await settle(stage)
            #expect(stage.lensPicture == nil && stage.lensFrames == 0)
            let both = try self.layers(of: stage)
            #expect(!both.scene.isHidden && both.lens.isHidden && both.lens.contents == nil)
            #expect((both.scene.sublayers ?? []).count >= 2)
        }
    }

    @Test func theLensComesWhenSomethingIsBlurredAndGoesWhenNothingIs() async throws {
        let (bench, stage) = staged(scene(), camera: [])
        let id = bench.a.id
        bench.step {
            bench.store.edit("Camera") { doc in
                doc.update(id) { n in
                    n.setKey(.cameraBlur, [0], at: 0, ease: .linear)
                    n.setKey(.cameraBlur, [8], at: 1, ease: .linear)
                }
            }
        }
        try await settle(stage)
        #expect(stage.lensPicture == nil)
        bench.store.seek(0.5)
        try await settle(stage)
        let half = try Tones(#require(stage.lensPicture).image)
        bench.store.seek(1)
        try await settle(stage)
        let whole = try Tones(#require(stage.lensPicture).image)
        #expect(half.distance(to: whole).mean > 0.5)
        var both = try layers(of: stage)
        #expect(both.scene.isHidden && !both.lens.isHidden)
        // Asked again for the same moment, nothing is made again.
        let made = stage.lensFrames
        try await settle(stage)
        #expect(stage.lensFrames == made)
        // Back where nothing is blurred, the layers show at once.
        bench.store.seek(0)
        _ = stage.sync(scale: 2)
        both = try layers(of: stage)
        #expect(!both.scene.isHidden && both.lens.isHidden && stage.lensPicture == nil)
        try await settle(stage)
        #expect(stage.lensPicture == nil)
    }

    @Test func zoomedInTheLensMakesOnlyWhatTheViewShows() async throws {
        // Four times, with the artboard's middle in the view: 1200 by 800 points of a frame of
        // 1600 by 1200, which is 3200 by 2400 pixels.
        let camera: [(MotionProperty, [Double])] = [(.cameraBlur, [8]), (.cameraTilt, [30])]
        let (bench, stage) = staged(scene(), camera: camera, zoom: 4, origin: CGPoint(x: 150, y: 125))
        try await settle(stage)
        let lens = try #require(stage.lensPicture)
        // What shows, and a little round it, on steps of 64 pixels.
        #expect(lens.covers == CGRect(x: 40, y: 16, width: 320, height: 224), "\(lens.covers)")
        #expect(lens.image.width == 2560 && lens.image.height == 1792)
        let board = try #require(bench.store.filmBoard)
        let frame = try #require(FilmExport.frame(of: board, at: 0, size: CGSize(width: 3200, height: 2400), assets: nil))
        let part = try Tones(#require(frame.cropping(to: CGRect(x: 320, y: 128, width: 2560, height: 1792))))
        let shown = try Tones(lens.image)
        let apart = shown.distance(to: part), off = shown.pixels(furtherThan: 8, from: part)
        #expect(apart.mean < 0.4, "\(apart)")
        #expect(off < 2560 * 1792 / 400, "\(off) pixels apart, \(apart)")
    }

    // MARK: To look at

    /// Writes frames of films with a camera that blurs into the folder ANIMATE_FOCUS_PICTURES
    /// names, to be looked at: `TEST_RUNNER_ANIMATE_FOCUS_PICTURES=<folder> xcodebuild test
    /// -only-testing:BezzleTests/FilmFocusFrameTests/pictures`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_FOCUS_PICTURES"] != nil))
    func pictures() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ANIMATE_FOCUS_PICTURES"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func save(_ board: Node, _ name: String, scale: CGFloat = 2) throws {
            let size = CGSize(width: board.frame.width * scale, height: board.frame.height * scale)
            let image = try #require(FilmExport.frame(of: board, at: 0, size: size, assets: nil))
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        var card = Self.board()
        card.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 200, height: 300), lift: 100),
                         Self.box("Mark", CGRect(x: 300, y: 0, width: 100, height: 300))]
        card.setKey(.cameraBlur, [6], at: 0)
        try save(card, "card off the focus")
        card.setKey(.cameraFocus, [100], at: 0)
        try save(card, "sharp on the card")
        var tipped = Self.board()
        tipped.children = [Self.box("Half", CGRect(x: 0, y: 0, width: 200, height: 300))]
        for x in stride(from: 210.0, to: 400, by: 20) { tipped.children.append(Self.box("Bar", CGRect(x: x, y: 0, width: 6, height: 300))) }
        tipped.setKey(.cameraTilt, [50], at: 0)
        tipped.setKey(.cameraBlur, [12], at: 0)
        try save(tipped, "tipped back")
        tipped.setKey(.cameraFocus, [60], at: 0)
        try save(tipped, "tipped back, sharp nearer")
        tipped.setKey(.cameraFocus, [0], at: 0)
        tipped.setKey(.cameraTilt, [60], at: 0)
        tipped.setKey(.cameraBlur, [40], at: 0)
        try save(tipped, "tipped far back, much blur")
        tipped.setKey(.cameraTilt, [0], at: 0)
        tipped.setKey(.cameraSwing, [40], at: 0)
        tipped.setKey(.cameraBlur, [12], at: 0)
        try save(tipped, "swung round")
        var wide = Self.board(CGSize(width: 1600, height: 400))
        wide.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 800, height: 400), lift: 400)]
        wide.setKey(.cameraBlur, [25], at: 0)
        try save(wide, "hundreds of pixels", scale: 1)
    }

    // MARK: The movie

    @Test func theMovieHasTheBlurOfItsFrames() async throws {
        var b = Self.board(CGSize(width: 200, height: 160))
        b.film = Film(length: 0.4)
        b.children = [Self.box("Card", CGRect(x: 0, y: 0, width: 100, height: 160), lift: 100)]
        b.setKey(.cameraBlur, [0], at: 0, ease: .linear)
        b.setKey(.cameraBlur, [10], at: 0.4, ease: .linear)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFocus-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = FilmExport.Settings(scale: 2, fps: 10)
        try await FilmExport.write(b, assets: nil, to: url, settings: settings) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let moments = FilmExport.moments(of: b, fps: 10), size = FilmExport.size(of: b, settings: settings)
        var spreads: [Double] = []
        for k in moments.indices {
            let read = try Tones(await generator.image(at: CMTime(value: CMTimeValue(k), timescale: 10)).image)
            let made = try Tones(#require(FilmExport.frame(of: b, at: moments[k], size: size, assets: nil)))
            let apart = read.distance(to: made)
            #expect(apart.mean < 3, "frame \(k): \(apart)")
            spreads.append(read.spread(inRow: 160, at: 200, within: 80))
        }
        // Sharp at its start, and softer with every frame.
        #expect(spreads[0] < 1.5 && spreads == spreads.sorted() && (spreads.last ?? 0) > 10, "\(spreads)")
    }
}
