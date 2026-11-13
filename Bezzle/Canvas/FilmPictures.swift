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
        /// Whether what reaches past the artboard's edges is cut off there, as the design shows it.
        var clipped: Bool
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
            a.kind == b.kind && a.clipped == b.clipped && a.origin == b.origin && a.layers == b.layers
                && (a.ground === b.ground || a.ground.board == b.ground.board)
        }

        /// Whether this is drawn as another is, for subjects of one artboard whose grounds were
        /// made one after the other (`Ground.of(_:before:)`): then another ground is another
        /// artboard, and is not read through for each piece to find that out.
        func isDrawn(as other: Subject) -> Bool {
            guard kind == other.kind, clipped == other.clipped, origin == other.origin, layers == other.layers else { return false }
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
        return Subject(kind: piece.kind, layers: layers, origin: piece.origin, ground: ground, clipped: piece.kind == .run)
    }

    /// The part of the artboard a subject's picture covers.
    static func rect(of subject: Subject) -> CGRect {
        let whole = CGRect(origin: .zero, size: subject.board.frame.size)
        guard subject.kind != .ground else { return whole }
        var r = CGRect.null
        for n in subject.layers { r = r.union(Renderer.reach(of: n)) }
        guard !r.isNull else { return .zero }
        r = r.offsetBy(dx: subject.origin.x, dy: subject.origin.y).insetBy(dx: -1, dy: -1).integral
        return subject.clipped ? r.intersection(whole) : r
    }

    /// Draws a subject, `scale` pixels to the artboard's point, or as many as its size allows.
    static func picture(of subject: Subject, scale: CGFloat, assets: Assets?) -> Picture? {
        let r = rect(of: subject)
        guard r.width > 0, r.height > 0, !r.isNull else { return nil }
        let scale = min(scale, most / max(r.width, r.height))
        let size = CGSize(width: max(1, (r.width * scale).rounded(.up)), height: max(1, (r.height * scale).rounded(.up)))
        guard let ctx = Renderer.bitmap(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / r.width, y: -size.height / r.height)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        Renderer.withFlippedContext(ctx) {
            var o = Renderer.Options()
            o.deviceScale = scale
            o.assets = assets
            if subject.kind == .ground {
                Renderer.drawArtboard(subject.board, in: ctx, options: o)
                return
            }
            o.board = subject.board
            o.offset = subject.origin
            ctx.translateBy(x: subject.origin.x, y: subject.origin.y)
            for n in subject.layers { Renderer.drawNode(n, in: ctx, options: o) }
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
