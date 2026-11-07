import Foundation

// A gradient shaped on the canvas, as the Mac's GradientHandles shape one (Views/GradientHandles.swift):
// its ends, centre, radii and corner dragged, its colours moved along its line, added and taken
// off. The shapes are the shared `Gradient`'s (Model/Paints.swift): `centre(at:)`, `turn(to:in:)`,
// `stretch(to:in:)`, `resize(to:in:keepingShape:)`, `placing`.

extension WindowsCore {
    /// What the canvas draws of a layer's gradient, in the layer's own box (0…1 across and down),
    /// and where the layer is: its frame on the canvas and its turn.
    nonisolated public struct GradientLook: Sendable, Equatable {
        public let radial: Bool
        public let stops: [Stop]
        /// Linear: where the first colour is. Radial: the centre.
        public let start: CGPoint
        /// Linear: where the last colour is. Radial: where its first radius ends.
        public let end: CGPoint
        /// Radial: where its second radius ends, square to the first as the layer shows them.
        public let side: CGPoint?
        /// Radial: the corner of the square the ellipse sits in, past both radii.
        public let corner: CGPoint?
        public let frame: CGRect
        public let rotation: Double

        public static func == (a: GradientLook, b: GradientLook) -> Bool {
            a.radial == b.radial && a.start == b.start && a.end == b.end && a.side == b.side && a.corner == b.corner
                && a.frame == b.frame && a.rotation == b.rotation && a.stops.count == b.stops.count
                && zip(a.stops, b.stops).allSatisfy { $0.offset == $1.offset && $0.colour == $1.colour }
        }
    }

    /// How a gradient is shaped from the canvas: an end moved to a point in the layer's box (a
    /// radial one's start moves its centre, its end turns and stretches it), the second radius
    /// stretched, the corner sizing both radii (keeping the ellipse's shape), or its colours set.
    public enum GradientShape: Sendable {
        case start(CGPoint), end(CGPoint), across(CGPoint), corner(CGPoint, keepingShape: Bool), stops([Stop])
    }

    private static func paintPath(border: Bool, slot: Int) -> PaintTarget { border ? .border(slot) : .fill(slot) }

    /// The gradient a layer's fill or border paints with, as the handles show it: only for a
    /// paint that is on, holds no picture and has two colours or more (the Mac's GradientHandles).
    public static func gradientLook(_ id: UUID, border: Bool, slot: Int) -> GradientLook? {
        guard let doc = design, let n = doc.node(id), let frame = doc.absoluteFrame(of: id) else { return nil }
        if border, slot >= n.slots(.border) { return nil }
        if !border, slot >= n.slots(.fill) { return nil }
        let fill = n[keyPath: paintPath(border: border, slot: slot).path]
        guard fill.on, fill.image == nil, let g = fill.gradient, g.stops.count >= 2 else { return nil }
        let radial = g.kind == .radial
        return GradientLook(radial: radial, stops: g.stops.map { Stop(offset: $0.offset, colour: Colour($0.color)) },
                            start: g.start, end: radial ? g.radii.0 : g.end, side: radial ? g.radii.1 : nil,
                            corner: radial ? g.corner : nil, frame: frame, rotation: n.rotation)
    }

    /// Shapes the gradient of the layers' fill or border; inside a gesture, from where it began.
    public static func shapeGradient(_ ids: [UUID], border: Bool, slot: Int, _ shape: GradientShape) {
        let path = paintPath(border: border, slot: slot).path
        edit { d in
            for id in ids {
                d.update(id) { n in
                    if border, slot >= n.slots(.border) { return }
                    guard var g = n[keyPath: path].gradient else { return }
                    let size = n.frame.size
                    switch shape {
                    case .start(let u):
                        if g.kind == .radial { g.centre(at: u) } else { g.start = u }
                    case .end(let u):
                        if g.kind == .radial { g.turn(to: u, in: size) } else { g.end = u }
                    case .across(let u): g.stretch(to: u, in: size)
                    case .corner(let u, let keep): g.resize(to: u, in: size, keepingShape: keep)
                    case .stops(let s): g.stops = s.map { GradientStop(offset: $0.offset, color: RGBA($0.colour)) }
                    }
                    n[keyPath: path].gradient = g
                }
            }
        }
    }

    /// The colour a gradient of these colours has at `offset` along it.
    public static func gradientColour(_ stops: [Stop], at offset: Double) -> Colour {
        let g = Gradient(kind: .linear, stops: stops.map { GradientStop(offset: $0.offset, color: RGBA($0.colour)) },
                         start: .zero, end: CGPoint(x: 1, y: 0))
        return Colour(g.color(at: offset))
    }

    /// The colours with the one at `index` moved to `offset`, in order along the line, and where
    /// that one is in the order now, as it may have passed another (the shared `placing`).
    public static func placing(_ stops: [Stop], _ index: Int, at offset: Double) -> (stops: [Stop], index: Int) {
        let (moved, at) = stops.map { GradientStop(offset: $0.offset, color: RGBA($0.colour)) }.placing(index, at: offset)
        return (moved.map { Stop(offset: $0.offset, colour: Colour($0.color)) }, at)
    }
}
