import SwiftUI
import AppKit

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

    /// The kinds to choose between. A picture is only one while the layer has one.
    static func choices(with current: FillKind) -> [(FillKind, LocalizedStringResource)] {
        var choices: [(FillKind, LocalizedStringResource)] = [(.solid, "Solid"), (.linear, "Linear"), (.radial, "Radial")]
        if current == .picture { choices.append((.picture, "Picture")) }
        return choices
    }
}

extension Gradient {
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

    /// The colours as SwiftUI draws them.
    var swiftUI: SwiftUI.Gradient {
        SwiftUI.Gradient(stops: stops.sorted { $0.offset < $1.offset }.map {
            SwiftUI.Gradient.Stop(color: Color(nsColor: $0.color.nsColor), location: $0.offset)
        })
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

/// What fills a layer or an artboard, in the inspector: a swatch that opens the fill menu, where
/// everything about the fill is chosen. One colour has its hex beside it to type, and the
/// design's colours one click away; a gradient or a picture is named there.
struct FillField: View {
    @Environment(DocumentStore.self) private var store
    @Environment(MenuHost.self) private var menus
    @Environment(GradientSession.self) private var session
    /// The first selected layer's fill.
    let fill: Fill
    /// The colour every selected layer has, if they share one.
    let color: RGBA?
    let action: LocalizedStringResource
    var suggestions: [RGBA] = []
    var preview: ((RGBA?) -> Void)? = nil
    let apply: (RGBA) -> Void

    var body: some View {
        let kind = FillKind(fill)
        if kind == .solid {
            ColorField(id: FillMenu.id, color: color, suggestions: suggestions, action: action, preview: preview, picker: open, apply: apply)
        } else {
            HStack(spacing: 8) {
                FillSwatch(fill: fill)
                    .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                Text(kind == .linear ? "Linear gradient" : kind == .radial ? "Radial gradient" : "Picture")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: Theme.controlHeight, alignment: .leading)
                    .well(radius: 7)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .menuAnchor(FillMenu.id)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .debugOpenMenu)) { note in
                if note.object as? String == FillMenu.id { open() }
            }
            #endif
        }
    }

    private func open() {
        menus.panel(FillMenu.id, size: FillMenu.size(for: FillKind(fill))) {
            FillMenu(action: action)
                .environment(store)
                .environment(menus)
                .environment(session)
        }
    }
}

/// A fill as a swatch: its colour, its gradient running as it does on the layer, or the mark of
/// a picture.
struct FillSwatch: View {
    let fill: Fill
    var radius: CGFloat = 7

    var body: some View {
        if fill.image == nil && fill.gradient == nil {
            Swatch(color: fill.color, radius: radius)
        } else {
            ZStack {
                if let g = fill.gradient, fill.image == nil {
                    Checkerboard()
                    switch g.kind {
                    case .linear:
                        LinearGradient(gradient: g.swiftUI, startPoint: UnitPoint(x: g.start.x, y: g.start.y), endPoint: UnitPoint(x: g.end.x, y: g.end.y))
                    case .radial:
                        Canvas { ctx, size in
                            let spread = g.spread(in: size)
                            guard abs(spread.a * spread.d - spread.b * spread.c) > 1e-6 else { return }
                            ctx.concatenate(spread)
                            ctx.fill(Path(CGRect(origin: .zero, size: size)).applying(spread.inverted()),
                                     with: .radialGradient(g.swiftUI, center: .zero, startRadius: 0, endRadius: 1))
                        }
                    }
                } else {
                    Theme.ink.opacity(0.06)
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5)
            }
        }
    }
}

/// The fill menu, hanging from the fill's swatch: one colour, a gradient along a line or out from
/// a point, or the picture there is. One colour is picked as any colour is. A gradient lays its
/// colours on a bar, to choose, move, add and drag off, with the chosen one's colour picked under
/// it; and while the menu is open its handles are out on the canvas, to shape it there.
struct FillMenu: View {
    static let id = "fill"

    @Environment(DocumentStore.self) private var store
    @Environment(MenuHost.self) private var menus
    @Environment(GradientSession.self) private var session
    let action: LocalizedStringResource

    static func size(for kind: FillKind) -> CGSize {
        switch kind {
        case .solid: CGSize(width: 248, height: 374)
        case .linear, .radial: CGSize(width: 248, height: 408)
        case .picture: CGSize(width: 248, height: 120)
        }
    }

    var body: some View {
        if let first = store.selectedNodes.first {
            let kind = FillKind(first.fill)
            let gradient = kind == .picture ? nil : first.fill.gradient.flatMap { $0.stops.isEmpty ? nil : $0 }
            let chosen = gradient.map { min(session.stop, $0.stops.count - 1) }
            VStack(alignment: .leading, spacing: 0) {
                SegmentedWell(selection: Binding(get: { kind }, set: { choose($0) }), options: FillKind.choices(with: kind))
                    .padding([.horizontal, .top], 14)
                if let gradient, let chosen {
                    GradientBar(stops: gradient.stops, chosen: chosen, choose: { session.stop = $0 },
                                move: { move($0, to: $1, in: gradient) }, add: { add(at: $0, in: gradient) }, remove: { remove($0, in: gradient) })
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .transition(.unfold)
                }
                if kind == .picture {
                    Text("A picture fills this. Choose a colour or a gradient to fill it with that instead.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                } else {
                    // One colour and a gradient's first are the same when it turns into the other,
                    // so the picker stays as it is then. It starts again for another colour, or when
                    // one is taken off or added and another comes to have the chosen place.
                    ColorPanel(id: gradient == nil ? Self.id : "fill-stop", action: action,
                               start: gradient.map { $0.stops[chosen ?? 0].color } ?? first.fill.color,
                               key: "\(chosen ?? 0) of \(gradient?.stops.count ?? 2)") { c in
                        store.updateSelection(action) { n in
                            n.fill.on = true
                            if let chosen, n.fill.gradient != nil {
                                if n.fill.gradient?.stops.indices.contains(chosen) == true { n.fill.gradient?.stops[chosen].color = c }
                            } else {
                                n.fill.color = c
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                session.stop = 0
                session.watchKeys()
            }
            .onDisappear { session.stopWatchingKeys() }
        }
    }

    /// Fills each selected layer with one colour or a gradient. A gradient starts from the colour
    /// there was, or keeps its colours when it only changes kind; one colour keeps the first.
    private func choose(_ kind: FillKind) {
        guard kind != .picture else { return }
        session.stop = 0
        withAnimation(Theme.unfold) {
            store.updateSelection(kind == .solid ? "Fill with a Colour" : "Fill with a Gradient") { n in
                n.fill.on = true
                switch kind {
                case .solid:
                    if let first = n.fill.gradient?.stops.first { n.fill.color = first.color }
                    n.fill.gradient = nil
                    n.fill.image = nil
                case .linear, .radial:
                    let was = n.fill.gradient?.kind
                    var g = n.fill.gradient ?? .fading(from: n.fill.color)
                    g.kind = kind == .radial ? .radial : .linear
                    if g.kind == .radial && was != .radial {
                        g.start = CGPoint(x: 0.5, y: 0.5)
                        g.radius = 0.5
                        g.across = nil
                    } else if g.kind == .linear && was != .linear {
                        g.aim(180, in: n.frame.size)
                        g.across = nil
                    }
                    n.fill.gradient = g
                    n.fill.image = nil
                case .picture:
                    break
                }
            }
            menus.resize(Self.id, to: Self.size(for: kind))
        }
    }

    /// Gives every selected gradient these colours.
    private func set(_ stops: [GradientStop], _ action: LocalizedStringResource) {
        store.updateSelection(action) { n in
            guard n.fill.gradient != nil else { return }
            n.fill.gradient?.stops = stops
            n.fill.on = true
        }
    }

    private func move(_ index: Int, to offset: Double, in gradient: Gradient) {
        guard gradient.stops.indices.contains(index) else { return }
        let (moved, at) = gradient.stops.placing(index, at: offset)
        session.stop = at
        set(moved, "Move Gradient Colour")
    }

    private func add(at offset: Double, in gradient: Gradient) {
        let stop = GradientStop(offset: offset, color: gradient.color(at: offset))
        let (stops, at) = (gradient.stops + [stop]).placing(gradient.stops.count, at: offset)
        session.stop = at
        set(stops, "Add Gradient Colour")
    }

    private func remove(_ index: Int, in gradient: Gradient) {
        guard gradient.stops.count > 2, gradient.stops.indices.contains(index) else { return }
        var stops = gradient.stops
        stops.remove(at: index)
        session.stop = max(index - 1, 0)
        set(stops, "Remove Gradient Colour")
    }
}

/// The gradient laid out on a bar, with its stops on it.
private struct GradientBar: View {
    @Environment(DocumentStore.self) private var store
    let stops: [GradientStop]
    let chosen: Int
    let choose: (Int) -> Void
    let move: (Int, Double) -> Void
    let add: (Double) -> Void
    let remove: (Int) -> Void

    static let pin: CGFloat = 16
    /// How far off the bar a stop is dragged to take it away.
    static let away: CGFloat = 22
    /// Where the stop being dragged set out from. While it moves it stays the chosen one, even
    /// as it passes others and its place in the order changes.
    @State private var from: Double?
    @State private var leaving = false

    var body: some View {
        GeometryReader { geo in
            // The colours run between the stops' centres, so a stop at an end sits over the end.
            let run = max(geo.size.width - Self.pin, 1)
            ZStack(alignment: .topLeading) {
                ZStack {
                    Checkerboard(square: 4)
                    // Out past the end stops' centres it keeps their colours, to the bar's ends.
                    LinearGradient(stops: stops.sorted { $0.offset < $1.offset }.map {
                        SwiftUI.Gradient.Stop(color: Color(nsColor: $0.color.nsColor), location: (Self.pin / 2 + $0.offset * run) / max(geo.size.width, 1))
                    }, startPoint: .leading, endPoint: .trailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5) }
                .frame(height: 14)
                .padding(.top, 1)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    add(Double(min(max((p.x - Self.pin / 2) / run, 0), 1)))
                }
                .help("Click to add a colour here")

                ForEach(stops.indices, id: \.self) { i in
                    StopPin(color: stops[i].color, chosen: i == chosen)
                        .opacity(from != nil && i == chosen && leaving ? 0.3 : 1)
                        .offset(x: stops[i].offset * run, y: -0.5)
                        .gesture(pinDrag(i, run: run))
                        .help("Drag to move this colour, or off the bar to take it away")
                }
            }
        }
        .frame(height: Self.pin)
        .padding(.vertical, 2)
    }

    private func pinDrag(_ i: Int, run: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                if from == nil {
                    guard stops.indices.contains(i) else { return }
                    from = stops[i].offset
                    choose(i)
                    store.beginGesture()
                }
                guard let from else { return }
                leaving = stops.count > 2 && abs(g.translation.height) > Self.away
                if g.translation.width != 0 { move(chosen, from + Double(g.translation.width / run)) }
            }
            .onEnded { _ in
                store.endGesture("Move Gradient Colour")
                if leaving { remove(chosen) }
                from = nil
                leaving = false
            }
    }
}

/// One stop on the bar, or hanging off the line on the canvas: a swatch of its colour with a
/// light rim, ringed in pencil when chosen.
struct StopPin: View {
    let color: RGBA
    let chosen: Bool

    var body: some View {
        Swatch(color: color, radius: 4)
            .frame(width: GradientBar.pin, height: GradientBar.pin)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(chosen ? Theme.pencil : Theme.card, lineWidth: chosen ? 2 : 1.5)
            }
            .shadow(color: Theme.shadow.opacity(0.22), radius: 1.5, y: 1)
            .contentShape(Rectangle())
            .animation(Theme.quick, value: chosen)
    }
}

/// Which of the gradient's colours is chosen, shared by the fill menu's bar and the handles on
/// the canvas so a colour chosen in one is chosen in the other; and where the handles are, so a
/// click on them leaves the menu open.
@Observable
final class GradientSession {
    var stop = 0
    @ObservationIgnored weak var store: DocumentStore?
    @ObservationIgnored weak var menus: MenuHost? {
        didSet { menus?.spares = { [weak self] p in self?.holds(p) ?? false } }
    }
    /// The handles' points and the line between its ends, in the window from its top left.
    @ObservationIgnored var handles: (points: [CGPoint], line: (CGPoint, CGPoint))?
    @ObservationIgnored private var keys: Any?

    /// Whether a click at `p` in the window, from its top left, falls on the handles.
    func holds(_ p: CGPoint) -> Bool {
        guard menus?.open?.id == FillMenu.id, let handles else { return false }
        if handles.points.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 13 }) { return true }
        let (a, b) = handles.line
        let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
        let t = length2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2, 0), 1) : 0
        return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)) < 7
    }

    /// While the fill menu is open on a gradient, Delete takes off the chosen colour rather than
    /// the layer, which a slip of the hand would otherwise do.
    func watchKeys() {
        if keys != nil { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 51 || event.keyCode == 117, self.menus?.open?.id == FillMenu.id,
                  !(event.window?.firstResponder is NSText), let store = self.store,
                  let fill = store.selectedNodes.first?.fill, fill.image == nil, let gradient = fill.gradient else { return event }
            if gradient.stops.count > 2, gradient.stops.indices.contains(self.stop) {
                var stops = gradient.stops
                stops.remove(at: self.stop)
                self.stop = max(self.stop - 1, 0)
                store.updateSelection("Remove Gradient Colour") { n in if n.fill.gradient != nil { n.fill.gradient?.stops = stops } }
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stopWatchingKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }
}
