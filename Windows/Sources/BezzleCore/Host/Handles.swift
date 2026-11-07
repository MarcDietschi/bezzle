import Foundation

// What the Windows canvas takes hold of besides a handle, as the Mac's canvas does (the shared
// `BezzleDocument.handleHit`): just outside a corner turns the selection in the page, a dot inside
// a selected rectangle's corner rounds the corners, a drag on the layer's shadow moves the shadow,
// and just outside the middle of a side turns it in depth. And the measure the Mac shows under
// what is dragged: its size, its turn, a radius, where a shadow falls.

extension WindowsCore {
    nonisolated public enum Hit: Equatable, Sendable {
        case resize(Int), lineEnd(Int), rotate, corner(Int), shadow, turnInDepth
    }

    /// What the pointer shows over the selection's handles, as the Mac's canvas has it: a resize
    /// arrow along a handle's pull, or the turning arrow at a corner, at angles in degrees
    /// clockwise from across (the selection's turn added); a cross on a line's end or a corner's
    /// dot, the hand on the shadow, turning in depth beside a side.
    nonisolated public enum HandlePointer: Equatable, Sendable {
        case resize(Double), rotate(Double), cross, grab, turn
    }

    /// The pointer over the selection's handles at `v` on the stage, if one is there.
    public static func handlePointer(at v: CGPoint, selection ids: [UUID], zoom: Double, pan: CGPoint, selecting: Bool) -> HandlePointer? {
        guard let doc = design, !ids.isEmpty else { return nil }
        let rotation = doc.handleFrame(of: ids)?.rotation ?? 0
        switch doc.handleHit(at: v, selection: ids, zoom: CGFloat(zoom), toView: toView(zoom: zoom, pan: pan), selecting: selecting, slot: shadowSlot) {
        case .resize(let h)?: return .resize(h.angle + rotation)
        case .rotate(let h)?: return .rotate(h.angle + rotation)
        case .lineEnd?, .corner?: return .cross
        case .shadow?: return .grab
        case .turnInDepth?: return .turn
        case nil: return nil
        }
    }

    /// The shadow card that is open (its slot), whose shadow a drag on the canvas moves.
    nonisolated(unsafe) public static var openShadow: Int?

    static func shadowSlot(_ n: Node) -> Int? { BezzleDocument.shadowSlot(of: n, open: openShadow) }

    private static func toView(zoom: Double, pan: CGPoint) -> (CGPoint) -> CGPoint {
        let z = CGFloat(zoom)
        return { CGPoint(x: pan.x + $0.x * z, y: pan.y + $0.y * z) }
    }

    /// What a press at `v` on the stage (where a canvas point `p` lies at `pan + p · zoom`) takes
    /// hold of; `selecting` is whether the select tool is in hand with nothing being typed.
    public static func hit(at v: CGPoint, selection ids: [UUID], zoom: Double, pan: CGPoint, selecting: Bool) -> Hit? {
        guard let doc = design, !ids.isEmpty else { return nil }
        let found = doc.handleHit(at: v, selection: ids, zoom: CGFloat(zoom), toView: toView(zoom: zoom, pan: pan), selecting: selecting, slot: shadowSlot)
        switch found {
        case .resize(let h)?: return handleOrder.firstIndex(of: h).map { .resize($0) }
        case .lineEnd(let k)?: return .lineEnd(k)
        case .rotate?: return .rotate
        case .corner(let h)?: return BezzleDocument.cornerOrder.firstIndex(of: h).map { .corner($0) }
        case .shadow?: return .shadow
        case .turnInDepth?: return .turnInDepth
        case nil: return nil
        }
    }

    /// The dots inside the selected rectangle's corners, on the stage, for the canvas to draw.
    public static func cornerDots(_ ids: [UUID], zoom: Double, pan: CGPoint) -> [CGPoint] {
        guard let doc = design else { return [] }
        return doc.cornerDots(of: ids, zoom: CGFloat(zoom)).map { toView(zoom: zoom, pan: pan)($0.1) }
    }

    /// Whether the pointer at `v` on the stage is on the selected rectangle, where its dots show.
    public static func onRectangle(_ v: CGPoint, selection ids: [UUID], zoom: Double, pan: CGPoint) -> Bool {
        guard let doc = design, ids.count == 1, let n = doc.node(ids[0]), n.kind == .rectangle, let f = doc.absoluteFrame(of: n.id) else { return false }
        let p = CGPoint(x: (v.x - pan.x) / CGFloat(zoom), y: (v.y - pan.y) / CGFloat(zoom))
        let local = Geometry.local(p, in: f, rotation: n.rotation)
        let reach = 10 / CGFloat(zoom)
        return abs(local.x) <= f.width / 2 + reach && abs(local.y) <= f.height / 2 + reach
    }

    /// Where the selected layer's shadow falls, on the canvas, to outline it while it is pointed at.
    public static func shadowOutline(_ ids: [UUID]) -> [CGPoint]? { design?.shadowCorners(of: ids, slot: shadowSlot) }

    /// Whether the pointer at `v` on the stage is on the selected layer's shadow.
    public static func onShadow(_ v: CGPoint, selection ids: [UUID], zoom: Double, pan: CGPoint) -> Bool {
        guard let doc = design else { return false }
        let p = CGPoint(x: (v.x - pan.x) / CGFloat(zoom), y: (v.y - pan.y) / CGFloat(zoom))
        return doc.isOnShadow(p, selection: ids, zoom: CGFloat(zoom), tolerance: 4 / CGFloat(zoom), slot: shadowSlot)
    }

    // MARK: Turning, rounding, moving a shadow

    /// What a drag holds while it turns, rounds or moves a shadow: as things were when it began.
    private enum Holding {
        case turn(originals: [UUID: Node], absolute: [UUID: CGRect], center: CGPoint, start: Double)
        case corner(id: UUID, frame: CGRect, rotation: Double, corner: Handle, radii: [CGFloat])
        case shadow(id: UUID, slot: Int, start: CGPoint, original: CGPoint)
    }
    nonisolated(unsafe) private static var holding: Holding?
    /// What the drag measures now, and the part of the canvas it measures: shown under it.
    nonisolated(unsafe) public internal(set) static var measure: (text: String, box: CGRect)?

    private static func number(_ v: CGFloat) -> String {
        let r = (Double(v) * 10).rounded() / 10 + 0
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// A turn of the selection begins, about the middle of the box its handles sit on, from
    /// where the pointer is (`p`, on the canvas).
    public static func beginTurn(_ ids: [UUID], at p: CGPoint) {
        guard let doc = design, let (frame, _, _) = doc.handleFrame(of: ids) else { return }
        var originals: [UUID: Node] = [:], absolute: [UUID: CGRect] = [:]
        for id in ids {
            guard let n = doc.node(id), !n.locked, let f = doc.absoluteFrame(of: id) else { continue }
            originals[id] = n
            absolute[id] = f
        }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        holding = .turn(originals: originals, absolute: absolute, center: c, start: Double(atan2(p.y - c.y, p.x - c.x)))
        beginGesture()
    }

    /// A rectangle's corners begin to be rounded by the dot of corner `index` (top left first, clockwise).
    public static func beginCorner(_ id: UUID, corner index: Int) {
        guard let doc = design, let n = doc.node(id), let f = doc.absoluteFrame(of: id), BezzleDocument.cornerOrder.indices.contains(index) else { return }
        holding = .corner(id: id, frame: f, rotation: n.rotation, corner: BezzleDocument.cornerOrder[index], radii: n.radii)
        beginGesture()
    }

    /// The selected layer's shadow begins to be moved, from `p` on the canvas.
    public static func beginShadow(_ id: UUID, at p: CGPoint) {
        guard let n = design?.node(id), let slot = shadowSlot(n) else { return }
        holding = .shadow(id: id, slot: slot, start: p, original: CGPoint(x: n[shadow: slot].x, y: n[shadow: slot].y))
        beginGesture()
    }

    /// The drag goes on to `p` on the canvas: Shift turns in steps of 15°, keeps a shadow to one
    /// axis; Alt rounds only the one corner.
    public static func hold(to p: CGPoint, shift: Bool, option: Bool) {
        switch holding {
        case .turn(let originals, let absolute, let center, let start)?:
            var delta = (Double(atan2(p.y - center.y, p.x - center.x)) - start) * 180 / .pi
            let base = BezzleDocument.turnBase(originals)
            if shift { delta = ((base + delta) / 15).rounded() * 15 - base }
            edit { $0.turn(originals, absolute: absolute, by: delta, about: center) }
            let ids = Array(originals.keys)
            measure = ("\(number(CGFloat(Geometry.normalized(base + delta))))°", design?.selectionFrame(ids) ?? .zero)
        case .corner(let id, let frame, let rotation, let corner, let radii)?:
            let (next, radius) = BezzleDocument.cornerRadii(at: p, frame: frame, rotation: rotation, corner: corner, original: radii, alone: option)
            edit { $0.update(id) { $0.radii = next } }
            measure = ("Radius \(number(radius))", Geometry.bounds(of: frame, rotation: rotation))
        case .shadow(let id, let slot, let start, let original)?:
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            let x = (original.x + dx).rounded(), y = (original.y + dy).rounded()
            edit { $0.update(id) { $0[shadow: slot].x = x; $0[shadow: slot].y = y } }
            if let f = design?.absoluteFrame(of: id) { measure = ("Shadow \(number(x)), \(number(y))", f.offsetBy(dx: x, dy: y)) }
        case nil:
            return
        }
    }

    /// A turn, a corner or a shadow taken back with Escape: as it was, and no step made.
    public static func cancelHold() {
        guard holding != nil else { return }
        holding = nil
        measure = nil
        cancelGesture()
    }

    /// The drag is over: one step.
    public static func letGo() {
        guard holding != nil else { return }
        holding = nil
        measure = nil
        endGesture()
    }

    /// Whether a turn, a corner or a shadow is being dragged.
    public static var holds: Bool { holding != nil }

    /// What a handle pulled measures: the size the selection takes, under it.
    public static func measureSize(_ ids: [UUID]) {
        guard let box = design?.selectionFrame(ids) else { measure = nil; return }
        measure = ("\(number(box.width)) × \(number(box.height))", box)
    }

    public static func clearMeasure() { measure = nil }
}
