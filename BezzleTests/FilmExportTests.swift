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

    @Test func aFilmWithNoMotionIsTheArtboardStandingStill() throws {
        var b = board()
        var round = box("Round", CGRect(x: 20, y: 16, width: 90, height: 60), red)
        round.cornerRadius = 14
        b.children = [round, box("Other", CGRect(x: 96, y: 70, width: 70, height: 50), blue)]
        // With no keys it runs as long as the shortest film does, and every moment of it is the design.
        #expect(b.filmLength == MotionTiming.shortest)
        #expect(FilmExport.moments(of: b, fps: 30).count == 60 && FilmExport.moments(of: b, fps: 60).count == 120)
        let plain = try Pixels(#require(Renderer.image(of: b, scale: 1)))
        for t in [0, 0.9, 2] {
            let apart = try frame(of: b, at: t).distance(to: plain)
            #expect(apart.most <= 3, "\(t): \(apart)")
        }
        // An artboard with nothing on it, likewise.
        let bare = try frame(of: board(), at: 0.5)
        #expect(bare.shows(.white, at: 3, 3) && bare.shows(.white, at: 100, 80))
    }

    @Test func aBackdropThatIsNotSolidLiesOnBlack() throws {
        var b = board()
        b.fill.color = blue
        b.setKey(.cameraZoom, [0.5], at: 0)
        // Seen from further away, the backdrop shows round the artboard.
        b.film = Film(backdrop: RGBA(r: 1, g: 0.5, b: 0))
        var film = try frame(of: b, at: 0)
        #expect(film.shows(RGBA(r: 1, g: 0.5, b: 0), at: 4, 4, within: 2), "\(film[4, 4])")
        #expect(film.shows(blue, at: 100, 80))
        // Half there, it is half as bright: a movie has nothing to show through to.
        b.film = Film(backdrop: RGBA(r: 1, g: 0.5, b: 0, a: 0.5))
        film = try frame(of: b, at: 0)
        #expect(film.shows(RGBA(r: 0.5, g: 0.25, b: 0), at: 4, 4, within: 2), "\(film[4, 4])")
        #expect(film.shows(RGBA(r: 0.5, g: 0.25, b: 0), at: 196, 156, within: 2) && film.shows(blue, at: 100, 80))
        // Not there at all, black.
        b.film = Film(backdrop: RGBA(r: 1, g: 1, b: 1, a: 0))
        #expect(try frame(of: b, at: 0).shows(.black, at: 4, 4, within: 1))
    }

    /// A folder of a design's files with one picture in it: two by two, red and blue over green and black.
    private func files() throws -> (folder: URL, assets: Assets) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFilmFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ctx = try #require(Renderer.bitmap(CGSize(width: 2, height: 2)))
        for (x, y, color) in [(0, 1, RGBA(r: 1, g: 0, b: 0)), (1, 1, RGBA(r: 0, g: 0, b: 1)), (0, 0, RGBA(r: 0, g: 1, b: 0)), (1, 0, RGBA.black)] {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        let squares = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: squares).representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("squares.png"))
        return (folder, Assets(folder: folder))
    }

    /// An artboard with that picture filling a layer that moves, and filling one that does not.
    private func pictured() -> Node {
        var b = board()
        b.film = Film(length: 0.4)
        var moving = Node(kind: .rectangle, name: "Moving", frame: CGRect(x: 10, y: 10, width: 80, height: 80))
        moving.fill.image = ImageFill(asset: "squares.png", mode: .stretch, size: CGSize(width: 2, height: 2))
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [40, 30], at: 0.4, ease: .linear)
        var still = Node(kind: .rectangle, name: "Still", frame: CGRect(x: 150, y: 110, width: 40, height: 40))
        still.fill.image = ImageFill(asset: "squares.png", mode: .stretch, size: CGSize(width: 2, height: 2))
        b.children = [still, moving]
        return b
    }

    @Test func aPictureFromTheDesignsFilesShowsInAFrame() throws {
        let (folder, assets) = try files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let b = pictured(), size = CGSize(width: 200, height: 160)
        let green = RGBA(r: 0, g: 1, b: 0), red = RGBA(r: 1, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 1)
        for (t, dx, dy) in [(0.0, 0, 0), (0.4, 40, 30)] {
            let film = try Pixels(#require(FilmExport.frame(of: b, at: t, size: size, assets: assets)))
            // The moving layer's four quarters, where the move has taken them.
            #expect(film.shows(red, at: 30 + dx, 30 + dy, within: 40), "\(t): \(film[30 + dx, 30 + dy])")
            #expect(film.shows(blue, at: 70 + dx, 30 + dy, within: 40) && film.shows(green, at: 30 + dx, 70 + dy, within: 40) && film.shows(.black, at: 70 + dx, 70 + dy, within: 40), "\(t)")
            // And the one that does not move, drawn with what lies still.
            #expect(film.shows(red, at: 160, 120, within: 40) && film.shows(.black, at: 180, 140, within: 40), "\(t)")
        }
        // The same as the artboard drawn with its files at rest.
        let plain = try Pixels(#require(Renderer.image(of: b, scale: 1, assets: assets)))
        let apart = try Pixels(#require(FilmExport.frame(of: b, at: 0, size: size, assets: assets))).distance(to: plain)
        #expect(apart.most <= 3, "\(apart)")
        // Without its files there is no picture to show.
        let bare = try Pixels(#require(FilmExport.frame(of: b, at: 0, size: size, assets: nil)))
        #expect(!bare.shows(red, at: 30, 30, within: 40) && !bare.shows(blue, at: 70, 30, within: 40))
    }

    @Test func liftedLayersCoverOneAnotherByTheirHeight() throws {
        var under = box("Under", CGRect(x: 40, y: 40, width: 80, height: 80), red)
        under.setKey(.lift, [0], at: 0, ease: .linear)
        under.setKey(.lift, [100], at: 1, ease: .linear)
        var over = box("Over", CGRect(x: 80, y: 60, width: 80, height: 80), blue)
        over.setKey(.lift, [40], at: 0)
        // Straight down, and under a camera tipped back, which shows their heights apart.
        for tilt in [0.0, 20.0] {
            var b = board()
            b.children = [under, over]
            if tilt != 0 { b.setKey(.cameraTilt, [tilt], at: 0) }
            let pieces = b.filmPieces()
            #expect(pieces.map(\.kind) == [.ground, .layer, .layer])
            for (t, top) in [(0.0, blue), (0.3, blue), (0.5, red), (1.0, red)] {
                let camera = b.camera(at: t)
                let lower = b.placement(of: pieces[1], at: t, camera: camera), upper = b.placement(of: pieces[2], at: t, camera: camera)
                #expect(b.filmOrder(pieces, [FilmPlacement(), lower, upper]) == (top == blue ? [0, 1, 2] : [0, 2, 1]), "tilt \(tilt) at \(t)")
                // A place in the frame that both cover: a point of the one above in the list where
                // the other shows too, well inside it.
                let inside = under.frame.insetBy(dx: 6, dy: 6)
                let points = stride(from: 86.0, through: 154, by: 4).flatMap { x in stride(from: 66.0, through: 134, by: 4).map { CGPoint(x: x, y: $0) } }
                let both = points.first { p in lower.map.back(upper.map(p)).map { inside.contains($0) } == true }
                let at = upper.map(try #require(both, "tilt \(tilt) at \(t)"))
                let film = try frame(of: b, at: t)
                #expect(film.shows(top, at: Int(at.x.rounded()), Int(at.y.rounded())), "tilt \(tilt) at \(t): \(film[Int(at.x.rounded()), Int(at.y.rounded())])")
                // Where only one of them is, it shows whatever the order.
                let alone = upper.map(CGPoint(x: 150, y: 130))
                #expect(film.shows(blue, at: Int(alone.x.rounded()), Int(alone.y.rounded())), "tilt \(tilt) at \(t)")
            }
        }
    }

    @Test func aLayerLiftedToTheEyeAndPastItIsLeftOut() throws {
        // The camera rests 600 points above this artboard.
        var b = board()
        #expect(FilmLens.distance(for: b.frame.size) == 600)
        var near = box("Near", CGRect(x: 80, y: 60, width: 40, height: 40), red)
        near.setKey(.lift, [0], at: 0, ease: .linear)
        near.setKey(.lift, [1200], at: 2, ease: .linear)
        b.children = [box("Still", CGRect(x: 10, y: 10, width: 30, height: 30), blue), near]
        func reds(_ film: Pixels) -> Int { (0..<film.height).reduce(0) { $0 + film.run(of: red, inRow: $1).count } }
        // Half way up to the eye it shows twice as large, and close under it, it fills the frame.
        let half = try frame(of: b, at: 0.5).run(of: red, inRow: 80)
        #expect(abs(half.start - 60) <= 1 && abs(half.count - 80) <= 2, "\(half)")
        #expect(try reds(frame(of: b, at: 0.95)) == 200 * 160)
        // At the eye and past it nothing of it shows, and the rest is as it was.
        for t in [1, 1.01, 1.5, 2] {
            let film = try frame(of: b, at: t)
            #expect(reds(film) == 0, "\(t)")
            #expect(film.shows(blue, at: 25, 25) && film.shows(.white, at: 100, 80) && film.shows(.white, at: 190, 150), "\(t)")
        }
    }

    @Test func anArtboardReachingBehindTheEyeStillShowsWhatLiesInFront() throws {
        let page = RGBA(r: 0.1, g: 0.6, b: 0.3)
        // Two still boxes, near the top and at the foot: one piece, as tall as the artboard.
        var plain = board(CGSize(width: 200, height: 200))
        plain.film = Film(backdrop: page)
        plain.children = [box("Top", CGRect(x: 90, y: 10, width: 20, height: 20), red), box("Foot", CGRect(x: 90, y: 180, width: 20, height: 15), blue)]
        #expect(plain.filmPieces().map(\.kind) == [.ground, .run])
        // Close, tipped back and looking at the top, also rolled and swung: the foot of the sheet,
        // and of what lies still on it, is behind the eye.
        for (roll, swing) in [(0.0, 0.0), (25.0, 0.0), (-40.0, 15.0), (0.0, 30.0)] {
            var b = plain
            b.setKey(.cameraZoom, [5], at: 0)
            b.setKey(.cameraTilt, [60], at: 0)
            b.setKey(.cameraMove, [0, -80], at: 0)
            b.setKey(.cameraRoll, [roll], at: 0)
            b.setKey(.cameraSwing, [swing], at: 0)
            let ground = FilmLens.ground(b.camera(at: 0), size: b.frame.size)
            let behind = [CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)].filter { ground.depth(at: $0) <= 0 }.count
            #expect(behind > 0 && behind < 4 && ground.depth(at: CGPoint(x: 100, y: 20)) > 0, "roll \(roll), swing \(swing)")
            let film = try frame(of: b, at: 0)
            var checked = 0
            func expect(_ color: RGBA, at p: CGPoint, _ what: String) {
                let q = ground(p), x = Int(q.x.rounded()), y = Int(q.y.rounded())
                // Away from the frame's own edge.
                guard ground.depth(at: p) > 1, x >= 2, y >= 2, x < film.width - 2, y < film.height - 2 else { return }
                checked += 1
                #expect(film.shows(color, at: x, y, within: 12), "roll \(roll), swing \(swing): \(what) at \(p) shows \(film[x, y]) at \(x), \(y)")
            }
            // The box near the top, where the film's arithmetic has it.
            for p in [CGPoint(x: 100, y: 20), CGPoint(x: 93, y: 13), CGPoint(x: 107, y: 13), CGPoint(x: 107, y: 27), CGPoint(x: 93, y: 27)] { expect(red, at: p, "the box") }
            // Round it the sheet, and past the sheet's top edge the backdrop.
            for p in [CGPoint(x: 84, y: 20), CGPoint(x: 116, y: 20), CGPoint(x: 100, y: 4), CGPoint(x: 100, y: 36), CGPoint(x: 100, y: 50)] { expect(.white, at: p, "the sheet") }
            for p in [CGPoint(x: 100, y: -5), CGPoint(x: 80, y: -8), CGPoint(x: 120, y: -8)] { expect(page, at: p, "the backdrop") }
            #expect(checked >= 7, "roll \(roll), swing \(swing): \(checked)")
        }
    }

    @Test func seenEdgeOnNothingOfALayerShows() throws {
        var b = board()
        // Swung and tipped a quarter turn about lines through the frame's middle, where the eye is over.
        var door = box("Door", CGRect(x: 60, y: 20, width: 80, height: 40), red)
        door.setKey(.swing, [0], at: 0, ease: .linear)
        door.setKey(.swing, [180], at: 2, ease: .linear)
        var lid = box("Lid", CGRect(x: 20, y: 60, width: 40, height: 40), blue)
        lid.setKey(.tilt, [0], at: 0, ease: .linear)
        lid.setKey(.tilt, [-90], at: 1, ease: .linear)
        b.children = [door, lid]
        func count(_ color: RGBA, _ film: Pixels) -> Int { (0..<film.height).reduce(0) { $0 + film.run(of: color, inRow: $1).count } }
        // Lying flat they show whole, give or take the pixels along their edges.
        let rest = try frame(of: b, at: 0)
        #expect(abs(count(red, rest) - 80 * 40) <= 240 && abs(count(blue, rest) - 40 * 40) <= 160, "\(count(red, rest)) and \(count(blue, rest))")
        // Narrower and narrower on the way there.
        let most = try frame(of: b, at: 0.9)
        #expect(count(red, most) > 0 && count(red, most) < 80 * 40 / 4, "\(count(red, most))")
        #expect(count(blue, most) > 0 && count(blue, most) < 40 * 40 / 4, "\(count(blue, most))")
        // Edge on.
        let edge = try frame(of: b, at: 1)
        #expect(count(red, edge) == 0 && count(blue, edge) == 0, "\(count(red, edge)) and \(count(blue, edge))")
        #expect(edge.shows(.white, at: 100, 40) && edge.shows(.white, at: 40, 80))
        // Swung on round, its back shows, as large as its front did.
        let back = try frame(of: b, at: 2)
        #expect(abs(count(red, back) - 80 * 40) <= 80, "\(count(red, back))")
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
        /// Whether anything was where the movie is to go before it was whole.
        var early = false
        /// How a save through the store ended, and whether the desk was clear when it said so.
        var ended = false
        var failure: Error?
        var clear = false
    }

    /// What a movie's file holds: how many frames, how large, how many a second and for how long.
    private func read(_ url: URL) async throws -> (frames: Int, size: CGSize, rate: Float, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
        let seconds = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        return (frames, size, rate, seconds)
    }

    /// A frame of a movie, by its number.
    private func frame(_ k: Int, of url: URL, fps: Int) async throws -> Pixels {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try Pixels(await generator.image(at: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))).image)
    }

    /// Waits for something that the main thread brings about meanwhile.
    private func wait(for what: String, limit: Duration = .seconds(120), until done: () -> Bool) async throws {
        let clock = ContinuousClock(), began = clock.now
        while !done() {
            guard clock.now - began < limit else {
                Issue.record("\(what) did not come within \(limit).")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
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
        // The movie is written out of the way until it is whole.
        let work = FilmExport.workFile(for: url)
        let told = Told()
        let task = Task {
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 30)) { done in
                told.all.append(done)
                guard done > 0.2, !told.began else { return }
                told.began = FileManager.default.fileExists(atPath: work.path)
                told.early = FileManager.default.fileExists(atPath: url.path)
                told.task?.cancel()
            }
        }
        told.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
        // It had begun, never where the movie was to go; it stopped well before the end, and
        // nothing is left of it in either place.
        #expect(told.began && !told.early)
        #expect((told.all.last ?? 1) < 0.5, "\(told.all.last ?? -1)")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test func aFileAlreadyThereIsReplaced() async throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)
        try await FilmExport.write(shortFilm(0.3), assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 10)) { _ in }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.3) < 0.1, "\(duration)")
    }

    @Test func aPictureFromTheDesignsFilesShowsInTheMovie() async throws {
        let (folder, assets) = try files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let b = pictured(), url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try await FilmExport.write(b, assets: assets, to: url, settings: FilmExport.Settings(scale: 1, fps: 10)) { _ in }
        let first = try await frame(0, of: url, fps: 10), last = try await frame(3, of: url, fps: 10)
        // The moving layer's red quarter, at the start and three frames on, thirty points across.
        #expect(first.shows(RGBA(r: 1, g: 0, b: 0), at: 30, 30, within: 50), "\(first[30, 30])")
        #expect(last.shows(RGBA(r: 1, g: 0, b: 0), at: 60, 52, within: 50) && last.shows(.white, at: 20, 20, within: 30), "\(last[60, 52])")
        #expect(first.shows(RGBA(r: 0, g: 0, b: 1), at: 70, 30, within: 50) && first.shows(RGBA(r: 1, g: 0, b: 0), at: 160, 120, within: 50))
    }

    @Test func aFilmThatPlaysOnceRestsOnItsLastMomentInTheMovieToo() async throws {
        // A layer crossing in half a second: at ten frames a second, twenty points a frame.
        var b = board(CGSize(width: 160, height: 120))
        b.film = Film(length: 0.5)
        var moving = box("Moving", CGRect(x: 10, y: 40, width: 40, height: 40), red)
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [100, 0], at: 0.5, ease: .linear)
        b.children = [moving]
        var starts: [Bool: Int] = [:]
        for once in [false, true] {
            b.film?.once = once
            let url = scratch()
            defer { try? FileManager.default.removeItem(at: url) }
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 10)) { _ in }
            let movie = try await read(url)
            #expect(movie.frames == 5 && abs(movie.seconds - 0.5) < 0.05, "\(once): \(movie)")
            starts[once] = try await frame(4, of: url, fps: 10).run(of: red, inRow: 60).start
        }
        // Going round, its last frame is one short of the end, as the start follows it. Played
        // once, the movie rests where the film does.
        #expect(abs((starts[false] ?? 0) - 90) <= 2 && abs((starts[true] ?? 0) - 110) <= 2, "\(starts)")
    }

    @Test func theMovieHasAsManyFramesASecondAsWereAskedFor() async throws {
        let b = shortFilm(0.5)
        for fps in [30, 60] {
            let url = scratch()
            defer { try? FileManager.default.removeItem(at: url) }
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: fps)) { _ in }
            let movie = try await read(url)
            #expect(movie.frames == fps / 2, "\(fps): \(movie)")
            #expect(abs(movie.rate - Float(fps)) < 0.1 && abs(movie.seconds - 0.5) < 0.02, "\(fps): \(movie)")
            #expect(movie.size == CGSize(width: 160, height: 120))
        }
    }

    @Test func theMovieIsAsLargeAsItsScaleSaysAndNoLargerThanAMovieMayBe() async throws {
        let b = shortFilm(0.2)
        for scale in [1.0, 2, 3] {
            let url = scratch()
            defer { try? FileManager.default.removeItem(at: url) }
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: scale, fps: 10)) { _ in }
            let movie = try await read(url)
            #expect(movie.size == CGSize(width: 160 * scale, height: 120 * scale) && movie.frames == 2, "\(scale): \(movie)")
        }
        // A square artboard that would be 4200 pixels across at three to the point: the movie is
        // as large as one may be, which is the largest there is, and it is whole.
        var large = board(CGSize(width: 1400, height: 1400))
        large.film = Film(length: 0.2)
        var moving = box("Moving", CGRect(x: 100, y: 100, width: 400, height: 400), red)
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [600, 0], at: 0.2, ease: .linear)
        large.children = [moving]
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try await FilmExport.write(large, assets: nil, to: url, settings: FilmExport.Settings(scale: 3, fps: 10)) { _ in }
        let movie = try await read(url)
        #expect(movie.size == CGSize(width: FilmExport.most, height: FilmExport.most) && movie.frames == 2, "\(movie)")
        let first = try await frame(0, of: url, fps: 10)
        #expect(first.width == 3840 && first.height == 3840)
        // The layer's middle, 300 points in, and its right edge at 500: 2.74 pixels to the point.
        #expect(first.shows(red, at: 823, 823, within: 30) && first.shows(.white, at: 3000, 3000, within: 30))
        #expect(first.shows(red, at: 1365, 823, within: 30) && first.shows(.white, at: 1378, 823, within: 30), "\(first[1365, 823]) and \(first[1378, 823])")
    }

    @Test func aMovieAlreadyThereStaysAsItWasWhenTheSaveIsStopped() async throws {
        let b = shortFilm(3), url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Data("the movie saved before".utf8)
        try old.write(to: url)
        let told = Told()
        let task = Task {
            try await FilmExport.write(b, assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 30)) { done in
                guard done > 0.2, !told.began else { return }
                told.began = true
                // With the new one half written, the one from before has not been touched.
                told.early = (try? Data(contentsOf: url)) == old
                told.task?.cancel()
            }
        }
        told.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(told.began && told.early)
        #expect(try Data(contentsOf: url) == old)
        #expect(!FileManager.default.fileExists(atPath: FilmExport.workFile(for: url).path))
    }

    /// A folder of its own in the temporary one, which the test may close to writing.
    private func ownFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFilmFolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func allow(writing: Bool, in folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: writing ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    @Test func aMovieAlreadyThereStaysAsItWasWhenTheNewOneCannotTakeItsPlace() async throws {
        let folder = try ownFolder()
        defer {
            allow(writing: true, in: folder)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("Film.mp4"), old = Data("the movie saved before".utf8)
        try old.write(to: url)
        // Its folder is closed to writing while the film is being made into frames.
        let told = Told()
        do {
            try await FilmExport.write(shortFilm(0.5), assets: nil, to: url, settings: FilmExport.Settings(scale: 1, fps: 10)) { done in
                told.all.append(done)
                guard done > 0.3, !told.began else { return }
                told.began = true
                self.allow(writing: false, in: folder)
            }
        } catch {
            told.failure = error
        }
        #expect(told.began)
        let said = try #require(told.failure)
        #expect(!(said is CancellationError), "\(said)")
        // It was never said to be whole; the movie from before is, and nothing is left over.
        #expect(told.all.last != 1, "\(told.all)")
        #expect(try Data(contentsOf: url) == old)
        #expect(!FileManager.default.fileExists(atPath: FilmExport.workFile(for: url).path))
    }

    @Test func aPlaceThatCannotBeWrittenToIsFoundOutBeforeAnyFrameIsMade() async throws {
        let folder = try ownFolder()
        defer {
            allow(writing: true, in: folder)
            try? FileManager.default.removeItem(at: folder)
        }
        let told = Told(), b = shortFilm(0.3), settings = FilmExport.Settings(scale: 1, fps: 10)
        // A folder that is not there.
        let nowhere = folder.appendingPathComponent("Missing/Film.mp4")
        await #expect(throws: (any Error).self) { try await FilmExport.write(b, assets: nil, to: nowhere, settings: settings) { told.all.append($0) } }
        // A folder closed to writing, with nothing in it and with a movie that is closed too.
        let closed = folder.appendingPathComponent("Film.mp4"), old = Data("the movie saved before".utf8)
        allow(writing: false, in: folder)
        await #expect(throws: (any Error).self) { try await FilmExport.write(b, assets: nil, to: closed, settings: settings) { told.all.append($0) } }
        allow(writing: true, in: folder)
        try old.write(to: closed)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: closed.path)
        allow(writing: false, in: folder)
        await #expect(throws: (any Error).self) { try await FilmExport.write(b, assets: nil, to: closed, settings: settings) { told.all.append($0) } }
        // Not a frame was made for any of them, and nothing is left of the tries.
        #expect(told.all.isEmpty, "\(told.all)")
        #expect(try Data(contentsOf: closed) == old)
        #expect(!FileManager.default.fileExists(atPath: nowhere.path))
        for url in [nowhere, closed] { #expect(!FileManager.default.fileExists(atPath: FilmExport.workFile(for: url).path)) }
    }

    @Test func aFilmLongerThanAMovieMayBeIsRefusedWholeAndNotCutShort() async throws {
        let told = Told(), settings = FilmExport.Settings(scale: 1, fps: 60)
        let url = scratch(), old = Data("the movie saved before".utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try old.write(to: url)
        // As a design from elsewhere may say it: a million seconds, more seconds than frames can
        // be counted in, and a key set far past any film.
        var million = shortFilm(0.3)
        million.film = Film(length: 1_000_000)
        var beyond = shortFilm(0.3)
        beyond.film = Film(length: 1e300)
        var keyed = shortFilm(0.3)
        keyed.film = nil
        keyed.setKey(.cameraZoom, [2], at: 1e12, ease: .linear)
        let most = Int(FilmExport.longest) * 60
        for b in [million, beyond, keyed] {
            #expect(throws: FilmExport.TooLong.self) { try FilmExport.check(b) }
            await #expect(throws: FilmExport.TooLong.self) {
                try await FilmExport.write(b, assets: nil, to: url, settings: settings) { told.all.append($0) }
            }
            // Asked for all the same, its moments are no more than the longest movie has.
            #expect(FilmExport.moments(of: b, fps: 60).count == most)
        }
        // Not a frame was made, the movie from before is as it was, and nothing is left over.
        #expect(told.all.isEmpty, "\(told.all)")
        #expect(try Data(contentsOf: url) == old)
        #expect(!FileManager.default.fileExists(atPath: FilmExport.workFile(for: url).path))
        // A length without end, one that is no number, and more frames a second than any movie
        // has: none of them is more than can be counted.
        var endless = shortFilm(0.3)
        endless.film = Film(length: .infinity)
        #expect(FilmExport.moments(of: endless, fps: 60).count <= most)
        endless.film = Film(length: .nan)
        #expect(FilmExport.moments(of: endless, fps: .max).count <= Int(FilmExport.longest) * FilmExport.fastest)
        // It is said in words, with what to do about it.
        let said = FilmExport.TooLong()
        #expect(said.errorDescription?.isEmpty == false && said.recoverySuggestion?.contains("hour") == true)
        // A film as long as a movie may be is taken, and one half a second longer is not.
        var hour = board()
        hour.film = Film(length: FilmExport.longest)
        #expect(throws: Never.self) { try FilmExport.check(hour) }
        #expect(FilmExport.moments(of: hour, fps: 30).count == 108_000)
        hour.film = Film(length: FilmExport.longest + 0.5)
        #expect(throws: FilmExport.TooLong.self) { try FilmExport.check(hour) }
    }

    // MARK: Saving from the desk

    /// A bench in Animate with a layer that crosses artboard A for as long as the film runs.
    private func desk(_ length: Double) -> Bench {
        var moving = box("Moving", CGRect(x: 20, y: 20, width: 80, height: 80), red)
        moving.setKey(.move, [0, 0], at: 0, ease: .linear)
        moving.setKey(.move, [280, 180], at: length, ease: .linear)
        let bench = Bench(extra: [box("Still", CGRect(x: 300, y: 20, width: 60, height: 60), blue), moving])
        bench.store.show(.animate)
        // The view's glide to the film's artboard is no part of what is tested here.
        bench.store.glide.stop()
        bench.store.viewport = Viewport(origin: .zero, zoom: 1)
        // As long as that, and not the two seconds a film runs at least when nothing is said.
        bench.step { bench.store.setFilm("Film") { $0.length = length } }
        return bench
    }

    /// Saves the bench's film through the store, as the panel does once it knows where, and
    /// notes how it ended. Always with someone to tell: left to itself the store shows the movie
    /// in the Finder, or says what went wrong in a window.
    private func save(_ bench: Bench, to url: URL, fps: Int = 30, _ told: Told) -> Bool {
        bench.store.writeFilm(to: url, scale: 1, fps: fps) { failure in
            told.failure = failure
            told.clear = bench.store.film.exporting == nil && bench.store.film.saving == nil
            told.ended = true
        }
    }

    private func isThere(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func savingTellsTheDeskHowFarItIsAndClearsItWhenTheMovieIsWhole() async throws {
        let bench = desk(1.5), store = bench.store, url = scratch(), told = Told()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.film.exporting == nil && store.film.saving == nil)
        #expect(save(bench, to: url, told))
        // At once, before a frame is made.
        #expect(store.film.exporting == 0 && store.film.saving != nil)
        try await wait(for: "the movie") {
            if let done = store.film.exporting, done != told.all.last { told.all.append(done) }
            return told.ended
        }
        #expect(told.failure == nil && told.clear)
        #expect(store.film.exporting == nil && store.film.saving == nil)
        #expect(told.all.first == 0 && told.all == told.all.sorted() && told.all.count >= 4 && (told.all.last ?? 2) <= 1, "\(told.all)")
        let movie = try await read(url)
        #expect(movie.frames == 45 && movie.size == CGSize(width: 400, height: 300), "\(movie)")
        #expect(!isThere(FilmExport.workFile(for: url)))
        // Its first frame is the film's start: the layer at rest, the still one beside it.
        let first = try await frame(0, of: url, fps: 30)
        #expect(first.shows(red, at: 60, 60, within: 30) && first.shows(blue, at: 330, 50, within: 30) && first.shows(.white, at: 200, 250, within: 30))
        // The film itself is as it was.
        #expect(store.filmTime == 0 && !store.film.playing)
    }

    @Test func stoppingASaveEndsItAndLeavesThingsAsTheyWere() async throws {
        let bench = desk(4), store = bench.store, url = scratch(), told = Told()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Data("the movie saved before".utf8)
        try old.write(to: url)
        #expect(save(bench, to: url, fps: 60, told))
        try await wait(for: "a fifth of the movie") { (store.film.exporting ?? 0) > 0.2 || told.ended }
        #expect(!told.ended)
        #expect(isThere(FilmExport.workFile(for: url)))
        store.stopSavingFilm()
        try await wait(for: "the save to end") { told.ended }
        #expect(told.failure is CancellationError && told.clear)
        #expect(store.film.exporting == nil && store.film.saving == nil)
        // The movie from before is as it was, and nothing is left of the new one.
        #expect(try Data(contentsOf: url) == old)
        #expect(!isThere(FilmExport.workFile(for: url)))
        // Stopping with nothing being saved does nothing, and the film can be saved again.
        store.stopSavingFilm()
        let again = Told()
        #expect(save(bench, to: url, fps: 10, again))
        try await wait(for: "the movie") { again.ended }
        #expect(again.failure == nil && again.clear)
        #expect(try await read(url).frames == 40)
    }

    @Test func whileOneMovieIsBeingSavedAnotherIsRefused() async throws {
        let bench = desk(2), store = bench.store, first = scratch(), second = scratch(), told = Told(), other = Told()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(save(bench, to: first, told))
        #expect(!save(bench, to: second, other))
        try await wait(for: "some of the movie") { (store.film.exporting ?? 0) > 0.1 || told.ended }
        let far = store.film.exporting
        #expect(!save(bench, to: second, other))
        // The desk still tells of the first.
        #expect(store.film.exporting == far && store.film.saving != nil)
        try await wait(for: "the movie") { told.ended }
        #expect(told.failure == nil && !other.ended)
        #expect(isThere(first) && !isThere(second) && !isThere(FilmExport.workFile(for: second)))
        #expect(try await read(first).frames == 60)
        // Once it is whole, the next is taken.
        #expect(save(bench, to: second, fps: 10, other))
        try await wait(for: "the second movie") { other.ended }
        #expect(other.failure == nil && isThere(second))
    }

    @Test func savingAFilmThatPlaysStopsItWhereItWas() async throws {
        let bench = desk(1), store = bench.store, url = scratch(), told = Told()
        defer { try? FileManager.default.removeItem(at: url) }
        store.playFilm(fromStart: true)
        let began = try #require(store.film.pass?.began)
        #expect(store.filmStep(began + 0.4) && store.film.playing)
        #expect(save(bench, to: url, fps: 10, told))
        #expect(!store.film.playing && store.film.pass == nil)
        #expect(abs(store.film.time - 0.4) < 0.002 && store.film.live == store.film.time && store.film.head == store.film.time)
        try await wait(for: "the movie") { told.ended }
        #expect(told.failure == nil)
        // The movie is the whole film from its start, wherever the playhead was.
        #expect(try await read(url).frames == 10)
        let first = try await frame(0, of: url, fps: 10)
        #expect(first.shows(red, at: 60, 60, within: 30) && first.shows(.white, at: 150, 110, within: 30))
        #expect(abs(store.film.time - 0.4) < 0.002 && !store.film.playing)
    }

    @Test func aPlaceThatCannotBeWrittenToIsSaidAndTheDeskIsClearAgain() async throws {
        let bench = desk(1), store = bench.store, told = Told()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleFilmMissing-\(UUID().uuidString)/Film.mp4")
        #expect(save(bench, to: url, told))
        try await wait(for: "the save to end") { told.ended }
        let said = try #require(told.failure)
        #expect(!(said is CancellationError) && told.clear, "\(said)")
        #expect(store.film.exporting == nil && store.film.saving == nil)
        #expect(!isThere(url) && !isThere(FilmExport.workFile(for: url)))
        // And the film can be saved somewhere that can be.
        let good = scratch(), again = Told()
        defer { try? FileManager.default.removeItem(at: good) }
        #expect(save(bench, to: good, fps: 10, again))
        try await wait(for: "the movie") { again.ended }
        #expect(again.failure == nil && isThere(good))
    }

    @Test func aFilmTooLongForAMovieIsSaidAndTheDeskIsClearAgain() async throws {
        let bench = desk(1), store = bench.store, url = scratch(), told = Told()
        defer { try? FileManager.default.removeItem(at: url) }
        bench.step { store.setFilm("Film") { $0.length = 1_000_000 } }
        #expect(save(bench, to: url, told))
        try await wait(for: "the save to end") { told.ended }
        #expect(told.failure is FilmExport.TooLong && told.clear, "\(String(describing: told.failure))")
        #expect(store.film.exporting == nil && store.film.saving == nil)
        #expect(!isThere(url) && !isThere(FilmExport.workFile(for: url)))
        // Given a length a movie may have, it is saved.
        bench.step { store.setFilm("Film") { $0.length = 1 } }
        let again = Told()
        #expect(save(bench, to: url, fps: 10, again))
        try await wait(for: "the movie") { again.ended }
        #expect(again.failure == nil && isThere(url))
        #expect(try await read(url).frames == 10)
    }

    @Test func withNoFilmOnTheDeskNothingIsSaved() async throws {
        let url = scratch(), told = Told()
        // Never animated: no artboard's film is on the desk.
        let fresh = Bench(extra: [box("Still", CGRect(x: 20, y: 20, width: 60, height: 60), blue)])
        #expect(fresh.store.film.board == nil)
        #expect(!save(fresh, to: url, told))
        // Every artboard hidden, so that the desk has none to turn to.
        let bench = desk(1), store = bench.store
        bench.step { store.setHidden(true, [bench.a.id, bench.b.id]) }
        #expect(store.filmBoard == nil)
        #expect(!save(bench, to: url, told))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!told.ended && !isThere(url) && !isThere(FilmExport.workFile(for: url)))
        #expect(store.film.exporting == nil && store.film.saving == nil && fresh.store.film.exporting == nil)
    }

    /// How long a film takes to write: three seconds at 60 frames a second of an 800 by 600
    /// artboard at two pixels to the point. Run with `TEST_RUNNER_ANIMATE_FILM_TIMING=1` before
    /// `xcodebuild`; the answer is written to `$TMPDIR/bezzle-film-timing.txt`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_FILM_TIMING"] != nil))
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
