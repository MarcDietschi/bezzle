import CoreGraphics
import Foundation

/// Smart guides: the edges and centres a moving layer catches on, those of its neighbours on the
/// same artboard and of the artboard itself; and the gaps between its neighbours, which it
/// catches on by leaving the same gap beside it, in its own row or, turning a corner, down from
/// one of a row as wide as the gaps across it.
struct SnapTargets {
    struct Line {
        var value: CGFloat
        /// The rectangle this edge or centre belongs to, so the guide can reach it.
        var box: CGRect
    }

    var xs: [Line] = []
    var ys: [Line] = []
    /// What lies beside the moving layers, which they keep even gaps to: the layers they lie
    /// with, not what holds them.
    private var neighbours: [CGRect] = []
    /// Neighbours side by side across, and above each other down, with the gap between them.
    private var gapsAcross: [Gap] = []
    private var gapsDown: [Gap] = []

    /// Two neighbours with nothing between them, `before` left of or above `after`.
    private struct Gap: Equatable {
        var before: CGRect
        var after: CGRect
        var size: CGFloat
    }

    /// Targets for layers `moving`, all on canvas points.
    init(doc: BezzleDocument, moving ids: Set<UUID>) {
        let first = ids.first
        let parent = first.flatMap { doc.parent(of: $0) }
        var boxes: [CGRect] = []
        // The artboard the layers lie on, or are crossing onto.
        var onto: Node?
        if let parent, let box = doc.absoluteFrame(of: parent.id) {
            boxes.append(box)
            for child in parent.children where !ids.contains(child.id) && !child.hidden {
                neighbours.append(Geometry.bounds(of: child).offsetBy(dx: box.minX, dy: box.minY))
            }
            onto = first.flatMap { doc.artboard(of: $0) }
            // Inside a group, the artboard around it counts too.
            if parent.isGroup, let onto { boxes.append(onto.frame) }
        } else {
            // Something loose that crosses onto an artboard catches on what is on it too. An
            // artboard is under its own middle, and what is on it moves with it.
            if let id = first, doc.node(id)?.isArtboard == false, let frame = doc.absoluteFrame(of: id), let board = doc.artboard(at: frame.center) {
                for child in board.children where !ids.contains(child.id) && !child.hidden {
                    neighbours.append(Geometry.bounds(of: child).offsetBy(dx: board.frame.minX, dy: board.frame.minY))
                }
                onto = board
            }
            for node in doc.nodes where !ids.contains(node.id) && !node.hidden {
                let box = node.isArtboard ? node.frame : Geometry.bounds(of: node)
                if node.id == onto?.id { boxes.append(box) } else { neighbours.append(box) }
            }
        }
        boxes += neighbours
        // On a carousel, each slide's edges and middle catch as the artboard's do.
        if let onto, onto.isCarousel, !ids.contains(onto.id) {
            boxes += onto.slideRects.map { $0.offsetBy(dx: onto.frame.minX, dy: onto.frame.minY) }
        }
        for b in boxes {
            xs += [Line(value: b.minX, box: b), Line(value: b.midX, box: b), Line(value: b.maxX, box: b)]
            ys += [Line(value: b.minY, box: b), Line(value: b.midY, box: b), Line(value: b.maxY, box: b)]
        }
        // A design with thousands of layers side by side would take too long to measure.
        if neighbours.count <= 400 {
            gapsAcross = Self.gaps(neighbours, across: true)
            gapsDown = Self.gaps(neighbours, across: false)
        }
    }

    init() {}

    /// How far to shift a rectangle so that one of its edges or its centre lies on a target,
    /// within `threshold`, along one axis. `edges` are the rectangle's own values to try.
    static func best(_ edges: [CGFloat], _ lines: [Line], threshold: CGFloat) -> (shift: CGFloat, value: CGFloat)? {
        var best: (CGFloat, CGFloat)?
        for e in edges {
            for l in lines {
                let d = l.value - e
                if abs(d) <= threshold, best == nil || abs(d) < abs(best!.0) { best = (d, l.value) }
            }
        }
        return best
    }

    /// The guides for a rectangle that lies on targets: one line per matched value, from the
    /// rectangle to the furthest thing that shares it.
    func guides(for rect: CGRect, x: CGFloat?, y: CGFloat?) -> [Guide] {
        var out: [Guide] = []
        if let x {
            let boxes = xs.filter { abs($0.value - x) < 0.5 }.map(\.box)
            let top = boxes.map(\.minY).min().map { min($0, rect.minY) } ?? rect.minY
            let bottom = boxes.map(\.maxY).max().map { max($0, rect.maxY) } ?? rect.maxY
            out.append(Guide(from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom)))
        }
        if let y {
            let boxes = ys.filter { abs($0.value - y) < 0.5 }.map(\.box)
            let left = boxes.map(\.minX).min().map { min($0, rect.minX) } ?? rect.minX
            let right = boxes.map(\.maxX).max().map { max($0, rect.maxX) } ?? rect.maxX
            out.append(Guide(from: CGPoint(x: left, y: y), to: CGPoint(x: right, y: y)))
        }
        return out
    }

    /// A moving rectangle caught by the nearest targets, an edge or an even gap on each axis: the
    /// shift to apply, and the guides to draw for the edges. `gapGuides` marks the gaps.
    func snap(moving rect: CGRect, threshold: CGFloat) -> (CGPoint, [Guide]) {
        let bx = Self.best([rect.minX, rect.midX, rect.maxX], xs, threshold: threshold)
        let by = Self.best([rect.minY, rect.midY, rect.maxY], ys, threshold: threshold)
        // An even gap catches only when it is nearer than any edge.
        func nearer(_ edge: CGFloat?, _ gap: CGFloat?) -> CGFloat {
            guard let gap else { return edge ?? 0 }
            guard let edge else { return gap }
            return abs(gap) < abs(edge) ? gap : edge
        }
        let shift = CGPoint(x: nearer(bx?.shift, evenShift(rect, across: true, threshold: threshold)),
                            y: nearer(by?.shift, evenShift(rect, across: false, threshold: threshold)))
        let moved = rect.offsetBy(dx: shift.x, dy: shift.y)
        // The edges it comes to lie on, however it got there.
        let x = bx.flatMap { abs($0.shift - shift.x) < 0.5 ? $0.value : nil }
        let y = by.flatMap { abs($0.shift - shift.y) < 0.5 ? $0.value : nil }
        return (shift, guides(for: moved, x: x, y: y))
    }

    // MARK: Even gaps

    /// A box's span along the axis gaps are measured on, across or down, and its span the other way.
    private static func along(_ r: CGRect, _ across: Bool) -> (lo: CGFloat, hi: CGFloat) {
        across ? (r.minX, r.maxX) : (r.minY, r.maxY)
    }

    private static func aside(_ r: CGRect, _ across: Bool) -> (lo: CGFloat, hi: CGFloat) {
        across ? (r.minY, r.maxY) : (r.minX, r.maxX)
    }

    /// Whether two boxes lie in one row (or one column, down): they overlap the other way.
    private static func inLine(_ a: CGRect, _ b: CGRect, _ across: Bool) -> Bool {
        let s = aside(a, across), t = aside(b, across)
        return s.hi > t.lo && t.hi > s.lo
    }

    /// Each neighbour, with the nearest one after it in its row.
    private static func gaps(_ boxes: [CGRect], across: Bool) -> [Gap] {
        let sorted = boxes.sorted { along($0, across).lo < along($1, across).lo }
        var out: [Gap] = []
        for (i, a) in sorted.enumerated() {
            let end = along(a, across).hi
            if let b = sorted[(i + 1)...].first(where: { along($0, across).lo >= end && inLine(a, $0, across) }) {
                out.append(Gap(before: a, after: b, size: along(b, across).lo - end))
            }
        }
        return out
    }

    /// The nearest neighbours in a rectangle's row, before it and after it.
    private func sides(of r: CGRect, across: Bool) -> (before: CGRect?, after: CGRect?) {
        let mid = across ? r.midX : r.midY
        let row = neighbours.filter { Self.inLine($0, r, across) }
        let before = row.filter { Self.along($0, across).hi <= mid }.max { Self.along($0, across).hi < Self.along($1, across).hi }
        let after = row.filter { Self.along($0, across).lo >= mid }.min { Self.along($0, across).lo < Self.along($1, across).lo }
        return (before, after)
    }

    /// The gaps between neighbours in a rectangle's row, other than the one it lies in.
    private func rowGaps(_ r: CGRect, across: Bool) -> [Gap] {
        let mid = across ? r.midX : r.midY
        return (across ? gapsAcross : gapsDown).filter { g in
            g.size >= 1 && Self.inLine(g.before, r, across) && Self.inLine(g.after, r, across)
                && !(Self.along(g.before, across).hi <= mid && Self.along(g.after, across).lo >= mid)
        }
    }

    /// The gaps the other way in a neighbour's own row: for three in an L, the gap down from one
    /// to what moves is as wide as the gap across from it to the other.
    private func cornerGaps(of n: CGRect?, across: Bool) -> [Gap] {
        guard let n else { return [] }
        return (across ? gapsDown : gapsAcross).filter { g in
            g.size >= 1 && Self.inLine(g.before, n, !across) && Self.inLine(g.after, n, !across)
        }
    }

    /// How far to shift a rectangle along one axis for the gap beside it to be even with another:
    /// with the one on its other side, so it is halfway between its neighbours, with a gap
    /// between two neighbours in its row, or with one the other way in a neighbour's row.
    private func evenShift(_ r: CGRect, across: Bool, threshold: CGFloat) -> CGFloat? {
        let (before, after) = sides(of: r, across: across)
        let span = Self.along(r, across), size = span.hi - span.lo
        var starts: [CGFloat] = []
        if let b = before, let a = after {
            let room = Self.along(a, across).lo - Self.along(b, across).hi - size
            if room >= 2 { starts.append(Self.along(b, across).hi + room / 2) }
        }
        let corners = cornerGaps(of: before, across: across) + cornerGaps(of: after, across: across)
        for g in rowGaps(r, across: across) + corners {
            if let b = before { starts.append(Self.along(b, across).hi + g.size) }
            if let a = after { starts.append(Self.along(a, across).lo - g.size - size) }
        }
        return starts.map { $0 - span.lo }.filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
    }

    /// Marks across the gaps beside a rectangle that are as wide as the gap on its other side,
    /// one between its neighbours, or one the other way in a neighbour's row, and across those as
    /// well: within a point, as positions are whole points and a gap can't always be halved.
    func gapGuides(for r: CGRect) -> [Guide] {
        var out: [Guide] = []
        for across in [true, false] {
            let (before, after) = sides(of: r, across: across)
            let span = Self.along(r, across)
            var mine: [Gap] = []
            if let b = before { mine.append(Gap(before: b, after: r, size: span.lo - Self.along(b, across).hi)) }
            if let a = after { mine.append(Gap(before: r, after: a, size: Self.along(a, across).lo - span.hi)) }
            mine = mine.filter { $0.size >= 1 }
            // Each gap with the way it is measured: across, or down.
            let others = rowGaps(r, across: across).map { ($0, across) }
                + (cornerGaps(of: before, across: across) + cornerGaps(of: after, across: across)).map { ($0, !across) }
            var marked: [(gap: Gap, across: Bool)] = []
            for (i, g) in mine.enumerated() {
                let even = (mine.enumerated().filter { $0.offset != i }.map { ($0.element, across) } + others)
                    .filter { abs($0.0.size - g.size) <= 1 }
                guard !even.isEmpty else { continue }
                for e in [(g, across)] + even where !marked.contains(where: { $0.gap == e.0 && $0.across == e.1 }) { marked.append(e) }
            }
            for m in marked {
                let guide = Self.mark(m.gap, across: m.across, mine: m.across == across && mine.contains(m.gap))
                if !out.contains(guide) { out.append(guide) }
            }
        }
        return out
    }

    /// A gap's mark: the space where its two sides face each other, and a line across its middle.
    private static func mark(_ g: Gap, across: Bool, mine: Bool) -> Guide {
        let s = aside(g.before, across), t = aside(g.after, across)
        let lo = max(s.lo, t.lo), hi = min(s.hi, t.hi), middle = (lo + hi) / 2
        let from = along(g.before, across).hi, to = along(g.after, across).lo
        return across
            ? Guide(from: CGPoint(x: from, y: middle), to: CGPoint(x: to, y: middle),
                    field: CGRect(x: from, y: lo, width: to - from, height: hi - lo), mine: mine)
            : Guide(from: CGPoint(x: middle, y: from), to: CGPoint(x: middle, y: to),
                    field: CGRect(x: lo, y: from, width: hi - lo, height: to - from), mine: mine)
    }

    /// A rectangle being resized by `handle`: only the edges that move are caught.
    func snap(resizing rect: CGRect, handle: Handle, threshold: CGFloat) -> (CGRect, [Guide]) {
        var r = rect
        var gx: CGFloat?, gy: CGFloat?
        let u = handle.unit
        if u.x != 0.5, let b = Self.best([u.x == 1 ? r.maxX : r.minX], xs, threshold: threshold) {
            if u.x == 1 { r.size.width += b.shift } else { r.origin.x += b.shift; r.size.width -= b.shift }
            gx = b.value
        }
        if u.y != 0.5, let b = Self.best([u.y == 1 ? r.maxY : r.minY], ys, threshold: threshold) {
            if u.y == 1 { r.size.height += b.shift } else { r.origin.y += b.shift; r.size.height -= b.shift }
            gy = b.value
        }
        return (r.standardized, guides(for: r.standardized, x: gx, y: gy))
    }

    /// A point (the corner of something being drawn) caught by the nearest targets.
    func snap(point p: CGPoint, threshold: CGFloat) -> (CGPoint, CGFloat?, CGFloat?) {
        let bx = Self.best([p.x], xs, threshold: threshold)
        let by = Self.best([p.y], ys, threshold: threshold)
        return (CGPoint(x: p.x + (bx?.shift ?? 0), y: p.y + (by?.shift ?? 0)), bx?.value, by?.value)
    }
}
