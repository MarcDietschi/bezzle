import Foundation

// The Draw move's chip in the Animate panel: a line drawn on as a pen draws it, over where the
// layer belongs. The Mac's MoveGlyph cuts its curve short with SwiftUI's trimmedPath; WinUI has
// nothing like it, so the line is laid as points here and cut at its length. Nothing here asks
// Windows anything: Windows/Tests checks it on a Mac too.

public nonisolated enum DrawnLine {
    /// One cubic curve: from, its two controls, to.
    public struct Curve: Sendable {
        public var from, c1, c2, to: CGPoint
        public init(_ from: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ to: CGPoint) {
            self.from = from
            self.c1 = c1
            self.c2 = c2
            self.to = to
        }

        func at(_ t: Double) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * Double(from.x) + b * Double(c1.x) + c * Double(c2.x) + d * Double(to.x),
                           y: a * Double(from.y) + b * Double(c1.y) + c * Double(c2.y) + d * Double(to.y))
        }
    }

    /// The Mac's line, for a home box (`x`, `y`, `w`, `h`): from just left of it and below its
    /// middle, over its top to the middle, under its foot and out past its right.
    public static func moveLine(x: Double, y: Double, w: Double, h: Double) -> [Curve] {
        let minX = x, minY = y, maxX = x + w, maxY = y + h, midX = x + w / 2, midY = y + h / 2
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        return [
            Curve(p(minX - 3, midY + 3), p(minX + 2, minY - 4), p(midX - 4, minY - 2), p(midX, midY)),
            Curve(p(midX, midY), p(midX + 4, maxY + 2), p(maxX - 2, maxY + 4), p(maxX + 3, midY - 3)),
        ]
    }

    /// The curves as a line of points, `steps` to a curve.
    static func points(_ curves: [Curve], steps: Int) -> [CGPoint] {
        guard let first = curves.first else { return [] }
        var out = [first.from]
        let n = max(steps, 1)
        for c in curves {
            for k in 1...n { out.append(c.at(Double(k) / Double(n))) }
        }
        return out
    }

    /// The line from its start to `drawn` of its whole length (0 to 1), as points: empty when
    /// nothing of it is drawn, the whole line at 1 or more.
    public static func trimmed(_ curves: [Curve], to drawn: Double, steps: Int = 24) -> [CGPoint] {
        let line = points(curves, steps: steps)
        guard drawn > 0.001, line.count >= 2 else { return [] }
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(b.x) - Double(a.x), Double(b.y) - Double(a.y)) }
        var whole = 0.0
        for i in 1..<line.count { whole += length(line[i - 1], line[i]) }
        guard drawn < 1, whole > 0 else { return line }
        let wanted = whole * drawn
        var out = [line[0]]
        var gone = 0.0
        for i in 1..<line.count {
            let piece = length(line[i - 1], line[i])
            if gone + piece >= wanted {
                let k = piece > 0 ? (wanted - gone) / piece : 0
                let a = line[i - 1], b = line[i]
                out.append(CGPoint(x: Double(a.x) + (Double(b.x) - Double(a.x)) * k, y: Double(a.y) + (Double(b.y) - Double(a.y)) * k))
                return out
            }
            gone += piece
            out.append(line[i])
        }
        return out
    }
}
