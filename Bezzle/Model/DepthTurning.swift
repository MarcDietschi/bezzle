import Foundation
import CoreGraphics

/// What turning in depth on a canvas needs of it: the design and what is picked, where the
/// canvas is, the steps of the history, and somewhere to say how far a thing is turned.
@MainActor protocol DepthHost: AnyObject {
    var doc: BezzleDocument { get }
    var selection: [UUID] { get set }
    /// Whether the select tool is in hand with nothing else under way (no words being typed, no
    /// points edited, no picture placed, no shapes built), so it may turn the selection.
    var turnsFreely: Bool { get }
    var zoom: CGFloat { get }
    func toView(_ p: CGPoint) -> CGPoint
    func toCanvas(_ v: CGPoint) -> CGPoint
    func beginGesture()
    func endGesture(_ action: LocalizedStringResource)
    func cancelGesture()
    func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void)
    /// How far what is turned is turned, said beside `box` (on the canvas); nil when it is not.
    func measure(_ what: DepthMeasure?, _ box: CGRect)
}

/// What turning in depth says while it turns: how many layers turn, or one's turn, or how near.
enum DepthMeasure: Equatable {
    case turning(Int)
    case angles(x: Double, y: Double)
    case nearness(CGFloat)
}

/// Turning layers in depth straight on the canvas, with no axis to think of, shared by every
/// Bezzle: the canvas hands it the pointer and draws what `overlay` says shows.
///
/// Aiming: a layer turned in depth shows which way its face points, as a knob on a short stalk
/// from its middle; pointing at the knob shows the ring where the face would be seen edge on.
/// Dragging the knob turns the face to follow it, as a head turns where its nose is led. With
/// Option (Alt), up and down bring it nearer or push it away instead. Passing face on, it settles
/// flat; Shift turns in steps of 15°; a double click lays it flat again.
///
/// Turning: just outside the middle of a side, a drag turns what is picked in depth, flat or not,
/// as a ball turns under the hand, its face toward where the pointer goes, as the knob does.
/// Several layers picked that lie together turn as one body about the middle they share, each
/// going where a real body's face would (`DepthBody`); layers lying apart, each with its own.
final class DepthTurning {
    private let host: DepthHost
    var redraw: () -> Void = {}
    /// What a click at a canvas point picks, as the canvas would pick it.
    var pick: (CGPoint) -> UUID? = { _ in nil }

    private enum Drag {
        /// `grip` is from the pointer to the knob's middle, so the knob does not jump to it.
        case aim(id: UUID, center: CGPoint, grip: CGPoint, original: Transform3D, start: CGPoint)
        /// `from` is the design as the press found it, which every step of the drag turns from.
        case turn(from: BezzleDocument, ids: [UUID], center: CGPoint, radius: CGFloat, start: CGPoint, started: Bool)
    }

    private var drag: Drag?
    /// Whether the pointer is on the knob, so the ring shows.
    private(set) var onKnob = false
    /// How far from the middle, on screen, the knob is when the face is seen edge on.
    static let reach: CGFloat = 36

    init(host: DepthHost) {
        self.host = host
    }

    var dragging: Bool { drag != nil }

    /// The layers picked that can be turned in depth: not artboards, which are the page, nor locked ones.
    private var turnable: [Node] {
        host.selection.compactMap { host.doc.node($0) }.filter { !$0.isArtboard && !$0.locked }
    }

    /// The one selected layer turned in depth, when the select tool is free to work on it. One
    /// only held nearer or further, facing the eye, has no knob: its middle is for moving it, as
    /// anything's is, and it is turned from just outside a side.
    private var single: (node: Node, turn: Transform3D)? {
        guard host.turnsFreely, host.selection.count == 1, let n = host.doc.node(host.selection[0]), !n.locked,
              !n.isArtboard, let turn = n.transform3D else { return nil }
        if turn.x == 0, turn.y == 0, turn.z != 0, !turn.pinned { return nil }
        return (n, turn)
    }

    /// The selected layer's middle on screen and its knob, where its face points; none on a
    /// layer too small on screen to hold a knob clear of its handles.
    func knob() -> (center: CGPoint, knob: CGPoint)? {
        guard let (n, turn) = single else { return nil }
        let shown = Geometry.bounds(of: n, eye: host.doc.eye(forParentOf: n.id))
        guard max(shown.width, shown.height) * host.zoom >= 40 else { return nil }
        let c = host.toView(host.doc.shown(CGPoint(x: n.frame.midX, y: n.frame.midY), inParentOf: n.id))
        let f = DepthAim.facing(turn)
        return (c, CGPoint(x: c.x + f.x * Self.reach, y: c.y + f.y * Self.reach))
    }

    // MARK: - The pointer

    /// A press with the select tool at `v` on screen, on a turned layer's knob; false leaves it
    /// to the canvas.
    func down(at v: CGPoint, clicks: Int) -> Bool {
        guard let k = knob(), let (n, turn) = single, hypot(k.knob.x - v.x, k.knob.y - v.y) <= 9 else { return false }
        if clicks >= 2 {
            host.edit("Lay Flat") { $0.update(n.id) { $0.transform3D = Transform3D() } }
            return true
        }
        host.beginGesture()
        drag = .aim(id: n.id, center: k.center, grip: CGPoint(x: k.knob.x - v.x, y: k.knob.y - v.y), original: turn, start: v)
        return true
    }

    /// A press just outside the middle of a side of what is picked: turning it in depth, once the
    /// pointer moves.
    func startTurn(at v: CGPoint) {
        let nodes = turnable
        guard !nodes.isEmpty, let box = host.doc.bounds(of: host.selection) else { return }
        let ids = nodes.map(\.id)
        let bodies = host.doc.depthBodies(of: ids)
        // A ball as big as what is picked, and never so small on screen that it spins away. One
        // layer is turned about its own middle, wherever a group turned in depth shows it;
        // several lying together about the middle they share, where that shows.
        let center: CGPoint
        if nodes.count == 1 {
            center = host.toView(host.doc.shown(CGPoint(x: nodes[0].frame.midX, y: nodes[0].frame.midY), inParentOf: nodes[0].id))
        } else if bodies.count == 1, let lead = DepthBody.lead(of: bodies[0]), let parent = host.doc.parent(of: lead.id) {
            center = host.toView(host.doc.shown(DepthBody.middle(of: bodies[0], lead: lead), inside: parent.id))
        } else {
            center = host.toView(CGPoint(x: box.midX, y: box.midY))
        }
        let radius = max(max(box.width, box.height) * host.zoom / 2, 60)
        drag = .turn(from: host.doc, ids: ids, center: center, radius: radius, start: v, started: false)
    }

    /// The pointer at `v` on screen while it is held; `option` brings the face nearer instead.
    func drag(to v: CGPoint, shift: Bool, option: Bool) {
        switch drag {
        case nil:
            return
        case .aim(let id, let center, let grip, let original, let start):
            var next = original
            if option {
                // Up is nearer, as far as the pointer goes, caught on the page and with Shift in
                // tens, as when it is pushed while it is moved (`DepthPushing`).
                var push = DepthPushing()
                push.pointer(at: CGPoint(x: 0, y: start.y / host.zoom), holding: true)
                push.pointer(at: CGPoint(x: 0, y: v.y / host.zoom), holding: true)
                next.z = push.height(from: original.z, reach: 4 / host.zoom, steps: shift)
            } else {
                let at = CGPoint(x: v.x + grip.x - center.x, y: v.y + grip.y - center.y)
                let (x, y) = DepthAim.turn(facing: CGPoint(x: at.x / Self.reach, y: at.y / Self.reach))
                (next.x, next.y) = DepthAim.settled(x, y, steps: shift)
            }
            host.edit("Turn in Depth") { doc in doc.update(id) { $0.transform3D = next } }
            show(next, of: [id], depth: option)

        case .turn(let from, let ids, let center, let radius, let start, let started):
            if !started {
                guard hypot(v.x - start.x, v.y - start.y) > 3 else { return }
                host.beginGesture()
                drag = .turn(from: from, ids: ids, center: center, radius: radius, start: start, started: true)
            }
            // Round a ball under the hand, and on past its rim as far as the pointer goes.
            func around(_ s: CGFloat) -> CGFloat { abs(s) <= 1 ? asin(s) : (s > 0 ? 1 : -1) * (.pi / 2 + abs(s) - 1) }
            var swing = Double(around((v.x - center.x) / radius) - around((start.x - center.x) / radius)) * 180 / .pi
            var tip = -Double(around((v.y - center.y) / radius) - around((start.y - center.y) / radius)) * 180 / .pi
            if shift { if abs(swing) > abs(tip) { tip = 0 } else { swing = 0 } }
            // Each body's lead turns as one layer would, from how the press found it, and the
            // rest of the body goes with it.
            var turns: [Transform3D] = []
            host.edit("Turn in Depth") { doc in
                turns = doc.turnInDepth(ids, from: from) { lead, now in
                    let original = lead.transform3D ?? Transform3D()
                    // As high as it stands: a body's lead goes higher or lower as the body turns.
                    var next = now
                    (next.x, next.y) = DepthAim.settled(Self.normalized(original.x + tip), Self.normalized(original.y + swing), steps: shift)
                    return next
                }
            }
            show(turns.count == 1 ? turns[0] : nil, of: ids, depth: false)
        }
        redraw()
    }

    /// How far it is turned, beside it, while it turns.
    private func show(_ turn: Transform3D?, of ids: [UUID], depth: Bool) {
        let doc = host.doc
        let box = doc.bounds(of: ids) ?? .zero
        guard let turn else { host.measure(.turning(ids.count), box); return }
        host.measure(depth ? .nearness(turn.z) : .angles(x: turn.x, y: turn.y), box)
    }

    /// The pointer let go at `v` on screen; `adding` (Shift) adds what a click picks.
    func up(at v: CGPoint, adding: Bool) {
        switch drag {
        case .aim:
            host.endGesture("Turn in Depth")
        case .turn(_, _, _, _, _, let started):
            if started {
                host.endGesture("Turn in Depth")
            } else if let id = pick(host.toCanvas(v)) {
                // Only a click, outside what is picked: whatever is there is picked, as anywhere else.
                if adding { if !host.selection.contains(id) { host.selection.append(id) } } else { host.selection = [id] }
            } else if !adding {
                host.selection = []
            }
        case nil:
            return
        }
        drag = nil
        host.measure(nil, .zero)
        redraw()
    }

    /// Escape during a drag: back as it was.
    func cancel() {
        if case .turn(_, _, _, _, _, false) = drag {} else { host.cancelGesture() }
        drag = nil
        host.measure(nil, .zero)
        redraw()
    }

    /// The pointer at `v` on screen, or nil when it has left the canvas.
    func hover(_ v: CGPoint?) {
        let on = v.flatMap { v in knob().map { hypot($0.knob.x - v.x, $0.knob.y - v.y) <= 9 } } ?? false
        if on != onKnob {
            onKnob = on
            redraw()
        }
    }

    /// Whether the pointer should show it turns things.
    var turnsPointer: Bool { drag != nil || onKnob }

    /// Degrees between -180 and 180.
    private static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    // MARK: - What shows

    /// What shows over the design, on screen: the ball being turned (dashed), or the ring where
    /// the face is seen edge on (while the knob is pointed at or held), and the stalk from the
    /// middle to the knob.
    struct Overlay {
        var ball: (center: CGPoint, radius: CGFloat)?
        var ring: CGPoint?
        var stalk: (center: CGPoint, knob: CGPoint)?
    }

    func overlay() -> Overlay {
        var o = Overlay()
        if case .turn(_, _, let center, let radius, _, true) = drag {
            o.ball = (center, radius)
            return o
        }
        guard let (center, knob) = knob() else { return o }
        let aiming: Bool = if case .aim = drag { true } else { false }
        if onKnob || aiming { o.ring = center }
        o.stalk = (center, knob)
        return o
    }
}
