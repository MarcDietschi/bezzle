import SwiftUI
import AppKit

/// The selected pictures' development, as a card: folded, a small picture of their tones and what
/// has been done in a word or two ("Brighter · Warmer"); its sideways drag takes the whole of it
/// from nothing to twice as much, and from an untouched picture, to as much again of what would
/// suit it best. Pulled past nothing, the picture is as it was taken.
///
/// Open, the picture's own tones lie across the top as a landscape, to drag sideways where it is
/// dark or light; under them, its light, its colour or its detail. Its colour is a ring of eight
/// colours around a cloud of the picture's own, each dragged round to turn its hue and out for
/// more of it. Pointing at a tone or a colour shows on the canvas what of the picture it changes,
/// the rest fading; and while the card is open, the picture itself is the control: dragged up or
/// down where it is dark or light, or where it is some colour. See `DevelopTool`.
struct PhotoCard: View {
    let store: DocumentStore
    let nodes: [Node]
    var live = false

    @State private var reader = LookReader()
    /// The tones as a drag began, faintly behind them while it goes on.
    @State private var ghost: [Double]?
    /// The tone or colour the pointer is on in the card, and which of the tones and the wheel
    /// last said so, for each to take back only its own.
    @State private var hovered: Develop.Isolation?
    @State private var onTones: Develop.Isolation?
    @State private var onWheel: Develop.Isolation?
    /// Whether Option is held: the canvas then shows only the part of the picture pointed at.
    @State private var peeking = false
    /// How much of the development there is while the folded card is dragged, as a share of
    /// what there was as the drag began.
    @State private var strength: Double?

    private var look: PictureLook? { reader.look }
    private var first: Node { nodes[0] }
    private var develop: Develop { first.fill.image?.develop ?? Develop() }

    private struct LookKey: Equatable {
        let picture: String?
        let develop: Develop?
    }

    var body: some View {
        let d = develop
        let developments = nodes.map { $0.fill.image?.develop }
        let alike = Set(developments).count == 1
        let neutral = developments.allSatisfy { $0 == nil }
        let summary = !alike ? SelectionInspector.several
            : d.isNeutral ? String(localized: "Original")
            : d.words.map { String(localized: $0) }.joined(separator: " · ")
        // Only with Option: shown at a mere pointing, the picture going grey under every row the
        // pointer crossed, and right after each drag, hid what the drag had done.
        let alone: Develop.Isolation? = peeking ? hovered ?? store.developPointed : nil
        AspectCard(aspect: .photo, title: "Photo", summary: summary, dial: strengthDial(neutral: neutral),
                   remove: neutral ? nil : { store.resetDevelop() }, removal: "Back to the original", live: live,
                   accessory: AnyView(AutoButton { store.autoDevelop() })) {
            ToneGlyph(tones: look?.tones)
        } picks: {
            VStack(alignment: .leading, spacing: 10) {
                ToneTerrain(look: look, ghost: ghost, develop: d, pointed: store.developPointed.flatMap { if case .tone(let s) = $0 { s } else { nil } },
                            begin: begin, change: { s, v in
                    store.develop(s.title) { $0[s] = v }
                }, end: { s in end(s.title) }, point: { s in
                    let now = s.flatMap { $0.isTone ? Develop.Isolation.tone($0) : nil }
                    hover(now, leaving: onTones)
                    onTones = now
                })
                HStack(spacing: 8) {
                    SegmentedWell(selection: Binding(get: { store.developGroup }, set: { g in
                        withAnimation(Theme.unfold) { store.developGroup = g }
                    }), options: Develop.Group.allCases.map { ($0, $0.title) })
                    TargetButton(on: store.developOnPhoto, enabled: store.developGroup != .detail) {
                        store.developOnPhoto.toggle()
                    }
                    CompareButton { store.showOriginal($0) }
                }
                Group {
                    switch store.developGroup {
                    case .light: rows(Develop.Group.light.settings)
                    case .color: colorPart(d)
                    case .detail: rows(Develop.Group.detail.settings)
                    }
                }
                // The one going shuts as the next opens, so the card never holds both at once.
                .transition(.unfold)
                Caption(caption)
                    .padding(.top, 2)
                    .animation(nil, value: store.developOnPhoto)
            }
            .animation(Theme.unfold, value: store.developGroup)
        }
        .onChange(of: LookKey(picture: first.fill.image?.shown, develop: first.fill.image?.develop), initial: true) {
            reader.read(store.developSource(first), first.fill.image?.develop)
        }
        .onChange(of: alone) { _, part in store.showIsolated(part) }
        .onChange(of: store.inGesture) { _, going in if !going { strength = nil } }
        .onChange(of: store.openAspect) { _, open in
            guard open != .photo else { return }
            store.developOnPhoto = false
            hovered = nil
        }
        // What the pointer was on, on the picture, is no longer pointed at once the picture stops
        // being the control.
        .onChange(of: store.developOnPhoto) { _, on in if !on { store.developPointed = nil } }
        .onChange(of: store.developGroup) { store.developPointed = nil }
        .onModifierKeysChanged(mask: .option) { _, keys in peeking = keys.contains(.option) }
        .onDisappear {
            store.developOnPhoto = false
            store.developPointed = nil
            store.showIsolated(nil)
        }
        .task { await Task.detached(priority: .utility) { Developer.warmUp() }.value }
    }

    private var caption: LocalizedStringResource {
        switch store.developGroup {
        case .detail: "Detail is best judged close up: zoom in on the photo."
        case .light where store.developOnPhoto: "Drag up or down on the photo to lighten or darken the tones under the pointer."
        case .color where store.developOnPhoto: "Drag up or down on the photo for more or less of the colour under the pointer, sideways to turn it. Click something white or grey to make it neutral."
        default: "Hold Option on a tone or colour to see only where it is in the photo. With the target on, drag on the photo itself."
        }
    }

    /// The pointer on a tone or colour in the card, or off `old`, the one it was on.
    private func hover(_ part: Develop.Isolation?, leaving old: Develop.Isolation?) {
        if let part { hovered = part } else if hovered == old { hovered = nil }
    }

    // MARK: Turning it all

    /// The folded card's drag: how much of the development there is, as a share of what it was as
    /// the drag began, from nothing to twice as much. An untouched picture starts from nothing and
    /// goes towards what would suit it best.
    private func strengthDial(neutral: Bool) -> Dial {
        Dial(value: strength ?? (neutral ? 0 : 100), range: 0...200, stops: [100], step: 10, action: neutral ? "Auto Photo" : "Change Photo") { v in
            // The level follows the drag; a step at a time, each is from where the last left it.
            if store.inGesture { strength = v }
            let start = store.gestureBefore ?? store.doc
            store.updateSelection("Change Photo") { n in
                guard DocumentStore.develops(n) else { return }
                let was = start.node(n.id)?.fill.image?.develop ?? Develop()
                let base = was.isNeutral ? store.autoDevelop(for: n) : was
                n.fill.image?.develop = base.scaled(by: v / 100).kept
            }
        }
    }

    private func begin() {
        store.beginGesture()
        ghost = look?.tones
    }

    private func end(_ action: LocalizedStringResource) {
        store.endGesture(action)
        withAnimation(.easeOut(duration: 0.4)) { ghost = nil }
    }

    // MARK: Rows

    private func rows(_ settings: [Develop.Setting]) -> some View {
        VStack(spacing: 2) {
            ForEach(settings, id: \.self) { s in row(s) }
        }
    }

    private func row(_ s: Develop.Setting) -> some View {
        let values = nodes.map { $0.fill.image?.develop?[s] ?? 0 }
        return DevelopRow(title: s.title, value: values[0], range: s.range, decimals: s == .exposure ? 2 : 0,
                          track: Self.track(for: s), mixed: Set(values).count > 1,
                          begin: begin, change: { v in store.develop(s.title) { $0[s] = v } }, end: { end(s.title) },
                          reset: { store.develop(s.title) { $0[s] = 0 } },
                          point: s.isTone ? { on in hover(on ? .tone(s) : nil, leaving: .tone(s)) } : nil)
    }

    /// The colours a setting runs between, drawn along its row, for those whose direction is a colour.
    static func track(for s: Develop.Setting) -> [Color]? {
        switch s {
        case .temperature: [Color(red: 0.29, green: 0.48, blue: 0.86), Color(white: 0.75), Color(red: 0.9, green: 0.64, blue: 0.24)]
        case .tint: [Color(red: 0.33, green: 0.68, blue: 0.35), Color(white: 0.75), Color(red: 0.8, green: 0.36, blue: 0.72)]
        case .saturation, .vibrance: [Color(white: 0.62), Color(white: 0.7), Color(red: 0.86, green: 0.36, blue: 0.3)]
        default: nil
        }
    }

    // MARK: Colour

    @ViewBuilder private func colorPart(_ d: Develop) -> some View {
        rows(Develop.Group.color.settings)
        ColorWheel(look: look, develop: d, picked: store.developBand,
                   pointed: store.developPointed.flatMap { if case .band(let b) = $0 { b } else { nil } }, pick: { band in
            withAnimation(Theme.spring) { store.developBand = band }
        }, begin: begin, change: { band, shift in
            store.develop(band.title) { $0[band] = shift }
        }, end: { band in end(band.title) }, point: { band in
            let now = band.map { Develop.Isolation.band($0) }
            hover(now, leaving: onWheel)
            onWheel = now
        })
        if let band = store.developBand {
            VStack(spacing: 2) {
                ForEach(Develop.Shift.Part.allCases, id: \.self) { part in
                    let values = nodes.map { $0.fill.image?.develop?[band][part] ?? 0 }
                    DevelopRow(title: part.title, value: values[0], range: -100...100, track: Self.track(for: part, of: band),
                               mixed: Set(values).count > 1, begin: begin, change: { v in
                                   store.develop(band.title) { $0[band][part] = v }
                               }, end: { end(band.title) }, reset: { store.develop(band.title) { $0[band][part] = 0 } },
                               point: { on in hover(on ? .band(band) : nil, leaving: .band(band)) })
                }
            }
            .transition(.unfold)
        }
    }

    static func track(for part: Develop.Shift.Part, of band: Develop.Band) -> [Color] {
        let h = band.hue / 360
        switch part {
        case .hue: return [Color(hue: (h - 30.0 / 360 + 1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.85),
                           Color(hue: h, saturation: 0.7, brightness: 0.85),
                           Color(hue: (h + 30.0 / 360).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.85)]
        case .saturation: return [Color(white: 0.7), Color(hue: h, saturation: 0.85, brightness: 0.85)]
        case .luminance: return [Color(hue: h, saturation: 0.8, brightness: 0.35), Color(hue: h, saturation: 0.35, brightness: 1)]
        }
    }
}

/// Reads the look of a picture away from the main thread, one at a time: while one is read, only
/// the latest asked for waits its turn. A drag asks at every step, and reading each of those would
/// pile up behind one another, the landscape lagging further and further behind.
@Observable final class LookReader {
    private(set) var look: PictureLook?
    @ObservationIgnored private var wanted: (Box, Develop?)?
    @ObservationIgnored private var reading = false

    private struct Box: @unchecked Sendable { let image: CGImage }

    func read(_ source: CGImage?, _ develop: Develop?) {
        guard let source else {
            wanted = nil
            look = nil
            return
        }
        wanted = (Box(image: source), develop)
        guard !reading else { return }
        reading = true
        Task {
            while let (box, d) = wanted {
                wanted = nil
                // Set without an animation of its own: one here would take along whatever else
                // changed in the same moment, such as a row's mark mid-drag. Each part that
                // shows the look eases into it by itself.
                look = await Task.detached(priority: .userInitiated) { PictureLook(box.image, d) }.value
            }
            reading = false
        }
    }
}

// MARK: - A row

/// One setting, as a line across the card: its name and amount, and under them a hairline marked
/// from nothing to how much there is. The whole line is the control: dragged sideways it sets the
/// amount, held for a moment at nothing, slower while Option is held; a double click puts it back
/// to nothing.
struct DevelopRow: View {
    let title: LocalizedStringResource
    let value: Double
    let range: ClosedRange<Double>
    var decimals = 0
    var track: [Color]?
    var mixed = false
    let begin: () -> Void
    let change: (Double) -> Void
    let end: () -> Void
    let reset: () -> Void
    var point: ((Bool) -> Void)?

    @State private var hovering = false
    /// Where the drag going on counts from: the amount, how far it had come, and whether Option
    /// was held, then. Pressing or letting go of Option starts counting again from where it is.
    @State private var from: (value: Double, x: CGFloat, slow: Bool)?
    @State private var held = false
    /// How long the hairline is: a drag along the row moves the amount as far along it as the
    /// pointer goes, so the mark stays with the pointer.
    @State private var length = Inspector.content - 14

    private var span: Double { range.upperBound - range.lowerBound }
    private var origin: Double { min(max(0, range.lowerBound), range.upperBound) }

    private func share(_ v: Double) -> CGFloat { CGFloat((v - range.lowerBound) / max(span, .ulpOfOne)) }

    private var said: String {
        if mixed { return SelectionInspector.several }
        if value == 0 { return "0" }
        return value.formatted(.number.precision(.fractionLength(decimals)).sign(strategy: .always(includingZero: false)))
    }

    var body: some View {
        let dragging = from != nil
        let active = hovering || dragging
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(value != 0 || dragging ? Theme.ink : Theme.ink2)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: said)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(value != 0 ? Theme.ink : Theme.ink3)
                .contentTransition(.numericText(value: value))
                // Rolling digits lag behind a drag: while it goes on, each amount at once.
                .transaction { if dragging { $0.animation = nil } }
        }
        .padding(.horizontal, 7)
        .frame(height: 27)
        .background(alignment: .bottom) { line(active: active, dragging: dragging) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 14 } action: { length = max($0, 1) }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(dragging ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.045 : 0))
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if from == nil { point?(inside) }
        }
        .gesture(scrub)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            withAnimation(Theme.spring) { reset() }
        })
        .pointerStyle(.frameResize(position: .trailing))
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(Theme.quick, value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: said))
        .accessibilityAdjustableAction { direction in
            let step = span / 100
            begin()
            change(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
            end()
        }
    }

    /// The hairline along the foot of the row, marked in pencil from nothing to the amount.
    private func line(active: Bool, dragging: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width - 14
            let zero = share(origin) * w, at = share(value) * w
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(Theme.ink.opacity(0.1)))
                    .opacity(track == nil ? 1 : active ? 0.8 : 0.4)
                    .frame(height: 2)
                Capsule()
                    .fill(Theme.pencil)
                    .frame(width: max(abs(at - zero), value == 0 ? 0 : 2), height: 2)
                    .offset(x: min(zero, at))
                Circle()
                    .fill(Theme.card)
                    .overlay { Circle().strokeBorder(Theme.pencil, lineWidth: 1.5) }
                    .frame(width: 8, height: 8)
                    // Grown where it is, and only then moved along: grown after, the way along
                    // would grow with it, and the mark run ahead of the amount.
                    .scaleEffect(dragging ? 1.25 : 1)
                    .animation(Theme.quick, value: dragging)
                    .opacity(active ? 1 : 0)
                    .offset(x: at - 4)
            }
            .frame(width: w, height: 8)
            .offset(x: 7)
            // While dragged, exactly where the pointer has put it, never on its way there.
            .transaction { if dragging { $0.animation = nil } }
        }
        .frame(height: 8)
        .offset(y: 3)
        .allowsHitTesting(false)
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let slow = NSEvent.modifierFlags.contains(.option)
                if from == nil {
                    from = (value, 0, slow)
                    begin()
                } else if let f = from, f.slow != slow {
                    from = (value, g.translation.width, slow)
                }
                guard let f = from else { return }
                let raw = f.value + Double((g.translation.width - f.x) / length) * span * (slow ? 0.25 : 1)
                var v = min(max(raw, range.lowerBound), range.upperBound)
                // Held at nothing, as the trackpad ticks.
                let catches = abs(v - origin) <= span * 0.018 && range.contains(origin)
                if catches { v = origin }
                if catches != held {
                    if catches { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    held = catches
                }
                if v != value { change(v) }
            }
            .onEnded { _ in
                from = nil
                held = false
                end()
                // Left where it was let go, off the row: it was kept on it while the drag went on.
                if !hovering { point?(false) }
            }
    }
}

// MARK: - The tones

/// The picture's tones as a landscape, dark at the left and light at the right, with red, green
/// and blue alone traced over it. It is cut into blacks, shadows, the middle, highlights and
/// whites: pointing at one names it and shows on the canvas what of the picture it is, and a
/// sideways drag there moves it, the landscape following, its shape as the drag began left
/// faintly behind.
struct ToneTerrain: View {
    let look: PictureLook?
    let ghost: [Double]?
    let develop: Develop
    /// The tone the pointer is on, on the picture itself.
    var pointed: Develop.Setting?
    let begin: () -> Void
    let change: (Develop.Setting, Double) -> Void
    let end: (Develop.Setting) -> Void
    let point: (Develop.Setting?) -> Void

    @State private var hovered: Develop.Setting?
    /// The zone dragged, and as for a row, where the drag counts from.
    @State private var drag: (setting: Develop.Setting, from: Double, x: CGFloat, slow: Bool)?
    @State private var held = false

    static let zones: [(Develop.Setting, ClosedRange<CGFloat>)] = [
        (.blacks, 0...0.12), (.shadows, 0.12...0.38), (.exposure, 0.38...0.62), (.highlights, 0.62...0.88), (.whites, 0.88...1),
    ]

    private static let height: CGFloat = 72

    private static func zone(at x: CGFloat) -> Develop.Setting {
        zones.first { $0.1.contains(min(max(x, 0), 1)) }?.0 ?? .exposure
    }

    var body: some View {
        let shown = drag?.setting ?? hovered ?? pointed
        let flat = [Double](repeating: 0, count: PictureLook.toneSteps)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                if let shown, let range = Self.zones.first(where: { $0.0 == shown })?.1 {
                    Rectangle()
                        .fill(Theme.pencilWash)
                        .frame(width: (range.upperBound - range.lowerBound) * w, height: h)
                        .offset(x: range.lowerBound * w)
                        .transition(.opacity)
                }
                if let ghost {
                    ToneShape(bins: Bins(ghost), closed: false)
                        .stroke(Theme.ink3, style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
                        .transition(.opacity)
                }
                // Only the landscape eases into a new look; nothing else in the card is caught up in it.
                ZStack {
                    ToneShape(bins: Bins(look?.reds ?? flat), closed: false).stroke(Color(red: 0.86, green: 0.24, blue: 0.2).opacity(0.45), lineWidth: 1)
                    ToneShape(bins: Bins(look?.greens ?? flat), closed: false).stroke(Color(red: 0.2, green: 0.66, blue: 0.3).opacity(0.45), lineWidth: 1)
                    ToneShape(bins: Bins(look?.blues ?? flat), closed: false).stroke(Color(red: 0.22, green: 0.42, blue: 0.9).opacity(0.45), lineWidth: 1)
                    ToneShape(bins: Bins(look?.tones ?? flat), closed: true)
                        .fill(LinearGradient(colors: [Theme.ink.opacity(0.2), Theme.ink.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    ToneShape(bins: Bins(look?.tones ?? flat), closed: false)
                        .stroke(Theme.ink.opacity(0.55), lineWidth: 1.2)
                }
                .animation(Theme.spring, value: look)
                // The zones' edges, while one is pointed at.
                ForEach(Self.zones.dropFirst(), id: \.0) { _, range in
                    Rectangle().fill(Theme.ink.opacity(shown == nil ? 0 : 0.12)).frame(width: 0.5, height: h).offset(x: range.lowerBound * w)
                }
                // A dot under each zone that is changed.
                ForEach(Self.zones, id: \.0) { s, range in
                    Circle()
                        .fill(Theme.pencil)
                        .frame(width: 4, height: 4)
                        .scaleEffect(develop[s] != 0 ? 1 : 0.3)
                        .opacity(develop[s] != 0 ? 1 : 0)
                        .offset(x: (range.lowerBound + range.upperBound) / 2 * w - 2, y: h - 7)
                }
                clipping(w: w)
                label(shown, w: w)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                switch phase {
                case .active(let p):
                    let s = Self.zone(at: p.x / w)
                    if s != hovered { hovered = s; point(s) }
                case .ended:
                    hovered = nil
                    point(nil)
                }
            }
            .gesture(dragging(width: w))
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .well(radius: 10)
        .pointerStyle(.frameResize(position: .trailing))
        .animation(.easeOut(duration: 0.18), value: shown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tones"))
    }

    /// Small marks in the top corners when part of the picture is lost to black or to white.
    private func clipping(w: CGFloat) -> some View {
        let crushed = (look?.crushed ?? 0) > 0.01, blown = (look?.blown ?? 0) > 0.01
        return ZStack(alignment: .topLeading) {
            Triangle().fill(Theme.ink2).frame(width: 7, height: 5).rotationEffect(.degrees(-90)).offset(x: 6, y: 7).opacity(crushed ? 1 : 0)
            Triangle().fill(Theme.ink2).frame(width: 7, height: 5).rotationEffect(.degrees(90)).offset(x: w - 13, y: 7).opacity(blown ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func label(_ shown: Develop.Setting?, w: CGFloat) -> some View {
        if let shown, let range = Self.zones.first(where: { $0.0 == shown })?.1 {
            let v = develop[shown]
            let amount = v == 0 ? "" : " " + v.formatted(.number.precision(.fractionLength(shown == .exposure ? 2 : 0)).sign(strategy: .always(includingZero: false)))
            HStack(spacing: 0) {
                Text(shown.title)
                Text(verbatim: amount).monospacedDigit().contentTransition(.numericText(value: v))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background { Capsule().fill(Theme.card.opacity(0.92)) }
            .fixedSize()
            .frame(width: w, alignment: range.lowerBound < 0.2 ? .leading : range.upperBound > 0.8 ? .trailing : .center)
            .padding(.horizontal, 5)
            .offset(y: 5)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func dragging(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let slow = NSEvent.modifierFlags.contains(.option)
                if drag == nil {
                    let s = Self.zone(at: g.startLocation.x / w)
                    drag = (s, develop[s], 0, slow)
                    if s != hovered { hovered = s; point(s) }
                    begin()
                } else if let d = drag, d.slow != slow {
                    drag = (d.setting, develop[d.setting], g.translation.width, slow)
                }
                guard let (s, from, x, _) = drag else { return }
                let span = s.range.upperBound - s.range.lowerBound
                var v = min(max(from + Double((g.translation.width - x) / w) * span * (slow ? 0.25 : 1), s.range.lowerBound), s.range.upperBound)
                let catches = abs(v) <= span * 0.018
                if catches { v = 0 }
                if catches != held {
                    if catches { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    held = catches
                }
                if v != develop[s] { change(s, v) }
            }
            .onEnded { g in
                if let s = drag?.setting { end(s) }
                drag = nil
                held = false
                let x = g.location.x / w
                if (0...1).contains(x), (0...Self.height).contains(g.location.y) {
                    hovered = Self.zone(at: x)
                    point(hovered)
                } else {
                    hovered = nil
                    point(nil)
                }
            }
    }
}

private nonisolated struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// A list of amounts that eases from one to the next, so the landscape flows into its new shape.
nonisolated struct Bins: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    static var zero: Bins { Bins([]) }

    private static func combine(_ a: Bins, _ b: Bins, _ f: (Double, Double) -> Double) -> Bins {
        let n = max(a.values.count, b.values.count)
        return Bins((0..<n).map { i in f(i < a.values.count ? a.values[i] : 0, i < b.values.count ? b.values[i] : 0) })
    }

    static func + (a: Bins, b: Bins) -> Bins { combine(a, b, +) }
    static func - (a: Bins, b: Bins) -> Bins { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// The landscape of a picture's tones: a smooth line through how much there is at each, shown
/// gently compressed so that small amounts still show; closed, the ground under it.
nonisolated struct ToneShape: Shape {
    var bins: Bins
    let closed: Bool

    var animatableData: Bins {
        get { bins }
        set { bins = newValue }
    }

    func path(in r: CGRect) -> Path {
        let v = bins.values
        guard v.count > 1 else { return Path() }
        let top = r.height * 0.86
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: r.minX + CGFloat(i) / CGFloat(v.count - 1) * r.width,
                    y: r.maxY - 1 - CGFloat(pow(min(max(v[i], 0), 1.15), 0.7)) * top)
        }
        var p = Path()
        if closed { p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: point(0)) } else { p.move(to: point(0)) }
        for i in 1..<v.count {
            let a = point(i - 1), b = point(i)
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        p.addLine(to: point(v.count - 1))
        if closed {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// The card's small picture: the picture's tones as a little landscape in a ring.
struct ToneGlyph: View {
    let tones: [Double]?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.3)
            ToneShape(bins: Bins(Self.coarse(tones)), closed: true)
                .padding(EdgeInsets(top: 3.5, leading: 2.5, bottom: 2.5, trailing: 2.5))
                .opacity(0.8)
        }
        .frame(width: 16, height: 14)
        .animation(Theme.spring, value: tones)
    }

    /// A few steps of the tones, smoothed, as a picture this small can show.
    private static func coarse(_ tones: [Double]?) -> [Double] {
        guard let tones, !tones.isEmpty else { return [0.15, 0.45, 0.8, 0.6, 0.85, 0.4, 0.15] }
        let steps = 8, per = max(tones.count / steps, 1)
        let sums = (0..<steps).map { i in tones[(i * per)..<min((i + 1) * per, tones.count)].reduce(0, +) / Double(per) }
        let most = sums.max() ?? 1
        return sums.map { most > 0 ? $0 / most : 0 }
    }
}

// MARK: - The colours

/// The picture's colours as a ring of eight, red at the top and round through yellow, green and
/// blue, around a cloud of the colours the picture has, strongest furthest out. Each colour is a
/// bead to drag: round the ring to turn its hue towards its neighbours, or out for more of it and
/// in for less, whichever way the drag sets off; up or down with Option for lighter or darker.
/// Its rest stays marked while it is moved from it. With Option, pointing at a bead shows on the
/// canvas what of the picture is that colour.
struct ColorWheel: View {
    let look: PictureLook?
    let develop: Develop
    let picked: Develop.Band?
    /// The colour the pointer is on, on the picture itself.
    var pointed: Develop.Band?
    let pick: (Develop.Band?) -> Void
    let begin: () -> Void
    let change: (Develop.Band, Develop.Shift) -> Void
    let end: (Develop.Band) -> Void
    let point: (Develop.Band?) -> Void

    @State private var hovered: Develop.Band?
    @State private var drag: Turning?
    @State private var held: Set<Develop.Shift.Part> = []

    /// A bead being dragged: where it was and where the pointer was as the drag began, or as
    /// Option was last pressed or let go, and which of its hue or its strength the drag changes,
    /// once it has set off one way or the other. Both at once, a pull outwards turned it too.
    private struct Turning {
        let band: Develop.Band
        var from: Develop.Shift
        var start: CGPoint
        var lighter: Bool
        var part: Develop.Shift.Part?
    }

    /// Room for a bead pulled all the way out, above and below the ring.
    private static let size = CGSize(width: Inspector.content, height: 200)
    private static let ring: CGFloat = 62
    /// How far out from the ring a bead goes for all of its colour, and in for none.
    private static let reach: CGFloat = 28
    /// How far a drag goes before it is known which way it set off.
    private static let settles: CGFloat = 4

    private var center: CGPoint { CGPoint(x: Self.size.width / 2, y: Self.size.height / 2) }

    private func place(_ band: Develop.Band) -> CGPoint {
        let s = develop[band]
        let angle = (band.hue + s.hue / 100 * 30) * .pi / 180
        let r = Self.ring + CGFloat(s.saturation / 100) * Self.reach
        return CGPoint(x: center.x + CGFloat(sin(angle)) * r, y: center.y - CGFloat(cos(angle)) * r)
    }

    private func rest(_ band: Develop.Band) -> CGPoint {
        let a = band.hue * .pi / 180
        return CGPoint(x: center.x + CGFloat(sin(a)) * Self.ring, y: center.y - CGFloat(cos(a)) * Self.ring)
    }

    private static func color(_ band: Develop.Band, _ s: Develop.Shift) -> Color {
        let h = ((band.hue + s.hue / 100 * 30) / 360 + 1).truncatingRemainder(dividingBy: 1)
        let light = s.luminance / 100
        return Color(hue: h, saturation: min(max(0.72 + s.saturation / 100 * 0.28, 0.08), 1) * (light > 0 ? 1 - light * 0.45 : 1),
                     brightness: min(max(0.86 + light * (light > 0 ? 0.14 : 0.5), 0.2), 1))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cloud
            Circle()
                .strokeBorder(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.6, brightness: 0.9) }, center: .center,
                                              startAngle: .degrees(-90), endAngle: .degrees(270)), lineWidth: 1.5)
                .frame(width: Self.ring * 2 + 1.5, height: Self.ring * 2 + 1.5)
                .opacity(0.5)
                .position(center)
                .allowsHitTesting(false)
            ForEach(Develop.Band.allCases, id: \.self) { band in bead(band) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .coordinateSpace(name: "wheel")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Colours"))
    }

    /// The picture's own colours, as a soft cloud: each hue round the wheel, stronger further out.
    private var cloud: some View {
        Canvas { ctx, size in
            guard let colors = look?.colors else { return }
            ctx.addFilter(.blur(radius: 4))
            let hues = PictureLook.hueSteps, rings = PictureLook.strengthSteps
            for i in 0..<hues {
                for j in 0..<rings {
                    let v = colors[i * rings + j]
                    guard v > 0.03 else { continue }
                    let a = Double(i) / Double(hues) * 2 * .pi
                    let r = (CGFloat(j) + 0.6) / CGFloat(rings) * (Self.ring - 12)
                    let p = CGPoint(x: size.width / 2 + CGFloat(sin(a)) * r, y: size.height / 2 - CGFloat(cos(a)) * r)
                    let d = 5 + CGFloat(v) * 9
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                             with: .color(Color(hue: Double(i) / Double(hues), saturation: (Double(j) + 0.5) / Double(rings), brightness: 0.92).opacity(0.25 + v * 0.7)))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .mask {
            Circle().frame(width: (Self.ring - 4) * 2, height: (Self.ring - 4) * 2).position(center).blur(radius: 6)
        }
        .allowsHitTesting(false)
    }

    private func bead(_ band: Develop.Band) -> some View {
        let s = develop[band]
        let p = place(band), home = rest(band)
        let isPicked = picked == band, active = hovered == band || drag?.band == band || pointed == band
        let size: CGFloat = active ? 19 : isPicked ? 17 : 14
        return ZStack(alignment: .topLeading) {
            // Where it rests, and the thread back to it, while it is moved from there.
            if !s.isNone {
                Path { path in path.move(to: home); path.addLine(to: p) }
                    .stroke(Theme.ink3, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 2.5]))
                    .allowsHitTesting(false)
                Circle().fill(Theme.ink3).frame(width: 4, height: 4).position(home)
                    .allowsHitTesting(false)
            }
            Circle()
                .fill(Self.color(band, s))
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                .overlay {
                    Circle().strokeBorder(Theme.pencil, lineWidth: 1.5).padding(-3.5).opacity(isPicked ? 1 : 0)
                }
                .shadow(color: Theme.shadow.opacity(active ? 0.3 : 0.18), radius: active ? 5 : 2, y: active ? 2 : 1)
                .frame(width: size, height: size)
                // Everything that takes the pointer before the bead is placed: after, it would
                // take it all over the wheel, every bead at once.
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .help(Text(band.title))
                .accessibilityLabel(Text(band.title))
                .accessibilityAddTraits(.isButton)
                .onHover { inside in
                    guard drag == nil else { return }
                    hovered = inside ? band : (hovered == band ? nil : hovered)
                    point(hovered)
                }
                .gesture(dragging(band))
                .onTapGesture { pick(picked == band ? nil : band) }
                .pointerStyle(drag?.band == band ? .grabActive : .grabIdle)
                .position(p)
        }
        .animation(drag?.band == band ? nil : Theme.spring, value: s)
        .animation(Theme.pop, value: size)
    }

    private func polar(_ p: CGPoint) -> (Double, CGFloat) {
        let dx = p.x - center.x, dy = p.y - center.y
        return (atan2(Double(dx), Double(-dy)) * 180 / .pi, hypot(dx, dy))
    }

    private func dragging(_ band: Develop.Band) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("wheel"))
            .onChanged { g in
                let lighter = NSEvent.modifierFlags.contains(.option)
                if drag == nil {
                    drag = Turning(band: band, from: develop[band], start: g.startLocation, lighter: lighter)
                    pick(band)
                    begin()
                }
                guard var d = drag else { return }
                // Option pressed or let go: on from here, with what it has come to.
                if d.lighter != lighter { d = Turning(band: band, from: develop[band], start: g.location, lighter: lighter) }
                var s = d.from
                if d.lighter {
                    s.luminance = d.from.luminance + Double(d.start.y - g.location.y) / 60 * 100
                } else {
                    let (a0, r0) = polar(d.start), (a, r) = polar(g.location)
                    let round = Develop.turn(a - a0) * .pi / 180 * Double(max(r0, 1)), out = Double(r - r0)
                    if d.part == nil, hypot(round, out) >= Double(Self.settles) { d.part = abs(round) > abs(out) ? .hue : .saturation }
                    switch d.part {
                    case .hue?: s.hue = d.from.hue + Develop.turn(a - a0) / 30 * 100
                    case .saturation?: s.saturation = d.from.saturation + out / Double(Self.reach) * 100
                    default: break
                    }
                }
                drag = d
                // Held at nothing as it passes, as the rows are.
                var next = Develop.Shift()
                var catches: Set<Develop.Shift.Part> = []
                for part in Develop.Shift.Part.allCases {
                    var v = min(max(s[part], -100), 100)
                    if v != d.from[part], abs(v) <= 4 { v = 0; catches.insert(part) }
                    next[part] = v
                }
                if !catches.subtracting(held).isEmpty { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                held = catches
                if next != develop[band] { change(band, next) }
            }
            .onEnded { g in
                guard let d = drag else { return }
                end(d.band)
                drag = nil
                held = []
                // The bead follows the drag only one way: the pointer may have left it.
                if hypot(g.location.x - place(band).x, g.location.y - place(band).y) > 13 {
                    hovered = nil
                    point(nil)
                }
            }
    }
}

// MARK: - Buttons

/// Develops the pictures as suits them best, at a click: the wand in the folded card.
private struct AutoButton: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var spark = 0

    var body: some View {
        Image(systemName: "wand.and.sparkles")
            .font(.system(size: 11, weight: .medium))
            .symbolEffect(.bounce, value: spark)
            .foregroundStyle(hovering ? Theme.pencil : Theme.ink3)
            .frame(width: 22, height: 22)
            .background { Circle().fill(Theme.ink.opacity(hovering ? 0.06 : 0)) }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture {
                spark += 1
                action()
            }
            .help(Text("Develop the photo as suits it best"))
            .accessibilityLabel(Text("Auto"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Makes the picture itself the control, and gives it back: see `DevelopTool`. Off, a press on the
/// picture moves it as on any layer.
private struct TargetButton: View {
    let on: Bool
    let enabled: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "scope")
            .font(.system(size: 12, weight: .medium))
            .symbolEffect(.bounce, value: on)
            .foregroundStyle(on ? Theme.pencil : hovering ? Theme.ink : Theme.ink2)
            .frame(width: Theme.controlHeight, height: Theme.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(on ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.05 : 0))
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovering = $0 && enabled }
            .onTapGesture { if enabled { toggle() } }
            .animation(Theme.quick, value: on)
            .animation(Theme.quick, value: hovering)
            .help(Text("Adjust on the photo"))
            .accessibilityLabel(Text("Adjust on the photo"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shows the pictures as they were taken while it is held down.
private struct CompareButton: View {
    let show: (Bool) -> Void
    @State private var held = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: "circle.lefthalf.filled")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(held ? Theme.pencil : hovering ? Theme.ink : Theme.ink2)
            .frame(width: Theme.controlHeight, height: Theme.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(held ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.05 : 0))
            }
            .scaleEffect(held ? 0.92 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !held else { return }
                    held = true
                    show(true)
                }
                .onEnded { _ in
                    held = false
                    show(false)
                })
            .animation(Theme.quick, value: held)
            .help(Text("Hold to see the original"))
            .accessibilityLabel(Text("Original"))
    }
}
