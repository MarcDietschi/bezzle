import Foundation

// The canvas seen as a prototype on Windows, as the Mac's FlowTool (Canvas/FlowTool.swift):
// every layer that goes somewhere has a thread to the screen it goes to; a layer is linked by
// pulling a thread out of it onto a screen, or onto the well beside its own screen to go back. A
// thread pulled off its screen and let go of in the open is cut. The flag sticking out of a
// screen's side is where the prototype starts, and goes wherever it is dragged. Changes go
// through the shared `BezzleDocument.linkFlow` and `markStart` (Model/PrototypeEditing.swift).
//
// Not yet: the current running along the flows coming in, the bead of light on a thread pointed
// at, and a screen answering a thread tied to it.

extension WindowsCore {
    /// A cubic curve on the stage.
    public struct FlowCurve: Sendable {
        public var p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint

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
        public func upTo(_ t: CGFloat) -> FlowCurve {
            func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
            let a = lerp(p0, c1), b = lerp(c1, c2), c = lerp(c2, p3)
            let d = lerp(a, b), e = lerp(b, c)
            return FlowCurve(p0: p0, c1: a, c2: d, p3: lerp(d, e))
        }

        func distance(to v: CGPoint) -> CGFloat {
            var best = CGFloat.infinity
            for i in 0...28 {
                let q = point(CGFloat(i) / 28)
                best = min(best, hypot(q.x - v.x, q.y - v.y))
            }
            return best
        }

        /// The curve from a layer's box to a screen's, leaving the layer by the side facing the
        /// screen and coming into the screen square to its edge.
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

        /// As path data for the stage.
        public var data: String {
            func n(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
            return "M\(n(p0.x)),\(n(p0.y)) C\(n(c1.x)),\(n(c1.y)) \(n(c2.x)),\(n(c2.y)) \(n(p3.x)),\(n(p3.y))"
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
                let ax = stiffness * Double(target.x - at.x) - damping * Double(velocity.dx)
                let ay = stiffness * Double(target.y - at.y) - damping * Double(velocity.dy)
                velocity.dx += CGFloat(ax * h)
                velocity.dy += CGFloat(ay * h)
                at.x += velocity.dx * CGFloat(h)
                at.y += velocity.dy * CGFloat(h)
                left -= h
            }
        }
    }

    @MainActor public final class FlowHand {
        /// The canvas seen as a prototype.
        public var on = false { didSet { if on != oldValue { modeChanged() } } }
        public var selection: [UUID] = []
        /// A screen pointed at in the inspector: the threads the picked layers would take to it.
        public var preview: UUID? { didSet { if preview != oldValue { redraw() } } }
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        public var redraw: () -> Void = {}
        /// The artboard whose name is at a point on the stage.
        public var titleHit: (CGPoint) -> UUID? = { _ in nil }
        /// What a click would pick at a canvas point, as the select tool picks it.
        public var pick: (CGPoint) -> UUID? = { _ in nil }
        /// The selection changed here.
        public var select: ([UUID]) -> Void = { _ in }
        /// A screen double clicked: played from there.
        public var play: (UUID) -> Void = { _ in }
        /// A thread double clicked: its note written, at a point on the stage.
        public var writeNote: (UUID, CGPoint) -> Void = { _, _ in }

        public init() {}

        // MARK: Coming into the prototype, and out of it

        /// How far into the prototype the canvas is, from what, toward what, since when.
        private var mode: (from: Double, to: Double, at: Double) = (0, 0, 0)
        private static let modeTime = 0.55
        /// When the current began running through the flows, and how many flows from the start
        /// each screen is.
        private var wave: (at: Double, steps: [UUID: Int])?
        private static let waveStep = 0.26

        private func modeChanged() {
            let now = Self.now()
            mode = (shown(at: now), on ? 1 : 0, now)
            press = nil
            pull = nil
            flag = nil
            if on, let seen = doc, let start = Prototype.start(of: seen) {
                wave = (now + 0.12, Prototype.steps(from: start.id, in: seen))
            } else if on {
                wave = nil
            }
            redraw()
        }

        /// How far into the prototype the canvas is at `now`, eased: the threads fade and draw in
        /// as it comes, and draw back into their layers as it goes.
        public func shown(at now: Double? = nil) -> Double {
            let t = min(max(((now ?? Self.now()) - mode.at) / Self.modeTime, 0), 1)
            let e = 1 - pow(1 - t, 3)
            return mode.from + (mode.to - mode.from) * e
        }

        /// Whether anything of the prototype shows: while it is seen as one, and while it fades.
        public var showing: Bool { on || shown() > 0.001 }

        private var doc: BezzleDocument? { WindowsCore.design }
        private static func now() -> Double { Date().timeIntervalSinceReferenceDate }
        private func view(_ r: CGRect) -> CGRect {
            CGRect(x: pan.x + r.minX * zoom, y: pan.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
        }
        private func canvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }

        /// The layers the selection links from: each, or the copy of a component it lies in.
        public var linkSources: [UUID] {
            guard let doc else { return [] }
            var seen = Set<UUID>()
            return selection.compactMap { doc.linkable($0) }.filter { seen.insert($0).inserted }
        }

        // MARK: Threads

        private struct Thread {
            let source: UUID
            let board: UUID
            let flow: FlowLink
            let from: CGRect
            let curve: FlowCurve
            var bySelf: Bool { source == board }
        }

        private func threads() -> [Thread] {
            guard let seen = doc else { return [] }
            var out: [Thread] = []
            for link in Prototype.links(in: seen) {
                guard let box = seen.absoluteFrame(of: link.source) else { continue }
                let from = view(box)
                if link.flow.goesBack {
                    out.append(Thread(source: link.source, board: link.board, flow: link.flow, from: from, curve: Self.backHook(from: from)))
                    continue
                }
                guard let to = link.flow.to, let target = seen.node(to), target.isArtboard, !target.hidden else { continue }
                let t = view(target.frame)
                var curve = FlowCurve.route(from: from, to: t)
                if to == link.board, link.source != link.board {
                    // To the screen it lies on: a loop out of its side and back in.
                    let p0 = CGPoint(x: from.maxX, y: from.midY), p3 = CGPoint(x: t.maxX, y: max(t.minY + 20, from.midY - 40))
                    curve = FlowCurve(p0: p0, c1: CGPoint(x: t.maxX + 70, y: from.midY + 30), c2: CGPoint(x: t.maxX + 70, y: p3.y - 30), p3: p3)
                }
                out.append(Thread(source: link.source, board: link.board, flow: link.flow, from: from, curve: curve))
            }
            return out
        }

        /// A short hook out of a layer's left side, curling back: it goes back.
        private static func backHook(from r: CGRect) -> FlowCurve {
            let p0 = CGPoint(x: r.minX, y: r.midY)
            return FlowCurve(p0: p0, c1: CGPoint(x: p0.x - 26, y: p0.y), c2: CGPoint(x: p0.x - 34, y: p0.y - 22), p3: CGPoint(x: p0.x - 14, y: p0.y - 30))
        }

        // MARK: Pointing

        private var hoveredSource: UUID?
        private var hoveredThread: UUID?
        private var hoveredFlag: UUID?
        private var hoveredBoard: UUID?

        @discardableResult public func hover(_ v: CGPoint?) -> Bool {
            guard on, let v else {
                guard hoveredSource != nil || hoveredThread != nil || hoveredFlag != nil || hoveredBoard != nil else { return false }
                hoveredSource = nil; hoveredThread = nil; hoveredFlag = nil; hoveredBoard = nil
                redraw()
                return true
            }
            let flagHit = flagAt(v)
            let thread = flagHit == nil ? threadAt(v) : nil
            let source = flagHit == nil && thread == nil ? sourceAt(v) : nil
            let board = boardAt(v)
            guard flagHit != hoveredFlag || thread != hoveredThread || source != hoveredSource || board != hoveredBoard else { return false }
            hoveredFlag = flagHit
            hoveredThread = thread
            hoveredSource = source
            hoveredBoard = board
            redraw()
            return true
        }

        public enum Pointer { case grab, grabbing, pointing, arrow }
        public func pointer(at v: CGPoint) -> Pointer {
            if press?.kind == .pan, press?.moved == true { return .grabbing }
            if flagAt(v) != nil || titleHit(v) != nil { return .grab }
            if threadAt(v) != nil || sourceAt(v) != nil { return .pointing }
            return .arrow
        }

        /// The thread a point on the stage is on.
        private func threadAt(_ v: CGPoint) -> UUID? {
            var best: (UUID, CGFloat)?
            for t in threads() {
                let d = t.curve.distance(to: v)
                if d < 7, d < best?.1 ?? .infinity { best = (t.source, d) }
                if let note = notePlate(of: t), note.insetBy(dx: -3, dy: -3).contains(v) { return t.source }
            }
            return best?.0
        }

        /// The layer a press would pull a thread out of: one that goes somewhere, the deepest of
        /// them under the point; else what a click picks, or the copy it lies in.
        private func sourceAt(_ v: CGPoint) -> UUID? {
            guard let seen = doc else { return nil }
            let p = canvas(v)
            guard let board = seen.artboard(at: p) else { return nil }
            let local = CGPoint(x: p.x - board.frame.minX, y: p.y - board.frame.minY)
            let chain = Prototype.chain(at: local, in: board, tolerance: 2 / zoom)
            if let linked = chain.first(where: { $0.flow?.leads == true }) { return linked.id }
            guard let id = pick(p), let n = seen.node(id), !n.isArtboard else { return nil }
            return seen.linkable(id)
        }

        private func boardAt(_ v: CGPoint) -> UUID? {
            if let t = titleHit(v) { return t }
            return doc?.artboard(at: canvas(v))?.id
        }

        private func boardRect(_ id: UUID) -> CGRect? { doc?.node(id).map { view($0.frame) } }

        // MARK: The start flag

        private static let flagSize = CGSize(width: 30, height: 22)

        /// Where a screen's flag sticks out of its left side, near its top.
        private func flagRect(of board: CGRect) -> CGRect {
            CGRect(x: board.minX - Self.flagSize.width + 4, y: board.minY + min(12, board.height * 0.1), width: Self.flagSize.width, height: Self.flagSize.height)
        }

        /// The flag, or the ghost of one, at a point on the stage: the screen it belongs to.
        private func flagAt(_ v: CGPoint) -> UUID? {
            guard let seen = doc else { return nil }
            for board in Prototype.screens(in: seen).reversed() {
                let r = view(board.frame)
                guard r.height > 30, flagRect(of: r).insetBy(dx: -3, dy: -3).contains(v) else { continue }
                if board.starts == true || hoveredBoard == board.id || hoveredFlag == board.id { return board.id }
            }
            return nil
        }

        // MARK: Pressing

        private enum PressKind: Equatable { case layer, thread, flag, title, pan }

        private struct Press {
            var kind: PressKind
            let at: CGPoint
            var id: UUID?
            var moved = false
            var origin: CGPoint = .zero
        }

        private var press: Press?

        /// A thread being pulled out of a layer, or off a screen to another.
        private struct Pull {
            let source: UUID
            var anchor: CGPoint
            var leaving: CGVector
            var end: FlowSpring
            var pointer: CGPoint
            var target: UUID?
            var back = false
            /// Pulled off a screen it went to before: let go of in the open, it is cut.
            let again: Bool
            var sag: CGFloat = 0
            var lastStep: Double
            let began: Double
        }

        private var pull: Pull?

        /// The start flag carried to another screen.
        private struct Carry {
            var spring: FlowSpring
            var pointer: CGPoint
            var target: UUID?
            var lastStep: Double
        }

        private var flag: Carry?
        /// A thread let go of in the open, springing back into its layer.
        private var retracting: (curve: FlowCurve, at: Double, cut: Bool)?
        /// A thread just tied, tightening from its sag.
        private var landing: (source: UUID, sag: CGFloat, at: Double)?

        public var dragging: Bool { press != nil }
        /// Whether the canvas moves round: a press on nothing.
        public var panning: Bool { press?.kind == .pan }

        /// A press on the stage while the design is a prototype; false leaves it (nothing).
        public func down(at v: CGPoint, clicks: Int, shift: Bool) -> Bool {
            guard on, let seen = doc else { return false }
            let p = canvas(v)
            if let board = flagAt(v) {
                press = Press(kind: .flag, at: v, id: board)
                return true
            }
            if let t = threadAt(v) {
                if clicks >= 2, let thread = threads().first(where: { $0.source == t }) {
                    select([t])
                    writeNote(t, thread.flow.goesBack ? thread.curve.p3 : thread.curve.point(0.5))
                    press = nil
                    return true
                }
                choose(t, adding: shift)
                press = Press(kind: .thread, at: v, id: t)
                return true
            }
            if let board = titleHit(v) {
                if clicks >= 2 { play(board); return true }
                if !selection.contains(board) { select([board]) }
                press = Press(kind: .title, at: v, id: board, origin: seen.node(board)?.frame.origin ?? .zero)
                WindowsCore.beginGesture()
                return true
            }
            if var id = sourceAt(v) {
                // A second click goes into a group, as on the design.
                if clicks >= 2, let n = seen.node(id), n.isGroup, !n.isCopy,
                   let inner = WindowsCore.pick(p, inGroup: id, zoom: Double(zoom)) {
                    id = seen.linkable(inner) ?? inner
                }
                choose(id, adding: shift)
                press = Press(kind: .layer, at: v, id: id)
                return true
            }
            if let board = seen.artboard(at: p) {
                // On a screen's own background: the screen.
                if clicks >= 2 { play(board.id); return true }
                choose(board.id, adding: shift)
                press = Press(kind: .layer, at: v, id: board.id)
                return true
            }
            if !shift { select([]) }
            press = Press(kind: .pan, at: v, origin: pan)
            return true
        }

        private func choose(_ id: UUID, adding: Bool) {
            if adding {
                select(selection.contains(id) ? selection.filter { $0 != id } : selection + [id])
            } else if !selection.contains(id) {
                select([id])
            }
        }

        /// The drag on to `v`; for a press on nothing, how far the canvas moves (`moveBy`).
        public func drag(to v: CGPoint, moveBy: (CGPoint) -> Void) {
            guard var press else { return }
            let now = Self.now()
            if !press.moved, hypot(v.x - press.at.x, v.y - press.at.y) < 3 { return }
            let first = !press.moved
            press.moved = true
            self.press = press
            switch press.kind {
            case .pan:
                moveBy(CGPoint(x: press.origin.x + v.x - press.at.x, y: press.origin.y + v.y - press.at.y))
            case .title:
                guard let id = press.id else { return }
                let o = CGPoint(x: (press.origin.x + (v.x - press.at.x) / zoom).rounded(), y: (press.origin.y + (v.y - press.at.y) / zoom).rounded())
                WindowsCore.edit { doc in doc.update(id) { $0.frame.origin = o } }
            case .layer, .thread:
                guard let id = press.id else { return }
                if first { startPull(from: id, again: press.kind == .thread, at: v, now: now) }
                pull?.pointer = v
                aim(at: v)
            case .flag:
                if first, let id = press.id, let r = boardRect(id) {
                    let f = flagRect(of: r)
                    flag = Carry(spring: FlowSpring(at: CGPoint(x: f.midX, y: f.midY)), pointer: v, target: id, lastStep: now)
                }
                flag?.pointer = v
                flag?.target = boardAt(v)
            }
            redraw()
        }

        public func up(at v: CGPoint) {
            guard let press else { return }
            self.press = nil
            let now = Self.now()
            switch press.kind {
            case .title:
                WindowsCore.endGesture()
            case .flag:
                if press.moved {
                    if let carry = flag, let to = carry.target, doc?.node(to)?.starts != true {
                        flagFlight = (CGRect(x: carry.spring.at.x - Self.flagSize.width / 2, y: carry.spring.at.y - Self.flagSize.height / 2,
                                             width: Self.flagSize.width, height: Self.flagSize.height), to, now)
                        WindowsCore.edit { $0.markStart(to) }
                    }
                    flag = nil
                } else if let id = press.id, doc?.node(id)?.starts != true {
                    // A click on a ghost flag: the flag flies over from where it was.
                    let was = doc.flatMap { d in Prototype.screens(in: d).first { $0.starts == true } }.flatMap { boardRect($0.id) }.map(flagRect(of:))
                    if let was { flagFlight = (was, id, now) }
                    WindowsCore.edit { $0.markStart(id) }
                }
            case .layer, .thread:
                if press.moved { letGo(now: now) }
            case .pan:
                break
            }
            pull = nil
            redraw()
        }

        public func cancel() -> Bool {
            guard press != nil || pull != nil else { return false }
            if press?.kind == .title { WindowsCore.cancelGesture() }
            if let pull { retracting = (curve(of: pull), Self.now(), false) }
            press = nil
            pull = nil
            flag = nil
            redraw()
            return true
        }

        /// Delete cuts the picked layers' threads, never the layers.
        public func deleteLinks() {
            let ids = linkSources
            guard !ids.isEmpty else { return }
            WindowsCore.edit { $0.linkFlow(ids, to: nil) }
        }

        // MARK: Pulling a thread

        private func startPull(from id: UUID, again: Bool, at v: CGPoint, now: Double) {
            guard let seen = doc, let box = seen.absoluteFrame(of: id) else { return }
            let r = view(box)
            // A screen pulls its thread from its right edge; a layer from the side the pointer leaves by.
            var anchor = CGPoint(x: r.maxX, y: r.midY), leaving = CGVector(dx: 1, dy: 0)
            if seen.node(id)?.isArtboard != true, v.x < r.midX - r.width * 0.2, !again {
                anchor = CGPoint(x: r.minX, y: r.midY)
                leaving = CGVector(dx: -1, dy: 0)
            }
            var start = anchor
            if again, let t = threads().first(where: { $0.source == id }) { start = t.curve.p3 }
            pull = Pull(source: id, anchor: anchor, leaving: leaving, end: FlowSpring(at: start), pointer: v, target: nil, again: again,
                        lastStep: now, began: now)
        }

        /// The screen, or the well to go back, under the pointer as a thread is pulled.
        private func aim(at v: CGPoint) {
            guard var pull, let seen = doc else { return }
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
            pull.target = target
            pull.back = back
            self.pull = pull
        }

        /// Where the pulled thread's end wants to be: the screen's edge it would come in by, the
        /// well's middle, or the pointer.
        private func wanted(_ pull: Pull) -> CGPoint {
            if pull.back, let well = backWell(for: pull) { return CGPoint(x: well.midX, y: well.midY) }
            if let t = pull.target, let r = boardRect(t), let box = doc?.absoluteFrame(of: pull.source) {
                return FlowCurve.route(from: view(box), to: r).p3
            }
            return pull.pointer
        }

        /// The round well to drop a thread in to go back: beside the screen the layer lies on, on
        /// its left, level with the layer.
        private func backWell(for pull: Pull) -> CGRect? {
            guard let seen = doc, seen.node(pull.source)?.isArtboard != true, let board = seen.artboard(of: pull.source), let r = boardRect(board.id) else { return nil }
            let d: CGFloat = 40
            let y = min(max(pull.anchor.y, r.minY + d), r.maxY - d)
            return CGRect(x: r.minX - d - 18, y: y - d / 2, width: d, height: d)
        }

        private func curve(of pull: Pull) -> FlowCurve {
            if pull.target != nil, let t = pull.target, let r = boardRect(t), let box = doc?.absoluteFrame(of: pull.source) {
                // Caught by a screen: the route it will take, its end where the spring has it.
                var c = FlowCurve.route(from: view(box), to: r, sag: pull.sag)
                c.p3 = pull.end.at
                return c
            }
            return FlowCurve.rope(from: pull.anchor, leaving: pull.leaving, to: pull.end.at, sag: pull.sag)
        }

        private func letGo(now: Double) {
            guard let pull else { return }
            let id = pull.source
            if let to = pull.target {
                WindowsCore.edit { $0.linkFlow([id], to: to) }
                landing = (id, pull.sag + 26, now)
                lit = (to, now + 0.32)
            } else if pull.back {
                WindowsCore.edit { $0.linkFlow([id], to: nil, back: true) }
                landing = (id, 0, now)
            } else {
                retracting = (curve(of: pull), now, pull.again)
                if pull.again { WindowsCore.edit { $0.linkFlow([id], to: nil) } }
            }
        }

        // MARK: Notes

        /// Where a thread's note sits: on its middle, or beside the hook of one that goes back.
        /// About 7 points a letter in the notes' hand.
        private func notePlate(of t: Thread) -> CGRect? {
            guard let note = t.flow.note, !note.isEmpty else { return nil }
            let w = min(CGFloat(note.count) * 7, 220) + 18, h: CGFloat = 23
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

        public struct MenuEntry {
            public let title: String
            public var checked = false
            public var enabled = true
            /// A line before it.
            public var separated = false
            public let action: @MainActor () -> Void
        }

        public func menuEntries(at v: CGPoint) -> [MenuEntry]? {
            guard on, let seen = doc else { return nil }
            guard let id = threadAt(v) ?? sourceAt(v) ?? boardAt(v), let node = seen.node(id) else { return nil }
            if !selection.contains(id) { select([id]) }
            var entries: [MenuEntry] = []
            let home = node.isArtboard ? node : seen.artboard(of: id)
            if node.isArtboard {
                entries.append(MenuEntry(title: WindowsCore.say("Play from Here")) { [weak self] in self?.play(id) })
                entries.append(MenuEntry(title: WindowsCore.say("Start Here"), checked: node.starts == true, enabled: node.starts != true) {
                    WindowsCore.edit { $0.markStart(id) }
                })
            }
            var first = node.isArtboard
            for screen in Prototype.screens(in: seen) where screen.id != home?.id {
                let to = screen.id
                entries.append(MenuEntry(title: WindowsCore.say("Go to %@", screen.name), checked: node.flow?.to == to, separated: first) {
                    WindowsCore.edit { $0.linkFlow([id], to: to) }
                })
                first = false
            }
            if !node.isArtboard {
                entries.append(MenuEntry(title: WindowsCore.say("Go Back"), checked: node.flow?.goesBack == true, separated: first) {
                    WindowsCore.edit { $0.linkFlow([id], to: nil, back: true) }
                })
            }
            if node.flow?.leads == true {
                let thread = threads().first { $0.source == id }
                entries.append(MenuEntry(title: WindowsCore.say("Write a Note"), separated: true) { [weak self] in
                    if let thread { self?.writeNote(id, thread.flow.goesBack ? thread.curve.p3 : thread.curve.point(0.5)) }
                })
                entries.append(MenuEntry(title: WindowsCore.say("Remove Link")) { WindowsCore.edit { $0.linkFlow([id], to: nil) } })
            }
            return entries
        }

        // MARK: What shows

        /// What the canvas draws, on the stage: threads (bright when picked or pointed at, dashed
        /// for going back or a screen going on by itself, red where it would be cut), arrowheads
        /// (a point and a direction), the dots threads come out of, notes on paper tags, timers,
        /// flags (ghosts dashed, one lifted while carried), the layer pointed at and those picked
        /// with the knob a thread comes out of, screens lifting while a thread is pulled, the well
        /// to go back, and beads of light.
        public struct Marks {
            public var threads: [(curve: FlowCurve, bright: Bool, dashed: Bool, cut: Bool, alpha: Double)] = []
            public var arrows: [(at: CGPoint, angle: Double, bright: Bool)] = []
            public var dots: [(at: CGPoint, bright: Bool)] = []
            public var notes: [(rect: CGRect, text: String, bright: Bool)] = []
            public var timers: [(at: CGPoint, text: String)] = []
            public var flags: [(rect: CGRect, ghost: Bool, lifted: Bool, alpha: Double)] = []
            public var outlines: [(rect: CGRect, width: Double, knob: Bool)] = []
            public var screens: [(rect: CGRect, width: Double, bright: Bool)] = []
            public var lifted: [(rect: CGRect, on: Bool)] = []
            public var well: (rect: CGRect, on: Bool)?
            public var lights: [(at: CGPoint, size: Double)] = []
            /// A screen ringing as it answers a thread tied to it.
            public var answer: (rect: CGRect, width: Double, alpha: Double, radius: Double)?
            /// How much of it all shows, as the canvas comes into the prototype and goes out.
            public var alpha: Double = 1
        }

        public var animating: Bool {
            let now = Self.now()
            if now - mode.at < Self.modeTime + 0.05 { return true }
            if on, let wave, now < wave.at + Double((wave.steps.values.max() ?? 0) + 2) * Self.waveStep + 0.8 { return true }
            if pull != nil || flag != nil || landing != nil || retracting != nil || flagFlight != nil { return true }
            if let lit, now - lit.at < 1.2 { return true }
            // A pulse runs along the thread pointed at, or picked.
            return on && (hoveredThread != nil || threads().contains { linkSources.contains($0.source) })
        }

        /// A screen a thread was just tied to, ringing once as if it heard it, from when.
        private var lit: (board: UUID, at: Double)?
        /// The start flag flying to the screen it was set on, from where.
        private var flagFlight: (from: CGRect, to: UUID, at: Double)?

        /// Moves the springs on.
        private func step(_ now: Double) {
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
                if let t = c.target, let r = boardRect(t) { let f = flagRect(of: r); target = CGPoint(x: f.midX, y: f.midY) }
                c.spring.step(toward: target, dt: dt, stiffness: 700, damping: 42)
                flag = c
            }
            if let l = landing, now - l.at > 1.1 { landing = nil }
            if let r = retracting, now - r.at > 0.4 { retracting = nil }
            if let f = flagFlight, now - f.at > 0.6 { flagFlight = nil }
            if let l = lit, now - l.at > 1.2 { lit = nil }
        }

        public func marks() -> Marks {
            var m = Marks()
            let now = Self.now()
            let k = shown(at: now)
            guard k > 0.001, let seen = doc else { return m }
            m.alpha = k
            step(now)
            // Going out, every thread draws back into its layer at once.
            let leaving = !on
            let picked = Set(linkSources)
            let all = threads()
            let last = (wave?.steps.values.max() ?? 0) + 1
            for t in all where pull?.source != t.source {
                var drawn = leaving ? CGFloat(k) : 1
                if !leaving, let wave {
                    let step = t.bySelf ? (wave.steps[t.board] ?? 0) : (wave.steps[t.board] ?? last)
                    let local = (now - wave.at - Double(step) * Self.waveStep) / 0.5
                    drawn = CGFloat(1 - pow(1 - min(max(local, 0), 1), 3))
                }
                guard drawn > 0.001 else { continue }
                var curve = t.curve
                if let landing, landing.source == t.source {
                    let e = now - landing.at
                    let wobble = landing.sag * CGFloat(exp(-6 * e) * cos(15 * e))
                    curve.c1.y += wobble
                    curve.c2.y += wobble
                }
                let lit = !leaving && (picked.contains(t.source) || hoveredThread == t.source)
                m.threads.append((curve.upTo(drawn), lit, t.flow.goesBack || t.bySelf, false, 1))
                if drawn >= 0.999 {
                    let d = curve.tangent(1)
                    m.arrows.append((curve.p3, atan2(Double(d.dy), Double(d.dx)), lit))
                    // A pulse runs along the thread pointed at, or picked.
                    if lit {
                        let u = now.truncatingRemainder(dividingBy: 1.5) / 1.5
                        let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                        m.lights.append((curve.point(CGFloat(e)), 5.5))
                    }
                    // A thread just tied: a light runs along it to the screen.
                    if let landing, landing.source == t.source, now - landing.at < 0.7 {
                        let u = (now - landing.at) / 0.6
                        if u <= 1 { m.lights.append((curve.point(CGFloat(1 - pow(1 - u, 2))), 7)) }
                    }
                }
                m.dots.append((curve.p0, lit))
                if t.bySelf, let after = t.flow.after {
                    m.timers.append((CGPoint(x: curve.p0.x + 4, y: curve.p0.y - 18), String(format: after < 10 ? "%.1f s" : "%.0f s", after)))
                }
                if drawn >= 0.999, let plate = notePlate(of: t) { m.notes.append((plate, t.flow.note ?? "", lit)) }
            }
            // A wave of light runs along each thread as it is drawn in, coming into the prototype.
            if !leaving, let wave {
                for t in all where pull?.source != t.source {
                    let step = wave.steps[t.board] ?? last
                    let local = (now - wave.at - Double(step) * Self.waveStep) / 0.5
                    if local > 0, local < 1 { m.lights.append((t.curve.point(CGFloat(1 - pow(1 - local, 3))), 6)) }
                }
            }
            // A screen a thread was just tied to rings once, as if it heard it.
            if let lit, let r = boardRect(lit.board) {
                let e = now - lit.at
                if e > 0, e < 0.9 {
                    let u = e / 0.9
                    let grow = CGFloat(4 + 26 * (1 - pow(1 - u, 3)))
                    m.answer = (r.insetBy(dx: -grow, dy: -grow), 2.5 * (1 - u) + 0.5, (1 - u) * 0.9, 10 + Double(grow) / 2)
                }
            }
            guard !leaving else {
                // Going out: only the start flag stays with the threads, fading.
                for board in Prototype.screens(in: seen) where board.starts == true {
                    let r = view(board.frame)
                    if r.height > 30 { m.flags.append((flagRect(of: r), false, false, 1)) }
                }
                return m
            }
            // The flags.
            for board in Prototype.screens(in: seen) {
                let r = view(board.frame)
                guard r.height > 30 else { continue }
                let spot = flagRect(of: r)
                if board.starts == true {
                    if flag == nil, let f = flagFlight, f.to == board.id {
                        // Along an arc, from where it was.
                        let u = CGFloat(min((now - f.at) / 0.5, 1))
                        let e = 1 - pow(1 - u, 3)
                        let a = CGPoint(x: f.from.midX, y: f.from.midY), b = CGPoint(x: spot.midX, y: spot.midY)
                        let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 60)
                        let x = (1 - e) * (1 - e) * a.x + 2 * (1 - e) * e * mid.x + e * e * b.x
                        let y = (1 - e) * (1 - e) * a.y + 2 * (1 - e) * e * mid.y + e * e * b.y
                        m.flags.append((CGRect(x: x - spot.width / 2, y: y - spot.height / 2, width: spot.width, height: spot.height), false, true, 1))
                    } else if flag == nil {
                        m.flags.append((spot, false, hoveredFlag == board.id, 1))
                    }
                } else if flag == nil, hoveredBoard == board.id || hoveredFlag == board.id {
                    m.flags.append((spot, true, false, hoveredFlag == board.id ? 1 : 0.6))
                }
            }
            if let carry = flag {
                if let t = carry.target, let r = boardRect(t) { m.flags.append((flagRect(of: r), true, false, 0.7)) }
                let c = carry.spring.at
                m.flags.append((CGRect(x: c.x - Self.flagSize.width / 2, y: c.y - Self.flagSize.height / 2, width: Self.flagSize.width, height: Self.flagSize.height), false, true, 1))
            }
            // The layer pointed at and those picked, with the knob a thread comes out of.
            if pull == nil {
                func outline(_ id: UUID, width: Double) {
                    guard let n = seen.node(id), !n.isArtboard, let box = seen.absoluteFrame(of: id) else { return }
                    m.outlines.append((view(box).insetBy(dx: -2, dy: -2), width, n.flow?.leads != true))
                }
                for id in selection where seen.node(id)?.isArtboard == false { outline(seen.linkable(id) ?? id, width: 1.5) }
                if let h = hoveredSource, !selection.contains(h) { outline(h, width: 1) }
                for id in selection { if let n = seen.node(id), n.isArtboard { m.screens.append((view(n.frame).insetBy(dx: -3, dy: -3), 2, false)) } }
            }
            if pull == nil, let to = preview, let r = boardRect(to) {
                for id in linkSources {
                    guard let box = seen.absoluteFrame(of: id), seen.artboard(of: id)?.id != to || seen.node(id)?.isArtboard == true else { continue }
                    let c = FlowCurve.route(from: view(box), to: r)
                    m.threads.append((c, true, true, false, 0.8))
                    let d = c.tangent(1)
                    m.arrows.append((c.p3, atan2(Double(d.dy), Double(d.dx)), true))
                }
                m.screens.append((r.insetBy(dx: -4, dy: -4), 2, true))
            }
            // A thread being pulled: the screens it could go to lifting, the well to go back.
            if let pull {
                let home = seen.node(pull.source).flatMap { $0.isArtboard ? $0 : seen.artboard(of: pull.source) }?.id
                for board in Prototype.screens(in: seen) where board.id != home {
                    guard let r = boardRect(board.id) else { continue }
                    let on = pull.target == board.id
                    m.lifted.append((r.insetBy(dx: on ? -5 : -3, dy: on ? -5 : -3), on))
                }
                if let well = backWell(for: pull) {
                    let rise = CGFloat(min((now - pull.began) / 0.25, 1))
                    let s: CGFloat = (pull.back ? 1.18 : 1) * (0.6 + 0.4 * rise)
                    m.well = (CGRect(x: well.midX - well.width * s / 2, y: well.midY - well.height * s / 2, width: well.width * s, height: well.height * s), pull.back)
                }
                let caught = pull.target != nil || pull.back
                let cut = pull.again && !caught
                let c = curve(of: pull)
                m.threads.append((c, caught, cut, cut, 1))
                if caught {
                    let d = c.tangent(1)
                    m.arrows.append((c.p3, atan2(Double(d.dy), Double(d.dx)), true))
                }
                m.lights.append((c.p3, caught ? 7 : 9))
                m.dots.append((c.p0, false))
            }
            if let r = retracting {
                let u = CGFloat(min((now - r.at) / 0.32, 1))
                // Quick at first, as a stretched cord snaps back.
                let left = 1 - (1 - pow(1 - u, 3))
                if left > 0.01 {
                    m.threads.append((r.curve.upTo(left), false, r.cut, r.cut, Double(left)))
                    m.lights.append((r.curve.point(left), Double(6 * left + 2)))
                }
            }
            return m
        }
    }
}
