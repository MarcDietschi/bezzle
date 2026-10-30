import SwiftUI
import AppKit

/// A number in a well. Drag anywhere on it sideways to scrub, even while typing, or click it to
/// type; a click elsewhere ends the typing. The arrow keys step it (with Shift for tens). A dash means the selected layers differ. Typing understands sums
/// ("120/3"), changes to what is there ("+10", "×2") and shares of the whole ("50%"); see `NumberEntry`.
///
/// While scrubbing the pointer holds still over the field and its movement goes to the value, so a
/// scrub can go as far as it likes; a tape of marks under the number runs with the hand. Option is
/// fine and Shift is coarse, in whole tens. The trackpad ticks as the value meets a limit and at
/// each ten with Shift, and Escape puts it back.
struct NumberField: View {
    @Environment(DocumentStore.self) private var store
    let label: LocalizedStringResource
    let value: Double?
    var unit: String = ""
    var range: ClosedRange<Double> = -100_000...100_000
    var step: Double = 1
    /// Points of value per point of pointer travel while scrubbing.
    var scrub: Double = 1
    var decimals = 1
    /// How the change is named in the Edit menu.
    let action: LocalizedStringResource
    let apply: (Double) -> Void
    /// Applies a typed change to each selected layer's own value, so "+2" adds two to every one
    /// of them, and arrow keys move each when they differ. Without it, changes start from the value shown.
    var each: ((EachValue) -> Void)? = nil

    @State private var draft = ""
    /// After a change to each layer, the value they come to replaces what was typed.
    @State private var echo = false
    @State private var hovering = false
    @State private var scrubber = Scrubber()
    @FocusState private var focused: Bool

    var body: some View {
        let scrubbing = scrubber.on
        HStack(spacing: 4) {
            // On one line, a little smaller if a language's word is long for the field.
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(scrubbing ? Theme.pencil : hovering ? Theme.ink2 : Theme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 12, alignment: .leading)
                .padding(.leading, 8)
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(scrubbing ? Theme.pencil : Theme.ink)
                .focused($focused)
                .onSubmit { commit() }
                .onKeyPress(.upArrow) { bump(+1); return .handled }
                .onKeyPress(.downArrow) { bump(-1); return .handled }
                .onExitCommand { draft = text(value); focused = false }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(scrubbing ? Theme.pencil.opacity(0.7) : Theme.ink3)
                    .padding(.trailing, 7)
            }
        }
        // Pulled past a limit, the number gives a little the way it is pulled.
        .offset(x: scrubber.give)
        .frame(height: Theme.controlHeight)
        .background(alignment: .bottom) {
            Tape(pulled: scrubber.pulled, color: scrubbing ? Theme.pencil.opacity(0.55) : Theme.ink.opacity(0.22))
                .frame(height: 5)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)
                .opacity(scrubbing ? 1 : hovering && !focused ? 0.8 : 0)
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.pencilWash)
                .opacity(scrubbing ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .well(radius: 7)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(scrubbing ? Theme.pencil.opacity(0.6) : Theme.ink.opacity(focused ? 0.35 : 0), lineWidth: 1)
        }
        .overlay {
            // The whole field scrubs, even while it is being typed into. A click types, and once
            // typing puts the caret where it falls.
            Color.clear
                .contentShape(Rectangle())
                .pointerStyle(focused ? .horizontalText : .frameResize(position: .trailing))
                .onHover { hovering = $0 }
                .gesture(pressing)
        }
        .animation(Theme.quick, value: scrubbing)
        .animation(Theme.quick, value: hovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: scrubber.give)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: bump(+1)
            case .decrement: bump(-1)
            @unknown default: break
            }
        }
        .onAppear { draft = text(value) }
        .onDisappear { scrubber.end() }
        .onChange(of: value) { _, v in
            if !focused || echo { draft = text(v); echo = false }
        }
        .onChange(of: focused) { _, now in
            if now { draft = text(value) } else { commit() }
        }
    }

    /// A press on the field: a drag of a few points scrubs, anything less types.
    private var pressing: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard !scrubber.on, !scrubber.done, hypot(g.translation.width, g.translation.height) >= 3 else { return }
                // What was being typed is kept, and the scrub goes on from it.
                var from = value
                if focused {
                    from = commit()
                    focused = false
                }
                startScrub(from: from, moved: g.translation.width)
            }
            .onEnded { _ in
                if scrubber.on || scrubber.done {
                    if scrubber.on { store.endGesture(action) }
                    scrubber.end()
                    scrubber.done = false
                } else if focused {
                    placeCaret()
                } else {
                    focused = true
                }
            }
    }

    /// A click while typing puts the caret where it falls; a double click takes in the whole number.
    private func placeCaret() {
        guard let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            editor.selectAll(nil)
            return
        }
        let i = editor.characterIndexForInsertion(at: editor.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        editor.setSelectedRange(NSRange(location: i, length: 0))
    }

    /// Scrubs from `from`, or, when the layers differ, each from its own value.
    private func startScrub(from: Double?, moved: CGFloat) {
        let together = from != nil || each == nil
        let from = together ? from ?? 0 : 0
        var last = from
        store.beginGesture()
        scrubber.start(Scrub(from: from, range: together ? range : -1e12...1e12, rate: scrub, decimals: decimals, step: step),
                       moved: moved) { v in
            if together {
                apply(v)
            } else if let each, v != last {
                each(EachValue(entry: .add(v - last), range: range))
            }
            last = v
        } cancel: {
            store.cancelGesture()
        }
    }

    private func bump(_ direction: Double) {
        let by = direction * step * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)
        if value == nil, let each {
            echo = true
            each(EachValue(entry: .add(by), range: range))
            return
        }
        let v = clamped((value ?? 0) + by)
        apply(v)
        draft = text(v)
    }

    /// Applies what was typed, and tells what the field comes to: nil when each layer took it
    /// to its own value.
    @discardableResult private func commit() -> Double? {
        guard let entry = NumberEntry.parse(draft, unit: unit, negatives: range.lowerBound < 0) else {
            draft = text(value)
            return value
        }
        if case .value(let v) = entry {
            if v != value { apply(clamped(v)) }
            draft = text(clamped(v))
            return clamped(v)
        } else if let each {
            echo = true
            each(EachValue(entry: entry, range: range))
            draft = text(value)
            return nil
        } else {
            let v = clamped(entry.applied(to: value ?? 0))
            if v != value { apply(v) }
            draft = text(v)
            return v
        }
    }

    private func clamped(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func rounded(_ v: Double) -> Double {
        let f = pow(10, Double(decimals))
        return (v * f).rounded() / f
    }

    private func text(_ v: Double?) -> String {
        guard let v else { return "–" }
        let f = pow(10, Double(decimals))
        let r = (v * f).rounded() / f
        if r == r.rounded() { return String(Int(r)) }
        // With the decimal mark of the user's language, which typing takes either way; never
        // grouped, as "1,000" would be read back as one.
        return r.formatted(.number.precision(.fractionLength(0...decimals)).grouping(.never))
    }
}

/// A click anywhere but in the field being typed into ends the typing, keeping what was typed;
/// a SwiftUI text field otherwise holds on to the keyboard through clicks on the panels around it.
enum ClickAway {
    private static var monitor: Any?

    static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard let window = event.window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return event }
            let field = editor.delegate as? NSView ?? editor
            if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { window.makeFirstResponder(nil) }
            return event
        }
    }
}

/// Typing in Bezzle is plain: no predicted words, no Writing Tools coming up over a selected
/// number, and in its fields no completions or corrections. They are for prose, and Bezzle's fields
/// hold numbers, colours and names; text on the canvas is a design's own words.
enum PlainTyping {
    private static var watching: [Any] = []

    static func watch() {
        guard watching.isEmpty else { return }
        // A text view a field or the canvas types with, as it takes the keyboard and selects.
        // (Both are told on the main queue, so what they are told about can be handled there.)
        watching.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated { if let text = object as? NSTextView { quiet(text) } }
        })
        // A window's own field editor, before anything is typed into it.
        watching.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                if let text = (object as? NSWindow)?.fieldEditor(true, for: nil) as? NSTextView { quiet(text) }
            }
        })
    }

    private static func quiet(_ text: NSTextView) {
        guard text.writingToolsBehavior != .none else { return }
        text.writingToolsBehavior = .none
        text.inlinePredictionType = .no
        if text.isFieldEditor {
            text.isAutomaticTextCompletionEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false
            text.isContinuousSpellCheckingEnabled = false
        }
    }
}

/// The arithmetic of a scrub. The value follows the pointer's travel at `rate` a point, a tenth as
/// fast while Option is down and ten times while Shift is, which also keeps it to whole tens of
/// `step`. At a limit it stops, noting how hard it is pulled past, and turns back the moment the
/// pointer does.
struct Scrub {
    enum Pace { case fine, normal, coarse }

    let from: Double
    let range: ClosedRange<Double>
    let rate: Double
    let decimals: Int
    let step: Double
    private(set) var value: Double
    /// Points pulled on past a limit, plus beyond the top and minus beyond the bottom.
    private(set) var strain: Double = 0
    /// Where the value was when the pace last changed, and how far the pointer has gone since.
    private var base: Double
    private var travel: Double = 0
    private var speed: Double = 1

    init(from: Double, range: ClosedRange<Double>, rate: Double, decimals: Int, step: Double) {
        self.from = min(max(from, range.lowerBound), range.upperBound)
        self.range = range
        self.rate = rate
        self.decimals = decimals
        self.step = step
        value = self.from
        base = self.from
    }

    /// Moves the pointer `dx` points at a pace, and tells whether the value changed.
    mutating func move(_ dx: Double, pace: Pace) -> Bool {
        let speed = pace == .fine ? 0.1 : pace == .coarse ? 10 : 1
        if speed != self.speed {
            // A new pace carries on from the value as it shows, not the unrounded one under it.
            base = value
            travel = 0
            self.speed = speed
        }
        if strain != 0 && dx != 0 && (dx > 0) != (strain > 0) { strain = 0 }
        travel += dx
        var raw = base + travel * rate * speed
        if raw > range.upperBound || raw < range.lowerBound {
            let bound = raw > range.upperBound ? range.upperBound : range.lowerBound
            strain += (raw - bound) / (rate * speed)
            base = bound
            travel = 0
            raw = bound
        }
        let tens = 10 * step
        let next = min(max(pace == .coarse ? (raw / tens).rounded() * tens : rounded(raw), range.lowerBound), range.upperBound)
        defer { value = next }
        return next != value
    }

    private func rounded(_ v: Double) -> Double {
        let f = pow(10, Double(decimals))
        return (v * f).rounded() / f
    }
}

/// A scrub in progress. The pointer is held where it was pressed, over the field, and its movement
/// comes here from the events instead of moving it, so it never runs off the screen.
@Observable
final class Scrubber {
    private(set) var on = false
    /// How far the hand has gone while the value followed, which the tape runs with.
    private(set) var pulled: CGFloat = 0
    /// How far the number gives, pulled past a limit.
    private(set) var give: CGFloat = 0
    /// The scrub was put back with Escape, and the press has yet to end.
    var done = false
    @ObservationIgnored private var scrub: Scrub?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var update: (Double) -> Void = { _ in }
    @ObservationIgnored private var cancel: () -> Void = {}

    func start(_ scrub: Scrub, moved: CGFloat, update: @escaping (Double) -> Void, cancel: @escaping () -> Void) {
        self.scrub = scrub
        self.update = update
        self.cancel = cancel
        on = true
        pulled = 0
        CGAssociateMouseAndMouseCursorPosition(0)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, self.on else { return event }
            if event.type == .leftMouseDragged {
                self.move(event.deltaX, event.modifierFlags)
            } else if event.type == .leftMouseUp {
                // The pointer goes free with the button, whatever becomes of the press.
                self.unlock()
            } else if event.keyCode == 53 {
                self.cancel()
                self.end()
                self.done = true
                return nil
            }
            return event
        }
        move(moved, NSEvent.modifierFlags)
    }

    private func move(_ dx: CGFloat, _ flags: NSEvent.ModifierFlags) {
        guard var scrub else { return }
        let pace: Scrub.Pace = flags.contains(.option) ? .fine : flags.contains(.shift) ? .coarse : .normal
        let pinned = scrub.strain != 0
        let changed = scrub.move(Double(dx), pace: pace)
        self.scrub = scrub
        if scrub.strain == 0 { pulled += dx }
        give = scrub.strain == 0 ? 0 : (scrub.strain > 0 ? 1 : -1) * min(4, sqrt(abs(scrub.strain)) * 0.6)
        if changed { update(scrub.value) }
        // The trackpad ticks as the value meets a limit, and at each ten while Shift is down.
        if !pinned && scrub.strain != 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else if pace == .coarse && changed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func end() {
        guard on else { return }
        on = false
        give = 0
        scrub = nil
        unlock()
    }

    private func unlock() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Marks along the foot of a number field, like a tape measure's, that run with the hand as it
/// scrubs; faintly there while the pointer is on the field, to say it can be dragged.
private struct Tape: View {
    let pulled: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 4
            let first = Int(ceil(-pulled / gap)), last = Int(floor((size.width - pulled) / gap))
            guard first <= last else { return }
            var short = Path(), tall = Path()
            for n in first...last {
                let x = ((CGFloat(n) * gap + pulled) * 2).rounded() / 2
                if n % 5 == 0 {
                    tall.addRect(CGRect(x: x - 0.5, y: size.height - 5, width: 1, height: 5))
                } else {
                    short.addRect(CGRect(x: x - 0.5, y: size.height - 2.5, width: 1, height: 2.5))
                }
            }
            ctx.fill(short, with: .color(color.opacity(0.7)))
            ctx.fill(tall, with: .color(color))
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
    }
}

/// What was typed into a number field, for each selected layer to apply to its own value.
struct EachValue {
    let entry: NumberEntry
    let range: ClosedRange<Double>

    /// The new value for a layer whose value is `old`, kept within the field's range.
    func callAsFunction(_ old: Double, whole: Double? = nil) -> Double {
        min(max(entry.applied(to: old, whole: whole), range.lowerBound), range.upperBound)
    }
}

/// A colour: its swatch opens the picker, its hex can be typed beside it, and the design's own
/// colours sit at the end of the row, one click away and shown on the canvas while pointed at.
struct ColorField: View {
    @Environment(DocumentStore.self) private var store
    @Environment(MenuHost.self) private var menus
    let id: String
    let color: RGBA?
    var suggestions: [RGBA] = []
    let action: LocalizedStringResource
    /// Shows a suggested colour on the canvas while the pointer is on it; nil when it leaves.
    var preview: ((RGBA?) -> Void)? = nil
    /// Opens something else from the swatch in place of the colour picker, such as the fill menu.
    var picker: (() -> Void)? = nil
    let apply: (RGBA) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Swatch(color: color)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .contentShape(Rectangle())
                .onTapGesture { (picker ?? openPicker)() }
                .menuAnchor(id)
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .debugOpenMenu)) { note in
                    if note.object as? String == id { (picker ?? openPicker)() }
                }
                #endif
            HStack(spacing: 2) {
                Text(verbatim: "#")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.leading, 8)
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { commit() }
                if let color, color.a < 1 {
                    Text(verbatim: "\(Int((color.a * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                        .padding(.trailing, 7)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.controlHeight)
            .well(radius: 7)
            if !suggestions.isEmpty {
                // In the inspector's last column, where the narrow fields at the ends of rows are.
                HStack(spacing: 4) {
                    ForEach(suggestions.prefix(4), id: \.self) { c in
                        Suggestion(color: c) { inside in
                            preview?(inside ? c.with(alpha: color?.a ?? 1) : nil)
                        } choose: {
                            preview?(nil)
                            apply(c.with(alpha: color?.a ?? 1))
                        }
                    }
                }
                .frame(width: Inspector.endField, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = color?.hex ?? "–" }
        .onChange(of: color) { _, c in if !focused { draft = c?.hex ?? "–" } }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func openPicker() {
        menus.panel(id, size: CGSize(width: 248, height: 330)) {
            ColorPanel(id: id, action: action, start: color, apply: apply)
                .environment(store)
                .environment(menus)
        }
    }

    private func commit() {
        guard let c = RGBA(hex: draft, alpha: color?.a ?? 1) else { draft = color?.hex ?? "–"; return }
        if c != color { apply(c) }
        draft = c.hex
    }
}

/// One of the design's colours beside a colour field: a dot that grows a little under the pointer.
private struct Suggestion: View {
    let color: RGBA
    let hover: (Bool) -> Void
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .overlay { Circle().strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.5) }
            .frame(width: 16, height: 16)
            .scaleEffect(hovering ? 1.18 : 1)
            .frame(width: 16, height: Theme.controlHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                hover(inside)
            }
            .onTapGesture(perform: choose)
            .onDisappear { if hovering { hover(false) } }
            .animation(Theme.quick, value: hovering)
            .help(Text(verbatim: "#\(color.hex)"))
    }
}

/// A colour on a checkerboard, so how see-through it is shows too.
struct Swatch: View {
    let color: RGBA?
    var radius: CGFloat = 7

    var body: some View {
        ZStack {
            Checkerboard()
            if let color {
                Color(nsColor: color.nsColor)
            } else {
                // Mixed: half and half of nothing in particular.
                LinearGradient(colors: [Theme.ink4, Theme.ink4.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5)
        }
    }
}

struct Checkerboard: View {
    var square: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var p = Path()
            for row in 0..<Int(ceil(size.height / square)) {
                for col in 0..<Int(ceil(size.width / square)) where (row + col) % 2 == 1 {
                    p.addRect(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            ctx.fill(p, with: .color(Color(white: 0.86)))
        }
    }
}

/// Picks a colour: brightness and saturation in a square, hue and transparency on two strips,
/// the hex, a dropper for any colour on screen, and the colours the design already uses.
struct ColorPanel: View {
    @Environment(DocumentStore.self) private var store
    @Environment(MenuHost.self) private var menus
    let id: String
    let action: LocalizedStringResource
    /// The colour to start from, when the field knows it, such as one stop of a gradient.
    var start: RGBA?
    /// Starts again from `start` when this changes, such as when another of a gradient's colours
    /// is chosen.
    var key: String?
    let apply: (RGBA) -> Void

    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1
    @State private var alpha: Double = 1
    @State private var dragging = false

    private var current: RGBA { RGBA(h: hue, s: saturation, b: brightness, a: alpha) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color(nsColor: RGBA(h: hue, s: 1, b: 1).nsColor)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    Knob(color: RGBA(h: hue, s: saturation, b: brightness))
                        .position(x: saturation * geo.size.width, y: (1 - brightness) * geo.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    begin()
                    saturation = min(max(g.location.x / geo.size.width, 0), 1)
                    brightness = 1 - min(max(g.location.y / geo.size.height, 0), 1)
                    push()
                }.onEnded { _ in end() })
            }
            .frame(height: 150)

            Strip(value: hue, knob: RGBA(h: hue, s: 1, b: 1)) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1 / 12).map { Color(nsColor: RGBA(h: $0 == 1 ? 0.9999 : $0, s: 1, b: 1).nsColor) },
                               startPoint: .leading, endPoint: .trailing)
            } changed: { v in begin(); hue = min(v, 0.9999); push() } ended: { end() }

            Strip(value: alpha, knob: current) {
                ZStack {
                    Checkerboard(square: 4)
                    LinearGradient(colors: [Color(nsColor: current.with(alpha: 0).nsColor), Color(nsColor: current.with(alpha: 1).nsColor)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            } changed: { v in begin(); alpha = (v * 100).rounded() / 100; push() } ended: { end() }

            HStack(spacing: 8) {
                HexEntry(color: current) { c in set(c); apply(c) }
                Text(verbatim: "\(Int((alpha * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 40, alignment: .trailing)
                IconButton(symbol: "eyedropper", help: "Pick a colour from the screen") {
                    NSColorSampler().show { picked in
                        guard let picked else { return }
                        let c = RGBA(picked).with(alpha: alpha)
                        set(c)
                        apply(c)
                    }
                }
            }

            let used = Array(store.designColors.prefix(18))
            if !used.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In this design")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                        ForEach(used, id: \.self) { c in
                            Swatch(color: c, radius: 5)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                                .onTapGesture { set(c); apply(c) }
                                .help(Text(verbatim: "#\(c.hex)"))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .onAppear { load() }
        .onChange(of: key) { load() }
    }

    /// The colour the field shows, or else the first selected layer's, to start from.
    private func load() {
        if let start { set(start); return }
        guard let first = store.selectedNodes.first else { return }
        let c: RGBA = switch id {
        case "border": first.border.color
        case "shadow": first.shadow.color
        default: first.fill.color
        }
        set(c)
    }

    private func set(_ c: RGBA) {
        let (h, s, b) = c.hsb
        // A grey has no hue of its own; keep the one the strip is on.
        if s > 0.001 && b > 0.001 { hue = h }
        saturation = s
        brightness = b
        alpha = c.a
    }

    private func begin() {
        if !dragging { dragging = true; store.beginGesture() }
    }

    private func push() { apply(current) }

    private func end() {
        dragging = false
        store.endGesture(action)
    }

}

private struct HexEntry: View {
    let color: RGBA
    let apply: (RGBA) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(verbatim: "#")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .padding(.leading, 8)
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .focused($focused)
                .onSubmit { commit() }
        }
        .frame(height: 26)
        .well(radius: 7)
        .onAppear { draft = color.hex }
        .onChange(of: color) { _, c in if !focused { draft = c.hex } }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        if let c = RGBA(hex: draft, alpha: color.a), c != color { apply(c) }
    }
}

/// A strip with a knob on it, for hue and transparency.
private struct Strip<Background: View>: View {
    let value: Double
    let knob: RGBA
    @ViewBuilder let background: Background
    let changed: (Double) -> Void
    let ended: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                background
                    .clipShape(Capsule())
                    .overlay { Capsule().strokeBorder(Theme.ink.opacity(0.1), lineWidth: 0.5) }
                Knob(color: knob)
                    .position(x: 7 + value * (geo.size.width - 14), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                changed(min(max((g.location.x - 7) / (geo.size.width - 14), 0), 1))
            }.onEnded { _ in ended() })
        }
        .frame(height: 14)
    }
}

private struct Knob: View {
    let color: RGBA

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.with(alpha: 1).nsColor))
            .frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
    }
}
