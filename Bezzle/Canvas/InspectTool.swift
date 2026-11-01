import AppKit

/// The design inspected, on the prototype's millimetre paper: it is read, never changed. The
/// pointer finds the smallest thing under it; a click picks that, and a click on what is picked
/// takes the next thing out, the group or screen it lies in, until the screen, and then back in.
/// What is picked is drawn with its width and height as on a technical drawing; the pointer on
/// anything else measures the way to it, in the pink the canvas gives gaps, and on the picked
/// layer itself it measures how far that lies inside what a click would pick next, which is
/// outlined dashed. Dragging moves the view, as a hand moves the sheet.
@MainActor
final class InspectTool {
    let store: DocumentStore
    var redraw: () -> Void = {}
    /// The artboard whose name is at a view point.
    var titleHit: (CGPoint) -> UUID? = { _ in nil }
    /// Opens a menu at a view point.
    var menu: (CGPoint, [MenuEntry]) -> Void = { _, _ in }

    init(store: DocumentStore) {
        self.store = store
    }

    // MARK: Coming in and going out

    private var mode: (from: CGFloat, to: CGFloat, at: CFTimeInterval) = (0, 0, 0)
    private static let modeTime: CFTimeInterval = 0.4
    /// Come straight from drawing, or gone straight back to it: the prototype's threads stay
    /// away, rather than showing for a moment between.
    private var jumped = false

    /// Turned on or off; `design` says it was come to from drawing, or left for it.
    func modeChanged(_ on: Bool, design: Bool) {
        let now = CACurrentMediaTime()
        mode = (shown(at: now), on ? 1 : 0, now)
        jumped = design
        press = nil
        hovered = nil
        if on { grow = Grow() }
        redraw()
    }

    /// How far the canvas has turned to being inspected, 0 to 1, eased.
    func shown(at now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        let t = min(max((now - mode.at) / Self.modeTime, 0), 1)
        let e = 1 - pow(1 - t, 3)
        return mode.from + (mode.to - mode.from) * CGFloat(e)
    }

    /// How much of the prototype's threads shows: they fade as the measures come, and back.
    var threadsAlpha: CGFloat {
        let k = shown()
        if jumped { return store.inspecting || k > 0.001 ? 0 : 1 }
        return 1 - k
    }

    var isAnimating: Bool {
        CACurrentMediaTime() - mode.at < Self.modeTime + 0.05 || (store.inspecting && !grow.settled)
    }

    // MARK: Finding things

    /// The smallest thing under a view point: a layer, however deep in groups and copies; the
    /// screen where nothing else is; a screen by its name.
    func deepest(at v: CGPoint) -> UUID? {
        if let t = titleHit(v) { return t }
        let p = store.viewport.toCanvas(v)
        let seen = store.seenDoc
        let tolerance = 2 / store.viewport.zoom
        for n in seen.nodes.reversed() where !n.hidden {
            if n.isArtboard {
                guard n.frame.contains(p) else { continue }
                let local = CGPoint(x: p.x - n.frame.minX, y: p.y - n.frame.minY)
                return Prototype.chain(at: local, in: n, tolerance: tolerance).first?.id ?? n.id
            }
            // Lying loose on the canvas.
            guard Geometry.contains(n, p, tolerance: tolerance) else { continue }
            if n.isGroup {
                let holder = Node(kind: .artboard, name: "", frame: .zero)
                var loose = holder
                loose.children = [n]
                return Prototype.chain(at: p, in: loose, tolerance: tolerance).first?.id ?? n.id
            }
            return n.id
        }
        return nil
    }

    /// What a click on `d` picks: `d` itself, unless what is picked is `d` or holds it; then the
    /// next thing out from what is picked, and from the screen back to `d`.
    func pick(for d: UUID) -> UUID {
        let seen = store.seenDoc
        guard store.selection.count == 1, let picked = store.selection.first else { return d }
        let chain = Inspect.path(of: d, in: seen).map(\.id)
        guard let i = chain.firstIndex(of: picked), i > 0 else { return d }
        return chain[i - 1]
    }

    // MARK: What is shown

    /// What the marks show, from what is picked and what the pointer is on.
    enum Showing: Equatable {
        case none
        /// Nothing picked: what the pointer is on, and its size.
        case outline(UUID)
        /// The picked layer alone: its width and height.
        case size(UUID)
        /// From the picked layer to another.
        case between(UUID, UUID)
        /// The picked layer inside what a click would pick next.
        case around(UUID, UUID)
    }

    private(set) var hovered: UUID?

    var showing: Showing {
        let seen = store.seenDoc
        let picked = store.selection.count == 1 ? store.selection.first.flatMap { seen.node($0) != nil ? $0 : nil } : nil
        guard let picked else { return hovered.map { .outline($0) } ?? .none }
        guard let h = hovered, h != picked || seen.node(picked)?.isArtboard == false else { return .size(picked) }
        let chain = Inspect.path(of: h, in: seen).map(\.id)
        if chain.contains(picked) {
            // On the picked layer: inside the next thing out, which a click would pick.
            if seen.node(picked)?.isArtboard == true { return h == picked ? .size(picked) : .between(h, picked) }
            let next = pick(for: h)
            return next == picked ? .size(picked) : .around(picked, next)
        }
        return .between(picked, h)
    }

    func hover(_ v: CGPoint?) {
        let h = v.flatMap { store.inspecting ? deepest(at: $0) : nil }
        guard h != hovered else { return }
        hovered = h
        redraw()
    }

    func cursor(at v: CGPoint) -> NSCursor {
        press?.moved == true ? .closedHand : .arrow
    }

    // MARK: Pressing

    private struct Press {
        let at: CGPoint
        let origin: CGPoint
        var moved = false
        let target: UUID?
    }

    private var press: Press?
    var dragging: Bool { press != nil }

    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard store.inspecting else { return false }
        press = Press(at: v, origin: store.viewport.origin, target: deepest(at: v))
        return true
    }

    func drag(to v: CGPoint) {
        guard var p = press else { return }
        if !p.moved, hypot(v.x - p.at.x, v.y - p.at.y) < 3 { return }
        if !p.moved { NSCursor.closedHand.set() }
        p.moved = true
        press = p
        let z = store.viewport.zoom
        store.viewport.origin = CGPoint(x: p.origin.x - (v.x - p.at.x) / z, y: p.origin.y - (v.y - p.at.y) / z)
        redraw()
    }

    func up(at v: CGPoint) {
        guard let p = press else { return }
        press = nil
        if p.moved {
            NSCursor.arrow.set()
            return
        }
        if let d = p.target { store.selection = [pick(for: d)] } else { store.selection = [] }
        hover(v)
        redraw()
    }

    func cancel() -> Bool {
        guard press != nil else { return false }
        press = nil
        return true
    }

    /// Escape takes the next thing out, and from the screen lets go. Nothing here changes the
    /// design, so the keys that would, do nothing.
    func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            if cancel() { return true }
            let seen = store.seenDoc
            if store.selection.count == 1, let id = store.selection.first, let parent = seen.parent(of: id) {
                store.selection = [parent.id]
            } else {
                store.selection = []
            }
            redraw()
            return true
        case 51, 117:
            return true
        default:
            return false
        }
    }

    // MARK: The menu

    func menuEntries(at v: CGPoint) -> [MenuEntry]? {
        guard let d = deepest(at: v) else { return nil }
        // What is picked stays picked when the menu opens on it, or on something in it.
        let seen = store.seenDoc
        if !(store.selection.count == 1 && Inspect.path(of: d, in: seen).map(\.id).contains(store.selection[0])) {
            store.selection = [d]
        }
        guard let id = store.selection.first, let node = seen.node(id) else { return nil }
        let doc = seen, tokens = Inspect.Tokens(seen)
        var entries: [MenuEntry] = [
            .item("Copy CSS") { InspectCopy.put(Inspect.css(node, in: doc, tokens: tokens)) },
            .item("Copy SwiftUI") { InspectCopy.put(Inspect.swiftUI(node, in: doc, tokens: tokens)) },
            .separator,
            .item("Copy as PNG") { [store] in InspectCopy.picture(of: id, as: .png, scale: 2, store: store) },
            .item("Copy as SVG") { [store] in InspectCopy.picture(of: id, as: .svg, scale: 1, store: store) },
            .separator,
            .item("Copy Name") { InspectCopy.put(node.name) },
        ]
        if node.kind == .text, let words = node.text, !words.isEmpty {
            entries.append(.item("Copy Text") { InspectCopy.put(words) })
        }
        return entries
    }

    // MARK: Drawing

    /// Each mark grows in from its middle when what is shown changes, a little past and back.
    private struct Grow {
        var showing: Showing = .none
        var value: Double = 0
        var velocity: Double = 0
        var last: CFTimeInterval?
        var settled: Bool { value > 0.999 && abs(velocity) < 0.01 }

        mutating func step(_ now: CFTimeInterval) {
            let dt = min(now - (last ?? now), 1.0 / 30)
            last = now
            let force = 420 * (1 - value) - 24 * velocity
            velocity += force * dt
            value += velocity * dt
            if abs(1 - value) < 0.001, abs(velocity) < 0.01 { value = 1; velocity = 0 }
        }
    }

    private var grow = Grow()

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        let k = shown()
        guard k > 0.001 else { return }
        let now = CACurrentMediaTime()
        // Going, what was shown fades as it was.
        let current = store.inspecting ? showing : grow.showing
        if current != grow.showing {
            grow = Grow(showing: current)
        }
        grow.step(now)
        let g = CGFloat(grow.value)
        let seen = store.seenDoc, vp = store.viewport
        func view(_ id: UUID) -> CGRect? { Inspect.box(of: id, in: seen).map { vp.toView($0) } }
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
        func crisp(_ r: CGRect) -> CGRect {
            CGRect(x: pixel(r.minX), y: pixel(r.minY), width: (r.width * scale).rounded() / scale, height: (r.height * scale).rounded() / scale)
        }

        ctx.saveGState()
        ctx.setAlpha(k)
        defer { ctx.restoreGState() }
        switch grow.showing {
        case .none:
            break
        case .outline(let id):
            guard let r = view(id) else { break }
            outline(crisp(r), ctx: ctx, ink: CanvasInk.pencil, width: 1, dashed: false)
            sizeTag(of: id, below: r, ctx: ctx, grow: g)
        case .size(let id):
            guard let r = view(id) else { break }
            outline(crisp(r), ctx: ctx, ink: CanvasInk.pencil, width: 1.5, dashed: false)
            dimensions(of: id, in: r, ctx: ctx, scale: scale, grow: g)
        case .around(let id, let next):
            guard let r = view(id), let o = view(next), let a = Inspect.box(of: id, in: seen), let b = Inspect.box(of: next, in: seen) else { break }
            outline(crisp(o), ctx: ctx, ink: CanvasInk.pencil, width: 1, dashed: true)
            if seen.node(next)?.isArtboard == false { nameTag(seen.node(next)?.name ?? "", at: o, ctx: ctx) }
            outline(crisp(r), ctx: ctx, ink: CanvasInk.pencil, width: 1.5, dashed: false)
            spans(Inspect.spans(from: a, to: b), ctx: ctx, scale: scale, grow: g)
        case .between(let id, let other):
            guard let r = view(id), let o = view(other), let a = Inspect.box(of: id, in: seen), let b = Inspect.box(of: other, in: seen) else { break }
            for gap in Inspect.gaps(between: a, and: b) { hatch(vp.toView(gap), ctx: ctx, scale: scale, grow: g) }
            outline(crisp(o), ctx: ctx, ink: CanvasInk.gap, width: 1, dashed: false)
            outline(crisp(r), ctx: ctx, ink: CanvasInk.pencil, width: 1.5, dashed: false)
            spans(Inspect.spans(from: a, to: b), ctx: ctx, scale: scale, grow: g)
        }
    }

    private func outline(_ r: CGRect, ctx: CGContext, ink: NSColor, width: CGFloat, dashed: Bool) {
        ctx.saveGState()
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(width)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    /// A number on a small pill of ink, grown in by `grow` about its middle.
    private func label(_ text: String, at c: CGPoint, ctx: CGContext, ink: NSColor, solid: Bool, grow: CGFloat) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.digits, .foregroundColor: solid ? NSColor.white : ink]
        let size = s.size(withAttributes: attrs)
        let pill = CGRect(x: (c.x - size.width / 2 - 5).rounded(), y: (c.y - 8.5).rounded(), width: (size.width + 10).rounded(), height: 17)
        ctx.saveGState()
        ctx.setAlpha(min(max(grow, 0), 1))
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: max(grow, 0.01), y: max(grow, 0.01))
        ctx.translateBy(x: -c.x, y: -c.y)
        let shape = CGPath(roundedRect: pill, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)
        if solid {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: ink.withAlphaComponent(0.35).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(ink.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            // A white ring, so it reads on a layer of its own colour.
            ctx.addPath(shape)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        s.draw(at: CGPoint(x: pill.minX + (pill.width - size.width) / 2, y: pill.minY + (pill.height - size.height) / 2), withAttributes: attrs)
        ctx.restoreGState()
    }

    private func labelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Self.digits]).width + 10
    }

    /// The distances, each a line in pink with a short tick at either end and its length in its
    /// middle, drawn out from the middle as they grow in; dashed where it meets an edge past its end.
    private func spans(_ spans: [Inspect.Span], ctx: CGContext, scale: CGFloat, grow: CGFloat) {
        let vp = store.viewport, ink = CanvasInk.gap
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
        let e = min(max(grow, 0), 1.2)
        ctx.saveGState()
        let lines = CGMutablePath()
        for s in spans {
            var a = vp.toView(s.from), b = vp.toView(s.to)
            if s.across { a.y = pixel(a.y); b.y = a.y } else { a.x = pixel(a.x); b.x = a.x }
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let p = CGPoint(x: m.x + (a.x - m.x) * min(e, 1), y: m.y + (a.y - m.y) * min(e, 1))
            let q = CGPoint(x: m.x + (b.x - m.x) * min(e, 1), y: m.y + (b.y - m.y) * min(e, 1))
            lines.move(to: p)
            lines.addLine(to: q)
            if e >= 0.98 {
                for end in [a, b] {
                    if s.across {
                        lines.move(to: CGPoint(x: pixel(end.x), y: end.y - 3.5))
                        lines.addLine(to: CGPoint(x: pixel(end.x), y: end.y + 3.5))
                    } else {
                        lines.move(to: CGPoint(x: end.x - 3.5, y: pixel(end.y)))
                        lines.addLine(to: CGPoint(x: end.x + 3.5, y: pixel(end.y)))
                    }
                }
            }
            if let reach = s.reach, reach.count == 2, e >= 0.98 {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [3, 3])
                ctx.setStrokeColor(ink.withAlphaComponent(0.8).cgColor)
                let r0 = vp.toView(reach[0]), r1 = vp.toView(reach[1])
                if s.across {
                    ctx.move(to: CGPoint(x: pixel(r0.x), y: r0.y))
                    ctx.addLine(to: CGPoint(x: pixel(r1.x), y: b.y))
                } else {
                    ctx.move(to: CGPoint(x: r0.x, y: pixel(r0.y)))
                    ctx.addLine(to: CGPoint(x: b.x, y: pixel(r1.y)))
                }
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        cased(lines, ink: ink, ctx: ctx)
        ctx.restoreGState()
        // The numbers over the lines; beside a line too short to hold its number.
        for s in spans {
            let a = vp.toView(s.from), b = vp.toView(s.to)
            let text = CanvasView.number(s.length)
            let w = labelWidth(text)
            var c = CGPoint(x: ((a.x + b.x) / 2).rounded(), y: ((a.y + b.y) / 2).rounded())
            let room = s.across ? abs(b.x - a.x) : abs(b.y - a.y)
            if room < (s.across ? w : 17) + 6 {
                if s.across { c.y -= 14 } else { c.x += w / 2 + 6 }
            }
            label(text, at: c, ctx: ctx, ink: ink, solid: true, grow: grow)
        }
    }

    /// Lines drawn over a casing of white, as the prototype's threads are, so they read on any layer.
    private func cased(_ lines: CGPath, ink: NSColor, ctx: CGContext) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.addPath(lines)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addPath(lines)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The picked layer's width along its top and height down its right, as a drawing marks them:
    /// a line out from the edge with a tick at each end and the number in its middle.
    private func dimensions(of id: UUID, in r: CGRect, ctx: CGContext, scale: CGFloat, grow: CGFloat) {
        let seen = store.seenDoc
        guard let n = seen.node(id) else { return }
        // A turned layer measures as it is, not by the box it covers.
        let size = n.isArtboard || n.rotation == 0 ? (Inspect.box(of: id, in: seen)?.size ?? n.frame.size) : n.frame.size
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
        let ink = CanvasInk.pencil
        let e = min(max(grow, 0), 1)
        let top = r.minY - 12, right = r.maxX + 12
        let lines = CGMutablePath()
        if r.width > 30 {
            let y = pixel(top), m = r.midX, half = r.width / 2 * e
            lines.move(to: CGPoint(x: m - half, y: y))
            lines.addLine(to: CGPoint(x: m + half, y: y))
            if e > 0.98 {
                for x in [r.minX, r.maxX] {
                    lines.move(to: CGPoint(x: pixel(x), y: y - 4))
                    lines.addLine(to: CGPoint(x: pixel(x), y: y + 4))
                }
            }
        }
        if r.height > 30 {
            let x = pixel(right), m = r.midY, half = r.height / 2 * e
            lines.move(to: CGPoint(x: x, y: m - half))
            lines.addLine(to: CGPoint(x: x, y: m + half))
            if e > 0.98 {
                for y in [r.minY, r.maxY] {
                    lines.move(to: CGPoint(x: x - 4, y: pixel(y)))
                    lines.addLine(to: CGPoint(x: x + 4, y: pixel(y)))
                }
            }
        }
        cased(lines, ink: ink.withAlphaComponent(0.9), ctx: ctx)
        // Out of the way of a screen's name, which sits over its top left.
        let w = CanvasView.number(size.width), h = CanvasView.number(size.height)
        label(w, at: CGPoint(x: r.midX.rounded(), y: (r.width > 30 ? top : r.minY - 14).rounded()), ctx: ctx, ink: ink, solid: true, grow: grow)
        // On its line; beside the edge where there is too little height for a line.
        let hx = r.height > 30 ? right : r.maxX + 6 + labelWidth(h) / 2
        label(h, at: CGPoint(x: hx.rounded(), y: r.midY.rounded()), ctx: ctx, ink: ink, solid: true, grow: grow)
    }

    /// What the pointer is on, with nothing picked: its size under it, outlined.
    private func sizeTag(of id: UUID, below r: CGRect, ctx: CGContext, grow: CGFloat) {
        let seen = store.seenDoc
        guard let n = seen.node(id) else { return }
        let size = n.rotation == 0 || n.isArtboard ? (Inspect.box(of: id, in: seen)?.size ?? n.frame.size) : n.frame.size
        let text = "\(CanvasView.number(size.width)) × \(CanvasView.number(size.height))"
        label(text, at: CGPoint(x: r.midX.rounded(), y: (r.maxY + 13).rounded()), ctx: ctx, ink: CanvasInk.pencil, solid: false, grow: grow)
    }

    /// The name of what a click would pick next, over its top left, as a screen's name is.
    private func nameTag(_ name: String, at r: CGRect, ctx: CGContext) {
        guard !name.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: CanvasInk.pencil]
        let s = name as NSString
        let size = s.size(withAttributes: attrs)
        let plate = CGRect(x: r.minX.rounded(), y: (r.minY - size.height - 6).rounded(), width: min(size.width + 8, max(r.width, 60)).rounded(), height: (size.height + 4).rounded())
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.clip(to: plate.insetBy(dx: 2, dy: 0))
        s.draw(at: CGPoint(x: plate.minX + 4, y: plate.minY + 2), withAttributes: attrs)
        ctx.restoreGState()
    }

    /// A gap between two layers, shaded in a fine pink hatch, as gaps of one width are while
    /// something is moved.
    private func hatch(_ r: CGRect, ctx: CGContext, scale: CGFloat, grow: CGFloat) {
        guard r.width > 0.5, r.height > 0.5 else { return }
        let ink = CanvasInk.gap
        ctx.saveGState()
        ctx.setAlpha(min(max(grow, 0), 1))
        ctx.clip(to: r)
        ctx.setFillColor(ink.withAlphaComponent(0.07).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(ink.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1 / scale)
        var x = r.minX - r.height
        while x < r.maxX {
            ctx.move(to: CGPoint(x: x, y: r.maxY))
            ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 4
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Copying what is inspected: words and code as text, a layer as a picture or a drawing.
@MainActor
enum InspectCopy {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A layer, or a screen, as a file of the format would hold it, on the pasteboard: a PNG as a
    /// picture, an SVG as its text too, so that it pastes into code.
    static func picture(of id: UUID, as format: ExportFormat, scale: CGFloat, store: DocumentStore) {
        guard let data = file(of: id, as: format, scale: scale, store: store) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch format {
        case .svg:
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.svg-image"))
            pb.setString(String(decoding: data, as: UTF8.self), forType: .string)
        case .pdf:
            pb.setData(data, forType: .pdf)
        default:
            pb.setData(data, forType: .png)
        }
    }

    /// What is exported of a layer: the item, drawn as the design is seen.
    static func item(_ id: UUID, store: DocumentStore) -> ExportItem? {
        let seen = store.seenDoc
        guard let n = seen.node(id) else { return nil }
        return n.isArtboard ? ExportItem(artboard: n) : ExportItem(layer: id, in: seen)
    }

    /// The bytes of a layer as a file of the format.
    static func file(of id: UUID, as format: ExportFormat, scale: CGFloat, store: DocumentStore) -> Data? {
        guard let item = item(id, store: store) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-inspect-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ExportFile(items: [item], format: format, size: .scale(Double(scale)), name: item.name)
        guard Exporter.write(file, to: url, quality: Exporter.defaultQuality, assets: store.assets) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A layer written as a file of the format into a folder of its own, named as an export
    /// names it, for dragging out to the Finder or into code.
    static func dragged(_ id: UUID, as format: ExportFormat, scale: CGFloat, store: DocumentStore) -> URL? {
        guard let item = item(id, store: store) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bezzle Inspect/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = ExportSize.scale(Double(scale))
        let name = format.isPicture && scale != 1 ? item.name + size.suffix : item.name
        let file = ExportFile(items: [item], format: format, size: size, name: name.replacingOccurrences(of: "/", with: "-"))
        let url = Exporter.place(of: file, in: folder)
        return Exporter.write(file, to: url, quality: Exporter.defaultQuality, assets: store.assets) ? url : nil
    }
}
