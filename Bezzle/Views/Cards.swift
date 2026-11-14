import SwiftUI
import AppKit

/// What the inspector shows of the selected layers, each on a card of its own. The store keeps
/// which card is open, and which the pointer is on, for the canvas to outline what that card changes.
enum Aspect: Hashable {
    case arrange, frame, artboard, background, deck, grid, cell, post, text, path
    /// An artboard shown dark, its named looks in their dark looks. See `Style.dark`.
    case appearance
    /// Words bent into an arc, or riding a shape's outline. See `CurveCard`.
    case curve
    case corners, opacity, blur, depth, export
    /// A mask, or a layer inside one. See `MaskCard`.
    case mask
    /// A copy of a component, or a layer in one. See `ComponentCard`.
    case component
    case layout, guides
    /// A picture's development: its light, colours and detail. See `PhotoCard`.
    case photo
    /// A picture made shapes, while it remembers its picture. See `VectorCard`.
    case vector
    /// Seen as a prototype: where the layers go, a screen's own part in it, and the states a copy
    /// of a component shows. See `PrototypeInspector`.
    case flow, screen, states
    /// One of the layers' fills, borders or shadows, by its slot: 0 for the first, at the bottom,
    /// and each over it one more. See `Look`.
    case fill(Int), border(Int), shadow(Int)

    /// The card for one slot of a look.
    static func of(_ look: Look, _ slot: Int) -> Aspect {
        switch look {
        case .fill: .fill(slot)
        case .border: .border(slot)
        case .shadow: .shadow(slot)
        }
    }
}

/// The amount a sideways drag across a card sets, such as how far its shadow lifts the layer.
/// The card's width is the whole range; the drag clicks to `stops`, such as the presets, as it
/// passes them, and the trackpad ticks there.
struct Dial {
    /// Where a drag starts from: the first selected layer's amount.
    var value: Double
    var range: ClosedRange<Double>
    var stops: [Double] = []
    /// How far one step moves it, for VoiceOver.
    var step: Double = 1
    /// Names the change in the Edit menu.
    let action: LocalizedStringResource
    let apply: (Double) -> Void

    /// How near a stop, as a share of the range, a drag is held at it.
    static let catchment = 0.03

    /// Where a drag that has come to `raw` settles: within the range, and held at a stop when near
    /// one, which it also tells.
    static func settle(_ raw: Double, in range: ClosedRange<Double>, stops: [Double]) -> (value: Double, stop: Double?) {
        let span = range.upperBound - range.lowerBound
        let near = stops.filter { range.contains($0) && abs(raw - $0) <= span * catchment }
            .min { abs(raw - $0) < abs(raw - $1) }
        if let near { return (near, near) }
        return (min(max(raw, range.lowerBound), range.upperBound), nil)
    }

    /// How far a card gives, pulled `over` points past the end of its range: less and less the
    /// further it is pulled, and never more than `limit`.
    static func give(_ over: CGFloat, limit: CGFloat) -> CGFloat {
        limit * (1 - exp(-over / (limit * 1.6)))
    }

    /// How far past the bottom of the range a card that can be taken away is pulled before
    /// letting go takes it away.
    static let tearsAt: CGFloat = 70
}

/// One thing the selected layers have, as a card resting on the panel. Folded, it is one line: a
/// small live picture, its name, and what it comes to. A click opens it, lifting it, and the
/// others settle; a sideways drag across it sets its amount, and one past the bottom of the range
/// takes it away. Pointing at it outlines on the canvas what it changes.
struct AspectCard<Glyph: View, Picks: View, Exact: View>: View {
    @Environment(DocumentStore.self) private var store
    let aspect: Aspect
    let title: LocalizedStringResource
    /// What it comes to, in a few words and numbers.
    let summary: String
    var dial: Dial?
    var remove: (() -> Void)?
    /// Says what taking it away does, such as "Remove shadow".
    var removal: LocalizedStringResource = "Remove"
    /// Lifted while a drag on the canvas changes what it shows.
    var live = false
    /// A control in the folded line itself, such as the arrows that turn a stack's posts.
    var accessory: AnyView?
    /// Another of the same kind, such as a second shadow, offered by a + beside the × while the
    /// card is open: pointing at it shows it on the canvas, and a click adds it and opens its card.
    var more: AddBar.Item?
    /// For a card in a pile of its kind: told how far it is dragged up or down as it is picked up
    /// and moved, and nil when it is let go. See `SelectionInspector.pile`.
    var restack: ((CGFloat?) -> Void)?
    /// Whether it says the design's style its look is and offers the styles of its kind: not in
    /// Animate, where a look is keyed and never named.
    var styles = true
    let glyph: Glyph
    let picks: Picks
    let exact: Exact

    @State private var hovering = false
    /// Whether the pointer is on the folded line, where a sideways drag turns the dial.
    @State private var onHead = false
    @State private var turn: Turn?
    @State private var caught: Double?

    /// Between the folded line and what an open card holds: clear of the level the line fills
    /// with as it is pointed at, as far as the rows below are apart.
    static var openGap: CGFloat { 8 }

    /// A press on the folded line, and the drag it may become: sideways it turns the dial, up or
    /// down it moves the card in its pile.
    private struct Turn {
        var from: Double
        var last: Double
        var on = false
        var pull: CGFloat = 0
        var tearing = false
        var restacking = false
    }

    init(aspect: Aspect, title: LocalizedStringResource, summary: String, dial: Dial? = nil, remove: (() -> Void)? = nil,
         removal: LocalizedStringResource = "Remove", live: Bool = false, accessory: AnyView? = nil,
         more: AddBar.Item? = nil, restack: ((CGFloat?) -> Void)? = nil, styles: Bool = true,
         @ViewBuilder glyph: () -> Glyph, @ViewBuilder picks: () -> Picks, @ViewBuilder exact: () -> Exact) {
        self.aspect = aspect
        self.title = title
        self.summary = summary
        self.dial = dial
        self.remove = remove
        self.removal = removal
        self.live = live
        self.accessory = accessory
        self.more = more
        self.restack = restack
        self.styles = styles
        self.glyph = glyph()
        self.picks = picks()
        self.exact = exact()
    }

    private var opens: Bool { Picks.self != EmptyView.self || Exact.self != EmptyView.self }

    /// The design's style the selected layers' look is, when the card shows one that has a name.
    private var named: Style? { styles ? aspect.stylePlace.flatMap { store.sharedStyle(at: $0) } : nil }

    /// Whether the open card offers the design's styles of its kind first: not while letters
    /// picked out are what the text card changes.
    private var offersStyles: Bool {
        guard styles, let place = aspect.stylePlace, !store.holding(place).isEmpty else { return false }
        return place != .text || store.pickedLetters == nil
    }

    var body: some View {
        let open = opens && store.openAspect == aspect
        let turning = turn?.on == true
        let lifted = open || live || turning || turn?.restacking == true
        VStack(alignment: .leading, spacing: 0) {
            head(open: open, turning: turning)
            if open {
                // Every row the same distance from the next, picked or exact.
                VStack(alignment: .leading, spacing: 8) {
                    if offersStyles, let place = aspect.stylePlace { StyleRow(place: place) }
                    picks
                    if Exact.self != EmptyView.self { exact }
                }
                .padding(.horizontal, Inspector.cardInset)
                .padding(.top, Self.openGap)
                .padding(.bottom, Inspector.cardInset)
                .transition(.unfold)
            }
        }
        .card(radius: 12, lifted: lifted)
        .offset(x: turn?.pull ?? 0, y: lifted ? -1.5 : 0)
        .rotationEffect(.degrees(turn?.tearing == true ? -1.5 : 0), anchor: .trailing)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            point(inside)
        }
        .onDisappear {
            // A turn cut short, as when an undo takes the card away, still ends as one step.
            if turn?.on == true, let dial { store.endGesture(dial.action) }
            point(false)
        }
        .animation(Theme.spring, value: lifted)
        .animation(Theme.quick, value: turn?.tearing)
    }

    private func head(open: Bool, turning: Bool) -> some View {
        let tearing = turn?.tearing == true
        let named = named
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                glyph
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 22, height: 22)
                    .overlay { NameRing(on: named != nil) }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Group {
                    if tearing {
                        Text("Release to remove")
                    } else if let named {
                        NamedSummary(name: named.name)
                            .id(named.id)
                            .transition(InkStamp())
                    } else {
                        Text(verbatim: summary)
                            .contentTransition(.numericText())
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(tearing ? Theme.warning : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(Theme.quick, value: summary)
                .animation(Theme.pop, value: named?.id)
            }
            // One element for VoiceOver, which opens the card and steps its dial; the controls
            // beside it stay their own.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityAdjustableAction { direction in
                guard let dial else { return }
                let by = direction == .increment ? dial.step : -dial.step
                dial.apply(min(max(dial.value + by, dial.range.lowerBound), dial.range.upperBound))
            }
            if let accessory { accessory }
            if let more, open {
                MoreButton(item: more)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if let remove, open {
                RemoveButton(help: removal, action: remove)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(alignment: .leading) { level(turning: turning) }
        .overlay(alignment: .bottom) {
            if turning, let dial { Notches(dial: dial, caught: caught).transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onHover { onHead = $0 }
        .gesture(pressing)
        .pointerStyle(turn?.restacking == true ? .grabActive : dial == nil ? PointerStyle.default : .frameResize(position: .trailing))
    }

    /// How much there is, as pencil filling the line from the left: faint while the pointer is
    /// on the line, to say it can be dragged, and full while it is. Not while the pointer is on
    /// an open card's rows, which have nothing to do with it.
    private func level(turning: Bool) -> some View {
        GeometryReader { geo in
            let share = dial.map { d in
                (d.value - d.range.lowerBound) / max(d.range.upperBound - d.range.lowerBound, .ulpOfOne)
            } ?? 0
            Rectangle()
                .fill(Theme.pencilWash)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.pencil.opacity(0.35)).frame(width: 1.5) }
                .frame(width: geo.size.width * min(max(share, 0), 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(dial == nil ? 0 : turning ? 1 : onHead ? 0.55 : 0)
        .animation(turning ? nil : .easeOut(duration: 0.25), value: onHead)
        .allowsHitTesting(false)
    }

    /// A press: a click opens or folds the card, and a sideways drag turns its dial.
    private var pressing: some Gesture {
        // Measured on the window, not on the card, which moves under the pointer as it goes: else
        // each move would be counted less the last, and a card picked up off its pile would shake.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { g in
                var t = turn ?? Turn(from: dial?.value ?? 0, last: dial?.value ?? 0)
                if !t.on && !t.restacking {
                    // Up or down, a card in a pile is picked up; sideways, its dial turns.
                    let across = abs(g.translation.width), along = abs(g.translation.height)
                    if let restack, along >= 4, along > across {
                        t.restacking = true
                        turn = t
                        restack(g.translation.height)
                        return
                    }
                    guard dial != nil, across >= 4 else { turn = t; return }
                    t.on = true
                    store.beginGesture()
                    store.pointedAspect = aspect
                }
                if t.restacking {
                    restack?(g.translation.height)
                    return
                }
                guard let dial else { return }
                let span = dial.range.upperBound - dial.range.lowerBound
                // Past an end, the way on is counted from where the card has given to, so it
                // takes as long a pull to tear one off as it always has.
                let raw = t.from + Double((g.translation.width - t.pull) / Inspector.card) * span
                let (value, stop) = Dial.settle(raw, in: dial.range, stops: dial.stops)
                if stop != caught {
                    if stop != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    caught = stop
                }
                // Past either end the card gives a little; past the bottom, one that can be taken
                // away gives more, and far enough comes away when let go.
                let below = CGFloat(max(dial.range.lowerBound - raw, 0) / span) * Inspector.card
                let above = CGFloat(max(raw - dial.range.upperBound, 0) / span) * Inspector.card
                let tearing = remove != nil && below > Dial.tearsAt
                if tearing != t.tearing, tearing { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                t.tearing = tearing
                t.pull = below > 0 ? -Dial.give(below, limit: remove != nil ? 90 : 14) : above > 0 ? Dial.give(above, limit: 14) : 0
                if value != t.last {
                    dial.apply(value)
                    t.last = value
                }
                turn = t
            }
            .onEnded { _ in
                caught = nil
                if turn?.restacking == true {
                    turn = nil
                    restack?(nil)
                    return
                }
                guard let t = turn, t.on, let dial else {
                    turn = nil
                    toggle()
                    return
                }
                if t.tearing, let remove {
                    // Taken away in one step, not turned down to nothing first.
                    store.cancelGesture()
                    withAnimation(Theme.unfold) { remove() }
                    return
                }
                store.endGesture(dial.action)
                if !hovering { point(false) }
                withAnimation(Theme.pop) { turn = nil }
            }
    }

    private func toggle() {
        guard opens else { return }
        withAnimation(Theme.unfold) { store.openAspect = store.openAspect == aspect ? nil : aspect }
    }

    private func point(_ inside: Bool) {
        if inside {
            store.pointedAspect = aspect
        } else if store.pointedAspect == aspect, turn?.on != true {
            store.pointedAspect = nil
        }
    }
}

extension AspectCard where Exact == EmptyView {
    init(aspect: Aspect, title: LocalizedStringResource, summary: String, dial: Dial? = nil, remove: (() -> Void)? = nil,
         removal: LocalizedStringResource = "Remove", live: Bool = false, accessory: AnyView? = nil,
         more: AddBar.Item? = nil, restack: ((CGFloat?) -> Void)? = nil, styles: Bool = true,
         @ViewBuilder glyph: () -> Glyph, @ViewBuilder picks: () -> Picks) {
        self.init(aspect: aspect, title: title, summary: summary, dial: dial, remove: remove, removal: removal, live: live,
                  accessory: accessory, more: more, restack: restack, styles: styles, glyph: glyph, picks: picks, exact: { EmptyView() })
    }
}

extension AspectCard where Picks == EmptyView, Exact == EmptyView {
    init(aspect: Aspect, title: LocalizedStringResource, summary: String, live: Bool = false, accessory: AnyView? = nil,
         @ViewBuilder glyph: () -> Glyph) {
        self.init(aspect: aspect, title: title, summary: summary, live: live, accessory: accessory,
                  glyph: glyph, picks: { EmptyView() }, exact: { EmptyView() })
    }
}

/// The stops along the foot of a card while its dial turns, the one it is held at standing taller.
private struct Notches: View {
    let dial: Dial
    let caught: Double?

    var body: some View {
        Canvas { ctx, size in
            let span = dial.range.upperBound - dial.range.lowerBound
            guard span > 0 else { return }
            for stop in dial.stops where dial.range.contains(stop) {
                let x = (CGFloat((stop - dial.range.lowerBound) / span) * size.width).clamped(to: 1...(size.width - 1))
                let held = stop == caught
                let h: CGFloat = held ? 8 : 4.5
                ctx.fill(Path(roundedRect: CGRect(x: x - 0.75, y: size.height - h, width: 1.5, height: h), cornerRadius: 0.75),
                         with: .color(Theme.pencil.opacity(held ? 1 : 0.45)))
            }
        }
        .frame(height: 9)
        .padding(.horizontal, 6)
        .animation(Theme.pop, value: caught)
        .allowsHitTesting(false)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound > range.upperBound ? self : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// The + on an open card that adds another of its kind, shown on the canvas while it is pointed at.
struct MoreButton: View {
    @Environment(DocumentStore.self) private var store
    let item: AddBar.Item
    @State private var hovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
            .frame(width: 20, height: 20)
            .background { Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0)) }
            .contentShape(Circle())
            .onHover { inside in
                hovering = inside
                store.showPreview(item.id, inside ? item.change : nil)
            }
            .onTapGesture {
                store.showPreview(item.id, nil)
                hovering = false
                withAnimation(Theme.unfold) {
                    if let add = item.add { add() } else { store.updateSelection(item.action, item.change) }
                    store.openAspect = item.aspect
                }
            }
            .onDisappear { if hovering { store.showPreview(item.id, nil) } }
            .help(Text(item.help))
            .accessibilityLabel(Text(item.help))
            .accessibilityAddTraits(.isButton)
    }
}

/// The × that takes a card's thing away.
struct RemoveButton: View {
    let help: LocalizedStringResource
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
            .frame(width: 20, height: 20)
            .background { Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0)) }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture { withAnimation(Theme.unfold) { action() } }
            .help(Text(help))
            .accessibilityLabel(Text(help))
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Coming and going

/// A card coming in for something just added: the dashed outline it was offered in fills in as
/// its room opens.
struct Materialize: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : 0.95, anchor: .top)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.ink3, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .opacity(phase.isIdentity ? 0 : 1)
            }
    }
}

/// A card for something taken away, thrown off the panel to the left.
struct ThrowOff: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(x: phase.isIdentity ? 0 : -320)
            .rotationEffect(.degrees(phase.isIdentity ? 0 : -5), anchor: .trailing)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

extension AnyTransition {
    /// How a card comes and goes: unfolding into the stack, filling in from dashes, and thrown
    /// off to the left as the stack closes up.
    static var card: AnyTransition {
        .asymmetric(insertion: AnyTransition(Unfold()).combined(with: AnyTransition(Materialize())), removal: AnyTransition(ThrowOff()))
    }
}

// MARK: - Small pictures

/// A ring filled from the left as far as there is of something, such as the layer's opacity.
struct LevelGlyph: View {
    let level: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .frame(width: 14 * min(max(level, 0), 1))
                .frame(width: 14, alignment: .leading)
                .mask(Circle())
            Circle().strokeBorder(lineWidth: 1.4)
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Placing on the artboard

/// The artboard in small, with the layer on it to drag into place. It clicks to the artboard's
/// edges and middle, and the trackpad ticks as it does.
struct PlacePad: View {
    @Environment(DocumentStore.self) private var store
    let board: Node
    /// The layer's frame on the artboard.
    let frame: CGRect
    /// Moves the layer's frame to a new top left.
    let move: (CGPoint) -> Void
    @State private var from: CGPoint?
    @State private var caught: (x: CGFloat?, y: CGFloat?) = (nil, nil)

    var body: some View {
        let size = board.frame.size
        let s = min((Inspector.content - 32) / max(size.width, 1), 132 / max(size.height, 1))
        let mini = CGSize(width: size.width * s, height: size.height * s)
        ZStack(alignment: .topLeading) {
            FillSwatch(fill: board.fill, radius: 2)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.pencilWash)
                .overlay { RoundedRectangle(cornerRadius: 1.5, style: .continuous).strokeBorder(Theme.pencil, lineWidth: 1) }
                .frame(width: max(frame.width * s, 4), height: max(frame.height * s, 4))
                .offset(x: frame.minX * s, y: frame.minY * s)
                .pointerStyle(.grabIdle)
                .gesture(dragging(scale: s))
            if let x = caught.x {
                Rectangle().fill(Theme.pencil).frame(width: 1, height: mini.height + 12).offset(x: x * s - 0.5, y: -6)
            }
            if let y = caught.y {
                Rectangle().fill(Theme.pencil).frame(width: mini.width + 12, height: 1).offset(x: -6, y: y * s - 0.5)
            }
        }
        .frame(width: mini.width, height: mini.height, alignment: .topLeading)
        .shadow(color: Theme.shadow.opacity(0.18), radius: 2, y: 1)
        .frame(maxWidth: .infinity)
        .frame(height: mini.height + 28)
        .well(radius: 10)
        .help("Drag the layer to place it on the artboard. It clicks to the edges and the middle.")
    }

    private func dragging(scale s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if from == nil {
                    from = frame.origin
                    store.beginGesture()
                }
                guard let from else { return }
                let w = board.frame.width, h = board.frame.height
                var p = CGPoint(x: from.x + g.translation.width / s, y: from.y + g.translation.height / s)
                // Each stop: where the layer's top left goes, and where its guide is drawn.
                let xs: [(CGFloat, CGFloat)] = [(0, 0), ((w - frame.width) / 2, w / 2), (w - frame.width, w)]
                let ys: [(CGFloat, CGFloat)] = [(0, 0), ((h - frame.height) / 2, h / 2), (h - frame.height, h)]
                let reach = 5 / s
                let cx = xs.first { abs($0.0 - p.x) <= reach }, cy = ys.first { abs($0.0 - p.y) <= reach }
                if let cx { p.x = cx.0 }
                if let cy { p.y = cy.0 }
                if (cx?.1, cy?.1) != (caught.x, caught.y), cx != nil || cy != nil {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                caught = (cx?.1, cy?.1)
                move(CGPoint(x: p.x.rounded(), y: p.y.rounded()))
            }
            .onEnded { _ in
                from = nil
                caught = (nil, nil)
                store.endGesture("Move")
            }
    }
}
