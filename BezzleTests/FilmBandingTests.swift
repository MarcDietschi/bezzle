import Testing
import AppKit
import AVFoundation
@testable import Bezzle

/// A film's gentle tones saved as a movie: a wide dark gradient, a card's soft glow, a blurred
/// shape and a slow fade. What shows as bands is how far the movie's values are from the exact
/// ones in the large, so that is what is measured: the mean of every 8 by 8 block of a frame
/// read back from the file against the mean it should have, in steps of a movie's eight bits,
/// beside how many values a part takes and how long one value runs along a row.
///
/// A ramp cut once to whole steps is 0.29 of a step off on average and half a step at most, and
/// no movie with eight bits does better without noise, which packing irons out again. That is
/// what an H.264 movie's gradients are now (0.28 to 0.29). Before tones were kept whole up to
/// that one cut they were 0.32 to 0.36 off, a blurred shape 0.43 to 0.46 where it is 0.35 to
/// 0.38 now, in bands up to a tenth wider. The bands themselves are eight bits' own, fourteen
/// across this ramp, and stay. With ten bits a step is a quarter as large: 54 values where
/// there were 14, a third as wide, 0.06 to 0.11 off.
///
/// The numbers are written down for whoever runs the tests: `$TMPDIR/bezzle-film-banding-…txt`.
@MainActor
struct FilmBandingTests {
    // MARK: The film

    /// Colours as a design has them, each a whole step of eight bits.
    private static func tone(_ r: Double, _ g: Double, _ b: Double) -> RGBA { RGBA(r: r / 255, g: g / 255, b: b / 255) }
    private static let dark = tone(9, 10, 18), lit = tone(26, 23, 56), page = tone(8, 9, 14)
    private static let size = CGSize(width: 960, height: 540)
    /// Where the two gradients lie, in the artboard's points.
    private static let rampBox = CGRect(x: 0, y: 0, width: 960, height: 140), fadeBox = CGRect(x: 0, y: 400, width: 960, height: 140)
    /// What is measured: of each gradient the strip that the glow and the blur between them do
    /// not reach, the glow beside its card, and the blurred shape with all that lies round it.
    private static let boxes = [
        ("ramp", CGRect(x: 0, y: 0, width: 960, height: 64)), ("fade", CGRect(x: 0, y: 476, width: 960, height: 64)),
        ("glow", CGRect(x: 70, y: 215, width: 72, height: 90)), ("soft", CGRect(x: 560, y: 160, width: 320, height: 210)),
    ]

    private static func ramp(_ name: String, _ frame: CGRect) -> Node {
        var ramp = Node(kind: .rectangle, name: name, frame: frame)
        ramp.fill.gradient = Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: dark), GradientStop(offset: 1, color: lit)],
                                      start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
        return ramp
    }

    /// How much of the fading ramp shows at a moment: from three tenths to all of it, evenly.
    private static func faded(at t: Double, of length: Double) -> Double { 0.3 + 0.7 * min(max(t / length, 0), 1) }

    /// A dark artboard, twice as large in the movie: a gentle gradient across it, a card with
    /// a wide glow, a blurred shape, and the same gradient fading in for as long as it runs.
    static func film(_ length: Double = 1) -> Node {
        var board = Node(kind: .artboard, name: "Tones", frame: CGRect(origin: CGPoint(x: 200, y: 80), size: size))
        board.fill.color = page
        board.film = Film(length: length)
        var card = Node(kind: .rectangle, name: "Glow", frame: CGRect(x: 150, y: 215, width: 150, height: 90))
        card.cornerRadius = 18
        card.fill.color = tone(31, 33, 51)
        card.shadow = Shadow(on: true, color: RGBA(r: 0.45, g: 0.55, b: 1, a: 0.4), x: 0, y: 0, blur: 80)
        var soft = Node(kind: .ellipse, name: "Soft", frame: CGRect(x: 620, y: 200, width: 200, height: 130))
        soft.fill.color = tone(77, 56, 140)
        soft.blur = Blur(radius: 40)
        var fading = ramp("Fading", fadeBox)
        fading.setKey(.fade, [faded(at: 0, of: length)], at: 0, ease: .linear)
        fading.setKey(.fade, [1], at: length, ease: .linear)
        board.children = [ramp("Ramp", rampBox), card, soft, fading]
        return board
    }

    /// The exact colour of the still ramp, and of the fading one at a moment, at a point.
    private static func rampColor(at p: CGPoint, faded opacity: Double = 1) -> (Double, Double, Double) {
        let u = Double(p.x / size.width)
        func mix(_ a: Double, _ b: Double, _ under: Double) -> Double { under + (a + (b - a) * u - under) * opacity }
        return (mix(dark.r, lit.r, page.r), mix(dark.g, lit.g, page.g), mix(dark.b, lit.b, page.b))
    }

    // MARK: Planes

    /// A frame as a movie holds it: luma for every pixel and two chromas for every four, in
    /// steps of eight bits, a deeper movie's in parts of them. Black is 16 and white 235.
    struct Planes {
        let width: Int, height: Int
        var y: [Float], cb: [Float], cr: [Float]

        /// A colour in sRGB as a movie's three numbers, exactly.
        static func packed(_ r: Double, _ g: Double, _ b: Double) -> (y: Float, cb: Float, cr: Float) {
            let luma: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let cb: Double = (b - luma) / 1.8556, cr: Double = (r - luma) / 1.5748
            return (Float(16 + 219 * luma), Float(128 + 224 * cb), Float(128 + 224 * cr))
        }

        /// With nothing in it yet.
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            y = [Float](repeating: 0, count: width * height)
            cb = [Float](repeating: 0, count: (width / 2) * (height / 2))
            cr = cb
        }

        /// Of a picture in sRGB, of any depth: what a movie would hold of it if it could hold
        /// every value exactly.
        init(_ image: CGImage) throws {
            self.init(width: image.width, height: image.height)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGBitmapInfo.floatComponents.rawValue
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let floats = try #require(ctx.data).assumingMemoryBound(to: Float.self), row = ctx.bytesPerRow / 4
            for py in 0..<height {
                for px in 0..<width {
                    let at = py * row + px * 4
                    let c = Self.packed(Double(floats[at]), Double(floats[at + 1]), Double(floats[at + 2]))
                    y[py * width + px] = c.y
                    guard px / 2 < width / 2, py / 2 < height / 2 else { continue }
                    let four = (py / 2) * (width / 2) + px / 2
                    cb[four] += c.cb / 4
                    cr[four] += c.cr / 4
                }
            }
        }

        /// Of a frame as the movie's reader hands it over, unpacked and nothing more.
        init(_ buffer: CVPixelBuffer) {
            self.init(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let deep = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            func value(_ base: UnsafeMutableRawPointer, _ at: Int, _ k: Int) -> Float {
                deep ? Float(base.load(fromByteOffset: at + k * 2, as: UInt16.self) >> 6) / 4 : Float(base.load(fromByteOffset: at + k, as: UInt8.self))
            }
            for py in 0..<height {
                for px in 0..<width { y[py * width + px] = value(luma, py * lumaRow, px) }
            }
            for py in 0..<height / 2 {
                for px in 0..<width / 2 {
                    cb[py * (width / 2) + px] = value(chroma, py * chromaRow, px * 2)
                    cr[py * (width / 2) + px] = value(chroma, py * chromaRow, px * 2 + 1)
                }
            }
        }
    }

    /// What a movie's file says of itself, and its frames by their numbers, as it holds them.
    struct Movie {
        var frames: [Int: Planes] = [:]
        var bits = 8
        var codec: CMFormatDescription.MediaSubType
        var transfer: String?
        var playable = false
        var count = 0
    }

    static func read(_ wanted: Set<Int>, of url: URL) async throws -> Movie {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        var movie = Movie(codec: format.mediaSubType)
        movie.bits = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int) ?? 8
        movie.transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let (playable, decodable) = (try await asset.load(.isPlayable), try await track.load(.isDecodable))
        movie.playable = playable && decodable
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: movie.bits > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            defer { movie.count += 1 }
            guard wanted.contains(movie.count), let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            movie.frames[movie.count] = Planes(buffer)
        }
        return movie
    }

    // MARK: Measuring

    /// How banded a part of a frame is.
    struct Banding: CustomStringConvertible {
        /// How many values its luma takes.
        var levels = 0
        /// The longest stretch of one value along a row, the middle one of all rows'.
        var run = 0
        /// The share of its 8 by 8 blocks that hold one value only.
        var flat = 0.0
        /// How far the means of its 8 by 8 blocks are from what they should be: luma on
        /// average and at most, and the chromas on average.
        var off = 0.0, most = 0.0, chroma = 0.0

        var description: String {
            String(format: "%4d levels, longest run %4d, %3.0f%% of blocks flat, luma off %.3f on average and %.2f at most, chroma %.3f",
                   levels, run, flat * 100, off, most, chroma)
        }
    }

    /// Measures the part of a frame that lies over `box` of the artboard, a little in from its
    /// edges, against the exact frame.
    static func banding(_ got: Planes, in box: CGRect, against exact: Planes) -> Banding {
        let k = CGFloat(got.width) / size.width
        // Whole blocks, on the grid the chromas lie on.
        let x0 = (Int((box.minX * k).rounded(.up)) + 8 + 7) / 8 * 8, x1 = (Int((box.maxX * k).rounded(.down)) - 8) / 8 * 8
        let y0 = (Int((box.minY * k).rounded(.up)) + 8 + 7) / 8 * 8, y1 = (Int((box.maxY * k).rounded(.down)) - 8) / 8 * 8
        var out = Banding()
        var values = Set<Float>(), runs: [Int] = []
        for y in y0..<y1 {
            var best = 1, run = 1
            for x in x0..<x1 {
                let v = got.y[y * got.width + x]
                values.insert(v)
                if x > x0 {
                    run = v == got.y[y * got.width + x - 1] ? run + 1 : 1
                    best = max(best, run)
                }
            }
            runs.append(best)
        }
        out.levels = values.count
        out.run = runs.sorted()[runs.count / 2]
        var flat = 0, blocks = 0, sum = 0.0, chroma = 0.0
        for by in stride(from: y0, to: y1, by: 8) {
            for bx in stride(from: x0, to: x1, by: 8) {
                var mean = 0.0, wanted = 0.0, same = true
                let first = got.y[by * got.width + bx]
                for y in by..<by + 8 {
                    for x in bx..<bx + 8 {
                        let v = got.y[y * got.width + x]
                        mean += Double(v)
                        same = same && v == first
                        wanted += Double(exact.y[y * got.width + x])
                    }
                }
                blocks += 1
                if same { flat += 1 }
                let off = (mean - wanted) / 64
                sum += off * off
                out.most = max(out.most, abs(off))
                var b = 0.0, r = 0.0
                for y in by / 2..<by / 2 + 4 {
                    for x in bx / 2..<bx / 2 + 4 {
                        let at = y * (got.width / 2) + x
                        b += Double(got.cb[at] - exact.cb[at])
                        r += Double(got.cr[at] - exact.cr[at])
                    }
                }
                chroma += (b / 16) * (b / 16) + (r / 16) * (r / 16)
            }
        }
        out.flat = Double(flat) / Double(max(blocks, 1))
        out.off = (sum / Double(max(blocks, 1))).squareRoot()
        out.chroma = (chroma / Double(max(blocks, 1) * 2)).squareRoot()
        return out
    }

    /// The exact frame at a moment where it can be worked out, the two ramps: everything else
    /// in it is left at nothing, and not to be measured against.
    static func exactRamps(at t: Double, length: Double, width: Int, height: Int) -> Planes {
        var planes = Planes(width: width, height: height)
        let k = size.width / CGFloat(width)
        for (box, opacity) in [(rampBox, 1.0), (fadeBox, faded(at: t, of: length))] {
            for py in Int(box.minY / k)..<Int(box.maxY / k) {
                for px in 0..<width {
                    let at = CGPoint(x: (CGFloat(px) + 0.5) * k, y: (CGFloat(py) + 0.5) * k)
                    let c = rampColor(at: at, faded: opacity), packed = Planes.packed(c.0, c.1, c.2)
                    planes.y[py * width + px] = packed.y
                    // Four pixels share a chroma: the mean of theirs.
                    let four = (py / 2) * (width / 2) + px / 2
                    planes.cb[four] += packed.cb / 4
                    planes.cr[four] += packed.cr / 4
                }
            }
        }
        return planes
    }

    private func scratch(_ name: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BezzleBanding-\(UUID().uuidString).\(name)")
    }

    private func note(_ lines: [String], as name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-film-banding-\(name).txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static let length = 1.0, fps = 30, shown = [0, 14, 29]

    /// The frame before any movie's steps have cut it.
    private func exact(_ board: Node, at t: Double, _ size: CGSize) throws -> Planes {
        try Planes(#require(FilmExport.frame(of: board, at: t, size: size, assets: nil, deep: true)))
    }

    /// Saves the film as a movie and measures it.
    private func measured(_ codec: FilmExport.Codec) async throws -> (worst: [String: Banding], movie: Movie, lines: [String]) {
        let board = Self.film(Self.length), settings = FilmExport.Settings(scale: 2, fps: Self.fps, codec: codec)
        // Kept, to be looked at or sent through a video site, when a folder is named for it.
        let kept = ProcessInfo.processInfo.environment["ANIMATE_BANDING_KEEP"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("tones-\(codec.rawValue).mp4")
        }
        let url = kept ?? scratch()
        defer { if kept == nil { try? FileManager.default.removeItem(at: url) } }
        if let kept {
            // And the film itself as a design, for a Bezzle elsewhere to make its movie of.
            var design = BezzleDocument()
            design.nodes = [board]
            let file = kept.deletingLastPathComponent().appendingPathComponent("tones.bezzle")
            try? FileManager.default.removeItem(at: file)
            try DesignFile.write(design, to: file)
        }
        let clock = ContinuousClock()
        let took = try await clock.measure { try await FilmExport.write(board, assets: nil, to: url, settings: settings) { _ in } }
        let size = FilmExport.size(of: board, settings: settings)
        return try await measure(url, as: codec.rawValue, said: "of \(FilmExport.bitRate(size, fps: Self.fps) / 1000) at most, written in \(took)")
    }

    /// Reads three frames of a movie of the film back and measures each part of each against
    /// the frame before it was cut to a movie's steps: the worst of the three for every part,
    /// the movie as it says it is, and what was found, in lines, which are written down too.
    private func measure(_ url: URL, as name: String, said: String = "") async throws -> (worst: [String: Banding], movie: Movie, lines: [String]) {
        let board = Self.film(Self.length)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let moments = FilmExport.moments(of: board, fps: Self.fps)
        let movie = try await Self.read(Set(Self.shown), of: url)
        let first = try #require(movie.frames[Self.shown[0]]), size = CGSize(width: first.width, height: first.height)
        var lines = ["\(name): \(first.width) by \(first.height), \(movie.codec), \(movie.bits) bit, \(movie.count) frames, \(Int(Double(bytes) * 8 / Self.length / 1000)) kbit/s \(said)"]
        var worst: [String: Banding] = [:]
        for k in Self.shown {
            let read = try #require(movie.frames[k]), whole = try exact(board, at: moments[k], size)
            #expect(read.width == whole.width && read.height == whole.height)
            for (part, box) in Self.boxes {
                let found = Self.banding(read, in: box, against: whole)
                lines.append("frame \(k), \(part): \(found)")
                var most = worst[part] ?? found
                most.levels = min(most.levels, found.levels)
                most.run = max(most.run, found.run)
                most.flat = max(most.flat, found.flat)
                most.off = max(most.off, found.off)
                most.most = max(most.most, found.most)
                most.chroma = max(most.chroma, found.chroma)
                worst[part] = most
            }
        }
        try note(lines, as: name)
        return (worst, movie, lines)
    }

    // MARK: The frame

    @Test func aFrameKeepsGentleTonesWholeUntilTheMovieCutsThem() throws {
        let board = Self.film(Self.length), settings = FilmExport.Settings(scale: 2, fps: Self.fps)
        let size = FilmExport.size(of: board, settings: settings)
        var lines: [String] = []
        for t in [0, 0.5] {
            let whole = try exact(board, at: t, size)
            // Where the exact values can be worked out, the two ramps, the frame has them: the
            // still one drawn deep, the fading one faded in numbers as fine.
            let ramps = Self.exactRamps(at: t, length: Self.length, width: whole.width, height: whole.height)
            for (name, box) in Self.boxes.prefix(2) {
                let found = Self.banding(whole, in: box, against: ramps)
                lines.append("whole frame at \(t), \(name), against the ramp worked out: \(found)")
                #expect(found.off < 0.02 && found.most < 0.06 && found.chroma < 0.02, "\(name) at \(t): \(found)")
            }
            // No part of it lies in flat patches: not the glow, which is a shadow, nor the blur.
            for (name, box) in Self.boxes {
                let found = Self.banding(whole, in: box, against: whole)
                lines.append("whole frame at \(t), \(name): \(found)")
                #expect(found.flat < 0.01, "\(name) at \(t): \(found)")
            }
            // The single frame is the same frame cut to eight bits to a colour, once: nowhere
            // further from it than rounding three colours can take a luma.
            let single = try Planes(#require(FilmExport.frame(of: board, at: t, size: size, assets: nil)))
            var furthest: Float = 0
            for i in single.y.indices { furthest = max(furthest, abs(single.y[i] - whole.y[i])) }
            #expect(furthest <= 0.45, "\(t): \(furthest)")
            for (name, box) in Self.boxes { lines.append("single frame at \(t), \(name): \(Self.banding(single, in: box, against: whole))") }
        }
        try note(lines, as: "frame")
    }

    @Test func piecesAreDrawnDeepOnlyWhereTonesAreGentle() throws {
        let board = Self.film()
        let pieces = board.filmPieces()
        var deep = 0
        for piece in pieces {
            let subject = FilmPictures.subject(of: piece, on: board, at: 0)
            let picture = try #require(FilmPictures.picture(of: subject, scale: 2, assets: nil, deep: true))
            // The sheet is one flat colour; everything on it is a gradient, a glow or a blur.
            #expect(subject.hasGentleTones == (piece.kind != .ground))
            #expect(picture.image.bitsPerComponent == (piece.kind == .ground ? 8 : 16), "\(piece.kind)")
            if picture.image.bitsPerComponent == 16 { deep += 1 }
            // Not asked to be deep, as for the stage, it never is.
            #expect(FilmPictures.picture(of: subject, scale: 2, assets: nil)?.image.bitsPerComponent == 8)
        }
        #expect(deep >= 2 && pieces.count >= 3)
        // Flat colours, letters and pictures have no such tones, whatever holds them.
        var flat = Node(kind: .rectangle, name: "Flat", frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        flat.fill.color = Self.lit
        flat.opacity = 0.5
        var group = Node(kind: .group, name: "Group", frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        group.children = [flat]
        #expect(!flat.hasGentleTones && !group.hasGentleTones)
        // One layer with a shadow inside a group, and the group has them; hidden, it has not.
        var lit = flat
        lit.shadow = Shadow(on: true, color: .black, x: 0, y: 2, blur: 12)
        group.children = [flat, lit]
        #expect(group.hasGentleTones)
        group.children[1].hidden = true
        #expect(!group.hasGentleTones)
        var bordered = flat
        bordered.border.on = true
        bordered.border.gradient = Self.ramp("", .zero).fill.gradient
        #expect(bordered.hasGentleTones)
    }

    /// Sixteen bits to a colour are half floats to Core Graphics, which stop at neither white
    /// nor black: two light layers added come to more than white, and what lies over them, or a
    /// fade, then leaves them lighter than the canvas shows. A piece with such a blend in it is
    /// drawn with eight bits, as it always was, and the movie's frame is the canvas's.
    @Test func aBlendThatLeavesTheRangeIsDrawnAsTheCanvasDrawsIt() throws {
        var board = Node(kind: .artboard, name: "Blends", frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        board.fill.color = Self.page
        board.film = Film(length: 1)
        func patch(_ name: String, _ x: CGFloat, _ color: RGBA, _ blend: BlendMode? = nil) -> Node {
            var n = Node(kind: .rectangle, name: name, frame: CGRect(x: x, y: 20, width: 40, height: 40))
            n.fill.color = color
            n.blend = blend
            return n
        }
        let light = RGBA(r: 0.8, g: 0.8, b: 0.8), half = RGBA(r: 0, g: 0, b: 0, a: 0.5)
        // In one group, so in one picture: a gradient, which asks for a deep one, and beside it
        // light added to light with half a black over it, and light taken from dark likewise.
        var group = Node(kind: .group, name: "Mixed", frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        group.children = [
            Self.ramp("Ramp", CGRect(x: 0, y: 0, width: 240, height: 12)),
            patch("Under", 20, light), patch("Added", 20, light, .plusLighter), patch("Shade", 20, half),
            patch("Dark", 100, RGBA(r: 0.1, g: 0.1, b: 0.1)), patch("Taken", 100, RGBA(r: 0.1, g: 0.1, b: 0.1), .plusDarker),
            patch("Veil", 100, RGBA(r: 1, g: 1, b: 1, a: 0.5)),
            patch("Rose", 180, RGBA(r: 0.9, g: 0.1, b: 0.5)), patch("Tinted", 180, RGBA(r: 0.2, g: 0.8, b: 0.95, a: 0.5), .color),
        ]
        group.setKey(.fade, [0.5], at: 0, ease: .linear)
        group.setKey(.fade, [1], at: 1, ease: .linear)
        board.children = [group]

        #expect(group.hasGentleTones && !group.drawsDeepAsPlain)
        for piece in board.filmPieces() {
            let subject = FilmPictures.subject(of: piece, on: board, at: 0)
            #expect(FilmPictures.picture(of: subject, scale: 1, assets: nil, deep: true)?.image.bitsPerComponent == 8, "\(piece.kind)")
        }
        // So the frame a movie is made of is the design as the canvas draws it: at the end, where
        // the group shows whole, and at the start, where it is half faded.
        let size = board.frame.size
        var faint = board
        faint.children[0].opacity = 0.5
        for (t, design) in [(1.0, board), (0.0, faint)] {
            let canvas = try Planes(#require(Renderer.image(of: design, scale: 1)))
            for deep in [false, true] {
                let frame = try Planes(#require(FilmExport.frame(of: board, at: t, size: size, assets: nil, deep: deep)))
                #expect(frame.width == canvas.width && frame.height == canvas.height)
                var furthest: Float = 0
                for i in frame.y.indices { furthest = max(furthest, abs(frame.y[i] - canvas.y[i])) }
                #expect(furthest <= 2, "at \(t), deep \(deep): \(furthest)")
            }
        }

        // Which blends those are, and that they are found wherever they lie.
        let apart: Set<BlendMode> = [.plusLighter, .plusDarker, .hue, .saturation, .color, .luminosity, .colorDodge, .colorBurn]
        for blend in BlendMode.allCases { #expect(blend.mixesDeepAsPlain != apart.contains(blend), "\(blend)") }
        var plain = group
        plain.children = [Self.ramp("Ramp", CGRect(x: 0, y: 0, width: 240, height: 12)), patch("Under", 20, light), patch("Over", 20, light, .multiply)]
        #expect(plain.drawsDeepAsPlain)
        plain.children[2].blend = .plusLighter
        #expect(!plain.drawsDeepAsPlain)
        plain.children[2].hidden = true
        #expect(plain.drawsDeepAsPlain)
        // A background blur made lighter adds, too; one left as it is does not.
        var glass = patch("Glass", 20, RGBA(r: 1, g: 1, b: 1, a: 0.2))
        glass.blur = Blur(radius: 12, background: true)
        #expect(glass.drawsDeepAsPlain && glass.blursBehind)
        glass.blur?.brightness = 0.2
        #expect(!glass.drawsDeepAsPlain)
    }

    // MARK: The movie

    @Test func anH264MovieCutsGentleTonesToItsStepsOnce() async throws {
        let (worst, movie, lines) = try await measured(.h264)
        #expect(movie.codec == .h264 && movie.bits == 8 && movie.playable && movie.count == Self.fps)
        #expect(movie.transfer == kCMFormatDescriptionTransferFunction_sRGB as String)
        // The gradients are as near the exact tones as eight bits come, 0.29 of a step on
        // average, where rounding twice left 0.32 to 0.36; the glow and the blur, which the
        // packing itself takes further, under 0.4, where that left up to 0.46.
        for (name, _) in Self.boxes {
            let found = try #require(worst[name])
            #expect(found.off < (name == "ramp" || name == "fade" ? 0.31 : 0.42) && found.most < 1.5,
                    "\(name): \(found)\n\(lines.joined(separator: "\n"))")
        }
        // The fading one never strays further than rounding takes it.
        #expect(try #require(worst["fade"]).most < 0.7)
    }

    @Test func aTenBitMovieHasStepsAQuarterAsLarge() async throws {
        let (worst, movie, lines) = try await measured(.hevc)
        // HEVC as QuickTime and Safari want it named, ten bits, and it plays here.
        #expect(movie.codec == .hevc && movie.bits == 10 && movie.playable && movie.count == Self.fps, "\(movie.codec) \(movie.bits)")
        #expect(movie.transfer == kCMFormatDescriptionTransferFunction_sRGB as String)
        // A third of what eight bits leave, or less, everywhere.
        for (name, _) in Self.boxes {
            let found = try #require(worst[name])
            #expect(found.off < 0.15 && found.most < 0.6, "\(name): \(found)\n\(lines.joined(separator: "\n"))")
        }
        // The still ramp runs over fourteen of eight bits' steps, each some 145 pixels wide,
        // and here over several times as many, none of them wide; the glow and the blur lie
        // in no flat patches.
        let ramp = try #require(worst["ramp"])
        #expect(ramp.levels >= 40 && ramp.run <= 80, "\(ramp)")
        #expect(try #require(worst["glow"]).flat < 0.15 && #require(worst["soft"]).flat < 0.15)
    }

    /// Movies of this film made elsewhere, by an older Bezzle, on Windows, or packed again by
    /// a video site, measured the same way: `TEST_RUNNER_ANIMATE_BANDING_MOVIE=<a file>`
    /// before `xcodebuild`, or several with a colon between them. Each is `film()` at 30 frames
    /// a second, of any size (`TEST_RUNNER_ANIMATE_BANDING_KEEP=<a folder>` keeps the ones made
    /// here, to send through such a site). Written down (`…-given-<its name>.txt`), nothing held
    /// to it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_BANDING_MOVIE"] != nil))
    func measuresMoviesMadeElsewhere() async throws {
        let paths = try #require(ProcessInfo.processInfo.environment["ANIMATE_BANDING_MOVIE"])
        for path in paths.split(separator: ":") {
            let url = URL(fileURLWithPath: String(path))
            _ = try await measure(url, as: "given-" + url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: Noise

    /// Why no noise is laid over a movie's steps to hide them. Frames are made here from exact
    /// numbers, a still dark ramp over the same ramp fading in, cut to eight bits plainly or
    /// with fine noise first (half a step either way, on the luma), packed as the app packs a
    /// movie and read back. Written down (`…-noise.txt`), nothing held to it: run with
    /// `TEST_RUNNER_ANIMATE_BANDING_NOISE=1` before `xcodebuild`, and again when what packs
    /// movies on a Mac changes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_BANDING_NOISE"] != nil))
    func measuresNoiseOverTheSteps() async throws {
        let width = 1920, height = 1080, count = Self.fps
        let size = CGSize(width: width, height: height)
        // What each column holds, exactly: of the still half, and of the fading half at a frame.
        func column(_ x: Int, _ shows: Double) -> (y: Float, cb: Float, cr: Float) {
            let u = (Double(x) + 0.5) / Double(width)
            func mix(_ a: Double, _ b: Double) -> Double { (a + (b - a) * u) * shows }
            return Planes.packed(mix(Self.dark.r, Self.lit.r), mix(Self.dark.g, Self.lit.g), mix(Self.dark.b, Self.lit.b))
        }
        func shows(_ frame: Int) -> Double { 0.3 + 0.7 * Double(frame) / Double(count - 1) }
        func exact(_ frame: Int) -> Planes {
            var planes = Planes(width: width, height: height)
            for half in 0..<2 {
                let row = (0..<width).map { column($0, half == 0 ? 1 : shows(frame)) }
                for py in half * height / 2..<(half + 1) * height / 2 {
                    for px in 0..<width { planes.y[py * width + px] = row[px].y }
                    guard py % 2 == 0 else { continue }
                    for px in 0..<width / 2 {
                        planes.cb[py / 2 * (width / 2) + px] = (row[2 * px].cb + row[2 * px + 1].cb) / 2
                        planes.cr[py / 2 * (width / 2) + px] = (row[2 * px].cr + row[2 * px + 1].cr) / 2
                    }
                }
            }
            return planes
        }
        // A tile of noise from half a step under to half a step over.
        var seed: UInt64 = 0x2545F4914F6CDD1D
        let noise: [Float] = (0..<64 * 64).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xFFFF) / 65536 - 0.5
        }
        let halves = [("still", CGRect(x: 0, y: 0, width: 960, height: 270)), ("fading", CGRect(x: 0, y: 270, width: 960, height: 270))]
        var lines: [String] = []
        for (name, noisy, bits) in [("plain", false, 1.0), ("noise", true, 1.0), ("noise at four times the bits", true, 4.0), ("noise at sixteen times the bits", true, 16.0)] {
            let url = scratch()
            defer { try? FileManager.default.removeItem(at: url) }
            var settings = FilmExport.video(size, fps: Self.fps, codec: .h264)
            var packing = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
            packing[AVVideoAverageBitRateKey] = Int(Double(FilmExport.bitRate(size, fps: Self.fps)) * bits)
            settings[AVVideoCompressionPropertiesKey] = packing
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(input)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<count {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &made)
                let buffer = try #require(made)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVPixelBufferLockBaseAddress(buffer, [])
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self), lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                for half in 0..<2 {
                    let row = (0..<width).map { column($0, half == 0 ? 1 : shows(frame)) }
                    for py in half * height / 2..<(half + 1) * height / 2 {
                        for px in 0..<width {
                            let grain = noisy ? noise[(py & 63) * 64 + (px & 63)] : 0
                            luma[py * lumaRow + px] = UInt8((row[px].y + grain).rounded())
                        }
                        guard py % 2 == 0 else { continue }
                        for px in 0..<width / 2 {
                            chroma[py / 2 * chromaRow + 2 * px] = UInt8(((row[2 * px].cb + row[2 * px + 1].cb) / 2).rounded())
                            chroma[py / 2 * chromaRow + 2 * px + 1] = UInt8(((row[2 * px].cr + row[2 * px + 1].cr) / 2).rounded())
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(Self.fps))))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(Self.fps)))
            await writer.finishWriting()
            #expect(writer.status == .completed)
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let movie = try await Self.read(Set(Self.shown), of: url)
            lines.append("\(name): \(bytes * 8 / 1000) kbit/s of \(Int(Double(FilmExport.bitRate(size, fps: Self.fps)) * bits) / 1000) at most")
            for k in Self.shown {
                let read = try #require(movie.frames[k]), whole = exact(k)
                for (part, box) in halves { lines.append("\(name), frame \(k), \(part): \(Self.banding(read, in: box, against: whole))") }
            }
        }
        try note(lines, as: "noise")
    }

    // MARK: Stills

    /// What the same tones are in a picture that is exported, and in the pictures the stage
    /// shows a film with: written down, nothing held to it. Run with
    /// `TEST_RUNNER_ANIMATE_BANDING_STILLS=1` before `xcodebuild`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMATE_BANDING_STILLS"] != nil))
    func measuresStills() throws {
        var board = Self.film()
        board.children[3].motion = nil
        let whole = try exact(board, at: 0, FilmExport.size(of: board, settings: FilmExport.Settings(scale: 2, fps: Self.fps)))
        let image = try #require(Renderer.image(of: board, scale: 2))
        var lines: [String] = []
        func add(_ name: String, _ image: CGImage) throws {
            let planes = try Planes(image)
            for (part, box) in Self.boxes { lines.append("\(name), \(part): \(Self.banding(planes, in: box, against: whole))") }
        }
        try add("drawn", image)
        for format in [ExportFormat.png, .jpeg] {
            let url = scratch(format == .png ? "png" : "jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(Exporter.write(image, as: format, scale: 2, quality: Exporter.defaultQuality, to: url))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            try add("\(format)", #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        // The stage's pictures, piece by piece: each as the film's stage draws it, eight bits.
        for piece in board.filmPieces() where piece.kind != .ground {
            let subject = FilmPictures.subject(of: piece, on: board, at: 0)
            let picture = try #require(FilmPictures.picture(of: subject, scale: 2, assets: nil))
            let levels = Set(try Planes(picture.image).y).count
            lines.append("stage picture of \(subject.layers.map(\.name)): \(picture.image.width) by \(picture.image.height), \(picture.image.bitsPerComponent) bit, \(levels) lumas")
        }
        try note(lines, as: "stills")
    }
}
