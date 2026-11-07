import Foundation
import WinSDK
import WinUI
import WindowsFoundation
import UWP
import BezzleCore

// The others in a shared design's live room, drawn on Windows as the Mac draws them
// (Canvas/LiveMarks.swift, Views/LiveViews.swift): from the core's `LiveScene`, each frame while
// anything eases, in the pencil each of them has on every computer. Pools of light lie on the
// table under the artboards; hands, names, what is held, fresh changes and pencil loops lie over
// the design; tokens of those out of sight sit on the canvas's rim, and in the bar, every token,
// pointed at to show a name, clicked to go along.

/// What the canvas draws of the live room.
@MainActor
final class LiveCanvas {
    /// On the table, under the artboards.
    let lights = Canvas()
    /// Over the design.
    let marks = Canvas()
    /// On the rim, taking the pointer.
    let rim = Canvas()

    /// The canvas's view: the canvas point at its top left, the zoom, and its size.
    var view: () -> (origin: CGPoint, zoom: Double, size: CGSize) = { (.zero, 1, .zero) }
    /// Where this computer is and what it does, for the others.
    var presence: () -> (view: CGRect, selection: [UUID], tool: String, doing: String) = { (.zero, [], "select", "looking") }
    /// The view moved by the camera; `last` once it rests.
    var move: (_ origin: CGPoint, _ zoom: Double, _ last: Bool) -> Void = { _, _, _ in }
    /// The design's layers at these places drawn again, with what the others drag.
    var redraw: (Set<Int>) -> Void = { _ in }
    /// How far the rulers reach into the canvas, when they show.
    var rulers: () -> Double = { 0 }
    /// The bar's tokens changed: the window shows them.
    var peopleChanged: (() -> Void)?

    /// Who else is in the room, for the bar.
    let people = LivePeople()

    nonisolated(unsafe) private var ticking: EventCleanup?
    nonisolated(unsafe) private var timer: Timer?
    private var flying = false
    private var shownAnything = false
    private var hands: [UInt32: (group: Canvas, tag: Border, tool: String, pencil: UInt32, name: String)] = [:]
    private var pools: [UInt32: (image: Image, pencil: UInt32)] = [:]
    private static var poolBitmaps: [String: WriteableBitmap] = [:]
    private var loops: [String: (group: Canvas, key: String)] = [:]
    /// This computer's pointer on the canvas, as last seen; nil off it.
    private var pointer: CGPoint?
    private var tokens: [UInt32: RimToken] = [:]
    private var others: [UIElement] = []
    private var lastStep = 0.0
    private weak var hooked: LiveTogether?

    init() {
        for layer in [lights, marks] { layer.isHitTestVisible = false }
        people.go = { [weak self] id in self?.go(to: id) }
        // Now and then, so the others hear where this computer is, and a room that came is seen.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idle() }
        }
    }

    deinit {
        timer?.invalidate()
        ticking?.dispose()
    }

    /// Something in the room changed: drawn at once, and every frame while it eases.
    func changed() {
        startTicking()
    }

    /// This computer's pointer, on the canvas (nil off it), and where it is on the stage.
    func pointerMoved(to p: CGPoint?, stage: CGPoint) {
        pointer = p
        guard let live = WindowsCore.live else { return }
        let pd = presence()
        live.say(pointer: p, view: pd.view, selection: pd.selection, tool: pd.tool, doing: pd.doing, away: GetActiveWindow() == nil)
        live.pointerMoved(to: p, screen: stage, at: WindowsCore.now)
    }

    private func idle() {
        guard let live = WindowsCore.live else {
            if shownAnything { clear() }
            people.show(nil)
            return
        }
        // A room come anew (the design shared, or opened): it says when something changes.
        if hooked !== live {
            hooked = live
            live.changed = { [weak self] in self?.changed() }
            startTicking()
        }
        say(live)
        if people.show(live) { peopleChanged?() }
    }

    private func say(_ live: LiveTogether) {
        let pd = presence()
        live.say(pointer: pointer, view: pd.view, selection: pd.selection, tool: pd.tool, doing: pd.doing, away: GetActiveWindow() == nil)
    }

    private func startTicking() {
        guard ticking == nil else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.frame() } }
    }

    /// One frame: the view the camera gives, then everything where it is now.
    private func frame() {
        guard let live = WindowsCore.live else {
            clear()
            ticking?.dispose()
            ticking = nil
            return
        }
        let now = WindowsCore.now
        // Thirty times a second is enough for the others to hear where this computer is.
        if now - lastStep > 1.0 / 30 { say(live); lastStep = now }
        var v = view()
        if let moved = live.cameraStep(origin: v.origin, zoom: v.zoom, size: v.size) {
            move(moved.origin, moved.zoom, false)
            flying = true
            v = view()
        } else if flying {
            flying = false
            move(v.origin, v.zoom, true)
        }
        let scene = live.scene(origin: v.origin, zoom: v.zoom, size: v.size)
        if !scene.moving.isEmpty { redraw(scene.moving) }
        draw(scene)
        people.pulse(now)
        if people.show(live) { peopleChanged?() }
        let showing = !scene.hands.isEmpty || !scene.lights.isEmpty || !scene.holds.isEmpty || !scene.tokens.isEmpty || !scene.loops.isEmpty
            || !scene.glows.isEmpty || scene.crop != nil
        shownAnything = showing
        // Nothing easing and nobody working: drawn again only when the room says something.
        let working = scene.tokens.contains { $0.working } || people.anyoneWorking
        if !scene.animating && !working && !flying {
            ticking?.dispose()
            ticking = nil
        }
    }

    private func clear() {
        lights.children.clear()
        marks.children.clear()
        rim.children.clear()
        hands = [:]
        pools = [:]
        loops = [:]
        tokens = [:]
        others = []
        shownAnything = false
    }

    private func go(to id: UInt32) {
        guard let live = WindowsCore.live else { return }
        let v = view()
        if live.winked(id) { live.go(toWinkOf: id, origin: v.origin, zoom: v.zoom, size: v.size) } else { live.go(to: id, origin: v.origin, zoom: v.zoom, size: v.size) }
        startTicking()
    }

    // MARK: Drawing

    private func draw(_ scene: WindowsCore.LiveScene) {
        drawLights(scene.lights)
        // What changes every frame is made again; hands and tokens are kept and moved.
        for e in others { remove(e, from: marks) }
        others = []
        for glow in scene.glows { add(glowShape(glow)) }
        for hold in scene.holds { drawHold(hold) }
        drawLoops(scene.loops)
        drawHands(scene.hands)
        if let crop = scene.crop { drawCrop(crop) }
        drawTokens(scene.tokens)
    }

    private func add(_ e: UIElement?) {
        guard let e else { return }
        marks.children.append(e)
        others.append(e)
    }

    private func remove(_ e: UIElement, from canvas: Canvas) {
        var k: UInt32 = 0
        if (try? canvas.children.indexOf(e, &k)) == true { canvas.children.removeAt(k) }
    }

    static func path(_ d: String, fill: Brush? = nil, stroke: Brush? = nil, width: Double = 1) -> WinUI.Path? {
        guard !d.isEmpty else { return nil }
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d)' StrokeThickness='\(width)' "
            + "StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>"
        guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { return nil }
        path.fill = fill
        path.stroke = stroke
        path.isHitTestVisible = false
        return path
    }

    private static func polygon(_ points: [CGPoint], closed: Bool) -> String {
        var p = PathData()
        for (i, q) in points.enumerated() { if i == 0 { p.move(Double(q.x), Double(q.y)) } else { p.line(Double(q.x), Double(q.y)) } }
        if closed && points.count > 2 { p.close() }
        return p.d
    }

    /// Where each looks: a pool of light in their pencil on the table, brightening it as a lamp
    /// would (the Mac draws it with screen, plus lighter in the dark), made for the table's
    /// colour, so that a picture laid over it gives the same light.
    private func drawLights(_ shown: [WindowsCore.LiveLight]) {
        var seen = Set<UInt32>()
        for light in shown {
            seen.insert(light.id)
            var pool = pools[light.id]
            if pool == nil || pool!.pencil != light.pencil {
                if let old = pool { remove(old.image, from: lights) }
                let image = Image()
                image.stretch = .fill
                image.isHitTestVisible = false
                image.source = Self.poolBitmap(light.pencil)
                lights.children.append(image)
                pool = (image, light.pencil)
                pools[light.id] = pool
            }
            guard let image = pool?.image else { continue }
            try? Canvas.setLeft(image, Double(light.rect.minX))
            try? Canvas.setTop(image, Double(light.rect.minY))
            image.width = max(Double(light.rect.width), 1)
            image.height = max(Double(light.rect.height), 1)
            image.opacity = light.alpha
        }
        for (id, pool) in pools where !seen.contains(id) {
            remove(pool.image, from: lights)
            pools[id] = nil
        }
    }

    /// A pool's picture: the light at its middle, half as strong at 55% of the way out, none at
    /// its rim, over the table as the Mac's screen blend leaves it.
    private static func poolBitmap(_ pencil: UInt32) -> WriteableBitmap {
        let key = "\(pencil)/\(Theme.dark)"
        if let kept = poolBitmaps[key] { return kept }
        let side = 128
        let bitmap = WriteableBitmap(Int32(side), Int32(side))
        let table = Theme.table, dark = Theme.dark
        let t = [Double((table >> 16) & 0xFF), Double((table >> 8) & 0xFF), Double(table & 0xFF)].map { $0 / 255 }
        let s = [Double((pencil >> 16) & 0xFF), Double((pencil >> 8) & 0xFF), Double(pencil & 0xFF)].map { $0 / 255 }
        let strongest = dark ? 0.22 : 0.55
        if let buffer = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) {
            let px = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    let dx = (Double(x) + 0.5) / Double(side) * 2 - 1, dy = (Double(y) + 0.5) / Double(side) * 2 - 1
                    let r = (dx * dx + dy * dy).squareRoot()
                    let a = r >= 1 ? 0 : r <= 0.55 ? strongest * (1 - 0.5 * r / 0.55) : strongest * 0.5 * (1 - (r - 0.55) / 0.45)
                    // What the table is under the light, then that as a colour laid over it.
                    var result = [0.0, 0.0, 0.0], alpha = 0.0
                    for c in 0..<3 {
                        result[c] = dark ? min(1, t[c] + a * s[c]) : t[c] + a * s[c] * (1 - t[c])
                        alpha = max(alpha, (result[c] - t[c]) / max(1 - t[c], 0.001))
                    }
                    alpha = min(alpha, 1)
                    let i = (y * side + x) * 4
                    // Premultiplied BGRA.
                    let p = (0..<3).map { c in max(0, min(1, result[c] - t[c] * (1 - alpha))) }
                    px[i] = UInt8((p[2] * 255).rounded())
                    px[i + 1] = UInt8((p[1] * 255).rounded())
                    px[i + 2] = UInt8((p[0] * 255).rounded())
                    px[i + 3] = UInt8((alpha * 255).rounded())
                }
            }
        }
        try? bitmap.invalidate()
        poolBitmaps[key] = bitmap
        return bitmap
    }

    /// Fresh ink: what someone just changed glows in their pencil and fades.
    private func glowShape(_ glow: WindowsCore.LiveGlow) -> UIElement? {
        let d = Self.polygon(glow.outline, closed: true)
        let group = Canvas()
        group.isHitTestVisible = false
        // The glow round it, as the Mac's soft shadow in their pencil, then the line itself.
        if let halo = Self.path(d, stroke: Theme.brush(glow.pencil, 0.16 * glow.fade), width: 7) { group.children.append(halo) }
        if let line = Self.path(d, fill: Theme.brush(glow.pencil, 0.09 * glow.fade), stroke: Theme.brush(glow.pencil, 0.85 * glow.fade), width: 2) {
            group.children.append(line)
        }
        return group
    }

    /// What someone holds, outlined in their pencil, with their initial on a flag at its corner.
    private func drawHold(_ hold: WindowsCore.LiveHold) {
        for outline in hold.outlines {
            add(Self.path(Self.polygon(outline, closed: outline.count > 2), stroke: Theme.brush(hold.pencil, hold.away ? 0.45 : 0.95), width: 1.25))
        }
        let flag = Border()
        flag.height = 15
        flag.minWidth = 15
        flag.cornerRadius = Theme.corners(3.5)
        flag.background = Theme.brush(hold.pencil)
        flag.isHitTestVisible = false
        let initial = Theme.text(hold.initial, size: 9.5, weight: 700)
        initial.foreground = Theme.brush(0xFFFFFF)
        initial.horizontalAlignment = .center
        initial.margin = Theme.inset(4, 0, 4, 0)
        flag.child = initial
        flag.opacity = hold.away ? 0.5 : 1
        try? Canvas.setLeft(flag, Double(hold.flag.x) - 0.6)
        try? Canvas.setTop(flag, Double(hold.flag.y) - 15)
        add(flag)
    }

    /// Where someone shook their pointer, circled by hand in their pencil: a pale rim under the
    /// line keeps it clear on dark work and light alike, each drawn whole, so the pieces never
    /// darken where they meet.
    private func drawLoops(_ shown: [WindowsCore.LiveLoop]) {
        var seen = Set<String>()
        for loop in shown {
            let id = loop.key.split(separator: "/").first.map(String.init) ?? loop.key
            seen.insert(id)
            if let kept = loops[id], kept.key == loop.key {
                kept.group.opacity = loop.alpha
                continue
            }
            if let kept = loops[id] { remove(kept.group, from: marks) }
            let group = Self.loop(loop, rim: 2.4)
            group.opacity = loop.alpha
            marks.children.append(group)
            loops[id] = (group, loop.key)
        }
        for (id, kept) in loops where !seen.contains(id) {
            remove(kept.group, from: marks)
            loops[id] = nil
        }
    }

    /// A loop as two filled outlines of its line: the pale rim, then the pencil.
    static func loop(_ loop: WindowsCore.LiveLoop, rim: Double) -> Canvas {
        let group = Canvas()
        group.isHitTestVisible = false
        let colour = loop.pencil.map { Theme.brush($0, 0.94) } ?? Theme.brush(Theme.pencil, 0.94)
        for (extra, brush) in [(rim, Theme.brush(0xFFFFFF, 0.5)), (0, colour)] {
            if let shape = path(outline(loop.points, loop.widths.map { $0 + extra }), fill: brush) { group.children.append(shape) }
        }
        return group
    }

    /// The outline of a line through `points`, `widths` wide at each, its ends rounded off.
    private static func outline(_ points: [CGPoint], _ widths: [Double]) -> String {
        guard points.count > 1 else { return "" }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in points.indices {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            var tx = Double(b.x - a.x), ty = Double(b.y - a.y)
            let length = max((tx * tx + ty * ty).squareRoot(), 0.0001)
            tx /= length; ty /= length
            let h = widths[i] / 2
            left.append(CGPoint(x: Double(points[i].x) - ty * h, y: Double(points[i].y) + tx * h))
            right.append(CGPoint(x: Double(points[i].x) + ty * h, y: Double(points[i].y) - tx * h))
        }
        var p = PathData()
        p.move(Double(left[0].x), Double(left[0].y))
        for q in left.dropFirst() { p.line(Double(q.x), Double(q.y)) }
        for q in right.reversed() { p.line(Double(q.x), Double(q.y)) }
        p.close()
        // Round ends, as the pencil's.
        for (c, w) in [(points[0], widths[0]), (points[points.count - 1], widths[widths.count - 1])] {
            p.ellipse(Double(c.x) - w / 2, Double(c.y) - w / 2, w, w)
        }
        return p.d
    }

    /// Each one's hand: the tool they hold, in their pencil, rimmed in white so it reads on
    /// anything, with their name beside it while it shows.
    private func drawHands(_ shown: [WindowsCore.LiveHand]) {
        var seen = Set<UInt32>()
        for hand in shown {
            seen.insert(hand.id)
            var kept = hands[hand.id]
            if kept == nil || kept!.tool != Self.handShape(hand.tool) || kept!.pencil != hand.pencil || kept!.name != hand.name {
                if let old = kept { remove(old.group, from: marks); remove(old.tag, from: marks) }
                let group = Self.handGroup(Self.handShape(hand.tool), pencil: hand.pencil)
                let tag = Self.nameTag(hand.name, pencil: hand.pencil)
                marks.children.append(group)
                marks.children.append(tag)
                kept = (group, tag, Self.handShape(hand.tool), hand.pencil, hand.name)
                hands[hand.id] = kept
            }
            guard let kept else { continue }
            try? Canvas.setLeft(kept.group, Double(hand.at.x))
            try? Canvas.setTop(kept.group, Double(hand.at.y))
            kept.group.opacity = hand.alpha
            kept.tag.opacity = hand.alpha * hand.tag
            kept.tag.visibility = hand.tag > 0.01 ? .visible : .collapsed
            try? Canvas.setLeft(kept.tag, Double(hand.at.x) + 11)
            try? Canvas.setTop(kept.tag, Double(hand.at.y) + 17 + (1 - hand.tag) * 5)
        }
        for (id, kept) in hands where !seen.contains(id) {
            remove(kept.group, from: marks)
            remove(kept.tag, from: marks)
            hands[id] = nil
        }
    }

    private static func handShape(_ tool: String) -> String {
        switch tool {
        case "text": "text"
        case "artboard", "rectangle", "ellipse", "line": "cross"
        case "pen": "pen"
        default: "arrow"
        }
    }

    /// A hand as the Mac's drawHand: its point at the group's corner.
    private static func handGroup(_ shape: String, pencil: UInt32) -> Canvas {
        let group = Canvas()
        group.isHitTestVisible = false
        var p = PathData()
        let filled: Bool
        switch shape {
        case "text":
            p.move(-3, -8); p.quad(-1, -8, 0, -6.5); p.quad(1, -8, 3, -8)
            p.move(0, -6.5); p.line(0, 6.5)
            p.move(-3, 8); p.quad(-1, 8, 0, 6.5); p.quad(1, 8, 3, 8)
            filled = false
        case "cross":
            p.move(0, -8); p.line(0, -2.5); p.move(0, 2.5); p.line(0, 8)
            p.move(-8, 0); p.line(-2.5, 0); p.move(2.5, 0); p.line(8, 0)
            filled = false
        case "pen":
            p.move(0, 0); p.line(4.2, 9.5); p.line(9.5, 14.8); p.line(14.8, 9.5); p.line(9.5, 4.2); p.close()
            filled = true
        default:
            p.move(0, 0); p.line(0, 15.5); p.line(3.9, 11.9); p.line(6.6, 18); p.line(9.1, 16.9); p.line(6.5, 10.9); p.line(11.8, 10.9); p.close()
            filled = true
        }
        // Its soft shadow, a point down; the white rim; then the pencil.
        let d = p.d
        if let shadow = path(d, stroke: Theme.brush(0, 0.16), width: filled ? 3.6 : 5) {
            shadow.renderTransform = { let t = CompositeTransform(); t.translateY = 1; return t }()
            group.children.append(shadow)
        }
        if let rim = path(d, stroke: Theme.brush(0xFFFFFF), width: filled ? 2.6 : 4) { group.children.append(rim) }
        if filled {
            if let body = path(d, fill: Theme.brush(pencil)) { group.children.append(body) }
            if shape == "pen" {
                var slit = PathData()
                slit.move(1.2, 1.2); slit.line(6.6, 6.6)
                if let line = path(slit.d, stroke: Theme.brush(0xFFFFFF), width: 1) { group.children.append(line) }
            }
        } else if let line = path(d, stroke: Theme.brush(pencil), width: 1.8) {
            group.children.append(line)
        }
        return group
    }

    /// Someone's name on a pill in their pencil, white, 19 tall.
    static func nameTag(_ name: String, pencil: UInt32, clock: String? = nil, height: Double = 19) -> Border {
        let pill = Border()
        pill.height = height
        pill.cornerRadius = Theme.corners(height / 2)
        pill.background = Theme.brush(pencil)
        pill.isHitTestVisible = false
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        row.margin = Theme.inset(height > 19 ? 9 : 7, 0, height > 19 ? 9 : 7, 0)
        row.verticalAlignment = .center
        let words = Theme.text(name, size: height > 19 ? 11.5 : 11, weight: 600)
        words.foreground = Theme.brush(0xFFFFFF)
        row.children.append(words)
        if let clock {
            let time = Theme.text(clock, size: 11, weight: 500)
            time.foreground = Theme.brush(0xFFFFFF, 0.75)
            row.children.append(time)
        }
        pill.child = row
        return pill
    }

    /// Crop marks in the canvas's corners, in the pencil of the one it goes along with, coming in
    /// from outside as it starts, and their name along the foot.
    private func drawCrop(_ crop: WindowsCore.LiveCrop) {
        let size = view().size, ruler = rulers()
        let inset = 12 + (1 - crop.alpha) * 28, arm = 22.0
        let b = CGRect(x: inset + ruler, y: inset + ruler, width: Double(size.width) - inset * 2 - ruler, height: Double(size.height) - inset * 2 - ruler)
        var p = PathData()
        for (cx, cy, dx, dy) in [(b.minX, b.minY, 1.0, 1.0), (b.maxX, b.minY, -1.0, 1.0), (b.minX, b.maxY, 1.0, -1.0), (b.maxX, b.maxY, -1.0, -1.0)] {
            p.move(Double(cx) + arm * dx, Double(cy))
            p.line(Double(cx), Double(cy))
            p.line(Double(cx), Double(cy) + arm * dy)
        }
        let group = Canvas()
        group.isHitTestVisible = false
        group.opacity = crop.alpha
        if let rim = Self.path(p.d, stroke: Theme.brush(0xFFFFFF, 0.8), width: 5) { group.children.append(rim) }
        if let line = Self.path(p.d, stroke: Theme.brush(crop.pencil), width: 2.5) { group.children.append(line) }
        let tag = Self.nameTag(crop.name, pencil: crop.pencil)
        try? Canvas.setLeft(tag, Double(b.minX) + arm - 3 + 11)
        try? Canvas.setTop(tag, Double(b.maxY) - 26.5 + 17)
        group.children.append(tag)
        add(group)
    }

    private func drawTokens(_ shown: [WindowsCore.LiveToken]) {
        var seen = Set<UInt32>()
        for token in shown {
            seen.insert(token.id)
            let kept = tokens[token.id] ?? {
                let made = RimToken()
                made.pressed = { [weak self] id in self?.go(to: id) }
                rim.children.append(made.root)
                tokens[token.id] = made
                return made
            }()
            kept.show(token, now: WindowsCore.now)
        }
        for (id, kept) in tokens where !seen.contains(id) {
            remove(kept.root, from: rim)
            tokens[id] = nil
        }
    }
}

// MARK: - On the rim

/// Someone out of sight, on the canvas's rim toward them: a token in their pencil, its point
/// toward them, sliding along the rim as either moves; their name pointed at; a click flies there
/// and goes along with them (the Mac's CompassToken).
@MainActor
final class RimToken {
    let root = Grid()
    var pressed: ((UInt32) -> Void)?
    private let move = CompositeTransform()
    private let point = Canvas()
    private let turn = CompositeTransform()
    private let disc = Ellipse()
    private let initial = Theme.text("", size: 12, weight: 700)
    private let breath = Ellipse()
    private let loopHolder = Canvas()
    private let nameHolder = Canvas()
    private var name: Border?
    private var shownName = ""
    private var at: CGPoint?
    private var last = 0.0
    private var hovering = false
    private var id: UInt32 = 0
    private var loopKey = ""
    private var pencil: UInt32 = 0

    init() {
        root.width = 44
        root.height = 44
        root.background = Theme.clear
        root.renderTransform = move
        move.centerX = 22
        move.centerY = 22
        breath.width = 42
        breath.height = 42
        breath.horizontalAlignment = .center
        breath.verticalAlignment = .center
        breath.isHitTestVisible = false
        root.children.append(breath)
        point.width = 44
        point.height = 44
        point.isHitTestVisible = false
        turn.centerX = 22
        turn.centerY = 22
        point.renderTransform = turn
        root.children.append(point)
        disc.width = 28
        disc.height = 28
        disc.stroke = Theme.brush(0xFFFFFF, 0.9)
        disc.strokeThickness = 2
        disc.horizontalAlignment = .center
        disc.verticalAlignment = .center
        disc.isHitTestVisible = false
        root.children.append(disc)
        initial.foreground = Theme.brush(0xFFFFFF)
        initial.horizontalAlignment = .center
        initial.isHitTestVisible = false
        root.children.append(initial)
        loopHolder.width = 44
        loopHolder.height = 44
        loopHolder.isHitTestVisible = false
        root.children.append(loopHolder)
        nameHolder.isHitTestVisible = false
        root.children.append(nameHolder)
        root.pointerEntered.addHandler { [weak self] _, _ in self?.hover(true) }
        root.pointerExited.addHandler { [weak self] _, _ in self?.hover(false) }
        root.pointerPressed.addHandler { _, args in args?.handled = true }
        root.tapped.addHandler { [weak self] _, args in
            args?.handled = true
            guard let self else { return }
            let id = self.id
            DispatchQueue.main.async { MainActor.assumeIsolated { self.pressed?(id) } }
        }
    }

    private func hover(_ on: Bool) {
        hovering = on
        move.scaleX = on ? 1.12 : 1
        move.scaleY = on ? 1.12 : 1
        name?.visibility = on ? .visible : .collapsed
    }

    func show(_ token: WindowsCore.LiveToken, now: Double) {
        id = token.id
        // Sliding along the rim, as a spring does.
        let dt = last == 0 ? 1.0 / 60 : min(max(now - last, 0.001), 0.1)
        last = now
        if let p = at {
            let k = 1 - exp(-dt / 0.09)
            at = CGPoint(x: Double(p.x) + Double(token.at.x - p.x) * k, y: Double(p.y) + Double(token.at.y - p.y) * k)
        } else {
            at = token.at
        }
        let p = at ?? token.at
        try? Canvas.setLeft(root, Double(p.x) - 22)
        try? Canvas.setTop(root, Double(p.y) - 22)
        if pencil != token.pencil {
            pencil = token.pencil
            disc.fill = Theme.brush(token.pencil)
            breath.fill = Theme.brush(token.pencil)
            point.children.clear()
            // The point, toward them: 9 by 8, 17 out from the middle.
            var d = PathData()
            d.move(22 + 17 + 4.5, 22); d.line(22 + 17 - 4.5, 18); d.line(22 + 17 - 4.5, 26); d.close()
            if let tip = LiveCanvas.path(d.d, fill: Theme.brush(token.pencil)) { point.children.append(tip) }
        }
        turn.rotation = token.angle * 180 / Double.pi
        initial.text = token.initial
        // A slow glow behind someone working this moment.
        breath.visibility = token.working ? .visible : .collapsed
        if token.working {
            let on = 0.5 - 0.5 * cos(now / 1.1 * Double.pi)
            breath.opacity = 0.12 + 0.22 * on
            let s = 0.92 + 0.16 * on
            breath.width = 42 * s
            breath.height = 42 * s
        }
        root.opacity = token.away ? 0.55 : 1
        // The name, toward the inside of the canvas, away from the rim.
        let label = token.name + "|" + (token.clock ?? "")
        if label != shownName {
            shownName = label
            nameHolder.children.clear()
            let pill = LiveCanvas.nameTag(token.name, pencil: token.pencil, clock: token.clock, height: 21)
            pill.visibility = hovering ? .visible : .collapsed
            nameHolder.children.append(pill)
            name = pill
        }
        if let name {
            let inward = (x: -cos(token.angle), y: -sin(token.angle))
            try? name.measure(Size(width: 400, height: 40))
            let w = Double(name.desiredSize.width)
            try? Canvas.setLeft(name, inward.x >= 0 ? 44 : -w)
            try? Canvas.setTop(name, 22 - 10.5 + inward.y * 18)
        }
        // Their wink rings their token instead, in the same hand.
        if let wink = token.wink {
            if wink.key != loopKey {
                loopKey = wink.key
                loopHolder.children.clear()
                var centred = wink
                centred.points = wink.points.map { CGPoint(x: $0.x + 22, y: $0.y + 22) }
                centred.widths = wink.widths
                loopHolder.children.append(LiveCanvas.loop(centred, rim: 2.2))
            }
            loopHolder.opacity = wink.alpha
        } else if !loopKey.isEmpty {
            loopKey = ""
            loopHolder.children.clear()
        }
    }
}

// MARK: - In the bar

/// Who else is in the design this moment, in the bar: their tokens side by side, each opening
/// into their name below it when pointed at, ringed while they work, dimmed while they are
/// elsewhere. A click goes to them, and again lets them go (the Mac's LivePeople).
@MainActor
final class LivePeople {
    let root = StackPanel()
    /// Where the names hang, over everything under the bar.
    let tags = Canvas()
    var go: ((UInt32) -> Void)?
    private var shown = ""
    private var rings: [(ring: Ellipse, working: Bool)] = []
    private(set) var anyoneWorking = false
    /// Whether anyone is there, so that the bar shows the tokens.
    private(set) var hasPeople = false

    init() {
        root.orientation = .horizontal
        root.spacing = -4
        root.verticalAlignment = .center
        tags.isHitTestVisible = false
    }

    /// Shows the room's people: true when whether there are any changed.
    @discardableResult func show(_ live: LiveTogether?) -> Bool {
        let people = live?.people ?? []
        let following = live?.following
        let key = people.map { "\($0.id)|\($0.name)|\($0.pencil)|\($0.doing)|\($0.away)|\(following == $0.id)" }.joined(separator: ",")
        guard key != shown else { return false }
        let had = hasPeople
        shown = key
        root.children.clear()
        tags.children.clear()
        rings = []
        anyoneWorking = false
        for person in people {
            root.children.append(token(person, live: live, following: following == person.id))
        }
        hasPeople = !people.isEmpty
        return had != hasPeople
    }

    /// The rings of those at work, breathing.
    func pulse(_ now: Double) {
        let on = 0.5 - 0.5 * cos(now / 0.9 * Double.pi)
        for (ring, working) in rings where working { ring.opacity = 0.25 + 0.75 * on }
    }

    private func token(_ person: WindowsCore.LivePerson, live: LiveTogether?, following: Bool) -> UIElement {
        let box = Grid()
        box.width = 30
        box.height = 30
        box.background = Theme.clear
        let back = Ellipse()
        back.width = 28
        back.height = 28
        back.fill = following ? Theme.brush(person.pencil, 0.35) : Theme.brush(Theme.paper)
        back.horizontalAlignment = .center
        back.verticalAlignment = .center
        box.children.append(back)
        let disc = Ellipse()
        disc.width = 24
        disc.height = 24
        disc.fill = Theme.brush(person.pencil)
        disc.horizontalAlignment = .center
        disc.verticalAlignment = .center
        box.children.append(disc)
        let initial = Theme.text(person.initial, size: 11, weight: 700)
        initial.foreground = Theme.brush(0xFFFFFF)
        initial.horizontalAlignment = .center
        box.children.append(initial)
        let working = person.doing != "looking" && !person.away
        let ring = Ellipse()
        ring.width = 30
        ring.height = 30
        ring.stroke = Theme.brush(person.pencil, 0.55)
        ring.strokeThickness = 1.5
        ring.visibility = working ? .visible : .collapsed
        box.children.append(ring)
        rings.append((ring, working))
        if working { anyoneWorking = true }
        box.opacity = person.away ? 0.5 : 1
        let grow = CompositeTransform()
        grow.centerX = 15
        grow.centerY = 15
        box.renderTransform = grow
        // The name hanging below on a little point, over what lies under the bar.
        let tag = StackPanel()
        tag.isHitTestVisible = false
        var point = PathData()
        point.move(4.5, 0); point.line(9, 5); point.line(0, 5); point.close()
        if let tip = LiveCanvas.path(point.d, fill: Theme.brush(person.pencil)) {
            let holder = Canvas()
            holder.width = 9
            holder.height = 5
            holder.horizontalAlignment = .center
            holder.margin = Theme.inset(0, 0, 0, -1)
            holder.children.append(tip)
            tag.children.append(holder)
        }
        tag.children.append(LiveCanvas.nameTag(person.name, pencil: person.pencil, clock: live?.clock(of: person), height: 21))
        tag.visibility = .collapsed
        tags.children.append(tag)
        box.pointerEntered.addHandler { [weak self] _, _ in
            grow.scaleX = 1.08
            grow.scaleY = 1.08
            guard let self, let t = try? box.transformToVisual(self.tags), let p = try? t.transformPoint(Point(x: 15, y: 32)) else { return }
            try? tag.measure(Size(width: 400, height: 60))
            try? Canvas.setLeft(tag, Double(p.x) - Double(tag.desiredSize.width) / 2)
            try? Canvas.setTop(tag, Double(p.y))
            tag.visibility = .visible
        }
        box.pointerExited.addHandler { _, _ in
            grow.scaleX = 1
            grow.scaleY = 1
            tag.visibility = .collapsed
        }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        let id = person.id
        box.tapped.addHandler { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.go?(id) } }
        }
        return box
    }
}
