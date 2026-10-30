import CoreGraphics
import Foundation

/// Rounded corners that run smoothly into the sides, as iOS draws its icons and Figma smooths its
/// corners: each corner is a shorter arc in its middle, eased into the straight sides on either
/// hand by a curve, so the bend comes on gently instead of all at once. With no smoothing it is a
/// circle's quarter, as a plain rounded corner is; 0.6 is the iOS look. The geometry is the one
/// Figma set out in "Desperately seeking squircles".
nonisolated enum Squircle {
    /// A rectangle with these corner radii, top left, top right, bottom right and bottom left,
    /// smoothed by `smoothing`, 0 to 1.
    static func path(in r: CGRect, corners: [CGFloat], smoothing: CGFloat) -> CGPath {
        let budget = min(r.width, r.height) / 2
        let smoothing = min(max(smoothing, 0), 1)
        // Clockwise from the top right, each with the side it comes in along and the one it leaves by.
        let turns: [(at: CGPoint, radius: CGFloat, along: CGVector, then: CGVector)] = [
            (CGPoint(x: r.maxX, y: r.minY), corners[1], CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: r.maxX, y: r.maxY), corners[2], CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: r.minX, y: r.maxY), corners[3], CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: r.minX, y: r.minY), corners[0], CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        let path = CGMutablePath()
        for (i, turn) in turns.enumerated() {
            let c = Corner(radius: turn.radius, smoothing: smoothing, budget: budget)
            func at(_ s: CGFloat, _ t: CGFloat, from o: CGPoint) -> CGPoint {
                CGPoint(x: o.x + turn.along.dx * s + turn.then.dx * t, y: o.y + turn.along.dy * s + turn.then.dy * t)
            }
            let start = at(-c.reach, 0, from: turn.at)
            if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
            guard c.radius > 0 else {
                path.addLine(to: turn.at)
                continue
            }
            // In along the side, onto the arc.
            let onArc = at(c.a + c.b + c.c, c.d, from: start)
            path.addCurve(to: onArc, control1: at(c.a, 0, from: start), control2: at(c.a + c.b, 0, from: start))
            let centre = at(-c.radius, c.radius, from: turn.at)
            let from = atan2(onArc.y - centre.y, onArc.x - centre.x)
            path.addArc(center: centre, radius: c.radius, startAngle: from, endAngle: from + c.sweep, clockwise: false)
            // Off the arc, out along the next side.
            let offArc = at(c.chord, c.chord, from: onArc)
            path.addCurve(to: at(c.d, c.a + c.b + c.c, from: offArc), control1: at(c.d, c.c, from: offArc),
                          control2: at(c.d, c.b + c.c, from: offArc))
        }
        path.closeSubpath()
        return path
    }

    /// One corner's measures, in the corner's own terms: along the side it comes in by, and
    /// across into the next.
    private struct Corner {
        let radius: CGFloat
        /// How far along each side the corner reaches.
        let reach: CGFloat
        /// The arc in its middle, as an angle, and as how far it goes along and across.
        let sweep: CGFloat
        let chord: CGFloat
        /// Where the curves either side of the arc have their control points.
        let a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat

        init(radius: CGFloat, smoothing: CGFloat, budget: CGFloat) {
            let radius = min(max(radius, 0), budget)
            var reach = (1 + smoothing) * radius
            let arc = 90 * (1 - smoothing)
            let chord = sin(Self.radians(arc / 2)) * radius * sqrt(2)
            let alpha = (90 - arc) / 2
            let p3ToP4 = radius * tan(Self.radians(alpha / 2))
            let beta = 45 * smoothing
            let c = p3ToP4 * cos(Self.radians(beta))
            let d = c * tan(Self.radians(beta))
            var b = (reach - chord - c - d) / 3
            var a = 2 * b
            // Without room for all of it, the smoothing is kept and the curves shortened.
            if reach > budget {
                let room = budget - d - chord - c
                b = min(b, room - room / 6)
                a = room - b
                reach = budget
            }
            self.radius = radius
            self.reach = reach
            self.sweep = Self.radians(arc)
            self.chord = chord
            self.a = a
            self.b = b
            self.c = c
            self.d = d
        }

        private static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
    }
}
