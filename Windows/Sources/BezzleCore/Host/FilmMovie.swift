import Foundation
import CBezzleHost

// An artboard's film saved as a movie on Windows, as the Mac's FilmExport (Export/FilmExport.swift,
// ported): a frame is put together as the stage shows it, each piece drawn once (the Mac's own
// FilmPictures) and after that only placed by the film's own arithmetic (`Node.placement`), so
// what is posed is what is saved. Where the Mac's Core Image lays the pictures into the frame on
// the graphics card, Skia does (`bz_film_frame`); where AVFoundation packs the frames as H.264,
// Media Foundation's sink writer does (CBezzleHost/movie.cpp), in an .mp4 with the same settings.

extension WindowsCore {
    public enum FilmMovie {
        public struct Settings: Equatable, Sendable {
            /// Pixels to the artboard's point.
            public var scale: Double = 2
            public var fps = 60
            public init(scale: Double = 2, fps: Int = 60) {
                self.scale = scale
                self.fps = fps
            }
        }

        /// The longest side a movie is made with, in pixels.
        static let most: CGFloat = 3840
        /// The longest film saved as a movie, in seconds: an hour.
        static let longest: Double = 3600
        /// The most frames a second a movie is made with: Windows' H.264 encoder takes no more.
        public static let fastest = 120

        /// The movie's frame in pixels: the artboard's size times the scale, in even numbers, as
        /// H.264 wants them, and no side over `most`.
        static func size(of board: Node, settings: Settings) -> CGSize {
            let w = max(board.frame.width, 1), h = max(board.frame.height, 1)
            let scale = min(max(CGFloat(settings.scale), 0.01), most / max(w, h))
            func even(_ side: CGFloat) -> CGFloat { max(2, (side * scale / 2).rounded() * 2) }
            return CGSize(width: even(w), height: even(h))
        }

        /// The movie's frame for the film on a desk, for the Film card to say.
        public static func size(of desk: FilmDesk, settings: Settings) -> (width: Int, height: Int)? {
            guard let board = desk.filmBoard else { return nil }
            let s = size(of: board, settings: settings)
            return (Int(s.width), Int(s.height))
        }

        /// Why a film is not saved as a movie: it runs longer than a movie may.
        public struct TooLong: LocalizedError, Equatable {
            public var errorDescription: String? { String(localized: "This film is too long to save as a movie.") }
            public var recoverySuggestion: String? {
                String(localized: "A movie runs for an hour at most. Give the film a shorter length, or take away the keys that come later.")
            }
        }

        /// Why a movie could not be written: what Windows said.
        public struct Unwritten: LocalizedError {
            let code: Int32
            let step = bz_movie_failed_step()
            public var errorDescription: String? { "Windows could not write the movie (0x\(String(UInt32(bitPattern: code), radix: 16, uppercase: true)), step \(step))." }
        }

        static func check(_ board: Node) throws {
            let length = board.filmLength
            guard length.isFinite, length <= longest else { throw TooLong() }
        }

        /// The moments the movie's frames show: one every `fps`th of a second; a film that goes
        /// round stops a frame short of its end, one that plays once ends on its last moment.
        static func moments(of board: Node, fps: Int) -> [Double] {
            let fps = min(max(fps, 1), fastest), told = board.filmLength
            let length = told.isFinite ? min(max(told, 0), longest) : longest
            let count = max(1, Int((length * Double(fps)).rounded()))
            var all = (0..<count).map { Double($0) / Double(fps) }
            if board.film?.once == true, count > 1 { all[count - 1] = length }
            return all
        }

        /// Bits a second for a movie of this size, as the Mac's.
        static func bitRate(_ size: CGSize, fps: Int) -> Int {
            max(1_000_000, Int(size.width * size.height * (CGFloat(fps) * 0.1 + 3)))
        }

        /// Where a movie bound for `url` is written until it is whole: a file of its own in the
        /// temporary folder, the same for the same `url`.
        static func workFile(for url: URL) -> URL {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in url.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            return FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle Film", isDirectory: true)
                .appendingPathComponent(String(hash, radix: 16) + ".mp4")
        }

        /// One frame of the film at a moment, `size` pixels, composed exactly as the movie's
        /// frames are: premultiplied RGBA, rows top first.
        static func frame(of board: Node, at t: Double, size: CGSize) -> [UInt8]? {
            let size = CGSize(width: size.width.rounded(), height: size.height.rounded())
            guard size.width >= 1, size.height >= 1, board.frame.width > 0, board.frame.height > 0 else { return nil }
            var reel = Reel(board, size: size)
            let shot = reel.shot(at: t)
            reel.draw(shot.fresh)
            var pixels = [UInt8](repeating: 0, count: Int(size.width) * Int(size.height) * 4)
            let pieces = reel.pieces(of: shot)
            let done = pixels.withUnsafeMutableBytes { raw in
                WindowsCore.composeFilm(pieces, width: Int(size.width), height: Int(size.height), backdrop: board.filmBackdrop, bgra: false, into: raw.baseAddress!)
            }
            return done ? pixels : nil
        }

        /// A film's frames at moments for the AI server: the artboard by id, each frame of `size`
        /// pixels, premultiplied RGBA.
        static func frames(of id: UUID, at times: [Double], size: CGSize) -> [[UInt8]]? {
            guard let n = WindowsCore.design?.node(id), n.isArtboard else { return nil }
            let board = WindowsCore.seen(n)
            return times.map { frame(of: board, at: $0, size: size) ?? [] }
        }

        /// Writes the film of `board` to `url` as an .mp4, out of the way first and put in its
        /// place when whole. `progress` is told how far it is, 0 to 1. Throws `TooLong`, what
        /// Windows said, or `CancellationError` when the task it runs in is cancelled, removing
        /// what it wrote.
        static func write(_ board: Node, to url: URL, settings: Settings = Settings(), progress: @escaping @MainActor (Double) -> Void) async throws {
            try check(board)
            let size = size(of: board, settings: settings), fps = min(max(settings.fps, 1), fastest)
            let moments = moments(of: board, fps: fps)
            var reel = Reel(board, size: size, fps: fps)
            try tryPlace(url)
            let work = workFile(for: url)
            try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: work)
            var error: Int32 = 0
            guard let movie = bz_movie_open(work.path, Int32(size.width), Int32(size.height), Int32(fps), Int64(bitRate(size, fps: fps)), &error) else {
                throw Unwritten(code: error)
            }
            let writing = Writing(movie: movie, width: Int(size.width), height: Int(size.height), backdrop: board.filmBackdrop)
            do {
                for (k, t) in moments.enumerated() {
                    try Task.checkCancellation()
                    progress(Double(k) / Double(moments.count))
                    // What each piece draws at this moment is read and drawn here; the frame is
                    // put together and packed away from the main thread.
                    let shot = reel.shot(at: t)
                    reel.draw(shot.fresh)
                    let pieces = Pieces(list: reel.pieces(of: shot))
                    let code = await Task.detached(priority: .userInitiated) { writing.add(pieces.list, index: k) }.value
                    if code != 0 { throw Unwritten(code: code) }
                }
                try Task.checkCancellation()
                let code = await Task.detached(priority: .userInitiated) { writing.finish(frames: moments.count) }.value
                if code != 0 { throw Unwritten(code: code) }
                try fastStart(work)
                try put(work, at: url)
                progress(1)
            } catch {
                writing.cancel()
                try? FileManager.default.removeItem(at: work)
                throw Task.isCancelled ? CancellationError() : error
            }
        }

        /// Puts what says how a movie is read (its `moov`) before its pictures (`mdat`), as the
        /// Mac's movies have it, so that a website plays it before all of it has come: the boxes
        /// after the first are moved down by as much, and where each chunk of pictures begins
        /// (`stco`, `co64`) with them. A movie that has it first already, or that this cannot be
        /// done to, is left as it is.
        static func fastStart(_ url: URL) throws {
            var data = try Data(contentsOf: url)
            func u32(_ d: Data, _ at: Int) -> UInt64 { d[at..<at + 4].reduce(0) { $0 << 8 | UInt64($1) } }
            func u64(_ d: Data, _ at: Int) -> UInt64 { d[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
            // The boxes at the top: where each begins, how long it is, and what it is.
            var boxes: [(at: Int, size: Int, type: String)] = []
            var at = 0
            while at + 8 <= data.count {
                var size = Int(u32(data, at))
                let type = String(decoding: data[at + 4..<at + 8], as: UTF8.self)
                if size == 1, at + 16 <= data.count { size = Int(u64(data, at + 8)) } else if size == 0 { size = data.count - at }
                guard size >= 8, at + size <= data.count else { return }
                boxes.append((at, size, type))
                at += size
            }
            guard let m = boxes.firstIndex(where: { $0.type == "moov" }), let d = boxes.firstIndex(where: { $0.type == "mdat" }), m > d,
                  let first = boxes.first, first.type == "ftyp" else { return }
            var moov = data.subdata(in: boxes[m].at..<boxes[m].at + boxes[m].size)
            let shift = UInt64(moov.count)
            // Every chunk's offset, wherever in the box it is, moved down by the box's own size.
            func patch(_ from: Int, _ to: Int) -> Bool {
                var i = from
                while i + 8 <= to {
                    let size = Int(u32(moov, i)), type = String(decoding: moov[i + 4..<i + 8], as: UTF8.self)
                    guard size >= 8, i + size <= to else { return false }
                    switch type {
                    case "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "mvex":
                        guard patch(i + 8, i + size) else { return false }
                    case "stco", "co64":
                        let wide = type == "co64", count = Int(u32(moov, i + 12))
                        guard i + 16 + count * (wide ? 8 : 4) <= i + size else { return false }
                        for k in 0..<count {
                            let p = i + 16 + k * (wide ? 8 : 4)
                            let v = (wide ? u64(moov, p) : u32(moov, p)) + shift
                            if !wide, v > UInt64(UInt32.max) { return false }
                            for b in 0..<(wide ? 8 : 4) { moov[p + b] = UInt8(truncatingIfNeeded: v >> (8 * UInt64((wide ? 7 : 3) - b))) }
                        }
                    default:
                        break
                    }
                    i += size
                }
                return true
            }
            guard patch(8, moov.count) else { return }
            var out = data.subdata(in: first.at..<first.at + first.size)
            out.append(moov)
            for (k, box) in boxes.enumerated() where k != 0 && k != m { out.append(data.subdata(in: box.at..<box.at + box.size)) }
            data = Data()
            try out.write(to: url, options: .atomic)
        }

        private static func tryPlace(_ url: URL) throws {
            let files = FileManager.default
            if files.fileExists(atPath: url.path) {
                guard files.isWritableFile(atPath: url.path) || files.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
                }
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
                try files.removeItem(at: url)
            }
        }

        private static func put(_ work: URL, at url: URL) throws {
            let files = FileManager.default
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            try files.moveItem(at: work, to: url)
        }

        /// The frames handed over to be put together and packed, away from the main thread.
        private struct Pieces: @unchecked Sendable { let list: [bz_film_piece] }

        /// The movie being written, as the Mac's Recorder: one frame at a time.
        private nonisolated final class Writing: @unchecked Sendable {
            private var movie: OpaquePointer?
            private let width: Int, height: Int
            private let backdrop: RGBA
            private var pixels: [UInt8]

            init(movie: OpaquePointer, width: Int, height: Int, backdrop: RGBA) {
                self.movie = movie
                self.width = width
                self.height = height
                self.backdrop = backdrop
                pixels = [UInt8](repeating: 0, count: width * height * 4)
            }

            func add(_ pieces: [bz_film_piece], index: Int) -> Int32 {
                guard let movie else { return -1 }
                let (w, h, ground) = (width, height, backdrop)
                return pixels.withUnsafeMutableBytes { raw -> Int32 in
                    guard WindowsCore.composeFilm(pieces, width: w, height: h, backdrop: ground, bgra: true, into: raw.baseAddress!) else { return -2 }
                    return bz_movie_add(movie, raw.baseAddress, Int64(index))
                }
            }

            func finish(frames: Int) -> Int32 {
                guard let movie else { return -1 }
                self.movie = nil
                return bz_movie_finish(movie, Int64(frames))
            }

            func cancel() {
                guard let movie else { return }
                self.movie = nil
                bz_movie_cancel(movie)
            }
        }

        // MARK: What a frame is made from

        struct Shot {
            struct Fresh {
                var piece: Int
                var subject: FilmPictures.Subject
                var scale: CGFloat
                var part: FilmPictures.Part?
            }
            var placements: [FilmPlacement]
            var order: [Int]
            var fresh: [Fresh]
            var parts: Set<Int>
        }

        /// A film being made into frames: its pieces, and what has been drawn of each (the Mac's
        /// Reel). A piece is drawn once, whole, as sharp as the film shows it at its largest, and
        /// after that only placed; where a frame shows it larger than a whole picture can hold,
        /// the part of it that the frame shows is drawn for that frame, as sharp as the frame is.
        struct Reel {
            let board: Node
            let pieces: [FilmPiece]
            private let density: CGFloat
            private let pixels: CGFloat
            private let fps: Int
            private let ground: FilmPictures.Ground
            private var subjects: [FilmPictures.Subject?]
            private var rects: [(reach: CGRect, core: CGRect)]
            private var scales: [CGFloat?]
            private var whole: [Bool]
            private var parts: [FilmPictures.Part?]
            /// The pictures drawn of each piece, whole and in part, kept while the reel lasts.
            private var stills: [FilmPictures.Picture?]
            private var partStills: [FilmPictures.Picture?]
            private let size: CGSize

            init(_ board: Node, size: CGSize, fps: Int = 1) {
                self.board = board
                self.fps = max(fps, 1)
                self.size = size
                pieces = board.filmPieces()
                ground = FilmPictures.Ground.of(board)
                density = max(size.width / max(board.frame.width, 1), size.height / max(board.frame.height, 1))
                pixels = size.width * size.height
                subjects = Array(repeating: nil, count: pieces.count)
                rects = Array(repeating: (.zero, .zero), count: pieces.count)
                scales = Array(repeating: nil, count: pieces.count)
                whole = Array(repeating: false, count: pieces.count)
                parts = Array(repeating: nil, count: pieces.count)
                stills = Array(repeating: nil, count: pieces.count)
                partStills = Array(repeating: nil, count: pieces.count)
            }

            mutating func shot(at t: Double) -> Shot {
                let camera = board.camera(at: t)
                let placements = pieces.map { board.placement(of: $0, at: t, camera: camera) }
                let frame = CGRect(origin: .zero, size: board.frame.size)
                var fresh: [Shot.Fresh] = []
                var inParts: Set<Int> = []
                for (i, piece) in pieces.enumerated() {
                    if subjects[i] == nil || piece.changes {
                        let now = FilmPictures.subject(of: piece, on: board, ground: ground, at: t)
                        if now != subjects[i] {
                            subjects[i] = now
                            rects[i] = (FilmPictures.rect(of: now), FilmPictures.core(of: now))
                            whole[i] = false
                            parts[i] = nil
                        }
                    }
                    guard let subject = subjects[i] else { continue }
                    let (reach, core) = rects[i]
                    guard core.width > 0, core.height > 0 else { continue }
                    let asked = scales[i] ?? density * CGFloat(board.filmStretch(of: piece, around: core))
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

            private func part(_ i: Int, _ piece: FilmPiece, reach: CGRect, seen: CGRect, need: CGFloat, at t: Double, frame: CGRect) -> FilmPictures.Part? {
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
                    let q = board.placement(of: piece, at: then, camera: board.camera(at: then))
                    guard q.blur <= 0.05, q.opacity >= 0.001, let next = q.map.seen(of: reach, through: frame) else { continue }
                    let grown = all.union(next.part), sharper = max(most, CGFloat(next.stretch) * density)
                    let drawn = sharper * 1.2
                    guard max(grown.width, grown.height) * drawn <= FilmPictures.mostInPart.side, grown.width * grown.height * drawn * drawn <= limit else { break }
                    all = grown
                    most = sharper
                }
                return FilmPictures.part(for: all, of: reach, need: most, around: around) ?? alone
            }

            /// Draws the pieces a frame needs afresh.
            mutating func draw(_ fresh: [Shot.Fresh]) {
                for item in fresh {
                    let picture = WindowsCore.filmPicture(item.subject, scale: item.scale, part: item.part)
                    if item.part != nil { partStills[item.piece] = picture } else { stills[item.piece] = picture }
                }
            }

            /// The frame's pieces for Skia, the lowest first, each by its part where the shot
            /// shows it so.
            func pieces(of shot: Shot) -> [bz_film_piece] {
                let toFrame = FilmMap(a: Double(size.width / board.frame.width), e: Double(size.height / board.frame.height))
                let frame = CGRect(origin: .zero, size: board.frame.size)
                var out: [bz_film_piece] = []
                for i in shot.order {
                    guard let still = shot.parts.contains(i) ? partStills[i] : stills[i],
                          let piece = WindowsCore.filmPiece(still, shot.placements[i], toFrame: toFrame, window: frame) else { continue }
                    out.append(piece)
                }
                return out
            }
        }
    }
}

extension WindowsCore.FilmDesk {
    /// Saves the film at a place as a movie, while the desk tells how far it is (`exporting`). A
    /// film that plays is stopped first. False, with nothing done, while another movie is being
    /// saved or with no film on the desk. `after` is told how it ended: nothing when the movie is
    /// whole, `CancellationError` when it was stopped, or what went wrong.
    @discardableResult
    public func saveMovie(to url: URL, scale: Double, fps: Int, after: @escaping @MainActor (Error?) -> Void) -> Bool {
        guard saving == nil, let board = filmBoard else { return false }
        pause()
        exporting = 0
        saving = Task { [weak self] in
            var failure: Error?
            do {
                try await WindowsCore.FilmMovie.write(board, to: url, settings: WindowsCore.FilmMovie.Settings(scale: scale, fps: fps)) { done in
                    self?.exporting = done
                }
            } catch {
                failure = error
            }
            self?.exporting = nil
            self?.saving = nil
            after(failure)
        }
        return true
    }

    public func stopSaving() {
        saving?.cancel()
    }

    /// Why the film on the desk cannot be saved as a movie, before asking where: nil when it can.
    public var movieRefusal: (title: String, detail: String)? {
        guard let board = filmBoard else { return nil }
        do {
            try WindowsCore.FilmMovie.check(board)
            return nil
        } catch {
            let e = error as? WindowsCore.FilmMovie.TooLong
            return (e?.errorDescription ?? "\(error)", e?.recoverySuggestion ?? "")
        }
    }

    /// The film's artboard's name, for the movie's file.
    public var boardName: String { filmBoard?.name ?? "" }
}

extension WindowsCore {
    /// For trying films without the app (bezzle-render): each artboard of the open design whose
    /// film moves, drawn at `times` as the stage and the movie draw it, `scale` pixels to the
    /// point, into PNG files in `folder`; with `movie` (scale, fps), saved there as an .mp4 too.
    /// Says what was made and how long it took.
    public static func filmCheck(times: [Double], movie: (scale: Double, fps: Int)?, scale: Double, into folder: URL) async -> [String] {
        guard let doc = design else { return ["no design"] }
        var said: [String] = []
        for n in doc.nodes where n.isArtboard && (n.hasFilm || n.holdsMovingShader) {
            let board = seen(n)
            let size = FilmMovie.size(of: board, settings: FilmMovie.Settings(scale: scale, fps: 1))
            said.append("\(board.name): \(board.filmPieces().count) pieces, \(board.filmLength) s, frame \(Int(size.width))x\(Int(size.height))")
            for t in times {
                let started = WindowsCore.now
                guard let pixels = FilmMovie.frame(of: board, at: t, size: size) else {
                    said.append("  \(t) s: not drawn")
                    continue
                }
                let file = folder.appendingPathComponent("\(board.name)-film-\(String(format: "%.2f", t)).png")
                do {
                    try writePNG(pixels, width: Int(size.width), height: Int(size.height), to: file)
                    said.append("  \(t) s: \(Int((WindowsCore.now - started) * 1000)) ms -> \(file.lastPathComponent)")
                } catch {
                    said.append("  \(t) s: \(error)")
                }
            }
            if let movie {
                let file = folder.appendingPathComponent("\(board.name).mp4")
                let started = WindowsCore.now
                do {
                    try await FilmMovie.write(board, to: file, settings: FilmMovie.Settings(scale: movie.scale, fps: movie.fps)) { _ in }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                    said.append("  movie: \(Int((WindowsCore.now - started) * 1000)) ms, \(bytes) bytes -> \(file.lastPathComponent)")
                } catch {
                    said.append("  movie: \(error.localizedDescription)")
                }
            }
        }
        return said.isEmpty ? ["no artboard moves"] : said
    }
}
