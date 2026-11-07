import Foundation
import WinSDK
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// A gradient's handles over the canvas, where the layer is, out while its fill menu is open, as
/// the Mac's GradientHandles (Views/GradientHandles.swift) shows them. A gradient along a line
/// shows the line between its ends; one spreading from a point shows the radius out from that
/// point, and the ellipse it spreads to, with a point on it square to the radius. Its colours are
/// points on the line: the ends are the first and last, and the ones between can be dragged along,
/// or away to take them off. Click one to pick its colour in the menu, and the line to add one
/// there. Drag an end to turn and stretch the gradient, or the centre to move it; the point on the
/// ellipse square to the radius makes it wider or narrower, and the one at the corner of the
/// square the ellipse sits in sizes it both ways at once, Shift keeping its shape. That square is
/// never drawn: only its two sides from the corner, fading out on their way to the ellipse, and
/// running on to touch it while the corner is pointed at or dragged. Shift keeps the line to every
/// fifteen degrees.
///
/// They lie in the menus' layer, over what catches presses round an open menu, so a press on
/// them leaves the menu open; anywhere else the menu closes as ever.
@MainActor
final class GradientHandles {
    typealias Stop = WindowsCore.Stop

    /// Over the canvas, where it is in the window: the handles, and what takes presses on them.
    let layer = Canvas()
    private let marks = Canvas()
    /// Where a press takes hold: round each point, along the line, and the corner, which shows
    /// the pointer a layer's corner does.
    private let grips = WinUI.Path()
    private let band = WinUI.Path()
    private let cornerGrip = WinUI.Path()
    private let clip = RectangleGeometry()
    private let session: DesignSession

    /// Whether a menu is open: the handles show only while the fill menu is.
    var menuOpen: () -> Bool = { false }
    /// From the canvas to the stage, and back.
    var toStage: (CGPoint) -> CGPoint = { $0 }
    var toCanvas: (CGPoint) -> CGPoint = { $0 }
    /// Where the canvas lies in the menus' layer.
    var canvasPlace: () -> CGRect? = { nil }

    private var look: WindowsCore.GradientLook?
    private var target: DesignSession.FillMenuTarget?
    private var id: UUID?

    private enum Grip: Equatable { case start, end, across, corner, stop, line }
    /// What the press being dragged took hold of.
    private var grip: Grip?
    private var began = false
    private var leaving = false
    private var pressAt = CGPoint.zero
    /// How far from the corner the press was, so the corner keeps that distance from the pointer.
    private var grabbed = CGSize.zero
    /// The colours as the press found them, and which was taken, for a colour moved along.
    private var held: (stops: [Stop], index: Int)?
    private var onCorner = false
    /// How far the corner's two sides run toward the ring, 0.36 at rest and all the way while the
    /// corner is pointed at or dragged, on the Mac's Theme.spring (response 0.34, damping 0.86).
    private var reach = DeckSpring(0.36)
    private var ticking: EventCleanup?
    private var lastTick = 0.0

    /// How near a point a press takes hold of it.
    static let reachDistance = 12.0
    /// How far off the line a colour is dragged to take it off.
    static let away = 30.0
    /// Colours this near an end are shown by the end's own point.
    static let atEnd = 0.001

    init(session: DesignSession) {
        self.session = session
        layer.visibility = .collapsed
        layer.clip = clip
        marks.isHitTestVisible = false
        layer.children.append(marks)
        grips.fill = Theme.clear
        band.stroke = Theme.clear
        band.strokeThickness = 12
        band.strokeStartLineCap = .round
        band.strokeEndLineCap = .round
        cornerGrip.fill = Theme.clear
        cornerGrip.protectedCursor = Pointer.resize(45).cursor
        for e in [band, grips, cornerGrip] {
            layer.children.append(e)
            e.pointerPressed.addHandler { [weak self] sender, args in self?.pressed(sender as? UIElement, args) }
            e.pointerMoved.addHandler { [weak self] _, args in self?.moved(args) }
            e.pointerReleased.addHandler { [weak self] sender, args in self?.released(sender as? UIElement, args) }
            e.pointerCaptureLost.addHandler { [weak self] _, _ in self?.lost() }
        }
        cornerGrip.pointerEntered.addHandler { [weak self] _, _ in self?.setOnCorner(true) }
        cornerGrip.pointerExited.addHandler { [weak self] _, _ in self?.setOnCorner(false) }
    }

    // MARK: Where things are

    /// From the layer's own box, 0…1 across and down as a gradient measures it, to the stage,
    /// turned as the layer is.
    private func view(_ u: CGPoint, _ l: WindowsCore.GradientLook) -> CGPoint {
        let x = (Double(u.x) - 0.5) * Double(l.frame.width), y = (Double(u.y) - 0.5) * Double(l.frame.height)
        let r = l.rotation * .pi / 180
        return toStage(CGPoint(x: Double(l.frame.midX) + x * cos(r) - y * sin(r), y: Double(l.frame.midY) + x * sin(r) + y * cos(r)))
    }

    private func unit(_ v: CGPoint, _ l: WindowsCore.GradientLook) -> CGPoint {
        let p = toCanvas(v)
        let x = Double(p.x) - Double(l.frame.midX), y = Double(p.y) - Double(l.frame.midY)
        let r = -l.rotation * .pi / 180
        return CGPoint(x: (x * cos(r) - y * sin(r)) / max(Double(l.frame.width), 0.001) + 0.5,
                       y: (x * sin(r) + y * cos(r)) / max(Double(l.frame.height), 0.001) + 0.5)
    }

    /// The line the colours lie along: from start to end, or from the centre out to the radius's end.
    private func ends(_ l: WindowsCore.GradientLook) -> (CGPoint, CGPoint) { (view(l.start, l), view(l.end, l)) }

    /// The colours that have points of their own between the ends.
    private func between(_ l: WindowsCore.GradientLook) -> [Int] {
        l.stops.indices.filter { l.stops[$0].offset > Self.atEnd && l.stops[$0].offset < 1 - Self.atEnd }
    }

    /// The first colour along the line and the last, which the ends stand for.
    private func first(_ l: WindowsCore.GradientLook) -> Int { l.stops.indices.min { l.stops[$0].offset < l.stops[$1].offset } ?? 0 }
    private func last(_ l: WindowsCore.GradientLook) -> Int { l.stops.indices.max { l.stops[$0].offset < l.stops[$1].offset } ?? 0 }

    private func on(_ offset: Double, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: Double(a.x) + Double(b.x - a.x) * offset, y: Double(a.y) + Double(b.y - a.y) * offset)
    }

    /// How far along the line a point on the stage falls, and how far off it.
    private func place(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (along: Double, off: Double) {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y), length2 = dx * dx + dy * dy
        let px = Double(p.x - a.x), py = Double(p.y - a.y)
        guard length2 > 0.25 else { return (0, hypot(px, py)) }
        let t = (px * dx + py * dy) / length2
        let off = abs(px * dy - py * dx) / sqrt(length2)
        return (min(max(t, 0), 1), off)
    }

    private func dots(_ l: WindowsCore.GradientLook) -> [(index: Int, at: CGPoint)] {
        let (a, b) = ends(l)
        return between(l).map { ($0, on(l.stops[$0].offset, a, b)) }
    }

    // MARK: Showing them

    /// Shows the handles as the gradient now is, or takes them away when the fill menu is shut,
    /// or not on one layer's gradient.
    func draw() {
        let t = session.fillMenu
        var shown: WindowsCore.GradientLook?
        if let t, menuOpen(), session.selection.count == 1, let id = session.selection.first {
            shown = WindowsCore.gradientLook(id, border: t.border, slot: t.slot)
            self.id = id
        }
        target = t
        look = shown
        marks.children.clear()
        guard let l = shown, let place = canvasPlace() else {
            layer.visibility = .collapsed
            if grip != nil { lost() }
            return
        }
        try? Canvas.setLeft(layer, Double(place.minX))
        try? Canvas.setTop(layer, Double(place.minY))
        layer.width = Double(place.width)
        layer.height = Double(place.height)
        clip.rect = Rect(x: 0, y: 0, width: Float(place.width), height: Float(place.height))
        layer.visibility = .visible

        let (a, b) = ends(l)
        let stops = l.stops
        let chosen = min(session.gradientStop, stops.count - 1)
        let side = l.side.map { view($0, l) }
        let corner = l.corner.map { view($0, l) }
        let dots = dots(l)
        // The chosen colour, when it is at an end, is ringed there.
        let endChosen: Int? = stops[chosen].offset <= Self.atEnd ? 0 : stops[chosen].offset >= 1 - Self.atEnd ? 1 : nil

        if l.radial {
            ring(l)
            if let corner, let side { tangents(corner: corner, edge: b, side: side) }
        }
        // The line, white over a dark edge so it shows over any colour beneath.
        stroke([a, b], brush: Theme.brush(0, 0.32), width: 3.5, round: true)
        stroke([a, b], brush: Theme.brush(0xFFFFFF), width: 1.5, round: true)
        if let side { shapePoint(side) }
        if let corner { shapePoint(corner) }
        colourPoint(WindowsCore.gradientColour(stops, at: 0), at: a, chosen: endChosen == 0, size: 16)
        colourPoint(WindowsCore.gradientColour(stops, at: 1), at: b, chosen: endChosen == 1, size: 16)
        for dot in dots {
            colourPoint(stops[dot.index].colour, at: dot.at, chosen: dot.index == chosen, size: 13,
                        faded: dot.index == chosen && leaving)
        }

        // Where presses take hold.
        let points = [a, b] + (side.map { [$0] } ?? []) + (corner.map { [$0] } ?? []) + dots.map(\.at)
        grips.data = geometry(points.map { circle($0, Self.reachDistance) }, closed: true)
        band.data = geometry([[a, b]], closed: false)
        if let corner {
            cornerGrip.data = geometry([circle(corner, Self.reachDistance)], closed: true)
            cornerGrip.visibility = .visible
        } else {
            cornerGrip.visibility = .collapsed
            if onCorner { setOnCorner(false) }
        }
    }

    /// How far a radial gradient spreads, drawn round its centre: dashed white over a dark edge.
    private func ring(_ l: WindowsCore.GradientLook) {
        guard let side = l.side else { return }
        let c = l.start, e = l.end
        let points = (0...72).map { k -> CGPoint in
            let angle = Double(k) / 72 * 2 * .pi
            let u = CGPoint(x: Double(c.x) + cos(angle) * Double(e.x - c.x) + sin(angle) * Double(side.x - c.x),
                            y: Double(c.y) + cos(angle) * Double(e.y - c.y) + sin(angle) * Double(side.y - c.y))
            return view(u, l)
        }
        stroke(points, brush: Theme.brush(0, 0.3), width: 2.5)
        let dashed = stroke(points, brush: Theme.brush(0xFFFFFF), width: 1)
        let dashes = DoubleCollection()
        dashes.append(4)
        dashes.append(3)
        dashed.strokeDashArray = dashes
    }

    /// The corner's tie to the ring: the two sides of the square the ring sits in, from the corner
    /// toward where they touch the ring. Resting, only their start shows, fading as it goes;
    /// pointed at or dragged, they run on all the way to the two points.
    private func tangents(corner: CGPoint, edge: CGPoint, side: CGPoint) {
        let k = reach.value
        // Faintest at the far end: fading out short of the ring at rest, just there once out to it.
        let far = 0.05 + 0.4 * min(max((k - 0.36) / 0.64, 0), 1)
        let pieces = 10
        for p in [edge, side] {
            let end = CGPoint(x: Double(corner.x) + Double(p.x - corner.x) * k, y: Double(corner.y) + Double(p.y - corner.y) * k)
            guard hypot(Double(end.x - corner.x), Double(end.y - corner.y)) > 0.5 else { continue }
            // Faded along the way in pieces, each as strong as the way is at its middle.
            for (ink, top, width) in [(0x000000 as UInt32, 0.28, 3.0), (0xFFFFFF as UInt32, 1.0, 1.25)] {
                for i in 0..<pieces {
                    let t0 = Double(i) / Double(pieces), t1 = Double(i + 1) / Double(pieces), mid = (t0 + t1) / 2
                    let alpha = top * (1 - mid * (1 - far))
                    let from = on(t0, corner, end), to = on(t1, corner, end)
                    let line = stroke([from, to], brush: Theme.brush(ink, alpha), width: width)
                    if i == 0 { line.strokeStartLineCap = .round }
                    if i == pieces - 1 { line.strokeEndLineCap = .round }
                }
            }
        }
    }

    /// A colour on the line: a white ring round it, easy to catch, ringed in pencil when chosen.
    private func colourPoint(_ c: WindowsCore.Colour, at p: CGPoint, chosen: Bool, size: Double, faded: Bool = false) {
        let s = size * (chosen ? 1.1 : 1)
        let group = Canvas()
        group.opacity = faded ? 0.3 : 1
        func disc(_ d: Double, _ brush: Brush, dy: Double = 0) {
            let e = Ellipse()
            e.width = d
            e.height = d
            e.fill = brush
            try? Canvas.setLeft(e, Double(p.x) - d / 2)
            try? Canvas.setTop(e, Double(p.y) - d / 2 + dy)
            group.children.append(e)
        }
        // A soft shadow under it, then a dark rim, so it shows over any colour.
        disc(s + 5, Theme.brush(0, 0.07), dy: 1)
        disc(s + 3, Theme.brush(0, 0.12), dy: 1)
        disc(s + 2, Theme.brush(0, 0.3))
        disc(s, Theme.brush(0xFFFFFF))
        let inner = s - 5
        let swatch = Colours.swatch(c, size: inner, radius: inner / 2)
        try? Canvas.setLeft(swatch, Double(p.x) - inner / 2)
        try? Canvas.setTop(swatch, Double(p.y) - inner / 2)
        group.children.append(swatch)
        if chosen {
            let ring = Ellipse()
            ring.width = s + 6
            ring.height = s + 6
            ring.stroke = Theme.brush(Theme.pencil)
            ring.strokeThickness = 2
            try? Canvas.setLeft(ring, Double(p.x) - (s + 6) / 2)
            try? Canvas.setTop(ring, Double(p.y) - (s + 6) / 2)
            group.children.append(ring)
        }
        marks.children.append(group)
    }

    /// A point on a radial gradient that shapes it, widening it or sizing it: small and white, as
    /// it holds no colour, a square stood on its corner.
    private func shapePoint(_ p: CGPoint) {
        for (size, fill, stroke, dy) in [(10.5, Theme.brush(0, 0.16), nil as Brush?, 0.5), (9.0, Theme.brush(0xFFFFFF), Theme.brush(0, 0.35), 0.0)] {
            let r = Rectangle()
            r.width = size
            r.height = size
            r.radiusX = 2
            r.radiusY = 2
            r.fill = fill
            if let stroke {
                r.stroke = stroke
                r.strokeThickness = 1
            }
            let turn = CompositeTransform()
            turn.rotation = 45
            turn.centerX = size / 2
            turn.centerY = size / 2
            r.renderTransform = turn
            try? Canvas.setLeft(r, Double(p.x) - size / 2)
            try? Canvas.setTop(r, Double(p.y) - size / 2 + dy)
            marks.children.append(r)
        }
    }

    @discardableResult
    private func stroke(_ points: [CGPoint], brush: Brush, width: Double, round: Bool = false) -> WinUI.Path {
        let path = WinUI.Path()
        path.data = geometry([points], closed: false)
        path.stroke = brush
        path.strokeThickness = width
        path.strokeLineJoin = .round
        if round {
            path.strokeStartLineCap = .round
            path.strokeEndLineCap = .round
        }
        marks.children.append(path)
        return path
    }

    private func circle(_ c: CGPoint, _ r: Double) -> [CGPoint] {
        (0..<20).map { k in
            let a = Double(k) / 20 * 2 * .pi
            return CGPoint(x: Double(c.x) + cos(a) * r, y: Double(c.y) + sin(a) * r)
        }
    }

    private func geometry(_ figures: [[CGPoint]], closed: Bool) -> PathGeometry {
        let g = PathGeometry()
        for points in figures {
            guard let first = points.first else { continue }
            let figure = PathFigure()
            figure.startPoint = Point(x: Float(first.x), y: Float(first.y))
            figure.isClosed = closed
            figure.isFilled = closed
            for p in points.dropFirst() {
                let segment = LineSegment()
                segment.point = Point(x: Float(p.x), y: Float(p.y))
                figure.segments.append(segment)
            }
            g.figures.append(figure)
        }
        return g
    }

    // MARK: The corner pointed at

    private func setOnCorner(_ on: Bool) {
        guard on != onCorner else { return }
        onCorner = on
        aimReach()
    }

    /// The corner's sides run out to the ring while it is pointed at or dragged, and back after.
    private func aimReach() {
        reach.target = onCorner || grip == .corner ? 1 : 0.36
        guard ticking == nil, !reach.settled else { return }
        lastTick = WindowsCore.now
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = WindowsCore.now
                let dt = min(max(now - self.lastTick, 1.0 / 240), 1.0 / 20)
                self.lastTick = now
                self.reach.step(dt, stiffness: 341, damping: 31.8)
                self.draw()
                if self.reach.settled {
                    self.ticking?.dispose()
                    self.ticking = nil
                }
            }
        }
    }

    // MARK: The pointer

    /// What a press near `p` takes hold of: a colour between the ends first, as they lie on the
    /// line, then an end or a point on the ring, then the line.
    private func hold(at p: CGPoint, _ l: WindowsCore.GradientLook) -> (Grip, Int?)? {
        func near(_ q: CGPoint) -> Double { hypot(Double(q.x - p.x), Double(q.y - p.y)) }
        let (a, b) = ends(l)
        if let dot = dots(l).min(by: { near($0.at) < near($1.at) }), near(dot.at) <= Self.reachDistance { return (.stop, dot.index) }
        var points: [(Grip, CGPoint)] = [(.start, a), (.end, b)]
        if let side = l.side { points.append((.across, view(side, l))) }
        if let corner = l.corner { points.append((.corner, view(corner, l))) }
        if let point = points.min(by: { near($0.1) < near($1.1) }), near(point.1) <= Self.reachDistance { return (point.0, nil) }
        return place(p, a, b).off <= 6 ? (.line, nil) : nil
    }

    private func position(_ args: PointerRoutedEventArgs?) -> CGPoint? {
        guard let q = try? args?.getCurrentPoint(layer)?.position else { return nil }
        return CGPoint(x: Double(q.x), y: Double(q.y))
    }

    private func pressed(_ sender: UIElement?, _ args: PointerRoutedEventArgs?) {
        args?.handled = true
        guard grip == nil, let l = look, let p = position(args), let taken = hold(at: p, l) else { return }
        _ = try? sender?.capturePointer(args?.pointer)
        grip = taken.0
        pressAt = p
        began = false
        leaving = false
        held = nil
        let was = session.gradientStop
        switch taken.0 {
        case .start: session.gradientStop = first(l)
        case .end: session.gradientStop = last(l)
        case .stop:
            let index = taken.1 ?? session.gradientStop
            session.gradientStop = index
            held = (l.stops, index)
        case .corner:
            if let corner = l.corner {
                let c = view(corner, l)
                grabbed = CGSize(width: Double(p.x - c.x), height: Double(p.y - c.y))
            }
            aimReach()
        case .across, .line: break
        }
        // Another colour chosen: the menu shows that one's.
        if session.gradientStop != was { refreshMenu(panelToo: true) }
        draw()
    }

    /// What the menu has to make again, once this event is over: its colour panel too, or only its bar.
    private var refreshing: Bool?

    /// The fill menu made again after the event that changed the gradient (never inside it), its
    /// colour panel too when another colour is chosen.
    private func refreshMenu(panelToo: Bool) {
        let was = refreshing
        refreshing = (was ?? false) || panelToo
        guard was == nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.refreshing else { return }
                self.refreshing = nil
                self.session.refreshFillMenu?(panel)
            }
        }
    }

    private func moved(_ args: PointerRoutedEventArgs?) {
        guard let grip, grip != .line, let l = look, let t = target, let id, let p = position(args) else { return }
        guard p != pressAt else { return }
        if !began {
            began = true
            WindowsCore.beginGesture()
        }
        let shift = GetKeyState(Int32(VK_SHIFT)) < 0
        let (a, b) = ends(l)
        switch grip {
        case .start, .end:
            var q = p
            let other = grip == .start ? b : a
            // Shift keeps the line to every fifteen degrees; a radial gradient's centre moves freely.
            if shift, !(grip == .start && l.radial) {
                let dx = Double(q.x - other.x), dy = Double(q.y - other.y), length = hypot(dx, dy)
                let angle = (atan2(dy, dx) / (.pi / 12)).rounded() * (.pi / 12)
                q = CGPoint(x: Double(other.x) + cos(angle) * length, y: Double(other.y) + sin(angle) * length)
            }
            let u = unit(q, l)
            WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, grip == .start ? .start(u) : .end(u))
        case .across:
            WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, .across(unit(p, l)))
        case .corner:
            let u = unit(CGPoint(x: Double(p.x) - grabbed.width, y: Double(p.y) - grabbed.height), l)
            WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, .corner(u, keepingShape: shift))
        case .stop:
            guard let held, held.stops.indices.contains(held.index) else { return }
            let (along, off) = place(p, a, b)
            leaving = held.stops.count > 2 && off > Self.away
            let (moved, at) = WindowsCore.placing(held.stops, held.index, at: along)
            let was = session.gradientStop
            session.gradientStop = at
            WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, .stops(moved))
            refreshMenu(panelToo: at != was)
        case .line:
            return
        }
        session.edited(board: t.board)
    }

    private func released(_ sender: UIElement?, _ args: PointerRoutedEventArgs?) {
        guard let g = grip else { return }
        args?.handled = true
        let p = position(args) ?? pressAt
        // Finished first, so the capture let go of after it finds nothing held.
        finish(g, at: p)
        try? sender?.releasePointerCapture(args?.pointer)
    }

    /// The press is over: what it began ends as one step; a colour dragged away is taken off,
    /// and a click on the line adds one there.
    private func finish(_ g: Grip, at p: CGPoint) {
        grip = nil
        let wasLeaving = leaving
        leaving = false
        grabbed = .zero
        held = nil
        if began {
            began = false
            WindowsCore.endGesture()
            session.edited(board: target?.board)
        }
        if g == .stop && wasLeaving { remove(session.gradientStop) }
        if g == .line, hypot(Double(p.x - pressAt.x), Double(p.y - pressAt.y)) < 3, let l = look {
            let (a, b) = ends(l)
            add(at: place(p, a, b).along)
        }
        aimReach()
        draw()
    }

    /// The press was lost without a release (another window came up): ended where it was.
    private func lost() {
        guard let g = grip else { return }
        finish(g, at: pressAt)
    }

    private func add(at offset: Double) {
        guard let l = look, let t = target, let id else { return }
        let stop = Stop(offset: offset, colour: WindowsCore.gradientColour(l.stops, at: offset))
        let (stops, at) = WindowsCore.placing(l.stops + [stop], l.stops.count, at: offset)
        session.gradientStop = at
        WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, .stops(stops))
        refreshMenu(panelToo: true)
        session.edited(board: t.board)
    }

    private func remove(_ i: Int) {
        guard let t = target, let id, let l = WindowsCore.gradientLook(id, border: t.border, slot: t.slot),
              l.stops.count > 2, l.stops.indices.contains(i) else { return }
        var stops = l.stops
        stops.remove(at: i)
        session.gradientStop = max(i - 1, 0)
        WindowsCore.shapeGradient([id], border: t.border, slot: t.slot, .stops(stops))
        refreshMenu(panelToo: true)
        session.edited(board: t.board)
    }

    /// Delete while the fill menu is open on a gradient takes off the chosen colour rather than
    /// the layer, which a slip of the hand would otherwise do. False when it is not on one (the
    /// key is the menu's then), or has only two colours left (a beep).
    func deleteKey() -> Bool {
        guard let l = look, target != nil else { return false }
        if l.stops.count > 2, l.stops.indices.contains(session.gradientStop) {
            remove(session.gradientStop)
        } else {
            MessageBeep(0)
        }
        return true
    }
}
