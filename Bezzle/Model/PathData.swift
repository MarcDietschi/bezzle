import CoreGraphics
import Foundation

/// Outlines written the way SVG writes them ("M 0 0 L 10 0 C … Z"): read into Core Graphics
/// paths, and written back, so a path can be moved, turned or flipped and kept as text.
nonisolated enum PathData {
    /// Reads SVG path data. Whatever cannot be read ends the path there.
    static func cgPath(_ data: String) -> CGPath {
        var reader = Reader(Array(data.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        // The last control point, for the smooth curves that mirror it.
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0

        while true {
            reader.skipSeparators()
            guard let next = reader.peek else { break }
            if Reader.isCommand(next) {
                command = next
                reader.advance()
            } else if command == 0 {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            func point() -> CGPoint? {
                guard let x = reader.number(), let y = reader.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubic: CGPoint?, quad: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = reader.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = reader.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case UInt8(ascii: "s"):
                let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubic = c2; current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case UInt8(ascii: "t"):
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c; current = p
            case UInt8(ascii: "a"):
                guard let rx = reader.number(), let ry = reader.number(), let angle = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return path
    }

    /// A number as SVG writes it: to a thousandth, without trailing zeros. Written out by hand, as
    /// a path has thousands.
    static func number(_ v: CGFloat) -> String {
        guard v.isFinite, abs(v) < 1e12 else { return "0" }
        let t = Int((v * 1000).rounded())
        let whole = String(abs(t) / 1000)
        var fraction = abs(t) % 1000
        let sign = t < 0 ? "-" : ""
        guard fraction != 0 else { return sign + whole }
        var digits = 3
        while fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        let f = String(fraction)
        return sign + whole + "." + String(repeating: "0", count: digits - f.count) + f
    }

    /// Writes a path as SVG path data, absolute and plain.
    static func string(_ path: CGPath) -> String {
        var parts: [String] = []
        func p(_ q: CGPoint) -> String { "\(number(q.x)) \(number(q.y))" }
        path.applyWithBlock { element in
            let e = element.pointee, pts = e.points
            switch e.type {
            case .moveToPoint: parts.append("M \(p(pts[0]))")
            case .addLineToPoint: parts.append("L \(p(pts[0]))")
            case .addQuadCurveToPoint: parts.append("Q \(p(pts[0])) \(p(pts[1]))")
            case .addCurveToPoint: parts.append("C \(p(pts[0])) \(p(pts[1])) \(p(pts[2]))")
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// The box the outline's curves pass through, not counting control points that pull from outside it.
    static func bounds(_ data: String) -> CGRect {
        cgPath(data).boundingBoxOfPath
    }

    /// The same outline moved through `transform`.
    static func transformed(_ data: String, _ transform: CGAffineTransform) -> String {
        var t = transform
        return string(cgPath(data).copy(using: &t) ?? cgPath(data))
    }

    /// An elliptical arc as SVG means it, from its two ends, made of Bézier curves.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = angle * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach are grown until they just do.
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angleOf(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angleOf(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        // A curve for each quarter turn or less.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ t: CGFloat) -> (CGPoint, CGPoint) {
            let x = rx * cos(t), y = ry * sin(t), tx = -rx * sin(t), ty = ry * cos(t)
            let p = CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
            let d = CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty)
            return (p, d)
        }
        var t = theta1
        for _ in 0..<segments {
            let (a, da) = onEllipse(t), (b, db) = onEllipse(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    /// Numbers and commands out of SVG path data, which allows "1-2", ".5.5" and "1e-3".
    private nonisolated struct Reader {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }
        mutating func advance() { i += 1 }

        static func isCommand(_ c: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
        }

        mutating func skipSeparators() {
            while let c = peek, c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D { advance() }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = i
            if let c = peek, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { advance() }
            var dot = false, digits = false
            while let c = peek {
                if c >= 0x30 && c <= 0x39 { digits = true; advance() }
                else if c == UInt8(ascii: "."), !dot { dot = true; advance() }
                else { break }
            }
            if digits, let c = peek, c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                let mark = i
                advance()
                if let s = peek, s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { advance() }
                var exp = false
                while let c = peek, c >= 0x30 && c <= 0x39 { exp = true; advance() }
                if !exp { i = mark }
            }
            guard digits, let text = String(bytes: bytes[start..<i], encoding: .ascii), let v = Double(text) else {
                i = start
                return nil
            }
            return CGFloat(v)
        }

        /// Arc flags may be written without anything between them: "a1 1 0 01 1 1".
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == 0x30 || c == 0x31 else { return nil }
            advance()
            return c == 0x31
        }
    }
}
