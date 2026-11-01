import AppKit

/// Masks on the canvas (see `Mask`): a shape holding layers, as a shape holds a picture.
///
/// - Something being dragged, held still over a shape for a moment, goes into it. As the moment
///   passes, a line runs round the shape's outline; once it closes, the shape opens with a tick
///   of the trackpad, glowing and breathing, and what is held is cut off at its outline at once,
///   what reaches past it fading to a ghost. Dragged on inside it, it moves inside it, so the part
///   that shows can be picked; let go, it is in. Dragged off the shape first, the shape closes
///   again, and does not open again in the same drag. Something lying wholly inside a shape,
///   where a mask would change nothing, never opens it.
/// - Several layers picked, one of them a shape the rest overlap, or a shape just drawn or moved
///   over a picture: a word offers to mask them. Pointed at, the canvas shows the mask made, what
///   it would cut off fading away; pressed, it is made, and what was cut off sinks in.
/// - Something inside a mask picked: what of it reaches past the shape shows as a ghost, to take
///   hold of. Dragged wholly off the shape, it comes out of the mask when let go.
final class MaskTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        self.store = store
    }

    private typealias Spring = DeckTool.Spring

    /// How long something has to rest over a shape for the shape to open.
    private static let rest: CFTimeInterval = 0.55
    /// How far the pointer may wander on screen and still be resting.
    private static let wander: CGFloat = 6
    /// How much of what reaches past a mask's shape shows while it is open, faded.
    private static let ghostLevel = 0.3
    /// How much shows of something dragged wholly off its mask, on its way out.
    private static let leavingLevel = 0.85
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    // MARK: - Time

    private var lastFrame: CFTimeInterval = 0
    private var dt: Double = 1.0 / 120
    private var began = CACurrentMediaTime()

    /// Whether the canvas should be drawn again next frame, for something on its way.
    var animating: Bool {
        if dip?.opened != nil || dip?.leaving != nil || previewing != nil { return true }
        if let d = dip, d.over != nil, d.ready { return true }
        return ghost?.alpha.isMoving == true || !fading.isEmpty || glow.isMoving || offerShown.isMoving || !rings.isEmpty
    }

    private func tick() {
        let now = CACurrentMediaTime()
        dt = lastFrame == 0 ? 1.0 / 120 : min(max(now - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = now
    }

    // MARK: - Holding something over a shape

    private struct Dip {
        var moving: [UUID]
        /// The shape the pointer rests on, or the mask, and since when and where.
        var over: UUID?
        var since: CFTimeInterval = 0
        var at: CGPoint = .zero
        /// Whether resting there would open it: it holds things, and would cut something off.
        var ready = false
        var opened: Opened?
        /// Shapes that opened and were left again in this drag.
        var declined: Set<UUID> = []
        /// The mask what is moved would come out of, lying wholly off its shape.
        var leaving: UUID?
    }

    private struct Opened {
        let shape: UUID
        let mask: UUID
        /// The design as it was the moment before, to go back to if it is left.
        let before: BezzleDocument
    }

    private var dip: Dip?
    private var waiting: Timer?

    /// Something being moved has been dragged to `v` on screen. Returns whether a shape opened
    /// or closed under it just now, so that what is moved has to be placed again as it now lies.
    func moving(_ ids: [UUID], at v: CGPoint) -> Bool {
        tick()
        if dip?.moving != ids { dip = Dip(moving: ids) }
        guard var d = dip else { return false }
        let p = store.viewport.toCanvas(v)
        if let opened = d.opened {
            // Inside it still, what it holds moves inside it.
            if let outline = Mask.outline(of: opened.mask, in: store.doc),
               outline.copy(strokingWithWidth: 24 / store.viewport.zoom, lineCap: .round, lineJoin: .round, miterLimit: 4).contains(p) || outline.contains(p) {
                dip = d
                return false
            }
            // Off it: it closes, and what it took in is as it was, wherever it is now.
            d.opened = nil
            d.declined.insert(opened.shape)
            d.over = nil
            dip = d
            ghost = nil
            glow.target = 0
            ring(opened.mask, in: store.doc, out: true)
            store.edit("Move") { $0 = opened.before }
            redraw()
            return true
        }
        let over = target(at: p, moving: ids)
        if over != d.over || hypot(v.x - d.at.x, v.y - d.at.y) > Self.wander {
            d.over = over
            d.since = CACurrentMediaTime()
            d.at = v
            d.ready = over.map { !d.declined.contains($0) && plan(ids, over: $0) != nil } == true
            waiting?.invalidate()
            waiting = nil
            if d.ready {
                let timer = Timer(timeInterval: Self.rest, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.open() }
                }
                RunLoop.main.add(timer, forMode: .common)
                waiting = timer
            }
        }
        d.leaving = leaving(ids)
        dip = d
        redraw()
        return false
    }

    /// Masking `ids` in the shape `over`, when that would cut something of them off that shows.
    private func plan(_ ids: [UUID], over: UUID) -> MaskPlan? {
        let doc = store.doc
        guard let plan = DocumentStore.dipPlan(ids, over: over, in: doc), let shape = canvasBounds(of: over, in: doc) else { return nil }
        var reach = CGRect.null
        for id in plan.held { if let r = canvasBounds(of: id, in: doc) { reach = reach.union(r) } }
        // What an artboard cuts off anyway is no reason to.
        if let board = doc.artboard(of: over), board.clips { reach = reach.intersection(board.frame) }
        guard !reach.isNull, reach.intersects(shape), !shape.insetBy(dx: -0.5, dy: -0.5).contains(reach) else { return nil }
        return plan
    }

    /// The shape resting has opened: what is held goes into it, as one step with the drag.
    private func open() {
        waiting = nil
        guard var d = dip, d.opened == nil, let over = d.over, d.ready, store.inGesture,
              let plan = plan(d.moving, over: over) else { return }
        let before = store.doc
        var made: UUID?
        store.edit(DocumentStore.masking) { doc in made = DocumentStore.mask(plan, in: &doc) }
        guard let made, store.doc.node(made) != nil else { return }
        d.opened = Opened(shape: over, mask: made, before: before)
        dip = d
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // What reaches past the shape was showing whole a moment ago: it fades from there.
        ghost = Ghost(ids: plan.held, alpha: Spring(1))
        glow = Spring(0)
        glow.target = 1
        redraw()
    }

    /// The drag has been let go. Returns what it did, for the Edit menu, when it went into a mask
    /// or came out of one; nil when it only moved.
    func released() -> LocalizedStringResource? {
        guard let d = dip else { return nil }
        reset()
        if let opened = d.opened, store.doc.node(opened.mask) != nil {
            store.selection = [opened.mask]
            ring(opened.mask, in: store.doc, out: false)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return DocumentStore.masking
        }
        if let mask = d.leaving {
            let outline = store.doc.node(mask).flatMap { _ in Mask.outline(of: mask, in: store.doc) }
            store.edit(DocumentStore.takingOut) { doc in DocumentStore.takeOut(d.moving, in: &doc) }
            if let outline { rings.append(Ring(path: outline, born: CACurrentMediaTime(), out: true)) }
            ghost = nil
            return DocumentStore.takingOut
        }
        return nil
    }

    /// The drag was called off, and the design put back as it was.
    func cancel() {
        guard dip != nil else { return }
        reset()
        ghost = nil
        redraw()
    }

    private func reset() {
        waiting?.invalidate()
        waiting = nil
        dip = nil
        glow.target = 0
    }

    /// The shape, or the mask, a layer dragged to `p` on the canvas is held over: whatever is under
    /// the pointer there, leaving out what is being dragged, down into groups as far as the shape
    /// itself. Something else on top, such as a text, is what is under the pointer, and no shape is.
    private func target(at p: CGPoint, moving: [UUID]) -> UUID? {
        let skip = Set(moving)
        func find(_ nodes: [Node], _ q: CGPoint) -> (found: UUID?, stop: Bool) {
            for n in nodes.reversed() where !n.hidden && !n.locked && !skip.contains(n.id) {
                let inner = CGPoint(x: q.x - n.frame.minX, y: q.y - n.frame.minY)
                if let holder = n.holder {
                    guard Mask.inside(holder, inner, tolerance: 0) else { continue }
                    return (n.id, true)
                }
                if n.isGroup {
                    let r = find(n.children, inner)
                    if r.stop { return r }
                    continue
                }
                guard Geometry.contains(n, q, tolerance: 0) else { continue }
                return (Mask.canHold(n) ? n.id : nil, true)
            }
            return (nil, false)
        }
        for top in store.doc.nodes.reversed() where !top.hidden {
            if top.isArtboard {
                guard top.frame.contains(p) else { continue }
                return find(store.seenLayers(of: top), CGPoint(x: p.x - top.frame.minX, y: p.y - top.frame.minY)).found
            }
            let r = find([top], p)
            if r.stop { return r.found }
        }
        return nil
    }

    /// The mask the layers being moved lie in, when they have been dragged wholly off its shape.
    private func leaving(_ ids: [UUID]) -> UUID? {
        let doc = store.doc
        guard let first = ids.first, let mask = doc.parent(of: first), let holder = mask.holder,
              ids.allSatisfy({ doc.parent(of: $0)?.id == mask.id && $0 != holder.id }),
              let outline = Mask.outline(of: mask.id, in: doc) else { return nil }
        let off = ids.allSatisfy { id in
            guard let r = canvasBounds(of: id, in: doc) else { return true }
            return !outline.intersects(CGPath(rect: r, transform: nil))
        }
        return off ? mask.id : nil
    }

    private func canvasBounds(of id: UUID, in doc: BezzleDocument) -> CGRect? {
        guard let n = doc.node(id) else { return nil }
        let o = doc.parentOrigin(of: id)
        return Geometry.bounds(of: n).offsetBy(dx: o.x, dy: o.y)
    }

    // MARK: - The word offered

    /// A shape just drawn or moved over a picture, and the design as it was then: the word
    /// offering to mask the picture in it shows until anything else changes.
    private var invited: (plan: MaskPlan, version: Int)?
    private var offerShown = Spring(0)
    private var offerKey: MaskPlan?
    private var offerHovered = false

    /// After a shape has been drawn, moved or resized: offers to mask the picture under it, when it
    /// lies mostly over one that reaches past it, as a shape drawn over a photo to frame it does.
    func invite() {
        invited = nil
        guard store.selection.count == 1, let id = store.selection.first, let shape = store.node(id), Mask.canHold(shape),
              shape.fill.image == nil, !shape.locked, let path = store.doc.path(of: id), let frame = canvasBounds(of: id, in: store.doc) else { return }
        let siblings = path.parent.map { store.doc[$0].children } ?? store.doc.nodes
        let i = path.indices.last!
        for other in siblings[..<i].reversed() where !other.hidden && !other.locked && other.post == shape.post {
            guard other.fill.on, other.fill.image != nil, Mask.canHold(other), let r = canvasBounds(of: other.id, in: store.doc) else { continue }
            let both = r.intersection(frame)
            guard !both.isNull, both.width * both.height >= frame.width * frame.height * 0.5 else { continue }
            if frame.insetBy(dx: -0.5, dy: -0.5).contains(r) { return }
            invited = (MaskPlan(shape: id, held: [other.id]), store.version)
            redraw()
            return
        }
    }

    /// What the word offers to mask, if it shows now.
    private var offer: MaskPlan? {
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.editingPicture == nil,
              store.building == nil, dip == nil, !store.inGesture, !store.isReadOnly else { return nil }
        if let invited, invited.version == store.version, store.selection == [invited.plan.shape] { return invited.plan }
        guard store.selection.count > 1, store.selection.count <= 12, let plan = store.maskPlan else { return nil }
        // Only where all of them overlap the shape, so picking things to move together does not ask.
        guard let reach = canvasBounds(of: plan.shape, in: store.doc),
              plan.held.allSatisfy({ canvasBounds(of: $0, in: store.doc)?.intersects(reach) == true }),
              store.node(plan.shape)?.isMask == true || plan.held.contains(where: { id in canvasBounds(of: id, in: store.doc).map { !reach.contains($0) } == true })
        else { return nil }
        return plan
    }

    private func offerRect(_ plan: MaskPlan, in bounds: CGRect) -> CGRect? {
        // Over all it is about, clear of the handles round them.
        guard var reach = canvasBounds(of: plan.shape, in: store.doc) else { return nil }
        for id in plan.held { if let r = canvasBounds(of: id, in: store.doc) { reach = reach.union(r) } }
        let r = store.viewport.toView(reach)
        let words = String(localized: DocumentStore.masking)
        let w = ceil((words as NSString).size(withAttributes: [.font: Self.font]).width)
        let size = CGSize(width: 10 + 13 + 6 + w + 13, height: 28)
        var origin = CGPoint(x: (r.midX - size.width / 2).rounded(), y: (r.minY - size.height - 12).rounded())
        if origin.y < bounds.minY + 8 { origin.y = (r.maxY + 12).rounded() }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        return CGRect(origin: origin, size: size)
    }

    private var lastBounds: CGRect = .zero

    /// A press on the word offered: makes the mask. False leaves it to the canvas.
    func offerDown(at v: CGPoint) -> Bool {
        guard let plan = offer, let r = offerRect(plan, in: lastBounds), r.insetBy(dx: -2, dy: -2).contains(v) else { return false }
        commit(plan)
        return true
    }

    /// The pointer over the canvas: the word offered shows what it would do while it is pointed at.
    func hover(_ v: CGPoint?) {
        let on = v.flatMap { v in offer.flatMap { offerRect($0, in: lastBounds) }.map { $0.insetBy(dx: -2, dy: -2).contains(v) } } ?? false
        guard on != offerHovered else { return }
        offerHovered = on
        if on, let plan = offer { preview(plan, true) } else if let plan = previewing { preview(plan, false) }
        redraw()
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        guard let plan = offer, let r = offerRect(plan, in: lastBounds), r.insetBy(dx: -2, dy: -2).contains(v) else { return nil }
        return .pointingHand
    }

    // MARK: - Showing a mask before it is made

    /// The mask the canvas shows made, from the word offered or a menu's entry pointed at.
    private var previewing: MaskPlan?
    /// Going back from showing it: what it cut off comes back before it is taken away.
    private var unwinding = false
    /// Come all the way back: the preview goes once this frame is drawn.
    private var unwound = false

    /// Shows the mask `plan` would make, or with false stops showing it.
    func preview(_ plan: MaskPlan, _ on: Bool) {
        if on {
            unwinding = false
            if previewing != plan {
                previewing = plan
                store.showPreview("mask", reshaping: { doc in DocumentStore.mask(plan, in: &doc) })
                ghost = Ghost(ids: plan.held, alpha: Spring(1))
            }
            ghost?.alpha.target = Self.ghostLevel
            glow.target = 1
        } else if previewing == plan {
            // What was cut off grows back whole, and only then is the preview taken away.
            unwinding = true
            ghost?.alpha.target = 1
            glow.target = 0
        }
        redraw()
    }

    /// Makes the mask the word offered, or a menu's entry, showed.
    func commit(_ plan: MaskPlan) {
        unwinding = false
        previewing = nil
        offerHovered = false
        invited = nil
        store.mask(plan)
        if let mask = store.selection.first, store.node(mask)?.isMask == true {
            ring(mask, in: store.doc, out: false)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        glow.target = 0
        redraw()
    }

    /// A mask being taken apart: a ripple runs out from its shape, as what it cut off comes back.
    func released(_ mask: UUID) {
        ring(mask, in: store.doc, out: true)
        redraw()
    }

    // MARK: - Ghosts

    /// What of some layers inside a mask reaches past its shape, faded. The mask is the one they
    /// lie in, in the design as drawn, so one shown made carries on into the one made.
    private struct Ghost {
        var ids: [UUID]
        var alpha: Spring
    }

    private var ghost: Ghost?
    private var fading: [Ghost] = []
    private var glow = Spring(0)

    /// The layers selected inside a mask, when that is all that is selected, and not its shape.
    private var picked: [UUID]? {
        let ids = store.selection
        guard let first = ids.first, store.editingText == nil, let mask = store.doc.parent(of: first), let holder = mask.holder,
              ids.allSatisfy({ store.doc.parent(of: $0)?.id == mask.id && $0 != holder.id }) else { return nil }
        return ids
    }

    /// The ghost that should show now, and how much of it.
    private func aimGhost() {
        // Taken away by something else, such as another pick: gone with it.
        if previewing != nil, store.preview?.key != "mask" {
            previewing = nil
            unwinding = false
            ghost = nil
        }
        var wanted: (ids: [UUID], level: Double)?
        if let plan = previewing {
            wanted = (plan.held, unwinding ? 1 : Self.ghostLevel)
        } else if let d = dip, d.opened != nil {
            wanted = (d.moving, Self.ghostLevel)
        } else if let ids = picked {
            wanted = (ids, dip?.leaving != nil ? Self.leavingLevel : Self.ghostLevel)
        }
        if let wanted, let g = ghost, Set(g.ids) == Set(wanted.ids) {
            ghost?.alpha.target = wanted.level
        } else {
            if var g = ghost {
                g.alpha.target = 0
                fading.append(g)
            }
            ghost = wanted.map { w in
                // What was hidden fades in.
                var s = Spring(0)
                s.target = w.level
                return Ghost(ids: w.ids, alpha: s)
            }
        }
        ghost?.alpha.step(dt, stiffness: 240, damping: 26)
        for i in fading.indices { fading[i].alpha.step(dt, stiffness: 240, damping: 26) }
        fading.removeAll { $0.alpha.settled }
        // Grown back whole: this frame still shows the preview, so the ghost is drawn with it once
        // more, and both go once it is drawn.
        if unwinding, let g = ghost, g.alpha.value > 0.97 { unwound = true }
    }

    private func drawGhost(_ g: Ghost, in doc: BezzleDocument, _ ctx: CGContext) {
        let alpha = min(max(g.alpha.value, 0), 1)
        guard alpha > 0.01, let first = g.ids.first, let mask = doc.parent(of: first), mask.isMask,
              let outline = Mask.outline(of: mask.id, in: doc) else { return }
        let o = doc.parentOrigin(of: first)
        let layers = mask.children.dropFirst().filter { g.ids.contains($0.id) && !$0.hidden }
        var reach = CGRect.null
        for n in layers { reach = reach.union(Renderer.reach(of: n).offsetBy(dx: o.x, dy: o.y)) }
        guard !reach.isNull else { return }
        let vp = store.viewport
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: vp.zoom, y: vp.zoom)
        ctx.translateBy(x: -vp.origin.x, y: -vp.origin.y)
        // Only what lies past the shape: inside it, the mask shows them itself.
        ctx.addRect(reach.insetBy(dx: -2, dy: -2))
        ctx.addPath(outline)
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(in: reach.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        ctx.translateBy(x: o.x, y: o.y)
        var options = Renderer.Options()
        options.assets = store.assets
        options.deviceScale = deviceScale
        options.picturesLater = true
        for n in layers { Renderer.drawNode(n, in: ctx, options: options) }
        ctx.endTransparencyLayer()
    }

    // MARK: - Rings

    /// An outline drawn once, running in as something sinks into a mask, or out as it lets go.
    private struct Ring {
        let path: CGPath
        let born: CFTimeInterval
        let out: Bool
    }

    private var rings: [Ring] = []
    private static let ringTime: CFTimeInterval = 0.5

    private func ring(_ mask: UUID, in doc: BezzleDocument, out: Bool) {
        guard let outline = Mask.outline(of: mask, in: doc) else { return }
        rings.append(Ring(path: outline, born: CACurrentMediaTime(), out: out))
    }

    private func drawRings(_ ctx: CGContext) {
        let now = CACurrentMediaTime()
        rings.removeAll { now - $0.born > Self.ringTime }
        for r in rings {
            let t = min((now - r.born) / Self.ringTime, 1)
            let eased = 1 - pow(1 - t, 3)
            var place = viewTransform
            let box = r.path.boundingBoxOfPath
            let c = CGPoint(x: box.midX, y: box.midY)
            // Out, it grows a little and goes; in, it draws in a little, as a breath taken.
            let s = r.out ? 1 + 0.08 * eased : 1 - 0.05 * eased
            let k = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
            place = k.concatenating(place)
            guard let path = r.path.copy(using: &place) else { continue }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.75 * (1 - eased)).cgColor)
            ctx.setLineWidth(r.out ? 2 : 4 - 2.5 * eased)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Keys

    /// Return on a selected mask picks what it holds, to move it inside it.
    func key(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76, store.tool == .select, store.editingPath == nil, store.selection.count == 1,
              let mask = store.node(store.selection[0]), mask.isMask, !mask.locked else { return false }
        let held = mask.children.dropFirst().filter { !$0.hidden && !$0.locked }.map(\.id)
        guard !held.isEmpty else { return false }
        store.selection = held
        return true
    }

    // MARK: - Drawing

    private var viewTransform: CGAffineTransform {
        let vp = store.viewport
        return CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y)
    }

    private func viewOutline(of mask: UUID, in doc: BezzleDocument) -> CGPath? {
        guard let outline = Mask.outline(of: mask, in: doc) else { return nil }
        var t = viewTransform
        return outline.copy(using: &t)
    }

    /// A shape's outline on screen, for one that is not a mask yet.
    private func viewOutline(ofShape id: UUID) -> CGPath? {
        guard let node = store.node(id) else { return nil }
        if node.isMask { return viewOutline(of: id, in: store.doc) }
        let o = store.doc.parentOrigin(of: id)
        var t = CGAffineTransform(translationX: o.x, y: o.y).concatenating(viewTransform)
        return Renderer.placedOutline(of: node).copy(using: &t)
    }

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        deviceScale = scale
        lastBounds = bounds
        tick()
        let doc = store.shownDoc
        aimGhost()
        for g in fading { drawGhost(g, in: doc, ctx) }
        if let g = ghost { drawGhost(g, in: doc, ctx) }

        // The mask shown made or open, glowing; one something is picked in, outlined.
        glow.step(dt, stiffness: 320, damping: 22)
        let breath = 0.5 + 0.5 * sin((CACurrentMediaTime() - began) * 2 * .pi / 1.6)
        let glowing: UUID? = {
            if let opened = dip?.opened { return opened.mask }
            if let plan = previewing, let first = plan.held.first { return doc.parent(of: first)?.id }
            return nil
        }()
        if let glowing, let outline = viewOutline(of: glowing, in: doc) {
            drawGlow(outline, strength: glow.value, breath: breath, ctx)
        } else if let ids = picked, let mask = store.doc.parent(of: ids[0]), let outline = viewOutline(of: mask.id, in: store.doc) {
            ctx.saveGState()
            ctx.addPath(outline)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(dip?.leaving != nil ? 0.45 : 1).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: dip?.leaving != nil ? [4, 3] : [])
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Resting over a shape: a line runs round it, and once it closes the shape opens.
        if let d = dip, d.opened == nil, d.ready, let over = d.over, let outline = viewOutline(ofShape: over) {
            let t = min((CACurrentMediaTime() - d.since) / Self.rest, 1)
            drawRest(outline, progress: t, ctx)
        }

        drawRings(ctx)

        if let d = dip, let opened = d.opened, let name = store.node(opened.shape)?.name ?? store.node(opened.mask)?.name,
           let outline = viewOutline(of: opened.mask, in: store.doc) {
            drawLabel(String(localized: "Into \(name)"), under: outline.boundingBoxOfPath, in: bounds, ctx)
        } else if let d = dip, let mask = d.leaving, let node = store.node(mask), let outline = viewOutline(of: mask, in: store.doc) {
            drawLabel(String(localized: "Out of \(node.holder?.name ?? node.name)"), under: outline.boundingBoxOfPath, in: bounds, ctx)
        }

        drawOffer(ctx, in: bounds)

        if unwound {
            unwound = false
            unwinding = false
            previewing = nil
            ghost = nil
            store.showPreview("mask", reshaping: nil)
        }
    }

    private func drawGlow(_ outline: CGPath, strength: Double, breath: Double, _ ctx: CGContext) {
        let k = CGFloat(min(max(strength, 0), 1.2))
        guard k > 0.01 else { return }
        let s = deviceScale
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: CGFloat(6 + 8 * breath) * s * k, color: CanvasInk.pencil.withAlphaComponent(0.95 * min(k, 1)).cgColor)
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.55 * min(k, 1)).cgColor)
        ctx.setLineWidth(2 + 2 * k)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(min(k, 1)).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The outline drawn round from its start as far as the rest has come, `progress` of the way.
    private func drawRest(_ outline: CGPath, progress: Double, _ ctx: CGContext) {
        let length = Self.length(of: outline)
        guard length > 0 else { return }
        let eased = CGFloat(1 - pow(1 - progress, 2))
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.addPath(outline)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.5 + 0.5 * eased).cgColor)
        ctx.setLineWidth(2 + eased)
        ctx.setLineCap(.round)
        // Glowing more as it closes, about to open.
        ctx.setShadow(offset: .zero, blur: 8 * eased * deviceScale, color: CanvasInk.pencil.withAlphaComponent(0.8 * eased).cgColor)
        ctx.setLineDash(phase: 0, lengths: [max(length * eased, 0.01), length + 1])
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// About how long an outline is, its curves measured in short straight steps.
    private static func length(of path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var last = CGPoint.zero, start = CGPoint.zero
        func walk(_ to: CGPoint) {
            total += hypot(to.x - last.x, to.y - last.y)
            last = to
        }
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                last = p[0]
                start = p[0]
            case .addLineToPoint:
                walk(p[0])
            case .addQuadCurveToPoint:
                let a = last
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1 - t
                    walk(CGPoint(x: u * u * a.x + 2 * u * t * p[0].x + t * t * p[1].x, y: u * u * a.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                let a = last
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * p[0].x + 3 * u * t * t * p[1].x + t * t * t * p[2].x
                    let y = u * u * u * a.y + 3 * u * u * t * p[0].y + 3 * u * t * t * p[1].y + t * t * t * p[2].y
                    walk(CGPoint(x: x, y: y))
                }
            case .closeSubpath:
                walk(start)
            @unknown default:
                break
            }
        }
        return total
    }

    private func drawLabel(_ text: String, under r: CGRect, in bounds: CGRect, _ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var pill = CGRect(x: (r.midX - size.width / 2 - 9).rounded(), y: (r.maxY + 12).rounded(), width: (size.width + 18).rounded(), height: 22)
        pill.origin.x = min(max(pill.minX, bounds.minX + 8), bounds.maxX - pill.width - 8)
        if pill.maxY > bounds.maxY - 8 { pill.origin.y = max(bounds.minY + 8, (r.minY - 34).rounded()) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * deviceScale), blur: 4 * deviceScale, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 9, y: pill.minY + (22 - size.height) / 2), withAttributes: attrs)
    }

    private func drawOffer(_ ctx: CGContext, in bounds: CGRect) {
        let plan = offer
        if plan != offerKey {
            // A new word springs in; one going away shrinks back into the shape.
            if plan != nil, offerKey == nil || offerShown.value < 0.05 { offerShown = Spring(0) }
            offerKey = plan ?? offerKey
            offerShown.target = plan == nil ? 0 : 1
        }
        offerShown.step(dt, stiffness: 300, damping: 20)
        guard let shown = plan ?? offerKey, offerShown.value > 0.01, let r = offerRect(shown, in: bounds) else {
            if plan == nil { offerKey = nil }
            return
        }
        let k = CGFloat(offerShown.value)
        let lifted = offerHovered && plan != nil
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Springs up out of the shape it is about.
        ctx.translateBy(x: r.midX, y: r.maxY)
        ctx.scaleBy(x: 0.85 + 0.15 * k, y: 0.85 + 0.15 * k)
        ctx.translateBy(x: -r.midX, y: -r.maxY + 6 * (1 - k) - (lifted ? 1 : 0))
        // Faded as one piece, words and all.
        ctx.setAlpha(min(1, k))
        ctx.beginTransparencyLayer(in: r.insetBy(dx: -20, dy: -20), auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        let capsule = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: lifted ? -5 : -3), blur: lifted ? 16 : 11,
                      color: NSColor.black.withAlphaComponent(lifted ? 0.28 : 0.2).cgColor)
        ctx.addPath(capsule)
        ctx.setFillColor((lifted ? CanvasInk.pencil.blended(withFraction: 0.12, of: .black) ?? CanvasInk.pencil : CanvasInk.pencil).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        drawGlyph(in: CGRect(x: r.minX + 10, y: r.midY - 6.5, width: 13, height: 13), ctx)
        let words = String(localized: DocumentStore.masking)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (words as NSString).size(withAttributes: attrs)
        (words as NSString).draw(at: CGPoint(x: r.minX + 10 + 13 + 6, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    /// A picture of a mask: a hill and a sun seen through a round window.
    private func drawGlyph(in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let window = CGPath(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        ctx.addPath(window)
        ctx.clip()
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: r.minX - 1, y: r.maxY))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.5))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.68))
        hill.addLine(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.56))
        hill.addLine(to: CGPoint(x: r.maxX + 1, y: r.maxY))
        hill.closeSubpath()
        ctx.addPath(hill)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.2, width: r.width * 0.2, height: r.width * 0.2))
        ctx.resetClip()
        ctx.addPath(window)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokePath()
    }
}
