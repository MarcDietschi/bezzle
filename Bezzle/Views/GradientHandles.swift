import SwiftUI
import AppKit

/// A gradient's handles over the canvas, where the layer is, out while its fill menu is open, as
/// Adobe XD shows them. A gradient along a line shows the line between its ends; one spreading from
/// a point shows the radius out from that point, and the ellipse it spreads to, with a point on it
/// square to the radius. Its colours are points on the line: the ends are the first and last, and
/// the ones between can be dragged along, or away to take them off. Click one to pick its colour in
/// the menu, and the line to add one there. Drag an end to turn and stretch the gradient, or the
/// centre to move it; the point on the ellipse makes it wider or narrower. Shift keeps the line to
/// every fifteen degrees. They lie over the canvas without taking its clicks anywhere but on
/// themselves, and a click on them leaves the menu open.
struct GradientHandles: View {
    let store: DocumentStore
    @Environment(MenuHost.self) private var menus

    var body: some View {
        if menus.open?.id == FillMenu.id, store.selection.count == 1, let id = store.selection.first, let node = store.node(id),
           node.fill.on, node.fill.image == nil, let gradient = node.fill.gradient, gradient.stops.count >= 2,
           let frame = store.doc.absoluteFrame(of: id) {
            GradientRig(store: store, gradient: gradient, map: LayerMap(frame: frame, rotation: node.rotation, viewport: store.viewport))
                .transition(.opacity)
        }
    }
}

/// Between a layer's own box, 0 to 1 across and down as a gradient measures it, and the canvas on
/// screen, turned as the layer is.
private struct LayerMap {
    let frame: CGRect
    let rotation: Double
    let viewport: Viewport

    func view(_ u: CGPoint) -> CGPoint {
        let x = (u.x - 0.5) * frame.width, y = (u.y - 0.5) * frame.height
        let r = Geometry.radians(rotation)
        return viewport.toView(CGPoint(x: frame.midX + x * cos(r) - y * sin(r), y: frame.midY + x * sin(r) + y * cos(r)))
    }

    func unit(_ v: CGPoint) -> CGPoint {
        let p = viewport.toCanvas(v)
        let x = p.x - frame.midX, y = p.y - frame.midY
        let r = -Geometry.radians(rotation)
        return CGPoint(x: (x * cos(r) - y * sin(r)) / max(frame.width, 0.001) + 0.5,
                       y: (x * sin(r) + y * cos(r)) / max(frame.height, 0.001) + 0.5)
    }
}

private struct GradientRig: View {
    let store: DocumentStore
    let gradient: Gradient
    let map: LayerMap
    @Environment(GradientSession.self) private var session
    /// What the press being dragged took hold of.
    @State private var grip: Grip?
    @State private var began = false
    @State private var leaving = false
    /// Where the handles' space is in the window, to tell the menu where they are.
    @State private var origin: CGPoint = .zero

    private enum Grip: Equatable { case start, end, across, stop, line }

    static let space = "gradient-rig"
    /// How near a point a press takes hold of it.
    static let reach: CGFloat = 12
    /// How far off the line a colour is dragged to take it off.
    static let away: CGFloat = 30
    /// Colours this near an end are shown by the end's own point.
    static let atEnd = 0.001

    /// The line the colours lie along: from start to end, or from the centre out to the radius's end.
    private var ends: (CGPoint, CGPoint) {
        switch gradient.kind {
        case .linear: (map.view(gradient.start), map.view(gradient.end))
        case .radial: (map.view(gradient.start), map.view(gradient.radii.0))
        }
    }

    /// The colours that have points of their own between the ends.
    private var between: [Int] {
        gradient.stops.indices.filter { gradient.stops[$0].offset > Self.atEnd && gradient.stops[$0].offset < 1 - Self.atEnd }
    }

    /// The first colour along the line and the last, which the ends stand for.
    private var first: Int { gradient.stops.indices.min { gradient.stops[$0].offset < gradient.stops[$1].offset } ?? 0 }
    private var last: Int { gradient.stops.indices.max { gradient.stops[$0].offset < gradient.stops[$1].offset } ?? 0 }

    private func on(_ offset: Double, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * offset, y: a.y + (b.y - a.y) * offset)
    }

    /// How far along the line a point on screen falls, and how far off it.
    private func place(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (along: Double, off: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
        guard length2 > 0.25 else { return (0, hypot(p.x - a.x, p.y - a.y)) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2
        let off = abs((p.x - a.x) * dy - (p.y - a.y) * dx) / sqrt(length2)
        return (Double(min(max(t, 0), 1)), off)
    }

    var body: some View {
        let (a, b) = ends
        let stops = gradient.stops
        let chosen = min(session.stop, stops.count - 1)
        let side = gradient.kind == .radial ? map.view(gradient.radii.1) : nil
        let dots = between.map { (index: $0, at: on(stops[$0].offset, a, b)) }
        // The chosen colour, when it is at an end, is ringed there.
        let endChosen = stops[chosen].offset <= Self.atEnd ? 0 : stops[chosen].offset >= 1 - Self.atEnd ? 1 : nil
        let points = [a, b] + (side.map { [$0] } ?? []) + dots.map(\.at)
        let _ = session.handles = (points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) },
                                   (CGPoint(x: a.x + origin.x, y: a.y + origin.y), CGPoint(x: b.x + origin.x, y: b.y + origin.y)))
        ZStack(alignment: .topLeading) {
            Group {
                if gradient.kind == .radial { ring }
                // The line, white over a dark edge so it shows over any colour beneath.
                Path { $0.move(to: a); $0.addLine(to: b) }
                    .stroke(Color.black.opacity(0.32), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                Path { $0.move(to: a); $0.addLine(to: b) }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                if let side {
                    ShapePoint().position(side)
                }
                ColourPoint(color: gradient.color(at: 0), chosen: endChosen == 0, size: 16).position(a)
                ColourPoint(color: gradient.color(at: 1), chosen: endChosen == 1, size: 16).position(b)
                ForEach(dots, id: \.index) { dot in
                    ColourPoint(color: stops[dot.index].color, chosen: dot.index == chosen, size: 13)
                        .opacity(dot.index == chosen && leaving ? 0.3 : 1)
                        .position(dot.at)
                }
            }
            .allowsHitTesting(false)

            // One press decides what it holds, so no point gives way under it as the colours reorder.
            Color.clear
                .contentShape(Grips(points: points, reach: Self.reach, line: (a, b)))
                .gesture(press(a: a, b: b, side: side, dots: dots))
                .help(gradient.kind == .radial
                      ? "Drag the centre to move the gradient, its edge to turn and stretch it, and the point on the ring to widen it. Click a colour to pick it, or the line to add one."
                      : "Drag an end to turn and stretch the gradient. Click a colour to pick it, drag it along to move it or away to take it off, or click the line to add one.")
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        .onDisappear { session.handles = nil }
        .animation(Theme.quick, value: chosen)
    }

    /// How far a radial gradient spreads, drawn round its centre.
    private var ring: some View {
        let spread = gradient.spread(in: CGSize(width: 1, height: 1))
        let path = Path { p in
            for k in 0...72 {
                let angle = Double(k) / 72 * 2 * .pi
                let point = map.view(CGPoint(x: cos(angle), y: sin(angle)).applying(spread))
                if k == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
        return ZStack {
            path.stroke(Color.black.opacity(0.3), lineWidth: 2.5)
            path.stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// What a press near `p` takes hold of: a colour between the ends first, as they lie on the line,
    /// then an end or the point on the ring, then the line.
    private func hold(at p: CGPoint, a: CGPoint, b: CGPoint, side: CGPoint?, dots: [(index: Int, at: CGPoint)]) -> (Grip, Int?)? {
        func near(_ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }
        if let dot = dots.min(by: { near($0.at) < near($1.at) }), near(dot.at) <= Self.reach { return (.stop, dot.index) }
        var points: [(Grip, CGPoint)] = [(.start, a), (.end, b)]
        if let side { points.append((.across, side)) }
        if let point = points.min(by: { near($0.1) < near($1.1) }), near(point.1) <= Self.reach { return (point.0, nil) }
        return place(p, a, b).off <= 6 ? (.line, nil) : nil
    }

    private func press(a: CGPoint, b: CGPoint, side: CGPoint?, dots: [(index: Int, at: CGPoint)]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if grip == nil {
                    guard let held = hold(at: g.startLocation, a: a, b: b, side: side, dots: dots) else { return }
                    grip = held.0
                    switch held.0 {
                    case .start: session.stop = first
                    case .end: session.stop = last
                    case .stop: session.stop = held.1 ?? session.stop
                    case .across, .line: break
                    }
                }
                guard let grip, grip != .line, g.translation != .zero else { return }
                if !began {
                    began = true
                    store.beginGesture()
                }
                switch grip {
                case .start, .end: moveEnd(grip == .start, to: g.location, other: grip == .start ? b : a)
                case .across:
                    let u = map.unit(g.location)
                    store.updateSelection("Shape Gradient") { n in
                        n.fill.gradient?.stretch(to: u, in: n.frame.size)
                    }
                case .stop:
                    let (along, off) = place(g.location, a, b)
                    leaving = gradient.stops.count > 2 && off > Self.away
                    guard gradient.stops.indices.contains(session.stop) else { return }
                    let (moved, at) = gradient.stops.placing(session.stop, at: along)
                    session.stop = at
                    store.updateSelection("Move Gradient Colour") { $0.fill.gradient?.stops = moved }
                case .line: break
                }
            }
            .onEnded { g in
                defer {
                    grip = nil
                    began = false
                    leaving = false
                }
                if began { store.endGesture(grip == .stop ? "Move Gradient Colour" : "Shape Gradient") }
                if grip == .stop && leaving { remove(session.stop) }
                if grip == .line && hypot(g.translation.width, g.translation.height) < 3 { add(at: place(g.location, a, b).along) }
            }
    }

    /// Drags an end: a linear gradient's start or end, or a radial one's centre or the end of its
    /// radius, which turns and stretches it. Shift keeps the line to every fifteen degrees.
    private func moveEnd(_ start: Bool, to location: CGPoint, other: CGPoint) {
        var p = location
        if NSEvent.modifierFlags.contains(.shift) && !(start && gradient.kind == .radial) {
            let dx = p.x - other.x, dy = p.y - other.y, length = hypot(dx, dy)
            let angle = (atan2(dy, dx) / (.pi / 12)).rounded() * (.pi / 12)
            p = CGPoint(x: other.x + cos(angle) * length, y: other.y + sin(angle) * length)
        }
        let u = map.unit(p)
        store.updateSelection("Shape Gradient") { n in
            guard var g = n.fill.gradient else { return }
            switch (g.kind, start) {
            case (.linear, true): g.start = u
            case (.linear, false): g.end = u
            case (.radial, true): g.centre(at: u)
            case (.radial, false): g.turn(to: u, in: n.frame.size)
            }
            n.fill.gradient = g
        }
    }

    private func add(at offset: Double) {
        let stop = GradientStop(offset: offset, color: gradient.color(at: offset))
        let (stops, at) = (gradient.stops + [stop]).placing(gradient.stops.count, at: offset)
        session.stop = at
        store.updateSelection("Add Gradient Colour") { $0.fill.gradient?.stops = stops }
    }

    private func remove(_ i: Int) {
        guard gradient.stops.count > 2, gradient.stops.indices.contains(i) else { return }
        var stops = gradient.stops
        stops.remove(at: i)
        session.stop = max(i - 1, 0)
        store.updateSelection("Remove Gradient Colour") { $0.fill.gradient?.stops = stops }
    }
}

/// A colour on the line: a white ring round it, easy to catch, ringed in pencil when chosen.
private struct ColourPoint: View {
    let color: RGBA
    let chosen: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.3)).frame(width: size + 2, height: size + 2)
            Circle().fill(Color.white).frame(width: size, height: size)
            Swatch(color: color, radius: (size - 5) / 2).frame(width: size - 5, height: size - 5)
            if chosen {
                Circle().strokeBorder(Theme.pencil, lineWidth: 2).frame(width: size + 6, height: size + 6)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .scaleEffect(chosen ? 1.1 : 1)
    }
}

/// The point on a radial gradient's ring that widens or narrows it: small and white, as it holds
/// no colour.
private struct ShapePoint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.black.opacity(0.35), lineWidth: 1) }
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// Where a press takes hold of the handles: round each point, and along the line.
private nonisolated struct Grips: Shape {
    let points: [CGPoint]
    let reach: CGFloat
    let line: (CGPoint, CGPoint)

    func path(in rect: CGRect) -> Path {
        var round = Path()
        for p in points { round.addEllipse(in: CGRect(x: p.x - reach, y: p.y - reach, width: reach * 2, height: reach * 2)) }
        let band = Path { $0.move(to: line.0); $0.addLine(to: line.1) }.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round))
        return round.union(band)
    }
}
