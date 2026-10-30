import CoreGraphics

/// What the path tools do to areas, all measured on the canvas: cutting a shape along a line,
/// the pieces overlapping shapes cut each other into, an outline grown or shrunk, and a border
/// as a shape of its own. Core Graphics works out where outlines cross; this tidies what it gives.
nonisolated enum Outlines {
    /// Pieces smaller than this, in square points, are what is left where two outlines ran along
    /// each other, not anything anyone made.
    static let sliver: CGFloat = 0.05

    /// The area an outline closes in, near enough: its curves are measured as short lines.
    static func area(_ path: CGPath) -> CGFloat {
        var twice: CGFloat = 0, current = CGPoint.zero, start = CGPoint.zero
        func to(_ q: CGPoint) {
            twice += current.x * q.y - q.x * current.y
            current = q
        }
        path.applyWithBlock { element in
            let e = element.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                current = pts[0]
                start = pts[0]
            case .addLineToPoint:
                to(pts[0])
            case .addQuadCurveToPoint:
                let p0 = current, c = pts[0], p = pts[1]
                for k in 1...8 {
                    let t = CGFloat(k) / 8, u = 1 - t
                    to(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p.y))
                }
            case .addCurveToPoint:
                let p0 = current
                for k in 1...12 {
                    to(BezierPath.point(on: (p0, pts[0], pts[1], pts[2]), at: CGFloat(k) / 12))
                }
            case .closeSubpath:
                to(start)
            @unknown default:
                break
            }
        }
        return abs(twice / 2)
    }

    /// Its parts that do not touch, without the slivers.
    static func parts(_ path: CGPath) -> [CGPath] {
        path.componentsSeparated().filter { area($0) > sliver }
    }

    /// The outline without the slivers left where outlines ran along each other.
    static func cleaned(_ path: CGPath) -> CGPath {
        let kept = parts(path)
        if kept.count == 1 { return kept[0] }
        let whole = CGMutablePath()
        for p in kept { whole.addPath(p) }
        return whole
    }

    static func union(_ paths: [CGPath]) -> CGPath? {
        guard let first = paths.first else { return nil }
        return cleaned(paths.dropFirst().reduce(first) { $0.union($1) })
    }

    // MARK: Cutting

    /// The pieces a cut along `line` leaves of `shape`, or nil when the cut does not part it.
    /// Where the cut stops short inside a piece, the slit it leaves is closed again.
    static func cut(_ shape: CGPath, along line: CGPath) -> [CGPath]? {
        // So thin no zoom shows where the pieces part.
        let blade = line.copy(strokingWithWidth: 0.001, lineCap: .butt, lineJoin: .round, miterLimit: 4)
        var pieces = parts(shape.subtracting(blade))
        guard pieces.count > 1 else { return nil }
        let slits = shape.intersection(blade).componentsSeparated()
        guard !slits.isEmpty else { return pieces }
        // Each part of the blade inside the shape: where it has the same piece on both sides, it
        // went into that piece and stopped.
        let marks = samples(of: line, every: 0.5)
        var closing: [Int: [CGPath]] = [:]
        for slit in slits {
            guard let (p, way) = marks.first(where: { slit.contains($0.0) }) else { continue }
            let across = CGPoint(x: -way.y, y: way.x)
            let left = pieces.firstIndex { $0.contains(p + across * 0.02) }
            let right = pieces.firstIndex { $0.contains(p - across * 0.02) }
            if let left, left == right { closing[left, default: []].append(slit) }
        }
        for (i, slits) in closing {
            pieces[i] = cleaned(slits.reduce(pieces[i]) { $0.union($1) })
        }
        return pieces
    }

    /// Points along a path about `step` apart, each with the way the path runs there.
    static func samples(of path: CGPath, every step: CGFloat) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        var current = CGPoint.zero, start = CGPoint.zero
        func run(_ c: (CGPoint, CGPoint, CGPoint, CGPoint)) {
            let l = BezierPath.length(of: [c.0, c.1, c.2, c.3])
            let n = max(1, Int((l / step).rounded(.up)))
            var last = c.0
            for k in 1...n {
                let p = BezierPath.point(on: c, at: CGFloat(k) / CGFloat(n))
                let way = BezierPath.unit(p - last)
                if way != .zero { out.append((CGPoint(x: (p.x + last.x) / 2, y: (p.y + last.y) / 2), way)) }
                last = p
            }
        }
        path.applyWithBlock { element in
            let e = element.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                current = pts[0]
                start = pts[0]
            case .addLineToPoint:
                run((current, current, pts[0], pts[0]))
                current = pts[0]
            case .addQuadCurveToPoint:
                let k: CGFloat = 2.0 / 3.0
                run((current, current + (pts[0] - current) * k, pts[1] + (pts[0] - pts[1]) * k, pts[1]))
                current = pts[1]
            case .addCurveToPoint:
                run((current, pts[0], pts[1], pts[2]))
                current = pts[2]
            case .closeSubpath:
                run((current, current, start, start))
                current = start
            @unknown default:
                break
            }
        }
        return out
    }

    // MARK: Pieces

    /// Part of the canvas covered by the same overlapping shapes, apart from the others.
    struct Piece {
        var outline: CGPath
        /// Which of the shapes cover it, by their place in the list, back first.
        var covers: [Int]
    }

    /// The pieces overlapping shapes cut each other into, each in one part.
    static func pieces(of shapes: [CGPath]) -> [Piece] {
        var pieces: [Piece] = []
        for (i, shape) in shapes.enumerated() {
            var next: [Piece] = [], rest = shape
            for piece in pieces {
                let inside = piece.outline.intersection(shape)
                if !inside.isEmpty { next.append(Piece(outline: inside, covers: piece.covers + [i])) }
                let outside = piece.outline.subtracting(shape)
                if !outside.isEmpty { next.append(Piece(outline: outside, covers: piece.covers)) }
                rest = rest.subtracting(piece.outline)
            }
            if !rest.isEmpty { next.append(Piece(outline: rest, covers: [i])) }
            pieces = next
        }
        return pieces.flatMap { piece in parts(piece.outline).map { Piece(outline: $0, covers: piece.covers) } }
    }

    // MARK: Growing and shrinking

    /// The outline moved out by `distance` all round, or in when it is less than 0. Corners stay
    /// sharp unless `round`; nil when shrinking leaves nothing.
    static func offset(_ shape: CGPath, by distance: CGFloat, round: Bool) -> CGPath? {
        guard abs(distance) > 0.001 else { return shape }
        let band = shape.copy(strokingWithWidth: abs(distance) * 2, lineCap: .round, lineJoin: round ? .round : .miter, miterLimit: 4)
        let grown = cleaned(distance > 0 ? shape.union(band) : shape.subtracting(band))
        return grown.isEmpty ? nil : grown
    }

    // MARK: Borders

    /// What a border covers, as an area: `line` is the outline it is drawn along, `inside` the
    /// area that outline closes in, for a border inside or outside it.
    static func covered(by border: Border, along line: CGPath, inside: CGPath, closed: Bool) -> CGPath? {
        guard border.on, border.width > 0 else { return nil }
        var line = line
        if border.dash > 0 { line = line.copy(dashingWithPhase: 0, lengths: [border.dash, max(border.gap, 0.5)]) }
        // As the canvas draws it: a border inside or outside is twice as wide, and half of it hidden.
        let sided = closed && border.position != .center
        let band = line.copy(strokingWithWidth: border.width * (sided ? 2 : 1),
                             lineCap: closed || border.dash > 0 ? .butt : .round, lineJoin: .miter, miterLimit: 10)
        let area: CGPath
        if sided {
            area = border.position == .inside ? band.intersection(inside) : band.subtracting(inside)
        } else {
            area = band.normalized()
        }
        let shape = cleaned(area)
        return shape.isEmpty ? nil : shape
    }
}

nonisolated extension Gradient {
    /// The same colours lying where they did on the canvas, after the layer's frame, `size`
    /// before, became `box`, measured from its old top left. Gradients are placed in the frame,
    /// so they would otherwise stretch with it.
    func moved(from size: CGSize, to box: CGRect) -> Gradient {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return self }
        func move(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x * size.width - box.minX) / box.width, y: (p.y * size.height - box.minY) / box.height)
        }
        var g = self
        if kind == .radial {
            let (a, b) = radii
            g.end = move(a)
            g.across = move(b)
        } else {
            g.end = move(end)
        }
        g.start = move(start)
        return g
    }
}
