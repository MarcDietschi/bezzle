import AppKit

/// A deck on the canvas, as a stack of cards: the posts behind the one in front peek out below it,
/// and fan a little further apart under the pointer. Pressed, they spread out over the canvas, every
/// post at once, to pick one, put them in another order, export one or throw one away; let go, they
/// fly back into the stack. Under a selected deck, a dot for each post turns to it, the post in front
/// a longer one; a plus after them deals a copy of the post in front, and on an artboard that is no
/// deck yet, makes it one. Every turn moves as cards do: the one in front slides away and the next
/// rises, a new one is dealt out and laid on top, one taken away drops off.
///
/// While a layer of a post is being moved, resized or typed into, the same layer in every other post
/// is outlined where it differs, so what the longest words do shows. After a change made to every
/// post, a word on the canvas offers to keep it in the one in front alone (`DeckOffer`).
final class DeckTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        self.store = store
    }

    private func view(_ r: CGRect) -> CGRect { store.viewport.toView(r) }

    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let offerFont = NSFont.systemFont(ofSize: 11.5)
    private static let offerButtonFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let surface = Theme.dynamicNS(0xFFFFFF, 0x2B2926)
    private static let edge = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.12, darkAlpha: 0.2)
    private static let ink = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.55, darkAlpha: 0.6)
    private static let faint = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.2, darkAlpha: 0.26)
    private static let broken = NSColor.systemRed

    // MARK: - Time

    private var lastFrame: CFTimeInterval = 0
    /// Seconds since the frame before, never more than a few frames' worth, so nothing jumps after a pause.
    private var dt: Double = 1.0 / 120

    /// Whether anything is still on its way, and the canvas should be drawn again next frame.
    var isAnimating: Bool {
        !transitions.isEmpty || spreadMoving || !fan.settled || !pager.settled || offerShown.isMoving
    }

    private var spreadMoving: Bool {
        guard let s = spread else { return false }
        if s.closing != nil || !s.backdrop.settled || drag != nil { return true }
        return s.cards.values.contains { !$0.settled }
    }

    /// Eases out in a cubic.
    private static func out(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
    /// Eases out past the end and back, as a card settling does.
    private static func settle(_ t: Double) -> Double {
        let x = min(max(t, 0), 1) - 1, c = 1.5
        return 1 + (c + 1) * x * x * x + c * x * x
    }

    /// A number that follows where it is meant to be as a spring does, slightly past it and back.
    struct Spring {
        var value: Double
        var target: Double
        var velocity: Double = 0

        init(_ v: Double) {
            value = v
            target = v
        }

        var settled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }
        var isMoving: Bool { !settled }

        mutating func step(_ dt: Double, stiffness: Double = 260, damping: Double = 24) {
            guard !settled else {
                value = target
                velocity = 0
                return
            }
            // A few small steps, so a long frame never makes it fly off.
            let n = max(1, Int((dt / 0.004).rounded(.up)))
            let h = dt / Double(n)
            for _ in 0..<n {
                velocity += (-stiffness * (value - target) - damping * velocity) * h
                value += velocity * h
            }
        }
    }

    /// Springs by key, all stepped together.
    struct Springs<Key: Hashable> {
        var all: [Key: Spring] = [:]
        var settled: Bool { all.values.allSatisfy(\.settled) }

        subscript(_ key: Key, start start: Double) -> Spring {
            get { all[key] ?? Spring(start) }
            set { all[key] = newValue }
        }

        mutating func step(_ dt: Double, stiffness: Double = 260, damping: Double = 24) {
            for k in all.keys { all[k]?.step(dt, stiffness: stiffness, damping: damping) }
            all = all.filter { !($0.value.settled && $0.value.value == 0) }
        }
    }

    // MARK: - The stack

    /// How far apart the cards behind a deck fan, by deck: 0 at rest, 1 under the pointer.
    private var fan = Springs<UUID>()
    private var pointedDeck: UUID?

    /// How much of each card behind shows below the one in front, on screen.
    private func sliver(_ r: CGRect, _ deck: UUID) -> CGFloat {
        let base = min(9, max(3, r.width * 0.022))
        return base * (1 + 0.7 * CGFloat(fan[deck, start: 0].value))
    }

    /// The cards behind a deck, on screen, back first: narrower, and lower, so their foot shows.
    private func backCards(_ r: CGRect, deck: Node) -> [CGRect] {
        let behind = min(deck.posts.count - 1, 2)
        guard behind > 0 else { return [] }
        let s = sliver(r, deck.id)
        return (1...behind).reversed().map { k in
            let inset = r.width * 0.035 * CGFloat(k)
            return CGRect(x: r.minX + inset, y: r.minY + s * CGFloat(k), width: r.width - inset * 2, height: r.height)
        }
    }

    /// Below the stack, where the dots go.
    private func stackFoot(_ r: CGRect, deck: Node?) -> CGFloat {
        guard let deck, deck.isDeck else { return r.maxY }
        return r.maxY + sliver(r, deck.id) * CGFloat(min(deck.posts.count - 1, 2))
    }

    /// The posts behind each deck, as the feet of cards in a stack: drawn before the design, which
    /// lies over them.
    func drawStacks(_ ctx: CGContext, in bounds: CGRect) {
        noticeTurns(in: bounds)
        for deck in store.doc.nodes where deck.isDeck && !deck.hidden && deck.posts.count > 1 {
            let r = view(deck.frame)
            guard r.insetBy(dx: -20, dy: -20).intersects(bounds), r.width >= 8 else { continue }
            drawBackCards(backCards(r, deck: deck), fill: deck.fill.on ? deck.fill.color.cgColor : .white, in: ctx)
        }
    }

    private func drawBackCards(_ cards: [CGRect], fill: CGColor, in ctx: CGContext) {
        for (i, card) in cards.enumerated() {
            let depth = CGFloat(cards.count - i)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 6, color: NSColor.black.withAlphaComponent(0.16).cgColor)
            ctx.setFillColor(fill)
            ctx.fill(card)
            ctx.restoreGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.05 * depth).cgColor)
            ctx.fill(card)
            ctx.setStrokeColor(Self.edge.cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(card.insetBy(dx: 0.25, dy: 0.25))
        }
    }

    // MARK: - Turning

    /// A deck's post in front changing, as cards move.
    private struct Transition {
        enum Kind { case forward, backward, deal, remove }
        let kind: Kind
        let start: CFTimeInterval
        let duration: Double
        let old: CGImage?
        let new: CGImage?
    }

    private var transitions: [UUID: Transition] = [:]
    /// Each deck as it was last drawn, and the post that was in front, to tell how it changed.
    private var seen: [UUID: (node: Node, front: Int?)] = [:]
    /// Decks to turn without moving, as when the spread lays the chosen post down itself.
    private var quietly: Set<UUID> = []
    private var lastTurn: CFTimeInterval = 0

    /// Starts a card's move for every deck in sight whose post in front changed since it was last drawn.
    private func noticeTurns(in bounds: CGRect) {
        let t = CACurrentMediaTime()
        dt = min(max(t - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = t
        fan.step(dt)
        pager.step(dt, stiffness: 320, damping: 28)
        offerShown.step(dt, stiffness: 300, damping: 20)
        transitions = transitions.filter { t - $0.value.start < $0.value.duration }

        var now: [UUID: (node: Node, front: Int?)] = [:]
        for deck in store.doc.nodes where deck.isDeck {
            let front = store.front(of: deck)
            now[deck.id] = (deck, front)
            guard let was = seen[deck.id], was.front != front, !quietly.contains(deck.id), spread?.deck != deck.id else { continue }
            let r = view(deck.frame)
            guard r.intersects(bounds), r.width >= 24 else { continue }
            let kind: Transition.Kind
            if let f = front, !was.node.posts.contains(f) {
                kind = .deal
            } else if let w = was.front, !deck.posts.contains(w) {
                kind = .remove
            } else {
                let a = was.front.flatMap { deck.posts.firstIndex(of: $0) } ?? 0, b = front.flatMap { deck.posts.firstIndex(of: $0) } ?? 0
                kind = b >= a ? .forward : .backward
            }
            // Turning quickly, as in scrubbing, each move is quicker.
            let quick = t - lastTurn < 0.3
            lastTurn = t
            let scale = min(store.viewport.zoom * deviceScale, 1600 / max(deck.frame.width, deck.frame.height, 1))
            transitions[deck.id] = Transition(kind: kind, start: t, duration: kind == .deal ? 0.62 : quick ? 0.24 : 0.46,
                                              old: picture(was.node.showing(was.front), scale: scale),
                                              new: picture(deck.showing(front), scale: scale))
        }
        seen = now
        quietly = []
    }

    /// Pictures of posts as they last were, so turning back and forth draws each only once.
    private var drawn: [UUID: (node: Node, scale: CGFloat, image: CGImage)] = [:]

    private func picture(_ board: Node, scale: CGFloat) -> CGImage? {
        let key = board.children.first?.id ?? board.id
        if let kept = drawn[key], kept.scale == scale, kept.node == board { return kept.image }
        guard let image = Renderer.image(of: board, scale: scale, assets: store.assets) else { return nil }
        if drawn.count > 40 { drawn.removeAll() }
        drawn[key] = (board, scale, image)
        return image
    }

    /// Draws a picture of a card centred in `rect`, turned, faded and shadowed.
    private func drawCard(_ image: CGImage?, in rect: CGRect, turn: CGFloat = 0, alpha: CGFloat = 1, lift: CGFloat = 0,
                          fill: CGColor = .white, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0, alpha > 0.001 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: turn)
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        // Fading, it fades as one card, not its paper and its print each.
        if alpha < 1 {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(in: local.insetBy(dx: -40, dy: -40), auxiliaryInfo: nil)
        }
        defer { if alpha < 1 { ctx.endTransparencyLayer() } }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -(3 + 10 * lift)), blur: 8 + 22 * lift,
                      color: NSColor.black.withAlphaComponent(0.18 + 0.14 * lift).cgColor)
        ctx.setFillColor(fill)
        ctx.fill(local)
        ctx.restoreGState()
        if let image {
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: local)
        }
    }

    /// A card's place as it lies `back` of the way to being the one behind: smaller about its top,
    /// and lower.
    private func receded(_ r: CGRect, _ back: CGFloat, deck: UUID) -> CGRect {
        let inset = r.width * 0.035 * back
        return CGRect(x: r.minX + inset, y: r.minY + sliver(r, deck) * back + inset * r.height / r.width,
                      width: r.width - inset * 2, height: r.height - inset * 2 * r.height / r.width)
    }

    private func drawTransitions(_ ctx: CGContext) {
        let t = CACurrentMediaTime()
        for (id, move) in transitions {
            guard let deck = store.node(id), deck.isDeck else { continue }
            let r = view(deck.frame)
            let p = min(max((t - move.start) / move.duration, 0), 1)
            let fill = deck.fill.on ? deck.fill.color.cgColor : CGColor.white
            ctx.saveGState()
            // What the canvas drew there is the post now in front, all at once: covered while it moves.
            ctx.setFillColor(CanvasInk.table.cgColor)
            ctx.fill(r.insetBy(dx: -1, dy: -1))
            drawBackCards(backCards(r, deck: deck), fill: fill, in: ctx)
            let w = r.width, h = r.height
            switch move.kind {
            case .forward:
                // The next rises into place; the one in front slides off to the left and down behind.
                drawCard(move.new, in: receded(r, CGFloat(1 - Self.out(p)), deck: id), fill: fill, ctx: ctx)
                let q = Self.out(p)
                let away = CGRect(x: r.minX - w * 0.72 * q, y: r.minY - h * 0.03 * sin(q * .pi), width: w * (1 - 0.1 * q), height: h * (1 - 0.1 * q))
                drawCard(move.old, in: away, turn: -0.14 * q, alpha: CGFloat(min(1, (1 - q) * 4)), lift: CGFloat(sin(q * .pi)), fill: fill, ctx: ctx)
            case .backward:
                // The one in front sinks back; the one before comes in from the left and settles on top.
                drawCard(move.old, in: receded(r, CGFloat(Self.out(p)), deck: id), fill: fill, ctx: ctx)
                let q = 1 - Self.settle(p)
                let coming = CGRect(x: r.minX - w * 0.72 * q, y: r.minY - h * 0.03 * sin(q * .pi), width: w * (1 - 0.1 * q), height: h * (1 - 0.1 * q))
                drawCard(move.new, in: coming, turn: -0.14 * q, alpha: CGFloat(min(1, p * 5)), lift: CGFloat(sin(q * .pi)), fill: fill, ctx: ctx)
            case .deal:
                // A copy of the one in front is drawn out to the right, and laid back on top.
                drawCard(move.old, in: receded(r, CGFloat(Self.out(p * 1.6)), deck: id), fill: fill, ctx: ctx)
                let arc = sin(min(p * 1.15, 1) * .pi)
                let x = w * 0.42 * arc, up = h * 0.04 * arc, grow = 1 + 0.04 * arc
                let card = CGRect(x: r.minX + x - w * (grow - 1) / 2, y: r.minY - up - h * (grow - 1) / 2, width: w * grow, height: h * grow)
                drawCard(move.new, in: card, turn: 0.09 * arc, lift: arc, fill: fill, ctx: ctx)
            case .remove:
                // The next rises; the one taken away drops and fades.
                drawCard(move.new, in: receded(r, CGFloat(1 - Self.out(p)), deck: id), fill: fill, ctx: ctx)
                let q = Self.out(p)
                let falling = CGRect(x: r.minX + w * 0.08 * q, y: r.minY + h * 0.35 * q * q, width: w * (1 - 0.15 * q), height: h * (1 - 0.15 * q))
                drawCard(move.old, in: falling, turn: 0.2 * q, alpha: CGFloat(1 - q), lift: CGFloat(q), fill: fill, ctx: ctx)
            }
            ctx.restoreGState()
        }
    }

    // MARK: - The dots

    /// The artboard the dots show under: the deck the selection is on, or an artboard selected alone.
    private var board: Node? {
        guard store.tool == .select || store.editingText != nil, store.editingPath == nil, store.editingPicture == nil,
              store.building == nil, spread == nil else { return nil }
        if let deck = store.selectedDeck, !deck.hidden { return deck }
        guard store.selection.count == 1, let n = store.node(store.selection[0]), n.isArtboard, !n.locked, !n.hidden else { return nil }
        return n
    }

    /// How much the dots show, and where the long dot of the post in front is, by deck.
    private var pager = Springs<String>()

    private struct Dots {
        let board: UUID
        let posts: [Int]
        /// The first post shown, when there are more than fit.
        let first: Int
        let shown: Int
        let front: Int
        let centres: [CGPoint]
        let track: CGRect
        let add: CGRect

        func index(at x: CGFloat) -> Int {
            guard let nearest = centres.indices.min(by: { abs(centres[$0].x - x) < abs(centres[$1].x - x) }) else { return 0 }
            return first + nearest
        }
    }

    private static let pitch: CGFloat = 13
    private static let most = 13

    private func dots(_ board: Node) -> Dots? {
        let r = view(board.frame)
        guard r.width >= 40 else { return nil }
        let posts = board.isDeck ? board.posts : []
        let front = board.isDeck ? store.place(in: board).index : 0
        let shown = min(posts.count, Self.most)
        let first = min(max(front - shown / 2, 0), max(posts.count - shown, 0))
        let y = stackFoot(r, deck: board) + 16
        let width = CGFloat(max(shown - 1, 0)) * Self.pitch + (shown > 0 ? 22 : 0)
        let left = r.midX - (width + (shown > 0 ? 14 : 0) + 18) / 2
        let centres = (0..<shown).map { CGPoint(x: left + 11 + CGFloat($0) * Self.pitch, y: y) }
        let track = CGRect(x: left - 8, y: y - 11, width: width + 16, height: 22)
        let add = CGRect(x: left + width + (shown > 0 ? 14 : 0), y: y - 9, width: 18, height: 18)
        return Dots(board: board.id, posts: posts, first: first, shown: shown, front: front, centres: centres, track: track, add: add)
    }

    private enum Part: Equatable { case dot(Int), add, offer }
    private var hovered: Part?

    private func part(at v: CGPoint, _ d: Dots) -> Part? {
        if d.add.insetBy(dx: -5, dy: -5).contains(v) { return .add }
        if d.shown > 1, d.track.insetBy(dx: 0, dy: -4).contains(v) { return .dot(d.index(at: v.x)) }
        return nil
    }

    private func drawDots(_ d: Dots, _ board: Node, in ctx: CGContext) {
        let shown = pager["shown " + d.board.uuidString, start: 0]
        let alpha = CGFloat(min(max(shown.value, 0), 1))
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        let broken = board.isDeck ? store.brokenPosts(of: board) : []
        let scrubbing: Bool = if case .scrub = drag { true } else { false }
        if d.shown > 1, scrubbing || { if case .dot = hovered { true } else { false } }() {
            ctx.addPath(CGPath(roundedRect: d.track, cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.setFillColor(Self.faint.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
        }
        // The long dot glides from post to post, over the dots it passes.
        let at = CGFloat(pager["at " + d.board.uuidString, start: Double(d.front - d.first)].value)
        for (i, c) in d.centres.enumerated() {
            let index = d.first + i
            // Past what fits, the dots at either end shrink, as there are more beyond them.
            var size: CGFloat = 6
            if d.posts.count > d.shown {
                if (i == 0 && d.first > 0) || (i == d.shown - 1 && d.first + d.shown < d.posts.count) { size = 3.5 }
                else if (i == 1 && d.first > 0) || (i == d.shown - 2 && d.first + d.shown < d.posts.count) { size = 5 }
            }
            let under = min(1, abs(at - CGFloat(i)) * 1.4)
            guard under > 0.02 else { continue }
            let isBroken = index < d.posts.count && broken.contains(d.posts[index])
            let lifted = hovered == .dot(index)
            let grow: CGFloat = lifted ? 2 : 0
            let dot = CGRect(x: c.x - (size + grow) / 2, y: c.y - (size + grow) / 2, width: size + grow, height: size + grow)
            let color: NSColor = isBroken ? Self.broken : lifted ? Self.ink : Self.faint.withAlphaComponent(0.6)
            ctx.setFillColor(color.withAlphaComponent(color.alphaComponent * under).cgColor)
            ctx.fillEllipse(in: dot)
        }
        if d.shown > 0 {
            let x = (d.centres.first?.x ?? 0) + at * Self.pitch
            let frontBroken = d.front < d.posts.count && broken.contains(d.posts[d.front])
            let pill = CGRect(x: x - 9, y: (d.centres.first?.y ?? 0) - 3, width: 18, height: 6)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor((frontBroken ? Self.broken : CanvasInk.pencil).cgColor)
            ctx.fillPath()
        }
        if d.posts.count > Self.most {
            let label = NSAttributedString(string: String(localized: "\(d.front + 1) of \(d.posts.count)"), attributes: [.font: Self.numberFont, .foregroundColor: Self.ink])
            let size = label.size()
            label.draw(at: CGPoint(x: d.track.midX - size.width / 2, y: d.track.maxY + 2))
        }
        // The plus: a copy of the post in front, dealt onto the stack.
        let ring = d.add.insetBy(dx: 0.75, dy: 0.75)
        let lift = hovered == .add
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: lift ? 6 : 3, color: NSColor.black.withAlphaComponent(lift ? 0.22 : 0.14).cgColor)
        ctx.setFillColor((lift ? CanvasInk.pencil : Self.surface).cgColor)
        ctx.fillEllipse(in: ring)
        ctx.restoreGState()
        let c = CGPoint(x: d.add.midX, y: d.add.midY)
        ctx.move(to: CGPoint(x: c.x - 3.5, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + 3.5, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 3.5))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 3.5))
        ctx.setStrokeColor((lift ? NSColor.white : CanvasInk.pencil).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    /// Brings the dots in under the board they belong to, and the long dot to the post in front.
    private func aimPager() {
        let current = board
        for key in pager.all.keys where key.hasPrefix("shown ") && key != "shown " + (current?.id.uuidString ?? "") {
            pager.all[key]?.target = 0
        }
        guard let current, let d = dots(current) else { return }
        pager["shown " + current.id.uuidString, start: 0].target = 1
        let key = "at " + current.id.uuidString
        var at = pager[key, start: Double(d.front - d.first)]
        at.target = Double(d.front - d.first)
        pager.all[key] = at
    }

    // MARK: - The pointer

    private enum Drag {
        /// Turning from post to post under the pointer, along the dots.
        case scrub(UUID)
        /// A post taken up in the spread, and where on it it was held.
        case lift(post: Int, grip: CGPoint, from: CGPoint, moved: Bool)
    }

    private var drag: Drag?
    var dragging: Bool { drag != nil }

    /// A press on the word offered after a change, with any tool, even while typing: does what it
    /// offers. False leaves it to the canvas.
    func offerDown(at v: CGPoint) -> Bool {
        guard spread == nil, let o = offerRect(), o.rect.contains(v), let offer = store.offer else { return false }
        store.take(offer)
        redraw()
        return true
    }

    /// A press with the select tool on the dots, the stack, an offer or the spread. False leaves it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        if spread != nil { return spreadDown(at: v) }
        if offerDown(at: v) { return true }
        if let board, let d = dots(board), let part = part(at: v, d) {
            switch part {
            case .add:
                store.addPost(to: board.id)
            case .dot(let i):
                if i < d.posts.count { store.turn(board.id, to: d.posts[i]) }
                drag = .scrub(board.id)
            case .offer:
                break
            }
            redraw()
            return true
        }
        // The feet of the cards behind a deck: every post, spread out.
        if let deck = deck(underFeet: v) {
            if !store.selection.contains(deck.id), store.selectedDeck?.id != deck.id { store.selection = [deck.id] }
            openSpread(deck)
            return true
        }
        return false
    }

    /// The deck whose cards behind show at a point on screen, below the one in front.
    private func deck(underFeet v: CGPoint) -> Node? {
        store.doc.nodes.reversed().first { deck in
            guard deck.isDeck, !deck.hidden, deck.posts.count > 1 else { return false }
            let r = view(deck.frame)
            return !r.contains(v) && backCards(r, deck: deck).contains { $0.contains(v) }
        }
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        switch drag {
        case .scrub(let id):
            guard let board = store.node(id), board.isDeck, let d = dots(board) else { return }
            let i = d.index(at: v.x)
            if i < d.posts.count { store.turn(id, to: d.posts[i]) }
        case .lift(let post, let grip, let from, let moved):
            if !moved, hypot(v.x - from.x, v.y - from.y) < 4 { return }
            drag = .lift(post: post, grip: grip, from: from, moved: true)
            spread?.pointer = v
            reflow()
        case nil:
            return
        }
        redraw()
    }

    func up(at v: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .scrub:
            break
        case .lift(let post, _, _, let moved):
            guard let s = spread else { break }
            if moved {
                if let to = slot(at: v, in: s) { store.movePost(post, in: s.deck, to: to) }
                spread?.pointer = nil
                spread?.posts = store.node(s.deck)?.posts ?? s.posts
                reflow()
            } else {
                closeSpread(choosing: post)
            }
        }
        redraw()
    }

    func cancel() -> Bool {
        if case .lift = drag {
            drag = nil
            spread?.pointer = nil
            reflow()
            redraw()
            return true
        }
        if spread != nil {
            closeSpread(choosing: nil)
            return true
        }
        return false
    }

    func hover(_ v: CGPoint?) {
        if spread != nil {
            spreadHover(v)
            return
        }
        var part: Part?
        var pointed: UUID?
        if let v, drag == nil {
            if let o = offerRect(), o.rect.contains(v) { part = .offer } else if let board, let d = dots(board) { part = self.part(at: v, d) }
            let p = store.viewport.toCanvas(v)
            pointed = store.doc.nodes.reversed().first { $0.isDeck && !$0.hidden && $0.frame.contains(p) }?.id ?? deck(underFeet: v)?.id
        }
        if pointed != pointedDeck {
            if let was = pointedDeck { fan.all[was]?.target = 0 }
            if let now = pointed { fan[now, start: 0].target = 1 }
            pointedDeck = pointed
            redraw()
        }
        if part != hovered {
            hovered = part
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if spread != nil { return .arrow }
        if case .scrub = drag { return .arrow }
        if let o = offerRect(), o.rect.contains(v) { return .pointingHand }
        if let board, let d = dots(board), part(at: v, d) != nil { return .pointingHand }
        if deck(underFeet: v) != nil { return .pointingHand }
        return nil
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        deviceScale = scale
        aimPager()
        drawTransitions(ctx)
        drawEchoes(ctx)
        for key in pager.all.keys where key.hasPrefix("shown ") {
            guard let id = UUID(uuidString: String(key.dropFirst(6))), let board = store.node(id), let d = dots(board) else { continue }
            drawDots(d, board, in: ctx)
        }
        drawOffer(ctx)
        if spread != nil { drawSpread(in: ctx, bounds: bounds) }
    }

    /// While a layer of a post is moved, resized or typed into, the same layer in every other post,
    /// where it lies or reaches elsewhere: faint dashes, so the longest words show from any post.
    private func drawEchoes(_ ctx: CGContext) {
        guard spread == nil, store.inGesture, let id = store.editingText ?? (store.selection.count == 1 ? store.selection.first : nil),
              let (deck, post) = store.doc.post(of: id), let post, deck.posts.count > 1, deck.posts.count <= 400,
              let mine = store.doc.absoluteFrame(of: id) else { return }
        var seen = Set<[Int]>()
        func key(_ r: CGRect) -> [Int] { [r.minX, r.minY, r.width, r.height].map { Int(($0 * 2).rounded()) } }
        seen.insert(key(mine))
        ctx.saveGState()
        var any = false
        for q in deck.posts where q != post {
            let other = id.mixed(Deck.key(from: post, to: q))
            guard let n = store.node(other), let frame = store.doc.absoluteFrame(of: other), seen.insert(key(frame)).inserted else { continue }
            ctx.addLines(between: Geometry.corners(of: frame, rotation: n.rotation).map { crisp(store.viewport.toView($0)) })
            ctx.closePath()
            any = true
        }
        if any {
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func crisp(_ p: CGPoint) -> CGPoint {
        let s = deviceScale
        return CGPoint(x: (p.x * s).rounded() / s + 0.5 / s, y: (p.y * s).rounded() / s + 0.5 / s)
    }

    // MARK: - The offer

    /// How far the word offered has come in: springs in when it is offered.
    private var offerShown = Spring(0)
    private var offerToken: UUID?

    private func offerRect() -> (rect: CGRect, words: NSAttributedString, button: CGRect)? {
        guard let offer = store.offer, store.editingText == nil, let deck = store.node(offer.deck), deck.isDeck,
              let frame = store.doc.absoluteFrame(of: offer.anchor) else { return nil }
        let words = NSMutableAttributedString(string: offer.words + "  ", attributes: [.font: Self.offerFont, .foregroundColor: Self.ink])
        let button = NSAttributedString(string: offer.button, attributes: [.font: Self.offerButtonFont, .foregroundColor: NSColor.white])
        let w = ceil(words.size().width), b = ceil(button.size().width)
        let size = CGSize(width: 12 + w + b + 20, height: 28)
        let r = view(frame), board = view(deck.frame)
        var origin = CGPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 10)
        if origin.y < board.minY + 4 { origin.y = r.maxY + 10 }
        let rect = CGRect(origin: origin, size: size)
        return (rect, words, CGRect(x: rect.maxX - 4 - b - 16, y: rect.minY + 4, width: b + 16, height: rect.height - 8))
    }

    private func drawOffer(_ ctx: CGContext) {
        if store.offer?.token != offerToken {
            offerToken = store.offer?.token
            offerShown = Spring(0)
            offerShown.target = store.offer == nil ? 0 : 1
        }
        guard spread == nil, let o = offerRect() else { return }
        let k = CGFloat(offerShown.value)
        guard k > 0.01 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Springs up out of the layer it is about.
        ctx.translateBy(x: o.rect.midX, y: o.rect.maxY)
        ctx.scaleBy(x: 0.85 + 0.15 * k, y: 0.85 + 0.15 * k)
        ctx.translateBy(x: -o.rect.midX, y: -o.rect.maxY + 6 * (1 - k))
        ctx.setAlpha(min(1, k))
        let capsule = CGPath(roundedRect: o.rect, cornerWidth: o.rect.height / 2, cornerHeight: o.rect.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.addPath(capsule)
        ctx.setFillColor(Self.surface.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: o.button, cornerWidth: o.button.height / 2, cornerHeight: o.button.height / 2, transform: nil))
        ctx.setFillColor((hovered == .offer ? CanvasInk.pencil.blended(withFraction: 0.15, of: .black) ?? CanvasInk.pencil : CanvasInk.pencil).cgColor)
        ctx.fillPath()
        let size = o.words.size()
        o.words.draw(at: CGPoint(x: o.rect.minX + 12, y: o.rect.midY - size.height / 2))
    }

    // MARK: - Every post at once

    private struct Card {
        var x: Spring, y: Spring, w: Spring, h: Spring
        var lift = Spring(0)

        init(_ r: CGRect) {
            x = Spring(r.midX)
            y = Spring(r.midY)
            w = Spring(r.width)
            h = Spring(r.height)
        }

        var rect: CGRect { CGRect(x: x.value - w.value / 2, y: y.value - h.value / 2, width: w.value, height: h.value) }
        var settled: Bool { x.settled && y.settled && w.settled && h.settled && lift.settled }

        mutating func aim(_ r: CGRect) {
            x.target = r.midX
            y.target = r.midY
            w.target = r.width
            h.target = r.height
        }

        mutating func step(_ dt: Double) {
            for k in [\Card.x, \Card.y, \Card.w, \Card.h] { self[keyPath: k].step(dt, stiffness: 210, damping: 21) }
            lift.step(dt, stiffness: 400, damping: 30)
        }
    }

    private struct Spread {
        let deck: UUID
        var posts: [Int]
        var pictures: [Int: CGImage] = [:]
        var cards: [Int: Card] = [:]
        /// When each card is let go from the stack to fly to its place, from when the spread opened.
        var opened: CFTimeInterval
        var backdrop = Spring(0)
        var hovered: Int?
        var hoveredButton: Button?
        var pointer: CGPoint?
        /// Closing: the post to lay on top, if one was chosen, and since when.
        var closing: (post: Int?, since: CFTimeInterval)?
        var token = UUID()
    }

    private enum Button: Equatable { case export(Int), remove(Int), add }
    private var spread: Spread?

    /// Whether every post of a deck is spread out over the canvas.
    var spreading: Bool { spread != nil }

    /// Every post of a deck flies out of the stack into rows over the canvas.
    func openSpread(_ board: Node) {
        guard board.isDeck, spread == nil, let bounds = store.canvas?.bounds else { return }
        let r = view(board.frame)
        var s = Spread(deck: board.id, posts: board.posts, opened: CACurrentMediaTime())
        let front = store.front(of: board)
        for (i, p) in s.posts.enumerated() {
            // Out of the stack: the one in front from where it lies, the rest from just behind it.
            s.cards[p] = Card(p == front ? r : receded(r, CGFloat(min(i, 2)) * 0.5 + 0.5, deck: board.id))
        }
        s.backdrop.target = 1
        spread = s
        if let front { s.pictures[front] = picture(board.showing(front), scale: min(deviceScale, 1600 / max(board.frame.width, 1))) }
        spread?.pictures = s.pictures
        drawPictures(bounds: bounds)
        reflow()
        redraw()
    }

    /// Each post drawn small, away from the main thread, coming in as they are drawn.
    private func drawPictures(bounds: CGRect) {
        guard let s = spread, let board = store.node(s.deck) else { return }
        let cell = layout(count: s.posts.count + 1, aspect: board.frame.width / max(board.frame.height, 1), in: bounds).size
        let scale = min(cell.width * 1.1 / max(board.frame.width, 1), 1) * deviceScale
        let assets = store.assets, token = s.token
        let shown = s.posts.filter { s.pictures[$0] == nil }.map { ($0, board.showing($0)) }
        struct Made: @unchecked Sendable { let post: Int, image: CGImage? }
        DispatchQueue.global(qos: .userInitiated).async {
            for (post, node) in shown {
                let made = Made(post: post, image: Renderer.image(of: node, scale: scale, assets: assets))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.spread?.token == token, let image = made.image else { return }
                        self.spread?.pictures[made.post] = image
                        self.redraw()
                    }
                }
            }
        }
    }

    /// Where the posts lie when spread: as big as all of them, and the card that adds one, fit on
    /// screen, in rows.
    private struct Layout {
        let size: CGSize
        let columns: Int
        let origin: CGPoint
        let gap: CGFloat

        func rect(_ i: Int) -> CGRect {
            CGRect(x: origin.x + CGFloat(i % columns) * (size.width + gap), y: origin.y + CGFloat(i / columns) * (size.height + gap + 18),
                   width: size.width, height: size.height)
        }
    }

    private func layout(count: Int, aspect: CGFloat, in bounds: CGRect) -> Layout {
        let room = bounds.insetBy(dx: 56, dy: 56)
        let gap: CGFloat = 24
        var best = Layout(size: .zero, columns: 1, origin: room.origin, gap: gap)
        for columns in 1...max(count, 1) {
            let rows = (count + columns - 1) / columns
            let w = min((room.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                        ((room.height - (gap + 18) * CGFloat(rows - 1) - 18) / CGFloat(rows)) * aspect)
            if w > best.size.width { best = Layout(size: CGSize(width: w, height: w / aspect), columns: columns, origin: .zero, gap: gap) }
        }
        let rows = (count + best.columns - 1) / best.columns
        let total = CGSize(width: CGFloat(best.columns) * best.size.width + gap * CGFloat(best.columns - 1),
                           height: CGFloat(rows) * (best.size.height + 18) + gap * CGFloat(rows - 1))
        return Layout(size: best.size, columns: best.columns,
                      origin: CGPoint(x: (room.midX - total.width / 2).rounded(), y: (room.midY - total.height / 2).rounded()), gap: gap)
    }

    private func spreadLayout(_ s: Spread) -> Layout? {
        guard let board = store.node(s.deck), let bounds = store.canvas?.bounds else { return nil }
        return layout(count: s.posts.count + 1, aspect: board.frame.width / max(board.frame.height, 1), in: bounds)
    }

    /// The posts in the order they show: with one taken up, the others make room where it would go.
    private func order(_ s: Spread) -> [Int] {
        guard case .lift(let post, _, _, true) = drag, let at = s.pointer, let to = slot(at: at, in: s) else { return s.posts }
        var list = s.posts
        guard let from = list.firstIndex(of: post) else { return list }
        list.remove(at: from)
        list.insert(post, at: min(max(to > from ? to - 1 : to, 0), list.count))
        return list
    }

    /// Sends every card to where it goes now.
    private func reflow() {
        guard var s = spread, let l = spreadLayout(s) else { return }
        guard s.closing == nil else { return }
        let lifted: Int? = if case .lift(let p, _, _, true) = drag { p } else { nil }
        for (i, p) in order(s).enumerated() {
            var card = s.cards[p] ?? Card(l.rect(i))
            card.aim(l.rect(i))
            card.lift.target = p == lifted ? 1.6 : p == s.hovered ? 1 : 0
            s.cards[p] = card
        }
        spread = s
    }

    private func closeSpread(choosing post: Int?) {
        guard var s = spread, let board = store.node(s.deck) else {
            spread = nil
            return
        }
        let r = view(board.frame)
        let chosen = post ?? store.front(of: board)
        for (i, p) in s.posts.enumerated() {
            guard var card = s.cards[p] else { continue }
            card.aim(p == chosen ? r : receded(r, CGFloat(min(i, 2)) * 0.5 + 0.5, deck: board.id))
            s.cards[p] = card
        }
        s.closing = (chosen, CACurrentMediaTime())
        s.backdrop.target = 0
        s.hovered = nil
        s.hoveredButton = nil
        spread = s
        // In front at once, under the cards flying back, so what is shown and exported is it.
        if let chosen { store.turn(board.id, to: chosen) }
        redraw()
    }

    private func post(at v: CGPoint, in s: Spread) -> Int? {
        s.posts.reversed().first { s.cards[$0]?.rect.insetBy(dx: -4, dy: -4).contains(v) == true }
    }

    /// Where among the posts one let go at `v` would go: before the post it is over, after it past
    /// its middle, after the last past them all.
    private func slot(at v: CGPoint, in s: Spread) -> Int? {
        guard let l = spreadLayout(s) else { return nil }
        var best: (Int, CGFloat)?
        for i in 0...s.posts.count {
            let r = l.rect(min(i, s.posts.count))
            let edge = CGPoint(x: i < s.posts.count ? r.minX - l.gap / 2 : l.rect(s.posts.count - 1).maxX + l.gap / 2, y: r.midY)
            let d = hypot(edge.x - v.x, (edge.y - v.y) * 1.5)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// The round buttons on a card the pointer is on, on screen: export it, throw it away.
    private func buttons(on r: CGRect, post: Int) -> [(Button, CGRect, String)] {
        let d: CGFloat = 26
        return [
            (.remove(post), CGRect(x: r.maxX - d - 6, y: r.minY + 6, width: d, height: d), "trash"),
            (.export(post), CGRect(x: r.maxX - 2 * d - 12, y: r.minY + 6, width: d, height: d), "square.and.arrow.up"),
        ]
    }

    private func addCard(_ s: Spread) -> CGRect? { spreadLayout(s).map { $0.rect(s.posts.count) } }

    private func spreadHover(_ v: CGPoint?) {
        guard var s = spread, s.closing == nil else { return }
        var post: Int?, button: Button?
        if let v {
            post = self.post(at: v, in: s)
            if let p = post, let r = s.cards[p]?.rect {
                button = buttons(on: r, post: p).first { $0.1.insetBy(dx: -3, dy: -3).contains(v) }?.0
            } else if addCard(s)?.contains(v) == true {
                button = .add
            }
        }
        if post != s.hovered || button != s.hoveredButton {
            for p in s.posts { s.cards[p]?.lift.target = p == post ? 1 : 0 }
            s.hovered = post
            s.hoveredButton = button
            spread = s
            redraw()
        }
    }

    private func spreadDown(at v: CGPoint) -> Bool {
        guard let s = spread else { return false }
        guard s.closing == nil else { return true }
        if let p = post(at: v, in: s), let r = s.cards[p]?.rect {
            if let (button, _, _) = buttons(on: r, post: p).first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(v) }) {
                press(button, s)
                return true
            }
            drag = .lift(post: p, grip: CGPoint(x: v.x - r.midX, y: v.y - r.midY), from: v, moved: false)
        } else if addCard(s)?.contains(v) == true {
            press(.add, s)
        } else {
            closeSpread(choosing: nil)
        }
        redraw()
        return true
    }

    private func press(_ button: Button, _ s: Spread) {
        switch button {
        case .export(let post):
            closeSpread(choosing: post)
            store.selection = [s.deck]
            // Once the cards are back in the stack, the post chosen goes out alone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                ExportPanel.present(for: self.store)
            }
        case .remove(let post):
            guard s.posts.count > 1 else { return }
            quietly.insert(s.deck)
            store.removePost(post, from: s.deck)
            spread?.posts.removeAll { $0 == post }
            spread?.cards[post] = nil
            spread?.hovered = nil
            reflow()
            // The last post left is an artboard like any again: its card goes back down onto it.
            if store.node(s.deck)?.isDeck != true { closeSpread(choosing: spread?.posts.first) }
        case .add:
            guard let last = s.posts.last, let l = spreadLayout(s) else { return }
            store.fronts[s.deck] = last
            quietly.insert(s.deck)
            store.addPost(to: s.deck)
            guard let added = store.node(s.deck).flatMap({ store.front(of: $0) }), added != last, var now = spread else { return }
            now.posts = store.node(s.deck)?.posts ?? s.posts
            // Dealt out of the card that adds it, already a copy of the last.
            now.cards[added] = Card(l.rect(s.posts.count))
            now.pictures[added] = now.pictures[last]
            spread = now
            reflow()
        }
        redraw()
    }

    private func drawSpread(in ctx: CGContext, bounds: CGRect) {
        guard var s = spread, let board = store.node(s.deck), let l = spreadLayout(s) else { return }
        let t = CACurrentMediaTime()
        // Each card leaves the stack a moment after the one before, so they fan out.
        if s.closing == nil {
            for (i, p) in s.posts.enumerated() where t - s.opened >= Double(i) * 0.022 { s.cards[p]?.step(dt) }
        } else {
            for p in s.posts { s.cards[p]?.step(dt) }
        }
        s.backdrop.step(dt, stiffness: 180, damping: 26)
        spread = s
        let fill = board.fill.on ? board.fill.color.cgColor : CGColor.white

        ctx.saveGState()
        defer { ctx.restoreGState() }
        let k = CGFloat(min(max(s.backdrop.value, 0), 1))
        ctx.setFillColor(CanvasInk.table.withAlphaComponent(0.985 * k).cgColor)
        ctx.fill(bounds)

        // The card that adds a post, after the last.
        if s.closing == nil {
            let r = l.rect(s.posts.count)
            let lifted = s.hoveredButton == .add
            ctx.saveGState()
            ctx.setAlpha(k)
            let path = CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(lifted ? 0.1 : 0.04).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(lifted ? 0.8 : 0.4).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 5])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let c = CGPoint(x: r.midX, y: r.midY), arm = min(r.width, r.height) * 0.08
            ctx.move(to: CGPoint(x: c.x - arm, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - arm))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        let front = store.front(of: board)
        let broken = store.brokenPosts(of: board)
        let lifted: Int? = if case .lift(let p, _, _, true) = drag { p } else { nil }
        // Back to front: the lifted card, or the one being laid on top, last.
        var drawing = s.posts.reversed() as [Int]
        if let top = lifted ?? s.closing?.post, let i = drawing.firstIndex(of: top) { drawing.append(drawing.remove(at: i)) }
        for p in drawing {
            guard var card = s.cards[p] else { continue }
            var r = card.rect
            if p == lifted, let at = s.pointer, case .lift(_, let grip, _, _) = drag {
                r = CGRect(center: CGPoint(x: at.x - grip.x, y: at.y - grip.y), size: r.size)
            }
            let up = CGFloat(card.lift.value)
            let grown = r.insetBy(dx: -r.width * 0.025 * up, dy: -r.height * 0.025 * up)
            // Leaning the way it flies.
            let lean = CGFloat(max(-0.12, min(0.12, card.x.velocity * 0.00012)))
            drawCard(s.pictures[p], in: grown, turn: lean, lift: min(up, 1) * 0.8, fill: fill, ctx: ctx)
            s.cards[p] = card
            guard s.closing == nil else { continue }
            if p == front || broken.contains(p) {
                ctx.setStrokeColor((broken.contains(p) ? Self.broken : CanvasInk.pencil).withAlphaComponent(k).cgColor)
                ctx.setLineWidth(2)
                ctx.addPath(CGPath(roundedRect: grown.insetBy(dx: -4, dy: -4), cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
            }
            if let i = s.posts.firstIndex(of: p), p != lifted {
                let number = NSAttributedString(string: "\(i + 1)", attributes: [
                    .font: Self.numberFont,
                    .foregroundColor: (p == front ? CanvasInk.pencil : broken.contains(p) ? Self.broken : Self.ink).withAlphaComponent(k),
                ])
                number.draw(at: CGPoint(x: grown.minX, y: grown.maxY + 6))
            }
            if p == s.hovered, p != lifted {
                for (button, rect, symbol) in buttons(on: grown, post: p) where button != .remove(p) || s.posts.count > 1 {
                    drawButton(symbol, in: rect, lifted: s.hoveredButton == button, ctx: ctx)
                }
            }
        }
        spread = s
        // Laid back in the stack, the spread is gone, and the chosen post is in front.
        if let closing = s.closing, t - closing.since > 0.12, s.posts.allSatisfy({ s.cards[$0]?.settled ?? true }) || t - closing.since > 0.9 {
            spread = nil
        }
    }

    private func drawButton(_ symbol: String, in rect: CGRect, lifted: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 5, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor((lifted ? CanvasInk.pencil : Self.surface).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [lifted ? .white : CanvasInk.pencil]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
