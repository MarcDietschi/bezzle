import AppKit

/// Placing a picture inside the layer it fills: double-click the layer, or select it and press
/// Return. The whole picture shows, faded where it reaches past the layer's outline, which is what
/// cuts it off, with crop marks at its corners. Drag the picture to move it, or a corner to make it
/// bigger or smaller about the corner across, or about its middle with Option; Shift keeps a move
/// straight across or down. Its middle catches on the layer's middle. It keeps its proportions and
/// always covers the layer: pulled too far, it gives a little, as on elastic, and springs back when
/// let go. The arrow keys move it a point at a time, ten with Shift. Return, Escape, a double click
/// on it or a click anywhere else ends placing.
final class PictureTool {
    private let store: DocumentStore
    /// Draws the canvas again, for what changes here and not in the store: the guides, the fades.
    var redraw: () -> Void = {}
    /// Told of a click on the picture, rather than a drag, where it was on screen.
    var clicked: (CGPoint) -> Void = { _ in }

    init(store: DocumentStore) {
        self.store = store
    }

    /// The layer being placed in, and the ways between its own coordinates and the screen.
    private struct Look {
        let id: UUID
        let node: Node
        let image: ImageFill
        /// The layer's frame on the canvas.
        let frame: CGRect
        let viewport: Viewport

        var size: CGSize { frame.size }
        /// Where the picture lies in the layer.
        var rect: CGRect { Renderer.imageRect(image, in: size) }

        /// From the layer's own coordinates, its top left at zero, to the screen.
        var toView: CGAffineTransform {
            CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: Geometry.radians(node.rotation))
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom).translatedBy(x: -viewport.origin.x, y: -viewport.origin.y))
        }

        func view(_ p: CGPoint) -> CGPoint { p.applying(toView) }
        func local(_ v: CGPoint) -> CGPoint { v.applying(toView.inverted()) }

        /// A corner of `rect` in the layer's coordinates.
        func point(_ corner: Handle, of rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + corner.unit.x * rect.width, y: rect.minY + corner.unit.y * rect.height)
        }

        /// Where the picture lies once it covers the layer, for one shown whole or squeezed to it:
        /// as small as covering takes, about the same middle.
        var coverRect: CGRect {
            let r = rect
            guard image.mode != .cover else { return r }
            let w = image.coverWidth(in: size)
            return ImageFill.covering(CGRect(center: r.center, size: CGSize(width: w, height: image.height(forWidth: w))), in: size)
        }
    }

    private var look: Look? {
        guard let id = store.editingPicture, let node = store.node(id), node.fill.on, let image = node.fill.image,
              !node.locked, let frame = store.doc.absoluteFrame(of: id) else { return nil }
        return Look(id: id, node: node, image: image, frame: frame, viewport: store.viewport)
    }

    private enum Drag {
        /// Moving the picture from where it lay; the press was at `start`, in the layer's coordinates.
        case move(start: CGPoint, from: CGRect)
        /// Resizing it by a corner, about the corner across, or its middle with Option.
        case resize(corner: Handle, from: CGRect)
    }

    private var drag: Drag?
    /// Whether the press has gone far enough to be a drag, and so begun a gesture.
    private var moved = false
    private var downView: CGPoint = .zero
    /// Where the picture comes to rest when let go, which is short of where it was pulled to
    /// when that would leave an edge of the layer showing.
    private var rest: CGRect?
    /// Springing back to rest once let go: from where to where, since when, and what it last set.
    private var settling: (id: UUID, from: CGRect, to: CGRect, began: CFTimeInterval, action: LocalizedStringResource, last: ImageFill?)?
    private var settleTimer: Timer?
    /// Whether the picture's middle has caught on the layer's, across and down, for the guides.
    private var caught = (x: false, y: false)
    /// The layer whose picture shows, and since when, as it fades in; the one that showed before,
    /// as it fades out.
    private var shown: (id: UUID, since: CFTimeInterval)?
    private var lastLook: Look?
    private var leaving: (look: Look, since: CFTimeInterval)?
    private var deviceScale: CGFloat = 2

    private static let corners: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    /// How near a corner a press takes hold of it, on screen.
    private static let reach: CGFloat = 11
    /// How far the elastic lets the picture go past covering, at most, on screen.
    private static let give: CGFloat = 120
    private static let fadeIn: CFTimeInterval = 0.22
    private static let fadeOut: CFTimeInterval = 0.16
    private static let settleTime: CFTimeInterval = 0.38
    /// How much of the picture past the layer shows, faded.
    private static let ghost: CGFloat = 0.42

    var dragging: Bool { drag != nil }

    /// Whether the canvas has to draw again soon, for a fade in progress.
    var animating: Bool {
        let now = CACurrentMediaTime()
        return leaving != nil || shown.map { now - $0.since < Self.fadeIn } == true
    }

    // MARK: - Where things are

    private func corner(at v: CGPoint, _ look: Look) -> Handle? {
        let rect = look.rect
        let near = Self.corners.map { ($0, look.view(look.point($0, of: rect))) }.map { ($0.0, hypot($0.1.x - v.x, $0.1.y - v.y)) }
        return near.filter { $0.1 <= Self.reach }.min { $0.1 < $1.1 }?.0
    }

    private func across(_ corner: Handle) -> Handle {
        switch corner {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomRight: .topLeft
        default: .topRight
        }
    }

    /// The pointer's look over the picture being placed; nil elsewhere, and when nothing is.
    func cursor(at v: CGPoint) -> NSCursor? {
        guard let look else { return nil }
        switch drag {
        case .resize(let corner, _): return Cursors.resize(corner.angle + look.node.rotation)
        case .move: return .closedHand
        case nil: break
        }
        if let corner = corner(at: v, look) { return Cursors.resize(corner.angle + look.node.rotation) }
        return look.rect.contains(look.local(v)) ? .openHand : nil
    }

    // MARK: - The pointer

    /// A press while placing, `clicks` the press's count. Returns whether it was taken here, on the
    /// picture or one of its corners; anywhere else placing ends, and the press goes on as usual.
    func down(at v: CGPoint, clicks: Int) -> Bool {
        finishSettling()
        guard let look else { return false }
        downView = v
        moved = false
        if let corner = corner(at: v, look) {
            drag = .resize(corner: corner, from: look.rect)
            return true
        }
        let p = look.local(v)
        guard look.rect.contains(p) else { return false }
        if clicks >= 2 {
            store.editingPicture = nil
            return true
        }
        drag = .move(start: p, from: look.rect)
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard var drag, let look else { return }
        if !moved {
            guard hypot(v.x - downView.x, v.y - downView.y) > 2 else { return }
            moved = true
            store.beginGesture()
            // A picture shown whole, or squeezed to the layer, covers it from the first move on.
            if look.image.mode != .cover {
                switch drag {
                case .move(let start, _): drag = .move(start: start, from: look.coverRect)
                case .resize(let corner, _): drag = .resize(corner: corner, from: look.coverRect)
                }
                self.drag = drag
            }
            if case .move = drag { NSCursor.closedHand.set() }
        }
        let size = look.size, zoom = look.viewport.zoom
        let p = look.local(v)
        switch drag {
        case .move(let start, let from):
            var dx = p.x - start.x, dy = p.y - start.y
            if flags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            var r = from.offsetBy(dx: dx, dy: dy)
            // Its middle catches on the layer's, five points either side on screen, along a side
            // it has room to move along. Command moves it freely.
            let near = 5 / zoom, snaps = !flags.contains(.command)
            caught = (snaps && r.width - size.width > 0.5 && abs(r.midX - size.width / 2) < near,
                      snaps && r.height - size.height > 0.5 && abs(r.midY - size.height / 2) < near)
            if caught.x { r.origin.x = (size.width - r.width) / 2 }
            if caught.y { r.origin.y = (size.height - r.height) / 2 }
            // Past covering, it gives as on elastic, less the further it is pulled.
            let settled = ImageFill.covering(r, in: size)
            var shown = settled
            shown.origin.x += ImageFill.elastic(r.minX - settled.minX, reach: min(Self.give / zoom, size.width / 2))
            shown.origin.y += ImageFill.elastic(r.minY - settled.minY, reach: min(Self.give / zoom, size.height / 2))
            rest = settled
            set(shown, look, "Move Picture")
            store.measurement = nil

        case .resize(let corner, let from):
            let anchor = flags.contains(.option) ? from.center : look.point(across(corner), of: from)
            let grabbed = look.point(corner, of: from)
            // As far out as the pointer has gone along either side, the proportions kept.
            let kx = grabbed.x != anchor.x ? (p.x - anchor.x) / (grabbed.x - anchor.x) : 0
            let ky = grabbed.y != anchor.y ? (p.y - anchor.y) / (grabbed.y - anchor.y) : 0
            let wanted = from.width * max(kx, ky, 0)
            // Never smaller than covering takes; pushed smaller, it gives as on elastic.
            let least = look.image.coverWidth(in: size)
            let width = wanted >= least ? wanted : least - ImageFill.elastic(least - wanted, reach: min(Self.give / zoom, least / 2))
            func scaled(_ w: CGFloat) -> CGRect {
                let s = from.width > 0 ? w / from.width : 1
                return CGRect(x: anchor.x + (from.minX - anchor.x) * s, y: anchor.y + (from.minY - anchor.y) * s,
                              width: w, height: from.height * s)
            }
            rest = ImageFill.covering(scaled(max(wanted, least)), in: size)
            caught = (false, false)
            set(ImageFill.covering(scaled(width), in: size), look, "Resize Picture")
            let bounds = Geometry.bounds(of: look.frame, rotation: look.node.rotation)
            store.measurement = ("\(Int((max(wanted, least) / least * 100).rounded()))%", bounds)
        }
    }

    func up() {
        guard let drag else { return }
        self.drag = nil
        caught = (false, false)
        store.measurement = nil
        defer {
            rest = nil
            redraw()
        }
        guard moved, let look else {
            // A click on the picture: a cut-out picture's subjects are kept or dropped so.
            if !moved, case .move = drag { clicked(downView) }
            return
        }
        let action: LocalizedStringResource = if case .resize = drag { "Resize Picture" } else { "Move Picture" }
        // Let go past covering, it springs back; the gesture ends once it is there.
        if let rest, !Self.same(rest, look.rect) {
            settling = (look.id, look.rect, rest, CACurrentMediaTime(), action, look.image)
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleStep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        } else {
            store.endGesture(action)
        }
    }

    private func cancelDrag() {
        if moved { store.cancelGesture() }
        drag = nil
        rest = nil
        caught = (false, false)
        store.measurement = nil
        redraw()
    }

    private func settleStep() {
        guard let s = settling else { return }
        // Something else changed the picture meanwhile, such as an undo: it is left as it is.
        guard let node = store.node(s.id), node.fill.image == s.last else { return finishSettling(placing: false) }
        let t = min((CACurrentMediaTime() - s.began) / Self.settleTime, 1)
        guard t < 1 else { return finishSettling() }
        // A spring that comes to rest without going past it: quick to leave, slow to arrive.
        let k = 1 - (1 + 10 * t) * exp(-10 * t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(k) }
        let r = CGRect(x: mix(s.from.minX, s.to.minX), y: mix(s.from.minY, s.to.minY),
                       width: mix(s.from.width, s.to.width), height: mix(s.from.height, s.to.height))
        settling?.last = set(r, of: s.id, s.action)
    }

    /// Brings a picture springing back straight to rest, and ends its gesture: when it gets there,
    /// or when something else wants the canvas first.
    func finishSettling() { finishSettling(placing: true) }

    private func finishSettling(placing: Bool) {
        guard let s = settling else { return }
        settling = nil
        settleTimer?.invalidate()
        settleTimer = nil
        if placing { set(s.to, of: s.id, s.action) }
        store.endGesture(s.action)
    }

    // MARK: - Placing

    @discardableResult
    private func set(_ rect: CGRect, _ look: Look, _ action: LocalizedStringResource) -> ImageFill? {
        set(rect, of: look.id, action)
    }

    /// Puts the picture at `rect` in its layer, and returns it as it now is.
    @discardableResult
    private func set(_ rect: CGRect, of id: UUID, _ action: LocalizedStringResource) -> ImageFill? {
        guard let node = store.node(id), let image = node.fill.image else { return nil }
        let placed = image.placed(at: rect, in: node.frame.size)
        store.edit(action) { doc in doc.update(id) { $0.fill.image = placed } }
        return placed
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
    }

    /// Moves the picture by `dx` and `dy` across and down the screen, whichever way the layer is
    /// turned, as far as it still covers the layer.
    private func nudge(_ dx: CGFloat, _ dy: CGFloat, _ look: Look) {
        let d = Geometry.rotate(CGPoint(x: dx, y: dy), by: -look.node.rotation)
        set(ImageFill.covering(look.coverRect.offsetBy(dx: d.x, dy: d.y), in: look.size), look, "Move Picture")
    }

    // MARK: - Keys

    /// A key while placing, or Return on a selected picture, which starts placing it.
    func key(_ event: NSEvent) -> Bool {
        finishSettling()
        let code = event.keyCode
        let escape = code == 53, enter = code == 36 || code == 76
        if drag != nil {
            if escape { cancelDrag(); return true }
            return false
        }
        if store.editingPicture != nil {
            guard let look else {
                store.editingPicture = nil
                return false
            }
            if escape || enter {
                store.editingPicture = nil
                return true
            }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch code {
            case 123: nudge(-step, 0, look)
            case 124: nudge(step, 0, look)
            case 125: nudge(0, step, look)
            case 126: nudge(0, -step, look)
            default: return false
            }
            return true
        }
        if enter, store.tool == .select, store.editingPath == nil, store.canEditPicture {
            store.editPicture()
            return true
        }
        return false
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        let now = CACurrentMediaTime()
        let current = look
        if current?.id != shown?.id {
            if shown != nil, let was = lastLook { leaving = (was, now) }
            shown = current.map { ($0.id, now) }
        }
        lastLook = current ?? lastLook
        if let (was, since) = leaving {
            let t = (now - since) / Self.fadeOut
            if t >= 1 { leaving = nil } else { paint(was, CGFloat(1 - t) * CGFloat(1 - t), ctx) }
        }
        if let current, let shown {
            let t = min((now - shown.since) / Self.fadeIn, 1)
            paint(current, CGFloat(1 - pow(1 - t, 3)), ctx)
        }
    }

    /// The picture past the layer, faded; the layer's outline; the picture's edge, and crop marks
    /// at its corners. All at `alpha`, as it fades in or out.
    private func paint(_ look: Look, _ alpha: CGFloat, _ ctx: CGContext) {
        let rect = look.rect, toView = look.toView
        let outline = Renderer.outline(of: look.node)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)

        let pixels = max(rect.width, rect.height) * look.viewport.zoom * deviceScale
        // The whole picture, even one cut out: what lies past the layer is placed with the rest.
        if let picture = store.assets.image(look.image.asset, pixels: pixels).map({ Developer.developed($0, look.image.develop) }) {
            ctx.saveGState()
            ctx.concatenate(toView)
            // Only what lies past the outline: inside it, the layer shows the picture itself.
            ctx.addRect(rect)
            ctx.addPath(outline)
            ctx.clip(using: .evenOdd)
            ctx.setAlpha(alpha * Self.ghost)
            ctx.interpolationQuality = .high
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: look.image.flippedX == true ? -1 : 1, y: look.image.flippedY == true ? 1 : -1)
            ctx.draw(picture, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }

        // The picture's edge: a fine white line on a dark one, to show over anything.
        let corners = Self.corners.map { look.view(look.point($0, of: rect)) }
        let edge = CGMutablePath()
        edge.addLines(between: corners)
        edge.closeSubpath()
        ctx.addPath(edge)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.addPath(edge)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // The layer's own outline, which cuts the picture off.
        var t = toView
        if let placed = outline.copy(using: &t) {
            ctx.addPath(placed)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        // Where the picture's middle caught on the layer's: a guide through the middle.
        if caught.x || caught.y, look.id == store.editingPicture {
            let guides = CGMutablePath()
            let s = look.size
            if caught.x { guides.addLines(between: [look.view(CGPoint(x: s.width / 2, y: 0)), look.view(CGPoint(x: s.width / 2, y: s.height))]) }
            if caught.y { guides.addLines(between: [look.view(CGPoint(x: 0, y: s.height / 2)), look.view(CGPoint(x: s.width, y: s.height / 2))]) }
            ctx.addPath(guides)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // Crop marks: an L at each corner along the picture's edges, white on a dark edge with a
        // soft shadow, to show over a light table and a dark picture alike.
        let marks = CGMutablePath()
        for (i, c) in corners.enumerated() {
            let next = corners[(i + 1) % 4], previous = corners[(i + 3) % 4]
            let arm = min(15, hypot(next.x - c.x, next.y - c.y) * 0.3, hypot(previous.x - c.x, previous.y - c.y) * 0.3)
            func toward(_ q: CGPoint) -> CGPoint {
                let d = hypot(q.x - c.x, q.y - c.y)
                return d > 0 ? CGPoint(x: c.x + (q.x - c.x) / d * arm, y: c.y + (q.y - c.y) / d * arm) : c
            }
            marks.move(to: toward(next))
            marks.addLine(to: c)
            marks.addLine(to: toward(previous))
        }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 3 * deviceScale, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(marks)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(marks)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
