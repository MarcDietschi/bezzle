import AppKit

/// The picture itself as the control, while the Photo card is open and its target is on (else a
/// press on the picture moves it, as on any layer): pointing at it names what is under the
/// pointer, beside it, in a small label with its colour; a drag there changes that. Escape, or
/// the target again, gives the picture back.
///
/// Working on the light, it is a tone: where the picture is deep black, in shadow, in the middle,
/// in highlight or white, and a drag up lightens it, down darkens it. Working on the colour, it is
/// a colour: a drag up gives more of it, down less, sideways turns its hue; on something with
/// hardly any colour, a sideways drag warms or cools the light, and a click makes it neutral grey.
/// Whatever the drag, it is one step to undo, and the card follows it as it goes.
final class DevelopTool {
    private let store: DocumentStore
    /// Draws the canvas again, for what changes here and not in the store.
    var redraw: () -> Void = {}

    init(store: DocumentStore) {
        self.store = store
    }

    /// What a drag on the picture changes.
    enum Target: Equatable {
        case tone(Develop.Setting)
        case band(Develop.Band)
        /// Something with hardly any colour of its own.
        case neutral

        var action: LocalizedStringResource {
            switch self {
            case .tone(let s): s.title
            case .band(let b): b.title
            case .neutral: "Set White Balance"
            }
        }

        /// Whether the way the drag sets off decides what it changes.
        var turns: Bool { if case .tone = self { false } else { true } }
    }

    /// A selected picture, and the ways from the screen to across and down it.
    private struct Look {
        let id: UUID
        let node: Node
        let image: ImageFill
        let frame: CGRect
        let viewport: Viewport

        /// From the layer's own coordinates, its top left at zero, to the screen.
        var toView: CGAffineTransform {
            CGAffineTransform(translationX: frame.midX, y: frame.midY)
                .rotated(by: Geometry.radians(node.rotation))
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                .concatenating(CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom).translatedBy(x: -viewport.origin.x, y: -viewport.origin.y))
        }

        /// Where a point on screen is across and down the picture, when it is on the layer.
        func unit(_ v: CGPoint) -> CGPoint? {
            let local = v.applying(toView.inverted())
            guard Renderer.outline(of: node).contains(local) else { return nil }
            let u = local.applying(image.placing(in: frame.size).inverted())
            return (0...1).contains(u.x) && (0...1).contains(u.y) ? u : nil
        }
    }

    /// Whether the picture is the control just now: the Photo card open on its light or colour
    /// with its target on, and nothing else going on on the canvas.
    private var working: Bool {
        store.developOnPhoto && store.openAspect == .photo && store.developGroup != .detail && store.tool == .select
            && store.editingPicture == nil && store.editingPath == nil && store.editingText == nil && store.building == nil
    }

    private func look(at v: CGPoint) -> (Look, CGPoint)? {
        guard working else { return nil }
        for id in store.selection.reversed() {
            guard let node = store.node(id), DocumentStore.develops(node), !node.locked, let image = node.fill.image,
                  let frame = store.doc.absoluteFrame(of: id) else { continue }
            let look = Look(id: id, node: node, image: image, frame: frame, viewport: store.viewport)
            if let u = look.unit(v) { return (look, u) }
        }
        return nil
    }

    // MARK: What is under the pointer

    /// The pointer on a picture: where, the colour there as it is shown, and what a drag would change.
    private struct Point {
        let view: CGPoint
        let color: SIMD3<Double>
        let target: Target
    }

    private var pointed: Point?
    private var shownAt: CFTimeInterval = 0

    /// Each picture, developed as it is now, small: what the pointer reads its colour from.
    private var read: (key: String, develop: Develop?, pixels: Pixels)?

    private func color(of look: Look, at unit: CGPoint) -> SIMD3<Double>? {
        let key = look.image.shown
        if read?.key != key || read?.develop != look.image.develop {
            guard let source = store.developSource(look.node),
                  let px = Pixels(Developer.developed(source, look.image.develop), longest: 256) else { return nil }
            read = (key, look.image.develop, px)
        }
        // A small patch round the point, not one pixel: a leaf in shadow is green, though the
        // darkest pixel of it may be nearly grey.
        guard let px = read?.pixels else { return nil }
        var sum = SIMD3<Double>(), count = 0.0
        for dy in -2...2 {
            for dx in -2...2 {
                let u = CGPoint(x: unit.x + CGFloat(dx) / CGFloat(px.width), y: unit.y + CGFloat(dy) / CGFloat(px.height))
                guard let c = px.color(at: u), c.w > 0.3 else { continue }
                sum += PointMap.decode(SIMD3(c.x, c.y, c.z))
                count += 1
            }
        }
        return count > 0 ? PointMap.encode(sum / count) : nil
    }

    /// What a colour is to work on: its tone, or its colour.
    private func target(for color: SIMD3<Double>) -> Target {
        if store.developGroup == .color {
            let (h, s) = PointMap.hueAndSaturation(color)
            guard s > 0.12 else { return .neutral }
            let (i, share) = Develop.Band.split(hue: h)
            let bands = Develop.Band.allCases
            return .band(share >= 0.5 ? bands[i] : bands[(i + 1) % bands.count])
        }
        let l = PointMap.encode(PointMap.norm(PointMap.decode(color)))
        return .tone(ToneTerrain.zones.first { $0.1.contains(CGFloat(min(max(l, 0), 1))) }?.0 ?? .exposure)
    }

    func hover(at v: CGPoint?) {
        guard drag == nil else { return }
        var next: Point?
        if let v, let (look, unit) = look(at: v), let c = color(of: look, at: unit) {
            next = Point(view: v, color: c, target: target(for: c))
        }
        if (next == nil) != (pointed == nil) { shownAt = CACurrentMediaTime() }
        if next != nil || pointed != nil {
            pointed = next
            redraw()
        }
        point(next?.target)
    }

    /// Tells the card what the pointer is on, when that changes.
    private func point(_ target: Target?) {
        let pointed: Develop.Isolation? = switch target {
        case .tone(let s)?: .tone(s)
        case .band(let b)?: .band(b)
        default: nil
        }
        if store.developPointed != pointed { store.developPointed = pointed }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if let drag {
            return drag.axis == .across ? .resizeLeftRight : drag.axis == .down ? .resizeUpDown : .crosshair
        }
        return pointed != nil && look(at: v) != nil ? .crosshair : nil
    }

    // MARK: Dragging

    private enum Axis { case none, across, down }

    private struct Drag {
        let id: UUID
        /// Where the way the drag has come is counted from, and the development there: where it
        /// began, or where Option was last pressed or let go, so going slower never jumps.
        var start: CGPoint
        let target: Target
        let color: SIMD3<Double>
        var from: Develop
        var slow = false
        var axis: Axis = .none
        var moved = false
    }

    private var drag: Drag?
    var dragging: Bool { drag != nil }

    /// A press on a selected picture while it is the control.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard event.clickCount < 2, let (look, unit) = look(at: v), let c = color(of: look, at: unit) else { return false }
        let target = target(for: c)
        drag = Drag(id: look.id, start: v, target: target, color: c, from: look.image.develop ?? Develop())
        pointed = Point(view: v, color: c, target: target)
        if case .band(let b) = target { store.developBand = b }
        redraw()
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard var d = drag else { return }
        if !d.moved {
            guard hypot(v.x - d.start.x, v.y - d.start.y) >= 3 else { return }
            d.moved = true
            store.beginGesture()
        }
        // A colour is turned or strengthened, one or the other, by which way the drag set off.
        if d.axis == .none {
            let dx = v.x - d.start.x, dy = v.y - d.start.y
            if !d.target.turns { d.axis = .down } else if hypot(dx, dy) >= 6 { d.axis = abs(dx) > abs(dy) ? .across : .down }
        }
        // Option goes slower from here on, and back again from where it is let go.
        if flags.contains(.option) != d.slow {
            d.slow.toggle()
            d.start = v
            d.from = store.node(d.id)?.fill.image?.develop ?? d.from
        }
        drag = d
        let dx = Double(v.x - d.start.x), up = Double(d.start.y - v.y)
        let slow = d.slow ? 0.25 : 1
        let from = d.from, target = d.target, axis = d.axis
        store.develop(target.action) { dev in
            switch target {
            case .tone(let s):
                // Exposure counted in fewer stops: the picture's whole light is a lot to move at once.
                let span = s == .exposure ? 4 : s.range.upperBound - s.range.lowerBound
                dev[s] = from[s] + up / 320 * span * slow
            case .band(let b):
                var shift = from[b]
                if axis == .across { shift.hue = from[b].hue + dx / 160 * 100 * slow }
                if axis == .down { shift.saturation = from[b].saturation + up / 160 * 100 * slow }
                dev[b] = shift
            case .neutral:
                // Sideways warmer or cooler, up towards magenta and down towards green.
                if axis == .across { dev[.temperature] = from[.temperature] + dx / 320 * 200 * slow }
                if axis == .down { dev[.tint] = from[.tint] + up / 320 * 200 * slow }
            }
        }
        pointed = Point(view: v, color: d.color, target: d.target)
        redraw()
    }

    /// Escape: a drag going on is taken back, else the picture stops being the control. Whether
    /// there was either.
    func cancel() -> Bool {
        if let d = drag {
            drag = nil
            if d.moved { store.cancelGesture() }
            pointed = nil
            redraw()
            return true
        }
        guard store.developOnPhoto else { return false }
        store.developOnPhoto = false
        pointed = nil
        point(nil)
        redraw()
        return true
    }

    func up(at v: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        if d.moved {
            store.endGesture(d.target.action)
        } else if d.target == .neutral {
            // A click on something without colour of its own: it becomes neutral grey.
            store.neutralize(d.color)
        }
        hover(at: v)
    }

    // MARK: Drawing

    var animating: Bool { CACurrentMediaTime() - shownAt < Self.appear }
    private static let appear: CFTimeInterval = 0.18

    private func title(_ target: Target) -> String {
        switch target {
        case .tone(let s): String(localized: s.title)
        case .band(let b): String(localized: b.title)
        case .neutral: drag?.moved == true ? String(localized: drag?.axis == .down ? Develop.Setting.tint.title : Develop.Setting.temperature.title)
            : String(localized: "Click to make neutral")
        }
    }

    private func amount(_ target: Target) -> String? {
        guard let drag, drag.moved else { return nil }
        let d = store.node(drag.id)?.fill.image?.develop ?? Develop()
        let v: Double, decimals: Int
        switch target {
        case .tone(let s): v = d[s]; decimals = s == .exposure ? 2 : 0
        case .band(let b): v = drag.axis == .across ? d[b].hue : d[b].saturation; decimals = 0
        case .neutral: v = drag.axis == .down ? d[.tint] : d[.temperature]; decimals = 0
        }
        return v == 0 ? "0" : v.formatted(.number.precision(.fractionLength(decimals)).sign(strategy: .always(includingZero: false)))
    }

    /// A ring where the colour is read, and beside it the label: the colour, what it is, and
    /// while dragging, how much.
    func draw(_ ctx: CGContext, scale: CGFloat) {
        guard let p = pointed, working else { return }
        let t = min(max((CACurrentMediaTime() - shownAt) / Self.appear, 0), 1)
        let grow = 1 - pow(1 - t, 3)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(grow))

        // The ring, light and dark so it shows on any picture.
        let ring = CGRect(x: p.view.x - 7, y: p.view.y - 7, width: 14, height: 14)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        ctx.strokeEllipse(in: ring)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(.white)
        ctx.strokeEllipse(in: ring)

        // The label.
        let words = NSAttributedString(string: title(p.target), attributes: [.font: Self.font, .foregroundColor: Self.ink])
        let number = amount(p.target).map { NSAttributedString(string: $0, attributes: [.font: Self.numberFont, .foregroundColor: Self.pencil]) }
        let ws = words.size(), ns = number?.size() ?? .zero
        let h: CGFloat = 24, swatch: CGFloat = 12
        let w = 8 + swatch + 7 + ws.width + (number != nil ? 6 + ns.width : 0) + 10
        var origin = CGPoint(x: p.view.x + 14, y: p.view.y + 12)
        if origin.x + w > ctx.boundingBoxOfClipPath.maxX - 8 { origin.x = p.view.x - 14 - w }
        let lift = (1 - CGFloat(grow)) * 4
        let box = CGRect(x: origin.x, y: origin.y + lift, width: w, height: h)
        let pill = CGPath(roundedRect: box, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(pill)
        ctx.setFillColor(Self.paper.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(pill)
        ctx.setStrokeColor(Self.hairline.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        let dot = CGRect(x: box.minX + 8, y: box.midY - swatch / 2, width: swatch, height: swatch)
        let c = p.color
        ctx.setFillColor(CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1))
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15))
        ctx.setLineWidth(0.75)
        ctx.strokeEllipse(in: dot)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        words.draw(at: CGPoint(x: dot.maxX + 7, y: box.midY - ws.height / 2))
        number?.draw(at: CGPoint(x: dot.maxX + 7 + ws.width + 6, y: box.midY - ns.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let ink = Theme.dynamicNS(0x1C1B19, 0xEDEAE4)
    private static let paper = Theme.dynamicNS(0xFCFBF8, 0x2A2926)
    private static let hairline = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.12, darkAlpha: 0.14)
    private static let pencil = Theme.dynamicNS(0x3559C7, 0x8FA8F2)
}
