import Foundation

// Words along curves on the Windows canvas, as the Mac's CurveTool (Canvas/CurveTool.swift) has
// them, its logic in the Windows way of editing (a drag made again from where it began):
//
// - A selected text shows the line it sits on, running on past its ends to a bead at each. A
//   bead swung round the middle of the words bends them: they go a quarter of the angle it is
//   swung through round a circle, so straight below the middle they close into a ring, and above
//   it they sag. Straight, a half circle and a ring catch.
// - A text dragged and held a moment on a shape's edge catches on it: a line runs out along the
//   edge as far as the words will reach, and they go onto it. Still held, they slide along after
//   the pointer, keep to the side of the edge the pointer is on, and always turn to read upright.
//   Dragged clear, they let go again.
// - A text riding a shape, dragged, slides along it the same way; pulled well clear, it comes off,
//   straight again.
//
// Its letters spring to their new places letter by letter from the pointer (`fly`, LetterFlights).

extension WindowsCore {
    @MainActor public final class CurveHand {
        public var selection: [UUID] = []
        /// Whether the select tool is in hand with nothing being typed or edited.
        public var free = true
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// Draws the canvas's marks again.
        public var redraw: () -> Void = {}
        /// The design changed by itself, as a text caught on an edge it rested on: drawn again.
        public var edited: () -> Void = {}
        /// Has a text's next change fly letter by letter, from the letter nearest a point on the
        /// canvas (LetterFlights.fly).
        public var fly: (_ id: UUID, _ from: CGPoint?) -> Void = { _, _ in }
        /// The text being dragged, whose letters are watched as it rests on an edge or rides one.
        public var holding: UUID? { hold?.text }

        public init() {}

        private var doc: BezzleDocument? { WindowsCore.design }
        private func view(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        private func canvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
        private var inGesture: Bool { Editing.gestureStart != nil }
        private static func now() -> Double { Date().timeIntervalSinceReferenceDate }

        /// How long a text has to rest on an edge to catch on it.
        private static let rest: Double = 0.42
        /// How far the pointer may wander on screen and still be resting.
        private static let wander: CGFloat = 6
        /// How near an edge, on screen, the pointer has to be for the text to catch on it.
        private static let band: CGFloat = 12
        /// How far past its ends, on screen, a text's line runs out to its beads.
        private static let reach: CGFloat = 22
        private static let stops: [Double] = [-1, -0.5, 0, 0.5, 1]

        /// Whether the marks should be drawn again next frame, for something on its way.
        public var animating: Bool {
            if let h = hold, h.over != nil, h.ride == nil { return true }
            return glow.map { Self.now() - $0.born < 0.9 } == true
        }

        // MARK: Geometry

        /// From a layer's own coordinates, its frame's top left at zero, to the canvas.
        static func toCanvas(_ node: Node, origin o: CGPoint) -> CGAffineTransform {
            CGAffineTransform(translationX: -node.frame.width / 2, y: -node.frame.height / 2)
                .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
                .concatenating(CGAffineTransform(translationX: o.x + node.frame.midX, y: o.y + node.frame.midY))
        }

        /// A shape's outline on the canvas, and walked along as words on it are.
        private func outline(of shape: UUID, in doc: BezzleDocument) -> (path: CGPath, walk: CurvedText.Walk)? {
            guard let n = doc.node(shape) else { return nil }
            let o = doc.parentOrigin(of: shape)
            var t = CGAffineTransform(translationX: o.x, y: o.y)
            let placed = Renderer.placedOutline(of: n)
            let path = placed.copy(using: &t) ?? placed
            return (path, CurvedText.walk(path, oriented: true))
        }

        // MARK: Bending by the beads

        private struct Beads {
            let id: UUID
            /// The middle of the words, which stays where it is as they bend, on the canvas.
            let apex: CGPoint
            let turn: Double
            let bend: Double
            /// The line the words sit on, and on past their ends to the beads, on the canvas.
            let line: CGPath
            let beads: [CGPoint]
        }

        /// The selected text's line and beads, when one text lies selected that can be bent.
        private func beads() -> Beads? {
            guard free, selection.count == 1, let doc, let node = doc.node(selection[0]), node.kind == .text, !node.locked, !node.rides,
                  node.transform3D == nil, !doc.ancestors(of: node.id).contains(where: \.locked),
                  node.frame.width * zoom >= 14, !(node.text ?? "").isEmpty else { return nil }
            let t = Self.toCanvas(node, origin: doc.parentOrigin(of: node.id))
            let reach = Self.reach / zoom
            let line = CGMutablePath()
            let apex: CGPoint
            var ends: [CGPoint]
            if node.bent, let laid = CurvedText.laid(node), let first = laid.walk.points.first, let last = laid.walk.points.last {
                apex = laid.anchor.applying(t)
                ends = [first.applying(t), last.applying(t)]
                line.addLines(between: laid.walk.points.map { $0.applying(t) })
            } else {
                let base = TextLayout.firstBaseline(node)
                let width = min(node.frame.width, CurvedText.width(of: node) + 1)
                let x0: CGFloat = switch node.style?.align ?? .left {
                case .left, .justify: 0
                case .center: (node.frame.width - width) / 2
                case .right: node.frame.width - width
                }
                ends = [CGPoint(x: x0, y: base).applying(t), CGPoint(x: x0 + width, y: base).applying(t)]
                apex = CGPoint(x: (ends[0].x + ends[1].x) / 2, y: (ends[0].y + ends[1].y) / 2)
                line.move(to: ends[0])
                line.addLine(to: ends[1])
            }
            // Each bead lies on the line from the middle through its end, a little past it.
            let down = Geometry.rotate(CGPoint(x: 0, y: 1), by: node.rotation)
            let beads = ends.map { e -> CGPoint in
                var d = CGPoint(x: e.x - apex.x, y: e.y - apex.y)
                var len = hypot(d.x, d.y)
                if len < 0.01 {
                    // A ring's two ends meet straight below its middle, or above it for a sag.
                    d = (node.curve?.bend ?? 0) < 0 ? CGPoint(x: -down.x, y: -down.y) : down
                    len = 1
                }
                return CGPoint(x: e.x + d.x / len * reach, y: e.y + d.y / len * reach)
            }
            line.move(to: beads[0])
            line.addLine(to: ends[0])
            line.move(to: ends[1])
            line.addLine(to: beads[1])
            return Beads(id: node.id, apex: apex, turn: node.rotation, bend: node.curve?.bend ?? 0, line: line, beads: beads)
        }

        private struct Bending {
            let id: UUID
            let apex: CGPoint
            let turn: Double
            /// Which bead: the one at the words' end, or at their start.
            let atEnd: Bool
            var last: Double
            var caught: Double?
        }

        private var bending: Bending?
        /// Whether the pointer is near the selected text, so its beads show.
        private var near = false
        private var hoveredBead: Int?

        public var dragging: Bool { bending != nil }

        /// A press on a bead begins bending; false leaves it to the canvas.
        public func down(at v: CGPoint, clicks: Int, command: Bool) -> Bool {
            guard clicks == 1, !command, let b = beads() else { return false }
            let points = b.beads.map(view)
            guard let i = points.indices.min(by: { hypot(points[$0].x - v.x, points[$0].y - v.y) < hypot(points[$1].x - v.x, points[$1].y - v.y) }),
                  hypot(points[i].x - v.x, points[i].y - v.y) <= 9 else { return false }
            WindowsCore.beginGesture()
            bending = Bending(id: b.id, apex: b.apex, turn: b.turn, atEnd: i == 1, last: b.bend, caught: Self.stops.first { abs($0 - b.bend) < 0.0001 })
            return true
        }

        /// The bead dragged to `v`; with Ctrl (`command`, as ⌘ on the Mac) nothing catches.
        public func drag(to v: CGPoint, command: Bool) {
            guard var b = bending else { return }
            let p = canvas(v)
            let q = Geometry.rotate(CGPoint(x: p.x - b.apex.x, y: p.y - b.apex.y), by: -b.turn)
            guard hypot(q.x, q.y) * zoom > 6 else { return }
            // Swung down from level, the end arches the words; straight down, they are a ring.
            let phi = min(max(atan2(q.y, b.atEnd ? q.x : -q.x), -.pi / 2), .pi / 2)
            var bend = Double(phi / (.pi / 2))
            let near = command ? nil : Self.stops.first { abs($0 - bend) < 0.03 }
            if let near { bend = near }
            b.caught = near
            bend = (bend * 1000).rounded() / 1000
            if bend != b.last {
                b.last = bend
                let id = b.id
                WindowsCore.edit { doc in doc.update(id) { $0.bend(to: bend) } }
            }
            bending = b
            if let r = doc?.absoluteFrame(of: b.id) {
                let degrees = Int((abs(bend) * 360).rounded())
                WindowsCore.measure = (bend == 0 ? "0°" : "\(bend < 0 ? "−" : "")\(degrees)°", r)
            }
            redraw()
        }

        public func up() {
            guard bending != nil else { return }
            bending = nil
            WindowsCore.endGesture()
            WindowsCore.measure = nil
            redraw()
        }

        // MARK: Catching on an edge, and sliding along it

        /// What resting on an edge has come to.
        private struct Edge {
            let shape: UUID
            let path: CGPath
            let walk: CurvedText.Walk
            /// Where along it, in its own direction, the pointer is nearest.
            let s: CGFloat
        }

        /// A text riding a shape while it is dragged.
        private struct Ride {
            let text: UUID
            let shape: UUID
            /// Whether it caught on during this drag, and what the drag was made again from before
            /// it did, to go back to if it is dragged off.
            let caught: Bool
            let before: BezzleDocument?
            /// How far along the curve, in its own direction, the middle of the words is from the
            /// point nearest the pointer.
            var offset: CGFloat
            let width: CGFloat
            var changed = false
        }

        private struct Hold {
            let text: UUID
            var over: Edge?
            var since: Double = 0
            var at: CGPoint = .zero
            var ride: Ride?
            /// Shapes left again in this drag, which it does not catch on again.
            var declined: Set<UUID> = []
            var torn = false
            /// Each rest begun, so a rest broken since is not taken for it.
            var rests = 0
            /// Where the pointer has lately been on the canvas, latest last: the side of an edge it
            /// came from is where the words go.
            var trail: [CGPoint] = []
        }

        private var hold: Hold?
        private var glow: (path: CGPath, born: Double, out: Bool)?

        /// Whether resting or riding takes the drag, so that nothing else catches it, as a mask would.
        public var claims: Bool { hold?.ride != nil || hold?.over != nil }

        public enum Moved {
            /// Moved as anything is.
            case normal
            /// Slid along an edge: the canvas places nothing.
            case handled
            /// Torn off an edge: the move goes on from here with the text straight under the pointer.
            case restart
        }

        /// Something being moved has been dragged to `v` on screen, from `start` on the canvas.
        public func moving(_ ids: [UUID], from start: CGPoint, at v: CGPoint) -> Moved {
            guard ids.count == 1, let id = ids.first, let doc, let node = doc.node(id), node.kind == .text, !node.locked, inGesture else {
                if hold != nil { hold = nil }
                return .normal
            }
            let p = canvas(v)
            if hold?.text != id {
                hold = Hold(text: id)
                if node.rides, let shape = doc.parent(of: id)?.carrier, let edge = outline(of: shape.id, in: doc), let laid = CurvedText.laid(node) {
                    // Held where it was pressed, however far along the words that was.
                    let width = CurvedText.width(of: node)
                    let mid = middle(of: laid, total: laid.walk.total, width: width)
                    let press = edge.walk.nearest(to: start).s
                    hold?.ride = Ride(text: id, shape: shape.id, caught: false, before: nil, offset: wrap(mid - press, edge.walk), width: width)
                }
            }
            guard var h = hold else { return .normal }
            h.trail.append(p)
            if h.trail.count > 40 { h.trail.removeFirst(h.trail.count - 40) }
            hold = h
            if var ride = h.ride {
                guard let edge = outline(of: ride.shape, in: doc), edge.walk.total > 0 else {
                    hold?.ride = nil
                    return .normal
                }
                let near = edge.walk.nearest(to: p)
                let size = (node.style?.size ?? 24) * zoom
                let tears = ride.caught ? max(40, size * 1.6) : max(64, size * 2.4)
                if near.distance * zoom > tears {
                    h.declined.insert(ride.shape)
                    h.ride = nil
                    h.over = nil
                    hold = h
                    glow = (edge.path, Self.now(), true)
                    fly(id, p)
                    if ride.caught {
                        // Caught a moment ago: back as it was, straight under the pointer.
                        Editing.gestureBase = ride.before
                        redraw()
                        return .normal
                    }
                    return tearOff(id, at: p, from: start)
                }
                slide(&ride, node: node, edge: edge, near: near)
                h.ride = ride
                hold = h
                redraw()
                return .handled
            }
            // Resting on an edge.
            let found = edgeUnder(p, for: id, declined: h.declined, in: doc)
            if found?.shape != h.over?.shape || hypot(v.x - h.at.x, v.y - h.at.y) > Self.wander {
                h.over = found
                h.since = Self.now()
                h.at = v
                h.rests += 1
                if found != nil {
                    let rest = h.rests
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.rest) { [weak self] in
                        MainActor.assumeIsolated { self?.catchOn(at: v, rest: rest) }
                    }
                }
            } else if let found {
                h.over = found
            }
            hold = h
            redraw()
            return .normal
        }

        /// The middle of the words laid on a curve, in its own direction.
        private func middle(of laid: CurvedText.Laid, total: CGFloat, width: CGFloat) -> CGFloat {
            let s = laid.walk.nearest(to: laid.anchor).s
            let read = laid.reversed ? total - s : s
            let mid = read + (0.5 - laid.alignK) * width
            return laid.reversed ? total - mid : mid
        }

        /// Where along a curve, in its own direction, a text is placed from, for its words' middle at `mid`.
        private func at(middle mid: CGFloat, width: CGFloat, alignK k: CGFloat, reversed: Bool, total: CGFloat) -> Double {
            let read = reversed ? total - mid : mid
            let anchor = read - (0.5 - k) * width
            let own = reversed ? total - anchor : anchor
            return Double(own / max(total, 0.0001))
        }

        private func wrap(_ s: CGFloat, _ walk: CurvedText.Walk) -> CGFloat {
            guard walk.closed, walk.total > 0 else { return s }
            var x = s.truncatingRemainder(dividingBy: walk.total)
            if x > walk.total / 2 { x -= walk.total }
            if x < -walk.total / 2 { x += walk.total }
            return x
        }

        /// Slides a riding text after the pointer, to the side of the edge it is on, reading upright.
        private func slide(_ ride: inout Ride, node: Node, edge: (path: CGPath, walk: CurvedText.Walk), near: (s: CGFloat, distance: CGFloat, side: CGFloat)) {
            guard var curve = node.curve else { return }
            let walk = edge.walk, total = walk.total
            var mid = near.s + ride.offset
            if walk.closed {
                mid = mid.truncatingRemainder(dividingBy: total)
                if mid < 0 { mid += total }
            } else {
                mid = min(max(mid, -total * 0.25), total * 1.25)
            }
            let k = CurvedText.alignK(node, closed: walk.closed)
            var reversed = curve.reversed == true
            var hangs = curve.hangs == true
            // On the side the pointer is on, once it is clearly over.
            let left = reversed == hangs
            if near.distance * zoom > 3, (near.side > 0) != left { hangs.toggle() }
            // Upright: turned round once the words would read more than a little upside down.
            let angle = walk.at(mid).angle + (reversed ? .pi : 0)
            if cos(angle) < -0.26 {
                reversed.toggle()
                hangs.toggle()
            }
            curve.reversed = reversed ? true : nil
            curve.hangs = hangs ? true : nil
            curve.at = (at(middle: mid, width: ride.width, alignK: k, reversed: reversed, total: total) * 10_000).rounded() / 10_000
            guard curve != node.curve else { return }
            // Over to the other side, or turned round: letter by letter.
            if curve.reversed != node.curve?.reversed || curve.hangs != node.curve?.hangs { fly(node.id, canvas(hold?.at ?? .zero)) }
            ride.changed = true
            let id = node.id
            // Made again from what the drag is made from: the text as it rode then, set where it slides to.
            WindowsCore.edit { doc in doc.update(id) { $0.curve = curve } }
        }

        /// Takes a text that rode before the drag off its shape, straight under the pointer, and has
        /// the drag carry on with it from there.
        private func tearOff(_ id: UUID, at p: CGPoint, from start: CGPoint) -> Moved {
            guard let begun = Editing.gestureStart else { return .normal }
            let base = Editing.edited(Editing.gestureBase ?? begun, start: nil) { $0.takeOffPath([id]) }
            guard let frame = base.absoluteFrame(of: id) else { return .normal }
            Editing.gestureBase = base
            design = base
            hold?.torn = true
            // Its middle under the pointer, as at the drag's start it would have been at the press.
            let placed = CGRect(x: p.x - frame.width / 2, y: p.y - frame.height / 2, width: frame.width, height: frame.height)
            WindowsCore.restartMove([id: placed.offsetBy(dx: start.x - p.x, dy: start.y - p.y)])
            redraw()
            return .restart
        }

        /// Resting has lasted: the text goes onto the edge, as one step with the drag.
        private func catchOn(at v: CGPoint, rest: Int) {
            guard var h = hold, h.rests == rest, h.ride == nil, let edge = h.over, inGesture, let doc, let node = doc.node(h.text),
                  let frame = doc.absoluteFrame(of: h.text) else { return }
            let walk = edge.walk, total = walk.total
            guard total > 1 else { return }
            let width = CurvedText.width(of: node)
            let p = canvas(v)
            let near = walk.nearest(to: p)
            // The words go to the side of the edge they came from, reading upright.
            let clear = 3 / zoom
            let came = h.trail.reversed().lazy.map { walk.nearest(to: $0) }.first { $0.distance > clear }
            let body = walk.nearest(to: CGPoint(x: frame.midX, y: frame.midY))
            let left = came.map { $0.side > 0 } ?? (body.distance > 1 ? body.side > 0 : near.side >= 0)
            let reversed = cos(walk.at(near.s).angle) < -0.26
            let hangs = reversed == left
            var curve = TextCurve(rides: true)
            curve.reversed = reversed ? true : nil
            curve.hangs = hangs ? true : nil
            let k = CurvedText.alignK(node, closed: walk.closed)
            curve.at = (at(middle: near.s, width: width, alignK: k, reversed: reversed, total: total) * 10_000).rounded() / 10_000
            // The drag goes on from the design as it is now, the text on the edge.
            let before = Editing.gestureBase
            fly(h.text, p)
            var made: UUID?
            let id = h.text
            let caught = Editing.edited(doc, start: nil) { made = $0.ride(id, on: edge.shape, curve: curve) }
            guard made != nil, caught.node(id)?.rides == true else { return }
            Editing.gestureBase = caught
            design = caught
            h.ride = Ride(text: id, shape: edge.shape, caught: true, before: before, offset: 0, width: width)
            h.over = nil
            hold = h
            glow = (edge.path, Self.now(), false)
            edited()
            redraw()
        }

        /// The edge of a shape a text dragged to `p` would catch on: the frontmost whose outline the
        /// pointer is on, of those it could ride.
        private func edgeUnder(_ p: CGPoint, for text: UUID, declined: Set<UUID>, in doc: BezzleDocument) -> Edge? {
            let band = Self.band / zoom
            var found: Edge?
            func look(_ nodes: [Node], origin: CGPoint) {
                for n in nodes.reversed() where found == nil && !n.hidden && n.id != text {
                    if n.isGroup {
                        guard !n.isRepeatGrid else { continue }
                        look(n.children, origin: CGPoint(x: origin.x + n.frame.minX, y: origin.y + n.frame.minY))
                        continue
                    }
                    guard TextCurve.canCarry(n), !declined.contains(n.id),
                          Geometry.bounds(of: n).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -band, dy: -band).contains(p),
                          doc.canRide(text, on: n.id) else { continue }
                    var t = CGAffineTransform(translationX: origin.x, y: origin.y)
                    let placed = Renderer.placedOutline(of: n)
                    let path = placed.copy(using: &t) ?? placed
                    guard path.copy(strokingWithWidth: band * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).contains(p) else { continue }
                    let walk = CurvedText.walk(path, oriented: true)
                    guard walk.total * zoom > 24 else { continue }
                    found = Edge(shape: n.id, path: path, walk: walk, s: walk.nearest(to: p).s)
                }
            }
            for top in doc.nodes.reversed() where found == nil && !top.hidden {
                if top.isArtboard {
                    guard top.frame.insetBy(dx: -band, dy: -band).contains(p) else { continue }
                    look(top.seenLayers(fronts: WindowsCore.fronts), origin: top.frame.origin)
                    if found == nil, top.frame.contains(p) { break }
                } else {
                    look([top], origin: .zero)
                }
            }
            return found
        }

        /// The drag has been let go: whether it put a text on an edge, slid it along one or took it
        /// off, rather than only moving it, and so whether the text rides (and is not placed).
        public func released() -> (rides: Bool, did: Bool) {
            guard let h = hold else { return (false, false) }
            hold = nil
            if let ride = h.ride { return (true, ride.caught || ride.changed) }
            return (false, h.torn)
        }

        public func cancel() {
            guard hold != nil || bending != nil else { return }
            hold = nil
            if bending != nil {
                bending = nil
                WindowsCore.cancelGesture()
                WindowsCore.measure = nil
            }
            redraw()
        }

        // MARK: The pointer

        /// The pointer at rest, or gone (nil); whether what shows changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool {
            var near = false
            var bead: Int?
            if let v, let b = beads() {
                let points = b.beads.map(view)
                bead = points.indices.first { hypot(points[$0].x - v.x, points[$0].y - v.y) <= 9 }
                if bead == nil, let id = selection.first, let frame = doc?.absoluteFrame(of: id) {
                    let a = view(frame.origin), z = view(CGPoint(x: frame.maxX, y: frame.maxY))
                    near = CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y).insetBy(dx: -Self.reach - 12, dy: -18).contains(v)
                }
                near = near || bead != nil
            }
            guard near != self.near || bead != hoveredBead else { return false }
            self.near = near
            hoveredBead = bead
            redraw()
            return true
        }

        /// Whether the pointer shows a hand: on a bead, bending, or on a selected text riding a shape,
        /// which slides along it.
        public func grabs(at v: CGPoint) -> Bool {
            if bending != nil { return true }
            if free, selection.count == 1, let doc, let node = doc.node(selection[0]), node.rides, !node.locked {
                let o = doc.parentOrigin(of: node.id), p = canvas(v)
                if Geometry.contains(node, CGPoint(x: p.x - o.x, y: p.y - o.y), tolerance: 3 / zoom) { return true }
            }
            guard let b = beads() else { return false }
            return b.beads.map(view).contains { hypot($0.x - v.x, $0.y - v.y) <= 9 }
        }

        // MARK: What shows

        /// What shows, on the stage, as path data: the line a selected text sits on, more strongly
        /// while bent, and its beads (7 points, 9 lit); an edge being rested on (its outline, and a
        /// line running out along it as far as the words will reach, growing as the rest lasts);
        /// and the glow of an edge just caught on or left. Alphas and glows run 0…1.
        public struct Marks {
            public let line: String?
            public let lineStrong: Bool
            public let beads: [(at: CGPoint, lit: Bool)]
            public let edge: (path: String, alpha: Double, glow: Double)?
            public let run: (path: String, alpha: Double, glow: Double)?
            public let flash: (path: String, alpha: Double, glow: Double)?
        }

        public func marks() -> Marks {
            let toView = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y)
            func shown(_ path: CGPath) -> String? {
                var t = toView
                return path.copy(using: &t).map { PathData.string($0) }
            }
            let now = Self.now()
            var edge: (String, Double, Double)?, run: (String, Double, Double)?, flash: (String, Double, Double)?
            if let h = hold, h.ride == nil, let over = h.over, let node = doc?.node(h.text) {
                let progress = min(max((now - h.since) / Self.rest, 0), 1)
                let eased = 1 - pow(1 - progress, 3)
                if let d = shown(over.path) { edge = (d, 0.45 * eased, 0.35 * eased) }
                // As far each way as the words will reach.
                let half = CurvedText.width(of: node) / 2 * CGFloat(eased)
                let line = CGMutablePath()
                let steps = max(Int(half * 2 * zoom / 3), 2)
                for i in 0...steps {
                    let s = over.s - half + half * 2 * CGFloat(i) / CGFloat(steps)
                    let q = over.walk.at(over.walk.closed ? s : min(max(s, 0), over.walk.total)).point
                    if i == 0 { line.move(to: q) } else { line.addLine(to: q) }
                }
                if let d = shown(line) { run = (d, 0.9 * eased, 0.8 * eased) }
            }
            if let g = glow {
                let age = now - g.born
                if age > 0.9 {
                    glow = nil
                } else {
                    let k = g.out ? max(0, 1 - age / 0.5) * 0.6 : (age < 0.12 ? age / 0.12 : max(0, 1 - (age - 0.12) / 0.78))
                    if let d = shown(g.path) { flash = (d, k * 0.8, k) }
                }
            }
            var line: String?
            var dots: [(CGPoint, Bool)] = []
            if near || bending != nil, hold == nil, let b = beads() {
                line = shown(b.line)
                dots = b.beads.enumerated().map { i, bead in
                    (view(bead), hoveredBead == i || (bending.map { $0.atEnd == (i == 1) } ?? false))
                }
            }
            return Marks(line: line, lineStrong: bending != nil, beads: dots, edge: edge, run: run, flash: flash)
        }
    }

    /// The move goes on from here with these layers, at these frames where the drag began (on the
    /// canvas): as after a text was torn off the edge it rode.
    static func restartMove(_ originals: [UUID: CGRect]) {
        guard let doc = design else { return }
        let bounds = originals.values.reduce(CGRect.null) { $0.union($1) }
        moving = (originals, bounds, SnapTargets(doc: doc, moving: Set(originals.keys)), .zero)
    }

    /// The move let go with a text riding the edge it was dragged along: not placed by the move,
    /// only settled where it lies, all one step.
    public static func endRide(_ ids: [UUID]) {
        if let doc = design { Editing.gestureBase = doc }
        edit { $0.settle(ids) }
        moving = nil
        endGesture()
    }
}
