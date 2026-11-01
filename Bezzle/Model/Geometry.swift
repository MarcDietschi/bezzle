import Foundation
import CoreGraphics

/// The eight handles around a selection, named by where they sit.
nonisolated enum Handle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Where the handle sits on the frame, 0…1 across and down.
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        }
    }

    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }

    /// The direction the handle pulls in, in degrees clockwise from pointing right.
    var angle: Double {
        switch self {
        case .right: 0
        case .bottomRight: 45
        case .bottom: 90
        case .bottomLeft: 135
        case .left: 180
        case .topLeft: 225
        case .top: 270
        case .topRight: 315
        }
    }
}

nonisolated enum Geometry {
    static func radians(_ degrees: Double) -> CGFloat { CGFloat(degrees * .pi / 180) }

    static func rotate(_ v: CGPoint, by degrees: Double) -> CGPoint {
        guard degrees != 0 else { return v }
        let a = radians(degrees), c = cos(a), s = sin(a)
        return CGPoint(x: v.x * c - v.y * s, y: v.x * s + v.y * c)
    }

    /// A point of the frame given 0…1 across and down, with the frame turned about its centre.
    static func point(_ unit: CGPoint, of frame: CGRect, rotation: Double) -> CGPoint {
        let local = CGPoint(x: (unit.x - 0.5) * frame.width, y: (unit.y - 0.5) * frame.height)
        let v = rotate(local, by: rotation)
        return CGPoint(x: frame.midX + v.x, y: frame.midY + v.y)
    }

    static func corners(of frame: CGRect, rotation: Double) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            .map { point($0, of: frame, rotation: rotation) }
    }

    /// The upright rectangle around a layer as it is drawn, turned and all, in the page and in depth.
    static func bounds(of node: Node) -> CGRect {
        guard Perspective(node) != nil else { return bounds(of: node.frame, rotation: node.rotation) }
        let pts = Perspective.corners(of: node)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func bounds(of frame: CGRect, rotation: Double) -> CGRect {
        guard rotation.truncatingRemainder(dividingBy: 360) != 0 else { return frame }
        let pts = corners(of: frame, rotation: rotation)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A point of the parent in the layer's own upright coordinates, measured from its centre.
    static func local(_ p: CGPoint, in frame: CGRect, rotation: Double) -> CGPoint {
        rotate(CGPoint(x: p.x - frame.midX, y: p.y - frame.midY), by: -rotation)
    }

    /// Whether a point of the parent falls on the layer; `tolerance` widens thin things.
    @MainActor
    static func contains(_ node: Node, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        // Turned in depth: wherever the point lies on the layer drawn flat.
        if Perspective(node) != nil {
            guard let flat = Perspective.flat(p, of: node) else { return false }
            var plain = node
            plain.transform3D = nil
            return contains(plain, flat, tolerance: tolerance)
        }
        if node.isGroup {
            // A group is where what it holds is drawn, and only inside its mask.
            let inner = CGPoint(x: p.x - node.frame.minX, y: p.y - node.frame.minY)
            if let mask = node.mask?.first, !contains(mask, inner, tolerance: tolerance) { return false }
            // A mask is all its shape, wherever what it holds shows or not.
            if let holder = node.holder { return Mask.inside(holder, inner, tolerance: tolerance) }
            return node.children.contains { !$0.hidden && contains($0, inner, tolerance: tolerance) }
        }
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            let ra = rotated(a, about: c, by: node.rotation), rb = rotated(b, about: c, by: node.rotation)
            return distance(from: p, toSegment: ra, rb) <= max(tolerance, node.borderWidth / 2 + tolerance / 2)
        }
        let q = local(p, in: node.frame, rotation: node.rotation)
        let hw = node.frame.width / 2 + tolerance, hh = node.frame.height / 2 + tolerance
        // A cut-out picture is only where its subject is, and its border round it: a click on
        // what was its background goes through to what lies under.
        if let silhouette = node.silhouette {
            guard abs(q.x) <= hw && abs(q.y) <= hh else { return false }
            let at = CGPoint(x: q.x + node.frame.width / 2, y: q.y + node.frame.height / 2)
            if silhouette.contains(at, using: .evenOdd) { return true }
            let border = node.borders.map { $0.width * ($0.position == .center ? 1 : 2) }.max() ?? 0
            return silhouette.copy(strokingWithWidth: border + tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).contains(at)
        }
        switch node.kind {
        case .ellipse:
            guard hw > 0, hh > 0 else { return false }
            return (q.x * q.x) / (hw * hw) + (q.y * q.y) / (hh * hh) <= 1
        case .path:
            guard abs(q.x) <= hw && abs(q.y) <= hh else { return false }
            // Inside the outline, or on its line, which is all there is of an open path.
            let at = CGPoint(x: q.x + node.frame.width / 2, y: q.y + node.frame.height / 2)
            let outline = Renderer.outline(of: node)
            if node.fill.on && outline.contains(at, using: node.evenOdd == true ? .evenOdd : .winding) { return true }
            return outline.copy(strokingWithWidth: max(node.borderWidth, tolerance * 2) + tolerance,
                                lineCap: .round, lineJoin: .round, miterLimit: 4).contains(at)
        default:
            return abs(q.x) <= hw && abs(q.y) <= hh
        }
    }

    static func rotated(_ p: CGPoint, about c: CGPoint, by degrees: Double) -> CGPoint {
        let v = rotate(CGPoint(x: p.x - c.x, y: p.y - c.y), by: degrees)
        return CGPoint(x: c.x + v.x, y: c.y + v.y)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Resizing

    /// A frame pulled by one of its handles to `point` (in the parent), keeping the opposite side
    /// where it is, or the centre with `fromCenter`. Works on turned frames: the pull is measured
    /// along the frame's own sides.
    static func resize(_ frame: CGRect, rotation: Double, handle: Handle, to point: CGPoint,
                       keepAspect: Bool, fromCenter: Bool, minSize: CGFloat = 1) -> CGRect {
        let w = frame.width, h = frame.height
        let m = local(point, in: frame, rotation: rotation)
        var minX = -w / 2, maxX = w / 2, minY = -h / 2, maxY = h / 2
        let u = handle.unit

        if u.x == 1 { maxX = m.x; if fromCenter { minX = -m.x } }
        if u.x == 0 { minX = m.x; if fromCenter { maxX = -m.x } }
        if u.y == 1 { maxY = m.y; if fromCenter { minY = -m.y } }
        if u.y == 0 { minY = m.y; if fromCenter { maxY = -m.y } }

        if keepAspect, w > 0, h > 0 {
            let sw = (maxX - minX) / w, sh = (maxY - minY) / h
            if handle.isCorner {
                let s = max(abs(sw), abs(sh))
                let nw = s * w * (sw < 0 ? -1 : 1), nh = s * h * (sh < 0 ? -1 : 1)
                if fromCenter {
                    minX = -nw / 2; maxX = nw / 2; minY = -nh / 2; maxY = nh / 2
                } else {
                    if u.x == 1 { maxX = minX + nw } else { minX = maxX - nw }
                    if u.y == 1 { maxY = minY + nh } else { minY = maxY - nh }
                }
            } else if u.y == 0.5 {
                let nh = abs(sw) * h
                minY = -nh / 2; maxY = nh / 2
            } else {
                let nw = abs(sh) * w
                minX = -nw / 2; maxX = nw / 2
            }
        }

        if minX > maxX { swap(&minX, &maxX) }
        if minY > maxY { swap(&minY, &maxY) }
        // Never thinner than a point, unless it was already (a straight line).
        if maxX - minX < minSize && w >= minSize { let c = (minX + maxX) / 2; minX = c - minSize / 2; maxX = c + minSize / 2 }
        if maxY - minY < minSize && h >= minSize { let c = (minY + maxY) / 2; minY = c - minSize / 2; maxY = c + minSize / 2 }

        let centre = rotate(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), by: rotation)
        let size = CGSize(width: maxX - minX, height: maxY - minY)
        return CGRect(x: frame.midX + centre.x - size.width / 2, y: frame.midY + centre.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Where `r` lands when the rectangle `from` is stretched into `to`.
    static func map(_ r: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let sx = from.width > 0 ? to.width / from.width : 1
        let sy = from.height > 0 ? to.height / from.height : 1
        return CGRect(x: to.minX + (r.minX - from.minX) * sx, y: to.minY + (r.minY - from.minY) * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    /// Whole points, as a design lands on the pixel grid.
    static func snapToPixels(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The rectangle drawn by dragging from `a` to `b`: a square with `square`, grown both ways from
    /// `a` with `fromCenter`.
    static func drawnRect(from a: CGPoint, to b: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let s = max(abs(dx), abs(dy))
            dx = s * (dx < 0 ? -1 : 1); dy = s * (dy < 0 ? -1 : 1)
        }
        if fromCenter {
            return CGRect(x: a.x - abs(dx), y: a.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return rect(from: a, to: CGPoint(x: a.x + dx, y: a.y + dy))
    }

    /// The end of a line drawn from `a` towards `b`, bent to the nearest 45° with `constrain`.
    static func lineEnd(from a: CGPoint, to b: CGPoint, constrain: Bool) -> CGPoint {
        guard constrain else { return b }
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
}

nonisolated extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

nonisolated extension CGPoint {
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
}
