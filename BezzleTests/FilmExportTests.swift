import Testing
import AppKit
import AVFoundation
@testable import Bezzle

/// A film saved as a movie: frames composed as the canvas shows the film, and the file made of them.
@MainActor
struct FilmExportTests {
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

        /// Whether the pixel is this colour, give or take.
        func shows(_ color: RGBA, at x: Int, _ y: Int, within tolerance: Int = 6) -> Bool {
            let want = [color.r, color.g, color.b].map { Int(($0 * 255).rounded()) }
            return zip(self[x, y], want).allSatisfy { abs($0 - $1) <= tolerance }
        }

        /// The pixels of a row that are this colour: where they begin, and how many there are.
        func run(of color: RGBA, inRow y: Int) -> (start: Int, count: Int) {
            let hits = (0..<width).filter { shows(color, at: $0, y, within: 40) }
            return (hits.first ?? -1, hits.count)
        }

        /// How far apart two pictures are: at the pixel where they differ most, and on average.
        func distance(to other: Pixels) -> (most: Int, mean: Double) {
            var most = 0, sum = 0
            for y in 0..<min(height, other.height) {
                for x in 0..<min(width, other.width) {
                    for (a, b) in zip(self[x, y], other[x, y]) {
                        most = max(most, abs(a - b))
                        sum += abs(a - b)
                    }
                }
            }
            return (most, Double(sum) / Double(max(1, width * height * 3)))
        }
    }

    private let red = RGBA(r: 0.9, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.3, b: 0.8), green = RGBA(r: 0.1, g: 0.6, b: 0.3)

    private func board(_ size: CGSize = CGSize(width: 200, height: 160), at origin: CGPoint = .zero) -> Node {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(origin: origin, size: size))
        board.fill.color = .white
        return board
    }

    private func box(_ name: String, _ frame: CGRect, _ color: RGBA) -> Node {
        var box = Node(kind: .rectangle, name: name, frame: frame)
        box.fill.color = color
        return box
    }

    /// A frame of the film, `scale` pixels to the point.
    private func frame(of board: Node, at t: Double, scale: CGFloat = 1) throws -> Pixels {
        let size = FilmExport.size(of: board, settings: FilmExport.Settings(scale: scale, fps: 30))
        return try Pixels(#require(FilmExport.frame(of: board, at: t, size: size, assets: nil)))
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFilm-\(UUID().uuidString).mp4")
    }

    // MARK: Frames

    @Test func atRestAFrameIsTheArtboardAsItIsDrawn() throws {
        // Anywhere on the canvas: a film is the artboard's own, wherever it lies.
        var b = board(at: CGPoint(x: 340, y: -120))
        var round = box("Round", CGRect(x: 20, y: 16, width: 90, height: 60), red)
        round.cornerRadius = 14
        round.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.4), x: 0, y: 4, blur: 8)
        var turned = box("Turned", CGRect(x: 96, y: 70, width: 70, height: 50), blue)
        turned.rotation = 20
        turned.opacity = 0.6
        var dot = Node(kind: .ellipse, name: "Dot", frame: CGRect(x: 150, y: 10, width: 70, height: 70))
        dot.fill.color = green
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 14, y: 96, width: 80, height: 50))
        group.opacity = 0.8
        group.children = [box("One", CGRect(x: 0, y: 0, width: 50, height: 30), blue), box("Two", CGRect(x: 30, y: 20, width: 50, height: 30), red)]
        b.children = [round, turned, dot, group]
        let film = try frame(of: b, at: 0.7, scale: 2)
        let plain = try Pixels(#require(Renderer.image(of: b, scale: 2)))
        #expect(film.width == plain.width && film.height == plain.height)
        let apart = film.distance(to: plain)
        #expect(apart.most <= 3, "\(apart)")
    }

    @Test func aMovedLayerShowsWhereItIsMoved() throws {
        var b = board()
        var moving = box("Moving", CGRect(x: 20, y: 20, width: 40, height: 40), red)
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [100, 60], at: 1, ease: .linear)
        b.children = [box("Still", CGRect(x: 150, y: 10, width: 30, height: 30), blue), moving]
        let start = try frame(of: b, at: 0), middle = try frame(of: b, at: 0.5), end = try frame(of: b, at: 1)
        #expect(start.shows(red, at: 40, 40) && start.shows(.white, at: 140, 100))
        #expect(middle.shows(red, at: 90, 70) && middle.shows(.white, at: 40, 40) && middle.shows(.white, at: 140, 100))
        #expect(end.shows(red, at: 140, 100) && end.shows(.white, at: 40, 40))
        // Its edges are where the move puts them, to the pixel.
        #expect(middle.shows(red, at: 71, 51) && middle.shows(.white, at: 68, 48))
        #expect(middle.shows(red, at: 108, 88) && middle.shows(.white, at: 111, 91))
        // What does not move stays.
        #expect(end.shows(blue, at: 165, 25))
    }

    @Test func aFadedLayerIsFainterAndABlurredOneSpreads() throws {
        var b = board()
        var faded = box("Faded", CGRect(x: 20, y: 20, width: 40, height: 40), .black)
        faded.setKey(.fade, [0.5], at: 0)
        var gone = box("Gone", CGRect(x: 80, y: 20, width: 40, height: 40), .black)
        gone.setKey(.fade, [0], at: 0)
        var soft = box("Soft", CGRect(x: 80, y: 90, width: 40, height: 40), .black)
        soft.setKey(.blur, [6], at: 0)
        b.children = [faded, gone, soft, box("Sharp", CGRect(x: 20, y: 90, width: 40, height: 40), .black)]
        let film = try frame(of: b, at: 0)
        #expect(film.shows(RGBA(r: 0.5, g: 0.5, b: 0.5), at: 40, 40, within: 3), "\(film[40, 40])")
        #expect(film.shows(.white, at: 100, 40))
        // Past the sharp one's edge the page is clean; past the blurred one's it is grey, and its
        // own edge is no longer black.
        #expect(film.shows(.white, at: 64, 110, within: 1))
        #expect(film[124, 110][0] < 235 && film[124, 110][0] > 120, "\(film[124, 110])")
        #expect(film[118, 110][0] > 40, "\(film[118, 110])")
        #expect(film[100, 110][0] < 30, "\(film[100, 110])")
    }

    @Test func zoomedInTwiceTheMiddleShowsTwiceAsLarge() throws {
        var b = board()
        b.children = [box("Middle", CGRect(x: 80, y: 60, width: 40, height: 40), blue)]
        let rest = try frame(of: b, at: 0).run(of: blue, inRow: 80)
        #expect(rest.start == 80 && rest.count == 40)
        b.setKey(.cameraZoom, [2], at: 0)
        let film = try frame(of: b, at: 0)
        let near = film.run(of: blue, inRow: 80)
        #expect(near.start == 60 && near.count == 80, "\(near)")
        // Down the page too: its top edge is forty above the middle now.
        #expect(film.shows(blue, at: 100, 42) && film.shows(.white, at: 100, 38))
        #expect(film.shows(blue, at: 100, 118) && film.shows(.white, at: 100, 122))
    }

    @Test func tippedBackTheTopEdgeShowsNarrowerThanTheBottom() throws {
        var b = board(CGSize(width: 200, height: 200))
        b.fill.color = blue
        b.film = Film(backdrop: .white)
        b.setKey(.cameraTilt, [50], at: 0)
        b.setKey(.cameraZoom, [0.7], at: 0)
        let film = try frame(of: b, at: 0)
        // What the film's own arithmetic says of two lines across the artboard, near its top and
        // near its foot, is what the picture shows.
        let ground = FilmLens.ground(b.camera(at: 0), size: b.frame.size)
        var widths: [Int] = []
        for y in [20.0, 180.0] {
            let left = ground(CGPoint(x: 0, y: y)), right = ground(CGPoint(x: 200, y: y))
            let shown = film.run(of: blue, inRow: Int(left.y.rounded()))
            #expect(abs(Double(shown.start) - left.x) <= 1.5, "\(y): \(shown) for \(left) to \(right)")
            #expect(abs(Double(shown.count) - (right.x - left.x)) <= 2, "\(y): \(shown) for \(left) to \(right)")
            widths.append(shown.count)
        }
        #expect(widths[0] > 40 && widths[0] < widths[1] - 10, "\(widths)")
        // Round the artboard, the backdrop.
        #expect(film.shows(.white, at: 3, 3) && film.shows(.white, at: 196, 196))
    }

    @Test func aLayerSwungInDepthShowsItsNearSideLarger() throws {
        var b = board()
        var door = box("Door", CGRect(x: 60, y: 40, width: 80, height: 80), red)
        door.setKey(.swing, [50], at: 0)
        b.children = [door]
        let film = try frame(of: b, at: 0)
        // Its right side has gone away: shorter there than on the left, which has come nearer.
        func height(inColumn x: Int) -> Int { (0..<film.height).filter { film.shows(red, at: x, $0, within: 40) }.count }
        let map = b.placement(of: b.filmPieces()[1], at: 0, camera: .rest).map
        let left = map(CGPoint(x: 60, y: 40)), right = map(CGPoint(x: 140, y: 40))
        let near = height(inColumn: Int(left.x.rounded()) + 3), far = height(inColumn: Int(right.x.rounded()) - 3)
        #expect(near > 80 && far < 80 && far > 40, "\(near) and \(far)")
    }

    @Test func theFrameIsEvenAndNoLargerThanAMovieMayBe() {
        func size(_ w: CGFloat, _ h: CGFloat, _ scale: CGFloat) -> CGSize {
            FilmExport.size(of: board(CGSize(width: w, height: h)), settings: FilmExport.Settings(scale: scale, fps: 60))
        }
        #expect(size(800, 600, 2) == CGSize(width: 1600, height: 1200))
        #expect(size(1080, 1350, 1) == CGSize(width: 1080, height: 1350))
        #expect(size(401, 301, 1) == CGSize(width: 402, height: 302))
        // Too large at this scale: the scale gives way and the shape stays.
        #expect(size(3000, 2000, 2) == CGSize(width: 3840, height: 2560))
        #expect(size(390, 12000, 2) == CGSize(width: 124, height: 3840))
        for (w, h, scale) in [(375.5, 812.0, 3.0), (1, 1, 1), (333, 777, 1.5), (5000, 5000, 4), (97, 31, 0.5)] {
            let s = size(w, h, scale)
            #expect(Int(s.width) % 2 == 0 && Int(s.height) % 2 == 0 && s.width >= 2 && s.height >= 2, "\(s)")
            #expect(max(s.width, s.height) <= 3840, "\(s)")
        }
    }

    @Test func aFilmThatPlaysOnceEndsOnItsLastMoment() {
        var b = board()
        b.film = Film(length: 1)
        #expect(FilmExport.moments(of: b, fps: 4) == [0, 0.25, 0.5, 0.75])
        b.film?.once = true
        #expect(FilmExport.moments(of: b, fps: 4) == [0, 0.25, 0.5, 1])
        // With nothing set, as long as the film runs.
        #expect(FilmExport.moments(of: board(), fps: 30).count == Int(MotionTiming.shortest * 30))
    }

    // MARK: The file

    /// A short film with a little of everything: a layer that moves, one that moves inside a
    /// group faded as a whole, which is drawn again as it does, and a camera coming closer.
    private func shortFilm(_ length: Double) -> Node {
        var b = board(CGSize(width: 160, height: 120))
        b.film = Film(length: length)
        var moving = box("Moving", CGRect(x: 10, y: 10, width: 40, height: 40), red)
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [100, 0], at: length, ease: .linear)
        var inner = box("Inner", CGRect(x: 0, y: 0, width: 30, height: 30), green)
        inner.setKey(.move, [90, 0], at: 0, ease: .linear)
        inner.setKey(.move, [0, 0], at: length, ease: .linear)
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 20, y: 70, width: 120, height: 30))
        group.opacity = 0.8
        group.children = [inner]
        b.children = [box("Still", CGRect(x: 60, y: 54, width: 40, height: 12), blue), moving, group]
        b.setKey(.cameraZoom, [1], at: 0, ease: .linear)
        b.setKey(.cameraZoom, [1.25], at: length, ease: .linear)
        return b
    }

    @MainActor private final class Told {
        var all: [Double] = []
        var task: Task<Void, Error>?
        var began = false
    }

    @Test func theMovieReadsBackAsItWasComposed() async throws {
        let b = shortFilm(0.6), settings = FilmExport.Settings(scale: 2, fps: 10)
        #expect(b.filmPieces().contains { $0.changes })
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let told = Told()
        try await FilmExport.write(b, assets: nil, to: url, settings: settings) { told.all.append($0) }
        #expect(told.all.first == 0 && told.all.last == 1 && told.all == told.all.sorted() && told.all.count == 7, "\(told.all)")

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (natural, rate, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        #expect(natural == CGSize(width: 320, height: 240))
        #expect(abs(duration - 0.6) < 0.1, "\(duration)")
        #expect(abs(rate - 10) < 0.05, "\(rate)")
        let format = try #require(formats.first)
        #expect(format.mediaSubType == .h264)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                == kCMFormatDescriptionTransferFunction_sRGB as String)

        // Its first and its last frame, as the film is composed at those moments. Loosely, as a
        // movie's packing softens edges.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let moments = FilmExport.moments(of: b, fps: settings.fps)
        #expect(moments.count == 6)
        let size = FilmExport.size(of: b, settings: settings)
        var frames: [Pixels] = []
        for k in [0, moments.count - 1] {
            let read = try Pixels(await generator.image(at: CMTime(value: CMTimeValue(k), timescale: 10)).image)
            let made = try Pixels(#require(FilmExport.frame(of: b, at: moments[k], size: size, assets: nil)))
            #expect(read.width == made.width && read.height == made.height)
            let apart = read.distance(to: made)
            #expect(apart.mean < 4, "frame \(k): \(apart)")
            frames.append(read)
        }
        // And the two are not the same picture: the layer has crossed over.
        #expect(frames[0].shows(red, at: 60, 60, within: 30) && !frames[1].shows(red, at: 60, 60, within: 30))
        #expect(frames[0].distance(to: frames[1]).mean > 8)
    }

    @Test func cancellingRemovesTheFileAndSaysSo() async throws {
        let b = shortFilm(3), url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let told = Told()
        let task = Task {
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 30)) { done in
                told.all.append(done)
                guard done > 0.2, !told.began else { return }
                told.began = FileManager.default.fileExists(atPath: url.path)
                told.task?.cancel()
            }
        }
        told.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
        // It had begun, it stopped well before the end, and nothing is left of it.
        #expect(told.began)
        #expect((told.all.last ?? 1) < 0.5, "\(told.all.last ?? -1)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFileAlreadyThereIsReplaced() async throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)
        try await FilmExport.write(shortFilm(0.3), assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 10)) { _ in }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.3) < 0.1, "\(duration)")
    }

    /// How long a film takes to write: three seconds at 60 frames a second of an 800 by 600
    /// artboard at two pixels to the point. Run with `TEST_RUNNER_BEZZLE_FILM_TIMING=1` before
    /// `xcodebuild`; the answer is written to `$TMPDIR/bezzle-film-timing.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEZZLE_FILM_TIMING"] != nil))
    func timesAThreeSecondFilm() async throws {
        var b = board(CGSize(width: 800, height: 600))
        b.film = Film(length: 3)
        var layers: [Node] = []
        for i in 0..<12 {
            var card = box("Card \(i)", CGRect(x: 40 + CGFloat(i % 4) * 185, y: 40 + CGFloat(i / 4) * 180, width: 165, height: 160), [red, blue, green][i % 3])
            card.cornerRadius = 18
            card.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.3), x: 0, y: 6, blur: 14)
            if i % 2 == 0 { card.apply(.rise, at: Double(i) * 0.1, frame: card.frame, board: b.frame.size) }
            if i % 4 == 1 { card.apply(.flip, at: 0.4 + Double(i) * 0.1, frame: card.frame, board: b.frame.size) }
            if i == 7 { card.apply(.focus, at: 1, frame: card.frame, board: b.frame.size) }
            layers.append(card)
            var label = Node(kind: .text, name: "Label \(i)", frame: CGRect(x: card.frame.minX + 12, y: card.frame.minY + 12, width: 140, height: 30))
            label.text = "Card number \(i)"
            label.fill.color = .white
            layers.append(label)
        }
        b.children = layers
        b.setKey(.cameraZoom, [1], at: 0)
        b.setKey(.cameraZoom, [1.6], at: 2.5)
        b.setKey(.cameraMove, [0, 0], at: 0)
        b.setKey(.cameraMove, [120, -60], at: 2.5)
        b.setKey(.cameraTilt, [0], at: 1)
        b.setKey(.cameraTilt, [24], at: 2.8)
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ContinuousClock()
        var lines: [String] = []
        for run in 1...3 {
            let took = try await clock.measure { try await FilmExport.write(b, assets: nil, to: url) { _ in } }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            lines.append("run \(run): \(took) for \(FilmExport.moments(of: b, fps: 60).count) frames of \(FilmExport.size(of: b, settings: FilmExport.Settings())), \(b.filmPieces().count) pieces, \(bytes) bytes")
        }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-film-timing.txt"), atomically: true, encoding: .utf8)
    }
}
