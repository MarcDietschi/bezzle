import SwiftUI
import AppKit

/// The ruler of time, on a card floating at the foot of the canvas: a comb of fine strokes, one
/// for each version, each in the colour of the sky when it was made, indigo at night and gold
/// towards evening, the named ones with a bead on top. Under the pointer the strokes swell, as
/// the Dock does, and a label glides along, catching on the version nearest. The pencil line where
/// the design is seen from flies from stroke to stroke when one is clicked, plucking each it
/// passes like a string; dragged, it lifts and follows, each version felt as it is passed; let
/// go, it settles on the one under it. Two fingers across the card leaf through time.
struct TimeRuler: View {
    let store: DocumentStore
    @State private var motion = RulerMotion()
    @State private var awake = true
    @State private var sleeper: Task<Void, Never>?
    @State private var hoverX: CGFloat?
    @State private var dragX: CGFloat?
    @State private var overCard = false
    @State private var scrolled: CGFloat = 0
    @State private var monitor: Any?
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var shelf: VersionShelf { store.versions }

    static let width: CGFloat = 600
    private static let comb: CGFloat = 40
    private static let baseline: CGFloat = 25

    var body: some View {
        let shown = shelf.shown
        VStack(alignment: .leading, spacing: 16) {
            header(shown)
                .frame(height: 24)
            HStack(spacing: 12) {
                playButton
                GeometryReader { geo in
                    comb(width: geo.size.width)
                }
                .frame(height: Self.comb)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: Self.width)
        .card(radius: 18, lifted: true)
        .onHover { overCard = $0 }
        .onChange(of: shelf.travel?.at) { naming = false; wake() }
        .onChange(of: shelf.list.count) { wake() }
        .onChange(of: store.preview?.key) { shelf.keepShown() }
        .onAppear {
            wake()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                leaf(event) ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            sleeper?.cancel()
        }
    }

    /// Keeps the comb moving until all of it has settled again.
    private func wake() {
        awake = true
        sleeper?.cancel()
        sleeper = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                if Task.isCancelled { return }
                if motion.settled, dragX == nil, hoverX == nil, !shelf.playing {
                    awake = false
                    return
                }
            }
        }
    }

    // MARK: The row above

    private func header(_ version: DesignVersion?) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Text(verbatim: version.map { Self.when($0.date) } ?? String(localized: "Now"))
                    .font(Theme.serif(15, weight: .medium).monospacedDigit())
                    .foregroundStyle(version == nil ? Theme.pencil : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .id(version?.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity.combined(with: .offset(y: -4))))
            }
            .frame(width: 150, alignment: .leading)
            .clipped()
            .animation(.snappy(duration: 0.24), value: version?.id)
            nameArea(version)
            Spacer(minLength: 8)
            actions
            Button { withAnimation(Theme.spring) { shelf.leave() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put the ruler away  ⎋")
        }
    }

    /// The name of what is shown, or a flag to give it one; written in place when asked.
    @ViewBuilder
    private func nameArea(_ version: DesignVersion?) -> some View {
        if naming {
            TextField(version == nil ? String(localized: "Name this moment") : String(localized: "Give it a name"), text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($nameFocused)
                .frame(width: 170)
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.pencil).frame(height: 1.5) }
                .onSubmit {
                    if let version { shelf.rename(version.id, name) } else { shelf.nameNow(name) }
                    naming = false
                }
                .onExitCommand { naming = false }
                .onChange(of: nameFocused) { if !nameFocused { naming = false } }
                .transition(.opacity.combined(with: .offset(x: -4)))
        } else if let words = version?.name {
            Text(verbatim: words)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .onTapGesture { startNaming(words) }
                .help("Give it a name")
                .transition(.opacity)
        } else if !store.isReadOnly {
            Button { startNaming("") } label: {
                Image(systemName: "flag")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(version == nil ? Text("Name this moment") : Text("Give it a name"))
            .transition(.opacity)
        }
    }

    private func startNaming(_ words: String) {
        guard !store.isReadOnly else { return }
        name = words
        withAnimation(.snappy(duration: 0.2)) { naming = true }
        nameFocused = true
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if let t = shelf.travel {
                if !t.picked.isEmpty {
                    CardButton(title: "Bring Back", symbol: "arrow.uturn.up", height: 26) { withAnimation(Theme.spring) { shelf.bringBack() } }
                        .help("Brings the layers picked back as they were, into the design as it is now")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                CardButton(title: "Go Back to This Version", height: 26) { withAnimation(Theme.spring) { shelf.restore() } }
                    .help("The design becomes what it was then. What it is now is kept as a version first.")
                    .disabled(store.isReadOnly)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: shelf.travel?.picked.isEmpty)
        .animation(Theme.spring, value: shelf.travel == nil)
    }

    private var playButton: some View {
        Button {
            if shelf.playing { shelf.stop() } else { shelf.play() }
            wake()
        } label: {
            ZStack {
                Circle().fill(shelf.playing ? Theme.pencil : Theme.ink.opacity(0.06))
                Image(systemName: shelf.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(shelf.playing ? .white : Theme.ink2)
                    .offset(x: shelf.playing ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(shelf.list.isEmpty)
        .opacity(shelf.list.isEmpty ? 0.4 : 1)
        .padding(.bottom, 10)
        .help(shelf.playing ? Text("Stop") : Text("Play its story"))
        .animation(Theme.spring, value: shelf.playing)
    }

    // MARK: The comb

    private var index: Int {
        shelf.shown.flatMap { v in shelf.list.firstIndex { $0.id == v.id } } ?? shelf.list.count
    }

    private func comb(width w: CGFloat) -> some View {
        let list = shelf.list
        let xs = Self.slots(list.map(\.date), width: w)
        let bases = list.map { $0.isNamed ? 15 : 11 as CGFloat } + [0]
        let at = index
        let pointer = dragX ?? hoverX
        let near = pointer.map { Self.nearest($0, in: xs) }
        return TimelineView(.animation(minimumInterval: nil, paused: !awake)) { timeline in
            let _ = motion.step(at: timeline.date, xs: xs, bases: bases, pointer: pointer, head: dragX ?? xs[at], held: dragX != nil, width: w)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx, size: size, list: list, xs: xs, near: near)
                }
                lens(list: list, near: near)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A press is a click until it moves: the line flies there; then it follows.
                if abs(value.translation.width) > 3 || dragX != nil { dragX = min(max(value.location.x, xs[0]), xs[xs.count - 1]) }
                hoverX = value.location.x
                go(to: Self.nearest(value.location.x, in: xs))
            }
            .onEnded { _ in
                dragX = nil
                wake()
            })
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            wake()
        }
    }

    private func go(to i: Int) {
        wake()
        guard i != index || shelf.playing else { return }
        if i >= shelf.list.count { shelf.showNow() } else { shelf.show(shelf.list[i].id) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Two fingers across the card, or the wheel, step through the versions, one each stretch.
    private func leaf(_ event: NSEvent) -> Bool {
        guard overCard, !shelf.list.isEmpty, !naming else { return false }
        let d = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            scrolled += d
            while scrolled > 24 { go(to: min(index + 1, shelf.list.count)); scrolled -= 24 }
            while scrolled < -24 { go(to: max(index - 1, 0)); scrolled += 24 }
            if event.phase == .ended || event.momentumPhase == .ended { scrolled = 0 }
        } else if d != 0 {
            go(to: min(max(index + (d > 0 ? 1 : -1), 0), shelf.list.count))
        }
        return true
    }

    /// Where each version stands along a comb this wide (`VersionKeeping.slots`).
    static func slots(_ dates: [Date], width: CGFloat, now: Date = Date()) -> [CGFloat] {
        VersionKeeping.slots(dates, width: width, now: now)
    }

    static func nearest(_ x: CGFloat, in xs: [CGFloat]) -> Int {
        VersionKeeping.nearest(x, in: xs)
    }

    /// The colour of a stroke: the sky then, kept legible on the card.
    private static func stroke(_ date: Date, dark: Bool) -> Color {
        let c = Sky.at(date).sky
        let k = dark ? 0.45 : 0.3
        let to: Double = dark ? 1 : 0.12
        return Color(red: c.r + (to - c.r) * k, green: c.g + (to - c.g) * k, blue: c.b + (to - c.b) * k)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, list: [DesignVersion], xs: [CGFloat], near: Int?) {
        let base = Self.baseline
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink = Color(nsColor: CanvasInk.rulerInk)
        let heights = motion.heights, glow = motion.glow
        guard heights.count == xs.count else { return }

        // The days, quietly, under the first stroke of each.
        let calendar = Calendar.current
        var taken: CGFloat = -.infinity
        let dates = list.map(\.date) + [Date()]
        for i in dates.indices where i == 0 || !calendar.isDate(dates[i - 1], inSameDayAs: dates[i]) {
            let text = ctx.resolve(Text(Self.day(dates[i])).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(ink.opacity(0.38)))
            let tw = text.measure(in: size).width
            let x = min(xs[i] - 1, size.width - tw)
            guard x > taken + 8 else { continue }
            taken = x + tw
            ctx.draw(text, at: CGPoint(x: x, y: base + 9), anchor: .leading)
        }

        // The scale: hairlines all along, carrying the ripples that run along the comb.
        let wave = motion.wave, spacing = RulerMotion.spacing
        let near = near.map { xs[$0] }
        var fine = Path(), lit = Path()
        for k in wave.indices {
            let x = CGFloat(k) * spacing + spacing / 2
            guard x < xs[xs.count - 1] - 4 else { break }
            let swell = motion.swell(at: x)
            let h = max(2.5 * (1 + 1.8 * swell) + CGFloat(wave[k]), 0.5)
            let close = near.map { abs($0 - x) < 30 } ?? false
            let bar = CGRect(x: x - 0.5, y: base - h, width: 1, height: h)
            if close { lit.addRect(bar) } else { fine.addRect(bar) }
        }
        ctx.fill(fine, with: .color(ink.opacity(0.14)))
        ctx.fill(lit, with: .color(ink.opacity(0.26)))

        // The versions, in the colours of their skies, swelling under the pointer and ringing
        // when plucked.
        for (i, v) in list.enumerated() {
            let x = xs[i]
            let h = max(CGFloat(heights[i].value) + CGFloat(motion.ripple(at: x)), 0)
            guard h > 0.2 else { continue }
            let lit = max(glow[i], near == x ? 1 : 0)
            var line = Path()
            line.move(to: CGPoint(x: x, y: base))
            line.addLine(to: CGPoint(x: x, y: base - h))
            ctx.stroke(line, with: .color(Self.stroke(v.date, dark: dark).opacity(0.78 + 0.22 * lit)),
                       style: StrokeStyle(lineWidth: 2.4 + CGFloat(lit) * 0.6, lineCap: .round))
            if v.isNamed {
                let r: CGFloat = 2.7
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: base - h - r * 2 - 1.5, width: r * 2, height: r * 2)), with: .color(author(v)))
            }
        }
        // Now, at the right end.
        let nx = xs[xs.count - 1]
        ctx.stroke(Path(ellipseIn: CGRect(x: nx - 3.5, y: base - 7, width: 7, height: 7)), with: .color(Theme.pencil), lineWidth: 1.5)

        // The pencil line, lifted while held.
        let hx = CGFloat(motion.head.value), lift = CGFloat(motion.lift.value)
        var head = Path()
        head.move(to: CGPoint(x: hx, y: base + 3))
        head.addLine(to: CGPoint(x: hx, y: 4))
        var glowCtx = ctx
        glowCtx.addFilter(.shadow(color: Theme.pencil.opacity(0.35 + 0.25 * Double(lift)), radius: 3 + 4 * lift))
        glowCtx.stroke(head, with: .color(Theme.pencil), style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
        let r = 3.5 * (1 + 0.4 * lift)
        glowCtx.fill(Path(ellipseIn: CGRect(x: hx - r, y: 4 - r, width: r * 2, height: r * 2)), with: .color(Theme.pencil))
    }

    /// The label gliding with the pointer, catching on the version nearest it.
    @ViewBuilder
    private func lens(list: [DesignVersion], near: Int?) -> some View {
        let shown = CGFloat(motion.lensShown.value)
        if let near, shown > 0.01 {
            let text = near < list.count ? Self.when(list[near].date) + (list[near].name.map { "  " + $0 } ?? "") : String(localized: "Now")
            Text(verbatim: text)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.card)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(Theme.ink.opacity(0.88)))
                .scaleEffect(0.86 + 0.14 * shown, anchor: .bottom)
                .opacity(Double(shown))
                .position(x: CGFloat(motion.lens.value), y: -9)
                .allowsHitTesting(false)
        }
    }

    /// The colour of who named a version: one's own pencil, or the pencil of someone sharing it.
    private func author(_ v: DesignVersion) -> Color {
        guard let replica = v.replica, replica != store.noteAuthor.replica, v.shared == true else { return Theme.pencil }
        let rgb = Pencil.preferred(replica).rgb
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    // MARK: Words

    /// A moment as one says it: the day, and the time.
    static func when(_ date: Date) -> String { day(date) + ", " + time(date) }

    /// The day of a moment, as one says it: today, yesterday, a weekday this week, else a date.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return String(localized: "Yesterday") }
        if now.timeIntervalSince(date) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
}

/// The time ruler's switch in the top bar.
struct VersionsButton: View {
    let store: DocumentStore
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.spring) {
                if store.versions.browsing { store.versions.leave() } else { store.versions.browse() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(store.versions.browsing ? Theme.pencil : (hovering ? Theme.ink : Theme.ink2))
                .frame(width: 30, height: 28)
                .background {
                    if store.versions.browsing { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.pencilWash) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Versions  ⌥⌘T")
    }
}
