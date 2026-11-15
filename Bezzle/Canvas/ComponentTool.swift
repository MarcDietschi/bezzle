import AppKit

/// Components on the canvas. A copy is outlined in violet rather than pencil wherever it is marked,
/// and with one of them selected, every other copy of it shows where it is with a faint line, so
/// what will change with it is in sight before anything is changed. When a change to one copy is
/// made in the others, a light runs out from it over the canvas and each copy lights up as it
/// reaches it, the nearest first: what followed shows, and nothing else does. A component just
/// made has its outline drawn round it.
///
/// Under a selected copy whose component has variants lies a row of them, each drawn as this copy
/// would look as it: the pointer on one shows the copy turning into it on the canvas, a press makes
/// it so, and the round button after them makes a new variant of the copy as it looks. After a
/// change, a word under the copy offers to narrow what the change reached, or to widen it
/// (`ComponentOffer`).
final class ComponentTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}

    init(store: DocumentStore) {
        self.store = store
    }

    typealias Spring = DeckTool.Spring

    private static let ink = CanvasInk.linked
    private static let surface = Theme.dynamicNS(0xFFFFFF, 0x2B2926)
    private static let edge = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.12, darkAlpha: 0.2)
    private static let words = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.6, darkAlpha: 0.66)
    private static let font = NSFont.systemFont(ofSize: 11.5)
    private static let buttonFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let tagFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    // MARK: - Time

    private var lastFrame: CFTimeInterval = 0
    private var dt: Double = 1.0 / 120

    /// Whether anything is still on its way, and the canvas should be drawn again next frame.
    var isAnimating: Bool {
        !lit.isEmpty || !waves.isEmpty || !traces.isEmpty || !ghosts.isEmpty || offerShown.isMoving || !lift.settled || addSwell.isMoving
    }

    /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
    private static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

    private static func clock() -> CFTimeInterval { CACurrentMediaTime() / slow }

    private func tick() -> CFTimeInterval {
        let now = Self.clock()
        dt = lastFrame == 0 ? 1.0 / 120 : min(max(now - lastFrame, 1.0 / 240 / Self.slow), 1.0 / 20)
        lastFrame = now
        return now
    }

    private func view(_ r: CGRect) -> CGRect { store.viewport.toView(r) }

    // MARK: - Where copies are

    /// A copy as it shows on screen: its corners, turned as it is, in view points.
    private func corners(of copy: Node) -> [CGPoint]? {
        guard let inst = copy.instance else { return nil }
        let o = store.doc.parentOrigin(of: copy.id) + copy.frame.origin
        let pts: [CGPoint]
        if let t = inst.turn, t != 0 {
            let c = inst.box.center + o
            pts = Geometry.corners(of: CGRect(center: c, size: inst.box.size), rotation: t)
        } else {
            let f = CGRect(origin: o, size: copy.frame.size)
            pts = Geometry.corners(of: f, rotation: 0)
        }
        return pts.map { store.viewport.toView($0) }
    }

    private func viewRect(of copy: Node) -> CGRect? {
        guard let pts = corners(of: copy) else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Whether a copy is seen: not in a post of a deck turned to another.
    private func seen(_ id: UUID) -> Bool {
        guard let (deck, post) = store.doc.post(of: id) else { return true }
        return post == nil ? false : post == store.front(of: deck)
    }

    private func path(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    // MARK: - The light running between copies

    private struct Lit {
        var from: CFTimeInterval
        var last: CFTimeInterval
    }

    private var lit: [UUID: Lit] = [:]
    private var waves: [(center: CGPoint, start: CFTimeInterval)] = []
    private var traces: [UUID: CFTimeInterval] = [:]
    private var echoSeen: CFTimeInterval = 0
    /// How fast the light runs over the screen, in points a second.
    private static let speed: Double = 1700

    /// Copies as they looked before a change made at once, drawn over them until the light reaches
    /// them, so the change is seen running from copy to copy: by copy, the copy then, on the
    /// canvas, and when the light gets there.
    private var ghosts: [UUID: (node: Node, at: CFTimeInterval)] = [:]

    private func takeEcho(_ now: CFTimeInterval) {
        guard let (echo, real, was) = store.componentEcho, real / Self.slow > echoSeen else { return }
        let at = real / Self.slow
        echoSeen = at
        let source = echo.from.first.flatMap { store.doc.node($0) }.flatMap(viewRect(of:))?.center
        if echo.made {
            for id in echo.from + echo.to { traces[id] = at }
        }
        if let source, !echo.to.isEmpty, waves.last.map({ now - $0.start > 0.45 }) ?? true {
            waves.append((source, at))
        }
        ghosts = [:]
        let visible = CGRect(origin: .zero, size: store.canvasSize).insetBy(dx: -40, dy: -40)
        for id in echo.to {
            let c = store.doc.node(id).flatMap(viewRect(of:))?.center
            let d = source.flatMap { s in c.map { Double(hypot($0.x - s.x, $0.y - s.y)) } } ?? 0
            let start = at + min(0.5, d / Self.speed)
            if let was, echo.to.count <= 120, let c, visible.contains(c), seen(id), var old = was.node(id), let frame = was.absoluteFrame(of: id) {
                old.frame.origin = frame.origin
                ghosts[id] = (old, start)
            }
            if var l = lit[id], now - l.last < 0.6 {
                l.last = max(l.last, start)
                lit[id] = l
            } else {
                lit[id] = Lit(from: start, last: start)
            }
        }
    }

    private static func smooth(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func glow(_ l: Lit, _ now: CFTimeInterval) -> CGFloat {
        let rise = Self.smooth((now - l.from) / 0.12)
        let after = now - l.last - 0.28
        let fall = after <= 0 ? 1 : exp(-after / 0.32)
        return CGFloat(rise * fall)
    }

    /// A copy's outline grown by `by` view points all round, its corners a little round.
    private func grown(_ pts: [CGPoint], by d: CGFloat) -> CGPath {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        // Turned copies keep their four corners; upright ones get soft ones.
        if Set(xs.map { ($0 * 10).rounded() }).count <= 2 {
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -d, dy: -d)
            let radius = min(4 + d, r.width / 2, r.height / 2)
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let c = CGPoint(x: xs.reduce(0, +) / 4, y: ys.reduce(0, +) / 4)
        return path(pts.map { p in
            let v = CGPoint(x: p.x - c.x, y: p.y - c.y), l = max(hypot(v.x, v.y), 0.001)
            return CGPoint(x: p.x + v.x / l * d * 1.41, y: p.y + v.y / l * d * 1.41)
        })
    }

    /// The copies as they were, until the light reaches each, fading into how they are now.
    private func drawGhosts(_ ctx: CGContext, _ now: CFTimeInterval, scale: CGFloat) {
        guard !ghosts.isEmpty else { return }
        let vp = store.viewport
        var options = Renderer.Options()
        options.deviceScale = scale * vp.zoom
        options.assets = store.assets
        for (id, g) in ghosts {
            let t = now - g.at
            if t > 0.2 { ghosts[id] = nil; continue }
            let alpha = t < 0 ? 1 : CGFloat(1 - Self.smooth(t / 0.2))
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.scaleBy(x: vp.zoom, y: vp.zoom)
            ctx.translateBy(x: -vp.origin.x, y: -vp.origin.y)
            Renderer.drawNode(g.node, in: ctx, options: options)
            ctx.restoreGState()
        }
    }

    private func drawLight(_ ctx: CGContext, _ now: CFTimeInterval, in bounds: CGRect) {
        // The light running out over the canvas.
        waves.removeAll { now - $0.start > 0.75 }
        for w in waves where now >= w.start {
            let t = now - w.start
            let r = CGFloat(t * Self.speed)
            let a = CGFloat(0.22 * (1 - Self.smooth(t / 0.75)))
            guard a > 0.005 else { continue }
            ctx.saveGState()
            ctx.setStrokeColor(Self.ink.withAlphaComponent(a).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setShadow(offset: .zero, blur: 10, color: Self.ink.withAlphaComponent(a * 1.6).cgColor)
            ctx.strokeEllipse(in: CGRect(x: w.center.x - r, y: w.center.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
        // Each copy as the light reaches it: it lights up, and a ring runs out from it.
        for (id, l) in lit {
            let k = glow(l, now)
            if now > l.last + 2.5 { lit[id] = nil; continue }
            guard k > 0.01, seen(id), let copy = store.doc.node(id), let pts = corners(of: copy) else { continue }
            let p = grown(pts, by: 2)
            ctx.saveGState()
            ctx.addPath(p)
            ctx.setFillColor(Self.ink.withAlphaComponent(0.12 * k).cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 22 * k, color: Self.ink.withAlphaComponent(0.85 * k).cgColor)
            ctx.addPath(p)
            ctx.setStrokeColor(Self.ink.withAlphaComponent(k).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.restoreGState()
            // The ring, once, as the light first reaches it.
            let t = (now - l.from) / 0.55
            if t > 0, t < 1 {
                ctx.saveGState()
                ctx.addPath(grown(pts, by: 2 + CGFloat(Self.smooth(t)) * 14))
                ctx.setStrokeColor(Self.ink.withAlphaComponent(0.55 * CGFloat(1 - t)).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        // An outline drawn round what was just made a component, or linked to one.
        for (id, start) in traces {
            let t = now - start
            if t > 1.1 { traces[id] = nil; continue }
            guard t >= 0, let copy = store.doc.node(id), let pts = corners(of: copy) else { continue }
            let length = zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
            let drawn = CGFloat(Self.smooth(t / 0.55)) * length
            let fade = CGFloat(1 - Self.smooth((t - 0.6) / 0.5))
            ctx.saveGState()
            ctx.addPath(path(pts))
            ctx.setLineDash(phase: 0, lengths: [drawn, length + 1])
            ctx.setShadow(offset: .zero, blur: 10, color: Self.ink.withAlphaComponent(0.6 * fade).cgColor)
            ctx.setStrokeColor(Self.ink.withAlphaComponent(fade).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - The copies of the one selected

    /// The other copies of the one selected, found once per change.
    private var siblings: (version: Int, copy: UUID, others: [Node])?

    private func drawSiblings(_ ctx: CGContext) {
        guard let copy = store.selectedCopy ?? store.selectedCopies.first, let inst = copy.instance else { return }
        let others: [Node]
        if let s = siblings, s.version == store.version, s.copy == copy.id {
            others = s.others
        } else {
            others = store.doc.copies(of: inst.of).filter { $0.id != copy.id }
            siblings = (store.version, copy.id, others)
        }
        guard !others.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(Self.ink.withAlphaComponent(0.42).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        let now = Self.clock()
        for o in others where seen(o.id) && (lit[o.id].map { glow($0, now) < 0.05 } ?? true) {
            guard let pts = corners(of: o) else { continue }
            ctx.addPath(path(pts))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The component's name over the copy selected, at its top left.
    private func drawTag(_ ctx: CGContext) {
        guard store.editingText == nil, let copy = store.selectedCopy, let master = store.master(of: copy),
              let r = viewRect(of: copy), r.width > 36 else { return }
        var text = master.name
        if (master.master?.variants.isEmpty ?? true) == false { text += "  ·  " + Components.name(of: copy.instance?.variant, in: master) }
        let s = NSAttributedString(string: text, attributes: [.font: Self.tagFont, .foregroundColor: Self.ink])
        let size = s.size()
        let origin = CGPoint(x: r.minX + 13, y: r.minY - size.height - 4)
        // A diamond, as a component is marked in the layers list.
        let d: CGFloat = 3.6, c = CGPoint(x: r.minX + 4.5, y: origin.y + size.height / 2)
        ctx.saveGState()
        let diamond = CGMutablePath()
        diamond.addLines(between: [CGPoint(x: c.x, y: c.y - d), CGPoint(x: c.x + d, y: c.y), CGPoint(x: c.x, y: c.y + d), CGPoint(x: c.x - d, y: c.y)])
        diamond.closeSubpath()
        ctx.addPath(diamond)
        ctx.setFillColor(Self.ink.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        s.draw(at: origin)
    }

    // MARK: - The row of variants

    private enum Part: Equatable { case card(Int), add, button(Int) }
    private var hovered: Part?
    /// How far each card has come up off the row, by its place in it.
    private var lift = DeckTool.Springs<Int>()
    private var addSwell = Spring(0)

    private struct Row {
        var copy: UUID
        var master: UUID
        var variants: [Int?]
        var cards: [CGRect]
        var add: CGRect
        var current: Int
        /// Beside the copy, rather than under it.
        var beside: Bool
    }

    private func row() -> Row? {
        guard store.editingText == nil, !store.inGesture, !store.isReadOnly, let copy = store.selectedCopy, !copy.locked,
              let inst = copy.instance, let master = store.master(of: copy), let r = viewRect(of: copy) else { return nil }
        let variants = Components.variants(of: master)
        guard variants.count >= 2 else { return nil }
        let h: CGFloat = 30, gap: CGFloat = 6, add: CGFloat = 18
        let widths = variants.map { v -> CGFloat in
            let b = Components.box(of: master, variant: v)
            return min(96, max(24, h * (b.height > 0 ? b.width / b.height : 1)))
        }
        let total = widths.reduce(0, +) + gap * CGFloat(variants.count - 1) + 10 + add
        // Beside the copy, where it covers nothing of what lies under it; else under it.
        let beside = r.maxX + 16 + total <= store.canvasSize.width - 8
        var x = beside ? (r.maxX + 16).rounded() : (r.midX - total / 2).rounded()
        let y = beside ? (r.midY - h / 2).rounded() : (r.maxY + 14).rounded()
        var cards: [CGRect] = []
        for w in widths {
            cards.append(CGRect(x: x, y: y, width: w, height: h))
            x += w + gap
        }
        let addRect = CGRect(x: x + 4, y: y + (h - add) / 2, width: add, height: add)
        let current = variants.firstIndex { $0 == Components.variant(inst.variant, of: master) } ?? 0
        return Row(copy: copy.id, master: master.id, variants: variants, cards: cards, add: addRect, current: current, beside: beside)
    }

    /// Each variant drawn as the selected copy would look as it, made once per change.
    private var pictures: (version: Int, copy: UUID, images: [CGImage?])?

    private func images(for row: Row) -> [CGImage?] {
        if let p = pictures, p.version == store.version, p.copy == row.copy, p.images.count == row.variants.count { return p.images }
        guard let copy = store.doc.node(row.copy), let master = store.doc.master(row.master) else { return [] }
        let images = row.variants.enumerated().map { i, v -> CGImage? in
            var shown = Components.build(Components.switched(copy, to: v, in: master), master: master, masterWas: nil, masters: store.doc.mastersByID)
            shown.frame.origin = .zero
            shown.hidden = false
            var doc = BezzleDocument()
            doc.nodes = [shown]
            doc.fitGroups()
            return Renderer.thumbnail(of: doc, size: row.cards[i].size, scale: 2, assets: store.assets)
        }
        pictures = (store.version, row.copy, images)
        return images
    }

    private func drawRow(_ ctx: CGContext) {
        lift.step(dt, stiffness: 420, damping: 26)
        addSwell.step(dt, stiffness: 420, damping: 22)
        guard let row = row() else { return }
        let images = images(for: row)
        for (i, card) in row.cards.enumerated() {
            if hovered == .card(i) { lift[i, start: 0].target = 1 } else { lift[i, start: 0].target = 0 }
            let up = CGFloat(lift[i, start: 0].value)
            let r = card.offsetBy(dx: 0, dy: -2.5 * up)
            let shape = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1 + 3 * up), blur: 4 + 6 * up, color: NSColor.black.withAlphaComponent(0.14 + 0.08 * up).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(Self.surface.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if i < images.count, let image = images[i] {
                ctx.saveGState()
                ctx.addPath(shape)
                ctx.clip()
                // Drawn the right way up in the flipped view.
                ctx.translateBy(x: r.minX, y: r.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
                ctx.restoreGState()
            }
            ctx.addPath(shape)
            if i == row.current {
                ctx.setStrokeColor(Self.ink.cgColor)
                ctx.setLineWidth(2)
            } else {
                ctx.setStrokeColor(Self.edge.cgColor)
                ctx.setLineWidth(0.5)
            }
            ctx.strokePath()
        }
        // The name of the one the pointer is on, under it; the one shown is named over the copy.
        // The pointer may rest where a card was before the row grew shorter under it (a variant
        // undone, another copy picked): that card is no longer there to name.
        if case .card(let named) = hovered, row.variants.indices.contains(named), let master = store.doc.master(row.master) {
            let s = NSAttributedString(string: Components.name(of: row.variants[named], in: master),
                                       attributes: [.font: Self.tagFont, .foregroundColor: Self.ink])
            let size = s.size(), c = row.cards[named]
            let at = CGPoint(x: (c.midX - size.width / 2).rounded(), y: c.maxY + 4)
            let pill = CGRect(x: at.x - 6, y: at.y - 1, width: size.width + 12, height: size.height + 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.setFillColor(Self.surface.cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            s.draw(at: at)
        }
        // The round button that makes a new variant.
        addSwell.target = hovered == .add ? 1 : 0
        let k = CGFloat(addSwell.value)
        let a = row.add.insetBy(dx: -1.5 * k, dy: -1.5 * k)
        ctx.saveGState()
        if k > 0.5 {
            ctx.setFillColor(Self.ink.cgColor)
            ctx.fillEllipse(in: a)
        } else {
            ctx.setFillColor(Self.surface.cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.16).cgColor)
            ctx.fillEllipse(in: a)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(Self.ink.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: a.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.setStrokeColor((k > 0.5 ? NSColor.white : Self.ink).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        let m = CGPoint(x: a.midX, y: a.midY), arm = a.width * 0.22
        ctx.move(to: CGPoint(x: m.x - arm, y: m.y))
        ctx.addLine(to: CGPoint(x: m.x + arm, y: m.y))
        ctx.move(to: CGPoint(x: m.x, y: m.y - arm))
        ctx.addLine(to: CGPoint(x: m.x, y: m.y + arm))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - The offer

    private var offerShown = Spring(0)
    private var offerToken: UUID?

    private struct OfferLayout {
        var rect: CGRect
        var words: NSAttributedString
        var buttons: [(rect: CGRect, label: NSAttributedString, action: ComponentOffer.Action, filled: Bool)]
        /// Beside the copy, rather than under it.
        var beside = true
    }

    private func offerLayout() -> OfferLayout? {
        // Only while what was changed is still what is worked on.
        guard let offer = store.componentOffer, store.editingText == nil, !store.inGesture,
              store.selectedCopies.contains(where: { $0.id == offer.anchor }),
              let copy = store.doc.node(offer.anchor), let r = viewRect(of: copy) else { return nil }
        let words = NSAttributedString(string: offer.words, attributes: [.font: Self.font, .foregroundColor: Self.words])
        var x = 12 + ceil(words.size().width) + 10
        var buttons: [(CGRect, NSAttributedString, ComponentOffer.Action, Bool)] = []
        for (i, b) in offer.buttons.enumerated() {
            let filled = i == 0
            let label = NSAttributedString(string: b.title, attributes: [.font: Self.buttonFont, .foregroundColor: filled ? NSColor.white : Self.ink])
            let w = ceil(label.size().width) + 18
            buttons.append((CGRect(x: x, y: 4, width: w, height: 20), label, b.action, filled))
            x += w + 4
        }
        let size = CGSize(width: x, height: 28)
        // Beside the copy, where it covers nothing of the copies under it; else under it.
        var origin = CGPoint(x: (r.maxX + 14).rounded(), y: (r.midY - size.height / 2).rounded())
        var beside = origin.x + size.width <= store.canvasSize.width - 8
        if let row = row(), row.copy == copy.id {
            // Under the row of variants beside the copy, or under the copy and the row under it.
            if row.beside {
                origin = CGPoint(x: row.cards[0].minX, y: (row.cards[0].maxY + 10).rounded())
            } else {
                origin = CGPoint(x: (r.midX - size.width / 2).rounded(), y: (row.cards[0].maxY + 12).rounded())
            }
            beside = false
        } else if !beside {
            origin = CGPoint(x: (r.midX - size.width / 2).rounded(), y: (r.maxY + 12).rounded())
        }
        let rect = CGRect(origin: origin, size: size)
        return OfferLayout(rect: rect, words: words, buttons: buttons.map { ($0.0.offsetBy(dx: rect.minX, dy: rect.minY), $0.1, $0.2, $0.3) }, beside: beside)
    }

    private func drawOffer(_ ctx: CGContext) {
        if store.componentOffer?.token != offerToken {
            offerToken = store.componentOffer?.token
            offerShown = Spring(0)
            offerShown.target = store.componentOffer == nil ? 0 : 1
        }
        offerShown.step(dt, stiffness: 300, damping: 20)
        guard let o = offerLayout() else { return }
        let k = CGFloat(offerShown.value)
        guard k > 0.01 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Springs out of the copy it is about.
        let anchor = o.beside ? CGPoint(x: o.rect.minX, y: o.rect.midY) : CGPoint(x: o.rect.midX, y: o.rect.minY)
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: 0.85 + 0.15 * k, y: 0.85 + 0.15 * k)
        ctx.translateBy(x: -anchor.x - (o.beside ? 8 * (1 - k) : 0), y: -anchor.y - (o.beside ? 0 : 6 * (1 - k)))
        ctx.setAlpha(min(1, k))
        let capsule = CGPath(roundedRect: o.rect, cornerWidth: o.rect.height / 2, cornerHeight: o.rect.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.addPath(capsule)
        ctx.setFillColor(Self.surface.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        for (i, b) in o.buttons.enumerated() {
            let pill = CGPath(roundedRect: b.rect, cornerWidth: b.rect.height / 2, cornerHeight: b.rect.height / 2, transform: nil)
            ctx.addPath(pill)
            if b.filled {
                ctx.setFillColor((hovered == .button(i) ? Self.ink.blended(withFraction: 0.15, of: .black) ?? Self.ink : Self.ink).cgColor)
                ctx.fillPath()
            } else {
                ctx.setFillColor(Self.ink.withAlphaComponent(hovered == .button(i) ? 0.16 : 0.08).cgColor)
                ctx.fillPath()
            }
            let size = b.label.size()
            b.label.draw(at: CGPoint(x: b.rect.midX - size.width / 2, y: b.rect.midY - size.height / 2))
        }
        let size = o.words.size()
        o.words.draw(at: CGPoint(x: o.rect.minX + 12, y: o.rect.midY - size.height / 2))
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        let now = tick()
        takeEcho(now)
        drawGhosts(ctx, now, scale: scale)
        drawSiblings(ctx)
        drawLight(ctx, now, in: bounds)
        drawTag(ctx)
        drawRow(ctx)
        drawOffer(ctx)
    }

    // MARK: - The pointer

    private func part(at v: CGPoint) -> Part? {
        if let o = offerLayout(), offerShown.value > 0.5, let i = o.buttons.firstIndex(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(v) }) { return .button(i) }
        guard let row = row() else { return nil }
        if row.add.insetBy(dx: -4, dy: -6).contains(v) { return .add }
        if let i = row.cards.firstIndex(where: { $0.insetBy(dx: -2, dy: -3).contains(v) }) { return .card(i) }
        return nil
    }

    /// Whether the pointer is on something of this tool's, which the canvas then leaves alone.
    func covers(_ v: CGPoint) -> Bool { part(at: v) != nil }

    /// Where the row of variants' cards and its round button are, and the offer's buttons, in view
    /// points: for tests, to press them.
    var places: (cards: [CGRect], add: CGRect?, offer: [CGRect]) {
        let r = row()
        // The offer shows once it has sprung in; tests have no frames to wait for.
        offerToken = store.componentOffer?.token
        offerShown = Spring(store.componentOffer == nil ? 0 : 1)
        return (r?.cards ?? [], r?.add, offerLayout()?.buttons.map(\.rect) ?? [])
    }

    /// Whether a change's light is still running over any copy, or a copy is still lit.
    var lights: (lit: Int, ghosts: Int, waves: Int) { (lit.count, ghosts.count, waves.count) }

    func hover(_ v: CGPoint?) {
        let next = v.flatMap(part(at:))
        guard next != hovered else { return }
        hovered = next
        // The copy turned into the variant the pointer is on, on the canvas, before it is chosen.
        if case .card(let i) = next, let row = row(), i != row.current, let copy = store.doc.node(row.copy), let master = store.doc.master(row.master) {
            let v = row.variants[i]
            store.showPreview("component.variant", reshaping: { doc in
                let before = doc
                doc.update(copy.id) { $0 = Components.switched($0, to: v, in: master) }
                doc.syncComponents(since: before)
            })
        } else {
            store.showPreview("component.variant", reshaping: nil)
        }
        redraw()
    }

    func cursor(at v: CGPoint) -> NSCursor? { part(at: v) == nil ? nil : .pointingHand }

    /// A press on the row of variants or on the word offered. False leaves it to the canvas.
    func down(at v: CGPoint) -> Bool {
        guard let p = part(at: v) else { return false }
        switch p {
        case .button(let i):
            guard let offer = store.componentOffer, let o = offerLayout(), i < o.buttons.count else { return false }
            store.take(offer, o.buttons[i].action)
        case .card(let i):
            guard let row = row() else { return false }
            let v = row.variants[i]
            store.setVariant(v, for: [row.copy])
            store.showPreview("component.variant", reshaping: nil)
            pictures = nil
        case .add:
            guard let row = row() else { return false }
            store.showPreview("component.variant", reshaping: nil)
            store.addVariant(from: row.copy)
        }
        hovered = nil
        redraw()
        return true
    }
}
