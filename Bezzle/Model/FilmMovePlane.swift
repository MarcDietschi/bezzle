import Foundation
import CoreGraphics

// Where a layer goes when it is dragged in Animate, shared by every Bezzle. A Move slides a layer
// along a plane: the artboard's sheet as high as the layer stands, or the plane of the group it
// lies in, which may be turned in depth, keeping its layers' depth or drawn as one card, as far
// off that plane as the layer stands. The pointer is cast onto that plane, through the camera
// and the eye the film is seen with, so the layer stays under it however the plane is turned.

nonisolated extension FilmMap {
    /// The map that takes the corners of the unit square, (0, 0), (1, 0), (1, 1) and (0, 1), to
    /// four points in that order: Heckbert's square to quadrilateral. Nil where three of them lie
    /// on a line, as a plane seen edge on shows.
    static func square(to q: [CGPoint]) -> FilmMap? {
        guard q.count == 4 else { return nil }
        let x = q.map { Double($0.x) }, y = q.map { Double($0.y) }
        // No three in a line, however large or small the four are.
        let size = max(x.max()! - x.min()!, y.max()! - y.min()!)
        for i in 0..<4 {
            let (j, k) = ((i + 1) % 4, (i + 2) % 4)
            let area = (x[j] - x[i]) * (y[k] - y[i]) - (y[j] - y[i]) * (x[k] - x[i])
            guard abs(area) > 1e-9 * size * size, area.isFinite else { return nil }
        }
        let dx1 = x[1] - x[2], dx2 = x[3] - x[2], dx3 = x[0] - x[1] + x[2] - x[3]
        let dy1 = y[1] - y[2], dy2 = y[3] - y[2], dy3 = y[0] - y[1] + y[2] - y[3]
        var g = 0.0, h = 0.0
        if abs(dx3) > 1e-12 || abs(dy3) > 1e-12 {
            let det = dx1 * dy2 - dx2 * dy1
            guard abs(det) > 1e-12 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        let map = FilmMap(a: x[1] - x[0] + g * x[1], b: x[3] - x[0] + h * x[3], c: x[0],
                          d: y[1] - y[0] + g * y[1], e: y[3] - y[0] + h * y[3], f: y[0],
                          g: g, h: h, i: 1)
        return map.inverse == nil ? nil : map
    }

    /// How far along its plane a point goes that shows first at `a` and then at `b`, in the
    /// plane's own points; nil where either lies past its horizon.
    func travel(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        guard let p = back(a), let q = back(b) else { return nil }
        return CGPoint(x: q.x - p.x, y: q.y - p.y)
    }
}

extension Node {
    /// Artboards: where a layer's middle shows in the film's frame at a moment for each Move it
    /// could have there, from the Move's two numbers to the frame's points. A Move slides the
    /// layer along a plane, which the film shows in perspective, so this is a map of a plane and
    /// four Moves settle it; each is posed and shown as the film shows it, through the piece the
    /// layer is drawn in, every group about it and the camera. A drag from `a` to `b` in the
    /// frame is then a Move `travel(from: a, to: b)` further, and the point of the layer that
    /// was under the pointer is under it again: exactly for a layer lying flat in what holds it,
    /// its middle for any. `pieces` are the film's, as Animate keeps them with what is picked
    /// apart. Nil for a layer not on it, or one whose plane shows edge on.
    ///
    /// Worked out once when a drag begins: each Move tried looks for the layer through the artboard.
    func filmMovePlane(of id: UUID, at t: Double, pieces: [FilmPiece]) -> FilmMap? {
        guard let layer = descendant(id), let way = way(to: id) else { return nil }
        let ids = Set(way.map(\.id))
        guard let holder = pieces.last(where: { p in p.layers.contains { ids.contains($0) } }) else { return nil }
        // Moved, it is drawn as it moves: in a piece of its own, or in the one of what holds it,
        // drawn again as it moves. Lying in a run that stands still, it is kept apart first.
        let drawn: [FilmPiece]
        if holder.kind == .run, holder.layers.contains(id) {
            drawn = filmPieces(loose: [id])
        } else {
            drawn = pieces.map { piece in
                var piece = piece
                if piece == holder { piece.changes = true }
                return piece
            }
        }
        let now = layer.value(of: .move, at: t)
        let start = CGPoint(x: now[0], y: now[1])
        // Where its middle shows with this Move at the moment, and nothing else changed: where
        // its frame's diagonals cross as the film shows its corners (`filmCorners`), which is
        // where the middle of anything flat shows in perspective.
        func shown(_ move: CGPoint) -> CGPoint? {
            let board = self.changing(id) { $0[track: .move] = MotionTrack([MotionKey(t: t, v: [Double(move.x), Double(move.y)])]) }
            guard let q = board.filmCorners(of: id, at: t, pieces: drawn), q.count == 4 else { return nil }
            return Geometry.crossing(q)
        }
        // A hundred points each way, and a fifth Move between them to bear the four out; nearer
        // where that reaches behind the eye, where the film presses what it shows against it.
        for reach in [100.0, 10.0, 1.0] {
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: reach, y: 0), CGPoint(x: reach, y: reach), CGPoint(x: 0, y: reach)]
            let seen = corners.compactMap { shown(CGPoint(x: start.x + $0.x, y: start.y + $0.y)) }
            guard seen.count == 4, let square = FilmMap.square(to: seen),
                  let between = shown(CGPoint(x: start.x + reach / 2, y: start.y + reach / 2)) else { continue }
            let fitted = square(CGPoint(x: 0.5, y: 0.5))
            let spread = hypot(seen[2].x - seen[0].x, seen[2].y - seen[0].y) + hypot(seen[3].x - seen[1].x, seen[3].y - seen[1].y)
            guard hypot(fitted.x - between.x, fitted.y - between.y) <= 1e-4 * spread + 1e-6 else { continue }
            // From a Move to the unit square those four make.
            return square.after(FilmMap(a: 1 / reach, c: -Double(start.x) / reach, e: 1 / reach, f: -Double(start.y) / reach))
        }
        return nil
    }

    /// This layer with one somewhere in it changed, the rest as it is: found first, then only
    /// what holds it is copied on the way down.
    fileprivate func changing(_ id: UUID, _ change: (inout Node) -> Void) -> Node {
        func find(_ nodes: [Node]) -> [Int]? {
            for (i, n) in nodes.enumerated() {
                if n.id == id { return [i] }
                if let rest = find(n.children) { return [i] + rest }
            }
            return nil
        }
        guard let path = find(children) else { return self }
        func modify(_ nodes: inout [Node], _ path: ArraySlice<Int>) {
            guard let i = path.first else { return }
            if path.count == 1 { change(&nodes[i]) } else { modify(&nodes[i].children, path.dropFirst()) }
        }
        var n = self
        modify(&n.children, path[...])
        return n
    }
}

nonisolated extension Geometry {
    /// Where the diagonals of four corners cross; for a line, which has none apart, its middle.
    static func crossing(_ q: [CGPoint]) -> CGPoint {
        let r = CGPoint(x: q[2].x - q[0].x, y: q[2].y - q[0].y), s = CGPoint(x: q[3].x - q[1].x, y: q[3].y - q[1].y)
        let across = r.x * s.y - r.y * s.x
        let size = max(abs(r.x) + abs(r.y), abs(s.x) + abs(s.y))
        guard abs(across) > 1e-9 * max(size * size, 1e-12) else {
            return CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
        }
        let u = ((q[1].x - q[0].x) * s.y - (q[1].y - q[0].y) * s.x) / across
        return CGPoint(x: q[0].x + r.x * u, y: q[0].y + r.y * u)
    }
}
