import CoreGraphics
import Foundation

/// Smart guides: the edges and centres a moving layer catches on, those of its neighbours on the
/// same artboard and of the artboard itself.
struct SnapTargets {
    struct Line {
        var value: CGFloat
        /// The rectangle this edge or centre belongs to, so the guide can reach it.
        var box: CGRect
    }

    var xs: [Line] = []
    var ys: [Line] = []

    /// Targets for layers `moving`, all on canvas points.
    init(doc: BezzleDocument, moving ids: Set<UUID>) {
        let first = ids.first
        let parent = first.flatMap { doc.parent(of: $0) }
        var boxes: [CGRect] = []
        if let parent, let box = doc.absoluteFrame(of: parent.id) {
            boxes.append(box)
            for child in parent.children where !ids.contains(child.id) && !child.hidden {
                boxes.append(Geometry.bounds(of: child).offsetBy(dx: box.minX, dy: box.minY))
            }
            // Inside a group, the artboard around it counts too.
            if parent.isGroup, let board = first.flatMap({ doc.artboard(of: $0) }) { boxes.append(board.frame) }
        } else {
            for node in doc.nodes where !ids.contains(node.id) && !node.hidden {
                boxes.append(node.isArtboard ? node.frame : Geometry.bounds(of: node))
            }
            // Something loose that crosses onto an artboard catches on what is on it too.
            if let id = first, let frame = doc.absoluteFrame(of: id), let board = doc.artboard(at: frame.center) {
                for child in board.children where !ids.contains(child.id) && !child.hidden {
                    boxes.append(Geometry.bounds(of: child).offsetBy(dx: board.frame.minX, dy: board.frame.minY))
                }
            }
        }
        for b in boxes {
            xs += [Line(value: b.minX, box: b), Line(value: b.midX, box: b), Line(value: b.maxX, box: b)]
            ys += [Line(value: b.minY, box: b), Line(value: b.midY, box: b), Line(value: b.maxY, box: b)]
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

    /// A moving rectangle caught by the nearest targets: the shift to apply, and the guides to draw.
    func snap(moving rect: CGRect, threshold: CGFloat) -> (CGPoint, [Guide]) {
        let bx = Self.best([rect.minX, rect.midX, rect.maxX], xs, threshold: threshold)
        let by = Self.best([rect.minY, rect.midY, rect.maxY], ys, threshold: threshold)
        let shift = CGPoint(x: bx?.shift ?? 0, y: by?.shift ?? 0)
        let moved = rect.offsetBy(dx: shift.x, dy: shift.y)
        return (shift, guides(for: moved, x: bx?.value, y: by?.value))
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
