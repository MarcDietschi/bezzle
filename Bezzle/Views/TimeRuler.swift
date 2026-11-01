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

    /// Where each version stands along a comb this wide, and now after the last: each a step
    /// apart, a little more between one day and the next, the first at the left, now at the right.
    static func slots(_ dates: [Date], width: CGFloat, now: Date = Date()) -> [CGFloat] {
        let lead: CGFloat = 4, tail: CGFloat = 6
        let calendar = Calendar.current
        let all = dates + [now]
        var units: [CGFloat] = [0]
        for i in all.indices.dropFirst() {
            let apart: CGFloat = calendar.isDate(all[i - 1], inSameDayAs: all[i]) ? 1 : 1.8
            units.append(units[i - 1] + apart)
        }
        guard let span = units.last, span > 0 else { return [width - tail] }
        let scale = (width - lead - tail) / span
        return units.map { lead + $0 * scale }
    }

    static func nearest(_ x: CGFloat, in xs: [CGFloat]) -> Int {
        xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? max(xs.count - 1, 0)
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

/// The comb's motion: each stroke's height on a spring, swelling under the pointer and plucked
/// as the pencil line passes it; the line itself, and the label gliding with the pointer.
@MainActor
final class RulerMotion {
    private(set) var heights: [DeckTool.Spring] = []
    private(set) var glow: [Double] = []
    private(set) var head = DeckTool.Spring(0)
    private(set) var lift = DeckTool.Spring(0)
    private(set) var lens = DeckTool.Spring(0)
    private(set) var lensShown = DeckTool.Spring(0)
    private var last: Date?
    private var born: Date?
    private var placed = false

    /// A string along the comb, sampled every `spacing`: how far each point of it stands out,
    /// and how fast it moves, as a ripple runs along it from where a stroke was plucked.
    private(set) var wave: [Double] = []
    private var speed: [Double] = []
    static let spacing: CGFloat = 5
    private var pointer: CGFloat?
    private var swellShown = DeckTool.Spring(0)

    /// How much the comb swells at `x` under the pointer, 0 to 1.
    func swell(at x: CGFloat) -> CGFloat {
        guard let p = pointer else { return 0 }
        let d = Double(x - p) / 26
        return CGFloat(exp(-d * d) * swellShown.value)
    }

    /// The ripple running along the comb at `x`.
    func ripple(at x: CGFloat) -> Double {
        guard !wave.isEmpty else { return 0 }
        let u = Double(x / Self.spacing - 0.5)
        let i = min(max(Int(u.rounded(.down)), 0), wave.count - 1), j = min(i + 1, wave.count - 1)
        let f = min(max(u - Double(i), 0), 1)
        return wave[i] * (1 - f) + wave[j] * f
    }

    /// Moves everything on to `now`: the strokes towards `bases`, swollen near `pointer`, and
    /// the line towards `target`, closely while `held`.
    func step(at now: Date, xs: [CGFloat], bases: [CGFloat], pointer: CGFloat?, head target: CGFloat, held: Bool, width: CGFloat = 600) {
        let dt = min(max(now.timeIntervalSince(last ?? now), 0), 1.0 / 20)
        last = now
        if born == nil { born = now }
        let samples = max(Int(width / Self.spacing), 1)
        if wave.count != samples {
            wave = Array(repeating: 0, count: samples)
            speed = wave
        }
        if let pointer { self.pointer = pointer }
        swellShown.target = pointer == nil ? 0 : 1
        swellShown.step(dt, stiffness: 300, damping: 30)
        ring(dt)
        if heights.count != xs.count {
            heights = xs.indices.map { i in i < heights.count ? heights[i] : DeckTool.Spring(0) }
            glow = xs.indices.map { i in i < glow.count ? glow[i] : 0 }
        }
        if !placed {
            head = DeckTool.Spring(Double(target))
            placed = true
        }
        let from = head.value
        head.target = Double(target)
        if held { head.step(dt, stiffness: 1600, damping: 80) } else { head.step(dt, stiffness: 230, damping: 23) }
        let passed = Self.crossed(from: CGFloat(from), to: CGFloat(head.value), xs: xs)
        lastXs = xs

        let age = now.timeIntervalSince(born ?? now)
        for i in xs.indices {
            // Printed in from now back to the first as the card comes out.
            let delay = Double(xs.count - 1 - i) / Double(max(xs.count, 1)) * 0.35
            var goal = age < delay ? 0 : Double(bases[i])
            if let p = pointer, goal > 0 {
                let d = Double(p - xs[i]) / 24
                goal *= 1 + 0.9 * exp(-d * d)
            }
            heights[i].target = goal
            heights[i].step(dt, stiffness: 420, damping: 19)
            glow[i] *= exp(-dt * 3.2)
        }
        for i in passed where i < heights.count { pluck(i) }
        lift.target = held ? 1 : 0
        lift.step(dt, stiffness: 520, damping: 30)
        if let p = pointer {
            let snapped = Double(xs[RulerMotion.nearest(p, in: xs)])
            if lensShown.value < 0.05 { lens = DeckTool.Spring(snapped) }
            lens.target = snapped
        }
        lens.step(dt, stiffness: 360, damping: 30)
        lensShown.target = pointer == nil ? 0 : 1
        lensShown.step(dt, stiffness: 420, damping: 32)
    }

    /// The strokes a line moving from one place to another passes over or lands on: not the
    /// one it leaves, nor now's end.
    static func crossed(from a: CGFloat, to b: CGFloat, xs: [CGFloat]) -> [Int] {
        guard abs(b - a) > 0.001 else { return [] }
        return xs.indices.dropLast().filter { i in
            b < a ? xs[i] >= b - 0.01 && xs[i] < a - 0.01 : xs[i] > a + 0.01 && xs[i] <= b + 0.01
        }
    }

    static func nearest(_ x: CGFloat, in xs: [CGFloat]) -> Int {
        xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? max(xs.count - 1, 0)
    }

    private var plucked: [CGFloat] = []

    private func pluck(_ i: Int) {
        heights[i].velocity += 150
        glow[i] = 1
        plucked.append(lastXs.indices.contains(i) ? lastXs[i] : 0)
    }

    private var lastXs: [CGFloat] = []

    /// The string, stepped on: each point pulled towards its neighbours and back to rest, slowly
    /// stilled; a stroke plucked sets it going where it stands.
    private func ring(_ dt: Double) {
        for x in plucked {
            let c = Double(x / Self.spacing - 0.5)
            for k in max(Int(c) - 3, 0)...min(Int(c) + 3, wave.count - 1) {
                let d = Double(k) - c
                speed[k] += 70 * exp(-d * d / 2)
            }
        }
        plucked = []
        let n = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Double(n)
        let tension = 2600.0, rest = 70.0, still = 5.0
        for _ in 0..<n {
            for k in wave.indices {
                let left = k > 0 ? wave[k - 1] : 0, right = k < wave.count - 1 ? wave[k + 1] : 0
                speed[k] += (tension * (left - 2 * wave[k] + right) - rest * wave[k] - still * speed[k]) * h
            }
            for k in wave.indices { wave[k] += speed[k] * h }
        }
    }

    private var ringing: Bool { wave.contains { abs($0) > 0.05 } || speed.contains { abs($0) > 0.5 } }

    var settled: Bool {
        heights.allSatisfy(\.settled) && head.settled && lift.settled && lens.settled && lensShown.settled && swellShown.settled
            && glow.allSatisfy { $0 < 0.02 } && !ringing
    }
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

// MARK: - The sky

/// The sky of a moment, for the ruler of time: where the sun stands, how warm its light is, how
/// dark it is. The days are as long as they are at this latitude through the year, and noon moves
/// with summer time.
nonisolated struct Sky: Equatable {
    /// Where the light falls from, across the table: 0 at the left, 1 at the right.
    var x: Double
    /// How high the sun stands: 0 at the horizon or below, 1 at its highest in summer.
    var sun: Double
    /// How warm the light is: 0 the pale light of noon, 1 the gold of a low sun or a lamp.
    var warmth: Double
    /// How dark it is outside: 0 by day, 1 by night, between at dusk and dawn.
    var night: Double
    /// How near the sun is to the horizon, at dusk and dawn.
    var dusk: Double

    static let latitude = 47.0

    static func at(_ date: Date, calendar: Calendar = .current) -> Sky {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 172)
        let noon = 12.5 + (calendar.timeZone.isDaylightSavingTime(for: date) ? 1 : 0)
        let rad = Double.pi / 180
        let declination = 23.44 * rad * sin(2 * .pi * (day - 80) / 365.25)
        let angle = (hour - noon) * 15 * rad
        let lat = latitude * rad
        // The sine of how high the sun stands.
        let e = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(angle)
        let night = smooth(from: 0.04, to: -0.18, e)
        let golden = min(max(1 - e / 0.36, 0), 1)
        let dayX = 0.5 + 0.38 * sin(angle)
        return Sky(x: dayX + (0.78 - dayX) * night,
                   sun: min(max(e / 0.92, 0), 1),
                   warmth: golden + (1 - golden) * night,
                   night: night,
                   dusk: min(max(1 - abs(e + 0.03) / 0.13, 0), 1))
    }

    /// Steps from 0 to 1 as `v` goes from `a` to `b`, gently at both ends.
    private static func smooth(from a: Double, to b: Double, _ v: Double) -> Double {
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The light itself: pale by day, gold low down, a lamp's at night.
    var light: (r: Double, g: Double, b: Double) {
        let cool = (0.93, 0.96, 1.0), gold = (1.0, 0.74, 0.45)
        let t = warmth
        return (cool.0 + (gold.0 - cool.0) * t, cool.1 + (gold.1 - cool.1) * t, cool.2 + (gold.2 - cool.2) * t)
    }

    /// The colour of the sky then, for the ruler of time: blue by day, gold and rose as the sun
    /// goes down, indigo by night.
    var sky: (r: Double, g: Double, b: Double) {
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let blue = (0.56, 0.74, 0.95), gold = (0.98, 0.72, 0.40), rose = (0.80, 0.48, 0.62), indigo = (0.17, 0.19, 0.38)
        let day = mix(blue, gold, (1 - night) * min(max(1 - sun / 0.4, 0), 1))
        let c = mix(mix(day, rose, dusk * 0.75), indigo, night)
        return (c.0, c.1, c.2)
    }
}
