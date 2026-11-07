import Foundation
import CoreGraphics

// What paints a layer, shared by every Bezzle: the kinds of fill the fill menu chooses between,
// which of a layer's paints it is open on, a fill turned into another kind, gradients aimed,
// stretched and given colours, and the colours a design uses. The Mac's FillMenu and the
// Windows one change paints alike.

/// What fills a layer: one colour, colours blending along a line or out from a point, or a picture.
enum FillKind: Hashable {
    case solid, linear, radial, picture

    init(_ fill: Fill) {
        if fill.image != nil {
            self = .picture
        } else if let gradient = fill.gradient {
            self = gradient.kind == .radial ? .radial : .linear
        } else {
            self = .solid
        }
    }

    /// The kinds to choose between: a picture where one can be painted with, and always while
    /// there is one.
    static func choices(with current: FillKind, pictures: Bool) -> [(FillKind, LocalizedStringResource)] {
        var choices: [(FillKind, LocalizedStringResource)] = [(.solid, "Solid"), (.linear, "Linear"), (.radial, "Radial")]
        if pictures || current == .picture { choices.append((.picture, "Picture")) }
        return choices
    }
}

/// Which of a layer's paints the fill menu is open on: one of its fills, the first at the bottom,
/// which is also the colour of text's letters; or one of its borders, or a line's strokes.
enum PaintTarget: Hashable {
    case fill(Int)
    case border(Int)

    var path: WritableKeyPath<Node, Fill> {
        switch self {
        case .fill(let slot): Node.fillPath(slot)
        case .border(let slot): Node.borderPath(slot).appending(path: \.paint)
        }
    }

    /// Whether it can be a picture: any border, but only the first fill, which repeat grids and
    /// decks keep their own of in each cell and post.
    var takesPicture: Bool {
        switch self {
        case .fill(let slot): slot == 0
        case .border: true
        }
    }

    /// Whether it is what a text's letters are painted with: changing it for the whole layer
    /// takes away the colours letters had of their own, as a new colour for all of them does.
    func paintsLetters(of n: Node) -> Bool { self == .fill(0) && n.kind == .text }
}

nonisolated extension RGBA {
    /// Part of the way from this colour to `other`.
    func mixed(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }
}

extension Fill {
    /// The fill made one colour or a gradient, as the fill menu's kinds make it, on layer `n`. A
    /// gradient starts from the colour there was, or keeps its colours when it only changes kind;
    /// one colour keeps the gradient's first. A picture is chosen otherwise.
    mutating func paint(as kind: FillKind, on n: Node) {
        on = true
        switch kind {
        case .solid:
            if let first = gradient?.stops.first { color = first.color }
            gradient = nil
            image = nil
        case .linear, .radial:
            let was = gradient?.kind
            var g = gradient ?? .fading(from: color)
            g.kind = kind == .radial ? .radial : .linear
            if g.kind == .radial && was != .radial {
                g.start = CGPoint(x: 0.5, y: 0.5)
                g.radius = 0.5
                g.across = nil
            } else if g.kind == .linear && was != .linear {
                // Along a line, from one end to the other; down anything else.
                if n.kind == .line { g.alongLine(rising: n.rising, size: n.frame.size) } else { g.aim(180, in: n.frame.size) }
                g.across = nil
            }
            gradient = g
            image = nil
        case .picture:
            break
        }
    }
}

extension Gradient {
    /// Runs a linear gradient from one end of a line to the other, its first colour where the
    /// line begins: at its top left, or its bottom left when it rises.
    mutating func alongLine(rising: Bool, size: CGSize) {
        // A level or upright line has no height or width to measure along, so it runs across its box.
        if size.height < 0.5 { start = CGPoint(x: 0, y: 0.5); end = CGPoint(x: 1, y: 0.5); return }
        if size.width < 0.5 { start = CGPoint(x: 0.5, y: 0); end = CGPoint(x: 0.5, y: 1); return }
        start = CGPoint(x: 0, y: rising ? 1 : 0)
        end = CGPoint(x: 1, y: rising ? 0 : 1)
    }

    /// A gradient made from one colour: from it to a shade of it, top to bottom.
    static func fading(from color: RGBA) -> Gradient {
        let (h, s, b) = color.hsb
        let shade = RGBA(h: h, s: s, b: b > 0.5 ? b * 0.7 : min(1, b + 0.35), a: color.a)
        return Gradient(kind: .linear, stops: [GradientStop(offset: 0, color: color), GradientStop(offset: 1, color: shade)],
                        start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
    }

    /// Which way a linear gradient runs as it looks on a layer of `size`, in degrees as CSS
    /// counts them: 0 runs up, 90 to the right, 180 down.
    func angle(in size: CGSize) -> Double {
        let dx = (end.x - start.x) * size.width, dy = (end.y - start.y) * size.height
        guard dx != 0 || dy != 0 else { return 180 }
        let degrees = atan2(dx, -dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Runs the gradient at `degrees` across a layer of `size`, from corner to corner along that
    /// way, so the first and last colours just reach the far corners.
    mutating func aim(_ degrees: Double, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let radians = degrees * .pi / 180
        let way = CGVector(dx: sin(radians), dy: -cos(radians))
        let half = (size.width * abs(way.dx) + size.height * abs(way.dy)) / 2
        start = CGPoint(x: 0.5 - way.dx * half / size.width, y: 0.5 - way.dy * half / size.height)
        end = CGPoint(x: 0.5 + way.dx * half / size.width, y: 0.5 + way.dy * half / size.height)
    }

    /// The colour the gradient has at `offset`.
    func color(at offset: Double) -> RGBA {
        let sorted = stops.sorted { $0.offset < $1.offset }
        guard let first = sorted.first, let last = sorted.last else { return RGBA(r: 0, g: 0, b: 0) }
        if offset <= first.offset { return first.color }
        if offset >= last.offset { return last.color }
        for (a, b) in zip(sorted, sorted.dropFirst()) where offset <= b.offset {
            let span = b.offset - a.offset
            return a.color.mixed(b.color, span > 0 ? (offset - a.offset) / span : 0)
        }
        return last.color
    }

    /// Moves a radial gradient's centre, its radii with it.
    mutating func centre(at point: CGPoint) {
        let dx = point.x - start.x, dy = point.y - start.y
        if let a = across {
            end = CGPoint(x: end.x + dx, y: end.y + dy)
            across = CGPoint(x: a.x + dx, y: a.y + dy)
        }
        start = point
    }

    /// Turns and stretches a radial gradient's first radius to end at `tip`, on a layer of `size`.
    /// The second turns with it, square to it as the layer shows them, and keeps its length.
    mutating func turn(to tip: CGPoint, in size: CGSize) {
        let c = Self.onLayer(start, size), (a, b) = radii
        let u = Self.onLayer(tip, size) - c, was = Self.onLayer(a, size) - c, v = Self.onLayer(b, size) - c
        guard hypot(u.x, u.y) > 0.5 else { return }
        let square = Self.square(to: u, side: was.x * v.y - was.y * v.x)
        let length = hypot(v.x, v.y)
        end = tip
        across = Self.inBox(CGPoint(x: c.x + square.x * length, y: c.y + square.y * length), size)
    }

    /// Stretches a radial gradient's second radius, square to the first, to reach as far out as
    /// `point` is, on a layer of `size`.
    mutating func stretch(to point: CGPoint, in size: CGSize) {
        let c = Self.onLayer(start, size), (a, b) = radii
        let u = Self.onLayer(a, size) - c, v = Self.onLayer(b, size) - c
        guard hypot(u.x, u.y) > 0.5 else { return }
        let square = Self.square(to: u, side: u.x * v.y - u.y * v.x)
        let p = Self.onLayer(point, size) - c
        let length = max(abs(p.x * square.x + p.y * square.y), 0.5)
        end = a
        across = Self.inBox(CGPoint(x: c.x + square.x * length, y: c.y + square.y * length), size)
    }

    /// The corner of the square a radial gradient's ellipse sits in, past the ends of both its
    /// radii, where the ellipse's edges there would meet: its bottom right, until it is turned.
    var corner: CGPoint {
        let (a, b) = radii
        return CGPoint(x: a.x + b.x - start.x, y: a.y + b.y - start.y)
    }

    /// Sizes a radial gradient by that corner, as a layer is sized by its own: both radii at once,
    /// each reaching as far along it as `point` is, on a layer of `size`. The centre stays where
    /// it is, as it does for the gradient's other points; `keepingShape`, both grow by the same share.
    mutating func resize(to point: CGPoint, in size: CGSize, keepingShape: Bool) {
        let c = Self.onLayer(start, size), (a, b) = radii
        let u = Self.onLayer(a, size) - c, v = Self.onLayer(b, size) - c
        let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
        guard lu > 0.5, lv > 0.5 else { return }
        let p = Self.onLayer(point, size) - c
        // How far out the point is along each radius.
        var s = (p.x * u.x + p.y * u.y) / lu, t = (p.x * v.x + p.y * v.y) / lv
        if keepingShape {
            // Along the line from the centre through the corner, so the ellipse keeps its shape.
            let k = (s * lu + t * lv) / (lu * lu + lv * lv)
            s = lu * k
            t = lv * k
        }
        // Never through the centre and out the other side: a point's width at the least.
        s = max(s, 1)
        t = max(t, 1)
        end = Self.inBox(CGPoint(x: c.x + u.x / lu * s, y: c.y + u.y / lu * s), size)
        across = Self.inBox(CGPoint(x: c.x + v.x / lv * t, y: c.y + v.y / lv * t), size)
    }

    /// One unit square to `u`, on the `side` of it the second radius was, so the ellipse keeps its turn.
    private static func square(to u: CGPoint, side: CGFloat) -> CGPoint {
        let length = hypot(u.x, u.y)
        let n = CGPoint(x: -u.y / length, y: u.x / length)
        return side >= 0 ? n : CGPoint(x: -n.x, y: -n.y)
    }

    private static func onLayer(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
    private static func inBox(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x / max(size.width, 0.001), y: p.y / max(size.height, 0.001))
    }
}

extension Array where Element == GradientStop {
    /// The stops with the one at `index` moved to `offset`, in order along the bar, and where
    /// that one is in the order now, as it may have passed another.
    func placing(_ index: Int, at offset: Double) -> (stops: [GradientStop], index: Int) {
        var moved = self
        moved[index].offset = Swift.min(Swift.max(offset, 0), 1)
        let order = moved.indices.sorted { moved[$0].offset < moved[$1].offset }
        return (order.map { moved[$0] }, order.firstIndex(of: index) ?? index)
    }
}


// MARK: - The colours a design uses

/// A colour a design uses, told apart as its hex code is, and how often it is met.
nonisolated struct UsedColor: Equatable {
    let color: RGBA
    let key: Int
    var count: Int
}

extension BezzleDocument {
    /// The fill and border colours in a layer and all it holds, without their transparency, told
    /// apart as their hex codes are, in the order met.
    nonisolated static func colorsUsed(in top: Node) -> [UsedColor] {
        var at: [Int: Int] = [:]
        var used: [UsedColor] = []
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        func visit(_ n: Node) {
            for c in (n.kind != .artboard ? n.fills.map(\.color) : []) + n.borders.map(\.color) {
                let key = byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
                if let i = at[key] { used[i].count += 1 } else {
                    at[key] = used.count
                    used.append(UsedColor(color: c.with(alpha: 1), key: key, count: 1))
                }
            }
            for child in n.children { visit(child) }
        }
        visit(top)
        return used
    }

    /// The colours of each artboard and loose layer together, the most used first, and those
    /// used as often in the order met.
    nonisolated static func ranked(_ perTop: [[UsedColor]]) -> [RGBA] {
        var counts: [Int: Int] = [:]
        var order: [UsedColor] = []
        for used in perTop {
            for u in used {
                if counts[u.key] == nil { order.append(u) }
                counts[u.key, default: 0] += u.count
            }
        }
        return order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element.key] ?? 0, counts[b.element.key] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element.color)
    }

    /// The colours the design uses, the most used first, without their transparency.
    var colorsUsed: [RGBA] { Self.ranked(nodes.map(Self.colorsUsed(in:))) }
}
