import Foundation
import AppKit

/// An artboard's film as the page shows it. Its pieces are the Mac's (`Node.filmPieces`), each
/// drawn once as a picture (`FilmPictures`, the Mac's own file) which the page keeps, and at every
/// moment the film's arithmetic says where each shows (`Node.placement`): given to the page as a
/// 3 by 3 map from the picture's pixels to the frame's, which CanvasKit draws the picture through.
///
/// What is drawn when is as the Mac makes a movie's frames (FilmExport's Reel, which this follows
/// line by line where it can): a piece seen larger than its picture holds, or past what its
/// picture covers, has the part that shows drawn as sharp as it shows; a piece whose insides move
/// is drawn again at each moment, and then only where it shows, as the Mac's stage draws it.
/// While the film plays, parts are drawn only for what a picture does not cover, so that frames
/// keep coming: its pictures are then as sharp as they were drawn, and sharp again once it rests.
///
/// Only here, in the browser's core: Bezzle for Windows has its own stage (Host/FilmStage.swift).
@MainActor
final class WebFilm {
    /// A piece's picture as the page has it, and the part of the piece it is of, when not all.
    private struct Kept {
        var picture: FilmPictures.Picture
        var part: FilmPictures.Part?
    }

    /// The longest side a picture is made with here, and the most pixels: what any browser's
    /// graphics card takes as one texture, and no more than a page should hold of one piece.
    static let most: (side: CGFloat, pixels: CGFloat) = (4096, 16_000_000)

    /// The frames a second a playing film is thought to show, for looking ahead.
    private static let pace = 60

    let board: Node
    let pieces: [FilmPiece]
    private let layers: [Node?]
    private let ground: FilmPictures.Ground
    private let assets: Assets
    /// What each piece shows, read once, and at each moment for one whose insides move; with it
    /// where the piece draws at all, and what of that its whole picture covers.
    private var subjects: [FilmPictures.Subject?]
    private var rects: [(reach: CGRect, core: CGRect)]
    /// How sharp each whole picture is asked for: as the film shows the piece at its largest.
    private var asked: [CGFloat?]
    private var wholes: [Kept?]
    private var parts: [Kept?]
    /// The frame's pixels to the artboard's point that the pictures were drawn for.
    private var density: CGFloat = 0
    /// How many pictures have been drawn, for seeing that a piece is drawn once.
    private(set) var drawn = 0

    init(_ board: Node, assets: Assets) {
        self.board = board
        self.assets = assets
        pieces = board.filmPieces()
        layers = board.filmLayers(of: pieces)
        ground = FilmPictures.Ground.of(board)
        subjects = Array(repeating: nil, count: pieces.count)
        rects = Array(repeating: (.zero, .zero), count: pieces.count)
        asked = Array(repeating: nil, count: pieces.count)
        wholes = Array(repeating: nil, count: pieces.count)
        parts = Array(repeating: nil, count: pieces.count)
    }

    /// The film, as the page is told of it when it opens one.
    var described: String {
        let backdrop = board.filmBackdrop
        // A frame has nothing to show through to: a backdrop that is not solid lies on black.
        let ground = [backdrop.r * backdrop.a, backdrop.g * backdrop.a, backdrop.b * backdrop.a]
        return "{\"length\":\(board.filmLength),\"once\":\(board.film?.once == true),\"backdrop\":\(Self.json(ground)),"
            + "\"size\":[\(board.frame.width),\(board.frame.height)],\"pieces\":\(pieces.count),\"changes\":\(pieces.contains(where: \.changes))}"
    }

    // MARK: A frame

    /// What the frame at a moment is made from, `width` by `height` pixels, as the page reads it:
    /// the pieces that show, the lowest first, each with its picture's number, the map from that
    /// picture's pixels to the frame's, how solid it is and how blurred. Pictures made for it are
    /// drawn first. `playing` leaves sharper parts for when the film rests.
    func frame(at t: Double, width: Int, height: Int, playing: Bool) -> String {
        let size = fit(width, height)
        let before = drawn
        let camera = board.camera(at: t)
        let placements = pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera) }
        let window = CGRect(origin: .zero, size: board.frame.size)
        var shown = [Kept?](repeating: nil, count: pieces.count)
        for (i, piece) in pieces.enumerated() {
            let p = placements[i]
            // What does not show at this moment is not drawn for it.
            guard p.opacity >= 0.001 else { continue }
            if subjects[i] == nil || piece.changes {
                let now = FilmPictures.subject(of: piece, on: board, ground: ground, at: t)
                if now != subjects[i] {
                    // Its insides have moved: what was drawn of it is of another moment.
                    subjects[i] = now
                    rects[i] = (FilmPictures.rect(of: now), FilmPictures.core(of: now))
                    wholes[i] = nil
                    parts[i] = nil
                }
            }
            guard let subject = subjects[i] else { continue }
            let (reach, core) = rects[i]
            guard core.width > 0, core.height > 0 else { continue }
            // A whole picture: sharp at its largest in the whole film, as far as one may be.
            let want = asked[i] ?? density * CGFloat(board.filmStretch(of: piece, around: core))
            asked[i] = want
            let sharp = min(want, Self.most.side / max(core.width, core.height), (Self.most.pixels / (core.width * core.height)).squareRoot())
            if p.blur <= 0.05 {
                // Sharp: only what of it shows through the frame matters.
                guard let seen = p.map.seen(of: reach, through: window) else { continue }
                let need = CGFloat(seen.stretch) * density
                let covered = Self.holds(core, seen.part)
                if piece.changes || !covered || (!playing && need > sharp * 1.02),
                   let part = part(i, piece, reach: reach, seen: seen.part, need: need, at: t, window: window, ahead: playing && !piece.changes) {
                    if parts[i]?.part != part { parts[i] = draw(subject, scale: part.scale, part: part) }
                    if let kept = parts[i] {
                        shown[i] = kept
                        continue
                    }
                }
            }
            if wholes[i] == nil { wholes[i] = draw(subject, scale: sharp, part: nil) }
            shown[i] = wholes[i]
        }
        let toFrame = FilmMap(a: Double(size.width / max(board.frame.width, 1)), e: Double(size.height / max(board.frame.height, 1)))
        var placed: [String] = []
        for i in board.filmOrder(pieces, placements) {
            guard let kept = shown[i], let piece = Self.placed(kept.picture, placements[i], toFrame: toFrame, window: window, still: !pieces[i].changes) else { continue }
            placed.append(piece)
        }
        return "{\"pieces\":[" + placed.joined(separator: ",") + "],\"drawn\":\(drawn - before)}"
    }

    // MARK: Pictures the page may let go

    // A picture drawn of a moment that has passed, or for a frame of another size, is held here
    // no more: the page is told with the next answer, and lets go of what it made of it
    // (`PageKeeps`, which does the same for an artboard drawn as the design).

    /// The frame's size in pixels, taken as the one the pictures are drawn for from here on:
    /// those drawn for a frame of another size are let go.
    private func fit(_ width: Int, _ height: Int) -> CGSize {
        let size = CGSize(width: max(width, 1), height: max(height, 1))
        let density = max(size.width / max(board.frame.width, 1), size.height / max(board.frame.height, 1))
        if density != self.density {
            self.density = density
            asked = Array(repeating: nil, count: pieces.count)
            wholes = Array(repeating: nil, count: pieces.count)
            parts = Array(repeating: nil, count: pieces.count)
        }
        return size
    }

    /// Draws the whole picture of one more piece whose insides stay as they are, for a frame
    /// `width` by `height` pixels, before the film plays: so that playing does not wait for a
    /// piece that first shows in the middle of it. Answers the picture, and how many are left.
    func warm(width: Int, height: Int) -> String {
        _ = fit(width, height)
        var made: Int?, left = 0
        for (i, piece) in pieces.enumerated() where !piece.changes && wholes[i] == nil && asked[i] == nil {
            guard made == nil else {
                left += 1
                continue
            }
            if subjects[i] == nil {
                let now = FilmPictures.subject(of: piece, on: board, ground: ground, at: 0)
                subjects[i] = now
                rects[i] = (FilmPictures.rect(of: now), FilmPictures.core(of: now))
            }
            let core = rects[i].core
            // Asked for now, drawn or not: one that cannot be drawn is not tried again here.
            let want = density * CGFloat(core.width > 0 && core.height > 0 ? board.filmStretch(of: piece, around: core) : 1)
            asked[i] = want
            guard let subject = subjects[i], subject.time == nil, core.width > 0, core.height > 0 else { continue }
            let sharp = min(want, Self.most.side / max(core.width, core.height), (Self.most.pixels / (core.width * core.height)).squareRoot())
            wholes[i] = draw(subject, scale: sharp, part: nil)
            made = wholes[i]?.picture.image.id
        }
        return "{\"left\":\(left)" + (made.map { ",\"image\":\($0)" } ?? "") + "}"
    }

    /// Draws a subject's picture, which the page then has by its number.
    private func draw(_ subject: FilmPictures.Subject, scale: CGFloat, part: FilmPictures.Part?) -> Kept? {
        guard let picture = FilmPictures.picture(of: subject, scale: scale, assets: assets, part: part) else { return nil }
        drawn += 1
        return Kept(picture: picture, part: part)
    }

    /// Whether a rect lies within another, give or take a hundredth of a point. Asked side by
    /// side: Core Graphics' own `contains`, which adds the two and compares, says no to a rect
    /// that is within by less than its sums round to, and a piece would be drawn again for it.
    private static func holds(_ outer: CGRect, _ inner: CGRect) -> Bool {
        guard !inner.isNull, !outer.isNull else { return inner.isNull }
        let slack: CGFloat = 0.01
        return inner.minX >= outer.minX - slack && inner.maxX <= outer.maxX + slack && inner.minY >= outer.minY - slack && inner.maxY <= outer.maxY + slack
    }

    /// A part no bigger than a picture may be here: less sharp where it would be, on its own
    /// whole pixels still.
    private static func limited(_ part: FilmPictures.Part) -> FilmPictures.Part {
        let r = part.rect
        let scale = min(part.scale, most.side / max(r.width, r.height), (most.pixels / (r.width * r.height)).squareRoot())
        guard scale < part.scale, scale > 0, scale.isFinite else { return part }
        let x0 = (r.minX * scale).rounded(.down) / scale, y0 = (r.minY * scale).rounded(.down) / scale
        let x1 = (r.maxX * scale).rounded(.up) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
        return FilmPictures.Part(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), scale: scale)
    }

    /// The part of a piece to show a frame by: the one kept, while it covers what the frame shows
    /// as sharp as the frame shows it, or one to draw. `ahead`, for a film that plays, has a new
    /// one cover what the next half second shows too, as far as a part may hold that, so that a
    /// camera on its way is not drawn for frame by frame.
    private func part(_ i: Int, _ piece: FilmPiece, reach: CGRect, seen: CGRect, need: CGFloat, at t: Double, window: CGRect, ahead: Bool) -> FilmPictures.Part? {
        // Two pixels round what shows, for what the picture's edge is mixed with.
        let around = 2 / need
        guard let alone = FilmPictures.part(for: seen, of: reach, need: need, around: around).map(Self.limited) else { return nil }
        if let kept = parts[i]?.part, Self.holds(kept.rect, seen.insetBy(dx: -around, dy: -around).intersection(reach)),
           kept.scale >= min(need, alone.scale) * 0.999 {
            return kept
        }
        guard ahead else { return alone }
        var all = seen, most = need
        let length = board.filmLength
        let limit = min(Self.most.pixels, window.width * window.height * density * density * 4)
        for k in 1...(Self.pace / 2) {
            let then = t + Double(k) / Double(Self.pace)
            guard then <= length + 1e-9 else { break }
            let q = board.placement(of: piece, layer: layers[i], at: then, camera: board.camera(at: then))
            guard q.blur <= 0.05, q.opacity >= 0.001, let next = q.map.seen(of: reach, through: window) else { continue }
            let grown = all.union(next.part), sharper = max(most, CGFloat(next.stretch) * density)
            // As it would be drawn: a fifth sharper at most, by the steps parts are sharp in.
            let drawn = sharper * 1.2
            guard max(grown.width, grown.height) * drawn <= Self.most.side, grown.width * grown.height * drawn * drawn <= limit else { break }
            all = grown
            most = sharper
        }
        return FilmPictures.part(for: all, of: reach, need: most, around: around).map(Self.limited) ?? alone
    }

    /// A piece's picture where the film has it, for the page: nil when it does not show.
    /// `toFrame` takes the artboard's points to the frame's pixels; `window` is the frame in the
    /// artboard's points.
    private static func placed(_ picture: FilmPictures.Picture, _ p: FilmPlacement, toFrame: FilmMap, window: CGRect, still: Bool) -> String? {
        let r = picture.rect, map = p.map
        let w = Double(picture.image.width), h = Double(picture.image.height)
        guard p.opacity >= 0.001, r.width > 0, r.height > 0, w > 0, h > 0 else { return nil }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        // Wholly behind the eye, nothing of it shows.
        let behind = corners.filter { map.depth(at: $0) <= 1e-3 }.count
        guard behind < corners.count else { return nil }
        // The picture's own pixels, counted from its top left, to the artboard's points.
        let fromPicture = FilmMap(a: Double(r.width) / w, c: Double(r.minX), e: Double(r.height) / h, f: Double(r.minY))
        let whole = toFrame.after(map).after(fromPicture)
        var s = "{\"image\":\(picture.image.id),\"map\":\(json([whole.a, whole.b, whole.c, whole.d, whole.e, whole.f, whole.g, whole.h, whole.i]))"
            + ",\"opacity\":\(min(max(p.opacity, 0), 1))"
        // A picture that stays is worth making smaller copies of, for when it shows small.
        if still { s += ",\"still\":true" }
        // Blurred as it is drawn, before the camera sees it: in its picture's own pixels.
        if p.blur > 0.05 { s += ",\"blur\":\(p.blur * (w / Double(r.width) + h / Double(r.height)) / 2)" }
        if behind > 0 {
            // Reaching behind the eye, as an artboard's own sheet does under a camera that is
            // close and tipped: only what of it lies in front, and within the frame and a
            // little past it, is filled with the picture. Its outline there, in its pixels.
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
            s += ",\"outline\":" + json(outline.flatMap { [(Double($0.x) - Double(r.minX)) * w / Double(r.width), (Double($0.y) - Double(r.minY)) * h / Double(r.height)] })
        }
        return s + "}"
    }

    // MARK: For comparing with the Mac

    /// Where the film's arithmetic puts every piece at a moment, as tools/FilmTruthTests.swift
    /// writes it on the Mac: the two are compared number by number (tools/film-compare.mjs).
    func placements(at t: Double) -> String {
        let camera = board.camera(at: t)
        let placements = pieces.indices.map { board.placement(of: pieces[$0], layer: layers[$0], at: t, camera: camera) }
        let all = zip(pieces, placements).map { piece, p in
            "{\"key\":\"\(piece.key)\",\"changes\":\(piece.changes),\"opacity\":\(p.opacity),\"blur\":\(p.blur),\"height\":\(p.height),"
                + "\"map\":\(Self.json([p.map.a, p.map.b, p.map.c, p.map.d, p.map.e, p.map.f, p.map.g, p.map.h, p.map.i]))}"
        }
        return "{\"order\":\(board.filmOrder(pieces, placements)),\"pieces\":[" + all.joined(separator: ",") + "]}"
    }

    /// Numbers as JSON, each whole: a map's are not rounded on their way to the page.
    private static func json(_ values: [Double]) -> String {
        "[" + values.map { $0.isFinite ? "\($0)" : "0" }.joined(separator: ",") + "]"
    }
}
