import AppKit

/// Turning layers in depth straight on the canvas, with no axis to think of.
///
/// Aiming: a layer turned in depth shows which way its face points, as a knob on a short stalk
/// from its middle; pointing at the knob shows the ring where the face would be seen edge on.
/// Dragging the knob turns the face to follow it, as a head turns where its nose is led. With
/// Option, up and down bring it nearer or push it away instead. Passing face on, it settles flat;
/// Shift turns in steps of 15°; a double click lays it flat again.
///
/// Turning: just outside a corner the pointer turns a layer in the page; just outside the middle
/// of a side, it turns it in depth, flat or not. A drag there turns it as a ball turns under the
/// hand, its face toward where the pointer goes, as the knob does. Every layer picked turns
/// alike, each about its own middle.
final class DepthTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}
    /// What a click at a canvas point picks, as the canvas would pick it.
    var pick: (CGPoint) -> UUID? = { _ in nil }

    private enum Drag {
        /// `grip` is from the pointer to the knob's middle, so the knob does not jump to it.
        case aim(id: UUID, center: CGPoint, grip: CGPoint, original: Transform3D, start: CGPoint)
        case turn(originals: [UUID: Transform3D], center: CGPoint, radius: CGFloat, start: CGPoint, started: Bool)
    }

    private var drag: Drag?
    /// Whether the pointer is on the knob, so the ring shows.
    private var onKnob = false
    private var deviceScale: CGFloat = 2
    /// How far from the middle, on screen, the knob is when the face is seen edge on.
    static let reach: CGFloat = 36

    init(store: DocumentStore) {
        self.store = store
    }

    var dragging: Bool { drag != nil }

    private var zoom: CGFloat { store.viewport.zoom }
    private func view(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }

    /// The layers picked that can be turned in depth: not artboards, which are the page, nor locked ones.
    private var turnable: [Node] {
        store.selection.compactMap { store.node($0) }.filter { !$0.isArtboard && !$0.locked }
    }

    /// The one selected layer turned in depth, when the select tool is free to work on it.
    private var single: (node: Node, turn: Transform3D)? {
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.editingPicture == nil,
              store.building == nil, store.selection.count == 1, let n = store.node(store.selection[0]), !n.locked,
              !n.isArtboard, let turn = n.transform3D else { return nil }
        return (n, turn)
    }

    /// The selected layer's middle on screen and its knob, where its face points; none on a
    /// layer too small on screen to hold a knob clear of its handles.
    private func knob() -> (center: CGPoint, knob: CGPoint)? {
        guard let (n, turn) = single else { return nil }
        let shown = Geometry.bounds(of: n)
        guard max(shown.width, shown.height) * zoom >= 40 else { return nil }
        let c = view(store.doc.shown(n.frame.center, inParentOf: n.id))
        let f = Self.facing(turn)
        return (c, CGPoint(x: c.x + f.x * Self.reach, y: c.y + f.y * Self.reach))
    }

    // MARK: - Which way a face points

    /// Where a turned face points, seen from in front: across and down, each from -1 to 1.
    static func facing(_ t: Transform3D) -> CGPoint {
        let a = t.x * .pi / 180, b = t.y * .pi / 180
        return CGPoint(x: sin(b), y: -sin(a) * cos(b))
    }

    /// The turn that points a face there, the other way; no further round than 85°, short of edge on.
    static func turn(facing d: CGPoint) -> (x: Double, y: Double) {
        var d = d
        let length = hypot(d.x, d.y), most = sin(85 * CGFloat.pi / 180)
        if length > most { d = CGPoint(x: d.x / length * most, y: d.y / length * most) }
        let b = asin(d.x)
        let a = asin(min(max(-d.y / cos(b), -1), 1))
        return (Double(a) * 180 / .pi, Double(b) * 180 / .pi)
    }

    /// Steps of 15° with Shift; and face on, or nearly, flat in the page.
    static func settled(_ x: Double, _ y: Double, steps: Bool) -> (x: Double, y: Double) {
        if steps { return (((x / 15).rounded() * 15), ((y / 15).rounded() * 15)) }
        if hypot(x, y) < 3 { return (0, 0) }
        return ((x * 10).rounded() / 10, (y * 10).rounded() / 10)
    }

    /// Degrees between -180 and 180.
    private static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    // MARK: - The pointer

    /// A press with the select tool on a turned layer's knob. False leaves it to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        if let k = knob(), let (n, turn) = single, hypot(k.knob.x - v.x, k.knob.y - v.y) <= 9 {
            if event.clickCount >= 2 {
                store.update([n.id], "Lay Flat") { $0.transform3D = Transform3D() }
                return true
            }
            store.beginGesture()
            drag = .aim(id: n.id, center: k.center, grip: CGPoint(x: k.knob.x - v.x, y: k.knob.y - v.y), original: turn, start: v)
            return true
        }
        return false
    }

    /// A press just outside the middle of a side of what is picked: turning it in depth, once the
    /// pointer moves.
    func startTurn(at v: CGPoint) {
        let nodes = turnable
        guard !nodes.isEmpty, let box = store.selectionBounds else { return }
        var originals: [UUID: Transform3D] = [:]
        for n in nodes { originals[n.id] = n.transform3D ?? Transform3D() }
        // A ball as big as what is picked, and never so small on screen that it spins away. One
        // layer is turned about its own middle, wherever a group turned in depth shows it.
        let center = nodes.count == 1 ? view(store.doc.shown(nodes[0].frame.center, inParentOf: nodes[0].id)) : view(box.center)
        let radius = max(max(box.width, box.height) * zoom / 2, 60)
        drag = .turn(originals: originals, center: center, radius: radius, start: v, started: false)
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        let shift = flags.contains(.shift)
        switch drag {
        case nil:
            return
        case .aim(let id, let center, let grip, let original, let start):
            var next = original
            if flags.contains(.option) {
                // Up is nearer, as far as the pointer goes.
                next.z = (original.z + (start.y - v.y) / zoom).rounded()
            } else {
                let at = CGPoint(x: v.x + grip.x - center.x, y: v.y + grip.y - center.y)
                let (x, y) = Self.turn(facing: CGPoint(x: at.x / Self.reach, y: at.y / Self.reach))
                (next.x, next.y) = Self.settled(x, y, steps: shift)
            }
            store.edit("Turn in Depth") { doc in doc.update(id) { $0.transform3D = next } }
            show(next, of: [id], depth: flags.contains(.option))

        case .turn(let originals, let center, let radius, let start, let started):
            if !started {
                guard hypot(v.x - start.x, v.y - start.y) > 3 else { return }
                store.beginGesture()
                drag = .turn(originals: originals, center: center, radius: radius, start: start, started: true)
            }
            // Round a ball under the hand, and on past its rim as far as the pointer goes.
            func around(_ s: CGFloat) -> CGFloat { abs(s) <= 1 ? asin(s) : (s > 0 ? 1 : -1) * (.pi / 2 + abs(s) - 1) }
            var swing = Double(around((v.x - center.x) / radius) - around((start.x - center.x) / radius)) * 180 / .pi
            var tip = -Double(around((v.y - center.y) / radius) - around((start.y - center.y) / radius)) * 180 / .pi
            if shift { if abs(swing) > abs(tip) { tip = 0 } else { swing = 0 } }
            var last = Transform3D()
            store.edit("Turn in Depth") { doc in
                for (id, original) in originals {
                    var next = original
                    (next.x, next.y) = Self.settled(Self.normalized(original.x + tip), Self.normalized(original.y + swing), steps: shift)
                    last = next
                    doc.update(id) { $0.transform3D = next }
                }
            }
            show(originals.count == 1 ? last : nil, of: Array(originals.keys), depth: false)
        }
        redraw()
    }

    /// How far it is turned, beside it, while it turns.
    private func show(_ turn: Transform3D?, of ids: [UUID], depth: Bool) {
        let box = ids.compactMap { id in store.node(id).map { Geometry.bounds(of: $0).offsetBy(dx: store.doc.parentOrigin(of: id).x, dy: store.doc.parentOrigin(of: id).y) } }
            .reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? .zero
        guard let turn else { store.measurement = (String(localized: "Turning \(ids.count) layers"), box); return }
        store.measurement = (depth ? "Z \(CanvasView.number(turn.z))" : "X \(CanvasView.number(turn.x))°  Y \(CanvasView.number(turn.y))°", box)
    }

    func up(at v: CGPoint, adding: Bool) {
        switch drag {
        case .aim:
            store.endGesture("Turn in Depth")
        case .turn(_, _, _, _, let started):
            if started {
                store.endGesture("Turn in Depth")
            } else if let id = pick(store.viewport.toCanvas(v)) {
                // Only a click, outside what is picked: whatever is there is picked, as anywhere else.
                if adding { if !store.selection.contains(id) { store.selection.append(id) } } else { store.selection = [id] }
            } else if !adding {
                store.selection = []
            }
        case nil:
            return
        }
        drag = nil
        redraw()
    }

    /// Escape during a drag: back as it was.
    func cancel() {
        if case .turn(_, _, _, _, false) = drag {} else { store.cancelGesture() }
        drag = nil
        redraw()
    }

    /// Nil when the pointer has left the canvas.
    func hover(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        let on = v.flatMap { v in knob().map { hypot($0.knob.x - v.x, $0.knob.y - v.y) <= 9 } } ?? false
        if on != onKnob {
            onKnob = on
            redraw()
        }
    }

    var cursor: NSCursor? {
        drag != nil || onKnob ? Cursors.turn : nil
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if case .turn(_, let center, let radius, _, true) = drag {
            // The ball being turned.
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 4])
            ctx.strokeEllipse(in: CGRect(center: center, size: CGSize(width: radius * 2, height: radius * 2)))
            return
        }
        guard let (center, knob) = knob() else { return }
        let aiming: Bool = if case .aim = drag { true } else { false }
        if onKnob || aiming {
            // Where the face would be seen edge on.
            ctx.saveGState()
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [2, 3])
            ctx.strokeEllipse(in: CGRect(center: center, size: CGSize(width: Self.reach * 2, height: Self.reach * 2)))
            ctx.restoreGState()
        }
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1.25)
        ctx.move(to: center)
        ctx.addLine(to: knob)
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(center: center, size: CGSize(width: 4, height: 4)))
        let rect = CGRect(center: knob, size: CGSize(width: 12, height: 12))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.fillEllipse(in: CGRect(center: knob, size: CGSize(width: 4, height: 4)))
    }
}
