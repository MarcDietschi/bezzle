import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// A number that follows where it is meant to be as a spring does, slightly past it and back (the
/// Mac's MotionSpring, which the app cannot see).
struct DeckSpring {
    var value: Double
    var target: Double
    var velocity = 0.0

    init(_ v: Double) {
        value = v
        target = v
    }

    var settled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

    mutating func step(_ dt: Double, stiffness: Double = 260, damping: Double = 24) {
        guard !settled else {
            value = target
            velocity = 0
            return
        }
        let n = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
        }
    }
}

/// A deck on the canvas as a stack of cards, as the Mac's DeckTool: the posts behind the one in
/// front peek out below it, and fan a little further apart under the pointer. Pressed, they spread
/// out over the canvas, every post at once, to pick one, put them in another order, export one or
/// throw one away; let go, they fly back into the stack. Under a selected deck, a small card for
/// each post turns to it, the post in front ringed in pencil; a round plus after them deals a copy
/// of the post in front, and on an artboard that is no deck yet, makes it one. Every turn moves as
/// cards do: the one in front slides away and the next rises, a new one is dealt out and laid on
/// top, one taken away drops off.
@MainActor
final class DeckView {
    /// Behind the artboards: the feet of the cards behind each deck.
    let feet = Canvas()
    /// Over the canvas: cards moving as posts turn, the row under a selected stack, the spread.
    let layer = Canvas()
    private let session: DesignSession

    /// A rectangle on the canvas, on the stage.
    var toView: (CGRect) -> CGRect = { $0 }
    var stageSize: () -> (width: Double, height: Double) = { (0, 0) }
    var pixelScale: () -> Double = { 1 }
    var zoom: () -> Double = { 1 }
    /// Leaves a deck's artboard to the cards drawn here, or draws it again.
    var hideSheet: (UUID, Bool) -> Void = { _, _ in }
    /// Whether the row may show under a selection: the select tool in hand, nothing typed into.
    var rowAllowed: () -> Bool = { true }
    /// After a post was turned to, added or taken away: the canvas and the panels show it.
    var turned: () -> Void = {}

    init(session: DesignSession) {
        self.session = session
        feet.isHitTestVisible = false
        layer.isHitTestVisible = false
    }

    // MARK: Time

    private var ticking: EventCleanup?
    /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
    private static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1
    private static var clock: Double { WindowsCore.now / slow }
    private var lastFrame = DeckView.clock
    private var dt = 1.0 / 60

    private var animating: Bool {
        !transitions.isEmpty || spreadMoving || !fanSettled || !pagerSettled
    }

    private var spreadMoving: Bool {
        guard let s = spread else { return false }
        if s.closing != nil || !s.backdrop.settled || drag != nil { return true }
        return s.cards.values.contains { !$0.settled } || s.pictures.count < s.posts.count || !s.coarse.isEmpty
    }

    private static func out(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
    private static func settle(_ t: Double) -> Double {
        let x = min(max(t, 0), 1) - 1, c = 1.5
        return 1 + (c + 1) * x * x * x + c * x * x
    }

    /// Draws again now, and frame by frame while anything moves.
    func update() {
        draw()
        guard ticking == nil, animating else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draw()
                if !self.animating {
                    self.ticking?.dispose()
                    self.ticking = nil
                    self.draw()
                }
            }
        }
    }

    /// The design changed: pictures of posts are made again as they are needed.
    func edited() {
        // Kept a moment, for a post taken away to fall as it looked.
        stale = pictures
        pictures = [:]
        update()
    }

    // MARK: The stack

    private var fan: [UUID: DeckSpring] = [:]
    private var fanSettled: Bool { fan.values.allSatisfy(\.settled) }
    private var pointedDeck: UUID?

    private func sliver(_ r: CGRect, _ deck: UUID) -> Double {
        let base = min(9, max(3, Double(r.width) * 0.022))
        return base * (1 + 0.7 * (fan[deck]?.value ?? 0))
    }

    /// The cards behind a deck, on the stage, back first: narrower, and lower, so their foot shows.
    private func backCards(_ r: CGRect, deck: WindowsCore.DeckLook) -> [CGRect] {
        let behind = min(deck.count - 1, 2)
        guard behind > 0 else { return [] }
        let s = sliver(r, deck.id)
        return (1...behind).reversed().map { k in
            let inset = Double(r.width) * 0.035 * Double(k)
            return CGRect(x: Double(r.minX) + inset, y: Double(r.minY) + s * Double(k), width: Double(r.width) - inset * 2, height: Double(r.height))
        }
    }

    private func stackFoot(_ r: CGRect, deck: WindowsCore.DeckLook?) -> Double {
        guard let deck, deck.count > 1 else { return Double(r.maxY) }
        return Double(r.maxY) + sliver(r, deck.id) * Double(min(deck.count - 1, 2))
    }

    /// Whether the canvas leaves a deck to the cards drawn here, as while it turns or its posts
    /// are spread out.
    private func hides(_ id: UUID) -> Bool { spread?.deck == id || transitions[id] != nil }

    /// How many cards back each post lies behind `front`: the posts after it first, then those before.
    private func depths(of posts: [Int], front: Int?) -> [Int: Int] {
        let c = front.flatMap { posts.firstIndex(of: $0) } ?? 0
        guard c < posts.count else { return [:] }
        let order = [posts[c]] + posts[(c + 1)...] + posts[..<c].reversed()
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    }

    private func stacked(_ r: CGRect, depth: Int, deck: WindowsCore.DeckLook) -> CGRect {
        let cards = backCards(r, deck: deck)
        guard depth > 0, !cards.isEmpty else { return r }
        return cards[max(cards.count - depth, 0)]
    }

    /// How finely a post is drawn to stand in for its artboard on the stage.
    private func stackScale(_ deck: WindowsCore.DeckLook) -> Double {
        min(zoom() * pixelScale(), 1600 / max(Double(deck.frame.width), Double(deck.frame.height), 1))
    }

    private func drawFeet() {
        feet.children.clear()
        for deck in WindowsCore.decks() where deck.count > 1 && !hides(deck.id) {
            let r = toView(deck.frame)
            let size = stageSize()
            guard r.insetBy(dx: -20, dy: -20).intersects(CGRect(x: 0, y: 0, width: size.width, height: size.height)), r.width >= 8 else { continue }
            let cards = backCards(r, deck: deck)
            for (i, card) in cards.enumerated() { foot(card, depth: cards.count - i, paper: deck.paper.rgb, into: feet) }
        }
    }

    /// A card `depth` behind the one in front, as its foot shows below it: plain paper, a little
    /// darker the further back it lies.
    private func foot(_ card: CGRect, depth: Int, turn: Double = 0, paper: UInt32, alpha: Double = 1, into canvas: Canvas) {
        let holder = Canvas()
        holder.width = Double(card.width)
        holder.height = Double(card.height)
        holder.opacity = alpha
        let shade = Rectangle()
        shade.width = Double(card.width) + 2
        shade.height = Double(card.height) + 2
        shade.fill = Theme.brush(0x000000, 0.08)
        try? Canvas.setLeft(shade, -1)
        try? Canvas.setTop(shade, 1)
        holder.children.append(shade)
        let face = Rectangle()
        face.width = Double(card.width)
        face.height = Double(card.height)
        face.fill = Theme.brush(Theme.mix(paper, 0x000000, 0.05 * Double(depth)))
        face.stroke = Theme.brush(Theme.ink, Theme.dark ? 0.2 : 0.12)
        face.strokeThickness = 0.5
        holder.children.append(face)
        place(holder, card, turn: turn)
        canvas.children.append(holder)
    }

    private func place(_ e: FrameworkElement, _ r: CGRect, turn: Double) {
        try? Canvas.setLeft(e, Double(r.minX))
        try? Canvas.setTop(e, Double(r.minY))
        if turn != 0 {
            let t = CompositeTransform()
            t.centerX = Double(r.width) / 2
            t.centerY = Double(r.height) / 2
            t.rotation = turn * 180 / .pi
            e.renderTransform = t
        }
    }

    // MARK: Pictures

    private var pictures: [String: WriteableBitmap] = [:]
    private var stale: [String: WriteableBitmap] = [:]

    private func key(_ deck: UUID, _ post: Int?, _ scale: Double) -> String { "\(deck.uuidString) \(post ?? -1) \(Int(scale * 100))" }

    private func picture(_ deck: UUID, post: Int?, scale: Double) -> WriteableBitmap? {
        let key = key(deck, post, scale)
        if let kept = pictures[key] { return kept }
        var bitmap: WriteableBitmap?
        let made = WindowsCore.render(post: post, of: deck, scale: scale) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        guard made, let bitmap else { return nil }
        try? bitmap.invalidate()
        if pictures.count > 60 { pictures.removeAll() }
        pictures[key] = bitmap
        return bitmap
    }

    /// A post as a card: its picture on its paper, turned, faded and shadowed as it lifts.
    private func card(_ image: WriteableBitmap?, in r: CGRect, turn: Double = 0, alpha: Double = 1, lift: Double = 0, paper: UInt32) {
        guard r.width > 0, r.height > 0, alpha > 0.001 else { return }
        let holder = Canvas()
        holder.width = Double(r.width)
        holder.height = Double(r.height)
        holder.opacity = alpha
        // The shadow the canvas gives an artboard at rest, deepening as the card lifts, as on the Mac.
        if let (image, pad) = shadow(Double(r.width), Double(r.height), lift: lift) {
            let shade = Image()
            shade.source = image
            shade.stretch = .fill
            shade.width = Double(r.width) + pad * 2
            shade.height = Double(r.height) + pad * 2
            try? Canvas.setLeft(shade, -pad)
            try? Canvas.setTop(shade, -pad + 2 + 10 * lift)
            holder.children.append(shade)
        }
        let face = Rectangle()
        face.width = Double(r.width)
        face.height = Double(r.height)
        face.fill = Theme.brush(paper)
        holder.children.append(face)
        if let image {
            let picture = Image()
            picture.source = image
            picture.stretch = .fill
            picture.width = Double(r.width)
            picture.height = Double(r.height)
            holder.children.append(picture)
        }
        place(holder, r, turn: turn)
        layer.children.append(holder)
    }

    /// Soft shadows by size and lift, made by Skia once each.
    private var shadows: [String: (WriteableBitmap, Double)] = [:]

    private func shadow(_ w: Double, _ h: Double, lift: Double) -> (WriteableBitmap, Double)? {
        // Near enough in size and lift share one: it is stretched to fit.
        let bw = max(Int((w / 6).rounded()) * 6, 6), bh = max(Int((h / 6).rounded()) * 6, 6), k = Int((min(max(lift, 0), 1) * 4).rounded())
        let key = "\(bw)x\(bh) \(k)"
        if let kept = shadows[key] { return kept }
        let l = Double(k) / 4
        let blur = 10 + 22 * l, pad = (blur * 1.6).rounded()
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: bw, height: bh, pad: Int(pad), blur: blur, dy: 0, colour: Theme.shadow, alpha: 0.13 + 0.19 * l) { pw, ph in
            bitmap = WriteableBitmap(Int32(pw), Int32(ph))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        guard let bitmap else { return nil }
        try? bitmap.invalidate()
        if shadows.count > 80 { shadows.removeAll() }
        // Stretched to the card, the pad grows with it.
        let made = (bitmap, pad * w / Double(bw))
        shadows[key] = made
        return made
    }

    // MARK: Turning

    private struct Transition {
        enum Kind { case forward, backward, deal, remove }
        let kind: Kind
        let start: Double
        let duration: Double
        let old: WriteableBitmap?
        let new: WriteableBitmap?
    }

    private var transitions: [UUID: Transition] = [:]
    /// Each deck as it was last drawn, and the post that was in front, to tell how it changed.
    private var seen: [UUID: WindowsCore.DeckLook] = [:]
    /// Decks to turn without moving, as when the spread lays the chosen post down itself.
    private var quietly: Set<UUID> = []
    private var lastTurn = 0.0

    private func noticeTurns() {
        let t = Self.clock
        dt = min(max(t - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = t
        for k in fan.keys { fan[k]?.step(dt) }
        fan = fan.filter { !($0.value.settled && $0.value.value == 0) }
        for k in pager.keys { pager[k]?.step(dt, stiffness: 320, damping: 28) }
        pager = pager.filter { !($0.value.settled && $0.value.value == 0) }
        let ended = transitions.filter { t - $0.value.start >= $0.value.duration }.map(\.key)
        for id in ended { transitions[id] = nil; hideSheet(id, spread?.deck == id) }

        var now: [UUID: WindowsCore.DeckLook] = [:]
        let size = stageSize()
        for deck in WindowsCore.decks() {
            now[deck.id] = deck
            guard let was = seen[deck.id], was.front != deck.front, !quietly.contains(deck.id), spread?.deck != deck.id else { continue }
            let r = toView(deck.frame)
            guard r.intersects(CGRect(x: 0, y: 0, width: size.width, height: size.height)), r.width >= 24 else { continue }
            let kind: Transition.Kind
            if let f = deck.front, !was.posts.contains(f) {
                kind = .deal
            } else if let w = was.front, !deck.posts.contains(w) {
                kind = .remove
            } else {
                let a = was.front.flatMap { deck.posts.firstIndex(of: $0) } ?? 0, b = deck.front.flatMap { deck.posts.firstIndex(of: $0) } ?? 0
                kind = b >= a ? .forward : .backward
            }
            // Turning quickly, as in scrubbing, each move is quicker.
            let quick = t - lastTurn < 0.3
            lastTurn = t
            let scale = stackScale(deck)
            // A post taken away is drawn as it was, if it was drawn before the change.
            let old = deck.posts.contains(was.front ?? -1) ? picture(deck.id, post: was.front, scale: scale) : stale[key(deck.id, was.front, scale)]
            transitions[deck.id] = Transition(kind: kind, start: t, duration: kind == .deal ? 0.62 : quick ? 0.24 : 0.46,
                                              old: old, new: picture(deck.id, post: deck.front, scale: scale))
            hideSheet(deck.id, true)
        }
        seen = now
        quietly = []
        stale = [:]
    }

    private func receded(_ r: CGRect, _ back: Double, deck: UUID) -> CGRect {
        let w = Double(r.width), h = Double(r.height)
        let inset = w * 0.035 * back
        return CGRect(x: Double(r.minX) + inset, y: Double(r.minY) + sliver(r, deck) * back + inset * h / w,
                      width: w - inset * 2, height: h - inset * 2 * h / w)
    }

    private func drawTransitions() {
        let t = Self.clock
        for (id, move) in transitions {
            guard let deck = WindowsCore.deck(id) else { continue }
            let r = toView(deck.frame)
            let p = min(max((t - move.start) / move.duration, 0), 1)
            let paper = deck.paper.rgb
            let cards = backCards(r, deck: deck)
            for (i, c) in cards.enumerated() { foot(c, depth: cards.count - i, paper: paper, into: layer) }
            let w = Double(r.width), h = Double(r.height), x0 = Double(r.minX), y0 = Double(r.minY)
            switch move.kind {
            case .forward:
                card(move.new, in: receded(r, 1 - Self.out(p), deck: id), paper: paper)
                let q = Self.out(p)
                let away = CGRect(x: x0 - w * 0.72 * q, y: y0 - h * 0.03 * sin(q * .pi), width: w * (1 - 0.1 * q), height: h * (1 - 0.1 * q))
                card(move.old, in: away, turn: -0.14 * q, alpha: min(1, (1 - q) * 4), lift: sin(q * .pi), paper: paper)
            case .backward:
                card(move.old, in: receded(r, Self.out(p), deck: id), paper: paper)
                let q = 1 - Self.settle(p)
                let coming = CGRect(x: x0 - w * 0.72 * q, y: y0 - h * 0.03 * sin(q * .pi), width: w * (1 - 0.1 * q), height: h * (1 - 0.1 * q))
                card(move.new, in: coming, turn: -0.14 * q, alpha: min(1, p * 5), lift: sin(q * .pi), paper: paper)
            case .deal:
                card(move.old, in: receded(r, Self.out(p * 1.6), deck: id), paper: paper)
                let arc = sin(min(p * 1.15, 1) * .pi)
                let x = w * 0.42 * arc, up = h * 0.04 * arc, grow = 1 + 0.04 * arc
                let c = CGRect(x: x0 + x - w * (grow - 1) / 2, y: y0 - up - h * (grow - 1) / 2, width: w * grow, height: h * grow)
                card(move.new, in: c, turn: 0.09 * arc, lift: arc, paper: paper)
            case .remove:
                card(move.new, in: receded(r, 1 - Self.out(p), deck: id), paper: paper)
                let q = Self.out(p)
                let falling = CGRect(x: x0 + w * 0.08 * q, y: y0 + h * 0.35 * q * q, width: w * (1 - 0.15 * q), height: h * (1 - 0.15 * q))
                card(move.old, in: falling, turn: 0.2 * q, alpha: 1 - q, lift: q, paper: paper)
            }
        }
    }

    // MARK: The posts under a stack

    /// The board the row shows under: the deck the selection is on, or an artboard selected alone.
    private var board: WindowsCore.DeckLook? {
        guard rowAllowed(), spread == nil else { return nil }
        if let id = WindowsCore.selectedDeck(session.selection), let deck = WindowsCore.deck(id), !deck.hidden { return deck }
        guard session.selection.count == 1, let n = WindowsCore.boardLook(session.selection[0]), !n.locked, !n.hidden else { return nil }
        return n
    }

    private var pager: [String: DeckSpring] = [:]
    private var pagerSettled: Bool { pager.values.allSatisfy(\.settled) }

    private struct Dots {
        let board: UUID
        let posts: [Int]
        let first: Int
        let shown: Int
        let front: Int
        let cards: [CGRect]
        let grows: [Double]
        let size: CGSize
        let track: CGRect
        let add: CGRect?

        var pitch: Double { Double(size.width) + DeckView.gap }

        func x(at a: Double) -> Double {
            guard let head = cards.first, let tail = cards.last else { return 0 }
            func mid(_ j: Int) -> Double {
                j < 0 ? Double(head.midX) + Double(j) * pitch : j >= cards.count ? Double(tail.midX) + Double(j - cards.count + 1) * pitch : Double(cards[j].midX)
            }
            let i = Int(a.rounded(.down))
            return mid(i) + (mid(i + 1) - mid(i)) * (a - Double(i))
        }

        func index(at x: Double) -> Int {
            guard let nearest = cards.indices.min(by: { abs(Double(cards[$0].midX) - x) < abs(Double(cards[$1].midX) - x) }) else { return 0 }
            return first + nearest
        }
    }

    private static let most = 13
    static let gap = 6.0
    private static let addGap = 14.0
    private static let addSize = 18.0

    private static func cardSize(_ frame: CGRect) -> CGSize {
        let root = sqrt(min(max(Double(frame.width) / max(Double(frame.height), 1), 0.3), 3.3))
        return CGSize(width: (11 * root).rounded(), height: (11 / root).rounded())
    }

    private func cardKey(_ board: UUID, _ post: Int) -> String { "card \(board.uuidString) \(post)" }

    private func dots(_ board: WindowsCore.DeckLook) -> Dots? {
        let r = toView(board.frame)
        guard r.width >= 40 else { return nil }
        let isDeck = board.count > 0 && WindowsCore.deck(board.id) != nil
        let posts = isDeck ? board.posts : []
        let front = isDeck ? board.index : 0
        let shown = min(posts.count, Self.most)
        let first = min(max(front - shown / 2, 0), max(posts.count - shown, 0))
        let size = Self.cardSize(board.frame)
        let grows = posts[first..<first + shown].map { min(max(pager[cardKey(board.id, $0)]?.value ?? 1, 0), 1.1) }
        let pitch = Double(size.width) + Self.gap
        let all = grows.reduce(0, +)
        let row = max(all * pitch - Self.gap * min(all, 1), 0)
        let adds = !board.locked
        let width = row + (adds ? Self.addGap * min(all, 1) + Self.addSize : 0)
        let y = (stackFoot(r, deck: isDeck ? board : nil) + 18).rounded()
        let left = Double(r.midX) - width / 2
        var x = left
        let cards = grows.map { g -> CGRect in
            defer { x += g * pitch }
            return CGRect(x: (x + g * Double(size.width) / 2 - Double(size.width) / 2).rounded(), y: y - Double(size.height) / 2,
                          width: Double(size.width), height: Double(size.height))
        }
        let add = adds ? CGRect(x: (left + width - Self.addSize).rounded(), y: y - Self.addSize / 2, width: Self.addSize, height: Self.addSize) : nil
        let tall = max(Double(size.height), 12) + 12
        let track = CGRect(x: left.rounded() - 8, y: y - tall / 2, width: row + 16, height: tall)
        return Dots(board: board.id, posts: posts, first: first, shown: shown, front: front, cards: cards, grows: grows, size: size, track: track, add: add)
    }

    private enum Part: Equatable { case dot(Int), add }
    private var hovered: Part?

    private func part(at v: CGPoint, _ d: Dots) -> Part? {
        if let add = d.add, add.insetBy(dx: -5, dy: -6).contains(v) { return .add }
        if d.shown > 1, d.track.insetBy(dx: 0, dy: -4).contains(v) { return .dot(d.index(at: Double(v.x))) }
        return nil
    }

    private var tip: (board: UUID, text: String, x: Double)?

    private func aim(_ key: String, _ target: Double, from start: Double? = nil) {
        var spring = pager[key] ?? DeckSpring(start ?? target)
        spring.target = target
        pager[key] = spring
    }

    private var rowPosts: [UUID: Set<Int>] = [:]

    private func aimPager() {
        let current = board
        for key in pager.keys where key.hasPrefix("shown ") && key != "shown " + (current?.id.uuidString ?? "") {
            pager[key]?.target = 0
        }
        guard let current, let d = dots(current) else { return }
        let id = current.id.uuidString
        let scrubbing: Bool = if case .scrub = drag { true } else { false }
        let onCards: Bool = if case .dot = hovered { true } else { false }
        aim("shown " + id, 1, from: 0)
        aim("at " + id, Double(d.front - d.first))
        if let known = rowPosts[current.id] {
            for p in d.posts where !known.contains(p) {
                var grow = DeckSpring(0)
                grow.target = 1
                pager[cardKey(current.id, p)] = grow
            }
        }
        rowPosts = [current.id: Set(d.posts)]
        pager = pager.filter { !($0.key.hasPrefix("card ") && $0.value.settled && $0.value.value == 1) }
        aim("well " + id, onCards || scrubbing ? 1 : 0, from: 0)
        aim("tip " + id, onCards || scrubbing || hovered == .add ? 1 : 0, from: 0)
        aim("add " + id, hovered == .add ? 1 : 0, from: 0)
    }

    private func drawDots(_ d: Dots, _ board: WindowsCore.DeckLook) {
        let id = d.board.uuidString
        let k = min(max(pager["shown " + id]?.value ?? 0, 0), 1)
        guard k > 0.01 else { return }
        let row = Canvas()
        row.opacity = k
        let lift = CompositeTransform()
        lift.translateY = 5 * (1 - k)
        row.renderTransform = lift
        layer.children.append(row)

        let broken = WindowsCore.deck(board.id) != nil ? WindowsCore.brokenPosts(board.id) : []
        let scrubbing: Bool = if case .scrub = drag { true } else { false }
        let pointed: Int? = if !scrubbing, case .dot(let i) = hovered { i } else { nil }
        let paper = board.paper.rgb

        // A shallow well under the cards while they are pointed at, as a strip to scrub along.
        let well = min(max(pager["well " + id]?.value ?? 0, 0), 1)
        if d.shown > 1, well > 0.01 {
            let t = d.track.insetBy(dx: 3 * (1 - well), dy: 2 * (1 - well))
            let strip = Rectangle()
            strip.width = Double(t.width)
            strip.height = Double(t.height)
            strip.radiusX = Double(t.height) / 2
            strip.radiusY = Double(t.height) / 2
            strip.fill = Theme.brush(Theme.ink, (Theme.dark ? 0.09 : 0.07) * well)
            try? Canvas.setLeft(strip, Double(t.minX))
            try? Canvas.setTop(strip, Double(t.minY))
            row.children.append(strip)
        }

        let recede = Theme.dark ? 0.38 : 0.75
        let at = pager["at " + id]?.value ?? Double(d.front - d.first)
        for (i, c) in d.cards.enumerated() {
            let index = d.first + i
            var grow = d.grows[i]
            if d.posts.count > d.shown {
                if (i == 0 && d.first > 0) || (i == d.shown - 1 && d.first + d.shown < d.posts.count) { grow *= 0.5 }
                else if (i == 1 && d.first > 0) || (i == d.shown - 2 && d.first + d.shown < d.posts.count) { grow *= 0.78 }
            }
            guard grow > 0.01 else { continue }
            let near = max(0, 1 - abs(at - Double(i)))
            let lifted = pointed == index ? 1.0 : 0
            let scale = grow * (1 + 0.1 * near + 0.14 * lifted * (1 - near))
            let w = Double(c.width) * scale, h = Double(c.height) * scale
            let r = CGRect(x: Double(c.midX) - w / 2, y: Double(c.midY) - h / 2, width: w, height: h)
            let isBroken = index < d.posts.count && broken.contains(d.posts[index])
            miniCard(r, fill: isBroken ? 0xE5484D : paper, alpha: recede + (1 - recede) * max(near, 0.7 * lifted), lift: max(near, lifted), into: row)
        }

        // The ring round the post in front, as a selection is drawn: it glides from card to card,
        // drawn out a little the faster it goes.
        if d.shown > 0, let firstCard = d.cards.first {
            let frontBroken = d.front < d.posts.count && broken.contains(d.posts[d.front])
            let stretch = min(abs(pager["at " + id]?.velocity ?? 0) * d.pitch * 0.02, 12)
            let w = Double(d.size.width) * 1.1 + 7 + stretch, h = Double(d.size.height) * 1.1 + 7
            let grown = d.front - d.first < d.grows.count ? min(d.grows[max(d.front - d.first, 0)], 1) : 1
            let ring = Rectangle()
            ring.width = w
            ring.height = h
            ring.radiusX = 4
            ring.radiusY = 4
            ring.stroke = Theme.brush(frontBroken ? 0xE5484D : Theme.selection, grown)
            ring.strokeThickness = 1.5
            try? Canvas.setLeft(ring, d.x(at: at) - w / 2)
            try? Canvas.setTop(ring, Double(firstCard.midY) - h / 2)
            row.children.append(ring)
        }

        let adding = hovered == .add && d.add != nil
        if let add = d.add { drawAdd(add, board: id, into: row) }

        // Under the row: which post is pointed at or scrubbed to, or what the button does.
        let below = Double(d.track.maxY) + 6
        if scrubbing, !d.cards.isEmpty {
            tip = (d.board, Words.t("%lld of %lld", d.front + 1, d.posts.count), d.x(at: at))
        } else if let p = pointed, p >= d.first, p - d.first < d.cards.count {
            tip = (d.board, Words.t("%lld of %lld", p + 1, d.posts.count), Double(d.cards[p - d.first].midX))
        } else if adding, let add = d.add {
            tip = (d.board, Words.t("Add Post"), Double(add.midX))
        }
        let showing = min(max(pager["tip " + id]?.value ?? 0, 0), 1)
        if showing > 0.01, let tip, tip.board == d.board {
            pill(tip.text, under: CGPoint(x: tip.x, y: below), grow: showing, into: row)
        }
        if d.posts.count > Self.most, showing < 0.99 {
            let label = Theme.text(Words.t("%lld of %lld", d.front + 1, d.posts.count), size: 11, weight: 500, ink: 3)
            label.opacity = 1 - showing
            try? label.measure(Size(width: 200, height: 30))
            try? Canvas.setLeft(label, (Double(d.track.midX) - Double(label.desiredSize.width) / 2).rounded())
            try? Canvas.setTop(label, below + (18 - Double(label.desiredSize.height)) / 2)
            row.children.append(label)
        }
    }

    /// The button that adds a post: round, a pencil tint at rest; under the pointer it fills in
    /// pencil and swells, and pressed it gives and springs back as the new post is dealt.
    private func drawAdd(_ add: CGRect, board id: String, into row: Canvas) {
        let h = min(max(pager["add " + id]?.value ?? 0, 0), 1)
        let press = pager["press " + id]?.value ?? 0
        let swell = 1 + 0.1 * h - 0.14 * press
        let c = CGPoint(x: add.midX, y: add.midY)
        let d = Self.addSize * swell
        let tint = Ellipse()
        tint.width = d
        tint.height = d
        tint.fill = Theme.brush(Theme.selection, Theme.dark ? 0.24 : 0.13)
        try? Canvas.setLeft(tint, Double(c.x) - d / 2)
        try? Canvas.setTop(tint, Double(c.y) - d / 2)
        row.children.append(tint)
        if h > 0.01 {
            let solid = Ellipse()
            solid.width = d
            solid.height = d
            solid.fill = Theme.brush(Theme.selection, h)
            try? Canvas.setLeft(solid, Double(c.x) - d / 2)
            try? Canvas.setTop(solid, Double(c.y) - d / 2)
            row.children.append(solid)
        }
        let arm = 3.5 * swell
        for (rgb, alpha) in [(Theme.dark ? 0x9DB3F5 : 0x3559C7 as UInt32, 1 - h), (0xFFFFFF as UInt32, h)] where alpha > 0.01 {
            for (w, hh) in [(arm * 2 + 1.5, 1.5), (1.5, arm * 2 + 1.5)] {
                let bar = Rectangle()
                bar.width = w
                bar.height = hh
                bar.radiusX = 0.75
                bar.radiusY = 0.75
                bar.fill = Theme.brush(rgb, alpha)
                try? Canvas.setLeft(bar, Double(c.x) - w / 2)
                try? Canvas.setTop(bar, Double(c.y) - hh / 2)
                row.children.append(bar)
            }
        }
    }

    /// A post as a small card of paper on the table: a hairline edge and a contact shadow, which
    /// deepens as it lifts.
    private func miniCard(_ r: CGRect, fill: UInt32, alpha: Double, lift: Double, into row: Canvas) {
        let holder = Canvas()
        holder.opacity = alpha
        let shade = Rectangle()
        let s = 0.5 + 1.5 * lift
        shade.width = Double(r.width) + s * 2
        shade.height = Double(r.height) + s * 2
        shade.radiusX = 1.5 + s
        shade.radiusY = 1.5 + s
        shade.fill = Theme.brush(Theme.shadow, 0.18 + 0.12 * lift)
        try? Canvas.setLeft(shade, Double(r.minX) - s)
        try? Canvas.setTop(shade, Double(r.minY) - s + 1 + 2 * lift)
        holder.children.append(shade)
        let face = Rectangle()
        face.width = Double(r.width)
        face.height = Double(r.height)
        face.radiusX = 1.5
        face.radiusY = 1.5
        face.fill = Theme.brush(fill)
        face.stroke = Theme.brush(Theme.ink, Theme.dark ? 0.2 : 0.12)
        face.strokeThickness = 0.5
        try? Canvas.setLeft(face, Double(r.minX))
        try? Canvas.setTop(face, Double(r.minY))
        holder.children.append(face)
        row.children.append(holder)
    }

    /// Words in a pencil pill, centred on `p.x` with its top at `p.y`, springing out of the row above.
    private func pill(_ text: String, under p: CGPoint, grow: Double, into row: Canvas) {
        let label = TextBlock()
        label.text = text
        label.fontFamily = Theme.ui
        label.fontSize = 10.5
        label.fontWeight = FontWeight(weight: 600)
        label.foreground = Theme.brush(0xFFFFFF)
        let box = Border()
        box.child = label
        box.height = 18
        box.padding = Theme.inset(7, 0, 7, 0)
        box.cornerRadius = Theme.corners(9)
        box.background = Theme.brush(Theme.selection)
        label.verticalAlignment = .center
        try? box.measure(Size(width: 400, height: 40))
        let w = Double(box.desiredSize.width)
        box.opacity = min(1, grow)
        let t = CompositeTransform()
        t.centerX = w / 2
        t.scaleX = 0.8 + 0.2 * grow
        t.scaleY = 0.8 + 0.2 * grow
        t.translateY = -4 * (1 - grow)
        box.renderTransform = t
        try? Canvas.setLeft(box, (Double(p.x) - w / 2).rounded())
        try? Canvas.setTop(box, Double(p.y).rounded())
        row.children.append(box)
    }

    // MARK: The pointer

    private enum Drag {
        /// Turning from post to post under the pointer, along the row.
        case scrub(UUID)
        /// A post taken up in the spread, where on it it was held, and from where.
        case lift(post: Int, grip: CGPoint, from: CGPoint, moved: Bool)
    }

    private var drag: Drag?
    var dragging: Bool { drag != nil }
    var spreading: Bool { spread != nil }

    /// A press with the select tool on the row, the stack's feet or the spread, on the stage.
    /// False leaves it to the canvas.
    func down(at v: CGPoint) -> Bool {
        if spread != nil { return spreadDown(at: v) }
        if let board, let d = dots(board), let part = part(at: v, d) {
            switch part {
            case .add:
                var press = DeckSpring(1)
                press.target = 0
                pager["press " + board.id.uuidString] = press
                addPost(to: board.id)
            case .dot(let i):
                if i < d.posts.count { turn(board.id, to: d.posts[i]) }
                drag = .scrub(board.id)
            }
            update()
            return true
        }
        // The feet of the cards behind a deck: every post, spread out.
        if let deck = deck(underFeet: v) {
            if !session.selection.contains(deck.id), WindowsCore.selectedDeck(session.selection) != deck.id {
                session.select([deck.id], on: WindowsCore.boardIndex(of: deck.id))
            }
            openSpread(deck.id)
            return true
        }
        return false
    }

    private func deck(underFeet v: CGPoint) -> WindowsCore.DeckLook? {
        WindowsCore.decks().reversed().first { deck in
            guard deck.count > 1 else { return false }
            let r = toView(deck.frame)
            return !r.contains(v) && backCards(r, deck: deck).contains { $0.contains(v) }
        }
    }

    func drag(to v: CGPoint) {
        switch drag {
        case .scrub(let id):
            guard let deck = WindowsCore.deck(id), let d = dots(deck) else { return }
            let i = d.index(at: Double(v.x))
            if i < d.posts.count { turn(id, to: d.posts[i]) }
        case .lift(let post, let grip, let from, let moved):
            if !moved, hypot(Double(v.x - from.x), Double(v.y - from.y)) < 4 { return }
            drag = .lift(post: post, grip: grip, from: from, moved: true)
            spread?.pointer = v
            reflow()
        case nil:
            return
        }
        update()
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
                if let to = slot(at: v, in: s) {
                    WindowsCore.movePost(post, in: s.deck, to: to)
                    session.edited(board: nil)
                }
                spread?.pointer = nil
                spread?.posts = WindowsCore.deck(s.deck)?.posts ?? s.posts
                reflow()
            } else {
                closeSpread(choosing: post)
            }
        }
        update()
    }

    func cancel() -> Bool {
        if case .lift = drag {
            drag = nil
            spread?.pointer = nil
            reflow()
            update()
            return true
        }
        if spread != nil {
            closeSpread(choosing: nil)
            return true
        }
        return false
    }

    /// The pointer over the stage, or gone (nil).
    func hover(_ v: CGPoint?, onCanvas c: CGPoint?) {
        if spread != nil {
            spreadHover(v)
            return
        }
        var part: Part?
        var pointed: UUID?
        if let v, drag == nil {
            if let board, let d = dots(board) { part = self.part(at: v, d) }
            if let c { pointed = WindowsCore.decks().reversed().first { $0.frame.contains(c) }?.id }
            pointed = pointed ?? deck(underFeet: v)?.id
        }
        if pointed != pointedDeck {
            if let was = pointedDeck { fan[was]?.target = 0 }
            if let now = pointed { var f = fan[now] ?? DeckSpring(0); f.target = 1; fan[now] = f }
            pointedDeck = pointed
            update()
        }
        if part != hovered {
            hovered = part
            update()
        }
    }

    /// Whether the pointer at `v` is on something here to press.
    func points(at v: CGPoint) -> Bool {
        if spread != nil { return false }
        if let board, let d = dots(board), part(at: v, d) != nil { return true }
        return deck(underFeet: v) != nil
    }

    // MARK: Acting

    private func turn(_ deck: UUID, to post: Int) {
        let ids = WindowsCore.turn(deck, to: post, selection: session.selection)
        session.select(ids, on: session.board)
        turned()
    }

    private func addPost(to board: UUID) {
        let ids = WindowsCore.addPost(to: board, selection: session.selection)
        session.select(ids, on: WindowsCore.boardIndex(of: board) ?? session.board)
        session.edited(board: nil)
    }

    // MARK: Drawing

    private func draw() {
        noticeTurns()
        aimPager()
        layer.children.clear()
        drawFeet()
        drawTransitions()
        for key in pager.keys where key.hasPrefix("shown ") {
            guard let id = UUID(uuidString: String(key.dropFirst(6))), let board = WindowsCore.deck(id) ?? WindowsCore.boardLook(id), let d = dots(board) else { continue }
            drawDots(d, board)
        }
        if spread != nil { drawSpread() }
    }

    // MARK: Every post at once

    private struct Card {
        var x: DeckSpring, y: DeckSpring, w: DeckSpring, h: DeckSpring
        var lift = DeckSpring(0)

        init(_ r: CGRect) {
            x = DeckSpring(Double(r.midX))
            y = DeckSpring(Double(r.midY))
            w = DeckSpring(Double(r.width))
            h = DeckSpring(Double(r.height))
        }

        var rect: CGRect { CGRect(x: x.value - w.value / 2, y: y.value - h.value / 2, width: w.value, height: h.value) }
        var settled: Bool { x.settled && y.settled && w.settled && h.settled && lift.settled }

        mutating func aim(_ r: CGRect) {
            x.target = Double(r.midX)
            y.target = Double(r.midY)
            w.target = Double(r.width)
            h.target = Double(r.height)
        }

        mutating func step(_ dt: Double, home: Bool = false) {
            let (stiffness, damping) = home ? (300.0, 32.0) : (210.0, 21.0)
            x.step(dt, stiffness: stiffness, damping: damping)
            y.step(dt, stiffness: stiffness, damping: damping)
            w.step(dt, stiffness: stiffness, damping: damping)
            h.step(dt, stiffness: stiffness, damping: damping)
            lift.step(dt, stiffness: 400, damping: 30)
        }

        var landed: Bool {
            [x, y, w, h].allSatisfy { abs($0.value - $0.target) < 0.35 && abs($0.velocity) < 12 } && abs(lift.value) < 0.01
        }
    }

    private struct Spread {
        let deck: UUID
        var posts: [Int]
        var pictures: [Int: WriteableBitmap] = [:]
        var cards: [Int: Card] = [:]
        var opened: Double
        var backdrop = DeckSpring(0)
        var hovered: Int?
        var hoveredButton: Button?
        var pointer: CGPoint?
        var closing: (post: Int?, since: Double)?
        /// Pictures drawn at the canvas's zoom, for leaving the stack: drawn again as the spread shows them.
        var coarse: Set<Int> = []
    }

    private enum Button: Equatable { case export(Int), remove(Int), add }
    private var spread: Spread?

    /// Every post of a deck flies out of the stack into rows over the canvas.
    func openSpread(_ id: UUID) {
        guard let deck = WindowsCore.deck(id), spread == nil else { return }
        let r = toView(deck.frame)
        var s = Spread(deck: id, posts: deck.posts, opened: Self.clock)
        for (p, depth) in depths(of: s.posts, front: deck.front) { s.cards[p] = Card(stacked(r, depth: depth, deck: deck)) }
        if let front = deck.front {
            s.pictures[front] = picture(id, post: front, scale: stackScale(deck))
            s.coarse.insert(front)
        }
        s.backdrop.target = 1
        spread = s
        hideSheet(id, true)
        reflow()
        update()
    }

    /// The posts not drawn yet, a couple a frame, as small as the spread shows them.
    private func drawPictures() {
        guard var s = spread, let deck = WindowsCore.deck(s.deck), let l = spreadLayout(s) else { return }
        // A little finer than the Mac's (which draws at twice the screen's points): Windows screens
        // are often at one pixel a point.
        let scale = min(Double(l.size.width) * 1.1 / max(Double(deck.frame.width), 1), 1) * max(pixelScale(), 1.5)
        var made = 0
        for p in s.posts where (s.pictures[p] == nil || s.coarse.contains(p)) && made < 2 && s.closing == nil {
            if let finer = picture(s.deck, post: p, scale: scale) { s.pictures[p] = finer }
            s.coarse.remove(p)
            made += 1
        }
        spread = s
    }

    private struct Layout {
        let size: CGSize
        let columns: Int
        let origin: CGPoint
        let gap: Double

        func rect(_ i: Int) -> CGRect {
            CGRect(x: Double(origin.x) + Double(i % columns) * (Double(size.width) + gap), y: Double(origin.y) + Double(i / columns) * (Double(size.height) + gap + 18),
                   width: Double(size.width), height: Double(size.height))
        }
    }

    private func layout(count: Int, aspect: Double) -> Layout {
        let stage = stageSize()
        let room = CGRect(x: 0, y: 0, width: stage.width, height: stage.height).insetBy(dx: 56, dy: 56)
        let gap = 24.0
        var best = Layout(size: .zero, columns: 1, origin: room.origin, gap: gap)
        for columns in 1...max(count, 1) {
            let rows = (count + columns - 1) / columns
            let w = min((Double(room.width) - gap * Double(columns - 1)) / Double(columns),
                        ((Double(room.height) - (gap + 18) * Double(rows - 1) - 18) / Double(rows)) * aspect)
            if w > Double(best.size.width) { best = Layout(size: CGSize(width: w, height: w / aspect), columns: columns, origin: .zero, gap: gap) }
        }
        let rows = (count + best.columns - 1) / best.columns
        let total = (Double(best.columns) * Double(best.size.width) + gap * Double(best.columns - 1),
                     Double(rows) * (Double(best.size.height) + 18) + gap * Double(rows - 1))
        return Layout(size: best.size, columns: best.columns,
                      origin: CGPoint(x: (Double(room.midX) - total.0 / 2).rounded(), y: (Double(room.midY) - total.1 / 2).rounded()), gap: gap)
    }

    private func spreadLayout(_ s: Spread) -> Layout? {
        guard let deck = WindowsCore.deck(s.deck) else { return nil }
        return layout(count: s.posts.count + (deck.locked ? 0 : 1), aspect: Double(deck.frame.width) / max(Double(deck.frame.height), 1))
    }

    private func order(_ s: Spread) -> [Int] {
        guard case .lift(let post, _, _, true) = drag, let at = s.pointer, let to = slot(at: at, in: s) else { return s.posts }
        var list = s.posts
        guard let from = list.firstIndex(of: post) else { return list }
        list.remove(at: from)
        list.insert(post, at: min(max(to > from ? to - 1 : to, 0), list.count))
        return list
    }

    private func reflow() {
        guard var s = spread, let l = spreadLayout(s), s.closing == nil else { return }
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
        guard var s = spread, let deck = WindowsCore.deck(s.deck) else {
            spread = nil
            return
        }
        guard s.closing == nil else { return }
        let chosen = post ?? deck.front
        s.closing = (chosen, Self.clock)
        s.backdrop.target = 0
        s.hovered = nil
        s.hoveredButton = nil
        for p in s.posts { s.cards[p]?.lift.target = 0 }
        if let was = pointedDeck { fan[was]?.target = 0 }
        pointedDeck = nil
        // In front at once, under the cards flying back, so what is shown and exported is it.
        if let chosen, chosen != deck.front {
            quietly.insert(s.deck)
            spread = s
            turn(s.deck, to: chosen)
            s = spread ?? s
        }
        aimHome(&s)
        if let chosen, let d = WindowsCore.deck(s.deck) { s.pictures[chosen] = picture(s.deck, post: chosen, scale: stackScale(d)) }
        spread = s
        update()
    }

    private func aimHome(_ s: inout Spread) {
        guard let closing = s.closing, let deck = WindowsCore.deck(s.deck) else { return }
        let r = toView(deck.frame)
        for (p, depth) in depths(of: s.posts, front: closing.post) { s.cards[p]?.aim(stacked(r, depth: depth, deck: deck)) }
    }

    private func post(at v: CGPoint, in s: Spread) -> Int? {
        s.posts.reversed().first { s.cards[$0]?.rect.insetBy(dx: -4, dy: -4).contains(v) == true }
    }

    private func slot(at v: CGPoint, in s: Spread) -> Int? {
        guard let l = spreadLayout(s) else { return nil }
        var best: (Int, Double)?
        for i in 0...s.posts.count {
            let r = l.rect(min(i, s.posts.count))
            let edge = (i < s.posts.count ? Double(r.minX) - l.gap / 2 : Double(l.rect(s.posts.count - 1).maxX) + l.gap / 2, Double(r.midY))
            let d = hypot(edge.0 - Double(v.x), (edge.1 - Double(v.y)) * 1.5)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    private func face(_ card: Card) -> CGRect {
        let r = card.rect, up = card.lift.value
        return r.insetBy(dx: -Double(r.width) * 0.025 * up, dy: -Double(r.height) * 0.025 * up)
    }

    /// The round buttons on a card the pointer is on: export it, throw it away. The last post of a
    /// deck, and any of a locked one, cannot be thrown away.
    private func buttons(on r: CGRect, post: Int, in s: Spread) -> [(Button, CGRect)] {
        let d = min(31, max(24, (Double(r.width) * 0.13).rounded()))
        let margin = (d * 0.42).rounded(), gap = (d * 0.28).rounded()
        let top = Double(r.minY) + margin
        let export = (Button.export(post), CGRect(x: Double(r.maxX) - margin - 2 * d - gap, y: top, width: d, height: d))
        guard s.posts.count > 1, takes(s) else { return [export] }
        return [(.remove(post), CGRect(x: Double(r.maxX) - margin - d, y: top, width: d, height: d)), export]
    }

    private func takes(_ s: Spread) -> Bool { WindowsCore.deck(s.deck)?.locked != true }

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
            update()
        }
    }

    private func spreadDown(at v: CGPoint) -> Bool {
        guard let s = spread else { return false }
        guard s.closing == nil else { return true }
        if let p = post(at: v, in: s), let card = s.cards[p] {
            let r = card.rect
            if let (button, _) = buttons(on: face(card), post: p, in: s).first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(v) }) {
                press(button, s)
                return true
            }
            drag = .lift(post: p, grip: CGPoint(x: Double(v.x - r.midX), y: Double(v.y - r.midY)), from: v, moved: false)
        } else if addCard(s)?.contains(v) == true {
            press(.add, s)
        } else {
            closeSpread(choosing: nil)
        }
        update()
        return true
    }

    private func press(_ button: Button, _ s: Spread) {
        switch button {
        case .export(let post):
            closeSpread(choosing: post)
            session.select([s.deck], on: WindowsCore.boardIndex(of: s.deck))
            // Once the cards are back in the stack, the post chosen goes out alone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated { self?.session.openExport?() }
            }
        case .remove(let post):
            guard s.posts.count > 1, takes(s) else { return }
            quietly.insert(s.deck)
            let ids = WindowsCore.removePost(post, from: s.deck, selection: session.selection)
            session.select(ids, on: session.board)
            session.edited(board: nil)
            spread?.posts.removeAll { $0 == post }
            spread?.cards[post] = nil
            spread?.hovered = nil
            reflow()
            if WindowsCore.deck(s.deck) == nil { closeSpread(choosing: spread?.posts.first) }
        case .add:
            guard takes(s), let last = s.posts.last, let l = spreadLayout(s) else { return }
            WindowsCore.fronts[s.deck] = last
            quietly.insert(s.deck)
            let ids = WindowsCore.addPost(to: s.deck, selection: session.selection)
            session.select(ids, on: session.board)
            session.edited(board: nil)
            guard let added = WindowsCore.deck(s.deck)?.front, added != last, var now = spread else { return }
            now.posts = WindowsCore.deck(s.deck)?.posts ?? s.posts
            now.cards[added] = Card(l.rect(s.posts.count))
            now.pictures[added] = now.pictures[last]
            spread = now
            reflow()
        }
        update()
    }

    private func drawSpread() {
        guard let current = spread, let deck = WindowsCore.deck(current.deck) ?? (current.closing != nil ? seen[current.deck] : nil) else {
            if let s = spread { hideSheet(s.deck, false) }
            spread = nil
            return
        }
        if current.closing == nil, drag == nil, deck.posts != current.posts { follow(deck) }
        drawPictures()
        guard var s = spread, spreadLayout(s) != nil || s.closing != nil else { return }
        let t = Self.clock
        let front = deck.front
        let depth = depths(of: s.posts, front: s.closing != nil ? s.closing?.post : front)
        let stagger = min(0.022, 0.3 / Double(max(s.posts.count, 1)))
        if s.closing == nil {
            for p in s.posts where t - s.opened >= Double(depth[p] ?? 0) * stagger { s.cards[p]?.step(dt) }
            s.backdrop.step(dt, stiffness: 180, damping: 26)
        } else {
            aimHome(&s)
            for p in s.posts { s.cards[p]?.step(dt, home: true) }
            s.backdrop.step(dt, stiffness: 260, damping: 32)
        }
        spread = s
        let paper = deck.paper.rgb
        let stage = stageSize()

        let k = min(max(s.backdrop.value, 0), 1)
        let backdrop = Rectangle()
        backdrop.width = stage.width
        backdrop.height = stage.height
        backdrop.fill = Theme.brush(Theme.table, 0.985 * k)
        layer.children.append(backdrop)

        // The card that adds a post, after the last; fading with the rest as they close.
        if k > 0.01, let r = addCard(s) {
            let lifted = s.hoveredButton == .add
            let box = Rectangle()
            box.width = Double(r.width) - 2
            box.height = Double(r.height) - 2
            box.radiusX = 10
            box.radiusY = 10
            box.fill = Theme.brush(Theme.selection, (lifted ? 0.1 : 0.04) * k)
            box.stroke = Theme.brush(Theme.selection, (lifted ? 0.8 : 0.4) * k)
            box.strokeThickness = 1.5
            let dashes = DoubleCollection()
            dashes.append(4)
            dashes.append(3.3)
            box.strokeDashArray = dashes
            try? Canvas.setLeft(box, Double(r.minX) + 1)
            try? Canvas.setTop(box, Double(r.minY) + 1)
            layer.children.append(box)
            let arm = min(Double(r.width), Double(r.height)) * 0.08
            for (w, h) in [(arm * 2 + 2, 2.0), (2.0, arm * 2 + 2)] {
                let bar = Rectangle()
                bar.width = w
                bar.height = h
                bar.radiusX = 1
                bar.radiusY = 1
                bar.fill = Theme.brush(Theme.selection, (lifted ? 0.8 : 0.4) * k)
                try? Canvas.setLeft(bar, Double(r.midX) - w / 2)
                try? Canvas.setTop(bar, Double(r.midY) - h / 2)
                layer.children.append(bar)
            }
        }

        let broken = WindowsCore.deck(s.deck) != nil ? WindowsCore.brokenPosts(s.deck) : []
        let lifted: Int? = if case .lift(let p, _, _, true) = drag { p } else { nil }
        let feetCount = backCards(toView(deck.frame), deck: deck).count
        var drawing = s.posts.sorted { (depth[$0] ?? 0) > (depth[$1] ?? 0) }
        if let lifted, let i = drawing.firstIndex(of: lifted) { drawing.append(drawing.remove(at: i)) }
        for p in drawing {
            guard let c = s.cards[p] else { continue }
            var grown = face(c)
            if p == lifted, let at = s.pointer, case .lift(_, let grip, _, _) = drag {
                grown = CGRect(x: Double(at.x - grip.x) - Double(grown.width) / 2, y: Double(at.y - grip.y) - Double(grown.height) / 2,
                               width: Double(grown.width), height: Double(grown.height))
            }
            let up = c.lift.value
            let most = s.closing != nil ? 0.05 : 0.12
            let lean = max(-most, min(most, c.x.velocity * (s.closing != nil ? 0.00006 : 0.00012)))
            let d = depth[p] ?? 0
            var foot = 0.0
            if d > 0 {
                foot = s.closing != nil
                    ? max(0, 1 - hypot(c.x.value - c.x.target, c.y.value - c.y.target) / 48)
                    : min(max(1 - (t - s.opened - Double(d) * stagger) / 0.1, 0), 1)
            }
            if foot > 0, d <= feetCount { self.foot(grown, depth: d, turn: lean, paper: paper, into: layer) }
            card(s.pictures[p], in: grown, turn: lean, alpha: 1 - foot, lift: min(up, 1) * 0.8, paper: paper)
            if p == front || broken.contains(p) {
                let ring = Rectangle()
                ring.width = Double(grown.width) + 8
                ring.height = Double(grown.height) + 8
                ring.radiusX = 4
                ring.radiusY = 4
                ring.stroke = Theme.brush(broken.contains(p) ? 0xE5484D : Theme.selection, k)
                ring.strokeThickness = 2
                place(ring, grown.insetBy(dx: -4, dy: -4), turn: lean)
                layer.children.append(ring)
            }
            if let i = s.posts.firstIndex(of: p), p != lifted {
                let number = Theme.text("\(i + 1)", size: 11, weight: 500)
                number.foreground = p == front ? Theme.brush(Theme.selection, k) : broken.contains(p) ? Theme.brush(0xE5484D, k) : Theme.brush(Theme.ink, (Theme.dark ? 0.6 : 0.55) * k)
                try? Canvas.setLeft(number, Double(grown.minX))
                try? Canvas.setTop(number, Double(grown.maxY) + 4)
                layer.children.append(number)
            }
            if s.closing == nil, p == s.hovered, p != lifted {
                for (button, rect) in buttons(on: grown, post: p, in: s) {
                    let lit = s.hoveredButton == button
                    let disc = Ellipse()
                    disc.width = Double(rect.width)
                    disc.height = Double(rect.height)
                    disc.fill = lit ? Theme.brush(Theme.selection) : Theme.brush(Theme.dark ? 0x2B2926 : 0xFFFFFF)
                    disc.stroke = Theme.brush(Theme.shadow, 0.12)
                    disc.strokeThickness = 0.5
                    try? Canvas.setLeft(disc, Double(rect.minX))
                    try? Canvas.setTop(disc, Double(rect.minY))
                    layer.children.append(disc)
                    let size = (Double(rect.width) * 0.55).rounded()
                    let parts: [Glyphs.Part]
                    if case .remove = button { parts = Glyphs.trash(size: size) } else { parts = Glyphs.export(size: size) }
                    let g = Glyphs.view(parts, size: size, brush: lit ? Theme.brush(0xFFFFFF) : Theme.brush(Theme.selection))
                    try? Canvas.setLeft(g, Double(rect.midX) - size / 2)
                    try? Canvas.setTop(g, Double(rect.midY) - size / 2)
                    layer.children.append(g)
                }
            }
        }
        // Laid back in the stack, the spread is gone as soon as nothing would move any more, and
        // the canvas draws the deck again, the chosen post in front.
        if let closing = s.closing,
           (s.backdrop.value < 0.02 && s.posts.allSatisfy({ s.cards[$0]?.landed ?? true })) || t - closing.since > 1.2 {
            spread = nil
            hideSheet(s.deck, false)
            // The feet and the row under the stack come back next frame.
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.update() } }
        }
    }

    /// Takes in posts added or taken away other than here, as by undoing.
    private func follow(_ deck: WindowsCore.DeckLook) {
        guard var s = spread else { return }
        let now = deck.posts
        let from = addCard(s) ?? toView(deck.frame)
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
    }
}
