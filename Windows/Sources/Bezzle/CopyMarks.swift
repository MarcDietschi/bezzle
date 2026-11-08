import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// What the Mac's ComponentTool draws over the design (Canvas/ComponentTool.swift), drawn as it
/// draws it, but for the dashed outlines of the other copies and the name over the copy picked,
/// which the canvas draws (`drawComponents`):
///
/// - When a change to one copy is made in the others, a light runs out from it over the canvas
///   (1700 points a second, faint, gone in 0.75 s) and each copy lights up as it reaches it, the
///   nearest first: a violet wash and a glowing outline that rise in 0.12 s, stay 0.28 s past the
///   last change and fade, and a ring that runs out once from it. Copies changed at once show as
///   they were until the light reaches them, then take the change in 0.2 s.
/// - What was just made a component, or linked to one, has its outline drawn round it.
/// - Under a copy picked whose component has variants (beside it, where there is room) lies a row
///   of them, each drawn as this copy would look as it: the pointer on one lifts it, names it and
///   turns the copy into it on the canvas; a press makes it so; the round button after them makes
///   a new variant of the copy as it looks.
///
/// Glows are the Mac's blurred shadows laid as a few wide, faint strokes, as the canvas's other
/// glows are on Windows.
@MainActor
final class CopyMarks {
    /// The copies as they were, under the dashed outlines of the others.
    let ghosts = Canvas()
    /// The light, the lit copies, their rings and the outlines being drawn, over those.
    let lights = Canvas()
    /// The row of variants.
    let row = Canvas()

    /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage, which is
    /// `size` big, `scale` pixels to its point.
    var view: () -> (zoom: Double, pan: CGPoint, size: CGSize, scale: Double) = { (1, .zero, .zero, 1) }
    /// What is picked, and whether the row may show: the select tool in hand, designing, nothing
    /// being typed, dragged or built.
    var state: () -> (selection: [UUID], free: Bool) = { ([], false) }
    /// The copies lit changed: the dashed outlines leave alone those lit.
    var litChanged: () -> Void = {}
    /// The copy turned into a variant on the canvas while its card is pointed at (nil: as it is).
    var preview: (_ copy: UUID, _ variant: Int?, _ on: Bool) -> Void = { _, _, _ in }
    /// A press on a variant's card, or on the button that makes a new variant.
    var choose: (_ copy: UUID, _ variant: Int?) -> Void = { _, _ in }
    var addVariant: (_ copy: UUID) -> Void = { _ in }

    private static var ink: UInt32 { Theme.linked }
    private static var surface: UInt32 { Theme.dark ? 0x2B2926 : 0xFFFFFF }
    private static var edge: (UInt32, Double) { Theme.dark ? (0xEDEAE4, 0.2) : (0x1C1B19, 0.12) }

    // MARK: Time

    /// Seconds, slowed as BEZZLE_SLOW asks, counted while anything moves.
    private var clock = 0.0
    private lazy var ticker = Motion.Ticker { [weak self] dt in self?.step(dt) ?? false }

    init() {
        for c in [ghosts, lights, row] { c.isHitTestVisible = false }
        for e: UIElement in [nameShade, namePill, addShade, addRing] { e.isHitTestVisible = false }
        namePill.child = nameText
        nameText.margin = Theme.inset(6, 1, 6, 1)
    }

    private func step(_ dt: Double) -> Bool {
        clock += dt
        stepRow(dt)
        draw()
        return moving
    }

    private var moving: Bool {
        !lit.isEmpty || !waves.isEmpty || !traces.isEmpty || !shownGhosts.isEmpty || !rowSettled
    }

    // MARK: Where copies are

    private func onStage(_ p: CGPoint) -> CGPoint {
        let v = view()
        return CGPoint(x: Double(v.pan.x) + Double(p.x) * v.zoom, y: Double(v.pan.y) + Double(p.y) * v.zoom)
    }

    /// A copy's corners on the stage, turned as it is.
    private func corners(_ id: UUID) -> [CGPoint]? {
        WindowsCore.copyCorners(id).map { $0.map(onStage) }
    }

    private func box(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CGRect(x: x0, y: y0, width: (xs.max() ?? x0) - x0, height: (ys.max() ?? y0) - y0)
    }

    private static func smooth(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: The light running between copies

    private struct Lit {
        var from: Double
        var last: Double
    }

    private var lit: [UUID: Lit] = [:]
    private var waves: [(center: CGPoint, start: Double)] = []
    private var traces: [UUID: Double] = [:]
    private var seen: Int?
    /// The copies as they were and when the light reaches each.
    private var ghostAt: [UUID: Double] = [:]
    private var shownGhosts: [UUID: (image: Image, bitmap: WriteableBitmap?)] = [:]
    /// The copies lit enough that their dashed outline gives way, as last told.
    private(set) var litNow: Set<UUID> = []
    private static let speed = 1700.0

    /// Takes the last change to copies, once: the light runs from where it was made.
    func take() {
        guard let echo = WindowsCore.copyEchoLook, echo.token != seen else { return }
        seen = echo.token
        let now = clock
        let source = echo.from.first.flatMap(corners).map { box($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        if echo.made {
            for id in echo.from + echo.to { traces[id] = now }
        }
        if let source, !echo.to.isEmpty, waves.last.map({ now - $0.start > 0.45 }) ?? true {
            waves.append((source, now))
        }
        clearGhosts()
        let size = view().size
        let visible = CGRect(x: -40, y: -40, width: Double(size.width) + 80, height: Double(size.height) + 80)
        for id in echo.to {
            let c = corners(id).map { box($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
            let d = source.flatMap { s in c.map { hypot(Double($0.x - s.x), Double($0.y - s.y)) } } ?? 0
            let start = now + min(0.5, d / Self.speed)
            if echo.was, echo.to.count <= 120, let c, visible.contains(c) { makeGhost(id, at: start) }
            if var l = lit[id], now - l.last < 0.6 {
                l.last = max(l.last, start)
                lit[id] = l
            } else {
                lit[id] = Lit(from: start, last: start)
            }
        }
        draw()
        ticker.start()
    }

    private func glow(_ l: Lit, _ now: Double) -> Double {
        let rise = Self.smooth((now - l.from) / 0.12)
        let after = now - l.last - 0.28
        let fall = after <= 0 ? 1 : exp(-after / 0.32)
        return rise * fall
    }

    /// Whether a copy is lit enough that its dashed outline gives way to the light.
    func isLit(_ id: UUID) -> Bool { litNow.contains(id) }

    private func makeGhost(_ id: UUID, at start: Double) {
        let v = view()
        let image = Image()
        image.isHitTestVisible = false
        image.stretch = .fill
        var bitmap: WriteableBitmap?
        let covered = WindowsCore.copyGhost(id, scale: v.scale, zoom: v.zoom, pan: v.pan, stage: v.size) { width, height in
            bitmap = WriteableBitmap(Int32(width), Int32(height))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        guard let covered else { return }
        try? bitmap?.invalidate()
        image.source = bitmap
        try? Canvas.setLeft(image, Double(covered.minX))
        try? Canvas.setTop(image, Double(covered.minY))
        image.width = Double(covered.width)
        image.height = Double(covered.height)
        ghosts.children.append(image)
        shownGhosts[id] = (image, bitmap)
        ghostAt[id] = start
    }

    private func clearGhosts() {
        ghosts.children.clear()
        shownGhosts = [:]
        ghostAt = [:]
    }

    /// The elements one lit copy is drawn with, kept while it is lit.
    private final class LitShape {
        let group = Canvas()
        let wash = Rectangle()
        let glows = [Rectangle(), Rectangle()]
        let line = Rectangle()
        let ring = Rectangle()
        init() {
            group.isHitTestVisible = false
            for r in [wash] + glows + [line, ring] { r.isHitTestVisible = false }
            group.children.append(wash)
            for g in glows { group.children.append(g) }
            group.children.append(line)
        }
    }
    private var litShapes: [UUID: LitShape] = [:]
    private var waveRings: [(line: Ellipse, glows: [Ellipse])] = []
    private var tracePaths: [UUID: [WinUI.Path]] = [:]

    /// Lays a rectangle over a copy's outline grown by `grow`, its stroke `stroke` wide centred on
    /// that outline: the copy upright, its corners a little round (4 more than it grew); turned,
    /// square and turned with it.
    private func lay(_ r: Rectangle, _ pts: [CGPoint], grow: Double, stroke: Double) {
        guard pts.count == 4 else { return }
        let c0 = pts[0], c1 = pts[1], c3 = pts[3]
        let w = hypot(Double(c1.x - c0.x), Double(c1.y - c0.y)), h = hypot(Double(c3.x - c0.x), Double(c3.y - c0.y))
        let angle = atan2(Double(c1.y - c0.y), Double(c1.x - c0.x)) * 180 / .pi
        let cx = pts.reduce(0) { $0 + Double($1.x) } / 4, cy = pts.reduce(0) { $0 + Double($1.y) } / 4
        // XAML strokes a rectangle inside its bounds: half the stroke out past the outline.
        let rw = w + 2 * grow + stroke, rh = h + 2 * grow + stroke
        let upright = abs(angle.truncatingRemainder(dividingBy: 90)) < 0.05
        let radius = upright ? min(4 + grow, (w + 2 * grow) / 2, (h + 2 * grow) / 2) + stroke / 2 : 0
        r.width = max(rw, 0)
        r.height = max(rh, 0)
        r.radiusX = max(radius, 0)
        r.radiusY = max(radius, 0)
        r.strokeThickness = stroke
        try? Canvas.setLeft(r, cx - rw / 2)
        try? Canvas.setTop(r, cy - rh / 2)
        if upright {
            r.renderTransform = nil
        } else {
            let t = CompositeTransform()
            t.centerX = rw / 2
            t.centerY = rh / 2
            t.rotation = angle
            r.renderTransform = t
        }
    }

    private func drawLight(_ now: Double) {
        // The light running out over the canvas.
        waves.removeAll { now - $0.start > 0.75 }
        while waveRings.count < waves.count {
            let line = Ellipse(), glows = [Ellipse(), Ellipse()]
            for e in glows + [line] {
                e.isHitTestVisible = false
                lights.children.append(e)
            }
            waveRings.append((line, glows))
        }
        for (k, ring) in waveRings.enumerated() {
            guard k < waves.count, now >= waves[k].start else {
                ring.line.visibility = .collapsed
                for g in ring.glows { g.visibility = .collapsed }
                continue
            }
            let w = waves[k], t = now - w.start
            let r = t * Self.speed
            let a = 0.22 * (1 - Self.smooth(t / 0.75))
            // A line 1.5 wide, glowing 10 round: the glow's own strokes, faint and wide.
            for (e, (stroke, alpha)) in zip([ring.line] + ring.glows, [(1.5, a), (12.0, a * 0.22), (5.0, a * 0.3)]) {
                e.visibility = a > 0.005 ? .visible : .collapsed
                e.stroke = Theme.brush(Self.ink, alpha)
                e.strokeThickness = stroke
                e.width = 2 * r + stroke
                e.height = 2 * r + stroke
                try? Canvas.setLeft(e, Double(w.center.x) - r - stroke / 2)
                try? Canvas.setTop(e, Double(w.center.y) - r - stroke / 2)
            }
        }
        // Each copy as the light reaches it: it lights up, and a ring runs out from it.
        var nowLit: Set<UUID> = []
        for (id, l) in lit {
            let k = glow(l, now)
            if now > l.last + 2.5 {
                lit[id] = nil
                if let s = litShapes.removeValue(forKey: id) { remove(s) }
                continue
            }
            if k >= 0.05 { nowLit.insert(id) }
            guard k > 0.01, let pts = corners(id) else {
                litShapes[id]?.group.visibility = .collapsed
                litShapes[id]?.ring.visibility = .collapsed
                continue
            }
            let s = litShapes[id] ?? {
                let s = LitShape()
                lights.children.append(s.group)
                lights.children.append(s.ring)
                s.wash.fill = Theme.brush(Self.ink, 0.12)
                s.glows[0].stroke = Theme.brush(Self.ink, 0.035)
                s.glows[1].stroke = Theme.brush(Self.ink, 0.07)
                s.line.stroke = Theme.brush(Self.ink, 1)
                litShapes[id] = s
                return s
            }()
            s.group.visibility = .visible
            s.group.opacity = k
            lay(s.wash, pts, grow: 2, stroke: 0)
            // The Mac's shadow round the line, 22 soft at its strongest.
            lay(s.glows[0], pts, grow: 2, stroke: 30 * k)
            lay(s.glows[1], pts, grow: 2, stroke: 12 * k)
            lay(s.line, pts, grow: 2, stroke: 2)
            // The ring, once, as the light first reaches it.
            let t = (now - l.from) / 0.55
            if t > 0, t < 1 {
                s.ring.visibility = .visible
                s.ring.stroke = Theme.brush(Self.ink, 0.55 * (1 - t))
                lay(s.ring, pts, grow: 2 + Self.smooth(t) * 14, stroke: 1.5)
            } else {
                s.ring.visibility = .collapsed
            }
        }
        if nowLit != litNow {
            litNow = nowLit
            litChanged()
        }
        // An outline drawn round what was just made a component, or linked to one.
        for (id, start) in traces {
            let t = now - start
            guard t <= 1.1 else {
                traces[id] = nil
                for p in tracePaths.removeValue(forKey: id) ?? [] { remove(p) }
                continue
            }
            for p in tracePaths.removeValue(forKey: id) ?? [] { remove(p) }
            guard t >= 0, let pts = corners(id), let first = pts.first else { continue }
            let sides = zip(pts, pts.dropFirst() + [first]).map { (a: $0.0, b: $0.1, l: hypot(Double($0.1.x - $0.0.x), Double($0.1.y - $0.0.y))) }
            let length = sides.reduce(0) { $0 + $1.l }
            var left = Self.smooth(t / 0.55) * length
            let fade = 1 - Self.smooth((t - 0.6) / 0.5)
            guard left > 0.5, fade > 0.01 else { continue }
            var d = PathData()
            d.move(Double(first.x), Double(first.y))
            for side in sides {
                guard left > 0 else { break }
                let f = min(1, left / max(side.l, 0.001))
                d.line(Double(side.a.x) + (Double(side.b.x) - Double(side.a.x)) * f, Double(side.a.y) + (Double(side.b.y) - Double(side.a.y)) * f)
                left -= side.l
            }
            var made: [WinUI.Path] = []
            // A line 2 wide, glowing 10 round.
            for (stroke, alpha) in [(9.0, 0.6 * fade * 0.22), (4.0, 0.6 * fade * 0.3), (2.0, fade)] {
                guard let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='\(stroke)' StrokeLineJoin='Round' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>")) as? WinUI.Path else { continue }
                path.stroke = Theme.brush(Self.ink, alpha)
                path.isHitTestVisible = false
                lights.children.append(path)
                made.append(path)
            }
            tracePaths[id] = made
        }
        // The copies as they were, until the light reaches each, fading into how they are now.
        for (id, g) in shownGhosts {
            let t = now - (ghostAt[id] ?? now)
            if t > 0.2 {
                remove(g.image, from: ghosts)
                shownGhosts[id] = nil
                ghostAt[id] = nil
                continue
            }
            g.image.opacity = t < 0 ? 1 : 1 - Self.smooth(t / 0.2)
        }
    }

    private func remove(_ s: LitShape) {
        remove(s.group)
        remove(s.ring)
    }

    private func remove(_ e: UIElement, from panel: Canvas? = nil) {
        let from = panel ?? lights
        var at: UInt32 = 0
        if from.children.indexOf(e, &at) { from.children.removeAt(at) }
    }

    // MARK: The row of variants

    private enum Part: Equatable { case card(Int), add }
    private var hovered: Part?
    /// How far each card has come up off the row, by its place in it, and how far the round button has swelled.
    private var lift: [DeckSpring] = []
    private var addSwell = DeckSpring(0)
    private var rowSettled: Bool { lift.allSatisfy(\.settled) && addSwell.settled }

    /// Where the row lies: its cards, its round button, whether it is beside the copy rather than under it.
    struct RowLayout {
        var look: WindowsCore.VariantRow
        var cards: [CGRect]
        var add: CGRect
        var beside: Bool
    }

    /// The row for what is picked, where it goes: beside the copy where it covers nothing of what
    /// lies under it, else under it (the Mac's row()).
    func layout() -> RowLayout? {
        let s = state()
        guard s.free, let look = WindowsCore.variantRow(s.selection), let canvasBox = WindowsCore.copyBox(look.copy) else { return nil }
        let a = onStage(canvasBox.origin), z = view().zoom
        let r = CGRect(x: Double(a.x), y: Double(a.y), width: Double(canvasBox.width) * z, height: Double(canvasBox.height) * z)
        let h = 30.0, gap = 6.0, add = 18.0
        let total = look.widths.reduce(0, +) + gap * Double(look.widths.count - 1) + 10 + add
        let beside = Double(r.maxX) + 16 + total <= Double(view().size.width) - 8
        var x = beside ? (Double(r.maxX) + 16).rounded() : (Double(r.midX) - total / 2).rounded()
        let y = beside ? (Double(r.midY) - h / 2).rounded() : (Double(r.maxY) + 14).rounded()
        var cards: [CGRect] = []
        for w in look.widths {
            cards.append(CGRect(x: x, y: y, width: w, height: h))
            x += w + gap
        }
        return RowLayout(look: look, cards: cards, add: CGRect(x: x + 4, y: y + (h - add) / 2, width: add, height: add), beside: beside)
    }

    private func part(at p: CGPoint) -> Part? {
        guard let l = layout() else { return nil }
        if l.add.insetBy(dx: -4, dy: -6).contains(p) { return .add }
        if let i = l.cards.firstIndex(where: { $0.insetBy(dx: -2, dy: -3).contains(p) }) { return .card(i) }
        return nil
    }

    /// Whether the pointer is on the row, which the canvas then leaves alone.
    func covers(_ p: CGPoint) -> Bool { part(at: p) != nil }

    /// The copy turned into the variant the pointer is on, on the canvas, before it is chosen.
    private var previewing: UUID?

    func hover(_ p: CGPoint?) {
        let next = p.flatMap(part(at:))
        guard next != hovered else { return }
        hovered = next
        if case .card(let i)? = next, let l = layout(), i != l.look.current {
            previewing = l.look.copy
            preview(l.look.copy, l.look.variants[i], true)
        } else if let copy = previewing {
            previewing = nil
            preview(copy, nil, false)
        }
        drawRow()
        ticker.start()
    }

    /// A press on the row: a card makes the copy that variant, the round button a new variant of
    /// it as it looks. False leaves the press to the canvas.
    func down(at p: CGPoint) -> Bool {
        guard let part = part(at: p), let l = layout() else { return false }
        if let copy = previewing {
            previewing = nil
            preview(copy, nil, false)
        }
        hovered = nil
        switch part {
        case .card(let i): choose(l.look.copy, l.look.variants[i])
        case .add: addVariant(l.look.copy)
        }
        pictures = nil
        drawRow()
        return true
    }

    /// Each variant drawn as the copy picked would look as it, made once per change.
    private var pictures: (version: Int, copy: UUID, variants: [Int?], images: [WriteableBitmap?])?
    private var cardViews: [(shade: Image, lifted: Image, card: Border, picture: Image)] = []
    private let namePill = Border()
    private let nameText = Theme.text("", size: 10.5, weight: 500)
    private let nameShade = Image()
    private let addRing = Ellipse()
    private var shades: [String: WriteableBitmap] = [:]

    /// A soft shadow under a box `w` by `h`, `blur` soft, fallen `dy`, as deep as `alpha`: the
    /// bitmap and how far it reaches past the box each way, in points.
    private func shade(_ w: Double, _ h: Double, blur: Double, alpha: Double) -> (WriteableBitmap?, Double) {
        let scale = view().scale
        let pad = Int((blur * 2 * scale).rounded()) + 2
        let key = "\(Int(w * scale))x\(Int(h * scale))b\(blur)a\(alpha)"
        if let made = shades[key] { return (made, Double(pad) / scale) }
        var bitmap: WriteableBitmap?
        _ = WindowsCore.softShadow(width: Int((w * scale).rounded()), height: Int((h * scale).rounded()), pad: pad, blur: blur * scale, dy: 0,
                                   colour: 0x000000, alpha: alpha) { bw, bh in
            bitmap = WriteableBitmap(Int32(bw), Int32(bh))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        try? bitmap?.invalidate()
        if let bitmap { shades[key] = bitmap }
        return (bitmap, Double(pad) / scale)
    }

    private func place(_ image: Image, _ bitmap: (WriteableBitmap?, Double), over r: CGRect, dy: Double) {
        image.source = bitmap.0
        image.width = Double(r.width) + 2 * bitmap.1
        image.height = Double(r.height) + 2 * bitmap.1
        try? Canvas.setLeft(image, Double(r.minX) - bitmap.1)
        try? Canvas.setTop(image, Double(r.minY) - bitmap.1 + dy)
    }

    private func drawRow() {
        guard let l = layout() else {
            row.visibility = .collapsed
            if let copy = previewing {
                previewing = nil
                preview(copy, nil, false)
            }
            hovered = nil
            return
        }
        row.visibility = .visible
        let look = l.look
        // Made again for another copy, another set of variants, or once the design changed (but not
        // while a change pointed at is only shown).
        if pictures == nil || pictures!.copy != look.copy || pictures!.variants != look.variants
            || pictures!.version != look.version {
            let scale = view().scale
            let images = l.cards.enumerated().map { i, card -> WriteableBitmap? in
                var bitmap: WriteableBitmap?
                let size = CGSize(width: Double(card.width) - 2, height: Double(card.height) - 2)
                _ = WindowsCore.variantPicture(of: look.copy, look.variants[i], size: size, scale: scale, asItIs: true) { w, h in
                    bitmap = WriteableBitmap(Int32(w), Int32(h))
                    return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
                }
                try? bitmap?.invalidate()
                return bitmap
            }
            pictures = (look.version, look.copy, look.variants, images)
        }
        nameText.foreground = Theme.brush(Self.ink)
        while cardViews.count < look.variants.count {
            let v = (shade: Image(), lifted: Image(), card: Border(), picture: Image())
            v.card.cornerRadius = Theme.corners(5)
            v.picture.stretch = .uniform
            v.picture.horizontalAlignment = .center
            v.picture.verticalAlignment = .center
            v.card.child = v.picture
            for e: UIElement in [v.shade, v.lifted, v.card] { e.isHitTestVisible = false }
            cardViews.append(v)
        }
        while lift.count < look.variants.count { lift.append(DeckSpring(0)) }
        row.children.clear()
        for (i, card) in l.cards.enumerated() {
            lift[i].target = hovered == .card(i) ? 1 : 0
            let up = lift[i].value
            let r = card.offsetBy(dx: 0, dy: -2.5 * up)
            let v = cardViews[i]
            // Its shadow, 1 down and 4 soft at rest, 4 down and 10 soft lifted.
            place(v.shade, shade(Double(card.width), Double(card.height), blur: 4, alpha: 0.14), over: r, dy: 1)
            place(v.lifted, shade(Double(card.width), Double(card.height), blur: 10, alpha: 0.22), over: r, dy: 4)
            v.shade.opacity = 1 - up
            v.lifted.opacity = up
            v.card.background = Theme.brush(Self.surface)
            if i == look.current {
                v.card.borderBrush = Theme.brush(Self.ink)
                v.card.borderThickness = Theme.inset(2)
            } else {
                v.card.borderBrush = Theme.brush(Self.edge.0, Self.edge.1)
                v.card.borderThickness = Theme.inset(0.5)
            }
            v.card.width = Double(r.width)
            v.card.height = Double(r.height)
            try? Canvas.setLeft(v.card, Double(r.minX))
            try? Canvas.setTop(v.card, Double(r.minY))
            v.picture.source = i < (pictures?.images.count ?? 0) ? pictures?.images[i] : nil
            v.picture.width = Double(r.width) - 2
            v.picture.height = Double(r.height) - 2
            row.children.append(v.shade)
            row.children.append(v.lifted)
            row.children.append(v.card)
        }
        // The name of the one the pointer is on, under it; the one shown is named over the copy.
        if case .card(let named)? = hovered, named < look.names.count {
            nameText.text = Words.match(look.names[named])
            try? namePill.measure(Size(width: 400, height: 40))
            let w = Double(namePill.desiredSize.width), h = Double(namePill.desiredSize.height)
            let c = l.cards[named]
            let pill = CGRect(x: (Double(c.midX) - w / 2).rounded(), y: Double(c.maxY) + 3, width: w, height: h)
            namePill.cornerRadius = Theme.corners(h / 2)
            namePill.background = Theme.brush(Self.surface)
            place(nameShade, shade(w, h, blur: 4, alpha: 0.12), over: pill, dy: 1)
            try? Canvas.setLeft(namePill, Double(pill.minX))
            try? Canvas.setTop(namePill, Double(pill.minY))
            row.children.append(nameShade)
            row.children.append(namePill)
        }
        // The round button that makes a new variant: filled once it has swelled half way.
        addSwell.target = hovered == .add ? 1 : 0
        let k = addSwell.value
        let a = l.add.insetBy(dx: -1.5 * k, dy: -1.5 * k)
        addRing.width = Double(a.width)
        addRing.height = Double(a.height)
        try? Canvas.setLeft(addRing, Double(a.minX))
        try? Canvas.setTop(addRing, Double(a.minY))
        if k > 0.5 {
            addRing.fill = Theme.brush(Self.ink)
            addRing.stroke = nil
        } else {
            addRing.fill = Theme.brush(Self.surface)
            addRing.stroke = Theme.brush(Self.ink, 0.6)
            addRing.strokeThickness = 1
            place(addShade, shade(Double(a.width), Double(a.height), blur: 3, alpha: 0.16), over: a, dy: 1)
            row.children.append(addShade)
        }
        row.children.append(addRing)
        let m = CGPoint(x: Double(a.midX), y: Double(a.midY)), arm = Double(a.width) * 0.22
        var plus = PathData()
        plus.move(Double(m.x) - arm, Double(m.y))
        plus.line(Double(m.x) + arm, Double(m.y))
        plus.move(Double(m.x), Double(m.y) - arm)
        plus.line(Double(m.x), Double(m.y) + arm)
        if let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(plus.d)' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>")) as? WinUI.Path {
            path.stroke = k > 0.5 ? Theme.brush(0xFFFFFF) : Theme.brush(Self.ink)
            path.isHitTestVisible = false
            row.children.append(path)
        }
    }

    private let addShade = Image()

    // MARK: Drawing

    /// Everything, as it is now: called after each change the canvas draws, and each frame while
    /// anything moves.
    func draw() {
        drawLight(clock)
        drawRow()
    }

    /// One frame of the row's springs (the Mac's 420, 26 for the cards and 420, 22 for the button).
    private func stepRow(_ dt: Double) {
        for k in lift.indices { lift[k].step(dt, stiffness: 420, damping: 26) }
        addSwell.step(dt, stiffness: 420, damping: 22)
    }
}
