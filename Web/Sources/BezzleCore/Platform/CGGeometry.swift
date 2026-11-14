import Foundation

// Core Graphics' geometry, as the Mac has it. Foundation has CGFloat, CGPoint, CGSize and CGRect
// here too, but on 32-bit WebAssembly its CGFloat is a Float: a design would be measured and
// merged at single precision, and numbers the browser wrote into a shared design would differ
// from the Mac's in their last digits (22.33 came back as 22.330017). Declared in the core's own
// module, these stand in for Foundation's everywhere in it.
//
// The rules are Core Graphics' own, as asked of it on a Mac (see tools/geometry): rectangles are
// standardized before anything is worked out from them, the null rectangle is (inf, inf, 0, 0),
// and `contains` takes a point on the left and top edges but not on the right and bottom.

public typealias CGFloat = Double

nonisolated public struct CGPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: CGFloat
    public var y: CGFloat
    public init() { x = 0; y = 0 }
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public init(x: Int, y: Int) { self.x = CGFloat(x); self.y = CGFloat(y) }
    public static let zero = CGPoint()
    public func equalTo(_ p: CGPoint) -> Bool { self == p }
    public var description: String { "(\(x), \(y))" }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(CGFloat.self)
        y = try c.decode(CGFloat.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

nonisolated public struct CGSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: CGFloat
    public var height: CGFloat
    public init() { width = 0; height = 0 }
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
    public init(width: Int, height: Int) { self.width = CGFloat(width); self.height = CGFloat(height) }
    public static let zero = CGSize()
    public func equalTo(_ s: CGSize) -> Bool { self == s }
    public var description: String { "(\(width), \(height))" }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        width = try c.decode(CGFloat.self)
        height = try c.decode(CGFloat.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(width)
        try c.encode(height)
    }
}

nonisolated public enum CGRectEdge: UInt32, Sendable {
    case minXEdge, minYEdge, maxXEdge, maxYEdge
}

nonisolated public struct CGRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var origin: CGPoint
    public var size: CGSize

    public init() { origin = .zero; size = .zero }
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        origin = CGPoint(x: x, y: y)
        size = CGSize(width: width, height: height)
    }
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    public static let zero = CGRect()
    public static let null = CGRect(x: .infinity, y: .infinity, width: 0, height: 0)
    public static let infinite = CGRect(x: -.greatestFiniteMagnitude / 2, y: -.greatestFiniteMagnitude / 2,
                                        width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

    public var isNull: Bool { origin.x == .infinity || origin.y == .infinity }
    public var isEmpty: Bool { isNull || size.width == 0 || size.height == 0 }
    public var isInfinite: Bool { self == .infinite }

    public var standardized: CGRect {
        if isNull { return .null }
        var r = self
        if r.size.width < 0 { r.origin.x += r.size.width; r.size.width = -r.size.width }
        if r.size.height < 0 { r.origin.y += r.size.height; r.size.height = -r.size.height }
        return r
    }

    public var width: CGFloat { isNull ? 0 : abs(size.width) }
    public var height: CGFloat { isNull ? 0 : abs(size.height) }
    public var minX: CGFloat { isNull ? .infinity : Swift.min(origin.x, origin.x + size.width) }
    public var maxX: CGFloat { isNull ? .infinity : Swift.max(origin.x, origin.x + size.width) }
    public var midX: CGFloat { isNull ? .infinity : origin.x + size.width / 2 }
    public var minY: CGFloat { isNull ? .infinity : Swift.min(origin.y, origin.y + size.height) }
    public var maxY: CGFloat { isNull ? .infinity : Swift.max(origin.y, origin.y + size.height) }
    public var midY: CGFloat { isNull ? .infinity : origin.y + size.height / 2 }

    public var integral: CGRect {
        if isNull { return .null }
        let x = minX.rounded(.down), y = minY.rounded(.down)
        return CGRect(x: x, y: y, width: maxX.rounded(.up) - x, height: maxY.rounded(.up) - y)
    }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return .null }
        let r = standardized
        let w = r.size.width - dx * 2, h = r.size.height - dy * 2
        if w < 0 || h < 0 { return .null }
        return CGRect(x: r.origin.x + dx, y: r.origin.y + dy, width: w, height: h)
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return .null }
        let r = standardized
        return CGRect(x: r.origin.x + dx, y: r.origin.y + dy, width: r.size.width, height: r.size.height)
    }

    public func union(_ other: CGRect) -> CGRect {
        // With nothing, the other as it is, not standardized: as Core Graphics answers.
        if isNull { return other }
        if other.isNull { return self }
        if isInfinite || other.isInfinite { return .infinite }
        let x = Swift.min(minX, other.minX), y = Swift.min(minY, other.minY)
        return CGRect(x: x, y: y, width: Swift.max(maxX, other.maxX) - x, height: Swift.max(maxY, other.maxY) - y)
    }

    public func intersection(_ other: CGRect) -> CGRect {
        if isNull || other.isNull { return .null }
        if isInfinite { return other.standardized }
        if other.isInfinite { return standardized }
        let x1 = Swift.max(minX, other.minX), x2 = Swift.min(maxX, other.maxX)
        let y1 = Swift.max(minY, other.minY), y2 = Swift.min(maxY, other.maxY)
        if x2 < x1 || y2 < y1 { return .null }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// Along each axis, two spans meet where they overlap; touching ends do not. A span of no
    /// length meets one it lies on from its start up to, not including, its end, as `contains`.
    public func intersects(_ other: CGRect) -> Bool {
        if isNull || other.isNull { return false }
        func meet(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
            if a0 == a1 && b0 == b1 { return a0 == b0 }
            if a0 == a1 { return a0 >= b0 && a0 < b1 }
            if b0 == b1 { return b0 >= a0 && b0 < a1 }
            return Swift.max(a0, b0) < Swift.min(a1, b1)
        }
        return meet(minX, maxX, other.minX, other.maxX) && meet(minY, maxY, other.minY, other.maxY)
    }

    public func contains(_ p: CGPoint) -> Bool {
        if isNull { return false }
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// Nothing is in everything; a rectangle is in another that reaches as far as it does on every
    /// side. Asked by the edges, as Core Graphics answers. Asked as "adding it changes nothing"
    /// (`union(r) == standardized`) it was right only where the union's width came out to the
    /// last digit, (x + w) − x being w only by luck: of rectangles as designs have them, more than
    /// half were not found in one that held them (`tools/geometry`, off the grid).
    public func contains(_ r: CGRect) -> Bool {
        if r.isNull { return true }
        if isNull { return false }
        return r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func divided(atDistance distance: CGFloat, from edge: CGRectEdge) -> (slice: CGRect, remainder: CGRect) {
        if isNull { return (.null, .null) }
        let r = standardized
        switch edge {
        case .minXEdge:
            let d = Swift.min(Swift.max(distance, 0), r.width)
            return (CGRect(x: r.minX, y: r.minY, width: d, height: r.height), CGRect(x: r.minX + d, y: r.minY, width: r.width - d, height: r.height))
        case .maxXEdge:
            let d = Swift.min(Swift.max(distance, 0), r.width)
            return (CGRect(x: r.maxX - d, y: r.minY, width: d, height: r.height), CGRect(x: r.minX, y: r.minY, width: r.width - d, height: r.height))
        case .minYEdge:
            let d = Swift.min(Swift.max(distance, 0), r.height)
            return (CGRect(x: r.minX, y: r.minY, width: r.width, height: d), CGRect(x: r.minX, y: r.minY + d, width: r.width, height: r.height - d))
        case .maxYEdge:
            let d = Swift.min(Swift.max(distance, 0), r.height)
            return (CGRect(x: r.minX, y: r.maxY - d, width: r.width, height: d), CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - d))
        }
    }

    public func equalTo(_ r: CGRect) -> Bool { self == r }
    public var description: String { "(\(origin.x), \(origin.y), \(size.width), \(size.height))" }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        origin = try c.decode(CGPoint.self)
        size = try c.decode(CGSize.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(origin)
        try c.encode(size)
    }
}

nonisolated public struct CGVector: Equatable, Hashable, Sendable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init() { dx = 0; dy = 0 }
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public init(dx: Int, dy: Int) { self.dx = CGFloat(dx); self.dy = CGFloat(dy) }
    public static let zero = CGVector()

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        dx = try c.decode(CGFloat.self)
        dy = try c.decode(CGFloat.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(dx)
        try c.encode(dy)
    }
}

/// A point maps as `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`, as in Core Graphics.
nonisolated public struct CGAffineTransform: Equatable, Hashable, Sendable, Codable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }
    public init(translationX x: CGFloat, y: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public init(scaleX x: CGFloat, y: CGFloat) { self.init(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    public init(rotationAngle angle: CGFloat) {
        let cs = cos(angle), sn = sin(angle)
        self.init(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }

    public static let identity = CGAffineTransform()
    public var isIdentity: Bool { self == .identity }

    /// `self` first, then `t`.
    /// `self` first, then `t`. Each `x·y + z·w` is fused as Core Graphics computes it on a Mac,
    /// `fma(x, y, z·w)`, so that the last digits come out the same (see tools/geometry).
    public func concatenating(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: fused(a, t.a, b, t.c), b: fused(a, t.b, b, t.d),
                          c: fused(c, t.a, d, t.c), d: fused(c, t.b, d, t.d),
                          tx: fused(tx, t.a, ty, t.c) + t.tx, ty: fused(tx, t.b, ty, t.d) + t.ty)
    }
    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: x, y: y).concatenating(self) }
    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(scaleX: x, y: y).concatenating(self) }
    public func rotated(by angle: CGFloat) -> CGAffineTransform { CGAffineTransform(rotationAngle: angle).concatenating(self) }

    /// By the reciprocal of the determinant, as Core Graphics does.
    public func inverted() -> CGAffineTransform {
        let det = fused(a, d, -b, c)
        guard det != 0, det.isFinite else { return self }
        let r = 1 / det
        let a2 = d * r, b2 = -b * r, c2 = -c * r, d2 = a * r
        // Moved back by the new coefficients: −(a′·tx + c′·ty), fused as a Mac fuses it.
        return CGAffineTransform(a: a2, b: b2, c: c2, d: d2,
                                 tx: (-(tx * a2)).addingProduct(ty, -c2), ty: (-(ty * d2)).addingProduct(tx, -b2))
    }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        self.init(a: try u.decode(CGFloat.self), b: try u.decode(CGFloat.self), c: try u.decode(CGFloat.self),
                  d: try u.decode(CGFloat.self), tx: try u.decode(CGFloat.self), ty: try u.decode(CGFloat.self))
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        for v in [a, b, c, d, tx, ty] { try u.encode(v) }
    }
}

nonisolated public extension CGPoint {
    func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: fused(t.a, x, t.c, y) + t.tx, y: fused(t.b, x, t.d, y) + t.ty)
    }
}

nonisolated public extension CGSize {
    func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: fused(t.a, width, t.c, height), height: fused(t.b, width, t.d, height))
    }
}

nonisolated public extension CGRect {
    func applying(_ t: CGAffineTransform) -> CGRect {
        if isNull || isInfinite { return self }
        let r = standardized
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// `x·y + z·w` as a Mac computes it: the first product fused into the sum, `fma(x, y, z·w)`.
@inline(__always) nonisolated func fused(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ w: CGFloat) -> CGFloat {
    (z * w).addingProduct(x, y)
}
