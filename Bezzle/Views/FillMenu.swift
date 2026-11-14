import SwiftUI
import AppKit

extension DocumentStore {
    /// Changes the paint `target` of every selected layer, as one step named `action`. Text
    /// painted anew loses the colours its letters had of their own, so all of it shows the paint.
    func updatePaint(_ target: PaintTarget, _ action: LocalizedStringResource, _ change: @escaping (inout Fill) -> Void) {
        updatePaintOfEach(target, action) { f, _ in change(&f) }
    }

    /// The same, the change seeing each layer as it was.
    func updatePaintOfEach(_ target: PaintTarget, _ action: LocalizedStringResource, _ change: @escaping (inout Fill, Node) -> Void) {
        let path = target.path
        updateSelection(action) { n in
            // A layer without such a border is passed over, as a change to several is.
            if case .border(let slot) = target, slot >= n.slots(.border) { return }
            let was = n[keyPath: path]
            var f = was
            change(&f, n)
            guard f != was else { return }
            n[keyPath: path] = f
            if target.paintsLetters(of: n) { n.clearLetterColors() }
        }
    }

    /// Paints `target` of every selected layer with one colour or a gradient, as the fill menu's
    /// kinds do. A gradient starts from the colour there was, or keeps its colours when it only
    /// changes kind; one colour keeps the gradient's first. A picture is asked for instead, with
    /// `choosePicture`.
    func choosePaint(_ kind: FillKind, for target: PaintTarget) {
        guard kind != .picture else { return }
        updatePaintOfEach(target, kind == .solid ? "Fill with a Colour" : "Fill with a Gradient") { f, n in f.paint(as: kind, on: n) }
    }

    /// Asks for a picture and paints `target` of the selected layers with it, in place of a
    /// colour or a gradient. False when none was chosen.
    @discardableResult
    func choosePicture(for target: PaintTarget, _ action: LocalizedStringResource = "Add Picture") -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return paint(target, withPictureAt: url, action)
    }

    /// Paints `target` of the selected layers with the picture in a file, in place of a colour or
    /// a gradient, as when it is dropped on the paint's swatch. False when it is no picture.
    @discardableResult
    func paint(_ target: PaintTarget, withPictureAt url: URL, _ action: LocalizedStringResource = "Add Picture") -> Bool {
        guard target.takesPicture, let image = importPicture(url) else { return false }
        updatePaint(target, action) { f in
            f.on = true
            f.image = image
        }
        return true
    }
}

extension Gradient {
    /// The colours as SwiftUI draws them.
    var swiftUI: SwiftUI.Gradient {
        SwiftUI.Gradient(stops: stops.sorted { $0.offset < $1.offset }.map {
            SwiftUI.Gradient.Stop(color: Color(nsColor: $0.color.nsColor), location: $0.offset)
        })
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
    /// Which of the layers' paints it is: one of their fills, or of their borders.
    var target: PaintTarget = .fill(0)
    let apply: (RGBA) -> Void
    /// A picture dragged in from the Finder is over it, to paint with.
    @State private var dropping = false

    var body: some View {
        field
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.pencil, lineWidth: 2)
                    .padding(-2)
                    .opacity(dropping ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(Theme.quick, value: dropping)
            // A picture from the Finder, let go on it, paints with that picture.
            // In Animate a paint keeps its kind: what it is painted with is the design's.
            .dropDestination(for: URL.self) { urls, _ in
                guard target.takesPicture, !store.animating, let url = DocumentStore.pictureFiles(in: urls).first else { return false }
                return store.paint(target, withPictureAt: url)
            } isTargeted: { dropping = $0 && target.takesPicture && !store.animating }
    }

    @ViewBuilder private var field: some View {
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
        session.target = target
        menus.panel(FillMenu.id, size: FillMenu.size(for: FillKind(fill), keyed: store.animating)) {
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

    /// The fill or border the menu is open on, of those one over another.
    private var path: WritableKeyPath<Node, Fill> { session.target.path }

    /// `keyed`, in Animate: without the row that chooses what it is painted with.
    static func size(for kind: FillKind, keyed: Bool = false) -> CGSize {
        let kinds: CGFloat = keyed ? Theme.controlHeight + 14 : 0
        switch kind {
        case .solid: return CGSize(width: 248, height: 374 - kinds)
        case .linear, .radial: return CGSize(width: 248, height: 408 - kinds)
        case .picture: return CGSize(width: 248, height: 156)
        }
    }

    var body: some View {
        // In Animate the paint is shown as it is at the playhead, and what is chosen here is
        // keyed there (`DocumentStore.poseLooks`): its colour, or its gradient's colours and
        // their places. What it is painted with, and how many colours, is the design's.
        let keyed = store.animating
        if let first = store.lookedSelection.first {
            let kind = FillKind(first[keyPath: path])
            let gradient = kind == .picture ? nil : first[keyPath: path].gradient.flatMap { $0.stops.isEmpty ? nil : $0 }
            let chosen = gradient.map { min(session.stop, $0.stops.count - 1) }
            VStack(alignment: .leading, spacing: 0) {
                if !keyed {
                    SegmentedWell(selection: Binding(get: { kind }, set: { choose($0) }), options: FillKind.choices(with: kind, pictures: session.target.takesPicture))
                        .padding([.horizontal, .top], 14)
                }
                if let gradient, let chosen {
                    GradientBar(stops: gradient.stops, chosen: chosen, fixed: keyed, choose: { session.stop = $0 },
                                move: { move($0, to: $1, in: gradient) }, add: { add(at: $0, in: gradient) }, remove: { remove($0, in: gradient) })
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .transition(.unfold)
                }
                if kind == .picture, !keyed {
                    Text("A picture fills this. Choose a colour or a gradient to fill it with that instead.")
                        .prose(12)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                    ChipButton(title: "Choose Another Picture…") { store.choosePicture(for: session.target, "Replace Picture") }
                        .padding(.horizontal, 14)
                } else if kind != .picture {
                    // One colour and a gradient's first are the same when it turns into the other,
                    // so the picker stays as it is then. It starts again for another colour, or when
                    // one is taken off or added and another comes to have the chosen place.
                    ColorPanel(id: gradient == nil ? Self.id : "fill-stop", action: action,
                               start: gradient.map { $0.stops[chosen ?? 0].color } ?? first[keyPath: path].color,
                               key: "\(chosen ?? 0) of \(gradient?.stops.count ?? 2)") { c in
                        store.updatePaint(session.target, action) { f in
                            f.on = true
                            if let chosen, f.gradient != nil {
                                if f.gradient?.stops.indices.contains(chosen) == true { f.gradient?.stops[chosen].color = c }
                            } else {
                                f.color = c
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

    /// Fills each selected layer with one colour, a gradient or a picture. A gradient starts from
    /// the colour there was, or keeps its colours when it only changes kind; one colour keeps the
    /// first. A picture is asked for, and the fill stays as it was when none is chosen.
    private func choose(_ kind: FillKind) {
        guard kind != .picture else {
            if store.choosePicture(for: session.target) {
                withAnimation(Theme.unfold) { menus.resize(Self.id, to: Self.size(for: .picture)) }
            }
            return
        }
        session.stop = 0
        withAnimation(Theme.unfold) {
            store.choosePaint(kind, for: session.target)
            menus.resize(Self.id, to: Self.size(for: kind))
        }
    }

    /// Gives every selected gradient these colours.
    private func set(_ stops: [GradientStop], _ action: LocalizedStringResource) {
        store.updatePaint(session.target, action) { f in
            guard f.gradient != nil else { return }
            f.gradient?.stops = stops
            f.on = true
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
    /// In Animate: the colours are moved and changed, and there stay as many as the design has.
    var fixed = false
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
                    if !fixed { add(Double(min(max((p.x - Self.pin / 2) / run, 0), 1))) }
                }
                .help(fixed ? Text(verbatim: "") : Text("Click to add a colour here"))

                ForEach(stops.indices, id: \.self) { i in
                    StopPin(color: stops[i].color, chosen: i == chosen)
                        .opacity(from != nil && i == chosen && leaving ? 0.3 : 1)
                        .offset(x: stops[i].offset * run, y: -0.5)
                        .gesture(pinDrag(i, run: run))
                        .help(fixed ? Text("Drag to move this colour") : Text("Drag to move this colour, or off the bar to take it away"))
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
                leaving = !fixed && stops.count > 2 && abs(g.translation.height) > Self.away
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
    /// Which of a layer's fills or borders the menu is open on.
    var target: PaintTarget = .fill(0)
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
                  let fill = store.lookedSelection.first?[keyPath: self.target.path], fill.on, fill.image == nil,
                  let gradient = fill.gradient else { return event }
            let path = self.target.path
            // In Animate a gradient keeps the colours the design gives it: none is taken off.
            if !store.animating, gradient.stops.count > 2, gradient.stops.indices.contains(self.stop) {
                var stops = gradient.stops
                stops.remove(at: self.stop)
                self.stop = max(self.stop - 1, 0)
                store.updateSelection("Remove Gradient Colour") { n in if n[keyPath: path].gradient != nil { n[keyPath: path].gradient?.stops = stops } }
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
