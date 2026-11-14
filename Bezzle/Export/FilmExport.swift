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

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Core Image on the graphics card, mixing in plain sRGB values as drawing does everywhere
    /// else in Bezzle (see `Renderer.imaging`), so a faded piece looks as it does on the canvas.
    /// It works in sixteen bit numbers, so fading, blurring and scaling keep what the deep
    /// pictures bring, down to the last step, where the movie's own depth takes over.
    private static let imaging: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: sRGB, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// A piece's picture as Core Image takes it, made once so that it is handed to the graphics
    /// card once.
    private struct Still: Sendable {
        let image: CIImage
        /// The part of the artboard it covers, in the artboard's points.
        let rect: CGRect

        init(_ picture: FilmPictures.Picture) {
            image = CIImage(cgImage: picture.image)
            rect = picture.rect
        }
    }

    /// A frame of `size` pixels: the backdrop, and over it each piece where the film has it, the
    /// lowest first. `board` is the artboard's size, which is the frame's in points.
    private static func composed(_ stills: [Still?], _ parts: [Still?], _ shot: Shot, backdrop: RGBA, board: CGSize, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        // The film counts points down from the top left, Core Image pixels up from the bottom left.
        let toPixels = CGAffineTransform(a: size.width / board.width, b: 0, c: 0, d: -size.height / board.height, tx: 0, ty: size.height)
        // A movie has nothing to show through to: a backdrop that is not solid lies on black.
        let ground = CIColor(red: backdrop.r * backdrop.a, green: backdrop.g * backdrop.a, blue: backdrop.b * backdrop.a)
        var out = CIImage(color: ground).cropped(to: frame)
        for i in shot.order {
            // By the part drawn of it for this frame, where its whole picture would not do.
            guard let still = shot.parts.contains(i) ? parts[i] : stills[i],
                  let piece = placed(still, by: shot.placements[i], toPixels: toPixels, board: board) else { continue }
            out = piece.composited(over: out)
        }
        return out.cropped(to: frame)
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
