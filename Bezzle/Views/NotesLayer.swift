import SwiftUI
import AppKit

/// The notes in a design's margins. Each thread hangs on a pencil thread from its pin, the spot it
/// is about, or the loop drawn round the part it is about, to a card on the table beside its sheet,
/// never over the work (see `NotePlacement`). Where the table has no room for a card, the thread is
/// a flag on the sheet's edge. The threads have weight, as the prototype's do: a pin pulled away
/// drags its thread after it, sagging, and the card follows; let go on another layer, it catches
/// and pulls taut. A thread ticked off is ticked in pencil, its card tucked away and its thread
/// reeled in; one written arrives the other way round.
struct NotesLayer: View {
    let store: DocumentStore
    /// How tall each open card is, as it was last drawn. A shut card's height is known before it
    /// is drawn (`NoteCardSize`), so where it goes never waits on how it came out.
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var motion = NoteMotion()
    @State private var drag: NoteDrag?
    @State private var pointed: UUID?

    static let space = "notes"

    var body: some View {
        let _ = motion.tick
        let scene = scene()
        ZStack(alignment: .topLeading) {
            if !scene.isEmpty {
                ForEach(scene.ghosts, id: \.key) { ghost in
                    piece(ghost)
                }
                Canvas { ctx, _ in NoteInk.draw(scene, in: ctx) }
                    .allowsHitTesting(false)
                ForEach(scene.shown.filter { $0.place.kind != .lifted }, id: \.key) { shown in
                    piece(shown)
                }
                ForEach(scene.shown.filter { $0.place.kind == .lifted }, id: \.key) { shown in
                    piece(shown)
                }
                // The pins over everything, an open card too: always there to be pulled elsewhere.
                ForEach(scene.shown, id: \.key) { shown in
                    PinView(store: store, shown: shown, pointed: $pointed, drag: $drag, motion: motion)
                        .position(shown.pin)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onChange(of: store.selection) { if store.openThread != nil { store.openThread = nil } }
    }

    @ViewBuilder private func piece(_ shown: Shown) -> some View {
        switch shown.place.kind {
        case .flag:
            FlagView(store: store, shown: shown, pointed: $pointed)
        case .card, .lifted:
            NoteCard(store: store, shown: shown, pointed: $pointed)
                .frame(width: NotePlacement.width, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    guard shown.leaving == nil, shown.item.open || shown.item.draft else { return }
                    if abs((heights[shown.id] ?? 0) - h) > 0.5 { heights[shown.id] = h }
                }
                .modifier(Arrival(shown: shown))
                .offset(x: shown.frame.minX, y: shown.frame.minY)
        case .pin:
            EmptyView()
        }
    }

    // MARK: The scene

    /// A thread as the margin shows it.
    struct Item {
        var start: MarginNote
        var replies: [MarginNote]
        var draft = false
        var open = false
        var done = false
        var unread = false
        var color: Color
    }

    /// A thread where it is on screen this frame, on its way to where it goes.
    struct Shown {
        var id: UUID
        var key: String
        var item: Item
        var place: NotePlacement.Place
        var frame: CGRect
        var anchor: CGPoint
        var pin: CGPoint
        var area: CGRect?
        var sag: CGFloat = 0
        /// How far it is written in, 0…1.
        var born: Double = 1
        /// How far it has gone, 0…1, once it has.
        var leaving: Double?
        var tickedOff = false
        /// Coming or going as a card folds to a flag or a flag unfolds to a card, in place.
        var turned = false
        var lit = false
        var dragged = false
    }

    struct Scene {
        var shown: [Shown] = []
        var ghosts: [Shown] = []
        /// The loop being drawn with the note tool, on screen.
        var circle: CGRect?
        var isEmpty: Bool { shown.isEmpty && ghosts.isEmpty && circle == nil }
    }

    private func scene() -> Scene {
        Self.scene(store, drag: drag, pointed: pointed, heights: heights, motion: motion, canvas: store.canvas)
    }

    /// The margin as it is this frame: where every thread goes (`NotePlacement`), and where it is
    /// on its way there (`NoteMotion`). The one way the margin is worked out, drawn and tested.
    static func scene(_ store: DocumentStore, drag: NoteDrag?, pointed: UUID?, heights: [UUID: CGFloat], motion: NoteMotion,
                      canvas: NSView?, now: CFTimeInterval = CACurrentMediaTime()) -> Scene {
        let doc = store.doc
        // Ticked off, a thread leaves the margin; with the note tool out, it shows as a flag.
        let showDone = store.tool == .note
        var list = doc.threads.filter { showDone || !$0.start.isDone }.map { (start: $0.start, replies: $0.replies, draft: false) }
        if let d = store.draftNote { list.append((d, [], true)) }
        let circle = store.noteCircle
        if list.isEmpty && motion.idle && circle == nil { return Scene() }
        let vp = store.viewport
        // Every sheet, near or far: where a card goes must not depend on what is in sight.
        let obstacles = doc.nodes.filter { !$0.hidden }.map { vp.toView($0.isArtboard ? $0.frame : Geometry.bounds(of: $0)) }
        var wants: [NotePlacement.Want] = []
        var items: [UUID: (item: Item, spot: CGPoint, area: CGRect?)] = [:]
        for (start, replies, draft) in list {
            guard var spot = doc.spot(of: start).map(vp.toView) else { continue }
            var area = doc.area(of: start).map(vp.toView)
            if let drag, drag.id == start.id {
                // Pulled away, its spot leads the card along.
                spot = CGPoint(x: spot.x + drag.by.width, y: spot.y + drag.by.height)
                area = area?.offsetBy(dx: drag.by.width, dy: drag.by.height)
            }
            let sheet = doc.sheet(of: start)
            let home = sheet.map { vp.toView($0.isArtboard ? $0.frame : Geometry.bounds(of: $0)) }
            let open = draft || store.openThread == start.id
            let item = Item(start: start, replies: replies, draft: draft, open: open, done: start.isDone,
                            unread: !draft && store.isUnread(start.id), color: color(of: start, in: store))
            wants.append(NotePlacement.Want(id: start.id, spot: area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? spot, home: home,
                                            sheet: sheet?.id, height: height(start, replies, open: open, draft: draft, heights: heights, store: store),
                                            open: open, flagOnly: start.isDone, area: area))
            items[start.id] = (item, spot, area)
        }
        let places = NotePlacement.place(wants, around: obstacles, was: motion.kinds)
        return motion.settle(places, items, drag: drag, pointed: pointed, viewport: vp, circle: circle.map(vp.toView),
                             done: Set(doc.threads.filter(\.start.isDone).map(\.start.id)), canvas: canvas, now: now)
    }

    /// How tall a thread's card is: shut, as its words make it; open, as it was last drawn, or as
    /// it will about be the first time.
    private static func height(_ start: MarginNote, _ replies: [MarginNote], open: Bool, draft: Bool, heights: [UUID: CGFloat],
                               store: DocumentStore) -> CGFloat {
        if draft { return heights[start.id] ?? NoteCardSize.draft }
        if open { return heights[start.id] ?? NoteCardSize.open(start, replies, answering: !store.isReadOnly && !start.isDone) }
        return NoteCardSize.shut(start, answered: !replies.isEmpty)
    }

    private static func color(of note: MarginNote, in store: DocumentStore) -> Color {
        guard let replica = note.replica, !store.wrote(note) else { return Theme.pencil }
        return store.sharing?.live?.pencil(of: replica).color ?? Pencil.preferred(replica).color
    }
}

/// How tall a card is, worked out from its words as the card sets them: the same every time, so
/// a shut card's place in the margin is settled before it is drawn.
nonisolated enum NoteCardSize {
    static let padding: CGFloat = 10
    static let header: CGFloat = 16
    static let spacing: CGFloat = 9
    static let textSize: CGFloat = 12.5
    /// What `prose(12.5)` puts between lines.
    static let leading: CGFloat = (textSize * 0.5).rounded() / 2
    static let answeredRow: CGFloat = 14
    static let composer: CGFloat = 32
    /// The words' width: the card's, less its padding.
    static let measure = NotePlacement.width - 22

    static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: textSize)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// How many lines the words take on a card, up to `limit`.
    static func lines(_ text: String, limit: Int?) -> Int {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = leading
        let box = (text as NSString).boundingRect(with: CGSize(width: measure, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: NSFont.systemFont(ofSize: textSize), .paragraphStyle: style])
        let n = max(1, Int(((box.height + leading) / (lineHeight + leading)).rounded()))
        return limit.map { min(n, $0) } ?? n
    }

    static func words(_ text: String, limit: Int?) -> CGFloat {
        let n = CGFloat(lines(text, limit: limit))
        return n * lineHeight + (n - 1) * leading
    }

    /// A note with its writer above it.
    static func note(_ text: String, limit: Int?) -> CGFloat { header + 4 + words(text, limit: limit) }

    static func shut(_ start: MarginNote, answered: Bool) -> CGFloat {
        (2 * padding + note(start.text, limit: 3) + (answered ? spacing + answeredRow : 0)).rounded(.up)
    }

    static func open(_ start: MarginNote, _ replies: [MarginNote], answering: Bool) -> CGFloat {
        let notes = ([start] + replies).map { note($0.text, limit: nil) }.reduce(0, +)
        let between = CGFloat(replies.count) * (2 * spacing + 0.5)
        return (2 * padding + notes + between + (answering ? spacing + composer : 0)).rounded(.up)
    }

    static let draft: CGFloat = 2 * padding + header + spacing + 20
}

/// A pin being pulled: whose, and how far from where it was.
struct NoteDrag: Equatable {
    let id: UUID
    var by: CGSize
    /// What it would land on, let go of now.
    var over: UUID?
}

// MARK: - Motion

/// What moves the margin: a spring for each card toward where it goes, so a card makes way with
/// weight, a spring carrying a pulled pin, a loose one for each thread's sag, and the clock for
/// threads being written in and ticked off. It runs a display link of the canvas's own only while
/// something moves; at rest it costs nothing.
@MainActor @Observable
final class NoteMotion {
    /// Counted up each frame something moves, for the margin to be drawn again.
    private(set) var tick = 0
    @ObservationIgnored private var bodies: [UUID: Body] = [:]
    @ObservationIgnored private var ghosts: [Ghost] = []
    @ObservationIgnored private var viewport: Viewport?
    @ObservationIgnored private var last: CFTimeInterval = 0
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private(set) var moving = false
    @ObservationIgnored private var clock: NoteClock?

    static let writeIn = 0.62
    /// A card folding to a flag, or a flag unfolding to a card, in place.
    static let turn = 0.34
    static let tickOff = 0.95
    static let fade = 0.34
    /// The springs a card moves by: critically damped, so it goes straight where it is going
    /// and stops there, never past.
    static let stiffness: Double = 300
    static let damping: Double = 2 * stiffness.squareRoot()

    var idle: Bool { bodies.isEmpty && ghosts.isEmpty }

    /// How each thread showed the last time, for the margin to keep it so near the edge of having
    /// room (`NotePlacement.reluctance`).
    var kinds: [UUID: NotePlacement.Kind] { bodies.mapValues(\.kind) }

    private struct Body {
        var target: CGRect
        var kind: NotePlacement.Kind
        var side: NotePlacement.Side
        var offset = FlowSpring(at: .zero)
        var pin: FlowSpring?
        var sag: CGFloat = 0
        var sagSpeed: CGFloat = 0
        var born: CFTimeInterval?
        /// Born of a card folding to a flag or the other way, not written.
        var turned = false
        var done: Bool
        var last: NotesLayer.Shown?
    }

    private struct Ghost {
        enum Kind { case tickedOff, gone, turned }
        var shown: NotesLayer.Shown
        var since: CFTimeInterval
        var kind: Kind
        var lasts: Double {
            switch kind {
            case .tickedOff: NoteMotion.tickOff
            case .gone: NoteMotion.fade
            case .turned: NoteMotion.turn * 0.75
            }
        }
    }

    /// Cards and lifted cards are one shape; a flag another; a token on the table a third. Going
    /// from one to another is a turn in place, never a flight across the table.
    private static func shape(_ kind: NotePlacement.Kind) -> Int {
        switch kind {
        case .card, .lifted: 0
        case .flag: 1
        case .pin: 2
        }
    }

    /// A thread let go of on something: it pulls taut, with a shiver.
    func caught(_ id: UUID) {
        bodies[id]?.sagSpeed -= 210
        moving = true
    }

    func settle(_ places: [NotePlacement.Place], _ items: [UUID: (item: NotesLayer.Item, spot: CGPoint, area: CGRect?)],
                drag: NoteDrag?, pointed: UUID?, viewport vp: Viewport, circle: CGRect?, done: Set<UUID>,
                canvas: NSView?, now: CFTimeInterval = CACurrentMediaTime()) -> NotesLayer.Scene {
        let dt = moving ? min(max(now - last, 0), 1.0 / 30) : 0
        last = now
        // The view moving carries everything with it: nothing springs for that.
        let panned = viewport.map { $0 != vp } ?? true
        viewport = vp
        var still = true
        var shown: [NotesLayer.Shown] = []
        var present = Set<UUID>()
        for place in places {
            guard let entry = items[place.id] else { continue }
            let (item, spot, area) = (entry.item, entry.spot, entry.area)
            present.insert(place.id)
            var b = bodies[place.id] ?? Body(target: place.frame, kind: place.kind, side: place.side, born: seeded ? now : nil, done: item.done)
            if bodies[place.id] != nil {
                if item.done != b.done {
                    // Ticked off where it shows (the note tool out), or brought back: it is written in again.
                    if item.done, let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: .tickedOff)) }
                    b.offset = FlowSpring(at: .zero)
                    b.born = now
                    b.turned = false
                    b.done = item.done
                } else if Self.shape(b.kind) != Self.shape(place.kind) || (b.side != place.side && Self.shape(place.kind) == 0) {
                    // Folding to a flag or unfolding to a card, or a card going to the sheet's
                    // other side: the one goes where it is as the other comes where it goes, never
                    // sliding across the work and its pins.
                    if let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: .turned)) }
                    b.offset = FlowSpring(at: .zero)
                    b.born = now
                    b.turned = true
                } else if !panned {
                    let dx = b.target.minX - place.frame.minX, dy = b.target.minY - place.frame.minY
                    if abs(dx) > 0.5 || abs(dy) > 0.5 {
                        b.offset.at.x += dx
                        b.offset.at.y += dy
                        // The thread gives a little as its card goes.
                        b.sagSpeed += min(hypot(dx, dy), 60) * 0.25
                    }
                }
            }
            b.target = place.frame
            b.kind = place.kind
            b.side = place.side
            b.offset.step(toward: .zero, dt: dt, stiffness: Self.stiffness, damping: Self.damping)
            if hypot(b.offset.at.x, b.offset.at.y) < 0.3, b.offset.resting { b.offset = FlowSpring(at: .zero) } else { still = false }

            // The pin: on its spot, or the loop's edge toward the card; pulled, carried by a spring.
            let right = place.side == .right
            var pin = area.map { NoteLoop.pin(seed: NoteLoop.seed(place.id), around: $0, right: right) } ?? spot
            var shownArea = area
            let dragged = drag?.id == place.id
            if dragged || b.pin != nil {
                // Lifted off its spot: carried from where it was, after the pointer.
                let from = drag.map { CGPoint(x: pin.x - $0.by.width, y: pin.y - $0.by.height) } ?? pin
                var spring = b.pin ?? FlowSpring(at: dragged ? from : pin)
                spring.step(toward: pin, dt: dt, stiffness: 620, damping: 40)
                let d = CGSize(width: spring.at.x - pin.x, height: spring.at.y - pin.y)
                if !dragged, spring.resting, hypot(d.width, d.height) < 0.3 {
                    b.pin = nil
                } else {
                    b.pin = spring
                    still = false
                    pin = spring.at
                    shownArea = shownArea?.offsetBy(dx: d.width, dy: d.height)
                }
            }
            let offset = b.offset.at
            var frame = place.frame.offsetBy(dx: offset.x, dy: offset.y)
            var anchor = CGPoint(x: place.anchor.x + offset.x, y: place.anchor.y + offset.y)
            // Whatever its springs are doing, as its pin is pulled or it makes way, a card never
            // comes over its own pin: it keeps out beside it.
            if Self.shape(place.kind) == 0, frame.minY < pin.y + NotePlacement.pinRoom, frame.maxY > pin.y - NotePlacement.pinRoom {
                let dx = place.side == .right ? max(pin.x + NotePlacement.pinRoom - frame.minX, 0)
                                              : min(pin.x - NotePlacement.pinRoom - frame.maxX, 0)
                frame.origin.x += dx
                anchor.x += dx
            }

            // Slack while pulled, so it hangs as a thread between two hands; a loose spring, so it
            // swings a little before it hangs still.
            let want: CGFloat = dragged ? min(hypot(anchor.x - pin.x, anchor.y - pin.y) * 0.14, 42) : 0
            var left = dt
            while left > 0 {
                let h = min(left, 1.0 / 240)
                b.sagSpeed += (170 * (want - b.sag) - 7.5 * b.sagSpeed) * h
                b.sag += b.sagSpeed * h
                left -= h
            }
            if abs(b.sag - want) < 0.2, abs(b.sagSpeed) < 2 { b.sag = want; b.sagSpeed = 0 } else { still = false }
            if dragged { still = false }

            var born = 1.0
            if let t = b.born {
                born = (now - t) / (b.turned ? Self.turn : Self.writeIn)
                if born >= 1 { b.born = nil; b.turned = false; born = 1 } else { still = false }
            }
            var s = NotesLayer.Shown(id: place.id, key: place.id.uuidString, item: item, place: place, frame: frame, anchor: anchor,
                                     pin: pin, area: shownArea, sag: b.sag, born: born, leaving: nil, tickedOff: false,
                                     lit: item.open || pointed == place.id || dragged, dragged: dragged)
            s.turned = b.turned
            b.last = s
            bodies[place.id] = b
            shown.append(s)
        }
        // What has gone leaves as it goes: ticked off, or simply taken away.
        for (id, b) in bodies where !present.contains(id) {
            if let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: done.contains(id) && !b.done ? .tickedOff : .gone)) }
            bodies[id] = nil
        }
        ghosts.removeAll { now - $0.since >= $0.lasts }
        let leaving = ghosts.map { g -> NotesLayer.Shown in
            var s = g.shown
            s.key = "\(s.id.uuidString)~\(g.since)"
            s.leaving = min((now - g.since) / g.lasts, 1)
            s.tickedOff = g.kind == .tickedOff
            s.turned = g.kind == .turned
            s.lit = false
            s.dragged = false
            return s
        }
        if !ghosts.isEmpty { still = false }
        seeded = true
        moving = !still
        if moving { run(canvas) }
        return NotesLayer.Scene(shown: shown, ghosts: leaving, circle: circle)
    }

    private func run(_ canvas: NSView?) {
        guard clock == nil, let canvas else { return }
        clock = NoteClock(view: canvas) { [weak self] in
            guard let self else { return false }
            guard self.moving else { self.clock = nil; return false }
            self.tick &+= 1
            return true
        }
    }
}

/// A display link that calls on while it is told to.
private final class NoteClock: NSObject {
    private var link: CADisplayLink?
    private let step: @MainActor () -> Bool

    @MainActor init(view: NSView, step: @escaping @MainActor () -> Bool) {
        self.step = step
        super.init()
        let link = view.displayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @MainActor @objc private func fire(_ link: CADisplayLink) {
        if !step() {
            link.invalidate()
            self.link = nil
        }
    }
}

// MARK: - Drawing

/// The pencil work of the margin: the threads, the loops round what notes are about, the loop
/// being drawn, and the ticks of threads ticked off.
private enum NoteInk {
    /// Under a thread, where it crosses the work: the paper's own white edge; faint in the dark,
    /// where a dark edge would weigh the thread down on a light sheet.
    static let casing = Theme.dynamic(0xFFFFFF, 0x1B1A18, lightAlpha: 0.85, darkAlpha: 0.35)

    /// A thread from a pin to its card: leaving the pin level, toward the card, and coming into it
    /// square to its edge, sagging by `sag`.
    static func thread(from p: CGPoint, to a: CGPoint, sag: CGFloat) -> FlowCurve {
        let dx = a.x - p.x
        let dir: CGFloat = dx >= 0 ? 1 : -1
        let k = max(abs(dx) * 0.5, 18)
        return FlowCurve(p0: p, c1: CGPoint(x: p.x + dir * k, y: p.y + sag),
                         c2: CGPoint(x: a.x - dir * k * 0.7, y: a.y + sag), p3: a)
    }

    static func ease(_ t: Double) -> Double { NoteInkEase.ease(t) }
    static func easeOut(_ t: Double) -> Double { NoteInkEase.out(t) }

    static func draw(_ scene: NotesLayer.Scene, in ctx: GraphicsContext) {
        for s in scene.ghosts { drawGhost(s, ctx) }
        for s in scene.shown { drawShown(s, ctx) }
        if let circle = scene.circle, circle.width > 0 || circle.height > 0 {
            loop(around: circle, seed: 7, color: Theme.pencil, alpha: 0.95, drawn: 1, ctx)
        }
    }

    private static func drawShown(_ s: NotesLayer.Shown, _ ctx: GraphicsContext) {
        let born = s.born
        if let area = s.area {
            loop(around: area, seed: NoteLoop.seed(s.id), color: s.item.color, alpha: s.lit ? 0.95 : 0.5,
                 drawn: s.turned ? 1 : ease(born / 0.45), ctx)
        }
        // A flag's thread shows only while it is pointed at: across the work, it would be in the way.
        let showsThread = s.place.kind == .card || s.place.kind == .lifted || (s.place.kind == .flag && s.lit)
        guard showsThread else { return }
        var curve = thread(from: s.pin, to: s.anchor, sag: s.sag)
        // Written: after the pin lands. Turned: at once, out to where the card unfolds.
        let drawn = s.turned ? easeOut(born / 0.6) : ease((born - 0.1) / 0.42)
        guard drawn > 0.001 else { return }
        if drawn < 1 { curve = curve.upTo(CGFloat(drawn)) }
        stroke(curve, color: s.item.color, lit: s.lit, alpha: s.item.done ? 0.5 : 1, ctx)
    }

    private static func drawGhost(_ s: NotesLayer.Shown, _ ctx: GraphicsContext) {
        let p = s.leaving ?? 1
        // Ticked off: the tick first, then the thread reels in; taken away: it reels in at once.
        let reel = s.tickedOff ? ease((p - 0.3) / 0.45) : ease(p / 0.8)
        let fade = s.tickedOff ? 1 - ease((p - 0.55) / 0.4) : 1 - ease(p)
        // Turned to a flag or a card, it is still there: only the old thread goes, quickly.
        if s.turned {
            if s.place.kind == .card || s.place.kind == .lifted {
                let curve = thread(from: s.pin, to: s.anchor, sag: s.sag).upTo(CGFloat(1 - easeOut(p)))
                stroke(curve, color: s.item.color, lit: false, alpha: 1 - p, ctx)
            }
            return
        }
        if let area = s.area {
            loop(around: area, seed: NoteLoop.seed(s.id), color: s.item.color, alpha: 0.5 * fade, drawn: 1, ctx)
        }
        if s.place.kind == .card || s.place.kind == .lifted, reel < 0.999 {
            let curve = thread(from: s.pin, to: s.anchor, sag: s.sag).upTo(CGFloat(1 - reel))
            stroke(curve, color: s.item.color, lit: false, alpha: 1, ctx)
        }
        // The pin goes, and where a thread was ticked off, a small tick stays a moment.
        let pinGone = s.tickedOff ? ease((p - 0.55) / 0.3) : ease(p / 0.6)
        if pinGone < 1 {
            let r = 5.5 * (1 - pinGone)
            let c = CGRect(x: s.pin.x - r, y: s.pin.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: c), with: .color(.white))
            ctx.stroke(Path(ellipseIn: c.insetBy(dx: 0.8, dy: 0.8)), with: .color(s.item.color), lineWidth: 1.6)
        }
        if s.tickedOff {
            let t = (p - 0.6) / 0.4
            if t > 0 {
                var tick = Path()
                let o = CGPoint(x: s.pin.x - 6, y: s.pin.y - 3)
                tick.move(to: CGPoint(x: o.x, y: o.y + 3))
                tick.addLine(to: CGPoint(x: o.x + 4, y: o.y + 7))
                tick.addLine(to: CGPoint(x: o.x + 12, y: o.y - 3))
                let drawn = ease(t / 0.4)
                var c = ctx
                c.opacity = 1 - ease((t - 0.5) / 0.5)
                c.stroke(tick.trimmedPath(from: 0, to: drawn), with: .color(Theme.pencil),
                         style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private static func stroke(_ curve: FlowCurve, color: Color, lit: Bool, alpha: Double, _ ctx: GraphicsContext) {
        let path = Path(curve.path)
        ctx.stroke(path, with: .color(casing.opacity(alpha)), style: StrokeStyle(lineWidth: lit ? 4.2 : 3.4, lineCap: .round))
        ctx.stroke(path, with: .color(color.opacity((lit ? 0.95 : 0.62) * alpha)), style: StrokeStyle(lineWidth: lit ? 1.5 : 1.1, lineCap: .round))
    }

    /// The hand loop round a part, drawn as far as `drawn`, fine where the pencil lands and lifts.
    static func loop(around r: CGRect, seed: UInt64, color: Color, alpha: Double, drawn: Double, _ ctx: GraphicsContext) {
        guard drawn > 0, alpha > 0 else { return }
        let points = NoteLoop.points(seed: seed, around: r)
        let n = max(1, Int(Double(points.count - 1) * min(drawn, 1)))
        // Drawn whole and then made faint, so the pieces of the line never darken where they meet.
        var faint = ctx
        faint.opacity = alpha
        faint.drawLayer { layer in
            for i in 0..<n {
                let w = PencilLoop.width(at: Double(i) / Double(points.count - 1), 2.1)
                var seg = Path()
                seg.move(to: points[i])
                seg.addLine(to: points[i + 1])
                layer.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }
    }
}

// MARK: - Pieces

/// A card coming in: unfolding from where its thread meets it, once the thread has reached it,
/// easing out so it slows into place and stops there. Unfolding from a flag, it opens straight
/// away from the sheet's edge. Going: ticked off, a pencil tick across it, then tucked away toward
/// its thread; folding to a flag, gathered into the edge.
private struct Arrival: ViewModifier {
    let shown: NotesLayer.Shown

    func body(content: Content) -> some View {
        let s = shown
        let edge = UnitPoint(x: s.place.side == .right ? 0 : 1, y: min(NotePlacement.lineIn / max(s.frame.height, 1), 1))
        let toward: CGFloat = s.place.side == .right ? -1 : 1
        let appear = s.turned ? NoteInkEase.out(s.born) : NoteInkEase.out((s.born - 0.3) / 0.7)
        let p = s.leaving ?? 0
        let (fold, fade) = Self.going(s)
        let grown = s.turned ? 0.72 + 0.28 * appear : 0.94 + 0.06 * appear
        content
            .overlay {
                if s.tickedOff { BigTick(drawn: NoteInkEase.ease(p / 0.32)) }
            }
            .allowsHitTesting(s.leaving == nil)
            .scaleEffect(CGFloat(grown) * CGFloat(1 - (s.turned ? 0.5 : 0.62) * fold), anchor: edge)
            .rotationEffect(.degrees(s.tickedOff ? Double(toward) * 4 * fold : 0), anchor: edge)
            .offset(x: toward * CGFloat(1 - appear) * (s.turned ? 4 : 8))
            .opacity(appear * (1 - fade))
    }

    /// How far a card going is folded away, and faded.
    private static func going(_ s: NotesLayer.Shown) -> (fold: Double, fade: Double) {
        guard let p = s.leaving else { return (0, 0) }
        if s.tickedOff { return (NoteInkEase.ease((p - 0.3) / 0.5), NoteInkEase.ease((p - 0.45) / 0.4)) }
        return (NoteInkEase.out(p), NoteInkEase.out(p))
    }
}

nonisolated enum NoteInkEase {
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Quick to start and slowing into place: a cubic ease out.
    static func out(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - pow(1 - t, 3)
    }
}

/// The tick a reviewer puts across a note once it is seen to, in pencil.
private struct BigTick: View {
    let drawn: Double

    var body: some View {
        GeometryReader { g in
            let h = min(g.size.height * 0.62, 46), w = h * 1.25
            let o = CGPoint(x: g.size.width - w - 18, y: (g.size.height - h) / 2)
            Path { p in
                p.move(to: CGPoint(x: o.x, y: o.y + h * 0.55))
                p.addQuadCurve(to: CGPoint(x: o.x + w * 0.34, y: o.y + h), control: CGPoint(x: o.x + w * 0.16, y: o.y + h * 0.7))
                p.addQuadCurve(to: CGPoint(x: o.x + w, y: o.y), control: CGPoint(x: o.x + w * 0.52, y: o.y + h * 0.36))
            }
            .trimmedPath(from: 0, to: drawn)
            .stroke(Theme.pencil, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// Where a note is about: a pin in its writer's pencil, or, on the table with no room for its card,
/// their token. Pulled, it takes its thread to another spot; clicked, it opens the thread.
private struct PinView: View {
    let store: DocumentStore
    let shown: NotesLayer.Shown
    @Binding var pointed: UUID?
    @Binding var drag: NoteDrag?
    let motion: NoteMotion
    @Environment(MenuHost.self) private var menus

    var body: some View {
        let s = shown
        let pop = s.born >= 1 || s.turned ? 1 : Self.pop(s.born / 0.38)
        Group {
            if s.place.kind == .pin {
                Token(note: s.item.start, color: s.item.color, size: 20)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            } else {
                ZStack {
                    Circle().fill(.white)
                    Circle().strokeBorder(s.item.color.opacity(s.item.done ? 0.5 : 1), lineWidth: 1.6)
                    Circle().fill(s.item.color.opacity(s.item.done ? 0.5 : 1)).frame(width: 3.5, height: 3.5)
                }
                .frame(width: s.area == nil ? 11 : 9, height: s.area == nil ? 11 : 9)
            }
        }
        .shadow(color: .black.opacity(s.dragged ? 0.28 : 0.18), radius: s.dragged ? 4 : 1.5, y: s.dragged ? 3 : 0.5)
        .scaleEffect(CGFloat(pop) * (s.dragged ? 1.4 : s.lit ? 1.22 : 1))
        .animation(Theme.pop, value: s.dragged)
        .animation(Theme.quick, value: s.lit)
        .contentShape(Circle().scale(2.2))
        .onHover { on in
            pointed = on ? s.id : (pointed == s.id ? nil : pointed)
            store.hovered = on ? s.item.start.on : nil
        }
        .onTapGesture { if !s.item.draft { store.toggleThread(s.id) } }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(NotesLayer.space))
            .onChanged { value in
                guard !s.item.draft, !store.isReadOnly else { return }
                var d = drag?.id == s.id ? drag! : NoteDrag(id: s.id, by: .zero)
                d.by = value.translation
                let over = landing(d)
                if over != d.over, over != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                d.over = over
                drag = d
                store.hovered = over
            }
            .onEnded { value in
                guard drag?.id == s.id else { return }
                drag = nil
                store.hovered = nil
                let vp = store.viewport
                let doc = store.doc
                guard let spot = doc.spot(of: s.item.start) else { return }
                let p = CGPoint(x: spot.x + value.translation.width / vp.zoom, y: spot.y + value.translation.height / vp.zoom)
                store.moveNote(s.id, to: p, on: doc.area(of: s.item.start) == nil ? layer(at: p) : nil)
                motion.caught(s.id)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            })
        .help(Text(verbatim: "\(s.item.start.by): \(s.item.start.text)"))
        .contextMenuReplacement { point in
            if !s.item.draft { menus.show(at: point, width: 210, entries: NoteMenu.thread(s.item, store: store)) }
        }
    }

    /// What the pin would land on, let go of where the drag has it.
    private func landing(_ d: NoteDrag) -> UUID? {
        let doc = store.doc, vp = store.viewport
        guard let spot = doc.spot(of: shown.item.start) else { return nil }
        let p = CGPoint(x: spot.x + d.by.width / vp.zoom, y: spot.y + d.by.height / vp.zoom)
        if let area = doc.area(of: shown.item.start) {
            return doc.subject(ofArea: area.offsetBy(dx: p.x - area.midX, dy: p.y - area.midY))
        }
        return layer(at: p)
    }

    private func layer(at p: CGPoint) -> UUID? {
        store.canvas?.layer(at: p) ?? store.doc.artboard(at: p)?.id
    }

    /// Dropping in, with a little give.
    static func pop(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        let c = 1.9
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
}

/// A thread where there is no room for its card: a flag stuck to the sheet's edge, level with its
/// spot, in its writer's pencil; paler once read, and ticked once ticked off.
private struct FlagView: View {
    let store: DocumentStore
    let shown: NotesLayer.Shown
    @Binding var pointed: UUID?
    @Environment(MenuHost.self) private var menus
    @State private var hovering = false

    var body: some View {
        let s = shown, f = s.frame
        let right = s.place.side == .right
        let reach = f.width + (hovering ? 4 : 0)
        let appear = s.leaving.map { 1 - NoteInkEase.out($0) } ?? NoteInkEase.out(s.born / (s.turned ? 1 : 0.5))
        FlagShape(right: right)
            .fill(s.item.color.opacity(s.item.done ? 0.38 : s.item.unread ? 1 : 0.78))
            .overlay {
                if f.width >= 13 {
                    if s.item.done {
                        CheckMark(size: 9, color: .white, weight: 1.6)
                    } else {
                        Text(verbatim: s.item.start.by.first.map { String($0).uppercased() } ?? "•")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: reach * CGFloat(appear), height: f.height)
            .shadow(color: Theme.shadow.opacity(hovering ? 0.25 : 0.14), radius: hovering ? 3 : 1.5, y: 1)
            .contentShape(Rectangle())
            .onHover { on in
                hovering = on
                pointed = on ? s.id : (pointed == s.id ? nil : pointed)
                store.hovered = on ? s.item.start.on : nil
            }
            .onTapGesture { store.toggleThread(s.id) }
            .help(Text(verbatim: "\(s.item.start.by): \(s.item.start.text)"))
            .contextMenuReplacement { point in menus.show(at: point, width: 210, entries: NoteMenu.thread(s.item, store: store)) }
            .animation(Theme.quick, value: hovering)
            .allowsHitTesting(s.leaving == nil)
            .offset(x: right ? f.minX : f.maxX - reach * CGFloat(appear), y: f.minY)
    }
}

/// A tab stuck to an edge: flat against it, round at its free end.
private nonisolated struct FlagShape: Shape {
    let right: Bool

    func path(in r: CGRect) -> Path {
        let radius = min(r.height / 2, 6, r.width)
        return Path(roundedRect: r, cornerRadii: right
            ? RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: radius, topTrailing: radius)
            : RectangleCornerRadii(topLeading: radius, bottomLeading: radius, bottomTrailing: 0, topTrailing: 0))
    }
}

/// A writer's initial in their pencil.
private struct Token: View {
    let note: MarginNote
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        Text(verbatim: note.by.first.map { String($0).uppercased() } ?? "•")
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
    }
}

// MARK: - The card

/// A thread on its card: its first note, and, opened, its answers and room for another. Ticking it
/// off is the round mark at its head, apart from the answer, which has its own send.
struct NoteCard: View {
    let store: DocumentStore
    let shown: NotesLayer.Shown
    @Binding var pointed: UUID?
    @Environment(MenuHost.self) private var menus
    @State private var hovering = false
    @State private var answer = ""
    @State private var draft = ""
    @State private var changing: UUID?
    @State private var change = ""
    @FocusState private var writing: Bool
    @FocusState private var answering: Bool
    @FocusState private var changeFocus: Bool

    private var item: NotesLayer.Item { shown.item }
    private var open: Bool { item.open || item.draft }
    private var right: Bool { shown.place.side == .right }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if item.draft {
                header(item.start, first: true)
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(String(localized: "Write a note"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .prose(12.5)
                        .foregroundStyle(Theme.ink)
                        .focused($writing)
                        .lineLimit(1...8)
                        .onSubmit { store.postNote(draft) }
                        .onExitCommand { store.draftNote = nil }
                        .onAppear { writing = true }
                        .onChange(of: writing) { _, now in if !now, store.draftNote?.id == item.start.id { store.postNote(draft) } }
                    SendButton(ready: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { store.postNote(draft) }
                }
            } else {
                note(item.start, lines: open ? nil : 3, first: true)
                if open {
                    ForEach(item.replies) { reply in
                        Hairline()
                        note(reply, lines: nil, first: false)
                    }
                    if !store.isReadOnly, !item.done { composer }
                } else if !item.replies.isEmpty {
                    answered
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        // Shut, as tall as the margin was told it is (`NoteCardSize`).
        .frame(minHeight: open ? nil : shown.place.frame.height, alignment: .top)
        // What it holds stays on the paper as the paper grows, uncovered as it unrolls.
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .card(radius: 11, lifted: hovering || open || shown.place.kind == .lifted)
        .overlay(alignment: right ? .leading : .trailing) {
            // The writer's pencil along the card's edge, where the thread comes in.
            Capsule().fill(item.color.opacity(item.done ? 0.45 : 1)).frame(width: 2.5, height: 16)
                .offset(x: right ? -1.25 : 1.25, y: NotePlacement.lineIn - 8).frame(maxHeight: .infinity, alignment: .top)
        }
        // Opening, the card grows down from where it is and what it holds fades in; shutting, the
        // other way, never past.
        .animation(Theme.unfold, value: open)
        .offset(y: hovering && !open ? -1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if !open { store.toggleThread(item.start.id) } }
        .onHover { on in
            hovering = on
            pointed = on ? item.start.id : (pointed == item.start.id ? nil : pointed)
            store.hovered = on ? item.start.on : nil
        }
        .contextMenuReplacement { point in
            if !item.draft { menus.show(at: point, width: 210, entries: NoteMenu.thread(item, store: store)) }
        }
        .onChange(of: store.noteFocus, initial: true) { _, focus in take(focus) }
        .animation(Theme.quick, value: hovering)
    }

    /// Answering or changing words asked for from a menu, once the card is open to do it in.
    private func take(_ focus: NoteFocus?) {
        guard let focus, !item.draft else { return }
        switch focus {
        case .answer(let id) where id == item.start.id:
            store.noteFocus = nil
            // Once the answer is there to type in: the card opens with this.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { answering = true }
        case .change(let id):
            guard let note = ([item.start] + item.replies).first(where: { $0.id == id }) else { return }
            store.noteFocus = nil
            startChanging(note)
        default:
            break
        }
    }

    private func tick() {
        store.setDone(item.start.id, !item.done)
    }

    private func header(_ note: MarginNote, first: Bool) -> some View {
        HStack(spacing: 6) {
            Token(note: note, color: first ? item.color : color(of: note))
            Text(verbatim: note.by)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            if first, item.unread {
                Circle().fill(item.color).frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 4)
            if !item.draft {
                Text(Date(timeIntervalSince1970: note.time), format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            if first, open, !item.draft {
                if store.doc.reviewOrder.count > 1 { Steps(store: store) }
                if !store.isReadOnly { TickButton(done: item.done || shown.tickedOff, color: item.color) { tick() } }
            } else if !first, open, hovering, store.wrote(note), !store.isReadOnly {
                GlyphButton(symbol: "trash", size: 10) { store.deleteNote(note.id) }
                    .help(String(localized: "Delete"))
            }
        }
    }

    private func note(_ note: MarginNote, lines: Int?, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(note, first: first)
            if changing == note.id {
                TextField("", text: $change, axis: .vertical)
                    .textFieldStyle(.plain)
                    .prose(12.5)
                    .foregroundStyle(Theme.ink)
                    .focused($changeFocus)
                    .lineLimit(1...8)
                    .onSubmit {
                        store.changeNote(note.id, change)
                        changing = nil
                    }
                    .onExitCommand { changing = nil }
                    .onAppear { changeFocus = true }
                    .onChange(of: changeFocus) { _, now in if !now { changing = nil } }
            } else {
                Text(verbatim: note.text)
                    .prose(12.5)
                    .foregroundStyle(item.done ? Theme.ink2 : Theme.ink)
                    .lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { if open, store.wrote(note), !store.isReadOnly { startChanging(note) } }
            }
        }
    }

    private func startChanging(_ note: MarginNote) {
        if !open { store.toggleThread(item.start.id) }
        change = note.text
        changing = note.id
    }

    /// Who answered, as their tokens, with how many.
    private var answered: some View {
        HStack(spacing: -4) {
            ForEach(Array(Set(item.replies.map(\.by)).sorted().prefix(4)), id: \.self) { name in
                if let reply = item.replies.first(where: { $0.by == name }) {
                    Token(note: reply, color: color(of: reply), size: 14)
                        .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                }
            }
            Text(verbatim: "\(item.replies.count)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink3)
                .padding(.leading, 9)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(String(localized: "Answer"), text: $answer, axis: .vertical)
                .textFieldStyle(.plain)
                .prose(12.5)
                .lineLimit(1...6)
                .focused($answering)
                .onSubmit(send)
                .onExitCommand { store.openThread = nil }
                .padding(.vertical, 2.5)
            SendButton(ready: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well.opacity(0.6)))
    }

    private func send() {
        store.answer(item.start.id, answer)
        answer = ""
        answering = true
    }

    private func color(of note: MarginNote) -> Color {
        guard let replica = note.replica, !store.wrote(note) else { return Theme.pencil }
        return store.sharing?.live?.pencil(of: replica).color ?? Pencil.preferred(replica).color
    }
}

/// What a right click on a note offers, in Bezzle's own menu: answering and ticking it off,
/// changing or taking away what was written here, and copying its words.
@MainActor
enum NoteMenu {
    static func thread(_ item: NotesLayer.Item, store: DocumentStore) -> [MenuEntry] {
        let id = item.start.id
        var entries: [MenuEntry] = []
        if !store.isReadOnly {
            if !item.done { entries.append(.item("Answer") { store.focusNote(.answer(id)) }) }
            entries.append(.item(item.done ? "Open Again" : "Mark as Done") { store.setDone(id, !item.done) })
            entries.append(.separator)
            if store.wrote(item.start) { entries.append(.item("Edit") { store.focusNote(.change(id)) }) }
        }
        entries.append(.item("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(([item.start] + item.replies).map { "\($0.by): \($0.text)" }.joined(separator: "\n\n"), forType: .string)
        })
        if !store.isReadOnly, store.wrote(item.start) {
            entries.append(.separator)
            entries.append(.item("Delete") { store.deleteNote(id) })
        }
        return entries
    }
}

/// Sends what is written: an arrow in the pencil, there once there is something to send.
private struct SendButton: View {
    let ready: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.pencil.opacity(hovering ? 1 : 0.9)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(ready ? 1 : 0.4)
        .opacity(ready ? 1 : 0)
        .allowsHitTesting(ready)
        .animation(Theme.pop, value: ready)
        .onHover { hovering = $0 }
        .help(String(localized: "Send"))
        .accessibilityLabel(String(localized: "Send"))
    }
}

/// Ticking a thread off: a round mark at its head that takes a tick when pointed at, and holds it
/// once ticked; clicked then, the thread is open again.
private struct TickButton: View {
    let done: Bool
    let color: Color
    let action: () -> Void
    @State private var hovering = false
    @State private var ticking = false

    var body: some View {
        let on = done || ticking
        Button {
            guard !ticking else { return }
            if done { action(); return }
            ticking = true
            // The tick lands before the card goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                action()
                ticking = false
            }
        } label: {
            ZStack {
                Circle().fill(on ? Theme.pencil : hovering ? Theme.pencilWash : .clear)
                Circle().strokeBorder(on ? Theme.pencil : hovering ? Theme.pencil : Theme.ink3, lineWidth: 1.2)
                CheckMark(size: 9, color: on ? .white : Theme.pencil, weight: 1.6)
                    .opacity(on || hovering ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.8)
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle().scale(1.4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.pop, value: on)
        .animation(Theme.quick, value: hovering)
        .help(done ? String(localized: "Open Again") : String(localized: "Mark as Done"))
        .accessibilityLabel(done ? String(localized: "Open Again") : String(localized: "Mark as Done"))
    }
}

/// To the thread before or after, in the order of a review: the view flies there.
private struct Steps: View {
    let store: DocumentStore

    var body: some View {
        HStack(spacing: 0) {
            GlyphButton(symbol: "chevron.left", size: 9) { store.stepThread(by: -1) }
                .help(String(localized: "Previous Note"))
            GlyphButton(symbol: "chevron.right", size: 9) { store.stepThread(by: 1) }
                .help(String(localized: "Next Note"))
        }
    }
}

/// A small glyph that does one thing.
private struct GlyphButton: View {
    let symbol: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
