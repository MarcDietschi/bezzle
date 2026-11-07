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

    /// A number that follows where it is meant to be as a spring does (the shared `MotionSpring`).
    typealias Spring = MotionSpring

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
        for deck in store.doc.nodes where deck.isDeck && !deck.hidden && deck.posts.count > 1 && !hides(deck) {
            let r = view(deck.frame)
            guard r.insetBy(dx: -20, dy: -20).intersects(bounds), r.width >= 8 else { continue }
            drawBackCards(backCards(r, deck: deck), fill: deck.fill.on ? deck.fill.color.cgColor : .white, in: ctx)
        }
    }

    /// Whether the canvas leaves a deck to the cards drawn here, as while it turns or its posts are
    /// spread out: drawn under them, the artboard would show where they have not yet come to lie.
    func hides(_ board: Node) -> Bool {
        spread?.deck == board.id || (board.isDeck && transitions[board.id] != nil)
    }

    /// How many cards back each post lies behind `front`: the posts after it first, as turning on
    /// brings them up, then those before it.
    private func depths(of posts: [Int], front: Int?) -> [Int: Int] {
        let c = front.flatMap { posts.firstIndex(of: $0) } ?? 0
        guard c < posts.count else { return [:] }
        let order = [posts[c]] + posts[(c + 1)...] + posts[..<c].reversed()
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    }

    /// A post's place in a deck's stack on screen, `depth` cards back: the one in front on the
    /// artboard, the next as the feet below it, any further back hidden behind the last foot.
    private func stacked(_ r: CGRect, depth: Int, deck: Node) -> CGRect {
        let feet = backCards(r, deck: deck)
        guard depth > 0, !feet.isEmpty else { return r }
        return feet[max(feet.count - depth, 0)]
    }

    /// How finely a post is drawn to stand in for its artboard on screen.
    private func stackScale(_ board: Node) -> CGFloat {
        min(store.viewport.zoom * deviceScale, 1600 / max(board.frame.width, board.frame.height, 1))
    }

    private func drawBackCards(_ cards: [CGRect], fill: CGColor, in ctx: CGContext) {
        for (i, card) in cards.enumerated() { drawFoot(card, depth: cards.count - i, fill: fill, ctx: ctx) }
    }

    /// A card `depth` behind the one in front, as its foot shows below it: plain paper, a little
    /// darker the further back it lies.
    private func drawFoot(_ card: CGRect, depth: Int, turn: CGFloat = 0, fill: CGColor, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: card.midX, y: card.midY)
        ctx.rotate(by: turn)
        let local = CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 6, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setFillColor(fill)
        ctx.fill(local)
        ctx.restoreGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.05 * CGFloat(depth)).cgColor)
        ctx.fill(local)
        ctx.setStrokeColor(Self.edge.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(local.insetBy(dx: 0.25, dy: 0.25))
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
            let scale = stackScale(deck)
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
        // At rest, the shadow the canvas gives an artboard, so that a card laid down is the artboard it lands on.
        ctx.setShadow(offset: CGSize(width: 0, height: -(2 * deviceScale + 10 * lift)), blur: 10 * deviceScale + 22 * lift,
                      color: CanvasInk.shadow.withAlphaComponent(0.13 + 0.19 * lift).cgColor)
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
            // The canvas leaves the deck out while it turns (`hides`): the cards are all there is of it.
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

    // MARK: - The posts under a stack

    /// The board the row shows under: the deck the selection is on, or an artboard selected alone.
    /// Not while typing: a click below the artboard to stop must never turn the post or add one.
    private var board: Node? {
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.editingPicture == nil,
              store.building == nil, spread == nil else { return nil }
        if let deck = store.selectedDeck, !deck.hidden { return deck }
        guard store.selection.count == 1, let n = store.node(store.selection[0]), n.isArtboard, !n.locked, !n.hidden else { return nil }
        return n
    }

    /// By board, each eased: how much the row shows, where the ring round the post in front is,
    /// how much the well under it and the words under it show, and how far a card just dealt has
    /// grown in.
    private var pager = Springs<String>()

    /// The row under a selected stack: a small card for each post, in the artboard's shape, the one
    /// in front ringed in pencil as a selection is; after them a round button that adds one. Under
    /// an artboard that is no stack yet, that button alone.
    private struct Dots {
        let board: UUID
        let posts: [Int]
        /// The first post shown, when there are more than fit.
        let first: Int
        let shown: Int
        let front: Int
        /// Each card shown, on screen, where the row lays it now, and how far it has grown in:
        /// a post just dealt grows where it goes, and the cards after it make room.
        let cards: [CGRect]
        let grows: [CGFloat]
        let size: CGSize
        let track: CGRect
        /// The button that adds a post; none on a locked board, which takes none.
        let add: CGRect?

        var pitch: CGFloat { size.width + DeckTool.gap }

        /// Where on the row a place between cards is, as the ring gliding from one to another goes.
        func x(at a: CGFloat) -> CGFloat {
            guard let head = cards.first, let tail = cards.last else { return 0 }
            func mid(_ j: Int) -> CGFloat {
                j < 0 ? head.midX + CGFloat(j) * pitch : j >= cards.count ? tail.midX + CGFloat(j - cards.count + 1) * pitch : cards[j].midX
            }
            let i = Int(a.rounded(.down))
            return mid(i) + (mid(i + 1) - mid(i)) * (a - CGFloat(i))
        }

        func index(at x: CGFloat) -> Int {
            guard let nearest = cards.indices.min(by: { abs(cards[$0].midX - x) < abs(cards[$1].midX - x) }) else { return 0 }
            return first + nearest
        }
    }

    private static let most = 13
    /// Between one card and the next; before the card that adds, a little more.
    fileprivate static let gap: CGFloat = 6
    private static let addGap: CGFloat = 14
    /// The button that adds a post: about as tall as the ring round the post in front.
    private static let addSize: CGFloat = 18
    /// Its plus at rest: the pencil, lighter on the dark table so it reads on its tint.
    private static let addInk = Theme.dynamicNS(0x3559C7, 0x9DB3F5)
    private static let tipFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let well = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.07, darkAlpha: 0.09)

    /// A post's card in the row: about as big as a small square, in the artboard's shape.
    private static func cardSize(_ board: Node) -> CGSize {
        let root = sqrt(min(max(board.frame.width / max(board.frame.height, 1), 0.3), 3.3))
        return CGSize(width: (11 * root).rounded(), height: (11 / root).rounded())
    }

    private func dots(_ board: Node) -> Dots? {
        let r = view(board.frame)
        guard r.width >= 40 else { return nil }
        let posts = board.isDeck ? board.posts : []
        let front = board.isDeck ? store.place(in: board).index : 0
        let shown = min(posts.count, Self.most)
        let first = min(max(front - shown / 2, 0), max(posts.count - shown, 0))
        let size = Self.cardSize(board)
        let grows = posts[first..<first + shown].map { CGFloat(min(max(pager.all[cardKey(board.id, $0)]?.value ?? 1, 0), 1.1)) }
        let pitch = size.width + Self.gap
        let all = grows.reduce(0, +)
        let row = max(all * pitch - Self.gap * min(all, 1), 0)
        let adds = !board.locked
        let width = row + (adds ? Self.addGap * min(all, 1) + Self.addSize : 0)
        let y = (stackFoot(r, deck: board) + 18).rounded()
        let left = r.midX - width / 2
        var x = left
        let cards = grows.map { g -> CGRect in
            defer { x += g * pitch }
            return CGRect(x: (x + g * size.width / 2 - size.width / 2).rounded(), y: y - size.height / 2, width: size.width, height: size.height)
        }
        let add = adds ? CGRect(x: (left + width - Self.addSize).rounded(), y: y - Self.addSize / 2, width: Self.addSize, height: Self.addSize) : nil
        let tall = max(size.height, 12) + 12
        let track = CGRect(x: left.rounded() - 8, y: y - tall / 2, width: row + 16, height: tall)
        return Dots(board: board.id, posts: posts, first: first, shown: shown, front: front, cards: cards, grows: grows, size: size, track: track, add: add)
    }

    /// Where the row under a board lays each post's card it shows, and the button that adds one,
    /// on screen; nil when no row shows under it. What a press there turns to or adds.
    func row(under board: Node) -> (cards: [CGRect], add: CGRect?)? {
        guard self.board?.id == board.id, let d = dots(board) else { return nil }
        return (d.cards, d.add)
    }

    private enum Part: Equatable { case dot(Int), add, offer }
    private var hovered: Part?

    private func part(at v: CGPoint, _ d: Dots) -> Part? {
        if let add = d.add, add.insetBy(dx: -5, dy: -6).contains(v) { return .add }
        if d.shown > 1, d.track.insetBy(dx: 0, dy: -4).contains(v) { return .dot(d.index(at: v.x)) }
        return nil
    }

    /// What the words under the row say, and under what, while it is pointed at or scrubbed; kept
    /// as they fade.
    private var tip: (board: UUID, text: String, x: CGFloat)?

    private func drawDots(_ d: Dots, _ board: Node, in ctx: CGContext) {
        let id = d.board.uuidString
        let k = CGFloat(min(max(pager["shown " + id, start: 0].value, 0), 1))
        guard k > 0.01 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Rises into place under the board as it comes, and fades as one.
        ctx.translateBy(x: 0, y: 5 * (1 - k))
        ctx.setAlpha(k)
        ctx.beginTransparencyLayer(in: (d.add.map { d.track.union($0) } ?? d.track).insetBy(dx: -60, dy: -40), auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }

        let broken = board.isDeck ? store.brokenPosts(of: board) : []
        let scrubbing: Bool = if case .scrub = drag { true } else { false }
        // Scrubbing, the ring is what moves; the card first pressed is not lifted.
        let pointed: Int? = if !scrubbing, case .dot(let i) = hovered { i } else { nil }
        let paper = board.fill.on ? board.fill.color.cgColor : CGColor.white

        // A shallow well under the cards while they are pointed at, as a strip to scrub along.
        let well = CGFloat(min(max(pager["well " + id, start: 0].value, 0), 1))
        if d.shown > 1, well > 0.01 {
            let t = d.track.insetBy(dx: 3 * (1 - well), dy: 2 * (1 - well))
            ctx.addPath(CGPath(roundedRect: t, cornerWidth: t.height / 2, cornerHeight: t.height / 2, transform: nil))
            ctx.setFillColor(Self.well.withAlphaComponent(Self.well.alphaComponent * well).cgColor)
            ctx.fillPath()
        }

        // The cards: those behind receded into the table, the one in front full and lifted. On the
        // light table paper shows little against it, so they recede less.
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let recede: CGFloat = dark ? 0.38 : 0.75
        let ring = pager["at " + id, start: Double(d.front - d.first)]
        let at = CGFloat(ring.value)
        for (i, card) in d.cards.enumerated() {
            let index = d.first + i
            // Dealt in, a card grows from nothing where it goes.
            var grow = d.grows[i]
            // Past what fits, the cards at either end are smaller, as there are more beyond them.
            if d.posts.count > d.shown {
                if (i == 0 && d.first > 0) || (i == d.shown - 1 && d.first + d.shown < d.posts.count) { grow *= 0.5 }
                else if (i == 1 && d.first > 0) || (i == d.shown - 2 && d.first + d.shown < d.posts.count) { grow *= 0.78 }
            }
            guard grow > 0.01 else { continue }
            let near = max(0, 1 - abs(at - CGFloat(i)))
            let lifted = pointed == index ? 1 : 0 as CGFloat
            let scale = grow * (1 + 0.1 * near + 0.14 * lifted * (1 - near))
            let r = CGRect(center: CGPoint(x: card.midX, y: card.midY), size: CGSize(width: card.width * scale, height: card.height * scale))
            let isBroken = index < d.posts.count && broken.contains(d.posts[index])
            drawMiniCard(r, fill: isBroken ? Self.broken.cgColor : paper, alpha: recede + (1 - recede) * max(near, 0.7 * lifted), lift: max(near, lifted), ctx: ctx)
        }

        // The ring round the post in front, as a selection is drawn: it glides from card to card,
        // drawn out a little the faster it goes.
        if d.shown > 0, let firstCard = d.cards.first {
            let frontBroken = d.front < d.posts.count && broken.contains(d.posts[d.front])
            let stretch = min(abs(CGFloat(ring.velocity)) * d.pitch * 0.02, 12)
            let size = CGSize(width: d.size.width * 1.1 + 7 + stretch, height: d.size.height * 1.1 + 7)
            let r = CGRect(center: CGPoint(x: d.x(at: at), y: firstCard.midY), size: size)
            let grown = d.front - d.first < d.grows.count ? min(d.grows[max(d.front - d.first, 0)], 1) : 1
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor((frontBroken ? Self.broken : CanvasInk.pencil).withAlphaComponent(grown).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        let adding = hovered == .add && d.add != nil
        if let add = d.add { drawAdd(add, board: id, dark: dark, ctx: ctx) }

        // Under the row: which post is pointed at or scrubbed to, or what the button does,
        // in a pencil pill as the canvas gives a measure; past what fits, which post is in front.
        let below = d.track.maxY + 6
        if scrubbing, !d.cards.isEmpty {
            tip = (d.board, String(localized: "\(d.front + 1) of \(d.posts.count)"), d.x(at: at))
        } else if let p = pointed, p >= d.first, p - d.first < d.cards.count {
            tip = (d.board, String(localized: "\(p + 1) of \(d.posts.count)"), d.cards[p - d.first].midX)
        } else if adding, let add = d.add {
            tip = (d.board, String(localized: "Add Post"), add.midX)
        }
        let showing = CGFloat(min(max(pager["tip " + id, start: 0].value, 0), 1))
        if showing > 0.01, let tip, tip.board == d.board {
            drawPill(tip.text, under: CGPoint(x: tip.x, y: below), grow: showing, ctx: ctx)
        }
        if d.posts.count > Self.most, showing < 0.99 {
            let label = NSAttributedString(string: String(localized: "\(d.front + 1) of \(d.posts.count)"),
                                           attributes: [.font: Self.numberFont, .foregroundColor: CanvasInk.label.withAlphaComponent(CanvasInk.label.alphaComponent * (1 - showing))])
            let size = label.size()
            label.draw(at: CGPoint(x: (d.track.midX - size.width / 2).rounded(), y: below + (18 - size.height) / 2))
        }
    }

    /// The button that adds a post: round, as the spread's buttons are, a pencil tint at rest;
    /// under the pointer it fills in pencil and swells, and pressed it gives and springs back
    /// as the new post is dealt into the row.
    private func drawAdd(_ add: CGRect, board id: String, dark: Bool, ctx: CGContext) {
        let h = CGFloat(min(max(pager["add " + id, start: 0].value, 0), 1))
        let press = CGFloat(pager["press " + id, start: 0].value)
        let swell = 1 + 0.1 * h - 0.14 * press
        let c = CGPoint(x: add.midX, y: add.midY)
        let disc = CGRect(center: c, size: CGSize(width: Self.addSize * swell, height: Self.addSize * swell))
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(dark ? 0.24 : 0.13).cgColor)
        ctx.fillEllipse(in: disc)
        if h > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(h)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 5, color: CanvasInk.pencil.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(CanvasInk.pencil.cgColor)
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()
        }
        let arm = 3.5 * swell
        for (color, alpha) in [(Self.addInk.cgColor, 1 - h), (CGColor.white, h)] where alpha > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.move(to: CGPoint(x: c.x - arm, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - arm))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A post as a small card of paper on the table: a hairline edge and a contact shadow, which
    /// deepens as it lifts.
    private func drawMiniCard(_ r: CGRect, fill: CGColor, alpha: CGFloat, lift: CGFloat, ctx: CGContext) {
        let shape = CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(in: r.insetBy(dx: -8, dy: -8), auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -(1 + 2 * lift)), blur: 2 + 5 * lift,
                      color: CanvasInk.shadow.withAlphaComponent(0.3 + 0.2 * lift).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
        ctx.setStrokeColor(Self.edge.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.endTransparencyLayer()
    }

    /// Words in a pencil pill, centred on `p.x` with its top at `p.y`, springing out of the row above.
    private func drawPill(_ text: String, under p: CGPoint, grow: CGFloat, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.tipFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = (size.width + 14).rounded(), h: CGFloat = 18
        let pill = CGRect(x: (p.x - w / 2).rounded(), y: p.y.rounded(), width: w, height: h)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: pill.midX, y: pill.minY)
        ctx.scaleBy(x: 0.8 + 0.2 * grow, y: 0.8 + 0.2 * grow)
        ctx.translateBy(x: -pill.midX, y: -pill.minY - 4 * (1 - grow))
        ctx.setAlpha(min(1, grow))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CanvasInk.pencil.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: pill.minX + (w - size.width) / 2, y: pill.minY + (h - size.height) / 2), withAttributes: attrs)
    }

    /// Brings the row in under the board it belongs to, the ring to the post in front, a post just
    /// dealt in, and the well and the words while it is pointed at.
    private func aimPager() {
        let current = board
        for key in pager.all.keys where key.hasPrefix("shown ") && key != "shown " + (current?.id.uuidString ?? "") {
            pager.all[key]?.target = 0
        }
        guard let current, let d = dots(current) else { return }
        let id = current.id.uuidString
        let scrubbing: Bool = if case .scrub = drag { true } else { false }
        let onCards: Bool = if case .dot = hovered { true } else { false }
        aim("shown " + id, 1, from: 0)
        aim("at " + id, Double(d.front - d.first))
        // A post the row has not shown before is dealt in: its card grows where it goes.
        if let known = rowPosts[current.id] {
            for p in d.posts where !known.contains(p) {
                var grow = Spring(0)
                grow.target = 1
                pager.all[cardKey(current.id, p)] = grow
            }
        }
        rowPosts = [current.id: Set(d.posts)]
        pager.all = pager.all.filter { !($0.key.hasPrefix("card ") && $0.value.settled && $0.value.value == 1) }
        aim("well " + id, onCards || scrubbing ? 1 : 0, from: 0)
        aim("tip " + id, onCards || scrubbing || hovered == .add ? 1 : 0, from: 0)
        aim("add " + id, hovered == .add ? 1 : 0, from: 0)
    }

    /// The posts each row last showed, to tell one just dealt.
    private var rowPosts: [UUID: Set<Int>] = [:]

    private func cardKey(_ board: UUID, _ post: Int) -> String { "card \(board.uuidString) \(post)" }

    private func aim(_ key: String, _ target: Double, from start: Double? = nil) {
        var spring = pager[key, start: start ?? target]
        spring.target = target
        pager.all[key] = spring
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
                var press = Spring(1)
                press.target = 0
                pager.all["press " + board.id.uuidString] = press
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

    private func offerRect() -> (rect: CGRect, words: NSAttributedString, button: CGRect, label: NSAttributedString)? {
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
        return (rect, words, CGRect(x: rect.maxX - 4 - b - 16, y: rect.minY + 4, width: b + 16, height: rect.height - 8), button)
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
        let label = o.label.size()
        o.label.draw(at: CGPoint(x: o.button.midX - label.width / 2, y: o.button.midY - label.height / 2))
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

        mutating func step(_ dt: Double, home: Bool = false) {
            // Flying back onto the stack, it comes firmly and stops where it lands, not past it.
            let (stiffness, damping) = home ? (300.0, 32.0) : (210.0, 21.0)
            for k in [\Card.x, \Card.y, \Card.w, \Card.h] { self[keyPath: k].step(dt, stiffness: stiffness, damping: damping) }
            lift.step(dt, stiffness: 400, damping: 30)
        }

        /// Near enough where it is going, and slow enough, for the canvas to take over without a jump.
        var landed: Bool {
            [x, y, w, h].allSatisfy { abs($0.value - $0.target) < 0.35 && abs($0.velocity) < 12 } && abs(lift.value) < 0.01
        }

        /// Kept where it is on the canvas as the view scrolls or zooms under it.
        mutating func carry(from old: Viewport, to new: Viewport) {
            let k = Double(new.zoom / old.zoom)
            let c = new.toView(old.toCanvas(CGPoint(x: x.value, y: y.value)))
            x.value = c.x
            y.value = c.y
            w.value *= k
            h.value *= k
            for path in [\Card.x, \Card.y, \Card.w, \Card.h] { self[keyPath: path].velocity *= k }
        }
    }

    private struct Spread {
        let deck: UUID
        var posts: [Int]
        var pictures: [Int: CGImage] = [:]
        var cards: [Int: Card] = [:]
        /// When each card is let go from the stack to fly to its place, from when the spread opened.
        var opened: CFTimeInterval
        /// The view the cards were last placed in: closing, they go where the stack is on the canvas.
        var viewport: Viewport
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

    /// The spread as it lies on screen now: each post's card, the buttons on it that throw it
    /// away, and the card that adds one. What a press there picks.
    var spreadPlaces: (cards: [Int: CGRect], trash: [Int: CGRect], add: CGRect?)? {
        guard let s = spread else { return nil }
        var cards: [Int: CGRect] = [:], trash: [Int: CGRect] = [:]
        for p in s.posts {
            guard let card = s.cards[p] else { continue }
            cards[p] = card.rect
            trash[p] = buttons(on: face(card), post: p, in: s).first { $0.0 == .remove(p) }?.1
        }
        return (cards, trash, addCard(s))
    }

    /// Every post of a deck flies out of the stack into rows over the canvas.
    func openSpread(_ board: Node) {
        guard board.isDeck, spread == nil, let bounds = store.canvas?.bounds else { return }
        let r = view(board.frame)
        var s = Spread(deck: board.id, posts: board.posts, opened: CACurrentMediaTime(), viewport: store.viewport)
        let front = store.front(of: board)
        // Out of the stack from where each lies in it: the one in front from the artboard, the rest
        // from the feet below it.
        for (p, depth) in depths(of: s.posts, front: front) { s.cards[p] = Card(stacked(r, depth: depth, deck: board)) }
        if let front { s.pictures[front] = picture(board.showing(front), scale: stackScale(board)) }
        s.backdrop.target = 1
        spread = s
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        return layout(count: s.posts.count + (board.locked ? 0 : 1), aspect: board.frame.width / max(board.frame.height, 1), in: bounds)
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
        guard s.closing == nil else { return }
        let chosen = post ?? store.front(of: board)
        s.closing = (chosen, CACurrentMediaTime())
        s.viewport = store.viewport
        s.backdrop.target = 0
        s.hovered = nil
        s.hoveredButton = nil
        // Laid down flat: a card still lifted under the pointer would land larger than its artboard.
        for p in s.posts { s.cards[p]?.lift.target = 0 }
        // The feet it lands on lie close, as they do with the pointer away; pointed at, they part again.
        if let was = pointedDeck { fan.all[was]?.target = 0 }
        pointedDeck = nil
        // In front at once, under the cards flying back, so what is shown and exported is it.
        if let chosen { store.turn(board.id, to: chosen) }
        aimHome(&s)
        spread = s
        sharpen(chosen)
        redraw()
    }

    /// Closing, sends every card to its place in the stack, wherever the stack is on screen now:
    /// the chosen post onto the artboard, the ones behind it onto its feet.
    private func aimHome(_ s: inout Spread) {
        guard let closing = s.closing, let board = store.node(s.deck) else { return }
        let r = view(board.frame)
        for (p, depth) in depths(of: s.posts, front: closing.post) { s.cards[p]?.aim(stacked(r, depth: depth, deck: board)) }
    }

    /// The post chosen drawn again as finely as the artboard it lands on, so that nothing changes
    /// when the canvas takes over from the card. Away from the main thread, while the card flies.
    private func sharpen(_ post: Int?) {
        guard let post, let s = spread, let board = store.node(s.deck) else { return }
        let node = board.isDeck ? board.showing(post) : board
        let scale = stackScale(board), key = node.children.first?.id ?? node.id
        if let kept = drawn[key], kept.scale == scale, kept.node == node {
            spread?.pictures[post] = kept.image
            return
        }
        let assets = store.assets, token = s.token
        struct Made: @unchecked Sendable { let image: CGImage? }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let made = Made(image: Renderer.image(of: node, scale: scale, assets: assets))
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let image = made.image else { return }
                    if self.drawn.count > 40 { self.drawn.removeAll() }
                    self.drawn[key] = (node, scale, image)
                    guard self.spread?.token == token else { return }
                    self.spread?.pictures[post] = image
                    self.redraw()
                }
            }
        }
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

    /// A card as it is drawn: a little larger as it is lifted.
    private func face(_ card: Card) -> CGRect {
        let r = card.rect, up = CGFloat(card.lift.value)
        return r.insetBy(dx: -r.width * 0.025 * up, dy: -r.height * 0.025 * up)
    }

    /// The round buttons on a card the pointer is on, as it is drawn on screen: export it, throw it
    /// away. Large enough to hit without aiming, and well in from the card's corner. The last post
    /// of a deck, and any of a locked one, cannot be thrown away.
    private func buttons(on r: CGRect, post: Int, in s: Spread) -> [(Button, CGRect, String)] {
        let d = min(31, max(24, (r.width * 0.13).rounded()))
        let margin = (d * 0.42).rounded(), gap = (d * 0.28).rounded()
        let top = r.minY + margin
        let export = (Button.export(post), CGRect(x: r.maxX - margin - 2 * d - gap, y: top, width: d, height: d), "square.and.arrow.up")
        guard s.posts.count > 1, takes(s) else { return [export] }
        return [(.remove(post), CGRect(x: r.maxX - margin - d, y: top, width: d, height: d), "trash"), export]
    }

    /// Whether the deck spread out takes posts added and thrown away: not while it is locked.
    private func takes(_ s: Spread) -> Bool { store.node(s.deck)?.locked != true }

    private func addCard(_ s: Spread) -> CGRect? {
        guard takes(s) else { return nil }
        return spreadLayout(s).map { $0.rect(s.posts.count) }
    }

    private func spreadHover(_ v: CGPoint?) {
        guard var s = spread, s.closing == nil else { return }
        var post: Int?, button: Button?
        if let v {
            post = self.post(at: v, in: s)
            if let p = post, let card = s.cards[p] {
                button = buttons(on: face(card), post: p, in: s).first { $0.1.insetBy(dx: -3, dy: -3).contains(v) }?.0
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
        if let p = post(at: v, in: s), let card = s.cards[p] {
            let r = card.rect
            if let (button, _, _) = buttons(on: face(card), post: p, in: s).first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(v) }) {
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
            guard s.posts.count > 1, takes(s) else { return }
            quietly.insert(s.deck)
            store.removePost(post, from: s.deck)
            spread?.posts.removeAll { $0 == post }
            spread?.cards[post] = nil
            spread?.hovered = nil
            reflow()
            // The last post left is an artboard like any again: its card goes back down onto it.
            if store.node(s.deck)?.isDeck != true { closeSpread(choosing: spread?.posts.first) }
        case .add:
            guard takes(s), let last = s.posts.last, let l = spreadLayout(s) else { return }
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
        // A deck undone away, or made an artboard elsewhere, while its posts were out: they go.
        guard let current = spread, let board = store.node(current.deck), board.isDeck || current.closing != nil else {
            spread = nil
            return
        }
        if current.closing == nil, drag == nil, board.posts != current.posts { follow(board, bounds: bounds) }
        guard var s = spread, spreadLayout(s) != nil else { return }
        let t = CACurrentMediaTime()
        let front = store.front(of: board)
        let depth = depths(of: s.posts, front: s.closing != nil ? s.closing?.post : front)
        // Each card leaves the stack a moment after the one in front of it, so they fan out.
        let stagger = min(0.022, 0.3 / Double(max(s.posts.count, 1)))
        if s.closing == nil {
            for p in s.posts where t - s.opened >= Double(depth[p] ?? 0) * stagger { s.cards[p]?.step(dt) }
            s.backdrop.step(dt, stiffness: 180, damping: 26)
        } else {
            // Flying back onto the canvas, they keep to it as it scrolls or zooms.
            if store.viewport != s.viewport {
                for p in s.posts { s.cards[p]?.carry(from: s.viewport, to: store.viewport) }
                s.viewport = store.viewport
            }
            aimHome(&s)
            for p in s.posts { s.cards[p]?.step(dt, home: true) }
            s.backdrop.step(dt, stiffness: 260, damping: 32)
        }
        spread = s
        let fill = board.fill.on ? board.fill.color.cgColor : CGColor.white

        ctx.saveGState()
        defer { ctx.restoreGState() }
        let k = CGFloat(min(max(s.backdrop.value, 0), 1))
        ctx.setFillColor(CanvasInk.table.withAlphaComponent(0.985 * k).cgColor)
        ctx.fill(bounds)

        // The card that adds a post, after the last; fading with the rest as they close.
        if k > 0.01, let r = addCard(s) {
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

        let broken = store.brokenPosts(of: board)
        let lifted: Int? = if case .lift(let p, _, _, true) = drag { p } else { nil }
        let feet = backCards(view(board.frame), deck: board).count
        // Back to front as they lie in the stack, the one in front (or being laid on top) last; one
        // taken up over them all.
        var drawing = s.posts.sorted { (depth[$0] ?? 0) > (depth[$1] ?? 0) }
        if let lifted, let i = drawing.firstIndex(of: lifted) { drawing.append(drawing.remove(at: i)) }
        for p in drawing {
            guard let card = s.cards[p] else { continue }
            var grown = face(card)
            if p == lifted, let at = s.pointer, case .lift(_, let grip, _, _) = drag {
                grown = CGRect(center: CGPoint(x: at.x - grip.x, y: at.y - grip.y), size: grown.size)
            }
            let up = CGFloat(card.lift.value)
            // Leaning the way it flies; coming back to lie in the stack, less, so it lands straight.
            let most = s.closing != nil ? 0.05 : 0.12
            let lean = CGFloat(max(-most, min(most, card.x.velocity * (s.closing != nil ? 0.00006 : 0.00012))))
            // A card behind the one in front is, in the stack, a plain foot below it: it turns into
            // the post as it leaves, and back into the foot as it lands, so that nothing jumps where
            // the canvas draws the feet again. Those further back than the feet show fade instead.
            let d = depth[p] ?? 0
            var foot: CGFloat = 0
            if d > 0 {
                foot = s.closing != nil
                    ? CGFloat(max(0, 1 - hypot(card.x.value - card.x.target, card.y.value - card.y.target) / 48))
                    : CGFloat(min(max(1 - (t - s.opened - Double(d) * stagger) / 0.1, 0), 1))
            }
            if foot > 0, d <= feet { drawFoot(grown, depth: d, turn: lean, fill: fill, ctx: ctx) }
            drawCard(s.pictures[p], in: grown, turn: lean, alpha: 1 - foot, lift: min(up, 1) * 0.8, fill: fill, ctx: ctx)
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
            if s.closing == nil, p == s.hovered, p != lifted {
                for (button, rect, symbol) in buttons(on: grown, post: p, in: s) {
                    drawButton(symbol, in: rect, lifted: s.hoveredButton == button, ctx: ctx)
                }
            }
        }
        // Laid back in the stack, the spread is gone as soon as nothing would move any more, and
        // the canvas draws the deck again, the chosen post in front.
        if let closing = s.closing,
           (s.backdrop.value < 0.02 && s.posts.allSatisfy({ s.cards[$0]?.landed ?? true })) || t - closing.since > 1.2 {
            spread = nil
        }
    }

    /// Takes in posts added or taken away other than here, as by undoing or by someone else: each
    /// new one dealt out of the card that adds, and those gone taken off the table.
    private func follow(_ board: Node, bounds: CGRect) {
        guard var s = spread else { return }
        let now = board.posts
        let from = addCard(s) ?? view(board.frame)
        for p in Set(s.posts).subtracting(now) {
            s.cards[p] = nil
            s.pictures[p] = nil
        }
        for p in now where s.cards[p] == nil { s.cards[p] = Card(from) }
        s.posts = now
        if let h = s.hovered, !now.contains(h) {
            s.hovered = nil
            s.hoveredButton = nil
        }
        spread = s
        reflow()
        drawPictures(bounds: bounds)
    }

    private func drawButton(_ symbol: String, in rect: CGRect, lifted: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 5, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor((lifted ? CanvasInk.pencil : Self.surface).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        let config = NSImage.SymbolConfiguration(pointSize: (rect.width * 0.42).rounded(), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [lifted ? .white : CanvasInk.pencil]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
