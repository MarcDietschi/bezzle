import Foundation

/// Which way a layer turned in depth faces, and the turn that faces it somewhere: what the 3D
/// card's pad, its dial and the knob on the canvas work out, on every platform.
enum DepthAim {
    /// Where a turned face points, seen from in front: across and down, each from -1 to 1.
    static func facing(_ t: Transform3D) -> CGPoint {
        let a = t.x * .pi / 180, b = t.y * .pi / 180
        return CGPoint(x: sin(b), y: -sin(a) * cos(b))
    }

    /// The turn that points a face there, the other way; no further round than 85°, short of edge on.
    static func turn(facing d: CGPoint) -> (x: Double, y: Double) {
        var d = d
        let length = hypot(d.x, d.y), most = sin(85 * CGFloat.pi / 180)
        if length > most { d = CGPoint(x: d.x / length * most, y: d.y / length * most) }
        let b = asin(d.x)
        let a = asin(min(max(-d.y / cos(b), -1), 1))
        return (Double(a) * 180 / .pi, Double(b) * 180 / .pi)
    }

    /// Steps of 15° with Shift; and face on, or nearly, flat in the page.
    static func settled(_ x: Double, _ y: Double, steps: Bool) -> (x: Double, y: Double) {
        if steps { return (((x / 15).rounded() * 15), ((y / 15).rounded() * 15)) }
        if hypot(x, y) < 3 { return (0, 0) }
        return ((x * 10).rounded() / 10, (y * 10).rounded() / 10)
    }

    /// A card turned as a layer is, drawn small in `size` (the Mac's CardInDepth), its
    /// perspective made strong enough to read at that size: its corners top left first, whether
    /// it shows its back (turned past edge on, its corners run the other way round), and how much
    /// black darkens its face (the light is above the page, a little in front).
    static func card(_ turn: Transform3D, in size: CGSize) -> (corners: [CGPoint], back: Bool, shade: Double) {
        let w = size.width * 0.82, h = size.height * 0.82
        let card = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let p = Perspective(Transform3D(x: turn.x, y: turn.y), center: CGPoint(x: card.midX, y: card.midY), distance: max(w, h) * 2.4)
        let pts = [CGPoint(x: card.minX, y: card.minY), CGPoint(x: card.maxX, y: card.minY),
                   CGPoint(x: card.maxX, y: card.maxY), CGPoint(x: card.minX, y: card.maxY)].map(p.shown)
        let area = zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        let a = turn.x * .pi / 180, b = turn.y * .pi / 180
        let lit = max(0, -sin(a) * cos(b) * -0.5 + cos(a) * cos(b) * 0.87)
        return (pts, area < 0, (1 - lit) * 0.22)
    }
}

extension Transform3D {
    /// Tipped `by` degrees off the page, the way it is turned already; laid flat, the way a
    /// layer is first held up (the 3D card's dial).
    func tipped(_ by: Double) -> Transform3D {
        var t = self
        let now = hypot(t.x, t.y), held = hypot(Presets.heldUp.x, Presets.heldUp.y)
        let (dx, dy) = now > 0.05 ? (t.x / now, t.y / now) : (Presets.heldUp.x / held, Presets.heldUp.y / held)
        let by = max(by, 0.1)
        t.x = (dx * by * 10).rounded() / 10
        t.y = (dy * by * 10).rounded() / 10
        return t
    }
}
