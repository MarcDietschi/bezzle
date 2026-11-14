import Foundation
import CBezzleHost

// The film's stage on Windows, as the Mac's FilmStageView (Canvas/FilmStage.swift, ported): the
// artboard being animated, shown as its pieces' pictures (the Mac's own FilmPictures, linked into
// Film/), each placed where the camera shows it at the playhead (`FilmLens`). Pictures are drawn
// once and after that only placed: where the Mac's graphics card moves layers, Skia lays the
// pictures into the frame through each one's 3×3 map (`bz_film_frame`), so posing, scrubbing and
// playing never draw the design again, only a piece whose own insides move, and that only as far
// as it shows through the frame, as sharp as it shows there. What is placed at every frame is
// found once (`Node.filmLayers`), not looked for through the artboard for each piece.
//
// Only what shows of the artboard in the canvas is laid out, at the screen's pixels. A piece seen
// larger than its picture holds, or past what the picture covers, has the part that shows drawn
// again as sharp as it shows, once the film rests (`FilmPictures.Part`), and that part is shown in
// its place. While the film plays its pictures are sharp to four times their size, as drawn.

extension WindowsCore {
    /// A piece's picture, as Skia has it, placed in a frame by a placement: for `bz_film_frame`.
    /// `toFrame` takes the artboard's points to the frame's pixels; `window` is the part of the
    /// artboard the frame shows, in its points, past which nothing need be drawn.
    static func filmPiece(_ picture: FilmPictures.Picture, _ p: FilmPlacement, toFrame: FilmMap, window: CGRect) -> bz_film_piece? {
        guard p.opacity >= 0.001 else { return nil }
        let r = picture.rect
        let w = Double(picture.image.width), h = Double(picture.image.height)
        guard r.width > 0, r.height > 0, w > 0, h > 0 else { return nil }
        let map = p.map
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        let behind = corners.filter { map.depth(at: $0) <= 1e-3 }.count
        guard behind < 4 else { return nil }
        var piece = bz_film_piece()
        piece.picture = Int32(picture.image.id)
        piece.opacity = min(max(p.opacity, 0), 1)
        let fromPicture = FilmMap(a: Double(r.width) / w, c: Double(r.minX), e: Double(r.height) / h, f: Double(r.minY))
        let whole = toFrame.after(map).after(fromPicture)
        withUnsafeMutableBytes(of: &piece.map) { raw in
            let m = raw.bindMemory(to: Double.self)
            for (k, v) in [whole.a, whole.b, whole.c, whole.d, whole.e, whole.f, whole.g, whole.h, whole.i].enumerated() { m[k] = v }
        }
        if p.blur > 0.05 {
            // As much blur as the frame shows of it: grown with the piece and with the frame's pixels.
            piece.blur = p.blur * map.stretch(at: CGPoint(x: r.midX, y: r.midY)) * hypot(toFrame.a, toFrame.d)
        }
        if behind > 0 {
            // Reaching behind the eye: only what of it lies in front, and within the frame and a
            // little past it, is filled with the picture.
            var outline = corners
            let past = 4.0
            let x0 = Double(window.minX) - past, x1 = Double(window.maxX) + past, y0 = Double(window.minY) - past, y1 = Double(window.maxY) + past
            let sides: [(a: Double, b: Double, c: Double)] = [
                (map.g, map.h, map.i - 1e-3),
                (map.a - x0 * map.g, map.b - x0 * map.h, map.c - x0 * map.i),
                (x1 * map.g - map.a, x1 * map.h - map.b, x1 * map.i - map.c),
                (map.d - y0 * map.g, map.e - y0 * map.h, map.f - y0 * map.i),
                (y1 * map.g - map.d, y1 * map.h - map.e, y1 * map.i - map.f),
            ]
            for side in sides {
                outline = FilmMap.cut(outline, along: side)
                guard outline.count >= 3 else { return nil }
            }
            piece.count = Int32(min(outline.count, 9))
            withUnsafeMutableBytes(of: &piece.outline) { raw in
                let o = raw.bindMemory(to: Double.self)
                for (k, q) in outline.prefix(9).enumerated() {
                    o[2 * k] = (Double(q.x) - Double(r.minX)) * w / Double(r.width)
                    o[2 * k + 1] = (Double(q.y) - Double(r.minY)) * h / Double(r.height)
                }
            }
        }
        return piece
    }

    /// Draws a subject's picture and hands it, and what it draws, to Skia, which keeps it while
    /// the picture is held.
    static func filmPicture(_ subject: FilmPictures.Subject, scale: CGFloat, part: FilmPictures.Part? = nil) -> FilmPictures.Picture? {
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        let made = Probe.time("picture.draw") { FilmPictures.picture(of: subject, scale: scale, assets: assets, part: part) }
        Probe.time("picture.send") { for p in Images.shared.list where p.id >= first { send(p) } }
        forget(before: first)
        return made
    }

    /// A frame put together by Skia: the backdrop, as a movie has it (one that is not solid lies on
    /// black), and the pieces over it, the lowest first.
    nonisolated static func composeFilm(_ pieces: [bz_film_piece], width: Int, height: Int, backdrop: RGBA, bgra: Bool, into pixels: UnsafeMutableRawPointer) -> Bool {
        let ground = [backdrop.r * backdrop.a, backdrop.g * backdrop.a, backdrop.b * backdrop.a, 1]
        return ground.withUnsafeBufferPointer { g in
            pieces.withUnsafeBufferPointer { p in
                bz_film_frame(Int32(width), Int32(height), g.baseAddress, p.baseAddress, Int32(p.count), bgra ? 1 : 0, pixels) == 0
            }
        }
    }

    @MainActor public final class FilmStage {
        /// A piece on the stage: what it draws and the picture kept of it.
        private struct Shown {
            var piece: FilmPiece
            var subject: FilmPictures.Subject
            /// What its whole picture covers, and where it draws at all.
            var rect: CGRect
            var reach: CGRect
            var picture: FilmPictures.Picture
            /// How many pixels to the point its whole picture has.
            var sharp: CGFloat
            /// The layer it places, found once with the others (`Node.filmLayers`).
            var layer: Node?
        }

        /// A picture kept: what it shows, how sharp, of which part when not of all of it (for a
        /// piece whose insides move), and when it was last on the stage.
        private struct Kept {
            var subject: FilmPictures.Subject
            var scale: CGFloat
            var part: FilmPictures.Part? = nil
            var picture: FilmPictures.Picture
            var used: Int
        }

        /// A part of a piece drawn sharper than its whole picture: what it shows, and its picture.
        private struct Sharper {
            var subject: FilmPictures.Subject
            var part: FilmPictures.Part
            var picture: FilmPictures.Picture
        }

        private struct Signature: Equatable {
            var version: Int
            var board: UUID
            var loose: Set<UUID>
            var fronts: [UUID: Int]
            var step: CGFloat
            var measured: Bool
        }

        private var shown: [Shown] = []
        /// The pieces last worked out, and the layer each places, found in one walk through the
        /// artboard: kept while only time passes, and not looked for again at every frame.
        private var pieces: [FilmPiece] = []
        private var layers: [Node?] = []
        private var kept: [String: Kept] = [:]
        private var sharper: [String: Sharper] = [:]
        private var ground: FilmPictures.Ground?
        private var signature: Signature?
        private var drawnAt = -1.0
        /// The moment of the frame last put together and the part of the artboard it showed, to
        /// tell a film that moves from one frame to the next (playing, a hand scrubbing through
        /// it, the canvas moved or zoomed under it) from one that rests.
        private var framed: (at: Double, window: CGRect)?
        /// Whether the frame last put together would show a part sharper than it does: left as
        /// it was because the moment was moving, and drawn with a frame at the same moment
        /// (`FilmView` asks for one once the playhead has rested a little).
        public private(set) var owesParts = false
        private var changing = false
        private var installs = 0
        /// How many pictures and parts have been drawn, for looking at what it costs.
        public private(set) var picturesMade = 0
        public private(set) var partsMade = 0

        public init() {}

        /// Lets every picture go, as when the film leaves the canvas.
        public func reset() {
            shown = []
            pieces = []
            layers = []
            kept = [:]
            sharper = [:]
            ground = nil
            signature = nil
            drawnAt = -1
            framed = nil
            owesParts = false
            changing = false
        }

        /// How sharp to draw for something shown this many times its size: the next of the steps
        /// that double it every second one.
        private static func sharpness(for times: CGFloat) -> CGFloat {
            pow(2, (log2(times) * 2 - 0.02).rounded(.up) / 2)
        }

        /// The film's frame at the playhead, drawn into pixels the caller has: the part of the
        /// artboard that shows on a stage `size` big (in its points), the design's origin at
        /// `pan` there and `zoom` to the point, `pixelScale` pixels to the stage's point. `fill`
        /// is told the frame's size in pixels and gives where its premultiplied BGRA pixels go.
        /// Gives back where the frame lies on the stage, in its points; nil with no film.
        public func draw(_ desk: FilmDesk, zoom: Double, pan: CGPoint, size: CGSize, pixelScale: Double,
                         into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> CGRect? {
            owesParts = false
            guard desk.on, let board = desk.filmBoard, board.frame.width > 0, board.frame.height > 0, zoom > 0, pixelScale > 0 else {
                reset()
                return nil
            }
            let k = zoom * pixelScale
            // The artboard on the stage, in its pixels, and the part of it that shows, on whole pixels.
            let bx = (Double(board.frame.minX) * zoom + Double(pan.x)) * pixelScale
            let by = (Double(board.frame.minY) * zoom + Double(pan.y)) * pixelScale
            let bw = Double(board.frame.width) * k, bh = Double(board.frame.height) * k
            let x0 = max(bx, 0).rounded(.down), y0 = max(by, 0).rounded(.down)
            let x1 = min(bx + bw, Double(size.width) * pixelScale).rounded(.up), y1 = min(by + bh, Double(size.height) * pixelScale).rounded(.up)
            guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
            let width = Int(x1 - x0), height = Int(y1 - y0)
            // The artboard's points into the frame's pixels, and the part of the artboard it shows.
            let toFrame = FilmMap(a: k, c: bx - x0, e: k, f: by - y0)
            let window = CGRect(x: (x0 - bx) / k, y: (y0 - by) / k, width: Double(width) / k, height: Double(height) / k)

            let t = desk.playing ? desk.head : desk.filmTime
            let step = Self.sharpness(for: CGFloat(max(k, 0.05)))
            let wanted = Signature(version: WindowsCore.designVersion, board: board.id, loose: Set(desk.posedLayers), fronts: WindowsCore.fronts,
                                   step: step, measured: !WindowsCore.inGesture)
            if wanted != signature {
                signature = wanted
                Probe.time("stage.prepare") { prepare(board, at: t, pixels: step, window: window, screen: CGFloat(k), measured: wanted.measured) }
            } else if changing, t != drawnAt {
                Probe.time("stage.prepareAgain") { prepare(board, at: t, pixels: step, window: window, screen: CGFloat(k), again: true) }
            }
            guard !shown.isEmpty, let pixels = fill(width, height) else { return nil }
            // A part is drawn here, on the thread that puts the frame together (the Mac draws its
            // parts away from it), so none is drawn while the film moves from frame to frame or
            // a hand is on it: a dozen of them at every step were most of what held a scrub up.
            // They come with the frame that rests.
            let moving = desk.playing || WindowsCore.inGesture || framed.map { $0.at != t || $0.window != window } == true
            framed = (t, window)
            owesParts = false
            let camera = board.camera(at: t)
            let placements = Probe.time("stage.placements") { shown.map { board.placement(of: $0.piece, layer: $0.layer, at: t, camera: camera) } }
            var pieces: [bz_film_piece] = []
            for i in Probe.time("stage.order", { board.filmOrder(shown.map(\.piece), placements) }) {
                let p = placements[i]
                // A part drawn sharper, where it covers what shows: drawn now when the film rests.
                if let part = part(i, p, window: window, pixels: CGFloat(k), playing: moving),
                   let piece = WindowsCore.filmPiece(part, p, toFrame: toFrame, window: window) {
                    pieces.append(piece)
                    continue
                }
                if let piece = WindowsCore.filmPiece(shown[i].picture, p, toFrame: toFrame, window: window) { pieces.append(piece) }
            }
            guard Probe.time("stage.compose", { WindowsCore.composeFilm(pieces, width: width, height: height, backdrop: board.filmBackdrop, bgra: true, into: pixels) }) else { return nil }
            return CGRect(x: x0 / pixelScale, y: y0 / pixelScale, width: Double(width) / pixelScale, height: Double(height) / pixelScale)
        }

        /// Works out the film's pieces, and draws the pictures that are not kept from before.
        /// `again` when only time has passed, for the pieces whose insides move: the pieces and
        /// their layers are the ones worked out before, and the others are left as they are.
        ///
        /// A piece whose insides move is drawn again at every moment, so it is drawn only as it is
        /// seen then, as the Mac's stage draws it (`FilmStageView.seenPart`): the part of it that
        /// shows through `window` (the part of the artboard the frame shows, in its points), as
        /// sharp as it shows at `screen` pixels to the point, with a little room round it. All of
        /// it, as sharp as it ever shows, at every step, was most of a scrub's time with a moving
        /// shader under the whole artboard.
        private func prepare(_ board: Node, at t: Double, pixels: CGFloat, window: CGRect, screen: CGFloat, measured: Bool = true, again: Bool = false) {
            if !again || pieces.isEmpty {
                let loose = Set(signature?.loose ?? [])
                pieces = board.filmPieces(loose: loose)
                layers = board.filmLayers(of: pieces)
            }
            changing = pieces.contains(where: \.changes)
            drawnAt = t
            let ground: FilmPictures.Ground
            if again, let had = self.ground { ground = had } else { ground = FilmPictures.Ground.of(board, before: self.ground) }
            self.ground = ground
            installs += 1
            var next: [Shown] = []
            let measure = measured && !again
            var was: [String: Shown] = [:]
            if again { for s in shown { was[s.piece.key] = s } }
            var camera: FilmCamera?
            for (index, piece) in pieces.enumerated() {
                let had = kept[piece.key]
                if again, !piece.changes, let had, let before = was[piece.key] {
                    kept[piece.key]?.used = installs
                    next.append(Shown(piece: piece, subject: had.subject, rect: before.rect, reach: before.reach, picture: had.picture, sharp: before.sharp,
                                      layer: layers[index]))
                    continue
                }
                let subject = Probe.time("stage.subject") { FilmPictures.subject(of: piece, on: board, ground: ground, at: t) }
                let rect = FilmPictures.core(of: subject)
                guard rect.width > 0, rect.height > 0 else { continue }
                var picture = had?.picture
                if piece.changes, window.width > 0, window.height > 0, screen > 0 {
                    let lens = camera ?? board.camera(at: t)
                    camera = lens
                    if let part = Self.seenPart(of: subject, placed: board.placement(of: piece, layer: layers[index], at: t, camera: lens), through: window, screen: screen) {
                        if let had, had.subject.isDrawn(as: subject), Self.holds(had, part) {
                            kept[piece.key]?.used = installs
                        } else {
                            picture = Probe.time("stage.picture") { WindowsCore.filmPicture(subject, scale: part.scale, part: part) }
                            picturesMade += 1
                            if let picture { kept[piece.key] = Kept(subject: subject, scale: part.scale, part: part, picture: picture, used: installs) }
                        }
                        guard let picture else { continue }
                        next.append(Shown(piece: piece, subject: subject, rect: picture.rect,
                                          reach: FilmPictures.rect(of: subject).union(picture.rect), picture: picture,
                                          sharp: FilmPictures.sharpness(of: picture), layer: layers[index]))
                        continue
                    }
                }
                var scale = pixels
                if let had, had.part == nil, !measure {
                    scale = had.scale
                } else {
                    scale = pixels * Self.sharpness(for: CGFloat(min(board.filmStretch(of: piece, around: rect), 4)))
                }
                scale = min(scale, FilmPictures.most / max(rect.width, rect.height))
                if !(had.map { $0.part == nil && $0.scale >= scale * 0.99 && $0.subject.isDrawn(as: subject) } ?? false) {
                    picture = Probe.time("stage.picture") { WindowsCore.filmPicture(subject, scale: scale) }
                    picturesMade += 1
                    if let picture { kept[piece.key] = Kept(subject: subject, scale: scale, picture: picture, used: installs) }
                } else {
                    kept[piece.key]?.used = installs
                }
                guard let picture else { continue }
                next.append(Shown(piece: piece, subject: subject, rect: picture.rect,
                                  reach: FilmPictures.rect(of: subject).union(picture.rect), picture: picture,
                                  sharp: FilmPictures.sharpness(of: picture), layer: layers[index]))
            }
            shown = next
            kept = kept.filter { $0.value.used >= installs - 3 }
            let here = Set(next.map(\.piece.key))
            var subjects: [String: FilmPictures.Subject] = [:]
            for s in next where here.contains(s.piece.key) { subjects[s.piece.key] = s.subject }
            sharper = sharper.filter { key, held in subjects[key].map { held.subject.isDrawn(as: $0) } ?? false }
        }

        /// The part to draw of a piece whose insides move, placed so at the moment: what shows of
        /// it through `window`, as sharp as it shows at `screen` pixels to the artboard's point,
        /// and a tenth more each way. Nil for one that does not show, or shows blurred: that is
        /// drawn whole. As the Mac's `FilmStageView.seenPart`.
        private static func seenPart(of subject: FilmPictures.Subject, placed p: FilmPlacement, through window: CGRect, screen: CGFloat) -> FilmPictures.Part? {
            let reach = FilmPictures.rect(of: subject)
            guard p.blur <= 0.05, p.opacity > 0.001, reach.width > 0, reach.height > 0, let seen = p.map.seen(of: reach, through: window) else { return nil }
            let need = CGFloat(seen.stretch) * screen
            return FilmPictures.part(for: seen.part, of: reach, need: need, margin: 0.1, around: 2 / max(need, 1e-6))
        }

        /// Whether a picture kept of a piece holds a part of it as sharp as asked.
        private static func holds(_ had: Kept, _ part: FilmPictures.Part) -> Bool {
            let rect = had.part?.rect ?? had.picture.rect
            return rect.insetBy(dx: -0.01, dy: -0.01).contains(part.rect) && had.scale >= part.scale * 0.99
        }

        /// The part of a piece to show in place of its whole picture: one kept that covers what
        /// shows sharp enough, or, while the film rests, one drawn now. Nil where the whole picture
        /// will do, the piece does not show, or it is blurred anyway.
        private func part(_ i: Int, _ p: FilmPlacement, window: CGRect, pixels: CGFloat, playing: Bool) -> FilmPictures.Picture? {
            let s = shown[i]
            guard p.blur <= 0.05, p.opacity > 0.001, let seen = p.map.seen(of: s.reach, through: window) else { return nil }
            let need = CGFloat(seen.stretch) * pixels
            let within = s.rect.insetBy(dx: -0.01, dy: -0.01).contains(seen.part)
            guard need > s.sharp * 1.05 || !within else { return nil }
            let key = s.piece.key
            let fresh = FilmPictures.part(for: seen.part, of: s.reach, need: need, margin: playing ? 0.05 : 0.1)
            // No sharper than a part may be: one held back by its size is as sharp as it gets.
            let most = fresh.map { Double($0.scale) } ?? Double(need)
            if let held = sharper[key], held.subject.isDrawn(as: s.subject),
               held.part.rect.insetBy(dx: -0.01, dy: -0.01).contains(seen.part), Double(held.part.scale) <= Double(need) * 2.5,
               Double(held.part.scale) >= min(Double(need), most) * (playing ? 0.85 : 0.999) {
                return held.picture
            }
            guard let part = fresh else { return nil }
            // A part held back by its size to no sharper than the whole picture is not worth drawing.
            guard part.scale > s.sharp * 1.05 || !within else { return nil }
            guard !playing else {
                owesParts = true
                return nil
            }
            guard let picture = WindowsCore.filmPicture(s.subject, scale: part.scale, part: part) else { return nil }
            partsMade += 1
            sharper[key] = Sharper(subject: s.subject, part: part, picture: picture)
            return picture
        }
    }
}
