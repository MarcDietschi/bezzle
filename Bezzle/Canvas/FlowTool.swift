import AppKit
import QuartzCore

/// The colours of the canvas seen as a prototype: a sheet of graph paper, ruled in the pencil's
/// blue, the screens pinned to it and the flows between them drawn in blue pencil, their notes on
/// paper tags. Light and dark as the rest of Bezzle is.
enum FlowInk {
    /// The sheet: the table itself, pressed into the paper as deep as it is while drawing; only
    /// its ruling tells the prototype from the design.
    static let stage = CanvasInk.table
    /// Its ruling: fine lines, and every fifth a stronger one, as on millimetre paper.
    static let ruling = Theme.dynamicNS(0x3A63D8, 0x8FA8F2, lightAlpha: 0.075, darkAlpha: 0.07)
    static let rulingMajor = Theme.dynamicNS(0x3A63D8, 0x8FA8F2, lightAlpha: 0.17, darkAlpha: 0.14)
    /// A thread, and the soft light round it.
    static let thread = Theme.dynamicNS(0x3A63D8, 0x8FA8F2)
    static let threadBright = Theme.dynamicNS(0x2347B8, 0xC2D1FF)
    static let glow = Theme.dynamicNS(0x3A63D8, 0x8FA8F2, lightAlpha: 0.35, darkAlpha: 0.6)
    /// The light, this strong: on paper it is softer than in the dark.
    static func glow(_ strength: CGFloat) -> NSColor {
        Theme.dynamicNS(0x3A63D8, 0x8FA8F2, lightAlpha: 0.4 * strength, darkAlpha: 0.7 * strength)
    }
    /// Under a thread, where it crosses a screen: the paper's own white edge.
    static let casing = Theme.dynamicNS(0xFFFFFF, 0x101114, lightAlpha: 0.95, darkAlpha: 0.9)
    /// Where a thread will be cut, let go of now.
    static let cut = Theme.dynamicNS(0xB3402F, 0xE4705C)
    /// What is written on a thread, by hand, and the tag it is written on.
    static let note = Theme.dynamicNS(0x2F4FB5, 0xB9C9FA)
    static let notePlate = Theme.dynamicNS(0xFFFEFB, 0x2A2926)
    static let noteEdge = Theme.dynamicNS(0x1C1B19, 0xEDEAE4, lightAlpha: 0.12, darkAlpha: 0.14)
    static let paperShadow = Theme.dynamicNS(0x3A3226, 0x000000, lightAlpha: 0.16, darkAlpha: 0.5)
    /// The pencil.
    static let pencil = CanvasInk.pencil

    static func noteFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Bradley Hand", size: size) ?? NSFont.systemFont(ofSize: size - 1, weight: .medium)
    }
}

/// A cubic curve in the canvas view's points.
struct FlowCurve {
    var p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }

    func tangent(_ t: CGFloat) -> CGVector {
        let u = 1 - t
        let x = 3 * u * u * (c1.x - p0.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p3.x - c2.x)
        let y = 3 * u * u * (c1.y - p0.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p3.y - c2.y)
        let l = max(hypot(x, y), 0.0001)
        return CGVector(dx: x / l, dy: y / l)
    }

    /// The part from the start to `t`.
    func upTo(_ t: CGFloat) -> FlowCurve {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let a = lerp(p0, c1), b = lerp(c1, c2), c = lerp(c2, p3)
        let d = lerp(a, b), e = lerp(b, c)
        return FlowCurve(p0: p0, c1: a, c2: d, p3: lerp(d, e))
    }

    var path: CGPath {
        let p = CGMutablePath()
        p.move(to: p0)
        p.addCurve(to: p3, control1: c1, control2: c2)
        return p
    }

    var length: CGFloat {
        var l: CGFloat = 0, last = p0
        for i in 1...16 {
            let q = point(CGFloat(i) / 16)
            l += hypot(q.x - last.x, q.y - last.y)
            last = q
        }
        return l
    }

    func distance(to v: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for i in 0...28 {
            let q = point(CGFloat(i) / 28)
            best = min(best, hypot(q.x - v.x, q.y - v.y))
        }
        return best
    }

    /// The curve from a layer's box to a screen's, leaving the layer by the side facing the screen
    /// and coming into the screen square to its edge.
    static func route(from s: CGRect, to t: CGRect, sag: CGFloat = 0) -> FlowCurve {
        let right = t.minX - s.maxX, left = s.minX - t.maxX, down = t.minY - s.maxY, up = s.minY - t.maxY
        let inset: CGFloat = min(16, t.height / 3)
        var p0: CGPoint, p3: CGPoint, n0: CGVector, n3: CGVector
        let horizontal = max(right, left) >= max(down, up) * 0.8 || max(right, left, down, up) <= 0
        if horizontal {
            if right >= left {
                p0 = CGPoint(x: s.maxX, y: s.midY); n0 = CGVector(dx: 1, dy: 0)
                p3 = CGPoint(x: t.minX, y: min(max(s.midY, t.minY + inset), t.maxY - inset)); n3 = CGVector(dx: -1, dy: 0)
            } else {
                p0 = CGPoint(x: s.minX, y: s.midY); n0 = CGVector(dx: -1, dy: 0)
                p3 = CGPoint(x: t.maxX, y: min(max(s.midY, t.minY + inset), t.maxY - inset)); n3 = CGVector(dx: 1, dy: 0)
            }
        } else if down >= up {
            p0 = CGPoint(x: s.midX, y: s.maxY); n0 = CGVector(dx: 0, dy: 1)
            p3 = CGPoint(x: min(max(s.midX, t.minX + inset), t.maxX - inset), y: t.minY); n3 = CGVector(dx: 0, dy: -1)
        } else {
            p0 = CGPoint(x: s.midX, y: s.minY); n0 = CGVector(dx: 0, dy: -1)
            p3 = CGPoint(x: min(max(s.midX, t.minX + inset), t.maxX - inset), y: t.maxY); n3 = CGVector(dx: 0, dy: 1)
        }
        let k = max(34, hypot(p3.x - p0.x, p3.y - p0.y) * 0.42)
        return FlowCurve(p0: p0, c1: CGPoint(x: p0.x + n0.dx * k, y: p0.y + n0.dy * k + sag),
                         c2: CGPoint(x: p3.x + n3.dx * k, y: p3.y + n3.dy * k + sag), p3: p3)
    }

    /// A thread hanging loose from a point to the pointer, as a rope sags between two hands.
    static func rope(from a: CGPoint, leaving n: CGVector, to b: CGPoint, sag: CGFloat) -> FlowCurve {
        let d = hypot(b.x - a.x, b.y - a.y), k = max(24, d * 0.36)
        return FlowCurve(p0: a, c1: CGPoint(x: a.x + n.dx * k, y: a.y + n.dy * k + sag),
                         c2: CGPoint(x: b.x - (b.x - a.x) * 0.25, y: b.y - (b.y - a.y) * 0.25 + sag), p3: b)
    }
}

/// A point carried by a spring toward where it is wanted, so what follows the pointer has weight.
struct FlowSpring {
    var at: CGPoint
    var velocity = CGVector.zero

    mutating func step(toward target: CGPoint, dt: Double, stiffness: Double = 620, damping: Double = 40) {
        var left = min(dt, 1.0 / 20)
        while left > 0 {
            let h = min(left, 1.0 / 240)
            let ax = stiffness * (target.x - at.x) - damping * velocity.dx
            let ay = stiffness * (target.y - at.y) - damping * velocity.dy
            velocity.dx += ax * h
            velocity.dy += ay * h
            at.x += velocity.dx * h
            at.y += velocity.dy * h
            left -= h
        }
    }

    var resting: Bool { hypot(velocity.dx, velocity.dy) < 4 }
}

/// The canvas seen as a prototype. Every layer that goes somewhere has a thread of light to the
/// screen it goes to; a layer is linked by pulling a thread out of it onto a screen, which comes
/// to meet it, or onto the well beside its screen, to go back. A thread pulled off its screen
/// and let go of in the open is cut. The flag sticking out of a screen's side is where the
/// prototype starts, and goes wherever it is dragged. Coming into this, the flows light up one
/// after another from the start, as a current runs along wires.
@MainActor
final class FlowTool {
    let store: DocumentStore
    var redraw: () -> Void = {}
    /// What a click would pick at a canvas point, as the select tool picks it.
    var pick: (CGPoint) -> UUID? = { _ in nil }
    /// One level further into the group at a canvas point.
    var pickInside: (CGPoint, Node) -> UUID? = { _, _ in nil }
    /// The artboard whose name is at a view point.
    var titleHit: (CGPoint) -> UUID? = { _ in nil }
    /// Opens a menu at a view point.
    var menu: (CGPoint, [MenuEntry]) -> Void = { _, _ in }

    init(store: DocumentStore) {
        self.store = store
    }

    // MARK: Coming in and going out

    /// How far the canvas has turned into the prototype, 0 to 1.
    private var mode: (from: CGFloat, to: CGFloat, at: CFTimeInterval) = (0, 0, 0)
    private static let modeTime: CFTimeInterval = 0.55
    /// When the current began running through the flows, and how many flows from the start each
    /// screen is.
    private var wave: (at: CFTimeInterval, steps: [UUID: Int])?

    func modeChanged(_ on: Bool) {
        let now = CACurrentMediaTime()
        mode = (shown(at: now), on ? 1 : 0, now)
        press = nil
        pull = nil
        if on {
            let seen = store.seenDoc
            if let start = Prototype.start(of: seen) {
                wave = (now + 0.12, Prototype.steps(from: start.id, in: seen))
            } else {
                wave = nil
            }
        }
        NSCursor.arrow.set()
        redraw()
    }

    /// How far into the prototype the canvas is at `now`, eased.
    func shown(at now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        let t = min(max((now - mode.at) / Self.modeTime, 0), 1)
        let e = 1 - pow(1 - t, 3)
        return mode.from + (mode.to - mode.from) * CGFloat(e)
    }

    var active: Bool { store.prototyping || shown() > 0.001 }

    /// The table's colour as the canvas turns into the prototype and back.
    func table(_ design: NSColor) -> CGColor {
        let k = shown()
        guard k > 0 else { return design.cgColor }
        guard let a = design.usingColorSpace(.sRGB), let b = FlowInk.stage.usingColorSpace(.sRGB) else { return FlowInk.stage.cgColor }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
        return CGColor(srgbRed: mix(a.redComponent, b.redComponent), green: mix(a.greenComponent, b.greenComponent),
                       blue: mix(a.blueComponent, b.blueComponent), alpha: 1)
    }

    /// The names of artboards, light on the stage.
    func labelColor(selected: Bool, design: NSColor) -> NSColor { design }

    var isAnimating: Bool {
        let now = CACurrentMediaTime()
        if now - mode.at < Self.modeTime + 0.05 { return true }
        if let wave, now < wave.at + Double((wave.steps.values.max() ?? 0) + 2) * Self.waveStep + 0.8 { return true }
        if pull != nil || landing != nil || retracting != nil || flag != nil || flagFlight != nil { return true }
        if let lit, now - lit.at < 1.2 { return true }
        // A pulse runs along the thread pointed at, or picked.
        return store.prototyping && (hoveredThread != nil || !selectedThreads.isEmpty)
    }

    private static let waveStep: CFTimeInterval = 0.26

    // MARK: Threads

    private struct Thread {
        let source: UUID
        let board: UUID
        let flow: FlowLink
        /// The layer's box, in the view.
        let from: CGRect
        /// The screen's, when it goes to one.
        let to: CGRect?
        let curve: FlowCurve
        /// A screen going on by itself, from its edge.
        var bySelf: Bool { source == board }
    }

    private var threadsWorkedOut: (version: Int, viewport: Viewport, fronts: [UUID: Int], threads: [Thread])?
    /// The links and where their layers and screens lie on the canvas, read once per change: the
    /// view moving only places them again.
    private var linksWorkedOut: (version: Int, fronts: [UUID: Int], links: [(Prototype.Link, CGRect, CGRect?)])?

    private func placedLinks() -> [(Prototype.Link, CGRect, CGRect?)] {
        if let w = linksWorkedOut, w.version == store.version, w.fronts == store.fronts { return w.links }
        let seen = store.seenDoc
        let out: [(Prototype.Link, CGRect, CGRect?)] = Prototype.links(in: seen).compactMap { link in
            guard let box = seen.absoluteFrame(of: link.source) else { return nil }
            let target = link.flow.to.flatMap { seen.node($0) }.flatMap { $0.isArtboard && !$0.hidden ? $0.frame : nil }
            return (link, box, target)
        }
        linksWorkedOut = (store.version, store.fronts, out)
        return out
    }

    private func threads() -> [Thread] {
        if let w = threadsWorkedOut, w.version == store.version, w.viewport == store.viewport, w.fronts == store.fronts { return w.threads }
        let vp = store.viewport
        var out: [Thread] = []
        for (link, box, targetFrame) in placedLinks() {
            let from = vp.toView(box)
            if link.flow.goesBack {
                out.append(Thread(source: link.source, board: link.board, flow: link.flow, from: from, to: nil, curve: Self.backHook(from: from)))
                continue
            }
            guard let to = link.flow.to, let targetFrame else { continue }
            let t = vp.toView(targetFrame)
            var curve = FlowCurve.route(from: from, to: t)
            if to == link.board, link.source != link.board {
                // To the screen it lies on: a loop out of its side and back in.
                let p0 = CGPoint(x: from.maxX, y: from.midY), p3 = CGPoint(x: t.maxX, y: max(t.minY + 20, from.midY - 40))
                curve = FlowCurve(p0: p0, c1: CGPoint(x: t.maxX + 70, y: from.midY + 30), c2: CGPoint(x: t.maxX + 70, y: p3.y - 30), p3: p3)
            }
            out.append(Thread(source: link.source, board: link.board, flow: link.flow, from: from, to: t, curve: curve))
        }
        threadsWorkedOut = (store.version, vp, store.fronts, out)
        return out
    }

    /// A short hook out of a layer's left side, curling back: it goes back.
    private static func backHook(from r: CGRect) -> FlowCurve {
        let p0 = CGPoint(x: r.minX, y: r.midY)
        return FlowCurve(p0: p0, c1: CGPoint(x: p0.x - 26, y: p0.y), c2: CGPoint(x: p0.x - 34, y: p0.y - 22), p3: CGPoint(x: p0.x - 14, y: p0.y - 30))
    }

    private var selectedThreads: Set<UUID> {
        guard store.prototyping else { return [] }
        return Set(store.linkSources)
    }

    // MARK: Pointing

    private var hoveredSource: UUID?
    private var hoveredThread: UUID?
    private var hoveredFlag: UUID?
    private var hoveredBoard: UUID?

    func hover(_ v: CGPoint?) {
        guard store.prototyping, let v else {
            if hoveredSource != nil || hoveredThread != nil || hoveredFlag != nil || hoveredBoard != nil {
                hoveredSource = nil; hoveredThread = nil; hoveredFlag = nil; hoveredBoard = nil
                redraw()
            }
            return
        }
        let flagHit = flagAt(v)
        let thread = flagHit == nil ? threadAt(v) : nil
        let source = flagHit == nil && thread == nil ? sourceAt(v) : nil
        let board = boardAt(v)
        if flagHit != hoveredFlag || thread != hoveredThread || source != hoveredSource || board != hoveredBoard {
            hoveredFlag = flagHit
            hoveredThread = thread
            hoveredSource = source
            hoveredBoard = board
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        guard store.prototyping else { return nil }
        if press?.kind == .pan { return .closedHand }
        if flagAt(v) != nil { return .openHand }
        if titleHit(v) != nil { return .openHand }
        if threadAt(v) != nil || sourceAt(v) != nil { return .pointingHand }
        return .arrow
    }

    /// The thread a view point is on.
    private func threadAt(_ v: CGPoint) -> UUID? {
        var best: (UUID, CGFloat)?
        for t in threads() {
            let d = t.curve.distance(to: v)
            if d < 7, d < best?.1 ?? .infinity { best = (t.source, d) }
            if let note = notePlate(of: t), note.insetBy(dx: -3, dy: -3).contains(v) { return t.source }
        }
        return best?.0
    }

    /// The layer a press at a view point would pull a thread out of: one that goes somewhere, the
    /// deepest of them under the point; else what a click picks, or the copy it lies in.
    private func sourceAt(_ v: CGPoint) -> UUID? {
        let p = store.viewport.toCanvas(v)
        let seen = store.seenDoc
        guard let board = seen.artboard(at: p) else { return nil }
        let shown = board.isDeck ? board.showing(store.front(of: board)) : board
        let local = CGPoint(x: p.x - board.frame.minX, y: p.y - board.frame.minY)
        let chain = Prototype.chain(at: local, in: shown, tolerance: 2 / store.viewport.zoom)
        if let linked = chain.first(where: { $0.flow?.leads == true }) { return linked.id }
        guard let id = pick(p), let n = seen.node(id), !n.isArtboard else { return nil }
        return seen.linkable(id)
    }

    private func boardAt(_ v: CGPoint) -> UUID? {
        if let t = titleHit(v) { return t }
        return store.seenDoc.artboard(at: store.viewport.toCanvas(v))?.id
    }

    // MARK: The start flag

    private static let flagSize = CGSize(width: 30, height: 22)

    /// Where a screen's flag sticks out of its left side, near its top.
    private func flagRect(of board: CGRect) -> CGRect {
        CGRect(x: board.minX - Self.flagSize.width + 4, y: board.minY + min(12, board.height * 0.1), width: Self.flagSize.width, height: Self.flagSize.height)
    }

    /// The flag, or the ghost of one, at a view point: the screen it belongs to.
    private func flagAt(_ v: CGPoint) -> UUID? {
        let vp = store.viewport
        for board in Prototype.screens(in: store.seenDoc).reversed() {
            let r = vp.toView(board.frame)
            guard r.height > 30 else { continue }
            let f = flagRect(of: r).insetBy(dx: -3, dy: -3)
            guard f.contains(v) else { continue }
            if board.starts == true || hoveredBoard == board.id || hoveredFlag == board.id { return board.id }
        }
        return nil
    }

    // MARK: Pressing

    private enum PressKind: Equatable { case layer, thread, flag, title, pan, empty }

    private struct Press {
        var kind: PressKind
        let at: CGPoint
        var id: UUID?
        var moved = false
        var origin: CGPoint = .zero
        var clicks = 1
    }

    private var press: Press?

    /// A thread being pulled out of a layer, or off a screen to another.
    private struct Pull {
        let source: UUID
        /// Where it comes out of the layer, and which way.
        var anchor: CGPoint
        var leaving: CGVector
        var end: FlowSpring
        var pointer: CGPoint
        /// The screen it would go to, let go of now, or back.
        var target: UUID?
        var back = false
        /// Pulled off a screen it went to before: let go of in the open, it is cut.
        let again: Bool
        var sag: CGFloat = 0
        var lastStep: CFTimeInterval
        var began: CFTimeInterval
    }

    private var pull: Pull?

    /// The start flag carried to another screen.
    private struct Carry {
        var spring: FlowSpring
        var pointer: CGPoint
        var target: UUID?
        var lastStep: CFTimeInterval
    }

    private var flag: Carry?
    /// The flag flying to a screen clicked to start on, from where it was.
    private var flagFlight: (from: CGRect, to: UUID, at: CFTimeInterval)?

    /// A thread just tied: it tightens from its sag, a light runs along it, and the screen it
    /// reaches answers.
    private var landing: (source: UUID, sag: CGFloat, at: CFTimeInterval)?
    private var lit: (board: UUID, at: CFTimeInterval)?
    /// A thread let go of in the open, springing back into its layer.
    private var retracting: (curve: FlowCurve, at: CFTimeInterval, cut: Bool)?

    var dragging: Bool { press != nil }

    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard store.prototyping else { return false }
        let now = CACurrentMediaTime()
        let p = store.viewport.toCanvas(v)
        if let board = flagAt(v) {
            press = Press(kind: .flag, at: v, id: board, clicks: event.clickCount)
            return true
        }
        if let t = threadAt(v) {
            if event.clickCount >= 2 {
                writeNote(on: t)
                press = nil
                return true
            }
            select(t, adding: event.modifierFlags.contains(.shift))
            press = Press(kind: .thread, at: v, id: t, clicks: event.clickCount)
            return true
        }
        if let board = titleHit(v) {
            if event.clickCount >= 2 { store.play(from: board); return true }
            if !store.selection.contains(board) { store.selection = [board] }
            press = Press(kind: .title, at: v, id: board, origin: store.doc.node(board)?.frame.origin ?? .zero, clicks: event.clickCount)
            store.beginGesture()
            return true
        }
        if var id = sourceAt(v) {
            // A second click goes into a group, as on the design.
            if event.clickCount >= 2, let n = store.seenDoc.node(id), n.isGroup, !n.isCopy, let inner = pickInside(p, n) {
                id = store.seenDoc.linkable(inner) ?? inner
            }
            select(id, adding: event.modifierFlags.contains(.shift))
            press = Press(kind: .layer, at: v, id: id, clicks: event.clickCount)
            _ = now
            return true
        }
        if store.seenDoc.artboard(at: p) != nil {
            // On a screen's own background: the screen.
            let board = store.seenDoc.artboard(at: p)!.id
            if event.clickCount >= 2 { store.play(from: board); return true }
            select(board, adding: event.modifierFlags.contains(.shift))
            press = Press(kind: .layer, at: v, id: board, clicks: event.clickCount)
            return true
        }
        if !event.modifierFlags.contains(.shift) { store.selection = [] }
        press = Press(kind: .pan, at: v, origin: store.viewport.origin)
        NSCursor.closedHand.set()
        return true
    }

    private func select(_ id: UUID, adding: Bool) {
        if adding {
            if store.selection.contains(id) { store.selection.removeAll { $0 == id } } else { store.selection.append(id) }
        } else if !store.selection.contains(id) {
            store.selection = [id]
        }
    }

    func drag(to v: CGPoint) {
        guard var press else { return }
        let now = CACurrentMediaTime()
        if !press.moved, hypot(v.x - press.at.x, v.y - press.at.y) < 3 { return }
        let first = !press.moved
        press.moved = true
        self.press = press
        switch press.kind {
        case .pan:
            let z = store.viewport.zoom
            store.viewport.origin = CGPoint(x: press.origin.x - (v.x - press.at.x) / z, y: press.origin.y - (v.y - press.at.y) / z)
        case .title:
            guard let id = press.id else { return }
            let z = store.viewport.zoom
            let o = CGPoint(x: (press.origin.x + (v.x - press.at.x) / z).rounded(), y: (press.origin.y + (v.y - press.at.y) / z).rounded())
            store.edit("Move Screen") { doc in doc.update(id) { $0.frame.origin = o } }
        case .layer, .thread:
            guard let id = press.id, !store.isReadOnly else { return }
            if first { startPull(from: id, again: press.kind == .thread, at: v, now: now) }
            pull?.pointer = v
            aim(at: v)
        case .flag:
            if first, let id = press.id, let r = boardRect(id) {
                flag = Carry(spring: FlowSpring(at: flagRect(of: r).center), pointer: v, target: id, lastStep: now)
            }
            flag?.pointer = v
            let board = boardAt(v)
            if flag?.target != board {
                if board != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                flag?.target = board
            }
        case .empty:
            break
        }
        redraw()
    }

    func up(at v: CGPoint) {
        guard let press else { return }
        self.press = nil
        let now = CACurrentMediaTime()
        switch press.kind {
        case .title:
            store.endGesture("Move Screen")
        case .flag:
            if press.moved {
                if let carry = flag, let to = carry.target, store.doc.node(to)?.starts != true {
                    flagFlight = (CGRect(origin: CGPoint(x: carry.spring.at.x - Self.flagSize.width / 2, y: carry.spring.at.y - Self.flagSize.height / 2), size: Self.flagSize), to, now)
                    store.setStart(to)
                }
                flag = nil
            } else if let id = press.id, store.doc.node(id)?.starts != true {
                // A click on a ghost flag: the flag flies over from where it was.
                let was = Prototype.screens(in: store.seenDoc).first { $0.starts == true }.flatMap { boardRect($0.id) }.map(flagRect(of:))
                if let was { flagFlight = (was, id, now) }
                store.setStart(id)
            }
        case .layer, .thread:
            if press.moved { letGo(now: now) }
        case .pan:
            NSCursor.arrow.set()
        case .empty:
            break
        }
        pull = nil
        redraw()
    }

    func cancel() -> Bool {
        guard press != nil || pull != nil else { return false }
        if press?.kind == .title { store.cancelGesture() }
        if let pull { retracting = (curve(of: pull), CACurrentMediaTime(), false) }
        press = nil
        pull = nil
        flag = nil
        redraw()
        return true
    }

    private func boardRect(_ id: UUID) -> CGRect? {
        store.seenDoc.node(id).map { store.viewport.toView($0.frame) }
    }

    // MARK: Pulling a thread

    private func startPull(from id: UUID, again: Bool, at v: CGPoint, now: CFTimeInterval) {
        guard let box = store.seenDoc.absoluteFrame(of: id) else { return }
        let r = store.viewport.toView(box)
        let n = store.seenDoc.node(id)
        // A screen pulls its thread from its right edge; a layer from the side the pointer leaves by.
        var anchor = CGPoint(x: r.maxX, y: r.midY), leaving = CGVector(dx: 1, dy: 0)
        if n?.isArtboard != true, v.x < r.midX - r.width * 0.2, !again {
            anchor = CGPoint(x: r.minX, y: r.midY)
            leaving = CGVector(dx: -1, dy: 0)
        }
        var start = anchor
        if again, let t = threads().first(where: { $0.source == id }) { start = t.curve.p3 }
        pull = Pull(source: id, anchor: anchor, leaving: leaving, end: FlowSpring(at: start), pointer: v, target: nil, again: again,
                    lastStep: now, began: now)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// The screen, or the well to go back, under the pointer as a thread is pulled.
    private func aim(at v: CGPoint) {
        guard var pull else { return }
        let seen = store.seenDoc
        let home = seen.node(pull.source).flatMap { $0.isArtboard ? $0 : seen.artboard(of: pull.source) }
        var target: UUID? = boardAt(v)
        if target == pull.source { target = nil }
        var back = false
        if let well = backWell(for: pull), hypot(v.x - well.midX, v.y - well.midY) < well.width * 0.75 {
            target = nil
            back = true
        }
        // The screen it lies on is no place to go.
        if target == home?.id { target = nil }
        if target != pull.target || back != pull.back {
            if target != nil || back { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            pull.target = target
            pull.back = back
        }
        self.pull = pull
    }

    /// Where the pulled thread's end wants to be: the screen's edge it would come in by, the well's
    /// middle, or the pointer.
    private func wanted(_ pull: Pull) -> CGPoint {
        if pull.back, let well = backWell(for: pull) { return well.center }
        if let t = pull.target, let r = boardRect(t), let box = store.seenDoc.absoluteFrame(of: pull.source) {
            return FlowCurve.route(from: store.viewport.toView(box), to: r).p3
        }
        return pull.pointer
    }

    /// The round well to drop a thread in to go back: beside the screen the layer lies on, on its
    /// left, level with the layer.
    private func backWell(for pull: Pull) -> CGRect? {
        let seen = store.seenDoc
        guard seen.node(pull.source)?.isArtboard != true, let board = seen.artboard(of: pull.source), let r = boardRect(board.id) else { return nil }
        let d: CGFloat = 40
        let y = min(max(pull.anchor.y, r.minY + d), r.maxY - d)
        return CGRect(x: r.minX - d - 18, y: y - d / 2, width: d, height: d)
    }

    private func curve(of pull: Pull) -> FlowCurve {
        if pull.target != nil || pull.back, let t = pull.target, let r = boardRect(t), let box = store.seenDoc.absoluteFrame(of: pull.source) {
            // Caught by a screen: the route it will take, its end where the spring has it.
            var c = FlowCurve.route(from: store.viewport.toView(box), to: r, sag: pull.sag)
            c.p3 = pull.end.at
            return c
        }
        return FlowCurve.rope(from: pull.anchor, leaving: pull.leaving, to: pull.end.at, sag: pull.sag)
    }

    private func letGo(now: CFTimeInterval) {
        guard let pull else { return }
        if let to = pull.target {
            store.linkFlow([pull.source], to: to)
            landing = (pull.source, pull.sag + 26, now)
            lit = (to, now + 0.32)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else if pull.back {
            store.linkFlow([pull.source], to: nil, back: true)
            landing = (pull.source, 0, now)
        } else {
            retracting = (curve(of: pull), now, pull.again)
            if pull.again { store.unlinkFlow([pull.source]) }
        }
    }

    // MARK: Notes

    private func writeNote(on source: UUID) {
        guard !store.isReadOnly, let t = threads().first(where: { $0.source == source }) else { return }
        store.selection = [source]
        let at = t.flow.goesBack ? t.curve.p3 : t.curve.point(0.5)
        store.writingNote = (source, at)
    }

    /// Where a thread's note sits: on its middle, or beside the hook of one that goes back.
    private func notePlate(of t: Thread) -> CGRect? {
        guard let note = t.flow.note, !note.isEmpty else { return nil }
        let size = (note as NSString).size(withAttributes: [.font: FlowInk.noteFont(14)])
        let w = min(size.width, 220) + 18, h = size.height + 6
        if t.flow.goesBack {
            let c = CGPoint(x: t.curve.p3.x - w / 2 - 6, y: t.curve.p3.y - h / 2 - 6)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }
        // Hung over the thread's middle, as a label on a wire, the thread still showing under it.
        let m = t.curve.point(0.5), d = t.curve.tangent(0.5)
        let along = abs(d.dx) >= abs(d.dy)
        let c = along ? CGPoint(x: m.x, y: m.y - h / 2 - 7) : CGPoint(x: m.x + w / 2 + 9, y: m.y)
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    // MARK: The menu

    func menuEntries(at v: CGPoint) -> [MenuEntry]? {
        guard store.prototyping else { return nil }
        let id = threadAt(v) ?? sourceAt(v) ?? boardAt(v)
        guard let id else { return nil }
        if !store.selection.contains(id) { store.selection = [id] }
        let seen = store.seenDoc
        guard let node = seen.node(id) else { return nil }
        var entries: [MenuEntry] = []
        let home = node.isArtboard ? node : seen.artboard(of: id)
        if node.isArtboard {
            entries.append(.item("Play from Here", shortcut: "⌘↩") { [store] in store.play(from: id) })
            entries.append(.item("Start Here", checked: node.starts == true, enabled: node.starts != true) { [store] in store.setStart(id) })
            entries.append(.separator)
        }
        for screen in Prototype.screens(in: seen) where screen.id != home?.id {
            entries.append(.item("Go to \(screen.name)", checked: node.flow?.to == screen.id) { [store] in store.linkFlow([id], to: screen.id) })
        }
        if !node.isArtboard {
            entries.append(.item("Go Back", checked: node.flow?.goesBack == true) { [store] in store.linkFlow([id], to: nil, back: true) })
        }
        if node.flow?.leads == true {
            entries.append(.separator)
            entries.append(.item("Write a Note") { [weak self] in self?.writeNote(on: id) })
            entries.append(.item("Remove Link") { [store] in store.unlinkFlow([id]) })
        }
        return entries
    }

    // MARK: Drawing

    /// The dots ruled over the stage, under the screens.
    func drawStage(_ ctx: CGContext, in bounds: CGRect, scale: CGFloat) {
        let k = shown()
        guard k > 0 else { return }
        let vp = store.viewport
        // Millimetre paper at any zoom: the fine ruling never closer than 9 points on screen, nor
        // further apart than 45, every fifth line a stronger one, fixed to the canvas as it moves.
        var step: CGFloat = 8
        while step * vp.zoom < 9 { step *= 5 }
        while step * vp.zoom > 45 { step /= 5 }
        let s = step * vp.zoom
        let first = (x: Int(floor(vp.origin.x / step)), y: Int(floor(vp.origin.y / step)))
        let minor = CGMutablePath(), major = CGMutablePath()
        // On whole device pixels, so a hairline stays one pixel wide.
        func crisp(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale + 0.5 / scale }
        var i = first.x
        while true {
            let x = (CGFloat(i) * step - vp.origin.x) * vp.zoom
            if x > bounds.maxX { break }
            let path = i % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: crisp(x), y: bounds.minY))
            path.addLine(to: CGPoint(x: crisp(x), y: bounds.maxY))
            i += 1
        }
        var j = first.y
        while true {
            let y = (CGFloat(j) * step - vp.origin.y) * vp.zoom
            if y > bounds.maxY { break }
            let path = j % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: bounds.minX, y: crisp(y)))
            path.addLine(to: CGPoint(x: bounds.maxX, y: crisp(y)))
            j += 1
        }
        _ = s
        ctx.saveGState()
        ctx.setAlpha(k)
        ctx.setLineWidth(1 / scale)
        ctx.addPath(minor)
        ctx.setStrokeColor(FlowInk.ruling.cgColor)
        ctx.strokePath()
        ctx.addPath(major)
        ctx.setStrokeColor(FlowInk.rulingMajor.cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The threads, the flags and whatever is being pulled, over the screens.
    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        let now = CACurrentMediaTime()
        let k = shown(at: now)
        guard k > 0.001 else { return }
        step(now)
        ctx.saveGState()
        let all = threads()
        let picked = selectedThreads
        // Going out, every thread draws back into its layer at once.
        let leaving = !store.prototyping
        for t in all {
            var drawn: CGFloat = leaving ? k : 1
            if !leaving, let wave {
                let step = t.bySelf ? (wave.steps[t.board] ?? 0) : (wave.steps[t.board] ?? (wave.steps.values.max() ?? 0) + 1)
                let local = (now - wave.at - Double(step) * Self.waveStep) / 0.5
                drawn = CGFloat(1 - pow(1 - min(max(local, 0), 1), 3))
            }
            if pull?.source == t.source { continue }
            guard drawn > 0.001 else { continue }
            var curve = t.curve
            if let landing, landing.source == t.source {
                let e = now - landing.at
                let wobble = landing.sag * CGFloat(exp(-6 * e) * cos(15 * e))
                curve.c1.y += wobble
                curve.c2.y += wobble
            }
            let on = picked.contains(t.source) || hoveredThread == t.source
            drawThread(curve.upTo(drawn), in: ctx, bright: on, dashed: t.flow.goesBack || t.bySelf, alpha: k)
            if drawn >= 0.999 {
                arrowHead(at: curve.p3, along: curve.tangent(1), in: ctx, bright: on, alpha: k)
                if on { pulse(on: curve, now: now, in: ctx, period: 1.5) }
                if let landing, landing.source == t.source, now - landing.at < 0.7 {
                    let u = (now - landing.at) / 0.6
                    if u <= 1 { light(at: curve.point(CGFloat(1 - pow(1 - u, 2))), in: ctx, size: 7) }
                }
            }
            // Where it comes out of the layer.
            let dot = curve.p0
            ctx.setFillColor((on ? FlowInk.threadBright : FlowInk.thread).withAlphaComponent(k).cgColor)
            ctx.fillEllipse(in: CGRect(x: dot.x - 3.2, y: dot.y - 3.2, width: 6.4, height: 6.4))
            if t.bySelf, let after = t.flow.after { drawTimer(after, at: CGPoint(x: dot.x + 4, y: dot.y - 18), in: ctx, alpha: k) }
            if drawn >= 0.999, let plate = notePlate(of: t) { drawNote(t.flow.note ?? "", in: plate, ctx: ctx, alpha: k, bright: on) }
        }
        // A wave of light runs along each thread as it is drawn in, coming into the prototype.
        if !leaving, let wave {
            for t in all where pull?.source != t.source {
                let step = wave.steps[t.board] ?? (wave.steps.values.max() ?? 0) + 1
                let local = (now - wave.at - Double(step) * Self.waveStep) / 0.5
                if local > 0, local < 1 { light(at: t.curve.point(CGFloat(1 - pow(1 - local, 3))), in: ctx, size: 6) }
            }
        }
        drawScreensAnswering(ctx, now: now, alpha: k)
        drawFlags(ctx, now: now, alpha: k)
        drawHover(ctx, alpha: k)
        drawPreview(ctx, alpha: k)
        drawPull(ctx, now: now)
        drawRetract(ctx, now: now)
        ctx.restoreGState()
    }

    /// Moves the springs on to `now`.
    private func step(_ now: CFTimeInterval) {
        if var p = pull {
            let dt = now - p.lastStep
            p.lastStep = now
            let caught = p.target != nil || p.back
            p.end.step(toward: wanted(p), dt: dt, stiffness: caught ? 900 : 520, damping: caught ? 52 : 34)
            // Hanging loose it sags with its length; caught, it pulls taut.
            let len = hypot(p.end.at.x - p.anchor.x, p.end.at.y - p.anchor.y)
            let want: CGFloat = caught ? 0 : min(56, len * 0.16)
            p.sag += (want - p.sag) * CGFloat(min(dt * 9, 1))
            pull = p
        }
        if var c = flag {
            let dt = now - c.lastStep
            c.lastStep = now
            var target = c.pointer
            if let t = c.target, let r = boardRect(t) { target = flagRect(of: r).center }
            c.spring.step(toward: target, dt: dt, stiffness: 700, damping: 42)
            flag = c
        }
        if let l = landing, now - l.at > 1.1 { landing = nil }
        if let r = retracting, now - r.at > 0.4 { retracting = nil }
        if let f = flagFlight, now - f.at > 0.6 { flagFlight = nil }
        if let l = lit, now - l.at > 1.2 { lit = nil }
    }

    private func drawThread(_ curve: FlowCurve, in ctx: CGContext, bright: Bool, dashed: Bool, alpha: CGFloat, color: NSColor = FlowInk.thread) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setLineCap(.round)
        if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
        // The paper's white edge under it, so it reads over a dark screen as well as on the sheet.
        ctx.addPath(curve.path)
        ctx.setStrokeColor(FlowInk.casing.cgColor)
        ctx.setLineWidth((bright ? 2.6 : 1.8) + 3)
        ctx.strokePath()
        ctx.addPath(curve.path)
        // A soft light round a thread picked or pointed at.
        if bright { ctx.setShadow(offset: .zero, blur: 8, color: FlowInk.glow(0.9).cgColor) }
        ctx.setStrokeColor((bright ? FlowInk.threadBright : color).cgColor)
        ctx.setLineWidth(bright ? 2.6 : 1.8)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func arrowHead(at p: CGPoint, along d: CGVector, in ctx: CGContext, bright: Bool, alpha: CGFloat) {
        let a = atan2(d.dy, d.dx), l: CGFloat = bright ? 8 : 7
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x - l * cos(a - 0.55), y: p.y - l * sin(a - 0.55)))
        path.addLine(to: p)
        path.addLine(to: CGPoint(x: p.x - l * cos(a + 0.55), y: p.y - l * sin(a + 0.55)))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 6, color: FlowInk.glow(0.7 * alpha).cgColor)
        ctx.setStrokeColor((bright ? FlowInk.threadBright : FlowInk.thread).withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(bright ? 2.6 : 2)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A bead of light running along a thread, again and again.
    private func pulse(on curve: FlowCurve, now: CFTimeInterval, in ctx: CGContext, period: Double) {
        let u = (now.truncatingRemainder(dividingBy: period)) / period
        let e = CGFloat(u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2)
        light(at: curve.point(e), in: ctx, size: 5.5)
    }

    private func light(at p: CGPoint, in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 1.8, color: FlowInk.glow.cgColor)
        ctx.setFillColor(FlowInk.thread.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        let c = size * 0.38
        ctx.fillEllipse(in: CGRect(x: p.x - c / 2, y: p.y - c / 2, width: c, height: c))
        ctx.restoreGState()
    }

    private func drawNote(_ note: String, in r: CGRect, ctx: CGContext, alpha: CGFloat, bright: Bool) {
        // A paper tag hung on the thread.
        let plate = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: FlowInk.paperShadow.cgColor)
        ctx.addPath(plate)
        ctx.setFillColor(FlowInk.notePlate.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(plate)
        ctx.setStrokeColor((bright ? FlowInk.thread : FlowInk.noteEdge).cgColor)
        ctx.setLineWidth(bright ? 1 : 0.5)
        ctx.strokePath()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        NSGraphicsContext.saveGraphicsState()
        (note as NSString).draw(with: r.insetBy(dx: 9, dy: 2).offsetBy(dx: 0, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: FlowInk.noteFont(14), .foregroundColor: FlowInk.note, .paragraphStyle: paragraph])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// A screen going on by itself: a small clock and how long it waits.
    private func drawTimer(_ seconds: Double, at p: CGPoint, in ctx: CGContext, alpha: CGFloat) {
        let text = String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds) as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let size = text.size(withAttributes: [.font: font])
        let r = CGRect(x: p.x, y: p.y, width: size.width + 22, height: 16)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: FlowInk.paperShadow.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(FlowInk.notePlate.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        let c = CGPoint(x: r.minX + 9, y: r.midY)
        ctx.setStrokeColor(FlowInk.thread.cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x, y: c.y - 3))
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + 2.2, y: c.y))
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: CGPoint(x: r.minX + 17, y: r.minY + 1.5), withAttributes: [.font: font, .foregroundColor: FlowInk.note])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// A screen a thread was just tied to rings once, as if it heard it.
    private func drawScreensAnswering(_ ctx: CGContext, now: CFTimeInterval, alpha: CGFloat) {
        guard let lit, let r = boardRect(lit.board) else { return }
        let e = now - lit.at
        guard e > 0, e < 0.9 else { return }
        let u = CGFloat(e / 0.9)
        let grow = 4 + 26 * (1 - pow(1 - u, 3))
        ctx.saveGState()
        ctx.setStrokeColor(FlowInk.threadBright.withAlphaComponent((1 - u) * 0.9 * alpha).cgColor)
        ctx.setLineWidth(2.5 * (1 - u) + 0.5)
        ctx.setShadow(offset: .zero, blur: 14, color: FlowInk.glow((1 - u) * alpha).cgColor)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -grow, dy: -grow), cornerWidth: 10 + grow / 2, cornerHeight: 10 + grow / 2, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawFlags(_ ctx: CGContext, now: CFTimeInterval, alpha: CGFloat) {
        let vp = store.viewport
        let screens = Prototype.screens(in: store.seenDoc)
        for board in screens {
            let r = vp.toView(board.frame)
            guard r.height > 30, r.intersects(CGRect(x: -100, y: -100, width: 100000, height: 100000)) else { continue }
            let spot = flagRect(of: r)
            if board.starts == true {
                if flag != nil { continue }
                if let f = flagFlight, f.to == board.id {
                    let u = CGFloat(min((now - f.at) / 0.5, 1))
                    let e = 1 - pow(1 - u, 3)
                    let mid = CGPoint(x: (f.from.midX + spot.midX) / 2, y: min(f.from.midY, spot.midY) - 60)
                    let a = f.from.center, b = spot.center
                    // Along an arc, from where it was.
                    let x = (1 - e) * (1 - e) * a.x + 2 * (1 - e) * e * mid.x + e * e * b.x
                    let y = (1 - e) * (1 - e) * a.y + 2 * (1 - e) * e * mid.y + e * e * b.y
                    drawFlag(in: CGRect(x: x - spot.width / 2, y: y - spot.height / 2, width: spot.width, height: spot.height), ctx: ctx, ghost: false, alpha: alpha, lifted: true)
                    continue
                }
                drawFlag(in: spot, ctx: ctx, ghost: false, alpha: alpha, lifted: hoveredFlag == board.id)
            } else if store.prototyping, flag == nil, hoveredBoard == board.id || hoveredFlag == board.id {
                drawFlag(in: spot, ctx: ctx, ghost: true, alpha: alpha * (hoveredFlag == board.id ? 1 : 0.6), lifted: false)
            }
        }
        if let carry = flag {
            let c = carry.spring.at
            if let t = carry.target, let r = boardRect(t) { drawFlag(in: flagRect(of: r), ctx: ctx, ghost: true, alpha: alpha * 0.7, lifted: false) }
            drawFlag(in: CGRect(x: c.x - Self.flagSize.width / 2, y: c.y - Self.flagSize.height / 2, width: Self.flagSize.width, height: Self.flagSize.height),
                     ctx: ctx, ghost: false, alpha: alpha, lifted: true)
        }
    }

    /// The flag: a ribbon of pencil sticking out of a screen's side, notched at its free end, with
    /// the triangle of play on it.
    private func drawFlag(in r: CGRect, ctx: CGContext, ghost: Bool, alpha: CGFloat, lifted: Bool) {
        let notch: CGFloat = 6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - 3, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 3), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 3))
        path.addQuadCurve(to: CGPoint(x: r.maxX - 3, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + notch, y: r.midY))
        path.closeSubpath()
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if ghost {
            ctx.addPath(path)
            ctx.setStrokeColor(FlowInk.thread.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [3, 2.5])
            ctx.strokePath()
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: lifted ? 6 : 1.5), blur: lifted ? 12 : 3, color: FlowInk.paperShadow.cgColor)
            ctx.addPath(path)
            ctx.setFillColor(FlowInk.pencil.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
        // The triangle of play.
        let c = CGPoint(x: r.midX + 2, y: r.midY)
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: c.x - 3.5, y: c.y - 5))
        tri.addLine(to: CGPoint(x: c.x + 5, y: c.y))
        tri.addLine(to: CGPoint(x: c.x - 3.5, y: c.y + 5))
        tri.closeSubpath()
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(tri)
        ctx.setFillColor(ghost ? FlowInk.thread.cgColor : NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The layer under the pointer, which a thread can be pulled out of, and those picked.
    private func drawHover(_ ctx: CGContext, alpha: CGFloat) {
        guard store.prototyping, pull == nil else { return }
        let seen = store.seenDoc, vp = store.viewport
        func outline(_ id: UUID, width: CGFloat, knob: Bool) {
            guard let n = seen.node(id), !n.isArtboard, let box = seen.absoluteFrame(of: id) else { return }
            let r = vp.toView(box).insetBy(dx: -2, dy: -2)
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor(FlowInk.pencil.cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
            if knob, n.flow?.leads != true {
                // The knob a thread comes out of.
                let k = CGPoint(x: r.maxX, y: r.midY)
                ctx.setShadow(offset: .zero, blur: 8, color: FlowInk.glow.cgColor)
                ctx.setFillColor(FlowInk.pencil.cgColor)
                ctx.fillEllipse(in: CGRect(x: k.x - 6, y: k.y - 6, width: 12, height: 12))
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.6)
                ctx.move(to: CGPoint(x: k.x - 2.6, y: k.y))
                ctx.addLine(to: CGPoint(x: k.x + 2.6, y: k.y))
                ctx.move(to: CGPoint(x: k.x, y: k.y - 2.6))
                ctx.addLine(to: CGPoint(x: k.x, y: k.y + 2.6))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        for id in store.selection where seen.node(id)?.isArtboard == false { outline(seen.linkable(id) ?? id, width: 1.5, knob: true) }
        if let h = hoveredSource, !store.selection.contains(h) { outline(h, width: 1, knob: true) }
        // A picked screen, outlined round its edge.
        for id in store.selection {
            guard let n = seen.node(id), n.isArtboard else { continue }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.setStrokeColor(FlowInk.pencil.cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: vp.toView(n.frame).insetBy(dx: -3, dy: -3), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A screen pointed at in the inspector: the threads the picked layers would take to it.
    private func drawPreview(_ ctx: CGContext, alpha: CGFloat) {
        guard store.prototyping, let to = store.flowPreview, let r = boardRect(to) else { return }
        let seen = store.seenDoc
        for id in store.linkSources {
            guard let box = seen.absoluteFrame(of: id), seen.artboard(of: id)?.id != to || seen.node(id)?.isArtboard == true else { continue }
            let c = FlowCurve.route(from: store.viewport.toView(box), to: r)
            drawThread(c, in: ctx, bright: true, dashed: true, alpha: alpha * 0.8)
            arrowHead(at: c.p3, along: c.tangent(1), in: ctx, bright: true, alpha: alpha * 0.8)
        }
        ctx.saveGState()
        ctx.setStrokeColor(FlowInk.threadBright.withAlphaComponent(0.7 * alpha).cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -4, dy: -4), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawPull(_ ctx: CGContext, now: CFTimeInterval) {
        guard let pull else { return }
        // Every screen it could go to lifts a little; the one it would go to, all the way.
        let seen = store.seenDoc
        let home = seen.node(pull.source).flatMap { $0.isArtboard ? $0 : seen.artboard(of: pull.source) }?.id
        let rise = CGFloat(min((now - pull.began) / 0.25, 1))
        for board in Prototype.screens(in: seen) where board.id != home {
            guard let r = boardRect(board.id) else { continue }
            let on = pull.target == board.id
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: on ? 22 : 10, color: FlowInk.glow((on ? 0.9 : 0.35) * rise).cgColor)
            ctx.setStrokeColor((on ? FlowInk.threadBright : FlowInk.thread).withAlphaComponent((on ? 1 : 0.4) * rise).cgColor)
            ctx.setLineWidth(on ? 2.5 : 1)
            let grow: CGFloat = on ? 5 : 3
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -grow, dy: -grow), cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }
        // The well to go back.
        if let well = backWell(for: pull) {
            let on = pull.back
            let s: CGFloat = (on ? 1.18 : 1) * (0.6 + 0.4 * rise)
            let r = CGRect(x: well.midX - well.width * s / 2, y: well.midY - well.height * s / 2, width: well.width * s, height: well.height * s)
            ctx.saveGState()
            ctx.setAlpha(rise)
            ctx.setFillColor(FlowInk.notePlate.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor((on ? FlowInk.threadBright : FlowInk.thread).cgColor)
            ctx.setLineWidth(on ? 2.2 : 1.3)
            if !on { ctx.setLineDash(phase: 0, lengths: [3, 3]) }
            ctx.strokeEllipse(in: r.insetBy(dx: 1, dy: 1))
            ctx.setLineDash(phase: 0, lengths: [])
            // A hook curling back to the left.
            let c = r.center, u = r.width / 40
            let hook = CGMutablePath()
            hook.move(to: CGPoint(x: c.x + 7 * u, y: c.y + 6 * u))
            hook.addCurve(to: CGPoint(x: c.x - 6 * u, y: c.y - 2 * u), control1: CGPoint(x: c.x + 8 * u, y: c.y - 4 * u), control2: CGPoint(x: c.x, y: c.y - 3 * u))
            hook.move(to: CGPoint(x: c.x - 2 * u, y: c.y - 6.5 * u))
            hook.addLine(to: CGPoint(x: c.x - 6.5 * u, y: c.y - 2 * u))
            hook.addLine(to: CGPoint(x: c.x - 2 * u, y: c.y + 2.5 * u))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(1.8)
            ctx.addPath(hook)
            ctx.strokePath()
            ctx.restoreGState()
        }
        let caught = pull.target != nil || pull.back
        let cut = pull.again && !caught
        let c = curve(of: pull)
        drawThread(c, in: ctx, bright: caught, dashed: cut, alpha: 1, color: cut ? FlowInk.cut : FlowInk.thread)
        if caught { arrowHead(at: c.p3, along: c.tangent(1), in: ctx, bright: true, alpha: 1) }
        // The end in the hand: a bead of light.
        light(at: c.p3, in: ctx, size: caught ? 7 : 9)
        ctx.setFillColor(FlowInk.thread.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.p0.x - 3.5, y: c.p0.y - 3.5, width: 7, height: 7))
    }

    private func drawRetract(_ ctx: CGContext, now: CFTimeInterval) {
        guard let r = retracting else { return }
        let u = CGFloat(min((now - r.at) / 0.32, 1))
        // Quick at first, as a stretched cord snaps back.
        let left = 1 - (1 - pow(1 - u, 3))
        guard left > 0.01 else { return }
        drawThread(r.curve.upTo(left), in: ctx, bright: false, dashed: r.cut, alpha: left, color: r.cut ? FlowInk.cut : FlowInk.thread)
        light(at: r.curve.point(left), in: ctx, size: 6 * left + 2)
    }
}
