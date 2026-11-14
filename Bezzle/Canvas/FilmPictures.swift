import AppKit

/// The drawings a film is made of. Each piece of an artboard (`FilmPiece`) is drawn once, away
/// from the main thread, and after that only placed as time passes: by the canvas while it is
/// posed, by the stage while it plays, and by the movie that is saved. Nothing is drawn afresh
/// from frame to frame but a piece whose own insides move.
nonisolated enum FilmPictures {
    /// A piece drawn: its picture, and the part of the artboard it covers, in the artboard's points.
    struct Picture: @unchecked Sendable {
        let image: CGImage
        let rect: CGRect
    }

    /// The artboard a film's pieces are drawn on: without its layers' keys, and lying at the
    /// origin. Its pieces share one, so that telling whether two of them were drawn on the same
    /// artboard takes a glance, and not a reading of every layer for each piece.
    final class Ground: @unchecked Sendable {
        let board: Node

        init(_ board: Node) { self.board = board }

        /// The ground of an artboard as it is now; `before` itself when nothing of it has changed
        /// since, so that it is still the one its pieces' pictures were drawn on.
        static func of(_ board: Node, before: Ground? = nil) -> Ground {
            var ground = board.withoutMotion
            ground.frame.origin = .zero
            if let before, before.board == ground { return before }
            return Ground(ground)
        }
    }

    /// What of the design a piece draws: enough to make its picture away from here, and to tell
    /// when it has to be made again. A layer's keys are no part of it, as posing a layer only
    /// places its picture elsewhere.
    struct Subject: Equatable, @unchecked Sendable {
        var kind: FilmPiece.Kind
        /// The ground: the artboard with nothing on it. Else the layers, bottom first.
        var layers: [Node]
        var origin: CGPoint
        /// Whether it ends at the artboard's edges: the artboard's own sheet does. Its layers do
        /// not. At rest the film's frame is the artboard, and cuts off what reaches past it as
        /// the design does; a camera that draws back sees what lies there, a shadow that falls
        /// past the edge or a layer waiting outside, whether or not the layer has keys.
        var clipped: Bool
        /// The film's moment, for what moves by itself (a shader) in its layers; nil for none.
        var time: Double? = nil
        fileprivate let ground: Ground

        /// The artboard they lie on, for what blurs the layers behind it; without its own layers'
        /// keys, so that posing one of them leaves the others' pictures alone.
        var board: Node { ground.board }

        fileprivate init(kind: FilmPiece.Kind, layers: [Node], origin: CGPoint, ground: Ground, clipped: Bool) {
            self.kind = kind
            self.layers = layers
            self.origin = origin
            self.ground = ground
            self.clipped = clipped
        }

        static func == (a: Subject, b: Subject) -> Bool {
            a.kind == b.kind && a.clipped == b.clipped && a.origin == b.origin && a.time == b.time && a.layers == b.layers
                && (a.ground === b.ground || a.ground.board == b.ground.board)
        }

        /// Whether this is drawn as another is, for subjects of one artboard whose grounds were
        /// made one after the other (`Ground.of(_:before:)`): then another ground is another
        /// artboard, and is not read through for each piece to find that out.
        func isDrawn(as other: Subject) -> Bool {
            guard kind == other.kind, clipped == other.clipped, origin == other.origin, time == other.time, layers == other.layers else { return false }
            // The ground's own is the bare artboard, which is soon read.
            return ground === other.ground || (kind == .ground && ground.board == other.ground.board)
        }
    }

    /// The longest side a picture is made with, in pixels.
    static let most: CGFloat = 6000

    /// What a piece draws at a moment. On the main actor, which poses what moves inside it.
    @MainActor
    static func subject(of piece: FilmPiece, on board: Node, at t: Double) -> Subject {
        subject(of: piece, on: board, ground: Ground.of(board), at: t)
    }

    /// What a piece draws at a moment, on a ground already made of its artboard: for the pieces
    /// of one artboard asked one after the other.
    @MainActor
    static func subject(of piece: FilmPiece, on board: Node, ground: Ground, at t: Double) -> Subject {
        guard piece.kind != .ground else {
            var bare = ground.board
            bare.children = []
            return Subject(kind: .ground, layers: [], origin: .zero, ground: Ground(bare), clipped: true)
        }
        let from = piece.holders.last.flatMap { board.descendant($0) }?.children ?? board.children
        let layers = from.filter { piece.layers.contains($0.id) }.map { layer -> Node in
            var n = piece.changes ? layer.posed(at: t, own: false) : layer
            if piece.flat { n.transform3D = nil }
            return n.withoutMotion
        }
        var subject = Subject(kind: piece.kind, layers: layers, origin: piece.origin, ground: ground, clipped: false)
        // Judged by the layers with their keys, which the drawing has no more.
        if from.contains(where: { piece.layers.contains($0.id) && $0.holdsMovingShader }) { subject.time = t }
        return subject
    }

    /// Where a subject draws, in the artboard's points, however far past its edges that reaches.
    static func rect(of subject: Subject) -> CGRect {
        let whole = CGRect(origin: .zero, size: subject.board.frame.size)
        guard subject.kind != .ground else { return whole }
        var r = CGRect.null
        let eye = Eye.stage(subject.board.frame.size).inside(subject.origin)
        for n in subject.layers { r = r.union(Renderer.reach(of: n, eye: eye)) }
        guard !r.isNull else { return .zero }
        r = r.offsetBy(dx: subject.origin.x, dy: subject.origin.y).insetBy(dx: -1, dy: -1).integral
        return subject.clipped ? r.intersection(whole) : r
    }

    /// The part of that which a subject's whole picture is made of. All of it, but for layers
    /// that stand as they were designed (a run): there, what lies far outside the artboard is
    /// left to be drawn when the camera finds it (`Part`), or one thing parked a long way off
    /// would take the sharpness from everything else in its picture.
    static func core(of subject: Subject) -> CGRect {
        let r = rect(of: subject)
        guard subject.kind == .run else { return r }
        let whole = CGRect(origin: .zero, size: subject.board.frame.size)
        let far = min(max(whole.width, whole.height) / 4, 400)
        let near = r.intersection(whole.insetBy(dx: -far, dy: -far))
        // Nothing of it near the artboard: its picture is of where it is.
        return near.isNull || near.width <= 0 || near.height <= 0 ? r : near
    }

    // MARK: Only what is seen, as sharp as it is seen

    /// A part of a piece to draw sharper than its whole picture is: where, in the artboard's
    /// points, and with how many pixels to the point.
    struct Part: Equatable, Sendable {
        var rect: CGRect
        var scale: CGFloat
    }

    /// The longest side a part is drawn with, and the most pixels in all: a part is what shows
    /// through the film's frame, so these are a large screen's own, with room to spare.
    static let mostInPart: (side: CGFloat, pixels: CGFloat) = (8192, 24_000_000)

    /// How many pixels to the point a whole picture really has, whatever was asked for: `most`
    /// holds a large piece back.
    static func sharpness(of picture: Picture) -> CGFloat {
        min(CGFloat(picture.image.width) / max(picture.rect.width, 1e-6), CGFloat(picture.image.height) / max(picture.rect.height, 1e-6))
    }

    /// The part to draw of a piece that covers `whole`, for what shows of it in `seen` at `need`
    /// pixels to the point: grown by `margin` of its size and `around` points each way, so a
    /// little movement stays within it, kept to the piece, sharp in steps a fifth apart so that
    /// zooming draws it again only now and then, and lying on its own whole pixels. Nil when
    /// there is nothing of it to draw.
    static func part(for seen: CGRect, of whole: CGRect, need: CGFloat, margin: CGFloat = 0, around: CGFloat = 0) -> Part? {
        guard need > 0, need.isFinite else { return nil }
        var r = seen.insetBy(dx: -(seen.width * margin + around), dy: -(seen.height * margin + around)).intersection(whole)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        var scale = pow(2, (log2(need) * 4 - 0.01).rounded(.up) / 4)
        scale = min(scale, mostInPart.side / max(r.width, r.height), (mostInPart.pixels / (r.width * r.height)).squareRoot())
        guard scale > 0, scale.isFinite else { return nil }
        let x0 = (r.minX * scale).rounded(.down) / scale, y0 = (r.minY * scale).rounded(.down) / scale
        let x1 = (r.maxX * scale).rounded(.up) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
        r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return Part(rect: r, scale: scale)
    }

    /// Draws a subject, `scale` pixels to the artboard's point, or as many as its size allows.
    /// With a `part`, only what of it lies there, as sharp as the part says: for a piece seen so
    /// large that all of it drawn as sharp would be more than any screen shows.
    ///
    /// `space` is the screen's, for a picture the stage shows: the colours are matched to it as
    /// it is drawn, away from the main thread, where Core Animation would otherwise match them
    /// itself, on the main thread, as the picture comes on the stage.
    static func picture(of subject: Subject, scale: CGFloat, assets: Assets?, part: Part? = nil, space: CGColorSpace? = nil) -> Picture? {
        let whole = rect(of: subject)
        guard whole.width > 0, whole.height > 0, !whole.isNull else { return nil }
        var r = core(of: subject), scale = scale
        var size: CGSize
        if let part {
            guard part.rect.intersects(whole), part.rect.width > 0, part.rect.height > 0 else { return nil }
            r = part.rect
            scale = part.scale
            size = CGSize(width: max(1, (r.width * scale).rounded()), height: max(1, (r.height * scale).rounded()))
        } else {
            scale = min(scale, most / max(r.width, r.height))
            size = CGSize(width: max(1, (r.width * scale).rounded(.up)), height: max(1, (r.height * scale).rounded(.up)))
        }
        guard let ctx = Renderer.bitmap(size, space: space) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / r.width, y: -size.height / r.height)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        // A part reaches a pixel's breadth past the piece, where the piece itself is cut off.
        if part != nil { ctx.clip(to: whole) }
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = assets
            o.time = subject.time
            if subject.kind == .ground {
                Renderer.drawArtboard(subject.board, in: ctx, options: o)
                return
            }
            o.board = subject.board
            o.offset = subject.origin
            ctx.translateBy(x: subject.origin.x, y: subject.origin.y)
            for n in DepthOrder.stacked(subject.layers) { Renderer.drawNode(n, in: ctx, options: o) }
        }
        return ctx.makeImage().map { Picture(image: $0, rect: r) }
    }
}

nonisolated extension Node {
    /// The layer with no keys, nor any in what it holds: what its drawing is made from.
    var withoutMotion: Node {
        guard motion != nil || film != nil || holdsMotion else { return self }
        var n = self
        n.motion = nil
        n.film = nil
        n.children = children.map(\.withoutMotion)
        return n
    }
}
