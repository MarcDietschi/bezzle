import AVFoundation
import CoreImage
import Metal
import VideoToolbox

/// An artboard's film saved as a movie.
///
/// A frame is put together as the canvas and the stage show it: each piece of the film is drawn
/// once (`FilmPictures`) and after that only placed, moment by moment, by the film's own
/// arithmetic (`Node.placement`), so what is posed is what is saved. Core Image does the placing
/// on the graphics card, straight into the pictures the movie's writer packs.
///
/// Gentle tones, a wide dark gradient, a soft shadow, a slow fade, are kept exact until the
/// movie's own steps cut them, once: a piece that has them is drawn with sixteen bits to a
/// colour (`FilmPictures.picture(deep:)`), the frame is put together in numbers as fine, and it
/// is written straight into the kind of picture the movie packs, luma and chroma at the
/// movie's depth. Cut to eight bits on the way and again by the packing, a gradient lay a
/// quarter further from its true tones, in bands up to a tenth wider, than eight bits make it
/// (`FilmBandingTests` measures it). The bands eight bits do make stay in an H.264 movie. No
/// noise is laid over them to hide them: what packs a movie on a Mac irons noise that fine
/// out again unless the movie is made many times larger, and what is left of it is further
/// from the true tones than the clean steps are. A movie with ten bits (`Codec.hevc`) has
/// steps a quarter as large instead.
nonisolated enum FilmExport {
    struct Settings: Equatable, Sendable {
        /// Pixels to the artboard's point.
        var scale: CGFloat = 2
        var fps = 60
        var codec = Codec.h264
    }

    /// How a movie is packed. Both are .mp4 files.
    enum Codec: String, Sendable, CaseIterable {
        /// H.264 with eight bits to a colour, which everything plays. A gentle dark gradient
        /// shows the steps eight bits have, and no others.
        case h264
        /// HEVC (Main 10, named `hvc1`) with ten bits to a colour: steps a quarter as large,
        /// for gentle gradients, soft shadows and slow fades. Plays wherever HEVC does: on
        /// Apple's devices and in the browsers that have it (read back here with AVFoundation,
        /// as QuickTime and Safari read it, with Chrome and with ffmpeg, 2026-11-14).
        case hevc

        /// The kind of picture its frames are handed over as: luma and chroma planes at its
        /// depth, in video's range, which is what it packs. Nothing is rounded twice on the way.
        fileprivate var pixels: OSType {
            self == .hevc ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    /// Why a movie is not made: this Mac cannot pack one the way that was asked for.
    struct CannotPack: LocalizedError, Equatable {
        var errorDescription: String? { String(localized: "This Mac cannot save a movie of this kind.") }
        var recoverySuggestion: String? { String(localized: "Save it as H.264 instead.") }
    }

    /// The longest side a movie is made with, in pixels.
    static let most: CGFloat = 3840

    /// The movie's frame in pixels: the artboard's size times the scale, in even numbers, as
    /// H.264 wants them, and no side over `most`: for a larger artboard the scale gives way.
    static func size(of board: Node, settings: Settings) -> CGSize {
        let w = max(board.frame.width, 1), h = max(board.frame.height, 1)
        let scale = min(max(settings.scale, 0.01), most / max(w, h))
        func even(_ side: CGFloat) -> CGFloat { max(2, (side * scale / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    /// The longest film saved as a movie, in seconds: an hour. A design from elsewhere may say its
    /// film runs for any time at all, and a movie of that would never be done, or never fit.
    static let longest: Double = 3600

    /// The most frames a second a movie is made with.
    static let fastest = 240

    /// Why a film is not saved as a movie: it runs longer than a movie may (`longest`).
    struct TooLong: LocalizedError, Equatable {
        var errorDescription: String? { String(localized: "This film is too long to save as a movie.") }
        var recoverySuggestion: String? {
            String(localized: "A movie runs for an hour at most. Give the film a shorter length, or take away the keys that come later.")
        }
    }

    /// Throws `TooLong` for a film that runs longer than a movie may. It is refused whole and said
    /// so: a movie cut short would pass for the film.
    static func check(_ board: Node) throws {
        let length = board.filmLength
        guard length.isFinite, length <= longest else { throw TooLong() }
    }

    /// The moments the movie's frames show, in seconds from the film's start: one for every
    /// `fps`th of a second the film runs. A film that goes round stops a frame short of its end,
    /// as its start follows; one that plays once ends on its last moment, where the movie rests.
    /// Never more than the longest movie has, whatever the film says of its length: `write`
    /// refuses a longer film (`check`), so these are not what a movie of it would be.
    static func moments(of board: Node, fps: Int) -> [Double] {
        let fps = min(max(fps, 1), fastest), told = board.filmLength
        let length = told.isFinite ? min(max(told, 0), longest) : longest
        let count = max(1, Int((length * Double(fps)).rounded()))
        var all = (0..<count).map { Double($0) / Double(fps) }
        if board.film?.once == true, count > 1 { all[count - 1] = length }
        return all
    }

    /// One frame of the film as a picture of `size` pixels, composed exactly as the movie's
    /// frames are, with eight bits to a colour. `deep`, with sixteen: the frame before any
    /// movie's steps have cut it, to hold a movie against.
    @MainActor
    static func frame(of board: Node, at t: Double, size: CGSize, assets: Assets?, deep: Bool = false) -> CGImage? {
        let size = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard size.width >= 1, size.height >= 1, board.frame.width > 0, board.frame.height > 0 else { return nil }
        var reel = Reel(board, size: size)
        let shot = reel.shot(at: t)
        var stills = [Still?](repeating: nil, count: reel.pieces.count), parts = stills
        for fresh in shot.fresh {
            let still = FilmPictures.picture(of: fresh.subject, scale: fresh.scale, assets: assets, part: fresh.part, deep: true).map(Still.init)
            if fresh.part != nil { parts[fresh.piece] = still } else { stills[fresh.piece] = still }
        }
        let image = composed(stills, parts, shot, backdrop: board.filmBackdrop, board: board.frame.size, size: size)
        return imaging.createCGImage(image, from: CGRect(origin: .zero, size: size), format: deep ? .RGBAh : .RGBA8, colorSpace: sRGB)
    }

    /// Writes the film of `board` (an artboard as it is seen; its frame's origin may be anywhere)
    /// to `url` as an .mp4: H.264 or HEVC as the settings say, sRGB, square pixels, `fps` frames
    /// a second and as long as the film runs. It is written out of the way first (`workFile`)
    /// and put in its place when it is whole, so a file already there is replaced only then,
    /// and stays as it was when the movie is stopped or cannot be made. `progress` is told how
    /// far it is, from 0 to 1 when the file is whole. Throws when the movie cannot be written,
    /// at once when nothing can be put at `url`, the film runs longer than a movie may
    /// (`TooLong`) or this Mac cannot pack such a movie (`CannotPack`), with nothing touched.
    /// When the task it runs in is cancelled it stops, removes what it wrote and throws
    /// `CancellationError`.
    @MainActor
    static func write(_ board: Node, assets: Assets?, to url: URL, settings: Settings = Settings(),
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        try check(board)
        let size = size(of: board, settings: settings), fps = min(max(settings.fps, 1), fastest)
        let moments = moments(of: board, fps: fps)
        var reel = Reel(board, size: size, fps: fps)
        // Found out now, not once the whole film has been made into frames.
        try tryPlace(url)
        let work = workFile(for: url)
        try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The writer does not write over a file, such as one left by a save that was cut short.
        try? FileManager.default.removeItem(at: work)
        let recorder = try Recorder(url: work, size: size, board: board, pieces: reel.pieces.count, fps: fps, codec: settings.codec, assets: assets)
        do {
            try await recorder.start()
            for (k, t) in moments.enumerated() {
                try Task.checkCancellation()
                progress(Double(k) / Double(moments.count))
                // What each piece draws at this moment is read here, on the main actor. Drawing it
                // and making the frame happen away from it, and the app goes on meanwhile.
                let shot = reel.shot(at: t)
                try await recorder.add(shot, as: k)
            }
            try Task.checkCancellation()
            try await recorder.finish(frames: moments.count)
            try put(work, at: url)
            progress(1)
        } catch {
            await recorder.cancel()
            try? FileManager.default.removeItem(at: work)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    /// Where a movie bound for `url` is written until it is whole: a file of its own in the
    /// temporary folder, which Bezzle may always write to, whatever it was let into. The same
    /// place for the same `url`, so what a save that was cut short left there is written over.
    static func workFile(for url: URL) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle Film", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16) + ".mp4")
    }

    /// Throws when nothing can be put at `url`: its folder is not there, or may not be written to.
    private static func tryPlace(_ url: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            // What is there gives way when it, or its folder, may be written to.
            guard files.isWritableFile(atPath: url.path) || files.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try Data().write(to: url, options: .withoutOverwriting)
            try files.removeItem(at: url)
        }
    }

    /// Puts a whole movie in its place. One already there gives way in the same step, so there
    /// is never a moment with neither; only onto another disk is it taken away first, and the
    /// new one copied there.
    private static func put(_ work: URL, at url: URL) throws {
        if rename(work.path, url.path) == 0 { return }
        let files = FileManager.default
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        try files.moveItem(at: work, to: url)
    }

    // MARK: - What a frame is made from

    /// What one frame is made from: where each piece shows, in what order, and the pictures that
    /// have to be drawn for it first.
    private struct Shot: Sendable {
        struct Fresh: Sendable {
            var piece: Int
            var subject: FilmPictures.Subject
            var scale: CGFloat
            /// Only a part of the piece, as sharp as this frame and those after it show it.
            var part: FilmPictures.Part?
        }

        var placements: [FilmPlacement]
        var order: [Int]
        var fresh: [Fresh]
        /// The pieces this frame shows by the part drawn of them, not by their whole picture.
        var parts: Set<Int>
    }

    /// A film being made into frames: its pieces, and what has been drawn of each.
    ///
    /// A piece is drawn once, whole, as sharp as the film shows it at its largest, and after
    /// that only placed. Where a frame shows it larger than a whole picture can hold, the camera
    /// close in, or shows what of it lies far outside the artboard, the part of it that the
    /// frame shows is drawn for that frame, as sharp as the frame is: a movie has every pixel of
    /// the design in it, however near the camera goes.
    @MainActor
    private struct Reel {
        let board: Node
        let pieces: [FilmPiece]
        /// The frame's pixels to the artboard's point, and its pixels in all.
        private let density: CGFloat
        private let pixels: CGFloat
        /// The frames a second of the movie being made; one, for a single frame.
        private let fps: Int
        /// The artboard every piece is drawn on, made once for the whole film.
        private let ground: FilmPictures.Ground
        /// What each piece shows, read once, and each frame for one whose insides move; and
        /// with it where the piece draws at all, and what of that its whole picture covers.
        private var subjects: [FilmPictures.Subject?]
        private var rects: [(reach: CGRect, core: CGRect)]
        /// How sharp each whole picture is asked for, and whether it has been drawn of what
        /// the piece shows now.
        private var scales: [CGFloat?]
        private var whole: [Bool]
        /// The part last drawn of each piece, of what it shows now.
        private var parts: [FilmPictures.Part?]
        /// The layer each piece places, found once for the whole film.
        private let layers: [Node?]

        init(_ board: Node, size: CGSize, fps: Int = 1) {
            self.board = board
            self.fps = max(fps, 1)
            pieces = board.filmPieces()
            layers = board.filmLayers(of: pieces)
            ground = FilmPictures.Ground.of(board)
            density = max(size.width / max(board.frame.width, 1), size.height / max(board.frame.height, 1))
            pixels = size.width * size.height
            subjects = Array(repeating: nil, count: pieces.count)
            rects = Array(repeating: (.zero, .zero), count: pieces.count)
            scales = Array(repeating: nil, count: pieces.count)
            whole = Array(repeating: false, count: pieces.count)
            parts = Array(repeating: nil, count: pieces.count)
        }

        /// What the frame at a moment is made from.
        mutating func shot(at t: Double) -> Shot {
            let camera = board.camera(at: t)
            let placements = pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera) }
            let frame = CGRect(origin: .zero, size: board.frame.size)
            var fresh: [Shot.Fresh] = []
            var inParts: Set<Int> = []
            for (i, piece) in pieces.enumerated() {
                if subjects[i] == nil || piece.changes {
                    let now = FilmPictures.subject(of: piece, on: board, ground: ground, at: t)
                    if now != subjects[i] {
                        // Its insides have moved: what was drawn of it is of another moment.
                        subjects[i] = now
                        rects[i] = (FilmPictures.rect(of: now), FilmPictures.core(of: now))
                        whole[i] = false
                        parts[i] = nil
                    }
                }
                guard let subject = subjects[i] else { continue }
                let (reach, core) = rects[i]
                guard core.width > 0, core.height > 0 else { continue }
                // A whole picture: sharp at its largest in the whole film, as far as one may be.
                let asked = scales[i] ?? density * board.filmStretch(of: piece, around: core)
                scales[i] = asked
                let sharp = min(asked, FilmPictures.most / max(core.width, core.height))
                let p = placements[i]
                if p.blur <= 0.05, p.opacity >= 0.001, let seen = p.map.seen(of: reach, through: frame) {
                    let need = CGFloat(seen.stretch) * density
                    if need > sharp * 1.02 || !core.insetBy(dx: -0.01, dy: -0.01).contains(seen.part),
                       let part = part(i, piece, reach: reach, seen: seen.part, need: need, at: t, frame: frame) {
                        if part != parts[i] {
                            parts[i] = part
                            fresh.append(Shot.Fresh(piece: i, subject: subject, scale: part.scale, part: part))
                        }
                        inParts.insert(i)
                        continue
                    }
                }
                if !whole[i] {
                    whole[i] = true
                    fresh.append(Shot.Fresh(piece: i, subject: subject, scale: asked, part: nil))
                }
            }
            return Shot(placements: placements, order: board.filmOrder(pieces, placements), fresh: fresh, parts: inParts)
        }

        /// The part of a piece to show a frame by: the one kept, while it covers what the frame
        /// shows as sharp as the frame shows it, or one to draw. A new one covers what the next
        /// half second shows too, as far as a part may hold that as sharp as it is needed, so
        /// that a camera on its way is not drawn for frame by frame.
        private func part(_ i: Int, _ piece: FilmPiece, reach: CGRect, seen: CGRect, need: CGFloat, at t: Double, frame: CGRect) -> FilmPictures.Part? {
            // Two pixels round what shows, for what the picture's edge is mixed with.
            let around = 2 / need
            guard let alone = FilmPictures.part(for: seen, of: reach, need: need, around: around) else { return nil }
            if let kept = parts[i], kept.rect.insetBy(dx: -0.01, dy: -0.01).contains(seen.insetBy(dx: -around, dy: -around).intersection(reach)),
               kept.scale >= min(need, alone.scale) * 0.999 {
                return kept
            }
            guard !piece.changes else { return alone }
            var all = seen, most = need
            let length = board.filmLength
            let limit = min(FilmPictures.mostInPart.pixels, pixels * 4)
            for k in stride(from: 1, through: fps / 2, by: 1) {
                let then = t + Double(k) / Double(fps)
                guard then <= length + 1e-9 else { break }
                let q = board.placement(of: piece, layer: layers[i], at: then, camera: board.camera(at: then))
                guard q.blur <= 0.05, q.opacity >= 0.001, let next = q.map.seen(of: reach, through: frame) else { continue }
                let grown = all.union(next.part), sharper = max(most, CGFloat(next.stretch) * density)
                // As it would be drawn: a fifth sharper at most, by the steps parts are sharp in.
                let drawn = sharper * 1.2
                guard max(grown.width, grown.height) * drawn <= FilmPictures.mostInPart.side, grown.width * grown.height * drawn * drawn <= limit else { break }
                all = grown
                most = sharper
            }
            return FilmPictures.part(for: all, of: reach, need: most, around: around) ?? alone
        }
    }

    // MARK: - Composing

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Core Image on the graphics card, mixing in plain sRGB values as drawing does everywhere
    /// else in Bezzle (see `Renderer.imaging`), so a faded piece looks as it does on the canvas.
    /// It works in sixteen bit numbers, so fading, blurring and scaling keep what the deep
    /// pictures bring, down to the last step, where the movie's own depth takes over. The stage
    /// makes its picture with it too, under a camera that blurs (`FilmStageView`'s lens).
    static let imaging: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: sRGB, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// A piece's picture as Core Image takes it, made once so that it is handed to the graphics
    /// card once.
    struct Still: Sendable {
        let image: CIImage
        /// The part of the artboard it covers, in the artboard's points.
        let rect: CGRect

        init(_ picture: FilmPictures.Picture) {
            image = CIImage(cgImage: picture.image)
            rect = picture.rect
        }

        /// Of a picture whose numbers are taken as they are, whatever colours it says they are
        /// in: the stage's, which are in the screen's own and shown in them.
        static func asItIs(_ picture: FilmPictures.Picture) -> Still {
            Still(image: CIImage(cgImage: picture.image, options: [.colorSpace: NSNull()]), rect: picture.rect)
        }

        init(image: CIImage, rect: CGRect) {
            self.image = image
            self.rect = rect
        }
    }

    /// A frame of `size` pixels: the backdrop, and over it each piece where the film has it, the
    /// lowest first. `board` is the artboard's size, which is the frame's in points.
    private static func composed(_ stills: [Still?], _ parts: [Still?], _ shot: Shot, backdrop: RGBA, board: CGSize, size: CGSize) -> CIImage {
        // By the part drawn of a piece for this frame, where its whole picture would not do.
        composed({ i in (shot.parts.contains(i) ? parts[i] : stills[i]).map { [Cut(still: $0)] } ?? [] },
                 placements: shot.placements, order: shot.order, backdrop: backdrop, board: board, size: size)
    }

    /// One of a piece's pictures for a frame. A movie's frame has one of a piece, its whole
    /// picture or the part drawn of it for that frame. The stage has both where it shows a part:
    /// the whole picture, which gives way where the part lies (`under`), and the part over it.
    struct Cut: Sendable {
        var still: Still
        /// A sharper picture of a part of the piece, laid over this one, which gives way there.
        var under: Still?
    }

    /// The same frame of the pictures each piece has for it (`cuts`, by the piece's number), for
    /// whatever shows a film: the movie, a single frame, and the stage under a camera that
    /// blurs. A piece that stands off the camera's focus (`FilmPlacement.soft`) is blurred by
    /// how far off it stands, where it shows; pieces lying in one plane, one after the other,
    /// are blurred as the one picture they are, so nothing shows through where two of them meet.
    static func composed(_ cuts: (Int) -> [Cut], placements: [FilmPlacement], order: [Int], backdrop: RGBA, board: CGSize, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        // The film counts points down from the top left, Core Image pixels up from the bottom left.
        let toPixels = CGAffineTransform(a: size.width / board.width, b: 0, c: 0, d: -size.height / board.height, tx: 0, ty: size.height)
        // A movie has nothing to show through to: a backdrop that is not solid lies on black.
        let ground = CIColor(red: backdrop.r * backdrop.a, green: backdrop.g * backdrop.a, blue: backdrop.b * backdrop.a)
        var out = CIImage(color: ground).cropped(to: frame)
        // What lies in one plane, gathered until something of another plane comes.
        var plane: (image: CIImage, soft: FilmSoft)?
        func lay() {
            guard let gathered = plane else { return }
            out = softened(gathered.image, by: gathered.soft, board: board, size: size).composited(over: out)
            plane = nil
        }
        for i in order {
            var piece: CIImage?
            for cut in cuts(i) {
                guard var one = placed(cut.still, by: placements[i], toPixels: toPixels, board: board) else { continue }
                if let part = cut.under {
                    // Where the part lies, placed as the piece is, and all there, whatever the piece's own fade.
                    var solid = placements[i]
                    solid.opacity = 1
                    solid.blur = 0
                    let cover = Still(image: CIImage(color: .white).cropped(to: part.image.extent), rect: part.rect)
                    if let gone = placed(cover, by: solid, toPixels: toPixels, board: board) {
                        one = one.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: gone])
                    }
                }
                piece = piece.map { one.composited(over: $0) } ?? one
            }
            guard let piece else { continue }
            guard let soft = placements[i].soft else {
                lay()
                out = piece.composited(over: out)
                continue
            }
            if let gathered = plane, gathered.soft.matches(soft, in: board) {
                plane = (piece.composited(over: gathered.image), gathered.soft)
            } else {
                lay()
                plane = (piece, soft)
            }
        }
        lay()
        return out.cropped(to: frame)
    }

    // MARK: - Off the camera's focus

    /// How many times its radius Core Image's variable blur spreads a picture, measured as a
    /// gaussian's spread is: an edge blurred with radius 10 is as wide as one a gaussian of
    /// 10.9 blurs (macOS 27, 2026-11-14, for radii from 2 to 40 and every strength of mask).
    private static let variableSpread = 1.094

    /// The most that blur is asked to spread a picture, in pixels. Asked for more than 45, it
    /// gives 49 and no more (measured with the above), so what is blurred further is made of a
    /// smaller picture (`varied`).
    private static let variableMost = 40.0

    /// How many times smaller the picture is that the blur past `variableMost` is made of.
    private static let coarser = 4.0

    /// Whether a piece that stands off the camera's focus shows blurred at all in a frame of
    /// `size` pixels: by half a pixel or more somewhere in it. One rule for the frames of a
    /// movie and for the stage, which shows a film without any such piece as it always has.
    static func blurs(_ soft: FilmSoft, board: CGSize, size: CGSize) -> Bool {
        let field = Field(soft, board: board, size: size)
        let most = field.range(in: CGRect(origin: .zero, size: size)).most
        return most.isFinite && most >= 0.5
    }

    /// How much a plane is blurred at each pixel of a frame, counted up from its bottom left:
    /// `|across * x + up * y + level|` pixels (`FilmSoft`, in the frame's pixels).
    private struct Field {
        var across: Double
        var up: Double
        var level: Double

        init(across: Double, up: Double, level: Double) {
            self.across = across
            self.up = up
            self.level = level
        }

        init(_ soft: FilmSoft, board: CGSize, size: CGSize) {
            let kx = Double(size.width / board.width), ky = Double(size.height / board.height), k = (kx + ky) / 2
            across = k * soft.across / kx
            up = -k * soft.down / ky
            level = k * (soft.down * Double(size.height) / ky + soft.level)
        }

        /// The least and the most it blurs within a rect.
        func range(in rect: CGRect) -> (least: Double, most: Double) {
            let values = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                .map { across * Double($0.x) + up * Double($0.y) + level }
            let low = values.min() ?? 0, high = values.max() ?? 0
            return (low <= 0 && high >= 0 ? 0 : min(abs(low), abs(high)), max(abs(low), abs(high)))
        }

        /// The same for a picture so many times smaller.
        func smaller(by times: Double) -> Field { Field(across: across, up: up, level: level / times) }

        /// A picture that is black where it blurs by `from` pixels or less, white where by `to`
        /// or more, and runs evenly between, within a rect.
        func mask(from: Double, to: Double, in rect: CGRect) -> CIImage {
            let steep = hypot(across, up)
            guard steep * Double(hypot(rect.width, rect.height)) >= 0.05 else {
                // As good as one blur all over.
                let v = min(max((abs(across * Double(rect.midX) + up * Double(rect.midY) + level) - from) / max(to - from, 1e-9), 0), 1)
                return CIImage(color: CIColor(red: v, green: v, blue: v))
            }
            // Two ramps, one each way from the line that is sharp, each black on the other's side.
            let nx = across / steep, ny = up / steep
            let sharp = CGPoint(x: -level * nx / steep, y: -level * ny / steep)
            func ramp(_ way: Double) -> CIImage {
                let a = way * from / steep, b = way * to / steep
                return CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: sharp.x + a * nx, y: sharp.y + a * ny), "inputPoint1": CIVector(x: sharp.x + b * nx, y: sharp.y + b * ny),
                    "inputColor0": CIColor.black, "inputColor1": CIColor.white,
                ])?.outputImage ?? CIImage(color: .white)
            }
            return ramp(1).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: ramp(-1)])
        }
    }

    /// A picture placed in the frame, blurred by how far what it shows stands off the camera's
    /// focus: at each pixel by what `soft` gives there, in the frame's pixels. Sharp along a
    /// line and more blurred the further from it, for a thing the camera does not face, which
    /// one blur for the whole of it could not show. What reaches the frame's edge is blurred as
    /// if it went on past the edge as it is there: nothing dark or clear is drawn in from
    /// outside, and nothing has to be drawn of a piece that the frame does not show.
    private static func softened(_ image: CIImage, by soft: FilmSoft, board: CGSize, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let field = Field(soft, board: board, size: size)
        let range = field.range(in: frame)
        // No more than anything is blurred, in the frame's points.
        let most = min(range.most, FilmSoft.most * Double(size.width / board.width + size.height / board.height) / 2)
        // Less than half a pixel at its most: sharp (`blurs`).
        guard range.most.isFinite, range.most >= 0.5, !image.extent.isEmpty else { return image }
        let base = image.cropped(to: frame).composited(over: CIImage(color: .clear).cropped(to: frame)).clampedToExtent()
        return varied(base, by: field, least: min(range.least, most), most: most, in: frame).cropped(to: frame)
    }

    /// A picture blurred by what `field` gives at each pixel, between `least` and `most` within
    /// `frame`, which the picture reaches past on every side. Core Image's variable blur does
    /// it as far as it goes. What is blurred further is made of the picture four times smaller,
    /// blurred a quarter as much and shown at its size again, which is the same to the eye
    /// under that much blur; and that again, as often as it takes. So a blur of hundreds of
    /// pixels takes little longer than one of ten.
    private static func varied(_ image: CIImage, by field: Field, least: Double, most: Double, in frame: CGRect, depth: Int = 0) -> CIImage {
        guard most > variableMost, depth < 12 else {
            return image.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": field.mask(from: 0, to: most, in: frame), kCIInputRadiusKey: most / variableSpread,
            ])
        }
        // On whole pixels of the smaller picture, with a little of what lies past the frame.
        let room = coarser * 2
        let whole = CGRect(x: -room, y: -room, width: (frame.maxX / coarser).rounded(.up) * coarser + room * 2, height: (frame.maxY / coarser).rounded(.up) * coarser + room * 2)
        let small = image.cropped(to: whole).transformed(by: CGAffineTransform(scaleX: 1 / coarser, y: 1 / coarser), highQualityDownsample: true).clampedToExtent()
        let within = CGRect(x: 0, y: 0, width: frame.maxX / coarser, height: frame.maxY / coarser)
        let coarse = varied(small, by: field.smaller(by: coarser), least: least / coarser, most: most / coarser, in: within, depth: depth + 1)
            .transformed(by: CGAffineTransform(scaleX: coarser, y: coarser))
        // All of it blurred past what the variable blur gives: nothing of it is made at full size.
        guard least < variableMost else { return coarse }
        let fine = image.applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": field.mask(from: 0, to: variableMost, in: frame), kCIInputRadiusKey: variableMost / variableSpread,
        ])
        // From the one to the other where the blur is between half and all of what the variable
        // blur gives, and the smaller picture's coarseness is long lost in it.
        return coarse.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: fine, kCIInputMaskImageKey: field.mask(from: variableMost / 2, to: variableMost, in: frame),
        ])
    }

    /// A piece's picture where the film has it, in the frame's pixels; nil when it does not show.
    /// `board` is the frame's size in the artboard's points.
    private static func placed(_ still: Still, by placement: FilmPlacement, toPixels: CGAffineTransform, board: CGSize) -> CIImage? {
        let r = still.rect, map = placement.map
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        // Faded away, or wholly behind the eye.
        let behind = corners.filter { map.depth(at: $0) <= 1e-3 }.count
        guard placement.opacity >= 0.001, behind < corners.count else { return nil }
        var image = still.image
        let whole = image.extent
        guard whole.width > 0, whole.height > 0 else { return nil }
        // The picture's own pixels, counted up from its bottom left, to the artboard's points.
        let toBoard = CGAffineTransform(a: r.width / whole.width, b: 0, c: 0, d: -r.height / whole.height, tx: r.minX, ty: r.maxY)
        if placement.blur > 0.05 {
            // Blurred as it is drawn, before the camera sees it; the blur spreads past its edges.
            let own = (whole.width / r.width + whole.height / r.height) / 2
            image = image.applyingGaussianBlur(sigma: placement.blur * own)
        }
        if map.isFlat {
            let flat = CGAffineTransform(a: map.a / map.i, b: map.d / map.i, c: map.b / map.i, d: map.e / map.i, tx: map.c / map.i, ty: map.f / map.i)
            // Shown smaller than it was drawn, every pixel of it still counts.
            image = image.transformed(by: toBoard.concatenating(flat).concatenating(toPixels), highQualityDownsample: true)
        } else if behind > 0 {
            // Reaching behind the eye, as an artboard's own sheet does under a camera that is
            // close and tipped: what of it lies in front and shows in the frame. Its blur ends
            // at its own edge.
            guard let front = front(of: image.cropped(to: whole), toBoard: toBoard, map: map, toPixels: toPixels, board: board) else { return nil }
            image = front
        } else {
            func isBehind(_ q: CGPoint) -> Bool { map.depth(at: q.applying(toBoard)) <= 1e-3 }
            // Where the blur has spread behind the eye, the piece ends at its own edge.
            let e = image.extent
            if e != whole, [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.minX, y: e.maxY)].contains(where: isBehind) {
                image = image.cropped(to: whole)
            }
            guard let bent = bent(image, { map($0.applying(toBoard)).applying(toPixels) }) else { return nil }
            image = bent
        }
        let extent = image.extent
        guard !extent.isNull, !extent.isEmpty else { return nil }
        if placement.opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: placement.opacity)])
        }
        return image
    }

    /// A picture in perspective: its four corners where `shown` has them, in the frame's pixels,
    /// and the rest bent between them. Nil when it is seen edge on, and nothing of it shows.
    private static func bent(_ image: CIImage, _ shown: (CGPoint) -> CGPoint) -> CIImage? {
        let e = image.extent
        guard !e.isNull, !e.isInfinite, e.width > 0, e.height > 0 else { return nil }
        let topLeft = shown(CGPoint(x: e.minX, y: e.maxY)), topRight = shown(CGPoint(x: e.maxX, y: e.maxY))
        let bottomRight = shown(CGPoint(x: e.maxX, y: e.minY)), bottomLeft = shown(CGPoint(x: e.minX, y: e.minY))
        let quad = [topLeft, topRight, bottomRight, bottomLeft]
        let area = (0..<4).reduce(0.0) { $0 + Double(quad[$1].x * quad[($1 + 1) % 4].y - quad[($1 + 1) % 4].x * quad[$1].y) } / 2
        guard area.isFinite, abs(area) >= 0.5 else { return nil }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft), "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomRight": CIVector(cgPoint: bottomRight), "inputBottomLeft": CIVector(cgPoint: bottomLeft),
        ])
    }

    /// The part of a picture that lies in front of the eye and shows in the frame, placed there;
    /// nil when none of it does. A picture can only be bent between four corners that are all in
    /// front. So its outline is cut down to what shows, the picture is turned until all that is
    /// as near the eye as each other lies in one row, and it is cut off along the nearest row
    /// that still shows: what is left has its corners in front, and is bent into place.
    private static func front(of image: CIImage, toBoard: CGAffineTransform, map: FilmMap, toPixels: CGAffineTransform, board: CGSize) -> CIImage? {
        let e = image.extent
        guard !e.isNull, !e.isInfinite, e.width > 0, e.height > 0 else { return nil }
        var outline = [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.minX, y: e.maxY)]
            .map { $0.applying(toBoard) }
        // In front of the eye, and within the frame's four sides, a little past them: each a line
        // on the artboard, with what shows on the side where it is not below nothing.
        let past = 4.0, w = Double(board.width) + past, h = Double(board.height) + past
        let sides: [(a: Double, b: Double, c: Double)] = [
            (map.g, map.h, map.i - 1e-3),
            (map.a + past * map.g, map.b + past * map.h, map.c + past * map.i),
            (w * map.g - map.a, w * map.h - map.b, w * map.i - map.c),
            (map.d + past * map.g, map.e + past * map.h, map.f + past * map.i),
            (h * map.g - map.d, h * map.h - map.e, h * map.i - map.f),
        ]
        for side in sides {
            outline = FilmMap.cut(outline, along: side)
            guard outline.count >= 3 else { return nil }
        }
        // Turned so that the rows run level with the eye, the nearest row lowest.
        let steep = hypot(map.g, map.h)
        guard steep > 1e-12 else { return nil }
        let nx = map.g / steep, ny = map.h / steep
        let turn = CGAffineTransform(a: ny, b: nx, c: -nx, d: ny, tx: 0, ty: 0)
        let turned = outline.map { $0.applying(turn) }
        var box = CGRect.null
        for p in turned { box = box.union(CGRect(origin: p, size: .zero)) }
        guard box.width > 1e-6, box.height > 1e-6 else { return nil }
        let back = turn.inverted()
        return bent(image.transformed(by: toBoard.concatenating(turn)).cropped(to: box)) { map($0.applying(back)).applying(toPixels) }
    }

    // MARK: - The file

    /// What the movie is packed as. The colours are tagged as what they are, sRGB, so a player
    /// that reads the tags shows them as the canvas does.
    static func video(_ size: CGSize, fps: Int, codec: Codec) -> [String: Any] {
        [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: codec == .hevc ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: bitRate(size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                // A whole picture every second, so the movie can be dragged through.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ] as [String: Any],
        ]
    }

    /// Bits a second for a movie of this size: enough that flat colour, hairlines and small
    /// letters stay clean, about half as much again as video sites ask for. The most it may
    /// take: what packs it takes far less for a film that is mostly still, and HEVC less than
    /// H.264 for the same film.
    static func bitRate(_ size: CGSize, fps: Int) -> Int {
        max(1_000_000, Int(size.width * size.height * (CGFloat(fps) * 0.1 + 3)))
    }

    /// The movie's file as it is written, away from the main thread: the pieces' pictures are
    /// drawn here, and each frame is put together and handed to the writer.
    private actor Recorder {
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let size: CGSize
        private let board: CGSize
        private let backdrop: RGBA
        private let fps: Int
        private let assets: Assets?
        private var stills: [Still?]
        /// The parts of pieces drawn sharper than their whole pictures, each the last drawn of its piece.
        private var parts: [Still?]

        init(url: URL, size: CGSize, board: Node, pieces: Int, fps: Int, codec: Codec, assets: Assets?) throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // What says how the movie is read comes first in the file, so it plays from a website
            // before all of it has arrived.
            writer.shouldOptimizeForNetworkUse = true
            let settings = FilmExport.video(size, fps: fps, codec: codec)
            // Asked first: an input made with what cannot be packed here does not throw, it traps.
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw CannotPack() }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: codec.pixels,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.size = size
            self.board = board.frame.size
            self.backdrop = board.filmBackdrop
            self.fps = fps
            self.assets = assets
            stills = Array(repeating: nil, count: pieces)
            parts = Array(repeating: nil, count: pieces)
        }

        private var failure: Error { writer.error ?? CocoaError(.fileWriteUnknown) }

        func start() throws {
            guard writer.startWriting() else { throw failure }
            writer.startSession(atSourceTime: .zero)
        }

        /// Makes the frame of a shot and adds it to the movie as its `index`th.
        func add(_ shot: Shot, as index: Int) async throws {
            await draw(shot.fresh)
            // The writer takes frames only as fast as it packs them. While it has enough, wait
            // without holding a thread.
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw failure }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw failure }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw failure }
            let image = FilmExport.composed(stills, parts, shot, backdrop: backdrop, board: board, size: size)
            // Said of every frame, and before it is filled: Core Image works out its luma and
            // chroma by what is said here, each rounded to the movie's nearest step, once
            // (measured: never more than half a step off, and by nothing on average), and
            // packing it then changes no colour.
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = FilmExport.sRGB
            try FilmExport.imaging.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero).waitUntilCompleted()
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else { throw failure }
        }

        /// Draws the pieces a frame needs afresh, side by side when there are several, as at the
        /// film's start.
        private func draw(_ fresh: [Shot.Fresh]) async {
            func keep(_ item: Shot.Fresh, _ picture: FilmPictures.Picture?) {
                if item.part != nil { parts[item.piece] = picture.map(Still.init) } else { stills[item.piece] = picture.map(Still.init) }
            }
            guard fresh.count > 1 else {
                for item in fresh { keep(item, FilmPictures.picture(of: item.subject, scale: item.scale, assets: assets, part: item.part, deep: true)) }
                return
            }
            let assets = assets
            await withTaskGroup(of: (Int, FilmPictures.Picture?).self) { group in
                for (k, item) in fresh.enumerated() {
                    group.addTask { (k, FilmPictures.picture(of: item.subject, scale: item.scale, assets: assets, part: item.part, deep: true)) }
                }
                for await (k, picture) in group { keep(fresh[k], picture) }
            }
        }

        /// Ends the movie after its last frame and waits until the file is whole.
        func finish(frames: Int) async throws {
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
            let writer = writer
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.finishWriting { done.resume() }
            }
            guard writer.status == .completed else { throw failure }
        }

        /// Gives the movie up; the writer removes what it wrote of it.
        func cancel() {
            if writer.status == .writing { writer.cancelWriting() }
        }
    }
}
