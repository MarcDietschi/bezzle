import SwiftUI
import AppKit

/// The film's timeline, on a card floating at the foot of the canvas while the design is animated.
/// A ruler of seconds over a ruled sheet: the camera's line first, then one for each layer that
/// moves, each key a bead on it. A bead is filled where the layer is away from the design and
/// hollow where it is as designed, so a line reads as what it does: out, and home again.
///
/// Everything is taken by hand (`FilmHand`). A press on the ruler, or on the playhead's line
/// down the sheet, moves the playhead, which catches on keys as it passes them; a bead dragged
/// moves its key, a line's band dragged moves its whole motion, and the flag at the end sets how
/// long the film runs. While something is dragged the seconds hold still under it; let go, the
/// film fits the card again. Bare sheet only clicked puts the playhead there; dragged, it draws a
/// marquee that picks the keys under it, with Shift adding to those picked and letting go of
/// those among them it catches again, and Escape gives back what was picked before.
///
/// A pinch looks at the film closer, about the moment under the pointer, and two fingers then
/// move it along; a double tap with two fingers, or pinching back out, shows the whole film
/// again. The wheel does the same with Command, Option or Control held, as on the canvas, and
/// with Shift moves it along (`FilmFingers`). How close it is looked at is the viewer's own.
struct FilmTimeline: View {
    let store: DocumentStore
    @Environment(MenuHost.self) private var menus
    @State private var hand: FilmHand
    @State private var fingers: FilmFingers

    init(store: DocumentStore) {
        self.store = store
        let hand = FilmHand(store: store)
        hand.escapeDown = FilmHand.escapeOnKeyboard
        _hand = State(initialValue: hand)
        _fingers = State(initialValue: FilmFingers(hand: hand))
    }

    static let rowHeight: CGFloat = 24
    static let rulerHeight: CGFloat = 24
    /// How many lines the card shows of a film that has this many: four at least, and seven at
    /// most, past which they scroll.
    static func shown(of lines: Int) -> Int { min(max(lines, 4), 7) }
    /// How much of the canvas's foot the card takes while a film of this many lines is on it,
    /// with the room under it: what the film's artboard is kept clear of.
    static func foot(lines: Int) -> CGFloat { 44 + rulerHeight + CGFloat(shown(of: lines)) * rowHeight + 6 + 14 }

    /// How wide the names are beside a sheet, of a card this wide inside.
    static func names(in width: CGFloat) -> CGFloat { min(150, max(104, width * 0.22)) }
    /// How wide the sheet is beside them: where the moments lie.
    static func sheet(in width: CGFloat) -> CGFloat { max(width - names(in: width), 60) }

    var body: some View {
        let board = store.filmBoard
        let rows = board.map { FilmRow.rows(of: $0, open: store.film.open) } ?? []
        let length = board?.filmLength ?? MotionTiming.shortest
        let shown = Self.shown(of: rows.count)
        VStack(spacing: 0) {
            FilmHeader(store: store, hand: hand, once: board?.film?.once == true)
            Hairline()
            GeometryReader { geo in
                let names = Self.names(in: geo.size.width)
                let scale = hand.scale(width: Self.sheet(in: geo.size.width))
                sheet(rows, board: board, length: length, names: names, scale: scale, shown: shown)
            }
            .frame(height: Self.rulerHeight + CGFloat(shown) * Self.rowHeight + 6)
            // Where two fingers and the wheel are the timeline's.
            .background { FilmGround(fingers: fingers) }
        }
        .frame(maxWidth: 1040)
        .card(radius: 18, lifted: true)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Theme.spring, value: shown)
        .onChange(of: store.film.board) { hand.held = nil }
        .onAppear {
            fingers.menus = menus
            fingers.watch()
        }
        .onDisappear { fingers.rest() }
    }

    // MARK: The sheet

    private func sheet(_ rows: [FilmRow], board: Node?, length: Double, names: CGFloat, scale: FilmScale, shown: Int) -> some View {
        let tall = CGFloat(shown) * Self.rowHeight
        let still = hand.drag != nil
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                FilmRuler(scale: scale, length: length, fixed: board?.film?.length != nil, hot: hand.hot.end || hand.drag?.kind == .length)
                    .frame(width: scale.width, height: Self.rulerHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard hand.drag == nil else { return }
                        if case .active(let p) = phase { hand.hot = hand.pointRuler(p, scale: scale, length: length) } else { hand.hot = FilmHand.Hot() }
                    }
                    .pointerStyle(hand.hot.end ? .frameResize(position: .trailing) : .default)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if hand.drag == nil { hand.pressRuler(at: g.startLocation, scale: scale, length: length, clicks: NSApp.currentEvent?.clickCount ?? 1) }
                            hand.dragged(to: g.location, by: g.translation.width, rows: rows, scale: scale, length: length, flags: NSEvent.modifierFlags)
                        }
                        .onEnded { _ in hand.ended(scale: scale, flags: NSEvent.modifierFlags) })
                    .padding(.leading, names)
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                FilmName(store: store, row: row, picked: hand.picked(row), open: store.film.open.contains(row.layer))
                                    .frame(height: Self.rowHeight)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: names, alignment: .leading)
                        tracks(rows, scale: scale, length: length, least: tall, still: still)
                    }
                    .frame(minHeight: tall, alignment: .top)
                    .animation(still ? nil : Theme.spring, value: rows.map(\.id))
                }
                .scrollIndicators(.never)
                .frame(height: tall)
            }
            // Within the sheet: moved along, a film looked at closer takes the playhead out of sight.
            FilmPlayhead(store: store, scale: scale, height: Self.rulerHeight + tall)
                .frame(width: scale.width, height: Self.rulerHeight + tall, alignment: .topLeading)
                .clipped()
                .offset(x: names)
                .allowsHitTesting(false)
            // Which part of the film shows, while not all of it does.
            FilmThumb(scale: scale, whole: FilmScale.span(for: length), shown: hand.zoomed)
                .frame(width: scale.width, height: 3)
                .offset(x: names, y: Self.rulerHeight + tall + 1.5)
                .allowsHitTesting(false)
        }
        // Whatever shows other seconds glides there, but under a hand: a drag holds the seconds
        // still, and two fingers move them with nothing gliding (`FilmHand.look`).
        .animation(still ? nil : Theme.spring, value: [scale.span, scale.start])
    }

    private func tracks(_ rows: [FilmRow], scale: FilmScale, length: Double, least: CGFloat, still: Bool) -> some View {
        let tall = max(CGFloat(rows.count) * Self.rowHeight, least)
        let keys = store.film.keys
        let hot = hand.hot
        return ZStack(alignment: .topLeading) {
            Ruled(step: Self.rowHeight)
            // Past the film's end, the sheet is in shade: what is keyed there does not play.
            Rectangle()
                .fill(Theme.ink.opacity(0.05))
                .frame(width: max(scale.width - scale.x(length), 0))
                .offset(x: scale.x(length))
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    FilmTrack(row: row, scale: scale,
                              picked: Set(keys.filter { row.holds($0) }.map(\.ms)),
                              hot: hot.row == row.id ? hot.key?.ms : nil,
                              band: hot.band == row.id || (hand.drag?.kind == .band && hot.row == row.id), still: still)
                        .frame(width: scale.width, height: Self.rowHeight)
                        .background {
                            if hand.picked(row) { Theme.pencilWash.opacity(row.single ? 0.35 : 0.7) }
                        }
                        .transition(.opacity)
                }
            }
            FilmMarqueeMark(hand: hand, scale: scale, tall: tall)
        }
        .frame(width: scale.width, height: tall, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard hand.drag == nil else { return }
            if case .active(let p) = phase { hand.hot = hand.point(p, rows: rows, scale: scale) } else { hand.hot = FilmHand.Hot() }
        }
        .pointerStyle(hand.drag?.kind == .band ? .grabActive : hot.band != nil ? .grabIdle : .default)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if hand.drag == nil {
                    hand.press(at: g.startLocation, rows: rows, scale: scale, flags: NSEvent.modifierFlags, clicks: NSApp.currentEvent?.clickCount ?? 1)
                }
                hand.dragged(to: g.location, by: g.translation.width, rows: rows, scale: scale, length: length, flags: NSEvent.modifierFlags)
            }
            .onEnded { _ in hand.ended(scale: scale, flags: NSEvent.modifierFlags) })
        .contextMenuReplacement { at in
            let entries = hand.menu(rows: rows, scale: scale)
            if !entries.isEmpty { menus.show(at: at, width: 200, entries: entries) }
        }
    }
}

/// The row above the timeline: play, the clock, a key here, how the keys in hand are come to,
/// and whether the film goes round. A view of its own, as what it shows depends on the playhead:
/// moving that draws this row again, and not every line of the timeline under it; and it reads the
/// panels' moment, so a scrub draws it again no more than thirty times a second.
private struct FilmHeader: View {
    let store: DocumentStore
    /// Only told what is done here, and read nothing of: what the hand holds changes under a
    /// scrub, and this row is not to be drawn again for it.
    let hand: FilmHand
    let once: Bool

    var body: some View {
        // With room for it, a spring's bounce stands beside the paces to the number; on a narrow
        // card the Spring chip alone sets it, dragged sideways.
        ViewThatFits(in: .horizontal) {
            row(exact: true)
            row(exact: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    private func row(exact: Bool) -> some View {
        let playing = store.film.playing
        // At the panels' moment, which a scrub catches up with thirty times a second.
        let t = store.panelTime
        let inHand = store.hasKeysToRemove(at: t)
        let pace = inHand ? store.sharedPace(at: t) : nil
        let springs = pace == .spring
        let bounce = springs ? store.sharedBounce(at: t) : nil
        let hold = store.holdState(at: t)
        return HStack(spacing: 10) {
            Button { store.toggleFilm() } label: {
                ZStack {
                    Circle().fill(playing ? Theme.pencil : Theme.ink.opacity(0.06))
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(playing ? .white : Theme.ink2)
                        .offset(x: playing ? 0 : 1)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
            }
            .buttonStyle(Pressable())
            .help(playing ? Text("Stop the film  Space") : Text("Play the film  Space"))
            .animation(Theme.spring, value: playing)
            FilmClock(store: store)
            Spacer(minLength: 4)
            if exact {
                // How far past its key a spring goes. Its room is always kept, so nothing moves
                // as the keys in hand turn to springs: it is only there for those.
                // Named beside its number, as the panel's cards name theirs: a word that is long in
                // one language keeps its letters, and the row is left out where it has no room.
                HStack(spacing: 6) {
                    Text("Bounce")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .fixedSize()
                    NumberField(label: .verbatim(""), value: bounce.map { ($0 * 100).rounded() }, unit: "%", range: 0...100, step: 5, scrub: 0.5, decimals: 0,
                                action: "Bounce") { store.setBounce($0 / 100) }
                        .frame(width: 76)
                        .accessibilityLabel(Text("Bounce"))
                }
                .help("How far a spring goes past its key before it comes to rest")
                .opacity(springs ? 1 : 0)
                .allowsHitTesting(springs)
                .accessibilityHidden(!springs)
                .animation(Theme.quick, value: springs)
            }
            HoldBead(state: hold) {
                if store.holdState == .here { store.removeFilmKeys() } else { store.holdHere() }
            }
            HStack(spacing: 1) {
                ForEach(MotionEase.Kind.allCases, id: \.self) { kind in
                    // The chosen Spring chip draws the springs' own bounce, and dragged, sets it.
                    let dial = kind == .spring && springs
                    PaceChip(kind: kind, chosen: pace == kind, bounce: dial ? bounce : nil, turned: dial ? { dx in
                        if let dx { hand.turnBounce(by: dx) } else { hand.bounceTurned() }
                    } : nil) { store.setPace(kind) }
                }
            }
            // Always there, so nothing moves as keys come into hand: only readier.
            .opacity(inHand ? 1 : 0.3)
            .allowsHitTesting(inHand)
            .animation(Theme.quick, value: inHand)
            // A dial taken from under the hand, as when the film plays on past the springs: what
            // it had set by then is the step, and nothing is left open.
            .onChange(of: springs) { _, still in
                if !still { hand.bounceTurned() }
            }
            .onDisappear { hand.bounceTurned() }
            Hairline(vertical: true)
                .frame(height: 16)
            RoundButton(on: !once, help: once ? "Plays once and stops. Click to play it round and round." : "Plays round and round. Click to play it once.") {
                store.setFilm(once ? "Play Round and Round" : "Play Once") { $0.once = once ? nil : true }
            }
        }
    }
}

/// A line's name, beside its beads: a click picks what it is of, and the chevron opens it into
/// a line for each property.
private struct FilmName: View {
    let store: DocumentStore
    let row: FilmRow
    let picked: Bool
    let open: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if !row.single {
                Chevron(color: hovering || open ? Theme.ink2 : Theme.ink4)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: 14, height: Self.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.spring) {
                            if open { store.film.open.remove(row.layer) } else { store.film.open.insert(row.layer) }
                        }
                    }
                    .opacity(row.marks.isEmpty ? 0 : 1)
                Group {
                    if let kind = row.kind { KindGlyph(kind: kind) } else { CameraGlyph() }
                }
                .foregroundStyle(picked ? Theme.pencil : Theme.ink2)
                .frame(width: 15, height: 15)
            } else {
                Color.clear.frame(width: 34, height: 1)
            }
            Text(verbatim: row.name)
                .font(.system(size: row.single ? 11 : 12, weight: picked && !row.single ? .medium : .regular))
                .foregroundStyle(row.single ? Theme.ink3 : picked ? Theme.pencil : Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background {
            if picked { Theme.pencilWash.opacity(row.single ? 0.35 : 0.7) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if row.camera {
                store.pickCamera()
            } else if NSEvent.modifierFlags.contains(.shift) {
                if let i = store.selection.firstIndex(of: row.layer) { store.selection.remove(at: i) } else { store.selection.append(row.layer) }
            } else {
                store.selection = [row.layer]
            }
        }
        .animation(Theme.quick, value: picked)
    }

    private static let height = FilmTimeline.rowHeight
}

/// A line's keys: the band they span, and a bead for each.
private struct FilmTrack: View {
    let row: FilmRow
    let scale: FilmScale
    /// The moments of its keys that are picked, in thousandths of a second.
    let picked: Set<Int>
    /// The moment of the bead the pointer is on.
    let hot: Int?
    /// Whether the pointer is on its band, or has it in hand.
    let band: Bool
    /// While something is dragged along the sheet, nothing here glides: it follows the hand.
    let still: Bool

    var body: some View {
        let own = row.single
        ZStack(alignment: .leading) {
            if let first = row.marks.first, let last = row.marks.last, last.t > first.t {
                Capsule()
                    .fill(Theme.ink.opacity(band ? 0.13 : own ? 0.05 : 0.075))
                    .frame(width: scale.x(last.t) - scale.x(first.t) + (own ? 11 : 15), height: own ? 11 : 15)
                    .offset(x: scale.x(first.t) - (own ? 5.5 : 7.5))
                    .animation(Theme.quick, value: band)
            }
            if own {
                PaceLines(marks: row.marks, scale: scale)
            }
            ForEach(row.marks, id: \.t) { mark in
                let ms = Int((mark.t * 1000).rounded())
                Bead(home: mark.home, given: mark.given, picked: picked.contains(ms), hot: hot == ms, small: own, gone: mark.gone)
                    .offset(x: scale.x(mark.t) - Bead.room / 2)
                    // Grown out of its own middle, which the offset puts away from the room it is laid out in.
                    .transition(.scale(scale: 0.2, anchor: UnitPoint(x: scale.x(mark.t) / Bead.room, y: 0.5)).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(still ? nil : Theme.pop, value: row.marks.map(\.t))
    }
}

/// A key: filled where the layer is away from the design, hollow where it is as designed.
private struct Bead: View {
    let home: Bool
    let given: Bool
    let picked: Bool
    let hot: Bool
    let small: Bool
    /// A look's key for what the design no longer has: it changes nothing, and is faint.
    var gone = false

    /// The room a bead is laid out in, whatever its size.
    static let room: CGFloat = 20

    var body: some View {
        let d: CGFloat = small ? 7 : 9
        let ink = picked ? Theme.pencil : given ? Theme.ink3 : Theme.ink
        ZStack {
            Circle()
                .fill(Theme.pencil.opacity(picked ? 0.2 : 0))
                .frame(width: d + 9, height: d + 9)
            Circle()
                .fill(home ? Theme.card : ink)
                .overlay { Circle().strokeBorder(ink, lineWidth: small ? 1.2 : 1.5) }
                .frame(width: d, height: d)
        }
        .scaleEffect(hot ? 1.3 : 1)
        .opacity(gone ? 0.35 : 1)
        .frame(width: Self.room, height: Self.room)
        .animation(Theme.pop, value: hot)
        .animation(Theme.quick, value: picked)
    }
}

/// How each key of a property is come to, drawn between it and the one before: flat where it
/// waits, steep where it hurries.
private struct PaceLines: View, Animatable {
    let marks: [FilmRow.Mark]
    /// As the ruler has them (`FilmRuler`), so the lines glide with the beads they join.
    var perSecond: CGFloat
    var origin: CGFloat

    init(marks: [FilmRow.Mark], scale: FilmScale) {
        self.marks = marks
        perSecond = scale.perSecond
        origin = scale.x(0)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(perSecond, origin) }
        set {
            perSecond = newValue.first
            origin = newValue.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard marks.count > 1 else { return }
            let rise: CGFloat = 7
            for i in 1..<marks.count {
                guard let pace = marks[i].pace else { continue }
                let a = origin + CGFloat(marks[i - 1].t) * perSecond + 5, b = origin + CGFloat(marks[i].t) * perSecond - 5
                // Only what is in sight: a film looked at closer has long stretches out of it.
                guard b - a > 10, b > 0, a < size.width else { continue }
                var path = Path()
                // The part of the stretch in sight, a point for every three across it.
                let from = max(a, -3), to = min(b, size.width + 3)
                let steps = max(8, Int((to - from) / 3))
                for s in 0...steps {
                    let x = from + (to - from) * CGFloat(s) / CGFloat(steps)
                    let u = Double((x - a) / (b - a))
                    let p = CGPoint(x: x, y: size.height / 2 + rise / 2 - rise * CGFloat(PaceChip.progress(pace, u)))
                    if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(Theme.ink.opacity(0.34)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The marquee dragged over the keys, as the canvas draws its own. A view of its own, as it
/// changes with every step of the drag: the lines under it are drawn again only as keys come
/// into it or leave it.
private struct FilmMarqueeMark: View {
    let hand: FilmHand
    let scale: FilmScale
    /// How tall the lines are in all.
    let tall: CGFloat

    var body: some View {
        if let marquee = hand.marquee {
            // No further than just past the sheet's sides, where it is cut off: a sheet looked
            // at closer has moments far out of sight, and nothing here is laid out by them.
            let r = marquee.rect(on: scale).intersection(CGRect(x: -2, y: -2, width: scale.width + 4, height: tall + 4))
            if !r.isNull {
                Rectangle()
                    .fill(Theme.pencil.opacity(0.08))
                    .overlay { Rectangle().strokeBorder(Theme.pencil.opacity(0.8), lineWidth: 1) }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
                    .transition(.identity)
            }
        }
    }
}

/// The sheet's ruling: a hairline under every line, whether one is written on it yet or not.
private struct Ruled: View {
    let step: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var y = step
            var path = Path()
            while y < size.height + 0.5 {
                path.move(to: CGPoint(x: 0, y: y - 0.25))
                path.addLine(to: CGPoint(x: size.width, y: y - 0.25))
                y += step
            }
            ctx.stroke(path, with: .color(Theme.ink.opacity(0.07)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The ruler and the playhead

/// The seconds along the top, and the flag where the film ends: hollow while the film is as long
/// as its keys, filled once its length was set.
struct FilmRuler: View, Animatable {
    /// How wide a second is, and where the film's start lies along the ruler: what a change of
    /// the seconds shown glides between, each stroke moving as the beads under it do.
    var perSecond: CGFloat
    var origin: CGFloat
    let length: Double
    let fixed: Bool
    let hot: Bool

    init(scale: FilmScale, length: Double, fixed: Bool, hot: Bool) {
        perSecond = scale.perSecond
        origin = scale.x(0)
        self.length = length
        self.fixed = fixed
        self.hot = hot
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(perSecond, origin) }
        set {
            perSecond = newValue.first
            origin = newValue.second
        }
    }

    /// The seconds between numbered strokes, and how many parts each is ruled in, so the numbers
    /// stand clear of each other: fewer of them as the film is looked at from further off, and
    /// more, down to twentieths of a second, as it is looked at closer. The strokes between
    /// come down to hundredths, a key's finest step, once those are wide enough to tell apart.
    static func step(_ perSecond: CGFloat) -> (Double, Int) {
        let steps: [(Double, Int)] = [(0.05, 5), (0.1, 2), (0.2, 4), (0.5, 5), (1, 10), (2, 4), (5, 5), (10, 10), (20, 4), (30, 6), (60, 6), (120, 4), (300, 5)]
        let (major, parts) = steps.first { CGFloat($0.0) * perSecond >= 52 } ?? (600, 10)
        // Tenths are halved into twentieths, where a key steps; closer still, into hundredths.
        if major == 0.1, perSecond >= 600 { return (major, 10) }
        return (major, parts)
    }

    /// The strokes a ruler this wide draws: the first stroke's number, counted in parts from
    /// the film's start, and one past the last. Only those in sight, with the numbered one
    /// before them whose number may still reach in, however long the film and however close.
    static func strokes(perSecond: CGFloat, origin: CGFloat, width: CGFloat) -> (first: Int, end: Int, major: Double, parts: Int) {
        let (major, parts) = step(perSecond)
        let part = CGFloat(major / Double(parts)) * perSecond
        guard part > 0, part.isFinite, origin.isFinite else { return (0, 0, major, parts) }
        var first = max(Int(((-origin) / part).rounded(.down)), 0)
        first = first / parts * parts
        // As before: none on the last two points, where its number would have no room.
        let end = max(Int(((width - 2 - origin) / part).rounded(.down)) + 1, first)
        return (first, end, major, parts)
    }

    var body: some View {
        Canvas { ctx, size in
            let rule = Self.strokes(perSecond: perSecond, origin: origin, width: size.width)
            let minor = rule.major / Double(rule.parts)
            var strokes = Path(), fine = Path()
            for i in rule.first..<rule.end {
                let t = Double(i) * minor
                let x = origin + CGFloat(t) * perSecond
                if x > size.width - 2 { break }
                let whole = i % rule.parts == 0
                let past = t > length + 0.0001
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - (whole ? 7 : 3.5)))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                if past { fine.addPath(tick) } else { strokes.addPath(tick) }
                if whole {
                    let label = ctx.resolve(Text(verbatim: Self.label(t, step: rule.major))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink.opacity(past ? 0.22 : 0.46)))
                    ctx.draw(label, at: CGPoint(x: x + 3.5, y: size.height - 12), anchor: .leading)
                }
            }
            ctx.stroke(strokes, with: .color(Theme.ink.opacity(0.3)), lineWidth: 1)
            ctx.stroke(fine, with: .color(Theme.ink.opacity(0.14)), lineWidth: 1)
            // The film's end.
            let x = origin + CGFloat(length) * perSecond
            var pole = Path()
            pole.move(to: CGPoint(x: x, y: 5))
            pole.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(pole, with: .color(Theme.ink.opacity(hot ? 0.9 : 0.55)), lineWidth: 1.25)
            let grow: CGFloat = hot ? 1.5 : 0
            var flag = Path()
            // It flies back over the film, clear of the number beside its pole.
            flag.move(to: CGPoint(x: x, y: 4.5 - grow))
            flag.addLine(to: CGPoint(x: x - 8 - grow, y: 8))
            flag.addLine(to: CGPoint(x: x, y: 11.5 + grow))
            flag.closeSubpath()
            ctx.fill(flag, with: .color(fixed ? Theme.ink.opacity(hot ? 0.95 : 0.8) : Theme.card))
            ctx.stroke(flag, with: .color(Theme.ink.opacity(hot ? 0.9 : 0.6)), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
        }
        .help("Where the film ends. Drag to set its length; double click to let it follow the keys.")
    }

    /// A stroke's number: seconds, and from a minute on, minutes and seconds; with the parts of
    /// a second where the strokes are closer than a second apart.
    static func label(_ t: Double, step: Double = 1) -> String {
        guard t >= 60 else { return t.formatted(.number.precision(.fractionLength(0...2))) }
        guard step < 1 else {
            let s = Int(t.rounded())
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        let hundredths = Int((t * 100).rounded())
        let rest = Double(hundredths % 6000) / 100
        return "\(hundredths / 6000):" + rest.formatted(.number.precision(.integerAndFractionLength(integerLimits: 2...2, fractionLimits: 0...2)))
    }
}

/// Which part of the film a sheet looked at closer shows: a stroke under the lines, as long
/// against the sheet as that part is against the film. Not there while the whole film shows.
private struct FilmThumb: View {
    let scale: FilmScale
    let whole: Double
    let shown: Bool

    var body: some View {
        let room = max(scale.width - FilmScale.inset * 2, 1)
        let long = max(room * CGFloat(min(scale.span / whole, 1)), 18)
        let along = whole > scale.span ? CGFloat(scale.start / (whole - scale.span)) : 0
        Capsule()
            .fill(Theme.ink.opacity(0.2))
            .frame(width: long, height: 3)
            .offset(x: FilmScale.inset + (room - long) * min(max(along, 0), 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(shown ? 1 : 0)
            .animation(Theme.quick, value: shown)
    }
}

/// The playhead: a pencil line down the sheet, with a tab in the ruler to take it by. It reads
/// the moment the film shows, so it alone is drawn again as the film plays.
private struct FilmPlayhead: View {
    let store: DocumentStore
    let scale: FilmScale
    let height: CGFloat

    var body: some View {
        let x = scale.x(store.film.live)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.pencil)
                .frame(width: 1.25, height: height)
            Tab()
                .fill(Theme.pencil)
                .frame(width: 11, height: 12)
                .shadow(color: Theme.shadow.opacity(0.2), radius: 1.5, y: 1)
        }
        .frame(width: 11, height: height, alignment: .top)
        .offset(x: x - 5.5)
    }

    /// A tab that comes to a point over its line.
    private nonisolated struct Tab: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let shoulder = r.minY + r.height * 0.5, round: CGFloat = 2.5
            p.move(to: CGPoint(x: r.minX + round, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - round, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + round), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: shoulder))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: shoulder))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + round))
            p.addQuadCurve(to: CGPoint(x: r.minX + round, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }
}

/// The moment the film shows, in seconds. A view of its own, as it changes with every frame
/// while the film plays.
private struct FilmClock: View {
    let store: DocumentStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: store.film.live.formatted(.number.precision(.fractionLength(2))))
                .font(Theme.serif(15, weight: .medium).monospacedDigit())
                .foregroundStyle(store.film.playing ? Theme.pencil : Theme.ink)
            Text(verbatim: "s")
                .font(Theme.serif(12))
                .foregroundStyle(Theme.ink3)
        }
        .frame(width: 58, alignment: .leading)
        .animation(Theme.quick, value: store.film.playing)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The controls above

/// Holds what is picked as it is at the playhead: a bead to press, hollow while there is no key
/// here and filled where there is one, which a press then takes away.
private struct HoldBead: View {
    let state: FilmKeyState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.ink.opacity(hovering && state != .none ? 0.08 : 0))
            Circle()
                .fill(state == .here ? Theme.pencil : Theme.card)
                .overlay { Circle().strokeBorder(state == .here ? Theme.pencil : Theme.ink2, lineWidth: 1.5) }
                .frame(width: 10, height: 10)
                .scaleEffect(state == .here ? 1.1 : 1)
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .opacity(state == .none ? 0.3 : 1)
        .allowsHitTesting(state != .none)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(state == .here ? Text("A key here. Click to take it away.") : Text("Hold it here: a key at the playhead  K"))
        .animation(Theme.pop, value: state)
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text("Hold Here"))
        .accessibilityAddTraits(.isButton)
    }
}

/// A way of coming to a key, as the curve it is.
struct PaceChip: View {
    let kind: MotionEase.Kind
    let chosen: Bool
    /// A spring's own bounce, which the chip's curve then tells. Nil draws the chip's usual picture.
    var bounce: Double? = nil
    /// Makes the chip a dial, as the chosen Spring chip is for its bounce: told how far it is
    /// dragged sideways, and nil when it is let go.
    var turned: ((CGFloat?) -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false
    /// Whether the press under way has turned the dial, and so is no click.
    @State private var turning = false

    var body: some View {
        Canvas { ctx, size in
            let box = CGRect(x: 6, y: 6.5, width: size.width - 12, height: size.height - 13)
            var path = Path()
            let steps = 28
            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let p = CGPoint(x: box.minX + box.width * CGFloat(u), y: box.maxY - box.height * CGFloat(MotionEase.progress(kind, u, bounce: bounce.map(Self.drawn) ?? Self.usual)) * (kind == .spring ? 0.8 : 1))
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            let color = chosen ? Theme.pencil : Theme.ink.opacity(hovering ? 0.9 : 0.6)
            // Auto is read from the keys round it: its curve is only pencilled in.
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: kind == .auto ? [2.2, 2.6] : []))
        }
        .frame(width: 28, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One or the other: a click waited for beside the drag would keep the drag waiting until
        // the pointer is let go, and the dial would never turn under the hand.
        .gesture(turned == nil ? TapGesture().onEnded(action) : nil)
        .gesture(turned == nil ? nil : DragGesture(minimumDistance: 0)
            .onChanged { g in
                // A press that goes nowhere is a click; from three points on it turns the dial.
                guard turning || abs(g.translation.width) >= 3 else { return }
                turning = true
                turned?(g.translation.width)
            }
            .onEnded { _ in
                if turning {
                    turning = false
                    turned?(nil)
                } else {
                    action()
                }
            })
        .onChange(of: turned == nil) { _, plain in
            if plain { turning = false }
        }
        .pointerStyle(turned == nil ? .default : .frameResize(position: .trailing))
        .help(turned == nil ? Text(verbatim: MotionEase(kind: kind).title) : Text("Spring. Drag sideways to set its bounce."))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: chosen)
        .accessibilityLabel(Text(verbatim: MotionEase(kind: kind).title))
        .accessibilityValue(Text(verbatim: bounce.map { "\(Int(($0 * 100).rounded())) %" } ?? ""))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    /// The bounce the Spring chip's picture is drawn with, more than a spring usually has: at
    /// this size the usual one would not be seen to go past at all.
    static let usual = 0.55

    /// The bounce the chip draws for a spring's own: the same picture as ever at the usual
    /// bounce, a plain arrival with none, and all of it with all. A picture this small tells the
    /// whole dial that way; the line in the timeline is the true curve.
    static func drawn(_ bounce: Double) -> Double {
        let b = min(max(bounce, 0), 1), usually = MotionEase.spring().springBounce
        return b <= usually ? b / usually * usual : usual + (b - usually) / (1 - usually) * (1 - usual)
    }

    /// How far along a stretch is when `u` of its time has passed, however it is paced.
    static func progress(_ pace: MotionTrack.Pace, _ u: Double) -> Double {
        switch pace {
        case .curve(let kind, let bounce): MotionEase.progress(kind, u, bounce: bounce)
        case .setOff: MotionEase.setOff(u)
        case .setDown: MotionEase.setDown(u)
        case .onward: u
        }
    }
}

/// Whether the film goes round: an arrow that comes back to where it set off, in pencil while it does.
private struct RoundButton: View {
    let on: Bool
    let help: LocalizedStringResource
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "repeat")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(on ? Theme.pencil : Theme.ink3)
            .frame(width: 26, height: 26)
            .background(Circle().fill(on ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.08 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(Text(help))
            .animation(Theme.quick, value: hovering)
            .animation(Theme.quick, value: on)
            .accessibilityLabel(Text(help))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The camera, drawn small: a body with its lens, and the finder on top.
struct CameraGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let body = Path(roundedRect: CGRect(x: w * 0.1, y: h * 0.3, width: w * 0.8, height: h * 0.52), cornerRadius: 2)
            ctx.stroke(body, with: .foreground, style: style)
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.36, y: h * 0.42, width: w * 0.28, height: h * 0.28)), with: .foreground, style: style)
            var finder = Path()
            finder.move(to: CGPoint(x: w * 0.36, y: h * 0.3))
            finder.addLine(to: CGPoint(x: w * 0.42, y: h * 0.17))
            finder.addLine(to: CGPoint(x: w * 0.58, y: h * 0.17))
            finder.addLine(to: CGPoint(x: w * 0.64, y: h * 0.3))
            ctx.stroke(finder, with: .foreground, style: style)
        }
        .frame(width: 15, height: 15)
    }
}
