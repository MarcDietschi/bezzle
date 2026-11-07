import AppKit

/// Guides on the Mac's canvas: the shared `GuideDragging` (Model/GuideDragging.swift, which says
/// what they do), handed the canvas's events; here they are felt, and drawn as threads stretched
/// across a sheet that unroll as they come, quiver when they catch on something or are let go,
/// and while one is dragged its distances to either edge, as a draftsman dimensions a drawing.
final class GuideTool {
    private let store: DocumentStore
    private let rulers: Rulers
    let guides: GuideDragging
    var redraw: () -> Void {
        get { guides.redraw }
        set { guides.redraw = newValue }
    }
    /// A press on a guide that did not become a drag, which the canvas takes as a click.
    var click: (CGPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// Opens a menu at a point on screen.
    var menu: (CGPoint, [MenuEntry]) -> Void = { _, _ in }
    /// Where the layer a press at a point on screen would take lies on the canvas, if one does.
    var under: (CGPoint) -> CGRect? {
        get { guides.under }
        set { guides.under = newValue }
    }

    typealias Ref = GuideDragging.Ref

    /// The guide a layer lies over where the pointer rests, kept while its glow fades.
    private var beckoned: Ref?
    private var beckon = DeckTool.Spring(0)
    private var grow = DeckTool.Spring(1)
    private var last: CFTimeInterval?
    private var deviceScale: CGFloat = 2

    /// How long a guide takes to unroll across its artboard, and how long a pluck rings.
    private static let unroll = GuideDragging.unroll
    private static let ring = 1.05

    /// The store and the rulers as the shared guides see them.
    private final class Host: GuideHost {
        let store: DocumentStore
        let rulers: Rulers
        init(store: DocumentStore, rulers: Rulers) {
            self.store = store
            self.rulers = rulers
        }
        var doc: BezzleDocument { store.doc }
        var zoom: CGFloat { store.viewport.zoom }
        func toView(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }
        func toCanvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }
        var visibleCanvasRect: CGRect { store.visibleCanvasRect }
        var selectsGuides: Bool { store.tool == .select }
        var isReadOnly: Bool { store.isReadOnly }
        func seenLayers(of board: Node) -> [Node] { store.seenLayers(of: board) }
        func beginGesture() { store.beginGesture() }
        func endGesture(_ action: LocalizedStringResource) { store.endGesture(action) }
        func cancelGesture() { store.cancelGesture() }
        func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) { store.edit(action, change) }
        var guidesShown: Bool {
            get { Helpers.shared.guides }
            set { Helpers.shared.guides = newValue }
        }
        var gridsShown: Bool { Helpers.shared.grids }
        var rulersShown: Bool { Helpers.shared.rulers }
        var guidesLocked: Bool { Helpers.shared.guidesLocked }
        func rulerPart(at v: CGPoint) -> RulerPart? {
            switch rulers.part(at: v) {
            case .top?: .top
            case .left?: .left
            case .corner?: .corner
            case nil: nil
            }
        }
        var rulerBoard: Node? { rulers.board }
        var rulerThickness: CGFloat { rulers.thickness }
    }

    init(store: DocumentStore, rulers: Rulers) {
        self.store = store
        self.rulers = rulers
        guides = GuideDragging(host: Host(store: store, rulers: rulers))
        guides.now = { CACurrentMediaTime() }
        guides.feel = { kind in
            let pattern: NSHapticFeedbackManager.FeedbackPattern = switch kind {
            case .generic: .generic
            case .alignment: .alignment
            case .levelChange: .levelChange
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        guides.began = { [weak self] fresh in
            guard let self else { return }
            self.grow = DeckTool.Spring(fresh ? 0 : 1)
            if fresh { self.grow.target = 1 }
        }
        guides.click = { [weak self] v, f in
            var flags: NSEvent.ModifierFlags = []
            if f.contains(.shift) { flags.insert(.shift) }
            if f.contains(.option) { flags.insert(.option) }
            if f.contains(.command) { flags.insert(.command) }
            self?.click(v, flags)
        }
        guides.cornerMenu = { [weak self] v in
            guard let self else { return }
            self.menu(v, Helpers.shared.entries(for: self.store))
        }
    }

    var dragging: Bool { guides.dragging }
    var pressed: Bool { guides.pressed }

    var isAnimating: Bool {
        let now = CACurrentMediaTime()
        return grow.isMoving || beckon.isMoving || !guides.vanishing.isEmpty || guides.appearing.values.contains { now - $0 < Self.unroll }
            || guides.plucks.values.contains { now - $0 < Self.ring } || guides.heldPluck.map { now - $0 < Self.ring } ?? false
    }

    private var zoom: CGFloat { store.viewport.zoom }
    private var shown: Bool { Helpers.shared.guides }

    func guide(at v: CGPoint) -> Ref? { guides.guide(at: v) }

    // MARK: - The pointer

    func rulerDown(at v: CGPoint, event: NSEvent) -> Bool {
        guides.rulerDown(at: v, clicks: event.clickCount, flags: PathTool.flags(event.modifierFlags))
    }

    func down(at v: CGPoint, event: NSEvent) -> Bool { guides.down(at: v, flags: PathTool.flags(event.modifierFlags)) }
    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) { guides.drag(to: v, flags: PathTool.flags(flags)) }
    func up(at v: CGPoint, flags: NSEvent.ModifierFlags) { guides.up(at: v, flags: PathTool.flags(flags)) }
    func cancel() { guides.cancel() }

    func hover(_ v: CGPoint?) {
        guides.hover(v)
        if let through = guides.beckoning { beckoned = through }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if let vertical = guides.movingVertical, guides.dragging { return vertical ? .resizeLeftRight : .resizeUpDown }
        if let vertical = guides.newVertical { return guides.held.first?.leaving == true ? .disappearingItem : vertical ? .resizeLeftRight : .resizeUpDown }
        if guides.crossing { return .crosshair }
        if let part = rulers.part(at: v) {
            if part == .corner { return .pointingHand }
            if let vertical = guides.tabVertical(at: v) { return vertical ? .resizeLeftRight : .resizeUpDown }
            return .arrow
        }
        guard !guides.pressed, store.tool == .select, let vertical = guides.hoveredVertical else { return nil }
        return vertical ? .resizeLeftRight : .resizeUpDown
    }

    /// What a right click on a guide offers, if it is on one.
    func menuEntries(at v: CGPoint) -> [MenuEntry]? {
        guard let (ref, count) = guides.guideForMenu(at: v) else { return nil }
        return [
            .item("Remove Guide", enabled: !store.isReadOnly) { self.guides.removeGuide(ref) },
            .item("Remove Guides", enabled: count > 1 && !store.isReadOnly) { self.guides.removeGuides(from: ref.board) },
            .separator,
            .item("Lock Guides", checked: Helpers.shared.guidesLocked) { Helpers.shared.guidesLocked.toggle() },
        ]
    }

    // MARK: - On the rulers

    /// The tabs of the guides of the artboard the rulers measure, and of a guide being dragged.
    func tabs() -> [Rulers.Tab] {
        guides.tabs().map { t in
            let glow = t.ref != nil && t.ref == beckoned ? CGFloat(min(max(beckon.value, 0), 1)) : 0
            return Rulers.Tab(at: t.at, vertical: t.vertical, lit: t.lit || glow > 0.5, glow: glow)
        }
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let now = CACurrentMediaTime()
        let dt = min(now - (last ?? now), 1.0 / 30)
        last = now
        grow.step(dt, stiffness: 260, damping: 26)
        beckon.target = guides.beckoning == nil ? 0 : 1
        beckon.step(dt, stiffness: 320, damping: 26)
        if guides.beckoning == nil, beckon.value < 0.01, !beckon.isMoving { beckoned = nil }
        guides.settle(unrollFor: Self.unroll, ringFor: Self.ring, fadeFor: 0.24)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        if shown {
            let moving = guides.moving
            for board in guides.boards() {
                for (key, g) in board.guides ?? [:] {
                    let ref = Ref(board: board.id, key: key)
                    if ref == moving, guides.held.first?.leaving == true { continue }
                    let lit = ref == guides.hovered || ref == moving
                    // Pointed at through a layer: brighter, as its tab lights up, but not lifted.
                    let glow = ref == beckoned ? CGFloat(min(max(beckon.value, 0), 1)) : 0
                    let (a, b) = guides.line(of: g, on: board)
                    var reach: CGFloat = 1
                    if let born = guides.appearing[ref] { reach = Self.unrolled(min((now - born) / Self.unroll, 1)) }
                    let pluck = ref == moving ? guides.heldPluck : guides.plucks[ref]
                    drawThread(ctx, from: a, to: b, alpha: lit ? 1 : 0.62 + 0.26 * glow, width: lit ? 1.25 : 1, reach: reach, from0: true,
                               pluck: pluck.map { now - $0 }, strength: ref == moving ? Self.caughtStrength : 1, vertical: g.vertical)
                }
            }
        }
        for v in guides.vanishing {
            let k = CGFloat((now - v.born) / 0.24)
            let mid = CGPoint(x: (v.from.x + v.to.x) / 2, y: (v.from.y + v.to.y) / 2)
            let a = CGPoint(x: v.from.x + (mid.x - v.from.x) * k, y: v.from.y + (mid.y - v.from.y) * k)
            let b = CGPoint(x: v.to.x + (mid.x - v.to.x) * k, y: v.to.y + (mid.y - v.to.y) * k)
            drawThread(ctx, from: a, to: b, alpha: 0.7 * (1 - k), width: 1, reach: 1, from0: true, pluck: nil, vertical: v.from.x == v.to.x)
        }
        for h in guides.held { drawHeld(h, ctx, now: now) }
    }

    /// How far a guide has unrolled: quickly at first, slowing to a stop at the far edge, never past it.
    private static func unrolled(_ t: Double) -> CGFloat {
        CGFloat(1 - pow(1 - min(max(t, 0), 1), 3))
    }

    /// How hard a guide quivers when it catches on something while still being dragged, against
    /// coming to rest: enough to feel the catch, not so much it shakes under the pointer.
    private static let caughtStrength: CGFloat = 0.45

    /// A guide's line from edge to edge. `reach` unrolls it from its start; a pluck makes it quiver
    /// as a string fixed at the edges does, most in its middle, dying away.
    private func drawThread(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, alpha: CGFloat, width: CGFloat, reach: CGFloat,
                            from0: Bool, pluck: Double?, strength: CGFloat = 1, vertical: Bool, dashed: Bool = false) {
        let vp = store.viewport
        let va = vp.toView(a), vb0 = vp.toView(b)
        let vb = CGPoint(x: va.x + (vb0.x - va.x) * reach, y: va.y + (vb0.y - va.y) * reach)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(width)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        let s = deviceScale
        func crisp(_ x: CGFloat) -> CGFloat { (x * s).rounded() / s + 0.5 / s }
        if let t = pluck, t >= 0, t < Self.ring {
            // A string fixed at both ends: ringing mostly at its first mode, swinging the middle
            // furthest, with a little of its second, which dies sooner, so it moves as a string
            // does rather than as a seesaw. A long one swings further than a short one.
            let reachOnScreen = hypot(vb0.x - va.x, vb0.y - va.y)
            let swing = Double(strength * min(max(reachOnScreen * 0.009, 4), 9.5))
            let first = swing * exp(-t / 0.24) * sin(2 * .pi * 8 * t)
            let second = swing * 0.28 * exp(-t / 0.12) * sin(2 * .pi * 17 * t + 0.6)
            let n = 48
            for i in 0...n {
                let u = CGFloat(i) / CGFloat(n)
                let off = CGFloat(first) * sin(.pi * u) + CGFloat(second) * sin(2 * .pi * u)
                let p = CGPoint(x: va.x + (vb.x - va.x) * u + (vertical ? off : 0), y: va.y + (vb.y - va.y) * u + (vertical ? 0 : off))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
        } else if vertical {
            ctx.move(to: CGPoint(x: crisp(va.x), y: va.y))
            ctx.addLine(to: CGPoint(x: crisp(vb.x), y: vb.y))
        } else {
            ctx.move(to: CGPoint(x: va.x, y: crisp(va.y)))
            ctx.addLine(to: CGPoint(x: vb.x, y: crisp(vb.y)))
        }
        ctx.strokePath()
    }

    /// A guide being dragged: on its artboard, with its distances to either edge as a draftsman
    /// dimensions a drawing, or, leaving, dashed and fading, offering to go.
    private func drawHeld(_ h: GuideDragging.Held, _ ctx: CGContext, now: CFTimeInterval) {
        let vp = store.viewport
        guard let id = h.board, let board = store.node(id) else {
            // Over no artboard at all: just a line under the pointer, dashed.
            let p = h.pointer, o = 40 / zoom
            let a = h.vertical ? CGPoint(x: h.position, y: p.y - o) : CGPoint(x: p.x - o, y: h.position)
            let b = h.vertical ? CGPoint(x: h.position, y: p.y + o) : CGPoint(x: p.x + o, y: h.position)
            drawThread(ctx, from: a, to: b, alpha: 0.4, width: 1, reach: 1, from0: true, pluck: nil, vertical: h.vertical, dashed: true)
            return
        }
        let f = board.frame
        let g = Guideline(vertical: h.vertical, edge: .start, offset: h.position)
        var (a, b) = guides.line(of: g, on: board)
        if h.leaving {
            // Off the artboard, it follows the pointer out, dashed.
            if h.vertical { a.x = h.pointer.x; b.x = h.pointer.x } else { a.y = h.pointer.y; b.y = h.pointer.y }
            drawThread(ctx, from: a, to: b, alpha: 0.38, width: 1, reach: 1, from0: true, pluck: nil, vertical: h.vertical, dashed: true)
            drawPill(String(localized: "Release to remove"), at: vp.toView(h.pointer) + CGPoint(x: 14, y: 14), ctx: ctx, solid: true, warning: true)
            return
        }
        // Unrolled from where the pointer brought it in, to the edges and not past them.
        let k = CGFloat(min(max(grow.value, 0), 1))
        let p = h.pointer
        let ca = h.vertical ? CGPoint(x: a.x, y: p.y + (a.y - p.y) * k) : CGPoint(x: p.x + (a.x - p.x) * k, y: a.y)
        let cb = h.vertical ? CGPoint(x: b.x, y: p.y + (b.y - p.y) * k) : CGPoint(x: p.x + (b.x - p.x) * k, y: b.y)
        if guides.moving == nil {
            drawThread(ctx, from: ca, to: cb, alpha: 1, width: 1.25, reach: 1, from0: true, pluck: guides.heldPluck.map { now - $0 }, strength: Self.caughtStrength, vertical: h.vertical)
        }
        // Its distances to both edges: solid toward the edge it keeps to, outlined toward the other.
        let length = h.vertical ? f.width : f.height
        let kept = Guideline.at(h.position, vertical: h.vertical, in: f.size).edge
        let start = h.vertical ? f.minX : f.minY
        let spans: [(lo: CGFloat, hi: CGFloat, solid: Bool)] = [(start, start + h.position, kept != .end), (start + h.position, start + length, kept != .start)]
            .filter { $0.1 - $0.0 > 0.5 }
        let numbers = spans.map { CanvasView.number($0.hi - $0.lo) }
        // On screen, along the dimension line, and across it.
        func along(_ v: CGFloat) -> CGFloat { h.vertical ? vp.toView(CGPoint(x: v, y: 0)).x : vp.toView(CGPoint(x: 0, y: v)).y }
        let sheet = vp.toView(f), pv = vp.toView(p)
        // The line runs beside the pointer, never under it: below a guide running down, right of
        // one running across, clear of the cursor and of the numbers on it; on the other side
        // near the artboard's far end.
        let clear = h.vertical ? 28 : (numbers.map(Self.pillWidth).max() ?? 30) / 2 + 16
        let here = h.vertical ? pv.y : pv.x
        let near = (h.vertical ? sheet.minY : sheet.minX) + 12, far = (h.vertical ? sheet.maxY : sheet.maxX) - 12
        var line = here + clear > far ? here - clear : here + clear
        line = min(max(line, near), max(far, near))
        // Never under the rulers, which are drawn over the canvas.
        let rulers = Helpers.shared.rulers ? Rulers.thickness : 0
        line = max(line, rulers + (h.vertical ? Self.pillHeight : numbers.map(Self.pillWidth).max() ?? 30) / 2 + 3)
        for (span, number) in zip(spans, numbers) {
            let a = along(span.lo), b = along(span.hi)
            let va = h.vertical ? CGPoint(x: a, y: line) : CGPoint(x: line, y: a)
            let vb = h.vertical ? CGPoint(x: b, y: line) : CGPoint(x: line, y: b)
            drawDimension(from: va, to: vb, vertical: h.vertical, ctx: ctx)
            // Too short to hold its number, the number goes outside, past the artboard's edge, as
            // a draftsman writes a small dimension.
            let size = h.vertical ? Self.pillWidth(number) : Self.pillHeight
            var c = (a + b) / 2
            if b - a < size + 8 { c = span.lo == start ? a - size / 2 - 6 : b + size / 2 + 6 }
            c = max(c, rulers + size / 2 + 3)
            drawPill(number, at: h.vertical ? CGPoint(x: c, y: line) : CGPoint(x: line, y: c), ctx: ctx, solid: span.solid, warning: false, centered: true)
        }
    }

    /// A dimension line between two points on screen, with a short slash across each end.
    private func drawDimension(from a: CGPoint, to b: CGPoint, vertical: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: a)
        ctx.addLine(to: b)
        for e in [a, b] {
            ctx.move(to: CGPoint(x: e.x - 3, y: e.y + 3))
            ctx.addLine(to: CGPoint(x: e.x + 3, y: e.y - 3))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let pillHeight: CGFloat = 18

    /// How wide a pill with these words is on screen.
    private static func pillWidth(_ text: String) -> CGFloat {
        ((text as NSString).size(withAttributes: [.font: pillFont]).width + 12).rounded()
    }

    private func drawPill(_ text: String, at p: CGPoint, ctx: CGContext, solid: Bool, warning: Bool, centered: Bool = false) {
        let ink = warning ? Theme.dynamicNS(0xB3402F, 0xE4705C) : CanvasInk.pencil
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.pillFont, .foregroundColor: solid ? NSColor.white : ink]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = Self.pillWidth(text), h = Self.pillHeight
        let pill = centered ? CGRect(x: (p.x - w / 2).rounded(), y: (p.y - h / 2).rounded(), width: w, height: h)
                            : CGRect(x: p.x.rounded(), y: p.y.rounded(), width: w, height: h)
        ctx.saveGState()
        let shape = CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        if solid {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: ink.withAlphaComponent(0.35).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(ink.cgColor)
            ctx.fillPath()
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil))
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: pill.minX + (w - size.width) / 2, y: pill.minY + (h - size.height) / 2), withAttributes: attrs)
    }
}
