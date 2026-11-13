import AVFoundation
import CoreImage
import Metal

/// An artboard's film saved as a movie.
///
/// A frame is put together as the canvas and the stage show it: each piece of the film is drawn
/// once (`FilmPictures`) and after that only placed, moment by moment, by the film's own
/// arithmetic (`Node.placement`), so what is posed is what is saved. Core Image does the placing
/// on the graphics card, straight into the pictures the movie's writer packs.
nonisolated enum FilmExport {
    struct Settings: Equatable, Sendable {
        /// Pixels to the artboard's point.
        var scale: CGFloat = 2
        var fps = 60
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

    /// The moments the movie's frames show, in seconds from the film's start: one for every
    /// `fps`th of a second the film runs. A film that goes round stops a frame short of its end,
    /// as its start follows; one that plays once ends on its last moment, where the movie rests.
    static func moments(of board: Node, fps: Int) -> [Double] {
        let fps = max(fps, 1), length = board.filmLength
        let count = max(1, Int((length * Double(fps)).rounded()))
        var all = (0..<count).map { Double($0) / Double(fps) }
        if board.film?.once == true, count > 1 { all[count - 1] = length }
        return all
    }

    /// One frame of the film as a picture of `size` pixels, composed exactly as the movie's
    /// frames are.
    @MainActor
    static func frame(of board: Node, at t: Double, size: CGSize, assets: Assets?) -> CGImage? {
        let size = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard size.width >= 1, size.height >= 1, board.frame.width > 0, board.frame.height > 0 else { return nil }
        var reel = Reel(board, size: size)
        let shot = reel.shot(at: t)
        var stills = [Still?](repeating: nil, count: reel.pieces.count)
        for fresh in shot.fresh {
            stills[fresh.piece] = FilmPictures.picture(of: fresh.subject, scale: fresh.scale, assets: assets).map(Still.init)
        }
        let image = composed(stills, shot, backdrop: board.filmBackdrop, board: board.frame.size, size: size)
        return imaging.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: sRGB)
    }

    /// Writes the film of `board` (an artboard as it is seen; its frame's origin may be anywhere)
    /// to `url` as an .mp4: H.264, sRGB, square pixels, `fps` frames a second and as long as the
    /// film runs. A file already there is replaced. `progress` is told how far it is, from 0 to
    /// 1 when the file is whole. Throws when the movie cannot be written. When the task it runs
    /// in is cancelled it stops, removes what it wrote and throws `CancellationError`.
    @MainActor
    static func write(_ board: Node, assets: Assets?, to url: URL, settings: Settings = Settings(),
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        let size = size(of: board, settings: settings), fps = max(settings.fps, 1)
        let moments = moments(of: board, fps: fps)
        var reel = Reel(board, size: size)
        // The writer does not write over a file.
        try? FileManager.default.removeItem(at: url)
        let recorder = try Recorder(url: url, size: size, board: board, pieces: reel.pieces.count, fps: fps, assets: assets)
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
            progress(1)
        } catch {
            await recorder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    // MARK: - What a frame is made from

    /// What one frame is made from: where each piece shows, in what order, and the pieces whose
    /// pictures have to be drawn for it first.
    private struct Shot: Sendable {
        struct Fresh: Sendable {
            var piece: Int
            var subject: FilmPictures.Subject
            var scale: CGFloat
        }

        var placements: [FilmPlacement]
        var order: [Int]
        var fresh: [Fresh]
    }

    /// A film being made into frames: its pieces, and what the picture kept of each was drawn from.
    @MainActor
    private struct Reel {
        let board: Node
        let pieces: [FilmPiece]
        /// The frame's pixels to the artboard's point.
        private let density: CGFloat
        private var drawn: [FilmPictures.Subject?]
        private var scales: [CGFloat?]

        init(_ board: Node, size: CGSize) {
            self.board = board
            pieces = board.filmPieces()
            density = max(size.width / max(board.frame.width, 1), size.height / max(board.frame.height, 1))
            drawn = Array(repeating: nil, count: pieces.count)
            scales = Array(repeating: nil, count: pieces.count)
        }

        /// What the frame at a moment is made from. A piece is drawn once and its picture kept;
        /// one whose insides move is drawn again only when they have moved since.
        mutating func shot(at t: Double) -> Shot {
            var fresh: [Shot.Fresh] = []
            for (i, piece) in pieces.enumerated() where drawn[i] == nil || piece.changes {
                let subject = FilmPictures.subject(of: piece, on: board, at: t)
                guard subject != drawn[i] else { continue }
                // Sharp at its largest in the whole film.
                let scale = scales[i] ?? density * board.filmStretch(of: piece, around: FilmPictures.rect(of: subject))
                scales[i] = scale
                drawn[i] = subject
                fresh.append(Shot.Fresh(piece: i, subject: subject, scale: scale))
            }
            let camera = board.camera(at: t)
            let placements = pieces.map { board.placement(of: $0, at: t, camera: camera) }
            return Shot(placements: placements, order: board.filmOrder(pieces, placements), fresh: fresh)
        }
    }

    // MARK: - Composing

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Core Image on the graphics card, mixing in plain sRGB values as drawing does everywhere
    /// else in Bezzle (see `Renderer.imaging`), so a faded piece looks as it does on the canvas.
    private static let imaging: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: sRGB, .cacheIntermediates: false]
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
    private static func composed(_ stills: [Still?], _ shot: Shot, backdrop: RGBA, board: CGSize, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        // The film counts points down from the top left, Core Image pixels up from the bottom left.
        let toPixels = CGAffineTransform(a: size.width / board.width, b: 0, c: 0, d: -size.height / board.height, tx: 0, ty: size.height)
        // A movie has nothing to show through to: a backdrop that is not solid lies on black.
        let ground = CIColor(red: backdrop.r * backdrop.a, green: backdrop.g * backdrop.a, blue: backdrop.b * backdrop.a)
        var out = CIImage(color: ground).cropped(to: frame)
        for i in shot.order {
            guard let still = stills[i], let piece = placed(still, by: shot.placements[i], toPixels: toPixels) else { continue }
            out = piece.composited(over: out)
        }
        return out.cropped(to: frame)
    }

    /// A piece's picture where the film has it, in the frame's pixels; nil when it does not show.
    private static func placed(_ still: Still, by placement: FilmPlacement, toPixels: CGAffineTransform) -> CIImage? {
        let r = still.rect, map = placement.map
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        // Faded away, or reaching behind the eye.
        guard placement.opacity >= 0.001, corners.allSatisfy({ map.depth(at: $0) > 1e-3 }) else { return nil }
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
        } else {
            func behind(_ q: CGPoint) -> Bool { map.depth(at: q.applying(toBoard)) <= 1e-3 }
            func shown(_ q: CGPoint) -> CGPoint { map(q.applying(toBoard)).applying(toPixels) }
            // Where the blur has spread behind the eye, the piece ends at its own edge.
            var e = image.extent
            if e != whole, [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.minX, y: e.maxY)].contains(where: behind) {
                image = image.cropped(to: whole)
                e = whole
            }
            // In perspective: its four corners where they show, and the rest bent between them.
            let topLeft = shown(CGPoint(x: e.minX, y: e.maxY)), topRight = shown(CGPoint(x: e.maxX, y: e.maxY))
            let bottomRight = shown(CGPoint(x: e.maxX, y: e.minY)), bottomLeft = shown(CGPoint(x: e.minX, y: e.minY))
            // Seen edge on, nothing of it shows.
            let quad = [topLeft, topRight, bottomRight, bottomLeft]
            let area = (0..<4).reduce(0.0) { $0 + Double(quad[$1].x * quad[($1 + 1) % 4].y - quad[($1 + 1) % 4].x * quad[$1].y) } / 2
            guard area.isFinite, abs(area) >= 0.5 else { return nil }
            image = image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: topLeft), "inputTopRight": CIVector(cgPoint: topRight),
                "inputBottomRight": CIVector(cgPoint: bottomRight), "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            ])
        }
        let extent = image.extent
        guard !extent.isNull, !extent.isEmpty else { return nil }
        if placement.opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: placement.opacity)])
        }
        return image
    }

    // MARK: - The file

    /// What the movie is packed as. The colours are tagged as what they are, sRGB, so a player
    /// that reads the tags shows them as the canvas does.
    private static func video(_ size: CGSize, fps: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: bitRate(size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                // A whole picture every second, so the movie can be dragged through.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ] as [String: Any],
        ]
    }

    /// Bits a second for a movie of this size: enough that flat colour, hairlines and small
    /// letters stay clean, about half as much again as video sites ask for.
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

        init(url: URL, size: CGSize, board: Node, pieces: Int, fps: Int, assets: Assets?) throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // What says how the movie is read comes first in the file, so it plays from a website
            // before all of it has arrived.
            writer.shouldOptimizeForNetworkUse = true
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: FilmExport.video(size, fps: fps))
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
            let image = FilmExport.composed(stills, shot, backdrop: backdrop, board: board, size: size)
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = FilmExport.sRGB
            try FilmExport.imaging.startTask(toRender: image, from: CGRect(origin: .zero, size: size), to: destination, at: .zero).waitUntilCompleted()
            // Said of every frame, so that packing it changes no colour.
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else { throw failure }
        }

        /// Draws the pieces a frame needs afresh, side by side when there are several, as at the
        /// film's start.
        private func draw(_ fresh: [Shot.Fresh]) async {
            guard fresh.count > 1 else {
                for item in fresh { stills[item.piece] = FilmPictures.picture(of: item.subject, scale: item.scale, assets: assets).map(Still.init) }
                return
            }
            let assets = assets
            await withTaskGroup(of: (Int, FilmPictures.Picture?).self) { group in
                for item in fresh {
                    group.addTask { (item.piece, FilmPictures.picture(of: item.subject, scale: item.scale, assets: assets)) }
                }
                for await (piece, picture) in group { stills[piece] = picture.map(Still.init) }
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
